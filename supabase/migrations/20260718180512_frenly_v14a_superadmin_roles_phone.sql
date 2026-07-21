-- ============================================================================
-- v14a: super admin (read-all / write-platform-only), role unification, phone norm
-- ============================================================================

-- ---------- 1. SUPER ADMIN ----------
create table if not exists public.super_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  note       text,
  created_at timestamptz not null default now()
);
alter table public.super_admins enable row level security;

create or replace function app.is_super_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.super_admins sa where sa.user_id = auth.uid());
$$;
revoke all on function app.is_super_admin() from public, anon;
grant execute on function app.is_super_admin() to authenticated;

-- super_admins is readable only BY super admins; no INSERT/UPDATE/DELETE policy
-- exists at all, so the table is unwritable through the API by anyone. It can only
-- be changed with the service role / direct SQL. That is deliberate: a compromised
-- owner session must never be able to promote itself.
drop policy if exists super_admins_select on public.super_admins;
create policy super_admins_select on public.super_admins
  for select to authenticated using (app.is_super_admin());

-- seed: owner-confirmed 2026-07-18
insert into public.super_admins (user_id, email, note)
select id, email, 'platform super admin (owner-confirmed 2026-07-18)'
from auth.users where email = 'leechuanseng.biz@gmail.com'
on conflict (user_id) do nothing;

-- ---------- 2. SUPER ADMIN READ-ALL POLICIES ----------
-- One SELECT-only permissive policy per tenant table. Permissive policies OR
-- together, so this ADDS read. It deliberately grants no INSERT/UPDATE/DELETE:
-- the pre-existing FOR ALL policies keep their is_salon_member WITH CHECK, which
-- is false for a super admin who is not staff. => read-all, write-nothing.
do $$
declare t text;
begin
  for t in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attname = 'business_id' and a.attnum > 0
    where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
  loop
    execute format('drop policy if exists %I on public.%I', t || '_sa_read', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (app.is_super_admin())',
      t || '_sa_read', t);
  end loop;
end $$;

-- businesses keys on id, not business_id
drop policy if exists businesses_sa_read on public.businesses;
create policy businesses_sa_read on public.businesses
  for select to authenticated using (app.is_super_admin());

-- child tables that inherit tenancy through a parent
drop policy if exists appointment_services_sa_read on public.appointment_services;
create policy appointment_services_sa_read on public.appointment_services
  for select to authenticated using (app.is_super_admin());

drop policy if exists bundle_items_sa_read on public.bundle_items;
create policy bundle_items_sa_read on public.bundle_items
  for select to authenticated using (app.is_super_admin());

drop policy if exists service_products_sa_read on public.service_products;
create policy service_products_sa_read on public.service_products
  for select to authenticated using (app.is_super_admin());

drop policy if exists stock_batches_sa_read on public.stock_batches;
create policy stock_batches_sa_read on public.stock_batches
  for select to authenticated using (app.is_super_admin());

-- ---------- 3. ROLE VOCABULARY UNIFICATION ----------
-- BUG BEING FIXED: staff_invites allowed role IN (manager, receptionist, bookkeeper,
-- staff) but staff allowed role IN (owner, manager, stylist, frontdesk). accept_invite
-- inserts the invite role straight into staff, so every invite except 'manager' threw
-- a check violation. Employee onboarding was broken for 3 of 4 roles.
-- Canonical set (industry-agnostic; 'stylist' was salon-only and dies here):
--   owner | manager | staff | frontdesk | bookkeeper
alter table public.staff drop constraint if exists staff_role_check;
update public.staff set role = 'staff'     where role = 'stylist';
update public.staff set role = 'frontdesk' where role = 'receptionist';
alter table public.staff add constraint staff_role_check
  check (role in ('owner','manager','staff','frontdesk','bookkeeper'));

alter table public.staff_invites drop constraint if exists staff_invites_role_check;
update public.staff_invites set role = 'staff'     where role = 'stylist';
update public.staff_invites set role = 'frontdesk' where role = 'receptionist';
-- 'owner' is intentionally NOT invitable: ownership transfer must be explicit.
alter table public.staff_invites add constraint staff_invites_role_check
  check (role in ('manager','staff','frontdesk','bookkeeper'));

create or replace function app.role_perms(p_role text)
returns text[] language sql immutable as $$
  select case p_role
    when 'owner'      then array['view_sales','create_sales','refund_sales',
                                 'reclassify_sales','view_finance','manage_sale_policy',
                                 'manage_team','manage_billing']
    when 'manager'    then array['view_sales','create_sales','refund_sales','view_finance']
    when 'staff'      then array['view_sales','create_sales']
    when 'frontdesk'  then array['view_sales','create_sales']
    when 'bookkeeper' then array['view_sales','view_finance']
    -- legacy tolerance: any row that escaped the backfill still resolves sanely
    when 'stylist'      then array['view_sales','create_sales']
    when 'receptionist' then array['view_sales','create_sales']
    else array[]::text[]
  end
$$;

-- ---------- 4. PHONE NORMALISATION (Singapore) ----------
-- Canonical form is the bare 8-digit local number, because that is what a cashier
-- types. Accepts 81863833 / +6581863833 / +65 8186 3833 / 65-8186-3833 and folds
-- them all to 81863833. Anything that is not a valid SG 8-digit number -> NULL.
-- SG prefixes: 8,9 = mobile; 6 = fixed line; 3 = VoIP.
create or replace function app.norm_phone(p text)
returns text language sql immutable as $$
  select case
           when length(d) = 8  and left(d,1) in ('3','6','8','9') then d
           when length(d) = 10 and left(d,2) = '65'
                and substr(d,3,1) in ('3','6','8','9')            then substr(d,3,8)
           when length(d) = 11 and left(d,3) = '065'
                and substr(d,4,1) in ('3','6','8','9')            then substr(d,4,8)
           else null
         end
  from (select regexp_replace(coalesce(p,''), '[^0-9]', '', 'g') as d) _;
$$;

alter table public.clients
  add column if not exists phone_norm text
  generated always as (app.norm_phone(phone)) stored;

-- One customer per phone per business. Partial: a client with no phone is still legal
-- (walk-ins, CSV imports without numbers) and many of them can coexist.
create unique index if not exists clients_business_phone_norm_uidx
  on public.clients (business_id, phone_norm) where phone_norm is not null;

comment on column public.clients.phone_norm is
  'Generated: bare 8-digit SG number derived from phone. The loyalty lookup key.';
comment on table public.super_admins is
  'Platform super admins. Read-all across tenants; cannot write tenant data. API-unwritable by design.';