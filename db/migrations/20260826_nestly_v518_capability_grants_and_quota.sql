-- NESTLY v518 - SUPERADMIN CAPABILITY GRANTS, SECTOR ELIGIBILITY AND MONTHLY QUOTA
--
-- Owner directive 2026-08-26: "a superadmin key to enable individual firms to use
-- any functions that we have, example - appointment notification through whatsapp
-- (only available for firms on spa/salon/massage modules) - and how many times
-- they able to use per month."
--
-- Three questions, one answer object:
--   (a) is this capability ON for this firm?
--   (b) is this firm even ELIGIBLE (industry / module)?
--   (c) how many uses per MONTH, and how many are left?
--
-- ===========================================================================
-- WHY THIS IS NEW CODE AND NOT AN EXTENSION OF v109
-- ===========================================================================
-- public.sector_policy_versions_v109 + business_sector_policy_overrides_v109 +
-- get_effective_sector_policy_v109 are, on paper, exactly this system: sector
-- defaults, per-firm overrides, effective dating, superadmin authorship. Their
-- policy_key is pinned by CHECK to the single value 'lapse_detection', and the
-- obvious move is to widen that CHECK.
--
-- I checked what that would cost, and it is too much:
--
--  1. BOTH entry points open with app.v109_require_feature(), which raises
--     0A000 unless the platform flag 'economics_driver_policy_v109' is enabled.
--     That flag is FALSE in production. Reusing v109 therefore means switching
--     on an entire revenue-driver economics subsystem - including
--     get_revenue_driver_decomposition_v109 and get_period_economics_v109 -
--     as a side effect of letting one firm send WhatsApp messages. A capability
--     grant must not be able to change how the platform computes revenue.
--  2. sector_policy_versions_v109 has FOUR not-null jsonb columns that are
--     meaningless here: evidence_basis, fallback_policy, suppression_rules,
--     limitations. They exist because a lapse-detection policy is a statistical
--     claim that must carry its evidence. A capability grant is not.
--
-- So v109 keeps its shape and its purpose, and this migration reuses the parts
-- of Peekaa that are genuinely free:
--
--   * app.v365_period_key(period, at) - the EXISTING period vocabulary and
--     bucketing, immutable and Asia/Singapore-anchored. This is the real reuse:
--     one period vocabulary with a second user, not a third invention. The v365
--     tier-benefit meter and this one now bucket time identically, by
--     construction rather than by convention.
--   * businesses.industry and businesses.enabled_modules for eligibility -
--     enabled_modules is the resolved output of the v75 sector entitlement, not
--     free text.
--   * app.v89_platform_can('automation', ...) for superadmin authorisation.
--   * The v104 setter shape: optimistic concurrency on a version column, plus
--     an audit row. (audit_log's jsonb column is `detail`, not `meta` - getting
--     that wrong raises 42703 and rolls back the whole RPC.)
--
-- ===========================================================================
-- SHAPE DECISIONS
-- ===========================================================================
-- THE METER IS AN APPEND-ONLY LEDGER, NOT A COUNTER. A counter cannot answer
-- "why was this firm charged 200 times" and cannot be reconciled after a
-- dispute. The ledger carries an idempotency key so a retried send consumes
-- once, and period_key is STORED, not derived on read - the v365 lesson at its
-- migration line 74: a later timezone or period change must not silently
-- re-open a limit that was already spent.
--
-- CONSUMPTION IS SERIALISED PER (FIRM, CAPABILITY) by a transaction-level
-- advisory lock. Without it, two concurrent sends at 199/200 both read 199 and
-- both insert, and the firm silently exceeds a cap the owner set. The lock is
-- taken only in the consume path, so reads stay lock-free.
--
-- ABSENCE IS NEVER PERMISSION. Every resolution step fails closed with a NAMED
-- reason, because "why did this firm not get the message" must be answerable
-- without reading code: capability_unknown / capability_inactive /
-- industry_not_eligible / module_not_enabled / not_enabled / quota_exhausted.
--
-- SEEDED CAPABILITY. whatsapp_appointment_notification ships requiring the
-- 'appointments' module - the genuine functional prerequisite, since a firm
-- without appointments has nothing to notify about - and DISABLED by default
-- with a 200/month limit. eligible_industries is left NULL (all industries)
-- deliberately: production industries are bar/facial/fnb/salon/test, there is
-- no 'spa' or 'massage' value today, and inventing a commercial restriction is
-- the owner's call, not mine. Narrowing it later is one UPDATE - see the note
-- at the seed.

begin;

-- ===========================================================================
-- 1. The registry - what capabilities exist. Platform-owned.
-- ===========================================================================

create table public.platform_capabilities_v518 (
  capability_key text primary key
    check (capability_key ~ '^[a-z][a-z0-9_]{2,63}$'),
  title text not null check (char_length(btrim(title)) between 1 and 120),
  description text,

  -- NULL means "every industry". A non-null array is an allowlist matched
  -- against businesses.industry.
  eligible_industries text[],
  -- Every listed module must be present in businesses.enabled_modules. NULL or
  -- empty means no module prerequisite.
  required_modules text[],

  default_enabled boolean not null default false,
  -- NULL limit_count means unlimited. The period vocabulary is v365's, enforced
  -- by the same CHECK so the two meters can never drift apart.
  default_limit_count integer check (default_limit_count is null or default_limit_count >= 0),
  default_limit_period text not null default 'month'
    check (default_limit_period in ('day','week','month','year','ever')),

  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.platform_capabilities_v518 is
  'v518 registry of platform capabilities a superadmin may grant per firm. Platform-owned: seeded by migration, never written by a tenant.';
comment on column public.platform_capabilities_v518.eligible_industries is
  'NULL = every industry. A non-null array is an allowlist matched against businesses.industry.';
comment on column public.platform_capabilities_v518.default_limit_count is
  'NULL = unlimited. Period bucketing uses app.v365_period_key, shared with the v365 tier-benefit meter.';

alter table public.platform_capabilities_v518 enable row level security;
revoke all privileges on table public.platform_capabilities_v518 from public, anon, authenticated;

-- ===========================================================================
-- 2. The per-firm grant - the superadmin's override of the registry default.
-- ===========================================================================

create table public.business_capability_grants_v518 (
  business_id uuid not null references public.businesses(id) on delete cascade,
  capability_key text not null references public.platform_capabilities_v518(capability_key) on delete restrict,

  -- Every override is NULLABLE and NULL means inherit. A firm with no row, and a
  -- firm with a row of all NULLs, resolve identically - so creating a row to
  -- write a note can never change behaviour.
  enabled boolean,
  limit_count integer check (limit_count is null or limit_count >= 0),
  limit_period text check (limit_period is null or limit_period in ('day','week','month','year','ever')),
  note text,

  -- v104's optimistic concurrency: a console that read version 3 cannot
  -- overwrite a change that took it to 4.
  version bigint not null default 1 check (version >= 1),
  granted_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (business_id, capability_key)
);

comment on table public.business_capability_grants_v518 is
  'v518 per-firm capability override. Superadmin-written only. Every column is nullable-means-inherit, so an all-NULL row is behaviourally identical to no row.';

alter table public.business_capability_grants_v518 enable row level security;
revoke all privileges on table public.business_capability_grants_v518 from public, anon, authenticated;

-- A firm may READ its own grant (it is about them, and the business-facing
-- allowance screen needs it). It may never write one.
create policy business_capability_grants_v518_own_read
  on public.business_capability_grants_v518 for select
  using (app.can_module_read(business_id, 'dashboard') or app.is_super_admin());

grant select on table public.business_capability_grants_v518 to authenticated;
grant select on table public.platform_capabilities_v518 to authenticated;
create policy platform_capabilities_v518_read
  on public.platform_capabilities_v518 for select using (true);

-- ===========================================================================
-- 3. The meter - append-only usage, one row per consumed use.
-- ===========================================================================

create table public.capability_usage_v518 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  capability_key text not null references public.platform_capabilities_v518(capability_key) on delete restrict,

  -- STORED, not derived. See the header: a later timezone or period-vocabulary
  -- change must not silently re-open a limit that was already spent.
  period_key text not null check (char_length(period_key) between 4 and 16),

  -- The caller's own idempotency token. A retried send consumes exactly once.
  idem_key text not null check (char_length(btrim(idem_key)) between 8 and 200),
  detail jsonb not null default '{}'::jsonb check (jsonb_typeof(detail) = 'object'),
  consumed_at timestamptz not null default now(),

  constraint capability_usage_v518_idem_uk unique (business_id, capability_key, idem_key)
);

comment on table public.capability_usage_v518 is
  'v518 append-only capability usage ledger. One row per consumed use. Counting is by (business_id, capability_key, period_key); period_key is stored so a spent limit can never silently re-open.';

create index capability_usage_v518_period_idx
  on public.capability_usage_v518 (business_id, capability_key, period_key);

alter table public.capability_usage_v518 enable row level security;
revoke all privileges on table public.capability_usage_v518 from public, anon, authenticated;

-- Append-only: reuse the v33 guard rather than declaring a second one.
create trigger capability_usage_v518_immutable
before update or delete on public.capability_usage_v518
for each row execute function app.v33_append_only_guard();

-- ===========================================================================
-- 4. The resolver - "may this firm use this right now, and how many are left?"
-- ===========================================================================

create or replace function app.capability_state_v518(
  p_business uuid,
  p_capability text,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_cap public.platform_capabilities_v518%rowtype;
  v_grant public.business_capability_grants_v518%rowtype;
  v_biz public.businesses%rowtype;
  v_enabled boolean;
  v_limit integer;
  v_period text;
  v_period_key text;
  v_used integer;
begin
  select * into v_cap from public.platform_capabilities_v518 where capability_key = p_capability;
  if not found then
    return jsonb_build_object('allowed', false, 'reason', 'capability_unknown');
  end if;
  if not v_cap.active then
    return jsonb_build_object('allowed', false, 'reason', 'capability_inactive');
  end if;

  select * into v_biz from public.businesses where id = p_business;
  if not found then
    return jsonb_build_object('allowed', false, 'reason', 'business_unknown');
  end if;

  -- (b) eligibility. Industry first, then modules — both fail closed with a
  -- reason the console can render without interpretation.
  if v_cap.eligible_industries is not null
     and not (v_biz.industry = any (v_cap.eligible_industries)) then
    return jsonb_build_object(
      'allowed', false, 'reason', 'industry_not_eligible',
      'industry', v_biz.industry, 'eligible_industries', to_jsonb(v_cap.eligible_industries));
  end if;

  if v_cap.required_modules is not null and array_length(v_cap.required_modules, 1) is not null
     and not (v_cap.required_modules <@ coalesce(v_biz.enabled_modules, array[]::text[])) then
    return jsonb_build_object(
      'allowed', false, 'reason', 'module_not_enabled',
      'required_modules', to_jsonb(v_cap.required_modules));
  end if;

  select * into v_grant from public.business_capability_grants_v518
   where business_id = p_business and capability_key = p_capability;

  -- (a) on/off. Absence inherits the registry default, which is false for
  -- anything that costs money.
  v_enabled := coalesce(v_grant.enabled, v_cap.default_enabled);
  v_limit   := coalesce(v_grant.limit_count, v_cap.default_limit_count);
  v_period  := coalesce(v_grant.limit_period, v_cap.default_limit_period);
  v_period_key := app.v365_period_key(v_period, p_at);

  select count(*)::integer into v_used
    from public.capability_usage_v518
   where business_id = p_business
     and capability_key = p_capability
     and period_key = v_period_key;

  if not v_enabled then
    return jsonb_build_object(
      'allowed', false, 'reason', 'not_enabled',
      'limit_count', v_limit, 'limit_period', v_period,
      'period_key', v_period_key, 'used', v_used);
  end if;

  -- (c) the number. A NULL limit is unlimited and reports remaining as null
  -- rather than as a large integer, so a console never renders a fake ceiling.
  if v_limit is not null and v_used >= v_limit then
    return jsonb_build_object(
      'allowed', false, 'reason', 'quota_exhausted',
      'limit_count', v_limit, 'limit_period', v_period,
      'period_key', v_period_key, 'used', v_used, 'remaining', 0);
  end if;

  return jsonb_build_object(
    'allowed', true, 'reason', 'ok',
    'limit_count', v_limit, 'limit_period', v_period,
    'period_key', v_period_key, 'used', v_used,
    'remaining', case when v_limit is null then null else v_limit - v_used end);
end
$fn$;

revoke all on function app.capability_state_v518(uuid, text, timestamptz)
  from public, anon, authenticated;

-- ===========================================================================
-- 5. The chokepoint - check and consume, atomically.
-- ===========================================================================

create or replace function app.capability_consume_v518(
  p_business uuid,
  p_capability text,
  p_idem_key text,
  p_detail jsonb default '{}'::jsonb,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_state jsonb;
  v_existing public.capability_usage_v518%rowtype;
  v_period_key text;
begin
  if coalesce(btrim(p_idem_key), '') = '' then
    raise exception 'capability consume requires an idempotency key' using errcode = '22023';
  end if;

  -- Serialise consumption for this (firm, capability) pair. Without this, two
  -- concurrent uses at 199/200 both read 199 and both insert. Transaction-level,
  -- so it releases on commit or rollback; the read path takes no lock.
  perform pg_advisory_xact_lock(
    hashtextextended(p_business::text || ':' || p_capability, 0));

  -- A retry must return the ORIGINAL outcome, not consume again. Checked inside
  -- the lock so two concurrent retries of the same key cannot both insert.
  select * into v_existing from public.capability_usage_v518
   where business_id = p_business and capability_key = p_capability and idem_key = p_idem_key;
  if found then
    v_state := app.capability_state_v518(p_business, p_capability, p_at);
    return jsonb_build_object(
      'consumed', true, 'duplicate', true, 'usage_id', v_existing.id,
      'period_key', v_existing.period_key,
      'remaining', v_state->'remaining');
  end if;

  v_state := app.capability_state_v518(p_business, p_capability, p_at);
  if not (v_state->>'allowed')::boolean then
    -- Refuse with the resolver's own named reason. The caller records it; the
    -- merchant sees "not enabled" or "quota used up", never a bare failure.
    return jsonb_build_object('consumed', false, 'duplicate', false) || v_state;
  end if;

  v_period_key := v_state->>'period_key';

  insert into public.capability_usage_v518(
    business_id, capability_key, period_key, idem_key, detail, consumed_at)
  values (p_business, p_capability, v_period_key, btrim(p_idem_key),
          coalesce(p_detail, '{}'::jsonb), p_at)
  returning * into v_existing;

  return jsonb_build_object(
    'consumed', true, 'duplicate', false, 'usage_id', v_existing.id,
    'period_key', v_period_key,
    'limit_count', v_state->'limit_count',
    'used', (v_state->>'used')::integer + 1,
    'remaining', case
      when v_state->'limit_count' = 'null'::jsonb or v_state->>'limit_count' is null then null
      else (v_state->>'limit_count')::integer - (v_state->>'used')::integer - 1 end);
end
$fn$;

revoke all on function app.capability_consume_v518(uuid, text, text, jsonb, timestamptz)
  from public, anon, authenticated;
grant execute on function app.capability_consume_v518(uuid, text, text, jsonb, timestamptz)
  to service_role;

-- ===========================================================================
-- 6. Superadmin write - the "key" the owner asked for.
-- ===========================================================================

create or replace function public.platform_set_capability_grant_v518(
  p_business uuid,
  p_capability text,
  p_enabled boolean,
  p_limit_count integer,
  p_limit_period text,
  p_note text,
  p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_current public.business_capability_grants_v518%rowtype;
  v_version bigint;
  v_actor uuid := auth.uid();
begin
  if not app.v89_platform_can('automation', 'rw') then
    raise exception 'platform automation write access required' using errcode = '42501';
  end if;
  if not exists (select 1 from public.platform_capabilities_v518 where capability_key = p_capability) then
    raise exception 'unknown capability' using errcode = '22023';
  end if;
  if p_limit_count is not null and p_limit_count < 0 then
    raise exception 'limit_count must not be negative' using errcode = '22023';
  end if;
  if p_limit_period is not null and p_limit_period not in ('day','week','month','year','ever') then
    raise exception 'unsupported limit period' using errcode = '22023';
  end if;

  select * into v_current from public.business_capability_grants_v518
   where business_id = p_business and capability_key = p_capability
   for update;

  -- v104's concurrency contract: absence is version 0.
  if coalesce(p_expected_version, 0) <> coalesce(v_current.version, 0) then
    raise exception 'capability grant changed since it was read' using errcode = '40001';
  end if;

  insert into public.business_capability_grants_v518(
    business_id, capability_key, enabled, limit_count, limit_period, note, version, granted_by)
  values (p_business, p_capability, p_enabled, p_limit_count, p_limit_period, p_note, 1, v_actor)
  on conflict (business_id, capability_key) do update
    set enabled = excluded.enabled,
        limit_count = excluded.limit_count,
        limit_period = excluded.limit_period,
        note = excluded.note,
        version = public.business_capability_grants_v518.version + 1,
        granted_by = v_actor,
        updated_at = now()
  returning version into v_version;

  -- audit_log's jsonb column is `detail`. Using `meta` raises 42703 and rolls
  -- back this whole RPC - it has caught three separate migrations.
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'capability_grant_set', 'business_capability_grants_v518', p_business,
    jsonb_build_object(
      'capability_key', p_capability, 'enabled', p_enabled,
      'limit_count', p_limit_count, 'limit_period', p_limit_period,
      'version', v_version));

  return jsonb_build_object('status', 'ok', 'version', v_version)
      || app.capability_state_v518(p_business, p_capability, now());
end
$fn$;

revoke all on function public.platform_set_capability_grant_v518(uuid, text, boolean, integer, text, text, bigint)
  from public, anon, authenticated;
grant execute on function public.platform_set_capability_grant_v518(uuid, text, boolean, integer, text, text, bigint)
  to authenticated, service_role;

-- ===========================================================================
-- 7. Superadmin read - one firm, every capability, with the live numbers.
-- ===========================================================================

create or replace function public.platform_get_capability_matrix_v518(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_rows jsonb;
begin
  if not app.v89_platform_can('automation', 'r') then
    raise exception 'platform automation read access required' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(entry order by entry->>'capability_key'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'capability_key', cap.capability_key,
      'title', cap.title,
      'description', cap.description,
      'active', cap.active,
      'eligible_industries', to_jsonb(cap.eligible_industries),
      'required_modules', to_jsonb(cap.required_modules),
      'default_enabled', cap.default_enabled,
      'default_limit_count', cap.default_limit_count,
      'default_limit_period', cap.default_limit_period,
      -- version is what the console must echo back to write safely
      'version', coalesce(grant_row.version, 0),
      'grant_enabled', grant_row.enabled,
      'grant_limit_count', grant_row.limit_count,
      'grant_limit_period', grant_row.limit_period,
      'note', grant_row.note,
      'state', app.capability_state_v518(p_business, cap.capability_key, now())
    ) as entry
    from public.platform_capabilities_v518 cap
    left join public.business_capability_grants_v518 grant_row
      on grant_row.business_id = p_business and grant_row.capability_key = cap.capability_key
  ) rows;

  return jsonb_build_object('business_id', p_business, 'capabilities', v_rows);
end
$fn$;

revoke all on function public.platform_get_capability_matrix_v518(uuid)
  from public, anon, authenticated;
grant execute on function public.platform_get_capability_matrix_v518(uuid) to authenticated, service_role;

-- ===========================================================================
-- 8. Business read - "43 of 200 used this month", for the firm itself.
-- ===========================================================================

create or replace function public.business_get_capability_v518(p_business uuid, p_capability text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
begin
  -- The firm's own dashboard read is the right gate: this is information about
  -- them, and it carries no other tenant's data.
  if not (app.can_module_read(p_business, 'dashboard') or app.v89_platform_can('automation', 'r')) then
    raise exception 'business access required' using errcode = '42501';
  end if;
  return app.capability_state_v518(p_business, p_capability, now());
end
$fn$;

revoke all on function public.business_get_capability_v518(uuid, text)
  from public, anon, authenticated;
grant execute on function public.business_get_capability_v518(uuid, text) to authenticated, service_role;

-- ===========================================================================
-- 9. The first capability.
-- ===========================================================================
--
-- required_modules = {appointments} is the genuine functional prerequisite: a
-- firm without the appointments module has nothing to notify anyone about.
--
-- eligible_industries is deliberately NULL (every industry). The owner's example
-- said "spa/salon/massage", but production industries are bar / facial / fnb /
-- salon / test - there is no 'spa' and no 'massage' value - and an fnb firm that
-- takes bookings has a legitimate claim to appointment reminders. Narrowing this
-- is a commercial decision and a ONE-LINE UPDATE, e.g.
--   update public.platform_capabilities_v518
--      set eligible_industries = array['salon','facial']
--    where capability_key = 'whatsapp_appointment_notification';
--
-- default_enabled = false: nothing that costs money per use is ever on by
-- default. 200/month is a placeholder ceiling, not a price - no commercial rate
-- is expressed anywhere in this migration.

insert into public.platform_capabilities_v518(
  capability_key, title, description,
  eligible_industries, required_modules,
  default_enabled, default_limit_count, default_limit_period, active)
values (
  'whatsapp_appointment_notification',
  'WhatsApp appointment notifications',
  'Appointment confirmations, reminders, reschedules and cancellations sent to the customer over WhatsApp from the Peekaa sender.',
  null,
  array['appointments'],
  false, 200, 'month', true)
on conflict (capability_key) do nothing;

commit;
