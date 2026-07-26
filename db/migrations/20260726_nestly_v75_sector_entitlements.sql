-- NESTLY v75 - PLATFORM SECTOR ENTITLEMENTS + CONSULTANT DIRECTORY
-- Additive local review candidate. Do not apply until the independent release gate accepts it.

begin;

-- Platform consultants are Frenly/Nestly operators, never tenant staff.
create table public.platform_consultants (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete restrict,
  display_name text not null check (length(btrim(display_name)) between 2 and 120),
  tier text not null check (tier in ('senior', 'junior')),
  employment_started_on date not null,
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.sector_profiles (
  sector_key text primary key check (sector_key ~ '^[a-z][a-z0-9_]*$'),
  label text not null check (length(btrim(label)) between 2 and 80),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.sector_bundle_versions (
  id uuid primary key default gen_random_uuid(),
  sector_key text not null references public.sector_profiles(sector_key) on delete restrict,
  version integer not null check (version > 0),
  label text not null check (length(btrim(label)) between 2 and 120),
  status text not null default 'draft' check (status in ('draft', 'published', 'retired')),
  modules text[] not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  published_at timestamptz,
  retired_at timestamptz,
  unique (sector_key, version),
  constraint sector_bundle_versions_status_time_check check (
    (status = 'draft' and published_at is null and retired_at is null)
    or (status = 'published' and published_at is not null and retired_at is null)
    or (status = 'retired' and published_at is not null and retired_at is not null)
  )
);
create unique index sector_bundle_versions_one_published_idx
  on public.sector_bundle_versions (sector_key) where status = 'published';

create table public.business_sector_override_versions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  version integer not null check (version > 0),
  add_modules text[] not null default '{}',
  remove_modules text[] not null default '{}',
  reason text not null check (length(btrim(reason)) between 3 and 1000),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (business_id, version),
  unique (id, business_id),
  constraint business_sector_override_disjoint_check check (
    not (add_modules && remove_modules)
  )
);

create table public.business_sector_assignments (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  bundle_version_id uuid not null references public.sector_bundle_versions(id) on delete restrict,
  override_version_id uuid,
  version bigint not null default 1 check (version > 0),
  assigned_by uuid references auth.users(id) on delete set null,
  assigned_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint business_sector_assignment_override_fk
    foreign key (override_version_id, business_id)
    references public.business_sector_override_versions(id, business_id) on delete restrict
);

create index sector_bundle_versions_sector_status_idx
  on public.sector_bundle_versions (sector_key, status, version desc);
create index business_sector_overrides_business_idx
  on public.business_sector_override_versions (business_id, version desc);

alter table public.platform_consultants enable row level security;
alter table public.sector_profiles enable row level security;
alter table public.sector_bundle_versions enable row level security;
alter table public.business_sector_override_versions enable row level security;
alter table public.business_sector_assignments enable row level security;

revoke all privileges on table public.platform_consultants from public, anon, authenticated;
revoke all privileges on table public.sector_profiles from public, anon, authenticated;
revoke all privileges on table public.sector_bundle_versions from public, anon, authenticated;
revoke all privileges on table public.business_sector_override_versions from public, anon, authenticated;
revoke all privileges on table public.business_sector_assignments from public, anon, authenticated;

create or replace function app.is_platform_operator_v75()
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select app.is_super_admin() or exists (
    select 1
      from public.platform_consultants consultant
     where consultant.user_id = auth.uid()
       and consultant.active
  )
$$;
revoke all on function app.is_platform_operator_v75() from public, anon, authenticated;

create or replace function app.resolve_sector_entitlement_v75(
  p_bundle_version uuid,
  p_add_modules text[] default '{}',
  p_remove_modules text[] default '{}'
)
returns text[]
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_base text[];
  v_requested text[];
  v_unknown text[];
begin
  select bundle.modules into v_base
    from public.sector_bundle_versions bundle
   where bundle.id = p_bundle_version;
  if not found then
    raise exception 'sector bundle version was not found' using errcode = '22023';
  end if;
  if coalesce(p_add_modules, '{}'::text[]) && coalesce(p_remove_modules, '{}'::text[]) then
    raise exception 'a module cannot be both added and removed' using errcode = '22023';
  end if;
  select array_agg(module_key order by module_key) into v_unknown
    from (
      select distinct requested module_key
        from unnest(
          coalesce(p_add_modules, '{}'::text[])
          || coalesce(p_remove_modules, '{}'::text[])
        ) requested
      except
      select registry.module_key from public.module_registry registry
    ) unknown;
  if coalesce(cardinality(v_unknown), 0) > 0 then
    raise exception 'unknown modules: %', array_to_string(v_unknown, ', ')
      using errcode = '22023';
  end if;
  select coalesce(array_agg(module_key order by module_key), '{}'::text[])
    into v_requested
    from (
      select unnest(v_base) module_key
      except
      select unnest(coalesce(p_remove_modules, '{}'::text[]))
      union
      select unnest(coalesce(p_add_modules, '{}'::text[]))
    ) requested;
  return app.resolve_module_dependencies(v_requested);
end
$$;
revoke all on function app.resolve_sector_entitlement_v75(uuid,text[],text[])
  from public, anon, authenticated;

create or replace function app.business_sector_modules_guard_v75()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if (
       new.enabled_modules is distinct from old.enabled_modules
       or new.industry is distinct from old.industry
     )
     and exists (
       select 1 from public.business_sector_assignments assignment
        where assignment.business_id = new.id
     )
     and nullif(current_setting('app.sector_entitlement_sync', true), '') is distinct from new.id::text
  then
    raise exception 'business modules are fixed by the assigned sector entitlement'
      using errcode = '42501';
  end if;
  return new;
end
$$;
revoke all on function app.business_sector_modules_guard_v75()
  from public, anon, authenticated;

create or replace function app.v75_immutable_guard()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $$
begin
  raise exception '% is immutable', tg_table_name using errcode = 'restrict_violation';
end
$$;
revoke all on function app.v75_immutable_guard() from public, anon, authenticated;

create trigger business_sector_override_versions_immutable_guard
  before update or delete on public.business_sector_override_versions
  for each row execute function app.v75_immutable_guard();

-- Canonical profiles mirror the seven shipped onboarding sectors. Stored modules
-- are dependency-closed by the database, not trusted from the browser constant.
insert into public.sector_profiles(sector_key, label) values
  ('fnb', 'F&B / Café'),
  ('salon', 'Hair Salon'),
  ('facial', 'Facial / Spa'),
  ('massage', 'Massage'),
  ('fitness', 'Fitness'),
  ('retail', 'Retail'),
  ('other', 'Other');

with seed(sector_key, label, modules) as (
  values
    ('fnb', 'F&B / Café core',
      array['dashboard','till','clients','sales','bookings','waitlist','inventory',
            'loyalty','retention','referrals','giftcards','reports','staffperf',
            'dailyreport','pnl','expenses']::text[]),
    ('salon', 'Hair Salon core',
      array['dashboard','till','clients','appointments','sales','services','bookings',
            'waitlist','inventory','packages','loyalty','retention','referrals',
            'memberships','giftcards','reports','staffperf','dailyreport','pnl','expenses']::text[]),
    ('facial', 'Facial / Spa core',
      array['dashboard','till','clients','appointments','sales','services','bookings',
            'waitlist','inventory','packages','loyalty','retention','referrals',
            'memberships','giftcards','reports','staffperf','dailyreport','pnl','expenses']::text[]),
    ('massage', 'Massage core',
      array['dashboard','till','clients','appointments','sales','services','bookings',
            'waitlist','inventory','packages','loyalty','retention','referrals',
            'memberships','giftcards','reports','staffperf','dailyreport','pnl','expenses']::text[]),
    ('fitness', 'Fitness core',
      array['dashboard','till','clients','appointments','sales','services','bookings',
            'waitlist','inventory','packages','loyalty','retention','referrals',
            'memberships','giftcards','reports','staffperf','dailyreport','pnl','expenses']::text[]),
    ('retail', 'Retail core',
      array['dashboard','till','clients','sales','inventory','packages','loyalty',
            'retention','referrals','giftcards','reports','staffperf','dailyreport',
            'pnl','expenses']::text[]),
    ('other', 'Other core',
      array['dashboard','till','clients','appointments','sales','services','bookings',
            'waitlist','inventory','packages','loyalty','retention','referrals',
            'memberships','giftcards','reports','staffperf','dailyreport','pnl','expenses']::text[])
)
insert into public.sector_bundle_versions(
  sector_key, version, label, status, modules, published_at
)
select sector_key, 1, label, 'published',
       app.resolve_module_dependencies(modules), now()
  from seed;

-- Existing firms receive an explicit profile plus a versioned compatibility
-- override only when necessary. This preserves every current enabled module.
with resolved as (
  select business.id business_id, business.enabled_modules,
         bundle.id bundle_version_id, bundle.modules bundle_modules
    from public.businesses business
    join public.sector_bundle_versions bundle
      on bundle.sector_key = case
           when business.industry in ('fnb','salon','facial','massage','fitness','retail','other')
             then business.industry
           else 'other'
         end
     and bundle.status = 'published'
), delta as (
  select resolved.*,
         array(
           select unnest(resolved.enabled_modules)
           except select unnest(resolved.bundle_modules)
           order by 1
         ) add_modules,
         array(
           select unnest(resolved.bundle_modules)
           except select unnest(resolved.enabled_modules)
           order by 1
         ) remove_modules
    from resolved
)
insert into public.business_sector_override_versions(
  business_id, version, add_modules, remove_modules, reason
)
select business_id, 1, add_modules, remove_modules,
       'v75 compatibility snapshot preserving pre-entitlement enabled modules'
  from delta
 where cardinality(add_modules) > 0 or cardinality(remove_modules) > 0;

insert into public.business_sector_assignments(
  business_id, bundle_version_id, override_version_id, version
)
select business.id, bundle.id, override_row.id, 1
  from public.businesses business
  join public.sector_bundle_versions bundle
    on bundle.sector_key = case
         when business.industry in ('fnb','salon','facial','massage','fitness','retail','other')
           then business.industry
         else 'other'
       end
   and bundle.status = 'published'
  left join public.business_sector_override_versions override_row
    on override_row.business_id = business.id and override_row.version = 1;

do $v75_backfill_gate$
declare v_mismatch uuid;
begin
  select business.id into v_mismatch
    from public.businesses business
    join public.business_sector_assignments assignment
      on assignment.business_id = business.id
    left join public.business_sector_override_versions override_row
      on override_row.id = assignment.override_version_id
   where business.enabled_modules is distinct from app.resolve_sector_entitlement_v75(
     assignment.bundle_version_id,
     coalesce(override_row.add_modules, '{}'::text[]),
     coalesce(override_row.remove_modules, '{}'::text[])
   )
   limit 1;
  if v_mismatch is not null then
    raise exception 'v75 compatibility backfill changed effective modules for business %', v_mismatch;
  end if;
end
$v75_backfill_gate$;

create trigger businesses_sector_modules_guard_v75
  before update of enabled_modules, industry on public.businesses
  for each row execute function app.business_sector_modules_guard_v75();

create or replace function public.platform_list_consultants_v75()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if not app.is_platform_operator_v75() then
    raise exception 'platform operator access is required' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'consultants', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', consultant.id,
        'user_id', consultant.user_id,
        'display_name', consultant.display_name,
        'tier', consultant.tier,
        'employment_started_on', consultant.employment_started_on,
        'active', consultant.active
      ) order by consultant.active desc, consultant.display_name)
        from public.platform_consultants consultant
    ), '[]'::jsonb)
  );
end
$$;

create or replace function public.platform_upsert_consultant_v75(
  p_consultant uuid,
  p_user uuid,
  p_display_name text,
  p_tier text,
  p_employment_started_on date,
  p_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_actor uuid := auth.uid(); v_row public.platform_consultants%rowtype;
begin
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode = '42501';
  end if;
  if p_consultant is null then
    insert into public.platform_consultants(
      user_id, display_name, tier, employment_started_on, active, created_by
    ) values (
      p_user, btrim(p_display_name), p_tier, p_employment_started_on,
      coalesce(p_active, true), v_actor
    ) returning * into v_row;
  else
    update public.platform_consultants
       set user_id = p_user,
           display_name = btrim(p_display_name),
           tier = p_tier,
           employment_started_on = p_employment_started_on,
           active = coalesce(p_active, active),
           updated_at = now()
     where id = p_consultant
     returning * into v_row;
    if not found then raise exception 'platform consultant was not found' using errcode = '22023'; end if;
  end if;
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (null, v_actor, 'PLATFORM_CONSULTANT_UPSERT_V75', 'platform_consultants',
          v_row.id, to_jsonb(v_row) - 'user_id');
  return jsonb_build_object('consultant', to_jsonb(v_row));
end
$$;

create or replace function public.platform_list_sector_entitlements_v75()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'profiles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'sector_key', profile.sector_key, 'label', profile.label, 'active', profile.active,
        'published_version', case when bundle.id is null then null else jsonb_build_object(
          'id', bundle.id, 'version', bundle.version, 'label', bundle.label,
          'modules', to_jsonb(bundle.modules), 'published_at', bundle.published_at
        ) end
      ) order by profile.label)
        from public.sector_profiles profile
        left join public.sector_bundle_versions bundle
          on bundle.sector_key = profile.sector_key and bundle.status = 'published'
    ), '[]'::jsonb),
    'businesses', coalesce((
      select jsonb_agg(jsonb_build_object(
        'business_id', business.id, 'business_name', business.name,
        'industry', business.industry, 'assignment_version', assignment.version,
        'bundle_version_id', bundle.id, 'sector_key', bundle.sector_key,
        'bundle_version', bundle.version, 'override_version_id', override_row.id,
        'effective_modules', to_jsonb(app.resolve_sector_entitlement_v75(
          bundle.id, coalesce(override_row.add_modules, '{}'::text[]),
          coalesce(override_row.remove_modules, '{}'::text[])
        ))
      ) order by business.name)
        from public.business_sector_assignments assignment
        join public.businesses business on business.id = assignment.business_id
        join public.sector_bundle_versions bundle on bundle.id = assignment.bundle_version_id
        left join public.business_sector_override_versions override_row
          on override_row.id = assignment.override_version_id
    ), '[]'::jsonb)
  );
end
$$;

create or replace function public.platform_create_sector_bundle_v75(
  p_sector_key text,
  p_label text,
  p_modules text[],
  p_dry_run boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid(); v_resolved text[]; v_next integer; v_id uuid;
begin
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode = '42501';
  end if;
  perform 1 from public.sector_profiles
   where sector_key = p_sector_key and active for update;
  if not found then raise exception 'active sector profile was not found' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_label, ''))) < 2 then
    raise exception 'bundle label is required' using errcode = '22023';
  end if;
  v_resolved := app.resolve_module_dependencies(coalesce(p_modules, '{}'::text[]));
  select coalesce(max(version), 0) + 1 into v_next
    from public.sector_bundle_versions where sector_key = p_sector_key;
  if not coalesce(p_dry_run, true) then
    insert into public.sector_bundle_versions(
      sector_key, version, label, modules, created_by
    ) values (p_sector_key, v_next, btrim(p_label), v_resolved, v_actor)
    returning id into v_id;
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (null, v_actor, 'SECTOR_BUNDLE_CREATED_V75', 'sector_bundle_versions',
            v_id, jsonb_build_object('sector_key',p_sector_key,'version',v_next,'modules',v_resolved));
  end if;
  return jsonb_build_object(
    'dry_run', coalesce(p_dry_run, true), 'sector_key', p_sector_key,
    'next_version', v_next, 'label', btrim(p_label),
    'requested_modules', to_jsonb(coalesce(p_modules, '{}'::text[])),
    'resolved_modules', to_jsonb(v_resolved), 'bundle_version_id', v_id,
    'status', 'draft'
  );
end
$$;

create or replace function public.platform_publish_sector_bundle_v75(
  p_bundle_version uuid,
  p_dry_run boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid(); v_bundle public.sector_bundle_versions%rowtype;
  v_previous uuid;
begin
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode = '42501';
  end if;
  select * into v_bundle from public.sector_bundle_versions
   where id = p_bundle_version for update;
  if not found then raise exception 'sector bundle version was not found' using errcode = '22023'; end if;
  if v_bundle.status = 'retired' then
    raise exception 'a retired sector bundle cannot be published again' using errcode = '22023';
  end if;
  select id into v_previous from public.sector_bundle_versions
   where sector_key = v_bundle.sector_key and status = 'published'
     and id <> v_bundle.id;
  if not coalesce(p_dry_run, true) and v_bundle.status = 'draft' then
    update public.sector_bundle_versions
       set status = 'retired', retired_at = now()
     where sector_key = v_bundle.sector_key and status = 'published'
       and id <> v_bundle.id;
    update public.sector_bundle_versions
       set status = 'published', published_at = now()
     where id = v_bundle.id;
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (null, v_actor, 'SECTOR_BUNDLE_PUBLISHED_V75', 'sector_bundle_versions',
            v_bundle.id, jsonb_build_object('sector_key',v_bundle.sector_key,
              'version',v_bundle.version,'previous_published_version_id',v_previous));
  end if;
  return jsonb_build_object(
    'dry_run', coalesce(p_dry_run, true), 'bundle_version_id', v_bundle.id,
    'sector_key', v_bundle.sector_key, 'version', v_bundle.version,
    'status', case when v_bundle.status = 'published' or not coalesce(p_dry_run, true)
                   then 'published' else v_bundle.status end,
    'modules', to_jsonb(v_bundle.modules),
    'previous_published_version_id', v_previous
  );
end
$$;

create or replace function public.platform_assign_business_sector_v75(
  p_business uuid,
  p_bundle_version uuid,
  p_expected_version bigint default null,
  p_dry_run boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid(); v_assignment public.business_sector_assignments%rowtype;
  v_bundle public.sector_bundle_versions%rowtype; v_effective text[]; v_next bigint;
  v_changed boolean;
begin
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode = '42501';
  end if;
  perform 1 from public.businesses where id = p_business for update;
  if not found then raise exception 'business was not found' using errcode = '22023'; end if;
  select * into v_bundle from public.sector_bundle_versions
   where id = p_bundle_version and status = 'published';
  if not found then raise exception 'published sector bundle was not found' using errcode = '22023'; end if;
  select * into v_assignment from public.business_sector_assignments
   where business_id = p_business for update;
  if found and p_expected_version is not null and v_assignment.version <> p_expected_version then
    raise exception 'sector assignment version conflict' using errcode = '40001';
  end if;
  v_next := case when v_assignment.business_id is null then 1 else v_assignment.version + 1 end;
  v_effective := app.resolve_sector_entitlement_v75(v_bundle.id, '{}', '{}');
  v_changed := v_assignment.business_id is null
    or v_assignment.bundle_version_id <> v_bundle.id
    or v_assignment.override_version_id is not null;
  if not coalesce(p_dry_run, true) and v_changed then
    insert into public.business_sector_assignments(
      business_id,bundle_version_id,override_version_id,version,assigned_by,assigned_at,updated_at
    ) values (p_business,v_bundle.id,null,v_next,v_actor,now(),now())
    on conflict (business_id) do update set
      bundle_version_id=excluded.bundle_version_id, override_version_id=null,
      version=excluded.version, assigned_by=excluded.assigned_by, updated_at=now();
    perform set_config('app.sector_entitlement_sync', p_business::text, true);
    update public.businesses
       set enabled_modules = v_effective,
           industry = v_bundle.sector_key
     where id = p_business;
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'BUSINESS_SECTOR_ASSIGNED_V75', 'businesses',
            p_business, jsonb_build_object('bundle_version_id',v_bundle.id,
              'sector_key',v_bundle.sector_key,'assignment_version',v_next,
              'effective_modules',v_effective));
  end if;
  return jsonb_build_object(
    'dry_run',coalesce(p_dry_run,true),'changed',v_changed,'business_id',p_business,
    'assignment_version',case when v_changed then v_next else v_assignment.version end,
    'bundle_version_id',v_bundle.id,'sector_key',v_bundle.sector_key,
    'override_version_id',null,'effective_modules',to_jsonb(v_effective)
  );
end
$$;

create or replace function public.platform_set_business_sector_override_v75(
  p_business uuid,
  p_add_modules text[],
  p_remove_modules text[],
  p_reason text,
  p_expected_version bigint default null,
  p_dry_run boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid(); v_assignment public.business_sector_assignments%rowtype;
  v_bundle public.sector_bundle_versions%rowtype; v_effective text[];
  v_override_id uuid; v_override_version integer; v_next bigint;
begin
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason,''))) < 3 then
    raise exception 'override reason is required' using errcode = '22023';
  end if;
  select * into v_assignment from public.business_sector_assignments
   where business_id = p_business for update;
  if not found then raise exception 'business sector assignment was not found' using errcode = '22023'; end if;
  if p_expected_version is not null and v_assignment.version <> p_expected_version then
    raise exception 'sector assignment version conflict' using errcode = '40001';
  end if;
  select * into strict v_bundle from public.sector_bundle_versions
   where id = v_assignment.bundle_version_id;
  v_effective := app.resolve_sector_entitlement_v75(
    v_bundle.id, coalesce(p_add_modules,'{}'), coalesce(p_remove_modules,'{}')
  );
  select coalesce(max(version),0)+1 into v_override_version
    from public.business_sector_override_versions where business_id = p_business;
  v_next := v_assignment.version + 1;
  if not coalesce(p_dry_run, true) then
    insert into public.business_sector_override_versions(
      business_id,version,add_modules,remove_modules,reason,created_by
    ) values (
      p_business,v_override_version,coalesce(p_add_modules,'{}'),
      coalesce(p_remove_modules,'{}'),btrim(p_reason),v_actor
    ) returning id into v_override_id;
    update public.business_sector_assignments
       set override_version_id=v_override_id,version=v_next,
           assigned_by=v_actor,updated_at=now()
     where business_id=p_business;
    perform set_config('app.sector_entitlement_sync', p_business::text, true);
    update public.businesses set enabled_modules=v_effective where id=p_business;
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business,v_actor,'BUSINESS_SECTOR_OVERRIDE_SET_V75','businesses',p_business,
            jsonb_build_object('override_version_id',v_override_id,
              'override_version',v_override_version,'assignment_version',v_next,
              'add_modules',coalesce(p_add_modules,'{}'),'remove_modules',coalesce(p_remove_modules,'{}'),
              'effective_modules',v_effective,'reason',btrim(p_reason)));
  end if;
  return jsonb_build_object(
    'dry_run',coalesce(p_dry_run,true),'changed',true,'business_id',p_business,
    'assignment_version',v_next,'bundle_version_id',v_bundle.id,
    'sector_key',v_bundle.sector_key,'override_version_id',v_override_id,
    'override_version',v_override_version,'add_modules',to_jsonb(coalesce(p_add_modules,'{}')),
    'remove_modules',to_jsonb(coalesce(p_remove_modules,'{}')),
    'effective_modules',to_jsonb(v_effective)
  );
end
$$;

-- Assigned firms cannot use the historical owner module selector. Unassigned
-- synthetic/recovery fixtures keep the legacy behavior.
create or replace function public.set_business_modules(p_business uuid, p_modules text[])
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_requested text[] := coalesce(p_modules,'{}'); v_resolved text[]; v_added text[];
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'only the business owner can change modules' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.business_sector_assignments where business_id=p_business
  ) then
    raise exception 'business modules are fixed by the assigned sector entitlement'
      using errcode = '42501';
  end if;
  v_resolved := app.resolve_module_dependencies(v_requested);
  update public.businesses set enabled_modules=v_resolved where id=p_business;
  if not found then raise exception 'business not found'; end if;
  select coalesce(array_agg(module_key order by module_key),'{}') into v_added
    from (select unnest(v_resolved) module_key except select unnest(v_requested)) added;
  return json_build_object('modules',v_resolved,'added_dependencies',v_added);
end
$$;
revoke all on function public.set_business_modules(uuid,text[])
  from public, anon, authenticated;
grant execute on function public.set_business_modules(uuid,text[])
  to authenticated;

-- Onboarding retains the shipped signature, but the server now resolves the
-- published sector bundle and ignores the browser's legacy p_modules suggestion.
create or replace function public.create_business(
  p_name text, p_slug text, p_industry text, p_modules text[]
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_uid uuid := auth.uid(); v_business public.businesses%rowtype;
  v_staff uuid; v_branch uuid; v_bundle public.sector_bundle_versions%rowtype;
  v_sector text := case
    when p_industry in ('fnb','salon','facial','massage','fitness','retail','other')
      then p_industry
    else 'other'
  end;
begin
  if v_uid is null then raise exception 'sign in required' using errcode='42501'; end if;
  if p_name is null or length(btrim(p_name))<2 then raise exception 'business name required'; end if;
  select * into v_bundle from public.sector_bundle_versions
   where sector_key=v_sector
     and status='published';
  if not found then raise exception 'published sector entitlement is unavailable'; end if;
  insert into public.businesses(name,slug,industry,enabled_modules)
  values (btrim(p_name),p_slug,v_sector,v_bundle.modules)
  returning * into v_business;
  insert into public.staff(business_id,user_id,role,full_name)
  values (v_business.id,v_uid,'owner',coalesce(auth.jwt()->>'email','Owner'))
  returning id into v_staff;
  insert into public.branches(business_id,name,is_default,active)
  values (v_business.id,btrim(p_name),true,true) returning id into v_branch;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values (v_business.id,v_staff,v_branch);
  insert into public.loyalty_programs(
    business_id,kind,earn_points_per_dollar,redeem_points,reward_credit_cents,
    active,loyalty_model,configuration_status,recommendation_source
  ) values (v_business.id,'points',1,800,2000,false,'classic','draft','onboarding_preset');
  insert into public.subscriptions(business_id) values(v_business.id)
  on conflict (business_id) do nothing;
  insert into public.business_sector_assignments(
    business_id,bundle_version_id,version,assigned_by
  ) values(v_business.id,v_bundle.id,1,v_uid);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_business.id,v_uid,'ONBOARD','businesses',v_business.id,jsonb_build_object(
    'name',v_business.name,'industry',v_business.industry,
    'sector_bundle_version_id',v_bundle.id,'legacy_requested_modules_ignored',p_modules is not null,
    'loyalty_configuration_status','draft'));
  return row_to_json(v_business);
end
$$;
revoke all on function public.create_business(text,text,text,text[])
  from public, anon, authenticated;
grant execute on function public.create_business(text,text,text,text[])
  to authenticated;

revoke all on function public.platform_list_consultants_v75() from public, anon, authenticated;
revoke all on function public.platform_upsert_consultant_v75(uuid,uuid,text,text,date,boolean) from public, anon, authenticated;
revoke all on function public.platform_list_sector_entitlements_v75() from public, anon, authenticated;
revoke all on function public.platform_create_sector_bundle_v75(text,text,text[],boolean) from public, anon, authenticated;
revoke all on function public.platform_publish_sector_bundle_v75(uuid,boolean) from public, anon, authenticated;
revoke all on function public.platform_assign_business_sector_v75(uuid,uuid,bigint,boolean) from public, anon, authenticated;
revoke all on function public.platform_set_business_sector_override_v75(uuid,text[],text[],text,bigint,boolean) from public, anon, authenticated;
grant execute on function public.platform_list_consultants_v75() to authenticated;
grant execute on function public.platform_upsert_consultant_v75(uuid,uuid,text,text,date,boolean) to authenticated;
grant execute on function public.platform_list_sector_entitlements_v75() to authenticated;
grant execute on function public.platform_create_sector_bundle_v75(text,text,text[],boolean) to authenticated;
grant execute on function public.platform_publish_sector_bundle_v75(uuid,boolean) to authenticated;
grant execute on function public.platform_assign_business_sector_v75(uuid,uuid,bigint,boolean) to authenticated;
grant execute on function public.platform_set_business_sector_override_v75(uuid,text[],text[],text,bigint,boolean) to authenticated;

commit;
