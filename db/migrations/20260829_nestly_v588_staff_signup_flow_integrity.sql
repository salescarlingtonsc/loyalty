-- nestly_v588 — the staff reference-code sign-up flow stops contradicting itself.
--
-- Owner, 2026-08-29 (pre-go-live): "even using the reference code to sign up as staff, during
-- sign up process - it is in a mess." Walked end-to-end against production. The machinery joins
-- people (audit_log shows accepts and approvals completing), but three server behaviours make the
-- journey incoherent, and the client compounds them (fixed in app/app.js alongside this):
--
--   1. accept_invite RETURNS NO BUSINESS IDENTITY — {status,business_name,message} only — while
--      the client assigned that object to S.biz and navigated to a dashboard it could not open.
--      And it is NOT idempotent: the sign-up flow's own instruction is "return to this invite
--      link", but a returning accepter hits status='awaiting_approval' and is told the invite
--      "has already been used", as if somebody else had taken it.
--   2. preview_staff_invite has no case for 'awaiting_approval' — the status accept_invite itself
--      writes — so it falls through to 'invalid'. During the exact window a confused new teammate
--      re-checks their code (accepted, waiting for the owner), every screen calls their code
--      INVALID. Measured live: Cubbly's Kelvin has SEVEN revoked codes from the owner retrying
--      around this.
--   3. create_staff_reference_code_v217 revokes the live code EVERY time the owner opens the
--      modal — "Give app access" is also silently "kill the code I already handed out". Those
--      seven revoked codes are this: re-opening the dialog to re-read the code cancels it.
--
-- WHAT CHANGES:
--   * accept_invite: same-user replay returns the same success payload (replayed:true, current
--     access_state) instead of raising — for ANY terminal status whose accepted_user_id is the
--     caller, including a code revoked AFTER they accepted. A DIFFERENT user's replay still gets
--     the original refusals verbatim. The payload gains business_id / business_slug /
--     access_state so the client can wait on, and then enter, the right workspace.
--   * preview_staff_invite: 'awaiting_approval' becomes its own status instead of 'invalid'.
--   * create_staff_reference_code_v217: an unexpired pending code for the teammate is RETURNED
--     (reused:true) rather than revoked and reminted; p_rotate := true forces a fresh one. The
--     2-arg overload is dropped in the same statement list so PostgREST never sees two candidates
--     (the PGRST203 lesson from v410); its only caller is app/app.js, updated with this change.
--
-- Nothing about WHO may join changes: every guard — code shape, expiry, revocation, the email
-- restriction, the owner-approval park at access_state='pending' (v569) — is byte-preserved.

begin;

create or replace function public.accept_invite(p_code text)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  inv public.staff_invites%rowtype;
  b public.businesses%rowtype;
  v_email text;
  v_code text;
  v_staff uuid;
  v_access text;
begin
  if auth.uid() is null then raise exception 'sign in required'; end if;

  v_code := upper(regexp_replace(btrim(coalesce(p_code, '')), '[\s-]+', '', 'g'));
  if v_code !~ '^[A-Z0-9]{4,32}$' then raise exception 'company invite code is invalid'; end if;

  select * into inv from public.staff_invites where code = v_code for update;
  if not found then raise exception 'company invite code is invalid'; end if;

  -- nestly_v588: the flow's own instruction is "return to this invite link", so the person who
  -- already accepted must get the same answer again, not a refusal implying somebody else used
  -- their code. This covers every terminal status they themselves produced — including a code the
  -- owner revoked AFTER acceptance, because that revocation was aimed at the paper slip, not at
  -- the person already on the roster. Anyone ELSE keeps the original refusals below, verbatim.
  if inv.accepted_user_id = auth.uid() then
    select * into b from public.businesses where id = inv.business_id;
    select access_state into v_access from public.staff
     where business_id = inv.business_id and user_id = auth.uid()
     order by (access_state='approved') desc limit 1;
    return json_build_object('status', case when v_access='approved' then 'approved' else 'awaiting_approval' end,
      'business_id', inv.business_id, 'business_slug', b.slug, 'business_name', b.name,
      'replayed', true,
      'message', case when v_access='approved'
        then 'You are already on this team. Opening the workspace.'
        else 'Your request has been sent. You can sign in once the owner approves it.' end);
  end if;

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
    if v_staff is null then
      raise exception 'that teammate already has a login';
    end if;
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

  -- nestly_v588: the caller has to be able to wait on, and then open, the right workspace.
  return json_build_object('status','awaiting_approval',
    'business_id', inv.business_id, 'business_slug', b.slug, 'business_name', b.name,
    'message','Your request has been sent. You can sign in once the owner approves it.');
end;
$function$;
revoke all on function public.accept_invite(text) from public, anon;
grant execute on function public.accept_invite(text) to authenticated, service_role;

create or replace function public.preview_staff_invite(p_code text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_code text;
  inv public.staff_invites%rowtype;
  biz record;
  v_status text;
begin
  v_code := upper(regexp_replace(btrim(coalesce(p_code, '')), '[\s-]+', '', 'g'));
  if v_code !~ '^[A-Z0-9]{4,32}$' then
    return jsonb_build_object('status', 'invalid');
  end if;

  select * into inv
  from public.staff_invites
  where code = v_code;

  if not found then
    return jsonb_build_object('status', 'invalid');
  end if;

  select name, slug, industry into biz
  from public.businesses
  where id = inv.business_id;

  if not found then
    return jsonb_build_object('status', 'business_unavailable');
  end if;

  v_status := case
    when inv.status = 'accepted' then 'already_used'
    -- nestly_v588: the status accept_invite itself writes. Falling to 'invalid' here is why a
    -- teammate re-checking their code while waiting for approval was told it never existed.
    when inv.status = 'awaiting_approval' then 'awaiting_approval'
    when inv.status = 'revoked' then 'revoked'
    when inv.status = 'expired' or inv.expires_at <= now() then 'expired'
    when inv.status = 'pending' then 'valid'
    else 'invalid'
  end;

  return jsonb_build_object(
    'status', v_status,
    'business_name', biz.name,
    'business_slug', biz.slug,
    'business_industry', biz.industry,
    'role', inv.role,
    'restricted_email', nullif(btrim(coalesce(inv.email, '')), ''),
    'expires_at', inv.expires_at
  );
end;
$$;
revoke all on function public.preview_staff_invite(text) from public;
grant execute on function public.preview_staff_invite(text) to anon, authenticated, service_role;

-- The 2-arg overload goes in the same statement list its replacement arrives, so PostgREST never
-- holds two candidates for the same named-argument call (the v410 PGRST203 lesson). Its only
-- caller is app/app.js, updated together with this migration.
drop function public.create_staff_reference_code_v217(uuid, uuid);

create function public.create_staff_reference_code_v217(
  p_business uuid, p_staff uuid, p_rotate boolean default false)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_actor uuid := auth.uid();
  v_staff public.staff%rowtype;
  v_existing public.staff_invites%rowtype;
  v_code text;
  v_invite uuid;
  v_expires timestamptz := now() + interval '14 days';
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode='42501';
  end if;
  -- Granting app access is an owner/manager act, exactly like create_invite.
  if not (app.is_salon_owner(p_business) or app.has_perm(p_business,'manage_staff')) then
    raise exception 'staff reference code authorization required' using errcode='42501';
  end if;

  select * into v_staff from public.staff
  where id = p_staff and business_id = p_business
  for update;
  if not found then
    raise exception 'staff_member_not_found' using errcode='22023';
  end if;
  if v_staff.user_id is not null then
    raise exception 'staff_member_already_has_login' using errcode='22023';
  end if;
  if not coalesce(v_staff.active, true) then
    raise exception 'staff_member_inactive' using errcode='22023';
  end if;
  if v_staff.role = 'owner' then
    raise exception 'owner_is_not_invitable' using errcode='22023';
  end if;

  -- nestly_v588: re-opening the dialog must not kill the code the owner already handed out.
  -- Measured live before this change: one teammate had SEVEN revoked codes, each one the owner
  -- re-opening "Give app access" to re-read a code that this very act had just cancelled. An
  -- unexpired pending code is returned as-is; p_rotate is the explicit "cancel it and mint a
  -- fresh one" the owner asks for when the slip of paper is lost.
  if not coalesce(p_rotate, false) then
    select * into v_existing from public.staff_invites
    where business_id = p_business and staff_id = p_staff
      and status = 'pending' and expires_at > now()
    order by created_at desc limit 1;
    if found then
      return jsonb_build_object('status','ok','code',v_existing.code,'invite_id',v_existing.id,
        'staff_id',p_staff,'staff_name',v_staff.full_name,'role',v_existing.role,
        'expires_at',v_existing.expires_at,'reused',true,
        'restricted_to_email', nullif(btrim(coalesce(v_existing.email,'')),''));
    end if;
  end if;

  -- One live code per teammate. Rotating supersedes the previous one so an old slip of paper
  -- cannot still claim the same person after the owner has re-thought it.
  update public.staff_invites set status='revoked'
  where business_id = p_business and staff_id = p_staff and status = 'pending';

  -- Unambiguous alphabet: no O/0, no I/1, so a handwritten code is readable by someone who may
  -- not read English well. accept_invite upper-cases and strips spaces and dashes already.
  loop
    v_code := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
                (floor(random()*32)+1)::int, 1), '')
               from generate_series(1,8));
    exit when not exists(select 1 from public.staff_invites where code = v_code);
  end loop;

  insert into public.staff_invites(business_id, email, role, code, status, expires_at, staff_id)
  values (p_business, nullif(btrim(coalesce(v_staff.email,'')),''), v_staff.role, v_code,
          'pending', v_expires, p_staff)
  returning id into v_invite;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'STAFF_REFERENCE_CODE_CREATED_V217', 'staff_invites', v_invite,
          jsonb_build_object('staff_id', p_staff, 'role', v_staff.role,
                             'staff_name', v_staff.full_name));

  return jsonb_build_object('status','ok','code',v_code,'invite_id',v_invite,
    'staff_id',p_staff,'staff_name',v_staff.full_name,'role',v_staff.role,
    'expires_at',v_expires,'reused',false,
    'restricted_to_email', nullif(btrim(coalesce(v_staff.email,'')),''));
end
$fn$;
revoke all on function public.create_staff_reference_code_v217(uuid,uuid,boolean) from public, anon;
grant execute on function public.create_staff_reference_code_v217(uuid,uuid,boolean) to authenticated, service_role;

commit;
