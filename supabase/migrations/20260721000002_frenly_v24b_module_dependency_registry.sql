-- FRENLY v24b - MODULE DEPENDENCY REGISTRY
-- Local review candidate. Do not apply until the phase release gate is accepted.
--
-- Owners remain free to choose modules, but a selected workflow cannot be saved without
-- the modules it depends on. The database resolves the dependency closure for every write,
-- including legacy direct updates; the owner RPC also reports which dependencies were added.

begin;

create table if not exists public.module_registry (
  module_key text primary key check (module_key ~ '^[a-z][a-z0-9_]*$'),
  label text not null check (length(btrim(label)) > 0),
  requires_modules text[] not null default '{}',
  recommended_modules text[] not null default '{}',
  sort_order integer not null,
  updated_at timestamptz not null default now(),
  constraint module_registry_no_self_requirement
    check (not (module_key = any(requires_modules)))
);

insert into public.module_registry
  (module_key, label, requires_modules, recommended_modules, sort_order)
values
  ('dashboard',    'Dashboard',         '{}',                              '{}',                 10),
  ('till',         'Till',              '{clients,sales}',                 '{loyalty}',          20),
  ('clients',      'Customers',         '{}',                              '{loyalty}',          30),
  ('appointments', 'Appointments',      '{clients,services}',              '{branches}',         40),
  ('sales',        'Sales',             '{}',                              '{clients,inventory}',50),
  ('services',     'Services',          '{}',                              '{}',                 60),
  ('bookings',     'Bookings',          '{appointments,clients,services}', '{waitlist}',         70),
  ('waitlist',     'Waitlist',          '{clients,services}',              '{appointments}',     80),
  ('inventory',    'Inventory',         '{}',                              '{sales}',             90),
  ('packages',     'Packages',          '{clients,services,sales}',        '{}',                100),
  ('branches',     'Branches',          '{}',                              '{}',                110),
  ('loyalty',      'Loyalty',           '{clients,sales}',                 '{retention}',        120),
  ('retention',    'Retention',         '{clients,sales}',                 '{loyalty}',          130),
  ('referrals',    'Referrals',         '{clients,sales}',                 '{loyalty}',          140),
  ('memberships',  'Memberships',       '{clients,sales}',                 '{}',                150),
  ('giftcards',    'Gift cards',        '{clients,sales}',                 '{}',                160),
  ('reports',      'Reports',           '{sales}',                         '{}',                170),
  ('staffperf',    'Staff performance', '{sales}',                         '{}',                180),
  ('dailyreport',  'Daily report',      '{sales}',                         '{}',                190),
  ('pnl',          'P&L',               '{sales,expenses}',                '{inventory}',        200),
  ('expenses',     'Expenses',          '{}',                              '{}',                210)
on conflict (module_key) do update set
  label = excluded.label,
  requires_modules = excluded.requires_modules,
  recommended_modules = excluded.recommended_modules,
  sort_order = excluded.sort_order,
  updated_at = now();

alter table public.module_registry enable row level security;
drop policy if exists module_registry_read on public.module_registry;
create policy module_registry_read on public.module_registry
  for select to authenticated using (true);
revoke all privileges on table public.module_registry from public, anon, authenticated;
grant select on table public.module_registry to authenticated;

create or replace function app.resolve_module_dependencies(p_modules text[])
returns text[]
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_unknown text[];
  v_resolved text[];
begin
  select array_agg(distinct requested order by requested)
    into v_unknown
    from unnest(coalesce(p_modules, '{}'::text[])) requested
    left join public.module_registry mr on mr.module_key = requested
   where mr.module_key is null;
  if coalesce(cardinality(v_unknown), 0) > 0 then
    raise exception 'unknown modules: %', array_to_string(v_unknown, ', ')
      using errcode = '22023';
  end if;

  with recursive closure(module_key) as (
    select unnest(array_append(coalesce(p_modules, '{}'::text[]), 'dashboard'))
    union
    select dependency
      from closure c
      join public.module_registry mr on mr.module_key = c.module_key
      cross join lateral unnest(mr.requires_modules) dependency
  )
  select array_agg(c.module_key order by mr.sort_order, c.module_key)
    into v_resolved
    from closure c
    join public.module_registry mr using (module_key);

  return coalesce(v_resolved, array['dashboard']::text[]);
end $$;

revoke execute on function app.resolve_module_dependencies(text[])
  from public, anon, authenticated;

create or replace function app.business_modules_dependency_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  new.enabled_modules := app.resolve_module_dependencies(new.enabled_modules);
  return new;
end $$;

revoke execute on function app.business_modules_dependency_guard()
  from public, anon, authenticated;

drop trigger if exists trg_business_modules_dependency_guard on public.businesses;
create trigger trg_business_modules_dependency_guard
  before insert or update of enabled_modules on public.businesses
  for each row execute function app.business_modules_dependency_guard();

create or replace function public.set_business_modules(p_business uuid, p_modules text[])
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_requested text[] := coalesce(p_modules, '{}'::text[]);
  v_resolved text[];
  v_added text[];
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'only the business owner can change modules' using errcode = '42501';
  end if;

  v_resolved := app.resolve_module_dependencies(v_requested);
  update public.businesses
     set enabled_modules = v_resolved
   where id = p_business;
  if not found then raise exception 'business not found'; end if;

  select coalesce(array_agg(module_key order by module_key), '{}'::text[])
    into v_added
    from (
      select unnest(v_resolved) module_key
      except
      select unnest(v_requested)
    ) added;

  return json_build_object(
    'modules', v_resolved,
    'added_dependencies', v_added
  );
end $$;

revoke all on function public.set_business_modules(uuid, text[]) from public, anon;
grant execute on function public.set_business_modules(uuid, text[]) to authenticated;

commit;
