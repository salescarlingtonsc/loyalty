-- FRENLY v7 — team invites (5 roles, code-based), booking policy + brand colour.

-- 1) Brand + policy on the business (Flowesce: Settings > Policies / Brand)
alter table public.businesses
  add column booking_policy text,
  add column brand_color text not null default '#FF6B5E';

-- portal payload now includes them
create or replace function public.get_business_public(p_slug text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', b.id, 'name', b.name, 'industry', b.industry, 'currency', b.currency,
    'booking_policy', b.booking_policy, 'brand_color', b.brand_color,
    'services', coalesce((select json_agg(json_build_object(
        'id', s.id, 'name', s.name, 'price_cents', s.price_cents,
        'duration_min', s.duration_min))
      from services s where s.business_id = b.id and s.active), '[]'::json))
  from businesses b where b.slug = p_slug;
$$;

-- 2) Team invites: owner creates a code, teammate signs up and enters it
create table public.staff_invites (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  email        text,
  role         text not null check (role in ('manager','receptionist','bookkeeper','staff')),
  code         text not null unique,
  status       text not null default 'pending' check (status in ('pending','accepted','revoked')),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '14 days'
);
create index on public.staff_invites (business_id, status);
alter table public.staff_invites enable row level security;
create policy invites_select on public.staff_invites for select to authenticated
  using (app.is_salon_member(business_id));
create policy invites_insert on public.staff_invites for insert to authenticated
  with check (app.is_salon_owner(business_id));
create policy invites_update on public.staff_invites for update to authenticated
  using (app.is_salon_owner(business_id));

create or replace function public.create_invite(p_business uuid, p_role text, p_email text)
returns json language plpgsql security definer set search_path = public as $$
declare v_code text; inv staff_invites;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner role required'; end if;
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text),1,8));
    exit when not exists (select 1 from staff_invites where code = v_code);
  end loop;
  insert into staff_invites (business_id, role, email, code)
  values (p_business, p_role, p_email, v_code) returning * into inv;
  return row_to_json(inv);
end $$;
revoke execute on function public.create_invite(uuid, text, text) from public, anon;
grant execute on function public.create_invite(uuid, text, text) to authenticated;

create or replace function public.accept_invite(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare inv record; b record;
begin
  if auth.uid() is null then raise exception 'sign in required'; end if;
  select * into inv from staff_invites
    where code = upper(trim(p_code)) and status = 'pending' and expires_at > now();
  if not found then raise exception 'invite code invalid, used, or expired'; end if;
  if exists (select 1 from staff where business_id = inv.business_id and user_id = auth.uid()) then
    raise exception 'you are already on this team';
  end if;
  insert into staff (business_id, user_id, role, full_name)
  values (inv.business_id, auth.uid(), inv.role, coalesce(auth.jwt()->>'email','Team member'));
  update staff_invites set status = 'accepted' where id = inv.id;
  insert into audit_log (business_id, actor, action, entity, entity_id, detail)
  values (inv.business_id, auth.uid(), 'INVITE_ACCEPTED', 'staff_invites', inv.id,
          json_build_object('role', inv.role)::jsonb);
  select * into b from businesses where id = inv.business_id;
  return row_to_json(b);
end $$;
revoke execute on function public.accept_invite(text) from public, anon;
grant execute on function public.accept_invite(text) to authenticated;