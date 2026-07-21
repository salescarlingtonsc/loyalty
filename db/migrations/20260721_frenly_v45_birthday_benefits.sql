-- FRENLY C45 — private birthday-benefit contracts.
--
-- Forward-only local review candidate.  This deliberately does not send a
-- message, create an outbox/provider record, seed a programme, or make an
-- entitlement automatically.  A customer explicitly activates a benefit
-- after independently opting in.  Full dates of birth stay in C42's private
-- profile table and are read only inside the narrowly scoped helper below.

begin;

insert into app.platform_feature_flags(feature_key, enabled)
values ('customer_birthday_benefits', false)
on conflict (feature_key) do nothing;

-- -------------------------------------------------------------------------
-- Private programme, consent, entitlement, and operation state
-- -------------------------------------------------------------------------

create table public.birthday_programs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (id, business_id)
);
comment on table public.birthday_programs is
  'Stable per-business birthday-program identities. No programme is seeded.';

create table public.birthday_program_versions (
  id uuid primary key default gen_random_uuid(),
  program_id uuid not null,
  config_version_id uuid not null,
  business_id uuid not null,
  active boolean not null default true,
  customer_label text not null check (length(btrim(customer_label)) between 1 and 120),
  customer_description text not null check (length(btrim(customer_description)) between 1 and 1000),
  customer_terms text not null check (length(btrim(customer_terms)) between 1 and 2000),
  fulfillment_kind text not null check (fulfillment_kind in ('discount_pct', 'free_item')),
  discount_percent numeric(5,2),
  manual_item text,
  window_days_before integer not null default 0 check (window_days_before between 0 and 182),
  window_days_after integer not null default 0 check (window_days_after between 0 and 182),
  sort integer not null default 0 check (sort between 0 and 10000),
  created_at timestamptz not null default now(),
  constraint birthday_program_versions_identity_uk unique (program_id, config_version_id),
  constraint birthday_program_versions_one_program_per_config_uk unique (business_id, config_version_id),
  constraint birthday_program_versions_id_config_business_uk unique (id, config_version_id, business_id),
  constraint birthday_program_versions_header_fk
    foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict,
  constraint birthday_program_versions_program_fk
    foreign key (program_id, business_id)
    references public.birthday_programs(id, business_id) on delete restrict,
  constraint birthday_program_versions_fulfillment_check check (
    (fulfillment_kind = 'discount_pct'
      and discount_percent is not null and discount_percent > 0 and discount_percent <= 100
      and manual_item is null)
    or
    (fulfillment_kind = 'free_item'
      and discount_percent is null
      and length(btrim(coalesce(manual_item, ''))) between 1 and 240)
  ),
  -- The half-open SG windows can touch but can never overlap across annual
  -- observed birthdays. This holds for leap and non-leap years alike.
  constraint birthday_program_versions_window_no_annual_overlap_check
    check (window_days_before + window_days_after + 1 <= 365)
);
comment on table public.birthday_program_versions is
  'One typed birthday rule per stable programme/configuration version. Published rows are immutable.';

create table public.customer_birthday_participation (
  identity_id uuid primary key references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null unique references auth.users(id) on delete restrict,
  opted_in boolean not null default false,
  updated_at timestamptz not null default now(),
  constraint customer_birthday_participation_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict
);
comment on table public.customer_birthday_participation is
  'Private, platform-wide birthday-benefit participation. It is separate from every marketing preference.';

create table public.customer_birthday_participation_operations (
  id uuid primary key default gen_random_uuid(),
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  actor_auth_user_id uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  opted_in boolean not null,
  created_at timestamptz not null default now(),
  unique (identity_id, idempotency_key),
  constraint customer_birthday_participation_operations_identity_actor_fk
    foreign key (identity_id, actor_auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict
);

create table public.birthday_program_draft_operations (
  id uuid primary key default gen_random_uuid(),
  config_version_id uuid not null references public.firm_config_versions(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete cascade,
  actor uuid not null references auth.users(id) on delete restrict,
  program_id uuid not null,
  expected_snapshot_hash text not null check (length(expected_snapshot_hash) = 32),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  result_snapshot_hash text not null check (length(result_snapshot_hash) = 32),
  created_at timestamptz not null default now(),
  unique (config_version_id, actor, program_id, expected_snapshot_hash, request_hash),
  unique (config_version_id, actor, program_id, expected_snapshot_hash),
  constraint birthday_program_draft_operations_config_fk
    foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict,
  constraint birthday_program_draft_operations_program_fk
    foreign key (program_id, business_id)
    references public.birthday_programs(id, business_id) on delete restrict
);

create table public.customer_birthday_entitlements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid not null,
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  config_version_id uuid not null,
  birthday_program_version_id uuid not null references public.birthday_program_versions(id) on delete restrict,
  birthday_year integer not null check (birthday_year between 1900 and 9999),
  status text not null check (status in ('available', 'redeemed', 'expired')),
  valid_from timestamptz not null,
  valid_until timestamptz not null,
  benefit_snapshot jsonb not null check (jsonb_typeof(benefit_snapshot) = 'object'),
  activated_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_birthday_entitlements_client_fk
    foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint customer_birthday_entitlements_config_fk
    foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict,
  constraint customer_birthday_entitlements_program_provenance_fk
    foreign key (birthday_program_version_id, config_version_id, business_id)
    references public.birthday_program_versions(id, config_version_id, business_id) on delete restrict,
  constraint customer_birthday_entitlements_window_check check (valid_until > valid_from),
  constraint customer_birthday_entitlements_customer_year_uk unique (business_id, client_id, birthday_year),
  constraint customer_birthday_entitlements_id_business_client_identity_uk unique (id, business_id, client_id, identity_id),
  constraint customer_birthday_entitlements_id_business_client_uk unique (id, business_id, client_id)
);
comment on table public.customer_birthday_entitlements is
  'Customer-specific immutable benefit promise. It stores no DOB, observed date, age, or birthday month/day.';

create table public.customer_birthday_activation_operations (
  id uuid primary key default gen_random_uuid(),
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid not null,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  entitlement_id uuid not null references public.customer_birthday_entitlements(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (identity_id, business_id, idempotency_key),
  constraint customer_birthday_activation_operations_client_fk
    foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint customer_birthday_activation_operations_entitlement_fk
    foreign key (entitlement_id, business_id, client_id, identity_id)
    references public.customer_birthday_entitlements(id, business_id, client_id, identity_id) on delete restrict
);

create table public.customer_birthday_redemptions (
  id uuid primary key default gen_random_uuid(),
  entitlement_id uuid not null references public.customer_birthday_entitlements(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid not null,
  branch_id uuid not null,
  actor uuid not null references auth.users(id) on delete restrict,
  operation_kind text not null check (operation_kind in ('redemption', 'reversal')),
  original_redemption_id uuid references public.customer_birthday_redemptions(id) on delete restrict,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  reason text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint customer_birthday_redemptions_client_fk
    foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint customer_birthday_redemptions_branch_fk
    foreign key (branch_id, business_id)
    references public.branches(id, business_id) on delete restrict,
  constraint customer_birthday_redemptions_entitlement_fk
    foreign key (entitlement_id, business_id, client_id)
    references public.customer_birthday_entitlements(id, business_id, client_id) on delete restrict,
  constraint customer_birthday_redemptions_shape_check check (
    (operation_kind = 'redemption' and original_redemption_id is null and reason is null)
    or
    (operation_kind = 'reversal' and original_redemption_id is not null
      and length(btrim(coalesce(reason, ''))) between 3 and 500)
  ),
  unique (entitlement_id, actor, operation_kind, idempotency_key)
);
create unique index customer_birthday_one_live_redemption_idx
  on public.customer_birthday_redemptions(entitlement_id)
  where operation_kind = 'redemption' and active;

create index customer_birthday_entitlements_effective_idx
  on public.customer_birthday_entitlements(business_id, client_id, status, valid_until);
create index birthday_program_versions_active_idx
  on public.birthday_program_versions(business_id, config_version_id, sort)
  where active;

alter table public.birthday_programs enable row level security;
alter table public.birthday_program_versions enable row level security;
alter table public.customer_birthday_participation enable row level security;
alter table public.customer_birthday_participation_operations enable row level security;
alter table public.birthday_program_draft_operations enable row level security;
alter table public.customer_birthday_entitlements enable row level security;
alter table public.customer_birthday_activation_operations enable row level security;
alter table public.customer_birthday_redemptions enable row level security;
revoke all privileges on table public.birthday_programs from public, anon, authenticated;
revoke all privileges on table public.birthday_program_versions from public, anon, authenticated;
revoke all privileges on table public.customer_birthday_participation from public, anon, authenticated;
revoke all privileges on table public.customer_birthday_participation_operations from public, anon, authenticated;
revoke all privileges on table public.birthday_program_draft_operations from public, anon, authenticated;
revoke all privileges on table public.customer_birthday_entitlements from public, anon, authenticated;
revoke all privileges on table public.customer_birthday_activation_operations from public, anon, authenticated;
revoke all privileges on table public.customer_birthday_redemptions from public, anon, authenticated;

-- -------------------------------------------------------------------------
-- Internal safety helpers. These are all browser-closed.
-- -------------------------------------------------------------------------

create or replace function app.c45_hash(p_value text)
returns text language sql immutable strict
set search_path to 'pg_catalog', 'extensions', 'pg_temp'
as $$ select encode(extensions.digest(convert_to(p_value, 'UTF8'), 'sha256'), 'hex') $$;

create or replace function app.c45_owner_loyalty_write(p_business_id uuid)
returns boolean language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select auth.uid() is not null
     and app.is_salon_owner(p_business_id)
     and app.can_module_write(p_business_id, 'loyalty')
     and exists (
       select 1 from public.businesses b
        where b.id = p_business_id and 'loyalty' = any(coalesce(b.enabled_modules, '{}'::text[]))
     )
$$;

create or replace function app.c45_observed_birthday(p_birth_date date, p_year integer)
returns date language plpgsql immutable strict
set search_path to 'pg_catalog', 'pg_temp'
as $$
begin
  if extract(month from p_birth_date) = 2 and extract(day from p_birth_date) = 29
     and not (p_year % 4 = 0 and (p_year % 100 <> 0 or p_year % 400 = 0)) then
    return make_date(p_year, 2, 28);
  end if;
  return make_date(p_year, extract(month from p_birth_date)::integer,
                   extract(day from p_birth_date)::integer);
end $$;

-- SG calendar is explicit and never inherits the connection/session timezone.
-- Adjacent calendar years are evaluated so December/January windows remain
-- available across the year boundary.
create or replace function app.c45_birthday_window(
  p_birth_date date,
  p_window_days_before integer,
  p_window_days_after integer,
  p_as_of timestamptz
)
returns table (birthday_year integer, valid_from timestamptz, valid_until timestamptz)
language sql immutable strict
set search_path to 'pg_catalog', 'pg_temp'
as $$
  with sg_now as (
    select timezone('Asia/Singapore', p_as_of) as local_now
  ), candidates as (
    select y as birthday_year, app.c45_observed_birthday(p_birth_date, y) as observed_date
      from sg_now,
      lateral generate_series(
        extract(year from local_now)::integer - 1,
        extract(year from local_now)::integer + 1
      ) as y
  )
  select birthday_year,
    ((observed_date - p_window_days_before)::timestamp at time zone 'Asia/Singapore') as valid_from,
    ((observed_date + p_window_days_after + 1)::timestamp at time zone 'Asia/Singapore') as valid_until
    from candidates
   where p_as_of >= ((observed_date - p_window_days_before)::timestamp at time zone 'Asia/Singapore')
     and p_as_of < ((observed_date + p_window_days_after + 1)::timestamp at time zone 'Asia/Singapore')
   order by birthday_year desc
   limit 1
$$;

create or replace function app.c45_benefit_snapshot(p_program public.birthday_program_versions)
returns jsonb language sql immutable strict
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'label', p_program.customer_label,
    'description', p_program.customer_description,
    'terms', p_program.customer_terms,
    'kind', p_program.fulfillment_kind,
    'display', case when p_program.fulfillment_kind = 'discount_pct'
      then trim(to_char(p_program.discount_percent, 'FM990D00')) || '% off'
      else p_program.manual_item end
  ))
$$;

create or replace function app.c45_safe_birthday_entitlement(
  p_entitlement public.customer_birthday_entitlements,
  p_as_of timestamptz,
  p_cta text default 'show_at_counter'
)
returns jsonb language sql stable strict
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'label', p_entitlement.benefit_snapshot->>'label',
    'description', p_entitlement.benefit_snapshot->>'description',
    'terms', p_entitlement.benefit_snapshot->>'terms',
    'kind', p_entitlement.benefit_snapshot->>'kind',
    'display', p_entitlement.benefit_snapshot->>'display',
    'status', case
      when p_entitlement.status = 'available' and p_entitlement.valid_until <= p_as_of then 'expired'
      else p_entitlement.status end,
    'validity', jsonb_build_object(
      'available_from', p_entitlement.valid_from,
      'available_until', p_entitlement.valid_until
    ),
    'redemption', case when p_entitlement.status = 'redeemed' then 'redeemed' else null end,
    'cta', case
      when p_entitlement.status = 'available'
       and p_entitlement.valid_from <= p_as_of
       and p_entitlement.valid_until > p_as_of then p_cta
      else null end
  ))
$$;

-- Customer validity is useful to the customer deciding whether to act, but is
-- never a counter-facing fact: even a half-open end instant can be combined
-- with a benefit label to infer an observed birthday date. Staff receive only
-- the current effective state and minimum fulfilment facts; customer-facing
-- description/terms remain customer-only because free-form text can describe
-- a validity window more precisely than the staff needs to fulfil it.
create or replace function app.c45_staff_safe_birthday_entitlement(
  p_entitlement public.customer_birthday_entitlements,
  p_as_of timestamptz,
  p_cta text default 'show_at_counter'
)
returns jsonb language sql stable strict
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'label', p_entitlement.benefit_snapshot->>'label',
    'kind', p_entitlement.benefit_snapshot->>'kind',
    'display', p_entitlement.benefit_snapshot->>'display',
    'status', case
      when p_entitlement.status = 'available' and p_entitlement.valid_until <= p_as_of then 'expired'
      else p_entitlement.status end,
    'redemption', case when p_entitlement.status = 'redeemed' then 'redeemed' else null end,
    'cta', case
      when p_entitlement.status = 'available'
       and p_entitlement.valid_from <= p_as_of
       and p_entitlement.valid_until > p_as_of then p_cta
      else null end
  ))
$$;

-- This is the only C45 helper that reads C42.birth_date. It can only derive
-- scope from an authenticated active identity plus a verified business link;
-- it returns a record to other private functions, never JSON or audit data.
create or replace function app.c45_customer_birthday_context(p_business_slug text)
returns table (
  identity_id uuid,
  business_id uuid,
  client_id uuid,
  birth_date date,
  business_slug text
)
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_context record;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_birthday_benefits') then
    raise exception 'birthday benefits are unavailable' using errcode = '0A000';
  end if;
  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'birthday benefits are unavailable' using errcode = '42501';
  end if;
  return query
    select v_context.identity_id, v_context.business_id, v_context.client_id,
           cp.birth_date, v_context.business_slug
      from public.customer_profiles cp
     where cp.identity_id = v_context.identity_id
       and cp.auth_user_id = auth.uid();
  if not found then
    raise exception 'birthday benefits are unavailable' using errcode = '42501';
  end if;
end $$;

-- Private reusable reader. The caller receives only the safe benefit envelope;
-- no DOB, observed date, birthday year, client/identity/program IDs, costs, or
-- saving estimate appear in its result.
create or replace function app.c45_customer_birthday_benefit_for_context(
  p_business_id uuid,
  p_client_id uuid,
  p_identity_id uuid,
  p_birth_date date,
  p_as_of timestamptz
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_entitlement public.customer_birthday_entitlements%rowtype;
  v_program public.birthday_program_versions%rowtype;
  v_window record;
  v_opted_in boolean := false;
begin
  -- A current immutable promise wins even if the active programme has since
  -- changed. Its effective state is derived from the half-open validity range.
  select * into v_entitlement
    from public.customer_birthday_entitlements e
   where e.business_id = p_business_id and e.client_id = p_client_id
     and e.identity_id = p_identity_id and e.valid_until > p_as_of
   order by e.valid_until desc, e.activated_at desc
   limit 1;
  if found then
    -- An existing promise remains visible after opt-out until it expires or is
    -- reversed; participation only gates NEW activation.
    return app.c45_safe_birthday_entitlement(v_entitlement, p_as_of);
  end if;
  select coalesce(p.opted_in, false) into v_opted_in
    from (select 1) one
    left join public.customer_birthday_participation p on p.identity_id = p_identity_id;
  select bpv.* into v_program
    from public.businesses b
    join public.loyalty_program_versions lpv
      on lpv.config_version_id = b.active_config_version_id
     and lpv.business_id = b.id and lpv.active
    join public.birthday_program_versions bpv
      on bpv.config_version_id = b.active_config_version_id
     and bpv.business_id = b.id and bpv.active
   where b.id = p_business_id
     and 'loyalty' = any(coalesce(b.enabled_modules, '{}'::text[]))
   order by bpv.sort, bpv.program_id
   limit 1;
  if found then
    select * into v_window
      from app.c45_birthday_window(p_birth_date, v_program.window_days_before,
        v_program.window_days_after, p_as_of);
    if found then
      -- Once the current SG birthday window is known, the matching immutable
      -- promise must be projected even when its end instant has elapsed. This
      -- produces effective `expired` without a write inside a failing action.
      select * into v_entitlement
        from public.customer_birthday_entitlements e
       where e.business_id = p_business_id and e.client_id = p_client_id
         and e.identity_id = p_identity_id and e.birthday_year = v_window.birthday_year
       order by e.activated_at desc
       limit 1;
      if found then return app.c45_safe_birthday_entitlement(v_entitlement, p_as_of); end if;
      if coalesce(v_opted_in, false) then
        return jsonb_build_object(
          'label', v_program.customer_label,
          'description', v_program.customer_description,
          'terms', v_program.customer_terms,
          'kind', v_program.fulfillment_kind,
          'display', case when v_program.fulfillment_kind = 'discount_pct'
            then trim(to_char(v_program.discount_percent, 'FM990D00')) || '% off'
            else v_program.manual_item end,
          'status', 'ready_to_activate',
          'validity', jsonb_build_object('available_from', v_window.valid_from, 'available_until', v_window.valid_until),
          'cta', 'activate'
        );
      end if;
    end if;
  end if;
  -- Outside the current birthday window, retain the most recent immutable
  -- promise as customer history. `c45_safe_birthday_entitlement` derives an
  -- effective expired state from valid_until; no failed redemption writes it.
  select * into v_entitlement
    from public.customer_birthday_entitlements e
   where e.business_id = p_business_id and e.client_id = p_client_id
     and e.identity_id = p_identity_id
   order by e.birthday_year desc, e.valid_until desc, e.activated_at desc
   limit 1;
  if found then return app.c45_safe_birthday_entitlement(v_entitlement, p_as_of); end if;
  return null;
end $$;

-- -------------------------------------------------------------------------
-- Versioned configuration: clone, immutable published rows, and snapshot
-- -------------------------------------------------------------------------

create or replace function app.c45_birthday_program_version_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_status text;
begin
  select status into v_status from public.firm_config_versions
   where id = case when tg_op = 'DELETE' then old.config_version_id else new.config_version_id end;
  if tg_op = 'UPDATE' then
    if (new.program_id, new.config_version_id, new.business_id, new.created_at)
        is distinct from (old.program_id, old.config_version_id, old.business_id, old.created_at) then
      raise exception 'birthday program identity is immutable; edit the draft row in place' using errcode = '23001';
    end if;
  end if;
  if v_status is distinct from 'draft' then
    raise exception 'published birthday configuration is immutable; edit a draft' using errcode = '23001';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
create trigger trg_c45_birthday_program_version_guard
  before insert or update or delete on public.birthday_program_versions
  for each row execute function app.c45_birthday_program_version_guard();

create or replace function app.c45_clone_birthday_programs_on_draft()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.status = 'draft' and new.based_on_version_id is not null then
    insert into public.birthday_program_versions (
      program_id, config_version_id, business_id, active, customer_label,
      customer_description, customer_terms, fulfillment_kind, discount_percent,
      manual_item, window_days_before, window_days_after, sort
    )
    select program_id, new.id, new.business_id, active, customer_label,
           customer_description, customer_terms, fulfillment_kind, discount_percent,
           manual_item, window_days_before, window_days_after, sort
      from public.birthday_program_versions
     where config_version_id = new.based_on_version_id and business_id = new.business_id;
  end if;
  return new;
end $$;
create trigger trg_c45_clone_birthday_programs_on_draft
  after insert on public.firm_config_versions
  for each row execute function app.c45_clone_birthday_programs_on_draft();

-- The shared configuration lifecycle is tightened forward rather than relying
-- on the historical owner predicate alone: an inactive owner or an owner
-- without an enabled loyalty module cannot create a C45-era draft.
create or replace function public.create_loyalty_config_draft(
  p_business uuid,
  p_based_on uuid default null,
  p_source text default 'manual'
)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_actor uuid:=auth.uid(); v_base uuid; v_id uuid; v_no integer; v_typed public.loyalty_program_versions%rowtype;
begin
  if not app.c45_owner_loyalty_write(p_business) then raise exception 'owner loyalty configuration access required' using errcode='42501'; end if;
  perform 1 from public.businesses where id=p_business for update;
  v_base:=coalesce(p_based_on,app.active_config_version(p_business),(select current_config_version_id from public.loyalty_programs where business_id=p_business));
  select * into v_typed from public.loyalty_program_versions where config_version_id=v_base and business_id=p_business;
  if not found then raise exception 'base configuration not found'; end if;
  select coalesce(max(version_no),0)+1 into v_no from public.firm_config_versions where business_id=p_business;
  v_id:=gen_random_uuid();
  insert into public.firm_config_versions(id,business_id,version_no,status,based_on_version_id,source,snapshot_hash,created_by)
  values(v_id,p_business,v_no,'draft',v_base,coalesce(nullif(btrim(p_source),''),'manual'),md5((to_jsonb(v_typed)-'config_version_id')::text),v_actor);
  insert into public.loyalty_program_versions(config_version_id,business_id,kind,loyalty_model,active,earn_points_per_dollar,redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,expiry_mode,expiry_days)
  select v_id,business_id,kind,loyalty_model,active,earn_points_per_dollar,redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,expiry_mode,expiry_days
    from public.loyalty_program_versions where config_version_id=v_base;
  insert into public.loyalty_tier_versions(tier_id,config_version_id,business_id,name,threshold,points_multiplier,perk_note,sort,active)
  select tier_id,v_id,business_id,name,threshold,points_multiplier,perk_note,sort,active
    from public.loyalty_tier_versions where config_version_id=v_base;
  perform app.refresh_loyalty_config_snapshot(v_id);
  return json_build_object('version_id',v_id,'version_no',v_no,'status','draft');
end $$;

create or replace function app.c45_loyalty_program_version_write_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_business uuid:=case when tg_op='DELETE' then old.business_id else new.business_id end;
  v_status text;
begin
  select status into v_status from public.firm_config_versions
   where id=case when tg_op='DELETE' then old.config_version_id else new.config_version_id end;
  if v_status='draft' and not app.c45_owner_loyalty_write(v_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if tg_op='DELETE' then return old; end if; return new;
end $$;
create trigger trg_c45_loyalty_program_version_write_guard
  before insert or update or delete on public.loyalty_program_versions
  for each row execute function app.c45_loyalty_program_version_write_guard();

-- C45 is an additive forward replacement of the C37 snapshot. DOB never enters
-- the configuration tree; the birthday-program contribution is stable, typed,
-- and contains only merchant-configured benefit fields.
create or replace function app.refresh_loyalty_config_snapshot(p_version uuid)
returns void language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_snapshot jsonb;
begin
  select jsonb_build_object(
    'program',(select to_jsonb(lp)-'config_version_id' from public.loyalty_program_versions lp where lp.config_version_id=p_version),
    'tiers',coalesce((select jsonb_agg(to_jsonb(tv)-'id'-'config_version_id'-'business_id'-'created_at' order by tv.threshold,tv.sort,tv.tier_id) from public.loyalty_tier_versions tv where tv.config_version_id=p_version),'[]'::jsonb),
    'rewards',coalesce((select jsonb_agg(jsonb_build_object(
      'reward',to_jsonb(rv)-'id'-'config_version_id'-'business_id'-'created_at',
      'branches',coalesce((select jsonb_agg(e.branch_id order by e.branch_id) from public.loyalty_reward_branches e where e.reward_version_id=rv.id),'[]'::jsonb),
      'services',coalesce((select jsonb_agg(e.service_id order by e.service_id) from public.loyalty_reward_services e where e.reward_version_id=rv.id),'[]'::jsonb),
      'products',coalesce((select jsonb_agg(e.product_id order by e.product_id) from public.loyalty_reward_products e where e.reward_version_id=rv.id),'[]'::jsonb)
    ) order by rv.reward_id) from public.loyalty_reward_versions rv where rv.config_version_id=p_version),'[]'::jsonb),
    'branch_overrides',coalesce((select jsonb_agg(to_jsonb(o)-'config_version_id'-'business_id'-'created_at'-'updated_at' order by o.branch_id) from public.loyalty_branch_overrides o where o.config_version_id=p_version),'[]'::jsonb),
    'retention_programs',coalesce((select jsonb_agg(to_jsonb(r)-'id'-'config_version_id'-'business_id'-'created_at' order by r.sort,r.program_id) from public.retention_program_versions r where r.config_version_id=p_version),'[]'::jsonb),
    'birthday_programs',coalesce((select jsonb_agg(
      to_jsonb(bp)-'id'-'config_version_id'-'business_id'-'created_at'
      order by bp.sort,bp.program_id
    ) from public.birthday_program_versions bp where bp.config_version_id=p_version),'[]'::jsonb)
  ) into v_snapshot;
  update public.firm_config_versions set snapshot_hash=md5(v_snapshot::text) where id=p_version;
end $$;

create or replace function app.c45_birthday_snapshot_trigger()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  perform app.refresh_loyalty_config_snapshot(case when tg_op = 'DELETE' then old.config_version_id else new.config_version_id end);
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
create trigger trg_c45_birthday_program_snapshot
  after insert or update or delete on public.birthday_program_versions
  for each row execute function app.c45_birthday_snapshot_trigger();

create or replace function public.get_birthday_program_draft(p_config_version uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_header public.firm_config_versions%rowtype;
begin
  select * into v_header from public.firm_config_versions where id = p_config_version for share;
  if not found or not app.c45_owner_loyalty_write(v_header.business_id) then
    raise exception 'owner loyalty configuration access required' using errcode = '42501';
  end if;
  if v_header.status <> 'draft' then
    raise exception 'only a draft birthday configuration may be read' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'status', v_header.status,
    'snapshot_hash', v_header.snapshot_hash,
    'programs', coalesce((select jsonb_agg(jsonb_build_object(
      'program_id', p.program_id, 'active', p.active, 'customer_label', p.customer_label,
      'customer_description', p.customer_description, 'customer_terms', p.customer_terms,
      'fulfillment_kind', p.fulfillment_kind, 'discount_percent', p.discount_percent,
      'manual_item', p.manual_item, 'window_days_before', p.window_days_before,
      'window_days_after', p.window_days_after, 'sort', p.sort
    ) order by p.sort, p.program_id) from public.birthday_program_versions p
      where p.config_version_id = p_config_version and p.business_id = v_header.business_id), '[]'::jsonb)
  );
end $$;

-- Owners can inspect the one live, published rule before deciding whether to
-- create a new draft. This deliberately exposes programme copy only to an
-- active owner with effective loyalty write access; it is not a merchant or
-- customer reader and never contains customer information.
create or replace function public.get_active_birthday_program(p_business_id uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_version uuid;
begin
  if not app.c45_owner_loyalty_write(p_business_id) then
    raise exception 'owner loyalty configuration access required' using errcode = '42501';
  end if;
  select active_config_version_id into v_version
    from public.businesses where id = p_business_id;
  if v_version is null then
    return jsonb_build_object('status','unavailable','programs','[]'::jsonb);
  end if;
  return jsonb_build_object(
    'status','published',
    'programs',coalesce((select jsonb_agg(jsonb_build_object(
      'program_id',p.program_id,'active',p.active,'customer_label',p.customer_label,
      'customer_description',p.customer_description,'customer_terms',p.customer_terms,
      'fulfillment_kind',p.fulfillment_kind,'discount_percent',p.discount_percent,
      'manual_item',p.manual_item,'window_days_before',p.window_days_before,
      'window_days_after',p.window_days_after,'sort',p.sort
    ) order by p.sort,p.program_id)
      from public.birthday_program_versions p
     where p.business_id=p_business_id and p.config_version_id=v_version), '[]'::jsonb)
  );
end $$;

create or replace function public.save_birthday_program_draft(
  p_config_version uuid,
  p_program_id uuid,
  p_program jsonb,
  p_expected_snapshot_hash text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_header public.firm_config_versions%rowtype;
  v_existing public.birthday_program_versions%rowtype;
  v_hash text;
  v_request_hash text;
  v_replay public.birthday_program_draft_operations%rowtype;
  v_active boolean;
  v_label text;
  v_description text;
  v_terms text;
  v_kind text;
  v_discount numeric(5,2);
  v_item text;
  v_before integer;
  v_after integer;
  v_sort integer;
begin
  if p_program_id is null or p_program is null or jsonb_typeof(p_program) <> 'object'
     or p_expected_snapshot_hash is null or length(p_expected_snapshot_hash) <> 32 then
    raise exception 'birthday draft request is invalid' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(p_program) k where k not in (
    'active','customer_label','customer_description','customer_terms','fulfillment_kind',
    'discount_percent','manual_item','window_days_before','window_days_after','sort'
  )) then
    raise exception 'birthday program contains unsupported fields' using errcode = '22023';
  end if;
  v_request_hash := app.c45_hash(jsonb_build_object('program_id',p_program_id,'program',p_program)::text);
  select * into v_header from public.firm_config_versions where id = p_config_version for update;
  if not found or not app.c45_owner_loyalty_write(v_header.business_id) then
    raise exception 'owner loyalty configuration access required' using errcode = '42501';
  end if;
  if v_header.status <> 'draft' then raise exception 'only a draft birthday program may be edited' using errcode = '42501'; end if;
  select * into v_replay from public.birthday_program_draft_operations
   where config_version_id=p_config_version and actor=auth.uid() and program_id=p_program_id
     and expected_snapshot_hash=p_expected_snapshot_hash for share;
  if found then
    if v_replay.request_hash is distinct from v_request_hash then
      raise exception 'birthday draft request conflicts with an existing operation' using errcode = '40001';
    end if;
    return jsonb_build_object('status','draft','snapshot_hash',v_replay.result_snapshot_hash,'replayed',true);
  end if;
  if v_header.snapshot_hash is distinct from p_expected_snapshot_hash then
    raise exception 'draft configuration changed; reload before saving' using errcode = '40001';
  end if;
  select * into v_existing from public.birthday_program_versions
   where config_version_id=p_config_version and business_id=v_header.business_id and program_id=p_program_id for update;
  if v_existing.id is null and exists (
    select 1 from public.birthday_program_versions p
     where p.config_version_id=p_config_version and p.business_id=v_header.business_id
  ) then
    raise exception 'only one birthday program may exist in a configuration version' using errcode='22023';
  end if;
  if v_existing.id is null then
    if exists (select 1 from public.birthday_programs where id=p_program_id and business_id<>v_header.business_id) then
      raise exception 'birthday program does not belong to this business' using errcode = '42501';
    end if;
    insert into public.birthday_programs(id,business_id) values(p_program_id,v_header.business_id)
      on conflict (id) do nothing;
  end if;
  v_active := case when p_program ? 'active' then (p_program->>'active')::boolean else coalesce(v_existing.active,true) end;
  v_label := coalesce(nullif(btrim(p_program->>'customer_label'),''),v_existing.customer_label);
  v_description := coalesce(nullif(btrim(p_program->>'customer_description'),''),v_existing.customer_description);
  v_terms := coalesce(nullif(btrim(p_program->>'customer_terms'),''),v_existing.customer_terms);
  v_kind := coalesce(nullif(btrim(p_program->>'fulfillment_kind'),''),v_existing.fulfillment_kind);
  v_discount := case when p_program ? 'discount_percent' then nullif(p_program->>'discount_percent','')::numeric else v_existing.discount_percent end;
  v_item := case when p_program ? 'manual_item' then nullif(btrim(p_program->>'manual_item'),'') else v_existing.manual_item end;
  v_before := case when p_program ? 'window_days_before' then (p_program->>'window_days_before')::integer else coalesce(v_existing.window_days_before,0) end;
  v_after := case when p_program ? 'window_days_after' then (p_program->>'window_days_after')::integer else coalesce(v_existing.window_days_after,0) end;
  v_sort := case when p_program ? 'sort' then (p_program->>'sort')::integer else coalesce(v_existing.sort,0) end;
  if v_label is null or v_description is null or v_terms is null or v_kind not in ('discount_pct','free_item')
     or v_before not between 0 and 182 or v_after not between 0 and 182 or v_before+v_after+1 > 365
     or v_sort not between 0 and 10000
     or (v_kind='discount_pct' and (v_discount is null or v_discount<=0 or v_discount>100 or v_item is not null))
     or (v_kind='free_item' and (v_discount is not null or v_item is null)) then
    raise exception 'birthday programme values are invalid' using errcode = '22023';
  end if;
  insert into public.birthday_program_versions(
    program_id,config_version_id,business_id,active,customer_label,customer_description,
    customer_terms,fulfillment_kind,discount_percent,manual_item,window_days_before,window_days_after,sort
  ) values(
    p_program_id,p_config_version,v_header.business_id,v_active,v_label,v_description,
    v_terms,v_kind,v_discount,v_item,v_before,v_after,v_sort
  ) on conflict(program_id,config_version_id) do update set
    active=excluded.active, customer_label=excluded.customer_label,
    customer_description=excluded.customer_description, customer_terms=excluded.customer_terms,
    fulfillment_kind=excluded.fulfillment_kind, discount_percent=excluded.discount_percent,
    manual_item=excluded.manual_item, window_days_before=excluded.window_days_before,
    window_days_after=excluded.window_days_after, sort=excluded.sort;
  perform app.refresh_loyalty_config_snapshot(p_config_version);
  select snapshot_hash into v_hash from public.firm_config_versions where id=p_config_version;
  insert into public.birthday_program_draft_operations(
    config_version_id,business_id,actor,program_id,expected_snapshot_hash,request_hash,result_snapshot_hash
  ) values(p_config_version,v_header.business_id,auth.uid(),p_program_id,p_expected_snapshot_hash,v_request_hash,v_hash);
  return jsonb_build_object('status','draft','snapshot_hash',v_hash,'replayed',false);
end $$;

-- C45’s publish replacement preserves C37’s atomic published configuration
-- projection while adding active owner + effective loyalty-write enforcement
-- and the birthday rule validation. No birthday entitlement is created here.
create or replace function public.publish_loyalty_config(p_version uuid)
returns json language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_header public.firm_config_versions%rowtype; v_typed public.loyalty_program_versions%rowtype; v_prior uuid;
begin
  select * into v_header from public.firm_config_versions where id=p_version for update;
  if not found or not app.c45_owner_loyalty_write(v_header.business_id) then raise exception 'owner loyalty configuration access required' using errcode='42501'; end if;
  if v_header.status<>'draft' then raise exception 'only a draft may be published'; end if;
  perform 1 from public.businesses where id=v_header.business_id for update;
  select * into v_typed from public.loyalty_program_versions where config_version_id=p_version;
  if v_typed.active and v_typed.loyalty_model='stamps' and coalesce(v_typed.stamp_per_cents,0)<=0 then raise exception 'active stamps configuration requires spend per stamp' using errcode='23514'; end if;
  if exists(select 1 from public.retention_program_versions rv left join public.firm_reward_taxonomy t on t.id=rv.reward_taxonomy_id and t.business_id=rv.business_id where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and coalesce(t.active,false)=false) then
    raise exception 'active retention programs cannot publish a retired taxonomy' using errcode='23514';
  end if;
  if exists(select 1 from public.birthday_program_versions bp where bp.config_version_id=p_version and bp.business_id=v_header.business_id and bp.active and bp.window_days_before+bp.window_days_after+1>365) then
    raise exception 'birthday benefit windows may not overlap annually' using errcode='23514';
  end if;
  perform app.refresh_loyalty_config_snapshot(p_version);
  select * into v_header from public.firm_config_versions where id=p_version;
  select active_config_version_id into v_prior from public.businesses where id=v_header.business_id;
  update public.firm_config_versions set status='superseded',superseded_at=now() where id=v_prior and status='published';
  update public.firm_config_versions set status='published',published_at=now() where id=p_version;
  update public.businesses set active_config_version_id=p_version where id=v_header.business_id;
  update public.loyalty_programs set kind=v_typed.kind,loyalty_model=v_typed.loyalty_model,active=v_typed.active,earn_points_per_dollar=v_typed.earn_points_per_dollar,redeem_points=v_typed.redeem_points,reward_credit_cents=v_typed.reward_credit_cents,stamp_target=v_typed.stamp_target,stamp_per_cents=v_typed.stamp_per_cents,tier_basis=v_typed.tier_basis,expiry_mode=v_typed.expiry_mode,expiry_days=v_typed.expiry_days,configuration_status='published',current_config_version_id=p_version where business_id=v_header.business_id;
  update public.loyalty_rewards r set name=rv.customer_name,internal_name=rv.internal_name,customer_name=rv.customer_name,description=rv.description,fulfillment_kind=rv.fulfillment_kind,taxonomy_label=rv.taxonomy_label,cost_points=rv.cost_points,credit_cents=rv.credit_cents,estimated_cost_cents=rv.estimated_cost_cents,active=rv.active,sort=rv.sort,claim_available_from=rv.claim_available_from,claim_available_until=rv.claim_available_until,entitlement_expiry_days=rv.entitlement_expiry_days,instructions=rv.instructions,terms=rv.terms,image_ref=rv.image_ref,usage_limit=rv.usage_limit,current_config_version_id=p_version from public.loyalty_reward_versions rv where rv.reward_id=r.id and rv.business_id=r.business_id and rv.config_version_id=p_version;
  delete from public.loyalty_tiers where business_id=v_header.business_id;
  insert into public.loyalty_tiers(id,business_id,name,threshold,points_multiplier,perk_note,sort) select tier_id,business_id,name,threshold,points_multiplier,perk_note,sort from public.loyalty_tier_versions where config_version_id=p_version and business_id=v_header.business_id and active;
  update public.retention_programs rp set name=rv.name,active=rv.active,goal_visits=rv.goal_visits,period_days=rv.period_days,starts_on=rv.starts_on,reward_taxonomy_id=rv.reward_taxonomy_id,reward_type=rv.fulfillment_kind,reward_value=coalesce(rv.discount_percent,rv.credit_cents,0),reward_item=rv.manual_item,current_config_version_id=p_version from public.retention_program_versions rv where rv.program_id=rp.id and rv.business_id=rp.business_id and rv.config_version_id=p_version and rp.business_id=v_header.business_id;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_header.business_id,auth.uid(),'PUBLISH_CONFIG','firm_config_versions',p_version,jsonb_build_object('prior_version_id',v_prior,'new_version_id',p_version,'snapshot_hash',v_header.snapshot_hash,'birthday_program_count',(select count(*) from public.birthday_program_versions where config_version_id=p_version)));
  return json_build_object('version_id',p_version,'version_no',v_header.version_no,'status','published');
end $$;

-- -------------------------------------------------------------------------
-- Customer consent, read, activation, and staff counter flows
-- -------------------------------------------------------------------------

create or replace function public.customer_set_birthday_participation(
  p_opted_in boolean,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_identity uuid; v_request_hash text; v_operation public.customer_birthday_participation_operations%rowtype;
begin
  if auth.uid() is null then raise exception 'authenticated customer session required' using errcode='28000'; end if;
  if not app.platform_feature_enabled('customer_birthday_benefits') then raise exception 'birthday benefits are unavailable' using errcode='0A000'; end if;
  if p_opted_in is null then raise exception 'birthday participation request is invalid' using errcode='22023'; end if;
  select id into v_identity from public.customer_identities where auth_user_id=auth.uid() and status='active' for update;
  if not found or p_idempotency_key is null then raise exception 'birthday benefits are unavailable' using errcode='42501'; end if;
  v_request_hash:=app.c45_hash(jsonb_build_object('opted_in',p_opted_in)::text);
  select * into v_operation from public.customer_birthday_participation_operations where identity_id=v_identity and idempotency_key=p_idempotency_key for share;
  if found then
    if v_operation.request_hash is distinct from v_request_hash then raise exception 'birthday participation request conflicts with an existing operation' using errcode='40001'; end if;
    return jsonb_build_object('opted_in',v_operation.opted_in,'replayed',true);
  end if;
  insert into public.customer_birthday_participation(identity_id,auth_user_id,opted_in,updated_at)
  values(v_identity,auth.uid(),p_opted_in,now())
  on conflict(identity_id) do update set opted_in=excluded.opted_in,updated_at=excluded.updated_at;
  insert into public.customer_birthday_participation_operations(identity_id,actor_auth_user_id,idempotency_key,request_hash,opted_in)
  values(v_identity,auth.uid(),p_idempotency_key,v_request_hash,p_opted_in);
  return jsonb_build_object('opted_in',p_opted_in,'replayed',false);
end $$;

create or replace function public.customer_get_birthday_participation()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_identity uuid; v_opted_in boolean := false;
begin
  if auth.uid() is null then raise exception 'authenticated customer session required' using errcode='28000'; end if;
  if not app.platform_feature_enabled('customer_birthday_benefits') then
    raise exception 'birthday benefits are unavailable' using errcode='0A000';
  end if;
  select id into v_identity from public.customer_identities
   where auth_user_id=auth.uid() and status='active';
  if not found then raise exception 'birthday benefits are unavailable' using errcode='42501'; end if;
  select coalesce(p.opted_in,false) into v_opted_in
    from (select 1) one left join public.customer_birthday_participation p on p.identity_id=v_identity;
  return jsonb_build_object('opted_in',coalesce(v_opted_in,false));
end $$;

create or replace function public.customer_get_birthday_benefit(p_business_slug text)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_context record; v_benefit jsonb;
begin
  select * into v_context from app.c45_customer_birthday_context(p_business_slug) limit 1;
  select app.c45_customer_birthday_benefit_for_context(
    v_context.business_id,v_context.client_id,v_context.identity_id,v_context.birth_date,statement_timestamp()
  ) into v_benefit;
  return coalesce(v_benefit, jsonb_build_object('status','unavailable'));
end $$;

create or replace function public.customer_activate_birthday_benefit(
  p_business_slug text,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record; v_as_of timestamptz:=statement_timestamp(); v_program public.birthday_program_versions%rowtype;
  v_window record; v_entitlement public.customer_birthday_entitlements%rowtype;
  v_op public.customer_birthday_activation_operations%rowtype; v_request_hash text;
begin
  select * into v_context from app.c45_customer_birthday_context(p_business_slug) limit 1;
  if p_idempotency_key is null then raise exception 'birthday benefits are unavailable' using errcode='22023'; end if;
  v_request_hash:=app.c45_hash(jsonb_build_object('business_slug',lower(btrim(p_business_slug)))::text);
  select * into v_op from public.customer_birthday_activation_operations
   where identity_id=v_context.identity_id and business_id=v_context.business_id and idempotency_key=p_idempotency_key for share;
  if found then
    if v_op.request_hash is distinct from v_request_hash then raise exception 'birthday activation conflicts with an existing operation' using errcode='40001'; end if;
    select * into v_entitlement from public.customer_birthday_entitlements where id=v_op.entitlement_id;
    return app.c45_safe_birthday_entitlement(v_entitlement,v_as_of);
  end if;
  if not exists(select 1 from public.customer_birthday_participation p where p.identity_id=v_context.identity_id and p.auth_user_id=auth.uid() and p.opted_in) then
    raise exception 'birthday benefits are unavailable' using errcode='42501';
  end if;
  select bpv.* into v_program from public.businesses b
   join public.loyalty_program_versions lpv on lpv.config_version_id=b.active_config_version_id and lpv.business_id=b.id and lpv.active
   join public.birthday_program_versions bpv on bpv.config_version_id=b.active_config_version_id and bpv.business_id=b.id and bpv.active
   where b.id=v_context.business_id and 'loyalty'=any(coalesce(b.enabled_modules,'{}'::text[]))
   order by bpv.sort,bpv.program_id limit 1 for update of bpv;
  if not found then raise exception 'birthday benefits are unavailable' using errcode='42501'; end if;
  select * into v_window from app.c45_birthday_window(v_context.birth_date,v_program.window_days_before,v_program.window_days_after,v_as_of);
  if not found then raise exception 'birthday benefits are unavailable' using errcode='42501'; end if;
  select * into v_entitlement from public.customer_birthday_entitlements
   where business_id=v_context.business_id and client_id=v_context.client_id and birthday_year=v_window.birthday_year for update;
  if found then
    insert into public.customer_birthday_activation_operations(identity_id,business_id,client_id,idempotency_key,request_hash,entitlement_id)
    values(v_context.identity_id,v_context.business_id,v_context.client_id,p_idempotency_key,v_request_hash,v_entitlement.id);
    return app.c45_safe_birthday_entitlement(v_entitlement,v_as_of);
  end if;
  insert into public.customer_birthday_entitlements(
    business_id,client_id,identity_id,config_version_id,birthday_program_version_id,birthday_year,
    status,valid_from,valid_until,benefit_snapshot
  ) values(
    v_context.business_id,v_context.client_id,v_context.identity_id,v_program.config_version_id,v_program.id,v_window.birthday_year,
    'available',v_window.valid_from,v_window.valid_until,app.c45_benefit_snapshot(v_program)
  ) returning * into v_entitlement;
  insert into public.customer_birthday_activation_operations(identity_id,business_id,client_id,idempotency_key,request_hash,entitlement_id)
  values(v_context.identity_id,v_context.business_id,v_context.client_id,p_idempotency_key,v_request_hash,v_entitlement.id);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_context.business_id,auth.uid(),'ACTIVATE_BIRTHDAY_BENEFIT','customer_birthday_entitlements',v_entitlement.id,jsonb_build_object('status','available'));
  return app.c45_safe_birthday_entitlement(v_entitlement,v_as_of);
exception when unique_violation then
  -- The per-customer/year uniqueness is the re-publish and concurrent-activate
  -- backstop. A caller retries through the same idempotency key for the exact
  -- immutable promise; changed inputs fail through the hash check above.
  select * into v_entitlement from public.customer_birthday_entitlements
   where business_id=v_context.business_id and client_id=v_context.client_id and birthday_year=v_window.birthday_year;
  if v_entitlement.id is null then raise; end if;
  insert into public.customer_birthday_activation_operations(identity_id,business_id,client_id,idempotency_key,request_hash,entitlement_id)
  values(v_context.identity_id,v_context.business_id,v_context.client_id,p_idempotency_key,v_request_hash,v_entitlement.id)
  on conflict (identity_id,business_id,idempotency_key) do nothing;
  return app.c45_safe_birthday_entitlement(v_entitlement,v_as_of);
end $$;

create or replace function app.c45_entitlement_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op='INSERT' then return new; end if;
  if tg_op='DELETE' or current_setting('app.c45_entitlement_id',true) is distinct from old.id::text
     or (new.business_id,new.client_id,new.identity_id,new.config_version_id,new.birthday_program_version_id,
         new.birthday_year,new.valid_from,new.valid_until,new.benefit_snapshot,new.activated_at)
       is distinct from
        (old.business_id,old.client_id,old.identity_id,old.config_version_id,old.birthday_program_version_id,
         old.birthday_year,old.valid_from,old.valid_until,old.benefit_snapshot,old.activated_at)
     or new.status not in ('available','redeemed','expired') then
    raise exception 'birthday entitlement provenance is immutable' using errcode='23001';
  end if;
  new.updated_at:=now(); return new;
end $$;

create or replace function app.c45_append_only_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception '% is append-only evidence', tg_table_name using errcode='23000';
end $$;
create trigger trg_c45_birthday_participation_operations_immutable
  before update or delete on public.customer_birthday_participation_operations
  for each row execute function app.c45_append_only_guard();
create trigger trg_c45_birthday_draft_operations_immutable
  before update or delete on public.birthday_program_draft_operations
  for each row execute function app.c45_append_only_guard();
create trigger trg_c45_birthday_activation_operations_immutable
  before update or delete on public.customer_birthday_activation_operations
  for each row execute function app.c45_append_only_guard();

create trigger trg_c45_entitlement_guard before update or delete on public.customer_birthday_entitlements
for each row execute function app.c45_entitlement_guard();

create or replace function app.c45_redemption_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op='INSERT' then return new; end if;
  if tg_op='DELETE' or current_setting('app.c45_redemption_id',true) is distinct from old.id::text
     or (new.id,new.entitlement_id,new.business_id,new.client_id,new.branch_id,new.actor,new.operation_kind,
         new.original_redemption_id,new.idempotency_key,new.request_hash,new.reason,new.created_at)
       is distinct from
        (old.id,old.entitlement_id,old.business_id,old.client_id,old.branch_id,old.actor,old.operation_kind,
         old.original_redemption_id,old.idempotency_key,old.request_hash,old.reason,old.created_at) then
    raise exception 'birthday redemption provenance is immutable' using errcode='23001';
  end if;
  return new;
end $$;
create trigger trg_c45_redemption_guard before update or delete on public.customer_birthday_redemptions
for each row execute function app.c45_redemption_guard();

-- Counter-facing reader. It takes only the staff-selected tenant/client scope
-- and returns the same benefit-safe fields as the customer reader—never DOB,
-- age, observed date, birthday year, or internal entitlement/program IDs.
create or replace function public.staff_get_customer_birthday_benefit(
  p_business_id uuid,
  p_client_id uuid
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_entitlement public.customer_birthday_entitlements%rowtype;
begin
  if not app.platform_feature_enabled('customer_birthday_benefits') then
    raise exception 'birthday benefit unavailable' using errcode='0A000';
  end if;
  if auth.uid() is null or not app.can_module_read(p_business_id,'loyalty')
     or not exists(select 1 from public.clients c where c.id=p_client_id and c.business_id=p_business_id) then
    raise exception 'birthday benefit unavailable' using errcode='42501';
  end if;
  select * into v_entitlement from public.customer_birthday_entitlements
   where business_id=p_business_id and client_id=p_client_id
   order by valid_until desc,activated_at desc limit 1;
  if not found then return jsonb_build_object('status','unavailable'); end if;
  return app.c45_staff_safe_birthday_entitlement(v_entitlement,statement_timestamp());
end $$;

create or replace function public.redeem_customer_birthday_benefit(
  p_business_id uuid,
  p_client_id uuid,
  p_branch_id uuid,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_entitlement public.customer_birthday_entitlements%rowtype; v_staff uuid;
  v_existing public.customer_birthday_redemptions%rowtype; v_redemption public.customer_birthday_redemptions%rowtype;
  v_hash text; v_as_of timestamptz:=statement_timestamp();
begin
  if not app.platform_feature_enabled('customer_birthday_benefits') then
    raise exception 'birthday benefit unavailable' using errcode='0A000';
  end if;
  -- The counter selects its own tenant-scoped client record. Customer-safe
  -- wallet JSON never carries an entitlement UUID to a browser.
  if auth.uid() is null or not app.can_module_write(p_business_id,'loyalty')
     or not exists(select 1 from public.clients c where c.id=p_client_id and c.business_id=p_business_id) then
    raise exception 'birthday benefit unavailable' using errcode='42501'; end if;
  select s.id into v_staff from public.staff s where s.business_id=p_business_id and s.user_id=auth.uid() and s.active
    order by case when s.role='owner' then 0 else 1 end,s.created_at limit 1 for update;
  if not found or p_branch_id is null or not exists(select 1 from public.staff_branches sb where sb.business_id=p_business_id and sb.staff_id=v_staff and sb.branch_id=p_branch_id) then
    raise exception 'birthday benefit unavailable' using errcode='42501'; end if;
  if p_idempotency_key is null then raise exception 'birthday benefit unavailable' using errcode='22023'; end if;
  v_hash:=app.c45_hash(jsonb_build_object('business_id',p_business_id,'client_id',p_client_id,'branch_id',p_branch_id)::text);
  select * into v_existing from public.customer_birthday_redemptions
   where business_id=p_business_id and client_id=p_client_id and actor=auth.uid() and operation_kind='redemption' and idempotency_key=p_idempotency_key for share;
  if found then
    if v_existing.request_hash is distinct from v_hash then raise exception 'birthday redemption conflicts with an existing operation' using errcode='40001'; end if;
    return jsonb_build_object('status','redeemed','replayed',true);
  end if;
  select * into v_entitlement from public.customer_birthday_entitlements
   where business_id=p_business_id and client_id=p_client_id
   order by valid_until desc,activated_at desc limit 1 for update;
  if not found then raise exception 'birthday benefit unavailable' using errcode='42501'; end if;
  -- The first lookup can legitimately miss a same-key request that commits
  -- while this session waits on the entitlement lock. Re-check after the lock
  -- and return the exact replay before evaluating the redeemed state.
  select * into v_existing from public.customer_birthday_redemptions
   where business_id=p_business_id and client_id=p_client_id and actor=auth.uid()
     and operation_kind='redemption' and idempotency_key=p_idempotency_key for share;
  if found then
    if v_existing.request_hash is distinct from v_hash then
      raise exception 'birthday redemption conflicts with an existing operation' using errcode='40001';
    end if;
    return jsonb_build_object('status','redeemed','replayed',true);
  end if;
  if v_entitlement.status<>'available' or v_entitlement.valid_from>v_as_of or v_entitlement.valid_until<=v_as_of then
    -- A different key racing with the successful redemption must be a clear
    -- optimistic conflict, never a misleading generic unavailability error.
    if exists(select 1 from public.customer_birthday_redemptions r
                where r.entitlement_id=v_entitlement.id and r.operation_kind='redemption' and r.active) then
      raise exception 'birthday redemption conflicts with an existing operation' using errcode='40001';
    end if;
    raise exception 'birthday benefit unavailable' using errcode='42501';
  end if;
  insert into public.customer_birthday_redemptions(entitlement_id,business_id,client_id,branch_id,actor,operation_kind,idempotency_key,request_hash)
  values(v_entitlement.id,v_entitlement.business_id,v_entitlement.client_id,p_branch_id,auth.uid(),'redemption',p_idempotency_key,v_hash)
  returning * into v_redemption;
  perform set_config('app.c45_entitlement_id',v_entitlement.id::text,true);
  update public.customer_birthday_entitlements set status='redeemed' where id=v_entitlement.id;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_entitlement.business_id,auth.uid(),'REDEEM_BIRTHDAY_BENEFIT','customer_birthday_redemptions',v_redemption.id,jsonb_build_object('status','redeemed'));
  return jsonb_build_object('status','redeemed','replayed',false);
exception when unique_violation then
  select * into v_existing from public.customer_birthday_redemptions
   where business_id=p_business_id and client_id=p_client_id and actor=auth.uid()
     and operation_kind='redemption' and idempotency_key=p_idempotency_key;
  if found and v_existing.request_hash = v_hash then
    return jsonb_build_object('status','redeemed','replayed',true);
  end if;
  raise exception 'birthday redemption conflicts with an existing operation' using errcode='40001';
end $$;

create or replace function app.reverse_customer_birthday_benefit_redemption(
  p_redemption_id uuid,
  p_reason text,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_original public.customer_birthday_redemptions%rowtype; v_entitlement public.customer_birthday_entitlements%rowtype;
  v_existing public.customer_birthday_redemptions%rowtype; v_reversal public.customer_birthday_redemptions%rowtype;
  v_reason text:=nullif(btrim(p_reason),''); v_hash text; v_as_of timestamptz:=statement_timestamp();
begin
  if not app.platform_feature_enabled('customer_birthday_benefits') then
    raise exception 'birthday benefit unavailable' using errcode='0A000';
  end if;
  select * into v_original from public.customer_birthday_redemptions where id=p_redemption_id for update;
  if not found or v_original.operation_kind<>'redemption' then raise exception 'birthday benefit unavailable' using errcode='42501'; end if;
  if auth.uid() is null or not app.c45_owner_loyalty_write(v_original.business_id) then raise exception 'owner loyalty reversal authorization is required' using errcode='42501'; end if;
  if p_idempotency_key is null or v_reason is null or length(v_reason)<3 or length(v_reason)>500 then raise exception 'a reversal reason is required' using errcode='22023'; end if;
  v_hash:=app.c45_hash(jsonb_build_object('redemption_id',p_redemption_id,'reason',v_reason)::text);
  select * into v_existing from public.customer_birthday_redemptions
   where original_redemption_id=p_redemption_id and actor=auth.uid() and operation_kind='reversal' and idempotency_key=p_idempotency_key for share;
  if found then
    if v_existing.request_hash is distinct from v_hash then raise exception 'birthday reversal conflicts with an existing operation' using errcode='40001'; end if;
    return jsonb_build_object('status','reversed','replayed',true);
  end if;
  if not v_original.active then raise exception 'birthday benefit unavailable' using errcode='42501'; end if;
  select * into v_entitlement from public.customer_birthday_entitlements where id=v_original.entitlement_id for update;
  perform set_config('app.c45_redemption_id',v_original.id::text,true);
  update public.customer_birthday_redemptions set active=false where id=v_original.id;
  insert into public.customer_birthday_redemptions(entitlement_id,business_id,client_id,branch_id,actor,operation_kind,original_redemption_id,idempotency_key,request_hash,reason)
  values(v_entitlement.id,v_entitlement.business_id,v_entitlement.client_id,v_original.branch_id,auth.uid(),'reversal',v_original.id,p_idempotency_key,v_hash,v_reason)
  returning * into v_reversal;
  perform set_config('app.c45_entitlement_id',v_entitlement.id::text,true);
  -- Expiry is an effective projection of the immutable end instant, never a
  -- state write hidden inside a failed redemption. A successful reversal only
  -- restores the underlying available state; readers derive expired if needed.
  update public.customer_birthday_entitlements set status='available' where id=v_entitlement.id;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_original.business_id,auth.uid(),'REVERSE_BIRTHDAY_BENEFIT_REDEMPTION','customer_birthday_redemptions',v_reversal.id,jsonb_build_object('reason',v_reason,'compensates_redemption_id',v_original.id));
  return jsonb_build_object('status','reversed','replayed',false);
end $$;

-- The browser never receives a redemption UUID. An active authorized owner
-- reverses only the live redemption in the selected business/client scope;
-- the lower-level UUID RPC remains an internal service seam for audited jobs.
create or replace function public.reverse_customer_birthday_benefit_for_client(
  p_business_id uuid,
  p_client_id uuid,
  p_reason text,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_redemption_id uuid;
begin
  if not app.platform_feature_enabled('customer_birthday_benefits') then
    raise exception 'birthday benefit unavailable' using errcode='0A000';
  end if;
  if auth.uid() is null or not app.c45_owner_loyalty_write(p_business_id)
     or not exists(select 1 from public.clients c where c.id=p_client_id and c.business_id=p_business_id) then
    raise exception 'birthday benefit unavailable' using errcode='42501';
  end if;
  -- Preserve an exact retry even after the original redemption is no longer
  -- live. The underlying reversal RPC compares the reason hash and rejects a
  -- changed request with 40001.
  select original_redemption_id into v_redemption_id
    from public.customer_birthday_redemptions
   where business_id=p_business_id and client_id=p_client_id and actor=auth.uid()
     and operation_kind='reversal' and idempotency_key=p_idempotency_key
   order by created_at desc,id desc
   limit 1 for share;
  if found then
    return app.reverse_customer_birthday_benefit_redemption(v_redemption_id,p_reason,p_idempotency_key);
  end if;
  select id into v_redemption_id
    from public.customer_birthday_redemptions
   where business_id=p_business_id and client_id=p_client_id
     and operation_kind='redemption' and active
   order by created_at desc,id desc
   limit 1 for update;
  if not found then
    -- A same-key concurrent reversal can commit while this statement waits on
    -- the active-redemption row and therefore leaves no active row to return.
    -- Resolve that exact replay before reporting unavailability.
    select original_redemption_id into v_redemption_id
      from public.customer_birthday_redemptions
     where business_id=p_business_id and client_id=p_client_id and actor=auth.uid()
       and operation_kind='reversal' and idempotency_key=p_idempotency_key
     order by created_at desc,id desc limit 1 for share;
    if not found then raise exception 'birthday benefit unavailable' using errcode='42501'; end if;
  end if;
  return app.reverse_customer_birthday_benefit_redemption(v_redemption_id,p_reason,p_idempotency_key);
end $$;

-- -------------------------------------------------------------------------
-- C44 forward extension. The original source is not edited. Birthday cards
-- use the same all-cards rank -> top 100 + 101st truncation path; no lexical
-- pre-limit is introduced.
-- -------------------------------------------------------------------------

alter function app.c44_actionable_wallet_card(uuid, uuid, text, text, text, text, text[], timestamptz)
  rename to c45_base_actionable_wallet_card;

create or replace function app.c44_actionable_wallet_card(
  p_business_id uuid, p_client_id uuid, p_business_slug text, p_business_name text,
  p_business_industry text, p_business_currency text, p_enabled_modules text[], p_as_of timestamptz
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_base jsonb; v_context record; v_birthday jsonb; v_base_band integer; v_birthday_band integer;
  v_base_deadline timestamptz; v_birthday_deadline timestamptz; v_base_units integer;
begin
  select app.c45_base_actionable_wallet_card(p_business_id,p_client_id,p_business_slug,p_business_name,p_business_industry,p_business_currency,p_enabled_modules,p_as_of) into v_base;
  if not app.platform_feature_enabled('customer_birthday_benefits') then return v_base || jsonb_build_object('birthday_benefit',null); end if;
  select ci.id,cp.birth_date into v_context
    from public.customer_identities ci
    join public.customer_links cl on cl.identity_id=ci.id and cl.business_id=p_business_id and cl.client_id=p_client_id and cl.auth_user_id=auth.uid() and cl.state='verified'
    join public.customer_profiles cp on cp.identity_id=ci.id and cp.auth_user_id=auth.uid()
   where ci.auth_user_id=auth.uid() and ci.status='active' limit 1;
  if not found then return v_base || jsonb_build_object('birthday_benefit',null); end if;
  select app.c45_customer_birthday_benefit_for_context(p_business_id,p_client_id,v_context.id,v_context.birth_date,p_as_of) into v_birthday;
  if v_birthday is null then return v_base || jsonb_build_object('birthday_benefit',null); end if;
  -- Redeemed/expired entries remain visible as history, but never outrank an
  -- actionable wallet card. Only the customer-safe CTA states can rank.
  if v_birthday->>'status' not in ('ready_to_activate','available')
     or coalesce(v_birthday->>'cta','') not in ('activate','show_at_counter')
     or nullif(v_birthday#>>'{validity,available_until}','') is null
     or (v_birthday#>>'{validity,available_until}')::timestamptz <= p_as_of then
    return v_base || jsonb_build_object('birthday_benefit',v_birthday);
  end if;
  v_base_band:=coalesce((v_base#>>'{action,sort_band}')::integer,6);
  v_base_deadline:=nullif(v_base#>>'{action,deadline_at}','')::timestamptz;
  v_base_units:=coalesce((v_base#>>'{action,sort_units}')::integer,0);
  v_birthday_deadline:=(v_birthday#>>'{validity,available_until}')::timestamptz;
  v_birthday_band:=case when (v_birthday#>>'{validity,available_until}')::timestamptz<=p_as_of+interval '7 days' then 1 else 2 end;
  if v_birthday_band < v_base_band
     or (v_birthday_band = v_base_band and (v_base_deadline is null or v_birthday_deadline < v_base_deadline))
     or (v_birthday_band = v_base_band and v_birthday_deadline = v_base_deadline and 0 < v_base_units) then
    v_base:=v_base || jsonb_build_object('action',jsonb_build_object(
      'reason',case when v_birthday_band=1 then 'birthday_benefit_expiring_within_7_days' else 'birthday_benefit_available' end,
      'deadline_at',v_birthday#>>'{validity,available_until}',
      'sort_band',v_birthday_band,'sort_units',0
    ));
  end if;
  return v_base || jsonb_build_object('birthday_benefit',v_birthday);
end $$;

create or replace function public.get_customer_feature_capabilities()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null then raise exception 'authenticated session required' using errcode='28000'; end if;
  return jsonb_build_object(
    'customer_identity',app.platform_feature_enabled('customer_identity'),
    'customer_claims',app.platform_feature_enabled('customer_claims'),
    'customer_wallet',app.platform_feature_enabled('customer_wallet'),
    'customer_actions',app.platform_feature_enabled('customer_actions'),
    'customer_notifications',app.platform_feature_enabled('customer_notifications'),
    'customer_email_otp',app.platform_feature_enabled('customer_email_otp'),
    'customer_phone_otp',app.platform_feature_enabled('customer_phone_otp'),
    'customer_whatsapp_otp',app.platform_feature_enabled('customer_whatsapp_otp'),
    'customer_phone_registration',app.platform_feature_enabled('customer_phone_registration'),
    'customer_phone_claims',app.platform_feature_enabled('customer_phone_claims'),
    'customer_actionable_wallet',app.platform_feature_enabled('customer_actionable_wallet'),
    'customer_birthday_benefits',app.platform_feature_enabled('customer_birthday_benefits')
  );
end $$;

-- Exact public/app ACLs: RPCs only, never raw table or helper access.
revoke all on function app.c45_hash(text) from public, anon, authenticated;
revoke all on function app.c45_owner_loyalty_write(uuid) from public, anon, authenticated;
revoke all on function app.c45_observed_birthday(date,integer) from public, anon, authenticated;
revoke all on function app.c45_birthday_window(date,integer,integer,timestamptz) from public, anon, authenticated;
revoke all on function app.c45_benefit_snapshot(public.birthday_program_versions) from public, anon, authenticated;
revoke all on function app.c45_safe_birthday_entitlement(public.customer_birthday_entitlements,timestamptz,text) from public, anon, authenticated;
revoke all on function app.c45_staff_safe_birthday_entitlement(public.customer_birthday_entitlements,timestamptz,text) from public, anon, authenticated;
revoke all on function app.c45_customer_birthday_context(text) from public, anon, authenticated;
revoke all on function app.c45_customer_birthday_benefit_for_context(uuid,uuid,uuid,date,timestamptz) from public, anon, authenticated;
revoke all on function app.c45_birthday_program_version_guard() from public, anon, authenticated;
revoke all on function app.c45_clone_birthday_programs_on_draft() from public, anon, authenticated;
revoke all on function app.c45_birthday_snapshot_trigger() from public, anon, authenticated;
revoke all on function app.c45_entitlement_guard() from public, anon, authenticated;
revoke all on function app.c45_append_only_guard() from public, anon, authenticated;
revoke all on function app.c45_redemption_guard() from public, anon, authenticated;
revoke all on function app.reverse_customer_birthday_benefit_redemption(uuid,text,uuid) from public, anon, authenticated;
revoke all on function app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamptz) from public, anon, authenticated;
revoke all on function app.c44_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamptz) from public, anon, authenticated;
revoke all on function public.get_birthday_program_draft(uuid) from public, anon;
revoke all on function public.get_active_birthday_program(uuid) from public, anon;
revoke all on function public.save_birthday_program_draft(uuid,uuid,jsonb,text) from public, anon;
revoke all on function public.customer_set_birthday_participation(boolean,uuid) from public, anon;
revoke all on function public.customer_get_birthday_participation() from public, anon;
revoke all on function public.customer_get_birthday_benefit(text) from public, anon;
revoke all on function public.customer_activate_birthday_benefit(text,uuid) from public, anon;
revoke all on function public.staff_get_customer_birthday_benefit(uuid,uuid) from public, anon;
revoke all on function public.redeem_customer_birthday_benefit(uuid,uuid,uuid,uuid) from public, anon;
revoke all on function public.reverse_customer_birthday_benefit_for_client(uuid,uuid,text,uuid) from public, anon;
revoke all on function public.get_customer_feature_capabilities() from public, anon;
grant execute on function public.get_birthday_program_draft(uuid) to authenticated;
grant execute on function public.get_active_birthday_program(uuid) to authenticated;
grant execute on function public.save_birthday_program_draft(uuid,uuid,jsonb,text) to authenticated;
grant execute on function public.customer_set_birthday_participation(boolean,uuid) to authenticated;
grant execute on function public.customer_get_birthday_participation() to authenticated;
grant execute on function public.customer_get_birthday_benefit(text) to authenticated;
grant execute on function public.customer_activate_birthday_benefit(text,uuid) to authenticated;
grant execute on function public.staff_get_customer_birthday_benefit(uuid,uuid) to authenticated;
grant execute on function public.redeem_customer_birthday_benefit(uuid,uuid,uuid,uuid) to authenticated;
grant execute on function public.reverse_customer_birthday_benefit_for_client(uuid,uuid,text,uuid) to authenticated;
grant execute on function public.get_customer_feature_capabilities() to authenticated;
revoke all on function public.publish_loyalty_config(uuid) from public, anon;
grant execute on function public.publish_loyalty_config(uuid) to authenticated;
revoke all on function public.create_loyalty_config_draft(uuid,uuid,text) from public, anon;
grant execute on function public.create_loyalty_config_draft(uuid,uuid,text) to authenticated;

commit;
