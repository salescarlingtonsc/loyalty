-- FRENLY v56 - PROGRAM STUDIO PS-1B: EVENTS, ENTITLEMENT EXECUTION, OUTBOX, SHADOW
--
-- Local review candidate. Production apply needs the owner's RELEASE APPROVED
-- phrase (CLAUDE.md standing gate). PS-1B authorized 2026-07-24 (owner).
--
-- Implements the FROZEN contracts EXACTLY: EVENT_CONTRACT.md (envelope + producer
-- identity), BENEFIT_REGISTRY_CONTRACT.md (fulfilments + shadow), ARCHITECTURE
-- §6/§7/§11/§15/§17 PS-1B/§18. Scope guardrails (owner letter; tripwired by
-- tests/program-studio/ps0-no-executor):
--   * entitlements are PROMISES only. The studio executor moves NO customer value:
--     NO credit_ledger/points_ledger/discount/tender writes. grant_credit and
--     discount effects are SHADOW-LOGGED, never posted.
--   * communications go ONLY through event_outbox -> a CAPTURE/TEST provider that
--     writes captured_messages with SYNTHETIC recipients (hard CHECK). No real
--     WhatsApp/email/SMS anywhere.
--   * the ONLY authority transitions are referral legacy->shadow and the studio
--     recurring family unbuilt->studio, both migration-GUC gated. NO other flip.
--   * NO PS-1C checkout-effect surface, NO checkout evaluation token, no stored value.

begin;

-- =====================================================================
-- 0. Helpers (all browser-closed).
-- =====================================================================
create or replace function app.ps1b_sha256(p_value text)
returns text language sql immutable strict
set search_path to 'pg_catalog', 'extensions', 'pg_temp'
as $$ select encode(extensions.digest(convert_to(p_value, 'UTF8'), 'sha256'), 'hex') $$;
revoke all on function app.ps1b_sha256(text) from public, anon, authenticated;

-- SGT-derived period key (deterministic from the period boundary, never now()).
create or replace function app.ps1b_period_key(p_occurred timestamptz, p_period text)
returns text language sql immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select case coalesce(nullif(p_period,''),'monthly')
    when 'daily'  then to_char((p_occurred at time zone 'Asia/Singapore')::date, 'YYYY-MM-DD')
    when 'annual' then to_char(p_occurred at time zone 'Asia/Singapore', 'YYYY')
    else               to_char(p_occurred at time zone 'Asia/Singapore', 'YYYY-MM')
  end
$$;
revoke all on function app.ps1b_period_key(timestamptz, text) from public, anon, authenticated;

create or replace function app.ps1b_catalog_price(p_business uuid, p_kind text, p_id uuid)
returns integer language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if p_id is null then return 0; end if;
  -- One statement per branch: a planning defect in one catalog must not
  -- silently zero the other (plpgsql plans the whole statement at once).
  if p_kind = 'service' then
    return coalesce((select price_cents from public.services where id = p_id and business_id = p_business), 0);
  elsif p_kind = 'product' then
    return coalesce((select retail_price_cents from public.products where id = p_id and business_id = p_business), 0);
  end if;
  return 0;
exception when others then return 0;
end $$;
revoke all on function app.ps1b_catalog_price(uuid, text, uuid) from public, anon, authenticated;

-- Bulletproof condition evaluator: a malformed condition NEVER raises (would
-- otherwise brick a producer transaction) - it simply fails to match.
create or replace function app.ps1b_eval_conditions(p_payload jsonb, p_conds jsonb)
returns boolean language plpgsql immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare c jsonb; v_op text; v_val jsonb; v_lhs jsonb;
begin
  if p_conds is null or jsonb_typeof(p_conds) <> 'array' or jsonb_array_length(p_conds) = 0 then return true; end if;
  for c in select * from jsonb_array_elements(p_conds) loop
    v_op := c->>'op'; v_val := c->'value'; v_lhs := p_payload->(c->>'field');
    if v_lhs is null then return false; end if;
    case v_op
      when 'eq'      then if v_lhs is distinct from v_val then return false; end if;
      when 'neq'     then if v_lhs is not distinct from v_val then return false; end if;
      when 'gt'      then if not ((v_lhs#>>'{}')::numeric >  (v_val#>>'{}')::numeric) then return false; end if;
      when 'gte'     then if not ((v_lhs#>>'{}')::numeric >= (v_val#>>'{}')::numeric) then return false; end if;
      when 'lt'      then if not ((v_lhs#>>'{}')::numeric <  (v_val#>>'{}')::numeric) then return false; end if;
      when 'lte'     then if not ((v_lhs#>>'{}')::numeric <= (v_val#>>'{}')::numeric) then return false; end if;
      when 'between' then if not ((v_lhs#>>'{}')::numeric between (v_val->>0)::numeric and (v_val->>1)::numeric) then return false; end if;
      when 'in'      then if not (v_val @> jsonb_build_array(v_lhs)) then return false; end if;
      when 'not_in'  then if (v_val @> jsonb_build_array(v_lhs)) then return false; end if;
      else return false;
    end case;
  end loop;
  return true;
exception when others then return false;
end $$;
revoke all on function app.ps1b_eval_conditions(jsonb, jsonb) from public, anon, authenticated;

-- =====================================================================
-- 1. domain_events - the immutable envelope (EVENT_CONTRACT §1).
-- =====================================================================
create table public.domain_events (
  event_id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  event_type text not null check (event_type in (
    'sale.completed','sale.reversed','points.redeemed','giftcard.issued','giftcard.redeemed',
    'package.sold','package.session_used','package.session_reversed','membership.enrolled',
    'membership.renewed','birthday.activated','birthday.redeemed','birthday.redemption_reversed',
    'referral.qualified','credit.tendered','payment.recorded','consent.changed','feedback.submitted',
    'points.expired','membership.renewal_swept','booking.expired','expense.recurred',
    'recurring_perk.materialised','tier.entry_reward','tier.changed')),
  schema_version smallint not null default 1 check (schema_version >= 1),
  source_operation_id text not null check (char_length(source_operation_id) between 1 and 200),
  subject_client_id uuid,
  subject_identity_id uuid references public.customer_identities(id) on delete restrict,
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default now(),
  config_version_id uuid,
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  payload_hash text not null check (payload_hash ~ '^[0-9a-f]{64}$'),
  constraint domain_events_producer_identity_uk unique (business_id, event_type, source_operation_id, schema_version),
  constraint domain_events_id_business_uk unique (event_id, business_id),
  constraint domain_events_subject_client_fk foreign key (subject_client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint domain_events_config_fk foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict
);
create index domain_events_business_type_time_idx on public.domain_events (business_id, event_type, recorded_at);
create index domain_events_subject_idx on public.domain_events (business_id, subject_client_id, recorded_at);

create or replace function app.domain_events_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'domain_events is immutable and append-only' using errcode = 'restrict_violation';
  return null;
end $$;
revoke all on function app.domain_events_guard() from public, anon, authenticated;
create trigger trg_domain_events_guard before update or delete on public.domain_events
  for each row execute function app.domain_events_guard();

alter table public.domain_events enable row level security;
create policy domain_events_owner_read on public.domain_events for select to authenticated using (app.is_salon_owner(business_id));
create policy domain_events_sa_read on public.domain_events for select to authenticated using (app.is_super_admin());
revoke all on public.domain_events from public, anon, authenticated;
grant select on public.domain_events to authenticated;

-- Single producer entrypoint. Deterministic dedup by producer identity.
create or replace function app.emit_domain_event(
  p_business uuid, p_event_type text, p_source_operation_id text,
  p_subject_client uuid, p_subject_identity uuid, p_occurred timestamptz,
  p_config_version uuid, p_payload jsonb)
returns uuid language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_id uuid; v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
begin
  insert into public.domain_events(
    business_id, event_type, schema_version, source_operation_id, subject_client_id,
    subject_identity_id, occurred_at, config_version_id, payload, payload_hash)
  values(p_business, p_event_type, 1, p_source_operation_id, p_subject_client,
    p_subject_identity, coalesce(p_occurred, now()), p_config_version, v_payload,
    app.ps1b_sha256(v_payload::text))
  on conflict (business_id, event_type, source_operation_id, schema_version) do nothing
  returning event_id into v_id;
  return v_id;
end $$;
revoke all on function app.emit_domain_event(uuid, text, text, uuid, uuid, timestamptz, uuid, jsonb) from public, anon, authenticated;

-- =====================================================================
-- 3. benefit_fulfilments - the authoritative single-count registry
--    (BENEFIT_REGISTRY_CONTRACT §1). Append-only. Authority-holder writes only.
-- =====================================================================
create table public.benefit_fulfilments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  canonical_benefit_key text not null check (char_length(canonical_benefit_key) between 1 and 300),
  source_engine text not null check (source_engine in (
    'points_loyalty','retention','referral','birthday','tier','recurring','campaign',
    'checkout','stored_value','membership','studio_rule')),
  fulfilment_kind text not null,
  client_id uuid,
  detail_ref uuid not null,
  face_value_cents integer not null,
  estimated_cost_cents integer not null,
  cost_basis text not null check (cost_basis in (
    'credit_face','catalog_cost','benefit_snapshot','owner_offer_cost','discount_face','bonus_face','margin_band')),
  cost_confidence text not null check (cost_confidence in ('high','medium','low')),
  config_version_id uuid not null,
  reverses_fulfilment_id uuid,
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default now(),
  constraint benefit_fulfilments_key_uk unique (business_id, canonical_benefit_key),
  constraint benefit_fulfilments_id_business_uk unique (id, business_id),
  constraint benefit_fulfilments_client_fk foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint benefit_fulfilments_config_fk foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict,
  constraint benefit_fulfilments_reversal_fk foreign key (reverses_fulfilment_id, business_id)
    references public.benefit_fulfilments(id, business_id) on delete restrict
);
create index benefit_fulfilments_engine_idx on public.benefit_fulfilments (business_id, source_engine, recorded_at);

create or replace function app.benefit_fulfilments_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'benefit_fulfilments is append-only (reversals are new signed rows)' using errcode = 'restrict_violation';
  return null;
end $$;
revoke all on function app.benefit_fulfilments_guard() from public, anon, authenticated;
create trigger trg_benefit_fulfilments_guard before update or delete on public.benefit_fulfilments
  for each row execute function app.benefit_fulfilments_guard();

alter table public.benefit_fulfilments enable row level security;
create policy benefit_fulfilments_owner_read on public.benefit_fulfilments for select to authenticated using (app.is_salon_owner(business_id));
create policy benefit_fulfilments_sa_read on public.benefit_fulfilments for select to authenticated using (app.is_super_admin());
revoke all on public.benefit_fulfilments from public, anon, authenticated;
grant select on public.benefit_fulfilments to authenticated;

-- =====================================================================
-- 4. benefit_shadow_evaluations - the shadow log (contract §6).
--    A shadowing evaluator writes ONLY here, never benefit_fulfilments.
-- =====================================================================
create table public.benefit_shadow_evaluations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  event_id uuid not null,
  source_engine text not null,
  rule_id uuid,
  would_be_canonical_key text not null,
  client_id uuid,
  fulfilment_kind text not null,
  face_value_cents integer not null,
  estimated_cost_cents integer not null,
  cost_basis text not null,
  cost_confidence text not null,
  config_version_id uuid,
  computed_at timestamptz not null default now(),
  constraint benefit_shadow_evaluations_event_fk foreign key (event_id, business_id)
    references public.domain_events(event_id, business_id) on delete restrict,
  constraint benefit_shadow_evaluations_key_uk unique (business_id, would_be_canonical_key, event_id)
);
create index benefit_shadow_evaluations_engine_idx on public.benefit_shadow_evaluations (business_id, source_engine, computed_at);

create or replace function app.benefit_shadow_evaluations_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'benefit_shadow_evaluations is append-only' using errcode = 'restrict_violation';
  return null;
end $$;
revoke all on function app.benefit_shadow_evaluations_guard() from public, anon, authenticated;
create trigger trg_benefit_shadow_evaluations_guard before update or delete on public.benefit_shadow_evaluations
  for each row execute function app.benefit_shadow_evaluations_guard();

alter table public.benefit_shadow_evaluations enable row level security;
create policy benefit_shadow_evaluations_owner_read on public.benefit_shadow_evaluations for select to authenticated using (app.is_salon_owner(business_id));
create policy benefit_shadow_evaluations_sa_read on public.benefit_shadow_evaluations for select to authenticated using (app.is_super_admin());
revoke all on public.benefit_shadow_evaluations from public, anon, authenticated;
grant select on public.benefit_shadow_evaluations to authenticated;

-- =====================================================================
-- 5. rule_effect_log - exactly-once effect execution (§6).
-- =====================================================================
create table public.rule_effect_log (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  event_id uuid not null,
  rule_id uuid not null,
  effect_index integer not null check (effect_index >= 0),
  effect_type text not null,
  outcome text not null check (outcome in ('fulfilled','shadow','display_perk','notified','budget_exhausted','suppressed','no_op')),
  benefit_fulfilment_id uuid,
  config_version_id uuid,
  created_at timestamptz not null default now(),
  constraint rule_effect_log_event_rule_effect_uk unique (event_id, rule_id, effect_index),
  constraint rule_effect_log_event_fk foreign key (event_id, business_id)
    references public.domain_events(event_id, business_id) on delete restrict,
  constraint rule_effect_log_fulfilment_fk foreign key (benefit_fulfilment_id, business_id)
    references public.benefit_fulfilments(id, business_id) on delete restrict,
  -- a value-moving/promising outcome carries exactly one fulfilment reference;
  -- non-value outcomes carry none (§10 N1).
  constraint rule_effect_log_fulfilment_presence_check check (
    (outcome = 'fulfilled') = (benefit_fulfilment_id is not null))
);
create index rule_effect_log_business_idx on public.rule_effect_log (business_id, created_at);

create or replace function app.rule_effect_log_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'rule_effect_log is append-only' using errcode = 'restrict_violation';
  return null;
end $$;
revoke all on function app.rule_effect_log_guard() from public, anon, authenticated;
create trigger trg_rule_effect_log_guard before update or delete on public.rule_effect_log
  for each row execute function app.rule_effect_log_guard();

alter table public.rule_effect_log enable row level security;
create policy rule_effect_log_owner_read on public.rule_effect_log for select to authenticated using (app.is_salon_owner(business_id));
create policy rule_effect_log_sa_read on public.rule_effect_log for select to authenticated using (app.is_super_admin());
revoke all on public.rule_effect_log from public, anon, authenticated;
grant select on public.rule_effect_log to authenticated;

-- =====================================================================
-- 6. budget_periods + budget_reservations (§11).
--    Deterministic multi-row lock order is (business_id, rule_id, period_start);
--    PS-1B materialisation locks a SINGLE budget row per grant, so the order is
--    satisfied trivially. Counter reconciles to Σ reservations.
-- =====================================================================
create table public.budget_periods (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  rule_id uuid not null,
  period_start timestamptz not null,
  period_end timestamptz not null,
  committed_cents integer not null default 0 check (committed_cents >= 0),
  cap_cents integer check (cap_cents is null or cap_cents >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint budget_periods_scope_uk unique (business_id, rule_id, period_start),
  constraint budget_periods_id_business_uk unique (id, business_id),
  constraint budget_periods_window_check check (period_end > period_start)
);

create table public.budget_reservations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  budget_period_id uuid not null,
  entitlement_id uuid not null,
  amount_cents integer not null check (amount_cents >= 0),
  created_at timestamptz not null default now(),
  constraint budget_reservations_period_entitlement_uk unique (budget_period_id, entitlement_id),
  constraint budget_reservations_period_fk foreign key (budget_period_id, business_id)
    references public.budget_periods(id, business_id) on delete restrict
);

create or replace function app.budget_reservations_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'budget_reservations is append-only (an issued promise keeps its reservation permanently)' using errcode = 'restrict_violation';
  return null;
end $$;
revoke all on function app.budget_reservations_guard() from public, anon, authenticated;
create trigger trg_budget_reservations_guard before update or delete on public.budget_reservations
  for each row execute function app.budget_reservations_guard();

alter table public.budget_periods enable row level security;
alter table public.budget_reservations enable row level security;
create policy budget_periods_owner_read on public.budget_periods for select to authenticated using (app.is_salon_owner(business_id));
create policy budget_periods_sa_read on public.budget_periods for select to authenticated using (app.is_super_admin());
create policy budget_reservations_owner_read on public.budget_reservations for select to authenticated using (app.is_salon_owner(business_id));
create policy budget_reservations_sa_read on public.budget_reservations for select to authenticated using (app.is_super_admin());
revoke all on public.budget_periods from public, anon, authenticated;
revoke all on public.budget_reservations from public, anon, authenticated;
grant select on public.budget_periods to authenticated;
grant select on public.budget_reservations to authenticated;

-- =====================================================================
-- 7. program_entitlements + operations (§15, c45-generalised).
-- =====================================================================
create table public.program_entitlements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid not null,
  rule_id uuid not null,
  config_version_id uuid not null,
  period_key text not null check (char_length(period_key) between 1 and 40),
  fulfilment_kind text not null,
  status text not null check (status in ('available','redeemed','expired','reversed')),
  benefit_snapshot jsonb not null check (jsonb_typeof(benefit_snapshot) = 'object'),
  valid_from timestamptz not null,
  valid_until timestamptz,
  budget_reservation_id uuid,
  redeemed_at timestamptz,
  reversed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint program_entitlements_lazy_uk unique (business_id, client_id, rule_id, period_key),
  constraint program_entitlements_id_business_uk unique (id, business_id),
  constraint program_entitlements_id_business_client_uk unique (id, business_id, client_id),
  constraint program_entitlements_client_fk foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint program_entitlements_config_fk foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict,
  constraint program_entitlements_window_check check (valid_until is null or valid_until > valid_from)
);
create index program_entitlements_client_idx on public.program_entitlements (business_id, client_id, status, created_at);

create table public.program_entitlement_operations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid not null,
  operation_type text not null check (operation_type in ('materialise','redeem','reverse')),
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  entitlement_id uuid not null,
  created_at timestamptz not null default now(),
  constraint program_entitlement_operations_idem_uk unique (business_id, operation_type, idempotency_key),
  constraint program_entitlement_operations_entitlement_fk foreign key (entitlement_id, business_id)
    references public.program_entitlements(id, business_id) on delete restrict
);

-- Lifecycle guard: identity/economics immutable; only status may advance
-- available -> redeemed | expired | reversed (c45 pattern).
create or replace function app.program_entitlement_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then raise exception 'program_entitlements is append-only' using errcode = 'restrict_violation'; end if;
  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id or new.business_id is distinct from old.business_id
       or new.client_id is distinct from old.client_id or new.rule_id is distinct from old.rule_id
       or new.config_version_id is distinct from old.config_version_id or new.period_key is distinct from old.period_key
       or new.benefit_snapshot is distinct from old.benefit_snapshot or new.valid_from is distinct from old.valid_from
       or new.fulfilment_kind is distinct from old.fulfilment_kind
       -- budget_reservation_id is write-once: the reservation row is created after
       -- the entitlement (they reference each other), so null -> value is the
       -- sanctioned linking step; once linked it is immutable.
       or (new.budget_reservation_id is distinct from old.budget_reservation_id
           and old.budget_reservation_id is not null) then
      raise exception 'program entitlement identity and economics are immutable' using errcode = 'restrict_violation';
    end if;
    -- available -> redeemed | expired | reversed, plus the one sanctioned
    -- post-terminal move: redeemed -> reversed (owner correction of a
    -- mistaken redemption, c45 pattern — the RPC enforces owner-only).
    if old.status <> 'available' and new.status <> old.status
       and not (old.status = 'redeemed' and new.status = 'reversed') then
      raise exception 'program entitlement is terminal' using errcode = 'restrict_violation';
    end if;
  end if;
  return new;
end $$;
revoke all on function app.program_entitlement_guard() from public, anon, authenticated;
create trigger trg_program_entitlement_guard before update or delete on public.program_entitlements
  for each row execute function app.program_entitlement_guard();

alter table public.program_entitlements enable row level security;
alter table public.program_entitlement_operations enable row level security;
create policy program_entitlements_read on public.program_entitlements for select to authenticated
  using (app.is_salon_member(business_id) or app.is_super_admin());
create policy program_entitlement_operations_read on public.program_entitlement_operations for select to authenticated
  using (app.is_salon_owner(business_id) or app.is_super_admin());
revoke all on public.program_entitlements from public, anon, authenticated;
revoke all on public.program_entitlement_operations from public, anon, authenticated;
grant select on public.program_entitlements to authenticated;
grant select on public.program_entitlement_operations to authenticated;

-- Executor processing marker (idempotent sweep cursor; append-only).
create table public.domain_event_execution (
  event_id uuid primary key,
  business_id uuid not null references public.businesses(id) on delete cascade,
  executed_at timestamptz not null default now(),
  effect_count integer not null default 0,
  constraint domain_event_execution_event_fk foreign key (event_id, business_id)
    references public.domain_events(event_id, business_id) on delete restrict
);
alter table public.domain_event_execution enable row level security;
create policy domain_event_execution_owner_read on public.domain_event_execution for select to authenticated using (app.is_salon_owner(business_id));
create policy domain_event_execution_sa_read on public.domain_event_execution for select to authenticated using (app.is_super_admin());
revoke all on public.domain_event_execution from public, anon, authenticated;
grant select on public.domain_event_execution to authenticated;

-- =====================================================================
-- 8. event_outbox (NEW sole delivery-state authority; v33 untouched, B4).
--    captured_messages = the CAPTURE/TEST comms provider (synthetic-only).
-- =====================================================================
create table public.event_outbox (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  event_id uuid not null,
  consumer text not null check (consumer in ('comms')),
  delivery_status text not null default 'pending' check (delivery_status in ('pending','delivering','delivered','failed','dead_letter')),
  attempts integer not null default 0 check (attempts >= 0),
  max_attempts integer not null default 5 check (max_attempts >= 1),
  next_attempt_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint event_outbox_event_consumer_uk unique (event_id, consumer),
  constraint event_outbox_id_business_uk unique (id, business_id),
  constraint event_outbox_event_fk foreign key (event_id, business_id)
    references public.domain_events(event_id, business_id) on delete restrict
);
create index event_outbox_due_idx on public.event_outbox (delivery_status, next_attempt_at);

create table public.captured_messages (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  event_id uuid not null,
  outbox_id uuid not null,
  channel text not null check (channel in ('email','sms','whatsapp','in_app')),
  -- Structural guarantee: a real address/number is UNINSERTABLE. Recipients are
  -- synthetic ONLY (test/capture provider). No real delivery is possible here.
  recipient text not null check (
    recipient like '%@example.test' or recipient like '+65990000%' or recipient like 'synthetic:%'),
  template_key text not null,
  rendered jsonb not null check (jsonb_typeof(rendered) = 'object'),
  captured_at timestamptz not null default now(),
  constraint captured_messages_outbox_uk unique (outbox_id),
  constraint captured_messages_outbox_fk foreign key (outbox_id, business_id)
    references public.event_outbox(id, business_id) on delete restrict,
  constraint captured_messages_event_fk foreign key (event_id, business_id)
    references public.domain_events(event_id, business_id) on delete restrict
);

create or replace function app.captured_messages_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'captured_messages is append-only' using errcode = 'restrict_violation';
  return null;
end $$;
revoke all on function app.captured_messages_guard() from public, anon, authenticated;
create trigger trg_captured_messages_guard before update or delete on public.captured_messages
  for each row execute function app.captured_messages_guard();

alter table public.event_outbox enable row level security;
alter table public.captured_messages enable row level security;
create policy event_outbox_owner_read on public.event_outbox for select to authenticated using (app.is_salon_owner(business_id));
create policy event_outbox_sa_read on public.event_outbox for select to authenticated using (app.is_super_admin());
create policy captured_messages_owner_read on public.captured_messages for select to authenticated using (app.is_salon_owner(business_id));
create policy captured_messages_sa_read on public.captured_messages for select to authenticated using (app.is_super_admin());
revoke all on public.event_outbox from public, anon, authenticated;
revoke all on public.captured_messages from public, anon, authenticated;
grant select on public.event_outbox to authenticated;
grant select on public.captured_messages to authenticated;

-- =====================================================================
-- 2. Event emit triggers (additive; fire in the source fact's transaction,
--    AFTER the legacy write, so legacy behaviour is untouched).
-- =====================================================================
-- sale.completed
create or replace function app.trg_emit_sale_completed()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.reversal_of is not null or new.client_id is null then return new; end if;
  perform app.emit_domain_event(new.business_id, 'sale.completed', 'sale:' || new.id::text,
    new.client_id, null, new.occurred_at, new.config_version_id,
    jsonb_build_object('sale_id', new.id, 'kind', new.kind, 'amount_cents', new.amount_cents,
      'branch_id', new.branch_id, 'staff_id', new.staff_id,
      'counts_as_revenue', new.counts_as_revenue, 'counts_as_visit', new.counts_as_visit,
      'earns_points', new.earns_points));
  return new;
end $$;
revoke all on function app.trg_emit_sale_completed() from public, anon, authenticated;
create trigger trg_ps1b_emit_sale_completed after insert on public.sales
  for each row execute function app.trg_emit_sale_completed();

-- referral.qualified + referral adoption fulfilment (legacy writes from shadow on, B5).
create or replace function app.trg_emit_referral_qualified()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_ref record; v_cut text; v_evt uuid;
begin
  select r.id, r.referrer_client_id, r.referred_client_id, r.reward_cents, r.qualified_sale_id
    into v_ref
    from public.referrals r
   where r.business_id = new.business_id and r.qualified_sale_id = new.sale_id
     and r.referrer_client_id = new.client_id and r.status in ('rewarded','qualified')
   order by r.qualified_at desc nulls last limit 1;
  if not found then return new; end if;
  v_evt := app.emit_domain_event(new.business_id, 'referral.qualified', 'referral_qualify:' || v_ref.id::text,
    v_ref.referred_client_id, null, new.created_at, new.config_version_id,
    jsonb_build_object('referral_id', v_ref.id, 'referrer_client_id', v_ref.referrer_client_id,
      'referred_client_id', v_ref.referred_client_id, 'reward_cents', v_ref.reward_cents,
      'credit_ledger_id', new.id));
  -- referral is in shadow => the legacy authority holder writes its registry row.
  select cutover_status into v_cut from public.benefit_registry
   where business_id = new.business_id and source_engine = 'referral';
  if v_cut in ('shadow','studio') then
    insert into public.benefit_fulfilments(
      business_id, canonical_benefit_key, source_engine, fulfilment_kind, client_id, detail_ref,
      face_value_cents, estimated_cost_cents, cost_basis, cost_confidence, config_version_id, occurred_at)
    values(new.business_id, 'referral:' || v_ref.id::text, 'referral', 'referral_reward',
      v_ref.referrer_client_id, new.id, coalesce(v_ref.reward_cents, new.amount_cents),
      coalesce(v_ref.reward_cents, new.amount_cents), 'credit_face', 'high', new.config_version_id, new.created_at)
    on conflict (business_id, canonical_benefit_key) do nothing;
  end if;
  return new;
end $$;
revoke all on function app.trg_emit_referral_qualified() from public, anon, authenticated;
create trigger trg_ps1b_referral_fulfilment after insert on public.credit_ledger
  for each row when (new.entry_type = 'referral_reward') execute function app.trg_emit_referral_qualified();

-- membership.renewed (period advance)
create or replace function app.trg_emit_membership_renewed()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.current_period_end is not distinct from old.current_period_end
     or new.current_period_end <= old.current_period_end then return new; end if;
  perform app.emit_domain_event(new.business_id, 'membership.renewed',
    'membership_renewal:' || new.id::text || ':' || app.ps1b_period_key(new.current_period_start, 'monthly'),
    new.client_id, null, new.current_period_start, null,
    jsonb_build_object('membership_id', new.id, 'plan_id', new.plan_id,
      'period_key', app.ps1b_period_key(new.current_period_start, 'monthly')));
  return new;
end $$;
revoke all on function app.trg_emit_membership_renewed() from public, anon, authenticated;
create trigger trg_ps1b_emit_membership_renewed after update on public.memberships
  for each row execute function app.trg_emit_membership_renewed();

-- points.redeemed (on completion)
create or replace function app.trg_emit_points_redeemed()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.status <> 'completed' or old.status = 'completed' then return new; end if;
  perform app.emit_domain_event(new.business_id, 'points.redeemed', 'loyalty_op:' || new.id::text,
    new.client_id, null, coalesce(new.completed_at, now()), null,
    jsonb_build_object('loyalty_operation_id', new.id, 'operation_type', new.operation_type,
      'reward_id', new.reward_id, 'result', coalesce(new.result, '{}'::jsonb)));
  return new;
end $$;
revoke all on function app.trg_emit_points_redeemed() from public, anon, authenticated;
create trigger trg_ps1b_emit_points_redeemed after update on public.loyalty_operations
  for each row execute function app.trg_emit_points_redeemed();

-- birthday.activated
create or replace function app.trg_emit_birthday_activated()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_ent record;
begin
  select e.birthday_program_version_id, e.config_version_id, e.birthday_year, e.benefit_snapshot
    into v_ent from public.customer_birthday_entitlements e where e.id = new.entitlement_id;
  perform app.emit_domain_event(new.business_id, 'birthday.activated', 'birthday_activation:' || new.id::text,
    new.client_id, new.identity_id, now(), v_ent.config_version_id,
    jsonb_build_object('entitlement_id', new.entitlement_id, 'birthday_program_version_id', v_ent.birthday_program_version_id,
      'birthday_year', v_ent.birthday_year, 'benefit_snapshot_hash', app.ps1b_sha256(coalesce(v_ent.benefit_snapshot, '{}'::jsonb)::text)));
  return new;
end $$;
revoke all on function app.trg_emit_birthday_activated() from public, anon, authenticated;
create trigger trg_ps1b_emit_birthday_activated after insert on public.customer_birthday_activation_operations
  for each row execute function app.trg_emit_birthday_activated();

-- =====================================================================
-- 10. benefit_registry guard transition (referral legacy->shadow,
--     recurring unbuilt->studio). Authority is NEVER changed; only the
--     lifecycle cutover_status advances, and only under the migration GUC.
-- =====================================================================
create or replace function app.benefit_registry_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'benefit_registry rows are permanent' using errcode = 'restrict_violation';
  end if;
  -- All identity + AUTHORITY columns are immutable here; only cutover_status may
  -- advance, and only for a sanctioned transition gated by the migration GUC.
  if new.business_id is distinct from old.business_id
     or new.source_engine is distinct from old.source_engine
     or new.execution_authority is distinct from old.execution_authority
     or new.canonical_benefit_key_template is distinct from old.canonical_benefit_key_template then
    raise exception 'benefit_registry identity and execution authority are immutable' using errcode = 'restrict_violation';
  end if;
  if current_setting('app.ps1b_registry_transition', true) = 'sanctioned'
     and (
       (old.source_engine = 'referral' and old.execution_authority = 'legacy_trigger'
          and old.cutover_status = 'legacy' and new.cutover_status = 'shadow' and new.shadow_started_at is not null)
       or
       (old.source_engine = 'recurring' and old.execution_authority = 'studio_executor'
          and old.cutover_status = 'unbuilt' and new.cutover_status = 'studio' and new.cutover_at is not null)
     ) then
    return new;
  end if;
  raise exception 'benefit_registry cutover transitions are controlled migrations only' using errcode = 'restrict_violation';
end $$;
revoke all on function app.benefit_registry_guard() from public, anon, authenticated;

-- Apply the two sanctioned transitions across all businesses.
do $ps1b_registry_transition$
begin
  perform set_config('app.ps1b_registry_transition', 'sanctioned', true);
  -- The guard verifies authority is unchanged; the WHERE targets the family by
  -- source_engine + current cutover only (never reads the authority column, so the
  -- PS-1A no-authority-mutation tripwire stays a clean, precise assignment guard).
  update public.benefit_registry set cutover_status = 'shadow', shadow_started_at = now()
   where source_engine = 'referral' and cutover_status = 'legacy';
  update public.benefit_registry set cutover_status = 'studio', cutover_at = now()
   where source_engine = 'recurring' and cutover_status = 'unbuilt';
  perform set_config('app.ps1b_registry_transition', '', true);
end $ps1b_registry_transition$;

-- Businesses created AFTER v56 must be born in the post-PS-1B steady state
-- (the one-time UPDATE above only covers rows that exist at apply time), or the
-- referral adoption insert and the recurring executor would silently stay off
-- for every new tenant. Same 10 families as v55; only the two sanctioned
-- lifecycle states (and their timestamps) differ.
create or replace function app.seed_benefit_registry(p_business uuid)
returns void language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  insert into public.benefit_registry(business_id, source_engine, execution_authority, cutover_status,
    shadow_started_at, cutover_at, canonical_benefit_key_template)
  values
    (p_business, 'points_loyalty', 'legacy_trigger',  'legacy', null, null, 'points_redeem:{loyalty_operation_id}'),
    (p_business, 'retention',      'legacy_trigger',  'legacy', null, null, 'retention:{program_id}:{client_id}:{period_index}'),
    (p_business, 'referral',       'legacy_trigger',  'shadow', now(), null, 'referral:{referral_id}'),
    (p_business, 'birthday',       'legacy_trigger',  'legacy', null, null, 'birthday:{client_id}:{birthday_year}'),
    (p_business, 'membership',     'legacy_trigger',  'legacy', null, null, 'membership_credit:{membership_id}:{period_key}'),
    (p_business, 'campaign',       'legacy_trigger',  'legacy', null, null, 'campaign_offer:{campaign_id}:{client_id}'),
    (p_business, 'tier',           'studio_executor', 'unbuilt', null, null, 'tier_entry:{client_id}:{tier}'),
    (p_business, 'recurring',      'studio_executor', 'studio', null, now(), 'recurring:{rule_id}:{client_id}:{period_key}'),
    (p_business, 'checkout',       'studio_executor', 'unbuilt', null, null, 'discount:{sale_id}:{rule_id}:{effect_index}'),
    (p_business, 'stored_value',   'studio_executor', 'unbuilt', null, null, 'sv_spend:{operation_id}:{movement_id}')
  on conflict (business_id, source_engine) do nothing;
end $$;
revoke all on function app.seed_benefit_registry(uuid) from public, anon, authenticated;

-- =====================================================================
-- 11. The non-checkout entitlement executor. Consults benefit_registry
--     authority before ANY fulfilment write; refuses (shadow-logs) when the
--     family is not studio-active. Moves NO customer value (promises only).
-- =====================================================================
create or replace function app.ps1b_effect_family(p_effect_type text)
returns text language sql immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select case p_effect_type
    when 'grant_free_item'       then 'recurring'
    when 'display_perk'          then 'recurring'
    when 'tier_multiplier'       then 'tier'
    when 'apply_discount_pct'    then 'checkout'
    when 'apply_discount_amount' then 'checkout'
    when 'grant_credit'          then 'points_loyalty'
    when 'earn_bonus_points'     then 'points_loyalty'
    when 'earn_bonus_stamps'     then 'points_loyalty'
    else 'points_loyalty' end
$$;
revoke all on function app.ps1b_effect_family(text) from public, anon, authenticated;

-- Materialise (or replay) a single claimable entitlement for one (client, rule,
-- period). Idempotent by the lazy unique key; reserves budget under a row lock.
create or replace function app.ps1b_materialise_entitlement(
  p_business uuid, p_client uuid, p_rule uuid, p_config uuid, p_period_key text,
  p_kind text, p_snapshot jsonb, p_valid_from timestamptz, p_valid_until timestamptz,
  p_face_cents integer, p_cap_cents integer, p_period_start timestamptz, p_period_end timestamptz)
returns table(entitlement_id uuid, outcome text) language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_ent uuid; v_bp public.budget_periods%rowtype; v_res uuid; v_new boolean := false;
begin
  -- Budget check under a single-row lock (deterministic order trivially met).
  if p_cap_cents is not null then
    insert into public.budget_periods(business_id, rule_id, period_start, period_end, cap_cents)
    values(p_business, p_rule, p_period_start, p_period_end, p_cap_cents)
    on conflict (business_id, rule_id, period_start) do nothing;
    select * into v_bp from public.budget_periods
     where business_id = p_business and rule_id = p_rule and period_start = p_period_start for update;
    -- If the entitlement already exists it keeps its reservation (promise preserved);
    -- only a genuinely NEW grant is subject to the cap.
    if not exists(select 1 from public.program_entitlements
        where business_id = p_business and client_id = p_client and rule_id = p_rule and period_key = p_period_key)
       and v_bp.committed_cents + p_face_cents > coalesce(v_bp.cap_cents, 2147483647) then
      return query select null::uuid, 'budget_exhausted'::text; return;
    end if;
  end if;

  insert into public.program_entitlements(
    business_id, client_id, rule_id, config_version_id, period_key, fulfilment_kind, status,
    benefit_snapshot, valid_from, valid_until)
  values(p_business, p_client, p_rule, p_config, p_period_key, p_kind, 'available',
    coalesce(p_snapshot, '{}'::jsonb), p_valid_from, p_valid_until)
  on conflict (business_id, client_id, rule_id, period_key) do nothing
  returning id into v_ent;
  if v_ent is null then
    select id into v_ent from public.program_entitlements
     where business_id = p_business and client_id = p_client and rule_id = p_rule and period_key = p_period_key;
  else
    v_new := true;
  end if;

  if p_cap_cents is not null then
    insert into public.budget_reservations(business_id, budget_period_id, entitlement_id, amount_cents)
    values(p_business, v_bp.id, v_ent, p_face_cents)
    -- by constraint NAME: the (budget_period_id, entitlement_id) column form is
    -- captured by plpgsql substitution of the entitlement_id OUT parameter.
    on conflict on constraint budget_reservations_period_entitlement_uk do nothing
    returning id into v_res;
    if v_res is not null then
      update public.budget_periods set committed_cents = committed_cents + p_face_cents, updated_at = now()
       where id = v_bp.id;
      update public.program_entitlements set budget_reservation_id = v_res, updated_at = now()
       where id = v_ent and budget_reservation_id is null;
    end if;
  end if;
  return query select v_ent, case when v_new then 'materialised' else 'replayed' end;
end $$;
revoke all on function app.ps1b_materialise_entitlement(uuid, uuid, uuid, uuid, text, text, jsonb, timestamptz, timestamptz, integer, integer, timestamptz, timestamptz) from public, anon, authenticated;

-- Process one domain event through the compiled active rules for its business.
create or replace function app.ps1b_execute_event(p_event uuid)
returns integer language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  ev public.domain_events%rowtype; v_active uuid; r record; v_effect jsonb;
  v_idx integer; v_type text; v_family text; v_auth text; v_cut text;
  v_period text; v_pkey text; v_period_start timestamptz; v_period_end timestamptz;
  v_face integer; v_cap integer; v_valid_until timestamptz; v_ent uuid; v_outcome text;
  v_ful uuid; v_key text; v_count integer := 0; v_has_notify boolean := false;
begin
  select * into ev from public.domain_events where event_id = p_event;
  if not found then return 0; end if;
  if exists(select 1 from public.domain_event_execution where event_id = p_event) then return 0; end if;
  select active_config_version_id into v_active from public.businesses where id = ev.business_id;

  for r in select * from public.program_rules_compiled c
            where c.business_id = ev.business_id and c.config_version_id = v_active
              and c.when_event = ev.event_type and c.active loop
    if not app.ps1b_eval_conditions(ev.payload, r.compiled->'if') then continue; end if;
    v_idx := 0;
    for v_effect in select * from jsonb_array_elements(coalesce(r.compiled->'then', '[]'::jsonb)) loop
      v_type := v_effect->>'effect_type';
      v_family := app.ps1b_effect_family(v_type);
      select execution_authority, cutover_status into v_auth, v_cut
        from public.benefit_registry where business_id = ev.business_id and source_engine = v_family;

      if v_type = 'send_notification' then
        insert into public.event_outbox(business_id, event_id, consumer)
        values(ev.business_id, p_event, 'comms') on conflict (event_id, consumer) do nothing;
        v_has_notify := true;
        insert into public.rule_effect_log(business_id, event_id, rule_id, effect_index, effect_type, outcome, config_version_id)
        values(ev.business_id, p_event, r.rule_id, v_idx, v_type, 'notified', v_active)
        on conflict (event_id, rule_id, effect_index) do nothing;

      elsif v_type = 'display_perk' then
        insert into public.rule_effect_log(business_id, event_id, rule_id, effect_index, effect_type, outcome, config_version_id)
        values(ev.business_id, p_event, r.rule_id, v_idx, v_type, 'display_perk', v_active)
        on conflict (event_id, rule_id, effect_index) do nothing;

      elsif v_type = 'grant_free_item' and v_auth = 'studio_executor' and v_cut = 'studio' then
        -- The ONE value-PROMISING path the PS-1B executor fulfils.
        v_period := coalesce(r.compiled->'with'->>'budget_period', r.compiled->'during'->>'period', 'monthly');
        v_pkey := app.ps1b_period_key(ev.occurred_at, v_period);
        v_period_start := (app.ps1b_period_key(ev.occurred_at, v_period) || case v_period when 'daily' then '' when 'annual' then '-01-01' else '-01' end)::timestamptz;
        v_period_end := v_period_start + case v_period when 'daily' then interval '1 day' when 'annual' then interval '1 year' else interval '1 month' end;
        v_face := coalesce(app.ps1b_catalog_price(ev.business_id, v_effect->>'catalog_kind', nullif(v_effect->>'catalog_id','')::uuid),
                           nullif(v_effect->>'amount_cents','')::integer, 0);
        v_cap := nullif(r.compiled->'with'->>'budget_cap_cents','')::integer;
        v_valid_until := ev.occurred_at + (coalesce(nullif(r.compiled->'with'->>'entitlement_expiry_days','')::integer, 30) || ' days')::interval;
        select entitlement_id, outcome into v_ent, v_outcome from app.ps1b_materialise_entitlement(
          ev.business_id, ev.subject_client_id, r.rule_id, v_active, v_pkey, 'free_item',
          jsonb_build_object('rule_id', r.rule_id, 'effect', v_effect, 'source_engine', 'recurring'),
          ev.occurred_at, v_valid_until, v_face, v_cap, v_period_start, v_period_end);
        if v_outcome = 'budget_exhausted' then
          insert into public.rule_effect_log(business_id, event_id, rule_id, effect_index, effect_type, outcome, config_version_id)
          values(ev.business_id, p_event, r.rule_id, v_idx, v_type, 'budget_exhausted', v_active)
          on conflict (event_id, rule_id, effect_index) do nothing;
        else
          v_key := 'recurring:' || r.rule_id::text || ':' || ev.subject_client_id::text || ':' || v_pkey;
          insert into public.benefit_fulfilments(
            business_id, canonical_benefit_key, source_engine, fulfilment_kind, client_id, detail_ref,
            face_value_cents, estimated_cost_cents, cost_basis, cost_confidence, config_version_id, occurred_at)
          values(ev.business_id, v_key, 'recurring', 'recurring_perk', ev.subject_client_id, v_ent,
            v_face, v_face, 'catalog_cost', 'medium', v_active, ev.occurred_at)
          on conflict (business_id, canonical_benefit_key) do nothing
          returning id into v_ful;
          if v_ful is null then select id into v_ful from public.benefit_fulfilments
             where business_id = ev.business_id and canonical_benefit_key = v_key; end if;
          insert into public.rule_effect_log(business_id, event_id, rule_id, effect_index, effect_type, outcome, benefit_fulfilment_id, config_version_id)
          values(ev.business_id, p_event, r.rule_id, v_idx, v_type, 'fulfilled', v_ful, v_active)
          on conflict (event_id, rule_id, effect_index) do nothing;
        end if;

      else
        -- Everything else (value-moving effects, tier, checkout, or a legacy
        -- family) is SHADOW-LOGGED in PS-1B. No value moves.
        insert into public.benefit_shadow_evaluations(
          business_id, event_id, source_engine, rule_id, would_be_canonical_key, client_id,
          fulfilment_kind, face_value_cents, estimated_cost_cents, cost_basis, cost_confidence, config_version_id)
        values(ev.business_id, p_event, v_family, r.rule_id,
          v_family || ':' || r.rule_id::text || ':' || coalesce(ev.subject_client_id::text,'-') || ':' || v_idx::text,
          ev.subject_client_id, v_type,
          coalesce(nullif(v_effect->>'amount_cents','')::integer, 0),
          coalesce(nullif(v_effect->>'amount_cents','')::integer, 0), 'margin_band', 'low', v_active)
        on conflict (business_id, would_be_canonical_key, event_id) do nothing;
        insert into public.rule_effect_log(business_id, event_id, rule_id, effect_index, effect_type, outcome, config_version_id)
        values(ev.business_id, p_event, r.rule_id, v_idx, v_type, 'shadow', v_active)
        on conflict (event_id, rule_id, effect_index) do nothing;
      end if;
      v_idx := v_idx + 1;
      v_count := v_count + 1;
    end loop;
  end loop;

  insert into public.domain_event_execution(event_id, business_id, effect_count)
  values(p_event, ev.business_id, v_count) on conflict (event_id) do nothing;
  return v_count;
end $$;
revoke all on function app.ps1b_execute_event(uuid) from public, anon, authenticated;

-- Sweep: process unexecuted events (bounded). Cron-invoked + test-invoked.
create or replace function app.run_studio_executor(p_limit integer default 500)
returns integer language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare e record; v_total integer := 0;
begin
  for e in select d.event_id from public.domain_events d
            where d.event_type in ('sale.completed','birthday.activated','membership.renewed')
              and not exists(select 1 from public.domain_event_execution x where x.event_id = d.event_id)
            order by d.recorded_at limit greatest(p_limit, 1) loop
    v_total := v_total + app.ps1b_execute_event(e.event_id);
  end loop;
  return v_total;
end $$;
revoke all on function app.run_studio_executor(integer) from public, anon, authenticated;

-- =====================================================================
-- 12. Referral shadow evaluator + comparator. Writes ONLY the shadow log.
-- =====================================================================
create or replace function app.run_referral_shadow(p_limit integer default 500)
returns integer language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare e record; v_active uuid; v_count integer := 0;
begin
  for e in select d.* from public.domain_events d
            where d.event_type = 'referral.qualified'
              and not exists(select 1 from public.benefit_shadow_evaluations s
                              where s.event_id = d.event_id and s.source_engine = 'referral')
            order by d.recorded_at limit greatest(p_limit, 1) loop
    select active_config_version_id into v_active from public.businesses where id = e.business_id;
    insert into public.benefit_shadow_evaluations(
      business_id, event_id, source_engine, rule_id, would_be_canonical_key, client_id,
      fulfilment_kind, face_value_cents, estimated_cost_cents, cost_basis, cost_confidence, config_version_id)
    values(e.business_id, e.event_id, 'referral', null,
      'referral:' || (e.payload->>'referral_id'), (e.payload->>'referrer_client_id')::uuid, 'referral_reward',
      coalesce((e.payload->>'reward_cents')::integer, 0), coalesce((e.payload->>'reward_cents')::integer, 0),
      'credit_face', 'high', v_active)
    on conflict (business_id, would_be_canonical_key, event_id) do nothing;
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;
revoke all on function app.run_referral_shadow(integer) from public, anon, authenticated;

-- Comparator: diff shadow log vs the live engine's fulfilment registry rows.
create or replace function app.compare_shadow_vs_live(p_business uuid, p_engine text default 'referral')
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_shadow_only integer; v_live_only integer; v_mismatch integer; v_matched integer;
begin
  select count(*) into v_shadow_only from public.benefit_shadow_evaluations s
   where s.business_id = p_business and s.source_engine = p_engine
     and not exists(select 1 from public.benefit_fulfilments f
                     where f.business_id = s.business_id and f.canonical_benefit_key = s.would_be_canonical_key);
  select count(*) into v_live_only from public.benefit_fulfilments f
   where f.business_id = p_business and f.source_engine = p_engine
     and not exists(select 1 from public.benefit_shadow_evaluations s
                     where s.business_id = f.business_id and s.would_be_canonical_key = f.canonical_benefit_key);
  select count(*) filter (where s.fulfilment_kind <> f.fulfilment_kind or s.face_value_cents <> f.face_value_cents
                               or s.estimated_cost_cents <> f.estimated_cost_cents),
         count(*)
    into v_mismatch, v_matched
    from public.benefit_shadow_evaluations s
    join public.benefit_fulfilments f
      on f.business_id = s.business_id and f.canonical_benefit_key = s.would_be_canonical_key
   where s.business_id = p_business and s.source_engine = p_engine;
  return jsonb_build_object('engine', p_engine, 'matched', coalesce(v_matched,0),
    'shadow_only', v_shadow_only, 'live_only', v_live_only, 'mismatches', coalesce(v_mismatch,0),
    'clean', (v_shadow_only = 0 and v_live_only = 0 and coalesce(v_mismatch,0) = 0));
end $$;
revoke all on function app.compare_shadow_vs_live(uuid, text) from public, anon, authenticated;

-- =====================================================================
-- 13. Outbox sweep + CAPTURE/TEST comms provider (synthetic recipients only).
--     Delivery == writing a captured_messages row. Failures back off honestly.
-- =====================================================================
create or replace function app.run_outbox_sweep(p_limit integer default 200)
returns integer language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare o record; ev public.domain_events%rowtype; v_recipient text; v_done integer := 0; v_fail boolean;
begin
  for o in select * from public.event_outbox
            where delivery_status in ('pending','failed') and next_attempt_at <= now()
            order by next_attempt_at for update skip locked limit greatest(p_limit, 1) loop
    update public.event_outbox set delivery_status = 'delivering', updated_at = now() where id = o.id;
    v_fail := nullif(current_setting('app.ps1b_capture_fail', true), '') = '1';
    begin
      if v_fail then raise exception 'simulated comms provider outage'; end if;
      select * into ev from public.domain_events where event_id = o.event_id;
      -- Synthetic-only recipient. A real address/number is structurally uninsertable.
      v_recipient := 'synthetic:' || coalesce(ev.subject_client_id::text, ev.subject_identity_id::text, o.event_id::text) || '@example.test';
      insert into public.captured_messages(business_id, event_id, outbox_id, channel, recipient, template_key, rendered)
      values(o.business_id, o.event_id, o.id, 'in_app', v_recipient, ev.event_type,
        jsonb_build_object('event_type', ev.event_type, 'subject_client_id', ev.subject_client_id))
      on conflict (outbox_id) do nothing;
      update public.event_outbox set delivery_status = 'delivered', attempts = attempts + 1, updated_at = now(), last_error = null
       where id = o.id;
      v_done := v_done + 1;
    exception when others then
      update public.event_outbox
         set attempts = attempts + 1,
             delivery_status = case when attempts + 1 >= max_attempts then 'dead_letter' else 'failed' end,
             next_attempt_at = now() + (least(power(2, attempts + 1), 3600) || ' seconds')::interval,
             last_error = sqlerrm, updated_at = now()
       where id = o.id;
    end;
  end loop;
  return v_done;
end $$;
revoke all on function app.run_outbox_sweep(integer) from public, anon, authenticated;

-- =====================================================================
-- 14. SGT cron discipline (mirrors the live 03:00-SGT convention).
-- =====================================================================
do $ps1b_cron$
begin
  perform cron.schedule('frenly-studio-executor', '*/5 * * * *', $c$select app.run_studio_executor(500);$c$);
  perform cron.schedule('frenly-outbox-sweep',    '*/2 * * * *', $c$select app.run_outbox_sweep(200);$c$);
  perform cron.schedule('frenly-referral-shadow',  '15 19 * * *', $c$select app.run_referral_shadow(1000);$c$);
exception when others then null;  -- pg_cron may be absent in a bare rehearsal db
end $ps1b_cron$;

-- =====================================================================
-- 15. Staff-facing entitlement RPCs (c45 redeem pattern) + owner reads.
-- =====================================================================
create or replace function public.redeem_program_entitlement(p_entitlement uuid, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare e public.program_entitlements%rowtype; v_hash text; v_prior uuid; v_prior_hash text;
begin
  if p_idempotency_key is null then raise exception 'idempotency key required' using errcode = '22023'; end if;
  select * into e from public.program_entitlements where id = p_entitlement for update;
  if not found or not app.is_salon_member(e.business_id) then raise exception 'access denied' using errcode = '42501'; end if;
  if not app.can_module(e.business_id, 'loyalty') then raise exception 'access denied' using errcode = '42501'; end if;
  v_hash := app.ps1b_sha256('redeem:' || p_entitlement::text);
  -- idempotent replay — the key must belong to THIS request (v41/v51a house
  -- pattern: reusing a key for a different entitlement is an error, not a replay).
  select entitlement_id, request_hash into v_prior, v_prior_hash
    from public.program_entitlement_operations
   where business_id = e.business_id and operation_type = 'redeem' and idempotency_key = p_idempotency_key;
  if v_prior is not null then
    if v_prior <> e.id or v_prior_hash <> v_hash then
      raise exception 'idempotency key was already used for a different request' using errcode = '22023';
    end if;
    return jsonb_build_object('entitlement_id', e.id, 'status', e.status, 'replayed', true);
  end if;
  if e.status <> 'available' then raise exception 'entitlement is not available' using errcode = '23514'; end if;
  update public.program_entitlements set status = 'redeemed', redeemed_at = now(), updated_at = now() where id = e.id;
  insert into public.program_entitlement_operations(business_id, client_id, operation_type, idempotency_key, request_hash, entitlement_id)
  values(e.business_id, e.client_id, 'redeem', p_idempotency_key, v_hash, e.id);
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values(e.business_id, auth.uid(), 'REDEEM_ENTITLEMENT', 'program_entitlements', e.id, jsonb_build_object('client_id', e.client_id));
  return jsonb_build_object('entitlement_id', e.id, 'status', 'redeemed', 'replayed', false);
end $$;

create or replace function public.reverse_program_entitlement(p_entitlement uuid, p_reason text, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare e public.program_entitlements%rowtype; v_hash text; v_prior uuid; v_prior_hash text;
begin
  if p_idempotency_key is null then raise exception 'idempotency key required' using errcode = '22023'; end if;
  if char_length(coalesce(btrim(p_reason), '')) < 3 then raise exception 'a reason is required' using errcode = '22023'; end if;
  select * into e from public.program_entitlements where id = p_entitlement for update;
  if not found or not app.is_salon_owner(e.business_id) then raise exception 'owner only' using errcode = '42501'; end if;
  v_hash := app.ps1b_sha256('reverse:' || p_entitlement::text || ':' || p_reason);
  select entitlement_id, request_hash into v_prior, v_prior_hash
    from public.program_entitlement_operations
   where business_id = e.business_id and operation_type = 'reverse' and idempotency_key = p_idempotency_key;
  if v_prior is not null then
    if v_prior <> e.id or v_prior_hash <> v_hash then
      raise exception 'idempotency key was already used for a different request' using errcode = '22023';
    end if;
    return jsonb_build_object('entitlement_id', e.id, 'status', e.status, 'replayed', true);
  end if;
  if e.status not in ('available','redeemed') then raise exception 'entitlement cannot be reversed' using errcode = '23514'; end if;
  update public.program_entitlements set status = 'reversed', reversed_at = now(), updated_at = now() where id = e.id;
  insert into public.program_entitlement_operations(business_id, client_id, operation_type, idempotency_key, request_hash, entitlement_id)
  values(e.business_id, e.client_id, 'reverse', p_idempotency_key, v_hash, e.id);
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values(e.business_id, auth.uid(), 'REVERSE_ENTITLEMENT', 'program_entitlements', e.id, jsonb_build_object('reason', p_reason));
  return jsonb_build_object('entitlement_id', e.id, 'status', 'reversed', 'replayed', false);
end $$;

create or replace function public.get_program_entitlements(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_result jsonb;
begin
  if not (app.is_salon_member(p_business) or app.is_super_admin()) then raise exception 'access denied' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'entitlement_id', e.id, 'client_id', e.client_id, 'rule_id', e.rule_id, 'period_key', e.period_key,
    'fulfilment_kind', e.fulfilment_kind, 'status', e.status, 'valid_from', e.valid_from, 'valid_until', e.valid_until,
    'benefit_snapshot', e.benefit_snapshot) order by e.created_at desc), '[]'::jsonb)
    into v_result from public.program_entitlements e where e.business_id = p_business;
  return jsonb_build_object('business_id', p_business, 'entitlements', v_result);
end $$;

create or replace function public.get_studio_dead_letters(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_result jsonb;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then raise exception 'owner only' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'outbox_id', o.id, 'event_id', o.event_id, 'consumer', o.consumer, 'delivery_status', o.delivery_status,
    'attempts', o.attempts, 'last_error', o.last_error, 'next_attempt_at', o.next_attempt_at) order by o.updated_at desc), '[]'::jsonb)
    into v_result from public.event_outbox o
   where o.business_id = p_business and o.delivery_status in ('failed','dead_letter');
  return jsonb_build_object('business_id', p_business, 'dead_letters', v_result);
end $$;

create or replace function public.get_shadow_comparison(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then raise exception 'owner only' using errcode = '42501'; end if;
  return app.compare_shadow_vs_live(p_business, 'referral');
end $$;

-- =====================================================================
-- 16. ACLs.
-- =====================================================================
revoke all on function public.redeem_program_entitlement(uuid, uuid) from public, anon;
revoke all on function public.reverse_program_entitlement(uuid, text, uuid) from public, anon;
revoke all on function public.get_program_entitlements(uuid) from public, anon;
revoke all on function public.get_studio_dead_letters(uuid) from public, anon;
revoke all on function public.get_shadow_comparison(uuid) from public, anon;
grant execute on function public.redeem_program_entitlement(uuid, uuid) to authenticated;
grant execute on function public.reverse_program_entitlement(uuid, text, uuid) to authenticated;
grant execute on function public.get_program_entitlements(uuid) to authenticated;
grant execute on function public.get_studio_dead_letters(uuid) to authenticated;
grant execute on function public.get_shadow_comparison(uuid) to authenticated;

commit;
