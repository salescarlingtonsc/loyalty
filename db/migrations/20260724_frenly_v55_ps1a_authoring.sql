-- FRENLY v55 - PROGRAM STUDIO PS-1A: AUTHORING, PROJECTION & VALIDATION ONLY
--
-- Local review candidate. Do not apply until the phase release gate is accepted
-- (CLAUDE.md standing gate: production apply needs the owner's RELEASE APPROVED
-- phrase). PS-1A is authorized for SCHEMA LANDING per docs/design/ps0/PS-GATES.md
-- (owner approval 2026-07-23, F2 PASS precondition met).
--
-- Scope guardrails (owner letter; enforced by tests/program-studio/ps0-no-executor):
--   * NO executor of any kind. This migration AUTHORS, PROJECTS and VALIDATES.
--   * It moves NO customer value: no ledger writes, no grants, no discounts, no
--     tier-entry grants, no fulfilment rows, no comms. Every effect TYPE may be
--     AUTHORED into a rule, but nothing here executes any effect.
--   * benefit_registry is METADATA ONLY. No authority flips (append-only guard).
--   * Adapter is a read-only PROJECTION over live engine config (zero copied
--     rows, zero new storage).
--
-- Mirrors the established config-spine patterns: version-scoping under
-- firm_config_versions, the v37b clone-on-draft trigger, the v37b/c45
-- publish_loyalty_config extension, and the save_retention_program_draft
-- snapshot-hash optimistic-concurrency contract.

begin;

-- =====================================================================
-- 0. Deterministic sha256 helper (mirrors app.c45_hash, v45:1298)
-- =====================================================================
create or replace function app.ps1a_sha256(p_value text)
returns text language sql immutable strict
set search_path to 'pg_catalog', 'extensions', 'pg_temp'
as $$ select encode(extensions.digest(convert_to(p_value, 'UTF8'), 'sha256'), 'hex') $$;
revoke all on function app.ps1a_sha256(text) from public, anon, authenticated;

-- =====================================================================
-- 1. rule_schema_versions - the payload-schema registry (ARCH §8)
-- =====================================================================
create table public.rule_schema_versions (
  schema_version smallint primary key check (schema_version >= 1),
  status text not null check (status in ('active', 'deprecated')),
  notes text check (notes is null or char_length(notes) <= 2000),
  created_at timestamptz not null default now()
);
insert into public.rule_schema_versions(schema_version, status, notes)
values (1, 'active', 'PS-1A initial studio rule payload vocabulary');

alter table public.rule_schema_versions enable row level security;
create policy rule_schema_versions_read on public.rule_schema_versions
  for select to authenticated using (true);
revoke all on public.rule_schema_versions from public, anon, authenticated;
grant select on public.rule_schema_versions to authenticated;

-- =====================================================================
-- 2. Allowlist-as-data: per event_type condition fields+operators, and
--    permitted effect types (ARCH §8 "allowlists as data"). Seeded from
--    the §8 vocabulary, restricted to what PS-1A can truthfully author.
--    Every effect type may be AUTHORED; none executes in PS-1A.
-- =====================================================================
create table public.rule_condition_allowlist (
  id uuid primary key default gen_random_uuid(),
  schema_version smallint not null references public.rule_schema_versions(schema_version),
  event_type text not null,
  field text not null,
  value_type text not null check (value_type in
    ('integer', 'numeric', 'text', 'boolean', 'catalog_ref')),
  operators text[] not null check (array_length(operators, 1) between 1 and 12),
  catalog_kind text check (catalog_kind is null or catalog_kind in
    ('service', 'product', 'branch', 'staff', 'reward', 'tier', 'membership_plan')),
  constraint rule_condition_allowlist_uk unique (schema_version, event_type, field),
  constraint rule_condition_allowlist_catalog_check check (
    (value_type = 'catalog_ref' and catalog_kind is not null)
    or (value_type <> 'catalog_ref' and catalog_kind is null)
  )
);

create table public.rule_effect_allowlist (
  id uuid primary key default gen_random_uuid(),
  schema_version smallint not null references public.rule_schema_versions(schema_version),
  event_type text not null,
  effect_type text not null,
  requires_catalog_ref boolean not null default false,
  catalog_kind text check (catalog_kind is null or catalog_kind in
    ('service', 'product', 'branch', 'staff', 'reward', 'tier', 'membership_plan')),
  -- moves_value flags whether the effect would move/promise customer value when
  -- an executor eventually exists. PS-1A executes NONE of these.
  moves_value boolean not null default false,
  constraint rule_effect_allowlist_uk unique (schema_version, event_type, effect_type)
);

-- Condition vocabulary (schema_version 1).
insert into public.rule_condition_allowlist(schema_version, event_type, field, value_type, operators, catalog_kind) values
  (1, 'sale.completed',     'amount_cents',     'integer',     array['eq','neq','gt','gte','lt','lte','between'], null),
  (1, 'sale.completed',     'kind',             'text',        array['eq','neq','in','not_in'],                   null),
  (1, 'sale.completed',     'branch_id',        'catalog_ref', array['eq','in'],                                  'branch'),
  (1, 'sale.completed',     'staff_id',         'catalog_ref', array['eq','in'],                                  'staff'),
  (1, 'sale.completed',     'counts_as_visit',  'boolean',     array['eq'],                                       null),
  (1, 'sale.completed',     'earns_points',     'boolean',     array['eq'],                                       null),
  (1, 'points.redeemed',    'reward_id',        'catalog_ref', array['eq','in'],                                  'reward'),
  (1, 'points.redeemed',    'points_spent',     'integer',     array['eq','gt','gte','lt','lte','between'],        null),
  (1, 'points.redeemed',    'credit_cents',     'integer',     array['eq','gte','lte'],                            null),
  (1, 'birthday.activated', 'birthday_year',    'integer',     array['eq','gte','lte'],                            null),
  (1, 'birthday.activated', 'fulfillment_kind', 'text',        array['eq','in'],                                   null),
  (1, 'referral.qualified', 'reward_cents',     'integer',     array['eq','gte','lte'],                            null),
  (1, 'membership.renewed', 'plan_id',          'catalog_ref', array['eq','in'],                                  'membership_plan'),
  (1, 'membership.renewed', 'credit_cents',     'integer',     array['eq','gte','lte'],                            null);

-- Effect vocabulary (schema_version 1). moves_value is descriptive only.
insert into public.rule_effect_allowlist(schema_version, event_type, effect_type, requires_catalog_ref, catalog_kind, moves_value) values
  (1, 'sale.completed',     'earn_bonus_points',     false, null, true),
  (1, 'sale.completed',     'earn_bonus_stamps',     false, null, true),
  (1, 'sale.completed',     'grant_credit',          false, null, true),
  (1, 'sale.completed',     'apply_discount_pct',    false, null, true),
  (1, 'sale.completed',     'apply_discount_amount', false, null, true),
  (1, 'sale.completed',     'grant_free_item',       true,  null, true),
  (1, 'sale.completed',     'tier_multiplier',       false, null, true),
  (1, 'sale.completed',     'display_perk',          false, null, false),
  (1, 'sale.completed',     'send_notification',     false, null, false),
  (1, 'points.redeemed',    'grant_credit',          false, null, true),
  (1, 'points.redeemed',    'grant_free_item',       true,  null, true),
  (1, 'points.redeemed',    'display_perk',          false, null, false),
  (1, 'points.redeemed',    'send_notification',     false, null, false),
  (1, 'birthday.activated', 'grant_credit',          false, null, true),
  (1, 'birthday.activated', 'apply_discount_pct',    false, null, true),
  (1, 'birthday.activated', 'grant_free_item',       true,  null, true),
  (1, 'birthday.activated', 'display_perk',          false, null, false),
  (1, 'birthday.activated', 'send_notification',     false, null, false),
  (1, 'referral.qualified', 'grant_credit',          false, null, true),
  (1, 'referral.qualified', 'display_perk',          false, null, false),
  (1, 'referral.qualified', 'send_notification',     false, null, false),
  (1, 'membership.renewed', 'grant_credit',          false, null, true),
  (1, 'membership.renewed', 'display_perk',          false, null, false),
  (1, 'membership.renewed', 'send_notification',     false, null, false);

alter table public.rule_condition_allowlist enable row level security;
alter table public.rule_effect_allowlist enable row level security;
create policy rule_condition_allowlist_read on public.rule_condition_allowlist
  for select to authenticated using (true);
create policy rule_effect_allowlist_read on public.rule_effect_allowlist
  for select to authenticated using (true);
revoke all on public.rule_condition_allowlist from public, anon, authenticated;
revoke all on public.rule_effect_allowlist from public, anon, authenticated;
grant select on public.rule_condition_allowlist to authenticated;
grant select on public.rule_effect_allowlist to authenticated;

-- =====================================================================
-- 3. benefit_registry - per business x benefit family execution authority
--    (ARCH §7, BENEFIT_REGISTRY_CONTRACT §2/§3). METADATA ONLY in PS-1A.
--    Families 1-6 are the LIVE legacy engines (legacy_trigger / legacy).
--    Families 7-10 are studio-only future engines that have no legacy path;
--    they enter honestly as studio_executor / 'unbuilt' until their phase.
-- =====================================================================
create table public.benefit_registry (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  source_engine text not null check (source_engine in
    ('points_loyalty', 'retention', 'referral', 'birthday', 'membership', 'campaign',
     'tier', 'recurring', 'checkout', 'stored_value')),
  execution_authority text not null check (execution_authority in
    ('legacy_trigger', 'studio_executor')),
  cutover_status text not null check (cutover_status in
    ('legacy', 'shadow', 'studio', 'rolled_back', 'unbuilt')),
  canonical_benefit_key_template text not null check (char_length(canonical_benefit_key_template) between 1 and 200),
  shadow_started_at timestamptz,
  cutover_at timestamptz,
  rolled_back_at timestamptz,
  created_at timestamptz not null default now(),
  constraint benefit_registry_business_engine_uk unique (business_id, source_engine),
  constraint benefit_registry_id_business_uk unique (id, business_id),
  -- authority and status are distinct fields (N7) but cannot contradict: a legacy
  -- authority holder is only ever in a legacy-side lifecycle stage; a studio
  -- authority holder is only ever 'studio' (cut over) or 'unbuilt' (future).
  constraint benefit_registry_authority_status_check check (
    (execution_authority = 'legacy_trigger' and cutover_status in ('legacy', 'shadow', 'rolled_back'))
    or (execution_authority = 'studio_executor' and cutover_status in ('studio', 'unbuilt'))
  )
);

create or replace function app.seed_benefit_registry(p_business uuid)
returns void language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  insert into public.benefit_registry(business_id, source_engine, execution_authority, cutover_status, canonical_benefit_key_template)
  values
    (p_business, 'points_loyalty', 'legacy_trigger',  'legacy',  'points_redeem:{loyalty_operation_id}'),
    (p_business, 'retention',      'legacy_trigger',  'legacy',  'retention:{program_id}:{client_id}:{period_index}'),
    (p_business, 'referral',       'legacy_trigger',  'legacy',  'referral:{referral_id}'),
    (p_business, 'birthday',       'legacy_trigger',  'legacy',  'birthday:{client_id}:{birthday_year}'),
    (p_business, 'membership',     'legacy_trigger',  'legacy',  'membership_credit:{membership_id}:{period_key}'),
    (p_business, 'campaign',       'legacy_trigger',  'legacy',  'campaign_offer:{campaign_id}:{client_id}'),
    (p_business, 'tier',           'studio_executor', 'unbuilt', 'tier_entry:{client_id}:{tier}'),
    (p_business, 'recurring',      'studio_executor', 'unbuilt', 'recurring:{rule_id}:{client_id}:{period_key}'),
    (p_business, 'checkout',       'studio_executor', 'unbuilt', 'discount:{sale_id}:{rule_id}:{effect_index}'),
    (p_business, 'stored_value',   'studio_executor', 'unbuilt', 'sv_spend:{operation_id}:{movement_id}')
  on conflict (business_id, source_engine) do nothing;
end $$;
revoke all on function app.seed_benefit_registry(uuid) from public, anon, authenticated;

-- Backfill every existing business.
do $seed_benefit_registry_backfill$
declare v_b uuid;
begin
  for v_b in select id from public.businesses loop
    perform app.seed_benefit_registry(v_b);
  end loop;
end $seed_benefit_registry_backfill$;

-- Seed trigger for future onboarding (mirrors app.seed_firm_reward_taxonomy, v37b).
create or replace function app.trg_seed_benefit_registry()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  perform app.seed_benefit_registry(new.id);
  return new;
end $$;
revoke all on function app.trg_seed_benefit_registry() from public, anon, authenticated;
create trigger trg_seed_benefit_registry
  after insert on public.businesses
  for each row execute function app.trg_seed_benefit_registry();

-- Append-only in PS-1A: no RPC mutates authority; authority flips are future
-- migrations that must deliberately replace or disable this guard.
create or replace function app.benefit_registry_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'benefit_registry is metadata-only in PS-1A; execution-authority transitions are future migrations'
    using errcode = 'restrict_violation';
  return null;
end $$;
revoke all on function app.benefit_registry_guard() from public, anon, authenticated;
create trigger trg_benefit_registry_guard
  before update or delete on public.benefit_registry
  for each row execute function app.benefit_registry_guard();

alter table public.benefit_registry enable row level security;
create policy benefit_registry_owner_read on public.benefit_registry
  for select to authenticated using (app.is_salon_owner(business_id));
create policy benefit_registry_sa_read on public.benefit_registry
  for select to authenticated using (app.is_super_admin());
revoke all on public.benefit_registry from public, anon, authenticated;
grant select on public.benefit_registry to authenticated;

-- =====================================================================
-- 6a. Validation helpers (defined before the authoring tables' RPCs).
-- =====================================================================
create or replace function app.ps1a_catalog_ref_valid(p_business uuid, p_kind text, p_id uuid)
returns boolean language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if p_id is null or p_kind is null then return false; end if;
  return case p_kind
    when 'service'         then exists(select 1 from public.services         where id = p_id and business_id = p_business)
    when 'product'         then exists(select 1 from public.products         where id = p_id and business_id = p_business)
    when 'branch'          then exists(select 1 from public.branches         where id = p_id and business_id = p_business)
    when 'staff'           then exists(select 1 from public.staff            where id = p_id and business_id = p_business)
    when 'reward'          then exists(select 1 from public.loyalty_rewards  where id = p_id and business_id = p_business)
    when 'tier'            then exists(select 1 from public.loyalty_tiers    where id = p_id and business_id = p_business)
    when 'membership_plan' then exists(select 1 from public.membership_plans where id = p_id and business_id = p_business)
    else false
  end;
end $$;
revoke all on function app.ps1a_catalog_ref_valid(uuid, text, uuid) from public, anon, authenticated;

-- Canonical rule form: only the SEMANTIC fields, arrays deterministically
-- ordered. jsonb normalizes number scale and object key order, so two
-- canonical-equivalent rules serialize byte-identically and therefore hash
-- identically; a materially different rule serializes (and hashes) differently.
create or replace function app.program_rule_canonical(p_rule jsonb)
returns jsonb language sql immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select jsonb_build_object(
    'schema_version', coalesce(nullif(p_rule->>'schema_version', '')::smallint, 1),
    'when',   p_rule->>'when_event',
    'if',     coalesce((select jsonb_agg(c order by c->>'field', c->>'op', c::text)
                          from jsonb_array_elements(coalesce(p_rule->'if_conditions', '[]'::jsonb)) c), '[]'::jsonb),
    'then',   coalesce((select jsonb_agg(e order by e->>'effect_type', e::text)
                          from jsonb_array_elements(coalesce(p_rule->'then_effects', '[]'::jsonb)) e), '[]'::jsonb),
    'with',   coalesce(p_rule->'with_params', '{}'::jsonb),
    'during', coalesce(p_rule->'during_schedule', '{}'::jsonb),
    'using',  coalesce(p_rule->'using_stacking', '{}'::jsonb)
  )
$$;
revoke all on function app.program_rule_canonical(jsonb) from public, anon, authenticated;

create or replace function app.program_rule_hash(p_rule jsonb)
returns text language sql stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$ select app.ps1a_sha256(app.program_rule_canonical(p_rule)::text) $$;
revoke all on function app.program_rule_hash(jsonb) from public, anon, authenticated;

-- The compiler/validator. Returns a text[] of error codes (empty = valid).
-- Enforces: allowlist conformance (event/field/operator/effect), NO SQL
-- fragments (structural key allowlist), NO client-supplied prices, catalog
-- references belong to the business, complexity limits, SGT schedule sanity,
-- and stacking-field sanity.
create or replace function app.program_rule_errors(p_business uuid, p_rule jsonb)
returns text[] language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_err text[] := array[]::text[];
  v_schema smallint;
  v_event text;
  v_if jsonb; v_then jsonb; v_with jsonb; v_during jsonb; v_using jsonb;
  v_events text[];
  c jsonb; e jsonb; d jsonb;
  v_field text; v_op text; v_val jsonb;
  v_ops text[]; v_vtype text; v_kind text;
  v_tz text;
  v_max_cond constant integer := 10;
  v_max_eff  constant integer := 8;
begin
  if p_rule is null or jsonb_typeof(p_rule) <> 'object' then
    return array['rule_not_object'];
  end if;
  if exists(select 1 from jsonb_object_keys(p_rule) k where k not in
      ('name','active','schema_version','when_event','if_conditions','then_effects',
       'with_params','during_schedule','using_stacking','sort','notes')) then
    v_err := v_err || 'unsupported_rule_field'::text;
  end if;

  v_schema := coalesce(nullif(p_rule->>'schema_version', '')::smallint, 1);
  if not exists(select 1 from public.rule_schema_versions where schema_version = v_schema and status = 'active') then
    v_err := v_err || 'invalid_schema_version'::text;
  end if;

  v_event := p_rule->>'when_event';
  select array_agg(distinct ev) into v_events from (
    select event_type ev from public.rule_condition_allowlist where schema_version = v_schema
    union
    select event_type    from public.rule_effect_allowlist    where schema_version = v_schema
  ) s;
  if v_event is null or not (v_event = any(coalesce(v_events, array[]::text[]))) then
    v_err := v_err || 'invalid_event'::text;
    return v_err;  -- fields cannot be judged without a known event
  end if;

  v_if     := coalesce(p_rule->'if_conditions',  '[]'::jsonb);
  v_then   := coalesce(p_rule->'then_effects',   '[]'::jsonb);
  v_with   := coalesce(p_rule->'with_params',    '{}'::jsonb);
  v_during := coalesce(p_rule->'during_schedule','{}'::jsonb);
  v_using  := coalesce(p_rule->'using_stacking', '{}'::jsonb);

  if jsonb_typeof(v_if) <> 'array' then v_err := v_err || 'if_not_array'::text;
  elsif jsonb_array_length(v_if) > v_max_cond then v_err := v_err || 'too_many_conditions'::text;
  end if;
  if jsonb_typeof(v_then) <> 'array' then v_err := v_err || 'then_not_array'::text;
  elsif jsonb_array_length(v_then) > v_max_eff then v_err := v_err || 'too_many_effects'::text;
  end if;

  -- conditions
  if jsonb_typeof(v_if) = 'array' then
    for c in select * from jsonb_array_elements(v_if) loop
      if jsonb_typeof(c) <> 'object' then v_err := v_err || 'condition_not_object'::text; continue; end if;
      if exists(select 1 from jsonb_object_keys(c) k where k not in ('field','op','value')) then
        v_err := v_err || 'condition_unsupported_key'::text;
      end if;
      v_field := c->>'field'; v_op := c->>'op'; v_val := c->'value';
      select operators, value_type, catalog_kind into v_ops, v_vtype, v_kind
        from public.rule_condition_allowlist
       where schema_version = v_schema and event_type = v_event and field = v_field;
      if not found then v_err := v_err || ('unknown_condition_field:' || coalesce(v_field, '?')); continue; end if;
      if v_op is null or not (v_op = any(v_ops)) then v_err := v_err || ('invalid_operator:' || coalesce(v_op, '?')); end if;
      if v_op in ('in','not_in') and jsonb_typeof(v_val) <> 'array' then v_err := v_err || 'in_requires_array'::text; end if;
      if v_op = 'between' and (jsonb_typeof(v_val) <> 'array' or jsonb_array_length(v_val) <> 2) then v_err := v_err || 'between_requires_pair'::text; end if;
      if v_vtype = 'catalog_ref' then
        if jsonb_typeof(v_val) = 'array' then
          for d in select * from jsonb_array_elements(v_val) loop
            if not app.ps1a_catalog_ref_valid(p_business, v_kind, nullif(d#>>'{}', '')::uuid) then v_err := v_err || ('catalog_ref_not_found:' || v_kind); end if;
          end loop;
        else
          if not app.ps1a_catalog_ref_valid(p_business, v_kind, nullif(v_val#>>'{}', '')::uuid) then v_err := v_err || ('catalog_ref_not_found:' || v_kind); end if;
        end if;
      end if;
    end loop;
  end if;

  -- effects
  if jsonb_typeof(v_then) = 'array' then
    for e in select * from jsonb_array_elements(v_then) loop
      if jsonb_typeof(e) <> 'object' then v_err := v_err || 'effect_not_object'::text; continue; end if;
      if exists(select 1 from jsonb_object_keys(e) k where k not in
          ('effect_type','amount_cents','discount_pct','points','stamps','multiplier','catalog_kind','catalog_id','note')) then
        v_err := v_err || 'effect_unsupported_key'::text;
      end if;
      -- structural bars: no client-supplied price, no SQL fragment surface
      if e ? 'price_cents' or e ? 'unit_price_cents' or e ? 'catalog_price' then v_err := v_err || 'client_supplied_price'::text; end if;
      if e ? 'sql' or e ? 'expr' or e ? 'expression' or e ? 'raw' then v_err := v_err || 'sql_fragment_forbidden'::text; end if;
      if not exists(select 1 from public.rule_effect_allowlist
          where schema_version = v_schema and event_type = v_event and effect_type = e->>'effect_type') then
        v_err := v_err || ('invalid_effect:' || coalesce(e->>'effect_type', '?')); continue;
      end if;
      case e->>'effect_type'
        when 'grant_credit' then
          if coalesce(nullif(e->>'amount_cents', '')::integer, 0) <= 0 then v_err := v_err || 'effect_amount_required'::text; end if;
        when 'apply_discount_amount' then
          if coalesce(nullif(e->>'amount_cents', '')::integer, 0) <= 0 then v_err := v_err || 'effect_amount_required'::text; end if;
        when 'apply_discount_pct' then
          if not (coalesce(nullif(e->>'discount_pct', '')::numeric, 0) > 0 and (e->>'discount_pct')::numeric <= 100) then v_err := v_err || 'effect_discount_pct_range'::text; end if;
        when 'earn_bonus_points' then
          if coalesce(nullif(e->>'points', '')::integer, 0) <= 0 then v_err := v_err || 'effect_points_required'::text; end if;
        when 'earn_bonus_stamps' then
          if coalesce(nullif(e->>'stamps', '')::integer, 0) <= 0 then v_err := v_err || 'effect_stamps_required'::text; end if;
        when 'tier_multiplier' then
          if coalesce(nullif(e->>'multiplier', '')::numeric, 0) < 1 then v_err := v_err || 'effect_multiplier_range'::text; end if;
        when 'grant_free_item' then
          if not app.ps1a_catalog_ref_valid(p_business, e->>'catalog_kind', nullif(e->>'catalog_id', '')::uuid) then v_err := v_err || 'effect_catalog_ref_not_found'::text; end if;
        else null;
      end case;
    end loop;
  end if;

  -- schedule sanity (SGT only)
  if v_during <> '{}'::jsonb then
    if jsonb_typeof(v_during) <> 'object' then v_err := v_err || 'schedule_not_object'::text;
    else
      if exists(select 1 from jsonb_object_keys(v_during) k where k not in
          ('timezone','start_date','end_date','days_of_week','start_time','end_time')) then
        v_err := v_err || 'schedule_unsupported_key'::text;
      end if;
      v_tz := v_during->>'timezone';
      if v_tz is not null and v_tz <> 'Asia/Singapore' then v_err := v_err || 'schedule_non_sgt'::text; end if;
      begin
        if (v_during ? 'start_date') and (v_during ? 'end_date')
           and (v_during->>'end_date')::date < (v_during->>'start_date')::date then
          v_err := v_err || 'schedule_end_before_start'::text;
        end if;
      exception when others then v_err := v_err || 'schedule_bad_date'::text; end;
      if v_during ? 'days_of_week' then
        if jsonb_typeof(v_during->'days_of_week') <> 'array' then v_err := v_err || 'schedule_dow_not_array'::text;
        else
          for d in select * from jsonb_array_elements(v_during->'days_of_week') loop
            if jsonb_typeof(d) <> 'number' or (d#>>'{}')::integer not between 0 and 6 then v_err := v_err || 'schedule_dow_range'::text; end if;
          end loop;
        end if;
      end if;
      begin
        if v_during ? 'start_time' then perform (v_during->>'start_time')::time; end if;
        if v_during ? 'end_time'   then perform (v_during->>'end_time')::time; end if;
      exception when others then v_err := v_err || 'schedule_bad_time'::text; end;
    end if;
  end if;

  -- stacking sanity
  if v_using <> '{}'::jsonb then
    if jsonb_typeof(v_using) <> 'object' then v_err := v_err || 'stacking_not_object'::text;
    else
      if exists(select 1 from jsonb_object_keys(v_using) k where k not in
          ('stackable','priority','max_stack','exclusive_group')) then
        v_err := v_err || 'stacking_unsupported_key'::text;
      end if;
      if (v_using ? 'stackable') and jsonb_typeof(v_using->'stackable') <> 'boolean' then v_err := v_err || 'stacking_stackable_type'::text; end if;
      begin
        if v_using ? 'priority'  then perform (v_using->>'priority')::integer; end if;
        if (v_using ? 'max_stack') and (v_using->>'max_stack')::integer < 1 then v_err := v_err || 'stacking_max_stack_range'::text; end if;
      exception when others then v_err := v_err || 'stacking_bad_number'::text; end;
    end if;
  end if;

  return v_err;
end $$;
revoke all on function app.program_rule_errors(uuid, jsonb) from public, anon, authenticated;

-- Owner-facing dry-run validator for the authoring UI.
create or replace function public.validate_program_rule(p_business uuid, p_rule jsonb)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_err text[];
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  v_err := app.program_rule_errors(p_business, p_rule);
  return jsonb_build_object(
    'valid',     coalesce(array_length(v_err, 1), 0) = 0,
    'errors',    to_jsonb(coalesce(v_err, array[]::text[])),
    'canonical', app.program_rule_canonical(p_rule),
    'rule_hash', app.program_rule_hash(p_rule)
  );
end $$;

-- =====================================================================
-- 4. program_rules - version-scoped studio authoring table.
--    Version-scoped under firm_config_versions exactly like
--    retention_program_versions; immutable once its version publishes;
--    drafts clone from the base version (v37b clone-on-draft pattern).
-- =====================================================================
create table public.program_rules (
  id uuid primary key default gen_random_uuid(),
  rule_id uuid not null,                 -- stable identity across config versions
  config_version_id uuid not null,
  business_id uuid not null,
  schema_version smallint not null default 1 references public.rule_schema_versions(schema_version),
  name text not null check (char_length(btrim(name)) between 1 and 120),
  active boolean not null default true,
  when_event text not null,
  if_conditions jsonb not null default '[]'::jsonb check (jsonb_typeof(if_conditions) = 'array'),
  then_effects jsonb not null default '[]'::jsonb check (jsonb_typeof(then_effects) = 'array'),
  with_params jsonb not null default '{}'::jsonb check (jsonb_typeof(with_params) = 'object'),
  during_schedule jsonb not null default '{}'::jsonb check (jsonb_typeof(during_schedule) = 'object'),
  using_stacking jsonb not null default '{}'::jsonb check (jsonb_typeof(using_stacking) = 'object'),
  source_engine text not null default 'studio_rule' check (source_engine = 'studio_rule'),
  rule_hash text not null check (rule_hash ~ '^[0-9a-f]{64}$'),
  sort integer not null default 0 check (sort between 0 and 10000),
  notes text check (notes is null or char_length(notes) <= 2000),
  created_at timestamptz not null default now(),
  constraint program_rules_config_business_fk
    foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict,
  constraint program_rules_rule_config_uk unique (rule_id, config_version_id),
  constraint program_rules_id_business_uk unique (id, business_id)
);
create index program_rules_config_idx
  on public.program_rules (business_id, config_version_id, active, when_event, sort, rule_id);

create or replace function app.program_rule_version_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_version uuid := case when tg_op = 'DELETE' then old.config_version_id else new.config_version_id end;
        v_status text;
begin
  select status into v_status from public.firm_config_versions where id = v_version;
  if v_status is distinct from 'draft' then
    raise exception 'published program rule configuration is immutable'
      using errcode = 'restrict_violation';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if tg_op = 'UPDATE' and (
       new.rule_id is distinct from old.rule_id
       or new.config_version_id is distinct from old.config_version_id
       or new.business_id is distinct from old.business_id) then
    raise exception 'program rule identity is immutable'
      using errcode = 'restrict_violation';
  end if;
  return new;
end $$;
revoke all on function app.program_rule_version_guard() from public, anon, authenticated;
create trigger trg_program_rule_version_guard
  before insert or update or delete on public.program_rules
  for each row execute function app.program_rule_version_guard();

-- Draft creation clones the immutable rule set from the base version. The AFTER
-- INSERT trigger fires when create_loyalty_config_draft inserts a draft header,
-- exactly like app.clone_retention_program_versions_on_draft (v37b).
create or replace function app.clone_program_rules_on_draft()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.status = 'draft' and new.based_on_version_id is not null then
    insert into public.program_rules(
      rule_id, config_version_id, business_id, schema_version, name, active,
      when_event, if_conditions, then_effects, with_params, during_schedule, using_stacking,
      source_engine, rule_hash, sort, notes)
    select pr.rule_id, new.id, new.business_id, pr.schema_version, pr.name, pr.active,
           pr.when_event, pr.if_conditions, pr.then_effects, pr.with_params, pr.during_schedule, pr.using_stacking,
           pr.source_engine, pr.rule_hash, pr.sort, pr.notes
      from public.program_rules pr
     where pr.config_version_id = new.based_on_version_id
       and pr.business_id = new.business_id;
  end if;
  return new;
end $$;
revoke all on function app.clone_program_rules_on_draft() from public, anon, authenticated;
create trigger trg_clone_program_rules_on_draft
  after insert on public.firm_config_versions
  for each row execute function app.clone_program_rules_on_draft();

alter table public.program_rules enable row level security;
create policy program_rules_owner_read on public.program_rules
  for select to authenticated using (app.is_salon_owner(business_id));
create policy program_rules_sa_read on public.program_rules
  for select to authenticated using (app.is_super_admin());
revoke all on public.program_rules from public, anon, authenticated;
grant select on public.program_rules to authenticated;

-- =====================================================================
-- 5. program_rules_compiled - the compiled read representation.
--    Materialized at publish (event-typed, indexed, hot fields lifted).
--    READ-only consumer surface for the future evaluator + PS-1A preview.
-- =====================================================================
create table public.program_rules_compiled (
  id uuid primary key default gen_random_uuid(),
  rule_id uuid not null,
  program_rule_id uuid not null,
  config_version_id uuid not null,
  business_id uuid not null,
  schema_version smallint not null,
  when_event text not null,
  active boolean not null,
  compiled jsonb not null,
  rule_hash text not null check (rule_hash ~ '^[0-9a-f]{64}$'),
  compiled_at timestamptz not null default now(),
  constraint program_rules_compiled_config_business_fk
    foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict,
  constraint program_rules_compiled_rule_fk
    foreign key (program_rule_id, business_id)
    references public.program_rules(id, business_id) on delete restrict,
  constraint program_rules_compiled_rule_uk unique (program_rule_id)
);
create index program_rules_compiled_event_idx
  on public.program_rules_compiled (business_id, config_version_id, when_event, active);

alter table public.program_rules_compiled enable row level security;
create policy program_rules_compiled_owner_read on public.program_rules_compiled
  for select to authenticated using (app.is_salon_owner(business_id));
create policy program_rules_compiled_sa_read on public.program_rules_compiled
  for select to authenticated using (app.is_super_admin());
revoke all on public.program_rules_compiled from public, anon, authenticated;
grant select on public.program_rules_compiled to authenticated;

create or replace function app.compile_program_rules(p_version uuid)
returns void language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  delete from public.program_rules_compiled where config_version_id = p_version;
  insert into public.program_rules_compiled(
    rule_id, program_rule_id, config_version_id, business_id, schema_version, when_event, active, compiled, rule_hash)
  select pr.rule_id, pr.id, pr.config_version_id, pr.business_id, pr.schema_version, pr.when_event, pr.active,
         app.program_rule_canonical(jsonb_build_object(
           'schema_version', pr.schema_version, 'when_event', pr.when_event,
           'if_conditions', pr.if_conditions, 'then_effects', pr.then_effects,
           'with_params', pr.with_params, 'during_schedule', pr.during_schedule, 'using_stacking', pr.using_stacking)),
         pr.rule_hash
    from public.program_rules pr
   where pr.config_version_id = p_version;
end $$;
revoke all on function app.compile_program_rules(uuid) from public, anon, authenticated;

-- =====================================================================
-- 7. Snapshot + publish extension.
--    (a) refresh_loyalty_config_snapshot: fold program_rules (by rule_hash)
--        into the config snapshot hash so a rule edit changes the version's
--        snapshot_hash - this is what save_program_rule_draft's optimistic
--        concurrency (below) relies on, exactly like retention (v37b).
--    (b) publish_loyalty_config: refuse to publish a version that contains
--        any INVALID program rule (atomic), then compile the version.
-- =====================================================================
create or replace function app.refresh_loyalty_config_snapshot(p_version uuid)
returns void language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
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
    'birthday_programs',coalesce((select jsonb_agg(to_jsonb(bp)-'id'-'config_version_id'-'business_id'-'created_at' order by bp.sort,bp.program_id) from public.birthday_program_versions bp where bp.config_version_id=p_version),'[]'::jsonb),
    'program_rules',coalesce((select jsonb_agg(jsonb_build_object(
      'rule_id',pr.rule_id,'schema_version',pr.schema_version,'name',pr.name,'active',pr.active,
      'when',pr.when_event,'sort',pr.sort,'hash',pr.rule_hash
    ) order by pr.sort,pr.rule_id) from public.program_rules pr where pr.config_version_id=p_version),'[]'::jsonb)
  ) into v_snapshot;
  update public.firm_config_versions set snapshot_hash=md5(v_snapshot::text) where id=p_version;
end $$;
revoke all on function app.refresh_loyalty_config_snapshot(uuid) from public, anon, authenticated;

create or replace function public.publish_loyalty_config(p_version uuid)
returns json language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_header public.firm_config_versions%rowtype; v_typed public.loyalty_program_versions%rowtype; v_prior uuid;
  v_rule public.program_rules%rowtype; v_rule_errs text[]; v_active_rule_count integer;
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
  -- PS-1A: a version containing ANY invalid studio rule refuses to publish, atomically.
  for v_rule in select * from public.program_rules where config_version_id=p_version and business_id=v_header.business_id loop
    v_rule_errs := app.program_rule_errors(v_header.business_id, jsonb_build_object(
      'schema_version',v_rule.schema_version,'when_event',v_rule.when_event,'if_conditions',v_rule.if_conditions,
      'then_effects',v_rule.then_effects,'with_params',v_rule.with_params,'during_schedule',v_rule.during_schedule,'using_stacking',v_rule.using_stacking));
    if coalesce(array_length(v_rule_errs,1),0)>0 then
      raise exception 'cannot publish: program rule % is invalid (%)', v_rule.name, array_to_string(v_rule_errs,', ') using errcode='23514';
    end if;
  end loop;
  select count(*) into v_active_rule_count from public.program_rules where config_version_id=p_version and business_id=v_header.business_id and active;
  if v_active_rule_count>200 then
    raise exception 'cannot publish: too many active program rules (%)', v_active_rule_count using errcode='23514';
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
  -- PS-1A: compile the published rule set into the read-only consumer surface.
  perform app.compile_program_rules(p_version);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_header.business_id,auth.uid(),'PUBLISH_CONFIG','firm_config_versions',p_version,jsonb_build_object('prior_version_id',v_prior,'new_version_id',p_version,'snapshot_hash',v_header.snapshot_hash,'birthday_program_count',(select count(*) from public.birthday_program_versions where config_version_id=p_version),'program_rule_count',(select count(*) from public.program_rules where config_version_id=p_version)));
  return json_build_object('version_id',p_version,'version_no',v_header.version_no,'status','published');
end $$;

-- =====================================================================
-- 8a. Adapter view v_program_rules_all - read-only PROJECTION of the LIVE
--     engines' active config into the WHEN/IF/THEN/WITH/DURING/USING shape.
--     Zero copied rows, zero new storage (relkind='v').
--
--     Security choice (justified): a plain (owner-privileged) view rather than
--     security_invoker, because the underlying engine tables carry HETEROGENEOUS
--     RLS - loyalty_* are salon-member-read, retention_program_versions is
--     owner-read, and birthday_program_versions is browser-CLOSED (no
--     authenticated grant at all, c45). A single security_invoker view would
--     fail for any owner the moment it touches birthday config. This plain view
--     reads all engine config uniformly under the migration role and enforces
--     tenant isolation + owner scoping through its OWN auth.uid()-based predicate
--     (app.is_salon_owner OR app.is_super_admin), matching the owner-read
--     contract of get_programs_overview. It is a secure-barrier projection.
--
--     Each row is 1:1 derivable from native config: native_config carries the
--     exact source row (to_jsonb), and the WHEN/IF/THEN/WITH/DURING/USING columns
--     are a canonical restatement of that engine's live behaviour. Equivalence
--     per engine is documented in the column comments below.
-- =====================================================================
create view public.v_program_rules_all as
select
  v.business_id,
  v.source_engine,
  v.rule_key,
  md5('v_program_rules_all:' || v.rule_key)::uuid as synthetic_rule_id,
  v.native_ref,
  v.config_version_id,
  v.name,
  v.active,
  v.when_event,
  v.if_conditions,
  v.then_effects,
  v.with_params,
  v.during_schedule,
  v.using_stacking,
  v.native_config,
  v.execution_state
from (
  -- Engine 1: points/stamps EARN (equiv: app.on_sale_recorded earn branch over
  -- loyalty_program_versions of the business's active config).
  select
    lp.business_id, 'points_loyalty'::text as source_engine,
    'points_loyalty:' || lp.config_version_id::text as rule_key,
    lp.config_version_id::text as native_ref, lp.config_version_id,
    ('Earn - ' || lp.loyalty_model) as name, lp.active,
    'sale.completed'::text as when_event,
    jsonb_build_array(jsonb_build_object('field','earns_points','op','eq','value',true)) as if_conditions,
    case when lp.kind='stamps' or lp.loyalty_model='stamps'
      then jsonb_build_array(jsonb_build_object('effect_type','earn_bonus_stamps','per_cents',lp.stamp_per_cents,'stamp_target',lp.stamp_target))
      else jsonb_build_array(jsonb_build_object('effect_type','earn_bonus_points','points_per_dollar',lp.earn_points_per_dollar)) end as then_effects,
    jsonb_build_object('redeem_points',lp.redeem_points,'reward_credit_cents',lp.reward_credit_cents,'expiry_mode',lp.expiry_mode,'expiry_days',lp.expiry_days) as with_params,
    '{}'::jsonb as during_schedule, '{}'::jsonb as using_stacking,
    to_jsonb(lp) as native_config,
    (case when lp.active then 'live' else 'paused' end)::text as execution_state
  from public.loyalty_program_versions lp
  join public.businesses b on b.id=lp.business_id and b.active_config_version_id=lp.config_version_id

  union all
  -- Engine 1b: TIERS (equiv: loyalty_tier_versions -> loyalty_tiers multiplier).
  select
    tv.business_id, 'points_loyalty'::text,
    'tier:' || tv.tier_id::text, tv.tier_id::text, tv.config_version_id,
    ('Tier - ' || tv.name), tv.active, 'sale.completed'::text,
    jsonb_build_array(jsonb_build_object('field','points_earned','op','gte','value',tv.threshold)),
    jsonb_build_array(jsonb_build_object('effect_type','tier_multiplier','multiplier',tv.points_multiplier,'tier_id',tv.tier_id)),
    jsonb_build_object('perk_note',tv.perk_note,'sort',tv.sort),
    '{}'::jsonb, '{}'::jsonb, to_jsonb(tv),
    (case when tv.active then 'live' else 'inactive' end)::text
  from public.loyalty_tier_versions tv
  join public.businesses b on b.id=tv.business_id and b.active_config_version_id=tv.config_version_id

  union all
  -- Engine 1c: REWARDS CATALOG (equiv: loyalty_reward_versions redemption catalog).
  select
    rv.business_id, 'points_loyalty'::text,
    'reward:' || rv.reward_id::text, rv.reward_id::text, rv.config_version_id,
    ('Reward - ' || rv.customer_name), rv.active, 'points.redeemed'::text,
    jsonb_build_array(jsonb_build_object('field','reward_id','op','eq','value',rv.reward_id)),
    jsonb_build_array(jsonb_build_object(
      'effect_type', case when rv.fulfillment_kind='credit' then 'grant_credit' else 'grant_free_item' end,
      'amount_cents', case when rv.fulfillment_kind='credit' then rv.credit_cents end,
      'cost_points', rv.cost_points)),
    jsonb_build_object('cost_points',rv.cost_points,'estimated_cost_cents',rv.estimated_cost_cents,'usage_limit',rv.usage_limit),
    '{}'::jsonb, '{}'::jsonb, to_jsonb(rv),
    (case when rv.active then 'live' else 'inactive' end)::text
  from public.loyalty_reward_versions rv
  join public.businesses b on b.id=rv.business_id and b.active_config_version_id=rv.config_version_id

  union all
  -- Engine 2: RETENTION (equiv: retention_program_versions -> reward_grants;
  -- goal_visits within a rolling period_days window).
  select
    r.business_id, 'retention'::text,
    'retention:' || r.program_id::text, r.program_id::text, r.config_version_id,
    ('Retention - ' || r.name), r.active, 'sale.completed'::text,
    jsonb_build_array(
      jsonb_build_object('field','counts_as_visit','op','eq','value',true),
      jsonb_build_object('field','visits_in_period','op','gte','value',r.goal_visits)),
    jsonb_build_array(jsonb_build_object(
      'effect_type', case r.fulfillment_kind when 'credit' then 'grant_credit' when 'discount_pct' then 'apply_discount_pct' else 'grant_free_item' end,
      'amount_cents', r.credit_cents, 'discount_pct', r.discount_percent, 'manual_item', r.manual_item)),
    jsonb_build_object('goal_visits',r.goal_visits,'period_days',r.period_days,'starts_on',r.starts_on),
    '{}'::jsonb, '{}'::jsonb, to_jsonb(r),
    (case when r.active then 'live' else 'paused' end)::text
  from public.retention_program_versions r
  join public.businesses b on b.id=r.business_id and b.active_config_version_id=r.config_version_id

  union all
  -- Engine 3: BIRTHDAY (equiv: birthday_program_versions benefit config).
  select
    bp.business_id, 'birthday'::text,
    'birthday:' || bp.program_id::text, bp.program_id::text, bp.config_version_id,
    ('Birthday - ' || bp.customer_label), bp.active, 'birthday.activated'::text,
    '[]'::jsonb,
    jsonb_build_array(jsonb_build_object(
      'effect_type', case bp.fulfillment_kind when 'discount_pct' then 'apply_discount_pct' else 'grant_free_item' end,
      'discount_pct', bp.discount_percent, 'manual_item', bp.manual_item)),
    jsonb_build_object('window_days_before',bp.window_days_before,'window_days_after',bp.window_days_after),
    '{}'::jsonb, '{}'::jsonb, to_jsonb(bp),
    (case when bp.active then 'live' else 'paused' end)::text
  from public.birthday_program_versions bp
  join public.businesses b on b.id=bp.business_id and b.active_config_version_id=bp.config_version_id

  union all
  -- Engine 4: REFERRAL program (off-spine; equiv: referral_programs -> qualify
  -- on first qualifying sale >= min_spend, credit reward_cents to referrer).
  select
    rp.business_id, 'referral'::text,
    'referral:' || rp.business_id::text, rp.business_id::text, b.active_config_version_id,
    'Referral program'::text, rp.enabled, 'referral.qualified'::text,
    jsonb_build_array(jsonb_build_object('field','min_spend_cents','op','gte','value',coalesce(rp.min_spend_cents,0))),
    jsonb_build_array(jsonb_build_object('effect_type','grant_credit','amount_cents',rp.reward_cents)),
    jsonb_build_object('min_spend_cents',rp.min_spend_cents,'reward_cents',rp.reward_cents),
    '{}'::jsonb, '{}'::jsonb, to_jsonb(rp),
    (case when rp.enabled then 'live' else 'disabled' end)::text
  from public.referral_programs rp
  join public.businesses b on b.id=rp.business_id
) v
where app.is_salon_owner(v.business_id) or app.is_super_admin();

comment on view public.v_program_rules_all is
  'PS-1A read-only adapter: projects each LIVE engine''s active config into the '
  'WHEN/IF/THEN/WITH/DURING/USING studio shape. Zero storage. Rows are 1:1 '
  'derivable from native_config (the exact source row). Secure-barrier view '
  '(owner/super-admin predicate); does NOT execute anything.';

revoke all on public.v_program_rules_all from public, anon, authenticated;
grant select on public.v_program_rules_all to authenticated;

-- =====================================================================
-- 8b. Truthful studio-rule execution state (server-derived; NEVER live/active).
-- =====================================================================
create or replace function app.ps1a_studio_rule_state(p_business uuid, p_rule_id uuid, p_config_status text)
returns text language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v public.program_rules%rowtype; v_err text[];
begin
  select * into v from public.program_rules where id = p_rule_id;
  if not found then return 'validation_failed'; end if;
  -- A published-version rule was validated at publish. PS-1A has NO executor, so
  -- it is 'ready_for_activation' - never 'live'/'active' (owner hard requirement).
  if p_config_status = 'published' then return 'ready_for_activation'; end if;
  v_err := app.program_rule_errors(p_business, jsonb_build_object(
    'schema_version',v.schema_version,'when_event',v.when_event,'if_conditions',v.if_conditions,
    'then_effects',v.then_effects,'with_params',v.with_params,'during_schedule',v.during_schedule,'using_stacking',v.using_stacking));
  if coalesce(array_length(v_err,1),0) > 0 then return 'validation_failed'; end if;
  if jsonb_array_length(coalesce(v.then_effects,'[]'::jsonb)) = 0 then return 'draft'; end if;
  return 'validated';
end $$;
revoke all on function app.ps1a_studio_rule_state(uuid, uuid, text) from public, anon, authenticated;

-- =====================================================================
-- 8c. Authoring RPCs (owner-only; draft context; snapshot-hash optimistic
--     concurrency - mirrors public.save_retention_program_draft, v37b).
-- =====================================================================
create or replace function public.save_program_rule_draft(
  p_config_version uuid,
  p_rule_id uuid,
  p_rule jsonb,
  p_expected_snapshot_hash text default null
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_header public.firm_config_versions%rowtype; v_existing public.program_rules%rowtype;
  v_id uuid; v_hash text; v_rule_hash text; v_errs text[];
  v_name text; v_active boolean; v_schema smallint; v_event text;
  v_if jsonb; v_then jsonb; v_with jsonb; v_during jsonb; v_using jsonb; v_sort integer; v_notes text;
  v_merged jsonb;
begin
  if p_rule_id is null then raise exception 'a stable rule id is required for retry-safe creation' using errcode='22023'; end if;
  if p_rule is null or jsonb_typeof(p_rule)<>'object' then raise exception 'program rule must be a JSON object' using errcode='22023'; end if;
  select * into v_header from public.firm_config_versions where id=p_config_version for update;
  if not found or not app.is_salon_owner(v_header.business_id) then raise exception 'owner only' using errcode='42501'; end if;
  if v_header.status<>'draft' then raise exception 'only a draft program rule may be edited' using errcode='42501'; end if;
  perform 1 from public.businesses where id=v_header.business_id for share;
  if p_expected_snapshot_hash is null then raise exception 'expected snapshot hash is required' using errcode='22023'; end if;

  select * into v_existing from public.program_rules
   where rule_id=p_rule_id and config_version_id=p_config_version and business_id=v_header.business_id;
  if v_existing.id is null and exists(select 1 from public.program_rules where rule_id=p_rule_id and business_id<>v_header.business_id) then
    raise exception 'program rule does not belong to this business' using errcode='42501';
  end if;

  -- Partial-update merge over the existing draft row.
  v_name   := coalesce(nullif(btrim(p_rule->>'name'),''), v_existing.name);
  v_active := case when p_rule?'active' then (p_rule->>'active')::boolean else coalesce(v_existing.active,true) end;
  v_schema := case when p_rule?'schema_version' then (p_rule->>'schema_version')::smallint else coalesce(v_existing.schema_version,1) end;
  v_event  := coalesce(nullif(p_rule->>'when_event',''), v_existing.when_event);
  v_if     := coalesce(p_rule->'if_conditions',   v_existing.if_conditions,   '[]'::jsonb);
  v_then   := coalesce(p_rule->'then_effects',    v_existing.then_effects,    '[]'::jsonb);
  v_with   := coalesce(p_rule->'with_params',     v_existing.with_params,     '{}'::jsonb);
  v_during := coalesce(p_rule->'during_schedule', v_existing.during_schedule, '{}'::jsonb);
  v_using  := coalesce(p_rule->'using_stacking',  v_existing.using_stacking,  '{}'::jsonb);
  v_sort   := case when p_rule?'sort' then (p_rule->>'sort')::integer else coalesce(v_existing.sort,0) end;
  v_notes  := case when p_rule?'notes' then nullif(btrim(p_rule->>'notes'),'') else v_existing.notes end;
  if v_name is null then raise exception 'program rule name is required' using errcode='22023'; end if;

  v_merged := jsonb_build_object(
    'schema_version',v_schema,'when_event',v_event,'if_conditions',v_if,'then_effects',v_then,
    'with_params',v_with,'during_schedule',v_during,'using_stacking',v_using);
  v_errs := app.program_rule_errors(v_header.business_id, v_merged);
  if coalesce(array_length(v_errs,1),0)>0 then
    raise exception 'program rule failed validation: %', array_to_string(v_errs,', ') using errcode='22023';
  end if;
  v_rule_hash := app.program_rule_hash(v_merged);

  -- Optimistic concurrency + idempotent lost-response replay.
  if v_header.snapshot_hash is distinct from p_expected_snapshot_hash then
    if v_existing.id is not null and v_existing.rule_hash=v_rule_hash
       and v_existing.name=v_name and v_existing.active=v_active and v_existing.sort=v_sort
       and v_existing.notes is not distinct from v_notes then
      return jsonb_build_object('rule_id',p_rule_id,'program_rule_id',v_existing.id,'config_version_id',p_config_version,
        'status','draft','rule_hash',v_rule_hash,'snapshot_hash',v_header.snapshot_hash,'replayed',true);
    end if;
    raise exception 'draft configuration changed; reload before saving' using errcode='40001';
  end if;

  insert into public.program_rules(
    rule_id, config_version_id, business_id, schema_version, name, active,
    when_event, if_conditions, then_effects, with_params, during_schedule, using_stacking,
    source_engine, rule_hash, sort, notes)
  values(
    p_rule_id, p_config_version, v_header.business_id, v_schema, v_name, v_active,
    v_event, v_if, v_then, v_with, v_during, v_using, 'studio_rule', v_rule_hash, v_sort, v_notes)
  on conflict(rule_id, config_version_id) do update set
    schema_version=excluded.schema_version, name=excluded.name, active=excluded.active,
    when_event=excluded.when_event, if_conditions=excluded.if_conditions, then_effects=excluded.then_effects,
    with_params=excluded.with_params, during_schedule=excluded.during_schedule, using_stacking=excluded.using_stacking,
    rule_hash=excluded.rule_hash, sort=excluded.sort, notes=excluded.notes
  returning id into v_id;

  perform app.refresh_loyalty_config_snapshot(p_config_version);
  select snapshot_hash into v_hash from public.firm_config_versions where id=p_config_version;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_header.business_id, auth.uid(), 'SAVE_PROGRAM_RULE_DRAFT', 'program_rules', v_id,
    jsonb_build_object('rule_id',p_rule_id,'config_version_id',p_config_version,'rule_hash',v_rule_hash));
  return jsonb_build_object('rule_id',p_rule_id,'program_rule_id',v_id,'config_version_id',p_config_version,
    'status','draft','rule_hash',v_rule_hash,'snapshot_hash',v_hash,'replayed',false);
end $$;

create or replace function public.delete_program_rule_draft(
  p_config_version uuid,
  p_rule_id uuid,
  p_expected_snapshot_hash text default null
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_header public.firm_config_versions%rowtype; v_existing public.program_rules%rowtype; v_hash text;
begin
  select * into v_header from public.firm_config_versions where id=p_config_version for update;
  if not found or not app.is_salon_owner(v_header.business_id) then raise exception 'owner only' using errcode='42501'; end if;
  if v_header.status<>'draft' then raise exception 'only a draft program rule may be deleted' using errcode='42501'; end if;
  perform 1 from public.businesses where id=v_header.business_id for share;
  if p_expected_snapshot_hash is null then raise exception 'expected snapshot hash is required' using errcode='22023'; end if;

  select * into v_existing from public.program_rules
   where rule_id=p_rule_id and config_version_id=p_config_version and business_id=v_header.business_id;
  if v_existing.id is null then
    -- Idempotent: already absent. Treat as a replay only when the caller's view is current.
    return jsonb_build_object('rule_id',p_rule_id,'config_version_id',p_config_version,'status','draft',
      'deleted',false,'replayed',true,'snapshot_hash',v_header.snapshot_hash);
  end if;
  if v_header.snapshot_hash is distinct from p_expected_snapshot_hash then
    raise exception 'draft configuration changed; reload before deleting' using errcode='40001';
  end if;

  delete from public.program_rules where id=v_existing.id;
  perform app.refresh_loyalty_config_snapshot(p_config_version);
  select snapshot_hash into v_hash from public.firm_config_versions where id=p_config_version;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_header.business_id, auth.uid(), 'DELETE_PROGRAM_RULE_DRAFT', 'program_rules', v_existing.id,
    jsonb_build_object('rule_id',p_rule_id,'config_version_id',p_config_version));
  return jsonb_build_object('rule_id',p_rule_id,'config_version_id',p_config_version,'status','draft',
    'deleted',true,'replayed',false,'snapshot_hash',v_hash);
end $$;

create or replace function public.get_rule_allowlists(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_result jsonb;
begin
  if not (app.is_salon_member(p_business) or app.is_super_admin()) then raise exception 'access denied' using errcode='42501'; end if;
  select jsonb_build_object(
    'schema_versions', coalesce((select jsonb_agg(jsonb_build_object('schema_version',schema_version,'status',status) order by schema_version) from public.rule_schema_versions),'[]'::jsonb),
    'events', coalesce((select jsonb_agg(distinct ev order by ev) from (
        select event_type ev from public.rule_condition_allowlist
        union select event_type from public.rule_effect_allowlist) s),'[]'::jsonb),
    'conditions', coalesce((select jsonb_agg(jsonb_build_object(
        'schema_version',schema_version,'event_type',event_type,'field',field,'value_type',value_type,
        'operators',to_jsonb(operators),'catalog_kind',catalog_kind
      ) order by schema_version,event_type,field) from public.rule_condition_allowlist),'[]'::jsonb),
    'effects', coalesce((select jsonb_agg(jsonb_build_object(
        'schema_version',schema_version,'event_type',event_type,'effect_type',effect_type,
        'requires_catalog_ref',requires_catalog_ref,'catalog_kind',catalog_kind,'moves_value',moves_value
      ) order by schema_version,event_type,effect_type) from public.rule_effect_allowlist),'[]'::jsonb)
  ) into v_result;
  return v_result;
end $$;

create or replace function public.get_program_rules_draft(p_config_version uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_header public.firm_config_versions%rowtype; v_result jsonb;
begin
  select * into v_header from public.firm_config_versions where id=p_config_version;
  if not found or not app.is_salon_owner(v_header.business_id) then raise exception 'owner only' using errcode='42501'; end if;
  if v_header.status<>'draft' then raise exception 'only a draft program rule set may be read' using errcode='42501'; end if;
  select jsonb_build_object(
    'config_version_id',v_header.id,'business_id',v_header.business_id,'version_no',v_header.version_no,
    'status',v_header.status,'snapshot_hash',v_header.snapshot_hash,
    'rules', coalesce((select jsonb_agg(jsonb_build_object(
        'rule_id',pr.rule_id,'program_rule_id',pr.id,'schema_version',pr.schema_version,'name',pr.name,'active',pr.active,
        'when_event',pr.when_event,'if_conditions',pr.if_conditions,'then_effects',pr.then_effects,
        'with_params',pr.with_params,'during_schedule',pr.during_schedule,'using_stacking',pr.using_stacking,
        'rule_hash',pr.rule_hash,'sort',pr.sort,'notes',pr.notes,
        'execution_state', app.ps1a_studio_rule_state(v_header.business_id, pr.id, v_header.status),
        'validation', public.validate_program_rule(v_header.business_id, jsonb_build_object(
          'schema_version',pr.schema_version,'when_event',pr.when_event,'if_conditions',pr.if_conditions,
          'then_effects',pr.then_effects,'with_params',pr.with_params,'during_schedule',pr.during_schedule,'using_stacking',pr.using_stacking))
      ) order by pr.sort, pr.rule_id) from public.program_rules pr where pr.config_version_id=p_config_version and pr.business_id=v_header.business_id),'[]'::jsonb),
    'allowlists', public.get_rule_allowlists(v_header.business_id)
  ) into v_result;
  return v_result;
end $$;

create or replace function public.get_programs_overview(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_active uuid; v_result jsonb;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then raise exception 'owner only' using errcode='42501'; end if;
  select active_config_version_id into v_active from public.businesses where id=p_business;
  select jsonb_build_object(
    'business_id', p_business,
    'active_config_version_id', v_active,
    'registry', coalesce((select jsonb_agg(jsonb_build_object(
        'source_engine',br.source_engine,'execution_authority',br.execution_authority,
        'cutover_status',br.cutover_status,'canonical_benefit_key_template',br.canonical_benefit_key_template
      ) order by br.source_engine) from public.benefit_registry br where br.business_id=p_business),'[]'::jsonb),
    'legacy_programs', coalesce((select jsonb_agg(jsonb_build_object(
        'source_engine',a.source_engine,'rule_key',a.rule_key,'synthetic_rule_id',a.synthetic_rule_id,
        'native_ref',a.native_ref,'name',a.name,'active',a.active,'when_event',a.when_event,
        'if_conditions',a.if_conditions,'then_effects',a.then_effects,'with_params',a.with_params,
        'during_schedule',a.during_schedule,'using_stacking',a.using_stacking,
        'execution_authority','legacy_trigger','execution_state',a.execution_state
      ) order by a.source_engine, a.rule_key) from public.v_program_rules_all a where a.business_id=p_business),'[]'::jsonb),
    'studio_rules', coalesce((select jsonb_agg(jsonb_build_object(
        'rule_id',s.rule_id,'program_rule_id',s.id,'config_version_id',s.config_version_id,
        'config_status',fv.status,'name',s.name,'active',s.active,'when_event',s.when_event,
        'if_conditions',s.if_conditions,'then_effects',s.then_effects,'with_params',s.with_params,
        'during_schedule',s.during_schedule,'using_stacking',s.using_stacking,'rule_hash',s.rule_hash,
        'source_engine','studio_rule','execution_authority','studio_executor',
        'execution_state', app.ps1a_studio_rule_state(s.business_id, s.id, fv.status)
      ) order by fv.status, s.sort, s.rule_id) from public.program_rules s
        join public.firm_config_versions fv on fv.id=s.config_version_id and fv.business_id=s.business_id
       where s.business_id=p_business and fv.status in ('draft','published')),'[]'::jsonb)
  ) into v_result;
  return v_result;
end $$;

-- Recompute every config-version snapshot so existing versions fold in the new
-- (empty) program_rules contribution consistently (mirrors v37b's refresh loop).
do $refresh_v55_snapshots$
declare v_id uuid;
begin
  for v_id in select id from public.firm_config_versions loop
    perform app.refresh_loyalty_config_snapshot(v_id);
  end loop;
end $refresh_v55_snapshots$;

-- =====================================================================
-- 9. Function ACLs. Browser roles get only the owner/member-gated RPCs; the
--    definer bodies do all privileged work. No RPC mutates benefit_registry
--    authority (there is none), matching the PS-1A "authoring only" contract.
-- =====================================================================
revoke all on function public.validate_program_rule(uuid, jsonb) from public, anon;
revoke all on function public.save_program_rule_draft(uuid, uuid, jsonb, text) from public, anon;
revoke all on function public.delete_program_rule_draft(uuid, uuid, text) from public, anon;
revoke all on function public.get_program_rules_draft(uuid) from public, anon;
revoke all on function public.get_rule_allowlists(uuid) from public, anon;
revoke all on function public.get_programs_overview(uuid) from public, anon;
revoke all on function public.publish_loyalty_config(uuid) from public, anon;

grant execute on function public.validate_program_rule(uuid, jsonb) to authenticated;
grant execute on function public.save_program_rule_draft(uuid, uuid, jsonb, text) to authenticated;
grant execute on function public.delete_program_rule_draft(uuid, uuid, text) to authenticated;
grant execute on function public.get_program_rules_draft(uuid) to authenticated;
grant execute on function public.get_rule_allowlists(uuid) to authenticated;
grant execute on function public.get_programs_overview(uuid) to authenticated;
grant execute on function public.publish_loyalty_config(uuid) to authenticated;

commit;
