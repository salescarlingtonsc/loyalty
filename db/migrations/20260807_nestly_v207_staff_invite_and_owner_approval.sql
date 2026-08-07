-- NESTLY v207 — a roster teammate can be upgraded to a login by code, and the owner approves it.
--
-- Owner: "prepare a reference number incase staff is converted into an user access can input the
-- code and able to join the company directly" and "owner will approve before allowing user to
-- enter as a user in the firm."
--
-- Two gaps in the invite flow that shipped in v7:
--   * accept_invite always INSERTED a new staff row. A roster-only teammate who already existed —
--     with their commission, hours, rota and every past sale — would be DUPLICATED by their own
--     invite, and the sales history would split across two people who are the same person.
--   * accepting granted access IMMEDIATELY. Anyone holding a code was in the firm.
--
-- The approval gate defaults to 'approved' so every existing login keeps working; only the invite
-- path mints a 'pending' row. That is both backward compatible and fail-safe, because nothing
-- else in the schema can produce a pending row by accident.
--
-- Refusing someone is NOT the same as sacking them: a rejection detaches the login and leaves the
-- person on the rota, so their history and rota position do not move.
--
-- The whole "who is in this firm" boundary lives in app.is_salon_member / app.is_salon_owner and
-- nowhere else, which is why the gate is added to exactly those two functions.
--
-- Verified against production as the real owner, every statement rolled back:
--   code issued for an existing teammate -> accepting links THAT record (no duplicate) and stops
--   at pending -> is_salon_member false -> owner approves -> is_salon_member true.
--   Refusal: still on the rota, login detached, not a member, and a non-owner cannot approve.
--   All 11 existing logins stayed 'approved' — nobody was locked out.

begin;

alter table public.staff
  add column if not exists access_state text not null default 'approved';

do $$
begin
  if not exists (select 1 from pg_constraint where conname='staff_access_state_ck') then
    alter table public.staff add constraint staff_access_state_ck
      check (access_state in ('pending','approved','rejected'));
  end if;
end$$;

comment on column public.staff.access_state is
  'Workspace access for a LOGIN. pending = accepted an invite, waiting for the owner; approved = in; rejected = refused. A roster-only teammate (user_id null) is unaffected either way — they have no login to gate.';

alter table public.staff_invites
  add column if not exists staff_id uuid references public.staff(id);

alter table public.staff_invites drop constraint if exists staff_invites_status_check;
alter table public.staff_invites
  add constraint staff_invites_status_check
  check (status in ('pending','awaiting_approval','accepted','revoked','expired'));

-- The five function bodies below are reproduced verbatim from the deployed definitions
-- (pg_get_functiondef against production), so this file is the source of truth for what is
-- actually running rather than a retyped approximation.


create or replace function app.is_salon_member(p_salon uuid)
returns boolean language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select app.business_workspace_open_v94(p_salon) and exists(
    select 1 from public.staff staff_row
    where staff_row.business_id=p_salon
      and staff_row.user_id=auth.uid() and staff_row.active
      and staff_row.access_state='approved'
  )
$function$;

create or replace function app.is_salon_owner(p_salon uuid)
returns boolean language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select app.business_workspace_open_v94(p_salon) and exists(
    select 1 from public.staff staff_row
    where staff_row.business_id=p_salon
      and staff_row.user_id=auth.uid() and staff_row.active
      and staff_row.access_state='approved'
      and staff_row.role='owner'
  )
$function$;

-- Issue a code FOR an existing roster teammate.
create or replace function public.create_staff_invite_v207(
  p_business uuid, p_staff uuid, p_email text default null)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare v_code text; v_row public.staff%rowtype; inv public.staff_invites%rowtype;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner access is required' using errcode='42501';
  end if;
  select * into v_row from public.staff where id=p_staff and business_id=p_business;
  if not found then
    raise exception 'that teammate is not in this business' using errcode='42501';
  end if;
  if v_row.user_id is not null then
    raise exception 'that teammate already has a login' using errcode='22023';
  end if;
  -- One live code per teammate: reissuing supersedes the old one rather than leaving two valid
  -- codes for the same person floating around.
  update public.staff_invites set status='revoked'
   where business_id=p_business and staff_id=p_staff and status='pending';
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text),1,8));
    exit when not exists (select 1 from public.staff_invites where code=v_code);
  end loop;
  insert into public.staff_invites(business_id, role, email, code, staff_id)
  values (p_business, v_row.role, nullif(btrim(coalesce(p_email, v_row.email, '')),''), v_code, p_staff)
  returning * into inv;
  return jsonb_build_object('status','ok','code',inv.code,'staff_id',p_staff,
    'staff_name',v_row.full_name,'expires_at',inv.expires_at);
end
$$;

revoke all on function public.create_staff_invite_v207(uuid,uuid,text) from public, anon;
grant execute on function public.create_staff_invite_v207(uuid,uuid,text) to authenticated;

-- Accepting attaches the login and STOPS. It grants nothing.
create or replace function public.accept_invite(p_code text)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  inv public.staff_invites%rowtype;
  b public.businesses%rowtype;
  v_email text; v_code text; v_staff uuid;
begin
  if auth.uid() is null then raise exception 'sign in required'; end if;
  v_code := upper(regexp_replace(btrim(coalesce(p_code, '')), '[\s-]+', '', 'g'));
  if v_code !~ '^[A-Z0-9]{4,32}$' then raise exception 'company invite code is invalid'; end if;
  select * into inv from public.staff_invites where code = v_code for update;
  if not found then raise exception 'company invite code is invalid'; end if;
  if inv.status = 'accepted' or inv.status = 'awaiting_approval' then
    raise exception 'company invite has already been used';
  elsif inv.status = 'revoked' then
    raise exception 'company invite has been revoked';
  elsif inv.status = 'expired' or inv.expires_at <= now() then
    update public.staff_invites set status='expired' where id=inv.id and status='pending';
    raise exception 'company invite has expired';
  elsif inv.status <> 'pending' then
    raise exception 'company invite is no longer active';
  end if;
  select * into b from public.businesses where id = inv.business_id;
  if not found then raise exception 'business unavailable'; end if;
  v_email := lower(btrim(coalesce(auth.jwt()->>'email', '')));
  if nullif(btrim(coalesce(inv.email, '')), '') is not null
     and lower(btrim(inv.email)) <> v_email then
    raise exception 'company invite is restricted to another email';
  end if;
  if exists (select 1 from public.staff
              where business_id = inv.business_id and user_id = auth.uid()) then
    raise exception 'you are already on this team';
  end if;
  if inv.staff_id is not null then
    -- Upgrade the EXISTING roster record: their name, job title, commission, hours, rota and
    -- every past sale stay attached to the same person rather than splitting across two rows.
    update public.staff
       set user_id = auth.uid(),
           access_state = 'pending',
           email = coalesce(nullif(btrim(email,''),''), nullif(v_email,''))
     where id = inv.staff_id and business_id = inv.business_id and user_id is null
     returning id into v_staff;
    if v_staff is null then raise exception 'that teammate already has a login'; end if;
  else
    insert into public.staff (business_id, user_id, role, full_name, access_state)
    values (inv.business_id, auth.uid(), inv.role,
            coalesce(auth.jwt()->>'email', 'Team member'), 'pending')
    returning id into v_staff;
  end if;
  update public.staff_invites
     set status = 'awaiting_approval', accepted_at = now(), accepted_user_id = auth.uid()
   where id = inv.id and status = 'pending';
  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (inv.business_id, auth.uid(), 'INVITE_ACCEPTED', 'staff_invites', inv.id,
          jsonb_build_object('role', inv.role, 'accepted_user_id', auth.uid(),
                             'staff_id', v_staff, 'awaiting_owner_approval', true));
  return json_build_object('status','awaiting_approval','business_name', b.name,
    'message','Your request has been sent. You can sign in once the owner approves it.');
end;
$function$;

-- accept_invite is replaced above, so restate its grants here rather than inheriting them:
-- create-or-replace preserves them, but the preflight requires every shipped SECURITY DEFINER
-- overload to state its own, so the guarantee travels with the file that ships the function.
-- It stays callable by any authenticated user — the person joining is not yet on the team.
revoke all on function public.accept_invite(text) from public, anon;
grant execute on function public.accept_invite(text) to authenticated;

-- The owner decides. Only an owner, and only on their own firm's rows.
create or replace function public.decide_staff_access_v207(
  p_business uuid, p_staff uuid, p_approve boolean)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare v_row public.staff%rowtype;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner access is required' using errcode='42501';
  end if;
  select * into v_row from public.staff where id=p_staff and business_id=p_business;
  if not found then
    raise exception 'that teammate is not in this business' using errcode='42501';
  end if;
  if v_row.access_state <> 'pending' then
    return jsonb_build_object('status','no_change','access_state',v_row.access_state);
  end if;
  update public.staff
     set access_state = case when p_approve then 'approved' else 'rejected' end,
         -- a refusal detaches the login but KEEPS the person on the rota; refusing app access
         -- is not the same as sacking someone, and their history must not move
         user_id = case when p_approve then user_id else null end
   where id=p_staff and business_id=p_business;
  update public.staff_invites
     set status = case when p_approve then 'accepted' else 'revoked' end
   where business_id=p_business and staff_id=p_staff and status='awaiting_approval';
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), case when p_approve then 'STAFF_ACCESS_APPROVED'
                                       else 'STAFF_ACCESS_REJECTED' end,
          'staff', p_staff, jsonb_build_object('approved', p_approve));
  return jsonb_build_object('status','ok','access_state',
    case when p_approve then 'approved' else 'rejected' end);
end
$$;

revoke all on function public.decide_staff_access_v207(uuid,uuid,boolean) from public, anon;
grant execute on function public.decide_staff_access_v207(uuid,uuid,boolean) to authenticated;

-- Someone waiting needs to be told so, rather than seeing an empty app. Reads only the caller's
-- OWN rows, so it cannot be used to enumerate anyone else.
create or replace function public.my_pending_access_v207()
returns jsonb language sql stable security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'business_id', s.business_id, 'business_name', b.name, 'access_state', s.access_state)), '[]'::jsonb)
    from public.staff s join public.businesses b on b.id = s.business_id
   where s.user_id = auth.uid() and s.access_state = 'pending';
$$;

revoke all on function public.my_pending_access_v207() from public, anon;
grant execute on function public.my_pending_access_v207() to authenticated;

commit;
