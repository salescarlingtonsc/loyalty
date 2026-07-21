-- ============================================================================
-- v14b: seat billing ($25 firm + $10/employee SGD) + per-staff module permissions
-- ============================================================================

-- ---------- 1. SUBSCRIPTIONS / SEATS ----------
create table if not exists public.subscriptions (
  business_id          uuid primary key references public.businesses(id) on delete cascade,
  status               text not null default 'trialing'
                         check (status in ('trialing','active','past_due','cancelled')),
  currency             text not null default 'SGD',
  base_price_cents     integer not null default 2500,   -- $25/mo, covers 1 user
  included_seats       integer not null default 1,
  per_seat_price_cents integer not null default 1000,   -- $10/mo per extra employee
  trial_ends_at        timestamptz not null default now() + interval '14 days',
  current_period_start timestamptz not null default now(),
  current_period_end   timestamptz not null default now() + interval '1 month',
  note                 text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint subscriptions_prices_sane check (
    base_price_cents >= 0 and per_seat_price_cents >= 0 and included_seats >= 0)
);
alter table public.subscriptions enable row level security;

-- A SEAT is a staff row that can actually log in (user_id not null) and is active.
-- v11a rota-only staff (user_id IS NULL — a cleaner on the roster with no account)
-- consume no login and are therefore NOT billable. Deactivating a staff member
-- releases their seat immediately.
create or replace function app.billable_seats(p_business uuid)
returns integer language sql stable security definer set search_path = public as $$
  select count(*)::integer from public.staff s
  where s.business_id = p_business and s.active and s.user_id is not null;
$$;

create or replace view public.v_business_billing with (security_invoker = true) as
select
  b.id   as business_id,
  b.name as business_name,
  coalesce(sub.status,               'trialing') as status,
  coalesce(sub.currency,             'SGD')      as currency,
  coalesce(sub.base_price_cents,     2500)       as base_price_cents,
  coalesce(sub.included_seats,       1)          as included_seats,
  coalesce(sub.per_seat_price_cents, 1000)       as per_seat_price_cents,
  app.billable_seats(b.id)                       as billable_seats,
  greatest(app.billable_seats(b.id) - coalesce(sub.included_seats,1), 0) as extra_seats,
  coalesce(sub.base_price_cents, 2500)
    + greatest(app.billable_seats(b.id) - coalesce(sub.included_seats,1), 0)
      * coalesce(sub.per_seat_price_cents, 1000)  as monthly_total_cents,
  sub.trial_ends_at,
  sub.current_period_start,
  sub.current_period_end
from public.businesses b
left join public.subscriptions sub on sub.business_id = b.id;

-- Owners/members READ their own subscription. Only a super admin can WRITE it —
-- a firm must never be able to set its own price. This is the "write platform only"
-- half of the super-admin grant.
drop policy if exists subscriptions_select on public.subscriptions;
create policy subscriptions_select on public.subscriptions
  for select to authenticated
  using (app.is_salon_member(business_id) or app.is_super_admin());

drop policy if exists subscriptions_sa_write on public.subscriptions;
create policy subscriptions_sa_write on public.subscriptions
  for all to authenticated
  using (app.is_super_admin()) with check (app.is_super_admin());

-- backfill existing tenants
insert into public.subscriptions (business_id)
select id from public.businesses on conflict (business_id) do nothing;

-- ---------- 2. MODULE PERMISSIONS ----------
-- staff.modules NULL  => inherit (sees everything the firm has enabled)  [default]
-- staff.modules ARRAY => explicit allowlist. Owners always bypass.
alter table public.staff add column if not exists modules text[];

create table if not exists public.module_templates (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name        text not null,
  modules     text[] not null default '{}',
  created_at  timestamptz not null default now(),
  unique (business_id, name)
);
alter table public.module_templates enable row level security;

drop policy if exists module_templates_select on public.module_templates;
create policy module_templates_select on public.module_templates
  for select to authenticated using (app.is_salon_member(business_id));
drop policy if exists module_templates_write on public.module_templates;
create policy module_templates_write on public.module_templates
  for all to authenticated
  using (app.is_salon_owner(business_id)) with check (app.is_salon_owner(business_id));
drop policy if exists module_templates_sa_read on public.module_templates;
create policy module_templates_sa_read on public.module_templates
  for select to authenticated using (app.is_super_admin());

-- Deliberately does NOT test businesses.enabled_modules: enabled_modules is a
-- packaging/nav concept, and switching a module off in Settings must never make the
-- underlying rows unreadable (that would strand data). Firm-level gating happens in
-- the nav; person-level gating happens here.
create or replace function app.can_module(p_business uuid, p_module text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.staff s
    where s.business_id = p_business
      and s.user_id = auth.uid()
      and s.active
      and (s.role = 'owner' or s.modules is null or p_module = any(s.modules))
  );
$$;
revoke all on function app.can_module(uuid, text) from public, anon;
grant execute on function app.can_module(uuid, text) to authenticated;

-- Effective module list for the signed-in user in one business.
create or replace function app.staff_modules(p_business uuid)
returns text[] language sql stable security definer set search_path = public as $$
  select case
           when s.role = 'owner'  then b.enabled_modules
           when s.modules is null then b.enabled_modules
           else array(select unnest(b.enabled_modules) intersect select unnest(s.modules))
         end
  from public.staff s
  join public.businesses b on b.id = s.business_id
  where s.business_id = p_business and s.user_id = auth.uid() and s.active
  limit 1;
$$;

create or replace function public.get_my_modules(p_business uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'modules', coalesce(to_json(app.staff_modules(p_business)), '[]'::json),
    'role',    (select s.role from public.staff s
                 where s.business_id = p_business and s.user_id = auth.uid() and s.active limit 1),
    'is_super_admin', app.is_super_admin()
  );
$$;
revoke all on function public.get_my_modules(uuid) from public, anon;
grant execute on function public.get_my_modules(uuid) to authenticated;

-- ---------- 3. ENFORCE MODULES IN RLS (not just the UI) ----------
-- Module scoping is a real DB boundary for the person-scoped tables, so an
-- inventory-only employee cannot simply call the REST API and read the customer
-- list. can_module() already implies staff membership + active, so it strictly
-- subsumes the is_salon_member() test it replaces.
drop policy if exists clients_all on public.clients;
create policy clients_all on public.clients for all to authenticated
  using (app.can_module(business_id, 'clients'))
  with check (app.can_module(business_id, 'clients'));

drop policy if exists appointments_all on public.appointments;
create policy appointments_all on public.appointments for all to authenticated
  using (app.can_module(business_id, 'appointments'))
  with check (app.can_module(business_id, 'appointments'));

drop policy if exists products_all on public.products;
create policy products_all on public.products for all to authenticated
  using (app.can_module(business_id, 'inventory'))
  with check (app.can_module(business_id, 'inventory'));

drop policy if exists stock_batches_all on public.stock_batches;
create policy stock_batches_all on public.stock_batches for all to authenticated
  using (exists (select 1 from public.products p
                 where p.id = stock_batches.product_id and app.can_module(p.business_id,'inventory')))
  with check (exists (select 1 from public.products p
                 where p.id = stock_batches.product_id and app.can_module(p.business_id,'inventory')));

-- ---------- 4. TEAM / MODULE RPCs ----------
create or replace function public.set_staff_modules(p_staff uuid, p_modules text[])
returns json language plpgsql security definer set search_path = public as $$
declare v_biz uuid; s public.staff;
begin
  select business_id into v_biz from public.staff where id = p_staff;
  if v_biz is null then raise exception 'staff not found'; end if;
  if not app.is_salon_owner(v_biz) then raise exception 'owner role required'; end if;
  if exists (select 1 from public.staff where id = p_staff and role = 'owner') then
    raise exception 'the owner always has full access and cannot be module-restricted';
  end if;
  update public.staff set modules = p_modules where id = p_staff returning * into s;
  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (v_biz, auth.uid(), 'STAFF_MODULES_SET', 'staff', p_staff,
          json_build_object('modules', p_modules)::jsonb);
  return row_to_json(s);
end $$;
revoke all on function public.set_staff_modules(uuid, text[]) from public, anon;
grant execute on function public.set_staff_modules(uuid, text[]) to authenticated;

create or replace function public.save_module_template(p_business uuid, p_name text, p_modules text[])
returns json language plpgsql security definer set search_path = public as $$
declare t public.module_templates;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner role required'; end if;
  if p_name is null or length(trim(p_name)) < 1 then raise exception 'template name required'; end if;
  insert into public.module_templates (business_id, name, modules)
  values (p_business, trim(p_name), coalesce(p_modules, '{}'))
  on conflict (business_id, name) do update set modules = excluded.modules
  returning * into t;
  return row_to_json(t);
end $$;
revoke all on function public.save_module_template(uuid, text, text[]) from public, anon;
grant execute on function public.save_module_template(uuid, text, text[]) to authenticated;

create or replace function public.apply_module_template(p_staff uuid, p_template uuid)
returns json language plpgsql security definer set search_path = public as $$
declare t public.module_templates; v_biz uuid;
begin
  select business_id into v_biz from public.staff where id = p_staff;
  if v_biz is null then raise exception 'staff not found'; end if;
  if not app.is_salon_owner(v_biz) then raise exception 'owner role required'; end if;
  select * into t from public.module_templates where id = p_template and business_id = v_biz;
  if not found then raise exception 'template not found for this business'; end if;
  return public.set_staff_modules(p_staff, t.modules);
end $$;
revoke all on function public.apply_module_template(uuid, uuid) from public, anon;
grant execute on function public.apply_module_template(uuid, uuid) to authenticated;

comment on view public.v_business_billing is
  'Seat billing: base $25 SGD/mo covers 1 login; each extra active login +$10/mo. No payment rail wired (Stripe deferred).';
comment on column public.staff.modules is
  'NULL = inherit all firm-enabled modules. Non-null = explicit allowlist. Owners bypass.';