-- FRENLY v12 — COMMISSION is SNAPSHOTTED AT RECORD TIME, not resolved at read time.
-- (target Supabase project kyzovonwnscrzmkvocid; migration name `frenly_v12_commission_snapshot`)
-- P1 CORRECTION to `frenly_v11b_money`, WHICH IS ALREADY LIVE IN PRODUCTION (Q8).
--
-- APPLY ORDER: v10 -> v10.1 -> v11a -> v11b -> v11c (ALL LIVE) -> v12 (this file).
-- REVIEW-ONLY. NOT APPLIED, NOT VERIFIED BY ITS AUTHOR. Fable verifies and applies.
--
-- ======================================================================================
-- SCOPE — read this before anything else
-- ======================================================================================
-- v12 does EXACTLY six things and nothing else:
--   1. An immutable resolved COMMISSION RATE on `sales` (the snapshot).
--   2. Backfill of the 6 existing rows, through v10.1's audited window.
--   3. Snapshot future rows at INSERT.
--   4. `public.sale_commission` reads EACH ROW'S OWN snapshot.
--   5. v10.1's immutability guard is extended to FREEZE the new columns.
--   6. Nothing else. No payout ledger, no payroll report, no Talenox export, no RPC that
--      pays anybody, no new permission, no new table, no new FK.
--
-- THERE IS STILL NO PAYROLL IN THIS SCHEMA AFTER v12. That is the point: this file exists
-- so that payroll can be built ON a stable number, not so that payroll exists. Do not read
-- the presence of a frozen commission rate as "commission works".
--
-- ======================================================================================
-- THE DEFECT (Q8) — and why it is the SAME defect as the v10 P0, not merely similar
-- ======================================================================================
-- v11b shipped `public.sale_commission`, which resolves the commission rate EVERY TIME A ROW
-- IS READ, against TODAY'S mutable configuration:
--     staff.commission_service_bps / staff.commission_product_bps / services.commission_bps
--     ...gated by staff.commission_starts_on
-- `sales` stores no commission decision at all. So a raise — a routine, forward-looking,
-- entirely legitimate HR act — SILENTLY REWRITES WHAT EVERY PAST SALE PAID. Nothing is
-- corrupted and no row is updated, which is exactly why it is dangerous: last quarter's
-- payroll simply reads differently tomorrow than it did today, with no diff, no audit row,
-- and no way to reproduce a figure that was already paid out on.
--
-- This is v10's P0 with the nouns changed. v10.1's header describes it exactly:
--   "it resolves the policy EVERY TIME A ROW IS READ, against TODAY'S configuration ... a
--    routine, forward-looking configuration change silently REWRITES THE MEANING OF SALES
--    THAT COMPLETED MONTHS AGO."
-- Same mechanism (no stored decision), same blast radius shape (history is a function of the
-- present), same fix. THIS FILE DELIBERATELY INVENTS NOTHING. It reuses v10.1's pattern, its
-- vocabulary (`*_resolved_at`, "snapshot", "the decision is an attribute of the event"), its
-- backfill window, its guard, and its permission helper. If you are reviewing this file, read
-- 20260717_frenly_v10_1_policy_snapshot.sql first; v12 should contain no surprises.
--
-- MEASURED ON LIVE (business 'QA Test Cafe', inside `begin; ... rollback;`, 2026-07-17).
-- Note the 6 live sales all have staff_id IS NULL, so the defect had to be demonstrated on
-- rows created inside the transaction — it is latent on live data, not absent from the code:
--
--   Setup: staff 'Q8 Test Stylist', commission_service_bps = 1000 (10%),
--          commission_product_bps = 500 (5%); a 10000c quick_sale and a 20000c service sale,
--          both rung up 90 DAYS AGO (closed books, "last quarter").
--
--   BEFORE the raise:   quick_sale  -> rate_bps =  500, commission_cents =  500
--                       service     -> rate_bps =    0, commission_cents =    0
--                       PAYROLL TOTAL FOR THE TENANT        =  500 cents
--
--   THE CHANGE (two ordinary settings edits, today, both forward-looking in intent):
--       update staff    set commission_product_bps = 2000, commission_service_bps = 3000;
--       update services set commission_bps = null;      -- someone clears the override field
--
--   AFTER, re-reading THE SAME UNTOUCHED HISTORICAL ROWS:
--                       quick_sale  -> rate_bps = 2000, commission_cents = 2000   (4x)
--                       service     -> rate_bps = 3000, commission_cents = 6000   (0 -> 6000)
--                       PAYROLL TOTAL FOR THE TENANT        = 8000 cents   (16x)
--
--   The service row is the one to look at twice. It was recorded against a service whose
--   commission_bps was an explicit 0 — a deliberate "this service pays no commission". A
--   later, unrelated edit that merely CLEARS that field retroactively pays 6000c of
--   commission on a sale that was completed, closed and (once payroll exists) already paid
--   out on. Nobody edited the sale. Nobody edited a payout. The money simply appeared in
--   history.
--
-- ======================================================================================
-- WHY NOW, AND NOT AFTER PAYROLL
-- ======================================================================================
-- Q8 is harmless TODAY only because nothing consumes sale_commission: there is no payout
-- ledger, and 0 of the 6 live sales carry a staff_id, so every live commission figure is
-- currently 0 (verified — see the BACKFILL PLAN). The window in which this is free is now.
--
-- The owner has ruled payroll IN SCOPE (CLAUDE.md, 2026-07-17: UO-1 lifted; `/reports/payroll`
-- is real, complete and SG-localised in the competitor product, incl. Talenox CSV export).
-- The moment a payout ledger reads sale_commission, this stops being a reporting wobble and
-- becomes a restatement problem: fixing it then means reconciling frozen payouts against a
-- rate that has since moved, per staff member, per period, with real money already in real
-- bank accounts. v10.1 got to say "this is the one moment in this system's life when the
-- backfill is provably exact." v12 gets to say it too — but only until the first staff rate
-- is set. After that, every proof below degrades to a judgement call.
--
-- ======================================================================================
-- ARCHITECTURE — what goes ON THE ROW vs what stays DERIVED
-- ======================================================================================
-- CLAUDE.md's principle: "Append-only ledgers + derived views. Never a mutable stored
-- balance." v10.1 resolved the apparent tension and v12 applies its ruling verbatim:
--
--   ON THE ROW  ->  commission_rate_bps.  THE DECISION. "What rate did this sale earn at?"
--       This is an ATTRIBUTE OF THE EVENT, not an aggregate — the same category as
--       points_ledger.points (what was earned) and v10.1's counts_as_revenue (what this sale
--       meant). It is the only thing in the whole calculation that is a function of MUTABLE
--       config, and therefore the only thing that must be frozen.
--
--   DERIVED     ->  commission_cents.  THE ARITHMETIC.
--       floor(amount_cents * commission_rate_bps / 10000). Once the rate is on the row, BOTH
--       inputs are immutable columns of the same immutable row, so the output CANNOT drift.
--       There is no live lookup left in it. Storing it would buy exactly nothing and cost the
--       classic failure of a stored derived value: a future change to the rounding rule
--       silently disagrees with a column nobody thought to rewrite.
--
--   DERIVED     ->  every payroll TOTAL. sum(commission_cents). Same as v10.1: revenue stayed
--       `sum(amount_cents) filter (where counts_as_revenue)` and no total is stored anywhere.
--
-- This is v10.1's precedent applied without modification: the DECISION is snapshotted, the
-- TOTAL stays derived. The dividing line is "is it a function of mutable config?", not "is it
-- expensive to compute?".
--
-- WHY NOT snapshot a `staff_rate_version` FK instead of the integer: v10.1 rejected exactly
-- this and the argument carries over verbatim — "A pointer into config is still a read-time
-- dereference, and [the config table] is mutable, so the pointer would resolve through a row
-- someone can edit — the defect, one level of indirection down."
--
-- WHY NOT effective-dated staff rates (the bitemporal answer): rejected for v10.1's reasons.
-- It keeps an as-of join on every read, so every future payroll report, CSV export and payout
-- RPC must remember to pass the right as-of timestamp; one forgotten `as_of` silently
-- reintroduces this exact defect. And it must choose between `occurred_at` (caller-supplied,
-- backdatable) and `created_at` to join on, and either choice is wrong somewhere. A snapshot
-- sidesteps that entirely and does not block effective-dating later.
--
-- ======================================================================================
-- THE RESOLUTION ORDER IS PRESERVED EXACTLY — AND ZERO IS A REAL VALUE
-- ======================================================================================
-- v11a's contract, reproduced here byte-for-byte in behaviour:
--     kind='service'  ->  services.commission_bps  ->  staff.commission_service_bps  ->  0
--     any other kind  ->  staff.commission_product_bps                               ->  0
--     ...and 0 if the staff member is absent, or if the sale predates commission_starts_on.
--
-- ⚠️ ZERO-AS-A-REAL-VALUE IS LOAD-BEARING AND HAS ALREADY BITTEN THIS PROJECT TWICE.
--    `commission_bps = 0` means "this service pays NO commission" and MUST BEAT a staff 10%.
--    It must NOT be read as "unset". The whole difference lives in one `coalesce`:
--        coalesce(svc.commission_bps, st.commission_service_bps)     -- CORRECT: 0 wins
--        coalesce(nullif(svc.commission_bps, 0), st.commission_service_bps)  -- SILENTLY
--                                                    OVERPAYS EVERY ZERO-COMMISSION SERVICE
--    The second form looks tidier and is a payroll fraud generator. There is no `nullif` in
--    this file and there must never be one. Both directions are tested (Scenario D):
--        override = 0    -> rate 0     (0 beats the staff rate)
--        override = NULL -> rate 1000  (NULL falls through to the staff rate)
--    A test that only checks the first direction passes against the broken code.
--
-- ⚠️ THE GATE IS FOLDED INTO THE RATE, DELIBERATELY. `commission_starts_on` is a MUTABLE
--    column on `staff` compared against the sale's date at READ TIME — i.e. it is the same
--    defect wearing a different hat: moving the start date retroactively switches commission
--    on or off for closed periods. Folding it into the resolved rate at insert (a gated sale
--    snapshots rate 0) freezes it with everything else. Tested: Scenario E.
--
--    CONSEQUENCE, STATED PLAINLY — `rate_bps` CHANGES MEANING. v11b's view reported the RAW
--    rate in `rate_bps` while separately zeroing `commission_cents` for a gated sale, so it
--    could emit the incoherent pair (rate_bps = 500, commission_cents = 0). After v12,
--    rate_bps is the EFFECTIVE rate and that pair becomes (0, 0). This is a coherence fix and
--    it is the right answer for a payroll CSV, but it IS a behaviour change and it is flagged
--    rather than buried. DAY-ONE IMPACT ON LIVE DATA: ZERO, and provably so — no staff row
--    has commission_starts_on set (both are NULL, verified), so the gate never fires today.
--    Measured: v12's view output is IDENTICAL to v11b's on all 6 live rows, 0 diffs.
--
-- ⚠️ ONE MORE DELIBERATE CORRECTION, FLAGGED FOR THE REVIEWER. v11b's gate is
--    `s.occurred_at::date`, which casts a timestamptz using the SESSION's ambient TimeZone
--    (UTC on Supabase). `commission_starts_on` is a DATE that means a Singapore business date.
--    So a 9am-SGT sale on the start date is 01:00 UTC the SAME day (fine), but a 2am-SGT sale
--    is 18:00 UTC the PREVIOUS day and would be gated out. This is precisely the class of bug
--    CLAUDE.md records as the v1.6 outage ("two stacked timezone bugs ... anchoring to +08:00
--    ... Known residual: Week-view bucketing still uses browser-local time, architecturally
--    fragile"). v12 anchors to `at time zone 'Asia/Singapore'`.
--    I am changing this rather than preserving it because an ambient-timezone dependency baked
--    into an IMMUTABLE SNAPSHOT is strictly worse than one in a view: a view computed under the
--    wrong TZ is wrong until fixed; a snapshot computed under the wrong TZ is wrong FOREVER.
--    Day-one impact: zero (no commission_starts_on is set anywhere). If the reviewer wants
--    v11b's literal semantics preserved, delete the `at time zone` clause — it is one line and
--    it changes no live number today either way.
--    ⚖️ SG-SPECIFIC. Hardcoding Asia/Singapore is correct for the SG-first beachhead and WRONG
--    the day a second market lands. It belongs on `businesses` as a timezone column. Not
--    invented here (that is a schema decision with its own migration); flagged as Q10.
--
-- ======================================================================================
-- PERMISSIONS — NO NEW PERMISSION IS INVENTED, AND THAT IS AN ARGUED CHOICE
-- ======================================================================================
-- v10.1 ships app.has_perm(business, permission) over six permissions. v11b already gates
-- `sale_commission` on `view_finance` (owner, manager). v12 KEEPS THAT AND ADDS NOTHING.
--
-- The tempting seventh is a `reclassify_commission` twin of v10.1's `reclassify_sales`. It is
-- not added, because a permission with no subject is a liability unless it is being wired NOW:
--   * v10.1 defined `refund_sales` with no subject specifically so v11b could wire it, and
--     said so ("refund_sales IS A NAME WITH NO SUBJECT"). v11b wired it one migration later.
--     That is the bar. v12 has no such caller queued: there IS no commission restatement RPC
--     in this file (see below), so the permission would gate nothing for an unknown number of
--     migrations, and the next author would find a reviewed-looking name and assume a reviewed
--     design behind it.
--   * v12 EXPOSES NO NEW SURFACE. It adds a column to a table that is already read-gated, and
--     replaces the body of a view that is already gated on view_finance. There is no new verb
--     for a new permission to protect.
-- If payroll needs one, payroll's migration adds it alongside the RPC that uses it.
--
-- WHY THERE IS NO `reclassify_sale_commission()` RPC — the mirror of v10.1's §9 question.
-- v10.1's rule: counts_as_revenue is restatable BECAUSE IT HAS NO LEDGER ("nothing else in
-- the database was written because of it"); counts_as_visit and earns_points are frozen
-- because other append-only ledgers were written against them, and
-- "THE SNAPSHOT AND THE LEDGERS MUST NEVER DISAGREE."
-- Apply that rule to commission_rate_bps and it lands in an awkward spot that is worth naming
-- rather than glossing: TODAY it has no ledger, so by v10.1's own logic it WOULD be safely
-- restatable. But that is temporary and it is temporary BY DESIGN — the entire justification
-- for this migration's timing is that a payout ledger is coming. So:
--   * Building a restatement path now means designing it against the absence of the exact
--     thing that makes restatement hard. It would be reviewed as a presentation fact and would
--     silently become an entitlement fact the day payroll lands — and nothing would raise.
--     That is how v10's "verified feature" became v10.1's P0.
--   * Nothing needs it. No owner has ever seen a commission figure (every live one is 0), so
--     there is no wrong number in the wild to restate.
--   * The honest owner of the problem is the payroll migration, which must define restatement
--     WITH its compensating append-only payout adjustment, in one reviewed piece — the same
--     ruling v10.1 made when it deferred entitlement reclassification to v11b rather than
--     half-building it.
-- CONSEQUENCE, STATED PLAINLY: after v12 a commission rate snapshotted in error CANNOT be
-- corrected by any supported path. That is a deliberate, temporary dead end, identical in
-- shape to the one v10.1 accepted for refunds, and it is safe only because the number is
-- currently unused. It MUST be resolved by the payroll migration BEFORE the first payout.
--
-- ======================================================================================
-- STYLE / SAFETY / THE TWO CONFIRMED TRAPS
-- ======================================================================================
-- plpgsql SECURITY DEFINER + `set search_path = public`. RLS fail-closed.
--   * NO NEW RPC. v12 adds no function in schema `public`, so there is no
--     `revoke ... from public, anon` / `grant ... to authenticated` block to write. The two
--     new functions are in schema `app`, which `authenticated` has no USAGE on. They are
--     reached only from triggers and from the view's already-parsed tree.
--   * TRAP (a) PGRST201 — the v1.6 outage. NOT APPLICABLE, ASSERTED NOT ASSUMED: v12 adds NO
--     foreign key and no table. `commission_rate_bps` is a plain integer, not a reference. No
--     table pair gains a second FK. Nothing for PostgREST to fail to disambiguate.
--   * TRAP (b) `authenticated` default ACLs / TRUNCATE — v11c revoked fleet-wide. NOT
--     APPLICABLE AND NOT REGRESSED: v12 CREATES NO TABLE, so no new default ACL is granted and
--     there is nothing new to revoke truncate on. `sale_commission` is a VIEW; views cannot be
--     truncated. Adding a column to `sales` does not alter `sales`'s ACL, which v10.1 already
--     hardened (`revoke update, delete, truncate ... from authenticated, anon`). Post-apply
--     check in the verification block confirms v11c's fleet-wide state is untouched.
--   * app.audit() dereferences new.id — irrelevant here: v12 adds no audit trigger. The
--     backfill's audit rows come from v10.1's begin/end_sales_backfill, which build their
--     jsonb by hand and pass entity_id => null.
--
-- PRE-FLIGHT (verified live, read-only, 2026-07-17 — RE-VERIFY BEFORE APPLYING):
--   * public.sales = 6 rows, ALL owned by the disposable QA tenant 'QA Test Cafe'. The real
--     tenant 'kopi tiam' has 0 sales.
--   * ALL 6 have staff_id IS NULL. sum(rate_bps) = 0, sum(commission_cents) = 0.
--   * public.staff = 2 rows, both role='owner', both with commission_service_bps,
--     commission_product_bps and commission_starts_on ALL NULL. No rate has ever been set.
--   * public.services = 1 row, commission_bps IS NULL.
--   * public.sale_commission is `security_invoker = on` and gated on view_finance.
--   * `sales` BEFORE INSERT triggers today: trg_sale_policy_snapshot, trg_sales_default_branch.

begin;

-- 1. The snapshot. ---------------------------------------------------------------------
--    Nullable first so the backfill can run; NOT NULL is asserted at the end of section 2,
--    after every existing row has a value. (v10.1 §1, same shape.)
alter table public.sales
  add column if not exists commission_rate_bps    integer,
  add column if not exists commission_resolved_at timestamptz;

comment on column public.sales.commission_rate_bps is
  'IMMUTABLE SNAPSHOT of the commission rate in basis points as resolved when this sale was '
  'RECORDED, per v11a''s order (services.commission_bps -> staff.commission_service_bps -> 0 '
  'for kind=service; staff.commission_product_bps -> 0 otherwise), with the '
  'staff.commission_starts_on gate and the no-staff case already FOLDED IN (both yield 0). '
  'Payroll MUST read this column, never staff.commission_*_bps. 0 is a REAL RATE meaning '
  '"no commission", never "unset". There is deliberately NO supported path to change this '
  'after insert — see the header.';
comment on column public.sales.commission_resolved_at is
  'When the commission snapshot was taken (insert time). Backfilled rows carry created_at. '
  'Mirrors policy_resolved_at (v10.1).';

-- 1.1 THE RESOLVER — one definition, used by BOTH the backfill and the trigger. -----------
--     Single source of truth, the way v10 made app.sale_policy_defaults() the single source
--     of truth for policy. If the backfill and the trigger resolved separately they could
--     drift, and the drift would be invisible: history and the future would disagree with no
--     error anywhere.
--
--     Reproduces v11b's live arithmetic EXACTLY, with the two deliberate corrections argued in
--     the header (the gate is folded in; the date is anchored to SGT).
--     The `left join public.staff st on st.id = p_staff AND st.business_id = p_business` pairing
--     is not decoration: it makes a cross-tenant staff_id resolve to rate 0 rather than to
--     another tenant's rate. v11a's composite FK already makes that unreachable via `sales`;
--     this is defence in depth at no cost, and it matches v11a's TENANT INTEGRITY reasoning
--     ("A single-column FK only asks 'does this id exist?' — never 'does it exist IN MY
--     TENANT?'").
create or replace function app.commission_rate_bps(
  p_business    uuid,
  p_kind        text,
  p_staff       uuid,
  p_appointment uuid,
  p_occurred_at timestamptz)
returns integer language sql stable security definer set search_path = public as $$
  select case
           -- No staff attribution -> nobody to pay. v11b's `when st.id is null then 0`.
           when st.id is null then 0
           -- The gate, FOLDED IN and anchored to SG business dates (see header).
           when st.commission_starts_on is not null
                and (p_occurred_at at time zone 'Asia/Singapore')::date < st.commission_starts_on
                then 0
           -- v11a's resolution order. NOTE THE coalesce AND THE ABSENCE OF ANY nullif:
           -- a service override of 0 is a REAL 0 and MUST beat the staff rate. The outer
           -- coalesce turns only a genuinely-NULL (never configured) rate into 0.
           else coalesce(
                  case when p_kind = 'service'
                       then coalesce(svc.commission_bps, st.commission_service_bps)
                       else st.commission_product_bps
                  end, 0)
         end
  from (select 1) _
  left join public.staff st       on st.id  = p_staff and st.business_id = p_business
  left join public.appointments a on a.id   = p_appointment
  left join public.services svc   on svc.id = a.service_id
$$;

-- 2. BACKFILL. See BACKFILL PLAN at the foot of this file for the full argument. ---------
--    `sales` is append-only since v10.1, so this REQUIRES v10.1's audited window. A bare
--    `update public.sales` here would abort the migration exactly the way v11a §1.7's did
--    (v10.1 measured it: "ERROR: sales is append-only: UPDATE is not permitted"). Those
--    functions do not exist before v10.1, so this file fails loudly if v10.1 is skipped rather
--    than silently leaving the snapshot null.
--    This is legal under v10.1's WINDOW 2 because commission_rate_bps is a column added AFTER
--    v10.1: the window permits later-added columns to move and freezes every v10.1-era column
--    byte-identical. Section 5 then closes that door behind us.
select app.begin_sales_backfill(
  'frenly_v12_commission_snapshot',
  'populate the new sales.commission_rate_bps / commission_resolved_at snapshot on pre-v12 historical rows');

update public.sales s set
  commission_rate_bps    = app.commission_rate_bps(s.business_id, s.kind, s.staff_id,
                                                   s.appointment_id, s.occurred_at),
  commission_resolved_at = s.created_at
where s.commission_rate_bps is null;

select app.end_sales_backfill();

--    Fail-closed: app.commission_rate_bps() is strict-free and always returns an integer
--    (0 in every degenerate case), so this NOT NULL cannot trip on the current data. It is
--    here so that if the resolver is ever changed to return NULL, the migration aborts rather
--    than leaving a hole that reads as "no commission".
alter table public.sales
  alter column commission_rate_bps    set not null,
  alter column commission_resolved_at set not null;

-- 3. Indexes. ---------------------------------------------------------------------------
--    Payroll's shape is "one staff member, one period": exactly this predicate. Partial,
--    because a sale with no commissionable staff is never in a payroll run and there is no
--    reason to index 6 of 6 current rows (and every gift_card/membership row forever).
create index if not exists sales_commission_payroll_idx
  on public.sales (business_id, staff_id, occurred_at)
  where staff_id is not null and commission_rate_bps > 0;

-- 4. THE SNAPSHOT TRIGGER — resolve once, at record time. -------------------------------
--    BEFORE INSERT, mirroring v10.1 §6. Caller-supplied values are ALWAYS overwritten — the
--    snapshot is the database's decision, not the client's. That is what makes "commission is
--    resolved at record time" an INVARIANT rather than a convention, and it matters more here
--    than for v10.1's flags: `sales` is INSERT-able directly through PostgREST by anyone with
--    create_sales (v10.1's sales_insert policy), so without this a stylist could POST their own
--    commission rate. Tested (Scenario C.1): a caller passing 9999 lands 500.
--
--    ORDERING: Postgres fires BEFORE triggers in NAME order —
--      trg_sale_commission_snapshot < trg_sale_policy_snapshot < trg_sales_default_branch
--      ('c' < 'p'; 'trg_sale_' < 'trg_sales'). So this one runs FIRST.
--    That order is IRRELEVANT and deliberately so: this trigger reads only caller-supplied
--    columns (business_id, kind, staff_id, appointment_id, occurred_at) and writes only its own
--    two. It does not read branch_id or any policy flag, and nothing reads its columns. No
--    dependency exists in either direction. Recorded so nobody has to re-derive it — and so
--    that a future author who renames a trigger does not have to wonder what breaks.
--
--    Runs for EVERY insert, including the 5 RPC writers that never set staff_id
--    (on_appointment_completed, sell_package, issue_gift_card, enroll_membership,
--    use_package_session) — all of which correctly snapshot rate 0. See DEFECT Q9 below:
--    that 0 is currently WRONG for appointment completions, and v12 deliberately preserves it.
create or replace function app.on_sale_commission_snapshot()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.commission_rate_bps := app.commission_rate_bps(
    new.business_id, new.kind, new.staff_id, new.appointment_id, new.occurred_at);
  new.commission_resolved_at := now();
  return new;
end $$;

drop trigger if exists trg_sale_commission_snapshot on public.sales;
create trigger trg_sale_commission_snapshot
  before insert on public.sales
  for each row execute function app.on_sale_commission_snapshot();

-- 5. EXTEND v10.1'S IMMUTABILITY GUARD to freeze the new columns. ------------------------
--    THIS SECTION IS NOT OPTIONAL AND IT IS THE EASIEST THING IN THIS FILE TO FORGET.
--    v10.1's guard hardcodes the tuple of columns each window must leave byte-identical. Its
--    WINDOW 2 exists to let a LATER migration populate a column that did not exist when v10.1
--    was written — which is exactly how section 2 above is legal. But that permission does not
--    expire: without this section, `commission_rate_bps` would remain in the "later-added, may
--    move" set FOREVER, and any future migration that opened a backfill window for an unrelated
--    column could rewrite every commission rate in history, audited only as "window open".
--    That is the defect again, one layer down — the config would be immutable but the snapshot
--    would not be.
--
--    So: the body below is v10.1's, unchanged except that BOTH tuples gain
--    `commission_rate_bps` and `commission_resolved_at`. Nothing else moves. Reviewed as a
--    diff against the live definition, which is exactly what it is.
--    (The DELETE branch, both window mechanics, the `restrict_violation` errcode and the
--    reclassify token-is-the-row-id design are all v10.1's and are reproduced verbatim.)
--
--    ⚠️ ORDER MATTERS WITHIN THIS FILE: section 2 backfills BEFORE this redefinition lands.
--    If you reorder them, section 2's own update trips this guard and the migration aborts.
create or replace function app.sales_immutable_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_reclassify text; v_backfill text;
begin
  if tg_op = 'DELETE' then
    raise exception 'sales is append-only: DELETE is not permitted (sale %). There is no '
                    'reversal path in this schema yet — refunds/reversals are deferred to '
                    'v11b.', old.id
      using errcode = 'restrict_violation';
  end if;

  v_reclassify := nullif(current_setting('app.reclassify_sale', true), '');
  v_backfill   := nullif(current_setting('app.sales_backfill',  true), '');

  -- WINDOW 1 — audited accounting reclassification of ONE named row (v10.1 §9).
  -- counts_as_revenue remains the ONLY column that may move. commission_rate_bps is now
  -- explicitly frozen here too: a revenue restatement must not silently re-rate a payout.
  if v_reclassify is not null and v_reclassify = old.id::text then
    if (new.id, new.business_id, new.client_id, new.kind, new.amount_cents, new.occurred_at,
        new.created_at, new.note, new.appointment_id, new.product_id, new.qty,
        new.counts_as_visit, new.earns_points, new.policy_resolved_at,
        new.commission_rate_bps, new.commission_resolved_at)
       is distinct from
       (old.id, old.business_id, old.client_id, old.kind, old.amount_cents, old.occurred_at,
        old.created_at, old.note, old.appointment_id, old.product_id, old.qty,
        old.counts_as_visit, old.earns_points, old.policy_resolved_at,
        old.commission_rate_bps, old.commission_resolved_at)
    then
      raise exception 'reclassification of sale % may change counts_as_revenue and nothing '
                      'else', old.id
        using errcode = 'restrict_violation';
    end if;
    return new;
  end if;

  -- WINDOW 2 — migration-time attribution backfill (v10.1 §5.1). Every column that existed
  -- when v12 was written must survive byte-identical; only columns added LATER may move.
  if v_backfill is not null then
    if (new.id, new.business_id, new.client_id, new.kind, new.amount_cents, new.occurred_at,
        new.created_at, new.note, new.appointment_id, new.product_id, new.qty,
        new.counts_as_revenue, new.counts_as_visit, new.earns_points, new.policy_resolved_at,
        new.commission_rate_bps, new.commission_resolved_at)
       is distinct from
       (old.id, old.business_id, old.client_id, old.kind, old.amount_cents, old.occurred_at,
        old.created_at, old.note, old.appointment_id, old.product_id, old.qty,
        old.counts_as_revenue, old.counts_as_visit, old.earns_points, old.policy_resolved_at,
        old.commission_rate_bps, old.commission_resolved_at)
    then
      raise exception 'backfill window "%" may only populate columns added after v12; it '
                      'may not change any economic fact, the policy snapshot, or the '
                      'commission snapshot of sale %',
                      v_backfill, old.id
        using errcode = 'restrict_violation';
    end if;
    return new;
  end if;

  raise exception 'sales is append-only: UPDATE is not permitted (sale %). Use '
                  'public.reclassify_sale_policy() for an audited revenue restatement, or '
                  'app.begin_sales_backfill() from a migration to populate a new column.',
                  old.id
    using errcode = 'restrict_violation';
end $$;

-- (The trigger itself is v10.1's and is NOT re-created: `create or replace function` swaps the
--  body under the existing trg_sales_immutable_guard. Re-creating the trigger would be a no-op
--  at best and a window where `sales` is unguarded at worst.)

-- 6. THE VIEW now READS THE SNAPSHOT. ---------------------------------------------------
--    Diff vs the live v11b definition, and nothing else:
--      (a) THE FIX — the three-table read-time resolution (LEFT JOIN staff / appointments /
--          services, with the rate CASE computed twice) is GONE. `rate_bps` is now the row's
--          own frozen column. This is the line that stops a raise from moving closed books.
--      (b) The joins to staff/appointments/services are DELETED ENTIRELY. They existed only to
--          resolve the rate. Removing them is not just tidiness: while they were there, the
--          next author had a live config join sitting in the file, ready to be reached for.
--          v10.1 made the same point about get_sale_policy — the join IS the defect.
--      (c) `commission_cents` is now derived from two immutable columns of the same immutable
--          row. Identical arithmetic (floor(amount * rate / 10000), integer), so no rounding
--          behaviour changes.
--    PRESERVED EXACTLY: the column list, names, order and types (so `create or replace view`
--    is legal and no PostgREST/UI caller breaks); `security_invoker = on`; and the
--    `where app.has_perm(s.business_id, 'view_finance')` gate — v11b's argument for it still
--    holds and is not re-litigated here.
--    A security_invoker view MAY call app.* despite `authenticated` having no USAGE on schema
--    `app` — v11b proved this live (schema USAGE is a parse-time check; a view stores an
--    already-parsed tree holding the OID). This view already relies on it today.
create or replace view public.sale_commission
with (security_invoker = on) as
select s.id                  as sale_id,
       s.business_id,
       s.branch_id,
       s.staff_id,
       s.kind,
       s.occurred_at,
       s.amount_cents,
       -- v12's IMMUTABLE SNAPSHOT. NOT a live lookup. This is the whole migration.
       s.commission_rate_bps as rate_bps,
       -- DERIVED, and it cannot drift: both inputs are immutable columns of this row.
       floor((s.amount_cents * s.commission_rate_bps)::numeric / 10000.0)::integer
                             as commission_cents
from public.sales s
where app.has_perm(s.business_id, 'view_finance');

commit;

-- ======================================================================================
-- DEFECT Q9 — FOUND WHILE WRITING THIS FILE. NOT FIXED HERE. NEEDS AN OWNER DECISION.
-- ======================================================================================
-- **`app.on_appointment_completed()` NEVER SETS sales.staff_id, SO EVERY SERVICE COMMISSION
--   IS SILENTLY ZERO.** Verified against the live function body:
--     insert into sales (business_id, client_id, kind, amount_cents, appointment_id, note)
--     values (new.business_id, new.client_id, 'service', v_amount, new.id, 'appointment completed')
--   `appointments.staff_id` EXISTS and is populated — it is simply not carried across. Of the
--   7 functions that insert into `sales`, exactly ONE (public.record_quick_sale) sets staff_id
--   at all (verified by scanning prosrc). So the primary path by which a stylist earns service
--   commission — completing their appointment — produces a sale with no staff attribution, and
--   sale_commission's `when st.id is null then 0` pays them nothing. Forever.
--
-- THE INTERACTION WITH THIS MIGRATION IS THE URGENT PART: before v12 this is a live bug that
-- corrects itself the moment someone fixes the insert (the view re-resolves and every past
-- appointment sale starts paying). AFTER v12 it is FROZEN INTO HISTORY — every sale recorded
-- between now and the fix carries a permanent rate-0 snapshot, and v12 deliberately ships no
-- path to restate it. **Fixing Q9 is therefore MORE urgent than v12, not less, and arguably
-- BLOCKS it.**
--
-- WHY v12 DOES NOT FIX IT — and I would rather flag this than quietly widen my own scope:
--   * It would change a live number on day one. v10.1's discipline was explicit ("v10.1 changes
--     no number on day one; it only freezes them") and this file's own regression test asserts
--     0 diffs against v11b. Carrying the appointment's staff into the resolver would make that
--     test go red BY DESIGN, and I would lose the only evidence that the snapshot is faithful.
--   * It means re-declaring app.on_appointment_completed(), the most-tested object in the
--     schema after on_sale_recorded (v6's idempotency chain runs through it). v11a's header
--     refused to touch on_sale_recorded for exactly this reason and it was right.
--   * The correct fix is one line in on_appointment_completed (`staff_id => new.staff_id`),
--     plus a decision only the owner can make: what happens to appointment sales ALREADY
--     recorded with no staff? They are unattributable from `sales` alone but ARE recoverable
--     via `appointments.staff_id` — so a one-off, audited, owner-approved backfill through
--     v10.1's window is available. That window is open only until payroll pays out.
--   * Alternative considered and rejected: make the resolver fall back to `a.staff_id` when
--     `s.staff_id is null`. It fixes the number without touching the trigger — but it makes
--     the snapshot disagree with the row's own staff_id (rate > 0, staff_id NULL), so payroll
--     cannot tell WHO to pay. It fixes the arithmetic and not the attribution, which is worse
--     than the honest zero.
--
-- RECOMMENDED ORDER: fix Q9 (+ backfill sales.staff_id from appointments.staff_id inside
-- app.begin_sales_backfill, owner-approved) FIRST, then apply v12. If v12 goes first, the
-- Q9 backfill must ALSO restate commission_rate_bps — which section 5 above now forbids,
-- deliberately. That is not an argument to weaken section 5; it is an argument to fix Q9 first.
--
-- ======================================================================================
-- WHAT THE UI MUST READ AFTER THIS (app/index.html — NOT touched by this migration)
-- ======================================================================================
-- Nothing changes for the UI, and that is by design: `sale_commission` keeps its exact column
-- list, names, order and types, so any existing/future caller is unaffected. There is today no
-- commission UI at all (no payroll report exists), so the blast radius is zero.
--
-- FOR WHOEVER BUILDS PAYROLL — the two rules this migration exists to make true:
--   1. A payroll run reads `sale_commission.rate_bps` / `.commission_cents`, i.e. the SALE'S
--      OWN snapshot. It MUST NEVER join `staff.commission_*_bps` or `services.commission_bps`
--      to a historical sale. That join IS the defect. Those columns describe what the NEXT sale
--      will earn — the future, not the past. (Exactly v10.1's get_sale_policy rule.)
--   2. A Settings screen that edits a commission rate should now say plainly: "this affects
--      sales recorded from now on. Past sales keep the rate they were recorded with." That
--      sentence is true only because of this migration. Before it, the same screen silently
--      restated every payout the business had ever made.
--
-- ======================================================================================
-- ROLLBACK PLAN  (undo v12; restores v11b's behaviour, defect included, exactly as it was)
-- ======================================================================================
-- Safe at any time: v12 adds two columns, one index, two app.* functions, and swaps two bodies
-- (the guard and the view). It destroys NO pre-existing data and creates no v12-native data
-- other than the snapshot columns and the two audit_log rows from begin/end_sales_backfill —
-- all additive.
--
--   begin;
--   -- 1. Stop snapshotting.
--   drop trigger if exists trg_sale_commission_snapshot on public.sales;
--   drop function if exists app.on_sale_commission_snapshot();
--   -- 2. Restore v11b's read-time view. Re-run §"1.2/sale_commission" of
--   --    20260717_frenly_v11b_money.sql VERBATIM — that file is the source of truth, do not
--   --    hand-retype it. (`create or replace view` will NOT work if you also drop columns in
--   --    step 5 first: restore the view BEFORE dropping the columns, or the replace fails.)
--   -- 3. Restore v10.1's guard body: re-run §5.2 of 20260717_frenly_v10_1_policy_snapshot.sql
--   --    VERBATIM. NOTE: leaving v12's guard in place is HARMLESS ONLY IF step 5 is skipped —
--   --    if the columns are dropped while the guard still names them, EVERY update to `sales`
--   --    raises a plpgsql "record new has no field" error and both windows are dead. Do step 3
--   --    before step 5, always.
--   drop function if exists app.commission_rate_bps(uuid, text, uuid, uuid, timestamptz);
--   -- 4. Index.
--   drop index if exists public.sales_commission_payroll_idx;
--   -- 5. Columns. LAST, and only if you are sure — it discards the snapshots irreversibly.
--   alter table public.sales
--     drop column if exists commission_rate_bps,
--     drop column if exists commission_resolved_at;
--   commit;
--
-- PARTIAL ROLLBACK (recommended if v12 misbehaves in reporting rather than in the engine):
--   run steps 2-3 only. The snapshot columns are then dead weight but harmless, history is
--   preserved for a re-apply, and reporting reverts to v11b's read-time behaviour. Prefer this:
--   dropping the columns is the only irreversible step in the whole plan, and re-applying v12
--   later would have to re-derive snapshots that are, by then, no longer provable (see below).
--
-- ======================================================================================
-- BACKFILL PLAN
-- ======================================================================================
-- QUESTION: the 6 existing rows predate the column. What commission did they MEAN when
-- recorded? v10.1 faced this identically and answered "today's resolver IS the policy in force
-- at record time, provably, because zero overrides ever existed". DOES THE EQUIVALENT CLAIM
-- HOLD FOR COMMISSION?
--
-- **YES — AND ON STRONGER GROUND THAN v10.1's, BY A DIFFERENT ARGUMENT.** This matters, because
-- v10.1's own form of the argument DOES NOT hold here and reusing it would be false:
--
--   ✗ THE ARGUMENT THAT DOES *NOT* WORK — "audit_log proves no rate ever changed."
--     v10.1 could say this because `sale_policies` was audited by trg_sale_policies_audit from
--     the moment it was created, so 0 audit rows PROVED no override ever existed. The
--     equivalent claim for commission is NOT available and must not be asserted:
--       * `public.services` HAS NO AUDIT TRIGGER AT ALL (verified: pg_trigger returns zero
--         non-internal triggers on the table). `services.commission_bps` could have been set to
--         500, used, and cleared, leaving no trace anywhere. Absence of evidence is not
--         evidence of absence when nothing was ever recording.
--       * `public.staff` DOES have trg_staff_audit (AFTER INSERT OR UPDATE OR DELETE ->
--         app.audit()), and audit_log holds 0 rows for entity='staff'. But 0 rows is ALSO what
--         you see if every staff write PREDATES the trigger's creation — and it must, because
--         2 staff rows exist and none produced an INSERT audit row. So the trigger's silence
--         does not cover the whole history of the table either.
--     Anyone reusing v10.1's sentence here would be asserting a proof they do not have. Do not.
--
--   ✓ THE ARGUMENT THAT DOES WORK — "no sale has a commission subject, so no rate can apply."
--     The proof does not need the config history at all, which is precisely why it is stronger:
--       * ALL 6 live sales have staff_id IS NULL (verified: `select count(*) from sales where
--         staff_id is not null` = 0). `staff_id` was added by v11a TODAY and is set by exactly
--         one writer (public.record_quick_sale), which has never run against these rows.
--       * app.commission_rate_bps() returns 0 on `st.id is null` BEFORE it reads any rate. The
--         staff rate, the service override and commission_starts_on are never consulted.
--       * Therefore the snapshot for all 6 rows is 0 UNDER EVERY POSSIBLE HISTORICAL
--         CONFIGURATION. Not "0 because the config says so today" — 0 because there is no
--         staff member to pay, and that fact is recorded on the immutable sale row itself.
--     This is a replay of the original decision, not a re-judgement, and unlike v10.1's version
--     it does not depend on any audit trail being complete.
--     Belt and braces (both true, neither load-bearing): every staff row has
--     commission_service_bps, commission_product_bps and commission_starts_on ALL NULL, and the
--     single `services` row has commission_bps NULL. Even if a rate DID apply, it would resolve
--     to 0 through the outer coalesce.
--
--   MEASURED, ROLLED BACK, ON LIVE: after the backfill, all 6 rows carry rate_bps = 0, and
--   v12's view output is IDENTICAL to v11b's on every one of the 6 (0 diffs on both rate_bps
--   and commission_cents). v12 changes no number on day one; it only freezes them.
--
-- BLAST RADIUS: 6 rows, ALL owned by the disposable QA tenant 'QA Test Cafe'. The real tenant
--   'kopi tiam' has 0 sales. No real customer's books, and no real staff member's pay, moves.
--   Verified at authoring time; RE-VERIFY IMMEDIATELY BEFORE APPLYING:
--     select b.name, count(s.id) as sales, count(s.staff_id) as with_staff,
--            count(s.id) filter (where s.commission_rate_bps is null) as unsnapshotted
--     from businesses b left join sales s on s.business_id = b.id group by b.name;
--     -- expect: kopi tiam 0/0, QA Test Cafe 6/0. IF with_staff > 0, STOP: the proof above
--     -- has collapsed and the backfill is a judgement call, not a replay. Reconstruct that
--     -- row's rate by hand and get owner sign-off per the production-write approval gate.
--
-- POST-APPLY VERIFICATION (all four must pass):
--   -- 1. No row escaped the backfill (also guaranteed by the NOT NULL; belt and braces):
--        select count(*) from sales where commission_rate_bps is null;                  -- 0
--   -- 2. THE REGRESSION TEST — the snapshot must agree with what v11b reported, i.e. v12
--        changes no number on day one. Run BEFORE applying (capture) and after (compare):
--        select sale_id, rate_bps, commission_cents from sale_commission order by sale_id;
--        -- must be byte-identical across the apply. Any diff: STOP and roll back rather than
--        -- reconcile by hand.
--   -- 3. The guard actually froze the new columns (v10.1's window must no longer let them move):
--        begin;
--          select app.begin_sales_backfill('probe','verifying the v12 guard freezes commission');
--          update sales set commission_rate_bps = 9999 where id = (select id from sales limit 1);
--        rollback;
--        -- must raise: 'backfill window "probe" may only populate columns added after v12...'
--        -- If it SUCCEEDS, section 5 did not land and the migration is not finished.
--   -- 4. v11c's fleet-wide TRUNCATE revoke is not regressed (v12 creates no table, so this
--        must be unchanged rather than merely acceptable):
--        select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
--         where n.nspname = 'public' and c.relkind = 'r'
--           and has_table_privilege('authenticated', c.oid, 'TRUNCATE');                -- 0
--        -- MEASURED live 2026-07-17: 0 of 47 tables. v11c intact, and v12 cannot regress it
--        -- because it creates no table.
--        --
--        -- ⚠️ DO NOT USE information_schema.role_table_grants FOR THIS CHECK. I wrote it that
--        -- way first and it reported 8 "TRUNCATE grants to authenticated", which looks exactly
--        -- like a v11c regression and is not one. All 8 are VIEWS — cash_drawer_balance,
--        -- cash_drawer_session_summary, client_credit_balance, client_points_balance,
--        -- product_stock, sale_balance, sale_commission, service_bookable — carrying the
--        -- pg_default_acl's `authenticated=arwdDxtm` (which is STILL live for new objects; v11c
--        -- revoked on existing tables, it did not change the default ACL). A view cannot be
--        -- truncated, so the bit is meaningless there, and v11c correctly ignored views.
--        -- `has_table_privilege` filtered to relkind='r' is the question that matters.
--        -- Recorded because the false positive is alarming, reproducible, and will otherwise
--        -- cost the next reviewer the same hour it cost me.
--
-- IF THIS EVER RUNS AGAINST A DB WHERE SALES CARRY staff_id (i.e. not this one): the proof
--   above collapses and section 2 becomes a re-judgement of history under whatever rates happen
--   to be current — the very defect being fixed, applied once, permanently, to the payroll
--   ledger. In that case DO NOT run section 2 as written. There is no honest replay available,
--   because `services` is unaudited and `staff`'s audit does not cover its full history: the
--   rate that was in force is simply NOT RECOVERABLE from this database. The honest options,
--   in order of preference:
--     (a) Have the owner state the rates in force per staff member per period, in writing, and
--         backfill from that statement — the rate came out of a human agreement anyway, and a
--         signed statement is better evidence than a config table we cannot date.
--     (b) Backfill 0 and treat all pre-v12 sales as non-commissionable, if no payout was ever
--         made against them (true today: there is no payout ledger). Defensible precisely
--         because nobody has been paid.
--     (c) Add the audit triggers `services` is missing, wait, and snapshot only from that point
--         — accepting that history is unrecoverable rather than inventing it.
--   Do NOT "replay" against current config and call it a backfill. That is the P0, laundered.
--   Whichever is chosen needs owner sign-off per the production-write approval gate.
--
-- ======================================================================================
-- OPEN QUESTIONS RAISED BY THIS FILE
-- ======================================================================================
-- Q9  (BLOCKING, above) on_appointment_completed drops appointments.staff_id, so every service
--     commission is 0. Fix + owner-approved staff_id backfill BEFORE v12, or the zero freezes.
-- Q10 `Asia/Singapore` is hardcoded in app.commission_rate_bps. Correct for the SG beachhead,
--     wrong for market #2. Belongs as `businesses.timezone`. ⚖️
-- Q11 `public.services` has NO audit trigger, so commission_bps (and price_cents) can be
--     changed with no trace. This is what cost v12 the clean version of v10.1's backfill proof.
--     Every other money-adjacent table in this schema is audited. Recommend adding
--     `trg_services_audit AFTER INSERT OR UPDATE OR DELETE -> app.audit()`. Not done here: it
--     is a v11a-owned table and adding an audit trigger is not a commission-snapshot change.
-- Q12 There is no supported way to correct a commission snapshot (argued in the header). The
--     payroll migration MUST resolve this before the first payout.
--
-- ======================================================================================
-- MANUAL TEST SCENARIOS
-- ======================================================================================
-- All executed as rolled-back transactions against LIVE (project kyzovonwnscrzmkvocid) on
-- 2026-07-17, as the QA Test Cafe owner
--   (set_config('request.jwt.claims','{"sub":"4be3825c-...","role":"authenticated"}', true)).
-- Measured results are recorded inline. NOTHING WAS COMMITTED.
--
-- Scenario A — THE DEFECT ITSELF, before the fix (THE FAILING TEST; run against LIVE v11b):
--   1. staff 'Q8 Test Stylist': service 1000bps, product 500bps. A 10000c quick_sale and a
--      20000c service sale (service.commission_bps = 0), both occurred_at = now() - 90 days.
--   2. Read sale_commission ->     quick_sale (500, 500) | service (0, 0) | TOTAL 500c
--   3. `update staff set commission_product_bps=2000, commission_service_bps=3000;`
--      `update services set commission_bps=null;`
--   4. Re-read THE SAME HISTORICAL ROWS ->
--                                  quick_sale (2000, 2000) | service (3000, 6000) | TOTAL 8000c
--      MEASURED: 500 -> 8000 cents. A raise moved last quarter's payroll 16x. THIS IS THE BUG.
--
-- Scenario B — THE FIX (same setup, after v12):
--   1. BEFORE the raise ->  quick_sale (500, 500) | service (0, 0) | TOTAL 500c
--   2. The identical two updates from A.3.
--   3. AFTER  the raise ->  quick_sale (500, 500) | service (0, 0) | TOTAL 500c   UNCHANGED.
--   4. THE CONTROL, EXPECTED TO FAIL AND OBSERVED FAILING: v11b's read-time computation was
--      kept alive beside the fixed view as `sale_commission_control_readtime` and read at the
--      same instant, same tenant, same rows:
--          snapshot view (v12) -> 500 cents      STABLE
--          control     (v11b)  -> 8000 cents     MOVED
--      The control is the proof that the test can fail: it is the same assertion against the
--      old resolution strategy, and it goes red. (The control view is a TEST ARTEFACT and is
--      NOT created by this migration.)
--   5. FORWARD-LOOKING: a NEW quick_sale recorded AFTER the raise snapshots (2000, 2000). Old
--      and new rows now legitimately disagree, each correct for its own era. This is the whole
--      design in one assertion.
--
-- Scenario C — Immutability is ENFORCED, not promised (every one attempted, error text shown):
--   1. `insert into sales (..., commission_rate_bps) values (..., 9999)` for a staff member on
--      500bps -> the caller's 9999 is IGNORED; the row lands with 500. The DB decides.
--   2. `update sales set commission_rate_bps = 9999` (no window)
--      -> 'sales is append-only: UPDATE is not permitted (sale 22222222-...).'
--   3. Inside an OPEN backfill window for an unrelated migration:
--      `begin_sales_backfill('some_future_migration','pretending to add a column later on');`
--      `update sales set commission_rate_bps = 9999;`
--      -> 'backfill window "some_future_migration" may only populate columns added after v12;
--          it may not change any economic fact, the policy snapshot, or the commission
--          snapshot of sale 22222222-...'
--      THIS IS THE ASSERTION THAT PROVES SECTION 5 LANDED. Without section 5 it SUCCEEDS.
--   4. Inside an OPEN reclassify window for that same row:
--      `set_config('app.reclassify_sale', '<id>', true); update sales set commission_rate_bps=9999;`
--      -> 'reclassification of sale 22222222-... may change counts_as_revenue and nothing else'
--   5. `delete from sales` -> 'sales is append-only: DELETE is not permitted (sale ...).'
--   6. v10.1's revenue restatement still works and does not touch commission:
--      `reclassify_sale_policy('<id>', false, 'accountant says defer this to next period')`
--      -> counts_as_revenue = false, commission_rate_bps = 500 UNTOUCHED. No regression.
--
-- Scenario D — ZERO-AS-A-REAL-VALUE, BOTH DIRECTIONS (the one that has bitten twice):
--   1. service sale, services.commission_bps = 0,    staff.commission_service_bps = 1000
--      -> rate 0.     ZERO BEATS THE STAFF RATE. (A `nullif` here would give 1000.)
--   2. service sale, services.commission_bps = NULL, staff.commission_service_bps = 1000
--      -> rate 1000.  NULL FALLS THROUGH. (Dropping the outer coalesce would give 0.)
--   3. quick_sale, staff.commission_product_bps = 0  -> rate 0. A real 0, not "unset".
--   ONLY 1+2 TOGETHER ARE A TEST. Either alone passes against the broken code.
--
-- Scenario E — the commission_starts_on gate is FROZEN, not re-judged:
--   1. staff.commission_starts_on = today - 30. A sale occurred_at = now() - 90 days
--      -> snapshots rate 0 (it predates the start date).
--   2. `update staff set commission_starts_on = today - 365` — i.e. the gate would now ADMIT
--      that sale. Re-read the SAME row -> rate STILL 0. Frozen.
--      Under v11b the same edit retroactively starts paying commission on a closed period.
--
-- Scenario F — the backfill (section 2):
--   1. All 6 live rows -> rate_bps = 0, commission_cents = 0.
--   2. Regression: v12's view vs v11b's read-time control over the 6 live rows -> 0 diffs on
--      both columns. IDENTICAL. v12 freezes the numbers without moving them.
--   3. begin_sales_backfill writes exactly one audit_log row, action
--      'SALES_BACKFILL_WINDOW_OPEN', naming the migration, reason and db_user (v10.1 §5.1).
--
-- Scenario G — tenant isolation: a staff_id belonging to business Y cannot resolve a rate for
--   a sale in business X (the resolver's `st.business_id = p_business` pairing -> rate 0).
--   Note this is defence in depth: v11a's composite FK makes the row unreachable first.
--
-- Scenario H — NOT TESTED, DECLARED AS A GAP: no concurrency test exists for a rate change
--   racing a sale insert. The snapshot reads config in a BEFORE INSERT trigger under READ
--   COMMITTED, so a sale inserted concurrently with a rate update takes whichever value is
--   committed when the trigger reads. Both outcomes are defensible (the rate genuinely changed
--   at that instant) and neither can move an ALREADY-RECORDED row, which is what this migration
--   promises. Recorded so nobody mistakes silence for proof.
-- ======================================================================================
