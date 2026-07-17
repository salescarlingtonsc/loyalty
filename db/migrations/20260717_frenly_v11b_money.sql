-- FRENLY v11b — the money layer: PAYMENTS ledger, the completion/payment split,
--                CASH DRAWER, EXPENSES, and derived Net.
-- (target Supabase project kyzovonwnscrzmkvocid; migration name `frenly_v11b_money`)
--
-- APPLY ORDER:  v10 (LIVE)  ->  v10.1_policy_snapshot  ->  v11a_branches_staff_services
--               ->  v11b (this file).
-- HARD DEPENDS ON ALL THREE. It will fail loudly at apply time if any is missing, which is
-- the intended behaviour. What it consumes from each:
--   v10.1  sales.counts_as_revenue (the immutable policy SNAPSHOT — every revenue figure in
--          this file reads it and NOTHING here resolves policy at read time);
--          app.has_perm(business, permission) — every money policy and RPC is gated on it;
--          the `refund_sales` permission, which v10.1 defined with no subject so that this
--          file could wire it (record_payment is its first and only caller).
--   v11a   branches / sales.branch_id / sales.staff_id / staff.commission_*_bps /
--          services.commission_bps / app.set_row_branch / app.default_branch;
--          AND the composite keys `unique (id, business_id)` on sales, appointments,
--          services, staff, branches AND clients — all SIX. THAT IS A CONTRACT: v11a OWNS
--          those keys, v11b CONSUMES them (§1.0a) and must not re-declare any of them.
--          v11b declares `unique (id, business_id)` ONLY on its own new tables (payments,
--          cash_drawer_sessions, expense_recurrences), which v11a does not touch.
--          ⚠️ CORRECTED 2026-07-17: this header previously said "v11b declares the same key
--          on `clients`, which v11a does not touch". That is now FALSE on both counts. v11a
--          §0 declares clients_id_business_uk — a reviewer added it because v11b's
--          payments_client_same_tenant FK had no legal target and the literal three-file
--          chain aborted. v11b's own `clients_id_business_key` is therefore deleted here: it
--          was a second, identical unique constraint on the same columns (and a redundant
--          index). Do not re-add it.
--
-- ⚠️ THIS FILE WAS REWORKED AFTER AN ADVERSARIAL REVIEW RETURNED **REWORK**. The two
-- blockers were: (1) get_revenue_summary reproduced v10's P0 verbatim by resolving policy at
-- read time — in the migration that lands right after the one that fixes it; and (2) a
-- cross-tenant hole where `payments` was directly INSERT-able with another tenant's sale_id,
-- because the guards lived in an RPC while the table was writable. Both are closed, both with
-- tests that fail against the old code. Three of the original file's own comments and tests
-- were also FALSE and are marked ❌ / RETRACTED in place rather than quietly deleted — a
-- wrong comment next to right code is how the next reader gets misled.
--
-- Read v11a's header first: it documents the live row counts that falsify the brief's
-- "sales is empty / 1 business" premise, and the one live kind='retail' package row that v10
-- will mis-classify. Both apply to this file too.
--
-- ====================================================================================
-- THE ARCHITECTURAL FORK — WHERE LOYALTY FIRES UNDER THE SPLIT
-- ====================================================================================
-- The brief: "does loyalty fire at completion (sale created) or at payment? ... decide and
-- argue." Here is the decision and the argument, because this is the one call in v11 that is
-- expensive to reverse.
--
-- DECISION: **loyalty keeps firing at COMPLETION. app.on_sale_recorded() is not touched, not
-- re-declared, and not re-timed by this migration.** v10's version of it survives intact.
--
-- The reasoning turns on what the two tables MEAN. The live evidence (walkthrough step 7)
-- shows the competitor treating completion and payment as two independent events:
--     completion -> stock deducted, client VISIT counted, NO transaction, NO revenue
--     checkout   -> transaction created, REVENUE recognised, cash drawer credited
-- That is not one event with a flag. It is an ACCRUAL event and a CASH event.
--
-- Frenly already has the accrual event: the `sales` row. What it has never had is the cash
-- event. So the split is additive, not a rewrite:
--     public.sales     = "a sale happened / the service was delivered"   (accrual)
--     public.payments  = "money physically arrived"                      (cash)   <- NEW
-- `sales` was never really conflating the two concepts; it was missing one of them. Adding
-- the missing half is a strictly smaller and safer change than moving the existing half.
--
-- Why NOT move the sales insert to checkout (the tempting reading of the brief):
--
--   1. It contradicts the product's own stated first principle. CLAUDE.md: "**Completion is
--      the universal earn/qualify event** — one shared visit.completed / sale.closed signal;
--      modules subscribe, none writes the ledger directly." Moving earn to payment would mean
--      a customer who is served and pays next Tuesday earns their points next Tuesday, and a
--      customer with an open tab never earns at all. That is not a schema detail; it reverses
--      a decision the product is built on.
--
--   2. It contradicts the competitor we are matching. They count the VISIT at completion.
--      Their loyalty module is Growth-paywalled (evidence E) so we have never observed their
--      points timing — but "visit at completion" is live-confirmed (Visits 0 -> 1 with no
--      transaction), and Frenly's retention engine is visit-driven. Firing retention at
--      payment would be LESS like them, not more.
--
--   3. v10 already answered this and the brief instructs me to use it, not to build a
--      parallel mechanism. `counts_as_visit` and `counts_as_revenue` are the two ideas the
--      competitor separates. v10 made them per-business booleans. The split does not need a
--      third mechanism; it needs the cash ledger those flags can be reported against.
--
--   4. Blast radius. Moving the insert would break: one_sale_per_appointment idempotency
--      (v6), the 16-assertion gift-card chain (v9), all 7 v10 policy scenarios, and would
--      require rewriting on_appointment_completed + sell_package + enroll_membership +
--      run_membership_renewals + issue_gift_card — all five of which insert sales with no
--      concept of payment. Every verified loyalty semantic in the system would need
--      re-proving to buy a property we can get for free by adding a table.
--
-- ====================================================================================
-- THE RULE I CHOSE FOR REVENUE (the brief asks me to state it explicitly)
-- ====================================================================================
-- **A sale with no payment rows does NOT vanish from revenue. It becomes an unpaid
--   receivable, and it is reported in BOTH of two different, both-correct revenue figures.**
--
--   ACCRUAL revenue = sum(sales.amount_cents) where THE SALE'S OWN counts_as_revenue
--                     SNAPSHOT is true. Recognised at completion.
--   CASH revenue     = sum(payments.amount_cents) against sales whose OWN snapshot says
--                     counts_as_revenue — resolved through sale_balance's join, so deposits
--                     (sale_id null, appointment_id set) are included. Recognised at payment.
--                     This is the competitor's "Revenue (Paid)" — $0.00 after completion,
--                     $50.00 after checkout (live-confirmed numbers).
--
--   ⚠️ "the KIND's counts_as_revenue" is how the first draft said it, and the wording was the
--   bug in miniature. A kind does not have a counts_as_revenue; a kind has a CURRENT POLICY,
--   and a SALE has a snapshot of what that policy said when the sale happened. Reporting must
--   read the sale. See the P0 note above get_revenue_summary for the measured damage.
--
-- Both come out of public.get_revenue_summary(). The difference between them IS accounts
-- receivable, and it is exactly public.sale_balance's unpaid+partial rows. A business that
-- never records a payment sees accrual revenue exactly as it does today and a growing
-- unpaid balance — a true statement about a business that is not collecting, not a silent
-- disappearance.
--
-- Chosen over the alternative ("revenue means cash, full stop") because that alternative
-- would silently zero the revenue of the 2 live businesses the moment it was applied: they
-- have 6 sales and, necessarily, 0 payments. A migration that takes a working dashboard to
-- $0 is not backward compatible no matter how defensible its accounting.
--
-- ⚖️ ACCOUNTING NOTE, NOT ADVICE: which of these two a Singapore SME must file on is a
--    question for their accountant. We compute both, label both, and claim neither is "the"
--    revenue. Do not let the UI pick one and call it Revenue without a label.
--
-- ====================================================================================
-- DESIGN — payments
-- ====================================================================================
-- Append-only, signed, never mutated — the credit_ledger pattern, which is the codebase's
-- stated principle ("Append-only ledgers + derived views. Never a mutable stored balance").
--   * A refund is a NEGATIVE row, not an UPDATE and not a status flip. amount_cents has no
--     sign check for exactly this reason.
--   * Payment STATUS is DERIVED (public.sale_balance), never stored. This is the brief's
--     explicit ask and it is also what makes refunds free: the status recomputes itself.
--   * UPDATE/DELETE/TRUNCATE are EXPLICITLY revoked (this database's default ACL grants
--     `authenticated=arwdDxtm` on every new public table, so `grant select, insert` alone
--     achieves precisely nothing — and RLS does not cover TRUNCATE). The append-only trigger
--     is the third lock, for roles RLS does not apply to and for the future migration that
--     re-grants carelessly. See §1.0b.
--
-- THE LINKAGE TRICK (worth understanding before reviewing sale_balance):
--   A deposit is taken at BOOKING — before the appointment completes, so before the sale row
--   exists. The obvious design is to write the payment with sale_id = null and back-fill
--   sale_id when the sale appears. That would require UPDATEing a row in an append-only
--   ledger, and "it's only the linkage, not the money" is precisely the argument that erodes
--   append-only ledgers.
--   Instead payments carry (sale_id, appointment_id) and NEITHER is ever updated. A payment
--   for an appointment is written with appointment_id set and sale_id null, at booking time,
--   and is RESOLVED to the sale later by the join, because sales.appointment_id already
--   exists and is already unique (one_sale_per_appointment, v6). Zero mutation, deposits
--   attach themselves the instant the appointment completes. See sale_balance's join.
--
-- IDEMPOTENCY: idempotency_key + a unique partial index on (business_id, idempotency_key).
--   Double-tapping "Charge $50" must not take $100. The key is caller-supplied and the RPC
--   returns the EXISTING payment on a repeat rather than raising — a raise would show the
--   cashier an error for an operation that in fact succeeded, and they would retry again.
--
-- ====================================================================================
-- DESIGN — cash drawer
-- ====================================================================================
-- Per-branch, expected-vs-actual, append-only movements + a derived expected balance.
-- Live-confirmed: cash payments auto-credit the drawer with no manual step ($0 -> $50 ->
-- $75 -> $100 across a cash checkout, a cash retail sale and a cash gift card — note that
-- the gift card credited the drawer even though it is NOT revenue; cash is cash. That falls
-- out of this design for free, because the drawer is fed by payments and knows nothing about
-- sale kinds or revenue policy).
--
-- THE CLOSE MECHANIC (the part worth arguing): closing a session with a counted amount
-- inserts a `close_variance` movement equal to (counted - expected). Therefore the running
-- sum of movements ALWAYS equals the physical cash in the drawer, and the variance is a
-- first-class ledger row you can report on and audit rather than a number computed in a UI
-- and thrown away. No stored balance anywhere; no reset; drift is recorded, not erased.
--
-- ====================================================================================
-- DESIGN — expenses
-- ====================================================================================
-- One-time + recurring, multi-currency, VOID not delete, category, supplier -> feeds Net.
--   * VOID IS A MUTABLE FLAG (voided_at), NOT a reversing ledger row. Deliberate and
--     inconsistent-looking next to payments, so: the competitor's UI is a "void TOGGLE"
--     (live), i.e. reversible. An expense is a recorded ASSERTION about a cost, not a
--     movement of money through our system; voiding it says "this assertion was wrong",
--     which is a correction, not a transaction. Every void is audited via app.audit(), so
--     the history is not lost. If the owner wants expenses to be strictly append-only, that
--     is a real position and a cheap change — flag it.
--   * MULTI-CURRENCY: amount_cents + currency + fx_rate_to_base. Net must be summed in ONE
--     currency; storing the rate AT ENTRY freezes the historical fact instead of re-valuing
--     last year's costs at today's rate. Default 1.0 for same-currency (the overwhelming
--     case: SGD). ⚖️ We do not source FX rates; the caller supplies one.
--   * RECURRING: a template table + a daily pg_cron job that MATERIALISES real expense rows.
--     Idempotent via unique (recurrence_id, period_on) — a cron double-run cannot double-bill.
--     Deliberately materialised rather than computed on the fly so a recurring expense can be
--     voided/edited for one month like any other row.
--
-- Style follows v2/v8/v9/v10 throughout. RLS on every table. app.audit() dereferences BOTH
-- new.id and new.business_id, so every audited table below carries both.

begin;

-- ====================================================================================
-- 1. PAYMENTS — the transaction ledger
-- ====================================================================================
create table public.payments (
  id             uuid primary key default gen_random_uuid(),
  -- business_id KEEPS its single-column FK: `businesses` is the tenant ROOT, so there is no
  -- (id, business_id) pair to compose against it and no composite FK below duplicates it.
  -- It is also the cascade root the whole file depends on. Exactly one FK on this pair.
  business_id    uuid not null references public.businesses(id) on delete cascade,
  -- ⚠️ NO INLINE `references` ON THE FIVE COLUMNS BELOW — DELIBERATE, DO NOT "FIX" IT BACK.
  -- Each one is covered by a composite `_same_tenant` FK in §1.0a, which is strictly stronger
  -- (it enforces the tenant pairing, not just existence). Declaring BOTH would give each of
  -- these five table pairs TWO foreign keys, and PostgREST cannot then resolve an embed:
  -- `select=...,sales(*)` on payments returns PGRST201 — the exact production outage app v1.6
  -- had to hot-fix on appointments->services. v11a's header states the rule this file now
  -- follows: "Every FK added below REPLACES rather than supplements, so no table pair ends up
  -- with two." The composite FK in §1.0a IS the FK for each of these columns.
  branch_id      uuid,
  -- A payment attaches to a sale, an appointment, or both. A deposit/no-show fee has an
  -- appointment and no sale. A quick sale has a sale and no appointment. NEITHER column is
  -- ever updated after insert (see THE LINKAGE TRICK in the header).
  sale_id        uuid,
  appointment_id uuid,
  client_id      uuid,
  -- Who rang it up. Drives the Transactions list's staff filter + commission attribution.
  staff_id       uuid,
  method         text not null check (method in
                   ('cash','card','paynow','bank_transfer','credit','gift_card','other')),
  -- 'payment'      — money against a delivered/booked sale (full or partial).
  -- 'deposit'      — money taken at booking, before the sale exists.
  -- 'no_show_fee'  — a charge for a no-show. See the OPEN QUESTION at the bottom.
  -- 'refund'       — money returned. MUST carry a negative amount_cents (checked below).
  kind           text not null default 'payment'
                   check (kind in ('payment','deposit','no_show_fee','refund')),
  -- SIGNED. No `> 0` check: a refund is a negative row, which is what makes this ledger
  -- append-only. Zero is meaningless and is rejected.
  amount_cents   integer not null check (amount_cents <> 0),
  -- Sign discipline, enforced rather than trusted: refunds negative, everything else
  -- positive. Without this a mistyped refund silently becomes a payment and inflates cash.
  check ((kind = 'refund' and amount_cents < 0) or (kind <> 'refund' and amount_cents > 0)),
  occurred_at    timestamptz not null default now(),
  reference      text,
  note           text,
  -- Double-charge protection. See IDEMPOTENCY in the header.
  idempotency_key text,
  created_at     timestamptz not null default now(),
  created_by     uuid default auth.uid()
);

-- ------------------------------------------------------------------------------------
-- 1.0a CROSS-TENANT ATTACHMENT, CLOSED IN THE SCHEMA (not in an RPC).
-- ------------------------------------------------------------------------------------
-- REPRODUCED, not theorised. `payments` is PostgREST-exposed and `authenticated` can INSERT.
-- The three guards in record_payment() are real but they are guards on ONE DOOR. The table is
-- the other door:
--     POST /payments  {business_id: <X>, sale_id: <a sale owned by Y>, amount_cents: 9999}
-- passes payments_insert's `with check (is_salon_member(business_id))` — the member IS a
-- member of X — and the single-column FK to sales(id) happily accepts Y's uuid. Y's
-- sale_balance then reads paid_cents = 9999 / status = 'paid', written by a member of X, and
-- Y cannot even SELECT the row to find out why (payments_select filters on business_id = X).
-- A guard in an RPC is not a guard when the table is writable.
--
-- THE FIX: composite foreign keys. The tenant is part of the key, so the DATABASE — not a
-- code path someone has to remember to route through — rejects the mismatch. v11a §0 owns and
-- creates ALL SIX `unique (id, business_id)` keys — sales / appointments / services / staff /
-- branches / clients (contract, do not re-declare any of them here). v11b declares that key
-- only on its OWN new tables, which v11a does not touch.
--
-- ⚠️ `alter table public.clients add constraint clients_id_business_key unique (id, business_id);`
--    USED TO LIVE HERE AND IS DELETED, not moved. v11a §0 now declares clients_id_business_uk
--    over the same two columns, so this line produced a SECOND identical unique constraint on
--    `clients` (measured: 2, expected 1) plus a redundant index backing it. The FK below
--    (payments_client_same_tenant) is unaffected: it targets the COLUMN LIST
--    `clients(id, business_id)`, and v11a's constraint satisfies it. Deleting a duplicate
--    unique constraint removes no integrity — the surviving one enforces the identical rule.

alter table public.payments
  -- v11b's own tables must be composable the same way (cash_drawer_movements.payment_id).
  add constraint payments_id_business_key unique (id, business_id),
  add constraint payments_sale_same_tenant   foreign key (sale_id, business_id)
      references public.sales(id, business_id),
  add constraint payments_appt_same_tenant   foreign key (appointment_id, business_id)
      references public.appointments(id, business_id),
  add constraint payments_staff_same_tenant  foreign key (staff_id, business_id)
      references public.staff(id, business_id),
  add constraint payments_client_same_tenant foreign key (client_id, business_id)
      references public.clients(id, business_id),
  add constraint payments_branch_same_tenant foreign key (branch_id, business_id)
      references public.branches(id, business_id);
--
-- ⚠️ A REFERENTIAL-ACTION CHANGE, STATED RATHER THAN BURIED. The five columns above USED to
-- carry inline single-column FKs with `on delete set null`. Those are DELETED (see the note in
-- the create table), so these composite FKs are now the ONLY FKs on those five table pairs and
-- their NO ACTION is the behaviour that applies. That is the intended outcome, not a side
-- effect: two FKs per pair is PGRST201, and of the two, the composite is the one worth keeping.
--   * NO ACTION is also the only correct choice here, independently of the PGRST201 argument.
--     `on delete set null` on a COMPOSITE key nulls EVERY column in the key — including
--     business_id, which is NOT NULL. It would therefore raise anyway, but with a confusing
--     not-null violation instead of a foreign-key violation. NO ACTION raises the honest one.
--   * The consequence: an appointment (or client, or staff, or branch) that a payment points
--     at CANNOT BE HARD-DELETED while that payment exists. `sales` is already undeletable
--     (v10.1's guard), so only the other four change. This is the correct behaviour for a
--     money ledger — a deposit must not be able to lose the appointment it was taken for —
--     but it IS a behaviour change for any UI code that deletes an appointment. Cancel it
--     (status='cancelled'), do not delete it.
--   * Deleting the BUSINESS still works: businesses cascades to payments and to
--     appointments/clients/staff/branches alike, so the cascade root is unaffected.

create unique index payments_idempotency
  on public.payments (business_id, idempotency_key)
  where idempotency_key is not null;
create index payments_sale        on public.payments (sale_id) where sale_id is not null;
create index payments_appointment on public.payments (appointment_id) where appointment_id is not null;
create index payments_branch_time on public.payments (branch_id, occurred_at);
create index payments_business_time on public.payments (business_id, occurred_at);
create index payments_client      on public.payments (client_id, occurred_at) where client_id is not null;

-- ------------------------------------------------------------------------------------
-- 1.0b PERMISSIONS ON MONEY — v10.1's app.has_perm(), not is_salon_member().
-- ------------------------------------------------------------------------------------
-- Every table in the first draft of this file was gated on app.is_salon_member(), i.e. "any
-- authenticated member of the tenant". On the MONEY layer that means a stylist reads every
-- payment, every expense and every commission figure in the business, and can post cash
-- movements into the drawer. v10.1 exists partly to make that unnecessary: it ships
-- app.has_perm(business, permission) over the four live roles. This file uses it.
--
--   THE MAPPING (v10.1's six permissions; no seventh is invented here):
--     view_finance  (owner, manager)                     -> READ money. payments,
--                    cash drawer (sessions/movements/balances), expenses, expense
--                    recurrences, sale_balance, sale_commission, get_revenue_summary.
--                    Also WRITE for anything that is an accounting act rather than a till
--                    act: expenses, recurrences, open/close drawer, manual pay_in/pay_out.
--     create_sales  (owner, manager, stylist, frontdesk) -> TAKE a payment. record_payment()
--                    with kind in ('payment','deposit','no_show_fee'). Whoever may ring up
--                    a sale must be able to collect for it, or checkout is owner-only and
--                    the feature is useless at the counter.
--     refund_sales  (owner, manager)                     -> GIVE money back. record_payment()
--                    with kind='refund'. v10.1 defined this permission with no subject
--                    precisely so v11b could wire it here instead of inventing one. This is
--                    its first and only caller.
--
--   ⚠️ OWNER DECISION SURFACED, NOT GUESSED. A frontdesk role can take payments but cannot
--   open or close the till, because closing a till is a view_finance act and frontdesk has
--   no view_finance. At a real café the person at the counter is usually the person who
--   counts the drawer. Fixing that means either giving frontdesk view_finance (which also
--   hands them the P&L — wrong) or adding a SEVENTH permission, e.g. `operate_drawer`
--   (owner, manager, frontdesk). A seventh permission is a v10.1 change, not a v11b one, so
--   it is NOT made here. Flagged as Q6 at the foot of this file.
--
--   Blast radius today: every live staff row is role='owner' (verified), so has_perm returns
--   true for all six permissions and this section is a no-op for every existing user.
alter table public.payments enable row level security;
create policy payments_select on public.payments for select to authenticated
  using (app.has_perm(business_id, 'view_finance'));
-- Taking money is a counter act (create_sales); giving it back is not (refund_sales). The
-- table-level split is coarse — the RPC below enforces the per-kind rule — but the policy
-- must at minimum stop a stylist from posting a raw negative row straight through PostgREST.
create policy payments_insert on public.payments for insert to authenticated
  with check (app.has_perm(business_id, 'create_sales')
              and (kind <> 'refund' or app.has_perm(business_id, 'refund_sales')));
-- NO update/delete policy, by design.
--
-- ⚠️ WHY THE `revoke` BELOW IS NOT THE ONE THE FIRST DRAFT WROTE. The first draft said
-- `revoke all from anon; grant select, insert to authenticated;` and claimed that was belt
-- and braces. It was neither belt nor braces. This database has a default ACL (verified
-- live: `pg_default_acl` = `authenticated=arwdDxtm/postgres` for every new table in schema
-- `public`), so a brand-new table ALREADY grants authenticated INSERT, SELECT, UPDATE,
-- DELETE, TRUNCATE, REFERENCES and TRIGGER. `grant select, insert` therefore added exactly
-- nothing. RLS masked most of it — an UPDATE or DELETE with no policy simply matches 0 rows,
-- which is why the append-only trigger below never fires and is, today, dead code.
--
-- BUT RLS DOES NOT APPLY TO TRUNCATE. In test, `authenticated` truncated the entire
-- multi-tenant payments ledger — every business, no error, no audit row, no trigger. The
-- explicit revoke is the only thing that stops it. v10.1 already does exactly this for
-- `sales`; every new table in this file now does too.
revoke all on public.payments from anon;
revoke update, delete, truncate on public.payments from authenticated;
grant select, insert on public.payments to authenticated;

create or replace function app.forbid_mutation()
returns trigger language plpgsql set search_path = public as $$
begin
  raise exception '% is an append-only ledger: % is not permitted. Post a reversing row instead.',
    tg_table_name, tg_op;
end $$;

create trigger trg_payments_append_only
  before update or delete on public.payments
  for each row execute function app.forbid_mutation();

create trigger trg_payments_audit
  after insert on public.payments
  for each row execute function app.audit();

-- 1.1 Default the branch, exactly as v11a does for sales/appointments, so that a payment
--     written without a branch still reaches the right drawer.
create trigger trg_payments_default_branch
  before insert on public.payments
  for each row execute function app.set_row_branch();

-- 1.2 DERIVED payment status. Never stored — the brief's explicit requirement and the
--     codebase's stated principle.
--
--     The join is the load-bearing line. A payment counts toward a sale if:
--       (a) it names the sale directly, OR
--       (b) it names the sale's appointment and names no sale
--           (the deposit case: written before the sale existed).
--
--     WHAT `p.sale_id is null` IN BRANCH (b) ACTUALLY DOES — the first draft's comment here
--     was WRONG and the test it justified could not fail. It claimed the clause prevents
--     double-counting a payment that carries BOTH ids. It does not: `LEFT JOIN ... ON a OR b`
--     produces ONE row when either side matches, never two, so a payment carrying both its
--     own sale's id and that sale's appointment id is summed once with or without the clause.
--     Deleting the clause and re-running the old Scenario B5 returns the same number either
--     way — an assertion that is green against the mutant is not an assertion.
--
--     The clause IS load-bearing, for a DIFFERENT case: CROSS-SALE LEAKAGE. Take a payment
--     that names sale Q while carrying appointment A's id (a checkout that pays down an
--     unrelated tab from A's booking screen; the RPC's `v_client`/`v_branch` resolution and
--     any caller passing both make this reachable). Without the clause, branch (b) matches
--     A's OWN sale too — so A's sale silently reads as paid with Q's money, and Q reads paid
--     as well. The same cents land on two different sales. With the clause, branch (b) is
--     restricted to payments that name NO sale, so a payment that has already chosen its sale
--     cannot be re-adopted by another one. Scenario B5 is rewritten to that case, and it goes
--     red against the mutant (see the test block).
create view public.sale_balance
with (security_invoker = on) as
select s.id                                            as sale_id,
       s.business_id,
       s.branch_id,
       s.client_id,
       s.appointment_id,
       s.kind,
       -- v10.1's IMMUTABLE SNAPSHOT, carried through so that callers can filter revenue
       -- WITHOUT re-resolving policy at read time. This column is the whole reason
       -- get_revenue_summary can be correct; exposing it here is what stops the next
       -- reporting view from reaching for app.sale_policy_set() again.
       s.counts_as_revenue,
       s.amount_cents,
       s.occurred_at,
       coalesce(sum(p.amount_cents), 0)::integer       as paid_cents,
       (s.amount_cents - coalesce(sum(p.amount_cents), 0))::integer as balance_cents,
       case
         when coalesce(sum(p.amount_cents), 0) <= 0             then 'unpaid'
         when coalesce(sum(p.amount_cents), 0) <  s.amount_cents then 'partial'
         when coalesce(sum(p.amount_cents), 0) =  s.amount_cents then 'paid'
         else 'overpaid'
       end                                             as payment_status
from public.sales s
left join public.payments p
  on  p.sale_id = s.id
   or (p.sale_id is null
       and s.appointment_id is not null
       and p.appointment_id = s.appointment_id)
-- Money is view_finance, not view_sales. Without this a stylist (view_sales, no view_finance)
-- reads every sale in the business through this view with paid_cents = 0 — because
-- payments_select filters their rows away — and concludes the business collects nothing. A
-- silently-wrong answer is worse than a denied one. This call is safe: a security_invoker
-- view MAY call app.* — see the note above §4.
where app.has_perm(s.business_id, 'view_finance')
group by s.id, s.business_id, s.branch_id, s.client_id, s.appointment_id,
         s.kind, s.counts_as_revenue, s.amount_cents, s.occurred_at;

revoke all on public.sale_balance from anon;
grant select on public.sale_balance to authenticated;

-- NOTE on 'unpaid' vs a zero-amount sale: use_package_session() writes a $0 kind='service'
-- sale. Its amount is 0 and its paid is 0, so it lands in 'unpaid' by the `<= 0` branch, not
-- in 'paid'. That is deliberate — a $0 row has nothing to collect and belongs in neither
-- bucket, and 'unpaid' with balance_cents = 0 is harmless as long as the UI's unpaid list
-- filters `balance_cents > 0`. Called out because it WILL look like a bug in a report that
-- counts rows instead of summing balances. (Test scenario D.)

-- 1.3 The checkout RPC. Idempotent, tenant-checked, sign-disciplined.
--     Deliberately does NOT enforce "cannot exceed the balance". A tip, a deposit taken
--     before the sale exists, and a rounding-up cash payment are all legitimate overpayments,
--     and a hard guard would make the cashier's screen wrong more often than it would save a
--     mistake. Overpayment is instead SURFACED as payment_status='overpaid' so it is visible
--     rather than impossible. If the owner wants a hard stop, it is one `if` — flag it.
create or replace function public.record_payment(
  p_business        uuid,
  p_method          text,
  p_amount_cents    integer,
  p_sale            uuid    default null,
  p_appointment     uuid    default null,
  p_client          uuid    default null,
  p_staff           uuid    default null,
  p_kind            text    default 'payment',
  p_branch          uuid    default null,
  p_reference       text    default null,
  p_note            text    default null,
  p_idempotency_key text    default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_row payments; v_branch uuid; v_client uuid;
begin
  -- Taking money is a counter act (create_sales); giving it back is not (refund_sales).
  -- See the permission mapping at §1.0b.
  if p_kind = 'refund' then
    if not app.has_perm(p_business, 'refund_sales') then
      raise exception 'you do not have permission to refund in this business (refund_sales)';
    end if;
  elsif not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to take a payment in this business (create_sales)';
  end if;

  if p_sale is null and p_appointment is null then
    raise exception 'a payment must reference a sale or an appointment';
  end if;

  -- Cross-tenant guards. NOTE WHAT THESE ARE AND ARE NOT, because the first draft got this
  -- exactly backwards and called them the fix. They are ERGONOMICS: they turn a raw
  -- `23503 ... violates foreign key constraint "payments_sale_same_tenant"` into a sentence a
  -- developer can act on. They are NOT the defence — they only run if the caller chooses to
  -- come through this function, and `payments` is PostgREST-exposed, so the caller need not.
  -- The DEFENCE is the composite FKs at §1.0a, which the database enforces on every path.
  -- If you ever find yourself deleting these, fine — nothing breaks. If you find yourself
  -- deleting the FKs because "the RPC already checks", read §1.0a's measured attack first.
  if p_sale is not null and not exists (
       select 1 from sales where id = p_sale and business_id = p_business) then
    raise exception 'sale does not belong to this business';
  end if;
  if p_appointment is not null and not exists (
       select 1 from appointments where id = p_appointment and business_id = p_business) then
    raise exception 'appointment does not belong to this business';
  end if;
  if p_staff is not null and not exists (
       select 1 from staff where id = p_staff and business_id = p_business) then
    raise exception 'staff does not belong to this business';
  end if;

  -- Sign discipline applied here so callers can pass a positive number for a refund and get
  -- the right thing, rather than silently recording a payment. The table check is the
  -- backstop; this is the ergonomics.
  if p_kind = 'refund' then
    p_amount_cents := -abs(p_amount_cents);
  else
    p_amount_cents := abs(p_amount_cents);
  end if;
  if p_amount_cents = 0 then raise exception 'amount must be non-zero'; end if;

  -- Resolve branch: explicit -> the sale's -> the appointment's -> business default
  -- (the last hop is trg_payments_default_branch).
  v_branch := coalesce(p_branch,
                       (select branch_id from sales where id = p_sale),
                       (select branch_id from appointments where id = p_appointment));
  -- Same for the client, so a checkout does not have to restate who it is for.
  v_client := coalesce(p_client,
                       (select client_id from sales where id = p_sale),
                       (select client_id from appointments where id = p_appointment));

  -- IDEMPOTENCY — atomic, not check-then-insert.
  --
  -- The first draft did `select ... if found then return; end if;` and then inserted. That is
  -- a textbook race and it fails in EXACTLY the case it was written for: the cashier's
  -- double-tap. Two concurrent calls with key 'chk-1' both SELECT (neither sees the other's
  -- uncommitted row), both fall through, both INSERT — one commits, the loser gets
  -- `unique_violation: duplicate key value violates unique constraint
  -- "payments_idempotency"`. The cashier is shown a hard error for a charge that DID
  -- succeed, which is the precise outcome the header promises this design avoids ("a raise
  -- would show the cashier an error for an operation that in fact succeeded, and they would
  -- retry again"). The comment was right; the code did not implement it.
  --
  -- `on conflict ... do nothing` moves the decision into the index, where it is atomic. The
  -- loser inserts nothing, returns nothing, and re-reads the winner's row — which is
  -- committed and visible by then, because ON CONFLICT waits on the conflicting transaction.
  -- The arbiter must restate the index predicate (`where idempotency_key is not null`) to
  -- infer a PARTIAL unique index. Calls with a NULL key can never conflict on it and so
  -- always insert — a caller who declines idempotency gets none, loudly and by choice.
  insert into payments (business_id, branch_id, sale_id, appointment_id, client_id,
                        staff_id, method, kind, amount_cents, reference, note,
                        idempotency_key)
  values (p_business, v_branch, p_sale, p_appointment, v_client,
          p_staff, p_method, p_kind, p_amount_cents, p_reference, p_note,
          p_idempotency_key)
  on conflict (business_id, idempotency_key) where idempotency_key is not null
    do nothing
  returning * into v_row;

  if v_row.id is null then
    -- We lost the race (or this is a serial replay). Return the ORIGINAL row. Not an error:
    -- the caller's intent — "this payment exists exactly once" — is satisfied.
    select * into v_row from payments
      where business_id = p_business and idempotency_key = p_idempotency_key;
    if not found then
      -- Cannot happen: do-nothing without a conflicting row is impossible. If it ever does,
      -- fail loudly rather than return null and let the UI decide the charge vanished.
      raise exception 'record_payment: insert produced no row and no conflicting row exists '
                      '(business %, key %)', p_business, p_idempotency_key;
    end if;
  end if;

  return row_to_json(v_row);
end $$;
revoke execute on function public.record_payment(uuid, text, integer, uuid, uuid, uuid, uuid,
  text, uuid, text, text, text) from public, anon;
grant execute on function public.record_payment(uuid, text, integer, uuid, uuid, uuid, uuid,
  text, uuid, text, text, text) to authenticated;

-- 1.4 QUICK SALE + TENDER, ATOMICALLY. The DB half of the Q2 gap (see OPEN QUESTIONS).
--
-- THE CONFIRMED DEFECT: the UI's quick sale does `sb.from('sales').insert(...)` and stops.
-- The sale books accrual revenue; no payment row exists; the drawer is never credited. The
-- consequences compound, and the third one is the serious one:
--   1. Every quick sale reads payment_status='unpaid' forever. The unpaid list — which is
--      supposed to be a to-do list — fills with counter sales that were paid in cash on the
--      spot, and stops being read.
--   2. revenue_cash undercounts by every quick sale ever rung up, so the two revenue figures
--      diverge without limit and the owner learns to ignore the "collected" one.
--   3. THE DRAWER'S VARIANCE SIGNAL DIES. `expected` never rises for quick-sale cash, but the
--      cash is physically in the till, so every close counts MORE than expected and posts a
--      large positive close_variance. That variance is then re-anchored away, so the drawer
--      reconciles perfectly, every time, while being wrong. A real shortfall — the thing the
--      count exists to detect — arrives as a slightly-less-large positive variance and is
--      invisible. A drawer that always balances is not a drawer that is right; it is a drawer
--      that has stopped measuring. This is worse than the header's "the drawer stays empty".
--
-- CAN THE DATABASE FIX IT ALONE? No, and it is worth being exact about why rather than
-- hand-waving. The missing datum is the TENDER METHOD, and it exists nowhere in the DB. A
-- trigger on `sales` that auto-posted a payment would have to guess it, and every guess is a
-- fresh bug: guess 'cash' and every card sale credits the till with money that is not in it —
-- manufacturing the exact phantom variance we are trying to remove, in the opposite
-- direction. Guess nothing and there is no trigger. Worse, such a trigger would mark EVERY
-- sale paid at completion, deleting the completion/payment split this migration exists to
-- build and silently zeroing A/R. The method is a fact only the person at the counter has.
--
-- WHAT THE DATABASE CAN DO — and does, here: make the correct call a SINGLE call, so the UI
-- cannot do half of it. record_quick_sale() inserts the sale and its payment in one
-- transaction, under one idempotency key, or neither. Both rows or no rows.
create or replace function public.record_quick_sale(
  p_business        uuid,
  p_amount_cents    integer,
  p_method          text,                       -- REQUIRED. The datum the trigger cannot know.
  p_client          uuid    default null,       -- null = walk-in: revenue, no loyalty.
  p_staff           uuid    default null,
  p_branch          uuid    default null,
  p_note            text    default null,
  p_idempotency_key text    default null,
  p_paid            boolean default true)       -- false = put it on a tab (A/R), no payment row.
returns json language plpgsql security definer set search_path = public as $$
declare v_sale sales; v_payment json; v_existing sales;
begin
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to record a sale in this business (create_sales)';
  end if;
  if coalesce(p_amount_cents, 0) <= 0 then
    raise exception 'a quick sale must have a positive amount';
  end if;

  -- IDEMPOTENCY SPANS BOTH ROWS, AND THAT NEEDS MORE THAN record_payment's ON CONFLICT.
  -- The payments unique index cannot protect the SALE: on a replay we would insert a second
  -- `sales` row, THEN call record_payment, which would dutifully return the original payment
  -- — leaving a duplicate sale that has booked duplicate revenue, minted duplicate points and
  -- possibly fired a retention reward. That is the expensive half of a double-tap, and a
  -- check-then-insert here would race exactly the way record_payment's did (D6).
  --
  -- So: serialise on the key itself. pg_advisory_xact_lock makes concurrent replays of the
  -- SAME key strictly sequential, so the second one sees the first one's committed rows and
  -- takes the early return below. It is transaction-scoped (released at commit/rollback, no
  -- unlock path to forget), and it contends only with the identical key — two different
  -- checkouts never block each other. Different keys, different lock; no key, no lock.
  if p_idempotency_key is not null then
    perform pg_advisory_xact_lock(hashtextextended(p_business::text || ':' || p_idempotency_key, 0));
    select s.* into v_existing from sales s
      join payments p on p.sale_id = s.id
     where p.business_id = p_business and p.idempotency_key = p_idempotency_key;
    if found then
      -- A replay is a SUCCESS, not an error. Return the original sale so the UI reprints the
      -- original receipt instead of telling the cashier to ring it up again.
      return json_build_object('sale', row_to_json(v_existing), 'replayed', true);
    end if;
  end if;

  -- The sale. kind='quick_sale' is snapshotted by v10.1's BEFORE INSERT trigger and the
  -- loyalty engine fires on the AFTER INSERT, exactly as it does for a UI-written row. This
  -- RPC changes nothing about what a quick sale MEANS; it only stops it arriving half-formed.
  insert into sales (business_id, client_id, kind, amount_cents, branch_id, staff_id, note)
  values (p_business, p_client, 'quick_sale', p_amount_cents, p_branch, p_staff, p_note)
  returning * into v_sale;

  if p_paid then
    v_payment := public.record_payment(
      p_business        => p_business,
      p_method          => p_method,
      p_amount_cents    => p_amount_cents,
      p_sale            => v_sale.id,
      p_client          => p_client,
      p_staff           => p_staff,
      p_kind            => 'payment',
      p_branch          => coalesce(p_branch, v_sale.branch_id),
      p_idempotency_key => p_idempotency_key);
  end if;

  return json_build_object('sale', row_to_json(v_sale), 'payment', v_payment,
                           'replayed', false);
end $$;
revoke execute on function public.record_quick_sale(uuid, integer, text, uuid, uuid, uuid,
  text, text, boolean) from public, anon;
grant execute on function public.record_quick_sale(uuid, integer, text, uuid, uuid, uuid,
  text, text, boolean) to authenticated;

-- ====================================================================================
-- 2. CASH DRAWER
-- ====================================================================================

-- 2.1 Sessions (the "close count" flow). A branch has at most one OPEN session at a time.
create table public.cash_drawer_sessions (
  id                  uuid primary key default gen_random_uuid(),
  business_id         uuid not null references public.businesses(id) on delete cascade,
  -- ⚠️ THE INLINE FK HERE CARRIED `on delete cascade` AND IT IS DELETED ON PURPOSE. The
  -- composite cash_drawer_sessions_branch_same_tenant below is now the only FK on this pair
  -- (two would be PGRST201), and it is NO ACTION. So: DELETING A BRANCH THAT HAS EVER OPENED
  -- A DRAWER NOW RAISES INSTEAD OF SILENTLY DELETING ITS CASH HISTORY. That is a deliberate
  -- upgrade, not collateral damage, for three reasons:
  --   1. It is this file's own rule, applied consistently. §1.0a already accepts exactly this
  --      for payments ("a branch with a payment attached can no longer be hard-deleted —
  --      cancel, don't delete") on the grounds that it is correct for a money ledger. The
  --      drawer is the MORE sensitive half: it is the system of record for physical cash.
  --   2. The cascade was already unreachable on the movements side. cash_drawer_movements has
  --      trg_cash_drawer_movements_append_only, a BEFORE DELETE FOR EACH ROW trigger that
  --      raises unconditionally — and ON DELETE CASCADE fires row triggers. So a branch delete
  --      could never actually complete; it aborted with "cash_drawer_movements is an
  --      append-only ledger: DELETE is not permitted". Keeping the cascade would only preserve
  --      a promise the file's own trigger already breaks.
  --   3. There is a real retire path that is not deletion: branches.active = false (v11a's
  --      "accepting bookings" flag). Nothing legitimate needs branch rows destroyed.
  -- A branch created by mistake has no sessions and still deletes cleanly. NO ACTION only
  -- blocks the delete once real cash history exists — which is precisely when it should.
  branch_id           uuid not null,
  opened_at           timestamptz not null default now(),
  opened_by           uuid default auth.uid(),
  opening_float_cents integer not null default 0 check (opening_float_cents >= 0),
  closed_at           timestamptz,
  closed_by           uuid,
  -- Both are FACTS RECORDED AT CLOSE, not a running balance: what the system expected, and
  -- what a human physically counted. Frozen forever once written.
  expected_cents      integer,
  counted_cents       integer,
  note                text,
  check ((closed_at is null and counted_cents is null and expected_cents is null)
      or (closed_at is not null and counted_cents is not null and expected_cents is not null))
);
create unique index one_open_drawer_per_branch
  on public.cash_drawer_sessions (branch_id) where closed_at is null;
create index cash_drawer_sessions_branch on public.cash_drawer_sessions (branch_id, opened_at);

alter table public.cash_drawer_sessions
  add constraint cash_drawer_sessions_id_business_key unique (id, business_id),
  add constraint cash_drawer_sessions_branch_same_tenant foreign key (branch_id, business_id)
      references public.branches(id, business_id);

alter table public.cash_drawer_sessions enable row level security;
create policy cash_drawer_sessions_select on public.cash_drawer_sessions for select to authenticated
  using (app.has_perm(business_id, 'view_finance'));
-- READ-ONLY from PostgREST. open_drawer()/close_drawer() are SECURITY DEFINER, so they do not
-- need — and must not have — a direct write grant behind them: a raw INSERT here could open a
-- second session behind the one_open_drawer_per_branch race, and a raw UPDATE could set
-- expected_cents to whatever makes the variance disappear. The whole point of computing
-- `expected` inside close_drawer is defeated if the client can just write it.
revoke all on public.cash_drawer_sessions from anon;
revoke insert, update, delete, truncate on public.cash_drawer_sessions from authenticated;
grant select on public.cash_drawer_sessions to authenticated;
create trigger trg_cash_drawer_sessions_audit
  after insert or update or delete on public.cash_drawer_sessions
  for each row execute function app.audit();

-- 2.2 Movements — append-only, signed. THE system of record for physical cash.
create table public.cash_drawer_movements (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  -- Inline FKs deleted on all four columns below; the composite _same_tenant FKs are the only
  -- FKs on these pairs. See the create table for cash_drawer_sessions for the full argument on
  -- why branch_id's `on delete cascade` in particular is dropped rather than preserved — in
  -- short, it was already unreachable through this table's own append-only DELETE trigger, and
  -- silently destroying the physical-cash ledger when a branch row is removed is the opposite
  -- of what an append-only money ledger is for.
  branch_id   uuid not null,
  session_id  uuid,
  -- 'open_float'     — the till float when a session opens.
  -- 'sale_cash'      — auto-posted from a cash payment (positive) or cash refund (negative).
  -- 'pay_in'         — manual cash added (owner tops up change).
  -- 'pay_out'        — manual cash removed (petty cash, bank run). NEGATIVE.
  -- 'close_variance' — (counted - expected) at close. Re-anchors the running sum to reality.
  kind        text not null check (kind in
                ('open_float','sale_cash','pay_in','pay_out','close_variance')),
  amount_cents integer not null,     -- signed; 0 is legal ONLY for a zero close_variance.
  payment_id  uuid,
  staff_id    uuid,
  note        text,
  occurred_at timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  check (kind <> 'pay_out' or amount_cents < 0),
  check (kind not in ('open_float','pay_in','sale_cash') or amount_cents <> 0)
);
-- One drawer movement per payment, ever. THE anti-double-credit guard: a retried trigger,
-- a replayed RPC or a backfill cannot credit the same $50 twice.
create unique index one_drawer_movement_per_payment
  on public.cash_drawer_movements (payment_id) where payment_id is not null;
create index cash_drawer_movements_branch on public.cash_drawer_movements (branch_id, occurred_at);
create index cash_drawer_movements_session on public.cash_drawer_movements (session_id);

alter table public.cash_drawer_movements
  add constraint cash_drawer_movements_branch_same_tenant foreign key (branch_id, business_id)
      references public.branches(id, business_id),
  add constraint cash_drawer_movements_session_same_tenant foreign key (session_id, business_id)
      references public.cash_drawer_sessions(id, business_id),
  add constraint cash_drawer_movements_payment_same_tenant foreign key (payment_id, business_id)
      references public.payments(id, business_id),
  add constraint cash_drawer_movements_staff_same_tenant foreign key (staff_id, business_id)
      references public.staff(id, business_id);

alter table public.cash_drawer_movements enable row level security;
create policy cash_drawer_movements_select on public.cash_drawer_movements for select to authenticated
  using (app.has_perm(business_id, 'view_finance'));
-- INSERT is DENIED to PostgREST entirely — there is no insert policy and no insert grant.
-- Every legitimate movement has a SECURITY DEFINER author: 'sale_cash' from the payment
-- trigger, 'open_float'/'close_variance' from open_drawer/close_drawer, 'pay_in'/'pay_out'
-- from record_drawer_movement. A direct INSERT is by definition cash appearing in the ledger
-- with no event behind it — which is the one thing a cash drawer exists to make impossible.
-- The first draft granted it to every member, so a stylist could post a 'sale_cash' row with
-- payment_id NULL and make any shortfall reconcile.
revoke all on public.cash_drawer_movements from anon;
revoke insert, update, delete, truncate on public.cash_drawer_movements from authenticated;
grant select on public.cash_drawer_movements to authenticated;
create trigger trg_cash_drawer_movements_append_only
  before update or delete on public.cash_drawer_movements
  for each row execute function app.forbid_mutation();
create trigger trg_cash_drawer_movements_audit
  after insert on public.cash_drawer_movements
  for each row execute function app.audit();

-- 2.3 Which session is currently open at a branch.
create or replace function app.open_drawer_session(p_branch uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.cash_drawer_sessions
   where branch_id = p_branch and closed_at is null
   limit 1
$$;

-- 2.4 THE AUTO-CREDIT. "Cash sales auto-credit the drawer" — live-confirmed
--     ($0 -> $50 -> $75 -> $100), automatic, no manual pay-in.
--
--     Gates on method='cash' ONLY. Note what it deliberately does NOT look at: sale kind,
--     revenue policy, or anything from v10. The $25 cash gift card credited the competitor's
--     drawer despite not being revenue — because cash is cash. That behaviour is free here
--     precisely because this trigger is ignorant of accounting.
--
--     A cash payment at a branch with NO open session still posts a movement (session_id
--     null). Refusing it would mean cash is taken and not recorded, which is worse than
--     unattributed cash: the drawer's running total stays true either way, and the movement
--     is adopted by reporting via branch_id.
create or replace function app.on_payment_drawer()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.method = 'cash' and new.branch_id is not null then
    insert into cash_drawer_movements (business_id, branch_id, session_id, kind,
                                       amount_cents, payment_id, staff_id, occurred_at, note)
    values (new.business_id, new.branch_id, app.open_drawer_session(new.branch_id),
            'sale_cash', new.amount_cents, new.id, new.staff_id, new.occurred_at,
            'auto: ' || new.kind)
    on conflict do nothing;   -- one_drawer_movement_per_payment
  end if;
  return new;
end $$;

create trigger trg_payment_drawer
  after insert on public.payments
  for each row execute function app.on_payment_drawer();

-- 2.5 Derived expected balance. Append-only sum, no stored total.
--     Because close_variance re-anchors the sum to the counted cash, this figure IS the
--     physical cash expected in the drawer right now, all-time, with no reset semantics.
--     ❌ RETRACTED — THE FIRST DRAFT'S REASONING HERE WAS FALSE, AND IT WAS LOAD-BEARING.
--     It said: this view is security_invoker, `authenticated` has no USAGE on schema `app`,
--     therefore a security_invoker view may not call app.*, therefore open_session_id must be
--     an inlined subquery and therefore get_revenue_summary (§4) must be an RPC. The premise
--     is wrong and the trap does not exist. Tested directly against this database, rolled
--     back:
--         create function app._probe_ok() returns int language sql stable as 'select 42';
--         create view public._probe_v with (security_invoker = on) as select app._probe_ok();
--         set local role authenticated;  select * from public._probe_v;   -->  42
--     `has_schema_privilege('authenticated','app','USAGE')` is indeed false — that part was
--     checked and is true — but it is IRRELEVANT here. Schema USAGE is a NAME-RESOLUTION
--     privilege, checked when a statement is PARSED. A view stores an already-parsed tree
--     holding the function's OID; no name is resolved at SELECT time, so no USAGE check
--     happens. What IS re-checked per call is EXECUTE on the function itself, and the default
--     ACL (verified above) grants `authenticated=X` on every function in every schema this
--     project creates. Same reason v10's `get_sale_policy` comment is wrong.
--
--     This matters twice over. Once here: the inlined subquery is fine but its justification
--     was fiction, so anyone who trusted it would go on contorting future views around a
--     constraint that isn't there. And once at §4, where the same false premise was the whole
--     argument for get_revenue_summary being an RPC — an argument that is now withdrawn and
--     replaced with the real reason.
--
--     The inline subquery STAYS, on its own merits: it is one correlated scalar select, the
--     planner folds it into the same plan, and it removes a dependency for no cost. That is
--     a preference, not a requirement, and it is now labelled as one.
create view public.cash_drawer_balance
with (security_invoker = on) as
select b.id                                        as branch_id,
       b.business_id,
       b.name                                      as branch_name,
       coalesce(sum(m.amount_cents), 0)::integer   as expected_cents,
       (select ds.id from public.cash_drawer_sessions ds
         where ds.branch_id = b.id and ds.closed_at is null
         limit 1)                                  as open_session_id,
       max(m.occurred_at)                          as last_movement_at
from public.branches b
left join public.cash_drawer_movements m on m.branch_id = b.id
where app.has_perm(b.business_id, 'view_finance')
group by b.id, b.business_id, b.name;

revoke all on public.cash_drawer_balance from anon;
grant select on public.cash_drawer_balance to authenticated;

-- Per-session view for the close screen.
create view public.cash_drawer_session_summary
with (security_invoker = on) as
select s.id            as session_id,
       s.business_id,
       s.branch_id,
       s.opened_at,
       s.closed_at,
       s.opening_float_cents,
       s.expected_cents,
       s.counted_cents,
       (s.counted_cents - s.expected_cents)          as variance_cents,
       coalesce(sum(m.amount_cents) filter (where m.kind = 'sale_cash'), 0)::integer as cash_sales_cents,
       coalesce(sum(m.amount_cents) filter (where m.kind = 'pay_in'),    0)::integer as pay_in_cents,
       coalesce(sum(m.amount_cents) filter (where m.kind = 'pay_out'),   0)::integer as pay_out_cents,
       coalesce(sum(m.amount_cents), 0)::integer                                     as session_net_cents
from public.cash_drawer_sessions s
left join public.cash_drawer_movements m on m.session_id = s.id
where app.has_perm(s.business_id, 'view_finance')
group by s.id;

revoke all on public.cash_drawer_session_summary from anon;
grant select on public.cash_drawer_session_summary to authenticated;

-- 2.6 Drawer RPCs.
create or replace function public.open_drawer(
  p_business uuid, p_branch uuid, p_float_cents integer default 0)
returns json language plpgsql security definer set search_path = public as $$
declare v_row cash_drawer_sessions;
begin
  -- Opening and closing a till is an accounting act, not a counter act (§1.0b, and Q6).
  if not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to operate the cash drawer (view_finance)';
  end if;
  if not exists (select 1 from branches where id = p_branch and business_id = p_business) then
    raise exception 'branch does not belong to this business';
  end if;
  if app.open_drawer_session(p_branch) is not null then
    raise exception 'this branch already has an open drawer session';
  end if;

  insert into cash_drawer_sessions (business_id, branch_id, opening_float_cents)
  values (p_business, p_branch, coalesce(p_float_cents, 0))
  returning * into v_row;

  -- The float is real cash and must be in the running sum, or every close is short by it.
  if coalesce(p_float_cents, 0) > 0 then
    insert into cash_drawer_movements (business_id, branch_id, session_id, kind,
                                       amount_cents, note)
    values (p_business, p_branch, v_row.id, 'open_float', p_float_cents, 'opening float');
  end if;

  return row_to_json(v_row);
end $$;
revoke execute on function public.open_drawer(uuid, uuid, integer) from public, anon;
grant execute on function public.open_drawer(uuid, uuid, integer) to authenticated;

-- Manual pay-in / pay-out. p_amount is given POSITIVE; direction comes from p_kind.
create or replace function public.record_drawer_movement(
  p_business uuid, p_branch uuid, p_kind text, p_amount_cents integer,
  p_note text default null, p_staff uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_row cash_drawer_movements; v_amt integer;
begin
  -- Moving cash in or out of the till by hand is the single easiest way to hide a shortfall.
  if not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to move cash in or out of the drawer (view_finance)';
  end if;
  if not exists (select 1 from branches where id = p_branch and business_id = p_business) then
    raise exception 'branch does not belong to this business';
  end if;
  if p_kind not in ('pay_in','pay_out') then
    raise exception 'kind must be pay_in or pay_out (sale_cash is posted automatically; open_float and close_variance are posted by open_drawer/close_drawer)';
  end if;
  if coalesce(p_amount_cents, 0) = 0 then raise exception 'amount must be non-zero'; end if;

  v_amt := case when p_kind = 'pay_out' then -abs(p_amount_cents) else abs(p_amount_cents) end;

  insert into cash_drawer_movements (business_id, branch_id, session_id, kind,
                                     amount_cents, staff_id, note)
  values (p_business, p_branch, app.open_drawer_session(p_branch), p_kind, v_amt, p_staff, p_note)
  returning * into v_row;

  return row_to_json(v_row);
end $$;
revoke execute on function public.record_drawer_movement(uuid, uuid, text, integer, text, uuid)
  from public, anon;
grant execute on function public.record_drawer_movement(uuid, uuid, text, integer, text, uuid)
  to authenticated;

-- Close + reconcile. Expected is computed HERE (not passed in) so a client cannot hide a
-- variance by telling us what it expected.
create or replace function public.close_drawer(
  p_business uuid, p_session uuid, p_counted_cents integer, p_note text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_s cash_drawer_sessions; v_expected integer; v_variance integer;
begin
  if not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to close the cash drawer (view_finance)';
  end if;
  select * into v_s from cash_drawer_sessions
    where id = p_session and business_id = p_business for update;
  if not found then raise exception 'drawer session not found'; end if;
  if v_s.closed_at is not null then raise exception 'drawer session already closed'; end if;
  if p_counted_cents is null or p_counted_cents < 0 then
    raise exception 'counted amount must be zero or positive';
  end if;

  -- Expected = the whole running sum for this branch, which after the previous close was
  -- re-anchored to that close's counted cash. So this is "float + everything since we last
  -- counted", which is what a person counting a till means by "expected".
  select coalesce(sum(amount_cents), 0) into v_expected
    from cash_drawer_movements where branch_id = v_s.branch_id;

  v_variance := p_counted_cents - v_expected;

  update cash_drawer_sessions
     set closed_at = now(), closed_by = auth.uid(),
         expected_cents = v_expected, counted_cents = p_counted_cents,
         note = coalesce(p_note, note)
   where id = p_session;

  -- Re-anchor. After this the running sum equals the cash a human actually counted, so the
  -- next session starts from truth instead of inheriting the drift.
  if v_variance <> 0 then
    insert into cash_drawer_movements (business_id, branch_id, session_id, kind,
                                       amount_cents, note)
    values (p_business, v_s.branch_id, p_session, 'close_variance', v_variance,
            'close: counted ' || p_counted_cents || ' vs expected ' || v_expected);
  end if;

  return json_build_object('session_id', p_session, 'expected_cents', v_expected,
                          'counted_cents', p_counted_cents, 'variance_cents', v_variance);
end $$;
revoke execute on function public.close_drawer(uuid, uuid, integer, text) from public, anon;
grant execute on function public.close_drawer(uuid, uuid, integer, text) to authenticated;

-- ====================================================================================
-- 3. EXPENSES
-- ====================================================================================

-- 3.1 Recurring templates. Materialise real rows (see header).
create table public.expense_recurrences (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references public.businesses(id) on delete cascade,
  -- Inline FK deleted; expense_recurrences_branch_same_tenant below is the only FK on this
  -- pair. NO ACTION, so a branch with recurring expenses must be deactivated, not deleted.
  branch_id      uuid,
  name           text not null,
  category       text,
  supplier       text,
  amount_cents   integer not null check (amount_cents >= 0),
  currency       text not null default 'SGD',
  fx_rate_to_base numeric not null default 1 check (fx_rate_to_base > 0),
  cadence        text not null check (cadence in ('weekly','monthly','annual')),
  starts_on      date not null default current_date,
  ends_on        date,
  next_run_on    date not null,
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  check (ends_on is null or ends_on >= starts_on)
);
create index expense_recurrences_due on public.expense_recurrences (next_run_on) where active;
alter table public.expense_recurrences
  add constraint expense_recurrences_id_business_key unique (id, business_id),
  add constraint expense_recurrences_branch_same_tenant foreign key (branch_id, business_id)
      references public.branches(id, business_id);
alter table public.expense_recurrences enable row level security;
-- A recurring expense is a standing instruction to charge the business money every month.
-- It is a bookkeeping object, not a counter object: view_finance (owner, manager).
create policy expense_recurrences_all on public.expense_recurrences for all to authenticated
  using (app.has_perm(business_id, 'view_finance'))
  with check (app.has_perm(business_id, 'view_finance'));
revoke all on public.expense_recurrences from anon;
revoke truncate on public.expense_recurrences from authenticated;
grant select, insert, update, delete on public.expense_recurrences to authenticated;
create trigger trg_expense_recurrences_audit
  after insert or update or delete on public.expense_recurrences
  for each row execute function app.audit();

-- 3.2 Expenses.
create table public.expenses (
  id              uuid primary key default gen_random_uuid(),
  business_id     uuid not null references public.businesses(id) on delete cascade,
  -- Inline FK deleted; expenses_branch_same_tenant below is the only FK on this pair.
  branch_id       uuid,
  category        text,
  supplier        text,
  description     text,
  amount_cents    integer not null check (amount_cents >= 0),
  currency        text not null default 'SGD',
  -- Frozen at entry. Re-valuing history at today's rate would make last month's Net move.
  -- ⚖️ We do not source rates. The caller supplies one; 1 for same-currency.
  fx_rate_to_base numeric not null default 1 check (fx_rate_to_base > 0),
  occurred_on     date not null default current_date,
  -- Void, not delete (live: a TOGGLE). Reversible; every flip is audited.
  voided_at       timestamptz,
  voided_by       uuid,
  -- Inline FK deleted; expenses_recurrence_same_tenant below is the only FK on this pair.
  -- ⚠️ THE ONE REACHABLE BEHAVIOUR CHANGE IN THIS FIX — FLAGGED, NOT BURIED. The inline FK was
  -- `on delete set null`; the composite is NO ACTION. Unlike branches/appointments/staff (which
  -- have no delete grant on the money path), `expense_recurrences` DOES grant DELETE to
  -- `authenticated` (§3.1), so "delete this recurring expense" is a live UI path. It will now
  -- RAISE a foreign-key violation once the recurrence has materialised even one expense row,
  -- instead of quietly orphaning those rows with recurrence_id = null.
  -- Deliberate, and the better of the two: nulling recurrence_id destroys the provenance of a
  -- real cost AND silently drops the row out of one_expense_per_recurrence_period's partial
  -- unique index (`where recurrence_id is not null`) — the guard that stops the cron
  -- double-billing rent. The retire path is expense_recurrences.active = false, which already
  -- exists for exactly this purpose. The UI should offer "stop this recurring expense", not
  -- "delete" — worth confirming with the owner before v11b ships. (Q9.)
  recurrence_id   uuid,
  -- The period this row materialises, for recurring rows. Null for one-off.
  period_on       date,
  note            text,
  created_at      timestamptz not null default now(),
  created_by      uuid default auth.uid()
);
-- A cron double-run, or two overlapping runs, cannot bill the same rent twice.
create unique index one_expense_per_recurrence_period
  on public.expenses (recurrence_id, period_on)
  where recurrence_id is not null;
create index expenses_business_date on public.expenses (business_id, occurred_on);
create index expenses_branch_date   on public.expenses (branch_id, occurred_on);
create index expenses_live          on public.expenses (business_id, occurred_on) where voided_at is null;

alter table public.expenses
  add constraint expenses_branch_same_tenant foreign key (branch_id, business_id)
      references public.branches(id, business_id),
  add constraint expenses_recurrence_same_tenant foreign key (recurrence_id, business_id)
      references public.expense_recurrences(id, business_id);

alter table public.expenses enable row level security;
-- Expenses ARE the P&L's other half. A stylist reading them reads the owner's rent, the
-- owner's supplier terms and, by subtraction, the owner's margin. view_finance.
create policy expenses_all on public.expenses for all to authenticated
  using (app.has_perm(business_id, 'view_finance'))
  with check (app.has_perm(business_id, 'view_finance'));
revoke all on public.expenses from anon;
revoke truncate on public.expenses from authenticated;
grant select, insert, update, delete on public.expenses to authenticated;
create trigger trg_expenses_audit
  after insert or update or delete on public.expenses
  for each row execute function app.audit();

-- 3.3 Void / unvoid. An RPC rather than a raw update so the toggle is auditable, symmetric,
--     and cannot be half-applied (voided_at set, voided_by not).
create or replace function public.set_expense_void(
  p_business uuid, p_expense uuid, p_void boolean)
returns json language plpgsql security definer set search_path = public as $$
declare v_row expenses;
begin
  if not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to void an expense (view_finance)';
  end if;
  update expenses
     set voided_at = case when p_void then now() else null end,
         voided_by = case when p_void then auth.uid() else null end
   where id = p_expense and business_id = p_business
  returning * into v_row;
  if not found then raise exception 'expense not found'; end if;
  return row_to_json(v_row);
end $$;
revoke execute on function public.set_expense_void(uuid, uuid, boolean) from public, anon;
grant execute on function public.set_expense_void(uuid, uuid, boolean) to authenticated;

-- 3.4 The recurring materialiser. Daily pg_cron, alongside the existing points-expiry and
--     membership-renewal jobs. Modelled on app.run_membership_renewals(): a bounded
--     catch-up loop (guard 60) so a job that has not run for a while backfills instead of
--     posting one row and losing the rest, and cannot spin forever on bad data.
create or replace function app.run_expense_recurrences()
returns void language plpgsql security definer set search_path = public as $$
declare r record; guard integer; v_next date;
begin
  for r in select * from expense_recurrences
      where active and next_run_on <= current_date loop
    guard := 0;
    v_next := r.next_run_on;
    while v_next <= current_date and guard < 60 loop
      exit when r.ends_on is not null and v_next > r.ends_on;
      insert into expenses (business_id, branch_id, category, supplier, description,
                            amount_cents, currency, fx_rate_to_base, occurred_on,
                            recurrence_id, period_on, note)
      values (r.business_id, r.branch_id, r.category, r.supplier, r.name,
              r.amount_cents, r.currency, r.fx_rate_to_base, v_next,
              r.id, v_next, 'auto: recurring expense')
      on conflict do nothing;      -- one_expense_per_recurrence_period
      v_next := case r.cadence
                  when 'weekly' then v_next + 7
                  when 'annual' then (v_next + interval '1 year')::date
                  else (v_next + interval '1 month')::date
                end;
      guard := guard + 1;
    end loop;
    update expense_recurrences
       set next_run_on = v_next,
           active = case when r.ends_on is not null and v_next > r.ends_on then false else active end
     where id = r.id;
  end loop;
end $$;

-- 19:20 UTC = 03:20 SGT, after points-expiry (19:00) and membership-renewals (19:10), so the
-- three daily jobs do not contend and Net is computed on a settled day.
select cron.schedule('frenly-expense-recurrences', '20 19 * * *',
                     'select app.run_expense_recurrences()');

-- ====================================================================================
-- 4. DERIVED REPORTING — Net, and the accrual/cash revenue pair
-- ====================================================================================
-- ====================================================================================
-- WHY THIS IS AN RPC — the first draft's answer was fiction; here is the real one.
-- ====================================================================================
-- ❌ RETRACTED: "it must be an RPC because it calls app.sale_policy_set() and a
--    security_invoker view cannot call app.* without schema USAGE." Both halves are dead.
--    The premise is false (proved by experiment — see the note above cash_drawer_balance;
--    a security_invoker view calls app.* fine as `authenticated`), AND the function no
--    longer calls app.sale_policy_set() at all, because calling it was the P0.
--
-- ✅ THE REAL REASON, which stands on its own: this function takes p_business from the
--    caller and must therefore PROVE the caller belongs to it before returning aggregates.
--    A view has no argument to check. Every filter here is `business_id = p_business`, and
--    an aggregate over a tenant is exactly the kind of thing that must fail closed and
--    LOUDLY ('you do not have permission…') rather than silently return zeros — which is
--    what a view relying on RLS would do for a stylist, and a zero is indistinguishable
--    from "a quiet week". It is also a multi-figure report over five relations with one
--    date window; a function is the honest shape for that.
--
-- ====================================================================================
-- REVENUE IS READ OFF THE SALE. THIS IS THE FIX FOR THE P0. Read it before editing.
-- ====================================================================================
-- The first draft of this function did:
--     select array_agg(kind) filter (where counts_as_revenue) from app.sale_policy_set(...)
--     ... where s.kind = any(v_kinds)
-- i.e. it resolved TODAY'S policy for a kind and applied it to sales recorded years ago.
-- That is the exact read-time join v10.1 exists to delete — reproduced verbatim, in the
-- migration that lands immediately after the one that fixes it.
--
-- MEASURED (live QA tenant, one rolled-back transaction, one date window, same instant):
--     baseline                       get_revenue_summary 28000  |  snapshot truth 28000  ✅
--     then set_sale_policy(package, counts_as_revenue => false)
--     then reclassify_sale_policy(<a 5000 quick_sale>, false, '<audited reason>')
--     AFTER                          get_revenue_summary 18000  |  snapshot truth 23000  ❌
--   The 5000 gap decomposes exactly, and each half is a separate defect:
--     -10000  a COMPLETED package sale, snapshot counts_as_revenue = true, silently left
--             historical revenue because a FORWARD-LOOKING config toggle was flipped
--             afterwards. The original P0, byte for byte.
--     + 5000  a sale an owner had FORMALLY RESTATED to non-revenue through the audited
--             reclassify_sale_policy() path was still counted, because v_kinds looks at
--             `kind` and the restatement lives in `counts_as_revenue`. The one supported
--             way to restate the books had no effect on the books.
--
-- THE RULE, now structural rather than remembered: **every revenue figure in this function
-- reads s.counts_as_revenue — the row's own immutable snapshot. v_kinds is gone from the
-- accrual leg, the cash leg and the receivables leg. There is no live policy read left in
-- this file.** A firm that flips `package` to non-revenue changes what its NEXT package sale
-- means and nothing else; a firm that restates a specific sale sees that sale move, today,
-- in this report. Both were broken; both are now the same one-column read.
--
-- `revenue_kinds` is REMOVED from the return payload. It described forward-looking config
-- while sitting in a historical report — the exact category error that produced the bug, and
-- an open invitation to the next reader to join it back against `sales`. Settings screens
-- read get_sale_policy() for that; it describes the future and says so.
create or replace function public.get_revenue_summary(
  p_business uuid, p_from date, p_to date, p_branch uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_accrual bigint; v_cash bigint; v_expenses bigint;
        v_unpaid bigint; v_collected bigint;
begin
  if not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to view finance for this business (view_finance)';
  end if;

  -- ACCRUAL: recognised at completion, judged by the row's own snapshot.
  select coalesce(sum(s.amount_cents), 0) into v_accrual
    from sales s
   where s.business_id = p_business
     and s.counts_as_revenue
     and s.occurred_at::date between p_from and p_to
     and (p_branch is null or s.branch_id = p_branch);

  -- CASH: recognised at payment, against revenue-counting sales only. The competitor's
  -- "Revenue (Paid)". Refunds net off automatically (negative rows).
  --
  -- THE JOIN IS sale_balance's JOIN, AND IT MUST BE. The first draft wrote
  -- `join sales s on s.id = p.sale_id`, which silently dropped EVERY DEPOSIT — a deposit is
  -- written at booking with sale_id NULL and appointment_id set (that is the linkage trick
  -- this file's own header is built around) and is resolved to its sale only through the
  -- appointment. Measured: a 2000 deposit + a 3000 balance payment on a 5000 sale gave
  -- sale_balance = 'paid', balance 0 — and revenue_cash 3000, unpaid_balance 0. 2000 of
  -- real, collected, delivered-against money existed in NEITHER figure. It was not revenue
  -- and it was not receivable; it had left the accounting model entirely while sitting in
  -- the drawer. Two identical joins are not duplication here — they are the same predicate,
  -- and the bug was that there was only one of them.
  select coalesce(sum(p.amount_cents), 0) into v_cash
    from payments p
    join sales s
      on  s.id = p.sale_id
       or (p.sale_id is null
           and p.appointment_id is not null
           and s.appointment_id = p.appointment_id)
   where p.business_id = p_business
     and s.counts_as_revenue
     and p.occurred_at::date between p_from and p_to
     and (p_branch is null or p.branch_id = p_branch);
  -- No fan-out: sales.appointment_id is UNIQUE (one_sale_per_appointment, v6), so a payment
  -- matches at most one sale on either branch of the OR, and the branches are disjoint by
  -- construction (`p.sale_id is null` vs `s.id = p.sale_id`).
  --
  -- ⚖️ A REAL PROPERTY, NOT A BUG, AND IT WILL BE QUERIED: a deposit becomes cash revenue
  -- DATED AT THE DEPOSIT, retroactively, on the day its appointment completes. Book a
  -- January deposit, deliver in March, and January's revenue_cash goes up when March's sale
  -- lands. Cash accounting says money is recognised when it arrives, so this is right — but
  -- it means revenue_cash for a CLOSED period is not frozen the way revenue_accrual is.
  -- Deposits held against undelivered appointments are visible in the meantime as
  -- cash_collected minus revenue_cash. If the owner needs a hard period close, that is a
  -- deferred-revenue liability account and a real conversation. Flagged as Q7.

  -- ALL cash collected, regardless of revenue policy: gift cards, deposits, no-show fees.
  -- The live-confirmed "cash collected is not revenue" distinction, as a number.
  select coalesce(sum(p.amount_cents), 0) into v_collected
    from payments p
   where p.business_id = p_business
     and p.occurred_at::date between p_from and p_to
     and (p_branch is null or p.branch_id = p_branch);

  -- Receivables: the gap the split creates. balance_cents > 0 excludes the $0 package-session
  -- rows (see the NOTE on sale_balance).
  select coalesce(sum(b.balance_cents), 0) into v_unpaid
    from sale_balance b
   where b.business_id = p_business
     and b.counts_as_revenue                       -- the snapshot, not today's policy
     and b.balance_cents > 0
     and b.occurred_at::date between p_from and p_to
     and (p_branch is null or b.branch_id = p_branch);

  select coalesce(sum(round(e.amount_cents * e.fx_rate_to_base)), 0) into v_expenses
    from expenses e
   where e.business_id = p_business
     and e.voided_at is null                       -- voided expenses never count
     and e.occurred_on between p_from and p_to
     and (p_branch is null or e.branch_id = p_branch);

  return json_build_object(
    'from', p_from, 'to', p_to, 'branch_id', p_branch,
    'revenue_accrual_cents', v_accrual,
    'revenue_cash_cents',    v_cash,
    'cash_collected_cents',  v_collected,
    'unpaid_balance_cents',  v_unpaid,
    'expenses_cents',        v_expenses,
    -- TWO Nets, because there are two revenues and picking one silently would be the bug.
    -- The UI must label them; see the UI NOTE.
    'net_accrual_cents',     v_accrual - v_expenses,
    'net_cash_cents',        v_cash    - v_expenses);
    -- `revenue_kinds` deliberately NOT returned — see the header of this function.
end $$;
revoke execute on function public.get_revenue_summary(uuid, date, date, uuid) from public, anon;
grant execute on function public.get_revenue_summary(uuid, date, date, uuid) to authenticated;

-- 4.1 Commission — DATA FOUNDATION ONLY (⚠️ UO-1, unapproved; see v11a's header).
--     This view shows the arithmetic. It does not pay anyone, has no period close, and no
--     payout ledger. Resolution, most specific first:
--        kind='service' -> services.commission_bps -> staff.commission_service_bps -> 0
--        other kinds    -> staff.commission_product_bps                            -> 0
--     ...gated on staff.commission_starts_on. The service for a sale is reached through the
--     appointment (sales has no service_id), so a service-kind sale with no appointment can
--     only ever use the staff default — correct, and worth knowing.
--
--     AUDITED FOR THE P0 (the reviewer asked; here is the answer with the reasoning):
--     this view does NOT reproduce it. It resolves nothing from app.sale_policy_set() and
--     never asks whether a kind is revenue — commission is owed on what the staff member
--     rang up, which is a fact of the sale, not an accounting classification of it. It reads
--     `s.kind` only to choose between the SERVICE and PRODUCT rate, and `kind` is itself an
--     immutable column on the sale (v10.1 freezes it), so there is no live lookup to drift.
--     It IS still read-time-resolved against staff.commission_*_bps and services.commission_bps,
--     which ARE mutable: give a stylist a raise today and last quarter's commission_cents
--     move. That is the same SHAPE of defect as the P0 — history reinterpreted by a
--     forward-looking config change — and it is NOT fixed here, deliberately:
--       * Nothing consumes it. There is no payout ledger, no period close, no money moves
--         (UO-1: payroll is in scope but unbuilt). A number nobody has been paid against
--         cannot be restated wrongly.
--       * The fix is the same one v10.1 applied to `sales`: snapshot rate_bps onto the sale
--         at insert. That belongs in the migration that builds the payout ledger, where a
--         rate can be frozen against something that was actually paid.
--     Recorded as Q8 so it is a known debt with a known fix, not a landmine. Do NOT build
--     payroll on this view without doing that first.
create view public.sale_commission
with (security_invoker = on) as
select s.id            as sale_id,
       s.business_id,
       s.branch_id,
       s.staff_id,
       s.kind,
       s.occurred_at,
       s.amount_cents,
       coalesce(
         case
           when s.kind = 'service'
             then coalesce(svc.commission_bps, st.commission_service_bps)
           else st.commission_product_bps
         end, 0)       as rate_bps,
       case
         when st.id is null then 0
         when st.commission_starts_on is not null
              and s.occurred_at::date < st.commission_starts_on then 0
         else floor(s.amount_cents * coalesce(
                case
                  when s.kind = 'service'
                    then coalesce(svc.commission_bps, st.commission_service_bps)
                  else st.commission_product_bps
                end, 0) / 10000.0)
       end::integer    as commission_cents
from public.sales s
left join public.staff st       on st.id = s.staff_id
left join public.appointments a on a.id = s.appointment_id
left join public.services svc   on svc.id = a.service_id
-- What someone is paid is not a fact every colleague may read. view_finance.
where app.has_perm(s.business_id, 'view_finance');

revoke all on public.sale_commission from anon;
grant select on public.sale_commission to authenticated;

commit;

-- ------------------------------------------------------------------------------------
-- EVERY EXISTING FUNCTION v11a+v11b AFFECT, AND HOW EACH KEEPS WORKING
-- ------------------------------------------------------------------------------------
-- MODIFIED (exactly one, and only additively):
--   public.create_business              v11a §1.9 — one added `insert into branches`. The
--                                       staff/loyalty_programs/audit_log inserts and the
--                                       row_to_json(rec) return shape are byte-for-byte.
-- NOT MODIFIED, but now behave differently (all via the BEFORE INSERT branch trigger only —
-- every one of them gains branch attribution and loses nothing):
--   app.on_appointment_completed        still inserts the sale at completion, still FEFO-
--                                       deducts stock, still relies on one_sale_per_appointment.
--                                       The sale now carries branch_id. Loyalty timing: unmoved.
--   app.on_sale_recorded (v10's)        UNTOUCHED. AFTER INSERT; the branch trigger is BEFORE
--                                       INSERT. Points/retention/referral semantics identical.
--   app.on_sale_stock_deduct            UNTOUCHED. Gates on product_id, not kind or branch.
--   public.sell_package                 UNTOUCHED (v10 already changes its kind). Sale branched.
--   public.issue_gift_card              UNTOUCHED. Sale branched. Still not revenue, still no points.
--   public.redeem_gift_card             UNTOUCHED. Still inserts no sale. Still correct.
--   public.enroll_membership            UNTOUCHED. Sale branched.
--   app.run_membership_renewals         UNTOUCHED. Renewal sales branched — and this one runs
--                                       from cron with no auth.uid(), which is why
--                                       app.default_branch is SECURITY DEFINER.
--   public.use_package_session          UNTOUCHED. $0 service sale branched; still a visit.
--   public.convert_booking_request      UNTOUCHED. Appointment branched by the trigger.
--   public.request_booking / list_my_appointments / request_change / decide_change
--                                       UNTOUCHED. No anon surface changed anywhere in v11.
--   app.is_salon_member / is_salon_owner
--                                       UNTOUCHED — but their INPUT changed: staff.user_id can
--                                       now be NULL. Fails closed (null = auth.uid() is NULL).
--                                       This is the single highest-value thing to test.
-- ------------------------------------------------------------------------------------

-- ------------------------------------------------------------------------------------
-- WHAT v11b DELIBERATELY LEAVES OUT
-- ------------------------------------------------------------------------------------
--  * Stripe / any processor (UO-2, owner-deferred). record_payment RECORDS money taken by
--    other means; it never MOVES money. Deposits are recordable, not chargeable.
--  * Tips. A Reports tab (FL-TIPS, evidence B — tab confirmed, contents never read). Adding
--    a tip column now means guessing whether tips are revenue, whether they are commissioned,
--    and whether they hit the drawer. Three guesses, zero evidence. Needs a Pass-2 read first.
--  * A GST/tax ENGINE. v11a stores rates; nothing computes tax on a sale. ⚖️ Inclusive vs
--    exclusive pricing and what is zero-rated are owner+counsel decisions, not schema ones.
--  * Payroll (UO-1). sale_commission is arithmetic in a view; no payouts, no period close.
--  * Storefront/promotions/marketing/forms — later migrations, per the brief.
--  * Refund of a gift-card-method payment does not restore the card balance. Recorded as a
--    negative payment only. Flagged as an open question, not silently half-built.
-- ------------------------------------------------------------------------------------

-- ------------------------------------------------------------------------------------
-- OPEN QUESTIONS FOR THE OWNER (do not let these get lost)
-- ------------------------------------------------------------------------------------
--  Q1. NO-SHOW FEES AND REVENUE. A no_show_fee payment has an appointment and no sale, so it
--      is cash_collected but NOT accrual revenue and NOT cash revenue (which joins sales).
--      Is a no-show fee revenue? If yes, it needs a sale row — arguably a new
--      sales.kind='fee' with its own v10 policy line, which is a clean fit but is a v10
--      change, not a v11 one. Not guessed at.
--  Q2. QUICK SALE AND THE DRAWER — CONFIRMED, AND THE HEADER UNDERSTATED IT. Not just "the
--      drawer stays empty": every quick sale reads permanently unpaid, revenue_cash
--      undercounts without limit, and — the serious one — close_drawer posts a positive
--      close_variance for every uncredited quick sale and then re-anchors it away, so the
--      drawer reconciles perfectly while being wrong and a genuine shortfall is hidden in
--      the noise. See §1.4 for the full mechanism.
--      DB HALF: DONE. public.record_quick_sale() (§1.4) writes sale + payment atomically
--      under one idempotency key. The remaining gap is genuinely UI-side, because the tender
--      method is a fact that exists only at the counter — no trigger can infer it, and a
--      trigger that guessed would manufacture phantom variance instead of removing it.
--      THE EXACT UI CONTRACT (app/index.html, owned elsewhere — hand this over verbatim):
--        REPLACE:  sb.from('sales').insert({business_id, client_id, kind:'quick_sale',
--                                           amount_cents, note})
--        WITH:     sb.rpc('record_quick_sale', {
--                    p_business:        <business uuid>,
--                    p_amount_cents:    <integer, > 0>,
--                    p_method:          <'cash'|'card'|'paynow'|'bank_transfer'|'credit'
--                                        |'gift_card'|'other'>,   -- REQUIRED, from a tender
--                                                                 -- picker; no default
--                    p_client:          <uuid|null>,   // null = walk-in
--                    p_staff:           <uuid|null>,
--                    p_branch:          <uuid|null>,   // null -> business default branch
--                    p_note:            <text|null>,
--                    p_idempotency_key: <uuid generated ONCE per checkout, not per click>,
--                    p_paid:            true           // false = on account -> A/R, no payment
--                  })
--        RETURNS:  { sale: <sales row>, payment: <payments row|null>, replayed: <boolean> }
--        UI RULES: (1) the tender picker must have NO pre-selected default — a defaulted
--                  'cash' is how phantom drawer credit gets created; (2) generate
--                  p_idempotency_key once when the checkout sheet OPENS and reuse it for
--                  every retry, or the guard protects nothing; (3) `replayed: true` is a
--                  SUCCESS — show the original receipt, never an error.
--  Q3. EXPENSES: void-as-flag vs strict append-only. Chosen: flag (matches the live toggle,
--      fully audited). Say so if you want a reversing-row model instead.
--  Q4. OVERPAYMENT is allowed and surfaced as payment_status='overpaid' rather than blocked.
--      One `if` to make it a hard stop.
--  Q5. The stale kind='retail' package row — see v11a's header, item 3. Needs a decision
--      before v10 is applied, not after.
--  Q6. A SEVENTH PERMISSION: `operate_drawer` (owner, manager, frontdesk). Today the drawer
--      is gated on view_finance, so a frontdesk role can take payments but cannot open or
--      close the till — and at a real café the person at the counter IS the person who counts
--      it. The alternative, giving frontdesk view_finance, also hands them the P&L, which is
--      worse. A seventh permission is a v10.1 change (app.role_perms lives there), so it is
--      NOT made here. This is the most likely operational complaint after v11 lands.
--  Q7. DEPOSITS AND PERIOD CLOSE. revenue_cash for a CLOSED period is not frozen: a deposit
--      becomes cash revenue dated at the deposit on the day its appointment completes, so a
--      January figure can rise in March. That is correct cash accounting, and it is also
--      exactly the kind of thing an accountant asks about once. The alternative is a
--      deferred-revenue liability account. Owner + accountant decision, not a schema one.
--  Q8. COMMISSION RATES ARE STILL READ-TIME RESOLVED. public.sale_commission recomputes
--      against today's staff.commission_*_bps / services.commission_bps, so giving a raise
--      moves last quarter's figures — the same SHAPE as the v10 P0. Harmless today (nothing
--      consumes it; no payout ledger exists). The fix is v10.1's: snapshot rate_bps onto the
--      sale at insert. It MUST be done in whatever migration builds payroll, BEFORE anyone is
--      paid against this view. See the note above the view.
-- ------------------------------------------------------------------------------------

-- ------------------------------------------------------------------------------------
-- UI NOTE (out of scope — app/index.html is owned by other agents)
-- ------------------------------------------------------------------------------------
-- After v11 lands the UI should:
--   * call get_revenue_summary() instead of summing sales client-side, and LABEL the two
--     revenue figures ("Revenue (billed)" vs "Revenue (collected)"). Do not silently pick one.
--   * add a Checkout action calling record_payment(), and ALWAYS pass p_idempotency_key
--     (a per-checkout uuid generated once, not per click) — that is what makes the
--     double-tap safe.
--   * call record_payment() from quick sale (see Q2) or the drawer stays empty.
--   * read sale_balance for the FULLY PAID / balance-pending badge.
--   * read cash_drawer_balance for the drawer page; open_drawer/close_drawer for the count.
-- ------------------------------------------------------------------------------------

-- ------------------------------------------------------------------------------------
-- REWORK LOG — every defect below was REPRODUCED against live data in a rolled-back
-- transaction BEFORE it was fixed, and the same measurement re-run after. Nothing here is
-- reasoned-from-first-principles; the numbers are real rows from project
-- kyzovonwnscrzmkvocid (business 'QA Test Cafe', 6 sales, 28000c revenue at baseline).
-- A test that cannot fail proves nothing — so where a guard is claimed, the blocked write
-- was ATTEMPTED and the actual error is quoted.
-- ------------------------------------------------------------------------------------
-- D1  BLOCKER — get_revenue_summary reproduced the v10 P0 verbatim.
--     Stage                                              AS SHIPPED   SNAPSHOT TRUTH   gap
--     A. baseline                                            28000         28000         0
--     B. + set_sale_policy(package, counts_as_revenue=false) 18000         28000    -10000
--     C. + reclassify_sale_policy(5000 quick_sale -> false)  18000         23000     -5000
--     B proves the P0: a forward-looking toggle retroactively erased a COMPLETED 10000
--     package sale from history. C proves the second, independent defect: the audited
--     restatement moved truth 28000 -> 23000 and the report did not move at all — the only
--     supported way to restate the books had zero effect on the books.
--     AFTER: the accrual/cash/receivables legs all read s.counts_as_revenue. The reworked
--     figure tracks truth at every stage (28000 / 28000 / 23000) and is STABLE across the
--     policy flip (A -> B: 28000 -> 28000). No live policy read remains in this file.
--
-- D2  BLOCKER — cross-tenant payment attachment. The exact PostgREST-shaped insert, run as
--     the OWNER OF BUSINESS X (kopi tiam) against a sale owned by Y (QA Test Cafe):
--       insert into payments (business_id, sale_id, method, amount_cents)
--       values ('<X>', '<Y-sale fc041326>', 'cash', 9999);
--     AS SHIPPED -> SUCCEEDED. rows_written 1; written_by_business = X;
--       sale_actually_belongs_to = Y; Y's sale then read paid_cents = 9999 — money booked
--       against Y's books by a member of X, invisible to Y (payments_select filters on X).
--       The RPC's three guards were never reached: the table is the other door.
--     AFTER (composite FK, §1.0a) -> the SAME insert now raises:
--       ERROR: 23503: insert or update on table "payments" violates foreign key constraint
--              "payments_sale_same_tenant"
--       DETAIL: Key is not present in table "sales".
--     Legitimate same-tenant insert (Y's owner, Y's sale) still succeeds — verified.
--
-- D3  MAJOR — deposits never reached revenue_cash. 2000 deposit (sale_id null, appointment
--     set) + 3000 balance on a 5000 service sale:
--       sale_balance          -> paid_cents 5000, balance_cents 0, status 'paid'
--       revenue_cash SHIPPED  -> 3000     <- the 2000 deposit is in NEITHER revenue NOR A/R
--       revenue_cash REWORKED -> 5000
--     2000 of collected money sat in the drawer and existed nowhere in the accounts.
--
-- D4  MAJOR — the revoke/grant did nothing. pg_default_acl (live) grants
--     `authenticated=arwdDxtm/postgres` on every new table in schema public, so
--     `grant select, insert` was a no-op. RLS masks UPDATE/DELETE (0 rows) but NOT TRUNCATE:
--       set local role authenticated; truncate public.payments;
--       AS SHIPPED -> SUCCEEDED. rows_left = 0. The whole multi-tenant ledger, every
--                     business, no error, no trigger, no audit row.
--       AFTER `revoke update, delete, truncate ... from authenticated`
--                  -> ERROR: 42501: permission denied for table payments
--     Corollary, now stated in §1.0b: trg_payments_append_only is DEAD CODE against
--     `authenticated` (RLS gets there first). It is kept for roles RLS does not apply to.
--
-- D5  MAJOR — no role separation on money. A stylist (view_sales, create_sales; no
--     view_finance) reading the payments ledger:
--       AS SHIPPED (is_salon_member)      -> rows_visible 1, cents_visible 9999
--       REWORKED   (has_perm view_finance)-> rows_visible 0, cents_visible 0
--     Mapping and the one open question (frontdesk cannot close the till) are at §1.0b / Q6.
--
-- D6  MINOR — record_payment's check-then-insert race. Simulated as the LOSER of a
--     concurrent double-tap (winner's row present; loser's SELECT already returned empty):
--       AS SHIPPED -> ERROR 23505: duplicate key value violates unique constraint
--                     "payments_idempotency"      <- the cashier is told a successful charge
--                                                    failed, and charges again. The exact
--                                                    outcome the header promised to prevent.
--       REWORKED   -> 'returned ORIGINAL fd1e08ff-…'; rows stayed 1; a NULL key still
--                     inserts normally.
--     ⚠️ NOT FULLY VERIFIED: this is a deterministic SIMULATION of the loser's position, not
--     a true concurrent race — that needs two connections and the MCP SQL tool has one. The
--     mechanism (ON CONFLICT arbitration in the index) is what makes it atomic, and the
--     re-select path is proven; the interleaving itself is argued, not measured. Fable should
--     confirm with two psql sessions before trusting it under load.
--
-- D7a MINOR — the deposit-join comment and Scenario B5 were FALSE. Old B5 claimed deleting
--     `p.sale_id is null` double-counts to 10000. Measured, real view vs mutant view, same
--     transaction, same fixture: real 5000, mutant 5000 — IDENTICAL. The test could not fail.
--     `LEFT JOIN ... ON a OR b` emits one row when either matches. Rewritten B5 (cross-sale
--     leakage) measured: SQ real 1000 / mutant 1000; SA real 0 / MUTANT 1000 — the mutant
--     pays SQ's cents against SA as well. Goes red against the mutant. That is a test.
--
-- D7b MINOR — Scenario E4 expected 3 recurrence rows; the code yields 2 and the code is
--     right. Measured from 2026-07-17: next_run_on 2026-05-18 -> posts; +1mo 2026-06-18 ->
--     posts; +2mo 2026-07-18 > current_date -> loop exits. 60 days is two monthly periods,
--     not three. Spec corrected; code untouched.
--
-- D7c MINOR — the "`security_invoker` view cannot call app.*" trap DOES NOT EXIST, and it
--     was the stated justification for two design decisions. Disproved by experiment:
--       create function app._probe_ok() returns int language sql stable as 'select 42';
--       create view public._probe_v with (security_invoker=on) as select app._probe_ok();
--       grant select on public._probe_v to authenticated;
--       set local role authenticated; select * from public._probe_v;   -->  42
--     has_schema_privilege('authenticated','app','USAGE') is indeed false — and irrelevant:
--     USAGE is a parse-time name-resolution check and a view stores a resolved OID. The
--     reasoning is retracted at cash_drawer_balance and at §4, and REPLACED with the real
--     reason in each place rather than deleted. The rework then USES the disproof: sale_balance,
--     sale_commission, cash_drawer_balance and cash_drawer_session_summary now call
--     app.has_perm() directly from security_invoker views — which the false premise forbade.
--
-- Q2  Quick sale / drawer — CONFIRMED and worse than the header admitted. See §1.4 for the
--     mechanism (the variance signal dies, it does not merely stay empty), the DB-side fix
--     (record_quick_sale), and the exact UI contract.
--
-- NEW DEFECT FOUND DURING REWORK — see Q8: public.sale_commission resolves commission rates
--     at READ time against mutable staff/service config, so a raise moves last quarter's
--     figures. Same shape as the P0. Harmless today (nothing consumes it), MUST be snapshotted
--     before payroll is built on it.
-- ------------------------------------------------------------------------------------

-- ------------------------------------------------------------------------------------
-- MANUAL TEST SCENARIOS — v11b
-- ------------------------------------------------------------------------------------
-- Scenario A — THE COMPLETION -> CHECKOUT -> DRAWER CHAIN. This is the walkthrough step 7
--              money flow reproduced with the competitor's exact live numbers. If one test
--              in this file gets run, make it this one.
--   Setup: business B (points program, 1pt/$), default branch BR, client C, staff ST,
--          service "Test Facial" $50.00 (5000 cents) linked via service_products to product
--          P qty 1, with a stock batch of 10. Appointment A booked for C/ST/service.
--          select public.open_drawer('<B>','<BR>', 0);
--
--   A1. BEFORE: cash_drawer_balance.expected_cents = 0
--               (select count(*) from payments) = 0
--               get_revenue_summary(B, today, today) -> revenue_accrual 0, revenue_cash 0
--               product_stock.stock for P = 10
--
--   A2. COMPLETE (no payment yet):  update appointments set status='completed' where id='<A>';
--       | check                                   | expect                                  |
--       |-----------------------------------------|-----------------------------------------|
--       | sales rows for A                        | 1  (kind='service', 5000, branch_id=BR) |
--       | product_stock for P                     | 9   <- 10 -> 9, exactly 1 unit          |
--       | points_ledger for C                     | 50  <- loyalty FIRES AT COMPLETION      |
--       | payments rows                           | 0   <- NO transaction. The split.       |
--       | cash_drawer_balance.expected_cents      | 0   <- drawer untouched                 |
--       | get_revenue_summary revenue_accrual     | 5000  <- billed                         |
--       | get_revenue_summary revenue_cash        | 0     <- competitor's "$0.00" at 7b     |
--       | get_revenue_summary unpaid_balance      | 5000                                    |
--       | sale_balance.payment_status             | 'unpaid', balance_cents = 5000          |
--       ^ The competitor's exact 7b state: "$50.00 balance — Pending", stock 10->9, visit
--         counted, no transaction, no revenue. The ONE deliberate divergence: we ALSO have
--         revenue_accrual = 5000, because our sale row exists. That is the stated rule.
--
--   A3. CHECKOUT: select public.record_payment('<B>','cash', 5000, p_sale => '<sale>',
--                        p_staff => '<ST>', p_idempotency_key => 'chk-1');
--       | payments rows                           | 1                                       |
--       | sale_balance.payment_status             | 'paid', balance_cents = 0  <- FULLY PAID|
--       | get_revenue_summary revenue_cash        | 5000  <- competitor's "$0.00 -> $50.00" |
--       | get_revenue_summary revenue_accrual     | 5000  (unchanged — not double counted)  |
--       | get_revenue_summary unpaid_balance      | 0                                       |
--       | cash_drawer_movements rows              | 1 (kind='sale_cash', 5000, payment_id)  |
--       | cash_drawer_balance.expected_cents      | 5000  <- "$0.00 -> $50.00", automatic   |
--       | points_ledger for C                     | STILL 50 — NOT 100. Payment must not    |
--       |                                         | earn a second time.                     |
--       ^ That last row is the highest-value assertion in the file: it proves the payments
--         ledger is invisible to on_sale_recorded.
--
--   A4. IDEMPOTENCY (the double-tap): re-run A3's call VERBATIM, same key 'chk-1'.
--       -> returns the SAME payment id; payments rows still 1; drawer still 5000; status
--          still 'paid' (NOT 'overpaid'). Then run it with p_idempotency_key => 'chk-2'
--          -> 2 payments, drawer 10000, status 'overpaid', balance_cents = -5000. Proves the
--          key is what protects, and that overpayment is visible rather than silent.
--
--   A5. CASH RETAIL (walkthrough step 8, the second path): insert a kind='retail' 2500 sale,
--       then record_payment(...,'cash',2500, p_sale => that sale).
--       -> drawer 5000 -> 7500 ("$50.00 -> $75.00"); revenue_cash 7500.
--
--   A6. CASH GIFT CARD (walkthrough step 9a — the precise illustration):
--       select public.issue_gift_card('<B>', 2500, '<C>', null);
--       then record_payment(...,'cash',2500, p_sale => <the gift_card sale>).
--       | cash_drawer_balance.expected_cents      | 10000  <- "$75.00 -> $100.00". Cash is cash|
--       | get_revenue_summary revenue_cash        | STILL 7500  <- NOT revenue                |
--       | get_revenue_summary cash_collected      | 10000                                     |
--       | points_ledger for C                     | unchanged (v9 intact)                     |
--       ^ Drawer credited, revenue not. Falls out for free because the drawer trigger gates
--         on method='cash' and knows nothing about v10 policy. Assert it anyway.
--
--   A7. CLOSE: select public.close_drawer('<B>','<session>', 9500);  -- $5 short
--       -> {expected_cents: 10000, counted_cents: 9500, variance_cents: -500}
--          a close_variance movement of -500 exists;
--          cash_drawer_balance.expected_cents is NOW 9500 — re-anchored to the counted cash,
--          so the next session does not inherit the drift.
--          Re-close the same session -> raises 'drawer session already closed'.
--          open_drawer on a branch with an open session -> raises (one_open_drawer_per_branch).
--
-- Scenario B — DEPOSIT ATTACHES WITH NO MUTATION (the linkage trick):
--   1. Appointment A2 booked, NOT completed. No sale exists yet.
--   2. record_payment('<B>','paynow', 2000, p_appointment => '<A2>', p_kind => 'deposit');
--      -> payment has appointment_id set, sale_id NULL. sale_balance has no row for it
--         (no sale yet). get_revenue_summary cash_collected = 2000; revenue_cash = 0.
--   3. NOW complete A2 (service price 5000).
--      -> sale created; sale_balance.paid_cents = 2000 WITHOUT ANY UPDATE to the payment row.
--         payment_status = 'partial', balance_cents = 3000.
--      ^ THE assertion. The deposit attached itself through the join. Verify the payments row
--         is byte-identical to step 2 (sale_id still null).
--   4. record_payment(... 3000, p_sale => '<sale>') -> 'paid', balance 0.
--   5. ❌ THE OLD B5 WAS A TEST THAT COULD NOT FAIL. It read: "a payment carrying BOTH
--      sale_id and appointment_id for the same sale must count ONCE; delete the
--      `p.sale_id is null` clause and confirm the test goes red." It does not go red.
--      `LEFT JOIN ... ON a OR b` emits ONE row when either predicate matches — it does not
--      emit one row per matching predicate — so the mutant returns the same 5000 as the real
--      view. MEASURED, both ways, same transaction: real view paid_cents 5000; mutant view
--      paid_cents 5000. The old B5 asserts a property SQL gives you for free, from a clause
--      that is not the reason you have it, and it was offered as proof that the clause was
--      load-bearing. This is the v10 failure mode exactly (a test that asserts the bug is a
--      feature), so it is replaced rather than deleted.
--
--   5. ✅ B5 (REWRITTEN) — CROSS-SALE LEAKAGE, which is what the clause actually prevents:
--      Setup: appointment A completes -> sale SA (5000). Separately, sale SQ (1000) exists
--             for the same client, with no appointment of its own.
--      Act:   insert ONE payment of 1000 naming sale SQ *and* carrying appointment A's id —
--             the shape record_payment produces whenever a caller passes both, e.g. paying
--             down a tab from the booking screen.
--      Assert (real view):   SQ paid_cents 1000 ('paid');  SA paid_cents 0 ('unpaid', 5000).
--      Assert (mutant view, `p.sale_id is null` deleted):
--                            SQ paid_cents 1000;           SA paid_cents 1000 ('partial').
--             -> the SAME 1000 cents is now paid against TWO different sales, and SA is
--                reported as part-paid with money that belongs to SQ. THAT is the leak.
--      This test goes RED against the mutant and GREEN against the real view. Run it that
--      way round or it proves nothing.
--
-- Scenario C — REFUNDS AND APPEND-ONLY:
--   1. record_payment('<B>','cash', 1000, p_sale => '<s>', p_kind => 'refund');
--      -> stored as -1000 (the RPC negates; caller passed positive). paid_cents drops by 1000;
--         status 'paid' -> 'partial'. Drawer expected drops by 1000. Status recomputed with
--         no state machine anywhere.
--   2. update payments set amount_cents = 1 where id = '<p>';
--      -> raises 'payments is an append-only ledger: UPDATE is not permitted...'
--   3. delete from payments where id = '<p>';                      -> same exception.
--   4. Same two against cash_drawer_movements                      -> same exception.
--   5. insert into payments (..., kind, amount_cents) values (..., 'refund', 500);
--      -> rejected by the sign check (a refund must be negative).
--      ... values (..., 'payment', -500);  -> rejected too.
--      ... values (..., 'payment', 0);     -> rejected (amount_cents <> 0).
--
-- Scenario D — THE $0 PACKAGE-SESSION ROW (documented sharp edge):
--   1. select public.use_package_session('<B>','<cp>');
--      -> sales row kind='service' amount 0. sale_balance.payment_status = 'unpaid',
--         balance_cents = 0.
--   2. get_revenue_summary unpaid_balance_cents must NOT include it (the view filters
--      balance_cents > 0). Assert unpaid is unchanged by step 1.
--   3. A UI "unpaid invoices" list that COUNTS sale_balance rows where status='unpaid' will
--      wrongly show it. One that SUMS balance_cents will not. Documented, not fixed.
--
-- Scenario E — EXPENSES + NET:
--   1. Expense 3000 SGD, occurred today, fx 1
--      -> get_revenue_summary: expenses 3000; net_accrual = accrual - 3000;
--         net_cash = cash - 3000.
--   2. select public.set_expense_void('<B>','<exp>', true);
--      -> expenses 0, Net back up. set_expense_void(..., false) -> 3000 again (a TOGGLE).
--      -> audit_log has a row per flip.
--   3. Multi-currency: expense 100 USD, fx_rate_to_base 1.35 -> contributes round(100*1.35)
--      = 135 to expenses. Assert the rate is FROZEN: changing the recurrence's rate later
--      must not move this row.
--   4. RECURRING + IDEMPOTENCY (the money-touching one):
--      recurrence: monthly, 5000, starts_on/next_run_on = 60 days ago.
--      select app.run_expense_recurrences();
--      -> exactly 2 expenses, one per period_on, next_run_on advanced past today.
--         ❌ THE OLD SPEC SAID 3 AND THE CODE WAS RIGHT — the spec was wrong, and a spec
--         that is wrong about a recurring BILL is not a cosmetic error: whoever reconciles
--         this next either "fixes" correct code to post a third rent charge, or files a bug
--         against working code. MEASURED from 2026-07-17: next_run_on = 2026-05-18 ->
--         posts 2026-05-18; +1 month = 2026-06-18 -> posts; +1 month = 2026-07-18 which is
--         > current_date, so the loop exits. Two periods have ELAPSED in 60 days on a
--         monthly cadence, because 60 days is not three months. The third row the old spec
--         expected would be a month that has not happened yet.
--         (Sanity check the arithmetic before trusting either number: a monthly cadence from
--          D posts at D, D+1mo, D+2mo…; from D = today-60 the periods <= today are D and
--          D+1mo. Two.)
--      Run it AGAIN immediately -> STILL exactly 2. Zero new rows
--         (one_expense_per_recurrence_period). This is the cron-double-run guard; a
--         recurring rent bill posted twice is a real-money error.
--      Set ends_on in the past -> the loop exits and active flips false.
--
-- Scenario F — RLS / GRANTS / TENANT ISOLATION (run every line; this is the money layer):
--   1. As anon (publishable key): select on payments, cash_drawer_movements,
--      cash_drawer_sessions, expenses, expense_recurrences, sale_balance,
--      cash_drawer_balance, sale_commission, service_bookable -> permission denied, ALL.
--      execute of record_payment / open_drawer / close_drawer / record_drawer_movement /
--      set_expense_void / get_revenue_summary -> permission denied, ALL.
--   2. Member of X: select from payments -> only X's rows. Same for every table above.
--   3. get_revenue_summary('<Y>', ...) as a member of X -> raises 'you do not have
--      permission to view finance for this business (view_finance)'.
--   4. CROSS-TENANT SALE ATTACHMENT — TEST THE TABLE, NOT JUST THE RPC. This is the one the
--      first draft got wrong: it tested only the RPC, the RPC passed, and the hole was wide
--      open beside it.
--      4a. Through the RPC: as a member of X, record_payment('<X>','cash',100,
--          p_sale => '<a sale owned by Y>') -> 'sale does not belong to this business'.
--          Repeat for p_appointment and p_staff. (These guards are kept — they give a
--          readable error where the FK gives 23503 — but they are no longer the defence.)
--      4b. THE DEFENCE — go around the RPC, exactly as PostgREST does:
--            set local role authenticated;   -- authenticated as a member of X
--            insert into payments (business_id, sale_id, method, amount_cents)
--            values ('<X>', '<Y-sale>', 'cash', 9999);
--          MUST raise 23503 payments_sale_same_tenant. Before the composite FK this
--          SUCCEEDED and Y's sale_balance read paid_cents 9999. Run 4b or you have not
--          tested the fix — 4a passed on the broken code too.
--      4c. Repeat 4b for appointment_id, staff_id, client_id and branch_id. Each has its own
--          composite FK and each was independently exploitable.
--      4d. The legitimate case still works: as a member of Y, the same insert with Y's own
--          sale succeeds. A tenant guard that also blocks the happy path is not a fix.
--   4e. TRUNCATE (RLS does not cover it):
--            set local role authenticated; truncate public.payments;
--       -> MUST raise 42501 permission denied. Before the explicit revoke this WIPED THE
--          WHOLE MULTI-TENANT LEDGER. Repeat for cash_drawer_movements,
--          cash_drawer_sessions, expenses, expense_recurrences.
--   4f. ROLE SEPARATION (D5). Set a staff row to role='stylist':
--       -> select from payments / expenses / sale_commission / cash_drawer_balance: 0 rows
--          (not an error — RLS filters).
--       -> get_revenue_summary(...)        -> raises (view_finance).
--       -> open_drawer / close_drawer / record_drawer_movement / set_expense_void -> raise.
--       -> record_payment(..., p_kind => 'payment') -> SUCCEEDS (create_sales). A stylist
--          must be able to take money.
--       -> record_payment(..., p_kind => 'refund')  -> raises (refund_sales). This is the
--          first and only caller of the permission v10.1 defined with no subject.
--       -> insert into cash_drawer_movements (...) directly -> denied (no policy, no grant).
--          Assert this: it is how a shortfall gets reconciled away by hand.
--   5. close_drawer('<X>','<session owned by Y>', 100) -> 'drawer session not found'.
--      open_drawer('<X>','<branch owned by Y>', 0) -> 'branch does not belong to this business'.
--   6. record_drawer_movement(..., 'sale_cash', ...) -> raises (only pay_in/pay_out are
--      manual; sale_cash must come from the trigger or the drawer can be credited without a
--      payment).
--
-- Scenario G — COMMISSION RESOLUTION (data foundation only; no money moves):
--   Staff ST: commission_service_bps = 1000 (10%), commission_product_bps = 500 (5%),
--   commission_starts_on = null.
--   1. kind='service' 5000 sale via appointment on a service with commission_bps = NULL
--      -> rate_bps 1000, commission_cents 500  (staff default)
--   2. Same, but services.commission_bps = 2000 -> rate_bps 2000, commission 1000 (override wins)
--   3. Same, but services.commission_bps = 0    -> rate_bps 0, commission 0.
--      ^ THE assertion. 0 must WIN over the staff's 10%, not fall through. A coalesce that
--        treats 0 as unset returns 500 here and silently overpays every zero-commission
--        service. Same class of bug as the branch tax override.
--   4. kind='retail' 5000, staff ST -> rate_bps 500, commission 250 (product rate, not service)
--   5. kind='package'/'quick_sale'/'membership'/'gift_card' -> all use the PRODUCT rate
--      ("applies to every sale this staff rings up"). Confirm 'package' resolves — it only
--      exists after v10.
--   6. commission_starts_on = tomorrow -> commission_cents 0 for today's sale, rate_bps still
--      reported (the rate exists; it just does not apply yet).
--   7. sales.staff_id null -> commission_cents 0, no error, row still present.
--   8. A kind='service' sale with NO appointment -> cannot reach a service override; falls to
--      the staff service rate. Correct by design; assert it so it is not later "fixed".
-- ------------------------------------------------------------------------------------
