-- FRENLY v65 - PS-2 LIVE INCREMENT 1: TOP-UP PLAN CONFIGURATION (rev 2, post CHANGES REQUIRED)
--
-- RELEASE APPROVED (owner, 2026-07-24) for the Stored Value / Top-Ups pilot arc. First forward
-- migration after the reviewed v61-v64 foundation. Implements directive Sec 1 (Top-Up Plan
-- Configuration) + Sec 12 economics surface. Pinned contract:
-- docs/design/ps2/PS2_LIVE_V65_PLAN_CONFIG_CONTRACT.md (rev 2).
--
-- FORWARD-ONLY: v61-v64 files/statements are NOT rewritten; v65 only ADDs. A top-up plan is
-- CONFIGURATION, not value: every configuration action writes ZERO sv_lot_movements / sv_lots and
-- never transitions sv_authority (stays 'unbuilt'). No cutover, no UI in this increment.
--
-- rev-2 corrections (independent review CHANGES REQUIRED, all 15):
--   1  sv_plan_versions stays FULLY immutable (v61 sv_immutable_guard rejects all UPDATE/DELETE);
--      retirement/reactivation live on the mutable sv_plans container + an append-only
--      sv_plan_status_events log. No retired_at column on the version.
--   2  a top-up plan requires price_cents > 0 (typed 22023 before insert; v61 already CHECKs it).
--   3  set_sv_plan_guardrails owner RPC; reads coalesce to usable defaults (no raw SQL needed).
--   4  eligibility validated + canonicalised (membership+active, dedupe+sort; empty array rejected;
--      null = all; cross-tenant -> typed error).
--   5  strict config patch: unknown keys / wrong types / malformed scalars -> typed 22023; JSON null
--      clears only nullable fields; text trimmed + length-bounded.
--   6  optimistic concurrency: sv_plan_drafts.revision + expected_revision on update/publish/discard.
--   7  publish locks the sv_plans row before max(version_no)+1; deterministic replay/conflict.
--   8  circular draft<->version FKs + one-draft-one-version uniqueness, satisfied atomically.
--   9  explicit points policy: topup_purchase_earns_points + stored_value_spend_earns_points.
--   10 purchase window pair both-or-neither; max_balance must fit >= one purchase.
--   11 publish-readiness validation; preview returns validation_errors/warnings/override_required/publishable.
--   12 full lifecycle: discard / clone-to-draft / retire / reactivate; no silent reactivation.
--   13 get_sv_plans returns the COMPLETE immutable config + status history + guardrails.
--   14 idempotency envelope (sv_plan_operations) on every owner state change; actor+hash+result kept.

begin;

-- =====================================================================
-- 1. sv_plan_guardrails - configurable, firm-scoped sanity limits. Reads coalesce to 3000/7000 when
--    absent (usable defaults, no raw SQL). Owner mutates via set_sv_plan_guardrails (Sec 3).
-- =====================================================================
create table public.sv_plan_guardrails (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  warn_discount_bps integer not null default 3000 check (warn_discount_bps between 0 and 10000),
  hard_discount_bps integer not null default 7000 check (hard_discount_bps between 0 and 10000),
  updated_at timestamptz not null default now(),
  constraint sv_plan_guardrails_ordering check (hard_discount_bps >= warn_discount_bps)
);
alter table public.sv_plan_guardrails enable row level security;
create policy sv_plan_guardrails_owner_read on public.sv_plan_guardrails for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_plan_guardrails_sa_read on public.sv_plan_guardrails for select to authenticated using (app.is_super_admin());
revoke all on public.sv_plan_guardrails from public, anon, authenticated;
grant select on public.sv_plan_guardrails to authenticated;

-- =====================================================================
-- 2. sv_plan_operations - idempotency envelope for every owner state change (Sec 14). Append-only.
-- =====================================================================
create table public.sv_plan_operations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  op_type text not null,
  idempotency_key uuid not null,
  request_hash text not null,
  actor uuid,
  result jsonb not null,
  created_at timestamptz not null default now(),
  constraint sv_plan_operations_key_uk unique (business_id, op_type, idempotency_key)
);
create trigger sv_plan_operations_immutable_guard
  before update or delete on public.sv_plan_operations
  for each row execute function app.sv_immutable_guard();
alter table public.sv_plan_operations enable row level security;
create policy sv_plan_operations_owner_read on public.sv_plan_operations for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_plan_operations_sa_read on public.sv_plan_operations for select to authenticated using (app.is_super_admin());
revoke all on public.sv_plan_operations from public, anon, authenticated;
grant select on public.sv_plan_operations to authenticated;

-- =====================================================================
-- 3. sv_plan_status_events - append-only plan lifecycle log (Sec 1/12). Retirement/reactivation of
--    the sv_plans container is recorded here; sv_plan_versions is never touched.
-- =====================================================================
create table public.sv_plan_status_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  plan_id uuid not null,
  actor uuid,
  prior_status text,
  new_status text not null check (new_status in ('active','retired')),
  reason text,
  created_at timestamptz not null default now(),
  constraint sv_plan_status_events_plan_fk foreign key (plan_id, business_id)
    references public.sv_plans(id, business_id) on delete cascade
);
create index sv_plan_status_events_plan_idx on public.sv_plan_status_events (business_id, plan_id, created_at);
create trigger sv_plan_status_events_immutable_guard
  before update or delete on public.sv_plan_status_events
  for each row execute function app.sv_immutable_guard();
alter table public.sv_plan_status_events enable row level security;
create policy sv_plan_status_events_owner_read on public.sv_plan_status_events for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_plan_status_events_sa_read on public.sv_plan_status_events for select to authenticated using (app.is_super_admin());
revoke all on public.sv_plan_status_events from public, anon, authenticated;
grant select on public.sv_plan_status_events to authenticated;

-- =====================================================================
-- 4. sv_plan_drafts - the mutable editing surface. revision drives optimistic concurrency; the two
--    points-policy flags are explicit. Editable only while status='draft' (guard).
-- =====================================================================
create table public.sv_plan_drafts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  plan_id uuid,
  status text not null default 'draft' check (status in ('draft','published','discarded')),
  revision integer not null default 0,
  actor uuid,
  customer_facing_name text not null default '',
  price_cents integer not null default 0 check (price_cents >= 0),
  bonus_cents integer not null default 0 check (bonus_cents >= 0),
  paid_expiry_days integer check (paid_expiry_days is null or paid_expiry_days > 0),
  bonus_expiry_days integer check (bonus_expiry_days is null or bonus_expiry_days > 0),
  eligible_branch_ids uuid[],
  eligible_service_ids uuid[],
  eligible_product_ids uuid[],
  eligible_service_categories text[],
  min_spend_cents integer check (min_spend_cents is null or min_spend_cents >= 0),
  stacking_policy text not null default 'stackable' check (stacking_policy in ('stackable','not_with_other_discounts','exclusive')),
  max_balance_cents integer check (max_balance_cents is null or max_balance_cents >= 0),
  purchase_window_days integer check (purchase_window_days is null or purchase_window_days > 0),
  purchase_max_in_window integer check (purchase_max_in_window is null or purchase_max_in_window > 0),
  purchase_lifetime_cap integer check (purchase_lifetime_cap is null or purchase_lifetime_cap > 0),
  refund_policy text not null default 'proportional' check (refund_policy in ('full_unused','proportional','unused_only','no_refund')),
  spend_order text not null default 'proportional' check (spend_order in ('bonus_first','paid_first','earliest_expiry_first','proportional')),
  topup_purchase_earns_points boolean not null default false,
  stored_value_spend_earns_points boolean not null default false,
  customer_terms text,
  accounting_inputs jsonb not null default '{}'::jsonb,
  effective_at timestamptz,
  published_version_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sv_plan_drafts_id_business_uk unique (id, business_id),
  constraint sv_plan_drafts_plan_fk foreign key (plan_id, business_id)
    references public.sv_plans(id, business_id) on delete restrict
);
create index sv_plan_drafts_business_status_idx on public.sv_plan_drafts (business_id, status, created_at desc);

create or replace function app.sv_plan_drafts_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'sv_plan_drafts is append-only (discard, never delete)' using errcode = 'restrict_violation';
  end if;
  if old.status <> 'draft' then
    raise exception 'stored-value plan draft is % and can no longer be edited', old.status using errcode = 'restrict_violation';
  end if;
  if new.business_id is distinct from old.business_id or new.created_at is distinct from old.created_at then
    raise exception 'stored-value plan draft identity is immutable' using errcode = 'restrict_violation';
  end if;
  if new.status not in ('draft','published','discarded') then
    raise exception 'stored-value plan draft status must be draft/published/discarded' using errcode = 'restrict_violation';
  end if;
  new.updated_at := now();
  return new;
end $$;
revoke all on function app.sv_plan_drafts_guard() from public, anon, authenticated;
create trigger sv_plan_drafts_guard before update or delete on public.sv_plan_drafts
  for each row execute function app.sv_plan_drafts_guard();

alter table public.sv_plan_drafts enable row level security;
create policy sv_plan_drafts_owner_read on public.sv_plan_drafts for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_plan_drafts_sa_read on public.sv_plan_drafts for select to authenticated using (app.is_super_admin());
revoke all on public.sv_plan_drafts from public, anon, authenticated;
grant select on public.sv_plan_drafts to authenticated;

-- =====================================================================
-- 5. ALTER sv_plan_versions - immutable published snapshot gains every Sec 1 config field (all set
--    at INSERT; the v61 guard forbids later UPDATE, so these are frozen). NO retired_at (Sec 1 fix).
-- =====================================================================
alter table public.sv_plan_versions
  add column customer_facing_name text,
  add column paid_expiry_days integer check (paid_expiry_days is null or paid_expiry_days > 0),
  add column bonus_expiry_days integer check (bonus_expiry_days is null or bonus_expiry_days > 0),
  add column eligible_branch_ids uuid[],
  add column eligible_service_ids uuid[],
  add column eligible_product_ids uuid[],
  add column eligible_service_categories text[],
  add column min_spend_cents integer check (min_spend_cents is null or min_spend_cents >= 0),
  add column stacking_policy text check (stacking_policy is null or stacking_policy in ('stackable','not_with_other_discounts','exclusive')),
  add column max_balance_cents integer check (max_balance_cents is null or max_balance_cents >= 0),
  add column purchase_window_days integer check (purchase_window_days is null or purchase_window_days > 0),
  add column purchase_max_in_window integer check (purchase_max_in_window is null or purchase_max_in_window > 0),
  add column purchase_lifetime_cap integer check (purchase_lifetime_cap is null or purchase_lifetime_cap > 0),
  add column refund_policy text check (refund_policy is null or refund_policy in ('full_unused','proportional','unused_only','no_refund')),
  add column spend_order text check (spend_order is null or spend_order in ('bonus_first','paid_first','earliest_expiry_first','proportional')),
  add column topup_purchase_earns_points boolean,
  add column stored_value_spend_earns_points boolean,
  add column customer_terms text,
  add column accounting_inputs jsonb,
  add column effective_at timestamptz,
  add column source_draft_id uuid;

-- circular relationships (Sec 8), created after both tables exist. One draft -> at most one version.
create unique index sv_plan_versions_source_draft_uk on public.sv_plan_versions (source_draft_id) where source_draft_id is not null;
alter table public.sv_plan_versions
  add constraint sv_plan_versions_source_draft_fk foreign key (source_draft_id, business_id)
    references public.sv_plan_drafts (id, business_id) on delete set null;
alter table public.sv_plan_drafts
  add constraint sv_plan_drafts_published_version_fk foreign key (published_version_id, business_id)
    references public.sv_plan_versions (id, business_id) on delete set null;

-- =====================================================================
-- 6. Pure/utility helpers.
-- =====================================================================
create or replace function app.sv_plan_effective_discount_bps(p_price integer, p_bonus integer)
returns integer language sql immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select case when coalesce(p_price,0) + coalesce(p_bonus,0) = 0 then 0
              else round(coalesce(p_bonus,0)::numeric * 10000 / (coalesce(p_price,0) + coalesce(p_bonus,0)))::integer end
$$;
revoke all on function app.sv_plan_effective_discount_bps(integer, integer) from public, anon, authenticated;

create or replace function app.sv_jsonb_is_int(v jsonb)
returns boolean language sql immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$ select v is not null and jsonb_typeof(v) = 'number' and (v#>>'{}') ~ '^-?[0-9]+$' $$;
revoke all on function app.sv_jsonb_is_int(jsonb) from public, anon, authenticated;

-- canonical (distinct + sorted) uuid[] from a jsonb array; null passthrough; typed error otherwise.
create or replace function app.sv_canon_uuid_array(v jsonb)
returns uuid[] language plpgsql immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare r uuid[];
begin
  if v is null or jsonb_typeof(v) = 'null' then return null; end if;
  if jsonb_typeof(v) <> 'array' then raise exception 'expected a JSON array of ids' using errcode = '22023'; end if;
  begin
    select array(select distinct e::uuid from jsonb_array_elements_text(v) e order by e::uuid) into r;
  exception when others then raise exception 'eligibility ids must be valid UUIDs' using errcode = '22023'; end;
  return r;
end $$;
revoke all on function app.sv_canon_uuid_array(jsonb) from public, anon, authenticated;

create or replace function app.sv_canon_text_array(v jsonb)
returns text[] language plpgsql immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare r text[];
begin
  if v is null or jsonb_typeof(v) = 'null' then return null; end if;
  if jsonb_typeof(v) <> 'array' then raise exception 'expected a JSON array of text' using errcode = '22023'; end if;
  select array(select distinct btrim(e) from jsonb_array_elements_text(v) e where btrim(e) <> '' order by btrim(e)) into r;
  return r;
end $$;
revoke all on function app.sv_canon_text_array(jsonb) from public, anon, authenticated;

-- =====================================================================
-- 7. app.sv_plan_assert_config - STRICT patch validation (Sec 5). Rejects unknown keys, wrong JSON
--    types, malformed scalars, empty eligibility arrays, over-long text. JSON null is allowed only
--    for nullable fields (it clears them). plan_id is allowed only on create.
-- =====================================================================
create or replace function app.sv_plan_assert_config(p_config jsonb, p_allow_plan_id boolean)
returns void language plpgsql immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  k text;
  v jsonb;
  allowed text[] := array['customer_facing_name','price_cents','bonus_cents','paid_expiry_days',
    'bonus_expiry_days','eligible_branch_ids','eligible_service_ids','eligible_product_ids',
    'eligible_service_categories','min_spend_cents','stacking_policy','max_balance_cents',
    'purchase_window_days','purchase_max_in_window','purchase_lifetime_cap','refund_policy',
    'spend_order','topup_purchase_earns_points','stored_value_spend_earns_points','customer_terms',
    'accounting_inputs','effective_at'];
  nullable_int text[] := array['paid_expiry_days','bonus_expiry_days','min_spend_cents','max_balance_cents',
    'purchase_window_days','purchase_max_in_window','purchase_lifetime_cap'];
  arr_uuid text[] := array['eligible_branch_ids','eligible_service_ids','eligible_product_ids'];
begin
  if p_config is null or jsonb_typeof(p_config) <> 'object' then
    raise exception 'plan configuration must be a JSON object' using errcode = '22023';
  end if;
  if p_allow_plan_id then allowed := array_append(allowed, 'plan_id'); end if;

  for k, v in select key, value from jsonb_each(p_config) loop
    if not (k = any(allowed)) then
      raise exception 'unknown plan configuration key: %', k using errcode = '22023';
    end if;

    if k = 'plan_id' then
      if jsonb_typeof(v) <> 'string' then raise exception 'plan_id must be a UUID string' using errcode = '22023'; end if;
    elsif k in ('price_cents','bonus_cents') then
      if not app.sv_jsonb_is_int(v) then raise exception '% must be a whole number', k using errcode = '22023'; end if;
      if (v#>>'{}')::bigint < 0 then raise exception '% cannot be negative', k using errcode = '22023'; end if;
    elsif k = any(nullable_int) then
      if jsonb_typeof(v) <> 'null' then
        if not app.sv_jsonb_is_int(v) then raise exception '% must be a whole number or null', k using errcode = '22023'; end if;
        if k in ('paid_expiry_days','bonus_expiry_days','purchase_window_days','purchase_max_in_window','purchase_lifetime_cap')
           and (v#>>'{}')::bigint <= 0 then raise exception '% must be a positive whole number', k using errcode = '22023'; end if;
        if k in ('min_spend_cents','max_balance_cents') and (v#>>'{}')::bigint < 0 then
          raise exception '% cannot be negative', k using errcode = '22023'; end if;
      end if;
    elsif k = any(arr_uuid) then
      if jsonb_typeof(v) not in ('array','null') then raise exception '% must be a JSON array of ids or null', k using errcode = '22023'; end if;
      if jsonb_typeof(v) = 'array' and jsonb_array_length(v) = 0 then
        raise exception '% cannot be an empty list (use null to mean all, or list at least one)', k using errcode = '22023'; end if;
    elsif k = 'eligible_service_categories' then
      if jsonb_typeof(v) not in ('array','null') then raise exception 'eligible_service_categories must be a JSON array or null' using errcode = '22023'; end if;
      if jsonb_typeof(v) = 'array' and jsonb_array_length(v) = 0 then
        raise exception 'eligible_service_categories cannot be an empty list (use null to mean all)' using errcode = '22023'; end if;
    elsif k = 'stacking_policy' then
      if jsonb_typeof(v) <> 'string' or (v#>>'{}') not in ('stackable','not_with_other_discounts','exclusive') then
        raise exception 'stacking_policy must be stackable/not_with_other_discounts/exclusive' using errcode = '22023'; end if;
    elsif k = 'refund_policy' then
      if jsonb_typeof(v) <> 'string' or (v#>>'{}') not in ('full_unused','proportional','unused_only','no_refund') then
        raise exception 'refund_policy must be full_unused/proportional/unused_only/no_refund' using errcode = '22023'; end if;
    elsif k = 'spend_order' then
      if jsonb_typeof(v) <> 'string' or (v#>>'{}') not in ('bonus_first','paid_first','earliest_expiry_first','proportional') then
        raise exception 'spend_order must be bonus_first/paid_first/earliest_expiry_first/proportional' using errcode = '22023'; end if;
    elsif k in ('topup_purchase_earns_points','stored_value_spend_earns_points') then
      if jsonb_typeof(v) <> 'boolean' then raise exception '% must be true or false', k using errcode = '22023'; end if;
    elsif k = 'customer_facing_name' then
      if jsonb_typeof(v) <> 'string' then raise exception 'customer_facing_name must be text' using errcode = '22023'; end if;
      if char_length(btrim(v#>>'{}')) > 200 then raise exception 'customer_facing_name is too long (max 200 chars)' using errcode = '22023'; end if;
    elsif k = 'customer_terms' then
      if jsonb_typeof(v) not in ('string','null') then raise exception 'customer_terms must be text or null' using errcode = '22023'; end if;
      if jsonb_typeof(v) = 'string' and char_length(v#>>'{}') > 5000 then raise exception 'customer_terms is too long (max 5000 chars)' using errcode = '22023'; end if;
    elsif k = 'accounting_inputs' then
      if jsonb_typeof(v) <> 'object' then raise exception 'accounting_inputs must be a JSON object' using errcode = '22023'; end if;
    elsif k = 'effective_at' then
      if jsonb_typeof(v) not in ('string','null') then raise exception 'effective_at must be a timestamp string or null' using errcode = '22023'; end if;
      if jsonb_typeof(v) = 'string' then
        begin perform (v#>>'{}')::timestamptz; exception when others then raise exception 'effective_at is not a valid timestamp' using errcode = '22023'; end;
      end if;
    end if;
  end loop;
end $$;
revoke all on function app.sv_plan_assert_config(jsonb, boolean) from public, anon, authenticated;

-- =====================================================================
-- 8. app.sv_plan_apply_config - assert then write. Missing key = unchanged; JSON null = clear a
--    nullable field; arrays canonicalised (distinct+sorted); text trimmed.
-- =====================================================================
create or replace function app.sv_plan_apply_config(p_business uuid, p_draft uuid, p_config jsonb)
returns void language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v jsonb := coalesce(p_config, '{}'::jsonb);
begin
  perform app.sv_plan_assert_config(v, false);
  update public.sv_plan_drafts d set
    customer_facing_name = case when v ? 'customer_facing_name' then btrim(v->>'customer_facing_name') else d.customer_facing_name end,
    price_cents          = case when v ? 'price_cents' then (v->>'price_cents')::integer else d.price_cents end,
    bonus_cents          = case when v ? 'bonus_cents' then (v->>'bonus_cents')::integer else d.bonus_cents end,
    paid_expiry_days     = case when not (v ? 'paid_expiry_days') then d.paid_expiry_days when jsonb_typeof(v->'paid_expiry_days')='null' then null else (v->>'paid_expiry_days')::integer end,
    bonus_expiry_days    = case when not (v ? 'bonus_expiry_days') then d.bonus_expiry_days when jsonb_typeof(v->'bonus_expiry_days')='null' then null else (v->>'bonus_expiry_days')::integer end,
    eligible_branch_ids  = case when not (v ? 'eligible_branch_ids') then d.eligible_branch_ids else app.sv_canon_uuid_array(v->'eligible_branch_ids') end,
    eligible_service_ids = case when not (v ? 'eligible_service_ids') then d.eligible_service_ids else app.sv_canon_uuid_array(v->'eligible_service_ids') end,
    eligible_product_ids = case when not (v ? 'eligible_product_ids') then d.eligible_product_ids else app.sv_canon_uuid_array(v->'eligible_product_ids') end,
    eligible_service_categories = case when not (v ? 'eligible_service_categories') then d.eligible_service_categories else app.sv_canon_text_array(v->'eligible_service_categories') end,
    min_spend_cents      = case when not (v ? 'min_spend_cents') then d.min_spend_cents when jsonb_typeof(v->'min_spend_cents')='null' then null else (v->>'min_spend_cents')::integer end,
    stacking_policy      = case when v ? 'stacking_policy' then v->>'stacking_policy' else d.stacking_policy end,
    max_balance_cents    = case when not (v ? 'max_balance_cents') then d.max_balance_cents when jsonb_typeof(v->'max_balance_cents')='null' then null else (v->>'max_balance_cents')::integer end,
    purchase_window_days = case when not (v ? 'purchase_window_days') then d.purchase_window_days when jsonb_typeof(v->'purchase_window_days')='null' then null else (v->>'purchase_window_days')::integer end,
    purchase_max_in_window = case when not (v ? 'purchase_max_in_window') then d.purchase_max_in_window when jsonb_typeof(v->'purchase_max_in_window')='null' then null else (v->>'purchase_max_in_window')::integer end,
    purchase_lifetime_cap = case when not (v ? 'purchase_lifetime_cap') then d.purchase_lifetime_cap when jsonb_typeof(v->'purchase_lifetime_cap')='null' then null else (v->>'purchase_lifetime_cap')::integer end,
    refund_policy        = case when v ? 'refund_policy' then v->>'refund_policy' else d.refund_policy end,
    spend_order          = case when v ? 'spend_order' then v->>'spend_order' else d.spend_order end,
    topup_purchase_earns_points     = case when v ? 'topup_purchase_earns_points' then (v->>'topup_purchase_earns_points')::boolean else d.topup_purchase_earns_points end,
    stored_value_spend_earns_points = case when v ? 'stored_value_spend_earns_points' then (v->>'stored_value_spend_earns_points')::boolean else d.stored_value_spend_earns_points end,
    customer_terms       = case when not (v ? 'customer_terms') then d.customer_terms when jsonb_typeof(v->'customer_terms')='null' then null else btrim(v->>'customer_terms') end,
    accounting_inputs    = case when v ? 'accounting_inputs' then v->'accounting_inputs' else d.accounting_inputs end,
    effective_at         = case when not (v ? 'effective_at') then d.effective_at when jsonb_typeof(v->'effective_at')='null' then null else (v->>'effective_at')::timestamptz end
  where d.id = p_draft and d.business_id = p_business;
end $$;
revoke all on function app.sv_plan_apply_config(uuid, uuid, jsonb) from public, anon, authenticated;

-- =====================================================================
-- 9. app.sv_plan_validate - shared publish-readiness check (Sec 10/11). Returns validation_errors
--    (structural, block publish), warnings (overridable), effective_discount_bps, override_required,
--    publishable. Eligibility membership+active checked here (needs table lookups).
-- =====================================================================
create or replace function app.sv_plan_validate(p_business uuid, p_draft uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  d public.sv_plan_drafts%rowtype;
  v_errors text[] := '{}';
  v_warnings text[] := '{}';
  v_warn integer; v_hard integer; v_disc integer;
  v_total integer;
begin
  select * into d from public.sv_plan_drafts where id = p_draft and business_id = p_business;
  if not found then raise exception 'stored-value plan draft not found in this business' using errcode = '22023'; end if;
  v_total := d.price_cents + d.bonus_cents;
  v_disc := app.sv_plan_effective_discount_bps(d.price_cents, d.bonus_cents);
  select coalesce(warn_discount_bps,3000), coalesce(hard_discount_bps,7000) into v_warn, v_hard
    from public.sv_plan_guardrails where business_id = p_business;
  v_warn := coalesce(v_warn,3000); v_hard := coalesce(v_hard,7000);

  -- structural errors
  if d.price_cents <= 0 then v_errors := array_append(v_errors, 'a top-up plan must have a positive paid amount (a zero-paid promo is a grant, not a top-up)'); end if;
  if btrim(d.customer_facing_name) = '' then v_errors := array_append(v_errors, 'a customer-facing name is required'); end if;
  if d.customer_terms is null or btrim(d.customer_terms) = '' then v_errors := array_append(v_errors, 'customer-facing terms are required for a live-pilot plan'); end if;
  if (d.purchase_window_days is null) <> (d.purchase_max_in_window is null) then
    v_errors := array_append(v_errors, 'purchase window days and max-in-window must be set together or both left empty'); end if;
  if d.max_balance_cents is not null and d.max_balance_cents < v_total then
    v_errors := array_append(v_errors, 'maximum balance is smaller than one purchase total - no customer could ever buy this plan'); end if;

  -- eligibility integrity (cross-tenant / inactive)
  if d.eligible_branch_ids is not null then
    if exists (select 1 from unnest(d.eligible_branch_ids) x where not exists (select 1 from public.branches b where b.id = x and b.business_id = p_business)) then
      v_errors := array_append(v_errors, 'one or more eligible branches do not belong to this business');
    elsif exists (select 1 from unnest(d.eligible_branch_ids) x join public.branches b on b.id = x and b.business_id = p_business where not b.active) then
      v_errors := array_append(v_errors, 'one or more eligible branches are inactive'); end if;
  end if;
  if d.eligible_service_ids is not null then
    if exists (select 1 from unnest(d.eligible_service_ids) x where not exists (select 1 from public.services s where s.id = x and s.business_id = p_business)) then
      v_errors := array_append(v_errors, 'one or more eligible services do not belong to this business');
    elsif exists (select 1 from unnest(d.eligible_service_ids) x join public.services s on s.id = x and s.business_id = p_business where not s.active) then
      v_errors := array_append(v_errors, 'one or more eligible services are inactive'); end if;
  end if;
  if d.eligible_product_ids is not null then
    if exists (select 1 from unnest(d.eligible_product_ids) x where not exists (select 1 from public.products p where p.id = x and p.business_id = p_business)) then
      v_errors := array_append(v_errors, 'one or more eligible products do not belong to this business');
    elsif exists (select 1 from unnest(d.eligible_product_ids) x join public.products p on p.id = x and p.business_id = p_business where not p.active) then
      v_errors := array_append(v_errors, 'one or more eligible products are inactive'); end if;
  end if;

  -- warnings (overridable)
  if d.bonus_cents > d.price_cents and d.price_cents > 0 then v_warnings := array_append(v_warnings, 'the bonus exceeds the amount paid'); end if;
  if d.max_balance_cents is null then v_warnings := array_append(v_warnings, 'no maximum customer balance is set'); end if;
  if d.paid_expiry_days is null and d.bonus_expiry_days is null then v_warnings := array_append(v_warnings, 'neither paid nor bonus value expires'); end if;
  if d.eligible_service_categories is not null and not exists (
       select 1 from public.services s where s.business_id = p_business and s.category = any(d.eligible_service_categories)) then
    v_warnings := array_append(v_warnings, 'no active service currently matches the chosen service categories'); end if;
  if v_disc >= v_hard then v_warnings := array_append(v_warnings, 'effective discount is at or above the firm hard limit ('||(v_hard/100.0)||'%) - an override reason is required to publish');
  elsif v_disc >= v_warn then v_warnings := array_append(v_warnings, 'effective discount is at or above the firm warning limit ('||(v_warn/100.0)||'%)'); end if;

  return jsonb_build_object(
    'effective_discount_bps', v_disc, 'warn_threshold_bps', v_warn, 'hard_threshold_bps', v_hard,
    'override_required', (v_disc >= v_hard),
    'validation_errors', to_jsonb(v_errors), 'warnings', to_jsonb(v_warnings),
    'publishable', (array_length(v_errors,1) is null));
end $$;
revoke all on function app.sv_plan_validate(uuid, uuid) from public, anon, authenticated;

-- =====================================================================
-- 10. Render helpers (one shape for create/update/preview/get).
-- =====================================================================
create or replace function app.sv_plan_draft_json(p public.sv_plan_drafts)
returns jsonb language sql stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select jsonb_build_object(
    'draft_id', p.id, 'business_id', p.business_id, 'plan_id', p.plan_id, 'status', p.status,
    'revision', p.revision, 'customer_facing_name', p.customer_facing_name,
    'price_cents', p.price_cents, 'bonus_cents', p.bonus_cents,
    'total_usable_cents', p.price_cents + p.bonus_cents,
    'effective_discount_bps', app.sv_plan_effective_discount_bps(p.price_cents, p.bonus_cents),
    'paid_expiry_days', p.paid_expiry_days, 'bonus_expiry_days', p.bonus_expiry_days,
    'eligible_branch_ids', to_jsonb(p.eligible_branch_ids), 'eligible_service_ids', to_jsonb(p.eligible_service_ids),
    'eligible_product_ids', to_jsonb(p.eligible_product_ids), 'eligible_service_categories', to_jsonb(p.eligible_service_categories),
    'min_spend_cents', p.min_spend_cents, 'stacking_policy', p.stacking_policy, 'max_balance_cents', p.max_balance_cents,
    'purchase_window_days', p.purchase_window_days, 'purchase_max_in_window', p.purchase_max_in_window,
    'purchase_lifetime_cap', p.purchase_lifetime_cap, 'refund_policy', p.refund_policy, 'spend_order', p.spend_order,
    'topup_purchase_earns_points', p.topup_purchase_earns_points, 'stored_value_spend_earns_points', p.stored_value_spend_earns_points,
    'customer_terms', p.customer_terms, 'accounting_inputs', p.accounting_inputs, 'effective_at', p.effective_at,
    'published_version_id', p.published_version_id)
$$;
revoke all on function app.sv_plan_draft_json(public.sv_plan_drafts) from public, anon, authenticated;

create or replace function app.sv_plan_version_json(p public.sv_plan_versions)
returns jsonb language sql stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select jsonb_build_object(
    'version_id', p.id, 'version_no', p.version_no, 'customer_facing_name', p.customer_facing_name,
    'price_cents', p.price_cents, 'bonus_cents', p.bonus_cents, 'total_usable_cents', p.price_cents + p.bonus_cents,
    'effective_discount_bps', app.sv_plan_effective_discount_bps(p.price_cents, p.bonus_cents),
    'paid_expiry_days', p.paid_expiry_days, 'bonus_expiry_days', p.bonus_expiry_days,
    'eligible_branch_ids', to_jsonb(p.eligible_branch_ids), 'eligible_service_ids', to_jsonb(p.eligible_service_ids),
    'eligible_product_ids', to_jsonb(p.eligible_product_ids), 'eligible_service_categories', to_jsonb(p.eligible_service_categories),
    'min_spend_cents', p.min_spend_cents, 'stacking_policy', p.stacking_policy, 'max_balance_cents', p.max_balance_cents,
    'purchase_window_days', p.purchase_window_days, 'purchase_max_in_window', p.purchase_max_in_window,
    'purchase_lifetime_cap', p.purchase_lifetime_cap, 'refund_policy', p.refund_policy, 'spend_order', p.spend_order,
    'topup_purchase_earns_points', p.topup_purchase_earns_points, 'stored_value_spend_earns_points', p.stored_value_spend_earns_points,
    'customer_terms', p.customer_terms, 'accounting_inputs', p.accounting_inputs, 'effective_at', p.effective_at,
    'source_draft_id', p.source_draft_id, 'published_at', p.published_at)
$$;
revoke all on function app.sv_plan_version_json(public.sv_plan_versions) from public, anon, authenticated;

-- =====================================================================
-- 11. app.sv_plan_idem_lookup - shared idempotency envelope (Sec 14). Advisory-locks the key,
--     returns the stored result on identical retry, raises 22023 on a hash conflict, else null.
-- =====================================================================
create or replace function app.sv_plan_idem_lookup(p_business uuid, p_op text, p_key uuid, p_hash text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v public.sv_plan_operations%rowtype;
begin
  if p_key is null then raise exception 'an idempotency key is required' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('v65:'||p_op||':'||p_business::text||':'||p_key::text, 0));
  select * into v from public.sv_plan_operations
   where business_id = p_business and op_type = p_op and idempotency_key = p_key for update;
  if found then
    if v.request_hash <> p_hash then
      raise exception 'idempotency key conflicts with a different % request', p_op using errcode = '22023';
    end if;
    return v.result;
  end if;
  return null;
end $$;
revoke all on function app.sv_plan_idem_lookup(uuid, text, uuid, text) from public, anon, authenticated;

-- =====================================================================
-- 12. set_sv_plan_guardrails (Sec 3) - owner-only, audited, idempotent.
-- =====================================================================
create or replace function public.set_sv_plan_guardrails(
  p_business uuid, p_warn_bps integer, p_hard_bps integer, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_hash text; v_hit jsonb; v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  if p_warn_bps is null or p_hard_bps is null or p_warn_bps < 0 or p_hard_bps > 10000 or p_warn_bps > p_hard_bps then
    raise exception 'guardrails require 0 <= warn_discount_bps <= hard_discount_bps <= 10000' using errcode = '22023';
  end if;
  v_hash := app.ps1b_sha256(jsonb_build_object('op','guardrails','business',p_business,'warn',p_warn_bps,'hard',p_hard_bps)::text);
  v_hit := app.sv_plan_idem_lookup(p_business, 'guardrails', p_idempotency_key, v_hash);
  if v_hit is not null then return v_hit; end if;

  insert into public.sv_plan_guardrails(business_id, warn_discount_bps, hard_discount_bps, updated_at)
  values (p_business, p_warn_bps, p_hard_bps, now())
  on conflict (business_id) do update set warn_discount_bps = excluded.warn_discount_bps,
    hard_discount_bps = excluded.hard_discount_bps, updated_at = now();

  v_result := jsonb_build_object('status','ok','business_id',p_business,'warn_discount_bps',p_warn_bps,'hard_discount_bps',p_hard_bps);
  insert into public.sv_plan_operations(business_id, op_type, idempotency_key, request_hash, actor, result)
  values (p_business, 'guardrails', p_idempotency_key, v_hash, v_actor, v_result);
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_PLAN_GUARDRAILS_SET', 'sv_plan_guardrails', p_business,
    jsonb_build_object('warn_discount_bps',p_warn_bps,'hard_discount_bps',p_hard_bps));
  return v_result;
end $$;
revoke all on function public.set_sv_plan_guardrails(uuid, integer, integer, uuid) from public, anon, authenticated;
grant execute on function public.set_sv_plan_guardrails(uuid, integer, integer, uuid) to authenticated;

-- =====================================================================
-- 13. create_sv_plan_draft (Sec 5/14) - owner-only, idempotent. plan_id may bind a new version to an
--     existing plan. Config applied strictly.
-- =====================================================================
create or replace function public.create_sv_plan_draft(p_business uuid, p_config jsonb, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_id uuid := gen_random_uuid();
  v_plan uuid;
  v_hash text; v_hit jsonb;
  v_row public.sv_plan_drafts%rowtype;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  perform app.sv_plan_assert_config(coalesce(p_config,'{}'::jsonb), true);
  v_hash := app.ps1b_sha256(jsonb_build_object('op','create_draft','business',p_business,'config',coalesce(p_config,'{}'::jsonb))::text);
  v_hit := app.sv_plan_idem_lookup(p_business, 'create_draft', p_idempotency_key, v_hash);
  if v_hit is not null then return v_hit; end if;

  if (p_config ? 'plan_id') and nullif(p_config->>'plan_id','') is not null then
    v_plan := (p_config->>'plan_id')::uuid;
    if not exists (select 1 from public.sv_plans s where s.id = v_plan and s.business_id = p_business) then
      raise exception 'stored-value plan does not belong to this business' using errcode = '22023';
    end if;
  end if;

  insert into public.sv_plan_drafts(id, business_id, plan_id, actor) values (v_id, p_business, v_plan, v_actor);
  perform app.sv_plan_apply_config(p_business, v_id, p_config - 'plan_id');
  select * into v_row from public.sv_plan_drafts where id = v_id and business_id = p_business;

  insert into public.sv_plan_operations(business_id, op_type, idempotency_key, request_hash, actor, result)
  values (p_business, 'create_draft', p_idempotency_key, v_hash, v_actor, app.sv_plan_draft_json(v_row));
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_PLAN_DRAFT_CREATED', 'sv_plan_drafts', v_id, jsonb_build_object('plan_id', v_plan));
  return app.sv_plan_draft_json(v_row);
end $$;
revoke all on function public.create_sv_plan_draft(uuid, jsonb, uuid) from public, anon, authenticated;
grant execute on function public.create_sv_plan_draft(uuid, jsonb, uuid) to authenticated;

-- =====================================================================
-- 14. update_sv_plan_draft (Sec 5/6) - owner-only. Optimistic concurrency via expected_revision.
-- =====================================================================
create or replace function public.update_sv_plan_draft(
  p_business uuid, p_draft uuid, p_config jsonb, p_expected_revision integer)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.sv_plan_drafts%rowtype;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  select * into v_row from public.sv_plan_drafts where id = p_draft and business_id = p_business for update;
  if not found then raise exception 'stored-value plan draft not found in this business' using errcode = '22023'; end if;
  if v_row.status <> 'draft' then raise exception 'stored-value plan draft is % and can no longer be edited', v_row.status using errcode = '22023'; end if;
  if p_expected_revision is null or p_expected_revision <> v_row.revision then
    raise exception 'stored-value plan draft was changed in another session (expected revision %, current %)', p_expected_revision, v_row.revision using errcode = '22023';
  end if;

  perform app.sv_plan_apply_config(p_business, p_draft, p_config);
  update public.sv_plan_drafts set revision = revision + 1 where id = p_draft and business_id = p_business;
  select * into v_row from public.sv_plan_drafts where id = p_draft and business_id = p_business;
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_PLAN_DRAFT_UPDATED', 'sv_plan_drafts', p_draft, jsonb_build_object('revision', v_row.revision));
  return app.sv_plan_draft_json(v_row);
end $$;
revoke all on function public.update_sv_plan_draft(uuid, uuid, jsonb, integer) from public, anon, authenticated;
grant execute on function public.update_sv_plan_draft(uuid, uuid, jsonb, integer) to authenticated;

-- =====================================================================
-- 15. preview_sv_plan (Sec 11) - owner-only, READ-only. Separated validation_errors / warnings /
--     override_required / publishable.
-- =====================================================================
create or replace function public.preview_sv_plan(p_business uuid, p_draft uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_row public.sv_plan_drafts%rowtype; v_val jsonb;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  select * into v_row from public.sv_plan_drafts where id = p_draft and business_id = p_business;
  if not found then raise exception 'stored-value plan draft not found in this business' using errcode = '22023'; end if;
  v_val := app.sv_plan_validate(p_business, p_draft);
  return jsonb_build_object(
    'draft_id', v_row.id, 'customer_facing_name', v_row.customer_facing_name,
    'price_cents', v_row.price_cents, 'bonus_cents', v_row.bonus_cents,
    'total_usable_cents', v_row.price_cents + v_row.bonus_cents,
    'effective_discount_bps', v_val->'effective_discount_bps',
    'warn_threshold_bps', v_val->'warn_threshold_bps', 'hard_threshold_bps', v_val->'hard_threshold_bps',
    'validation_errors', v_val->'validation_errors', 'warnings', v_val->'warnings',
    'override_required', v_val->'override_required', 'publishable', v_val->'publishable');
end $$;
revoke all on function public.preview_sv_plan(uuid, uuid) from public, anon, authenticated;
grant execute on function public.preview_sv_plan(uuid, uuid) to authenticated;

-- =====================================================================
-- 16. publish_sv_plan_version (Sec 2/7/8/11/14) - owner-only. Optimistic concurrency, idempotent,
--     locks the plan row before numbering, structural validation gate, inactive-plan denial,
--     override-required at the hard limit. Writes an immutable version; no version is ever mutated.
-- =====================================================================
create or replace function public.publish_sv_plan_version(
  p_business uuid, p_draft uuid, p_expected_revision integer, p_idempotency_key uuid, p_override_reason text default null)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.sv_plan_drafts%rowtype;
  v_plan uuid; v_active boolean; v_version uuid := gen_random_uuid(); v_version_no integer;
  v_val jsonb; v_disc integer; v_hard integer; v_reason text := nullif(btrim(coalesce(p_override_reason,'')),'');
  v_hash text; v_hit jsonb; v_new_plan boolean := false; v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  v_hash := app.ps1b_sha256(jsonb_build_object('op','publish','business',p_business,'draft',p_draft)::text);
  v_hit := app.sv_plan_idem_lookup(p_business, 'publish', p_idempotency_key, v_hash);
  if v_hit is not null then return v_hit; end if;

  select * into v_row from public.sv_plan_drafts where id = p_draft and business_id = p_business for update;
  if not found then raise exception 'stored-value plan draft not found in this business' using errcode = '22023'; end if;
  if v_row.status = 'published' then
    return jsonb_build_object('status','ok','plan_id',v_row.plan_id,'version_id',v_row.published_version_id,'replayed',true);
  end if;
  if v_row.status = 'discarded' then raise exception 'a discarded stored-value plan draft cannot be published' using errcode = '22023'; end if;
  if p_expected_revision is null or p_expected_revision <> v_row.revision then
    raise exception 'stored-value plan draft was changed in another session (expected revision %, current %)', p_expected_revision, v_row.revision using errcode = '22023';
  end if;

  -- structural validation gate (blocks; not overridable)
  v_val := app.sv_plan_validate(p_business, p_draft);
  if (v_val->>'publishable')::boolean is not true then
    raise exception 'plan is not publishable: %', (v_val->'validation_errors')::text using errcode = '22023';
  end if;
  v_disc := (v_val->>'effective_discount_bps')::integer;
  v_hard := (v_val->>'hard_threshold_bps')::integer;
  if v_disc >= v_hard and (v_reason is null or char_length(v_reason) < 3) then
    raise exception 'effective discount is at/above the firm hard limit - an override reason of at least 3 characters is required' using errcode = '22023';
  end if;

  -- bind or create the plan container; LOCK it before numbering (Sec 7)
  v_plan := v_row.plan_id;
  if v_plan is null then
    v_plan := gen_random_uuid(); v_new_plan := true;
    insert into public.sv_plans(id, business_id, name, active) values (v_plan, p_business, v_row.customer_facing_name, true);
    insert into public.sv_plan_status_events(business_id, plan_id, actor, prior_status, new_status, reason)
    values (p_business, v_plan, v_actor, null, 'active', 'plan created');
  end if;
  perform 1 from public.sv_plans where id = v_plan and business_id = p_business for update;
  select active into v_active from public.sv_plans where id = v_plan and business_id = p_business;
  if not v_active then
    raise exception 'stored-value plan is retired - reactivate it before publishing a new version' using errcode = '22023';
  end if;
  select coalesce(max(version_no),0) + 1 into v_version_no from public.sv_plan_versions where plan_id = v_plan and business_id = p_business;

  insert into public.sv_plan_versions(
    id, business_id, plan_id, version_no, price_cents, bonus_cents, expiry_days, terms_snapshot,
    customer_facing_name, paid_expiry_days, bonus_expiry_days, eligible_branch_ids, eligible_service_ids,
    eligible_product_ids, eligible_service_categories, min_spend_cents, stacking_policy, max_balance_cents,
    purchase_window_days, purchase_max_in_window, purchase_lifetime_cap, refund_policy, spend_order,
    topup_purchase_earns_points, stored_value_spend_earns_points, customer_terms, accounting_inputs,
    effective_at, source_draft_id)
  values (
    v_version, p_business, v_plan, v_version_no, v_row.price_cents, v_row.bonus_cents,
    coalesce(v_row.paid_expiry_days, v_row.bonus_expiry_days),
    jsonb_build_object('customer_terms', v_row.customer_terms, 'accounting_inputs', v_row.accounting_inputs, 'source_draft_id', v_row.id),
    v_row.customer_facing_name, v_row.paid_expiry_days, v_row.bonus_expiry_days, v_row.eligible_branch_ids,
    v_row.eligible_service_ids, v_row.eligible_product_ids, v_row.eligible_service_categories, v_row.min_spend_cents,
    v_row.stacking_policy, v_row.max_balance_cents, v_row.purchase_window_days, v_row.purchase_max_in_window,
    v_row.purchase_lifetime_cap, v_row.refund_policy, v_row.spend_order, v_row.topup_purchase_earns_points,
    v_row.stored_value_spend_earns_points, v_row.customer_terms, v_row.accounting_inputs, v_row.effective_at, v_row.id);

  update public.sv_plan_drafts set status = 'published', plan_id = v_plan, published_version_id = v_version
   where id = p_draft and business_id = p_business;

  v_result := jsonb_build_object('status','ok','plan_id',v_plan,'version_id',v_version,'version_no',v_version_no,
    'effective_discount_bps',v_disc,'override_applied',(v_disc >= v_hard),'new_plan',v_new_plan,'replayed',false);
  insert into public.sv_plan_operations(business_id, op_type, idempotency_key, request_hash, actor, result)
  values (p_business, 'publish', p_idempotency_key, v_hash, v_actor, v_result);
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_PLAN_PUBLISHED', 'sv_plan_versions', v_version, jsonb_build_object(
    'plan_id', v_plan, 'version_no', v_version_no, 'price_cents', v_row.price_cents, 'bonus_cents', v_row.bonus_cents,
    'effective_discount_bps', v_disc, 'override_reason', v_reason, 'override_applied', (v_disc >= v_hard)));
  return v_result;
end $$;
revoke all on function public.publish_sv_plan_version(uuid, uuid, integer, uuid, text) from public, anon, authenticated;
grant execute on function public.publish_sv_plan_version(uuid, uuid, integer, uuid, text) to authenticated;

-- =====================================================================
-- 17. discard_sv_plan_draft (Sec 12/14) - owner-only, idempotent, optimistic.
-- =====================================================================
create or replace function public.discard_sv_plan_draft(
  p_business uuid, p_draft uuid, p_expected_revision integer, p_idempotency_key uuid, p_reason text default null)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid(); v_row public.sv_plan_drafts%rowtype; v_hash text; v_hit jsonb; v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  v_hash := app.ps1b_sha256(jsonb_build_object('op','discard','business',p_business,'draft',p_draft)::text);
  v_hit := app.sv_plan_idem_lookup(p_business, 'discard', p_idempotency_key, v_hash);
  if v_hit is not null then return v_hit; end if;

  select * into v_row from public.sv_plan_drafts where id = p_draft and business_id = p_business for update;
  if not found then raise exception 'stored-value plan draft not found in this business' using errcode = '22023'; end if;
  if v_row.status = 'discarded' then
    v_result := jsonb_build_object('status','ok','draft_id',p_draft,'discarded',true,'replayed',true);
  elsif v_row.status = 'published' then
    raise exception 'a published stored-value plan draft cannot be discarded' using errcode = '22023';
  else
    if p_expected_revision is null or p_expected_revision <> v_row.revision then
      raise exception 'stored-value plan draft was changed in another session (expected revision %, current %)', p_expected_revision, v_row.revision using errcode = '22023';
    end if;
    update public.sv_plan_drafts set status = 'discarded' where id = p_draft and business_id = p_business;
    v_result := jsonb_build_object('status','ok','draft_id',p_draft,'discarded',true,'replayed',false);
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'SV_PLAN_DRAFT_DISCARDED', 'sv_plan_drafts', p_draft, jsonb_build_object('reason', nullif(btrim(coalesce(p_reason,'')),'')));
  end if;
  insert into public.sv_plan_operations(business_id, op_type, idempotency_key, request_hash, actor, result)
  values (p_business, 'discard', p_idempotency_key, v_hash, v_actor, v_result);
  return v_result;
end $$;
revoke all on function public.discard_sv_plan_draft(uuid, uuid, integer, uuid, text) from public, anon, authenticated;
grant execute on function public.discard_sv_plan_draft(uuid, uuid, integer, uuid, text) to authenticated;

-- =====================================================================
-- 18. clone_sv_plan_version_to_draft (Sec 12/14) - owner-only, idempotent. New editable draft
--     pre-filled from an immutable version, bound to that plan (publishing makes a new version).
-- =====================================================================
create or replace function public.clone_sv_plan_version_to_draft(p_business uuid, p_version uuid, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid(); pv public.sv_plan_versions%rowtype; v_id uuid := gen_random_uuid();
  v_hash text; v_hit jsonb; v_row public.sv_plan_drafts%rowtype;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  v_hash := app.ps1b_sha256(jsonb_build_object('op','clone','business',p_business,'version',p_version)::text);
  v_hit := app.sv_plan_idem_lookup(p_business, 'clone', p_idempotency_key, v_hash);
  if v_hit is not null then return v_hit; end if;

  select * into pv from public.sv_plan_versions where id = p_version and business_id = p_business;
  if not found then raise exception 'stored-value plan version not found in this business' using errcode = '22023'; end if;

  insert into public.sv_plan_drafts(
    id, business_id, plan_id, actor, customer_facing_name, price_cents, bonus_cents, paid_expiry_days,
    bonus_expiry_days, eligible_branch_ids, eligible_service_ids, eligible_product_ids, eligible_service_categories,
    min_spend_cents, stacking_policy, max_balance_cents, purchase_window_days, purchase_max_in_window,
    purchase_lifetime_cap, refund_policy, spend_order, topup_purchase_earns_points, stored_value_spend_earns_points,
    customer_terms, accounting_inputs, effective_at)
  values (
    v_id, p_business, pv.plan_id, v_actor, pv.customer_facing_name, pv.price_cents, pv.bonus_cents, pv.paid_expiry_days,
    pv.bonus_expiry_days, pv.eligible_branch_ids, pv.eligible_service_ids, pv.eligible_product_ids, pv.eligible_service_categories,
    pv.min_spend_cents, coalesce(pv.stacking_policy,'stackable'), pv.max_balance_cents, pv.purchase_window_days, pv.purchase_max_in_window,
    pv.purchase_lifetime_cap, coalesce(pv.refund_policy,'proportional'), coalesce(pv.spend_order,'proportional'),
    coalesce(pv.topup_purchase_earns_points,false), coalesce(pv.stored_value_spend_earns_points,false),
    pv.customer_terms, coalesce(pv.accounting_inputs,'{}'::jsonb), pv.effective_at);
  select * into v_row from public.sv_plan_drafts where id = v_id and business_id = p_business;

  insert into public.sv_plan_operations(business_id, op_type, idempotency_key, request_hash, actor, result)
  values (p_business, 'clone', p_idempotency_key, v_hash, v_actor, app.sv_plan_draft_json(v_row));
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_PLAN_CLONED_TO_DRAFT', 'sv_plan_drafts', v_id, jsonb_build_object('from_version', p_version, 'plan_id', pv.plan_id));
  return app.sv_plan_draft_json(v_row);
end $$;
revoke all on function public.clone_sv_plan_version_to_draft(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.clone_sv_plan_version_to_draft(uuid, uuid, uuid) to authenticated;

-- =====================================================================
-- 19. retire_sv_plan / reactivate_sv_plan (Sec 1/12/14) - owner-only, idempotent, audited. Mutates
--     ONLY the sv_plans container + appends a status event; never touches a version.
-- =====================================================================
create or replace function public.retire_sv_plan(p_business uuid, p_plan uuid, p_reason text, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid(); v_reason text := nullif(btrim(coalesce(p_reason,'')),''); v_active boolean;
  v_hash text; v_hit jsonb; v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  if v_reason is null or char_length(v_reason) < 3 then raise exception 'retiring a stored-value plan requires a reason of at least 3 characters' using errcode = '22023'; end if;
  v_hash := app.ps1b_sha256(jsonb_build_object('op','retire','business',p_business,'plan',p_plan)::text);
  v_hit := app.sv_plan_idem_lookup(p_business, 'retire', p_idempotency_key, v_hash);
  if v_hit is not null then return v_hit; end if;

  select active into v_active from public.sv_plans where id = p_plan and business_id = p_business for update;
  if not found then raise exception 'stored-value plan does not belong to this business' using errcode = '22023'; end if;
  if v_active then
    update public.sv_plans set active = false where id = p_plan and business_id = p_business;
    insert into public.sv_plan_status_events(business_id, plan_id, actor, prior_status, new_status, reason)
    values (p_business, p_plan, v_actor, 'active', 'retired', v_reason);
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'SV_PLAN_RETIRED', 'sv_plans', p_plan, jsonb_build_object('reason', v_reason));
    v_result := jsonb_build_object('status','ok','plan_id',p_plan,'active',false,'replayed',false);
  else
    v_result := jsonb_build_object('status','ok','plan_id',p_plan,'active',false,'replayed',true);
  end if;
  insert into public.sv_plan_operations(business_id, op_type, idempotency_key, request_hash, actor, result)
  values (p_business, 'retire', p_idempotency_key, v_hash, v_actor, v_result);
  return v_result;
end $$;
revoke all on function public.retire_sv_plan(uuid, uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.retire_sv_plan(uuid, uuid, text, uuid) to authenticated;

create or replace function public.reactivate_sv_plan(p_business uuid, p_plan uuid, p_reason text, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid(); v_reason text := nullif(btrim(coalesce(p_reason,'')),''); v_active boolean;
  v_hash text; v_hit jsonb; v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  if v_reason is null or char_length(v_reason) < 3 then raise exception 'reactivating a stored-value plan requires a reason of at least 3 characters' using errcode = '22023'; end if;
  v_hash := app.ps1b_sha256(jsonb_build_object('op','reactivate','business',p_business,'plan',p_plan)::text);
  v_hit := app.sv_plan_idem_lookup(p_business, 'reactivate', p_idempotency_key, v_hash);
  if v_hit is not null then return v_hit; end if;

  select active into v_active from public.sv_plans where id = p_plan and business_id = p_business for update;
  if not found then raise exception 'stored-value plan does not belong to this business' using errcode = '22023'; end if;
  if not v_active then
    update public.sv_plans set active = true where id = p_plan and business_id = p_business;
    insert into public.sv_plan_status_events(business_id, plan_id, actor, prior_status, new_status, reason)
    values (p_business, p_plan, v_actor, 'retired', 'active', v_reason);
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'SV_PLAN_REACTIVATED', 'sv_plans', p_plan, jsonb_build_object('reason', v_reason));
    v_result := jsonb_build_object('status','ok','plan_id',p_plan,'active',true,'replayed',false);
  else
    v_result := jsonb_build_object('status','ok','plan_id',p_plan,'active',true,'replayed',true);
  end if;
  insert into public.sv_plan_operations(business_id, op_type, idempotency_key, request_hash, actor, result)
  values (p_business, 'reactivate', p_idempotency_key, v_hash, v_actor, v_result);
  return v_result;
end $$;
revoke all on function public.reactivate_sv_plan(uuid, uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.reactivate_sv_plan(uuid, uuid, text, uuid) to authenticated;

-- =====================================================================
-- 20. get_sv_plans (Sec 13) - owner/SA read: COMPLETE version config + status history + guardrails +
--     open drafts. Nothing shortened.
-- =====================================================================
create or replace function public.get_sv_plans(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_plans jsonb; v_drafts jsonb; v_warn integer; v_hard integer;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'not permitted to view stored-value plans for this business' using errcode = '42501';
  end if;
  select coalesce(warn_discount_bps,3000), coalesce(hard_discount_bps,7000) into v_warn, v_hard
    from public.sv_plan_guardrails where business_id = p_business;
  v_warn := coalesce(v_warn,3000); v_hard := coalesce(v_hard,7000);

  select coalesce(jsonb_agg(jsonb_build_object(
      'plan_id', s.id, 'name', s.name, 'active', s.active,
      'versions', (select coalesce(jsonb_agg(app.sv_plan_version_json(pv) order by pv.version_no desc), '[]'::jsonb)
                     from public.sv_plan_versions pv where pv.plan_id = s.id and pv.business_id = p_business),
      'status_history', (select coalesce(jsonb_agg(jsonb_build_object(
          'prior_status', e.prior_status, 'new_status', e.new_status, 'reason', e.reason,
          'actor', e.actor, 'at', e.created_at) order by e.created_at desc), '[]'::jsonb)
        from public.sv_plan_status_events e where e.plan_id = s.id and e.business_id = p_business))
      order by s.created_at desc), '[]'::jsonb)
    into v_plans from public.sv_plans s where s.business_id = p_business;

  select coalesce(jsonb_agg(app.sv_plan_draft_json(d) order by d.created_at desc), '[]'::jsonb)
    into v_drafts from public.sv_plan_drafts d where d.business_id = p_business and d.status = 'draft';

  return jsonb_build_object('business_id', p_business, 'plans', v_plans, 'open_drafts', v_drafts,
    'guardrails', jsonb_build_object('warn_discount_bps', v_warn, 'hard_discount_bps', v_hard));
end $$;
revoke all on function public.get_sv_plans(uuid) from public, anon, authenticated;
grant execute on function public.get_sv_plans(uuid) to authenticated;

commit;
