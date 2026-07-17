-- FRENLY v11b — the money layer: PAYMENTS ledger, the completion/payment split,
--                CASH DRAWER, EXPENSES, and derived Net.
-- (target Supabase project kyzovonwnscrzmkvocid; migration name `frenly_v11b_money`)
--
-- APPLY ORDER:  v10_sale_policy  ->  v11a_branches_staff_services  ->  v11b (this file).
-- HARD DEPENDS ON BOTH. v11b calls app.sale_policy_set() (v10) and branches / sales.branch_id
-- / sales.staff_id / staff.commission_*_bps / services.commission_bps (v11a). It will fail
-- loudly at apply time if either is missing, which is the intended behaviour.
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
--   ACCRUAL revenue = sum(sales.amount_cents) where the kind's counts_as_revenue is true.
--                     Recognised at completion. This is TODAY'S NUMBER, byte-for-byte
--                     unchanged. Nothing that reads it today changes meaning.
--   CASH revenue     = sum(payments.amount_cents) against sales whose kind counts_as_revenue.
--                     Recognised at payment. This is the competitor's "Revenue (Paid)" —
--                     $0.00 after completion, $50.00 after checkout (live-confirmed numbers).
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
--   * INSERT + SELECT are granted; UPDATE/DELETE are revoked AND blocked by a trigger, so a
--     future migration that carelessly re-grants cannot silently reopen mutation.
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
  business_id    uuid not null references public.businesses(id) on delete cascade,
  branch_id      uuid references public.branches(id) on delete set null,
  -- A payment attaches to a sale, an appointment, or both. A deposit/no-show fee has an
  -- appointment and no sale. A quick sale has a sale and no appointment. NEITHER column is
  -- ever updated after insert (see THE LINKAGE TRICK in the header).
  sale_id        uuid references public.sales(id) on delete set null,
  appointment_id uuid references public.appointments(id) on delete set null,
  client_id      uuid references public.clients(id) on delete set null,
  -- Who rang it up. Drives the Transactions list's staff filter + commission attribution.
  staff_id       uuid references public.staff(id) on delete set null,
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

create unique index payments_idempotency
  on public.payments (business_id, idempotency_key)
  where idempotency_key is not null;
create index payments_sale        on public.payments (sale_id) where sale_id is not null;
create index payments_appointment on public.payments (appointment_id) where appointment_id is not null;
create index payments_branch_time on public.payments (branch_id, occurred_at);
create index payments_business_time on public.payments (business_id, occurred_at);
create index payments_client      on public.payments (client_id, occurred_at) where client_id is not null;

alter table public.payments enable row level security;
create policy payments_select on public.payments for select to authenticated
  using (app.is_salon_member(business_id));
create policy payments_insert on public.payments for insert to authenticated
  with check (app.is_salon_member(business_id));
-- NO update/delete policy, by design. Belt AND braces: the grants below omit them and
-- trg_payments_append_only blocks them even if a future migration re-grants carelessly.
revoke all on public.payments from anon;
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
--     The `p.sale_id is null` in branch (b) is what prevents double-counting a payment that
--     carries BOTH ids. Delete it and every appointment payment is counted twice.
create view public.sale_balance
with (security_invoker = on) as
select s.id                                            as sale_id,
       s.business_id,
       s.branch_id,
       s.client_id,
       s.appointment_id,
       s.kind,
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
group by s.id, s.business_id, s.branch_id, s.client_id, s.appointment_id,
         s.kind, s.amount_cents, s.occurred_at;

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
declare v_row payments; v_existing payments; v_branch uuid; v_client uuid;
begin
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;

  -- Idempotent replay: return the ORIGINAL row rather than raising. A raise here would tell
  -- a cashier that a successful charge failed, and they would charge again.
  if p_idempotency_key is not null then
    select * into v_existing from payments
      where business_id = p_business and idempotency_key = p_idempotency_key;
    if found then return row_to_json(v_existing); end if;
  end if;

  if p_sale is null and p_appointment is null then
    raise exception 'a payment must reference a sale or an appointment';
  end if;

  -- Cross-tenant guards. Without these, a member of business X could attach a payment to
  -- business Y's sale by passing its uuid: p_business would pass is_salon_member and the FK
  -- would happily accept the foreign sale_id.
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

  insert into payments (business_id, branch_id, sale_id, appointment_id, client_id,
                        staff_id, method, kind, amount_cents, reference, note,
                        idempotency_key)
  values (p_business, v_branch, p_sale, p_appointment, v_client,
          p_staff, p_method, p_kind, p_amount_cents, p_reference, p_note,
          p_idempotency_key)
  returning * into v_row;

  return row_to_json(v_row);
end $$;
revoke execute on function public.record_payment(uuid, text, integer, uuid, uuid, uuid, uuid,
  text, uuid, text, text, text) from public, anon;
grant execute on function public.record_payment(uuid, text, integer, uuid, uuid, uuid, uuid,
  text, uuid, text, text, text) to authenticated;

-- ====================================================================================
-- 2. CASH DRAWER
-- ====================================================================================

-- 2.1 Sessions (the "close count" flow). A branch has at most one OPEN session at a time.
create table public.cash_drawer_sessions (
  id                  uuid primary key default gen_random_uuid(),
  business_id         uuid not null references public.businesses(id) on delete cascade,
  branch_id           uuid not null references public.branches(id) on delete cascade,
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

alter table public.cash_drawer_sessions enable row level security;
create policy cash_drawer_sessions_select on public.cash_drawer_sessions for select to authenticated
  using (app.is_salon_member(business_id));
create policy cash_drawer_sessions_write on public.cash_drawer_sessions for all to authenticated
  using (app.is_salon_member(business_id))
  with check (app.is_salon_member(business_id));
revoke all on public.cash_drawer_sessions from anon;
grant select, insert, update on public.cash_drawer_sessions to authenticated;
create trigger trg_cash_drawer_sessions_audit
  after insert or update or delete on public.cash_drawer_sessions
  for each row execute function app.audit();

-- 2.2 Movements — append-only, signed. THE system of record for physical cash.
create table public.cash_drawer_movements (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id   uuid not null references public.branches(id) on delete cascade,
  session_id  uuid references public.cash_drawer_sessions(id) on delete set null,
  -- 'open_float'     — the till float when a session opens.
  -- 'sale_cash'      — auto-posted from a cash payment (positive) or cash refund (negative).
  -- 'pay_in'         — manual cash added (owner tops up change).
  -- 'pay_out'        — manual cash removed (petty cash, bank run). NEGATIVE.
  -- 'close_variance' — (counted - expected) at close. Re-anchors the running sum to reality.
  kind        text not null check (kind in
                ('open_float','sale_cash','pay_in','pay_out','close_variance')),
  amount_cents integer not null,     -- signed; 0 is legal ONLY for a zero close_variance.
  payment_id  uuid references public.payments(id) on delete set null,
  staff_id    uuid references public.staff(id) on delete set null,
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

alter table public.cash_drawer_movements enable row level security;
create policy cash_drawer_movements_select on public.cash_drawer_movements for select to authenticated
  using (app.is_salon_member(business_id));
create policy cash_drawer_movements_insert on public.cash_drawer_movements for insert to authenticated
  with check (app.is_salon_member(business_id));
revoke all on public.cash_drawer_movements from anon;
grant select, insert on public.cash_drawer_movements to authenticated;
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
--     NOTE — open_session_id is an INLINE correlated subquery, NOT a call to
--     app.open_drawer_session(). This view is security_invoker, so its body executes as
--     `authenticated`, and `authenticated` has NO USAGE on schema app (re-verified live).
--     Calling the app helper here would fail with "permission denied for schema app" at
--     SELECT time — not at apply time — i.e. it would ship green and break in the UI. Same
--     trap v10's header documents for get_sale_policy. The helper stays for plpgsql callers
--     (SECURITY DEFINER functions), which is where it is safe.
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
group by s.id;

revoke all on public.cash_drawer_session_summary from anon;
grant select on public.cash_drawer_session_summary to authenticated;

-- 2.6 Drawer RPCs.
create or replace function public.open_drawer(
  p_business uuid, p_branch uuid, p_float_cents integer default 0)
returns json language plpgsql security definer set search_path = public as $$
declare v_row cash_drawer_sessions;
begin
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
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
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
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
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
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
  branch_id      uuid references public.branches(id) on delete set null,
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
alter table public.expense_recurrences enable row level security;
create policy expense_recurrences_all on public.expense_recurrences for all to authenticated
  using (app.is_salon_member(business_id))
  with check (app.is_salon_member(business_id));
revoke all on public.expense_recurrences from anon;
grant select, insert, update, delete on public.expense_recurrences to authenticated;
create trigger trg_expense_recurrences_audit
  after insert or update or delete on public.expense_recurrences
  for each row execute function app.audit();

-- 3.2 Expenses.
create table public.expenses (
  id              uuid primary key default gen_random_uuid(),
  business_id     uuid not null references public.businesses(id) on delete cascade,
  branch_id       uuid references public.branches(id) on delete set null,
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
  recurrence_id   uuid references public.expense_recurrences(id) on delete set null,
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

alter table public.expenses enable row level security;
create policy expenses_all on public.expenses for all to authenticated
  using (app.is_salon_member(business_id))
  with check (app.is_salon_member(business_id));
revoke all on public.expenses from anon;
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
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
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
-- An RPC, not a view, for the same reason v10's get_sale_policy is an RPC: this must call
-- app.sale_policy_set(), and `authenticated` does NOT have USAGE on schema app (re-verified
-- live: has_schema_privilege('authenticated','app','USAGE') = false). That is load-bearing —
-- it is what stops any logged-in user calling app.run_membership_renewals(). A
-- security_invoker view would fail; granting app usage would widen the internal surface;
-- duplicating v10's defaults in public would reintroduce exactly the drift v10 removed.
-- A SECURITY DEFINER RPC crosses the boundary once, with an explicit tenant check.
--
-- Revenue kinds come from v10 policy — NOT a hardcoded list. A firm that flips package to
-- counts_as_revenue = false gets a Net that reflects that with no code change.
create or replace function public.get_revenue_summary(
  p_business uuid, p_from date, p_to date, p_branch uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_kinds text[]; v_accrual bigint; v_cash bigint; v_expenses bigint;
        v_unpaid bigint; v_collected bigint;
begin
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;

  select coalesce(array_agg(kind) filter (where counts_as_revenue), array[]::text[])
    into v_kinds from app.sale_policy_set(p_business);

  -- ACCRUAL: recognised at completion. Today's number, unchanged.
  select coalesce(sum(s.amount_cents), 0) into v_accrual
    from sales s
   where s.business_id = p_business
     and s.kind = any(v_kinds)
     and s.occurred_at::date between p_from and p_to
     and (p_branch is null or s.branch_id = p_branch);

  -- CASH: recognised at payment, against revenue-counting sales only. The competitor's
  -- "Revenue (Paid)". Refunds net off automatically (negative rows).
  select coalesce(sum(p.amount_cents), 0) into v_cash
    from payments p
    join sales s on s.id = p.sale_id
   where p.business_id = p_business
     and s.kind = any(v_kinds)
     and p.occurred_at::date between p_from and p_to
     and (p_branch is null or p.branch_id = p_branch);

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
     and b.kind = any(v_kinds)
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
    'net_cash_cents',        v_cash    - v_expenses,
    'revenue_kinds',         to_json(v_kinds));
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
left join public.services svc   on svc.id = a.service_id;

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
--  Q2. QUICK SALE AND THE DRAWER. The UI's quick sale inserts into `sales` directly and takes
--      no payment, so it books accrual revenue but puts nothing in the drawer. The competitor
--      takes a method at quick-sale time ("Cash / Exact"). The UI must call record_payment()
--      alongside the sale insert. This is a UI change (app/index.html is owned elsewhere) and
--      is the single most likely functional gap after v11 lands.
--  Q3. EXPENSES: void-as-flag vs strict append-only. Chosen: flag (matches the live toggle,
--      fully audited). Say so if you want a reversing-row model instead.
--  Q4. OVERPAYMENT is allowed and surfaced as payment_status='overpaid' rather than blocked.
--      One `if` to make it a hard stop.
--  Q5. The stale kind='retail' package row — see v11a's header, item 3. Needs a decision
--      before v10 is applied, not after.
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
--   5. NO DOUBLE-COUNT: a payment carrying BOTH sale_id and appointment_id for the same sale
--      must count ONCE. Insert one, assert paid_cents rises by its amount and not twice it.
--      (This is what `p.sale_id is null` in the join's second branch protects. Delete that
--      clause locally and confirm the test goes red — otherwise it is not testing anything.)
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
--      -> exactly 3 expenses (backfilled: 60d ago, 30d ago, today), one per period_on,
--         next_run_on advanced past today.
--      Run it AGAIN immediately -> STILL exactly 3. Zero new rows
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
--   3. get_revenue_summary('<Y>', ...) as a member of X -> raises 'not a member'.
--   4. CROSS-TENANT SALE ATTACHMENT (the guard I added for this specifically):
--      As a member of X: record_payment('<X>','cash',100, p_sale => '<a sale owned by Y>')
--      -> raises 'sale does not belong to this business'. Repeat for p_appointment
--         ('appointment does not belong...') and p_staff ('staff does not belong...').
--         Without those three guards the is_salon_member check on p_business alone passes
--         and the FK accepts the foreign row.
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
