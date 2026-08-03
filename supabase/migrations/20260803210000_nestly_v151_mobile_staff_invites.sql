-- NESTLY v151 — mobile staff invite preview and hardened invite acceptance.
--
-- Scope:
-- - Reuse the existing staff_invites/staff membership model.
-- - Add only the missing acceptance metadata and expired state.
-- - Keep the invite record, not the browser, as the source of truth for role and tenant.

alter table public.staff_invites
  add column if not exists accepted_at timestamptz,
  add column if not exists accepted_user_id uuid references auth.users(id) on delete set null;

alter table public.staff_invites drop constraint if exists staff_invites_status_check;
alter table public.staff_invites
  add constraint staff_invites_status_check
  check (status in ('pending','accepted','revoked','expired'));

create index if not exists staff_invites_code_status_v151
  on public.staff_invites (code, status);

create or replace function public.preview_staff_invite(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
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

revoke execute on function public.preview_staff_invite(text) from public;
grant execute on function public.preview_staff_invite(text) to anon, authenticated;

create or replace function public.accept_invite(p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  inv public.staff_invites%rowtype;
  b public.businesses%rowtype;
  v_email text;
  v_code text;
begin
  if auth.uid() is null then
    raise exception 'sign in required';
  end if;

  v_code := upper(regexp_replace(btrim(coalesce(p_code, '')), '[\s-]+', '', 'g'));
  if v_code !~ '^[A-Z0-9]{4,32}$' then
    raise exception 'company invite code is invalid';
  end if;

  select * into inv
  from public.staff_invites
  where code = v_code
  for update;

  if not found then
    raise exception 'company invite code is invalid';
  end if;

  if inv.status = 'accepted' then
    raise exception 'company invite has already been used';
  elsif inv.status = 'revoked' then
    raise exception 'company invite has been revoked';
  elsif inv.status = 'expired' or inv.expires_at <= now() then
    update public.staff_invites
       set status = 'expired'
     where id = inv.id and status = 'pending';
    raise exception 'company invite has expired';
  elsif inv.status <> 'pending' then
    raise exception 'company invite is no longer active';
  end if;

  select * into b
  from public.businesses
  where id = inv.business_id;

  if not found then
    raise exception 'business unavailable';
  end if;

  v_email := lower(btrim(coalesce(auth.jwt()->>'email', '')));
  if nullif(btrim(coalesce(inv.email, '')), '') is not null
     and lower(btrim(inv.email)) <> v_email then
    raise exception 'company invite is restricted to another email';
  end if;

  if exists (
    select 1 from public.staff
    where business_id = inv.business_id and user_id = auth.uid()
  ) then
    raise exception 'you are already on this team';
  end if;

  insert into public.staff (business_id, user_id, role, full_name)
  values (inv.business_id, auth.uid(), inv.role, coalesce(auth.jwt()->>'email', 'Team member'));

  update public.staff_invites
     set status = 'accepted',
         accepted_at = now(),
         accepted_user_id = auth.uid()
   where id = inv.id and status = 'pending';

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (inv.business_id, auth.uid(), 'INVITE_ACCEPTED', 'staff_invites', inv.id,
          jsonb_build_object('role', inv.role, 'accepted_user_id', auth.uid()));

  return row_to_json(b);
end;
$$;

revoke execute on function public.accept_invite(text) from public, anon;
grant execute on function public.accept_invite(text) to authenticated;
