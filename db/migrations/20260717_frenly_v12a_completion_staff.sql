-- FRENLY v12a — THE APPOINTMENT COMPLETION TRIGGER MUST CARRY staff_id ONTO THE SALE.
-- (target Supabase project kyzovonwnscrzmkvocid; migration name `frenly_v12a_completion_staff`)
-- FIXES DEFECT Q9, raised by the header of 20260717_frenly_v12_commission_snapshot.sql.
--
-- APPLY ORDER: v10 -> v10.1 -> v11a -> v11b -> v11c (ALL LIVE) -> **v12a (this file)** -> v12.
-- v12a MUST LAND BEFORE v12. That ordering is the entire reason this file exists separately.
--
-- ======================================================================================
-- THE DEFECT (Q9) — verified against the LIVE function body, not the repo
-- ======================================================================================
-- `app.on_appointment_completed()` inserts the sale like this (live definition, fetched via
-- pg_get_functiondef 2026-07-17):
--     insert into sales (business_id, client_id, kind, amount_cents, appointment_id, note)
--     values (new.business_id, new.client_id, 'service', v_amount, new.id, 'appointment completed')
-- `appointments.staff_id` EXISTS and is the person who performed the work. It is simply never
-- carried across. So the PRIMARY path by which a stylist earns service commission — completing
-- their own appointment — lands a sale with NO staff attribution, and v11b's resolver
-- (`when st.id is null then 0`) pays them exactly nothing. Silently. Forever.
--
-- WHY THIS BLOCKS v12, RATHER THAN MERELY PRECEDING IT:
--   * TODAY the bug is self-correcting. `sale_commission` resolves the rate at READ time, so
--     the moment this insert is fixed, every past appointment sale starts resolving a real rate.
--   * AFTER v12 it is PERMANENT. v12 snapshots the resolved rate onto the row at INSERT and
--     freezes it (its section 5 extends v10.1's guard to forbid the column ever moving), and
--     v12 deliberately ships NO restatement path (its Q12). Every appointment sale recorded
--     between v12 and a Q9 fix would carry a permanent, uncorrectable commission_rate_bps = 0.
--   * v12's own header reaches this conclusion and states it: "Fixing Q9 is therefore MORE
--     urgent than v12, not less, and arguably BLOCKS it." This file agrees and unblocks it.
--
-- ======================================================================================
-- SCOPE — v12a does ONE thing
-- ======================================================================================
-- It carries `appointments.staff_id` onto the `sales` row, with a same-tenant guard (below).
-- It changes NOTHING else in the function: the idempotent insert and the FEFO stock
-- consumption are reproduced from the live definition unchanged. It adds no column, no table,
-- no index, no RPC, no permission, no trigger. It touches no other writer (see the WRITERS
-- AUDIT). It does NOT backfill (see NO BACKFILL).
--
-- ======================================================================================
-- ⚠️ THE SAME-TENANT GUARD — NOT DECORATION. A NAIVE ONE-LINE FIX CAUSES AN OUTAGE.
-- ======================================================================================
-- The obvious fix is to add `staff_id` to the column list and `new.staff_id` to the values.
-- That is UNSAFE HERE, and the asymmetry that makes it unsafe is live and verified:
--
--     appointments_staff_id_fkey : FOREIGN KEY (staff_id) REFERENCES staff(id) ON DELETE SET NULL
--     sales_staff_fk             : FOREIGN KEY (staff_id, business_id) REFERENCES staff(id, business_id)
--
-- `appointments` uses a SINGLE-COLUMN FK. It only asks "does this staff id exist?" — never
-- "does it exist IN MY TENANT?" (v11a's own TENANT INTEGRITY wording). `sales` uses v11a's
-- COMPOSITE FK, which asks both. So an appointment in business X may legally reference a staff
-- member of business Y today, and blindly forwarding that id would make the sale insert raise
-- a foreign_key_violation INSIDE the completion trigger — converting a silent zero-commission
-- into a hard failure to complete the appointment at all. That is a strictly worse bug.
--
-- v12a resolves the staff through the composite pair explicitly, exactly as v12's resolver
-- does (`left join public.staff st on st.id = p_staff and st.business_id = p_business`), and
-- FAILS CLOSED with a named error rather than forwarding a cross-tenant id.
--
-- WHY RAISE RATHER THAN SILENTLY NULL: a cross-tenant staff assignment is a tenant-isolation
-- breach — CLAUDE.md lists tenant isolation under Key unresolved risks. Nulling it would
-- restore the exact silence this migration exists to end, and would quietly under-pay someone.
-- Raising surfaces corrupt data loudly at the moment it would otherwise be laundered into the
-- money path. DAY-ONE IMPACT: ZERO, provably — all 4 live appointments have staff_id IS NULL
-- (verified), so the branch is unreachable on current data. It is a tripwire, not a behaviour
-- change. Tested in both directions (same-tenant staff carries; cross-tenant staff raises).
--
-- THE REAL FIX belongs upstream and is NOT done here: `appointments_staff_id_fkey` should be
-- the composite `(staff_id, business_id) -> staff(id, business_id)`, matching `sales_staff_fk`
-- and `appointments_branch_fk` (which is ALREADY composite on the same table — so this is an
-- inconsistency within v11a, not a deliberate design). That is a v11a-owned schema change with
-- its own review, not a completion-trigger change. Raised as Q13.
--
-- ======================================================================================
-- NO BACKFILL — DELIBERATE, AND THIS IS THE HONEST CHOICE
-- ======================================================================================
-- v12a does NOT backfill `staff_id` onto the 6 existing sales, and opens no
-- app.begin_sales_backfill() window. Verified live immediately before writing:
--     sales = 6, sales with staff_id = 0
--     appointments = 4, appointments with staff_id = 0
-- Every one of the 6 sales belongs to the disposable QA tenant 'QA Test Cafe' (the real tenant
-- 'kopi tiam' has 0 sales), and there is NO appointment carrying a staff_id from which any
-- attribution could be reconstructed. There is nothing to backfill FROM. Inventing an
-- attribution — picking one of the 2 live staff rows because they are the only candidates —
-- would be fabricating who performed work that nobody recorded, and would then be frozen into
-- v12's snapshot as fact. CLAUDE.md's rule holds: no mock data in prod.
-- Consequence, stated plainly: the 6 pre-existing sales keep staff_id NULL forever and will
-- snapshot commission_rate_bps = 0 under v12. That is CORRECT, not a loss — it is precisely
-- v12's BACKFILL PLAN argument ("no sale has a commission subject, so no rate can apply"), and
-- v12a preserves that proof intact rather than destroying it. Nobody has ever been paid against
-- these rows (there is no payout ledger), so there is no wrong number in the wild.
--
-- APPEND-ONLY / NO BACKFILL WINDOW NEEDED — CONFIRMED. v10.1's guard
-- (trg_sales_immutable_guard, BEFORE DELETE OR UPDATE) blocks UPDATE on `sales`. v12a issues
-- NO UPDATE against `sales`: it replaces a FUNCTION BODY that governs future INSERTs. The guard
-- is a row-level UPDATE/DELETE trigger and is never reached by `create or replace function`, nor
-- by an INSERT. So no window is opened, no window is needed, and v10.1's guard is untouched and
-- unweakened by this file. (This is exactly why the no-backfill decision above is free: the
-- expensive, audited path is simply never entered.)
--
-- ======================================================================================
-- WRITERS AUDIT — all 7 functions that INSERT INTO sales, decided individually
-- ======================================================================================
-- Enumerated from live proscr (`prosrc ~* 'insert\s+into\s+sales'`), not from the repo. NOTE:
-- this returns SEVEN, and v12's header names only six of them — it missed
-- `app.run_membership_renewals`. Recorded so the next author does not inherit the short list.
--
--  1. app.on_appointment_completed   -> **FIXED HERE.** appointments.staff_id is populated and
--     is the performer of the service. This is the canonical service-commission path and the
--     whole subject of Q9.
--
--  2. public.record_quick_sale       -> ALREADY CORRECT, NOT TOUCHED. Takes p_staff and writes
--     it (`insert into sales (..., branch_id, staff_id, ...)`). The only writer that ever did.
--
--  3. public.sell_package            -> NOT CHANGED. Not an oversight: it has no p_staff
--     parameter and `client_packages` records no seller, so there is no staff to carry — the
--     information does not exist in the schema. Adding it is not a one-line fix; it needs a new
--     RPC parameter, a UI change, and FIRST an owner ruling on a genuine business question:
--     does a package pay commission ONCE at purchase (on revenue booked upfront), or per
--     session as it is consumed? Both are defensible; paying both double-pays. Out of scope for
--     a completion-trigger fix. Raised as Q14. Snapshots rate 0 under v12 meanwhile, which is
--     the honest answer while the question is open.
--
--  4. public.use_package_session     -> NOT CHANGED, and note this one costs nothing today: it
--     inserts a $0 (`amount_cents = 0`) kind='service' sale, and v12's derived arithmetic is
--     floor(amount_cents * rate / 10000) — so the commission is 0 for ANY rate. Attribution
--     here is real but is the other half of Q14's question, and cannot be answered separately
--     from it. Same reasoning as #3: no p_staff parameter exists to carry.
--
--  5. public.issue_gift_card         -> CORRECTLY HAS NO STAFF. Not deferred — decided. v9
--     established that a gift card sale is CASH COLLECTED AGAINST A LIABILITY, NOT REVENUE.
--     Commissioning it would pay out on money the business has not earned, and would then pay
--     AGAIN on the real, commissionable sale when that credit is spent. Double-pay. The absent
--     staff_id is the right answer permanently, not a gap.
--
--  6. public.enroll_membership       -> NO STAFF, consistent with the established treatment.
--     v5/v9: a membership sale never earns points, never counts as a retention visit, never
--     qualifies a referral. Commission on memberships is a separate policy question the owner
--     has not been asked (and which v10's sale_policies framework, not this file, is the right
--     home for). No p_staff parameter exists. Not changed.
--
--  7. app.run_membership_renewals    -> MUST NEVER SET STAFF. This is the automated daily
--     pg_cron renewal job. No human performed a renewal, so there is no one to pay. NULL is
--     not a gap here; it is the correct and permanent value. A staff_id on this row would be
--     a fabricated attribution to a person who did nothing.
--
-- SUMMARY: exactly one writer is wrong (#1) and it is fixed. One was already right (#2). Two
-- are correct to have no staff, permanently (#5, #7). Three are blocked on owner rulings that
-- do not belong in a trigger fix (#3, #4, #6) and cost nothing while v12's snapshot records an
-- honest 0.
--
-- ======================================================================================
-- PRE-FLIGHT (verified live, read-only, 2026-07-17 — RE-VERIFY BEFORE APPLYING)
-- ======================================================================================
--   * 15 migrations applied, latest frenly_v11c_revoke_truncate. v12 NOT applied.
--   * sales = 6 rows (all QA Test Cafe), 0 with staff_id. appointments = 4, 0 with staff_id.
--   * staff = 2 (both role='owner'); services = 1.
--   * `one_sale_per_appointment` is a partial UNIQUE INDEX
--     (`on public.sales (appointment_id) where appointment_id is not null`), NOT a table
--     constraint. A bare `on conflict do nothing` (no inference clause) honours ANY unique
--     index, so idempotency is preserved verbatim. Do not "helpfully" add an
--     `on conflict (appointment_id)` target — with a PARTIAL index that requires restating the
--     WHERE clause, and getting it wrong turns a no-op into a duplicate sale.

begin;

-- ONE FUNCTION. Body reproduced from the LIVE definition; the ONLY changes are the resolution
-- of v_staff, the same-tenant guard, and `staff_id` in the INSERT. The FEFO block below is
-- byte-identical to live, deliberately: `sales` is the most trigger-laden table in the schema
-- and this is the most-tested function in it after on_sale_recorded (v6's idempotency chain
-- runs through it).
create or replace function app.on_appointment_completed()
returns trigger language plpgsql security definer set search_path = public as $function$
declare
  v_amount integer;
  sp       record;
  b        record;
  v_need   integer;
  v_take   integer;
  v_staff  uuid;
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    v_amount := coalesce(nullif(new.total_cents,0),
                         (select price_cents from services where id = new.service_id), 0);

    -- Q9 FIX. Resolve the performer through the SAME COMPOSITE PAIR that sales_staff_fk
    -- enforces, so a cross-tenant staff_id is caught here with a named error instead of
    -- surfacing as an opaque foreign_key_violation from the FK a millisecond later.
    -- Unreachable on live data today (0 of 4 appointments carry a staff_id) — a tripwire.
    if new.staff_id is not null then
      select st.id into v_staff
        from staff st
       where st.id = new.staff_id
         and st.business_id = new.business_id;
      if v_staff is null then
        raise exception 'appointment % references staff % which does not belong to business % '
                        '— refusing to attribute a sale across tenants',
                        new.id, new.staff_id, new.business_id
          using errcode = 'foreign_key_violation';
      end if;
    end if;

    -- Idempotent against the partial unique index one_sale_per_appointment. Bare `on conflict
    -- do nothing` (no inference clause) — preserved exactly as live.
    insert into sales (business_id, client_id, kind, amount_cents, appointment_id, staff_id, note)
    values (new.business_id, new.client_id, 'service', v_amount, new.id, v_staff, 'appointment completed')
    on conflict do nothing;

    -- FEFO stock consumption via service_products. UNCHANGED from the live definition.
    if new.service_id is not null then
      for sp in
        select product_id, qty from service_products where service_id = new.service_id
      loop
        v_need := sp.qty;
        for b in
          select id, qty from stock_batches
          where product_id = sp.product_id and qty > 0
          order by expires_on nulls last, received_on, id
        loop
          exit when v_need <= 0;
          v_take := least(b.qty, v_need);
          update stock_batches set qty = qty - v_take where id = b.id;
          v_need := v_need - v_take;
        end loop;
      end loop;
    end if;
  end if;
  return new;
end $function$;

commit;

-- ======================================================================================
-- POST-APPLY VERIFICATION (run rolled back; all must pass BEFORE v12 is applied)
-- ======================================================================================
--   1. A staffed appointment completion lands a sale carrying that staff_id.
--   2. The sale is created EXACTLY ONCE (re-completing does not duplicate).
--   3. FEFO still deducts, oldest-expiry-first.
--   4. CONTROL, EXPECTED TO FAIL: a cross-tenant staff_id raises rather than attributing.
--   5. No live row moved: sales still 6, still 0 with staff_id.
--
-- ======================================================================================
-- OPEN QUESTIONS RAISED BY THIS FILE
-- ======================================================================================
-- Q13 `appointments_staff_id_fkey` is single-column `staff(id)` while `sales_staff_fk` and
--     `appointments_branch_fk` are composite. An appointment can therefore reference another
--     tenant's staff. v12a fails closed on it; the schema should make it unrepresentable.
--     v11a-owned change.
-- Q14 Package commission is undecided: `sell_package` books revenue upfront with no seller, and
--     `use_package_session` inserts $0 sales. Commission ONCE at purchase or PER session?
--     Needs an owner ruling; belongs with v10's sale_policies framework.
-- Q15 `app.on_appointment_completed` does not carry `appointments.branch_id` either — the sale
--     falls through to trg_sales_default_branch and lands at the BUSINESS DEFAULT branch, which
--     is wrong for any multi-branch tenant and will misattribute branch-level payroll and
--     revenue. Same shape as Q9, different column. NOT fixed here (Q9 blocks v12; this does
--     not), but it is the obvious next one and it is cheap.
-- Q16 The FEFO block runs whenever status transitions INTO 'completed', but the sale insert is
--     idempotent. So completing -> reopening -> re-completing an appointment deducts stock
--     AGAIN while inserting no second sale. Pre-existing (v6), out of scope, unfixed by v12a.
-- ======================================================================================
