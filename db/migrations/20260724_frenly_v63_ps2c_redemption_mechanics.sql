-- FRENLY v63 - PROGRAM STUDIO PS-2A INCREMENT C: REDEMPTION / SPEND / REVERSE / REFUND / EXPIRY
--
-- Local review candidate. Production apply needs the owner RELEASE APPROVED phrase
-- (CLAUDE.md standing gate). Builds on Increment A (v61, PASS) + Increment B (v62, PASS)
-- under the SAME PS-2 authorization - no new phase, no cutover. This migration IMPLEMENTS
-- docs/design/ps2/PS2A_INCREMENT_C_CONTRACT.md over the frozen arithmetic authority
-- docs/design/ps0/STORED_VALUE_CONTRACT.md §3-§6 (PS-0 wins ANY conflict). The 26-vector +
-- 2000-iteration property oracle (tests/program-studio/ps0-sv-arithmetic.test.mjs) is the
-- acceptance oracle: the SQL below MUST reproduce identical paid_draw / bonus_draw / clawback
-- / reversal outcomes.
--
-- THE SINGLE HARD SAFETY PROPERTY (contract §"single hard safety property"):
--   Every value-moving entry point here - sv_reserve, sv_release, sv_spend, sv_reverse_spend,
--   refund_sv_operation, sv_expire_due - is GATED so it can only ever run when
--   sv_authority.state = 'live', which is UNREACHABLE in PS-2A (no function sets 'live'; the
--   v61 sv_authority guard rejects the transition; the v62 set_sv_authority_state CHECK forbids
--   naming it; the ps0-no-executor tripwire forbids any migration setting it). So Increment C
--   ships the COMPLETE redemption machinery + its exact PS-0 arithmetic, but NO real customer
--   value can move: the FIRST line after the owner check in every value RPC is
--     if coalesce((select state from sv_authority ...), 'unbuilt') <> 'live'
--       then raise '22023 sv_not_live' end if
--   and unbuilt (the ship state for every tenant) fails it with ZERO writes. The PURE planners
--   (app.sv_allocate_spend / app.sv_plan_refund / app.sv_checkout_quote) carry NO authority gate
--   - they only COMPUTE a plan (no DML), so they are safe to unit-test directly - but nothing
--   applies their plan except a gated RPC. The suite exercises the machinery two ways: (a) the
--   pure planners directly, and (b) the gated RPCs under a rolled-back authority='live' shim
--   (test-local trigger-disable inside BEGIN/ROLLBACK - NEVER in a migration, NEVER persistent).
--
-- WHAT INCREMENT C ADDS:
--   1. app.sv_available_balance (CREATE OR REPLACE, minimal diff): now subtracts the sum of
--      ACTIVE sv_reservations holds (contract: available = Σ movements - Σ active reservations).
--      Behaviour is unchanged in PS-2A because no reservation can be created (authority never
--      live), so Σ active holds is always 0; get_sv_account.total_cents is byte-unchanged today.
--   2. app.sv_allocate_spend (PURE, PS-0 §3): aggregate-proportional cross-operation FEFO
--      allocation. bonus_draw = floor(spend×total_bonus/total); paid_draw = spend-bonus_draw
--      (paid takes the remainder cent, business-favorable ≤1¢); consume lots FEFO within class.
--   3. app.sv_plan_refund (PURE, PS-0 §4 SF2): per-operation paid+bonus lot refund. Partial
--      non-final clawback = floor(bonus_rem×X/paid_rem); FINAL step (X==paid_rem) claws the
--      ENTIRE bonus_rem (terminal sweep - no stranded bonus cent).
--   4. app.sv_checkout_quote (PURE, INERT): what SV WOULD cover of a cart total. NO checkout
--      path consumes it while authority≠live (documented cutover integration point).
--   5. public.sv_reserve / sv_release: hold ledger (sv_reservations, append-only status).
--   6. public.sv_spend: allocate + one 'spend' movement per lot atomically, one-winner under
--      the per-account advisory lock + FEFO row locks.
--   7. public.sv_reverse_spend: restore-then-expire (PS-0 §6). Restores the exact lots a spend
--      drew; if a restored lot is now past its expiry_key, immediately writes a -expiry for the
--      restored amount. Bounded (over-reversal fails) + idempotent.
--   8. public.refund_sv_operation: SF2 per-op cash refund + bonus clawback.
--   9. public.sv_expire_due: owner/service sweep of lots past expiry_key (expire exactly
--      remaining; cannot expire spent/already-expired value; idempotent per lot).
--  10. sv_lot_movements per-kind SIGN checks (v61 deferred them to "their Increment-C write
--      paths" - now enforced): spend/expiry/refund/clawback < 0, reversal > 0. correction is ±.
--
-- CHECKOUT KERNEL: UNCHANGED. ps1c_plan_checkout / record_cart_sale / evaluate_checkout are NOT
--   redefined here (proven byte-unchanged by the ps0-no-executor "checkout kernel byte-unchanged
--   by PS-2 increments" tripwire). Stored-value tender stays inert (sv_checkout_quote computes,
--   nothing consumes). points_ledger / credit_ledger / gift_cards / benefit_registry untouched.

begin;

-- =====================================================================
-- 1. sv_reservations - the append-only HOLD ledger. A reservation subtracts from available
--    balance (contract: available = Σ movements - Σ active holds) so a concurrent spend cannot
--    consume held value. Status is a one-way active -> consumed|released ('consumed' is the
--    FUTURE cutover transition where a checkout reservation is turned into a spend; the PS-2A
--    sv_spend operates on available balance and never consumes a specific hold). NO mutable
--    balance column (amount_cents is the immutable hold size). Owner+SA read; zero browser DML.
-- =====================================================================
create table public.sv_reservations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  account_id uuid not null,
  operation_id uuid not null,
  amount_cents integer not null check (amount_cents > 0),
  status text not null default 'active' check (status in ('active', 'consumed', 'released')),
  released_by_operation_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sv_reservations_id_business_uk unique (id, business_id),
  constraint sv_reservations_account_fk foreign key (account_id, business_id)
    references public.sv_accounts(id, business_id) on delete restrict,
  constraint sv_reservations_operation_fk foreign key (operation_id, business_id)
    references public.sv_operations(id, business_id) on delete restrict,
  constraint sv_reservations_release_op_fk foreign key (released_by_operation_id, business_id)
    references public.sv_operations(id, business_id) on delete restrict
);
create index sv_reservations_account_idx on public.sv_reservations (business_id, account_id, status);
create index sv_reservations_operation_idx on public.sv_reservations (business_id, operation_id);

-- Guard: identity + amount immutable; status is a one-way active -> consumed|released; no DELETE.
create or replace function app.sv_reservations_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'sv_reservations rows are permanent (append-only holds)' using errcode = 'restrict_violation';
  end if;
  if new.id is distinct from old.id or new.business_id is distinct from old.business_id
     or new.account_id is distinct from old.account_id or new.operation_id is distinct from old.operation_id
     or new.amount_cents is distinct from old.amount_cents or new.created_at is distinct from old.created_at then
    raise exception 'sv_reservations identity and economics are immutable' using errcode = 'restrict_violation';
  end if;
  if new.status not in ('active', 'consumed', 'released') then
    raise exception 'sv_reservations status must be active/consumed/released' using errcode = 'restrict_violation';
  end if;
  -- terminal is terminal: a non-active reservation can never change status again.
  if old.status <> 'active' and new.status is distinct from old.status then
    raise exception 'sv_reservations is already % (holds are single-transition)', old.status using errcode = 'restrict_violation';
  end if;
  return new;
end $$;
revoke all on function app.sv_reservations_guard() from public, anon, authenticated;
create trigger sv_reservations_guard
  before update or delete on public.sv_reservations
  for each row execute function app.sv_reservations_guard();

alter table public.sv_reservations enable row level security;
create policy sv_reservations_owner_read on public.sv_reservations for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_reservations_sa_read on public.sv_reservations for select to authenticated using (app.is_super_admin());
revoke all on public.sv_reservations from public, anon, authenticated;
grant select on public.sv_reservations to authenticated;

-- =====================================================================
-- 2. sv_lot_movements per-kind SIGN checks. v61 shipped only the issue>0 / bad_debt=0 rules and
--    deferred "the remaining kinds sign matrix ... to their Increment-C write paths." Increment
--    C writes spend/expiry/refund/clawback (all draws, < 0) and reversal (restore, > 0); 'correction'
--    stays free (±, PS-0 §6 both directions). These CHECKs harden every future write path, not
--    just the RPCs below. Fresh replay has only 'issue' rows, so adding them is safe.
-- =====================================================================
alter table public.sv_lot_movements
  add constraint sv_lot_movements_spend_negative    check (kind <> 'spend'    or cents < 0),
  add constraint sv_lot_movements_expiry_negative   check (kind <> 'expiry'   or cents < 0),
  add constraint sv_lot_movements_reversal_positive check (kind <> 'reversal' or cents > 0),
  add constraint sv_lot_movements_refund_negative   check (kind <> 'refund'   or cents < 0),
  add constraint sv_lot_movements_clawback_negative check (kind <> 'clawback' or cents < 0);

-- =====================================================================
-- 3. app.sv_available_balance - CREATE OR REPLACE (minimal diff): available balance now nets out
--    ACTIVE reservation holds. PS-0/contract: available = Σ movements - Σ active reservations. In
--    PS-2A no reservation can exist (authority is never 'live'), so this is byte-equivalent to
--    the v61 body today; get_sv_account.total_cents is unchanged. When authority is 'live' (only
--    ever inside a rolled-back test shim), a hold reduces spendable available.
-- =====================================================================
create or replace function app.sv_available_balance(p_business uuid, p_account uuid)
returns integer language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select (
    coalesce((select sum(m.cents) from public.sv_lot_movements m
               where m.business_id = p_business and m.account_id = p_account), 0)
    - coalesce((select sum(r.amount_cents) from public.sv_reservations r
                 where r.business_id = p_business and r.account_id = p_account and r.status = 'active'), 0)
  )::integer
$$;
revoke all on function app.sv_available_balance(uuid, uuid) from public, anon, authenticated;

-- =====================================================================
-- 4. app.sv_allocate_spend - PURE planner (NO authority gate, NO DML). PS-0 §3 EXACTLY.
--    total_paid = Σ remaining(paid lots, all ops); total_bonus = Σ remaining(bonus); total = sum.
--    Reject spend > total (or spend < 1). bonus_draw = floor(spend×total_bonus/total) computed in
--    bigint (product ≤ 2^62); paid_draw = spend - bonus_draw (paid takes the remainder cent).
--    Within each class consume lots FEFO across operations: expiry_key asc NULLS LAST -> earned_seq
--    asc -> lot id asc; never over-drawing a lot. Returns {ok, paid_draw, bonus_draw, plan:[{lot_id,
--    class, kind:'spend', cents<0}...]}. The caller writes one 'spend' movement per plan entry.
-- =====================================================================
create or replace function app.sv_allocate_spend(p_business uuid, p_account uuid, p_spend_cents integer)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_total_paid bigint;
  v_total_bonus bigint;
  v_total bigint;
  v_bonus_draw bigint;
  v_paid_draw bigint;
  v_plan jsonb := '[]'::jsonb;
  v_left bigint;
  v_take bigint;
  r record;
begin
  if p_spend_cents is null or p_spend_cents < 1 then
    return jsonb_build_object('ok', false, 'reason', 'spend must be a whole number of at least 1 cent');
  end if;

  select coalesce(sum(case when l.class = 'paid'  then m.cents else 0 end), 0),
         coalesce(sum(case when l.class = 'bonus' then m.cents else 0 end), 0)
    into v_total_paid, v_total_bonus
    from public.sv_lot_movements m
    join public.sv_lots l on l.id = m.lot_id and l.business_id = m.business_id
   where m.business_id = p_business and m.account_id = p_account;
  v_total := v_total_paid + v_total_bonus;

  if p_spend_cents > v_total then
    return jsonb_build_object('ok', false, 'reason', 'insufficient stored value',
      'total_paid_cents', v_total_paid, 'total_bonus_cents', v_total_bonus, 'total_cents', v_total);
  end if;

  -- PS-0 §3: floor on bonus; paid keeps the remainder cent. total > 0 here (spend >= 1 <= total).
  v_bonus_draw := (p_spend_cents::bigint * v_total_bonus) / v_total;
  v_paid_draw := p_spend_cents - v_bonus_draw;

  -- paid class FEFO
  v_left := v_paid_draw;
  for r in
    select l.id as lot_id, app.sv_lot_remaining(l.id) as remaining
      from public.sv_lots l
     where l.business_id = p_business and l.account_id = p_account and l.class = 'paid'
     order by l.expiry_key asc nulls last, l.earned_seq asc, l.id asc
  loop
    exit when v_left <= 0;
    if r.remaining <= 0 then continue; end if;
    v_take := least(v_left, r.remaining);
    v_plan := v_plan || jsonb_build_array(jsonb_build_object(
      'lot_id', r.lot_id, 'class', 'paid', 'kind', 'spend', 'cents', (-v_take)::int));
    v_left := v_left - v_take;
  end loop;
  if v_left <> 0 then
    return jsonb_build_object('ok', false, 'reason', 'could not fully allocate the paid class');
  end if;

  -- bonus class FEFO
  v_left := v_bonus_draw;
  for r in
    select l.id as lot_id, app.sv_lot_remaining(l.id) as remaining
      from public.sv_lots l
     where l.business_id = p_business and l.account_id = p_account and l.class = 'bonus'
     order by l.expiry_key asc nulls last, l.earned_seq asc, l.id asc
  loop
    exit when v_left <= 0;
    if r.remaining <= 0 then continue; end if;
    v_take := least(v_left, r.remaining);
    v_plan := v_plan || jsonb_build_array(jsonb_build_object(
      'lot_id', r.lot_id, 'class', 'bonus', 'kind', 'spend', 'cents', (-v_take)::int));
    v_left := v_left - v_take;
  end loop;
  if v_left <> 0 then
    return jsonb_build_object('ok', false, 'reason', 'could not fully allocate the bonus class');
  end if;

  return jsonb_build_object(
    'ok', true,
    'paid_draw', v_paid_draw::int,
    'bonus_draw', v_bonus_draw::int,
    'total_paid_cents', v_total_paid::int,
    'total_bonus_cents', v_total_bonus::int,
    'total_cents', v_total::int,
    'plan', v_plan);
end $$;
revoke all on function app.sv_allocate_spend(uuid, uuid, integer) from public, anon, authenticated;

-- =====================================================================
-- 5. app.sv_plan_refund - PURE planner (NO authority gate, NO DML). PS-0 §4 SF2, per top-up op.
--    Locate the operations single paid lot (+ optional bonus lot). paid_rem/bonus_rem from Σ
--    movements. p_cash_cents NULL or >= paid_rem => whole-op (X = paid_rem, final). Else partial
--    X = p_cash_cents (X < paid_rem). clawback: FINAL step = bonus_rem (terminal sweep, no
--    stranded cent); non-final = floor(bonus_rem × X / paid_rem). Returns {ok, cash_cents,
--    clawback_cents, final, plan:[{lot_id,class,kind:'refund'|'clawback', cents<0}...]}.
-- =====================================================================
create or replace function app.sv_plan_refund(p_business uuid, p_topup_operation uuid, p_cash_cents integer)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_paid_lot uuid;
  v_bonus_lot uuid;
  v_paid_rem bigint;
  v_bonus_rem bigint;
  v_x bigint;
  v_clawback bigint;
  v_final boolean;
  v_plan jsonb := '[]'::jsonb;
begin
  if p_cash_cents is not null and p_cash_cents < 0 then
    return jsonb_build_object('ok', false, 'reason', 'a refund amount cannot be negative');
  end if;

  select id into v_paid_lot from public.sv_lots
   where business_id = p_business and operation_id = p_topup_operation and class = 'paid'
   order by earned_seq asc, id asc limit 1;
  if v_paid_lot is null then
    return jsonb_build_object('ok', false, 'reason', 'operation has no paid lot to refund');
  end if;
  select id into v_bonus_lot from public.sv_lots
   where business_id = p_business and operation_id = p_topup_operation and class = 'bonus'
   order by earned_seq asc, id asc limit 1;

  v_paid_rem := app.sv_lot_remaining(v_paid_lot);
  v_bonus_rem := coalesce(app.sv_lot_remaining(v_bonus_lot), 0);

  -- Whole-op when cash is unspecified or >= paid remaining (contract: null/>=paid_rem = whole-op).
  v_final := (p_cash_cents is null) or (p_cash_cents >= v_paid_rem);
  v_x := case when v_final then v_paid_rem else p_cash_cents end;

  -- PS-0 §4: X <= paid_rem always holds (partial branch has X < paid_rem; final branch X = paid_rem).
  if v_x > v_paid_rem then
    return jsonb_build_object('ok', false, 'reason', 'refund exceeds the operation paid remaining');
  end if;

  if v_final then
    v_clawback := v_bonus_rem;                                          -- terminal sweep (requirement 2)
  elsif v_paid_rem = 0 then
    v_clawback := v_bonus_rem;                                          -- defensive (final would have fired)
  else
    v_clawback := (v_bonus_rem * v_x) / v_paid_rem;                     -- floor on bonus (non-final)
  end if;

  if v_x > 0 then
    v_plan := v_plan || jsonb_build_array(jsonb_build_object(
      'lot_id', v_paid_lot, 'class', 'paid', 'kind', 'refund', 'cents', (-v_x)::int));
  end if;
  if v_clawback > 0 and v_bonus_lot is not null then
    v_plan := v_plan || jsonb_build_array(jsonb_build_object(
      'lot_id', v_bonus_lot, 'class', 'bonus', 'kind', 'clawback', 'cents', (-v_clawback)::int));
  end if;

  return jsonb_build_object(
    'ok', true,
    'cash_cents', v_x::int,
    'clawback_cents', v_clawback::int,
    'final', v_final,
    'paid_lot', v_paid_lot,
    'bonus_lot', v_bonus_lot,
    'paid_remaining_cents', v_paid_rem::int,
    'bonus_remaining_cents', v_bonus_rem::int,
    'plan', v_plan);
end $$;
revoke all on function app.sv_plan_refund(uuid, uuid, integer) from public, anon, authenticated;

-- =====================================================================
-- 6. app.sv_checkout_quote - PURE, INERT shadow. Returns what stored value WOULD cover of a cart
--    total (min(available, cart_total)) and the residual cash due. spendable is ALWAYS the live
--    check (false in PS-2A). *** FUTURE CUTOVER INTEGRATION POINT ***: at cutover, the checkout
--    kernel finaliser (public.record_cart_sale) would, for an authority='live' tenant, call this
--    to size an sv tender then invoke public.sv_spend for that amount under the same transaction,
--    writing an sv 'spend' alongside the sale. NOTHING consumes this in PS-2A - it is computed and
--    never applied while authority≠live, so the checkout financial logic stays byte-unchanged.
-- =====================================================================
create or replace function app.sv_checkout_quote(p_business uuid, p_account uuid, p_cart_total_cents integer)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_state text;
  v_available integer;
  v_cover integer;
begin
  select coalesce(state, 'unbuilt') into v_state from public.sv_authority
   where business_id = p_business and asset = 'stored_value';
  v_state := coalesce(v_state, 'unbuilt');
  v_available := coalesce(app.sv_available_balance(p_business, p_account), 0);
  if p_cart_total_cents is null or p_cart_total_cents < 0 then
    return jsonb_build_object('ok', false, 'reason', 'cart total must be a non-negative integer');
  end if;
  v_cover := least(v_available, p_cart_total_cents);
  return jsonb_build_object(
    'ok', true,
    'authority_state', v_state,
    'spendable', (v_state = 'live'),
    'available_cents', v_available,
    'would_cover_cents', v_cover,
    'remaining_due_cents', greatest(p_cart_total_cents - v_cover, 0),
    'note', 'shadow quote only - no checkout path consumes stored-value tender while authority is not live');
end $$;
revoke all on function app.sv_checkout_quote(uuid, uuid, integer) from public, anon, authenticated;

-- =====================================================================
-- 7. public.sv_reserve - place a HOLD (contract). Owner-only; authority=live gated; idempotent
--    via sv_operations. Serialized on a per-account advisory xact lock (PS-0 §7) so concurrent
--    reserves/spends see consistent available. Refuses when cents exceed available. Serialized on available (post-hold).
-- =====================================================================
create or replace function public.sv_reserve(
  p_business uuid, p_account uuid, p_cents integer, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_hash text;
  v_existing public.sv_operations%rowtype;
  v_op uuid := gen_random_uuid();
  v_res uuid := gen_random_uuid();
  v_available integer;
  v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  -- HARD SAFETY GATE: value only moves when stored value is the authority (unreachable in PS-2A).
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value reserve idempotency key is required' using errcode = '22023';
  end if;
  if p_cents is null or p_cents < 1 then
    raise exception 'a stored-value reserve must be a whole number of at least 1 cent' using errcode = '22023';
  end if;
  if not exists (select 1 from public.sv_accounts a where a.id = p_account and a.business_id = p_business) then
    raise exception 'stored-value account does not belong to this business' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('v63:sv_acct:' || p_business::text || ':' || p_account::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('v63:sv_reserve:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'reserve' and o.idempotency_key = p_idempotency_key
   for update;
  v_hash := app.ps1b_sha256(jsonb_build_object(
    'op', 'reserve', 'business_id', p_business, 'account_id', p_account, 'cents', p_cents)::text);
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different stored-value reserve' using errcode = '22023';
    end if;
    return v_existing.result;
  end if;

  v_available := app.sv_available_balance(p_business, p_account);
  if p_cents > v_available then
    raise exception 'insufficient stored value to reserve (% requested, % available)', p_cents, v_available
      using errcode = '22023';
  end if;

  v_result := jsonb_build_object(
    'status', 'ok', 'operation_id', v_op, 'reservation_id', v_res, 'account_id', p_account,
    'amount_cents', p_cents, 'reservation_status', 'active',
    'available_after_cents', v_available - p_cents);

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'reserve', p_idempotency_key, v_hash, v_actor, v_result);
  insert into public.sv_reservations(id, business_id, account_id, operation_id, amount_cents, status)
  values (v_res, p_business, p_account, v_op, p_cents, 'active');
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_RESERVE', 'sv_reservations', v_res, jsonb_build_object(
    'operation_id', v_op, 'account_id', p_account, 'amount_cents', p_cents));

  return v_result;
end $$;
revoke all on function public.sv_reserve(uuid, uuid, integer, uuid) from public, anon, authenticated;
grant execute on function public.sv_reserve(uuid, uuid, integer, uuid) to authenticated;

-- =====================================================================
-- 8. public.sv_release - release an active HOLD (contract). Owner-only; authority=live gated;
--    idempotent. Returns the value to available balance. A release of an already-released hold
--    is an idempotent no-op; a consumed hold cannot be released.
-- =====================================================================
create or replace function public.sv_release(
  p_business uuid, p_reservation uuid, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_hash text;
  v_existing public.sv_operations%rowtype;
  v_op uuid := gen_random_uuid();
  v_row public.sv_reservations%rowtype;
  v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value release idempotency key is required' using errcode = '22023';
  end if;

  select * into v_row from public.sv_reservations
   where id = p_reservation and business_id = p_business for update;
  if not found then
    raise exception 'stored-value reservation not found in this business' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('v63:sv_acct:' || p_business::text || ':' || v_row.account_id::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('v63:sv_release:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'release' and o.idempotency_key = p_idempotency_key
   for update;
  v_hash := app.ps1b_sha256(jsonb_build_object(
    'op', 'release', 'business_id', p_business, 'reservation_id', p_reservation)::text);
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different stored-value release' using errcode = '22023';
    end if;
    return v_existing.result;
  end if;

  if v_row.status = 'released' then
    -- idempotent: already released, nothing to move.
    return jsonb_build_object('status', 'ok', 'reservation_id', p_reservation,
      'reservation_status', 'released', 'already_released', true);
  end if;
  if v_row.status = 'consumed' then
    raise exception 'stored-value reservation is already consumed and cannot be released' using errcode = '22023';
  end if;

  v_result := jsonb_build_object('status', 'ok', 'operation_id', v_op, 'reservation_id', p_reservation,
    'reservation_status', 'released', 'amount_cents', v_row.amount_cents, 'already_released', false);

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'release', p_idempotency_key, v_hash, v_actor, v_result);
  update public.sv_reservations
     set status = 'released', released_by_operation_id = v_op, updated_at = now()
   where id = p_reservation and business_id = p_business and status = 'active';
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_RELEASE', 'sv_reservations', p_reservation, jsonb_build_object(
    'operation_id', v_op, 'amount_cents', v_row.amount_cents));

  return v_result;
end $$;
revoke all on function public.sv_release(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.sv_release(uuid, uuid, uuid) to authenticated;

-- =====================================================================
-- 9. public.sv_spend - SPEND stored value (PS-0 §3). Owner-only; authority=live gated; idempotent.
--    One-winner concurrency: a per-account advisory xact lock (PS-0 §7) plus FOR UPDATE row locks
--    over the accounts lot set in FEFO order (deterministic -> no deadlock). Refuses when cents exceed available. Serialized on
--    available (post-reservation); on refusal writes NOTHING (no partial movement). Writes exactly
--    one 'spend' movement per lot the pure allocator plans.
-- =====================================================================
create or replace function public.sv_spend(
  p_business uuid, p_account uuid, p_cents integer, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_hash text;
  v_existing public.sv_operations%rowtype;
  v_op uuid := gen_random_uuid();
  v_available integer;
  v_plan jsonb;
  v_entry jsonb;
  v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value spend idempotency key is required' using errcode = '22023';
  end if;
  if p_cents is null or p_cents < 1 then
    raise exception 'a stored-value spend must be a whole number of at least 1 cent' using errcode = '22023';
  end if;
  if not exists (select 1 from public.sv_accounts a where a.id = p_account and a.business_id = p_business) then
    raise exception 'stored-value account does not belong to this business' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('v63:sv_acct:' || p_business::text || ':' || p_account::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('v63:sv_spend:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'spend' and o.idempotency_key = p_idempotency_key
   for update;
  v_hash := app.ps1b_sha256(jsonb_build_object(
    'op', 'spend', 'business_id', p_business, 'account_id', p_account, 'cents', p_cents)::text);
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different stored-value spend' using errcode = '22023';
    end if;
    return v_existing.result;   -- duplicate spend, same key -> ONE effect, replayed result
  end if;

  -- Deterministic FEFO row locks over the accounts lot set (one-winner; the fresh READ COMMITTED
  -- snapshot after the advisory lock + these locks sees a concurrent winning transaction committed movements).
  perform 1 from public.sv_lots l
   where l.business_id = p_business and l.account_id = p_account
   order by l.expiry_key asc nulls last, l.earned_seq asc, l.id asc
   for update;

  v_available := app.sv_available_balance(p_business, p_account);
  if p_cents > v_available then
    raise exception 'insufficient stored value to spend (% requested, % available)', p_cents, v_available
      using errcode = '22023';   -- refuse BEFORE any write: no partial movement
  end if;

  v_plan := app.sv_allocate_spend(p_business, p_account, p_cents);
  if (v_plan->>'ok')::boolean is not true then
    raise exception 'stored-value allocation failed: %', coalesce(v_plan->>'reason', 'unknown') using errcode = '22023';
  end if;

  v_result := jsonb_build_object(
    'status', 'ok', 'operation_id', v_op, 'account_id', p_account, 'spend_cents', p_cents,
    'paid_draw_cents', (v_plan->>'paid_draw')::int, 'bonus_draw_cents', (v_plan->>'bonus_draw')::int,
    'plan', v_plan->'plan', 'available_after_cents', v_available - p_cents);

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'spend', p_idempotency_key, v_hash, v_actor, v_result);
  for v_entry in select * from jsonb_array_elements(v_plan->'plan') loop
    insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
    values (p_business, p_account, (v_entry->>'lot_id')::uuid, v_op, 'spend', (v_entry->>'cents')::int);
  end loop;
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_SPEND', 'sv_accounts', p_account, jsonb_build_object(
    'operation_id', v_op, 'spend_cents', p_cents,
    'paid_draw_cents', (v_plan->>'paid_draw')::int, 'bonus_draw_cents', (v_plan->>'bonus_draw')::int));

  return v_result;
end $$;
revoke all on function public.sv_spend(uuid, uuid, integer, uuid) from public, anon, authenticated;
grant execute on function public.sv_spend(uuid, uuid, integer, uuid) to authenticated;

-- =====================================================================
-- 10. public.sv_reverse_spend - RESTORE-THEN-EXPIRE (PS-0 §6). Owner-only; authority=live gated;
--     idempotent. Restores the EXACT per-lot allocation the spend drew (a 'reversal' + per lot);
--     if a restored lot is now past its expiry_key, immediately writes a '-expiry' for the
--     restored amount (both recorded - an expired lot is never silently resurrected). A spend op
--     is fully reversible AT MOST ONCE: a second reverse under a DIFFERENT key fails (over-
--     reversal); the SAME key replays. Case (f) trail: issue+1200, spend-128, expiry-1072,
--     reversal+128, expiry-128 -> sums to 0.
-- =====================================================================
create or replace function public.sv_reverse_spend(
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
  v_spend_type text;
  v_restored jsonb := '[]'::jsonb;
  v_restored_total bigint := 0;
  v_reexpired_total bigint := 0;
  m record;
  v_amt bigint;
  v_expiry timestamptz;
  v_reexpired boolean;
  v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
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

  -- Compute the restore-then-expire plan FIRST (sv_operations is append-only/immutable, so the
  -- op row must be inserted ONCE with its final result before the movements it anchors).
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

  -- Apply: a 'reversal' (+) per lot, immediately followed by a '-expiry' when the restored lot
  -- is now past its expiry_key (restore-then-expire; an expired lot is never silently resurrected).
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
revoke all on function public.sv_reverse_spend(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.sv_reverse_spend(uuid, uuid, uuid) to authenticated;

-- =====================================================================
-- 11. public.refund_sv_operation - SF2 per-op cash refund (PS-0 §4). Owner-only; authority=live
--     gated; idempotent. p_cash_cents NULL or >= paid_rem => whole-op. Writes the paid 'refund'
--     (-X) and bonus 'clawback' (-clawback) movements from the pure planner.
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
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
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

  v_plan := app.sv_plan_refund(p_business, p_topup_operation, p_cash_cents);
  if (v_plan->>'ok')::boolean is not true then
    raise exception 'stored-value refund failed: %', coalesce(v_plan->>'reason', 'unknown') using errcode = '22023';
  end if;

  v_result := jsonb_build_object(
    'status', 'ok', 'operation_id', v_op, 'topup_operation_id', p_topup_operation, 'account_id', v_account,
    'cash_cents', (v_plan->>'cash_cents')::int, 'clawback_cents', (v_plan->>'clawback_cents')::int,
    'final', (v_plan->>'final')::boolean, 'plan', v_plan->'plan');

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'refund', p_idempotency_key, v_hash, v_actor, v_result);
  for v_entry in select * from jsonb_array_elements(v_plan->'plan') loop
    insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
    values (p_business, v_account, (v_entry->>'lot_id')::uuid, v_op, v_entry->>'kind', (v_entry->>'cents')::int);
  end loop;
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_REFUND', 'sv_accounts', v_account, jsonb_build_object(
    'operation_id', v_op, 'topup_operation_id', p_topup_operation,
    'cash_cents', (v_plan->>'cash_cents')::int, 'clawback_cents', (v_plan->>'clawback_cents')::int));

  return v_result;
end $$;
revoke all on function public.refund_sv_operation(uuid, uuid, integer, uuid) from public, anon, authenticated;
grant execute on function public.refund_sv_operation(uuid, uuid, integer, uuid) to authenticated;

-- =====================================================================
-- 12. public.sv_expire_due - owner/service EXPIRY sweep (PS-0 §6). Owner-only; authority=live
--     gated. For each lot past its expiry_key with remaining > 0 (Σ movements), writes a '-expiry'
--     of EXACTLY remaining. Cannot expire spent value (remaining already excludes it) nor
--     already-expired value (remaining 0 -> skipped). Idempotent per lot (a rerun finds remaining
--     0). Per-account advisory locks (acquired in account order) + FEFO row locks keep it
--     one-winner and deadlock-free vs concurrent spends.
-- =====================================================================
create or replace function public.sv_expire_due(p_business uuid, p_limit integer default 1000)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_op uuid := gen_random_uuid();
  v_limit integer := least(greatest(coalesce(p_limit, 1000), 1), 100000);
  v_acc uuid;
  l record;
  v_rem integer;
  v_expired_lots integer := 0;
  v_expired_cents bigint := 0;
  v_details jsonb := '[]'::jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;

  -- Serialize per touched account (ascending order -> deadlock-free vs per-account spend locks).
  for v_acc in
    select distinct l2.account_id from public.sv_lots l2
     where l2.business_id = p_business and l2.expiry_key is not null and l2.expiry_key <= now()
     order by l2.account_id
  loop
    perform pg_advisory_xact_lock(hashtextextended('v63:sv_acct:' || p_business::text || ':' || v_acc::text, 0));
  end loop;

  -- Compute the sweep plan under FOR UPDATE row locks (sv_operations is append-only, so the anchor
  -- op is inserted ONCE with its final result). Locking the candidate lots holds them for the txn.
  for l in
    select ll.id as lot_id, ll.account_id
      from public.sv_lots ll
     where ll.business_id = p_business and ll.expiry_key is not null and ll.expiry_key <= now()
     order by ll.account_id, ll.expiry_key asc, ll.earned_seq asc, ll.id asc
     for update
  loop
    exit when v_expired_lots >= v_limit;
    v_rem := app.sv_lot_remaining(l.lot_id);
    if v_rem is null or v_rem <= 0 then continue; end if;   -- spent / already-expired -> skip
    v_expired_lots := v_expired_lots + 1;
    v_expired_cents := v_expired_cents + v_rem;
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'lot_id', l.lot_id, 'account_id', l.account_id, 'expired_cents', v_rem));
  end loop;

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'expire', gen_random_uuid(),
    app.ps1b_sha256(jsonb_build_object('op', 'expire', 'business_id', p_business, 'at', now())::text),
    v_actor, jsonb_build_object('status', 'ok', 'expired_lots', v_expired_lots,
      'expired_cents', v_expired_cents::int, 'details', v_details));

  for l in select value from jsonb_array_elements(v_details) as t(value) loop
    insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
    values (p_business, (l.value->>'account_id')::uuid, (l.value->>'lot_id')::uuid, v_op, 'expiry',
      (-(l.value->>'expired_cents')::int)::int);
  end loop;

  if v_expired_lots > 0 then
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'SV_EXPIRE_SWEEP', 'sv_accounts', v_op, jsonb_build_object(
      'operation_id', v_op, 'expired_lots', v_expired_lots, 'expired_cents', v_expired_cents::int));
  end if;

  return jsonb_build_object('status', 'ok', 'operation_id', v_op,
    'expired_lots', v_expired_lots, 'expired_cents', v_expired_cents::int, 'details', v_details);
end $$;
revoke all on function public.sv_expire_due(uuid, integer) from public, anon, authenticated;
grant execute on function public.sv_expire_due(uuid, integer) to authenticated;

commit;
