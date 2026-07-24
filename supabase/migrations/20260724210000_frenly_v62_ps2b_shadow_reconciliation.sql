-- FRENLY v62 - PROGRAM STUDIO PS-2A INCREMENT B: SHADOW OPERATIONS & RECONCILIATION
--
-- Local review candidate. Production apply needs the owner's RELEASE APPROVED phrase
-- (CLAUDE.md standing gate). Builds on Increment A (v61, reviewed PASS): the sv_accounts /
-- sv_plans / sv_plan_versions / immutable sv_lots / append-only sv_lot_movements authority /
-- sv_operations idempotency envelope / derived-balance functions / the dedicated sv_authority
-- table shipped at 'unbuilt' for every tenant, plus its guard rejecting any transition into
-- 'live'/'ready_for_cutover'. This migration EXTENDS get_sv_account and ADDS the shadow +
-- reconciliation layer; it changes NO existing v61 table and NO existing guard.
--
-- This migration IMPLEMENTS docs/design/ps2/PS2A_INCREMENT_B_CONTRACT.md under the parent
-- docs/design/ps2/PS2A_STORED_VALUE_CONTRACT.md (authority states §2, reconciliation §7) and
-- the frozen docs/design/ps0/STORED_VALUE_CONTRACT.md (PS-0 wins any conflict). Nothing here
-- makes stored value spendable: 'live'/'ready_for_cutover' remain unreachable, no customer
-- value moves, no real communications, and there is NO UI (Increment D).
--
-- WHAT INCREMENT B ADDS (and its hard safety gates):
--   1. public.set_sv_authority_state - owner-only, audited transitions across the SAFE SUBSET
--      ONLY. A hard CHECK forbids naming 'live'/'ready_for_cutover' (22023), so 'live' is now
--      unreachable FOUR ways: no live-setter exists, this RPC's CHECK, the v61 sv_authority
--      guard, and the ps0-no-executor tripwire. A business in 'reconciliation_blocked' may only
--      step back to 'shadow_testing' (never to 'unbuilt', never forward) until it clears.
--   2. public.sv_shadow_evaluations - an append-only log of a PROPOSED (would-be) stored-value
--      operation, computed without asserting authority. Writing a shadow evaluation writes ZERO
--      rows to sv_lot_movements or any value table.
--   3. public.sv_reconciliation_snapshots + public.sv_reconciliation_discrepancies +
--      public.run_sv_reconciliation - reconciliation against the designated READ-ONLY legacy
--      analog (gift_cards, per Increment-A ground truth G2). run_sv_reconciliation NEVER
--      INSERT/UPDATE/DELETEs a gift_cards row (read-only), NEVER auto-corrects, and writes no
--      value. Tolerance is 0. Any open discrepancy forces 'reconciliation_blocked'.
--   4. public.get_sv_reconciliation - owner/super-admin read of the latest snapshot + its
--      discrepancies + the current authority state. Discrepancies are shown, never hidden.
--   5. get_sv_account (CREATE OR REPLACE, minimal diff) - adds shadow_testing + disclaimer so
--      the UI (D) can distinguish shadow from spendable. spendable's meaning is unchanged.
--
-- DISCREPANCY CATEGORY MAPPING (documented precisely; tolerance 0, nothing auto-fixed):
--   * invalid_legacy_balance - gift_cards.balance_cents IS NULL or < 0 (structurally malformed).
--     Current gift_cards constraints (NOT NULL, CHECK >= 0) make this uninsertable through
--     normal paths; the classification is DEFENSIVE against direct-SQL / future schema drift.
--   * duplicate_legacy_event  - the same 'code' appears more than once within the business.
--     Also defensive today (code carries a global UNIQUE), classified never repaired.
--   * orphan_legacy_record    - a TERMINAL legacy card (status 'void'/'redeemed') that still
--     carries a positive balance: an internally inconsistent, non-migratable legacy row.
--   * missing_in_studio       - an ACTIVE legacy card with a valid positive balance the studio
--     ledger does not represent (studio projection 0). The expected fresh-tenant finding: legacy
--     holds outstanding value the studio has not adopted (gift-card migration is OUT of PS-2A).
--   * amount_mismatch         - a card whose studio projection is non-zero but differs from the
--     legacy balance. Defensive in PS-2A: no migration linkage exists, so studio is always 0.
--   * missing_in_legacy       - a studio record claiming a legacy gift-card origin (a prior
--     shadow evaluation's legacy_ref) whose gift card has since vanished. Empty on a fresh
--     tenant; handled for the future migration phase.
-- The studio projection attributable to a legacy gift card is 0 by construction in PS-2A: there
-- is NO migration linkage between gift_cards and sv value (that would move real value and is out
-- of scope), so every outstanding legacy card reconciles as missing_in_studio.

begin;

-- =====================================================================
-- 1. sv_shadow_evaluations - append-only log of a PROPOSED stored-value operation, computed
--    WITHOUT asserting authority (contract §2). Reuses the v61 app.sv_immutable_guard so an
--    UPDATE/DELETE raises restrict_violation. Owner + super-admin read only; zero browser DML.
--    A shadow evaluation moves NO value (writes nothing to sv_lot_movements / sv_lots).
-- =====================================================================
create table public.sv_shadow_evaluations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  account_id uuid,
  asset text not null default 'stored_value' check (asset = 'stored_value'),
  operation_type text not null check (operation_type in
    ('topup', 'grant', 'spend', 'reserve', 'release', 'expire', 'reverse', 'refund', 'adjust')),
  proposed_movements jsonb not null,
  proposed_total_cents integer not null,
  legacy_ref text,
  note text,
  computed_at timestamptz not null default now(),
  constraint sv_shadow_evaluations_id_business_uk unique (id, business_id),
  -- Nullable composite tenant FK (MATCH SIMPLE: a null account_id skips the check).
  constraint sv_shadow_evaluations_account_fk foreign key (account_id, business_id)
    references public.sv_accounts(id, business_id) on delete restrict
);
create index sv_shadow_evaluations_business_idx on public.sv_shadow_evaluations (business_id, computed_at);
create index sv_shadow_evaluations_legacy_idx on public.sv_shadow_evaluations (business_id, legacy_ref);
create trigger sv_shadow_evaluations_immutable_guard
  before update or delete on public.sv_shadow_evaluations
  for each row execute function app.sv_immutable_guard();
alter table public.sv_shadow_evaluations enable row level security;
create policy sv_shadow_evaluations_owner_read on public.sv_shadow_evaluations for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_shadow_evaluations_sa_read on public.sv_shadow_evaluations for select to authenticated using (app.is_super_admin());
revoke all on public.sv_shadow_evaluations from public, anon, authenticated;
grant select on public.sv_shadow_evaluations to authenticated;

-- =====================================================================
-- 2. sv_reconciliation_snapshots - one row per (business, run_id): the totals + status of a
--    reconciliation run against the legacy analog (contract §3/§7). Append-only.
-- =====================================================================
create table public.sv_reconciliation_snapshots (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  run_id uuid not null,
  asset text not null default 'stored_value' check (asset = 'stored_value'),
  source text not null default 'gift_cards' check (source = 'gift_cards'),
  actor uuid,
  legacy_total_cents bigint not null,
  studio_total_cents bigint not null,
  discrepancy_count integer not null check (discrepancy_count >= 0),
  status text not null check (status in ('clean', 'blocked')),
  captured_at timestamptz not null default now(),
  constraint sv_reconciliation_snapshots_id_business_uk unique (id, business_id),
  constraint sv_reconciliation_snapshots_run_uk unique (business_id, run_id)
);
create index sv_reconciliation_snapshots_business_idx on public.sv_reconciliation_snapshots (business_id, captured_at desc);
create trigger sv_reconciliation_snapshots_immutable_guard
  before update or delete on public.sv_reconciliation_snapshots
  for each row execute function app.sv_immutable_guard();
alter table public.sv_reconciliation_snapshots enable row level security;
create policy sv_reconciliation_snapshots_owner_read on public.sv_reconciliation_snapshots for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_reconciliation_snapshots_sa_read on public.sv_reconciliation_snapshots for select to authenticated using (app.is_super_admin());
revoke all on public.sv_reconciliation_snapshots from public, anon, authenticated;
grant select on public.sv_reconciliation_snapshots to authenticated;

-- =====================================================================
-- 3. sv_reconciliation_discrepancies - one preserved, inspectable row per discrepancy
--    (contract §3/§7). Append-only; NEVER auto-corrected. The 6-category CHECK is the frozen
--    reconciliation vocabulary. client_id is a display reference copied from
--    gift_cards.purchaser_client_id (not FK-constrained so historical evidence survives client
--    deletion); tenant scoping comes from business_id + the composite snapshot FK.
-- =====================================================================
create table public.sv_reconciliation_discrepancies (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  run_id uuid not null,
  snapshot_id uuid not null,
  category text not null check (category in
    ('missing_in_studio', 'missing_in_legacy', 'amount_mismatch', 'orphan_legacy_record',
     'duplicate_legacy_event', 'invalid_legacy_balance')),
  legacy_ref text not null,
  client_id uuid,
  legacy_cents integer,
  studio_cents integer not null default 0,
  delta_cents integer,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint sv_reconciliation_discrepancies_id_business_uk unique (id, business_id),
  constraint sv_reconciliation_discrepancies_snapshot_fk foreign key (snapshot_id, business_id)
    references public.sv_reconciliation_snapshots(id, business_id) on delete restrict
);
create index sv_reconciliation_discrepancies_run_idx on public.sv_reconciliation_discrepancies (business_id, run_id);
create index sv_reconciliation_discrepancies_snapshot_idx on public.sv_reconciliation_discrepancies (business_id, snapshot_id);
create trigger sv_reconciliation_discrepancies_immutable_guard
  before update or delete on public.sv_reconciliation_discrepancies
  for each row execute function app.sv_immutable_guard();
alter table public.sv_reconciliation_discrepancies enable row level security;
create policy sv_reconciliation_discrepancies_owner_read on public.sv_reconciliation_discrepancies for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_reconciliation_discrepancies_sa_read on public.sv_reconciliation_discrepancies for select to authenticated using (app.is_super_admin());
revoke all on public.sv_reconciliation_discrepancies from public, anon, authenticated;
grant select on public.sv_reconciliation_discrepancies to authenticated;

-- =====================================================================
-- 4. app.sv_apply_authority_state - the INTERNAL state-setter shared by the public RPC and
--    the reconciliation engine (so reconciliation avoids the owner-recursion of calling the
--    public RPC). HARD CHECK: only 'unbuilt'/'shadow_testing'/'reconciliation_blocked' are
--    settable - 'live'/'ready_for_cutover' raise 22023 here (and the v61 guard rejects them
--    regardless). Idempotent no-op on same-state. Blocked-lock: from 'reconciliation_blocked'
--    the only non-idempotent target is 'shadow_testing' (never 'unbuilt', never forward).
-- =====================================================================
create or replace function app.sv_apply_authority_state(
  p_business uuid, p_asset text, p_state text, p_reason text, p_actor uuid)
returns text language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_asset text := coalesce(p_asset, 'stored_value');
  v_reason text := btrim(coalesce(p_reason, ''));
  v_current text;
begin
  if p_state is null or p_state not in ('unbuilt', 'shadow_testing', 'reconciliation_blocked') then
    raise exception 'stored-value authority state % is not settable in PS-2A (cutover states are unreachable)', p_state
      using errcode = '22023';
  end if;
  if char_length(v_reason) < 3 then
    raise exception 'a stored-value authority transition requires a reason of at least 3 characters' using errcode = '22023';
  end if;

  select state into v_current from public.sv_authority
   where business_id = p_business and asset = v_asset
   for update;
  if v_current is null then
    raise exception 'stored-value authority is not initialised for this business' using errcode = '22023';
  end if;

  -- Idempotent no-op: same state -> no write, no audit.
  if v_current = p_state then
    return v_current;
  end if;

  -- Blocked-lock (contract §1): a business with open discrepancies cannot leave
  -- 'reconciliation_blocked' except back to 'shadow_testing' (never forward). Forward states
  -- do not exist in PS-2A, so this concretely forbids blocked -> unbuilt.
  if v_current = 'reconciliation_blocked' and p_state <> 'shadow_testing' then
    raise exception 'stored-value authority is reconciliation_blocked; it may only return to shadow_testing' using errcode = '22023';
  end if;

  update public.sv_authority
     set state = p_state, updated_at = now(), updated_by = p_actor
   where business_id = p_business and asset = v_asset;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, p_actor, 'SV_AUTHORITY_STATE_SET', 'sv_authority', p_business, jsonb_build_object(
    'asset', v_asset, 'from', v_current, 'to', p_state, 'reason', v_reason));

  return p_state;
end $$;
revoke all on function app.sv_apply_authority_state(uuid, text, text, text, uuid) from public, anon, authenticated;

-- =====================================================================
-- 5. public.set_sv_authority_state - owner-only, audited authority transition. The HARD CHECK
--    here (belt-and-braces with the internal helper) means this RPC literally CANNOT name
--    'live'/'ready_for_cutover' - they raise 22023.
-- =====================================================================
create or replace function public.set_sv_authority_state(
  p_business uuid, p_asset text, p_state text, p_reason text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_asset text := coalesce(p_asset, 'stored_value');
  v_new text;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  -- HARD CHECK: the only nameable states are the safe subset. 'live'/'ready_for_cutover' are
  -- unreachable - this RPC cannot set them, they raise 22023.
  if p_state is null or p_state not in ('unbuilt', 'shadow_testing', 'reconciliation_blocked') then
    raise exception 'stored-value authority state must be one of unbuilt/shadow_testing/reconciliation_blocked (cutover states are unreachable in PS-2A)'
      using errcode = '22023';
  end if;
  v_new := app.sv_apply_authority_state(p_business, v_asset, p_state, p_reason, v_actor);
  return jsonb_build_object('status', 'ok', 'business_id', p_business, 'asset', v_asset, 'state', v_new);
end $$;
revoke all on function public.set_sv_authority_state(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.set_sv_authority_state(uuid, text, text, text) to authenticated;

-- =====================================================================
-- 6. app.sv_write_shadow_evaluation - INTERNAL writer of the shadow log. Writes ONE
--    sv_shadow_evaluations row and NOTHING to any value table. Used by the reconciliation
--    projection (and any future shadow-mechanics increment); there is no browser mutate.
-- =====================================================================
create or replace function app.sv_write_shadow_evaluation(
  p_business uuid, p_account uuid, p_asset text, p_operation_type text,
  p_proposed_movements jsonb, p_proposed_total_cents integer, p_legacy_ref text, p_note text)
returns uuid language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into public.sv_shadow_evaluations(
    id, business_id, account_id, asset, operation_type,
    proposed_movements, proposed_total_cents, legacy_ref, note)
  values (v_id, p_business, p_account, coalesce(p_asset, 'stored_value'), p_operation_type,
    coalesce(p_proposed_movements, '[]'::jsonb), coalesce(p_proposed_total_cents, 0), p_legacy_ref, p_note);
  return v_id;
end $$;
revoke all on function app.sv_write_shadow_evaluation(uuid, uuid, text, text, jsonb, integer, text, text) from public, anon, authenticated;

-- =====================================================================
-- 7. public.run_sv_reconciliation - owner-only reconciliation against the READ-ONLY legacy
--    analog (gift_cards). Deterministic legacy_ref = 'legacy:giftcard:{id}' makes reruns
--    idempotent in CONTENT (a new snapshot each run - append-only - but the discrepancy set is
--    stable for stable inputs). tolerance = 0. NEVER writes/updates/deletes a gift_cards row;
--    NEVER moves value; NEVER auto-corrects. Any discrepancy -> snapshot 'blocked' and the
--    authority is driven to 'reconciliation_blocked' via the INTERNAL state path. All in one
--    transaction (rollback-safe).
-- =====================================================================
create or replace function public.run_sv_reconciliation(p_business uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_asset text := 'stored_value';
  v_run uuid := gen_random_uuid();
  v_snapshot uuid := gen_random_uuid();
  v_authority text;
  gc record;
  v_legacy_ref text;
  v_studio integer;
  v_legacy_total bigint := 0;
  v_studio_total bigint := 0;
  v_disc integer;
  v_status text;
  v_category text;
  v_dup boolean;
  v_discrepancies jsonb := '[]'::jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  select state into v_authority from public.sv_authority
   where business_id = p_business and asset = v_asset;
  if v_authority is null then
    raise exception 'stored-value authority is not initialised for this business' using errcode = '22023';
  end if;

  -- Direction 1: legacy (gift_cards, READ-ONLY) -> studio projection. No migration linkage
  -- exists in PS-2A, so the studio value attributable to any legacy gift card is 0.
  for gc in
    select id, code, balance_cents, status, purchaser_client_id
      from public.gift_cards
     where business_id = p_business
     order by id
  loop
    v_legacy_ref := 'legacy:giftcard:' || gc.id::text;
    v_studio := 0;
    v_legacy_total := v_legacy_total + coalesce(gc.balance_cents, 0);
    v_studio_total := v_studio_total + v_studio;

    -- Shadow evaluation: the would-be mint projection of this legacy balance into the studio
    -- ledger. Writing it moves NO value (append-only shadow log only).
    perform app.sv_write_shadow_evaluation(
      p_business, null, v_asset, 'topup',
      jsonb_build_array(jsonb_build_object('class', 'paid', 'kind', 'issue', 'cents', coalesce(gc.balance_cents, 0))),
      coalesce(gc.balance_cents, 0), v_legacy_ref, 'reconcile_projection');

    select count(*) > 1 into v_dup from public.gift_cards g
     where g.business_id = p_business and g.code = gc.code;

    v_category := null;
    if gc.balance_cents is null or gc.balance_cents < 0 then
      v_category := 'invalid_legacy_balance';
    elsif v_dup then
      v_category := 'duplicate_legacy_event';
    elsif gc.status in ('void', 'redeemed') and gc.balance_cents > 0 then
      v_category := 'orphan_legacy_record';
    elsif gc.balance_cents > 0 and v_studio = 0 then
      v_category := 'missing_in_studio';
    elsif gc.balance_cents <> v_studio then
      v_category := 'amount_mismatch';
    else
      v_category := null;   -- balance 0 (or exact match) -> clean, no discrepancy row
    end if;

    if v_category is not null then
      v_discrepancies := v_discrepancies || jsonb_build_object(
        'category', v_category,
        'legacy_ref', v_legacy_ref,
        'client_id', gc.purchaser_client_id,
        'legacy_cents', gc.balance_cents,
        'studio_cents', v_studio,
        'delta_cents', case when gc.balance_cents is null then null else gc.balance_cents - v_studio end,
        'detail', jsonb_build_object('code', gc.code, 'status', gc.status, 'source', 'gift_cards'));
    end if;
  end loop;

  -- Direction 2: a studio record claiming a legacy gift-card origin (a prior shadow
  -- evaluation's legacy_ref) whose gift card has vanished -> missing_in_legacy. Empty on a
  -- fresh tenant (every current card exists); DISTINCT so each vanished ref is one row.
  for v_legacy_ref in
    select distinct se.legacy_ref
      from public.sv_shadow_evaluations se
     where se.business_id = p_business
       and se.legacy_ref like 'legacy:giftcard:%'
       and not exists (
         select 1 from public.gift_cards g
          where g.business_id = p_business
            and 'legacy:giftcard:' || g.id::text = se.legacy_ref)
     order by se.legacy_ref
  loop
    v_discrepancies := v_discrepancies || jsonb_build_object(
      'category', 'missing_in_legacy',
      'legacy_ref', v_legacy_ref,
      'client_id', null,
      'legacy_cents', null,
      'studio_cents', 0,
      'delta_cents', null,
      'detail', jsonb_build_object('source', 'studio_shadow_origin'));
  end loop;

  v_disc := jsonb_array_length(v_discrepancies);
  v_status := case when v_disc = 0 then 'clean' else 'blocked' end;

  -- Snapshot FIRST (the discrepancy rows carry a composite FK to it).
  insert into public.sv_reconciliation_snapshots(
    id, business_id, run_id, asset, source, actor,
    legacy_total_cents, studio_total_cents, discrepancy_count, status)
  values (v_snapshot, p_business, v_run, v_asset, 'gift_cards', v_actor,
    v_legacy_total, v_studio_total, v_disc, v_status);

  insert into public.sv_reconciliation_discrepancies(
    business_id, run_id, snapshot_id, category, legacy_ref, client_id,
    legacy_cents, studio_cents, delta_cents, detail)
  select p_business, v_run, v_snapshot,
    d->>'category', d->>'legacy_ref', nullif(d->>'client_id', '')::uuid,
    (d->>'legacy_cents')::integer, (d->>'studio_cents')::integer, (d->>'delta_cents')::integer,
    coalesce(d->'detail', '{}'::jsonb)
  from jsonb_array_elements(v_discrepancies) d;

  -- Any open discrepancy blocks cutover (drives 'reconciliation_blocked' via the INTERNAL
  -- state path). NEVER auto-corrects, NEVER writes a legacy row.
  if v_disc > 0 then
    perform app.sv_apply_authority_state(
      p_business, v_asset, 'reconciliation_blocked', 'open stored-value reconciliation discrepancies', v_actor);
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_RECONCILIATION_RUN', 'sv_reconciliation_snapshots', v_snapshot, jsonb_build_object(
    'run_id', v_run, 'status', v_status, 'discrepancy_count', v_disc,
    'legacy_total_cents', v_legacy_total, 'studio_total_cents', v_studio_total));

  return jsonb_build_object(
    'status', 'ok',
    'run_id', v_run,
    'snapshot_id', v_snapshot,
    'source', 'gift_cards',
    'reconciliation_status', v_status,
    'discrepancy_count', v_disc,
    'legacy_total_cents', v_legacy_total,
    'studio_total_cents', v_studio_total,
    'authority_state', (select state from public.sv_authority where business_id = p_business and asset = v_asset));
end $$;
revoke all on function public.run_sv_reconciliation(uuid) from public, anon, authenticated;
grant execute on function public.run_sv_reconciliation(uuid) to authenticated;

-- =====================================================================
-- 8. public.get_sv_reconciliation - owner (and super-admin) read of the LATEST snapshot, its
--    discrepancies, and the current authority state. Discrepancies are surfaced, never hidden.
-- =====================================================================
create or replace function public.get_sv_reconciliation(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_asset text := 'stored_value';
  v_authority text;
  v_snapshot public.sv_reconciliation_snapshots%rowtype;
  v_discrepancies jsonb;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'not permitted to view stored-value reconciliation for this business' using errcode = '42501';
  end if;

  select coalesce(state, 'unbuilt') into v_authority from public.sv_authority
   where business_id = p_business and asset = v_asset;
  v_authority := coalesce(v_authority, 'unbuilt');   -- fail closed if no authority row

  select * into v_snapshot from public.sv_reconciliation_snapshots
   where business_id = p_business and asset = v_asset
   order by captured_at desc, id desc limit 1;

  if not found then
    return jsonb_build_object(
      'business_id', p_business,
      'asset', v_asset,
      'authority_state', v_authority,
      'has_run', false,
      'latest_snapshot', null,
      'discrepancies', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'discrepancy_id', d.id, 'category', d.category, 'legacy_ref', d.legacy_ref,
      'client_id', d.client_id, 'legacy_cents', d.legacy_cents, 'studio_cents', d.studio_cents,
      'delta_cents', d.delta_cents, 'detail', d.detail) order by d.category, d.legacy_ref), '[]'::jsonb)
    into v_discrepancies
    from public.sv_reconciliation_discrepancies d
   where d.business_id = p_business and d.run_id = v_snapshot.run_id;

  return jsonb_build_object(
    'business_id', p_business,
    'asset', v_asset,
    'authority_state', v_authority,
    'has_run', true,
    'latest_snapshot', jsonb_build_object(
      'snapshot_id', v_snapshot.id, 'run_id', v_snapshot.run_id, 'captured_at', v_snapshot.captured_at,
      'source', v_snapshot.source, 'status', v_snapshot.status,
      'legacy_total_cents', v_snapshot.legacy_total_cents, 'studio_total_cents', v_snapshot.studio_total_cents,
      'discrepancy_count', v_snapshot.discrepancy_count),
    'discrepancies', v_discrepancies);
end $$;
revoke all on function public.get_sv_reconciliation(uuid) from public, anon, authenticated;
grant execute on function public.get_sv_reconciliation(uuid) to authenticated;

-- =====================================================================
-- 9. public.get_sv_account - CREATE OR REPLACE, MINIMAL diff over v61: every existing field is
--    preserved byte-for-byte, and two truthfulness fields are ADDED so the D UI can distinguish
--    shadow from spendable - shadow_testing = (authority_state = 'shadow_testing') and a
--    disclaimer that is null ONLY when live (always non-null in PS-2A). spendable's meaning is
--    unchanged: spendable = (authority_state = 'live'), i.e. always false here.
-- =====================================================================
create or replace function public.get_sv_account(p_business uuid, p_client uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_account uuid;
  v_state text;
  v_total int; v_paid int; v_bonus int;
  v_lots jsonb; v_moves jsonb;
begin
  if not (app.is_salon_member(p_business) or app.is_super_admin()) then
    raise exception 'not permitted to view stored value for this business' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clients c where c.id = p_client and c.business_id = p_business) then
    raise exception 'stored-value client does not belong to this business' using errcode = '22023';
  end if;

  select id into v_account from public.sv_accounts
   where business_id = p_business and client_id = p_client and asset = 'stored_value';

  select coalesce(state, 'unbuilt') into v_state from public.sv_authority
   where business_id = p_business and asset = 'stored_value';
  v_state := coalesce(v_state, 'unbuilt');   -- fail closed if no authority row

  if v_account is null then
    v_total := 0; v_paid := 0; v_bonus := 0; v_lots := '[]'::jsonb; v_moves := '[]'::jsonb;
  else
    v_total := app.sv_available_balance(p_business, v_account);
    v_paid := app.sv_class_balance(p_business, v_account, 'paid');
    v_bonus := app.sv_class_balance(p_business, v_account, 'bonus');
    select coalesce(jsonb_agg(jsonb_build_object(
        'lot_id', l.id, 'class', l.class, 'minted_cents', l.minted_cents,
        'remaining_cents', app.sv_lot_remaining(l.id), 'expiry_key', l.expiry_key,
        'earned_seq', l.earned_seq, 'plan_version_id', l.plan_version_id) order by l.earned_seq), '[]'::jsonb)
      into v_lots from public.sv_lots l
     where l.business_id = p_business and l.account_id = v_account;
    select coalesce(jsonb_agg(jsonb_build_object(
        'movement_id', t.id, 'lot_id', t.lot_id, 'kind', t.kind,
        'cents', t.cents, 'created_at', t.created_at) order by t.created_at desc, t.id), '[]'::jsonb)
      into v_moves
      from (select mv.id, mv.lot_id, mv.kind, mv.cents, mv.created_at
              from public.sv_lot_movements mv
             where mv.business_id = p_business and mv.account_id = v_account
             order by mv.created_at desc, mv.id limit 50) t;
  end if;

  return jsonb_build_object(
    'business_id', p_business,
    'client_id', p_client,
    'account_id', v_account,
    'asset', 'stored_value',
    'authority_state', v_state,
    'spendable', (v_state = 'live'),
    'shadow_testing', (v_state = 'shadow_testing'),
    'disclaimer', case when v_state = 'live' then null else 'simulated — not spendable' end,
    'balances', jsonb_build_object('total_cents', v_total, 'paid_cents', v_paid, 'bonus_cents', v_bonus),
    'lots', v_lots,
    'recent_movements', v_moves);
end $$;
revoke all on function public.get_sv_account(uuid, uuid) from public, anon, authenticated;
grant execute on function public.get_sv_account(uuid, uuid) to authenticated;

commit;
