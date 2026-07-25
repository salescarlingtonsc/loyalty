-- FRENLY v68b - PS-2 LIVE INCREMENT: LIFT THE SV-SETTLEMENT REVERSAL REFUSALS + NET THE LEGS
--
-- Implements directive §6 of the RELEASE APPROVED pilot mandate, PART 2 OF 2. Pinned contract:
-- docs/design/ps2/PS2_LIVE_V68B_SV_REVERSAL_NETTING_CONTRACT.md. Frozen arithmetic oracle:
-- docs/design/ps0/STORED_VALUE_CONTRACT.md §6 ("reversal restores the exact lots" + restore-then-
-- expire, case (f)). Forward-only; v61-v68a untouched in behaviour except the FOUR functions +
-- ONE view named below. The migration moves ZERO value in production: prod authority is 'unbuilt'
-- for every business, so every reversal path built here stays structurally unreachable until v69.
--
-- THE COUPLING (contract §A). v67 made an sv-settled sale unreversible from BOTH directions - §11a
-- refused reversing the SALE (public.reverse_sale_v20_base) and §11b refused reversing the
-- SETTLEMENT SPEND (public.sv_reverse_spend) - precisely because v67's §10 accounting
-- (sale_balance.sv_tender_totals + get_revenue_summary.v_sv_cash) reads a 'consumed' tender as
-- settled + realised cash-basis revenue and NEVER nets it back out. Lifting EITHER refusal without
-- netting BOTH legs is a financial-truth defect. v68b therefore ships all three ATOMICALLY:
--   (1) coherent restitution (restore EXACTLY what the settlement spend drew, PS-0 §6), reusing the
--       v63/v64 restore-then-expire engine, extracted into app.sv_reverse_spend_core;
--   (2) an append-only settlement-reversal MARKER (public.checkout_sv_tender_reversals) that the two
--       §10 surfaces LEFT-JOIN/NOT-EXISTS to net; and
--   (3) the lifting of §11a and §11b, so the sv-settled sale and the settlement spend become
--       reversible via the SAME coherent path.
--
-- §2 DESIGN CHOICE - APPEND-ONLY EVIDENCE (the contract's PREFERRED option). v67 froze the
-- checkout_sv_tenders state machine (one-way reserved -> consumed|released; terminal rows immutable;
-- sale_id/spend_operation_id write-once) and TWO partial-unique settlement indexes
-- (... where status='consumed') that block a double settlement. v68b leaves that machine and those
-- indexes untouched: a reversed settlement's tender row STAYS 'consumed'. The reversal is recorded
-- in a NEW append-only table, one row per reversed settlement (unique on the tender AND on the spend
-- operation), FK-bound, RLS'd, immutable. The §10 surfaces net by NOT-EXISTS against it. Extending
-- the state machine with a consumed->reversed transition was rejected because it would move a
-- reversed tender OUT of the status='consumed' partial-unique indexes and thereby re-open the exact
-- double-settlement hole v67's F2 closed.
--
-- §3 NETTING (the load-bearing half). sale_balance.sv_tender_totals now EXCLUDES a settlement whose
-- tender has a reversal marker (so a reversed sv sale no longer reads 'paid'); get_revenue_summary's
-- v_sv_cash nets the settlement out of cash-basis revenue the same way. THE v67-REVIEW TRAP: v_sv_cash
-- filtered s.reversal_of on the ORIGINAL sale, which a reversal never sets - keying netting off that
-- does nothing. v68b keys BOTH legs off the marker (which actually changes). cash_collected is NOT
-- touched: the sv portion never wrote a payment, so it was never in cash_collected; a split sale's
-- cash remainder nets through the EXISTING payment-reversal path exactly once (the v20 refund loop).
--
-- §4 RESTITUTION (no arbitrage). app.sv_reverse_spend_core restores EXACTLY the recorded per-lot
-- allocation: paid cents to the paid lot, bonus cents to the bonus lot; restore-then-expire when a
-- target lot has since expired (never a silent resurrection); never above minted_cents; never below
-- zero; sv_total_outstanding returns exactly to its pre-spend value for a full reversal; over-reversal
-- still refused (v63 bound). INTERACTION WITH v68a: a chargeback voids remaining; a later reversal of
-- a spend whose SOURCE top-up was charged back must NOT resurrect the clawed-back value, so the core
-- REFUSES it (typed sv_settlement_charged_back) rather than restoring - the same fail-closed choice
-- v68a's sv_correct_lot makes for a charged-back lot. reversal-then-chargeback needs no special case:
-- the chargeback naturally voids the restored remaining and reports bad debt = spend - reversal = 0.
--
-- §5 GATES (v66/v67/v68a pattern, in app.sv_reverse_spend_core). First line authority='live' (typed
-- sv_not_live) - real reversal unreachable in prod until v69; pause 'all'/'redeem' blocks reversal
-- (a reversal is a redeem-family correction, v64); synthetic-on-live refused (v66); currency
-- validated; all gates RE-VALIDATED after the locks (TOCTOU). The existing reversal permission
-- governs and is NOT widened: public.sv_reverse_spend keeps its owner check (v63); the sale-leg
-- restitution runs inside public.reverse_sale_v20_base, which already enforces 'refund_sales'.
--
-- METHOD. app.sv_reverse_spend_core is the v64 sv_reverse_spend body MINUS the owner check (the same
-- extraction pattern v67 used for sv_reserve_core/sv_spend_core/sv_release_core), so no parallel
-- restore path exists. public.sv_reverse_spend and app.sv_reverse_settlement_for_sale delegate to it.
-- §10 (sale_balance view, get_revenue_summary function) are re-issued as FULL create-or-replace from
-- the post-v67 shape (security_invoker preserved on the view; the v21 hardened search_path preserved
-- on the function). §11a is the ONE splice: public.reverse_sale_v20_base's v67 refusal block is
-- removed and a single restitution call spliced in, via the v49a pg_get_functiondef idiom on the
-- POST-v67 prod shape, with COMMENT-FREE needles (GUARD 3). §11b is NOT spliced - lifting it is just
-- the full create-or-replace of public.sv_reverse_spend (the refusal simply is not reproduced).
--
-- SAFETY: applying v68b to a clean chain creates ZERO checkout_sv_tender_reversals rows and moves
-- ZERO value. The v66 mint tripwire holds (v68b adds no minter and inserts into no lot table). The
-- v67 F2 settlement-uniqueness indexes stay valid and still block a double settlement.

begin;

-- =====================================================================
-- 1. public.checkout_sv_tender_reversals - the append-only settlement-reversal MARKER. ONE row per
--    reversed settlement: unique on the tender AND on the spend operation (a settlement is reversed
--    at most once, structurally). FK-bound to the tender, its sale, its spend + reverse operations,
--    and the account. Owner + finance + super-admin READ; browser DML revoked; immutable (v61 guard).
--    The two §10 surfaces net by NOT-EXISTS against tender_id.
-- =====================================================================
create table public.checkout_sv_tender_reversals (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  tender_id uuid not null,
  sale_id uuid not null,
  spend_operation_id uuid not null,
  reverse_operation_id uuid not null,
  account_id uuid not null,
  restored_cents integer not null check (restored_cents >= 0),
  restored_paid_cents integer not null check (restored_paid_cents >= 0),
  restored_bonus_cents integer not null check (restored_bonus_cents >= 0),
  reversed_via text not null check (reversed_via in ('sale_reversal', 'settlement_reversal')),
  reversal_sale_id uuid,
  actor uuid,
  reason text,
  created_at timestamptz not null default now(),
  constraint checkout_sv_tender_reversals_id_business_uk unique (id, business_id),
  constraint checkout_sv_tender_reversals_tender_uk unique (tender_id),
  constraint checkout_sv_tender_reversals_spend_op_uk unique (business_id, spend_operation_id),
  constraint checkout_sv_tender_reversals_tender_fk foreign key (tender_id, business_id)
    references public.checkout_sv_tenders(id, business_id) on delete restrict,
  constraint checkout_sv_tender_reversals_sale_fk foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete restrict,
  constraint checkout_sv_tender_reversals_spend_op_fk foreign key (spend_operation_id, business_id)
    references public.sv_operations(id, business_id) on delete restrict,
  constraint checkout_sv_tender_reversals_reverse_op_fk foreign key (reverse_operation_id, business_id)
    references public.sv_operations(id, business_id) on delete restrict,
  constraint checkout_sv_tender_reversals_reversal_sale_fk foreign key (reversal_sale_id, business_id)
    references public.sales(id, business_id) on delete restrict,
  constraint checkout_sv_tender_reversals_account_fk foreign key (account_id, business_id)
    references public.sv_accounts(id, business_id) on delete restrict
);
create index checkout_sv_tender_reversals_business_idx
  on public.checkout_sv_tender_reversals (business_id, created_at);
create index checkout_sv_tender_reversals_sale_idx
  on public.checkout_sv_tender_reversals (business_id, sale_id);
create trigger checkout_sv_tender_reversals_immutable_guard
  before update or delete on public.checkout_sv_tender_reversals
  for each row execute function app.sv_immutable_guard();
alter table public.checkout_sv_tender_reversals enable row level security;
create policy checkout_sv_tender_reversals_owner_read on public.checkout_sv_tender_reversals
  for select to authenticated using (app.is_salon_owner(business_id));
create policy checkout_sv_tender_reversals_sa_read on public.checkout_sv_tender_reversals
  for select to authenticated using (app.is_super_admin());
-- view_finance staff must read the marker so the security_invoker sale_balance view (§10) nets a
-- reversed sv-tendered sale for them too (matching v67's checkout_sv_tenders finance-read policy).
create policy checkout_sv_tender_reversals_finance_read on public.checkout_sv_tender_reversals
  for select to authenticated using (app.has_perm(business_id, 'view_finance'));
revoke all on public.checkout_sv_tender_reversals from public, anon, authenticated;
grant select on public.checkout_sv_tender_reversals to authenticated;

-- =====================================================================
-- 2. app.sv_reverse_spend_core - the v64 public.sv_reverse_spend body MINUS the owner check (the
--    same extraction pattern v67 used for the reserve/spend/release cores), PLUS the v68b additions
--    the contract requires and NOTHING else: synthetic-on-live + currency gates (v66), a chargeback
--    refusal (contract §4 / v68a interaction), and TOCTOU re-validation after the locks. It performs
--    the ONLY restitution path (restore-then-expire, PS-0 §6); it writes NO marker (the caller does,
--    so both doors funnel through the same restore engine). Reusable for a PLAIN owner sv_spend
--    reversal (no tender) and for a checkout settlement reversal alike.
-- =====================================================================
create or replace function app.sv_reverse_spend_core(
  p_business uuid, p_spend_operation uuid, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_hash text;
  v_existing public.sv_operations%rowtype;
  v_op uuid := gen_random_uuid();
  v_account uuid;
  v_client uuid;
  v_spend_type text;
  v_state text;
  v_biz_synth boolean;
  v_client_synth boolean;
  v_biz_currency text;
  v_restored jsonb := '[]'::jsonb;
  v_restored_total bigint := 0;
  v_reexpired_total bigint := 0;
  m record;
  v_amt bigint;
  v_expiry timestamptz;
  v_reexpired boolean;
  v_result jsonb;
begin
  -- HARD SAFETY GATE (v63): value only moves when stored value is the authority for this business.
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;

  -- PAUSE GATE (v64 family mapping): a reversal of a spend is a redeem-side correction, so an active
  -- 'all' or 'redeem' sv_pause blocks it.
  if app.sv_pause_active(p_business, 'stored_value', 'redeem') then
    raise exception 'sv_paused: stored-value redemptions are paused' using errcode = '22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value reverse idempotency key is required' using errcode = '22023';
  end if;

  -- The spend operation must exist, be a 'spend', and belong to this business.
  select o.operation_type into v_spend_type from public.sv_operations o
   where o.id = p_spend_operation and o.business_id = p_business;
  if v_spend_type is null then
    raise exception 'stored-value spend operation not found in this business' using errcode = '22023';
  end if;
  if v_spend_type <> 'spend' then
    raise exception 'stored-value reverse target is not a spend operation' using errcode = '22023';
  end if;

  select account_id into v_account from public.sv_lot_movements
   where business_id = p_business and operation_id = p_spend_operation and kind = 'spend'
   order by id limit 1;
  if v_account is null then
    raise exception 'stored-value spend operation wrote no spend movements to reverse' using errcode = '22023';
  end if;

  -- SYNTHETIC/LIVE COHERENCE (v66): a synthetic entity may never transact on a live business.
  select a.client_id into v_client from public.sv_accounts a
   where a.id = v_account and a.business_id = p_business;
  select b.is_synthetic, b.currency into v_biz_synth, v_biz_currency
    from public.businesses b where b.id = p_business;
  select c.is_synthetic into v_client_synth from public.clients c
   where c.id = v_client and c.business_id = p_business;
  if coalesce(v_biz_synth, false) or coalesce(v_client_synth, false) then
    raise exception 'a synthetic entity cannot transact on a live business' using errcode = '22023';
  end if;
  -- CURRENCY: the business must carry a valid three-letter currency (restitution restores the exact
  -- lots, which are denominated in the business currency; there is no cross-currency conversion).
  if btrim(coalesce(v_biz_currency, '')) !~ '^[A-Za-z]{3}$' then
    raise exception 'currency_missing: this business has no valid three-letter currency configured'
      using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('v63:sv_acct:' || p_business::text || ':' || v_account::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('v63:sv_reverse:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'reverse' and o.idempotency_key = p_idempotency_key
   for update;
  v_hash := app.ps1b_sha256(jsonb_build_object(
    'op', 'reverse', 'business_id', p_business, 'spend_operation_id', p_spend_operation)::text);
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different stored-value reverse' using errcode = '22023';
    end if;
    return v_existing.result;   -- same key -> idempotent replay
  end if;

  -- BOUND: a spend op is reversed at most once. Any prior reverse of THIS spend op (under a
  -- different key) is over-reversal -> fail.
  if exists (
    select 1 from public.sv_operations o
     where o.business_id = p_business and o.operation_type = 'reverse'
       and o.result->>'spend_operation_id' = p_spend_operation::text) then
    raise exception 'stored-value spend operation is already reversed (over-reversal refused)' using errcode = '22023';
  end if;

  -- CHARGEBACK INTERACTION (contract §4): if ANY source lot of this spend belongs to a charged-back
  -- top-up, the funding was clawed back by the bank; restoring it would resurrect voided value.
  -- Fail CLOSED (the same choice v68a's sv_correct_lot makes for a charged-back lot).
  if exists (
    select 1
      from public.sv_lot_movements mv
      join public.sv_lots l on l.id = mv.lot_id and l.business_id = mv.business_id
      join public.sv_chargebacks c on c.business_id = l.business_id and c.topup_operation_id = l.operation_id
     where mv.business_id = p_business and mv.operation_id = p_spend_operation and mv.kind = 'spend') then
    raise exception 'sv_settlement_charged_back: a source top-up of this spend has been charged back; reversing would resurrect clawed-back value'
      using errcode = '22023';
  end if;

  -- TOCTOU RE-VALIDATION (v66/v67/v68a): re-read authority + pause under the locks so a concurrent
  -- transition or pause committed since the early checks cannot slip a restitution through.
  select coalesce(state, 'unbuilt') into v_state from public.sv_authority
   where business_id = p_business and asset = 'stored_value';
  if coalesce(v_state, 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;
  if app.sv_pause_active(p_business, 'stored_value', 'redeem') then
    raise exception 'sv_paused: stored-value redemptions are paused' using errcode = '22023';
  end if;

  -- Compute the restore-then-expire plan FIRST (sv_operations is append-only/immutable, so the op
  -- row must be inserted ONCE with its final result before the movements it anchors).
  for m in
    select mv.lot_id, mv.cents
      from public.sv_lot_movements mv
     where mv.business_id = p_business and mv.operation_id = p_spend_operation and mv.kind = 'spend'
     order by mv.id
  loop
    v_amt := -m.cents;   -- positive restore amount
    if v_amt <= 0 then continue; end if;
    v_restored_total := v_restored_total + v_amt;
    select expiry_key into v_expiry from public.sv_lots where id = m.lot_id and business_id = p_business;
    v_reexpired := (v_expiry is not null and v_expiry <= now());
    if v_reexpired then
      v_reexpired_total := v_reexpired_total + v_amt;
    end if;
    v_restored := v_restored || jsonb_build_array(jsonb_build_object(
      'lot_id', m.lot_id, 'restored_cents', v_amt::int, 're_expired', v_reexpired));
  end loop;

  v_result := jsonb_build_object(
    'status', 'ok', 'operation_id', v_op, 'spend_operation_id', p_spend_operation, 'account_id', v_account,
    'restored_cents', v_restored_total::int, 're_expired_cents', v_reexpired_total::int,
    'net_restored_cents', (v_restored_total - v_reexpired_total)::int, 'restored', v_restored);

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'reverse', p_idempotency_key, v_hash, v_actor, v_result);

  -- Apply: a 'reversal' (+) per lot, immediately followed by a '-expiry' when the restored lot is now
  -- past its expiry_key (restore-then-expire; an expired lot is never silently resurrected).
  for m in
    select mv.lot_id, mv.cents
      from public.sv_lot_movements mv
     where mv.business_id = p_business and mv.operation_id = p_spend_operation and mv.kind = 'spend'
     order by mv.id
  loop
    v_amt := -m.cents;
    if v_amt <= 0 then continue; end if;
    insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
    values (p_business, v_account, m.lot_id, v_op, 'reversal', v_amt::int);
    select expiry_key into v_expiry from public.sv_lots where id = m.lot_id and business_id = p_business;
    if v_expiry is not null and v_expiry <= now() then
      insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
      values (p_business, v_account, m.lot_id, v_op, 'expiry', (-v_amt)::int);
    end if;
  end loop;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_REVERSE_SPEND', 'sv_accounts', v_account, jsonb_build_object(
    'operation_id', v_op, 'spend_operation_id', p_spend_operation,
    'restored_cents', v_restored_total::int, 're_expired_cents', v_reexpired_total::int));

  return v_result;
end $$;
revoke all on function app.sv_reverse_spend_core(uuid, uuid, uuid) from public, anon, authenticated;

-- =====================================================================
-- 3. app.sv_record_settlement_reversal - the append-only MARKER writer. Both doors call it AFTER the
--    restore engine, so the marker recording lives in exactly one place. Finds the CONSUMED tender
--    bound to the reversed spend operation; if there is none this was a plain (non-checkout) spend
--    reversal and no marker is written (returns false). Otherwise it records one immutable marker row
--    (ON CONFLICT on the tender -> no-op on replay), keyed off the recorded per-lot allocation the
--    settlement drew, and returns true. This is what the §10 surfaces net against.
-- =====================================================================
create or replace function app.sv_record_settlement_reversal(
  p_business uuid, p_spend_operation uuid, p_reverse_result jsonb,
  p_reversed_via text, p_reversal_sale_id uuid, p_reason text)
returns boolean language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_tender public.checkout_sv_tenders%rowtype;
  v_marker uuid;
begin
  select * into v_tender from public.checkout_sv_tenders
   where business_id = p_business and spend_operation_id = p_spend_operation and status = 'consumed';
  if not found then
    return false;   -- a plain spend reversal (no checkout settlement) writes no marker
  end if;

  insert into public.checkout_sv_tender_reversals(
    business_id, tender_id, sale_id, spend_operation_id, reverse_operation_id, account_id,
    restored_cents, restored_paid_cents, restored_bonus_cents, reversed_via, reversal_sale_id, actor, reason)
  values (
    p_business, v_tender.id, v_tender.sale_id, p_spend_operation,
    (p_reverse_result->>'operation_id')::uuid, v_tender.account_id,
    coalesce((p_reverse_result->>'net_restored_cents')::int, 0),
    coalesce(v_tender.sv_paid_cents, 0), coalesce(v_tender.sv_bonus_cents, 0),
    p_reversed_via, p_reversal_sale_id, v_actor, p_reason)
  on conflict on constraint checkout_sv_tender_reversals_tender_uk do nothing
  returning id into v_marker;

  if v_marker is not null then
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'SV_SETTLEMENT_REVERSED', 'checkout_sv_tenders', v_tender.id,
      jsonb_build_object('tender_id', v_tender.id, 'sale_id', v_tender.sale_id,
        'spend_operation_id', p_spend_operation, 'reverse_operation_id', (p_reverse_result->>'operation_id')::uuid,
        'reversed_via', p_reversed_via, 'restored_paid_cents', coalesce(v_tender.sv_paid_cents, 0),
        'restored_bonus_cents', coalesce(v_tender.sv_bonus_cents, 0)));
  end if;
  return true;
end $$;
revoke all on function app.sv_record_settlement_reversal(uuid, uuid, jsonb, text, uuid, text) from public, anon, authenticated;

-- =====================================================================
-- 4. app.sv_reverse_settlement_for_sale - the SALE-leg (§11a) restitution entry. Called from inside
--    public.reverse_sale_v20_base (the single money core) for any sale that carries a consumed sv
--    tender. In production no such tender can exist (stored value is unreachable until v69), so this
--    is a no-op there and every ordinary reversal stays byte-behaviour-identical. When a settlement
--    exists it reuses app.sv_reverse_spend_core to restore the lots and records the marker. If the
--    settlement was ALREADY reversed via the settlement door (Door B), the value is already restored
--    and §10 already nets it, so it skips (never a double restitution). Serialized on the account so
--    a racing settlement reversal is one-winner.
-- =====================================================================
create or replace function app.sv_reverse_settlement_for_sale(
  p_business uuid, p_sale uuid, p_reversal_sale_id uuid, p_reason text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_tender public.checkout_sv_tenders%rowtype;
  v_res jsonb;
  v_key uuid;
begin
  select * into v_tender from public.checkout_sv_tenders
   where business_id = p_business and sale_id = p_sale and status = 'consumed';
  if not found then
    return null;   -- non-sv sale: nothing to restore (the ONLY reachable path in production)
  end if;

  -- Serialize on the account (re-entrant with the core's own lock) so a concurrent Door-B settlement
  -- reversal of the same spend is one-winner: marker-check + restore + marker-write is atomic here.
  perform pg_advisory_xact_lock(hashtextextended('v63:sv_acct:' || p_business::text || ':' || v_tender.account_id::text, 0));

  if exists (select 1 from public.checkout_sv_tender_reversals rv
              where rv.business_id = p_business and rv.tender_id = v_tender.id) then
    -- already reversed via the settlement door: SV restored + §10 nets it; do not double-restore.
    return jsonb_build_object('status', 'already_reversed', 'tender_id', v_tender.id,
      'spend_operation_id', v_tender.spend_operation_id);
  end if;

  v_key := md5('v68b:sale_settlement_reversal:' || v_tender.id::text)::uuid;
  v_res := app.sv_reverse_spend_core(p_business, v_tender.spend_operation_id, v_key);
  perform app.sv_record_settlement_reversal(
    p_business, v_tender.spend_operation_id, v_res, 'sale_reversal', p_reversal_sale_id, p_reason);
  return v_res;
end $$;
revoke all on function app.sv_reverse_settlement_for_sale(uuid, uuid, uuid, text) from public, anon, authenticated;

-- =====================================================================
-- 5. public.sv_reverse_spend - the SETTLEMENT-leg (§11b) door. LIFTS v67's §11b refusal by simply
--    NOT reproducing it: owner check (unchanged, v63), delegate to the shared restore engine, then
--    record the settlement-reversal marker when the reversed spend was a checkout settlement (a plain
--    owner sv_spend reversal writes no marker and stays exactly as reversible as v63 made it). The
--    v49a splice idiom is DELIBERATELY not used here - a full create-or-replace lifts the refusal
--    with no needle to validate against prod.
-- =====================================================================
create or replace function public.sv_reverse_spend(
  p_business uuid, p_spend_operation uuid, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_res jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  v_res := app.sv_reverse_spend_core(p_business, p_spend_operation, p_idempotency_key);
  perform app.sv_record_settlement_reversal(
    p_business, p_spend_operation, v_res, 'settlement_reversal', null, null);
  return v_res;
end $$;
revoke all on function public.sv_reverse_spend(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.sv_reverse_spend(uuid, uuid, uuid) to authenticated;

-- =====================================================================
-- 6. §10 NETTING LEG 1 - public.sale_balance. CREATE OR REPLACE from the v67 shape (security_invoker
--    preserved, v66a class regression guard). The ONLY change vs v67: sv_tender_totals now EXCLUDES a
--    settlement whose tender carries a reversal marker, so a reversed sv-tendered sale no longer reads
--    as 'paid' - its balance re-opens (A/R for a settlement reversal; nets with the reversal row to
--    zero for a full sale reversal).
-- =====================================================================
create or replace view public.sale_balance
with (security_invoker = on) as
with reversal_totals as (
  select r.business_id,
         r.reversal_of as sale_id,
         coalesce(sum(r.amount_cents), 0)::integer as reversal_cents
    from public.sales r
   where r.reversal_of is not null
   group by r.business_id, r.reversal_of
),
payment_totals as (
  select s.business_id,
         s.id as sale_id,
         coalesce(sum(p.amount_cents), 0)::integer as paid_cents
    from public.sales s
    left join public.payments p
      on p.business_id = s.business_id
     and (
       p.sale_id = s.id
       or (
         p.sale_id is null
         and s.appointment_id is not null
         and p.appointment_id = s.appointment_id
       )
     )
   where s.reversal_of is null
   group by s.business_id, s.id
),
sv_tender_totals as (
  -- v67 settlement marker: a consumed stored-value tender settles its sale with NO payments row.
  -- v68b: a settlement whose tender carries a reversal marker is netted OUT (the sv value was
  -- restored to the customer's lots, so the sale no longer stands settled by it).
  select t.business_id,
         t.sale_id,
         coalesce(sum(t.reserved_cents), 0)::integer as sv_settled_cents
    from public.checkout_sv_tenders t
   where t.status = 'consumed'
     and t.sale_id is not null
     and not exists (
       select 1 from public.checkout_sv_tender_reversals rv
        where rv.business_id = t.business_id and rv.tender_id = t.id)
   group by t.business_id, t.sale_id
)
select s.id as sale_id,
       s.business_id,
       s.branch_id,
       s.client_id,
       s.appointment_id,
       s.kind,
       s.counts_as_revenue,
       (s.amount_cents + coalesce(rt.reversal_cents, 0))::integer as amount_cents,
       s.occurred_at,
       coalesce(pt.paid_cents, 0)::integer as paid_cents,
       ((s.amount_cents + coalesce(rt.reversal_cents, 0)) - coalesce(pt.paid_cents, 0) - coalesce(st.sv_settled_cents, 0))::integer as balance_cents,
       case
         when (s.amount_cents + coalesce(rt.reversal_cents, 0)) = 0
              and coalesce(pt.paid_cents, 0) + coalesce(st.sv_settled_cents, 0) = 0 then 'paid'
         when coalesce(pt.paid_cents, 0) + coalesce(st.sv_settled_cents, 0) <= 0 then 'unpaid'
         when coalesce(pt.paid_cents, 0) + coalesce(st.sv_settled_cents, 0) < (s.amount_cents + coalesce(rt.reversal_cents, 0)) then 'partial'
         when coalesce(pt.paid_cents, 0) + coalesce(st.sv_settled_cents, 0) = (s.amount_cents + coalesce(rt.reversal_cents, 0)) then 'paid'
         else 'overpaid'
       end as payment_status,
       s.amount_cents as gross_amount_cents,
       coalesce(-rt.reversal_cents, 0)::integer as reversed_cents,
       coalesce(st.sv_settled_cents, 0)::integer as sv_settled_cents
  from public.sales s
  left join reversal_totals rt
    on rt.business_id = s.business_id
   and rt.sale_id = s.id
  left join payment_totals pt
    on pt.business_id = s.business_id
   and pt.sale_id = s.id
  left join sv_tender_totals st
    on st.business_id = s.business_id
   and st.sale_id = s.id
 where s.reversal_of is null
   and app.has_perm(s.business_id, 'view_finance');

revoke all on public.sale_balance from anon;
grant select on public.sale_balance to authenticated;

-- =====================================================================
-- 7. §10 NETTING LEG 2 - public.get_revenue_summary. CREATE OR REPLACE from the v67 shape (the v21
--    hardened search_path preserved, v67 D2 class). The ONLY change vs v67: v_sv_cash nets OUT a
--    settlement whose tender carries a reversal marker. The v67 review's TRAP - keying off
--    s.reversal_of on the ORIGINAL sale (which a reversal never sets) - is avoided: the netting is
--    keyed off the marker, which actually changes on a reversal. cash_collected (v_collected) is
--    untouched, so the sv portion (which never wrote a payment) is unaffected; a split sale's cash
--    remainder is refunded through the existing payment-reversal path and nets in v_cash exactly once.
-- =====================================================================
create or replace function public.get_revenue_summary(
  p_business uuid,
  p_from date,
  p_to date,
  p_branch uuid default null::uuid)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_accrual bigint;
  v_cash bigint;
  v_sv_cash bigint;
  v_expenses bigint;
  v_unpaid bigint;
  v_collected bigint;
  v_from_ts timestamptz;
  v_to_ts timestamptz;
begin
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'p_from and p_to are required and p_from must be on or before p_to';
  end if;

  if not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to view finance for this business (view_finance)'
      using errcode = '42501';
  end if;

  if p_branch is not null and not exists (
    select 1
      from public.branches b
     where b.id = p_branch
       and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to this business';
  end if;

  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'you are not permitted to view this branch scope for this business (branch_visibility)'
      using errcode = '42501';
  end if;

  v_from_ts := p_from::timestamp at time zone 'Asia/Singapore';
  v_to_ts := (p_to + 1)::timestamp at time zone 'Asia/Singapore';

  select coalesce(sum(s.amount_cents), 0)
    into v_accrual
    from public.sales s
   where s.business_id = p_business
     and s.counts_as_revenue
     and s.occurred_at >= v_from_ts
     and s.occurred_at < v_to_ts
     and (p_branch is null or s.branch_id = p_branch);

  select coalesce(sum(p.amount_cents), 0)
    into v_cash
    from public.payments p
    join public.sales s
      on s.business_id = p.business_id
     and s.reversal_of is null
     and (
       s.id = p.sale_id
       or (
         p.sale_id is null
         and p.appointment_id is not null
         and s.appointment_id = p.appointment_id
       )
     )
   where p.business_id = p_business
     and s.counts_as_revenue
     and p.occurred_at >= v_from_ts
     and p.occurred_at < v_to_ts
     and (p_branch is null or p.branch_id = p_branch);

  -- v67: a consumed stored-value tender settles its sale (no payments row); recognise it as
  -- cash-basis revenue at the SALE occurred_at. v68b: a settlement whose tender carries a reversal
  -- marker is netted OUT here, so revenue_cash drops by exactly the reversed settlement. Keyed off
  -- the MARKER (which changes on a reversal), never off s.reversal_of on the original sale (which a
  -- reversal never sets). cash_collected (v_collected) is deliberately NOT touched.
  select coalesce(sum(t.reserved_cents), 0)
    into v_sv_cash
    from public.checkout_sv_tenders t
    join public.sales s
      on s.business_id = t.business_id
     and s.id = t.sale_id
     and s.reversal_of is null
   where t.business_id = p_business
     and t.status = 'consumed'
     and not exists (
       select 1 from public.checkout_sv_tender_reversals rv
        where rv.business_id = t.business_id and rv.tender_id = t.id)
     and s.counts_as_revenue
     and s.occurred_at >= v_from_ts
     and s.occurred_at < v_to_ts
     and (p_branch is null or s.branch_id = p_branch);
  v_cash := v_cash + v_sv_cash;

  select coalesce(sum(p.amount_cents), 0)
    into v_collected
    from public.payments p
   where p.business_id = p_business
     and p.method not in ('credit', 'gift_card')
     and p.occurred_at >= v_from_ts
     and p.occurred_at < v_to_ts
     and (p_branch is null or p.branch_id = p_branch);

  select coalesce(sum(b.balance_cents), 0)
    into v_unpaid
    from public.sale_balance b
   where b.business_id = p_business
     and b.counts_as_revenue
     and b.balance_cents > 0
     and b.occurred_at >= v_from_ts
     and b.occurred_at < v_to_ts
     and (p_branch is null or b.branch_id = p_branch);

  select coalesce(sum(round(e.amount_cents::numeric * e.fx_rate_to_base::numeric)), 0)::bigint
    into v_expenses
    from public.expenses e
   where e.business_id = p_business
     and e.voided_at is null
     and e.occurred_on between p_from and p_to
     and (p_branch is null or e.branch_id = p_branch);

  return json_build_object(
    'from', p_from,
    'to', p_to,
    'branch_id', p_branch,
    'revenue_accrual_cents', v_accrual,
    'revenue_cash_cents', v_cash,
    'cash_collected_cents', v_collected,
    'unpaid_balance_cents', v_unpaid,
    'expenses_cents', v_expenses,
    'net_accrual_cents', v_accrual - v_expenses,
    'net_cash_cents', v_cash - v_expenses
  );
end $$;
revoke all on function public.get_revenue_summary(uuid, date, date, uuid) from public, anon, authenticated;
grant execute on function public.get_revenue_summary(uuid, date, date, uuid) to authenticated;

-- =====================================================================
-- 8. §11a LIFT + RESTITUTION - public.reverse_sale_v20_base. The v49a pg_get_functiondef splice
--    idiom on the POST-v67 prod shape (GUARD 3: comment-free needles), doing TWO edits to the exact
--    applied catalog definition and preserving every unrelated byte BY CONSTRUCTION:
--      EDIT 1 (a plain replace assignment): REMOVE the v67 §11a refusal block. Its needle is v67's
--        own comment-free replacement text (present verbatim in prod's catalog since v67 applied),
--        kept and replaced down to the surviving 'if o.kind not in (...)' anchor. A miss fails closed.
--      EDIT 2 (the execute replace, GUARD-3-validated): SPLICE a single restitution call in right
--        after the reversal sale row is created (comment-free anchor: the two set_config('',...) resets
--        that follow the reversal INSERT). The call is a no-op for any sale without a consumed sv
--        tender, so ordinary reversals are byte-behaviour-identical, and in production - where no such
--        tender can exist until v69 - it never fires.
--    The needle text is REPORTED in the builder integration note so the orchestrator can validate it
--    against prod's live catalog before freeze (rehearsal is not byte-faithful to prod).
-- =====================================================================
do $v68b_reverse_sale_lift$
declare
  v_identity constant text := 'public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)';
  v_definition text;
  v_lifted text;
  v_refusal text;
  v_anchor text;
  v_replacement text;
  v_config text[];
  v_occurrences integer;
begin
  select pg_get_functiondef(v_identity::regprocedure) into strict v_definition;

  if position('sv_tendered_sale_unsupported' in v_definition) = 0 then
    raise exception 'reverse_sale_v20_base is missing the v67 §11a refusal this migration must lift';
  end if;
  if position('sv_reverse_settlement_for_sale' in v_definition) > 0 then
    raise exception 'reverse_sale_v20_base already carries the v68b restitution call';
  end if;

  -- EDIT 1: the v67 §11a refusal block (v67's exact comment-free replacement text) down through the
  -- surviving kind-check anchor -> replaced by the kind-check alone, deleting the refusal.
  v_refusal :=
    '  if exists (' || E'\n' ||
    '    select 1' || E'\n' ||
    '      from public.checkout_sv_tenders t' || E'\n' ||
    '     where t.business_id = o.business_id' || E'\n' ||
    '       and t.sale_id = o.id' || E'\n' ||
    '       and t.status = ''consumed''' || E'\n' ||
    '  ) then' || E'\n' ||
    '    raise exception ''sv_tendered_sale_unsupported: sale % was settled with stored value;' ||
    ' stored-value restitution has no proven correction path, so this reversal is refused'',' || E'\n' ||
    '      o.id;' || E'\n' ||
    '  end if;' || E'\n' ||
    '  if o.kind not in (''service'', ''retail'', ''quick_sale'') then';
  v_occurrences := (length(v_definition) - length(replace(v_definition, v_refusal, '')))
                   / length(v_refusal);
  if v_occurrences <> 1 then
    raise exception 'unexpected reverse_sale_v20_base §11a refusal shape (needle occurrences: %)', v_occurrences;
  end if;
  v_lifted := replace(v_definition, v_refusal,
    '  if o.kind not in (''service'', ''retail'', ''quick_sale'') then');

  -- EDIT 2: splice the restitution call right after the reversal sale row is created. Anchor = the
  -- two GUC resets that immediately follow the reversal INSERT (comment-free pure code, single
  -- occurrence: the value-setting variant a few lines above uses v_reversal_id::text / o.id::text).
  v_anchor :=
    '  perform set_config(''app.sale_reversal_insert_id'', '''', true);' || E'\n' ||
    '  perform set_config(''app.sale_reversal_original_id'', '''', true);';
  v_occurrences := (length(v_lifted) - length(replace(v_lifted, v_anchor, ''))) / length(v_anchor);
  if v_occurrences <> 1 then
    raise exception 'unexpected reverse_sale_v20_base restitution anchor (needle occurrences: %)', v_occurrences;
  end if;
  v_replacement := v_anchor || E'\n' || E'\n' ||
    '  perform app.sv_reverse_settlement_for_sale(o.business_id, o.id, v_reversal.id, btrim(p_reason));';

  execute replace(v_lifted, v_anchor, v_replacement);

  -- Post-conditions: the v21 hardening + closed ACL must survive, the refusal must be gone, and the
  -- restitution call must be installed.
  select p.proconfig into v_config from pg_proc p where p.oid = v_identity::regprocedure;
  if v_config is distinct from array['search_path=pg_catalog, public, app, pg_temp'] then
    raise exception 'reverse_sale_v20_base lost its v21 hardened search_path: %', v_config;
  end if;
  if has_function_privilege('authenticated', v_identity, 'execute')
     or has_function_privilege('anon', v_identity, 'execute') then
    raise exception 'reverse_sale_v20_base must stay closed to the browser roles';
  end if;
  if position('sv_tendered_sale_unsupported' in pg_get_functiondef(v_identity::regprocedure)) > 0 then
    raise exception 'reverse_sale_v20_base still carries the lifted §11a refusal';
  end if;
  if position('sv_reverse_settlement_for_sale' in pg_get_functiondef(v_identity::regprocedure)) = 0 then
    raise exception 'reverse_sale_v20_base restitution call was not installed';
  end if;
end
$v68b_reverse_sale_lift$;

-- =====================================================================
-- 9. POST-CONDITIONS. v68b must have LIFTED both refusals, kept the v66 mint tripwire green, kept the
--    v67 F2 settlement-uniqueness indexes valid, and not opened the new marker table to anon.
-- =====================================================================
do $v68b_postconditions$
declare v_bad text;
begin
  -- both v67 refusals are GONE (lifted together, per the coupling)
  if position('sv_tendered_sale_unsupported' in
      pg_get_functiondef('public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)'::regprocedure)) > 0 then
    raise exception 'v68b: the §11a sale-leg refusal was not lifted';
  end if;
  if position('sv_tendered_spend_unsupported' in
      pg_get_functiondef('public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure)) > 0 then
    raise exception 'v68b: the §11b settlement-leg refusal was not lifted';
  end if;
  -- the restore engine and both doors funnel through app.sv_reverse_spend_core
  if position('sv_reverse_spend_core' in
      pg_get_functiondef('public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure)) = 0 then
    raise exception 'v68b: public.sv_reverse_spend does not delegate to the shared restore core';
  end if;
  -- v66 mint tripwire: still exactly one paid-lot minter
  select string_agg(n.nspname || '.' || p.proname, ', ' order by n.nspname || '.' || p.proname) into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app')
     and p.prosrc ilike '%insert into public.sv_lots%' and p.prosrc ilike '%''paid''%'
     and p.proname <> 'record_sv_topup_sale';
  if v_bad is not null then
    raise exception 'v68b: a non-authoritative function can mint a paid lot: %', v_bad;
  end if;
  -- v67 F2 settlement-uniqueness indexes still exist, unique and partial
  if (select count(*) from pg_index i join pg_class c on c.oid = i.indexrelid
       where c.relname in ('checkout_sv_tenders_settled_spend_uk', 'checkout_sv_tenders_settled_sale_uk')
         and i.indisunique and i.indpred is not null) <> 2 then
    raise exception 'v68b: the v67 F2 settlement-uniqueness indexes are missing or no longer partial-unique';
  end if;
  -- the marker table: RLS on, browser DML revoked, closed to anon
  if not (select relrowsecurity from pg_class where oid = 'public.checkout_sv_tender_reversals'::regclass) then
    raise exception 'v68b: checkout_sv_tender_reversals RLS is off';
  end if;
  if has_table_privilege('authenticated', 'public.checkout_sv_tender_reversals', 'insert')
     or has_table_privilege('anon', 'public.checkout_sv_tender_reversals', 'select') then
    raise exception 'v68b: checkout_sv_tender_reversals is writable by the browser or readable by anon';
  end if;
  -- the new app cores stay closed to the browser roles
  if has_function_privilege('authenticated', 'app.sv_reverse_spend_core(uuid,uuid,uuid)', 'execute')
     or has_function_privilege('authenticated', 'app.sv_reverse_settlement_for_sale(uuid,uuid,uuid,text)', 'execute')
     or has_function_privilege('authenticated', 'app.sv_record_settlement_reversal(uuid,uuid,jsonb,text,uuid,text)', 'execute') then
    raise exception 'v68b: an internal app.* reversal core is executable by the browser role';
  end if;
  -- public.sv_reverse_spend keeps its owner-RPC grant, closed to anon
  if not has_function_privilege('authenticated', 'public.sv_reverse_spend(uuid,uuid,uuid)', 'execute')
     or has_function_privilege('anon', 'public.sv_reverse_spend(uuid,uuid,uuid)', 'execute') then
    raise exception 'v68b: public.sv_reverse_spend lost its owner-RPC grant or leaked to anon';
  end if;
end
$v68b_postconditions$;

commit;
