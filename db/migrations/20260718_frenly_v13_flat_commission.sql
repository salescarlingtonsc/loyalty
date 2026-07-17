-- FRENLY v13 — FLAT-AMOUNT-PER-SERVICE COMMISSION, alongside the existing percentage system.
-- (target Supabase project kyzovonwnscrzmkvocid; migration name `frenly_v13_flat_commission`)
-- P2 FEATURE extending `frenly_v12_commission_snapshot`, WHICH IS ALREADY LIVE (17 migrations).
--
-- APPLY ORDER: … v11a → v11b → v11c → v12a (Q9 fix) → v12 (snapshot, LIVE) → v13 (this file).
-- REVIEW-ONLY. NOT APPLIED, NOT DEPLOYED, NOT COMMITTED BY ITS AUTHOR. Fable verifies + applies.
--
-- ⚠️ RELEASE COUPLING — READ FIRST (yesterday's `reversal_of`-class outage). The Settings UI
--    that lets a firm TYPE a flat dollar amount MUST NOT ship until this migration is APPLIED.
--    v13 adds `services.commission_flat_cents` and `sales.commission_flat_cents`; any UI that
--    references either column before the migration lands throws PGRST/`42703 column does not
--    exist` at runtime — exactly the shape of the outage where UI referenced an unapplied
--    column. Order is: apply v13 → verify → THEN deploy the flat-amount UI. Never the reverse.
--
-- ======================================================================================
-- SCOPE — read this before anything else
-- ======================================================================================
-- v13 does EXACTLY six things and nothing else:
--   1. `services.commission_flat_cents` — the CONFIG lever. Where a firm sets "$5 flat when
--      this service is performed". Nullable; 0 is a real value; NULL = "no flat, use %".
--   2. `sales.commission_flat_cents` — the IMMUTABLE SNAPSHOT of the resolved flat amount at
--      record time. NULL on a row means "this sale is not flat-commission; consult rate_bps".
--   3. `app.commission_flat_cents(...)` — the single resolver, used by the snapshot trigger.
--   4. The v12 snapshot trigger now resolves BOTH the rate and the flat amount at INSERT.
--   5. `public.sale_commission` picks flat-over-percent from each row's OWN snapshot, and
--      v12's immutability guard is extended to FREEZE the new snapshot column.
--   6. Nothing else. No payroll report, no payout ledger, no Talenox export, no staff-level
--      flat, no per-staff-service flat, no new RPC that pays anybody, no new permission, no
--      new table, no new FK, no UI.
--
-- THERE IS STILL NO PAYROLL IN THIS SCHEMA AFTER v13. As with v12, this file exists so payroll
-- can be built ON a stable, faithful flat-or-percent number — not so payroll exists.
--
-- ======================================================================================
-- THE GAP (owner ask) — the platform can express % but NOT a flat amount
-- ======================================================================================
-- Owner, verbatim: "services may be tagged to the staff for commission etc. like Flowesce… we
-- don't need to set any pricing or % etc right now, just need a platform for individual firms
-- to set themselves — can be a % of sales OR an amount allocated per selected service."
--
-- The percentage half exists (v11a config columns, v12 snapshot). The FLAT half does not, and
-- it CANNOT be faked with the percentage lever. Measured on LIVE, 2026-07-17 — a firm wanting
-- "$5.00 flat when this service is performed" has only `commission_bps` to reach for, and a
-- single bps value pays a DIFFERENT dollar amount at every price point:
--     commission_bps = 1666 ("≈ $5 on a $30 service"):
--         $30 service -> floor(3000*1666/10000) =  499c   ("close to $5")
--         $60 service -> floor(6000*1666/10000) =  999c   (now ~$10 — the flat has doubled)
--        $120 service -> floor(12000*1666/10000)= 1999c   (now ~$20)
-- A percentage is a function of the sale amount BY DEFINITION; a flat amount is not. There is
-- no bps value that holds $5 across prices. So the ask is not "another rate" — it is a second,
-- orthogonal MECHANISM. v13 adds it as a first-class snapshotted decision.
--
-- THE PLATFORM PROVIDES THE MECHANISM, NEVER THE NUMBERS. Every rate/amount stays NULL until a
-- firm sets it. v13 ships zero commission values (verified: 0 services and 0 staff carry any
-- commission config today).
--
-- ======================================================================================
-- DESIGN Q1 — WHERE DOES THE FLAT AMOUNT LIVE? -> `services.commission_flat_cents`
-- ======================================================================================
-- The owner said "an amount allocated PER SELECTED SERVICE". The literal, and correct, read is
-- PER-SERVICE. It also mirrors v11a's existing `services.commission_bps` override exactly: the
-- flat amount is the same category of fact (a per-service commission intent), so it lives on the
-- same row. Integer cents (never float), nullable, `check (>= 0)`.
--
-- DELIBERATELY NOT per-(staff,service) pair, and NOT a staff-level flat default:
--   * The owner's words scope it to the SERVICE, not to a staff member. The existing %
--     system's staff dimension is a DEFAULT rate that a service can override; "$5 per service"
--     has no natural staff-default analogue — a flat amount is intrinsically about the service
--     performed, not about who is cheaper or dearer.
--   * A per-(staff,service) flat would live on `staff_services` (which exists and today carries
--     no commission columns). That is strictly MORE granular than the ask and adds a resolution
--     level nobody requested. It is not foreclosed: because the resolved amount is SNAPSHOTTED
--     (Q3), a future migration can add `staff_services.commission_flat_cents` and slot it into
--     the resolver ABOVE the service-level flat, and history will not move. Flagged as Q14,
--     deferred, not built. Building the broader thing now would be guessing past the ask —
--     the same trap v12 refused when it declined to invent an unused permission.
--
-- If the owner re-confirms "% only", unwinding v13 is: drop two columns, one function, one
-- index, and restore v12's trigger/guard/view bodies (see ROLLBACK PLAN).
--
-- ======================================================================================
-- DESIGN Q2 — PRECEDENCE: FLAT (if set) WINS OVER %, and ZERO IS A REAL VALUE
-- ======================================================================================
-- On one service a firm may set BOTH `commission_bps` and `commission_flat_cents`. The rule a
-- salon owner can predict in one sentence:
--
--     "If you type a dollar amount in the flat field, that dollar amount is paid — instead of
--      the percentage. Clear the flat field to go back to the percentage."
--
-- i.e. FLAT, IF SET (non-NULL), WINS. Argued against the alternative ("% wins, flat is a
-- floor/cap"): a floor/cap is a THIRD semantic the owner never asked for and cannot be guessed;
-- "most specific intent wins" is the same principle v11a already uses for the service % override
-- beating the staff % default. A firm that put a number in the flat box meant that number.
--
-- ⚠️ ZERO-AS-A-REAL-VALUE — LOAD-BEARING, HAS BITTEN THIS PROJECT TWICE (v9 gift cards, v10
--    sale policy). It applies to the flat field in TWO distinct places and both are tested:
--
--    (a) THE FLAT FIELD ITSELF. `commission_flat_cents = 0` means "flat ZERO — this service
--        pays no commission" and MUST BEAT any percentage. `commission_flat_cents = NULL` means
--        "no flat configured — fall through to the percentage path". The resolver returns
--        `svc.commission_flat_cents` DIRECTLY for a service sale — there is exactly ONE flat
--        level, so there is NO coalesce and there must NEVER be a `nullif`:
--            when p_kind = 'service' then svc.commission_flat_cents   -- CORRECT: 0 -> 0, NULL -> NULL
--            when p_kind = 'service' then nullif(svc.commission_flat_cents, 0)  -- WRONG: a $0
--                                        -- flat silently reverts to the percentage and OVERPAYS
--        A `nullif` here is a payroll-fraud generator identical in shape to v12's warning about
--        `nullif(svc.commission_bps,0)`. There is no `nullif` in this file. Both directions are
--        tested (Scenario D): flat=0 -> commission 0 (beats a 10% rate); flat=NULL -> the % rate.
--
--    (b) THE VIEW'S PICK. `sale_commission` chooses flat when the SNAPSHOT `commission_flat_cents
--        IS NOT NULL` — never `> 0`, or a snapshotted flat-zero would fall through to the rate
--        and overpay. The whole precedence lives in `IS NOT NULL`, and it is tested both ways.
--
-- Interaction with % resolution: the flat lever is SERVICE-scoped, so it only engages for
-- kind='service' sales that resolve a service (via appointment -> service, the same path v11a's
-- % override uses). Non-service kinds (retail / quick_sale / product / package / gift_card /
-- membership) never see a service, so flat is always NULL for them and they keep the pure %
-- path (`staff.commission_product_bps`). A quick_sale of a service that is NOT linked to an
-- appointment likewise resolves no service and gets the % product path — flat is naturally
-- appointment-driven, matching "when this service is performed". Documented as a known
-- consequence, not a silent one (the primary path — appointment completion — carries both
-- staff_id and appointment_id since v12a, so it resolves flat correctly).
--
-- THE GATE AND THE NO-STAFF CASE FOLD IN IDENTICALLY TO v12. Flat commission still requires
-- someone to pay and a sale on/after `commission_starts_on`:
--     st.id IS NULL                              -> flat NULL (nobody to pay; % path yields 0)
--     sale predates commission_starts_on (SGT)   -> flat NULL (% path yields 0)
-- so a gated or unattributed sale pays nothing by EITHER mechanism. Tested: Scenario E.
--
-- ======================================================================================
-- DESIGN Q3 — SNAPSHOT SHAPE: a SECOND snapshot column `commission_flat_cents`,
--             NOT a single resolved `commission_cents`. Argued against the alternative.
-- ======================================================================================
-- v12's dividing line, verbatim: "the DECISION is snapshotted, the TOTAL stays derived. The
-- dividing line is 'is it a function of mutable config?', not 'is it expensive to compute?'."
-- For the PERCENTAGE path the decision is the RATE and the cents are DERIVED arithmetic on two
-- immutable columns (amount × rate). v12 explicitly REJECTED storing the % cents:
--     "Storing it would buy exactly nothing and cost the classic failure of a stored derived
--      value: a future change to the rounding rule silently disagrees with a column nobody
--      thought to rewrite."
--
-- A FLAT AMOUNT IS DIFFERENT IN KIND. It is NOT arithmetic on amount_cents — there is nothing
-- to derive; the resolved dollar figure IS the decision, and it is a function of MUTABLE config
-- (`services.commission_flat_cents`). By v12's own rule it is therefore exactly the sort of
-- thing that must be frozen ON THE ROW. So:
--
--   * CHOSEN — add `sales.commission_flat_cents`, the snapshotted resolved flat amount (or NULL
--     for a non-flat sale). This snapshots the DECISION and only the decision.
--
--   * REJECTED (the "snapshot the resolved commission_cents directly" option) — collapsing both
--     mechanisms into one stored `commission_cents` column would, for every PERCENTAGE row,
--     store a derived total — precisely the stored-derived-value failure v12 rejected: change
--     the rounding rule later and the stored cents silently disagree with `amount × rate`. It
--     also erases the rate, destroying "what rate did this sale earn at?". So the % total must
--     stay DERIVED, which means flat needs its own column rather than a shared resolved-cents.
--
--   * REJECTED (reuse `commission_rate_bps` with a boolean "is_flat") — a $5 flat on a $30 sale
--     is 1666.67 bps (lossy) and on a $0 sale is undefined/infinite. A flat amount is simply not
--     expressible as bps of the sale amount without loss. It needs its own cents column.
--
-- RESULT: each sale carries BOTH snapshots. `commission_rate_bps` is always the resolved % (the
-- rate that WOULD apply / does apply on the % path — kept, so the row still answers "what rate?"
-- and stays byte-identical to v12 for every non-flat sale). `commission_flat_cents` is the flat
-- decision or NULL. The view is the single authority on which one is the money (Q3 view rule):
--     commission_cents = CASE WHEN commission_flat_cents IS NOT NULL
--                             THEN commission_flat_cents                       -- flat wins
--                             ELSE floor(amount_cents * commission_rate_bps / 10000) END
-- PAYROLL READS `sale_commission.commission_cents` — the resolved figure — NEVER the raw
-- columns, and NEVER re-joins config. Same contract v12 set.
--
-- No `commission_flat_resolved_at` is added: `commission_resolved_at` (v12) already timestamps
-- the whole commission snapshot; both mechanisms are resolved in the same BEFORE INSERT instant.
--
-- PROOF THAT A CONFIG CHANGE DOES NOT MOVE HISTORY (the whole point):
--   * `commission_flat_cents` on `sales` is frozen by extending v12's immutability guard (both
--     the reclassify window and the backfill window now include the column — §5). A config edit
--     to `services.commission_flat_cents` writes `services`, not `sales`; no `sales` row moves.
--   * `sale_commission` reads ONLY the row's own snapshot columns — there is NO live join to
--     `services`/`staff`/`appointments` in the view (v12 deleted them; v13 adds none back).
--   * Therefore changing a flat amount affects only sales recorded AFTER the change. Tested:
--     Scenario B step 3 (edit the flat amount, re-read the same historical row -> unchanged).
--
-- ======================================================================================
-- DESIGN Q4 — $0 SALES (package sessions): FLAT IS DEFERRED TO "NO PAYOUT", NOT SILENT.
--             This is an OWNER DECISION — recommended default recorded, one-line switch noted.
-- ======================================================================================
-- `use_package_session` inserts a $0 `kind='service'` sale (a session redemption). A flat "$5
-- when this service is performed" is PLAUSIBLE policy on such a row — the staff did the work,
-- and the money was collected upfront at package purchase. But paying it is NOT obviously right:
--   * It interacts with an UNRESOLVED accounting question the owner has not ruled on. Per
--     CLAUDE.md's own v10/v11 notes, `sell_package` books revenue upfront AND each session is a
--     $0 visit; whether a session should ALSO trigger a per-session flat payout is entangled
--     with that unsettled package accounting. Paying flat per session could be a double-pay.
--   * Today's percentage path yields 0 on a $0 sale (floor(0 × rate) = 0). Making flat pay on
--     $0 rows would introduce a payout where none exists today — a live behaviour change on the
--     one class of row where it is least clearly correct.
--
-- RULING (recommended default, SAFE + REVERSIBLE): flat does NOT resolve on a $0-amount sale.
-- The resolver guards `coalesce(p_amount_cents,0) <= 0 -> NULL`, so a $0 session falls through
-- to the % path and pays 0 — IDENTICAL to today. This is deferral, not a silent choice: it is
-- documented here and asserted in Scenario C (measured on live: $0 -> flat NULL).
--
-- WHY DEFER-TO-NO rather than pay:
--   1. Changes no live number and no future $0-session number — the conservative default.
--   2. Does not entangle v13 with the open package-accounting question. When the owner settles
--      that, they settle this in the same breath.
--   3. Fully reversible and snapshot-clean: enabling it later is deleting ONE line
--      (`when coalesce(p_amount_cents,0) <= 0 then null`), and because the amount is snapshotted
--      it only affects sessions recorded after the switch — no history restatement.
-- The eventual home if the owner wants per-business control is `public.sale_policies` (v10),
-- which already holds per-(business,kind) flags — a `pays_flat_on_zero` flag would live there.
-- Not built now (heavier than a deferral warrants). ESCALATED as Q13 (owner decision).
--
-- ======================================================================================
-- DESIGN Q5 — BACKFILL: NONE NEEDED, AND THAT IS PROVABLE (stronger than v12's).
-- ======================================================================================
-- v12 had to backfill `commission_rate_bps` because it was NOT NULL. v13's snapshot column is
-- NULLABLE and NULL is its CORRECT historical value, so there is NO `update public.sales` here
-- and NO `begin_sales_backfill` window is opened. The argument, three independent ways, each
-- sufficient:
--
--   ✓ THE COLUMN DID NOT EXIST. `services.commission_flat_cents` is created BY THIS MIGRATION.
--     No sale in history could have been recorded under any flat policy, because there was no
--     flat policy to record. Every historical row is, by construction, a NON-flat (percentage-
--     or-zero) row. Its correct snapshot value is NULL — which is exactly the column default,
--     applied automatically by `ALTER TABLE ADD COLUMN` with no row rewrite. (DDL does not fire
--     the immutability guard, so no window is required to add it.)
--
--   ✓ NO SALE HAS A COMMISSION SUBJECT. Verified live 2026-07-17: `select count(*) from sales
--     where staff_id is not null` = 0 (9 sales total, all staff_id NULL). The flat resolver
--     returns NULL on `st.id is null` before it ever reads a flat amount. So even the resolver,
--     run against every existing row, yields NULL for all of them.
--
--   ✓ NO CONFIG EXISTS ANYWAY. 0 of 2 services carry `commission_bps`; the new
--     `commission_flat_cents` is NULL on all (just created); 0 of 3 staff carry any commission
--     column. Belt and braces, not load-bearing.
--
-- LIVE COUNTS AT AUTHORING (RE-VERIFY IMMEDIATELY BEFORE APPLYING):
--     sales 9 · sales_with_staff 0 · commission_rate_bps IS NULL 0 · rate_bps>0 0
--     services 2 · services_with_commission_bps 0 · staff 3 · staff_with_any_commission 0
--     businesses 3.  (Note: grew from v12's 6/2 to 9/3 — the "empty/stale premise" trap. The
--     proof does NOT depend on the counts staying at 6/2; it depends on staff_id being NULL on
--     every row, which is RE-VERIFIED below, not assumed.)
--
--   POST-ADD ASSERTION (belt and braces): after ADD COLUMN, every existing row is NULL:
--       select count(*) from sales where commission_flat_cents is not null;   -- expect 0
--
--   IF THIS EVER RUNS AGAINST A DB WHERE A SALE ALREADY CARRIES staff_id AND a service already
--   carries commission_flat_cents (impossible here — the column is brand new — but stated for a
--   re-run elsewhere): NULL is STILL correct for every pre-v13 row, because the flat column did
--   not exist when those rows were recorded, so no flat decision was ever taken on them. There
--   is no honest "replay" that would invent a flat amount for a historical sale. Leave them NULL.
--
-- ======================================================================================
-- STYLE / SAFETY / THE CONFIRMED TRAPS (v12's checklist, re-answered for v13)
-- ======================================================================================
-- plpgsql/sql SECURITY DEFINER + `set search_path = public`. RLS fail-closed.
--   * NO NEW RPC and NO NEW PERMISSION. Editing a service is already owner-gated by the existing
--     `services` write policy; setting the flat amount rides that gate. Reading commission stays
--     on v11b/v12's `view_finance`. v13 exposes no new verb, so it adds no permission — the same
--     argued restraint v12 used (a permission with no subject is a liability).
--   * The two new functions are in schema `app`; `authenticated` has no USAGE there. The
--     `security_invoker` view may still call them (parse-time OID capture — v11b/v12 proved this
--     live and this view already relies on it).
--   * TRAP (a) PGRST201 (the v1.6 outage) — NOT APPLICABLE, ASSERTED: v13 adds NO foreign key
--     and NO table. `commission_flat_cents` is a plain integer on two existing tables. No table
--     pair gains a second FK; nothing for PostgREST to fail to disambiguate.
--   * TRAP (b) `authenticated` default ACL / TRUNCATE (v11c fleet-wide revoke) — NOT REGRESSED:
--     v13 CREATES NO TABLE, so no new default ACL is granted and there is nothing new to revoke
--     truncate on. Adding a column to `services`/`sales` does not alter their ACLs. Post-apply
--     check (§verification) re-confirms v11c's 0-of-N state with `has_table_privilege` filtered
--     to `relkind='r'` (NOT `information_schema.role_table_grants`, which false-positives on
--     views — see v12's note).
--   * No new audit trigger. (Q11 from v12 stands: `services` has NO audit trigger, so
--     `commission_flat_cents` — like `commission_bps` and `price_cents` before it — can be
--     changed with no trace. v13 does NOT fix that; it is a `services`-owned concern, re-flagged
--     as Q11. It does NOT weaken v13's backfill proof, which does not rely on config history.)

begin;

-- 1. THE CONFIG LEVER. Where a firm sets "$5 flat when this service is performed". ------------
--    Nullable: NULL = "no flat, use the percentage path". 0 = a REAL "flat zero / no commission"
--    that BEATS any percentage (see Q2). Integer cents, never float. `check (>= 0)`: a negative
--    commission is a clawback, which is a different feature with its own ledger — not this.
alter table public.services
  add column if not exists commission_flat_cents integer
    check (commission_flat_cents is null or commission_flat_cents >= 0);

comment on column public.services.commission_flat_cents is
  'CONFIG: flat commission in cents paid when THIS service is performed, overriding the '
  'percentage (services.commission_bps / staff.commission_service_bps) when set. NULL = no '
  'flat, use the percentage path. 0 = a REAL flat-zero that beats any percentage — never read '
  'it as "unset" (no nullif). Set by the business; the platform provides the field, never the '
  'number. UI for this ships only AFTER v13 is applied.';

-- 2. THE SNAPSHOT. Immutable resolved flat amount at record time (or NULL for a non-flat sale).
--    NULLABLE BY DESIGN and stays nullable forever: NULL is the meaningful value "this sale is
--    not flat-commission; consult commission_rate_bps". No NOT NULL, so no backfill (see Q5).
alter table public.sales
  add column if not exists commission_flat_cents integer
    check (commission_flat_cents is null or commission_flat_cents >= 0);

comment on column public.sales.commission_flat_cents is
  'IMMUTABLE SNAPSHOT of the resolved FLAT commission in cents as of when this sale was '
  'RECORDED, or NULL if this sale is not flat-commission (then commission_rate_bps applies). '
  'When NOT NULL this value IS the commission and WINS over commission_rate_bps — 0 is a real '
  'flat-zero. Resolved through services.commission_flat_cents for kind=service, with the '
  'no-staff case, the commission_starts_on gate and the $0-sale rule (Q13) all folding to NULL. '
  'Payroll reads public.sale_commission.commission_cents, never this column raw. There is '
  'deliberately NO supported path to change this after insert (mirrors commission_rate_bps).';

-- 2.1 THE FLAT RESOLVER — single source of truth, called by the snapshot trigger. -------------
--     Mirrors app.commission_rate_bps's join shape and its no-staff / gate guards EXACTLY so the
--     two never disagree about WHETHER commission applies (they only differ on WHAT it is).
--     ⚠️ If you ever change the no-staff or gate rule, change it in BOTH resolvers or a gated
--     sale could snapshot rate 0 but a non-NULL flat (or vice versa). Scenario E asserts both
--     resolvers agree that a gated / staffless sale pays nothing by either mechanism.
--
--     NOTE THE ABSENCE OF ANY nullif: `svc.commission_flat_cents` is returned directly, so a
--     service flat of 0 is a REAL 0 and NULL falls through to the percentage path. There is
--     exactly one flat level (service), so there is no coalesce to a lower level either.
--
--     The `st.business_id = p_business` pairing makes a cross-tenant staff_id resolve to NULL
--     rather than to another tenant's context — defence in depth atop v11a's composite FK, at
--     no cost, matching app.commission_rate_bps.
create or replace function app.commission_flat_cents(
  p_business     uuid,
  p_kind         text,
  p_staff        uuid,
  p_appointment  uuid,
  p_occurred_at  timestamptz,
  p_amount_cents integer)
returns integer language sql stable security definer set search_path = public as $$
  select case
           -- No staff attribution -> nobody to pay. Matches app.commission_rate_bps's `-> 0`.
           when st.id is null then null
           -- The gate, folded in and anchored to SG business dates (identical to v12's rate gate).
           when st.commission_starts_on is not null
                and (p_occurred_at at time zone 'Asia/Singapore')::date < st.commission_starts_on
                then null
           -- Q13 (owner decision, DEFERRED): a flat amount does NOT pay on a $0-amount sale
           -- (package-session redemptions). Delete THIS ONE LINE to enable it — snapshot-clean,
           -- affects only future sessions. See DESIGN Q4.
           when coalesce(p_amount_cents, 0) <= 0 then null
           -- Flat is SERVICE-scoped. Direct read: 0 stays 0 (real flat-zero), NULL stays NULL
           -- (falls through to the percentage path). NO nullif — that would overpay a flat-zero.
           when p_kind = 'service' then svc.commission_flat_cents
           -- Non-service kinds have no service, hence no flat. Percentage product path applies.
           else null
         end
  from (select 1) _
  left join public.staff st       on st.id  = p_staff and st.business_id = p_business
  left join public.appointments a on a.id   = p_appointment
  left join public.services svc   on svc.id = a.service_id
$$;

-- 3. INDEX — extend v12's partial payroll index to also catch FLAT rows. ----------------------
--    v12's predicate was `staff_id is not null and commission_rate_bps > 0`, which MISSES a
--    flat sale whose resolved % is 0 (a pure-flat service with no percentage). Drop and recreate
--    with the flat arm added. `commission_flat_cents > 0` (not `is not null`) because a
--    flat-zero row pays nothing and need not be indexed for payroll.
drop index if exists public.sales_commission_payroll_idx;
create index if not exists sales_commission_payroll_idx
  on public.sales (business_id, staff_id, occurred_at)
  where staff_id is not null
    and (commission_rate_bps > 0 or commission_flat_cents > 0);

-- 4. THE SNAPSHOT TRIGGER now resolves BOTH mechanisms at record time. ------------------------
--    Same object, same name, same BEFORE-INSERT ordering as v12 (unchanged: trg_sale_commission
--    _snapshot < trg_sale_policy_snapshot < trg_sales_default_branch, and this trigger still
--    reads only caller-supplied columns and writes only its own — no cross-dependency). Caller-
--    supplied commission_flat_cents is ALWAYS overwritten: the snapshot is the DB's decision, so
--    a stylist POSTing their own flat amount through PostgREST lands the resolved value. Tested:
--    Scenario C.1.
create or replace function app.on_sale_commission_snapshot()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.commission_rate_bps   := app.commission_rate_bps(
    new.business_id, new.kind, new.staff_id, new.appointment_id, new.occurred_at);
  new.commission_flat_cents := app.commission_flat_cents(
    new.business_id, new.kind, new.staff_id, new.appointment_id, new.occurred_at, new.amount_cents);
  new.commission_resolved_at := now();
  return new;
end $$;

-- (Trigger trg_sale_commission_snapshot is v12's and is NOT re-created: `create or replace
--  function` swaps the body under the existing trigger. Re-creating it would be a no-op at best
--  and a window where the snapshot is unenforced at worst.)

-- 5. EXTEND v12'S IMMUTABILITY GUARD to FREEZE `commission_flat_cents`. -----------------------
--    NOT OPTIONAL. Without it, `commission_flat_cents` — a column added AFTER v12 — stays in
--    WINDOW 2's "later-added, may move" set forever, so any future migration opening a backfill
--    window for an unrelated column could rewrite every flat snapshot in history, audited only
--    as "window open". That is the defect one layer down: the config would be immutable but the
--    snapshot would not. The body below is v12's LIVE definition, UNCHANGED except that BOTH
--    tuples gain `commission_flat_cents`. Reviewed as a diff against the live function, which is
--    exactly what it is. Section 2's ADD COLUMN is DDL (no row UPDATE), so — unlike v12 — there
--    is no backfill statement that this redefinition must run AFTER; order within this file is
--    not load-bearing here.
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

  -- WINDOW 1 — audited accounting reclassification of ONE named row (v10.1 §9). counts_as_revenue
  -- remains the ONLY column that may move; commission_rate_bps AND commission_flat_cents are
  -- frozen here too: a revenue restatement must not silently re-rate OR re-flat a payout.
  if v_reclassify is not null and v_reclassify = old.id::text then
    if (new.id, new.business_id, new.client_id, new.kind, new.amount_cents, new.occurred_at,
        new.created_at, new.note, new.appointment_id, new.product_id, new.qty,
        new.counts_as_visit, new.earns_points, new.policy_resolved_at,
        new.commission_rate_bps, new.commission_resolved_at, new.commission_flat_cents)
       is distinct from
       (old.id, old.business_id, old.client_id, old.kind, old.amount_cents, old.occurred_at,
        old.created_at, old.note, old.appointment_id, old.product_id, old.qty,
        old.counts_as_visit, old.earns_points, old.policy_resolved_at,
        old.commission_rate_bps, old.commission_resolved_at, old.commission_flat_cents)
    then
      raise exception 'reclassification of sale % may change counts_as_revenue and nothing '
                      'else', old.id
        using errcode = 'restrict_violation';
    end if;
    return new;
  end if;

  -- WINDOW 2 — migration-time attribution backfill (v10.1 §5.1). Every column that existed when
  -- v13 was written must survive byte-identical; only columns added LATER may move.
  if v_backfill is not null then
    if (new.id, new.business_id, new.client_id, new.kind, new.amount_cents, new.occurred_at,
        new.created_at, new.note, new.appointment_id, new.product_id, new.qty,
        new.counts_as_revenue, new.counts_as_visit, new.earns_points, new.policy_resolved_at,
        new.commission_rate_bps, new.commission_resolved_at, new.commission_flat_cents)
       is distinct from
       (old.id, old.business_id, old.client_id, old.kind, old.amount_cents, old.occurred_at,
        old.created_at, old.note, old.appointment_id, old.product_id, old.qty,
        old.counts_as_revenue, old.counts_as_visit, old.earns_points, old.policy_resolved_at,
        old.commission_rate_bps, old.commission_resolved_at, old.commission_flat_cents)
    then
      raise exception 'backfill window "%" may only populate columns added after v13; it '
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

-- 6. THE VIEW now PICKS flat-over-percent from each row's OWN snapshot. -----------------------
--    Diff vs the live v12 definition, and nothing else:
--      (a) commission_cents becomes a CASE: flat snapshot wins WHEN NOT NULL (0 included);
--          otherwise the v12 percentage arithmetic, byte-identical (floor(amount*rate/10000)).
--          For every non-flat row (flat_cents IS NULL) this is EXACTLY v12's output — so v13
--          changes no number on day one (all 9 live rows have flat_cents NULL). Regression-
--          tested in Scenario F.
--      (b) `flat_cents` is ADDED as a new trailing column (the row's flat snapshot passthrough),
--          so a reader can tell WHICH mechanism paid. Trailing add keeps `create or replace
--          view` legal and breaks no positional caller (there is no commission UI today anyway).
--    PRESERVED EXACTLY: every pre-existing column's name/order/type; `security_invoker = on`;
--    the `where app.has_perm(business_id,'view_finance')` gate. NO live join to config is
--    re-introduced — the view reads only `sales`, which is what freezes history.
create or replace view public.sale_commission
with (security_invoker = on) as
select s.id                  as sale_id,
       s.business_id,
       s.branch_id,
       s.staff_id,
       s.kind,
       s.occurred_at,
       s.amount_cents,
       s.commission_rate_bps as rate_bps,
       -- The authoritative commission. FLAT WINS when the flat snapshot is present (0 included).
       -- Both branches read immutable columns of THIS row only — neither can drift.
       case when s.commission_flat_cents is not null
            then s.commission_flat_cents
            else floor((s.amount_cents * s.commission_rate_bps)::numeric / 10000.0)::integer
       end                   as commission_cents,
       -- The flat snapshot passthrough: non-NULL => this sale paid by the flat mechanism.
       s.commission_flat_cents as flat_cents
from public.sales s
where app.has_perm(s.business_id, 'view_finance');

commit;

-- ======================================================================================
-- WHAT THE UI MUST DO AFTER THIS (app/index.html — NOT touched by this migration)
-- ======================================================================================
--   1. RELEASE ORDER (the coupling lesson, restated): the Settings field that edits
--      `services.commission_flat_cents`, and any payroll/commission surface that reads
--      `sale_commission.flat_cents`/`.commission_cents`, ships ONLY AFTER this migration is
--      applied. Referencing either column beforehand throws `42703 column does not exist`.
--   2. The service Commission setting is now TWO mutually-exclusive inputs: a percentage OR a
--      flat amount. The UI copy should say plainly: "Percentage of the sale, or a fixed amount
--      per service. If you set a fixed amount, it is paid instead of the percentage. This
--      affects sales recorded from now on — past sales keep the commission they were recorded
--      with." That last sentence is true only because of the snapshot (v12 + v13).
--   3. Payroll (when built) reads `sale_commission.commission_cents` — the resolved figure. It
--      MUST NEVER join `services.commission_flat_cents` / `commission_bps` / `staff.commission_*`
--      to a historical sale. Those columns describe the NEXT sale, not the past.
--
-- ======================================================================================
-- ROLLBACK PLAN (undo v13; restores v12's behaviour exactly — % only, no flat)
-- ======================================================================================
-- Safe at any time: v13 adds two columns, swaps three function bodies (resolver is new; trigger
-- + guard + view are replacements), and re-creates one index. It destroys NO pre-existing data
-- and creates NO v13-native data (no backfill, no audit rows — no window was opened).
--
--   begin;
--   -- 1. Restore v12's snapshot trigger body (resolves rate only). Re-run §4 of
--   --    20260717_frenly_v12_commission_snapshot.sql VERBATIM (that file is the source of
--   --    truth — do not hand-retype). This stops the flat column being populated on new rows.
--   -- 2. Restore v12's view body (rate-only commission_cents, no flat_cents column). Re-run §6
--   --    of the v12 file VERBATIM. Do this BEFORE step 5 — `create or replace view` cannot drop
--   --    the trailing flat_cents column if you have already dropped the underlying column, and a
--   --    plain replace that still selects flat_cents fails once the column is gone. Restore the
--   --    view first, columns last.
--   -- 3. Restore v12's immutability guard body (tuples WITHOUT commission_flat_cents). Re-run §5
--   --    of the v12 file VERBATIM. NOTE: leaving v13's guard in place is HARMLESS ONLY IF step 5
--   --    is skipped — if the column is dropped while the guard still names it, EVERY update to
--   --    `sales` raises 'record new has no field "commission_flat_cents"' and both windows die.
--   --    Do step 3 before step 5, always.
--   -- 4. Drop the flat resolver.
--   drop function if exists app.commission_flat_cents(uuid, text, uuid, uuid, timestamptz, integer);
--   -- 5. Restore v12's payroll index predicate (drop the flat arm):
--   drop index if exists public.sales_commission_payroll_idx;
--   create index sales_commission_payroll_idx on public.sales (business_id, staff_id, occurred_at)
--     where staff_id is not null and commission_rate_bps > 0;
--   -- 6. Columns. LAST, and only if you are sure — discards the flat snapshots irreversibly.
--   alter table public.sales    drop column if exists commission_flat_cents;
--   alter table public.services drop column if exists commission_flat_cents;
--   commit;
--
-- PARTIAL ROLLBACK (preferred if v13 misbehaves in reporting rather than in the engine): run
-- steps 1-3 only. New rows stop getting a flat snapshot and reporting reverts to v12's % path;
-- the two columns become harmless dead weight, history is preserved for a clean re-apply, and no
-- irreversible column drop happens.
--
-- ======================================================================================
-- OPEN QUESTIONS RAISED / CARRIED BY THIS FILE
-- ======================================================================================
-- Q13 (OWNER DECISION) Should a flat commission pay on a $0-amount sale (package-session
--     redemption)? v13 DEFERS to NO (recommended, safe, reversible; DESIGN Q4). Enabling it is
--     deleting one resolver line; settle it together with the open package-accounting question
--     (revenue-upfront + per-session visit) that CLAUDE.md already records as unresolved.
-- Q14 (DEFERRED, not built) Per-(staff,service) flat, i.e. `staff_services.commission_flat_cents`
--     resolved ABOVE the service-level flat. Not requested by the owner ("per selected service").
--     Snapshotting leaves the door open: a later migration can add it without moving history.
-- Q11 (CARRIED FROM v12) `public.services` still has NO audit trigger, so commission_flat_cents
--     (like commission_bps / price_cents) can be changed with no trace. Does not weaken v13's
--     backfill proof (which does not rely on config history). Recommend `trg_services_audit`.
-- Q10 (CARRIED FROM v12) `Asia/Singapore` is hardcoded in both commission resolvers (the gate).
--     Correct for the SG beachhead, wrong for market #2; belongs on `businesses.timezone`. ⚖️
-- Q12 (CARRIED FROM v12) No supported path corrects a commission snapshot (rate OR now flat).
--     The payroll migration MUST resolve this before the first payout.
--
-- ======================================================================================
-- MANUAL TEST SCENARIOS
-- ======================================================================================
-- Run as rolled-back transactions against LIVE (project kyzovonwnscrzmkvocid), as the tenant
-- owner (set request.jwt.claims). NOTHING TO BE COMMITTED. Core resolver values below were
-- MEASURED on live 2026-07-17 inside `begin; … rollback;` (fixtures: a staff on
-- commission_service_bps=1000, a service with commission_flat_cents=500, an appointment linking
-- them). The FULL apply-and-measure (trigger + view) is Fable's to run post-verify.
--
-- Scenario A — THE GAP, before v13 (THE FAILING TEST; the ask cannot be met with %):
--   1. A firm wants "$5 flat when this service is performed". The only lever is commission_bps.
--   2. commission_bps = 1666, read the resulting commission at three prices:
--        $30 -> floor(3000*1666/10000)  =  499c   MEASURED (want 500)
--        $60 -> floor(6000*1666/10000)  =  999c   MEASURED (want 500 — DOUBLED)
--       $120 -> floor(12000*1666/10000) = 1999c   MEASURED (want 500 — QUADRUPLED)
--      A percentage cannot hold a flat amount. THIS IS THE GAP v13 closes.
--   3. And the flat field does not exist yet:
--        select commission_flat_cents from public.services;
--        -> ERROR: 42703: column "commission_flat_cents" does not exist   MEASURED.
--
-- Scenario B — THE FIX (after v13): flat holds across prices AND a later edit does not move
--              history:
--   1. services.commission_flat_cents = 500 on the service; staff on it, appointment links them.
--      A service sale at amount 3000 and another at 6000:
--        both snapshot commission_flat_cents = 500 -> sale_commission.commission_cents = 500 EACH.
--        (Resolver MEASURED on live: flat_on_$30 = 500, flat_on_$60 = 500. Flat holds.)
--   2. THE CONTROL, EXPECTED TO FAIL AND SHOWN FAILING: a SECOND service configured with a
--      PERCENTAGE (commission_flat_cents = NULL, commission_bps = 1000) records two sales at
--      3000 and 6000 -> commission_cents = 300 and 600. The "is it flat/price-invariant?"
--      assertion GOES RED for this service (300 <> 600): it varies with price, proving the test
--      can distinguish flat from percentage and is not vacuously passing.
--   3. HISTORY DOES NOT MOVE: after step 1, `update services set commission_flat_cents = 999`
--      then re-read sale_commission for the two step-1 sales -> STILL 500 each (they read their
--      own frozen snapshot). A NEW sale after the edit snapshots 999. Old and new legitimately
--      disagree, each correct for its era — the whole design in one assertion.
--
-- Scenario C — Immutability + caller cannot inject (error text as v12):
--   1. insert into sales (…, commission_flat_cents) values (…, 9999) for a flat service ->
--      the caller's 9999 is IGNORED; the row lands with the resolved 500. The DB decides.
--   2. update sales set commission_flat_cents = 9999 (no window)
--      -> 'sales is append-only: UPDATE is not permitted (sale …).'
--   3. Inside an OPEN backfill window for an unrelated migration:
--        begin_sales_backfill('some_future_migration','pretending to add a column later on');
--        update sales set commission_flat_cents = 9999;
--      -> 'backfill window "some_future_migration" may only populate columns added after v13; it
--          may not change any economic fact, the policy snapshot, or the commission snapshot of
--          sale …'  THIS PROVES SECTION 5 LANDED. Without §5 it SUCCEEDS (the exact defect).
--   4. Inside an OPEN reclassify window for that row:
--        set_config('app.reclassify_sale','<id>',true); update sales set commission_flat_cents=9999;
--      -> 'reclassification of sale … may change counts_as_revenue and nothing else'.
--   5. v10.1's revenue restatement still works and leaves commission untouched:
--        reclassify_sale_policy('<id>', false, 'accountant defers this to next period')
--      -> counts_as_revenue=false; commission_rate_bps AND commission_flat_cents UNCHANGED.
--
-- Scenario D — ZERO-AS-A-REAL-VALUE, BOTH DIRECTIONS (the class that has bitten twice):
--   1. service sale, services.commission_flat_cents = 0, services.commission_bps = 1000,
--      staff.commission_service_bps = 1000
--      -> flat snapshot = 0 -> commission_cents = 0. A flat-ZERO BEATS the 10% rate.
--         (A `nullif(commission_flat_cents,0)` anywhere would pay ~10% here — the fraud form.)
--   2. service sale, services.commission_flat_cents = NULL, services.commission_bps = 1000
--      -> flat snapshot = NULL -> commission_cents = floor(amount*1000/10000). NULL falls through.
--   3. The VIEW picks on IS NOT NULL, not > 0: a snapshot flat_cents = 0 yields commission_cents
--      = 0, NOT the percentage. (A `> 0` pick would overpay a deliberate flat-zero.)
--   ONLY 1+2(+3) TOGETHER ARE A TEST. Either direction alone passes against broken code.
--
-- Scenario E — GATE + NO-STAFF fold to NULL for flat, agreeing with the rate resolver:
--   1. staff with commission_starts_on = today, a service flat = 500, a sale occurred_at =
--      now() - 90 days -> flat resolver = NULL AND rate resolver = 0. Sale pays 0 by BOTH.
--      (Resolver MEASURED: no-staff -> NULL; the gate path returns NULL the same way.)
--   2. Move the start date earlier (would admit that sale) -> the ALREADY-RECORDED row is
--      unchanged (snapshot frozen); only NEW sales see the change.
--   3. no-staff service sale -> flat = NULL, rate = 0, commission_cents = 0.  MEASURED: NULL.
--
-- Scenario F — the "changes no number on day one" regression (parallels v12 Scenario F):
--   1. All 9 live rows -> commission_flat_cents IS NULL after ADD COLUMN (Q5 assertion). MEASURED
--      pre-conditions: 9 sales, 0 with staff_id, 0 with rate_bps>0.
--   2. sale_commission.commission_cents for the 9 live rows is BYTE-IDENTICAL to its v12 output
--      (flat_cents NULL on every row -> the CASE takes the ELSE = v12's exact arithmetic). 0
--      diffs. v13 freezes the flat mechanism into place without moving any existing number.
--
-- Scenario G — the $0-sale ruling (Q13) is enforced, not silent:
--   1. A flat service (commission_flat_cents = 500) sold as a $0 kind='service' session
--      (use_package_session shape) -> flat resolver = NULL -> commission_cents = 0 (% path).
--      MEASURED on live: app.commission_flat_cents(…, 0) = NULL. Deferred-to-NO, as documented.
--   2. If Q13 is later flipped (delete the one resolver line), the SAME $0 session would
--      snapshot 500 — but only for sessions recorded AFTER the flip. Recorded so the switch is
--      understood as forward-only.
--
-- Scenario H — non-service kinds never get a flat (flat is per-service):
--   1. quick_sale / retail with a flat service in the tenant but no service on the sale ->
--      flat resolver = NULL -> percentage product path. MEASURED: non_service_kind -> NULL.
--
-- Scenario I — v11c fleet-wide TRUNCATE revoke not regressed (v13 creates no table):
--   select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
--    where n.nspname='public' and c.relkind='r'
--      and has_table_privilege('authenticated', c.oid, 'TRUNCATE');   -- expect 0
--   (Use has_table_privilege on relkind='r', NOT information_schema.role_table_grants — the
--    latter false-positives on views. See v12's note.)
--
-- Scenario J — NOT TESTED, DECLARED AS A GAP: no concurrency test for a flat-amount edit racing
--   a sale insert. Same reasoning as v12 Scenario H — the BEFORE INSERT trigger snapshots
--   whichever config is committed at read time under READ COMMITTED; neither outcome can move an
--   already-recorded row, which is all this migration promises.
-- ======================================================================================
