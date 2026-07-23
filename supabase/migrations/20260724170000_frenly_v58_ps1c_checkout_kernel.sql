-- FRENLY v58 - PROGRAM STUDIO PS-1C: THE UNIFIED CHECKOUT KERNEL
--
-- Local review candidate. Production apply needs the owner's RELEASE APPROVED
-- phrase (CLAUDE.md standing gate). PS-1C authorized 2026-07-24 (owner) and the
-- PS-GATES marker + tripwire (tests/program-studio/ps0-no-executor.test.mjs) are
-- flipped in the SAME change that lands this schema.
--
-- WHAT THIS IS
--   ONE authoritative, server-owned checkout kernel. A staff device holds only an
--   OPAQUE evaluation-token handle; nothing in it is client-computable or
--   client-priceable. Discounts are authored in Program Studio (v55) as
--   apply_discount_pct / apply_discount_amount effects on when_event='sale.completed'
--   rules (that is the seeded allowlist event key - see v55 §2, rule_effect_allowlist,
--   which seeds apply_discount_* under 'sale.completed' and 'birthday.activated' only;
--   there is NO 'checkout.completed' event, so checkout rules ARE sale.completed
--   rules and are evaluated against a synthetic {amount_cents, kind:'cart_sale',
--   branch_id, client_id, counts_as_visit, earns_points} payload). PS-1B keeps
--   SHADOW-LOGGING apply_discount_* for events; THIS kernel's synchronous token
--   path is the ONLY place a discount is ever actually applied to money.
--
-- MONEY ORDER OF OPERATIONS (architecture §9)
--   line discounts (per-line, ordered rule_id,effect_index) -> bill discounts
--   (ordered rule_id,effect_index) -> tax base on the discounted total (SG overlay:
--   GST-INCLUSIVE extraction, informational, total unchanged - ⚖️ classification
--   reviewable) -> integer-cent rounding (pct half-up per target) -> total fixed at
--   completion -> tender (none / partial / full split), which the token never governs.
--
-- ATOMIC REVALIDATION (architecture §9)
--   The finaliser locks the token FOR UPDATE and, in the SAME transaction, re-checks
--   unconsumed + unexpired + same active config version + re-resolves every server
--   price (recomputes cart_hash) + re-checks and COMMITS budget under a deterministic
--   (business_id, rule_id, period_start) lock order. Any drift -> 'stale_evaluation'
--   (P0001); the client re-evaluates. Stale discounts are never silently applied and
--   never silently dropped.
--
-- MUST NOT (owner scope): no studio points/credit effects (grant_credit /
--   earn_bonus_* stay SHADOW-only in the executor, untouched here); no stored-value
--   tender; no tier financial rewards; no real comms; NO studio ledger-guard scope
--   (the kernel writes NO credit_ledger / points_ledger - discounts reduce
--   sales.amount_cents BEFORE app.on_sale_recorded fires, so points/retention/referral
--   earn on the DISCOUNTED total, which is correct); legacy loyalty engines untouched.

begin;

-- =====================================================================
-- 1. GST (SG overlay). GST-INCLUSIVE extraction only: informational, the total
--    is NEVER changed by GST. ⚖️ classification map is reviewable by counsel.
-- =====================================================================
alter table public.businesses
  add column if not exists gst_registered boolean not null default false;
alter table public.businesses
  add column if not exists gst_rate_bps integer not null default 900
    check (gst_rate_bps >= 0 and gst_rate_bps <= 2000);

-- =====================================================================
-- 2. budget_reservations: teach it to also back a checkout DISCOUNT commitment.
--    v56 made entitlement_id NOT NULL; a discount reservation has no entitlement,
--    it points at the discount's benefit_fulfilment. Exactly one owner column is
--    set. Append-only guard (v56 trg_budget_reservations_guard) is unchanged.
-- =====================================================================
alter table public.budget_reservations alter column entitlement_id drop not null;
alter table public.budget_reservations add column discount_fulfilment_id uuid;
alter table public.budget_reservations
  add constraint budget_reservations_id_business_uk unique (id, business_id);
alter table public.budget_reservations
  add constraint budget_reservations_one_owner_check check (
    (entitlement_id is not null and discount_fulfilment_id is null)
    or (entitlement_id is null and discount_fulfilment_id is not null));
-- (business_id, id) parent key already exists on benefit_fulfilments (v56).
alter table public.budget_reservations
  add constraint budget_reservations_discount_fulfilment_fk
  foreign key (discount_fulfilment_id, business_id)
  references public.benefit_fulfilments(id, business_id) on delete restrict;
-- one reservation per (period, discount fulfilment); NULLs (the entitlement path)
-- are distinct so the v56 (budget_period_id, entitlement_id) uniqueness is untouched.
create unique index budget_reservations_discount_uk
  on public.budget_reservations (budget_period_id, discount_fulfilment_id)
  where discount_fulfilment_id is not null;

-- =====================================================================
-- 3. sale_items: admit a signed studio_discount line so Σ(sale_items) reconciles
--    to the discounted sales.amount_cents byte-for-byte. A discount line is the
--    ONLY negative line; every other line stays non-negative. line = qty*unit holds
--    for all rows. sale_items is empty in a fresh replay at this point, so re-adding
--    the CHECKs is safe (and on real data every existing row is a non-discount line
--    that already satisfies the new predicate).
-- =====================================================================
alter table public.sale_items drop constraint if exists sale_items_item_type_check;
alter table public.sale_items drop constraint if exists sale_items_unit_cents_check;
alter table public.sale_items drop constraint if exists sale_items_line_cents_check;
do $sale_items_checks$
declare c record;
begin
  -- Belt-and-suspenders: drop any residual CHECK governing item_type / unit_cents /
  -- line_cents regardless of the auto name pg assigned. The qty CHECK (qty > 0) is
  -- deliberately preserved (a discount line uses qty=1).
  for c in
    select con.conname
      from pg_catalog.pg_constraint con
      join pg_catalog.pg_class rel on rel.oid = con.conrelid
      join pg_catalog.pg_namespace ns on ns.oid = rel.relnamespace
     where ns.nspname = 'public' and rel.relname = 'sale_items' and con.contype = 'c'
       and pg_catalog.pg_get_constraintdef(con.oid) ~* '(item_type|unit_cents|line_cents)'
  loop
    execute format('alter table public.sale_items drop constraint %I', c.conname);
  end loop;
end $sale_items_checks$;

alter table public.sale_items
  add constraint sale_items_item_type_check check (item_type in
    ('service', 'retail', 'package', 'membership', 'gift_card', 'custom', 'studio_discount'));
alter table public.sale_items
  add constraint sale_items_amount_sign_check check (
    line_cents = qty * unit_cents
    and (
      (item_type = 'studio_discount' and unit_cents <= 0 and line_cents <= 0)
      or (item_type <> 'studio_discount' and unit_cents >= 0 and line_cents >= 0)
    ));

-- =====================================================================
-- 4. checkout_evaluations - the server-owned evaluation TOKEN (architecture §9).
--    The opaque uuid handle is the only thing the client holds. RLS owner+sa read,
--    NO browser write. Single-use is enforced by the finaliser under a row lock;
--    a write-once guard makes consumed_at / consumed_sale_id settable exactly once
--    and everything else immutable.
-- =====================================================================
create table public.checkout_evaluations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id uuid not null,
  client_id uuid,
  server_lines jsonb not null check (jsonb_typeof(server_lines) = 'array'),
  cart_hash text not null check (cart_hash ~ '^[0-9a-f]{64}$'),
  config_version_id uuid,
  applied_effects jsonb not null default '[]'::jsonb check (jsonb_typeof(applied_effects) = 'array'),
  subtotal_cents integer not null check (subtotal_cents >= 0),
  discount_total_cents integer not null check (discount_total_cents >= 0),
  total_cents integer not null check (total_cents >= 0),
  gst_cents integer not null default 0 check (gst_cents >= 0),
  gst_rate_bps integer not null default 0 check (gst_rate_bps >= 0 and gst_rate_bps <= 2000),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  consumed_sale_id uuid,
  created_at timestamptz not null default now(),
  constraint checkout_evaluations_id_business_uk unique (id, business_id),
  constraint checkout_evaluations_totals_check check (total_cents = subtotal_cents - discount_total_cents),
  constraint checkout_evaluations_branch_fk foreign key (branch_id, business_id)
    references public.branches(id, business_id) on delete restrict,
  constraint checkout_evaluations_client_fk foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint checkout_evaluations_config_fk foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict,
  constraint checkout_evaluations_consumed_sale_fk foreign key (consumed_sale_id, business_id)
    references public.sales(id, business_id) on delete restrict,
  constraint checkout_evaluations_consumed_check check (
    (consumed_at is null) = (consumed_sale_id is null))
);
create index checkout_evaluations_business_idx on public.checkout_evaluations (business_id, created_at);

create or replace function app.checkout_evaluations_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'checkout_evaluations rows are permanent' using errcode = 'restrict_violation';
  end if;
  if new.id is distinct from old.id or new.business_id is distinct from old.business_id
     or new.branch_id is distinct from old.branch_id or new.client_id is distinct from old.client_id
     or new.server_lines is distinct from old.server_lines or new.cart_hash is distinct from old.cart_hash
     or new.config_version_id is distinct from old.config_version_id
     or new.applied_effects is distinct from old.applied_effects
     or new.subtotal_cents is distinct from old.subtotal_cents
     or new.discount_total_cents is distinct from old.discount_total_cents
     or new.total_cents is distinct from old.total_cents or new.gst_cents is distinct from old.gst_cents
     or new.gst_rate_bps is distinct from old.gst_rate_bps or new.expires_at is distinct from old.expires_at
     or new.created_at is distinct from old.created_at then
    raise exception 'checkout evaluation identity and economics are immutable' using errcode = 'restrict_violation';
  end if;
  -- consumed_at / consumed_sale_id are write-once (null -> value, then frozen).
  if old.consumed_at is not null and new.consumed_at is distinct from old.consumed_at then
    raise exception 'checkout evaluation is already consumed (single-use)' using errcode = 'restrict_violation';
  end if;
  if old.consumed_sale_id is not null and new.consumed_sale_id is distinct from old.consumed_sale_id then
    raise exception 'checkout evaluation consumed_sale_id is write-once' using errcode = 'restrict_violation';
  end if;
  return new;
end $$;
revoke all on function app.checkout_evaluations_guard() from public, anon, authenticated;
create trigger trg_checkout_evaluations_guard before update or delete on public.checkout_evaluations
  for each row execute function app.checkout_evaluations_guard();

alter table public.checkout_evaluations enable row level security;
create policy checkout_evaluations_owner_read on public.checkout_evaluations for select to authenticated using (app.is_salon_owner(business_id));
create policy checkout_evaluations_sa_read on public.checkout_evaluations for select to authenticated using (app.is_super_admin());
revoke all on public.checkout_evaluations from public, anon, authenticated;
grant select on public.checkout_evaluations to authenticated;

-- =====================================================================
-- 5. checkout_evaluation_operations - keyed idempotency ledger for evaluate_checkout
--    (the v51a/v41 op-ledger house pattern). Reuses the v41 append-only guard.
-- =====================================================================
create table public.checkout_evaluation_operations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  actor uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  evaluation_id uuid not null,
  created_at timestamptz not null default now(),
  constraint checkout_eval_ops_idem_uk unique (business_id, idempotency_key),
  constraint checkout_eval_ops_evaluation_fk foreign key (evaluation_id, business_id)
    references public.checkout_evaluations(id, business_id) on delete restrict
);
create index checkout_eval_ops_business_idx on public.checkout_evaluation_operations (business_id, created_at);
create trigger checkout_eval_ops_immutable_guard
  before update or delete on public.checkout_evaluation_operations
  for each row execute function app.v41_operation_immutable_guard();

alter table public.checkout_evaluation_operations enable row level security;
create policy checkout_eval_ops_owner_read on public.checkout_evaluation_operations for select to authenticated using (app.is_salon_owner(business_id));
create policy checkout_eval_ops_sa_read on public.checkout_evaluation_operations for select to authenticated using (app.is_super_admin());
revoke all on public.checkout_evaluation_operations from public, anon, authenticated;
grant select on public.checkout_evaluation_operations to authenticated;

-- =====================================================================
-- 6. checkout_discount_lines - per-effect provenance for every applied discount.
--    The ONLY writer is the token finaliser (record_cart_sale WITH a token); the
--    FK to checkout_evaluations means every provenance row traces to a consumed
--    token. Append-only. benefit_fulfilment_id is MANDATORY (single-count registry).
-- =====================================================================
create table public.checkout_discount_lines (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  sale_id uuid not null,
  evaluation_id uuid not null,
  rule_id uuid not null,
  effect_index integer not null check (effect_index >= 0),
  effect_type text not null check (effect_type in ('apply_discount_pct', 'apply_discount_amount')),
  level text not null check (level in ('line', 'bill')),
  target_line_index integer,
  amount_cents integer not null check (amount_cents > 0),
  benefit_fulfilment_id uuid not null,
  config_version_id uuid not null,
  created_at timestamptz not null default now(),
  constraint checkout_discount_lines_id_business_uk unique (id, business_id),
  constraint checkout_discount_lines_effect_uk unique (sale_id, rule_id, effect_index),
  constraint checkout_discount_lines_sale_fk foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete restrict,
  constraint checkout_discount_lines_eval_fk foreign key (evaluation_id, business_id)
    references public.checkout_evaluations(id, business_id) on delete restrict,
  constraint checkout_discount_lines_fulfilment_fk foreign key (benefit_fulfilment_id, business_id)
    references public.benefit_fulfilments(id, business_id) on delete restrict,
  constraint checkout_discount_lines_config_fk foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict
);
create index checkout_discount_lines_sale_idx on public.checkout_discount_lines (business_id, sale_id);
create index checkout_discount_lines_rule_idx on public.checkout_discount_lines (business_id, rule_id, created_at);

create or replace function app.checkout_discount_lines_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'checkout_discount_lines is append-only (reversals are new signed fulfilments)' using errcode = 'restrict_violation';
  return null;
end $$;
revoke all on function app.checkout_discount_lines_guard() from public, anon, authenticated;
create trigger trg_checkout_discount_lines_guard before update or delete on public.checkout_discount_lines
  for each row execute function app.checkout_discount_lines_guard();

alter table public.checkout_discount_lines enable row level security;
create policy checkout_discount_lines_owner_read on public.checkout_discount_lines for select to authenticated using (app.is_salon_owner(business_id));
create policy checkout_discount_lines_sa_read on public.checkout_discount_lines for select to authenticated using (app.is_super_admin());
revoke all on public.checkout_discount_lines from public, anon, authenticated;
grant select on public.checkout_discount_lines to authenticated;

-- =====================================================================
-- 7. budget_commitment_releases - exact release of a checkout discount's budget
--    commitment on reversal. Invariant: committed_cents = Σreservations − Σreleases,
--    committed_cents >= 0. Append-only; one release per reservation.
-- =====================================================================
create table public.budget_commitment_releases (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  budget_period_id uuid not null,
  reservation_id uuid not null,
  amount_cents integer not null check (amount_cents > 0),
  reversal_sale_id uuid not null,
  created_at timestamptz not null default now(),
  constraint budget_commitment_releases_reservation_uk unique (reservation_id),
  constraint budget_commitment_releases_period_fk foreign key (budget_period_id, business_id)
    references public.budget_periods(id, business_id) on delete restrict,
  constraint budget_commitment_releases_reservation_fk foreign key (reservation_id, business_id)
    references public.budget_reservations(id, business_id) on delete restrict,
  constraint budget_commitment_releases_reversal_sale_fk foreign key (reversal_sale_id, business_id)
    references public.sales(id, business_id) on delete restrict
);
create index budget_commitment_releases_period_idx on public.budget_commitment_releases (business_id, budget_period_id, created_at);

create or replace function app.budget_commitment_releases_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'budget_commitment_releases is append-only' using errcode = 'restrict_violation';
  return null;
end $$;
revoke all on function app.budget_commitment_releases_guard() from public, anon, authenticated;
create trigger trg_budget_commitment_releases_guard before update or delete on public.budget_commitment_releases
  for each row execute function app.budget_commitment_releases_guard();

alter table public.budget_commitment_releases enable row level security;
create policy budget_commitment_releases_owner_read on public.budget_commitment_releases for select to authenticated using (app.is_salon_owner(business_id));
create policy budget_commitment_releases_sa_read on public.budget_commitment_releases for select to authenticated using (app.is_super_admin());
revoke all on public.budget_commitment_releases from public, anon, authenticated;
grant select on public.budget_commitment_releases to authenticated;

-- =====================================================================
-- 8. benefit_registry cutover: the checkout family unbuilt -> studio, via the SAME
--    GUC-gated mechanism as v56 (referral legacy->shadow, recurring unbuilt->studio).
--    Execution AUTHORITY is never mutated (checkout is already studio_executor);
--    only cutover_status advances, under app.ps1c_registry_transition='sanctioned'.
--    The v56 sanctioned transitions are preserved so nothing regresses.
-- =====================================================================
create or replace function app.benefit_registry_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'benefit_registry rows are permanent' using errcode = 'restrict_violation';
  end if;
  if new.business_id is distinct from old.business_id
     or new.source_engine is distinct from old.source_engine
     or new.execution_authority is distinct from old.execution_authority
     or new.canonical_benefit_key_template is distinct from old.canonical_benefit_key_template then
    raise exception 'benefit_registry identity and execution authority are immutable' using errcode = 'restrict_violation';
  end if;
  -- v56 sanctioned transitions (unchanged).
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
  -- v58 sanctioned transition: the checkout family goes live (unbuilt -> studio).
  if current_setting('app.ps1c_registry_transition', true) = 'sanctioned'
     and old.source_engine = 'checkout' and old.execution_authority = 'studio_executor'
     and old.cutover_status = 'unbuilt' and new.cutover_status = 'studio' and new.cutover_at is not null then
    return new;
  end if;
  raise exception 'benefit_registry cutover transitions are controlled migrations only' using errcode = 'restrict_violation';
end $$;
revoke all on function app.benefit_registry_guard() from public, anon, authenticated;

do $ps1c_registry_transition$
begin
  perform set_config('app.ps1c_registry_transition', 'sanctioned', true);
  -- The WHERE never reads the authority column, so the PS-1A no-authority-mutation
  -- tripwire stays a clean, precise assignment guard.
  update public.benefit_registry set cutover_status = 'studio', cutover_at = now()
   where source_engine = 'checkout' and cutover_status = 'unbuilt';
  perform set_config('app.ps1c_registry_transition', '', true);
end $ps1c_registry_transition$;

-- Businesses created AFTER v58 are born in the post-PS-1C steady state (the one-time
-- UPDATE above only covers rows that exist at apply time). Reborn seed: checkout is
-- now 'studio' with a cutover_at; referral 'shadow' and recurring 'studio' carry
-- forward from v56; nothing else changes.
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
    (p_business, 'checkout',       'studio_executor', 'studio', null, now(), 'discount:{sale_id}:{rule_id}:{effect_index}'),
    (p_business, 'stored_value',   'studio_executor', 'unbuilt', null, null, 'sv_spend:{operation_id}:{movement_id}')
  on conflict (business_id, source_engine) do nothing;
end $$;
revoke all on function app.seed_benefit_registry(uuid) from public, anon, authenticated;

-- =====================================================================
-- 9. Pure kernel helpers (browser-closed, no DML - not writer surfaces).
-- =====================================================================
-- Deterministic cart hash over the PRICE-relevant projection of server_lines
-- (index, kind, id, qty, unit price, line total). Names are intentionally excluded
-- so a catalog rename is NOT price drift, but a price change IS.
create or replace function app.ps1c_cart_hash(p_server_lines jsonb)
returns text language sql immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select app.ps1b_sha256(coalesce((
    select jsonb_agg(jsonb_build_array(
             ord, e->>'catalog_kind', e->>'catalog_id',
             e->>'qty', e->>'unit_price_cents', e->>'line_total_cents') order by ord)
      from jsonb_array_elements(p_server_lines) with ordinality as t(e, ord)
  ), '[]'::jsonb)::text)
$$;
revoke all on function app.ps1c_cart_hash(jsonb) from public, anon, authenticated;

-- SGT-derived budget period bounds (mirrors the v56 executor's period math exactly).
create or replace function app.ps1c_period_bounds(p_occurred timestamptz, p_period text,
  out period_start timestamptz, out period_end timestamptz)
language plpgsql immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_key text := app.ps1b_period_key(p_occurred, coalesce(nullif(p_period, ''), 'monthly'));
begin
  period_start := (v_key || case coalesce(nullif(p_period, ''), 'monthly')
                     when 'daily' then '' when 'annual' then '-01-01' else '-01' end)::timestamptz;
  period_end := period_start + case coalesce(nullif(p_period, ''), 'monthly')
                  when 'daily' then interval '1 day' when 'annual' then interval '1 year' else interval '1 month' end;
end $$;
revoke all on function app.ps1c_period_bounds(timestamptz, text) from public, anon, authenticated;

-- The deterministic evaluation engine. Reads catalog + compiled rules + budget
-- counters (PROJECTED - no reservation). Returns the full plan as jsonb, or a typed
-- price failure. NO DML - fails closed on any non-ok catalog price (no silent zero).
create or replace function app.ps1c_plan_checkout(
  p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_config uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_line jsonb; v_ord int := 0; v_n int;
  v_kind text[]; v_id uuid[]; v_name text[]; v_unit int[]; v_qty int[]; v_ltot int[]; v_rem int[];
  v_subtotal bigint := 0; v_price jsonb; v_pstatus text; v_nm text;
  v_server jsonb := '[]'::jsonb;
  v_payload jsonb; v_active_rules boolean := (p_config is not null);
  r record; v_eff jsonb; v_idx int; v_etype text; v_ckind text; v_cid uuid; v_level text;
  v_stackable boolean; v_cap int; v_period text;
  v_cand jsonb := '[]'::jsonb;   -- gathered discount candidates
  v_applied jsonb := '[]'::jsonb;
  v_total_discount bigint := 0; v_any_line boolean := false; v_any_bill boolean := false;
  c jsonb; v_target int; v_base int; v_d int; v_reason text; v_suppressed boolean;
  v_ps timestamptz; v_pe timestamptz; v_committed int; v_projected int;
  v_rule_proj jsonb := '{}'::jsonb; v_gst_reg boolean; v_gst_bps int; v_total int; v_gst int;
  j int;
begin
  if jsonb_typeof(p_lines) <> 'array' then
    return jsonb_build_object('status', 'invalid', 'reason', 'lines must be a JSON array');
  end if;
  v_n := jsonb_array_length(p_lines);
  if v_n < 1 or v_n > 50 then
    return jsonb_build_object('status', 'invalid', 'reason', 'a cart must have between 1 and 50 lines');
  end if;

  -- 9.1 Resolve every server price (fail closed).
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_ord := v_ord + 1;
    -- Nothing is client-priceable: any price/amount key on a line is a hard error.
    if v_line ? 'unit_price_cents' or v_line ? 'price_cents' or v_line ? 'amount_cents'
       or v_line ? 'line_total_cents' or v_line ? 'unit_cents' or v_line ? 'discount' then
      return jsonb_build_object('status', 'client_priced', 'line', v_ord,
        'reason', 'checkout lines carry catalog_kind + catalog_id + qty ONLY; nothing is client-priceable');
    end if;
    v_ckind := v_line->>'catalog_kind';
    if v_ckind is null or v_ckind not in ('service', 'product') then
      return jsonb_build_object('status', 'bad_kind', 'line', v_ord, 'reason', 'catalog_kind must be service or product');
    end if;
    if jsonb_typeof(v_line->'qty') is distinct from 'number' then
      return jsonb_build_object('status', 'bad_qty', 'line', v_ord, 'reason', 'qty must be a number');
    end if;
    if (v_line->>'qty')::numeric <> trunc((v_line->>'qty')::numeric)
       or (v_line->>'qty')::numeric < 1 or (v_line->>'qty')::numeric > 1000000 then
      return jsonb_build_object('status', 'bad_qty', 'line', v_ord, 'reason', 'qty must be a whole number 1..1000000');
    end if;
    v_cid := nullif(v_line->>'catalog_id', '')::uuid;
    v_price := app.ps1b_catalog_price(p_business, v_ckind, v_cid);
    v_pstatus := v_price->>'status';
    if v_pstatus <> 'ok' then
      return jsonb_build_object('status', 'price_error', 'line', v_ord, 'catalog_kind', v_ckind,
        'catalog_id', v_cid, 'reason', v_pstatus || ':' || coalesce(v_price->>'reason', ''));
    end if;
    if v_ckind = 'service' then
      select name into v_nm from public.services where id = v_cid and business_id = p_business;
    else
      select name into v_nm from public.products where id = v_cid and business_id = p_business;
    end if;
    v_kind := array_append(v_kind, v_ckind);
    v_id := array_append(v_id, v_cid);
    v_name := array_append(v_name, coalesce(v_nm, v_ckind));
    v_unit := array_append(v_unit, (v_price->>'price_cents')::int);
    v_qty := array_append(v_qty, (v_line->>'qty')::int);
    v_ltot := array_append(v_ltot, (v_price->>'price_cents')::int * (v_line->>'qty')::int);
    v_rem := array_append(v_rem, (v_price->>'price_cents')::int * (v_line->>'qty')::int);
    v_subtotal := v_subtotal + ((v_price->>'price_cents')::int * (v_line->>'qty')::int);
  end loop;

  if v_subtotal <= 0 then
    return jsonb_build_object('status', 'invalid', 'reason', 'a checkout must total more than zero');
  end if;
  if v_subtotal > 2147483647 then
    return jsonb_build_object('status', 'invalid', 'reason', 'checkout subtotal exceeds the supported maximum');
  end if;

  for j in 1 .. array_length(v_kind, 1) loop
    v_server := v_server || jsonb_build_array(jsonb_build_object(
      'catalog_kind', v_kind[j], 'catalog_id', v_id[j], 'name', v_name[j],
      'unit_price_cents', v_unit[j], 'qty', v_qty[j], 'line_total_cents', v_ltot[j]));
  end loop;

  -- 9.2 Gather discount candidates from ACTIVE sale.completed rules (the seeded
  --     event key for apply_discount_*). Conditions evaluate against a synthetic
  --     cart payload. Deterministic order: line effects first, then bill effects;
  --     within each, ordered by (rule_id, effect_index).
  v_payload := jsonb_build_object('amount_cents', v_subtotal, 'kind', 'cart_sale',
    'branch_id', to_jsonb(p_branch::text), 'client_id', to_jsonb(coalesce(p_client::text, '')),
    'counts_as_visit', true, 'earns_points', true);
  if v_active_rules then
    for r in select c2.rule_id, c2.compiled from public.program_rules_compiled c2
              where c2.business_id = p_business and c2.config_version_id = p_config
                and c2.when_event = 'sale.completed' and c2.active
              order by c2.rule_id loop
      if not app.ps1b_eval_conditions(v_payload, r.compiled->'if') then continue; end if;
      v_stackable := coalesce((r.compiled->'using'->>'stackable')::boolean, true);
      v_cap := nullif(r.compiled->'with'->>'budget_cap_cents', '')::int;
      v_period := coalesce(r.compiled->'with'->>'budget_period', 'monthly');
      v_idx := 0;
      for v_eff in select * from jsonb_array_elements(coalesce(r.compiled->'then', '[]'::jsonb)) loop
        v_etype := v_eff->>'effect_type';
        if v_etype in ('apply_discount_pct', 'apply_discount_amount') then
          v_ckind := nullif(v_eff->>'catalog_kind', '');
          v_cid := nullif(v_eff->>'catalog_id', '')::uuid;
          v_level := case when v_ckind is not null and v_cid is not null then 'line' else 'bill' end;
          v_cand := v_cand || jsonb_build_array(jsonb_build_object(
            'rule_id', r.rule_id, 'effect_index', v_idx, 'effect_type', v_etype, 'level', v_level,
            'catalog_kind', v_ckind, 'catalog_id', v_cid,
            'discount_pct', v_eff->>'discount_pct', 'amount_cents', v_eff->>'amount_cents',
            'stackable', v_stackable, 'cap_cents', v_cap, 'period', v_period));
        end if;
        v_idx := v_idx + 1;
      end loop;
    end loop;
  end if;

  -- 9.3 Apply candidates in deterministic order.
  for c in
    select e from jsonb_array_elements(v_cand) e
     order by (e->>'level') desc,  -- 'line' > 'bill' alphabetically, so desc = line first
              (e->>'rule_id'), (e->>'effect_index')::int
  loop
    v_suppressed := false; v_reason := null; v_d := 0; v_target := null;
    v_stackable := (c->>'stackable')::boolean;
    v_cap := nullif(c->>'cap_cents', '')::int;
    v_period := c->>'period';

    -- stacking: a non-stackable rule refuses to stack on an existing discount at its level.
    if not v_stackable and ((c->>'level' = 'line' and v_any_line) or (c->>'level' = 'bill' and v_any_bill)) then
      v_suppressed := true; v_reason := 'stacking';
    end if;

    -- compute the raw discount against the correct base.
    if not v_suppressed then
      if c->>'level' = 'line' then
        v_target := null;
        for j in 1 .. array_length(v_kind, 1) loop
          if v_kind[j] = (c->>'catalog_kind') and v_id[j] = nullif(c->>'catalog_id', '')::uuid and v_rem[j] > 0 then
            v_target := j; exit;
          end if;
        end loop;
        if v_target is null then
          v_suppressed := true; v_reason := 'no_target';
        else
          v_base := v_rem[v_target];
        end if;
      else
        v_base := (v_subtotal - v_total_discount)::int;
        if v_base <= 0 then v_suppressed := true; v_reason := 'no_target'; end if;
      end if;
    end if;

    if not v_suppressed then
      if c->>'effect_type' = 'apply_discount_pct' then
        v_d := round(v_base::numeric * (c->>'discount_pct')::numeric / 100.0)::int;
      else
        v_d := least((c->>'amount_cents')::int, v_base);
      end if;
      if v_d > v_base then v_d := v_base; end if;
      if v_d < 0 then v_d := 0; end if;
      if v_d = 0 then v_suppressed := true; v_reason := 'no_target'; end if;
    end if;

    -- budget cap: projected against the persisted counter + running per-rule total.
    v_ps := null; v_pe := null;
    if v_cap is not null then
      select period_start, period_end into v_ps, v_pe from app.ps1c_period_bounds(now(), v_period);
    end if;
    if not v_suppressed and v_cap is not null then
      select coalesce(committed_cents, 0) into v_committed from public.budget_periods
       where business_id = p_business and rule_id = (c->>'rule_id')::uuid and period_start = v_ps;
      v_committed := coalesce(v_committed, 0);
      v_projected := coalesce((v_rule_proj->>(c->>'rule_id'))::int, 0);
      if v_committed + v_projected + v_d > v_cap then
        v_suppressed := true; v_reason := 'budget_exhausted';
      else
        v_rule_proj := v_rule_proj || jsonb_build_object(c->>'rule_id', v_projected + v_d);
      end if;
    end if;

    if v_suppressed then
      v_applied := v_applied || jsonb_build_array(jsonb_build_object(
        'rule_id', c->>'rule_id', 'effect_index', (c->>'effect_index')::int, 'effect_type', c->>'effect_type',
        'level', c->>'level', 'target_line_index', v_target, 'amount_cents', 0,
        'suppressed', true, 'suppression_reason', v_reason,
        'capped', v_cap is not null, 'cap_cents', v_cap,
        'period_start', v_ps, 'period_end', v_pe));
    else
      if c->>'level' = 'line' then
        v_rem[v_target] := v_rem[v_target] - v_d; v_any_line := true;
      else
        v_any_bill := true;
      end if;
      v_total_discount := v_total_discount + v_d;
      v_applied := v_applied || jsonb_build_array(jsonb_build_object(
        'rule_id', c->>'rule_id', 'effect_index', (c->>'effect_index')::int, 'effect_type', c->>'effect_type',
        'level', c->>'level', 'target_line_index', v_target, 'amount_cents', v_d,
        'suppressed', false, 'suppression_reason', null,
        'capped', v_cap is not null, 'cap_cents', v_cap,
        'period_start', v_ps, 'period_end', v_pe));
    end if;
  end loop;

  v_total := (v_subtotal - v_total_discount)::int;

  -- 9.4 GST-INCLUSIVE extraction (informational; total unchanged). ⚖️ reviewable.
  select gst_registered, gst_rate_bps into v_gst_reg, v_gst_bps from public.businesses where id = p_business;
  if coalesce(v_gst_reg, false) and coalesce(v_gst_bps, 0) > 0 then
    v_gst := round(v_total::numeric * v_gst_bps / (10000 + v_gst_bps))::int;
  else
    v_gst_bps := 0; v_gst := 0;
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'server_lines', v_server,
    'subtotal_cents', v_subtotal::int,
    'applied_effects', v_applied,
    'discount_total_cents', v_total_discount::int,
    'total_cents', v_total,
    'gst_cents', v_gst,
    'gst_rate_bps', coalesce(v_gst_bps, 0),
    'cart_hash', app.ps1c_cart_hash(v_server));
end $$;
revoke all on function app.ps1c_plan_checkout(uuid, uuid, uuid, jsonb, uuid) from public, anon, authenticated;

-- =====================================================================
-- 10. public.evaluate_checkout - mint an opaque evaluation token. Staff with
--     create_sales (the record_cart_sale auth pattern). Idempotent by
--     p_idempotency_key via the checkout_evaluation_operations ledger: a replay
--     with the SAME key returns the SAME token while it is unexpired + unconsumed,
--     else a 22023 'stale'. Nothing here moves money.
-- =====================================================================
create or replace function public.evaluate_checkout(
  p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_branch uuid;
  v_config uuid;
  v_hash text;
  v_existing public.checkout_evaluation_operations%rowtype;
  v_eval public.checkout_evaluations%rowtype;
  v_plan jsonb;
  v_eval_id uuid;
begin
  if v_actor is null then
    raise exception 'authenticated staff required to evaluate a checkout' using errcode = '42501';
  end if;
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to price a checkout in this business (create_sales)'
      using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'a checkout evaluation idempotency key is required' using errcode = '22023';
  end if;
  v_branch := coalesce(p_branch, app.default_branch(p_business));
  if v_branch is null or not exists (
    select 1 from public.branches b where b.id = v_branch and b.business_id = p_business and b.active) then
    raise exception 'checkout branch is missing, inactive, or belongs to another business' using errcode = '22023';
  end if;
  if not app.can_see_branch(p_business, v_branch) then
    raise exception 'you are not permitted to price a checkout for this branch scope' using errcode = '42501';
  end if;
  if p_client is not null and not exists (
    select 1 from public.clients c where c.id = p_client and c.business_id = p_business) then
    raise exception 'checkout client does not belong to this business' using errcode = '22023';
  end if;

  v_hash := app.ps1b_sha256(jsonb_build_object(
    'business_id', p_business, 'branch_id', v_branch, 'client_id', p_client, 'lines', p_lines)::text);

  perform pg_advisory_xact_lock(hashtextextended(
    'v58:evaluate:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.checkout_evaluation_operations o
   where o.business_id = p_business and o.idempotency_key = p_idempotency_key for update;
  if found then
    if v_existing.actor is distinct from v_actor or v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different checkout evaluation' using errcode = '22023';
    end if;
    select * into v_eval from public.checkout_evaluations where id = v_existing.evaluation_id;
    if v_eval.consumed_at is not null or v_eval.expires_at <= now() then
      raise exception 'stale: this checkout evaluation is already consumed or expired; re-evaluate' using errcode = '22023';
    end if;
    return jsonb_build_object(
      'status', 'ok', 'replayed', true, 'evaluation_id', v_eval.id, 'expires_at', v_eval.expires_at,
      'server_lines', v_eval.server_lines, 'applied_effects', v_eval.applied_effects,
      'subtotal_cents', v_eval.subtotal_cents, 'discount_total_cents', v_eval.discount_total_cents,
      'total_cents', v_eval.total_cents, 'gst_cents', v_eval.gst_cents);
  end if;

  select active_config_version_id into v_config from public.businesses where id = p_business;

  v_plan := app.ps1c_plan_checkout(p_business, v_branch, p_client, p_lines, v_config);
  if v_plan->>'status' <> 'ok' then
    raise exception 'checkout cannot be priced (line %): %',
      coalesce(v_plan->>'line', '-'), coalesce(v_plan->>'reason', v_plan->>'status')
      using errcode = '22023';
  end if;

  insert into public.checkout_evaluations(
    business_id, branch_id, client_id, server_lines, cart_hash, config_version_id, applied_effects,
    subtotal_cents, discount_total_cents, total_cents, gst_cents, gst_rate_bps, expires_at)
  values(
    p_business, v_branch, p_client, v_plan->'server_lines', v_plan->>'cart_hash', v_config,
    v_plan->'applied_effects', (v_plan->>'subtotal_cents')::int, (v_plan->>'discount_total_cents')::int,
    (v_plan->>'total_cents')::int, (v_plan->>'gst_cents')::int, (v_plan->>'gst_rate_bps')::int,
    now() + interval '10 minutes')
  returning id into v_eval_id;

  insert into public.checkout_evaluation_operations(business_id, actor, idempotency_key, request_hash, evaluation_id)
  values(p_business, v_actor, p_idempotency_key, v_hash, v_eval_id);

  return jsonb_build_object(
    'status', 'ok', 'replayed', false, 'evaluation_id', v_eval_id,
    'expires_at', now() + interval '10 minutes',
    'server_lines', v_plan->'server_lines', 'applied_effects', v_plan->'applied_effects',
    'subtotal_cents', (v_plan->>'subtotal_cents')::int, 'discount_total_cents', (v_plan->>'discount_total_cents')::int,
    'total_cents', (v_plan->>'total_cents')::int, 'gst_cents', (v_plan->>'gst_cents')::int);
end $$;
revoke all on function public.evaluate_checkout(uuid, uuid, uuid, jsonb, uuid) from public, anon, authenticated;
grant execute on function public.evaluate_checkout(uuid, uuid, uuid, jsonb, uuid) to authenticated;

-- =====================================================================
-- 11. public.record_cart_sale(..., p_evaluation_id, p_paid) - the KERNEL FINALISER.
--     A NEW overload (arity 9); the v51 7-arg cart signature is untouched. The
--     opaque token is authoritative: p_lines is accepted only for call-shape
--     compatibility with the v51 cart signature and is NEVER priced. Atomic
--     revalidation + budget commit + signed discount lines + provenance, all in one
--     transaction. Reuses record_quick_sale for the parent sale (so points/retention/
--     referral earn on the DISCOUNTED total via the existing sale-trigger chain).
-- =====================================================================
create or replace function public.record_cart_sale(
  p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text,
  p_idempotency_key text, p_lines jsonb, p_evaluation_id uuid, p_paid boolean default true)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_key text := nullif(btrim(p_idempotency_key), '');
  v_method text := lower(nullif(btrim(p_method), ''));
  v_paid boolean := coalesce(p_paid, true);
  v_eval public.checkout_evaluations%rowtype;
  v_line jsonb; v_ord int; v_rehash text; v_price jsonb;
  v_kind text; v_cid uuid; v_qty int; v_unit int;
  v_reproj jsonb := '[]'::jsonb;
  v_retail_lines int := 0; v_stamp_product uuid; v_stamp_qty int;
  v_financial jsonb; v_sale_id uuid; v_replayed boolean;
  eff jsonb; v_ps timestamptz; v_amt int; v_ful uuid; v_key_ben text; v_rule uuid; v_rule_name text;
  bp record; v_bp_id uuid; v_committed int; v_points int := 0; v_items json;
begin
  if v_actor is null then
    raise exception 'authenticated staff required to finalise a cart sale' using errcode = '42501';
  end if;
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to record a sale in this business (create_sales)' using errcode = '42501';
  end if;
  if v_key is null or length(v_key) < 8 then
    raise exception 'a cart-sale idempotency key of at least 8 characters is required' using errcode = '22023';
  end if;
  if v_method is null or v_method not in ('cash', 'card', 'paynow', 'other') then
    raise exception 'choose Cash, Card, PayNow or Other' using errcode = '22023';
  end if;
  if p_evaluation_id is null then
    raise exception 'the kernel finaliser requires a checkout evaluation token' using errcode = '22023';
  end if;

  -- 11.1 Lock the token. Single-use + tenant + scope validation.
  select * into v_eval from public.checkout_evaluations
   where id = p_evaluation_id and business_id = p_business for update;
  if not found then
    raise exception 'checkout evaluation not found in this business' using errcode = '42501';
  end if;
  -- The token's server-resolved branch/client are AUTHORITATIVE. A caller may omit
  -- them (NULL) and inherit the token's; a non-NULL value that disagrees is a stale
  -- mismatch. Everything below (the sale, points, provenance) uses the token values.
  if p_branch is not null and p_branch is distinct from v_eval.branch_id then
    raise exception 'stale_evaluation: branch does not match the evaluation token' using errcode = 'P0001';
  end if;
  if p_client is not null and p_client is distinct from v_eval.client_id then
    raise exception 'stale_evaluation: client does not match the evaluation token' using errcode = 'P0001';
  end if;

  -- 11.2 If already consumed, this is either an exact replay of THIS key, or a loser
  --      in a same-token/different-key race (which must fail stale, never double-sell).
  if v_eval.consumed_at is not null then
    if exists (select 1 from public.financial_operations fo
                where fo.business_id = p_business and fo.sale_id = v_eval.consumed_sale_id
                  and fo.operation_type = 'quick_sale' and fo.idempotency_key = v_key) then
      -- exact replay: return the already-committed result deterministically.
      select coalesce(sum(pl.points), 0) into v_points from public.points_ledger pl
       where pl.business_id = p_business and pl.sale_id = v_eval.consumed_sale_id and pl.entry_type = 'earn';
      select coalesce(json_agg(row_to_json(si) order by si.created_at, si.id), '[]'::json) into v_items
        from public.sale_items si where si.business_id = p_business and si.sale_id = v_eval.consumed_sale_id;
      return json_build_object('status', 'duplicate_ignored', 'sale_id', v_eval.consumed_sale_id,
        'business_id', p_business, 'total_cents', v_eval.total_cents, 'discount_total_cents', v_eval.discount_total_cents,
        'replayed', true, 'points_earned', 0, 'evaluation_id', v_eval.id, 'items', v_items);
    end if;
    raise exception 'stale_evaluation: this checkout evaluation was already consumed by another sale' using errcode = 'P0001';
  end if;
  if v_eval.expires_at <= now() then
    raise exception 'stale_evaluation: the checkout evaluation has expired; re-evaluate' using errcode = 'P0001';
  end if;

  -- 11.3 Config drift: the active config version must be UNCHANGED since evaluation.
  if v_eval.config_version_id is distinct from
     (select active_config_version_id from public.businesses where id = p_business) then
    raise exception 'stale_evaluation: the active configuration changed since evaluation; re-evaluate' using errcode = 'P0001';
  end if;

  -- 11.4 Price drift: re-resolve every server line and recompute the cart hash.
  v_ord := 0;
  for v_line in select * from jsonb_array_elements(v_eval.server_lines) loop
    v_ord := v_ord + 1;
    v_kind := v_line->>'catalog_kind';
    v_cid := nullif(v_line->>'catalog_id', '')::uuid;
    v_qty := (v_line->>'qty')::int;
    v_price := app.ps1b_catalog_price(p_business, v_kind, v_cid);
    if v_price->>'status' <> 'ok' then
      raise exception 'stale_evaluation: line % can no longer be priced (%); re-evaluate', v_ord, v_price->>'status'
        using errcode = 'P0001';
    end if;
    v_unit := (v_price->>'price_cents')::int;
    v_reproj := v_reproj || jsonb_build_array(jsonb_build_object(
      'catalog_kind', v_kind, 'catalog_id', v_cid, 'name', v_line->>'name',
      'unit_price_cents', v_unit, 'qty', v_qty, 'line_total_cents', v_unit * v_qty));
    if v_kind = 'product' then v_retail_lines := v_retail_lines + 1; v_stamp_product := v_cid; v_stamp_qty := v_qty; end if;
  end loop;
  v_rehash := app.ps1c_cart_hash(v_reproj);
  if v_rehash is distinct from v_eval.cart_hash then
    raise exception 'stale_evaluation: catalog prices changed since evaluation; re-evaluate' using errcode = 'P0001';
  end if;

  -- 11.5 Budget re-check + COMMIT, atomically, under a deterministic
  --      (business_id, rule_id, period_start) lock order. Ensure the rows exist,
  --      then lock them all in sorted order, then re-check each capped rule's cap.
  for eff in select e from jsonb_array_elements(v_eval.applied_effects) e
              where (e->>'suppressed')::boolean is not true and coalesce((e->>'capped')::boolean, false) loop
    insert into public.budget_periods(business_id, rule_id, period_start, period_end, cap_cents)
    values(p_business, (eff->>'rule_id')::uuid, (eff->>'period_start')::timestamptz,
           (eff->>'period_end')::timestamptz, (eff->>'cap_cents')::int)
    on conflict (business_id, rule_id, period_start) do nothing;
  end loop;
  -- Lock AND re-check each capped rule's period row one at a time in the deterministic
  -- (rule_id, period_start) order (business_id constant here), so concurrent multi-rule
  -- checkouts can never deadlock and the loser sees the winner's committed increment.
  for bp in select (e->>'rule_id')::uuid as rule_id, (e->>'period_start')::timestamptz as ps,
                    (e->>'cap_cents')::int as cap, sum((e->>'amount_cents')::int) as amt
              from jsonb_array_elements(v_eval.applied_effects) e
             where (e->>'suppressed')::boolean is not true and coalesce((e->>'capped')::boolean, false)
             group by 1, 2, 3
             order by 1, 2 loop
    select coalesce(committed_cents, 0) into v_committed from public.budget_periods
     where business_id = p_business and rule_id = bp.rule_id and period_start = bp.ps
     for update;
    if coalesce(v_committed, 0) + bp.amt > bp.cap then
      raise exception 'stale_evaluation: rule budget was exhausted since evaluation; re-evaluate' using errcode = 'P0001';
    end if;
  end loop;

  -- 11.6 Create the parent sale for the DISCOUNTED total via the kernel candidate.
  --      Points/retention/referral earn on this discounted amount (correct).
  perform set_config('app.cart_line_product_id',
    coalesce(case when v_retail_lines = 1 then v_stamp_product::text end, ''), true);
  perform set_config('app.cart_line_qty',
    coalesce(case when v_retail_lines = 1 then v_stamp_qty::text end, ''), true);
  v_financial := public.record_quick_sale(
    p_business => p_business, p_amount_cents => v_eval.total_cents, p_method => v_method,
    p_client => v_eval.client_id, p_staff => p_staff, p_branch => v_eval.branch_id, p_note => 'cart checkout (kernel)',
    p_idempotency_key => v_key, p_paid => v_paid)::jsonb;
  perform set_config('app.cart_line_product_id', '', true);
  perform set_config('app.cart_line_qty', '', true);

  v_sale_id := nullif(v_financial #>> '{sale,id}', '')::uuid;
  v_replayed := coalesce((v_financial->>'replayed')::boolean, false);
  if v_sale_id is null then
    raise exception 'kernel finaliser did not produce a parent sale row' using errcode = 'XX001';
  end if;
  if v_replayed then
    -- The token was unconsumed but this key already made a sale: inconsistent input.
    -- Never double-write provenance; surface it as a stale token to re-evaluate.
    raise exception 'stale_evaluation: this idempotency key already produced a sale for a different token' using errcode = 'P0001';
  end if;

  -- 11.7 Write server-line sale_items (positive) then one signed studio_discount
  --      line per applied effect (negative). Σ(sale_items) == sales.amount_cents.
  insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents, product_id)
  select v_sale_id, p_business,
         case e->>'catalog_kind' when 'service' then 'service' else 'retail' end,
         nullif(e->>'catalog_id', '')::uuid, e->>'name', (e->>'qty')::int, (e->>'unit_price_cents')::int,
         (e->>'unit_price_cents')::int * (e->>'qty')::int,
         case when e->>'catalog_kind' = 'product' then nullif(e->>'catalog_id', '')::uuid end
    from jsonb_array_elements(v_eval.server_lines) e;

  -- 11.8 Per applied (non-suppressed) discount: fulfilment registry row, provenance
  --      line, signed sale_items line, and (if capped) a committed budget reservation.
  for eff in select e from jsonb_array_elements(v_eval.applied_effects) e
              where (e->>'suppressed')::boolean is not true and (e->>'amount_cents')::int > 0
              order by (e->>'rule_id'), (e->>'effect_index')::int loop
    v_rule := (eff->>'rule_id')::uuid;
    v_amt := (eff->>'amount_cents')::int;
    select name into v_rule_name from public.program_rules
      where rule_id = v_rule and config_version_id = v_eval.config_version_id and business_id = p_business;
    v_rule_name := coalesce(v_rule_name, 'Studio discount');

    v_key_ben := 'discount:' || v_sale_id::text || ':' || v_rule::text || ':' || (eff->>'effect_index');
    insert into public.benefit_fulfilments(
      business_id, canonical_benefit_key, source_engine, fulfilment_kind, client_id, detail_ref,
      face_value_cents, estimated_cost_cents, cost_basis, cost_confidence, config_version_id, occurred_at)
    values(p_business, v_key_ben, 'checkout', 'checkout_discount', v_eval.client_id, v_sale_id,
      v_amt, v_amt, 'discount_face', 'high', v_eval.config_version_id, now())
    returning id into v_ful;

    insert into public.checkout_discount_lines(
      business_id, sale_id, evaluation_id, rule_id, effect_index, effect_type, level, target_line_index,
      amount_cents, benefit_fulfilment_id, config_version_id)
    values(p_business, v_sale_id, v_eval.id, v_rule, (eff->>'effect_index')::int, eff->>'effect_type',
      eff->>'level', nullif(eff->>'target_line_index', '')::int, v_amt, v_ful, v_eval.config_version_id);

    insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents)
    values(v_sale_id, p_business, 'studio_discount', v_rule, left('Discount: ' || v_rule_name, 200), 1, -v_amt, -v_amt);

    if coalesce((eff->>'capped')::boolean, false) then
      v_ps := (eff->>'period_start')::timestamptz;
      select id into v_bp_id from public.budget_periods
        where business_id = p_business and rule_id = v_rule and period_start = v_ps;
      insert into public.budget_reservations(business_id, budget_period_id, discount_fulfilment_id, amount_cents)
      values(p_business, v_bp_id, v_ful, v_amt);
      update public.budget_periods set committed_cents = committed_cents + v_amt, updated_at = now()
       where id = v_bp_id;
    end if;
  end loop;

  -- 11.9 Consume the token (single-use).
  update public.checkout_evaluations set consumed_at = now(), consumed_sale_id = v_sale_id
   where id = v_eval.id and consumed_at is null;
  if not found then
    raise exception 'stale_evaluation: token consumed concurrently; re-evaluate' using errcode = 'P0001';
  end if;

  if v_eval.client_id is not null then
    select coalesce(sum(pl.points), 0) into v_points from public.points_ledger pl
     where pl.business_id = p_business and pl.client_id = v_eval.client_id and pl.sale_id = v_sale_id and pl.entry_type = 'earn';
  end if;
  select coalesce(json_agg(row_to_json(si) order by si.created_at, si.id), '[]'::json) into v_items
    from public.sale_items si where si.business_id = p_business and si.sale_id = v_sale_id;

  return json_build_object(
    'status', 'ok', 'sale_id', v_sale_id, 'business_id', p_business,
    'subtotal_cents', v_eval.subtotal_cents, 'discount_total_cents', v_eval.discount_total_cents,
    'total_cents', v_eval.total_cents, 'gst_cents', v_eval.gst_cents,
    'replayed', false, 'points_earned', v_points, 'evaluation_id', v_eval.id,
    'sale', v_financial->'sale', 'items', v_items);
end $$;
revoke all on function public.record_cart_sale(uuid, uuid, uuid, uuid, text, text, jsonb, uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.record_cart_sale(uuid, uuid, uuid, uuid, text, text, jsonb, uuid, boolean)
  to authenticated;

-- =====================================================================
-- 12. Reversal - exact compensating release of a kernel discount. We extend the
--     PUBLIC boundary following the repo's own rename-and-wrap idiom (v34 renamed
--     reverse_sale -> reverse_sale_v20_base; v40 renamed reverse_sale ->
--     reverse_sale_v34_base). reverse_sale_v20_base (the money/reversal-sale core)
--     is preserved byte-for-byte; the outer reverse_sale now ALSO, after the base
--     creates the reversing sale row, writes a compensating benefit_fulfilment per
--     discount and RELEASES the budget commitment. All idempotent by canonical key /
--     reservation uniqueness, so a replayed reversal is a clean no-op.
-- =====================================================================
alter function public.reverse_sale(uuid, uuid, text, text, text, text) rename to reverse_sale_v40_base;
revoke all privileges on function public.reverse_sale_v40_base(uuid, uuid, text, text, text, text)
  from public, anon, authenticated;

create or replace function public.reverse_sale(
  p_business uuid, p_sale uuid, p_reason text, p_idempotency_key text,
  p_reference text default null, p_restock_policy text default 'none')
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_res json;
  v_reversal_sale uuid;
  d record;
  v_key text;
begin
  -- Delegate the entire existing reversal (auth, package/provenance, money core).
  v_res := public.reverse_sale_v40_base(p_business, p_sale, p_reason, p_idempotency_key, p_reference, p_restock_policy);
  v_reversal_sale := nullif(v_res->>'reversal_sale_id', '')::uuid;
  if v_reversal_sale is null then
    return v_res;   -- nothing reversed (should not happen on success) - pass through.
  end if;

  -- Compensate any checkout discounts recorded against the ORIGINAL sale. Idempotent:
  -- the compensating fulfilment key and the per-reservation release uniqueness make a
  -- replayed reversal a strict no-op.
  for d in
    select cdl.rule_id, cdl.effect_index, cdl.amount_cents, cdl.benefit_fulfilment_id, cdl.config_version_id
      from public.checkout_discount_lines cdl
     where cdl.business_id = p_business and cdl.sale_id = p_sale
     order by cdl.rule_id, cdl.effect_index
  loop
    v_key := 'discount_reversal:' || v_reversal_sale::text || ':' || d.rule_id::text || ':' || d.effect_index::text;
    insert into public.benefit_fulfilments(
      business_id, canonical_benefit_key, source_engine, fulfilment_kind, client_id, detail_ref,
      face_value_cents, estimated_cost_cents, cost_basis, cost_confidence, config_version_id,
      reverses_fulfilment_id, occurred_at)
    select p_business, v_key, 'checkout', 'checkout_discount_reversal',
      (select client_id from public.benefit_fulfilments where id = d.benefit_fulfilment_id and business_id = p_business),
      v_reversal_sale, -d.amount_cents, -d.amount_cents, 'discount_face', 'high', d.config_version_id,
      d.benefit_fulfilment_id, now()
    on conflict (business_id, canonical_benefit_key) do nothing;

    -- Release the budget commitment (committed_cents -= amount) under a row lock,
    -- exactly once per reservation. The CTE inserts the release only when it does
    -- not already exist and RETURNS only the newly-inserted row, so the counter
    -- decrement happens once. A replayed reversal inserts nothing and decrements
    -- nothing. Invariant: committed = Σreservations − Σreleases >= 0.
    perform 1 from public.budget_periods bp
     where bp.business_id = p_business
       and bp.id in (select budget_period_id from public.budget_reservations
                      where business_id = p_business and discount_fulfilment_id = d.benefit_fulfilment_id)
     for update;
    with rel as (
      insert into public.budget_commitment_releases(
        business_id, budget_period_id, reservation_id, amount_cents, reversal_sale_id)
      select p_business, br.budget_period_id, br.id, br.amount_cents, v_reversal_sale
        from public.budget_reservations br
       where br.business_id = p_business and br.discount_fulfilment_id = d.benefit_fulfilment_id
      on conflict (reservation_id) do nothing
      returning budget_period_id, amount_cents)
    update public.budget_periods bp
       set committed_cents = committed_cents - rel.amount_cents, updated_at = now()
      from rel where bp.id = rel.budget_period_id;
  end loop;

  return v_res;
end $$;
revoke all on function public.reverse_sale(uuid, uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.reverse_sale(uuid, uuid, text, text, text, text) to authenticated;

-- =====================================================================
-- 13. public.get_checkout_discount_report - owner-only reconciliation + CSV.
--     Reconciliation invariant (asserted by the suite): grand-total discount_cents
--     = Σ checkout_discount_lines.amount_cents in range = Σ positive checkout
--     benefit_fulfilments face. gst_cents is informational (⚖️).
-- =====================================================================
create or replace function public.get_checkout_discount_report(
  p_business uuid, p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_rows jsonb;
  v_grand jsonb;
  v_csv text;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'a valid from/to date range is required' using errcode = '22023';
  end if;

  -- Per (SGT day, rule) aggregate. Distinct-sale sales_total / gst avoid the
  -- double-count that summing a per-line grain would cause when a sale carries
  -- several discount lines. All CTEs are scoped to THIS single statement.
  with lines as (
    select cdl.rule_id, cdl.amount_cents, cdl.sale_id, s.amount_cents as sale_total,
           (s.occurred_at at time zone 'Asia/Singapore')::date as sgt_date,
           ce.gst_cents
      from public.checkout_discount_lines cdl
      join public.sales s on s.id = cdl.sale_id and s.business_id = cdl.business_id
      join public.checkout_evaluations ce on ce.id = cdl.evaluation_id and ce.business_id = cdl.business_id
     where cdl.business_id = p_business
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  sale_grain as (
    select distinct sgt_date, rule_id, sale_id, sale_total, gst_cents from lines
  ),
  discount_grain as (
    select sgt_date, rule_id, count(*)::int as discount_count, sum(amount_cents)::int as discount_cents
      from lines group by sgt_date, rule_id
  ),
  sale_totals as (
    select sgt_date, rule_id, sum(sale_total)::int as sales_total_cents, sum(gst_cents)::int as gst_cents
      from sale_grain group by sgt_date, rule_id
  ),
  merged as (
    select dg.sgt_date, dg.rule_id, coalesce(pr.name, 'Studio discount') as rule_name,
           dg.discount_count, dg.discount_cents, st.sales_total_cents, st.gst_cents
      from discount_grain dg
      join sale_totals st on st.sgt_date = dg.sgt_date and st.rule_id = dg.rule_id
      left join public.program_rules pr
        on pr.rule_id = dg.rule_id and pr.business_id = p_business
       and pr.config_version_id = (select active_config_version_id from public.businesses where id = p_business)
     order by dg.sgt_date, dg.rule_id
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'date', sgt_date, 'rule_id', rule_id, 'rule_name', rule_name,
      'discount_count', discount_count, 'discount_cents', discount_cents,
      'gst_cents', gst_cents, 'sales_total_cents', sales_total_cents) order by sgt_date, rule_id), '[]'::jsonb),
    'date,rule_id,rule_name,discount_count,discount_cents,gst_cents,sales_total_cents' ||
      coalesce(string_agg(E'\n' ||
        sgt_date::text || ',' || rule_id::text || ',' ||
        '"' || replace(rule_name, '"', '""') || '"' || ',' ||
        discount_count::text || ',' || discount_cents::text || ',' ||
        gst_cents::text || ',' || sales_total_cents::text, '' order by sgt_date, rule_id), '')
    into v_rows, v_csv
    from merged;

  -- Grand totals computed directly (independent of the report grain); discount_cents
  -- is the reconciliation anchor. Distinct-sale sales_total / gst here are the true
  -- unduplicated totals.
  select jsonb_build_object(
           'discount_count', coalesce((select count(*) from public.checkout_discount_lines cdl
              join public.sales s on s.id = cdl.sale_id and s.business_id = cdl.business_id
             where cdl.business_id = p_business
               and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to), 0)::int,
           'discount_cents', coalesce((select sum(cdl.amount_cents) from public.checkout_discount_lines cdl
              join public.sales s on s.id = cdl.sale_id and s.business_id = cdl.business_id
             where cdl.business_id = p_business
               and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to), 0)::int,
           'sales_total_cents', coalesce((select sum(d.sale_total) from (
              select distinct s.id, s.amount_cents as sale_total from public.checkout_discount_lines cdl
                join public.sales s on s.id = cdl.sale_id and s.business_id = cdl.business_id
               where cdl.business_id = p_business
                 and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to) d), 0)::int,
           'gst_cents', coalesce((select sum(d.gst_cents) from (
              select distinct ce.id, ce.gst_cents from public.checkout_discount_lines cdl
                join public.sales s on s.id = cdl.sale_id and s.business_id = cdl.business_id
                join public.checkout_evaluations ce on ce.id = cdl.evaluation_id and ce.business_id = cdl.business_id
               where cdl.business_id = p_business
                 and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to) d), 0)::int)
    into v_grand;

  return jsonb_build_object(
    'business_id', p_business, 'from', p_from, 'to', p_to,
    'by_day_rule', v_rows, 'grand_totals', v_grand, 'csv', v_csv);
end $$;
revoke all on function public.get_checkout_discount_report(uuid, date, date) from public, anon, authenticated;
grant execute on function public.get_checkout_discount_report(uuid, date, date) to authenticated;

commit;
