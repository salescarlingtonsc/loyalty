-- FRENLY v67 - PS-2 LIVE INCREMENT: STORED VALUE AS CHECKOUT-KERNEL TENDER (DB layer)
--
-- Implements directive §4/§5 of the RELEASE APPROVED pilot mandate. Pinned contract:
-- docs/design/ps2/PS2_LIVE_V67_CHECKOUT_TENDER_CONTRACT.md. Forward-only; v61-v66b untouched in
-- behaviour. v67 WIRES the EXISTING v63 spend engine (sv_reserve/sv_release/sv_spend +
-- app.sv_allocate_spend/sv_available_balance/sv_checkout_quote) into the EXISTING PS-1C checkout
-- kernel (evaluate_checkout/5 + record_cart_sale/9) as a TENDER. It builds NO new spend
-- arithmetic, NO new mint path (record_sv_topup_sale stays the ONLY mint), NO cutover, NO customer
-- self-service. Real SV spend remains structurally UNREACHABLE: reserve/spend still refuse unless
-- authority='live' (v66 live-state gates stand; prod authority stays 'unbuilt').
--
-- WHAT v67 ADDS (all reuse-first):
--   1. checkout_sv_tenders - append-only binding of a checkout evaluation TOKEN to ONE v63
--      reservation, and (at finalisation) to the v63 sv_spend that consumes it. Owner+SA read;
--      zero browser DML.
--   2. app.sv_reserve_core / app.sv_spend_core / app.sv_release_core - the v64/v63 reserve/spend/
--      release BODIES minus the owner check, extracted so BOTH the owner-facing public RPCs AND
--      the till checkout path (create_sales, contract §5: no extra grant) drive the SAME engine.
--      NO parallel allocation/spend/balance code - allocation stays app.sv_allocate_spend, balance
--      stays app.sv_available_balance. The public sv_reserve/sv_spend/sv_release are CREATE OR
--      REPLACEd to KEEP the owner check then delegate to their core; owner-facing behaviour is
--      byte-identical (owner-only, same authority-live + pause gates, same idempotency, same result).
--   3. public.reserve_checkout_sv_tender - the till "opt into stored value" step. create_sales +
--      can_see_branch + tenant only. Gated (authority live, synthetic-on-live refused, redeem
--      pause, currency). Reserves amount = min(requested, available, token total) via
--      app.sv_reserve_core, bound to the token; supersedes any prior active tender for the account
--      (re-evaluation atomically releases the prior reservation and creates the new one).
--   4. evaluate_checkout/5 - CREATE OR REPLACE, single delta: the OK responses (fresh + replay)
--      carry a server-authoritative stored_value quote block (authority_state, spendable=(live),
--      available_cents, would_cover_cents) so the UI can show "Use stored value" ONLY when the
--      server reports spendable balance > 0. Nothing else changes; no new persisted column.
--   5. record_cart_sale/9 - CREATE OR REPLACE, single delta: when an active tender is bound to the
--      token, INSIDE the same atomic transaction it releases the reservation and consumes it via
--      app.sv_spend_core (paid/bonus split per PS-0), records tender evidence, and records only the
--      non-SV remainder as a payment (no cash double-count: the top-up already collected the cash).
--      The sale row is the FULL discounted total through the existing finaliser (legacy earn
--      unchanged). All SV gates re-validated after the token lock (TOCTOU).
--   6. public.sv_release_expired_checkout_tenders - owner/service sweep that releases (via
--      app.sv_release_core) reservations bound to expired/consumed-by-another tokens. No new cron.
--   7. TWO TYPED REVERSAL REFUSALS (§11): unwinding an sv-tendered checkout is OUT OF v67 SCOPE
--      (coherent stored-value restitution is the v68 refund/reversal matrix), so v67 makes BOTH
--      halves REFUSE rather than silently mis-settle. §11a gates the SALE leg in
--      public.reverse_sale_v20_base - the money core every reversal entry point funnels through;
--      §11b gates the SETTLEMENT leg in public.sv_reverse_spend, which reverses a spend OPERATION
--      directly and therefore never passes through the sale core at all. Both use the v49a
--      pg_get_functiondef splice idiom.
--
-- STANDING RULE FOR EVERY pg_get_functiondef SPLICE IN THIS REPO (learned the hard way at v67
-- rev-4/rev-5): a splice needle MUST anchor on COMMENT-FREE code, and it MUST be validated
-- against PRODUCTION's live catalog (pg_get_functiondef on the target) before the migration is
-- frozen. The local rehearsal chain is replayed from repo files through psql, which preserves
-- comments verbatim; PRODUCTION was built through the Supabase MCP `apply_migration`, which
-- CONDENSES `--` comments out of large function bodies (observed on v66's record_sv_topup_sale
-- and across the v60 wave). The rehearsal DB is therefore NOT byte-faithful to prod for function
-- bodies. A comment-anchored needle passes every local gate and then matches ZERO times in prod,
-- raising `unexpected <fn> predecessor definition (needle occurrences: 0)` and rolling back the
-- ENTIRE migration - which is exactly what rev-4's §11b needle would have done. No amount of local
-- rehearsal catches this; only a prod catalog read does. The rule is machine-enforced by
-- tests/phase0-foundation/pending-migration-hardening-guards.test.mjs (GUARD 3) and rehearsed by
-- db/tests/v67_prod_shape_splice.sh, which strips the comments out of the predecessor body to
-- reproduce the production shape before applying v67.
--
-- SAFETY: applying v67 to a clean chain creates ZERO sv_lots/sv_lot_movements/sv_topup_payments/
-- reservations/tenders. Reservations NEVER write sv_lot_movements; app.sv_total_outstanding is
-- unchanged by reserve/release. The v66 mint tripwire (only record_sv_topup_sale mints a paid lot)
-- still holds - v67 adds no minter.
--
-- ACCOUNTING (§10, grounded in v11b/v20 + PS-0 §4/§8): an sv-tendered checkout finalises the parent
-- sale at the FULL discounted total with p_paid=false, so record_quick_sale writes NO full-amount
-- payment (no cash double-count); only the non-sv cash remainder is a public.payments row. The sv
-- portion writes NO payment (spending stored value collects no new cash - that cash was taken at
-- top-up and stays a liability in sv_topup_payments). checkout_sv_tenders (status='consumed') is the
-- SETTLEMENT MARKER, and public.sale_balance + public.get_revenue_summary are re-created (CREATE OR REPLACE) to
-- read it so an sv sale is NOT phantom accounts-receivable (balance nets to 0, payment_status='paid')
-- and is cash-basis revenue (revenue_cash == accrual), while cash_collected excludes the sv portion.
-- Non-sv sales are byte-unchanged. Paid/bonus revenue split is recorded on the tender for a future
-- contra-revenue increment (PS-0 "bonus is promotional exposure, never revenue"), documented not invented.
-- Both §10 surfaces read the settlement marker WITHOUT netting it out against a reversal; that is sound
-- only because §11 makes an sv settlement unreversible from BOTH directions - §11a refuses reversing the
-- SALE (public.reverse_sale_v20_base) and §11b refuses reversing the SETTLEMENT SPEND
-- (public.sv_reverse_spend, which bypasses the sale core entirely). Lifting EITHER refusal in v68
-- REQUIRES netting the settlement legs out of sale_balance.sv_tender_totals AND
-- get_revenue_summary.v_sv_cash in the same increment.

begin;

-- =====================================================================
-- 1. checkout_sv_tenders - append-only binding TOKEN <-> reservation <-> spend. One ACTIVE
--    ('reserved') tender per (business, account) via a partial unique index (a customer has one
--    checkout SV hold at a time); superseded tenders go 'released', consumed ones go 'consumed'.
--    Identity + economics immutable; status is a one-way reserved -> consumed|released. Owner+SA
--    read; browser writes revoked (definer RPCs only).
-- =====================================================================
create table public.checkout_sv_tenders (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  evaluation_id uuid not null,
  account_id uuid not null,
  reservation_id uuid not null,
  reserve_operation_id uuid not null,
  idempotency_key uuid not null,
  requested_cents integer not null check (requested_cents > 0),
  reserved_cents integer not null check (reserved_cents > 0),
  currency text not null,
  status text not null default 'reserved' check (status in ('reserved', 'consumed', 'released')),
  spend_operation_id uuid,
  sale_id uuid,
  sv_paid_cents integer,
  sv_bonus_cents integer,
  cash_remainder_cents integer,
  released_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint checkout_sv_tenders_id_business_uk unique (id, business_id),
  constraint checkout_sv_tenders_reservation_uk unique (reservation_id),
  constraint checkout_sv_tenders_eval_fk foreign key (evaluation_id, business_id)
    references public.checkout_evaluations(id, business_id) on delete restrict,
  constraint checkout_sv_tenders_account_fk foreign key (account_id, business_id)
    references public.sv_accounts(id, business_id) on delete restrict,
  constraint checkout_sv_tenders_reservation_fk foreign key (reservation_id, business_id)
    references public.sv_reservations(id, business_id) on delete restrict,
  constraint checkout_sv_tenders_reserve_op_fk foreign key (reserve_operation_id, business_id)
    references public.sv_operations(id, business_id) on delete restrict,
  constraint checkout_sv_tenders_spend_op_fk foreign key (spend_operation_id, business_id)
    references public.sv_operations(id, business_id) on delete restrict,
  constraint checkout_sv_tenders_sale_fk foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete restrict
);
-- One ACTIVE (reserved) tender per (business, account): a customer holds at most one checkout SV
-- reservation at a time; the bind RPC releases any prior before creating a new one.
create unique index checkout_sv_tenders_active_uk
  on public.checkout_sv_tenders (business_id, account_id) where status = 'reserved';
create index checkout_sv_tenders_eval_idx on public.checkout_sv_tenders (business_id, evaluation_id, status);
create index checkout_sv_tenders_business_idx on public.checkout_sv_tenders (business_id, created_at);
-- One SETTLEMENT per sale and per spend operation. A 'consumed' row is the settlement marker §10
-- reads as "paid + realised cash revenue" and §11 reads as "unreversible", and BOTH read it 1:1:
-- §11a asks "is there a consumed tender for THIS sale", §11b "for THIS spend operation". The guard
-- trigger above enforces that a consumed row carries BOTH bindings, but not that no OTHER consumed
-- row already claims the same sale or the same spend operation - so a direct service_role UPDATE
-- could consume a second reserved tender onto an ALREADY-settled sale + spend op and INFLATE
-- sale_balance.sv_tender_totals / get_revenue_summary.v_sv_cash (observed on the rev-4 chain:
-- sv_settled_cents 5000 -> 6000, revenue_cash with it). These two partial unique indexes make the
-- 1:1 STRUCTURAL rather than a convention the readers assume. Neither can fire on the legitimate
-- path: record_cart_sale consumes exactly ONE tender per invocation and that invocation creates
-- exactly ONE new sale, so a consumed row's (sale_id, spend_operation_id) pair is fresh by
-- construction. Both are partial on status='consumed', so reserved/released rows (whose bindings
-- are NULL) are outside the index entirely.
create unique index checkout_sv_tenders_settled_spend_uk
  on public.checkout_sv_tenders (business_id, spend_operation_id) where status = 'consumed';
create unique index checkout_sv_tenders_settled_sale_uk
  on public.checkout_sv_tenders (business_id, sale_id) where status = 'consumed';

-- Guard: identity + economics immutable; status is a one-way reserved -> consumed|released; no
-- DELETE. Terminal (consumed|released) is frozen INCLUDING its settlement bindings.
--
-- The settlement columns (status, sale_id, spend_operation_id) are what §10 and §11 read to decide
-- that a sale is settled, cash-basis revenue and unreversible. Leaving them out of the immutability
-- list made that correctness ACL-dependent (safe only because `authenticated` holds no UPDATE grant)
-- rather than trigger-enforced; a future grant, a definer helper, or a service-role write would have
-- been able to flip 'consumed' back to 'reserved' or re-point sale_id at another sale. The trigger
-- now enforces the transition machine itself, in the same append-only spirit as the rest of the
-- chain: reserved -> consumed | released is the ONLY move, terminal rows never move again, and
-- sale_id / spend_operation_id are WRITE-ONCE - settable exactly on the reserved -> consumed
-- settlement, null on every other shape, and frozen thereafter.
create or replace function app.checkout_sv_tenders_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'checkout_sv_tenders is append-only (bindings are permanent)' using errcode = 'restrict_violation';
  end if;
  if new.id is distinct from old.id or new.business_id is distinct from old.business_id
     or new.evaluation_id is distinct from old.evaluation_id or new.account_id is distinct from old.account_id
     or new.reservation_id is distinct from old.reservation_id
     or new.reserve_operation_id is distinct from old.reserve_operation_id
     or new.idempotency_key is distinct from old.idempotency_key
     or new.requested_cents is distinct from old.requested_cents
     or new.reserved_cents is distinct from old.reserved_cents
     or new.currency is distinct from old.currency or new.created_at is distinct from old.created_at then
    raise exception 'checkout_sv_tenders identity and economics are immutable' using errcode = 'restrict_violation';
  end if;
  if new.status not in ('reserved', 'consumed', 'released') then
    raise exception 'checkout_sv_tenders status must be reserved/consumed/released' using errcode = 'restrict_violation';
  end if;
  if old.status <> 'reserved' and new.status is distinct from old.status then
    raise exception 'checkout_sv_tenders is already % (single-transition)', old.status using errcode = 'restrict_violation';
  end if;
  if old.status <> 'reserved' then
    -- Terminal: the settlement bindings §10/§11 read are frozen with the status.
    if new.sale_id is distinct from old.sale_id
       or new.spend_operation_id is distinct from old.spend_operation_id then
      raise exception 'checkout_sv_tenders is already % (settlement bindings are frozen)', old.status
        using errcode = 'restrict_violation';
    end if;
  elsif new.status = 'consumed' then
    -- The ONE transition that may write them, and it must write BOTH.
    if old.sale_id is not null or old.spend_operation_id is not null then
      raise exception 'checkout_sv_tenders sale/spend bindings are write-once' using errcode = 'restrict_violation';
    end if;
    if new.sale_id is null or new.spend_operation_id is null then
      raise exception 'a consumed checkout_sv_tender must record both its sale and its spend operation'
        using errcode = 'restrict_violation';
    end if;
  else
    -- Still reserved, or reserved -> released: nothing settled, so nothing binds.
    if new.sale_id is not null or new.spend_operation_id is not null then
      raise exception 'only a consumed checkout_sv_tender may bind a sale and a spend operation'
        using errcode = 'restrict_violation';
    end if;
  end if;
  return new;
end $$;
revoke all on function app.checkout_sv_tenders_guard() from public, anon, authenticated;
create trigger checkout_sv_tenders_guard
  before update or delete on public.checkout_sv_tenders
  for each row execute function app.checkout_sv_tenders_guard();

alter table public.checkout_sv_tenders enable row level security;
create policy checkout_sv_tenders_owner_read on public.checkout_sv_tenders for select to authenticated using (app.is_salon_owner(business_id));
create policy checkout_sv_tenders_sa_read on public.checkout_sv_tenders for select to authenticated using (app.is_super_admin());
-- view_finance staff must read the settlement marker so the security_invoker sale_balance view (§10)
-- nets an sv-tendered sale to zero for them too (not just owners); definer reports bypass RLS anyway.
create policy checkout_sv_tenders_finance_read on public.checkout_sv_tenders for select to authenticated using (app.has_perm(business_id, 'view_finance'));
revoke all on public.checkout_sv_tenders from public, anon, authenticated;
grant select on public.checkout_sv_tenders to authenticated;

-- =====================================================================
-- 2. app.sv_reserve_core - the v64 public.sv_reserve body MINUS the owner check. The owner-facing
--    sv_reserve keeps its owner check and delegates here; the till checkout path (create_sales)
--    calls this core directly (contract §5: spending SV at the till needs no extra grant). The
--    authority='live' gate + redeem pause gate + validation + idempotency + advisory locks +
--    inserts are IDENTICAL to v64 - only the owner check moves up to the public wrapper.
-- =====================================================================
create or replace function app.sv_reserve_core(
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
  -- HARD SAFETY GATE: value only moves when stored value is the authority (unreachable in prod).
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;

  -- Redeem pause gate (an active 'all' or 'redeem' sv_pause blocks spends/reservations).
  if app.sv_pause_active(p_business, 'stored_value', 'redeem') then
    raise exception 'sv_paused: stored-value redemptions are paused' using errcode = '22023';
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
revoke all on function app.sv_reserve_core(uuid, uuid, integer, uuid) from public, anon, authenticated;

-- public.sv_reserve - owner check preserved, then delegate to the shared core (behaviour identical).
create or replace function public.sv_reserve(
  p_business uuid, p_account uuid, p_cents integer, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  return app.sv_reserve_core(p_business, p_account, p_cents, p_idempotency_key);
end $$;
revoke all on function public.sv_reserve(uuid, uuid, integer, uuid) from public, anon, authenticated;
grant execute on function public.sv_reserve(uuid, uuid, integer, uuid) to authenticated;

-- =====================================================================
-- 3. app.sv_spend_core - the v64 public.sv_spend body MINUS the owner check. Same authority-live +
--    redeem pause gates, same FEFO one-winner locks, same app.sv_allocate_spend (PS-0) plan, same
--    idempotency + result. Only the owner check moves up to the public wrapper.
-- =====================================================================
create or replace function app.sv_spend_core(
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
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;

  -- Redeem pause gate (an active 'all' or 'redeem' sv_pause blocks spends/reservations).
  if app.sv_pause_active(p_business, 'stored_value', 'redeem') then
    raise exception 'sv_paused: stored-value redemptions are paused' using errcode = '22023';
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
revoke all on function app.sv_spend_core(uuid, uuid, integer, uuid) from public, anon, authenticated;

create or replace function public.sv_spend(
  p_business uuid, p_account uuid, p_cents integer, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  return app.sv_spend_core(p_business, p_account, p_cents, p_idempotency_key);
end $$;
revoke all on function public.sv_spend(uuid, uuid, integer, uuid) from public, anon, authenticated;
grant execute on function public.sv_spend(uuid, uuid, integer, uuid) to authenticated;

-- =====================================================================
-- 4. app.sv_release_core - the v63 public.sv_release body MINUS the owner check. sv_release is
--    DELIBERATELY not pause-gated (contract D §8: release returns held value, it is the redeem
--    redeem-family undo, never a new redemption). Same authority-live gate, same idempotency,
--    same result. Only the owner check moves up to the public wrapper.
-- =====================================================================
create or replace function app.sv_release_core(
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
revoke all on function app.sv_release_core(uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public.sv_release(
  p_business uuid, p_reservation uuid, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  return app.sv_release_core(p_business, p_reservation, p_idempotency_key);
end $$;
revoke all on function public.sv_release(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.sv_release(uuid, uuid, uuid) to authenticated;

-- =====================================================================
-- 5. app.sv_tender_gate - the shared checkout-tender authority/synthetic/pause/currency gate,
--    applied at BIND and re-applied at FINALISATION after the token lock (TOCTOU, v66 pattern).
--    Raises a typed 22023 on any failure; returns the resolved business currency on success.
--    Definer, revoked from browsers.
-- =====================================================================
create or replace function app.sv_checkout_tender_gate(p_business uuid, p_client uuid, p_currency text)
returns text language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_state text;
  v_biz_synth boolean;
  v_client_synth boolean;
  v_biz_currency text;
begin
  select coalesce(state, 'unbuilt') into v_state from public.sv_authority
   where business_id = p_business and asset = 'stored_value';
  v_state := coalesce(v_state, 'unbuilt');
  if v_state <> 'live' then
    raise exception 'sv_not_live: stored value is not spendable for this business' using errcode = '22023';
  end if;
  -- Redeem pause gate (mirrors the spend engine; a clear typed message at the tender boundary).
  if app.sv_pause_active(p_business, 'stored_value', 'redeem') then
    raise exception 'sv_paused: stored-value redemptions are paused' using errcode = '22023';
  end if;
  select is_synthetic, currency into v_biz_synth, v_biz_currency from public.businesses where id = p_business;
  select is_synthetic into v_client_synth from public.clients where id = p_client and business_id = p_business;
  -- On a live business a synthetic entity may never transact (v66 rule).
  if coalesce(v_biz_synth, false) or coalesce(v_client_synth, false) then
    raise exception 'a synthetic entity cannot spend stored value on a live business' using errcode = '22023';
  end if;
  if p_currency is not null and upper(btrim(p_currency)) <> upper(coalesce(v_biz_currency, 'SGD')) then
    raise exception 'currency_mismatch: stored value must be spent in %', upper(coalesce(v_biz_currency, 'SGD')) using errcode = '22023';
  end if;
  return upper(coalesce(v_biz_currency, 'SGD'));
end $$;
revoke all on function app.sv_checkout_tender_gate(uuid, uuid, text) from public, anon, authenticated;

-- app.sv_evaluate_quote - the compact server-authoritative stored_value block for evaluate_checkout.
-- Resolves the client account (nullable) and reuses the v63 pure app.sv_checkout_quote. spendable
-- is ALWAYS the live check (false in prod), so the UI structurally never offers the tender there.
create or replace function app.sv_evaluate_quote(p_business uuid, p_client uuid, p_total_cents integer)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_account uuid;
  v_quote jsonb;
begin
  if p_client is not null then
    select id into v_account from public.sv_accounts
     where business_id = p_business and client_id = p_client and asset = 'stored_value';
  end if;
  v_quote := app.sv_checkout_quote(p_business, v_account, greatest(coalesce(p_total_cents, 0), 0));
  return jsonb_build_object(
    'authority_state', v_quote->>'authority_state',
    'spendable', (v_quote->>'spendable')::boolean,
    'available_cents', coalesce((v_quote->>'available_cents')::int, 0),
    'would_cover_cents', coalesce((v_quote->>'would_cover_cents')::int, 0),
    'remaining_due_cents', coalesce((v_quote->>'remaining_due_cents')::int, greatest(coalesce(p_total_cents, 0), 0)));
end $$;
revoke all on function app.sv_evaluate_quote(uuid, uuid, integer) from public, anon, authenticated;

-- =====================================================================
-- 6. public.reserve_checkout_sv_tender - the till "opt into stored value" step. create_sales +
--    can_see_branch + tenant only (contract §5). Gated by app.sv_checkout_tender_gate. Reserves
--    amount = min(requested, available, token total after discounts) via app.sv_reserve_core,
--    bound to the token. Supersedes any prior active tender for the account (re-evaluation
--    atomically releases the prior reservation and creates the new one). Idempotent per token+key.
-- =====================================================================
create or replace function public.reserve_checkout_sv_tender(
  p_business uuid, p_evaluation_id uuid, p_requested_cents integer, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_eval public.checkout_evaluations%rowtype;
  v_currency text;
  v_account uuid;
  v_existing public.checkout_sv_tenders%rowtype;
  v_prior public.checkout_sv_tenders%rowtype;
  v_available integer;
  v_amount integer;
  v_reserve jsonb;
  v_row_id uuid := gen_random_uuid();
begin
  if v_actor is null then
    raise exception 'authenticated staff required to add stored value to a checkout' using errcode = '42501';
  end if;
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to add stored value to a checkout (create_sales)' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value tender idempotency key is required' using errcode = '22023';
  end if;
  if p_requested_cents is null or p_requested_cents < 1 then
    raise exception 'a stored-value tender must request a whole number of at least 1 cent' using errcode = '22023';
  end if;

  select * into v_eval from public.checkout_evaluations
   where id = p_evaluation_id and business_id = p_business for update;
  if not found then
    raise exception 'checkout evaluation not found in this business' using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, v_eval.branch_id) then
    raise exception 'you are not permitted to tender for this branch scope' using errcode = '42501';
  end if;
  if v_eval.client_id is null then
    raise exception 'stored value needs a named customer on the checkout' using errcode = '22023';
  end if;
  if v_eval.consumed_at is not null then
    raise exception 'stale_evaluation: this checkout is already finalised; re-evaluate' using errcode = '22023';
  end if;
  if v_eval.expires_at <= now() then
    raise exception 'stale_evaluation: the checkout evaluation has expired; re-evaluate' using errcode = '22023';
  end if;

  -- Tender gate: authority live, no synthetic on live, redeem pause, currency.
  v_currency := app.sv_checkout_tender_gate(p_business, v_eval.client_id, null);

  -- Serialize per (business, evaluation) so a double opt-in is idempotent, not a double reservation.
  perform pg_advisory_xact_lock(hashtextextended('v67:tender:' || p_business::text || ':' || p_evaluation_id::text, 0));

  v_account := app.sv_ensure_account(p_business, v_eval.client_id);

  -- Exact replay: an active tender for THIS evaluation under THIS key returns unchanged.
  select * into v_existing from public.checkout_sv_tenders
   where business_id = p_business and evaluation_id = p_evaluation_id and status = 'reserved'
   order by created_at desc limit 1 for update;
  if found and v_existing.idempotency_key = p_idempotency_key then
    return jsonb_build_object(
      'status', 'ok', 'replayed', true, 'evaluation_id', p_evaluation_id, 'account_id', v_account,
      'reservation_id', v_existing.reservation_id, 'reserved_cents', v_existing.reserved_cents,
      'requested_cents', v_existing.requested_cents, 'bill_total_cents', v_eval.total_cents,
      'remaining_due_cents', greatest(v_eval.total_cents - v_existing.reserved_cents, 0), 'currency', v_currency);
  end if;

  -- Supersede any prior active tender for THIS account (re-evaluation / re-bind releases the prior).
  for v_prior in
    select * from public.checkout_sv_tenders
     where business_id = p_business and account_id = v_account and status = 'reserved'
     for update
  loop
    perform app.sv_release_core(p_business, v_prior.reservation_id, gen_random_uuid());
    update public.checkout_sv_tenders
       set status = 'released', released_reason = 'superseded', updated_at = now()
     where id = v_prior.id;
  end loop;

  v_available := coalesce(app.sv_available_balance(p_business, v_account), 0);
  v_amount := least(p_requested_cents, v_available, v_eval.total_cents);
  if v_amount < 1 then
    raise exception 'sv_no_coverage: this customer has no spendable stored value for this checkout' using errcode = '22023';
  end if;

  v_reserve := app.sv_reserve_core(p_business, v_account, v_amount, p_idempotency_key);

  -- The two unique constraints that can fire here are both "this customer's checkout hold is
  -- already spoken for", and both must reach the till as a TYPED refusal rather than a raw 23505:
  --   * checkout_sv_tenders_reservation_uk - reusing a reserve idempotency key across tokens.
  --     app.sv_reserve_core replays the stored result, so the SUPERSEDED (already released)
  --     reservation_id comes back and collides. Deterministic, not a race.
  --   * checkout_sv_tenders_active_uk - two tokens binding the same account concurrently, where the
  --     loser's supersede scan ran before the winner committed.
  -- Catching here changes nothing else: the idempotent-replay path returned long before this point,
  -- and both advisory locks are transaction-scoped, so the handler perturbs no lock or replay
  -- semantics - it only re-labels an error that already aborted the transaction.
  begin
    insert into public.checkout_sv_tenders(
      id, business_id, evaluation_id, account_id, reservation_id, reserve_operation_id, idempotency_key,
      requested_cents, reserved_cents, currency, status)
    values (
      v_row_id, p_business, p_evaluation_id, v_account,
      (v_reserve->>'reservation_id')::uuid, (v_reserve->>'operation_id')::uuid, p_idempotency_key,
      p_requested_cents, v_amount, v_currency, 'reserved');
  exception when unique_violation then
    raise exception 'sv_tender_conflict: this customer''s stored value is already held by another checkout or tender key; re-evaluate and bind with a fresh key'
      using errcode = '22023';
  end;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_CHECKOUT_TENDER_RESERVED', 'checkout_sv_tenders', v_row_id, jsonb_build_object(
    'evaluation_id', p_evaluation_id, 'account_id', v_account, 'reserved_cents', v_amount,
    'requested_cents', p_requested_cents, 'reservation_id', (v_reserve->>'reservation_id')::uuid));

  return jsonb_build_object(
    'status', 'ok', 'replayed', false, 'evaluation_id', p_evaluation_id, 'account_id', v_account,
    'reservation_id', (v_reserve->>'reservation_id')::uuid, 'reserved_cents', v_amount,
    'requested_cents', p_requested_cents, 'bill_total_cents', v_eval.total_cents,
    'remaining_due_cents', greatest(v_eval.total_cents - v_amount, 0), 'currency', v_currency);
end $$;
revoke all on function public.reserve_checkout_sv_tender(uuid, uuid, integer, uuid) from public, anon, authenticated;
grant execute on function public.reserve_checkout_sv_tender(uuid, uuid, integer, uuid) to authenticated;

-- =====================================================================
-- 7. public.evaluate_checkout - CREATE OR REPLACE. Byte-identical to v59 EXCEPT the two OK
--    responses (replay + fresh) now carry a server-authoritative 'stored_value' quote block for
--    the token client so the UI can offer "Use stored value" ONLY when spendable balance > 0.
--    No new persisted column, no change to pricing / token minting / idempotency.
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
  v_msg text;
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
      'total_cents', v_eval.total_cents, 'gst_cents', v_eval.gst_cents,
      'stored_value', app.sv_evaluate_quote(p_business, v_eval.client_id, v_eval.total_cents));
  end if;

  select active_config_version_id into v_config from public.businesses where id = p_business;

  v_plan := app.ps1c_plan_checkout(p_business, v_branch, p_client, p_lines, v_config);
  if v_plan->>'status' <> 'ok' then
    -- Surface the typed status as the message prefix. When the plan already provides a
    -- prefixed human sentence in 'reason' (custom_line_*, total_zero_not_supported) use
    -- it as-is; otherwise compose '<status>: <reason> (line N)'.
    if v_plan->>'reason' is not null and position((v_plan->>'status') || ':' in (v_plan->>'reason')) = 1 then
      v_msg := v_plan->>'reason';
    else
      v_msg := (v_plan->>'status') || ': ' || coalesce(v_plan->>'reason', 'checkout could not be priced')
               || case when v_plan->>'line' is not null then ' (line ' || (v_plan->>'line') || ')' else '' end;
    end if;
    raise exception '%', v_msg using errcode = '22023';
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
    'total_cents', (v_plan->>'total_cents')::int, 'gst_cents', (v_plan->>'gst_cents')::int,
    'stored_value', app.sv_evaluate_quote(p_business, p_client, (v_plan->>'total_cents')::int));
end $$;
revoke all on function public.evaluate_checkout(uuid, uuid, uuid, jsonb, uuid) from public, anon, authenticated;
grant execute on function public.evaluate_checkout(uuid, uuid, uuid, jsonb, uuid) to authenticated;

-- =====================================================================
-- 8. public.record_cart_sale/9 - CREATE OR REPLACE. Byte-identical to v59 EXCEPT the stored-value
--    tender consumption. When an active tender is bound to the token, INSIDE the same atomic
--    transaction: (a) the parent sale is finalised at the FULL discounted total with p_paid=false
--    so the finaliser writes NO full-amount payment (no cash double-count); (b) the reservation is
--    released then consumed via app.sv_spend_core (paid/bonus split per PS-0); (c) only the non-SV
--    remainder is recorded as a payment via record_payment; (d) tender evidence is written. All SV
--    gates are re-validated after the token lock (TOCTOU). No tender -> byte-identical to v59.
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
  -- v67 stored-value tender locals
  v_tender public.checkout_sv_tenders%rowtype; v_has_sv boolean := false;
  v_sv_amount int := 0; v_sv_remainder int := 0; v_spend jsonb; v_sv_json jsonb := null;
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

  -- 8.1 Lock the token. Single-use + tenant + scope validation.
  select * into v_eval from public.checkout_evaluations
   where id = p_evaluation_id and business_id = p_business for update;
  if not found then
    raise exception 'checkout evaluation not found in this business' using errcode = '42501';
  end if;
  if p_branch is not null and p_branch is distinct from v_eval.branch_id then
    raise exception 'stale_evaluation: branch does not match the evaluation token' using errcode = 'P0001';
  end if;
  if p_client is not null and p_client is distinct from v_eval.client_id then
    raise exception 'stale_evaluation: client does not match the evaluation token' using errcode = 'P0001';
  end if;

  -- 8.2 If already consumed: exact replay of THIS key, or a same-token/different-key loser
  --     (which must fail stale, never double-sell).
  if v_eval.consumed_at is not null then
    if exists (select 1 from public.financial_operations fo
                where fo.business_id = p_business and fo.sale_id = v_eval.consumed_sale_id
                  and fo.operation_type = 'quick_sale' and fo.idempotency_key = v_key) then
      select coalesce(sum(pl.points), 0) into v_points from public.points_ledger pl
       where pl.business_id = p_business and pl.sale_id = v_eval.consumed_sale_id and pl.entry_type = 'earn';
      select coalesce(json_agg(row_to_json(si) order by si.created_at, si.id), '[]'::json) into v_items
        from public.sale_items si where si.business_id = p_business and si.sale_id = v_eval.consumed_sale_id;
      return json_build_object('status', 'duplicate_ignored', 'sale_id', v_eval.consumed_sale_id,
        'business_id', p_business, 'total_cents', v_eval.total_cents, 'discount_total_cents', v_eval.discount_total_cents,
        'replayed', true, 'points_earned', 0, 'evaluation_id', v_eval.id, 'items', v_items,
        'stored_value', (select jsonb_build_object('sv_paid_cents', t.reserved_cents,
            'cash_collected_cents', t.cash_remainder_cents) from public.checkout_sv_tenders t
           where t.evaluation_id = v_eval.id and t.status = 'consumed' limit 1));
    end if;
    raise exception 'stale_evaluation: this checkout evaluation was already consumed by another sale' using errcode = 'P0001';
  end if;
  if v_eval.expires_at <= now() then
    raise exception 'stale_evaluation: the checkout evaluation has expired; re-evaluate' using errcode = 'P0001';
  end if;

  -- 8.3 Config drift: the active config version must be UNCHANGED since evaluation.
  if v_eval.config_version_id is distinct from
     (select active_config_version_id from public.businesses where id = p_business) then
    raise exception 'stale_evaluation: the active configuration changed since evaluation; re-evaluate' using errcode = 'P0001';
  end if;

  -- 8.3b Stored-value tender bound to this token? Discover + re-validate gates (TOCTOU). Any drift
  --      (reservation missing/expired/released) -> stale_evaluation so the till re-evaluates once.
  select * into v_tender from public.checkout_sv_tenders
   where business_id = p_business and evaluation_id = v_eval.id and status = 'reserved'
   for update;
  if found then
    v_has_sv := true;
    -- Gate re-validation after the lock (authority live, no synthetic on live, redeem pause, currency).
    perform app.sv_checkout_tender_gate(p_business, v_eval.client_id, v_tender.currency);
    if not exists (select 1 from public.sv_reservations r
                    where r.id = v_tender.reservation_id and r.business_id = p_business and r.status = 'active') then
      raise exception 'stale_evaluation: the stored-value hold is no longer active; re-evaluate' using errcode = 'P0001';
    end if;
    v_sv_amount := least(v_tender.reserved_cents, v_eval.total_cents);
    if v_sv_amount < 1 then
      raise exception 'stale_evaluation: the stored-value hold no longer covers this checkout; re-evaluate' using errcode = 'P0001';
    end if;
    v_sv_remainder := v_eval.total_cents - v_sv_amount;
  elsif exists (select 1 from public.checkout_sv_tenders t
                 where t.business_id = p_business and t.evaluation_id = v_eval.id and t.status = 'released') then
    -- The staff opted into stored value for this token but the hold was released (superseded by a
    -- later checkout for the same customer, or swept). Never silently downgrade to cash: fail stale
    -- so the till re-evaluates once (one winner in a two-token race; the loser gets a typed stale).
    raise exception 'stale_evaluation: the stored-value hold for this checkout was released; re-evaluate' using errcode = 'P0001';
  end if;

  -- 8.4 Price drift: re-resolve every server line and recompute the cart hash. A custom line is
  --     re-projected AS-IS from the immutable token.
  v_ord := 0;
  for v_line in select * from jsonb_array_elements(v_eval.server_lines) loop
    v_ord := v_ord + 1;
    v_kind := v_line->>'catalog_kind';
    v_cid := nullif(v_line->>'catalog_id', '')::uuid;
    v_qty := (v_line->>'qty')::int;
    if v_kind = 'custom' then
      v_unit := (v_line->>'unit_price_cents')::int;
    else
      v_price := app.ps1b_catalog_price(p_business, v_kind, v_cid);
      if v_price->>'status' <> 'ok' then
        raise exception 'stale_evaluation: line % can no longer be priced (%); re-evaluate', v_ord, v_price->>'status'
          using errcode = 'P0001';
      end if;
      v_unit := (v_price->>'price_cents')::int;
      if v_kind = 'product' then v_retail_lines := v_retail_lines + 1; v_stamp_product := v_cid; v_stamp_qty := v_qty; end if;
    end if;
    v_reproj := v_reproj || jsonb_build_array(jsonb_build_object(
      'catalog_kind', v_kind, 'catalog_id', v_cid, 'name', v_line->>'name',
      'unit_price_cents', v_unit, 'qty', v_qty, 'line_total_cents', v_unit * v_qty));
  end loop;
  v_rehash := app.ps1c_cart_hash(v_reproj);
  if v_rehash is distinct from v_eval.cart_hash then
    raise exception 'stale_evaluation: catalog prices changed since evaluation; re-evaluate' using errcode = 'P0001';
  end if;

  -- 8.5 Budget re-check + COMMIT, atomically, under a deterministic
  --     (business_id, rule_id, period_start) lock order.
  for eff in select e from jsonb_array_elements(v_eval.applied_effects) e
              where (e->>'suppressed')::boolean is not true and coalesce((e->>'capped')::boolean, false) loop
    insert into public.budget_periods(business_id, rule_id, period_start, period_end, cap_cents)
    values(p_business, (eff->>'rule_id')::uuid, (eff->>'period_start')::timestamptz,
           (eff->>'period_end')::timestamptz, (eff->>'cap_cents')::int)
    on conflict (business_id, rule_id, period_start) do nothing;
  end loop;
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

  -- 8.6 Belt-guard (contract B, v59): a zero total must NEVER create a sale, and must fail as a
  --     TYPED 22023 (not a stale P0001 that would spin a client re-evaluation loop).
  if v_eval.total_cents = 0 then
    raise exception 'total_zero_not_supported: this checkout totals zero after discounts and cannot be recorded; re-price it'
      using errcode = '22023';
  end if;

  -- 8.7 Create the parent sale for the DISCOUNTED total via the kernel candidate. When stored value
  --     tenders any portion, finalise the parent p_paid=false so the finaliser writes NO full-amount
  --     payment (the non-SV remainder is recorded below; the SV portion collects no new cash).
  perform set_config('app.cart_line_product_id',
    coalesce(case when v_retail_lines = 1 then v_stamp_product::text end, ''), true);
  perform set_config('app.cart_line_qty',
    coalesce(case when v_retail_lines = 1 then v_stamp_qty::text end, ''), true);
  v_financial := public.record_quick_sale(
    p_business => p_business, p_amount_cents => v_eval.total_cents, p_method => v_method,
    p_client => v_eval.client_id, p_staff => p_staff, p_branch => v_eval.branch_id, p_note => 'cart checkout (kernel)',
    p_idempotency_key => v_key, p_paid => case when v_has_sv then false else v_paid end)::jsonb;
  perform set_config('app.cart_line_product_id', '', true);
  perform set_config('app.cart_line_qty', '', true);

  v_sale_id := nullif(v_financial #>> '{sale,id}', '')::uuid;
  v_replayed := coalesce((v_financial->>'replayed')::boolean, false);
  if v_sale_id is null then
    raise exception 'kernel finaliser did not produce a parent sale row' using errcode = 'XX001';
  end if;
  if v_replayed then
    raise exception 'stale_evaluation: this idempotency key already produced a sale for a different token' using errcode = 'P0001';
  end if;

  -- 8.8 Write server-line sale_items (positive; custom -> item_type 'custom') then one signed
  --     studio_discount line per applied effect (negative).
  insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents, product_id)
  select v_sale_id, p_business,
         case e->>'catalog_kind' when 'service' then 'service' when 'product' then 'retail' else 'custom' end,
         nullif(e->>'catalog_id', '')::uuid, e->>'name', (e->>'qty')::int, (e->>'unit_price_cents')::int,
         (e->>'unit_price_cents')::int * (e->>'qty')::int,
         case when e->>'catalog_kind' = 'product' then nullif(e->>'catalog_id', '')::uuid end
    from jsonb_array_elements(v_eval.server_lines) e;

  -- 8.8b One CUSTOM_PRICE_LINE audit row per custom line.
  for eff in select e from jsonb_array_elements(v_eval.server_lines) e where e->>'catalog_kind' = 'custom' loop
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values(p_business, v_actor, 'CUSTOM_PRICE_LINE', 'sale_items', v_sale_id,
      jsonb_build_object(
        'description', eff->>'name',
        'amount_cents', (eff->>'unit_price_cents')::int,
        'reason', eff->>'reason',
        'entered_by', eff->>'entered_by'));
  end loop;

  -- 8.9 Per applied (non-suppressed) discount: fulfilment registry row, provenance line, signed
  --     sale_items line, and (if capped) a committed budget reservation.
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

  -- 8.9b Stored-value tender consumption (v67). Release the token hold, then spend the SV portion
  --      via the v63 engine (paid/bonus split per PS-0), record tender evidence, and record only the
  --      non-SV remainder as a payment. All within this atomic transaction with the sale.
  if v_has_sv then
    perform app.sv_release_core(p_business, v_tender.reservation_id, gen_random_uuid());
    v_spend := app.sv_spend_core(p_business, v_tender.account_id, v_sv_amount, gen_random_uuid());
    update public.checkout_sv_tenders
       set status = 'consumed', spend_operation_id = (v_spend->>'operation_id')::uuid, sale_id = v_sale_id,
           sv_paid_cents = (v_spend->>'paid_draw_cents')::int, sv_bonus_cents = (v_spend->>'bonus_draw_cents')::int,
           cash_remainder_cents = v_sv_remainder, updated_at = now()
     where id = v_tender.id;
    if v_sv_remainder > 0 and v_paid then
      perform public.record_payment(
        p_business => p_business, p_method => v_method, p_amount_cents => v_sv_remainder, p_sale => v_sale_id,
        p_client => v_eval.client_id, p_staff => p_staff, p_branch => v_eval.branch_id,
        p_idempotency_key => left(v_key || '-svrem', 255));
    end if;
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values(p_business, v_actor, 'SV_CHECKOUT_TENDER_SPENT', 'checkout_sv_tenders', v_tender.id, jsonb_build_object(
      'evaluation_id', v_eval.id, 'sale_id', v_sale_id, 'spend_operation_id', (v_spend->>'operation_id')::uuid,
      'sv_spend_cents', v_sv_amount, 'sv_paid_cents', (v_spend->>'paid_draw_cents')::int,
      'sv_bonus_cents', (v_spend->>'bonus_draw_cents')::int, 'cash_remainder_cents', v_sv_remainder));
    v_sv_json := jsonb_build_object(
      'sv_spend_cents', v_sv_amount, 'sv_paid_cents', (v_spend->>'paid_draw_cents')::int,
      'sv_bonus_cents', (v_spend->>'bonus_draw_cents')::int, 'cash_collected_cents', v_sv_remainder,
      'spend_operation_id', (v_spend->>'operation_id')::uuid);
  end if;

  -- 8.10 Consume the token (single-use).
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
    'sale', v_financial->'sale', 'items', v_items, 'stored_value', v_sv_json);
end $$;
revoke all on function public.record_cart_sale(uuid, uuid, uuid, uuid, text, text, jsonb, uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.record_cart_sale(uuid, uuid, uuid, uuid, text, text, jsonb, uuid, boolean)
  to authenticated;

-- =====================================================================
-- 9. public.sv_release_expired_checkout_tenders - owner/service sweep. Releases (via
--    app.sv_release_core) the reservations of active tenders bound to tokens that are expired or
--    consumed-by-another-sale, and marks those tenders 'released'. Idempotent; NO new cron (the
--    contract's "extend the sweep" - abandoned tender holds do not strand a customer's balance).
-- =====================================================================
create or replace function public.sv_release_expired_checkout_tenders(p_business uuid, p_limit integer default 1000)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 1000), 1), 100000);
  t record;
  v_released integer := 0;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  for t in
    select ct.id, ct.reservation_id
      from public.checkout_sv_tenders ct
      join public.checkout_evaluations ce on ce.id = ct.evaluation_id and ce.business_id = ct.business_id
     where ct.business_id = p_business and ct.status = 'reserved'
       and (ce.expires_at <= now() or ce.consumed_at is not null)
     order by ct.created_at
     for update of ct
  loop
    exit when v_released >= v_limit;
    perform app.sv_release_core(p_business, t.reservation_id, gen_random_uuid());
    update public.checkout_sv_tenders
       set status = 'released', released_reason = 'expired_sweep', updated_at = now()
     where id = t.id;
    v_released := v_released + 1;
  end loop;
  if v_released > 0 then
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'SV_CHECKOUT_TENDER_SWEEP', 'checkout_sv_tenders', p_business,
      jsonb_build_object('released', v_released));
  end if;
  return jsonb_build_object('status', 'ok', 'business_id', p_business, 'released', v_released);
end $$;
revoke all on function public.sv_release_expired_checkout_tenders(uuid, integer) from public, anon, authenticated;
grant execute on function public.sv_release_expired_checkout_tenders(uuid, integer) to authenticated;

-- =====================================================================
-- 10. ACCOUNTING REPRESENTATION - close the phantom-A/R risk of the p_paid=false finalise.
--     A consumed stored-value tender SETTLES its sale but writes NO public.payments row (spending
--     stored value collects no new cash; the cash was collected at top-up and lives as a liability
--     in sv_topup_payments - v11b/v20 keep the top-up cash-collected/liability, and v67 must not
--     re-count it). So checkout_sv_tenders (status='consumed') is the SETTLEMENT MARKER, and the two
--     v20 finance surfaces are re-created (CREATE OR REPLACE) to read it (additive; a sale with no tender is
--     byte-unchanged):
--       * public.sale_balance: settled = payments + sv_settled, so balance_cents nets to 0 and
--         payment_status reads 'paid' for a fully sv-tendered sale (no phantom accounts-receivable);
--         a new sv_settled_cents column exposes the marker. (grounds: v20 sale_balance + PS-0 §8.)
--       * public.get_revenue_summary: revenue_cash_cents now includes the sv settlement (a settled
--         sale is cash-basis realised: accrual == cash for a fully-tendered sale), while
--         cash_collected_cents (real cash) is UNCHANGED - the sv portion is not a payment, so it is
--         naturally excluded (spending stored value collects no new cash, contract §4). unpaid_
--         balance_cents auto-corrects because it reads the now-sv-aware sale_balance.
--     Bonus-vs-paid revenue nuance: PS-0 §4 marks bonus-lot spend as promotional exposure, never
--     revenue; the existing v20 surfaces count the FULL sale as revenue (a promo is not modelled as
--     contra-revenue for ANY tender), and v67 must NOT change the sale total / earn base, so the
--     paid/bonus split is recorded on checkout_sv_tenders (sv_paid_cents/sv_bonus_cents) for a future
--     contra-revenue increment and documented here rather than invented (contract §4 "document").
--
--     COUPLING (read with §11). Neither surface nets the settlement marker out against a compensating
--     movement, because in v67 no such compensation can exist: §11a refuses reversing the SALE and
--     §11b refuses reversing the SETTLEMENT SPEND, so a 'consumed' tender is terminal in both
--     directions and sv_settled_cents / v_sv_cash can never go stale. v68 (the refund/reversal
--     matrix) must net BOTH legs - sv_tender_totals here and v_sv_cash below - in the SAME increment
--     that lifts either refusal; lifting one alone reproduces exactly the defect §11 closes.
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
  select t.business_id,
         t.sale_id,
         coalesce(sum(t.reserved_cents), 0)::integer as sv_settled_cents
    from public.checkout_sv_tenders t
   where t.status = 'consumed'
     and t.sale_id is not null
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

create or replace function public.get_revenue_summary(
  p_business uuid,
  p_from date,
  p_to date,
  p_branch uuid default null::uuid)
returns json
language plpgsql
security definer
-- v21 hardened EVERY security-definer function to this exact search_path. The v20 source
-- this body is grounded in predates that sweep ('set search_path = public'), so re-creating
-- it verbatim would SILENTLY DOWNGRADE the applied catalog. Pin the hardened path.
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

  -- v67: a consumed stored-value tender settles its sale (no payments row). Recognise it as
  -- cash-basis revenue at the SALE occurred_at, so a settled sv sale is revenue_cash == accrual.
  -- cash_collected_cents (v_collected) is deliberately NOT touched: the sv portion is no new cash.
  select coalesce(sum(t.reserved_cents), 0)
    into v_sv_cash
    from public.checkout_sv_tenders t
    join public.sales s
      on s.business_id = t.business_id
     and s.id = t.sale_id
     and s.reversal_of is null
   where t.business_id = p_business
     and t.status = 'consumed'
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
-- 11a. TYPED REVERSAL REFUSAL FOR STORED-VALUE-TENDERED SALES (the SALE leg).
--     §10 gives an sv-tendered sale a NON-payment settlement (the consumed
--     checkout_sv_tenders row). The v20 money core knows only public.payments and
--     public.credit_ledger, so on such a sale reverse_sale would return 'ok' while
--     restoring NOTHING of the spent stored value - observed on the pre-fix chain:
--     an SV-only 5000 sale reversed with reversed_cents=5000, refunded_payment_cents=0,
--     credit_restored_cents=0 and zero compensating sv_lot_movements (the customer paid
--     real cash at top-up and afterwards holds neither goods nor value); a split
--     5000 SV + 3000 cash sale refunded only the 3000; both originals then read
--     balance_cents=-5000 / payment_status='overpaid'; and get_revenue_summary kept
--     counting the settlement as cash-basis revenue because its sv leg filters
--     reversal_of on the ORIGINAL sale, which a reversal never sets.
--
--     Coherent stored-value restitution (compensating movements, lot/expiry semantics,
--     bonus clawback interaction) is the v68 refund/reversal matrix and is deliberately
--     OUT OF v67 SCOPE. Out of scope must mean REFUSED, never silently wrong - so v67
--     refuses, mirroring the family's existing unsupported-scope refusal for
--     gift_card/package/membership kinds: a plain RAISE (SQLSTATE P0001, no errcode
--     override, exactly like its neighbour) with a typed message prefix.
--     NOTE the coupling: the §10 surfaces stay correct under reversal ONLY because an
--     sv settlement is unreversible from BOTH directions - this gate refuses reversing
--     the SALE, and §11b refuses reversing the SETTLEMENT SPEND. Neither gate alone is
--     sufficient: public.sv_reverse_spend takes a spend OPERATION and never funnels
--     through this money core, so with only this gate in place the settlement could be
--     unwound (value restored to the customer) while the sale kept reading paid and
--     cash-basis revenue. v68 must net the settlement leg out
--     (sale_balance.sv_tender_totals and get_revenue_summary's v_sv_cash) at the same
--     time it lifts EITHER refusal.
--
--     PLACEMENT - the single layer EVERY entry point funnels through. The live chain is
--       public.refund_sale/6  ->  public.reverse_sale/6            (v58: discount compensation)
--                             ->  public.reverse_sale_v40_base/6   (v40: package-reference idempotency)
--                             ->  public.reverse_sale_v34_base/6   (v34: provenance)
--                             ->  public.reverse_sale_v20_base/6   (v20: the money core)
--     so the gate goes in reverse_sale_v20_base: no present or future wrapper can bypass
--     it. Inside that body it sits immediately BEFORE the unsupported-kind refusal - after
--     every authorization check and row lock, but before the first write - so a refused
--     attempt mutates nothing and reserves no idempotency key.
--
--     METHOD - the repo's own v49a idiom: patch the EXACT applied catalog definition via
--     pg_get_functiondef under a single-occurrence needle guard. Every unrelated byte
--     (the v21-hardened search_path, the v49a uuid[] repair, the whole 680-line money
--     core) is preserved BY CONSTRUCTION, and a drifted predecessor fails closed instead
--     of being silently overwritten by a transcribed copy.
-- =====================================================================
do $v67_reversal_gate$
declare
  v_identity constant text := 'public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)';
  v_definition text;
  v_needle text;
  v_replacement text;
  v_occurrences integer;
  v_config text[];
begin
  select pg_get_functiondef(v_identity::regprocedure) into strict v_definition;

  if position('checkout_sv_tenders' in v_definition) > 0 then
    raise exception 'reverse_sale_v20_base already carries a stored-value tender gate';
  end if;

  v_needle := '  if o.kind not in (''service'', ''retail'', ''quick_sale'') then';
  v_occurrences := (length(v_definition) - length(replace(v_definition, v_needle, '')))
                   / length(v_needle);
  if v_occurrences <> 1 then
    raise exception 'unexpected reverse_sale_v20_base predecessor definition (needle occurrences: %)',
      v_occurrences;
  end if;

  v_replacement :=
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
    v_needle;

  execute replace(v_definition, v_needle, v_replacement);

  -- The replace must not have relaxed the v21 hardening or re-opened the closed ACL
  -- (CREATE OR REPLACE keeps grants, but assert rather than assume).
  select p.proconfig into v_config from pg_proc p where p.oid = v_identity::regprocedure;
  if v_config is distinct from array['search_path=pg_catalog, public, app, pg_temp'] then
    raise exception 'reverse_sale_v20_base lost its v21 hardened search_path: %', v_config;
  end if;
  if has_function_privilege('authenticated', v_identity, 'execute')
     or has_function_privilege('anon', v_identity, 'execute') then
    raise exception 'reverse_sale_v20_base must stay closed to the browser roles';
  end if;
  if position('sv_tendered_sale_unsupported' in pg_get_functiondef(v_identity::regprocedure)) = 0 then
    raise exception 'reverse_sale_v20_base stored-value tender gate was not installed';
  end if;
end
$v67_reversal_gate$;

-- =====================================================================
-- 11b. TYPED REVERSAL REFUSAL FOR THE SETTLEMENT SPEND (the STORED-VALUE leg).
--     §11a closes the SALE door. public.sv_reverse_spend (v63, pause-gated in v64) is the
--     OTHER door, and it does not open onto the same corridor: it takes a spend OPERATION
--     id, is granted to `authenticated`, and reverses that operation directly through the
--     lot ledger. It never calls reverse_sale_v20_base, so §11a's gate cannot see it - and
--     §8.9b makes the checkout tender's settlement exactly such a spend operation
--     (app.sv_spend_core, recorded as checkout_sv_tenders.spend_operation_id).
--
--     Observed on the §11a-only chain, as the business owner on a forced-live business,
--     against the suite's SV-only 5000 sale:
--         sv_reverse_spend -> {"status":"ok","restored_cents":5000,"net_restored_cents":5000}
--         sv balance:   available 0 -> 5000, outstanding 0 -> 5000        (value returned)
--         sale_balance: amount=5000 paid=0 sv_settled=5000 balance=0 status=paid  (UNCHANGED)
--         revenue_cash 5000, accrual 5100                                (UNCHANGED)
--         tender status still 'consumed'                                 (UNCHANGED)
--     i.e. the customer keeps the goods AND gets the stored value back while the books
--     still report the sale fully paid and count it as realised cash-basis revenue. That
--     falsifies §10/§11a's own correctness argument: the SALE was unreversible, the
--     SETTLEMENT was not. Latent (authority='live' is unreachable in prod until v69), but
--     the reasoning ships now, so the gate ships now.
--
--     SCOPE - identical to §11a and deliberately narrow: v67 REFUSES, it does not net the
--     legs. Netting the settlement out of sale_balance.sv_tender_totals and
--     get_revenue_summary.v_sv_cash is the v68 refund/reversal matrix, and both refusals
--     must be lifted together with that netting.
--
--     NON-CHECKOUT SPENDS STAY REVERSIBLE. The predicate is not "this account has a
--     tender" nor "stored value moved" - it is exactly "a CONSUMED checkout tender of this
--     business points at THIS spend operation". A plain owner-driven public.sv_spend
--     writes no tender row, so v63's reversal remains available to it unchanged
--     (asserted in db/tests/v67_ps2live_checkout_tender.sql).
--
--     ERROR SHAPE - the same typed-prefix idiom as §11a, with the sibling prefix
--     `sv_tendered_spend_unsupported:`. The SQLSTATE follows the LOCAL family, exactly as
--     §11a's did: every refusal already inside this body (sv_not_live, sv_paused,
--     over-reversal, target-not-a-spend) raises 22023, so this one does too. §11a chose
--     P0001 for the same reason - it is what ITS neighbours in reverse_sale_v20_base use.
--
--     PLACEMENT - after every authorization/existence check, after both advisory locks and
--     after the idempotent-replay lookup, immediately AFTER the over-reversal bound (see
--     NEEDLE ANCHORING below) and therefore still before the first write - the sv_operations
--     insert; only the read-only restore-plan loop sits between them. A refused attempt
--     mutates nothing and reserves no idempotency key.
--
--     METHOD - the v49a / §11a pg_get_functiondef splice, not a transcribed body. The
--     predecessor is v63's 130-line restore-then-expire money core as amended by v64's
--     pause gate; transcribing it to add four lines is exactly the "rebuilt from an older
--     source" class of defect the pending-migration guards exist to catch. Splicing
--     preserves every unrelated byte BY CONSTRUCTION and fails closed on a drifted
--     predecessor. Post-conditions differ from §11a in ONE place: sv_reverse_spend is an
--     owner-facing RPC that legitimately holds EXECUTE for `authenticated`, so the ACL
--     assertion is that the grant SURVIVED and that anon still has none.
--
--     NEEDLE ANCHORING (rev-5, and a STANDING RULE for every future splice - see the header
--     note). The rev-4 needle opened on the over-reversal bound's OWN `-- BOUND:` comment so
--     the gate would land ABOVE it. That needle occurs ONCE in a psql-replayed rehearsal DB
--     and ZERO times in production: prod's catalog was built through the Supabase MCP
--     `apply_migration`, which CONDENSES `--` comments out of large function bodies (first
--     observed on v66's record_sv_topup_sale and across the v60 wave). The rehearsal cluster
--     is therefore NOT byte-faithful to prod for function bodies, and a comment-anchored
--     needle passes every local gate while raising
--     `unexpected sv_reverse_spend predecessor definition (needle occurrences: 0)` against
--     prod - rolling the whole migration back. The needle is now the LAST TWO LINES of the
--     completed over-reversal construct (its raise + its `end if;`), which is pure code,
--     byte-identical in the v64 source and in prod's live definition, and occurs exactly once
--     in both. The gate is spliced AFTER that construct rather than before it, so no comment
--     - present in rehearsal, absent in prod - can be orphaned or re-annotated in either
--     environment, and the INSERTED block carries no `--` of its own for the same reason
--     (v67 is the only migration in the repo that ever put `--` inside a single-quoted
--     literal; that is now forbidden by
--     tests/phase0-foundation/pending-migration-hardening-guards.test.mjs GUARD 3).
--
--     PLACEMENT CONSEQUENCE of moving from before to after that construct: the gate still sits
--     after every authz/existence check, after both advisory locks, after the idempotent-replay
--     lookup, and BEFORE the first write (the sv_operations insert; the restore plan loop between
--     them is read-only) - so a refused attempt still mutates nothing and reserves no idempotency
--     key. The only behavioural difference is ordering between two refusals: an operation that is
--     BOTH already-reversed AND a checkout settlement now reports the over-reversal first. Both
--     are 22023 refusals that write nothing, so no caller-visible outcome changes beyond the
--     message, and the settlement refusal is still the only reachable one for a real settlement
--     spend (which by construction has never been reversed).
-- =====================================================================
do $v67_sv_reverse_gate$
declare
  v_identity constant text := 'public.sv_reverse_spend(uuid,uuid,uuid)';
  v_definition text;
  v_needle text;
  v_replacement text;
  v_occurrences integer;
  v_config text[];
  v_secdef boolean;
begin
  select pg_get_functiondef(v_identity::regprocedure) into strict v_definition;

  if position('checkout_sv_tenders' in v_definition) > 0 then
    raise exception 'sv_reverse_spend already carries a checkout-tender settlement gate';
  end if;

  -- COMMENT-FREE NEEDLE (rev-5). The last two lines of the COMPLETED over-reversal construct:
  -- pure code, byte-identical in the v64 source and in production's live catalog (where the MCP
  -- apply has condensed every `--` comment out of this body), single-occurrence in both. The gate
  -- is spliced AFTER this construct, so nothing can orphan or re-annotate a comment that exists in
  -- one environment and not the other. The inserted block is comment-free for the same reason.
  v_needle :=
    '    raise exception ''stored-value spend operation is already reversed (over-reversal refused)''' ||
    ' using errcode = ''22023'';' || E'\n' ||
    '  end if;';
  v_occurrences := (length(v_definition) - length(replace(v_definition, v_needle, '')))
                   / length(v_needle);
  if v_occurrences <> 1 then
    raise exception 'unexpected sv_reverse_spend predecessor definition (needle occurrences: %)',
      v_occurrences;
  end if;

  v_replacement :=
    v_needle || E'\n' || E'\n' ||
    '  if exists (' || E'\n' ||
    '    select 1' || E'\n' ||
    '      from public.checkout_sv_tenders t' || E'\n' ||
    '     where t.business_id = p_business' || E'\n' ||
    '       and t.spend_operation_id = p_spend_operation' || E'\n' ||
    '       and t.status = ''consumed''' || E'\n' ||
    '  ) then' || E'\n' ||
    '    raise exception ''sv_tendered_spend_unsupported: stored-value operation % settled a' ||
    ' checkout sale; that sale stays paid and cash-basis revenue, so reversing the settlement' ||
    ' alone is refused'', p_spend_operation' || E'\n' ||
    '      using errcode = ''22023'';' || E'\n' ||
    '  end if;';

  execute replace(v_definition, v_needle, v_replacement);

  -- The replace must not have relaxed the v21 hardening, dropped SECURITY DEFINER, or moved
  -- the ACL in EITHER direction (CREATE OR REPLACE keeps grants, but assert rather than assume).
  select p.proconfig, p.prosecdef into v_config, v_secdef
    from pg_proc p where p.oid = v_identity::regprocedure;
  if v_config is distinct from array['search_path=pg_catalog, public, app, pg_temp'] then
    raise exception 'sv_reverse_spend lost its v21 hardened search_path: %', v_config;
  end if;
  if not v_secdef then
    raise exception 'sv_reverse_spend is no longer SECURITY DEFINER';
  end if;
  if not has_function_privilege('authenticated', v_identity, 'execute') then
    raise exception 'sv_reverse_spend lost the owner-RPC EXECUTE grant it has held since v63';
  end if;
  if has_function_privilege('anon', v_identity, 'execute') then
    raise exception 'sv_reverse_spend must stay closed to anon';
  end if;
  if position('sv_tendered_spend_unsupported' in pg_get_functiondef(v_identity::regprocedure)) = 0 then
    raise exception 'sv_reverse_spend checkout-tender settlement gate was not installed';
  end if;
end
$v67_sv_reverse_gate$;

commit;
