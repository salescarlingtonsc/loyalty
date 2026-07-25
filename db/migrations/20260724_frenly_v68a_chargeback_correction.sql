-- FRENLY v68a - PS-2 LIVE INCREMENT: CHARGEBACK, BAD DEBT, BUSINESS CORRECTION, REFUND CAPS
--
-- Implements directive §6 of the RELEASE APPROVED pilot mandate, PART 1 OF 2. Pinned contract:
-- docs/design/ps2/PS2_LIVE_V68A_CHARGEBACK_CORRECTION_CONTRACT.md. Frozen arithmetic oracle:
-- docs/design/ps0/STORED_VALUE_CONTRACT.md §4/§5/§6/§9/§10 (PS-0 wins ANY conflict). Forward-only;
-- v61-v67 untouched in behaviour except the ONE function named below.
--
-- v68a completes the PS-0 §6 "other operations" surface on top of the v63 engine. It builds NO new
-- allocation arithmetic, NO new mint path, NO cutover, NO live transition, NO customer self-service,
-- NO real comms. It does NOT lift the v67 §11a/§11b reversal refusals - an SV-settled sale stays
-- unreversible from BOTH directions (that coupled change is v68b, with the settlement-leg netting).
-- Real stored value stays structurally unreachable: every write path keeps the v63/v66 first-line
-- authority='live' gate, and prod authority is 'unbuilt' for every business until v69.
--
-- WHAT v68a ADDS (all reuse-first):
--   1. public.sv_chargebacks - append-only, one row per charged-back top-up operation (structural
--      single-winner). Owner+SA read; zero browser DML.
--   2. public.sv_topup_cash_refunds - append-only materialised CASH-REFUND CAP ledger. Carries the
--      running cumulative cash per top-up operation with a table CHECK bounding it by the cash
--      actually collected, plus a unique index on the running total so two concurrent refunds can
--      never both write the same cumulative. STRUCTURAL enforcement, not just a code branch.
--   3. app.sv_cash_collected_cents / app.sv_cash_refunded_cents / app.sv_operation_net_spent /
--      app.sv_operation_refund_policy - pure read helpers over the EXISTING ledger authority.
--   4. app.sv_chargeback_plan - PURE planner (no DML, no gate), mirroring app.sv_plan_refund's shape:
--      locates the operation's paid + bonus lots, derives what a chargeback would void and what the
--      bad debt is. Directly unit-testable.
--   5. public.sv_chargeback_topup(business, topup_operation, reason, idempotency_key) - owner-gated
--      chargeback (PS-0 §6, case (e)).
--   6. public.sv_correct_lot(business, lot, cents, reason, idempotency_key) - owner-gated business
--      correction (PS-0 §6), reason mandatory, both directions, fully audited.
--   7. public.refund_sv_operation - CREATE OR REPLACE over its v64 predecessor. THREE additions and
--      nothing else (see §7 below): the charged-back refusal, the plan-version refund policy
--      (unused_only / no_refund), and the cash-refund cap + its structural ledger row.
--   8. sv_operations.operation_type gains 'chargeback' and 'correction'. NO new MOVEMENT kind: the
--      PS-0 8-kind vocab stays closed and v68a introduces the FIRST WRITERS for the two kinds that
--      had none - 'correction' and 'bad_debt' (verified against the applied catalog: before v68a the
--      only functions inserting into sv_lot_movements were app.sv_spend_core ('spend'),
--      record_sv_topup_sale ('issue'), refund_sv_operation ('refund'/'clawback'), sv_expire_due
--      ('expiry') and sv_reverse_spend ('reversal'/'expiry')).
--
-- NO pg_get_functiondef SPLICE IS USED. The single replaced function (public.refund_sv_operation) is
-- re-issued as a full CREATE OR REPLACE whose body is byte-identical to its v64 predecessor except
-- for the three additions listed in §7 - the same method v64 itself used over v63. This deliberately
-- avoids the rehearsal-vs-production body-shape hazard documented in the v67 header (the Supabase MCP
-- apply condenses `--` comments out of large function bodies, so a comment-anchored needle matches
-- the rehearsal cluster and not prod). There is therefore no needle to validate against prod.
--
-- BAD-DEBT REPRESENTATION (contract §2 asks us to state the choice and prove it):
--   PS-0 §2 pins it and v61 already enforces it structurally -
--   `sv_lot_movements_bad_debt_zero check (kind <> 'bad_debt' or cents = 0)`.
--   v68a therefore records the loss as a ZERO-BALANCE-EFFECT 'bad_debt' movement on the PAID lot,
--   and carries the figure on public.sv_chargebacks.bad_debt_cents, on the operation result, and in
--   audit_log. Because the movement's cents are 0 by CHECK, Sum(movements) per lot is untouched by
--   it, so the PS-0 §10.1 invariant `remaining == Sum(movements)` still holds after a chargeback and
--   the already-voided value (the negative 'correction') is NOT double-subtracted. Exactly one
--   'bad_debt' movement is written per chargeback, on the paid lot, even when the figure is 0 - a
--   zero bad debt is a meaningful fact (everything was voided, nothing was delivered) and the
--   uniform shape makes "one bad_debt movement per chargeback" a clean assertable invariant.
--   The chargeback voids what REMAINS via negative 'correction' movements (PS-0 §6: "void all
--   remaining lots (paid + bonus) via correction"); the bad debt is the net paid value already
--   DELIVERED AS GOODS (Sum(spend) - Sum(reversal) on the paid lot) that voiding cannot recover.
--   Sales already delivered STAND - v68a reverses no sale and claws back no goods.
--   BALANCE ⚖️ - the accounting TREATMENT of bad debt (write-off vs contra-revenue, GST) is owner +
--   accountant territory (PS-0 §11.3). This migration emits the NUMBER and the EVIDENCE and
--   classifies NOTHING; the operation result says so in words.
--
-- PINNED DEFAULT AWAITING OWNER RATIFICATION (contract §3, PS-0 §11.4) - PRIOR REFUND THEN
-- CHARGEBACK: a chargeback voids only what REMAINS and reports goods-delivered bad debt. It does
-- NOT attempt to recover cash ALREADY REFUNDED to the customer before the chargeback (the
-- double-loss edge: the business refunded cash AND the funding was clawed back). That figure is
-- surfaced explicitly and separately as `cash_already_refunded_cents` on the operation result, on
-- public.sv_chargebacks and in audit_log. It is NOT netted against the void, the bad debt, or
-- anything else. This is a SAFE DEFAULT chosen by the builder, not an owner ruling; the owner may
-- ratify or replace it in a later increment.
--
-- SECOND PINNED DEFAULT AWAITING OWNER RATIFICATION - POSITIVE CORRECTION ONTO AN EXPIRED LOT:
-- public.sv_correct_lot REFUSES a positive correction on a lot whose expiry_key has passed
-- (typed sv_correct_expired_lot). PS-0 §6 pins "an expired lot is never silently resurrected" for
-- the reversal path (restore-then-expire); an owner correction is not an automatic restore, so
-- v68a fails CLOSED rather than inventing either a silent resurrection or a self-cancelling
-- correct-then-expire pair. NEGATIVE corrections on an expired lot remain available.
--
-- PAUSE MAPPING (contract §7, stated explicitly): chargeback and correction are REDEMPTION-FAMILY
-- corrections - they remove value that a customer currently holds - so an active 'all' OR 'redeem'
-- sv_pause blocks both (app.sv_pause_active(..., 'redeem')). This is the same family v64 assigned to
-- sv_reverse_spend ("a reversal of a spend is a redeem-side correction"). refund_sv_operation keeps
-- its v64 'earn' mapping unchanged (a refund returns customer cash = an earn-side correction).
--
-- SAFETY: applying v68a to a clean chain creates ZERO sv_lots / sv_lot_movements / sv_chargebacks /
-- sv_topup_cash_refunds rows and moves ZERO value. The v66 mint tripwire (record_sv_topup_sale is
-- the only paid-lot minter) still holds - v68a adds no minter and inserts into no lot table. The
-- v67 §11a/§11b refusals are neither touched nor weakened.

begin;

-- =====================================================================
-- 1. sv_operations operation_type vocabulary: add 'chargeback' and 'correction'.
--    The v61 CHECK is an inline unnamed constraint, so its catalog name is resolved rather than
--    assumed (a hard-coded DROP would fail closed on any environment PostgreSQL named differently).
--    Existing values are untouched; this only WIDENS the accepted set.
-- =====================================================================
do $v68a_operation_type_vocab$
declare v_name text; v_def text;
begin
  select c.conname, pg_get_constraintdef(c.oid) into v_name, v_def
    from pg_constraint c
   where c.conrelid = 'public.sv_operations'::regclass and c.contype = 'c'
     and pg_get_constraintdef(c.oid) like '%operation_type%';
  if v_name is null then
    raise exception 'v68a: the sv_operations operation_type CHECK constraint was not found';
  end if;
  if position('chargeback' in v_def) > 0 or position('correction' in v_def) > 0 then
    raise exception 'v68a: sv_operations already accepts chargeback/correction operations';
  end if;
  if position('''topup''' in v_def) = 0 or position('''refund''' in v_def) = 0 then
    raise exception 'v68a: unexpected sv_operations operation_type CHECK definition: %', v_def;
  end if;
  execute format('alter table public.sv_operations drop constraint %I', v_name);
end
$v68a_operation_type_vocab$;

alter table public.sv_operations
  add constraint sv_operations_operation_type_check check (operation_type in
    ('topup', 'grant', 'spend', 'reserve', 'release', 'expire', 'reverse', 'refund', 'adjust',
     'chargeback', 'correction'));

-- =====================================================================
-- 2. public.sv_chargebacks - the append-only chargeback record. ONE row per charged-back top-up
--    operation (unique business_id, topup_operation_id) is the STRUCTURAL single-winner guarantee:
--    two concurrent chargebacks of one operation cannot both materialise even if both somehow got
--    past the advisory lock. Carries the report figures PS-0 §6 defines (voided paid, voided bonus,
--    bad debt) plus the contract §3 double-loss figure (cash_already_refunded_cents), NONE of them
--    netted against each other. Owner + super-admin READ; browser writes revoked (definer RPC only).
-- =====================================================================
create table public.sv_chargebacks (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  account_id uuid not null,
  topup_operation_id uuid not null,
  operation_id uuid not null,
  payment_id uuid not null,
  paid_lot_id uuid not null,
  bonus_lot_id uuid,
  voided_paid_cents integer not null check (voided_paid_cents >= 0),
  voided_bonus_cents integer not null check (voided_bonus_cents >= 0),
  bad_debt_cents integer not null check (bad_debt_cents >= 0),
  cash_already_refunded_cents integer not null check (cash_already_refunded_cents >= 0),
  cash_collected_cents integer not null check (cash_collected_cents >= 0),
  currency text not null,
  reason text not null check (char_length(btrim(reason)) >= 3),
  actor uuid,
  created_at timestamptz not null default now(),
  constraint sv_chargebacks_id_business_uk unique (id, business_id),
  constraint sv_chargebacks_topup_uk unique (business_id, topup_operation_id),
  constraint sv_chargebacks_operation_uk unique (operation_id),
  constraint sv_chargebacks_account_fk foreign key (account_id, business_id)
    references public.sv_accounts(id, business_id) on delete restrict,
  constraint sv_chargebacks_topup_op_fk foreign key (topup_operation_id, business_id)
    references public.sv_operations(id, business_id) on delete restrict,
  constraint sv_chargebacks_operation_fk foreign key (operation_id, business_id)
    references public.sv_operations(id, business_id) on delete restrict,
  constraint sv_chargebacks_payment_fk foreign key (payment_id, business_id)
    references public.sv_topup_payments(id, business_id) on delete restrict,
  constraint sv_chargebacks_paid_lot_fk foreign key (paid_lot_id, business_id)
    references public.sv_lots(id, business_id) on delete restrict,
  constraint sv_chargebacks_bonus_lot_fk foreign key (bonus_lot_id, business_id)
    references public.sv_lots(id, business_id) on delete restrict
);
create index sv_chargebacks_business_idx on public.sv_chargebacks (business_id, created_at);
create index sv_chargebacks_account_idx on public.sv_chargebacks (business_id, account_id);
create trigger sv_chargebacks_immutable_guard
  before update or delete on public.sv_chargebacks
  for each row execute function app.sv_immutable_guard();
alter table public.sv_chargebacks enable row level security;
create policy sv_chargebacks_owner_read on public.sv_chargebacks
  for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_chargebacks_sa_read on public.sv_chargebacks
  for select to authenticated using (app.is_super_admin());
revoke all on public.sv_chargebacks from public, anon, authenticated;
grant select on public.sv_chargebacks to authenticated;

-- =====================================================================
-- 3. public.sv_topup_cash_refunds - the STRUCTURAL cash-refund cap (contract §5). One append-only
--    row per cash-bearing refund of a top-up operation, carrying the RUNNING cumulative cash. Three
--    structures, not one code branch, enforce the cap:
--      (a) `cumulative_cash_cents <= cash_collected_cents` - a CHECK, so no code path (present or
--          future, RPC or SQL console) can record cash beyond what was collected;
--      (b) unique (business_id, topup_operation_id, cumulative_cash_cents) - two concurrent refunds
--          that both computed the same running total cannot both commit;
--      (c) unique refund_operation_id - one cap row per refund operation, so a replayed refund
--          cannot double-count.
--    `cash_basis` records WHICH figure bounded the row: 'payment_evidence' is the contract's
--    sv_topup_payments.amount_cents; 'minted_paid_fallback' is the paid lot's minted_cents, used
--    only for operations that carry no payment-evidence row at all (the retired pre-v66 sv_topup /
--    sv_grant mint paths, which cannot be reached in production and mint exactly price_cents into
--    the paid lot, so the fallback equals the collected cash by construction).
-- =====================================================================
create table public.sv_topup_cash_refunds (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  account_id uuid not null,
  topup_operation_id uuid not null,
  refund_operation_id uuid not null,
  paid_lot_id uuid not null,
  cash_cents integer not null check (cash_cents > 0),
  cumulative_cash_cents integer not null check (cumulative_cash_cents > 0),
  cash_collected_cents integer not null check (cash_collected_cents >= 0),
  cash_basis text not null check (cash_basis in ('payment_evidence', 'minted_paid_fallback')),
  actor uuid,
  created_at timestamptz not null default now(),
  constraint sv_topup_cash_refunds_id_business_uk unique (id, business_id),
  constraint sv_topup_cash_refunds_refund_op_uk unique (refund_operation_id),
  constraint sv_topup_cash_refunds_running_uk unique (business_id, topup_operation_id, cumulative_cash_cents),
  constraint sv_topup_cash_refunds_cap_check check (cumulative_cash_cents <= cash_collected_cents),
  constraint sv_topup_cash_refunds_running_check check (cumulative_cash_cents >= cash_cents),
  constraint sv_topup_cash_refunds_account_fk foreign key (account_id, business_id)
    references public.sv_accounts(id, business_id) on delete restrict,
  constraint sv_topup_cash_refunds_topup_op_fk foreign key (topup_operation_id, business_id)
    references public.sv_operations(id, business_id) on delete restrict,
  constraint sv_topup_cash_refunds_refund_op_fk foreign key (refund_operation_id, business_id)
    references public.sv_operations(id, business_id) on delete restrict,
  constraint sv_topup_cash_refunds_paid_lot_fk foreign key (paid_lot_id, business_id)
    references public.sv_lots(id, business_id) on delete restrict
);
create index sv_topup_cash_refunds_topup_idx
  on public.sv_topup_cash_refunds (business_id, topup_operation_id, created_at);
create trigger sv_topup_cash_refunds_immutable_guard
  before update or delete on public.sv_topup_cash_refunds
  for each row execute function app.sv_immutable_guard();
alter table public.sv_topup_cash_refunds enable row level security;
create policy sv_topup_cash_refunds_owner_read on public.sv_topup_cash_refunds
  for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_topup_cash_refunds_sa_read on public.sv_topup_cash_refunds
  for select to authenticated using (app.is_super_admin());
revoke all on public.sv_topup_cash_refunds from public, anon, authenticated;
grant select on public.sv_topup_cash_refunds to authenticated;

-- =====================================================================
-- 4. PURE read helpers over the EXISTING ledger authority. None of them writes; none of them
--    re-implements allocation, balance or refund arithmetic (that stays app.sv_allocate_spend /
--    app.sv_available_balance / app.sv_lot_remaining / app.sv_plan_refund).
-- =====================================================================

-- The cash actually collected for a top-up operation, and WHICH figure that came from.
-- Contract §5 names sv_topup_payments.amount_cents; the fallback exists only for lots minted by the
-- retired pre-v66 paths, which carry no payment-evidence row (see §3 above).
create or replace function app.sv_cash_collected_cents(p_business uuid, p_topup_operation uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_amount integer; v_minted integer;
begin
  select amount_cents into v_amount from public.sv_topup_payments
   where business_id = p_business and operation_id = p_topup_operation;
  if v_amount is not null then
    return jsonb_build_object('collected_cents', v_amount, 'basis', 'payment_evidence');
  end if;
  select coalesce(sum(minted_cents), 0)::integer into v_minted from public.sv_lots
   where business_id = p_business and operation_id = p_topup_operation and class = 'paid';
  return jsonb_build_object('collected_cents', v_minted, 'basis', 'minted_paid_fallback');
end $$;
revoke all on function app.sv_cash_collected_cents(uuid, uuid) from public, anon, authenticated;

-- Cumulative cash already refunded for a top-up operation, derived from the MOVEMENT AUTHORITY
-- (the paid lot's 'refund' rows), not from a cache: correct for operations refunded before v68a and
-- immune to any drift in the cap ledger.
create or replace function app.sv_cash_refunded_cents(p_business uuid, p_topup_operation uuid)
returns integer language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce(-sum(m.cents), 0)::integer
    from public.sv_lot_movements m
    join public.sv_lots l on l.id = m.lot_id and l.business_id = m.business_id
   where m.business_id = p_business and l.operation_id = p_topup_operation
     and l.class = 'paid' and m.kind = 'refund'
$$;
revoke all on function app.sv_cash_refunded_cents(uuid, uuid) from public, anon, authenticated;

-- Net value of a top-up operation already consumed as goods: Sum(spend) - Sum(reversal) over ALL of
-- the operation's lots. PS-0 §6 uses exactly this expression (there, over the paid lot) for bad
-- debt; the unused-only refund variant uses it over the whole operation. Floored at 0.
create or replace function app.sv_operation_net_spent(p_business uuid, p_topup_operation uuid)
returns integer language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select greatest(coalesce(sum(
           case when m.kind = 'spend' then -m.cents
                when m.kind = 'reversal' then -m.cents
                else 0 end), 0), 0)::integer
    from public.sv_lot_movements m
    join public.sv_lots l on l.id = m.lot_id and l.business_id = m.business_id
   where m.business_id = p_business and l.operation_id = p_topup_operation
$$;
revoke all on function app.sv_operation_net_spent(uuid, uuid) from public, anon, authenticated;

-- The refund policy that governs a top-up operation: the IMMUTABLE plan version its paid lot pinned
-- at mint (v65 config; PS-0 §2 "consumption/refund logic reads the purchase's own snapshot, never
-- the live plan"). Operations minted without a plan version resolve to the product default
-- 'proportional', so the stricter variants are OFF unless a business published them.
create or replace function app.sv_operation_refund_policy(p_business uuid, p_topup_operation uuid)
returns text language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce((select pv.refund_policy
                     from public.sv_lots l
                     join public.sv_plan_versions pv
                       on pv.id = l.plan_version_id and pv.business_id = l.business_id
                    where l.business_id = p_business and l.operation_id = p_topup_operation
                      and l.class = 'paid'
                    order by l.earned_seq asc, l.id asc limit 1), 'proportional')
$$;
revoke all on function app.sv_operation_refund_policy(uuid, uuid) from public, anon, authenticated;

-- =====================================================================
-- 5. app.sv_chargeback_plan - PURE planner (NO authority gate, NO DML), the same shape as the v63
--    app.sv_plan_refund it sits beside. PS-0 §6 case (e): the funding payment was reversed by the
--    bank, so VOID ALL REMAINING on that operation's lots (paid remaining and bonus remaining) via
--    negative 'correction' movements, and REPORT the bad debt = the net paid value already delivered
--    as goods = Sum(spend) - Sum(reversal) on the PAID lot. Remaining comes from the engine
--    (app.sv_lot_remaining), so this adds no parallel balance implementation.
--    Case (e) oracle - $100 paid (10000) + $12 bonus (1200), $80 spend (bonus_draw 857 / paid_draw
--    7143): void paid 2857 + bonus 343, bad debt 7143.
-- =====================================================================
create or replace function app.sv_chargeback_plan(p_business uuid, p_topup_operation uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_paid_lot uuid;
  v_bonus_lot uuid;
  v_account uuid;
  v_paid_rem bigint;
  v_bonus_rem bigint;
  v_spent bigint;
  v_reversed bigint;
  v_refunded bigint;
  v_bad_debt bigint;
  v_plan jsonb := '[]'::jsonb;
begin
  select id, account_id into v_paid_lot, v_account from public.sv_lots
   where business_id = p_business and operation_id = p_topup_operation and class = 'paid'
   order by earned_seq asc, id asc limit 1;
  if v_paid_lot is null then
    return jsonb_build_object('ok', false, 'reason', 'operation has no paid lot to charge back');
  end if;
  select id into v_bonus_lot from public.sv_lots
   where business_id = p_business and operation_id = p_topup_operation and class = 'bonus'
   order by earned_seq asc, id asc limit 1;

  v_paid_rem := app.sv_lot_remaining(v_paid_lot);
  v_bonus_rem := coalesce(app.sv_lot_remaining(v_bonus_lot), 0);

  -- PS-0 §6: bad debt is the net PAID value already delivered as goods; the refund total is the
  -- contract §3 double-loss figure and is reported ALONGSIDE, never netted into, the bad debt.
  select coalesce(sum(case when m.kind = 'spend' then -m.cents else 0 end), 0),
         coalesce(sum(case when m.kind = 'reversal' then m.cents else 0 end), 0),
         coalesce(sum(case when m.kind = 'refund' then -m.cents else 0 end), 0)
    into v_spent, v_reversed, v_refunded
    from public.sv_lot_movements m
   where m.business_id = p_business and m.lot_id = v_paid_lot;
  v_bad_debt := greatest(v_spent - v_reversed, 0);

  if v_paid_rem > 0 then
    v_plan := v_plan || jsonb_build_array(jsonb_build_object(
      'lot_id', v_paid_lot, 'class', 'paid', 'kind', 'correction', 'cents', (-v_paid_rem)::int));
  end if;
  if v_bonus_rem > 0 and v_bonus_lot is not null then
    v_plan := v_plan || jsonb_build_array(jsonb_build_object(
      'lot_id', v_bonus_lot, 'class', 'bonus', 'kind', 'correction', 'cents', (-v_bonus_rem)::int));
  end if;
  -- The zero-balance-effect loss record (PS-0 §2 footnote; v61 CHECK forces cents = 0).
  v_plan := v_plan || jsonb_build_array(jsonb_build_object(
    'lot_id', v_paid_lot, 'class', 'paid', 'kind', 'bad_debt', 'cents', 0));

  return jsonb_build_object(
    'ok', true,
    'account_id', v_account,
    'paid_lot', v_paid_lot,
    'bonus_lot', v_bonus_lot,
    'paid_remaining_cents', v_paid_rem::int,
    'bonus_remaining_cents', v_bonus_rem::int,
    'void_paid_cents', v_paid_rem::int,
    'void_bonus_cents', v_bonus_rem::int,
    'bad_debt_cents', v_bad_debt::int,
    'cash_already_refunded_cents', v_refunded::int,
    'plan', v_plan);
end $$;
revoke all on function app.sv_chargeback_plan(uuid, uuid) from public, anon, authenticated;

-- =====================================================================
-- 6. public.sv_chargeback_topup - the owner-gated chargeback (contract §2, PS-0 §6 case (e)).
--    Gate order mirrors v63/v64/v66/v67 exactly: owner -> authority='live' -> pause -> arguments ->
--    entity resolution + tenancy -> synthetic/live coherence -> currency -> advisory locks ->
--    idempotency envelope -> TOCTOU re-validation -> FEFO row locks -> compute -> write.
--    A refused attempt writes NOTHING and reserves no idempotency key.
--    The payment row stays IMMUTABLE (v66): the chargeback is recorded as an append-only
--    sv_topup_payment_events row with event_type='chargeback'.
--    Sales already delivered STAND: no sale is reversed and no goods are clawed back. In particular
--    this function does NOT call any reversal path, so the v67 §11a/§11b refusals are untouched.
-- =====================================================================
create or replace function public.sv_chargeback_topup(
  p_business uuid, p_topup_operation uuid, p_reason text, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_hash text;
  v_existing public.sv_operations%rowtype;
  v_op uuid := gen_random_uuid();
  v_state text;
  v_topup_type text;
  v_account uuid;
  v_client uuid;
  v_biz_synth boolean;
  v_client_synth boolean;
  v_biz_currency text;
  v_payment public.sv_topup_payments%rowtype;
  v_collected jsonb;
  v_plan jsonb;
  v_entry jsonb;
  v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  -- HARD SAFETY GATE (v63): value only moves when stored value is the authority for this business.
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;
  -- PAUSE GATE (v64 family mapping): a chargeback removes value the customer currently holds, so it
  -- is a redemption-family correction - an active 'all' or 'redeem' pause blocks it.
  if app.sv_pause_active(p_business, 'stored_value', 'redeem') then
    raise exception 'sv_paused: stored-value redemptions are paused' using errcode = '22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value chargeback idempotency key is required' using errcode = '22023';
  end if;
  if char_length(v_reason) < 3 then
    raise exception 'a stored-value chargeback requires a reason of at least 3 characters' using errcode = '22023';
  end if;

  select o.operation_type into v_topup_type from public.sv_operations o
   where o.id = p_topup_operation and o.business_id = p_business;
  if v_topup_type is null then
    raise exception 'stored-value top-up operation not found in this business' using errcode = '22023';
  end if;
  if v_topup_type <> 'topup' then
    raise exception 'stored-value chargeback target is not a top-up operation' using errcode = '22023';
  end if;

  select l.account_id into v_account from public.sv_lots l
   where l.business_id = p_business and l.operation_id = p_topup_operation and l.class = 'paid'
   order by l.earned_seq asc, l.id asc limit 1;
  if v_account is null then
    raise exception 'stored-value operation has no paid lot to charge back' using errcode = '22023';
  end if;
  select a.client_id into v_client from public.sv_accounts a
   where a.id = v_account and a.business_id = p_business;

  -- Payment evidence is mandatory: a chargeback is the reversal of a RECORDED funding payment.
  select * into v_payment from public.sv_topup_payments
   where business_id = p_business and operation_id = p_topup_operation;
  if not found then
    raise exception 'sv_no_payment_evidence: this top-up carries no recorded funding payment to charge back'
      using errcode = '22023';
  end if;

  -- SYNTHETIC/LIVE COHERENCE (v66): a synthetic entity cannot transact on a live business.
  select b.is_synthetic, b.currency into v_biz_synth, v_biz_currency
    from public.businesses b where b.id = p_business;
  select c.is_synthetic into v_client_synth from public.clients c
   where c.id = v_client and c.business_id = p_business;
  if coalesce(v_biz_synth, false) or coalesce(v_client_synth, false) then
    raise exception 'a synthetic entity cannot transact on a live business' using errcode = '22023';
  end if;
  -- CURRENCY: the recorded funding currency must still be this business's currency.
  if upper(btrim(coalesce(v_payment.currency, ''))) <> upper(btrim(coalesce(v_biz_currency, 'SGD'))) then
    raise exception 'currency_mismatch: the recorded funding currency (%) is not this business currency (%)',
      v_payment.currency, upper(coalesce(v_biz_currency, 'SGD')) using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('v63:sv_acct:' || p_business::text || ':' || v_account::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('v68a:sv_chargeback:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'chargeback' and o.idempotency_key = p_idempotency_key
   for update;
  v_hash := app.ps1b_sha256(jsonb_build_object(
    'op', 'chargeback', 'business_id', p_business, 'topup_operation_id', p_topup_operation,
    'reason', v_reason)::text);
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different stored-value chargeback' using errcode = '22023';
    end if;
    return v_existing.result;   -- same key, same request -> ONE effect, replayed result
  end if;

  -- TOCTOU RE-VALIDATION (v66/v67 pattern): re-read the gates under the locks so a concurrent
  -- authority transition or pause committed since the early checks cannot slip a write through.
  select coalesce(state, 'unbuilt') into v_state from public.sv_authority
   where business_id = p_business and asset = 'stored_value';
  if coalesce(v_state, 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;
  if app.sv_pause_active(p_business, 'stored_value', 'redeem') then
    raise exception 'sv_paused: stored-value redemptions are paused' using errcode = '22023';
  end if;

  -- ONE chargeback per top-up operation. The unique index is the hard guarantee; this is the typed
  -- refusal the caller sees.
  if exists (select 1 from public.sv_chargebacks c
              where c.business_id = p_business and c.topup_operation_id = p_topup_operation) then
    raise exception 'sv_already_charged_back: this top-up has already been charged back' using errcode = '22023';
  end if;

  -- FEFO row locks over the account's lot set (one-winner vs a concurrent spend or refund; the same
  -- deterministic order the v63 engine uses, so no deadlock).
  perform 1 from public.sv_lots l
   where l.business_id = p_business and l.account_id = v_account
   order by l.expiry_key asc nulls last, l.earned_seq asc, l.id asc
   for update;

  v_plan := app.sv_chargeback_plan(p_business, p_topup_operation);
  if (v_plan->>'ok')::boolean is not true then
    raise exception 'stored-value chargeback failed: %', coalesce(v_plan->>'reason', 'unknown') using errcode = '22023';
  end if;
  v_collected := app.sv_cash_collected_cents(p_business, p_topup_operation);

  v_result := jsonb_build_object(
    'status', 'ok', 'operation_id', v_op, 'topup_operation_id', p_topup_operation,
    'account_id', v_account, 'payment_id', v_payment.id,
    'paid_lot', v_plan->'paid_lot', 'bonus_lot', v_plan->'bonus_lot',
    'void_paid_cents', (v_plan->>'void_paid_cents')::int,
    'void_bonus_cents', (v_plan->>'void_bonus_cents')::int,
    'voided_total_cents', (v_plan->>'void_paid_cents')::int + (v_plan->>'void_bonus_cents')::int,
    'bad_debt_cents', (v_plan->>'bad_debt_cents')::int,
    'cash_already_refunded_cents', (v_plan->>'cash_already_refunded_cents')::int,
    'cash_collected_cents', (v_collected->>'collected_cents')::int,
    'cash_basis', v_collected->>'basis',
    'currency', upper(btrim(v_payment.currency)),
    'reason', v_reason,
    'sales_delivered_stand', true,
    'bad_debt_accounting_classification', 'not_classified_owner_and_accountant_review_required',
    'plan', v_plan->'plan');

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'chargeback', p_idempotency_key, v_hash, v_actor, v_result);

  -- Apply: a negative 'correction' per lot that still holds value, plus exactly one zero-cents
  -- 'bad_debt' loss record on the paid lot. The bad_debt row cannot disturb
  -- `remaining == Sum(movements)` because v61's CHECK forces its cents to 0.
  for v_entry in select * from jsonb_array_elements(v_plan->'plan') loop
    insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
    values (p_business, v_account, (v_entry->>'lot_id')::uuid, v_op, v_entry->>'kind', (v_entry->>'cents')::int);
  end loop;

  insert into public.sv_chargebacks(
    business_id, account_id, topup_operation_id, operation_id, payment_id, paid_lot_id, bonus_lot_id,
    voided_paid_cents, voided_bonus_cents, bad_debt_cents, cash_already_refunded_cents,
    cash_collected_cents, currency, reason, actor)
  values (
    p_business, v_account, p_topup_operation, v_op, v_payment.id,
    (v_plan->>'paid_lot')::uuid, nullif(v_plan->>'bonus_lot', '')::uuid,
    (v_plan->>'void_paid_cents')::int, (v_plan->>'void_bonus_cents')::int,
    (v_plan->>'bad_debt_cents')::int, (v_plan->>'cash_already_refunded_cents')::int,
    (v_collected->>'collected_cents')::int, upper(btrim(v_payment.currency)), v_reason, v_actor);

  -- The payment itself is immutable (v66); the chargeback is append-only evidence beside it.
  insert into public.sv_topup_payment_events(business_id, payment_id, event_type, operation_id, actor, reason)
  values (p_business, v_payment.id, 'chargeback', v_op, v_actor, v_reason);

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_CHARGEBACK', 'sv_accounts', v_account, jsonb_build_object(
    'operation_id', v_op, 'topup_operation_id', p_topup_operation, 'payment_id', v_payment.id,
    'void_paid_cents', (v_plan->>'void_paid_cents')::int,
    'void_bonus_cents', (v_plan->>'void_bonus_cents')::int,
    'bad_debt_cents', (v_plan->>'bad_debt_cents')::int,
    'cash_already_refunded_cents', (v_plan->>'cash_already_refunded_cents')::int,
    'cash_collected_cents', (v_collected->>'collected_cents')::int,
    'bad_debt_accounting_classification', 'not_classified_owner_and_accountant_review_required',
    'reason', v_reason));

  return v_result;
end $$;
revoke all on function public.sv_chargeback_topup(uuid, uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.sv_chargeback_topup(uuid, uuid, text, uuid) to authenticated;

-- =====================================================================
-- 7. public.sv_correct_lot - the owner-gated business correction (contract §4, PS-0 §6). Reason
--    MANDATORY (empty/whitespace/short -> typed 22023), BOTH DIRECTIONS, fully audited. Invariants:
--      * a correction may never drive a lot's derived remaining BELOW 0 nor ABOVE its minted_cents;
--      * it never touches another lot - exactly ONE movement is written, on p_lot;
--      * it is NOT a mint - no sv_lots row is ever created here, so the v66 tripwire
--        (record_sv_topup_sale is the only paid-lot minter) stays green;
--      * a POSITIVE correction onto an already-expired lot is REFUSED (pinned default, see header);
--      * a lot belonging to a charged-back top-up operation is frozen - the funding is gone, so
--        putting value back onto it would recreate value the bank clawed back.
-- =====================================================================
create or replace function public.sv_correct_lot(
  p_business uuid, p_lot uuid, p_cents integer, p_reason text, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_hash text;
  v_existing public.sv_operations%rowtype;
  v_op uuid := gen_random_uuid();
  v_state text;
  v_lot public.sv_lots%rowtype;
  v_client uuid;
  v_biz_synth boolean;
  v_client_synth boolean;
  v_biz_currency text;
  v_remaining integer;
  v_after bigint;
  v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;
  -- Same redemption-family mapping as the chargeback (see header): a correction adjusts value the
  -- customer currently holds, so 'all' or 'redeem' blocks it.
  if app.sv_pause_active(p_business, 'stored_value', 'redeem') then
    raise exception 'sv_paused: stored-value redemptions are paused' using errcode = '22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value correction idempotency key is required' using errcode = '22023';
  end if;
  if char_length(v_reason) < 3 then
    raise exception 'a stored-value correction requires a reason of at least 3 characters' using errcode = '22023';
  end if;
  if p_cents is null or p_cents = 0 then
    raise exception 'a stored-value correction must be a non-zero whole number of cents' using errcode = '22023';
  end if;

  select * into v_lot from public.sv_lots where id = p_lot and business_id = p_business;
  if not found then
    raise exception 'stored-value lot not found in this business' using errcode = '22023';
  end if;
  select a.client_id into v_client from public.sv_accounts a
   where a.id = v_lot.account_id and a.business_id = p_business;

  select b.is_synthetic, b.currency into v_biz_synth, v_biz_currency
    from public.businesses b where b.id = p_business;
  select c.is_synthetic into v_client_synth from public.clients c
   where c.id = v_client and c.business_id = p_business;
  if coalesce(v_biz_synth, false) or coalesce(v_client_synth, false) then
    raise exception 'a synthetic entity cannot transact on a live business' using errcode = '22023';
  end if;
  if btrim(coalesce(v_biz_currency, '')) !~ '^[A-Za-z]{3}$' then
    raise exception 'currency_missing: this business has no valid three-letter currency configured'
      using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('v63:sv_acct:' || p_business::text || ':' || v_lot.account_id::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('v68a:sv_correct:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'correction' and o.idempotency_key = p_idempotency_key
   for update;
  v_hash := app.ps1b_sha256(jsonb_build_object(
    'op', 'correction', 'business_id', p_business, 'lot_id', p_lot, 'cents', p_cents,
    'reason', v_reason)::text);
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different stored-value correction' using errcode = '22023';
    end if;
    return v_existing.result;
  end if;

  -- TOCTOU RE-VALIDATION under the locks.
  select coalesce(state, 'unbuilt') into v_state from public.sv_authority
   where business_id = p_business and asset = 'stored_value';
  if coalesce(v_state, 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;
  if app.sv_pause_active(p_business, 'stored_value', 'redeem') then
    raise exception 'sv_paused: stored-value redemptions are paused' using errcode = '22023';
  end if;

  if exists (select 1 from public.sv_chargebacks c
              where c.business_id = p_business and c.topup_operation_id = v_lot.operation_id) then
    raise exception 'sv_charged_back: this lot belongs to a charged-back top-up and can no longer be corrected'
      using errcode = '22023';
  end if;

  -- Lock exactly the target lot's row (a correction never touches another lot).
  perform 1 from public.sv_lots l where l.id = p_lot and l.business_id = p_business for update;

  v_remaining := app.sv_lot_remaining(p_lot);
  v_after := coalesce(v_remaining, 0)::bigint + p_cents;
  if v_after < 0 then
    raise exception 'sv_correction_below_zero: a correction of % would drive lot remaining from % to %',
      p_cents, v_remaining, v_after using errcode = '22023';
  end if;
  if v_after > v_lot.minted_cents then
    raise exception 'sv_correction_above_mint: a correction of % would drive lot remaining from % to %, above the minted %',
      p_cents, v_remaining, v_after, v_lot.minted_cents using errcode = '22023';
  end if;
  if p_cents > 0 and v_lot.expiry_key is not null and v_lot.expiry_key <= now() then
    raise exception 'sv_correct_expired_lot: a positive correction cannot be applied to an expired lot (expired %)',
      v_lot.expiry_key using errcode = '22023';
  end if;

  v_result := jsonb_build_object(
    'status', 'ok', 'operation_id', v_op, 'lot_id', p_lot, 'account_id', v_lot.account_id,
    'class', v_lot.class, 'cents', p_cents, 'direction', case when p_cents > 0 then 'increase' else 'decrease' end,
    'remaining_before_cents', coalesce(v_remaining, 0), 'remaining_after_cents', v_after::int,
    'minted_cents', v_lot.minted_cents, 'currency', upper(btrim(v_biz_currency)),
    'reason', v_reason, 'is_mint', false);

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'correction', p_idempotency_key, v_hash, v_actor, v_result);
  insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
  values (p_business, v_lot.account_id, p_lot, v_op, 'correction', p_cents);
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_CORRECT_LOT', 'sv_lots', p_lot, jsonb_build_object(
    'operation_id', v_op, 'account_id', v_lot.account_id, 'class', v_lot.class, 'cents', p_cents,
    'remaining_before_cents', coalesce(v_remaining, 0), 'remaining_after_cents', v_after::int,
    'minted_cents', v_lot.minted_cents, 'reason', v_reason));

  return v_result;
end $$;
revoke all on function public.sv_correct_lot(uuid, uuid, integer, text, uuid) from public, anon, authenticated;
grant execute on function public.sv_correct_lot(uuid, uuid, integer, text, uuid) to authenticated;

-- =====================================================================
-- 8. public.refund_sv_operation - CREATE OR REPLACE over its v64 predecessor (v63 body + v64's earn
--    pause gate). The body below is byte-identical to that predecessor EXCEPT for three additions,
--    all placed after the idempotency-envelope lookup and the FEFO row locks and BEFORE the first
--    write, so a refused attempt mutates nothing and reserves no idempotency key:
--
--      (a) CHARGED-BACK REFUSAL - refunding cash on a top-up whose funding the bank already clawed
--          back would pay the customer twice for money the business no longer has. Typed
--          `sv_charged_back` (22023). This is also what makes contract §7's "chargeback racing a
--          refund -> one winner, the loser typed" true rather than a silent zero-cash no-op.
--      (b) PLAN-VERSION REFUND POLICY (contract §5, reusing the v65 config - no parallel config
--          table): 'no_refund' refuses outright; 'unused_only' refuses unless the operation is
--          WHOLLY UNSPENT (app.sv_operation_net_spent = 0). The product default 'proportional' and
--          the existing 'full_unused' value both keep today's behaviour exactly, so the stricter
--          variant is OFF unless a business published it.
--      (c) CASH-REFUND CAP (contract §5): cumulative cash refunded for the operation may never
--          exceed the cash actually collected for it. The typed refusal is `sv_cash_refund_cap`
--          (22023); the STRUCTURAL enforcement is the public.sv_topup_cash_refunds row written
--          alongside the movements (CHECK cumulative <= collected + unique running total).
--          The "never exceeds paid remaining" half of the cap is already structural in the v63
--          planner (app.sv_plan_refund refuses X > paid_remaining) and is unchanged here.
--
--    Everything else - the owner check, the sv_not_live gate, the v64 earn pause gate, the argument
--    validation, the operation/account resolution, both advisory locks, the request-hash envelope,
--    the FEFO row locks, the pure planner call, the result shape, the movement writes and the
--    SV_REFUND audit row - is preserved verbatim.
-- =====================================================================
create or replace function public.refund_sv_operation(
  p_business uuid, p_topup_operation uuid, p_cash_cents integer, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_hash text;
  v_existing public.sv_operations%rowtype;
  v_op uuid := gen_random_uuid();
  v_account uuid;
  v_topup_type text;
  v_plan jsonb;
  v_entry jsonb;
  v_result jsonb;
  v_policy text;
  v_net_spent integer;
  v_collected jsonb;
  v_collected_cents integer;
  v_prior_cash integer;
  v_cash integer;
  v_cumulative integer;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;

  -- PS-2A Increment D pause gate (contract D §1: a refund returns customer cash = an earn-side
  -- correction, so an active 'all' or 'earn' sv_pause blocks it). Second gate, independent of
  -- sv_not_live; this block is the ONLY addition over the v63 body.
  if app.sv_pause_active(p_business, 'stored_value', 'earn') then
    raise exception 'sv_paused: stored-value earns are paused' using errcode = '22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value refund idempotency key is required' using errcode = '22023';
  end if;

  select o.operation_type into v_topup_type from public.sv_operations o
   where o.id = p_topup_operation and o.business_id = p_business;
  if v_topup_type is null then
    raise exception 'stored-value top-up operation not found in this business' using errcode = '22023';
  end if;

  select account_id into v_account from public.sv_lots
   where business_id = p_business and operation_id = p_topup_operation and class = 'paid'
   order by earned_seq asc, id asc limit 1;
  if v_account is null then
    raise exception 'stored-value operation has no paid lot to refund' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('v63:sv_acct:' || p_business::text || ':' || v_account::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('v63:sv_refund:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'refund' and o.idempotency_key = p_idempotency_key
   for update;
  v_hash := app.ps1b_sha256(jsonb_build_object(
    'op', 'refund', 'business_id', p_business, 'topup_operation_id', p_topup_operation,
    'cash_cents', p_cash_cents)::text);
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different stored-value refund' using errcode = '22023';
    end if;
    return v_existing.result;
  end if;

  -- FEFO row locks over the operations lots (one-winner vs a concurrent spend on the same account).
  perform 1 from public.sv_lots l
   where l.business_id = p_business and l.account_id = v_account
   order by l.expiry_key asc nulls last, l.earned_seq asc, l.id asc
   for update;

  -- v68a (a): a charged-back top-up can no longer return cash - the funding is gone.
  if exists (select 1 from public.sv_chargebacks c
              where c.business_id = p_business and c.topup_operation_id = p_topup_operation) then
    raise exception 'sv_charged_back: this top-up has been charged back and can no longer be refunded'
      using errcode = '22023';
  end if;

  -- v68a (b): the immutable plan-version refund policy the paid lot pinned at mint (v65 config).
  v_policy := app.sv_operation_refund_policy(p_business, p_topup_operation);
  if v_policy = 'no_refund' then
    raise exception 'sv_refund_not_permitted: the plan version for this top-up does not permit refunds'
      using errcode = '22023';
  end if;
  if v_policy = 'unused_only' then
    v_net_spent := app.sv_operation_net_spent(p_business, p_topup_operation);
    if v_net_spent > 0 then
      raise exception 'sv_refund_unused_only: the plan version permits a refund only while the top-up is wholly unspent (% cents already consumed)',
        v_net_spent using errcode = '22023';
    end if;
  end if;

  v_plan := app.sv_plan_refund(p_business, p_topup_operation, p_cash_cents);
  if (v_plan->>'ok')::boolean is not true then
    raise exception 'stored-value refund failed: %', coalesce(v_plan->>'reason', 'unknown') using errcode = '22023';
  end if;

  -- v68a (c): the cumulative cash cap. Prior cash comes from the MOVEMENT AUTHORITY, so the cap is
  -- correct even for operations refunded before v68a existed.
  v_collected := app.sv_cash_collected_cents(p_business, p_topup_operation);
  v_collected_cents := (v_collected->>'collected_cents')::int;
  v_prior_cash := app.sv_cash_refunded_cents(p_business, p_topup_operation);
  v_cash := (v_plan->>'cash_cents')::int;
  v_cumulative := v_prior_cash + v_cash;
  if v_cumulative > v_collected_cents then
    raise exception 'sv_cash_refund_cap: refunding % cents would take cumulative cash to % on a top-up that collected % cents',
      v_cash, v_cumulative, v_collected_cents using errcode = '22023';
  end if;

  v_result := jsonb_build_object(
    'status', 'ok', 'operation_id', v_op, 'topup_operation_id', p_topup_operation, 'account_id', v_account,
    'cash_cents', (v_plan->>'cash_cents')::int, 'clawback_cents', (v_plan->>'clawback_cents')::int,
    'final', (v_plan->>'final')::boolean, 'plan', v_plan->'plan',
    'refund_policy', v_policy, 'cash_collected_cents', v_collected_cents,
    'cash_basis', v_collected->>'basis',
    'cash_refunded_before_cents', v_prior_cash, 'cash_refunded_cumulative_cents', v_cumulative);

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'refund', p_idempotency_key, v_hash, v_actor, v_result);
  for v_entry in select * from jsonb_array_elements(v_plan->'plan') loop
    insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
    values (p_business, v_account, (v_entry->>'lot_id')::uuid, v_op, v_entry->>'kind', (v_entry->>'cents')::int);
  end loop;
  -- The structural half of the cap: the running total is materialised under a CHECK bounding it by
  -- the collected cash and a unique index that no two concurrent refunds can both satisfy.
  if v_cash > 0 then
    insert into public.sv_topup_cash_refunds(
      business_id, account_id, topup_operation_id, refund_operation_id, paid_lot_id,
      cash_cents, cumulative_cash_cents, cash_collected_cents, cash_basis, actor)
    values (
      p_business, v_account, p_topup_operation, v_op, (v_plan->>'paid_lot')::uuid,
      v_cash, v_cumulative, v_collected_cents, v_collected->>'basis', v_actor);
  end if;
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_REFUND', 'sv_accounts', v_account, jsonb_build_object(
    'operation_id', v_op, 'topup_operation_id', p_topup_operation,
    'cash_cents', (v_plan->>'cash_cents')::int, 'clawback_cents', (v_plan->>'clawback_cents')::int,
    'refund_policy', v_policy, 'cash_collected_cents', v_collected_cents,
    'cash_refunded_cumulative_cents', v_cumulative));

  return v_result;
end $$;
revoke all on function public.refund_sv_operation(uuid, uuid, integer, uuid) from public, anon, authenticated;
grant execute on function public.refund_sv_operation(uuid, uuid, integer, uuid) to authenticated;

-- =====================================================================
-- 9. POST-CONDITIONS. v68a must not have weakened the two v67 reversal refusals, must not have
--    created a second paid-lot minter, and must not have opened either new RPC to anon.
-- =====================================================================
do $v68a_postconditions$
declare v_bad text;
begin
  if position('sv_tendered_sale_unsupported' in
      pg_get_functiondef('public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)'::regprocedure)) = 0 then
    raise exception 'v68a: the v67 §11a sale-leg reversal refusal is missing';
  end if;
  if position('sv_tendered_spend_unsupported' in
      pg_get_functiondef('public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure)) = 0 then
    raise exception 'v68a: the v67 §11b settlement-leg reversal refusal is missing';
  end if;
  select string_agg(n.nspname || '.' || p.proname, ', ' order by n.nspname || '.' || p.proname) into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app')
     and p.prosrc ilike '%insert into public.sv_lots%' and p.prosrc ilike '%''paid''%'
     and p.proname <> 'record_sv_topup_sale';
  if v_bad is not null then
    raise exception 'v68a: a non-authoritative function can mint a paid lot: %', v_bad;
  end if;
  if has_function_privilege('anon', 'public.sv_chargeback_topup(uuid,uuid,text,uuid)', 'execute')
     or has_function_privilege('anon', 'public.sv_correct_lot(uuid,uuid,integer,text,uuid)', 'execute')
     or has_function_privilege('anon', 'public.refund_sv_operation(uuid,uuid,integer,uuid)', 'execute') then
    raise exception 'v68a: a stored-value correction RPC is executable by anon';
  end if;
  if not has_function_privilege('authenticated', 'public.refund_sv_operation(uuid,uuid,integer,uuid)', 'execute') then
    raise exception 'v68a: refund_sv_operation lost the owner-RPC EXECUTE grant it has held since v63';
  end if;
end
$v68a_postconditions$;

commit;
