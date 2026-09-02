-- NESTLY v744 -- scanner blind spots the fifth refuter found, PLUS a hardened
-- app.ci_synthetic_scan_v743() that would have found them (and ten more) itself.
-- Continues nestly_v687/v734/v737/v740/v742/v743.
--
-- PART A -- the two refuter-reported bugs, fixed, PLUS every sibling reader of the same
-- pattern found by re-running the refuter's own method (grep every reader of the affected
-- table/view/RPC, not just the one named):
--
--  (1) public.get_ci_opportunities_v1 -- Generator B's "overdue" CTE (the lapsed_regulars
--      cohort) selects client_id straight out of app.customer_cadence_batch_v1() with NO join
--      to public.clients and no is_synthetic predicate: a synthetic customer with an 'overdue'
--      cadence state inflated v_lapsed_n (the "N customers overdue" prose and
--      evidence.refs.overdue_regulars) and fed inputs.scored for the EV estimate. The EXTENDED
--      MODE re-derivation of the same cohort (used to price the lapsed_regulars expected-value
--      figure) carries an IDENTICAL unguarded "overdue" CTE -- same bug, same fix, twice. Fixed
--      by joining public.clients on customer_cadence_batch_v1's client_id and requiring
--      `not cli.is_synthetic`, in both places. Every OTHER cohort generator in this spine
--      (at_risk/retention_funnel, daypart, category_mix, packages, service_intelligence,
--      contactability, data_quality) was re-read against the same question and each already
--      carries its own synthetic exclusion (proven by the estate-wide scan below returning zero
--      NEW findings inside this function once these two CTEs are fixed) -- lapsed_regulars was
--      the one generator whose population comes from a *function call*
--      (app.customer_cadence_batch_v1), not a raw table scan, which is also why nestly_v743's
--      literal table-name scanner could never have caught it: this is a genuine, permanent
--      scanner blind spot, documented in Part C below.
--
--  (2) public.get_reports_summary_v94_base -- `v_credit_liability` sums public.client_credit_balance
--      with no join to clients and no is_synthetic predicate (10000 read where 1000 is the true
--      figure with a 9000-cent synthetic pot mixed in). Re-running the refuter's instruction --
--      "check every other reader of client_credit_balance, client_points_balance, sale_balance,
--      product_stock" -- against the live estate found FIVE more unguarded aggregates over the
--      same three views/tables, all in reader functions a business owner or platform operator
--      reads directly (not test-only paths):
--        - public.get_reports_summary (the credit_liability sibling v94_base was split from in
--          nestly_v94, PLUS its own compensating_rows/reversed_revenue/net_revenue block and its
--          non_revenue_by_kind and points_by_type blocks -- FOUR separate unguarded aggregates in
--          the one function, all fixed here)
--        - public.get_reports_summary_v94_base's own non_revenue_by_kind and points_by_type
--          blocks (v_credit_liability was not the only unguarded figure in this function either)
--        - public.get_dashboard_summary -- SEVEN unguarded aggregates: new_customers,
--          points_issued, credit_liability_cents, the visits-by-weekday chart, the revenue-by-day
--          chart, and the gender/age demographic breakdowns. This is the number every owner sees
--          first on login; all seven are fixed here.
--        - public.get_revenue_summary -- THREE unguarded aggregates: cash collected (payments
--          joined to sales), stored-value cash, and unpaid balance (the sale_balance reader the
--          refuter named).
--      product_stock was checked and is NOT synthetic-exposed: its definition
--      (products left join stock_batches) carries no client dimension at all, so no reader of it
--      needs a synthetic predicate -- confirmed by grepping pg_views for every view whose
--      definition references any of the seven guarded tables (see Part C); product_stock does
--      not appear in that list.
--
-- FOUR MORE, found not by re-running the refuter's instruction but by the hardened scanner built
-- in Part C, against the live (pre-fix) estate, and fixed here for the same reason nestly_v743
-- fixed its own scanner-found extras: leaving a proven-broken reader unallowlisted would make
-- Part C's "zero rows" assertion dishonest --
--
--  (3) app.v177_overview and app.v179_business_insights -- the superadmin/owner "outstanding
--      loyalty liability" mirrors (both descend from the same nestly_v545 shape). Each summed
--      public.points_ledger / public.credit_ledger directly, with NO join to clients: a
--      synthetic client's live points balance and historical-programme balances inflated the
--      "outstanding" and "historical_programmes" figures on BOTH surfaces, and its store credit
--      inflated "credit_cents" on v177. v179 also had the same defect on its earned/redeemed
--      points-for-the-period figures. Fixed uniformly: join public.clients on the ledger row's
--      client_id (both columns are NOT NULL, so a plain join is correct -- no walk-in/anonymous
--      case to protect, unlike a sales table read) and require `not <alias>.is_synthetic`.
--  (4) app.get_growth_execution_result_at_v108 -- `v_overlap` (the identity-overlap validity
--      detector that forces `measurement_status = 'invalid_overlap'` when tripped) queried
--      growth_outcomes_v108/growth_execution_members_v108/sales directly, bypassing the
--      `effective_members` CTE the rest of this same function already synthetic-filters (fixed
--      in nestly_v743 item #4). A synthetic member's outcome could poison the measurement
--      validity of a REAL execution. Fixed by joining public.clients on the member's client_id,
--      matching the guard already proven correct for this function's member population.
--  (5) public.platform_generate_my_report_v89 -- the superadmin per-firm/aggregate report's
--      `sales_count`, `appointment_count`, and `completed_appointments` had no synthetic
--      predicate, while `customer_count`/`customers`/`revenue_cents` in the SAME function did
--      (nestly_v743's own "mixed" class, found before the scanner had a name for it). Fixed with
--      the walk-in-safe `not exists (select 1 from public.clients c where c.id = <table>.client_id
--      and c.is_synthetic)` pattern nestly_v743 used for the same shape.
--  (6) public.get_legacy_value_inventory -- the owner/super-admin "unclaimed store value" audit
--      already flags each BUSINESS as `is_synthetic` but summed a business's
--      public.credit_ledger with no per-CLIENT synthetic exclusion: a real business's legacy
--      store-credit total could be inflated by a synthetic fixture client's real balance. Fixed
--      with a join + `not is_synthetic` on the credit_ledger reader.
--  (7) public.refresh_growth_recommendation_v108 -- THE WRITER, not a reader: `canonical_sales`,
--      the population a real marketing campaign's candidate list is built from, read
--      public.sales with no join to clients and no synthetic predicate. A synthetic (fixture)
--      customer could be selected as a growth-recommendation candidate for a REAL campaign.
--      Fixed at the write path: joined public.clients on the sale's client_id, required
--      `not sale_client.is_synthetic`.
--  (8) public.get_period_economics_v109 -- the growth-entitlement "eligible" CTE (marketing
--      redemption cost, folded into the period's cost-of-growth figure) read
--      public.growth_entitlements_v108 with no join to clients: a synthetic client's redeemed
--      entitlement cost could inflate the period's reported marketing spend. Fixed by joining
--      public.clients on the entitlement's client_id (NOT NULL) and requiring
--      `not entitlement_client.is_synthetic`.
--
-- Twelve functions, thirty-one individual anchored hunks. Every patch below is an anchored,
-- comment-free replace-equality diff against the LIVE pg_get_functiondef body -- the same
-- discipline as nestly_v668/v687/v714/v724/v734/v737/v740/v742/v743: capture the body before,
-- apply CREATE OR REPLACE, then assert the new body equals old-with-exactly-this-substitution-
-- and-nothing-else, or roll back the whole migration. ACLs are restated exactly as the live
-- `proacl` already shows (CREATE OR REPLACE preserves existing grants; nothing here widens or
-- narrows anon/authenticated/service_role/public access). app.v177_overview,
-- app.v179_business_insights, app.get_growth_execution_result_at_v108,
-- app.get_period_economics_v109 (app schema entries) and public.get_legacy_value_inventory /
-- public.platform_generate_my_report_v89 / public.refresh_growth_recommendation_v108 remain
-- exactly as privileged as they already were -- no anon exposure anywhere in this migration.
--
-- PROVEN BY: db/tests/executed/v744_corpus_scanner_blind_spots.sql -- the refuter's two named
-- scenarios (5 real + 1 synthetic same cadence -> lapsed_regulars count 4, not 5; credit ledger
-- real 1000 + synthetic 9000 -> liability 1000, not 10000), a mixed-function probe caught only by
-- the stricter Part C pass, a view-reading probe caught by the widened Part C table list, and a
-- rolled-back call to each of the other ten fixed readers proving the synthetic contribution is
-- now excluded. Every reader is called as its real principal (owner / staff / platform super
-- admin per the function's own gate), never as the migration role.
--
-- PART B is the scanner allowlist re-seed: PART C's stricter pass, run against the estate BEFORE
-- any of Part A's twelve fixes, additionally caught 24 "mixed" functions (guarded in one
-- statement, unguarded in another) beyond the eight named above that turned out to be real bugs.
-- The other seventeen were read individually and are, each, a correlated subquery/CTE scoped by
-- an ALREADY-synthetic-filtered outer population (the exclusion marker is textually present a
-- few lines away, just outside this particular aggregate's own statement boundary), a
-- reconciliation/exclusion-COUNTER whose entire purpose is to count what other readers exclude,
-- or a currency-consistency check with no customer dimension at all -- never a raw, unguarded
-- population aggregate. Each is allowlisted below with its own specific reason; none is a blanket
-- "trust me".
--
-- PART C -- app.ci_synthetic_scan_v743() (kept: same name, same allowlist table, internal
-- version note bumped to v744) is rebuilt with three changes over its nestly_v743 shape:
--   1. the table regex additionally matches every VIEW whose own definition reads one of the
--      seven guarded tables -- enumerated by hand against pg_views
--      (`client_credit_balance`, `client_points_balance`, `sale_balance`; `product_stock` was
--      checked and excluded -- its definition has no client dimension to be synthetic-exposed
--      on) -- so a reader that aggregates the VIEW, never the base table by name, is caught too.
--   2. the aggregate regex additionally matches `bool_or`, `bool_and`, `every`, `jsonb_agg`,
--      `json_agg`, `count(1`, `count(distinct` (the last two are already implied by the
--      existing bare `count\(` alternative, kept explicit per instruction so a future edit to
--      the aggregate list cannot silently drop count-shaped coverage without a visible diff).
--   3. a SECOND, STRICTER pass, `app.ci_synthetic_scan_mixed_v744()`: for every candidate
--      function (same table+aggregate gate as the original check), each aggregate occurrence's
--      own enclosing statement is isolated -- walking outward from the aggregate call to the
--      nearest subquery boundary (an unmatched `(` immediately followed by `select`/`with`) or
--      the statement's own terminating `;`, treating a plain function-call paren
--      (`coalesce(`, `round(`, ...) as transparent so it does not falsely truncate the window --
--      and checked for an exclusion marker WITHIN that statement alone, not merely somewhere in
--      the function. A function is reported 'mixed' when at least one such statement lacks a
--      marker while at least one other has one; a function with markers in NONE of its
--      statements is still caught by the original, unchanged rule. `app.ci_synthetic_scan_v743()`
--      now returns the union of both checks, still filtered by the one shared allowlist table --
--      an allowlisted signature is exempt from both classes, not one.
--
-- Run against the estate BEFORE any of Part A's fixes and BEFORE Part B's allowlist re-seed, the
-- widened scanner (both passes together) returned 32 rows: the original 0 unguarded (nestly_v743
-- left the estate clean by ITS OWN rule) plus 24 newly-caught 'mixed' functions -- of which eight
-- were the real bugs fixed in Part A above (four of those eight were caught by the widened TABLE
-- list specifically -- get_reports_summary/_v94_base's client_credit_balance reads,
-- get_dashboard_summary's, get_revenue_summary's sale_balance read -- and would NOT have
-- surfaced under nestly_v743's original table regex even with the stricter statement-level pass,
-- since that regex never matched the view names at all) and seventeen were read and justified
-- below. Run again after Part A's fixes and Part B's allowlist seed, it returns ZERO rows --
-- proven by the fixture, which also proves the scanner still finds a deliberately unguarded probe
-- function (both the plain and the mixed shape), still finds a probe that reads a VIEW instead of
-- a table by name, and still fails by name when a single allowlist row is deleted.
--
-- SCANNER BLIND SPOT, DECLARED HONESTLY (per db-tests/known-limitations convention): a population
-- built by calling ANOTHER function (app.customer_cadence_batch_v1 in bug #1, or any RPC that
-- itself queries a guarded table internally) is invisible to a source-text regex scan of the
-- CALLER's own body -- the caller's text contains no literal `public.clients`/`public.sales`
-- etc. for the scanner to match. Nothing in Part C closes this; it is a structural limit of a
-- static source-regex scanner, not a bug in it. The mitigation is procedural, not automatic: any
-- new population-shaped kernel function name added to the allowlist's "per-row kernel, caller's
-- responsibility to filter" class (the app.customer_cadence_batch_v1 shape) should be grepped for
-- by name across the estate at review time, the way this migration's Part A #1 was found by
-- re-reading every caller of app.customer_cadence_batch_v1 by hand, not by the scanner.
--
-- Existing fixtures for every touched reader (v730/v734/v737/v740/v742/v743 synthetic-exclusion
-- estate sweeps) were re-run against this migration's MIGRATED database and stay green -- none of
-- them exercised a code path this migration's patches moved, confirmed by re-running
-- `LC_ALL=C node scripts/db-tests/run.mjs --migrated-only` (see the session report for the full
-- pass/fail table).
--
-- ROLLBACK: each function's captured "before" body is available in this migration's own do-block
-- (re-run each CREATE OR REPLACE with the pre-image quoted in that block's `v_old`/`v_new`
-- constants); to remove only the scanner hardening, `CREATE OR REPLACE FUNCTION
-- app.ci_synthetic_scan_v743()` back to its nestly_v743 body and `drop function
-- app.ci_synthetic_scan_mixed_v744()`; the allowlist rows added here are additive and harmless to
-- leave in place even on a partial rollback.

begin;

create temp table _v744_before(fn text primary key, def text) on commit drop;

do $capture$
begin
  insert into _v744_before(fn, def)
  select 'get_ci_opportunities_v1', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_ci_opportunities_v1'  union all
  select 'get_reports_summary_v94_base', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_reports_summary_v94_base'  union all
  select 'get_reports_summary', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_reports_summary'  union all
  select 'get_dashboard_summary', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_dashboard_summary'  union all
  select 'get_revenue_summary', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_revenue_summary'  union all
  select 'v177_overview', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'v177_overview'  union all
  select 'v179_business_insights', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'v179_business_insights'  union all
  select 'get_growth_execution_result_at_v108_v744', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'get_growth_execution_result_at_v108'  union all
  select 'platform_generate_my_report_v89', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'platform_generate_my_report_v89'  union all
  select 'get_legacy_value_inventory', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_legacy_value_inventory'  union all
  select 'refresh_growth_recommendation_v108', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'refresh_growth_recommendation_v108'  union all
  select 'get_period_economics_v109', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_period_economics_v109';

  if (select count(*) from _v744_before) <> 12 then
    raise exception 'v744: expected exactly 12 captured function bodies, found %',
      (select count(*) from _v744_before);
  end if;
end
$capture$;

-- =============================================================================================
-- 1 . public.get_ci_opportunities_v1 -- Generator B + EV re-derivation overdue CTEs
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_ci_opportunities_v1(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid, p_as_of timestamp with time zone DEFAULT clock_timestamp(), p_extended boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  c_funnel_window   constant integer := 60;
  c_gap_pp          constant numeric := 15.0;
  c_util_pct        constant numeric := 50.0;
  c_conc_bps        constant integer := 6000;
  c_daypart_ratio   constant numeric := 2.0;
  c_gateway_min     constant integer := 5;
  c_reach_pct       constant numeric := 50.0;
  c_classified_bps  constant integer := 9000;
  c_demog_pct       constant numeric := 50.0;
  c_stale_days      constant integer := 400;
  c_stale_period_days constant integer := 90;
  c_ev_materiality_pct constant numeric :=
    app.ci_materiality_threshold_bps_v705() / 100.0;   -- NESTLY v712 (check 23): ONE bar, derived
  c_cannibal_pct    constant numeric := 50.0;      -- new: loyalty_cannibalisation_gap bar
  c_staff_index_bar constant numeric := 0.80;      -- new: staff_mix_underperformance bar

  v_funnel      jsonb;
  v_daypart     jsonb;
  v_svc         jsonb;
  v_pkg         jsonb;
  v_catmix      jsonb;
  v_contact     jsonb;
  v_demog       jsonb;

  v_cands       jsonb := '[]'::jsonb;
  v_abst        jsonb := '[]'::jsonb;
  v_ranked      jsonb;
  v_examined    integer := 0;
  v_promoted    integer := 0;

  v_f_d1        bigint;
  v_f_d2        bigint;
  v_f_p1        numeric;
  v_f_p2        numeric;
  v_f_stage     text;
  v_f_conf      jsonb;

  v_conf        jsonb;
  v_hi          jsonb;
  v_lo          jsonb;
  v_busiest     jsonb;
  v_valuable    jsonb;
  v_top         jsonb;
  v_classified  bigint;
  v_share_bps   integer;

  v_lapsed_n    integer;
  v_lapsed_sum  bigint;

  v_plan        record;
  v_service     record;
  v_n_entities  integer;
  v_unused      bigint;
  v_unit        bigint;

  v_bo          jsonb;
  v_customers   bigint;
  v_best        bigint;
  v_best_ch     text;

  v_classified_bps integer;
  v_demog_pct   numeric;
  v_identified  bigint;

  v_obs_min     timestamptz;
  v_stale       boolean;
  v_period_far  boolean;
  v_refusal     text;
  v_result      jsonb;

  -- ---------------------------------------------------------------------------------------
  -- extended-mode-only state (all computed and used ONLY when p_extended)
  -- ---------------------------------------------------------------------------------------
  v_has_v683       boolean;
  v_period_revenue bigint;
  v_ev_bar         numeric;
  v_cands_ext      jsonb := '[]'::jsonb;
  v_abst_ext       jsonb;
  v_ranked_ext     jsonb;
  v_examined_ext   integer;
  v_promoted_ext   integer;
  v_c              jsonb;
  v_id             text;
  v_domain         text;
  v_impact         jsonb;
  v_action         jsonb;
  v_incentive      jsonb;
  v_why_now        text;
  v_alternatives   jsonb;
  v_reversal       text;
  v_cost_basis     jsonb;
  v_ev             jsonb;

  v_ev_lapsed_cents   bigint;
  v_ev_lapsed_abst    integer;
  v_ev_pkg_cents      bigint;
  v_ev_pkg_abst       integer;

  v_discovery       jsonb;
  v_new_cands       jsonb := '[]'::jsonb;
  v_dsc             record;

  v_top_weekday     jsonb;
  v_top_category    jsonb;
  v_top_service     jsonb;

  v_discount_dep    jsonb;
  v_reminder_n      integer;
  v_loyalty         jsonb;
  v_best_programme  text;
  v_best_cannibal   numeric;
  v_staff_perf      jsonb;
  v_worst_staff     jsonb;

  v_report_sections jsonb;
  v_top_actions     jsonb;

  -- NESTLY v705 (checks 23/25/66/74/77) — materiality, margin guard, capacity, concentration,
  -- rebooking-alternatives state. All extended-mode-only; none of it is read in the base pass.
  v_capacity              jsonb;
  v_top_skew              boolean;
  v_margin_guard_cannibal jsonb;
  v_rebooking             jsonb;
  v_campaign_funnel       jsonb;

  c_incentive_unavailable constant jsonb := jsonb_build_object(
    'status', 'unavailable',
    'reason', 'no cost coverage: services carry no cost field; products.cost_cents nullable');
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  -- =============================================================================================
  -- GENERATOR A · retention funnel — a named bottleneck with a material gap between the stages
  -- =============================================================================================
  v_examined := v_examined + 1;
  v_funnel := public.get_ci_funnel_conversion_v1(p_business, p_from, p_to, c_funnel_window, p_branch, p_as_of);
  v_f_d1 := (v_funnel->'stage_1_to_2'->>'denominator')::bigint;
  v_f_d2 := (v_funnel->'stage_2_to_3'->>'denominator')::bigint;
  v_f_p1 := (v_funnel->'stage_1_to_2'->>'pct')::numeric;
  v_f_p2 := (v_funnel->'stage_2_to_3'->>'pct')::numeric;
  v_f_stage := v_funnel->>'bottleneck';
  v_f_conf := app.subgroup_evidence_v1(least(coalesce(v_f_d1, 0), coalesce(v_f_d2, 0))::int);

  if v_f_stage is null or v_f_p1 is null or v_f_p2 is null then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'funnel_bottleneck',
      'reason', 'no bottleneck is nameable: a stage rate is null or the two stages are tied'));
  elsif v_f_conf->>'status' <> 'ok' then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'funnel_bottleneck',
      'reason', format('smallest stage denominator (%s) is below the sample floor of %s',
                        v_f_conf->>'n', v_f_conf->>'floor')));
  elsif abs(v_f_p1 - v_f_p2) < c_gap_pp then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'funnel_bottleneck',
      'reason', format('below_materiality: the stages differ by %s points, below the %s-point '
                        'materiality bar', round(abs(v_f_p1 - v_f_p2), 1), c_gap_pp)));
  else
    v_cands := v_cands || jsonb_build_array(jsonb_build_object(
      'id', 'funnel_bottleneck',
      'domain', 'retention_funnel',
      'pattern', format(
        'Of %s customers whose first visit matured, %s%% came back for a second within %s days, '
        'and %s%% of those went on to a third; the %s step is the weaker of the two by %s points.',
        v_f_d1, v_f_p1, c_funnel_window, v_f_p2, replace(v_f_stage, '_', '-'),
        round(abs(v_f_p1 - v_f_p2), 1)),
      'comparison', jsonb_build_object(
        'kind', 'cross_segment',
        'detail', format('first-to-second conversion (%s%%, n=%s) against second-to-third '
                          '(%s%%, n=%s), both on the same %s-day maturity rule',
                          v_f_p1, v_f_d1, v_f_p2, v_f_d2, c_funnel_window)),
      'impact', jsonb_build_object(
        'cents', null,
        'reason', 'no incremental model: converting a funnel gap into cents requires an assumed '
                  'uplift, which would be a forecast rather than a measurement'),
      'action', jsonb_build_object(
        'who', 'the owner, with the staff who serve the visit before the drop',
        'what', format('Fix the %s drop-off — rework what happens at the end of that visit '
                        '(rebook on the spot, name the next appointment, hand over the follow-up '
                        'offer) rather than adding another campaign upstream of it.',
                        replace(v_f_stage, '_', '-')),
        'when', 'within the next full ' || c_funnel_window || '-day cycle, so the change is measurable',
        'channel', 'in_person_at_checkout'),
      'evidence', jsonb_build_object(
        'source_rpc', 'public.get_ci_funnel_conversion_v1',
        'refs', jsonb_build_object(
          'stage_1_to_2', v_funnel->'stage_1_to_2',
          'stage_2_to_3', v_funnel->'stage_2_to_3',
          'bottleneck', v_f_stage,
          'immature', v_funnel->'immature',
          'window_days', v_funnel->'window_days',
          'reader_evidence', v_funnel->'evidence')),
      'evidence_class', 'DIRECT_FACT',
      'confidence', v_f_conf,
      'limitation',
        'Both rates are measured on customers who have already had a full window, so a recent '
        'change in how the firm operates is not visible here yet, and the two stages are not the '
        'same people — the second-to-third denominator is a self-selected subset of the first.',
      'rank_class', 'unquantified'));
  end if;

  -- =============================================================================================
  -- GENERATOR B · lapsed regulars — customers overdue against their OWN median rhythm
  -- =============================================================================================
  v_examined := v_examined + 1;
  if p_branch is not null then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'lapsed_regulars',
      'reason', 'no branch dimension: app.customer_cadence_v1 resolves the v107 lifecycle policy '
                'firm-wide and emits deviation_state only for a firm-wide computation'));
  else
    with overdue as materialized (
      select b.client_id
        from app.customer_cadence_batch_v1(
               p_business,
               ((p_as_of at time zone 'Asia/Singapore')::date + 1),
               ((p_as_of at time zone 'Asia/Singapore')::date + 1),
               p_as_of, null, true) b
        join public.clients cli on cli.id = b.client_id and cli.business_id = p_business
        cross join lateral (
          select app.customer_cadence_v1(p_business, b.client_id) as cad
        ) c
       where c.cad->>'deviation_state' = 'overdue'
         and c.cad->>'evidence_source' = 'customer_median_interval'
         and not cli.is_synthetic
    ),
    tickets as (
      select o.client_id,
             round(sum(s.amount_cents)::numeric / count(*)) as avg_ticket
        from overdue o
        join public.sales s
          on s.business_id = p_business
         and app.v111_effective_client_id(s.business_id, s.client_id) = o.client_id
        cross join lateral app.analytics_sale_class_v1(s) sc
       where sc.include_revenue
         and not sc.is_synthetic_client
         and s.created_at <= p_as_of
       group by o.client_id
    )
    select count(*)::int, coalesce(sum(coalesce(t.avg_ticket, 0)), 0)::bigint
      into v_lapsed_n, v_lapsed_sum
      from overdue o
      left join tickets t on t.client_id = o.client_id;

    v_conf := app.subgroup_evidence_v1(coalesce(v_lapsed_n, 0));
    if coalesce(v_lapsed_n, 0) = 0 then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'lapsed_regulars',
        'reason', 'no customer is overdue against a rhythm of their own: every overdue customer '
                  'is judged on the business fallback, which says nothing about that person'));
    elsif v_conf->>'status' <> 'ok' then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'lapsed_regulars',
        'reason', format('%s overdue regular(s) is below the sample floor of %s',
                          v_conf->>'n', v_conf->>'floor')));
    else
      v_cands := v_cands || jsonb_build_array(jsonb_build_object(
        'id', 'lapsed_regulars',
        'domain', 'cadence',
        'pattern', format(
          '%s customers with an established visit rhythm are now overdue against their OWN median '
          'interval; one return visit each at their own historical average ticket is worth %s cents.',
          v_lapsed_n, v_lapsed_sum),
        'comparison', jsonb_build_object(
          'kind', 'baseline',
          'detail', 'each customer is compared against their own median inter-visit interval '
                    '(app.customer_cadence_v1, evidence_source=customer_median_interval), never '
                    'against a firm-wide days-since-last-visit cut-off'),
        'impact', jsonb_build_object(
          'cents', v_lapsed_sum,
          'method', 'sum over the overdue regulars of round(that customer''s lifetime '
                    'revenue-qualifying sale total / their count of such sales) — one visit each, '
                    'at their own average ticket. No response rate, no uplift, no discounting.'),
        'action', jsonb_build_object(
          'who', 'front desk',
          'what', 'Contact these customers individually, referencing what they last had and when, '
                  'before offering anything — the list is small enough to work by hand and a '
                  'discount is not what a customer with a broken rhythm is missing.',
          'when', 'this week',
          'channel', 'whatsapp_or_call_where_consent_exists'),
        'evidence', jsonb_build_object(
          'source_rpc', 'app.customer_cadence_batch_v1 + app.customer_cadence_v1',
          'refs', jsonb_build_object(
            'overdue_regulars', v_lapsed_n,
            'recoverable_cents', v_lapsed_sum,
            'deviation_state', 'overdue',
            'evidence_source', 'customer_median_interval')),
        'evidence_class', 'ASSOCIATION',
        'confidence', v_conf,
        'limitation',
          'An overdue customer is not a lost customer: some would have returned unprompted, so '
          'the figure is the value at stake, not the value a campaign would add.',
        'rank_class', 'quantified'));
    end if;
  end if;

  -- =============================================================================================
  -- GENERATOR C · dead-vs-gold weekday — the busiest day is not the valuable one
  -- =============================================================================================
  v_examined := v_examined + 1;
  v_daypart := public.get_ci_daypart_v1(p_business, p_from, p_to, p_branch, p_as_of);
  v_busiest := v_daypart->'busiest_weekday';
  v_valuable := v_daypart->'most_valuable_weekday';

  select w into v_hi
    from jsonb_array_elements(coalesce(v_daypart->'weekdays', '[]'::jsonb)) w
   where w->'evidence'->>'status' = 'ok'
     and w->>'revenue_per_visit_cents' is not null
     and (w->>'revenue_per_visit_cents')::numeric > 0
   order by (w->>'revenue_per_visit_cents')::numeric desc, (w->>'dow')::int
   limit 1;
  select w into v_lo
    from jsonb_array_elements(coalesce(v_daypart->'weekdays', '[]'::jsonb)) w
   where w->'evidence'->>'status' = 'ok'
     and w->>'revenue_per_visit_cents' is not null
     and (w->>'revenue_per_visit_cents')::numeric > 0
   order by (w->>'revenue_per_visit_cents')::numeric asc, (w->>'dow')::int
   limit 1;

  if v_busiest is null or v_valuable is null or v_valuable->>'dow' is null then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'daypart_shift',
      'reason', 'no weekday clears the evidence floor, so no weekday may be called most valuable'));
  elsif (v_busiest->>'dow')::int = (v_valuable->>'dow')::int then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'daypart_shift',
      'reason', format('the busiest and most valuable weekday are the same day (%s); there is no '
                        'capacity to shift', v_busiest->>'label')));
  elsif v_hi is null or v_lo is null or (v_hi->>'dow')::int = (v_lo->>'dow')::int then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'daypart_shift',
      'reason', 'no comparable pair of evidence-backed weekdays exists to compare a ratio against'));
  elsif (v_hi->>'revenue_per_visit_cents')::numeric
             < c_daypart_ratio * (v_lo->>'revenue_per_visit_cents')::numeric then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'daypart_shift',
      'reason', format('below_materiality: no pair of evidence-backed weekdays differs by %sx in '
                        'revenue per visit (actual ratio %s)', c_daypart_ratio,
                        round((v_hi->>'revenue_per_visit_cents')::numeric
                              / nullif((v_lo->>'revenue_per_visit_cents')::numeric, 0), 2))));
  else
    v_conf := app.subgroup_evidence_v1(least((v_hi->>'visits')::int, (v_lo->>'visits')::int));
    if v_conf->>'status' <> 'ok' then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'daypart_shift',
        'reason', 'the thinner of the two compared weekdays is below the sample floor'));
    else
      v_cands := v_cands || jsonb_build_array(jsonb_build_object(
        'id', 'daypart_shift',
        'domain', 'daypart',
        'pattern', format(
          '%s takes %s cents per visit against %s''s %s — %sx — while %s is the busiest day by '
          'volume (%s visits).',
          v_hi->>'label', v_hi->>'revenue_per_visit_cents', v_lo->>'label',
          v_lo->>'revenue_per_visit_cents',
          round((v_hi->>'revenue_per_visit_cents')::numeric
                 / nullif((v_lo->>'revenue_per_visit_cents')::numeric, 0), 1),
          v_busiest->>'label', v_busiest->>'visits'),
        'comparison', jsonb_build_object(
          'kind', 'cross_segment',
          'detail', format('%s (n=%s visits) against %s (n=%s visits), both above the sample floor, '
                            'each measured over the same number of weekday occurrences in the window',
                            v_hi->>'label', v_hi->>'visits', v_lo->>'label', v_lo->>'visits')),
        'impact', jsonb_build_object(
          'cents', null,
          'reason', 'no incremental model: moving capacity between weekdays has no measured '
                    'counterfactual here, and assuming the gold day''s per-visit value would '
                    'survive extra volume is exactly the assumption that must not be smuggled in'),
        'action', jsonb_build_object(
          'who', 'the owner, with whoever writes the rota',
          'what', format('Shift capacity and promotion toward %s — staff it first, book the '
                          'higher-value work into it, and stop spending promotion on %s, which is '
                          'already full of low-value visits.',
                          v_valuable->>'label', v_busiest->>'label'),
          'when', 'next rota cycle',
          'channel', 'rota_and_promotions'),
        'evidence', jsonb_build_object(
          'source_rpc', 'public.get_ci_daypart_v1',
          'refs', jsonb_build_object(
            'gold_weekday', v_hi,
            'dead_weekday', v_lo,
            'busiest_weekday', v_busiest,
            'most_valuable_weekday', v_valuable,
            'time_basis', v_daypart->'time_basis')),
        'evidence_class', 'ASSOCIATION',
        'confidence', v_conf,
        'limitation',
          'Revenue per visit is a mix effect as much as a day effect: the valuable day may simply '
          'be when the expensive service is offered, and the till timestamp is not arrival time.',
        'rank_class', 'unquantified'));
    end if;
  end if;

  -- =============================================================================================
  -- GENERATOR D · category concentration — diversification risk
  -- =============================================================================================
  v_examined := v_examined + 1;
  v_catmix := public.get_ci_category_mix_v1(p_business, p_from, p_to, p_branch, p_as_of);
  select coalesce(sum((c->>'revenue_cents')::bigint), 0) into v_classified
    from jsonb_array_elements(coalesce(v_catmix->'categories', '[]'::jsonb)) c;
  select c into v_top
    from jsonb_array_elements(coalesce(v_catmix->'categories', '[]'::jsonb)) c
   order by (c->>'revenue_cents')::bigint desc, c->>'node_key'
   limit 1;

  if v_top is null or coalesce(v_classified, 0) <= 0 then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'category_concentration',
      'reason', 'no classified revenue in the window, so no share can be computed'));
  else
    v_share_bps := (10000.0 * (v_top->>'revenue_cents')::bigint / v_classified)::int;
    v_conf := app.subgroup_evidence_v1((v_top->>'customer_count')::int);
    if v_share_bps < c_conc_bps then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'category_concentration',
        'reason', format('the largest category holds %s bps of classified revenue, below the %s '
                          'bps concentration bar', v_share_bps, c_conc_bps)));
    elsif v_conf->>'status' <> 'ok' then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'category_concentration',
        'reason', format('the largest category has %s customer(s), below the sample floor of %s',
                          v_conf->>'n', v_conf->>'floor')));
    else
      v_cands := v_cands || jsonb_build_array(jsonb_build_object(
        'id', 'category_concentration',
        'domain', 'category_mix',
        'pattern', format(
          '%s cents of %s cents of classified revenue — %s%% — comes from a single category (%s), '
          'bought by %s customers.',
          v_top->>'revenue_cents', v_classified, round(v_share_bps / 100.0, 1),
          coalesce(v_top->>'label', v_top->>'node_key'), v_top->>'customer_count'),
        'comparison', jsonb_build_object(
          'kind', 'threshold',
          'detail', format('largest level-2 category share of CLASSIFIED revenue (%s bps) against '
                            'the %s bps concentration bar; unclassified revenue is deliberately '
                            'outside the denominator', v_share_bps, c_conc_bps)),
        'impact', jsonb_build_object(
          'cents', null,
          'reason', 'concentration is an exposure profile, not a cash figure; the amount at risk '
                    'is the category revenue already stated, and how much of it would actually '
                    'move is unmeasurable from this data'),
        'action', jsonb_build_object(
          'who', 'the owner',
          'what', format('Treat %s as a single point of failure: know what a price, staffing or '
                          'demand change there does to the month, and pick ONE adjacent category '
                          'to grow deliberately rather than diversifying everywhere at once.',
                          coalesce(v_top->>'label', v_top->>'node_key')),
          'when', 'this quarter',
          'channel', 'planning'),
        'evidence', jsonb_build_object(
          'source_rpc', 'public.get_ci_category_mix_v1',
          'refs', jsonb_build_object(
            'top_category', v_top,
            'classified_revenue_cents', v_classified,
            'top_share_bps', v_share_bps,
            'coverage', v_catmix->'coverage')),
        'evidence_class', 'DIRECT_FACT',
        'confidence', v_conf,
        'limitation',
          'A concentrated mix is not automatically a fault — a specialist earns its living that '
          'way — and this share is computed only over revenue that was classified at all.',
        'rank_class', 'unquantified'));
    end if;
  end if;

  -- =============================================================================================
  -- GENERATOR E · package leakage — prepaid sessions nobody is using (one candidate per plan)
  -- =============================================================================================
  if p_branch is not null then
    v_examined := v_examined + 1;
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'package_leakage',
      'reason', 'no branch dimension: client_packages carries no branch column (v675), so a '
                'branch-scoped utilisation figure cannot be produced honestly'));
  else
    v_pkg := public.get_ci_package_intelligence_v1(p_business, p_from, p_to, null, p_as_of);
    v_n_entities := coalesce(jsonb_array_length(v_pkg->'plans'), 0);
    v_examined := v_examined + greatest(1, v_n_entities);
    if v_n_entities = 0 then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'package_leakage',
        'reason', 'no package plan had a purchase inside the window'));
    end if;
    for v_plan in
      select e.value as p from jsonb_array_elements(coalesce(v_pkg->'plans', '[]'::jsonb)) e
    loop
      if v_plan.p->'evidence'->>'status' <> 'ok' then
        v_abst := v_abst || jsonb_build_array(jsonb_build_object(
          'generator', 'package_leakage:' || (v_plan.p->>'plan_id'),
          'reason', format('%s package(s) sold in the window is below the sample floor of %s',
                            v_plan.p->'evidence'->>'n', v_plan.p->'evidence'->>'floor')));
      elsif v_plan.p->'utilisation'->>'pct' is null
            or (v_plan.p->'utilisation'->>'pct')::numeric >= c_util_pct then
        v_abst := v_abst || jsonb_build_array(jsonb_build_object(
          'generator', 'package_leakage:' || (v_plan.p->>'plan_id'),
          'reason', format('utilisation is %s%%, at or above the %s%% leakage bar',
                            coalesce(v_plan.p->'utilisation'->>'pct', 'null'), c_util_pct)));
      else
        v_unused := (v_plan.p->>'sessions_included')::bigint
                     - (v_plan.p->>'sessions_used')::bigint;
        select round(pp.price_cents::numeric / nullif(pp.sessions, 0))::bigint into v_unit
          from public.package_plans pp
         where pp.id = (v_plan.p->>'plan_id')::uuid and pp.business_id = p_business;
        if v_unit is null or v_unused <= 0 then
          v_abst := v_abst || jsonb_build_array(jsonb_build_object(
            'generator', 'package_leakage:' || (v_plan.p->>'plan_id'),
            'reason', 'no unused sessions, or the plan carries no per-session price to value them'));
        else
          v_cands := v_cands || jsonb_build_array(jsonb_build_object(
            'id', 'package_leakage:' || (v_plan.p->>'plan_id'),
            'domain', 'packages',
            'pattern', format(
              '%s of %s sessions sold on "%s" are still unused (%s%% utilisation across %s '
              'packages), worth %s cents of prepaid service at %s cents a session.',
              v_unused, v_plan.p->>'sessions_included', v_plan.p->>'plan_name',
              v_plan.p->'utilisation'->>'pct', v_plan.p->>'sold_count',
              v_unused * v_unit, v_unit),
            'comparison', jsonb_build_object(
              'kind', 'threshold',
              'detail', format('plan utilisation %s%% against the %s%% bar, on %s packages sold '
                                'inside the window', v_plan.p->'utilisation'->>'pct', c_util_pct,
                                v_plan.p->>'sold_count')),
            'impact', jsonb_build_object(
              'cents', v_unused * v_unit,
              'method', format('(sessions_included %s - sessions_used %s) x round(plan price / '
                                'plan sessions) = %s x %s. The session count comes from '
                                'get_ci_package_intelligence_v1; the per-session unit from '
                                'public.package_plans, which the payload does not carry.',
                                v_plan.p->>'sessions_included', v_plan.p->>'sessions_used',
                                v_unused, v_unit)),
            'action', jsonb_build_object(
              'who', 'front desk',
              'what', format('Book the unused "%s" sessions out: call every holder with sessions '
                              'left and put a date in the diary on the call, rather than waiting '
                              'for them to come back on their own.', v_plan.p->>'plan_name'),
              'when', 'this month',
              'channel', 'call_or_whatsapp_where_consent_exists'),
            'evidence', jsonb_build_object(
              'source_rpc', 'public.get_ci_package_intelligence_v1 + public.package_plans',
              'refs', jsonb_build_object(
                'plan_id', v_plan.p->'plan_id',
                'plan_name', v_plan.p->'plan_name',
                'sold_count', v_plan.p->'sold_count',
                'sessions_included', v_plan.p->'sessions_included',
                'sessions_used', v_plan.p->'sessions_used',
                'utilisation', v_plan.p->'utilisation',
                'expired_or_lapsed_with_unused', v_plan.p->'expired_or_lapsed_with_unused',
                'unused_sessions', v_unused,
                'per_session_cents', v_unit)),
            'evidence_class', 'DIRECT_FACT',
            'confidence', v_plan.p->'evidence',
            'limitation',
              'This is prepaid service at risk of lapsing, not new revenue: the money was already '
              'recognised when the package was sold, and a holder who bought at an older price is '
              'valued here at the plan''s current list price.',
            'rank_class', 'quantified'));
        end if;
      end if;
    end loop;
  end if;

  -- =============================================================================================
  -- GENERATOR F · gateway services whose buyers do not come back (one candidate per service)
  -- =============================================================================================
  v_svc := public.get_ci_service_intelligence_v1(p_business, p_from, p_to, p_branch, p_as_of);
  v_n_entities := coalesce(jsonb_array_length(v_svc->'services'), 0);
  v_examined := v_examined + greatest(1, v_n_entities);
  if v_f_p1 is null or v_f_conf->>'status' <> 'ok' then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'gateway_followthrough',
      'reason', 'the firm''s own first-to-second funnel rate is unavailable or below the sample '
                'floor, so there is no baseline to judge a service against'));
  elsif v_n_entities = 0 then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'gateway_followthrough',
      'reason', 'no service was bought inside the window'));
  else
    for v_service in
      select e.value as s from jsonb_array_elements(coalesce(v_svc->'services', '[]'::jsonb)) e
    loop
      if (v_service.s->>'gateway_count')::int < c_gateway_min then
        v_abst := v_abst || jsonb_build_array(jsonb_build_object(
          'generator', 'gateway_followthrough:' || (v_service.s->>'service_id'),
          'reason', format('%s first-ever buyers is below the %s needed to call it a gateway',
                            v_service.s->>'gateway_count', c_gateway_min)));
      elsif v_service.s->'evidence'->>'status' <> 'ok'
            or v_service.s->'repeat_rate'->>'pct' is null then
        v_abst := v_abst || jsonb_build_array(jsonb_build_object(
          'generator', 'gateway_followthrough:' || (v_service.s->>'service_id'),
          'reason', 'the service''s buyer count is below the sample floor, so its repeat rate is '
                    'withheld and cannot be compared'));
      elsif v_f_p1 - (v_service.s->'repeat_rate'->>'pct')::numeric < c_gap_pp then
        v_abst := v_abst || jsonb_build_array(jsonb_build_object(
          'generator', 'gateway_followthrough:' || (v_service.s->>'service_id'),
          'reason', format('repeat rate %s%% trails the firm''s %s%% by less than %s points',
                            v_service.s->'repeat_rate'->>'pct', v_f_p1, c_gap_pp)));
      else
        v_conf := app.subgroup_evidence_v1(
                    least((v_service.s->>'buyers')::int, coalesce(v_f_d1, 0)::int));
        if v_conf->>'status' <> 'ok' then
          v_abst := v_abst || jsonb_build_array(jsonb_build_object(
            'generator', 'gateway_followthrough:' || (v_service.s->>'service_id'),
            'reason', 'the smaller of the service''s buyers and the funnel denominator is below '
                      'the sample floor'));
        else
          v_cands := v_cands || jsonb_build_array(jsonb_build_object(
            'id', 'gateway_followthrough:' || (v_service.s->>'service_id'),
            'domain', 'service_intelligence',
            'pattern', format(
              '"%s" is how %s customers first arrived, but only %s%% of its %s buyers bought it '
              'again, against a firm-wide first-to-second rate of %s%% — %s points behind.',
              v_service.s->>'service_name', v_service.s->>'gateway_count',
              v_service.s->'repeat_rate'->>'pct', v_service.s->>'buyers', v_f_p1,
              round(v_f_p1 - (v_service.s->'repeat_rate'->>'pct')::numeric, 1)),
            'comparison', jsonb_build_object(
              'kind', 'baseline',
              'detail', format('this service''s repeat rate (%s of %s buyers) against the firm''s '
                                'own first-to-second conversion (%s%%, n=%s) as the baseline',
                                v_service.s->'repeat_rate'->>'numerator',
                                v_service.s->'repeat_rate'->>'denominator', v_f_p1, v_f_d1)),
            'impact', jsonb_build_object(
              'cents', null,
              'reason', 'no incremental model: the gap says the first experience under-converts, '
                        'not how much revenue a better one would add'),
            'action', jsonb_build_object(
              'who', 'the owner, with the staff who deliver this service',
              'what', format('Fix the first-visit experience for "%s": watch the appointment end '
                              'to end, decide what the next step should be for someone who has '
                              'only ever had this one thing, and make offering it part of the '
                              'service rather than an afterthought.', v_service.s->>'service_name'),
              'when', 'within the month',
              'channel', 'in_person_at_the_appointment'),
            'evidence', jsonb_build_object(
              'source_rpc', 'public.get_ci_service_intelligence_v1 + '
                            'public.get_ci_funnel_conversion_v1',
              'refs', jsonb_build_object(
                'service_id', v_service.s->'service_id',
                'service_name', v_service.s->'service_name',
                'buyers', v_service.s->'buyers',
                'orders', v_service.s->'orders',
                'revenue_cents', v_service.s->'revenue_cents',
                'gateway_count', v_service.s->'gateway_count',
                'repeat_rate', v_service.s->'repeat_rate',
                'firm_stage_1_to_2', v_funnel->'stage_1_to_2')),
            'evidence_class', 'ASSOCIATION',
            'confidence', v_conf,
            'limitation',
              'Whoever chooses this service is not a random draw from the firm''s first-timers, so '
              'the gap may be who they are rather than what happened to them.',
            'rank_class', 'unquantified'));
        end if;
      end if;
    end loop;
  end if;

  -- =============================================================================================
  -- GENERATOR G · contactability — most customers cannot legally be reached at all
  -- =============================================================================================
  v_examined := v_examined + 1;
  if p_branch is not null then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'contactability_gap',
      'reason', 'no branch dimension: consent is recorded per business, not per branch'));
  else
    v_contact := public.get_ci_contactability_v1(p_business, null);
    v_bo := v_contact->'business_offers';
    v_customers := (v_bo->>'customers')::bigint;
    select e.key, e.value::bigint into v_best_ch, v_best
      from jsonb_each_text(coalesce(v_bo->'allowed_by_channel', '{}'::jsonb)) e
     order by e.value::bigint desc, e.key
     limit 1;
    v_conf := app.subgroup_evidence_v1(coalesce(v_customers, 0)::int);
    if coalesce(v_customers, 0) = 0 or v_conf->>'status' <> 'ok' then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'contactability_gap',
        'reason', format('%s identified customer(s) is below the sample floor of %s',
                          v_conf->>'n', v_conf->>'floor')));
    elsif 100.0 * coalesce(v_best, 0) / v_customers >= c_reach_pct then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'contactability_gap',
        'reason', format('the best channel reaches %s%% of customers, at or above the %s%% bar',
                          round(100.0 * coalesce(v_best, 0) / v_customers, 1), c_reach_pct)));
    else
      v_cands := v_cands || jsonb_build_array(jsonb_build_object(
        'id', 'contactability_gap',
        'domain', 'contactability',
        'pattern', format(
          'Only %s of %s customers (%s%%) can lawfully be sent a business offer on the best '
          'available channel (%s); the rest have no affirmative consent on record.',
          coalesce(v_best, 0), v_customers,
          round(100.0 * coalesce(v_best, 0) / v_customers, 1), v_best_ch),
        'comparison', jsonb_build_object(
          'kind', 'threshold',
          'detail', format('best single-channel reachable share (%s of %s) against the %s%% bar; '
                            'the best channel is used because per-channel counts cannot be unioned '
                            'from the reader''s payload, which makes this an under-statement of '
                            'reach, never an over-statement',
                            coalesce(v_best, 0), v_customers, c_reach_pct)),
        'impact', jsonb_build_object(
          'cents', null,
          'reason', 'no incremental model: the value of being able to contact someone depends on '
                    'what would be said to them, which does not exist yet'),
        'action', jsonb_build_object(
          'who', 'front desk',
          'what', 'Ask for consent at checkout, in person, with the notice shown — one question '
                  'at the point of payment, recorded per channel. Do not bulk-import or assume '
                  'existing customers are opted in.',
          'when', 'starting immediately, reviewed in 30 days',
          'channel', 'in_person_at_checkout'),
        'evidence', jsonb_build_object(
          'source_rpc', 'public.get_ci_contactability_v1',
          'refs', jsonb_build_object(
            'business_offers', v_bo,
            'best_channel', v_best_ch,
            'best_channel_allowed', coalesce(v_best, 0),
            'note', v_contact->'note')),
        'evidence_class', 'DIRECT_FACT',
        'confidence', v_conf,
        'limitation',
          'A customer unreachable for marketing is still reachable for a booking they asked for; '
          'this counts consent for proactive offers only, and a customer with two channels is '
          'counted once per channel, so the true reachable union is somewhere between the best '
          'channel and their sum.',
        'rank_class', 'unquantified'));
    end if;
  end if;

  -- =============================================================================================
  -- GENERATOR H · data quality (check 30) — a FOUNDATION candidate, ranked above business advice
  -- =============================================================================================
  v_examined := v_examined + 1;
  v_demog := public.get_ci_demographics_v1(p_business, p_from, p_to, p_branch, p_as_of);
  v_classified_bps := (v_catmix->'coverage'->>'classified_pct_bps')::int;
  v_demog_pct := (v_demog->'coverage'->'demographics'->>'pct')::numeric;
  v_identified := (v_demog->'coverage'->'demographics'->>'denominator')::bigint;
  v_conf := app.subgroup_evidence_v1(coalesce(v_identified, 0)::int);

  if v_conf->>'status' <> 'ok' then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'data_quality_coverage',
      'reason', format('%s identified customer(s) is below the sample floor of %s, so a coverage '
                        'complaint would itself rest on nothing',
                        v_conf->>'n', v_conf->>'floor')));
  elsif not ((v_classified_bps is not null and v_classified_bps < c_classified_bps)
             or (v_demog_pct is not null and v_demog_pct < c_demog_pct)) then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'data_quality_coverage',
      'reason', format('coverage is adequate: %s bps of revenue classified, %s%% of customers '
                        'demographically resolved', coalesce(v_classified_bps::text, 'null'),
                        coalesce(v_demog_pct::text, 'null'))));
  else
    v_cands := v_cands || jsonb_build_array(jsonb_build_object(
      'id', 'data_quality_coverage',
      'domain', 'data_quality',
      'pattern', format(
        'Only %s%% of revenue is classified to a category and only %s%% of %s active customers '
        'have a resolved age and gender — every category, cohort and mix finding below is drawn '
        'from that fraction.',
        case when v_classified_bps is null then 'an unknown share of'
             else round(v_classified_bps / 100.0, 1)::text end,
        coalesce(v_demog_pct::text, 'an unknown share of'), v_identified),
      'comparison', jsonb_build_object(
        'kind', 'threshold',
        'detail', format('classified revenue coverage %s bps against %s bps, and demographic '
                          'coverage %s%% against %s%%',
                          coalesce(v_classified_bps::text, 'null'), c_classified_bps,
                          coalesce(v_demog_pct::text, 'null'), c_demog_pct)),
      'impact', jsonb_build_object(
        'cents', null,
        'reason', 'a coverage defect has no revenue figure of its own; what it does is put an '
                  'error bar on every figure above it'),
      'action', jsonb_build_object(
        'who', 'the owner, once, then front desk on an ongoing basis',
        'what', 'Map every service and product to a category in Settings, and capture date of '
                'birth and gender at the point a customer is created rather than retrospectively. '
                'Do this BEFORE acting on any category or cohort finding in this list.',
        'when', 'before the next review',
        'channel', 'settings_and_checkout'),
      'evidence', jsonb_build_object(
        'source_rpc', 'public.get_ci_category_mix_v1 + public.get_ci_demographics_v1',
        'refs', jsonb_build_object(
          'category_coverage', v_catmix->'coverage',
          'demographic_coverage', v_demog->'coverage'->'demographics',
          'unclassified_customers', v_demog->'unclassified',
          'classified_bar_bps', c_classified_bps,
          'demographic_bar_pct', c_demog_pct)),
      'evidence_class', 'DIRECT_FACT',
      'confidence', v_conf,
      'limitation',
        'Coverage is not accuracy: fully classified revenue can still be classified wrongly, and '
        'this says nothing about whether the mapped categories are the right ones.',
      'rank_class', 'foundation'));
  end if;

  -- =============================================================================================
  -- THE FLOOR SWEEP · a tripwire, not a crutch.
  -- =============================================================================================
  v_abst := v_abst || coalesce((
    select jsonb_agg(jsonb_build_object(
             'generator', c->>'id', 'reason', 'below_evidence_floor'))
      from jsonb_array_elements(v_cands) c
     where c->'confidence'->>'status' is distinct from 'ok'), '[]'::jsonb);

  select coalesce(jsonb_agg(x.c || jsonb_build_object('rank', x.rn) order by x.rn), '[]'::jsonb)
    into v_ranked
    from (
      select c,
             row_number() over (
               order by case c->>'rank_class'
                          when 'foundation' then 0
                          when 'quantified' then 1
                          else 2 end,
                        coalesce((c->'impact'->>'cents')::bigint, 0) desc,
                        c->>'domain', c->>'id') as rn
        from jsonb_array_elements(v_cands) c
       where c->'confidence'->>'status' = 'ok'
    ) x;

  v_promoted := coalesce(jsonb_array_length(v_ranked), 0);

  -- =============================================================================================
  -- THE DO-NOTHING OUTCOME · a ranked result in its own right (check 72)
  -- =============================================================================================
  if v_promoted = 0 then
    v_ranked := jsonb_build_array(jsonb_build_object(
      'id', 'do_nothing',
      'domain', 'none',
      'pattern', 'No opportunity clears the evidence bar',
      'comparison', jsonb_build_object(
        'kind', 'threshold',
        'detail', format('all %s candidate evaluation(s) were made and every one abstained; the '
                          'reasons are listed under "abstentions"', v_examined)),
      'impact', jsonb_build_object(
        'cents', null,
        'reason', 'nothing is being recommended, so there is nothing to value'),
      'action', jsonb_build_object(
        'who', 'the consultant',
        'what', 'Take no action from this analysis. If a recommendation is wanted, the constraint '
                'is evidence, not effort: read the abstention reasons and fix whichever one is '
                'cheapest to clear (usually volume, coverage, or consent capture).',
        'when', 'revisit at the next review',
        'channel', 'none'),
      'evidence', jsonb_build_object(
        'source_rpc', 'public.get_ci_funnel_conversion_v1, public.get_ci_daypart_v1, '
                      'public.get_ci_category_mix_v1, public.get_ci_service_intelligence_v1, '
                      'public.get_ci_package_intelligence_v1, public.get_ci_contactability_v1, '
                      'public.get_ci_demographics_v1, app.customer_cadence_v1',
        'refs', jsonb_build_object(
          'candidates_examined', v_examined,
          'candidates_promoted', 0,
          'abstentions', v_abst)),
      'evidence_class', 'DIRECT_FACT',
      'confidence', app.subgroup_evidence_v1(0),
      'limitation',
        '"No opportunity" is a statement about what this period''s data can support, not a finding '
        'that the business has none — a thin window and a healthy business look identical here.',
      'rank_class', 'do_nothing',
      'rank', 1));
  end if;

  -- =============================================================================================
  -- FRESHNESS (check 97) — observed_since_min across the six re-emitted sub-readers this engine
  -- consumes and that carry the field, and a stale-evidence refusal that overrides ranking.
  -- =============================================================================================
  select min(x) into v_obs_min
    from (values
      ((v_funnel->>'observed_since')::timestamptz),
      ((v_daypart->>'observed_since')::timestamptz),
      ((v_svc->>'observed_since')::timestamptz),
      ((v_pkg->>'observed_since')::timestamptz),
      ((v_catmix->>'observed_since')::timestamptz),
      ((v_demog->>'observed_since')::timestamptz)
    ) as t(x)
   where x is not null;

  v_period_far := p_to < (p_as_of at time zone 'Asia/Singapore')::date - c_stale_period_days;
  v_stale := v_obs_min is not null and p_as_of - v_obs_min > make_interval(days => c_stale_days);

  if v_stale then
    v_refusal := 'stale_evidence';
    v_ranked := jsonb_build_array(jsonb_build_object(
      'id', 'do_nothing',
      'domain', 'none',
      'pattern', 'No opportunity is ranked: the evidence behind this analysis is stale.',
      'comparison', jsonb_build_object(
        'kind', 'threshold',
        'detail', format(
          'observed_since_min=%s, as_of=%s — stale when as_of is more than %s days past '
          'observed_since_min (period_far_from_as_of=%s is disclosed but does not itself refuse)',
          v_obs_min, p_as_of, c_stale_days, v_period_far)),
      'impact', jsonb_build_object(
        'cents', null,
        'reason', 'ranking is refused on stale evidence, so there is nothing to value'),
      'action', jsonb_build_object(
        'who', 'the consultant',
        'what', 'Refresh the underlying data (or request a more recent period) before ranking — '
                'acting on this analysis without doing so risks acting on facts that are no '
                'longer true.',
        'when', 'before the next review',
        'channel', 'none'),
      'evidence', jsonb_build_object(
        'source_rpc', 'public.get_ci_opportunities_v1',
        'refs', jsonb_build_object(
          'observed_since_min', v_obs_min, 'as_of', p_as_of, 'period_to', p_to,
          'period_far_from_as_of', v_period_far, 'stale_days_bar', c_stale_days)),
      'evidence_class', 'DIRECT_FACT',
      'confidence', app.subgroup_evidence_v1(0),
      'limitation',
        'Staleness is a statement about data freshness, not about whether opportunities exist.',
      'rank_class', 'do_nothing',
      'rank', 1));
    v_promoted := 0;
  else
    v_refusal := null;
  end if;

  -- =============================================================================================
  -- NESTLY v696 (check 17, spine half) — impact_class, additive only. Base-pass impact never
  -- carries an expected_value (that concept starts in extended mode), so the only two reachable
  -- states here are 'scenario' (impact.cents states a figure) and 'none' (it does not). No
  -- literal evidence_class is touched anywhere in this function; app.ci_verdict_class_v696 is
  -- checked against those literals by db/tests/executed/v696_corpus_spine_verdicts.sql, never
  -- substituted into this body, so v678/v680/v688's byte-identical assertions cannot regress.
  -- =============================================================================================
  select coalesce(jsonb_agg(
           t.c || jsonb_build_object('impact',
             (t.c->'impact') || jsonb_build_object('impact_class',
               case when (t.c->'impact'->'expected_value'->>'cents') is not null
                      then 'expected_value'
                    when (t.c->'impact'->>'cents') is not null then 'scenario'
                    else 'none' end))
           order by t.ord), '[]'::jsonb)
    into v_ranked
    from jsonb_array_elements(v_ranked) with ordinality as t(c, ord);

  -- =============================================================================================
  -- THE BASE (v680-identical) RESULT. Non-extended callers stop here.
  -- =============================================================================================
  v_result := jsonb_build_object(
    'contract', 'ci_opportunities_v1',
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                 'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'ranked', v_ranked,
    'abstentions', v_abst,
    'comparisons', app.comparisons_note_v1(v_examined, v_promoted),
    'freshness', jsonb_build_object(
      'observed_since_min', v_obs_min,
      'generated_at', clock_timestamp(),
      'stale', v_stale,
      'period_far_from_as_of', v_period_far),
    'refusal_reason', v_refusal,
    'observed_since', app.metric_observed_since_v1('ci_opportunities', p_business),
    'verdict_policy', jsonb_build_object(
      'classes', jsonb_build_array('DIRECT_FACT', 'ASSOCIATION'),
      'causal_claims', 'never'));

  if not p_extended or v_stale then
    -- a stale-evidence refusal is a full-stop in both modes: nothing more to enrich.
    if p_extended then
      v_result := v_result || jsonb_build_object(
        'report_sections', jsonb_build_object(
          'strengths', '[]'::jsonb, 'failures', '[]'::jsonb, 'leakage', '[]'::jsonb,
          'margin', jsonb_build_object('status', 'unavailable',
            'reason', 'no COGS/cost-of-goods field on services or sales in this schema'),
          'unnoticed_behaviour', '[]'::jsonb, 'segments', '[]'::jsonb, 'change', '[]'::jsonb),
        'top_actions', (select coalesce(jsonb_agg(e), '[]'::jsonb)
                          from jsonb_array_elements(v_ranked) e limit 5));
    end if;
    return app.ci_envelope_v680('ci_opportunities_v1', p_business, p_branch, p_from, p_to,
      p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
  end if;

  -- =============================================================================================
  -- EXTENDED MODE STARTS HERE. Nothing above this point behaves differently because of it.
  -- =============================================================================================
  v_has_v683 := to_regprocedure('public.get_ci_discount_dependency_v1(uuid,date,date,uuid,timestamptz)') is not null
            and to_regprocedure('public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid)') is not null
            and to_regprocedure('public.get_ci_staff_performance_v1(uuid,date,date,uuid,timestamptz)') is not null;

  select coalesce(sum(s.amount_cents), 0) into v_period_revenue
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
   where s.business_id = p_business
     and (p_branch is null or s.branch_id = p_branch)
     and sc.include_revenue
     and not sc.is_synthetic_client
     and s.created_at <= p_as_of
     and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to;
  v_ev_bar := round(v_period_revenue * c_ev_materiality_pct / 100.0);

  -- NESTLY v705 — computed ONCE, reused by the generic per-candidate enrichment pass below (JC2/JC3
  -- in this migration's header): a capacity snapshot does not vary per candidate, and the only
  -- candidate whose incentive is itself a spend (loyalty_cannibalisation_gap) names no specific
  -- service, so its margin guard call is a single constant, not a per-candidate lookup.
  v_capacity := app.ci_capacity_v705(p_business, p_branch, p_from, p_to);
  v_top_skew := v_top is not null
                and coalesce((v_top->'distribution'->>'skew_material')::boolean, false);
  v_margin_guard_cannibal := app.ci_margin_guard_v705(p_business, null, 0);

  -- ---------------------------------------------------------------------------------------
  -- EV for lapsed_regulars (check 73): re-derive the overdue+ticket population (same query as
  -- generator B — p_branch is already known null here, since generator B itself only ever runs
  -- firm-wide) and score each with app.return_probability_v681.
  -- ---------------------------------------------------------------------------------------
  v_ev_lapsed_cents := 0;
  v_ev_lapsed_abst := 0;
  if p_branch is null then
    for v_dsc in
      with overdue as materialized (
        select b.client_id
          from app.customer_cadence_batch_v1(
                 p_business,
                 ((p_as_of at time zone 'Asia/Singapore')::date + 1),
                 ((p_as_of at time zone 'Asia/Singapore')::date + 1),
                 p_as_of, null, true) b
          join public.clients cli on cli.id = b.client_id and cli.business_id = p_business
          cross join lateral (select app.customer_cadence_v1(p_business, b.client_id) as cad) c
         where c.cad->>'deviation_state' = 'overdue'
           and c.cad->>'evidence_source' = 'customer_median_interval'
           and not cli.is_synthetic
      ),
      tickets as (
        select o.client_id,
               round(sum(s.amount_cents)::numeric / count(*)) as avg_ticket
          from overdue o
          join public.sales s
            on s.business_id = p_business
           and app.v111_effective_client_id(s.business_id, s.client_id) = o.client_id
          cross join lateral app.analytics_sale_class_v1(s) sc
         where sc.include_revenue and not sc.is_synthetic_client and s.created_at <= p_as_of
         group by o.client_id
      )
      select o.client_id, coalesce(t.avg_ticket, 0) as avg_ticket
        from overdue o left join tickets t on t.client_id = o.client_id
    loop
      v_ev := app.return_probability_v681(p_business, v_dsc.client_id, p_as_of);
      if v_ev->>'status' = 'ready' then
        v_ev_lapsed_cents := v_ev_lapsed_cents
          + round((v_ev->>'probability')::numeric * v_dsc.avg_ticket)::bigint;
      else
        v_ev_lapsed_abst := v_ev_lapsed_abst + 1;
      end if;
    end loop;
  end if;

  -- ---------------------------------------------------------------------------------------
  -- Build the extended candidate set: enrich the ORIGINAL (base-pass) candidates, then append
  -- the new generator classes, THEN apply the materiality gate, THEN re-rank.
  -- ---------------------------------------------------------------------------------------
  -- NESTLY v705 (check 77) — computed ONCE, reused by every 'cadence' candidate below rather than
  -- re-queried per candidate.
  v_rebooking := public.get_ci_rebooking_v1(p_business, p_from, p_to, null);

  for v_c in select c from jsonb_array_elements(v_cands) c loop
    v_id := v_c->>'id';
    v_domain := v_c->>'domain';

    -- incentive + why_now + reversal_condition + alternatives, per domain
    if v_domain = 'retention_funnel' then
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format(
        'The %s-day maturity window for this cohort has already fully elapsed as of %s; every '
        'day the %s step goes unaddressed carries the same gap into the next cohort.',
        c_funnel_window, p_to, replace(v_f_stage, '_', '-'));
      v_reversal := format(
        'Reconsider this call if the stage gap narrows to under %s points over one more full '
        '%s-day cycle.', c_gap_pp, c_funnel_window);
    elsif v_domain = 'cadence' then
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format(
        '%s customers are already overdue against their OWN rhythm as of %s; the longer the gap '
        'runs past their personal median interval, the more likely they re-anchor elsewhere.',
        v_lapsed_n, p_as_of::date);
      v_reversal := format(
        'Reconsider this call if fewer than half of these %s overdue customers return within 60 '
        'days of being contacted.', v_lapsed_n);
    elsif v_domain = 'daypart' then
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format(
        '%s is already %sx more valuable per visit than %s as of %s; every rota cycle left '
        'unchanged trades a %s-value slot for a %s-value one.',
        v_valuable->>'label',
        round((v_hi->>'revenue_per_visit_cents')::numeric
              / nullif((v_lo->>'revenue_per_visit_cents')::numeric, 0), 1),
        v_busiest->>'label', p_to, v_valuable->>'label', v_busiest->>'label');
      v_reversal := format(
        'Reconsider this call if the ratio between the two weekdays falls under %sx.',
        c_daypart_ratio);
    elsif v_domain = 'category_mix' then
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format(
        'The top category already holds %s bps of classified revenue as of %s; a single '
        'disruption there removes %s cents from the period in one stroke.',
        v_share_bps, p_to, v_top->>'revenue_cents');
      v_reversal := format(
        'Reconsider this call if the top category''s share falls under %s bps of classified '
        'revenue.', c_conc_bps);
    elsif v_domain = 'packages' then
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format(
        '%s cents of prepaid sessions on "%s" are already unused as of %s; every day past the '
        'holder''s own usage rhythm shortens the runway before expiry forfeits them.',
        (v_c->'impact'->>'cents'), v_c->'evidence'->'refs'->>'plan_name', p_to);
      v_reversal := format(
        'Reconsider this call if utilisation rises to %s%% or above.', c_util_pct);
    elsif v_domain = 'service_intelligence' then
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format(
        '%s%% of this service''s buyers already fail to return, %s points behind the firm''s '
        '%s%% baseline as of %s.', v_c->'evidence'->'refs'->'repeat_rate'->>'pct',
        round(v_f_p1 - (v_c->'evidence'->'refs'->'repeat_rate'->>'pct')::numeric, 1),
        v_f_p1, p_to);
      v_reversal := format(
        'Reconsider this call if the repeat rate closes to within %s points of the firm''s %s%%.',
        c_gap_pp, v_f_p1);
    elsif v_domain = 'contactability' then
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format(
        'Only %s%% of customers are lawfully reachable as of %s; every new customer added '
        'without capturing consent widens this gap.',
        round(100.0 * coalesce(v_best, 0) / nullif(v_customers, 0), 1), p_to);
      v_reversal := format(
        'Reconsider this call once the best-channel reachable share reaches %s%%.', c_reach_pct);
    elsif v_domain = 'data_quality' then
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format(
        '%s bps of revenue remain unclassified as of %s; every day of new sales without mapping '
        'compounds the blind spot beneath every other finding here.',
        10000 - coalesce(v_classified_bps, 0), p_to);
      v_reversal := format(
        'Reconsider this call once classified revenue reaches %s bps AND demographic coverage '
        'reaches %s%%.', c_classified_bps, c_demog_pct);
    else
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format('As of %s, this pattern still holds in the current period.', p_to);
      v_reversal := 'Reconsider this call once the underlying numbers change materially.';
    end if;

    v_cost_basis := case when v_incentive->>'kind' = 'none'
      then jsonb_build_object('status', 'declared', 'cents', 0,
             'note', 'a reminder/operational action carries no incentive spend')
      else c_incentive_unavailable end;

    v_alternatives := case
      when v_domain = 'service_intelligence' then
        jsonb_build_array(
          jsonb_build_object('kind', 'reminder_only', 'primary', true,
            'what', 'Contact without any discount or credit.',
            'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
          jsonb_build_object('kind', 'service_recovery', 'primary', false,
            'what', 'Re-run the first-visit experience for a sample of recent buyers at no charge '
                    'to find what is actually going wrong before spending on acquisition.',
            'cost_basis', c_incentive_unavailable),
          jsonb_build_object('kind', 'incentive', 'primary', false,
            'what', 'Offer a discount or loyalty credit to prompt a second visit.',
            -- NESTLY v718 (check 74) — gateway_followthrough is the only base-generator candidate
            -- that names a real public.services.id (embedded in its own id); resolve the guard for
            -- real instead of the static c_incentive_unavailable fallback. The guard result is
            -- merged with the standard incentive figure it was scored against (refuter finding 2)
            -- so every branch (blocked/ok/unavailable) discloses it structurally, not only inside
            -- blocked-case prose.
            'cost_basis', case when v_id like 'gateway_followthrough:%' then
              app.ci_margin_guard_v705(p_business,
                nullif(split_part(v_id, ':', 2), '')::uuid,
                app.ci_standard_incentive_cents_v718())
              || jsonb_build_object('assumed_incentive_cents', app.ci_standard_incentive_cents_v718(),
                   'assumption', 'Scored against the standard proposed incentive amount, not this candidate''s own declared spend.')
            else c_incentive_unavailable end))
      when v_domain = 'daypart' then
        jsonb_build_array(
          jsonb_build_object('kind', 'reminder_only', 'primary', true,
            'what', 'Contact without any discount or credit.',
            'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
          jsonb_build_object('kind', 'incentive', 'primary', false,
            'what', 'Offer a discount or loyalty credit to prompt action.',
            'cost_basis', c_incentive_unavailable),
          jsonb_build_object('kind', 'operational_change', 'primary', false,
            'what', format('Re-staff the rota toward %s and pull promotion away from %s — no '
                            'incentive spend, just where the labour and marketing hours go.',
                            v_valuable->>'label', v_busiest->>'label'),
            'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0,
              'note', 'operational, no incentive spend')))
      when v_domain = 'cadence'
           and (v_rebooking->'cohorts'->'rebooked_at_departure'->'evidence'->>'status') = 'ok'
           and (v_rebooking->'cohorts'->'rebooked_at_departure'->'within_window'->>'pct') is not null
      then
        jsonb_build_array(
          jsonb_build_object('kind', 'reminder_only', 'primary', true,
            'what', 'Contact without any discount or credit.',
            'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
          jsonb_build_object('kind', 'incentive', 'primary', false,
            'what', 'Offer a discount or loyalty credit to prompt action.',
            'cost_basis', c_incentive_unavailable),
          jsonb_build_object('kind', 'rebooking', 'primary', false,
            'what', format('Book the next visit before the customer leaves — the rebooked-at-'
                            'departure cohort''s within-window return rate is %s%% (n=%s) against '
                            '%s%% for everyone else.',
                            v_rebooking->'cohorts'->'rebooked_at_departure'->'within_window'->>'pct',
                            v_rebooking->'cohorts'->'rebooked_at_departure'->>'n',
                            v_rebooking->'cohorts'->'other'->'within_window'->>'pct'),
            'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0,
              'note', 'operational, no incentive spend')))
      else
        jsonb_build_array(
          jsonb_build_object('kind', 'reminder_only', 'primary', true,
            'what', 'Contact without any discount or credit.',
            'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
          jsonb_build_object('kind', 'incentive', 'primary', false,
            'what', 'Offer a discount or loyalty credit to prompt action.',
            'cost_basis', c_incentive_unavailable))
      end;

    -- expected value: only lapsed_regulars and package_leakage:* carry a behavioural model
    if v_id = 'lapsed_regulars' then
      v_ev := jsonb_build_object(
        'cents', v_ev_lapsed_cents,
        'method', 'sum over overdue regulars of app.return_probability_v681(business, client, '
                  'as_of).probability * that customer''s own average ticket; a customer on which '
                  'the model itself abstains contributes 0 and is counted in inputs.abstained',
        'inputs', jsonb_build_object('scored', v_lapsed_n - v_ev_lapsed_abst,
                                      'abstained', v_ev_lapsed_abst));
    elsif v_domain = 'packages' then
      select coalesce(sum(
               cp.remaining
               * (v_c->'evidence'->'refs'->>'per_session_cents')::bigint
               * coalesce((app.return_probability_v681(p_business, cp.client_id, p_as_of)
                            ->>'probability')::numeric, 0)), 0)::bigint,
             count(*) filter (where (app.return_probability_v681(p_business, cp.client_id, p_as_of)
                                       ->>'status') <> 'ready')
        into v_ev_pkg_cents, v_ev_pkg_abst
        from public.client_packages cp
        join public.clients c2 on c2.id = cp.client_id
       where cp.plan_id = (v_c->'evidence'->'refs'->>'plan_id')::uuid
         and cp.business_id = p_business
         and not coalesce(c2.is_synthetic, false)
         and cp.remaining > 0
         and (cp.purchased_at at time zone 'Asia/Singapore')::date between p_from and p_to;
      v_ev := jsonb_build_object(
        'cents', round(v_ev_pkg_cents),
        'method', 'sum over the plan''s in-window holders with sessions remaining of '
                  'remaining_sessions * per_session_cents * app.return_probability_v681(business, '
                  'holder, as_of).probability; a holder on which the model abstains contributes 0 '
                  'and is counted in inputs.abstained',
        'inputs', jsonb_build_object('abstained', v_ev_pkg_abst));
    else
      v_ev := jsonb_build_object('status', 'unavailable',
        'reason', 'no behavioural model backs this candidate''s pattern');
    end if;

    v_impact := (v_c->'impact') || jsonb_build_object(
      'scenario_cents', v_c->'impact'->'cents', 'expected_value', v_ev);

    v_cands_ext := v_cands_ext || jsonb_build_array(
      v_c || jsonb_build_object(
        'impact', v_impact, 'incentive', v_incentive, 'why_now', v_why_now,
        'reversal_condition', v_reversal, 'alternatives', v_alternatives,
        'cost_basis', v_cost_basis));
  end loop;
  v_examined_ext := v_examined;

  -- ---------------------------------------------------------------------------------------
  -- NEW GENERATOR · discovery (check 22/79): one candidate per REPLICATED discovery
  -- ---------------------------------------------------------------------------------------
  -- get_ci_discovery_v1 needs a period wide enough to split into two non-empty halves (it raises
  -- 22023 otherwise, by its own design). A caller asking a single-day/short-window question of
  -- this engine (a real, legitimate call shape) gets an honest abstention here instead of an
  -- unhandled exception surfacing from a sub-reader it never asked for by name.
  v_examined_ext := v_examined_ext + 1;
  if (p_to - p_from) < 2 then
    v_discovery := null;
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'discovery',
      'reason', 'the requested period is too short to split into a train and a holdout half'));
  else
    v_discovery := public.get_ci_discovery_v1(p_business, p_from, p_to, p_branch);
  end if;
  for v_dsc in select e.value as d from jsonb_array_elements(coalesce(v_discovery->'discoveries','[]'::jsonb)) e loop
    v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
      'id', 'discovery:' || (v_dsc.d->>'dimension') || ':' || (v_dsc.d->>'group'),
      'domain', 'discovery',
      'pattern', format('The "%s" segment in dimension "%s" differs from the rest by %s points '
                         '(train %s%%, n=%s), and the direction replicated on unseen holdout data.',
                         v_dsc.d->>'group', v_dsc.d->>'dimension', v_dsc.d->>'diff_pp',
                         v_dsc.d->'train'->>'rate', v_dsc.d->'train'->>'n'),
      'comparison', jsonb_build_object('kind', 'cross_segment',
        'detail', format('train vs rest diff %s pp; holdout n=%s, rate %s%%',
                          v_dsc.d->>'diff_pp', v_dsc.d->'holdout'->>'n', v_dsc.d->'holdout'->>'rate')),
      'impact', jsonb_build_object('cents', null, 'reason',
        'an association, not an incremental model: no assumed uplift is smuggled in',
        'scenario_cents', null,
        'expected_value', jsonb_build_object('status', 'unavailable',
          'reason', 'no behavioural model backs a discovered association')),
      'action', jsonb_build_object('who', 'the owner', 'what',
        format('Look at "%s" (%s) specifically: something about this group already behaves '
               'differently and it held up on later data.', v_dsc.d->>'group', v_dsc.d->>'dimension'),
        'when', 'this review cycle', 'channel', 'analysis'),
      'incentive', jsonb_build_object('kind', 'none', 'declared', true),
      'why_now', format('The pattern already replicated on holdout data as of %s; the longer it '
                         'goes unexamined the more the underlying cause compounds.', p_to),
      'reversal_condition', format('Reconsider this call if the difference falls back under %s '
                                    'points on the next holdout split.', v_dsc.d->>'diff_pp'),
      -- NESTLY v718 (check 77) — a second, non-primary, non-incentive alternative kind, reusing the
      -- candidate's own dimension/group (nothing invented).
      'alternatives', jsonb_build_array(
        jsonb_build_object('kind', 'reminder_only', 'primary', true,
          'what', 'Note it and monitor, no spend.',
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
        jsonb_build_object('kind', 'operational_change', 'primary', false,
          'what', format('Investigate the driver behind %s=%s before acting.',
                          v_dsc.d->>'dimension', v_dsc.d->>'group'),
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0,
            'note', 'operational, no incentive spend'))),
      'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'observation only'),
      'evidence', jsonb_build_object('source_rpc', 'public.get_ci_discovery_v1', 'refs', v_dsc.d),
      'evidence_class', 'ASSOCIATION',
      'confidence', app.subgroup_evidence_v1((v_dsc.d->'train'->>'n')::int),
      'limitation', 'A discovered association is not a cause; predefined dimensions were scanned '
                    'and this one survived false-discovery control and holdout replication.',
      'rank_class', 'unquantified'));
  end loop;

  -- ---------------------------------------------------------------------------------------
  -- NEW GENERATOR · change (check 22/79): one candidate per deteriorating cell
  -- ---------------------------------------------------------------------------------------
  v_examined_ext := v_examined_ext + 1;
  for v_dsc in select e.value as d from jsonb_array_elements(coalesce(v_discovery->'deteriorating','[]'::jsonb)) e loop
    v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
      'id', 'change:' || (v_dsc.d->>'dimension') || ':' || (v_dsc.d->>'group'),
      'domain', 'change',
      'pattern', format('"%s" (%s) fell from %s%% in the first half of the period to %s%% in the '
                         'second, a drop of %s points.', v_dsc.d->>'group', v_dsc.d->>'dimension',
                         v_dsc.d->'train'->>'rate', v_dsc.d->'holdout'->>'rate', v_dsc.d->>'diff_pp'),
      'comparison', jsonb_build_object('kind', 'baseline',
        'detail', format('this group''s own train rate (n=%s) against its own holdout rate (n=%s)',
                          v_dsc.d->'train'->>'n', v_dsc.d->'holdout'->>'n')),
      'impact', jsonb_build_object('cents', null, 'reason',
        'no incremental model: a rate decline is not a cash figure without an assumed baseline',
        'scenario_cents', null,
        'expected_value', jsonb_build_object('status', 'unavailable',
          'reason', 'no behavioural model backs a deteriorating cell')),
      'action', jsonb_build_object('who', 'the owner', 'what',
        format('Find out what changed for "%s" between the two halves of the period before it '
               'compounds further.', v_dsc.d->>'group'),
        'when', 'this review cycle', 'channel', 'analysis'),
      'incentive', jsonb_build_object('kind', 'none', 'declared', true),
      'why_now', format('This segment''s own rate has already fallen %s points as of %s.',
                         v_dsc.d->>'diff_pp', p_to),
      'reversal_condition', format('Reconsider this call if the holdout-half rate recovers to '
                                    'within %s points of the train-half rate.', v_dsc.d->>'diff_pp'),
      -- NESTLY v718 (check 77) — a second, non-primary, non-incentive alternative kind. Deliberately
      -- 'operational_change' rather than 'service_recovery': 'change' fires on ANY of five
      -- segment_dimensions (weekday/age_gender/category_node/acquisition_source/branch), most of
      -- which are not service-shaped, so implying a specific service failed would be a fabricated
      -- implication for e.g. a weekday or branch deterioration (see this migration's own header).
      'alternatives', jsonb_build_array(
        jsonb_build_object('kind', 'reminder_only', 'primary', true,
          'what', 'Note it and monitor, no spend.',
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
        jsonb_build_object('kind', 'operational_change', 'primary', false,
          'what', format('Review what changed for %s in the window.', v_dsc.d->>'dimension'),
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0,
            'note', 'operational, no incentive spend'))),
      'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'observation only'),
      'evidence', jsonb_build_object('source_rpc', 'public.get_ci_discovery_v1', 'refs', v_dsc.d),
      'evidence_class', 'ASSOCIATION',
      'confidence', app.subgroup_evidence_v1(least((v_dsc.d->'train'->>'n')::int,
                                                    (v_dsc.d->'holdout'->>'n')::int)),
      'limitation', 'Deterioration is measured on the same self-selected group across halves of '
                    'one period; it is not validated against an independent cause.',
      'rank_class', 'unquantified'));
  end loop;

  -- ---------------------------------------------------------------------------------------
  -- NEW GENERATOR · strength (check 22/79): top evidence-ok weekday / category / service,
  -- ranked strictly after every opportunity (rank_class 'strength').
  -- ---------------------------------------------------------------------------------------
  v_examined_ext := v_examined_ext + 3;
  v_top_weekday := v_hi;
  select c into v_top_category
    from jsonb_array_elements(coalesce(v_catmix->'categories', '[]'::jsonb)) c
   order by (c->>'revenue_cents')::bigint desc, c->>'node_key' limit 1;
  select s into v_top_service
    from jsonb_array_elements(coalesce(v_svc->'services', '[]'::jsonb)) s
   where s->'evidence'->>'status' = 'ok'
   order by (s->>'revenue_cents')::bigint desc, s->>'service_id' limit 1;

  if v_top_weekday is not null then
    v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
      'id', 'strength:weekday:' || (v_top_weekday->>'dow'),
      'domain', 'strength',
      'pattern', format('%s already returns %s cents per visit, the strongest weekday measured.',
                         v_top_weekday->>'label', v_top_weekday->>'revenue_per_visit_cents'),
      'comparison', jsonb_build_object('kind', 'threshold',
        'detail', 'evidence-ok weekday with the highest revenue per visit in the window'),
      'impact', jsonb_build_object('cents', null, 'reason', 'a strength is not a gap to close',
        'scenario_cents', null,
        'expected_value', jsonb_build_object('status', 'unavailable',
          'reason', 'strengths are descriptive, not a prediction')),
      'action', jsonb_build_object('who', 'the owner', 'what',
        format('Protect %s: staff it reliably and do not let it silently drift.', v_top_weekday->>'label'),
        'when', 'ongoing', 'channel', 'rota'),
      'incentive', jsonb_build_object('kind', 'none', 'declared', true),
      'why_now', format('As of %s this remains the strongest weekday measured.', p_to),
      'reversal_condition', format('Reconsider this call if revenue per visit on %s falls under '
        '%s cents.', v_top_weekday->>'label', v_top_weekday->>'revenue_per_visit_cents'),
      'alternatives', jsonb_build_array(
        jsonb_build_object('kind', 'no_action', 'primary', true,
          'what', 'keep doing this; nothing to change',
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
        jsonb_build_object('kind', 'reminder_only', 'primary', false,
          'what', 'No action needed beyond monitoring.',
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend'))),
      'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'observation only'),
      'evidence', jsonb_build_object('source_rpc', 'public.get_ci_daypart_v1', 'refs', v_top_weekday),
      'evidence_class', 'DIRECT_FACT',
      'confidence', app.subgroup_evidence_v1((v_top_weekday->>'visits')::int),
      'limitation', 'A strength today is not a guarantee it persists.',
      'rank_class', 'strength'));
  end if;

  if v_top_category is not null then
    v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
      'id', 'strength:category:' || (v_top_category->>'node_key'),
      'domain', 'strength',
      'pattern', format('%s already leads all classified categories at %s cents of revenue.',
        coalesce(v_top_category->>'label', v_top_category->>'node_key'), v_top_category->>'revenue_cents'),
      'comparison', jsonb_build_object('kind', 'threshold', 'detail', 'top classified category by revenue'),
      'impact', jsonb_build_object('cents', null, 'reason', 'a strength is not a gap to close',
        'scenario_cents', null,
        'expected_value', jsonb_build_object('status', 'unavailable',
          'reason', 'strengths are descriptive, not a prediction')),
      'action', jsonb_build_object('who', 'the owner', 'what',
        format('Keep %s well stocked and staffed; it already carries the mix.',
               coalesce(v_top_category->>'label', v_top_category->>'node_key')),
        'when', 'ongoing', 'channel', 'planning'),
      'incentive', jsonb_build_object('kind', 'none', 'declared', true),
      'why_now', format('As of %s this remains the top classified category.', p_to),
      'reversal_condition', format('Reconsider this call if its revenue falls under %s cents.',
        v_top_category->>'revenue_cents'),
      'alternatives', jsonb_build_array(
        jsonb_build_object('kind', 'no_action', 'primary', true,
          'what', 'keep doing this; nothing to change',
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
        jsonb_build_object('kind', 'reminder_only', 'primary', false,
          'what', 'No action needed beyond monitoring.',
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend'))),
      'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'observation only'),
      'evidence', jsonb_build_object('source_rpc', 'public.get_ci_category_mix_v1', 'refs', v_top_category),
      'evidence_class', 'DIRECT_FACT',
      'confidence', app.subgroup_evidence_v1((v_top_category->>'customer_count')::int),
      'limitation', 'A strength today is not a guarantee it persists.',
      'rank_class', 'strength'));
  end if;

  if v_top_service is not null then
    v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
      'id', 'strength:service:' || (v_top_service->>'service_id'),
      'domain', 'strength',
      'pattern', format('"%s" already leads all services at %s cents of revenue.',
        v_top_service->>'service_name', v_top_service->>'revenue_cents'),
      'comparison', jsonb_build_object('kind', 'threshold', 'detail', 'top evidence-ok service by revenue'),
      'impact', jsonb_build_object('cents', null, 'reason', 'a strength is not a gap to close',
        'scenario_cents', null,
        'expected_value', jsonb_build_object('status', 'unavailable',
          'reason', 'strengths are descriptive, not a prediction')),
      'action', jsonb_build_object('who', 'the owner', 'what',
        format('Protect "%s": keep it staffed and do not let quality drift.', v_top_service->>'service_name'),
        'when', 'ongoing', 'channel', 'planning'),
      'incentive', jsonb_build_object('kind', 'none', 'declared', true),
      'why_now', format('As of %s this remains the top-performing service.', p_to),
      'reversal_condition', format('Reconsider this call if its revenue falls under %s cents.',
        v_top_service->>'revenue_cents'),
      'alternatives', jsonb_build_array(
        jsonb_build_object('kind', 'no_action', 'primary', true,
          'what', 'keep doing this; nothing to change',
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
        jsonb_build_object('kind', 'reminder_only', 'primary', false,
          'what', 'No action needed beyond monitoring.',
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend'))),
      'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'observation only'),
      'evidence', jsonb_build_object('source_rpc', 'public.get_ci_service_intelligence_v1', 'refs', v_top_service),
      'evidence_class', 'DIRECT_FACT',
      'confidence', app.subgroup_evidence_v1((v_top_service->>'buyers')::int),
      'limitation', 'A strength today is not a guarantee it persists.',
      'rank_class', 'strength'));
  end if;

  -- ---------------------------------------------------------------------------------------
  -- v683-GATED GENERATORS (present in this tree — checked, not assumed)
  -- ---------------------------------------------------------------------------------------
  if v_has_v683 and p_branch is null then
    v_examined_ext := v_examined_ext + 1;
    v_discount_dep := public.get_ci_discount_dependency_v1(p_business, p_from, p_to, null);
    v_reminder_n := coalesce(jsonb_array_length(v_discount_dep->'reminder_only_candidates'->'candidates'), 0);
    if v_discount_dep->'reminder_only_candidates'->'suppressed' is not null then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'no_discount_reminder',
        'reason', 'below_evidence_floor: ' ||
          coalesce(v_discount_dep->'reminder_only_candidates'->'suppressed'->>'reason', '')));
    elsif v_reminder_n = 0 then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'no_discount_reminder',
        'reason', 'no organic returner is currently overdue'));
    else
      v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
        'id', 'no_discount_reminder',
        'domain', 'discount_dependency',
        'pattern', format('%s organic returners (never discount-dependent) are overdue right now; '
                           'they do not need an incentive to come back, only a reminder.', v_reminder_n),
        'comparison', jsonb_build_object('kind', 'threshold',
          'detail', format('%s organic-class customers overdue against their own cadence', v_reminder_n)),
        'impact', jsonb_build_object('cents', null,
          'reason', 'no incremental model for a reminder-only contact',
          'scenario_cents', null,
          'expected_value', jsonb_build_object('status', 'unavailable',
            'reason', 'no behavioural model backs this cohort figure')),
        'action', jsonb_build_object('who', 'front desk', 'what',
          'Send a reminder, no incentive: these customers already return without one.',
          'when', 'this week', 'channel', 'whatsapp_or_call_where_consent_exists'),
        'incentive', jsonb_build_object('kind', 'none', 'declared', true),
        'why_now', format('%s customers are already overdue as of %s.', v_reminder_n, p_to),
        'reversal_condition', format('Reconsider this call if fewer than %s of these customers '
          'return within 30 days of the reminder.', ceil(v_reminder_n / 2.0)),
        'alternatives', jsonb_build_array(jsonb_build_object('kind', 'reminder_only', 'primary', true,
          'what', 'Contact without any discount or credit.',
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
          jsonb_build_object('kind', 'incentive', 'primary', false,
            'what', 'Offer a discount anyway.', 'cost_basis', c_incentive_unavailable)),
        'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'reminder only, no incentive'),
        'evidence', jsonb_build_object('source_rpc', 'public.get_ci_discount_dependency_v1',
          'refs', jsonb_build_object('reminder_only_candidates_n', v_reminder_n)),
        'evidence_class', 'ASSOCIATION',
        'confidence', app.subgroup_evidence_v1(v_reminder_n),
        'limitation', 'Organic-vs-dependent classification is itself a proxy on discount history, '
                      'not a controlled experiment.',
        'rank_class', 'unquantified'));
    end if;

    v_examined_ext := v_examined_ext + 1;
    v_loyalty := public.get_ci_loyalty_programmes_v1(p_business, p_from, p_to, null);
    v_best_programme := null; v_best_cannibal := null;
    for v_dsc in
      select key as k, value as v from jsonb_each(coalesce(v_loyalty->'programmes', '{}'::jsonb))
    loop
      if v_dsc.v->>'status' = 'ready'
         and (v_dsc.v->'cannibalisation_proxy'->'within_cycle'->>'pct') is not null
         and (v_dsc.v->'cannibalisation_proxy'->'within_cycle'->>'pct')::numeric >= c_cannibal_pct
         and (v_best_cannibal is null
              or (v_dsc.v->'cannibalisation_proxy'->'within_cycle'->>'pct')::numeric > v_best_cannibal)
      then
        v_best_cannibal := (v_dsc.v->'cannibalisation_proxy'->'within_cycle'->>'pct')::numeric;
        v_best_programme := v_dsc.k;
      end if;
    end loop;
    if v_best_programme is null then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'loyalty_cannibalisation_gap',
        'reason', format('no active loyalty programme has a within-cycle cannibalisation share '
                          'at or above the %s%% bar', c_cannibal_pct)));
    else
      v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
        'id', 'loyalty_cannibalisation_gap',
        'domain', 'loyalty',
        'pattern', format('%s%% of "%s" redemptions coincide with visits the customer''s own '
                           'rhythm already predicted — the programme is largely buying visits '
                           'that were coming anyway.', v_best_cannibal, v_best_programme),
        'comparison', jsonb_build_object('kind', 'threshold',
          'detail', format('within-cycle share %s%% against the %s%% cannibalisation bar',
                            v_best_cannibal, c_cannibal_pct)),
        'impact', jsonb_build_object('cents', null,
          'reason', 'no incremental model: this is a proxy, not a measured incremental effect',
          'scenario_cents', null,
          'expected_value', jsonb_build_object('status', 'unavailable',
            'reason', 'no behavioural model backs a cannibalisation proxy')),
        'action', jsonb_build_object('who', 'the owner', 'what',
          format('Review "%s"''s reward design: redemptions that were coming anyway are pure '
                 'margin loss, not incremental visits.', v_best_programme),
          'when', 'next programme review', 'channel', 'planning'),
        'incentive', jsonb_build_object('kind', 'credit', 'declared', true),
        'why_now', format('%s%% within-cycle as of %s; every redemption cycle at this level is '
                           'spend without incremental return.', v_best_cannibal, p_to),
        'reversal_condition', format('Reconsider this call if the within-cycle share falls under '
                                      '%s%%.', c_cannibal_pct),
        'alternatives', jsonb_build_array(
          jsonb_build_object('kind', 'reminder_only', 'primary', true,
            'what', 'Review the programme design at no cost before changing the reward itself.',
            'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
          jsonb_build_object('kind', 'incentive', 'primary', false,
            'what', 'Redesign the reward (raise the bar or lower the value).',
            'cost_basis', c_incentive_unavailable)),
        'cost_basis', c_incentive_unavailable,
        'evidence', jsonb_build_object('source_rpc', 'public.get_ci_loyalty_programmes_v1',
          'refs', jsonb_build_object('programme', v_best_programme, 'within_cycle_pct', v_best_cannibal)),
        'evidence_class', 'ASSOCIATION',
        'confidence', app.subgroup_evidence_v1(5),
        'limitation', 'within_cycle is a proxy on the customer''s own rhythm, not a measured '
                      'incremental effect (see app.ci_loyalty_outcomes_v683).',
        'rank_class', 'unquantified'));
    end if;

    v_examined_ext := v_examined_ext + 1;
    v_staff_perf := public.get_ci_staff_performance_v1(p_business, p_from, p_to, null);
    select s into v_worst_staff
      from jsonb_array_elements(coalesce(v_staff_perf->'staff', '[]'::jsonb)) s
     where s->'evidence'->>'status' = 'ok'
       and (s->'adjusted'->>'index') is not null
       and (s->'adjusted'->>'index')::numeric < c_staff_index_bar
     order by (s->'adjusted'->>'index')::numeric asc, s->>'staff_id' limit 1;
    if v_worst_staff is null then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'staff_mix_underperformance',
        'reason', format('no staff member''s mix-adjusted index is below the %s bar',
                          c_staff_index_bar)));
    else
      v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
        'id', 'staff_mix_underperformance:' || (v_worst_staff->>'staff_id'),
        'domain', 'staff_performance',
        'pattern', format('%s''s mix-adjusted index is %s — below what the same service mix '
                           'earns at the firm average.',
                           coalesce(v_worst_staff->>'full_name', v_worst_staff->>'staff_id'),
                           v_worst_staff->'adjusted'->>'index'),
        'comparison', jsonb_build_object('kind', 'baseline',
          'detail', format('actual revenue / expected revenue at the firm''s own per-service '
                            'average ticket, index %s against the %s bar',
                            v_worst_staff->'adjusted'->>'index', c_staff_index_bar)),
        'impact', jsonb_build_object('cents', null,
          'reason', 'no incremental model: a mix-adjusted index gap is not itself a cash figure',
          'scenario_cents', null,
          'expected_value', jsonb_build_object('status', 'unavailable',
            'reason', 'no behavioural model backs a staff performance index')),
        'action', jsonb_build_object('who', 'the owner, with this staff member', 'what',
          format('Coach %s on upselling/service delivery for their own mix — the gap is against '
                 'the FIRM''S OWN average for the services they already perform, not a made-up '
                 'target.', coalesce(v_worst_staff->>'full_name', v_worst_staff->>'staff_id')),
          'when', 'next 1:1', 'channel', 'in_person_coaching'),
        'incentive', jsonb_build_object('kind', 'none', 'declared', true),
        'why_now', format('Index is already %s as of %s; every day at this level under-earns '
                           'against the firm''s own price list for the same services.',
                           v_worst_staff->'adjusted'->>'index', p_to),
        'reversal_condition', format('Reconsider this call once the index rises to %s or above.',
                                      c_staff_index_bar),
        'alternatives', jsonb_build_array(
          jsonb_build_object('kind', 'operational_change', 'primary', true,
            'what', 'review the mix this person is scheduled on (training, booking rules, roster)',
            'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0,
              'note', 'operational, no incentive spend')),
          jsonb_build_object('kind', 'reminder_only', 'primary', false,
            'what', 'Coach, no compensation change.',
            'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend'))),
        'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'coaching only'),
        'evidence', jsonb_build_object('source_rpc', 'public.get_ci_staff_performance_v1',
          'refs', v_worst_staff),
        'evidence_class', 'ASSOCIATION',
        'confidence', v_worst_staff->'evidence',
        'limitation', 'A mix-adjusted index is observational: it does not control for tenure, '
                      'shift allocation, or customer selection.',
        'rank_class', 'unquantified'));
    end if;
  end if;

  -- ---------------------------------------------------------------------------------------
  -- MATERIALITY GATE (check 65), the EV half: any candidate with a computed expected_value
  -- below 1% of the period's own known revenue abstains, even with evidence ok.
  -- ---------------------------------------------------------------------------------------
  -- ---------------------------------------------------------------------------------------
  -- NESTLY v705 · NEW GENERATOR · campaigns (check 22): read -> purchase association rate from the
  -- marketing funnel reader. That reader is p_branch-rejecting (app.ci_no_branch_dimension_v667), so
  -- a branch-scoped call abstains honestly here rather than raising from a sub-reader it was never
  -- asked for by name (same pattern as generators B/E/G above).
  -- ---------------------------------------------------------------------------------------
  v_examined_ext := v_examined_ext + 1;
  if p_branch is not null then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'campaigns',
      'reason', 'no branch dimension: campaign sends are recorded per business, not per branch'));
  else
    v_campaign_funnel := public.get_ci_marketing_funnel_v1(p_business, p_from, p_to, null);
    if (v_campaign_funnel->'stages'->'associated_purchase'->'evidence'->>'status') = 'ok'
       and (v_campaign_funnel->'stages'->'associated_purchase'->'rate'->>'pct') is not null then
      v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
        'id', 'campaigns',
        'domain', 'campaigns',
        'pattern', format(
          'Of %s customers sent a campaign whose 30-day window has already matured, %s%% (%s of %s) '
          'made a purchase afterward.',
          v_campaign_funnel->'stages'->'associated_purchase'->'rate'->>'denominator',
          v_campaign_funnel->'stages'->'associated_purchase'->'rate'->>'pct',
          v_campaign_funnel->'stages'->'associated_purchase'->'rate'->>'numerator',
          v_campaign_funnel->'stages'->'associated_purchase'->'rate'->>'denominator'),
        'comparison', jsonb_build_object('kind', 'baseline',
          'detail', format('read->purchase association rate %s%% (%s of %s), matured sends only',
            v_campaign_funnel->'stages'->'associated_purchase'->'rate'->>'pct',
            v_campaign_funnel->'stages'->'associated_purchase'->'rate'->>'numerator',
            v_campaign_funnel->'stages'->'associated_purchase'->'rate'->>'denominator')),
        'impact', jsonb_build_object('cents', null,
          'reason', 'no incremental model: association with a subsequent purchase is not the same '
                    'as the campaign causing it',
          'scenario_cents', null,
          'expected_value', jsonb_build_object('status', 'unavailable',
            'reason', 'no behavioural model backs a campaign association')),
        'action', jsonb_build_object('who', 'the owner or whoever runs marketing', 'what',
          'Review this campaign''s targeting and content; an association with a later purchase '
          'is not proof the campaign caused it.', 'when', 'this review cycle', 'channel', 'analysis'),
        'incentive', jsonb_build_object('kind', 'none', 'declared', true),
        'why_now', format('The association is already measurable on matured sends as of %s.', p_to),
        'reversal_condition', 'Reconsider this call if the association rate falls materially on '
                               'the next measurement window.',
        'alternatives', jsonb_build_array(
          jsonb_build_object('kind', 'reminder_only', 'primary', true,
            'what', 'Note the association and monitor, no spend.',
            'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
          jsonb_build_object('kind', 'incentive', 'primary', false,
            'what', 'Add an incentive to the next send to test whether it changes the rate.',
            'cost_basis', c_incentive_unavailable)),
        'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'observation only'),
        'evidence', jsonb_build_object('source_rpc', 'public.get_ci_marketing_funnel_v1',
          'refs', v_campaign_funnel->'stages'->'associated_purchase'),
        'evidence_class', (app.ci_verdict_class_v696('campaigns')->>'class'),
        'confidence', v_campaign_funnel->'stages'->'associated_purchase'->'evidence',
        'limitation',
          'Incremental effect is unavailable: this is an association between being sent a campaign '
          'and a later purchase, never causal — nothing in this engine runs a controlled experiment '
          'for campaign sends, and recipients are not a random draw from the customer base.',
        'rank_class', 'unquantified'));
    else
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'campaigns',
        'reason', 'no matured send cohort clears the evidence floor, or no associated-purchase '
                  'rate is available'));
    end if;
  end if;

  v_c := v_cands_ext || v_new_cands;   -- v_c reused as the full pre-materiality candidate array

  select coalesce(jsonb_agg(jsonb_build_object(
           'generator', e->>'id',
           'reason', format('below_materiality: expected value %s cents is below 1%% of period '
                             'revenue (%s cents)', e->'impact'->'expected_value'->>'cents', v_ev_bar)))
         , '[]'::jsonb)
    into v_abst_ext
    from jsonb_array_elements(v_c) e
   where (e->'impact'->'expected_value'->>'cents') is not null
     and (e->'impact'->'expected_value'->>'cents')::numeric < v_ev_bar;
  v_abst_ext := v_abst || v_abst_ext;

  select coalesce(jsonb_agg(e), '[]'::jsonb) into v_cands_ext
    from jsonb_array_elements(v_c) e
   where (e->'impact'->'expected_value'->>'cents') is null
      or (e->'impact'->'expected_value'->>'cents')::numeric >= v_ev_bar;

  -- ---------------------------------------------------------------------------------------
  -- NESTLY v705 (checks 23/25/66/74) · materiality, margin guard, capacity, concentration —
  -- additive keys only, applied generically to every surviving extended-mode candidate (JC2 in
  -- this migration's header). Never touches v_ranked/v_cands (the base pass), so v678/v696's
  -- frozen twelve-key contract on p_extended=>false cannot regress.
  -- ---------------------------------------------------------------------------------------
  select coalesce(jsonb_agg(fin.c2 order by t.ord), '[]'::jsonb)
    into v_cands_ext
    from jsonb_array_elements(v_cands_ext) with ordinality as t(c, ord)
    cross join lateral (
      select coalesce((t.c->'impact'->'expected_value'->>'cents')::bigint,
                       (t.c->'impact'->>'scenario_cents')::bigint) as num
    ) n
    cross join lateral (
      select case
               when n.num is null then 'unquantified'
               when v_period_revenue > 0
                    and round(10000.0 * n.num / v_period_revenue)
                        >= app.ci_materiality_threshold_bps_v705()
                 then 'material'
               else 'minor'
             end as mclass
    ) mc
    cross join lateral (
      -- NESTLY v718 (check 74) — the SAME resolution as the service_intelligence alternatives case
      -- above (JC2 in this migration's header: computed twice, both calls agree by construction
      -- since app.ci_margin_guard_v705 is stable and both use identical arguments), so
      -- gateway_followthrough's top-level margin_guard key and its alternative's cost_basis are
      -- never out of step, including the merged assumed_incentive_cents/assumption keys (refuter
      -- finding 2). Every other candidate is untouched: loyalty_cannibalisation_gap (the
      -- only OTHER incentive.kind in ('credit','discount')) still resolves via the pre-existing
      -- v_margin_guard_cannibal constant (nestly_v705 JC3 — it names no service, stays
      -- 'unavailable'); every remaining candidate still resolves to null (impact.margin
      -- 'not_applicable', nestly_v712).
      select case
               when t.c->>'id' like 'gateway_followthrough:%' then
                 app.ci_margin_guard_v705(p_business,
                   nullif(split_part(t.c->>'id', ':', 2), '')::uuid,
                   app.ci_standard_incentive_cents_v718())
                 || jsonb_build_object('assumed_incentive_cents', app.ci_standard_incentive_cents_v718(),
                      'assumption', 'Scored against the standard proposed incentive amount, not this candidate''s own declared spend.')
               when t.c->'incentive'->>'kind' in ('credit', 'discount') then v_margin_guard_cannibal
               else null
             end as mg
    ) g
    cross join lateral (
      select case when t.c->>'domain' in ('retention_funnel', 'daypart', 'service_intelligence',
                                           'staff_performance')
                  then v_capacity else null end as cap
    ) capx
    cross join lateral (
      select coalesce((t.c->'confidence'->>'n')::int, 0) as n
    ) cn
    cross join lateral (
      -- NESTLY v712 (check 25) — affected_customers/revenue_cents/margin/capacity/retention_risk,
      -- every value traced to an ALREADY-COMPUTED figure (cn.n from the candidate's own
      -- confidence.n; n.num from the same expected_value/scenario_cents this pass already reads;
      -- g.mg/capx.cap already computed above) — never a fabricated number, honest not_applicable
      -- when the underlying figure does not exist for this candidate's domain.
      select jsonb_build_object(
               'affected_customers', jsonb_build_object(
                 'status', case when cn.n > 0 then 'ok' else 'not_applicable' end, 'n', cn.n),
               'revenue_cents', case when n.num is null
                 then jsonb_build_object('status', 'not_applicable')
                 else jsonb_build_object('status', 'ok', 'cents', n.num) end,
               'margin', coalesce(g.mg, jsonb_build_object('status', 'not_applicable',
                 'reason', 'no incentive spend for this candidate')),
               'capacity', coalesce(capx.cap, jsonb_build_object('status', 'not_applicable')),
               'retention_risk', case when t.c->>'domain' in ('cadence', 'retention_funnel')
                 then jsonb_build_object('status', 'ok', 'at_risk_n', cn.n)
                 else jsonb_build_object('status', 'not_applicable') end)
             as extra
    ) imp5
    cross join lateral (
      select t.c || jsonb_build_object(
               'materiality', app.rate_block_v1(n.num, v_period_revenue),
               'materiality_class', mc.mclass,
               'margin_guard', g.mg,
               'capacity', capx.cap,
               'impact', (t.c->'impact') || imp5.extra)
             as base
    ) b1
    cross join lateral (
      select case
               when t.c->>'domain' <> 'category_mix' then b1.base
               when v_top_skew then
                 b1.base || jsonb_build_object(
                   'concentration', jsonb_build_object(
                     'top1_share_bps', (v_top->'distribution'->>'top1_share_bps')::int,
                     'mean_excl_top1', (v_top->'distribution'->>'mean_excl_top1')::numeric,
                     'skew_note', v_top->>'skew_note'),
                   'pattern', (t.c->>'pattern') || ' ' ||
                     format('Its top customer alone accounts for %s%% of the category.',
                            round((v_top->'distribution'->>'top1_share_bps')::numeric / 100, 1)))
               else
                 b1.base || jsonb_build_object('concentration', null)
             end as base2
    ) b2
    cross join lateral (
      select case
               when g.mg is not null and g.mg->>'status' = 'blocked' then
                 b2.base2 || jsonb_build_object('rank_class', 'unquantified',
                   'limitation', (t.c->>'limitation') || ' ' || (g.mg->>'reason'))
               else b2.base2
             end as c2
    ) fin;

  -- ---------------------------------------------------------------------------------------
  -- RE-RANK: foundation < quantified (by EV desc, else scenario_cents desc) < unquantified <
  -- strength; ties broken by domain, id.
  -- ---------------------------------------------------------------------------------------
  select coalesce(jsonb_agg(x.c || jsonb_build_object('rank', x.rn) order by x.rn), '[]'::jsonb)
    into v_ranked_ext
    from (
      select c,
             row_number() over (
               order by case c->>'rank_class'
                          when 'foundation' then 0
                          when 'quantified' then 1
                          when 'unquantified' then 2
                          else 3 end,
                        case c->>'materiality_class'
                          when 'material' then 0
                          when 'minor' then 1
                          else 2 end,
                        coalesce((c->'impact'->'expected_value'->>'cents')::bigint,
                                 (c->'impact'->>'scenario_cents')::bigint, 0) desc,
                        c->>'domain', c->>'id') as rn
        from jsonb_array_elements(v_cands_ext) c
       where c->'confidence'->>'status' = 'ok'
    ) x;

  v_promoted_ext := coalesce(jsonb_array_length(v_ranked_ext), 0);

  if v_promoted_ext = 0 then
    v_ranked_ext := v_ranked;  -- reuse the base pass's do_nothing/stale-evidence entry
  end if;

  -- NESTLY v696 (check 17, spine half) — the same additive impact_class pass, now three-way:
  -- 'expected_value' beats 'scenario' beats 'none'. Idempotent on the v_promoted_ext=0
  -- fallback above, which reuses an already-enriched v_ranked entry — recomputing the same value
  -- twice is harmless, not a second kind of enrichment.
  select coalesce(jsonb_agg(
           t.c || jsonb_build_object('impact',
             (t.c->'impact') || jsonb_build_object('impact_class',
               case when (t.c->'impact'->'expected_value'->>'cents') is not null
                      then 'expected_value'
                    when (t.c->'impact'->>'cents') is not null then 'scenario'
                    else 'none' end))
           order by t.ord), '[]'::jsonb)
    into v_ranked_ext
    from jsonb_array_elements(v_ranked_ext) with ordinality as t(c, ord);

  -- ---------------------------------------------------------------------------------------
  -- report_sections + top_actions (checks 22/79)
  -- ---------------------------------------------------------------------------------------
  select jsonb_build_object(
    'strengths', coalesce((select jsonb_agg(c->>'id') from jsonb_array_elements(v_ranked_ext) c
                            where c->>'rank_class' = 'strength'), '[]'::jsonb),
    'change', coalesce((select jsonb_agg(c->>'id') from jsonb_array_elements(v_ranked_ext) c
                         where c->>'domain' = 'change'), '[]'::jsonb),
    'unnoticed_behaviour', coalesce((select jsonb_agg(c->>'id') from jsonb_array_elements(v_ranked_ext) c
                                      where c->>'domain' = 'discovery'), '[]'::jsonb),
    'leakage', coalesce((select jsonb_agg(c->>'id') from jsonb_array_elements(v_ranked_ext) c
                          where c->>'domain' in ('packages','discount_dependency','loyalty')), '[]'::jsonb),
    'margin', jsonb_build_object('status', 'unavailable',
      'reason', 'no COGS/cost-of-goods field on services or sales in this schema'),
    'segments', coalesce((select jsonb_agg(c->>'id') from jsonb_array_elements(v_ranked_ext) c
                           where c->>'domain' in ('discovery','change')
                             and c->'evidence'->'refs'->>'dimension' in ('age_gender','category_node')),
                          '[]'::jsonb),
    'failures', coalesce((select jsonb_agg(c->>'id') from jsonb_array_elements(v_ranked_ext) c
                           where c->>'rank_class' not in ('foundation','strength','do_nothing')
                             and c->>'domain' not in ('discovery','change','packages',
                                                       'discount_dependency','loyalty')), '[]'::jsonb)
  ) into v_report_sections;

  select coalesce(jsonb_agg(e), '[]'::jsonb) into v_top_actions
    from (select e from jsonb_array_elements(v_ranked_ext) e limit 5) t;

  v_result := v_result || jsonb_build_object(
    'ranked', v_ranked_ext,
    'abstentions', v_abst_ext,
    'comparisons', app.comparisons_note_v1(v_examined_ext, v_promoted_ext),
    'report_sections', v_report_sections,
    'top_actions', v_top_actions);

  return app.ci_envelope_v680('ci_opportunities_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$function$
;

do $check_public_get_ci_opportunities_v1$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$    with overdue as materialized (
      select b.client_id
        from app.customer_cadence_batch_v1(
               p_business,
               ((p_as_of at time zone 'Asia/Singapore')::date + 1),
               ((p_as_of at time zone 'Asia/Singapore')::date + 1),
               p_as_of, null, true) b
        cross join lateral (
          select app.customer_cadence_v1(p_business, b.client_id) as cad
        ) c
       where c.cad->>'deviation_state' = 'overdue'
         and c.cad->>'evidence_source' = 'customer_median_interval'
    ),$lit$;
  v_new1 constant text := $lit$    with overdue as materialized (
      select b.client_id
        from app.customer_cadence_batch_v1(
               p_business,
               ((p_as_of at time zone 'Asia/Singapore')::date + 1),
               ((p_as_of at time zone 'Asia/Singapore')::date + 1),
               p_as_of, null, true) b
        join public.clients cli on cli.id = b.client_id and cli.business_id = p_business
        cross join lateral (
          select app.customer_cadence_v1(p_business, b.client_id) as cad
        ) c
       where c.cad->>'deviation_state' = 'overdue'
         and c.cad->>'evidence_source' = 'customer_median_interval'
         and not cli.is_synthetic
    ),$lit$;
  v_old2 constant text := $lit$      with overdue as materialized (
        select b.client_id
          from app.customer_cadence_batch_v1(
                 p_business,
                 ((p_as_of at time zone 'Asia/Singapore')::date + 1),
                 ((p_as_of at time zone 'Asia/Singapore')::date + 1),
                 p_as_of, null, true) b
          cross join lateral (select app.customer_cadence_v1(p_business, b.client_id) as cad) c
         where c.cad->>'deviation_state' = 'overdue'
           and c.cad->>'evidence_source' = 'customer_median_interval'
      ),$lit$;
  v_new2 constant text := $lit$      with overdue as materialized (
        select b.client_id
          from app.customer_cadence_batch_v1(
                 p_business,
                 ((p_as_of at time zone 'Asia/Singapore')::date + 1),
                 ((p_as_of at time zone 'Asia/Singapore')::date + 1),
                 p_as_of, null, true) b
          join public.clients cli on cli.id = b.client_id and cli.business_id = p_business
          cross join lateral (select app.customer_cadence_v1(p_business, b.client_id) as cad) c
         where c.cad->>'deviation_state' = 'overdue'
           and c.cad->>'evidence_source' = 'customer_median_interval'
           and not cli.is_synthetic
      ),$lit$;
begin
  select def into v_before from _v744_before where fn = $lit$get_ci_opportunities_v1$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = $lit$public$lit$ and p.proname = $lit$get_ci_opportunities_v1$lit$;
  if position(v_old1 in v_before) = 0 then
    raise exception 'public.get_ci_opportunities_v1: hunk 1 anchor not found in captured body';
  end if;
  if position(v_old2 in v_before) = 0 then
    raise exception 'public.get_ci_opportunities_v1: hunk 2 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  v_expect := replace(v_expect, v_old2, v_new2);
  if v_expect <> v_after then
    raise exception 'public.get_ci_opportunities_v1: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check_public_get_ci_opportunities_v1$;

-- =============================================================================================
-- 2 . public.get_reports_summary_v94_base -- credit_liability, non_revenue_by_kind, points_by_type
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_reports_summary_v94_base(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_revenue jsonb;
  v_non_revenue jsonb;
  v_points jsonb;
  v_credit_liability bigint;
  v_gift_card_liability bigint;
  v_active_memberships bigint;
begin
  if auth.uid() is null
     or not app.has_perm(p_business, 'view_sales')
     or not app.can_module_read(p_business, 'reports') then
    raise exception 'you do not have permission to view reports for this business'
      using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'a valid report date range is required'
      using errcode = '22007';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches b
    where b.id = p_branch and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to this business'
      using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'you are not permitted to view this branch scope'
      using errcode = '42501';
  end if;

  select coalesce(jsonb_object_agg(x.kind, x.amount_cents), '{}'::jsonb)
  into v_revenue
  from (
    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not sc.is_synthetic_client
    group by s.kind
  ) x;

  select coalesce(jsonb_object_agg(x.kind, x.amount_cents), '{}'::jsonb)
  into v_non_revenue
  from (
    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and not s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not exists (
        select 1 from public.clients c
        where c.id = s.client_id and c.is_synthetic
      )
    group by s.kind
  ) x;

  select coalesce(jsonb_object_agg(x.entry_type, x.points), '{}'::jsonb)
  into v_points
  from (
    select pl.entry_type, sum(pl.points) as points
    from public.points_ledger pl
    join public.clients plc on plc.id = pl.client_id and plc.business_id = pl.business_id
    where pl.business_id = p_business
      and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and not plc.is_synthetic
    group by pl.entry_type
  ) x;

  select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
  into v_credit_liability
  from public.client_credit_balance cb
  join public.clients cli on cli.id = cb.client_id and cli.business_id = cb.business_id
  where cb.business_id = p_business
    and not cli.is_synthetic;

  v_gift_card_liability := app.reports_gift_card_liability_v49b(p_business, p_branch);

  select count(*) filter (where m.status = 'active')
  into v_active_memberships
  from public.memberships m
  where m.business_id = p_business;

  return jsonb_build_object(
    'revenue_by_kind', v_revenue,
    'non_revenue_by_kind', v_non_revenue,
    'points_by_type', v_points,
    'credit_liability_cents', v_credit_liability,
    'gift_card_liability_cents', v_gift_card_liability,
    'active_memberships', v_active_memberships
  );
end;
$function$
;

do $check_public_get_reports_summary_v94_base$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$  select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
  into v_credit_liability
  from public.client_credit_balance cb
  where cb.business_id = p_business;$lit$;
  v_new1 constant text := $lit$  select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
  into v_credit_liability
  from public.client_credit_balance cb
  join public.clients cli on cli.id = cb.client_id and cli.business_id = cb.business_id
  where cb.business_id = p_business
    and not cli.is_synthetic;$lit$;
  v_old2 constant text := $lit$    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and not s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
    group by s.kind
  ) x;

  select coalesce(jsonb_object_agg(x.entry_type, x.points), '{}'::jsonb)
  into v_points
  from (
    select pl.entry_type, sum(pl.points) as points
    from public.points_ledger pl
    where pl.business_id = p_business
      and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    group by pl.entry_type
  ) x;$lit$;
  v_new2 constant text := $lit$    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and not s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not exists (
        select 1 from public.clients c
        where c.id = s.client_id and c.is_synthetic
      )
    group by s.kind
  ) x;

  select coalesce(jsonb_object_agg(x.entry_type, x.points), '{}'::jsonb)
  into v_points
  from (
    select pl.entry_type, sum(pl.points) as points
    from public.points_ledger pl
    join public.clients plc on plc.id = pl.client_id and plc.business_id = pl.business_id
    where pl.business_id = p_business
      and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and not plc.is_synthetic
    group by pl.entry_type
  ) x;$lit$;
begin
  select def into v_before from _v744_before where fn = $lit$get_reports_summary_v94_base$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = $lit$public$lit$ and p.proname = $lit$get_reports_summary_v94_base$lit$;
  if position(v_old1 in v_before) = 0 then
    raise exception 'public.get_reports_summary_v94_base: hunk 1 anchor not found in captured body';
  end if;
  if position(v_old2 in v_before) = 0 then
    raise exception 'public.get_reports_summary_v94_base: hunk 2 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  v_expect := replace(v_expect, v_old2, v_new2);
  if v_expect <> v_after then
    raise exception 'public.get_reports_summary_v94_base: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check_public_get_reports_summary_v94_base$;

-- =============================================================================================
-- 3 . public.get_reports_summary -- credit_liability, compensating/reversed/net revenue, non_revenue_by_kind, points_by_type
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_reports_summary(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_revenue jsonb;
  v_non_revenue jsonb;
  v_points jsonb;
  v_credit_liability bigint;
  v_gift_card_liability bigint;
  v_active_memberships bigint;
  v_compensating_rows bigint;
  v_reversed_revenue_cents bigint;
  v_net_revenue_cents bigint;
  v_sales_export_available boolean;
  v_clients_export_available boolean;
  v_loyalty_available boolean;
  v_gift_cards_available boolean;
  v_memberships_available boolean;
  v_credit_liability_available boolean;
begin
  if auth.uid() is null
     or not app.has_perm(p_business, 'view_sales') then
    raise exception 'you do not have permission to view reports for this business'
      using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'a valid report date range is required'
      using errcode = '22007';
  end if;
  if p_to - p_from > 1826 then
    raise exception 'report date range cannot exceed 1827 days'
      using errcode = '22023';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches b
    where b.id = p_branch and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to this business'
      using errcode = '42501';
  end if;

  -- Every money/reversal field below is derived from Sales. Reports mode alone is not
  -- sufficient because a branch-level Sales override may intentionally make that
  -- source unreadable. A SECURITY DEFINER aggregate must fail closed for the exact
  -- selected scope rather than return a plausible complete total from hidden rows.
  perform app.require_metric_module_scope_v145(
    p_business, p_branch, 'reports'
  );
  if not app.platform_metric_source_scope_available_v145(
    p_business, p_branch, 'sales'
  ) then
    raise exception 'complete_metric_source_scope_required:sales'
      using errcode = '42501';
  end if;

  v_sales_export_available := app.metric_module_scope_available_v145(
    p_business, p_branch, 'sales'
  );
  v_clients_export_available := app.metric_module_scope_available_v145(
    p_business, p_branch, 'clients'
  );
  v_loyalty_available := app.metric_module_scope_available_v145(
    p_business, null, 'loyalty'
  );
  v_gift_cards_available := app.metric_module_scope_available_v145(
    p_business, null, 'giftcards'
  );
  v_memberships_available := app.metric_module_scope_available_v145(
    p_business, null, 'memberships'
  );
  v_credit_liability_available := app.metric_module_scope_available_v145(
    p_business, null, 'reports'
  ) and app.platform_metric_source_scope_available_v145(
    p_business, null, 'sales'
  );
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'you are not permitted to view this branch scope'
      using errcode = '42501';
  end if;
  -- Preserve the V94 branch-effective Reports boundary. A branch override may
  -- intentionally differ from the firm mode, and an all-branch report must not
  -- consolidate a branch the caller cannot see or where Reports is disabled.
  if p_branch is not null then
    perform app.require_branch_module_v94(p_business, p_branch, 'reports', 'r');
  elsif not app.is_super_admin() then
    if not app.can_module_read_at_v94(p_business, null, 'reports') then
      raise exception 'branch_module_access_required:reports:r'
        using errcode = '42501';
    end if;
    if exists (
      select 1
      from public.branches branch
      where branch.business_id = p_business
        and (
          not app.can_see_branch(p_business, branch.id)
          or not case when branch.active
            then app.can_module_read_at_v94(p_business, branch.id, 'reports')
            else app.can_module_read_at_v94(p_business, null, 'reports')
          end
        )
    ) then
      raise exception 'explicit_branch_required_for_partial_report_scope'
        using errcode = '42501';
    end if;
  end if;

  select coalesce(jsonb_object_agg(x.kind, x.amount_cents), '{}'::jsonb)
  into v_revenue
  from (
    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not sc.is_synthetic_client
    group by s.kind
  ) x;

  select
    count(*) filter (where s.reversal_of is not null),
    coalesce(sum(-s.amount_cents) filter (
      where s.counts_as_revenue
        and s.reversal_of is not null
        and s.amount_cents < 0
    ), 0),
    coalesce(sum(s.amount_cents) filter (where s.counts_as_revenue), 0)
  into v_compensating_rows, v_reversed_revenue_cents, v_net_revenue_cents
  from public.sales s
  cross join lateral app.analytics_sale_class_v1(s) sc
  where s.business_id = p_business
    and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
    and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    and (p_branch is null or s.branch_id = p_branch)
    and not sc.is_synthetic_client;

  select coalesce(jsonb_object_agg(x.kind, x.amount_cents), '{}'::jsonb)
  into v_non_revenue
  from (
    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and not s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not exists (
        select 1 from public.clients c
        where c.id = s.client_id and c.is_synthetic
      )
    group by s.kind
  ) x;

  if v_loyalty_available then
    select coalesce(jsonb_object_agg(x.entry_type, x.points), '{}'::jsonb)
    into v_points
    from (
      select pl.entry_type, sum(pl.points) as points
      from public.points_ledger pl
      join public.clients plc on plc.id = pl.client_id and plc.business_id = pl.business_id
      where pl.business_id = p_business
        and pl.programme_id = app.live_balance_programme_v381(p_business)
        and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
        and not plc.is_synthetic
      group by pl.entry_type
    ) x;
  else
    v_points := null;
  end if;

  if v_credit_liability_available then
    select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
      into v_credit_liability
      from public.client_credit_balance cb
      join public.clients cli on cli.id = cb.client_id and cli.business_id = cb.business_id
     where cb.business_id = p_business
       and not cli.is_synthetic;
  else
    v_credit_liability := null;
  end if;

  if v_gift_cards_available then
    v_gift_card_liability := app.reports_gift_card_liability_v49b(
      p_business, p_branch
    );
  else
    v_gift_card_liability := null;
  end if;

  if v_memberships_available then
    select count(*) filter (where m.status = 'active')
    into v_active_memberships
    from public.memberships m
    where m.business_id = p_business;
  else
    v_active_memberships := null;
  end if;

  return jsonb_build_object(
    'revenue_by_kind', v_revenue,
    'non_revenue_by_kind', v_non_revenue,
    'points_by_type', v_points,
    'loyalty_unit', case when v_loyalty_available then (select spine.kind from public.business_programmes spine where spine.id = app.live_balance_programme_v381(p_business)) else null end,
    'credit_liability_cents', v_credit_liability,
    'gift_card_liability_cents', v_gift_card_liability,
    'active_memberships', v_active_memberships,
    'reversal_reconciliation', jsonb_build_object(
      'compensating_rows', v_compensating_rows,
      'reversed_revenue_cents', v_reversed_revenue_cents,
      'net_revenue_cents', v_net_revenue_cents
    ),
    'availability', jsonb_build_object(
      'sales_export', v_sales_export_available,
      'clients_export', v_clients_export_available,
      'loyalty', v_loyalty_available,
      'gift_cards', v_gift_cards_available,
      'memberships', v_memberships_available,
      'credit_liability', v_credit_liability_available
    ),
    'scope', jsonb_build_object(
      'timezone', 'Asia/Singapore',
      'from', p_from,
      'to', p_to,
      'branch_id', p_branch,
      'sales', 'selected_period_and_branch_signed_ledger',
      'points', case when v_loyalty_available
        then 'business_wide_selected_period'
        else 'unavailable_without_complete_loyalty_scope' end,
      'credit_liability', case when v_credit_liability_available
        then 'business_wide_current_with_complete_business_reports_and_sales_source_scope'
        else 'unavailable_without_complete_business_reports_and_sales_source_scope' end,
      'gift_card_liability', case when v_gift_cards_available
        then 'business_wide_current' else 'unavailable_without_complete_giftcards_scope' end,
      'active_memberships', case when v_memberships_available
        then 'business_wide_current'
        else 'unavailable_without_complete_memberships_scope' end
    )
  );
end;
$function$
;

do $check_public_get_reports_summary$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$  if v_credit_liability_available then
    select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
      into v_credit_liability
      from public.client_credit_balance cb
     where cb.business_id = p_business;
  else$lit$;
  v_new1 constant text := $lit$  if v_credit_liability_available then
    select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
      into v_credit_liability
      from public.client_credit_balance cb
      join public.clients cli on cli.id = cb.client_id and cli.business_id = cb.business_id
     where cb.business_id = p_business
       and not cli.is_synthetic;
  else$lit$;
  v_old2 constant text := $lit$  select
    count(*) filter (where s.reversal_of is not null),
    coalesce(sum(-s.amount_cents) filter (
      where s.counts_as_revenue
        and s.reversal_of is not null
        and s.amount_cents < 0
    ), 0),
    coalesce(sum(s.amount_cents) filter (where s.counts_as_revenue), 0)
  into v_compensating_rows, v_reversed_revenue_cents, v_net_revenue_cents
  from public.sales s
  where s.business_id = p_business
    and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
    and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    and (p_branch is null or s.branch_id = p_branch);$lit$;
  v_new2 constant text := $lit$  select
    count(*) filter (where s.reversal_of is not null),
    coalesce(sum(-s.amount_cents) filter (
      where s.counts_as_revenue
        and s.reversal_of is not null
        and s.amount_cents < 0
    ), 0),
    coalesce(sum(s.amount_cents) filter (where s.counts_as_revenue), 0)
  into v_compensating_rows, v_reversed_revenue_cents, v_net_revenue_cents
  from public.sales s
  cross join lateral app.analytics_sale_class_v1(s) sc
  where s.business_id = p_business
    and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
    and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    and (p_branch is null or s.branch_id = p_branch)
    and not sc.is_synthetic_client;$lit$;
  v_old3 constant text := $lit$  select coalesce(jsonb_object_agg(x.kind, x.amount_cents), '{}'::jsonb)
  into v_non_revenue
  from (
    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and not s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
    group by s.kind
  ) x;$lit$;
  v_new3 constant text := $lit$  select coalesce(jsonb_object_agg(x.kind, x.amount_cents), '{}'::jsonb)
  into v_non_revenue
  from (
    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and not s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not exists (
        select 1 from public.clients c
        where c.id = s.client_id and c.is_synthetic
      )
    group by s.kind
  ) x;$lit$;
  v_old4 constant text := $lit$  if v_loyalty_available then
    select coalesce(jsonb_object_agg(x.entry_type, x.points), '{}'::jsonb)
    into v_points
    from (
      select pl.entry_type, sum(pl.points) as points
      from public.points_ledger pl
      where pl.business_id = p_business
        and pl.programme_id = app.live_balance_programme_v381(p_business)
        and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      group by pl.entry_type
    ) x;
  else$lit$;
  v_new4 constant text := $lit$  if v_loyalty_available then
    select coalesce(jsonb_object_agg(x.entry_type, x.points), '{}'::jsonb)
    into v_points
    from (
      select pl.entry_type, sum(pl.points) as points
      from public.points_ledger pl
      join public.clients plc on plc.id = pl.client_id and plc.business_id = pl.business_id
      where pl.business_id = p_business
        and pl.programme_id = app.live_balance_programme_v381(p_business)
        and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
        and not plc.is_synthetic
      group by pl.entry_type
    ) x;
  else$lit$;
begin
  select def into v_before from _v744_before where fn = $lit$get_reports_summary$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = $lit$public$lit$ and p.proname = $lit$get_reports_summary$lit$;
  if position(v_old1 in v_before) = 0 then
    raise exception 'public.get_reports_summary: hunk 1 anchor not found in captured body';
  end if;
  if position(v_old2 in v_before) = 0 then
    raise exception 'public.get_reports_summary: hunk 2 anchor not found in captured body';
  end if;
  if position(v_old3 in v_before) = 0 then
    raise exception 'public.get_reports_summary: hunk 3 anchor not found in captured body';
  end if;
  if position(v_old4 in v_before) = 0 then
    raise exception 'public.get_reports_summary: hunk 4 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  v_expect := replace(v_expect, v_old2, v_new2);
  v_expect := replace(v_expect, v_old3, v_new3);
  v_expect := replace(v_expect, v_old4, v_new4);
  if v_expect <> v_after then
    raise exception 'public.get_reports_summary: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check_public_get_reports_summary$;

-- =============================================================================================
-- 4 . public.get_dashboard_summary -- new_customers, points_issued, credit_liability, weekday chart, revenue-by-day chart, gender/age breakdowns
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_dashboard_summary(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_kpis jsonb;
  v_weekdays jsonb;
  v_revenue_by_day jsonb;
  v_gender jsonb;
  v_age jsonb;
  v_sales_available boolean;
  v_clients_available boolean;
  v_loyalty_available boolean;
  v_credit_liability_available boolean;
begin
  if auth.uid() is null
     or not app.has_perm(p_business, 'view_sales')
     or not app.can_module(p_business, 'dailyreport') then
    raise exception 'you do not have permission to view this dashboard'
      using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'a valid report date range is required'
      using errcode = '22007';
  end if;
  if p_to - p_from > 1826 then
    raise exception 'report date range cannot exceed 1827 days'
      using errcode = '22023';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches b
    where b.id = p_branch and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to this business'
      using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'you are not permitted to view this branch scope'
      using errcode = '42501';
  end if;

  v_sales_available := app.metric_module_scope_available_v145(
    p_business, p_branch, 'sales'
  );
  v_clients_available := app.metric_module_scope_available_v145(
    p_business, null, 'clients'
  );
  v_loyalty_available := app.metric_module_scope_available_v145(
    p_business, p_branch, 'loyalty'
  );
  v_credit_liability_available := app.metric_module_scope_available_v145(
    p_business, null, 'sales'
  );
  if not v_sales_available then
    return jsonb_build_object(
      'availability', jsonb_build_object(
        'sales', false,
        'clients', false,
        'loyalty', false,
        'credit_liability', false
      ),
      'scope', jsonb_build_object(
        'timezone', 'Asia/Singapore',
        'from', p_from,
        'to', p_to,
        'branch_id', p_branch,
        'status', 'unavailable_incomplete_sales_scope'
      )
    );
  end if;

  with scoped_sales as (
    select s.*
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not sc.is_synthetic_client
  ), valid_visits as (
    select s.*
    from scoped_sales s
    where s.counts_as_visit
      and s.reversal_of is null
      and not exists (
        select 1
        from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  ), visit_days as (
    -- nestly_v714 (check 4 fix): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699). Sales with no
    -- client_id (walk-ins) cannot be deduped by customer identity, so each still counts on its own
    -- below.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day
    from valid_visits
    where client_id is not null
    group by client_id, app.ci_visit_day_v699(occurred_at)
  )
  select jsonb_build_object(
    'visits', (select count(*) from visit_days) + (select count(*) from valid_visits where client_id is null),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue), 0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null)
  )
  into v_kpis;

  v_kpis := v_kpis || jsonb_build_object(
    'new_customers', case when v_clients_available then (
      select count(*) from public.clients c
      where c.business_id = p_business
        and c.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and c.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
        and not c.is_synthetic
    ) else null end,
    'points_issued', case when v_loyalty_available then (
      select coalesce(sum(pl.points), 0)
      from public.points_ledger pl
      left join public.sales ps
        on ps.id = pl.sale_id
       and ps.business_id = pl.business_id
      join public.clients plc
        on plc.id = pl.client_id
       and plc.business_id = pl.business_id
      where pl.business_id = p_business
        and pl.entry_type = 'earn'
        and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
        and (p_branch is null or ps.branch_id = p_branch)
        and not plc.is_synthetic
    ) else null end,
    'credit_liability_cents', case when v_credit_liability_available then (
      select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
      from public.client_credit_balance cb
      join public.clients cbc on cbc.id = cb.client_id and cbc.business_id = cb.business_id
      where cb.business_id = p_business
        and not cbc.is_synthetic
    ) else null end
  );

  with valid_visits as (
    select s.*
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not exists (
        select 1
        from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
      and not exists (
        select 1 from public.clients c
        where c.id = s.client_id and c.is_synthetic
      )
  )
  select coalesce(jsonb_agg(coalesce(w.visits, 0) order by d.day_no), '[]'::jsonb)
  into v_weekdays
  from generate_series(1, 7) d(day_no)
  left join (
    select extract(isodow from s.occurred_at at time zone 'Asia/Singapore')::int as day_no,
           count(*) as visits
    from valid_visits s
    group by 1
  ) w using (day_no);

  select coalesce(
    jsonb_agg(jsonb_build_object(
      'day', d.sale_day,
      'amount_cents', coalesce(r.amount_cents, 0)
    ) order by d.sale_day),
    '[]'::jsonb)
  into v_revenue_by_day
  from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d0(day_value)
  cross join lateral (select d0.day_value::date as sale_day) d
  left join (
    select (s.occurred_at at time zone 'Asia/Singapore')::date as sale_day,
           sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not exists (
        select 1 from public.clients c
        where c.id = s.client_id and c.is_synthetic
      )
    group by 1
  ) r using (sale_day);

  if v_clients_available then
  select jsonb_build_object(
    'female', count(*) filter (where c.gender = 'female'),
    'male', count(*) filter (where c.gender = 'male'),
    'other', count(*) filter (where c.gender = 'other'),
    'unknown', count(*) filter (where c.gender is null)
  )
  into v_gender
  from public.clients c
  where c.business_id = p_business
    and not c.is_synthetic;

  select jsonb_build_object(
    'under_25', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) < 25),
    'age_25_34', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 25 and 34),
    'age_35_44', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 35 and 44),
    'age_45_54', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 45 and 54),
    'age_55_plus', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) >= 55),
    'unknown', count(*) filter (where c.birth_date is null)
  )
  into v_age
  from public.clients c
  where c.business_id = p_business
    and not c.is_synthetic;
  else
    v_gender := null;
    v_age := null;
  end if;

  return v_kpis || jsonb_build_object(
    'visits_by_weekday', v_weekdays,
    'revenue_by_day', v_revenue_by_day,
    'gender_counts', v_gender,
    'age_counts', v_age,
    'availability', jsonb_build_object(
      'sales', true,
      'clients', v_clients_available,
      'loyalty', v_loyalty_available,
      'credit_liability', v_credit_liability_available
    ),
    'scope', jsonb_build_object(
      'timezone', 'Asia/Singapore',
      'from', p_from,
      'to', p_to,
      'branch_id', p_branch,
      'visits', 'selected_period_and_branch_valid_originals',
      'revenue', 'selected_period_and_branch_signed_ledger',
      'unique_customers', 'selected_period_and_branch_customer_records_with_valid_visits',
      'new_customers', case when v_clients_available then 'business_wide_records_added_in_selected_period' else 'unavailable_without_complete_clients_scope' end,
      'points_issued', case
        when not v_loyalty_available then 'unavailable_without_complete_loyalty_scope'
        when p_branch is null then 'business_wide_gross_earn_in_selected_period'
        else 'selected_branch_sale_linked_gross_earn_in_selected_period'
      end,
      'credit_liability', case when v_credit_liability_available
        then 'business_wide_current_signed_credit_ledger_with_complete_business_sales_read'
        else 'unavailable_without_complete_business_sales_scope' end,
      'age_counts', case when v_clients_available then 'business_wide_current' else 'unavailable_without_complete_clients_scope' end
    )
  );
end;
$function$
;

do $check_public_get_dashboard_summary$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$    'new_customers', case when v_clients_available then (
      select count(*) from public.clients c
      where c.business_id = p_business
        and c.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and c.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    ) else null end,$lit$;
  v_new1 constant text := $lit$    'new_customers', case when v_clients_available then (
      select count(*) from public.clients c
      where c.business_id = p_business
        and c.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and c.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
        and not c.is_synthetic
    ) else null end,$lit$;
  v_old2 constant text := $lit$    'points_issued', case when v_loyalty_available then (
      select coalesce(sum(pl.points), 0)
      from public.points_ledger pl
      left join public.sales ps
        on ps.id = pl.sale_id
       and ps.business_id = pl.business_id
      where pl.business_id = p_business
        and pl.entry_type = 'earn'
        and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
        and (p_branch is null or ps.branch_id = p_branch)
    ) else null end,$lit$;
  v_new2 constant text := $lit$    'points_issued', case when v_loyalty_available then (
      select coalesce(sum(pl.points), 0)
      from public.points_ledger pl
      left join public.sales ps
        on ps.id = pl.sale_id
       and ps.business_id = pl.business_id
      join public.clients plc
        on plc.id = pl.client_id
       and plc.business_id = pl.business_id
      where pl.business_id = p_business
        and pl.entry_type = 'earn'
        and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
        and (p_branch is null or ps.branch_id = p_branch)
        and not plc.is_synthetic
    ) else null end,$lit$;
  v_old3 constant text := $lit$    'credit_liability_cents', case when v_credit_liability_available then (
      select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
      from public.client_credit_balance cb
      where cb.business_id = p_business
    ) else null end
  );$lit$;
  v_new3 constant text := $lit$    'credit_liability_cents', case when v_credit_liability_available then (
      select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
      from public.client_credit_balance cb
      join public.clients cbc on cbc.id = cb.client_id and cbc.business_id = cb.business_id
      where cb.business_id = p_business
        and not cbc.is_synthetic
    ) else null end
  );$lit$;
  v_old4 constant text := $lit$  with valid_visits as (
    select s.*
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not exists (
        select 1
        from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  )
  select coalesce(jsonb_agg(coalesce(w.visits, 0) order by d.day_no), '[]'::jsonb)
  into v_weekdays$lit$;
  v_new4 constant text := $lit$  with valid_visits as (
    select s.*
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not exists (
        select 1
        from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
      and not exists (
        select 1 from public.clients c
        where c.id = s.client_id and c.is_synthetic
      )
  )
  select coalesce(jsonb_agg(coalesce(w.visits, 0) order by d.day_no), '[]'::jsonb)
  into v_weekdays$lit$;
  v_old5 constant text := $lit$  left join (
    select (s.occurred_at at time zone 'Asia/Singapore')::date as sale_day,
           sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
    group by 1
  ) r using (sale_day);$lit$;
  v_new5 constant text := $lit$  left join (
    select (s.occurred_at at time zone 'Asia/Singapore')::date as sale_day,
           sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not exists (
        select 1 from public.clients c
        where c.id = s.client_id and c.is_synthetic
      )
    group by 1
  ) r using (sale_day);$lit$;
  v_old6 constant text := $lit$  if v_clients_available then
  select jsonb_build_object(
    'female', count(*) filter (where c.gender = 'female'),
    'male', count(*) filter (where c.gender = 'male'),
    'other', count(*) filter (where c.gender = 'other'),
    'unknown', count(*) filter (where c.gender is null)
  )
  into v_gender
  from public.clients c
  where c.business_id = p_business;$lit$;
  v_new6 constant text := $lit$  if v_clients_available then
  select jsonb_build_object(
    'female', count(*) filter (where c.gender = 'female'),
    'male', count(*) filter (where c.gender = 'male'),
    'other', count(*) filter (where c.gender = 'other'),
    'unknown', count(*) filter (where c.gender is null)
  )
  into v_gender
  from public.clients c
  where c.business_id = p_business
    and not c.is_synthetic;$lit$;
  v_old7 constant text := $lit$  select jsonb_build_object(
    'under_25', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) < 25),
    'age_25_34', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 25 and 34),
    'age_35_44', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 35 and 44),
    'age_45_54', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 45 and 54),
    'age_55_plus', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) >= 55),
    'unknown', count(*) filter (where c.birth_date is null)
  )
  into v_age
  from public.clients c
  where c.business_id = p_business;
  else$lit$;
  v_new7 constant text := $lit$  select jsonb_build_object(
    'under_25', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) < 25),
    'age_25_34', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 25 and 34),
    'age_35_44', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 35 and 44),
    'age_45_54', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 45 and 54),
    'age_55_plus', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) >= 55),
    'unknown', count(*) filter (where c.birth_date is null)
  )
  into v_age
  from public.clients c
  where c.business_id = p_business
    and not c.is_synthetic;
  else$lit$;
begin
  select def into v_before from _v744_before where fn = $lit$get_dashboard_summary$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = $lit$public$lit$ and p.proname = $lit$get_dashboard_summary$lit$;
  if position(v_old1 in v_before) = 0 then
    raise exception 'public.get_dashboard_summary: hunk 1 anchor not found in captured body';
  end if;
  if position(v_old2 in v_before) = 0 then
    raise exception 'public.get_dashboard_summary: hunk 2 anchor not found in captured body';
  end if;
  if position(v_old3 in v_before) = 0 then
    raise exception 'public.get_dashboard_summary: hunk 3 anchor not found in captured body';
  end if;
  if position(v_old4 in v_before) = 0 then
    raise exception 'public.get_dashboard_summary: hunk 4 anchor not found in captured body';
  end if;
  if position(v_old5 in v_before) = 0 then
    raise exception 'public.get_dashboard_summary: hunk 5 anchor not found in captured body';
  end if;
  if position(v_old6 in v_before) = 0 then
    raise exception 'public.get_dashboard_summary: hunk 6 anchor not found in captured body';
  end if;
  if position(v_old7 in v_before) = 0 then
    raise exception 'public.get_dashboard_summary: hunk 7 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  v_expect := replace(v_expect, v_old2, v_new2);
  v_expect := replace(v_expect, v_old3, v_new3);
  v_expect := replace(v_expect, v_old4, v_new4);
  v_expect := replace(v_expect, v_old5, v_new5);
  v_expect := replace(v_expect, v_old6, v_new6);
  v_expect := replace(v_expect, v_old7, v_new7);
  if v_expect <> v_after then
    raise exception 'public.get_dashboard_summary: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check_public_get_dashboard_summary$;

-- =============================================================================================
-- 5 . public.get_revenue_summary -- v_cash, v_sv_cash, v_unpaid
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_revenue_summary(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_accrual bigint;
  v_cash bigint;
  v_sv_cash bigint;
  v_expenses bigint;
  v_unpaid bigint;
  v_collected bigint;
  v_from_ts timestamptz;
  v_to_ts timestamptz;
  v_expenses_by_category jsonb;
  v_monthly jsonb;
begin
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'p_from and p_to are required and p_from must be on or before p_to'
      using errcode = '22007';
  end if;
  if p_to - p_from > 1826 then
    raise exception 'report date range cannot exceed 1827 days'
      using errcode = '22023';
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

  perform app.require_metric_module_scope_v145(p_business, p_branch, 'pnl');
  perform app.require_metric_module_scope_v145(p_business, p_branch, 'sales');
  perform app.require_metric_module_scope_v145(p_business, p_branch, 'expenses');

  v_from_ts := p_from::timestamp at time zone 'Asia/Singapore';
  v_to_ts := (p_to + 1)::timestamp at time zone 'Asia/Singapore';

  select coalesce(sum(s.amount_cents), 0)
    into v_accrual
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
   where s.business_id = p_business
     and s.counts_as_revenue
     and s.occurred_at >= v_from_ts
     and s.occurred_at < v_to_ts
     and (p_branch is null or s.branch_id = p_branch)
     and not sc.is_synthetic_client;

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
     and (p_branch is null or p.branch_id = p_branch)
     and not exists (
       select 1 from public.clients c
       where c.id = s.client_id and c.is_synthetic
     );

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
     and (p_branch is null or s.branch_id = p_branch)
     and not exists (
       select 1 from public.clients c
       where c.id = s.client_id and c.is_synthetic
     );
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
     and (p_branch is null or b.branch_id = p_branch)
     and not exists (
       select 1 from public.clients c
       where c.id = b.client_id and c.is_synthetic
     );

  select coalesce(sum(round(e.amount_cents::numeric * e.fx_rate_to_base::numeric)), 0)::bigint
    into v_expenses
    from public.expenses e
   where e.business_id = p_business
     and e.voided_at is null
     and e.occurred_on between p_from and p_to
     and (p_branch is null or e.branch_id = p_branch);

  select coalesce(jsonb_object_agg(x.category, x.amount_cents order by x.category), '{}'::jsonb)
    into v_expenses_by_category
    from (
      select coalesce(nullif(btrim(e.category), ''), 'Uncategorised') as category,
             sum(round(e.amount_cents::numeric * e.fx_rate_to_base::numeric))::bigint as amount_cents
      from public.expenses e
      where e.business_id = p_business
        and e.voided_at is null
        and e.occurred_on between p_from and p_to
        and (p_branch is null or e.branch_id = p_branch)
      group by coalesce(nullif(btrim(e.category), ''), 'Uncategorised')
    ) x;

  with months as (
    select generate_series(
      date_trunc('month', p_from::timestamp),
      date_trunc('month', p_to::timestamp),
      interval '1 month'
    )::date as month_start
  ), revenue as (
    select date_trunc('month', s.occurred_at at time zone 'Asia/Singapore')::date as month_start,
           sum(s.amount_cents)::bigint as amount_cents
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= v_from_ts
      and s.occurred_at < v_to_ts
      and (p_branch is null or s.branch_id = p_branch)
      and not sc.is_synthetic_client
    group by 1
  ), expense as (
    select date_trunc('month', e.occurred_on::timestamp)::date as month_start,
           sum(round(e.amount_cents::numeric * e.fx_rate_to_base::numeric))::bigint as amount_cents
    from public.expenses e
    where e.business_id = p_business
      and e.voided_at is null
      and e.occurred_on between p_from and p_to
      and (p_branch is null or e.branch_id = p_branch)
    group by 1
  )
  select coalesce(jsonb_object_agg(
    to_char(m.month_start, 'YYYY-MM'),
    jsonb_build_object(
      'revenue_accrual_cents', coalesce(r.amount_cents, 0),
      'expenses_cents', coalesce(e.amount_cents, 0)
    ) order by m.month_start
  ), '{}'::jsonb)
  into v_monthly
  from months m
  left join revenue r using (month_start)
  left join expense e using (month_start);

  return json_build_object(
    'from', p_from,
    'to', p_to,
    'branch_id', p_branch,
    'timezone', 'Asia/Singapore',
    'revenue_accrual_cents', v_accrual,
    'revenue_cash_cents', v_cash,
    'cash_collected_cents', v_collected,
    'unpaid_balance_cents', v_unpaid,
    'expenses_cents', v_expenses,
    'expenses_scope', case when p_branch is null
      then 'all_business_expenses'
      else 'selected_branch_expenses_only_business_wide_overhead_excluded'
    end,
    'business_wide_overhead_excluded', p_branch is not null,
    'net_accrual_cents', v_accrual - v_expenses,
    'net_cash_cents', v_cash - v_expenses,
    'expenses_by_category', v_expenses_by_category,
    'monthly', v_monthly
  );
end $function$
;

do $check_public_get_revenue_summary$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$  select coalesce(sum(p.amount_cents), 0)
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
     and (p_branch is null or p.branch_id = p_branch);$lit$;
  v_new1 constant text := $lit$  select coalesce(sum(p.amount_cents), 0)
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
     and (p_branch is null or p.branch_id = p_branch)
     and not exists (
       select 1 from public.clients c
       where c.id = s.client_id and c.is_synthetic
     );$lit$;
  v_old2 constant text := $lit$  select coalesce(sum(t.reserved_cents), 0)
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
     and (p_branch is null or s.branch_id = p_branch);$lit$;
  v_new2 constant text := $lit$  select coalesce(sum(t.reserved_cents), 0)
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
     and (p_branch is null or s.branch_id = p_branch)
     and not exists (
       select 1 from public.clients c
       where c.id = s.client_id and c.is_synthetic
     );$lit$;
  v_old3 constant text := $lit$  select coalesce(sum(b.balance_cents), 0)
    into v_unpaid
    from public.sale_balance b
   where b.business_id = p_business
     and b.counts_as_revenue
     and b.balance_cents > 0
     and b.occurred_at >= v_from_ts
     and b.occurred_at < v_to_ts
     and (p_branch is null or b.branch_id = p_branch);$lit$;
  v_new3 constant text := $lit$  select coalesce(sum(b.balance_cents), 0)
    into v_unpaid
    from public.sale_balance b
   where b.business_id = p_business
     and b.counts_as_revenue
     and b.balance_cents > 0
     and b.occurred_at >= v_from_ts
     and b.occurred_at < v_to_ts
     and (p_branch is null or b.branch_id = p_branch)
     and not exists (
       select 1 from public.clients c
       where c.id = b.client_id and c.is_synthetic
     );$lit$;
begin
  select def into v_before from _v744_before where fn = $lit$get_revenue_summary$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = $lit$public$lit$ and p.proname = $lit$get_revenue_summary$lit$;
  if position(v_old1 in v_before) = 0 then
    raise exception 'public.get_revenue_summary: hunk 1 anchor not found in captured body';
  end if;
  if position(v_old2 in v_before) = 0 then
    raise exception 'public.get_revenue_summary: hunk 2 anchor not found in captured body';
  end if;
  if position(v_old3 in v_before) = 0 then
    raise exception 'public.get_revenue_summary: hunk 3 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  v_expect := replace(v_expect, v_old2, v_new2);
  v_expect := replace(v_expect, v_old3, v_new3);
  if v_expect <> v_after then
    raise exception 'public.get_revenue_summary: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check_public_get_revenue_summary$;

-- =============================================================================================
-- 6 . app.v177_overview -- outstanding, historical_programmes, credit_cents
-- =============================================================================================
CREATE OR REPLACE FUNCTION app.v177_overview(p_business uuid, p_branch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_today date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_current_from date;
  v_prior_from date;
  v_prior_to date;
  v_current jsonb;
  v_prior jsonb;
  v_growth jsonb;
begin
  v_current_from := v_today - 29;
  v_prior_to := v_today - 30;
  v_prior_from := v_today - 59;

  if p_branch is null then
    v_current := app.v176_sales_window(p_business, v_current_from, v_today);
    v_prior := app.v176_sales_window(p_business, v_prior_from, v_prior_to);
  else
    v_current := app.v177_sales_window(p_business, p_branch, v_current_from, v_today);
    v_prior := app.v177_sales_window(p_business, p_branch, v_prior_from, v_prior_to);
  end if;

  v_growth := jsonb_build_object(
    'net_revenue_pct', case
      when coalesce((v_prior->>'net_revenue_cents')::numeric, 0) = 0 then null
      else round(
        ((v_current->>'net_revenue_cents')::numeric
          - (v_prior->>'net_revenue_cents')::numeric)
        * 100 / (v_prior->>'net_revenue_cents')::numeric, 1)
    end,
    'visits_delta',
      coalesce((v_current->>'visits')::bigint, 0)
      - coalesce((v_prior->>'visits')::bigint, 0),
    'new_customers_delta',
      coalesce((v_current->>'new_customers')::bigint, 0)
      - coalesce((v_prior->>'new_customers')::bigint, 0)
  );

  return jsonb_build_object(
    'window', jsonb_build_object(
      'current', jsonb_build_object('from', v_current_from, 'to', v_today),
      'prior', jsonb_build_object('from', v_prior_from, 'to', v_prior_to)
    ),
    'sales', jsonb_build_object(
      'current', v_current, 'prior', v_prior, 'growth', v_growth
    ),
    -- v175 account-open days carry no branch, so this block is always the
    -- whole firm. It is labelled as such rather than silently branch-filtered.
    'account_opens', jsonb_build_object(
      'scope', 'whole_firm',
      'current', app.v176_account_opens_window(p_business, v_current_from, v_today),
      'prior', app.v176_account_opens_window(p_business, v_prior_from, v_prior_to)
    ),
    /* v545: the superadmin mirror carried the same cross-unit total as the AI pack - a firm's
       loyalty liability read 35% high on Cubbly because a dormant stamps pot was added to a live
       points one. Same shape as v179 now: one programme per figure, each with its unit, no total. */
    'outstanding', jsonb_build_object(
      'scope', 'whole_firm',
      'active_programme', jsonb_build_object(
        'programme_id', app.live_balance_programme_v381(p_business),
        'unit', (select spine.kind from public.business_programmes spine
                    where spine.id = app.live_balance_programme_v381(p_business)),
        'is_running', app.live_balance_programme_v381(p_business) is not null,
        'outstanding', case when app.live_balance_programme_v381(p_business) is null then null
          else coalesce((select sum(entry.points) from public.points_ledger entry
                          join public.clients entry_c on entry_c.id = entry.client_id
                            and entry_c.business_id = entry.business_id
                          where entry.business_id = p_business
                            and entry.programme_id = app.live_balance_programme_v381(p_business)
                            and not entry_c.is_synthetic), 0)
          end
      ),
      'historical_programmes', coalesce((
        select jsonb_agg(jsonb_build_object('unit', spine.kind, 'outstanding', tag.points)
                 order by spine.sort)
          from (
            select entry.programme_id, sum(entry.points) as points
              from public.points_ledger entry
              join public.clients entry_c on entry_c.id = entry.client_id
                and entry_c.business_id = entry.business_id
             where entry.business_id = p_business
               and entry.programme_id is distinct from app.live_balance_programme_v381(p_business)
               and not entry_c.is_synthetic
             group by entry.programme_id
          ) tag
          join public.business_programmes spine on spine.id = tag.programme_id
         where tag.points <> 0
      ), '[]'::jsonb),
      'unit_rule',
        'Balances in different units are never combined; there is no total across programmes.',
      'credit_cents', coalesce(
        (select sum(entry.amount_cents) from public.credit_ledger entry
         join public.clients entry_c on entry_c.id = entry.client_id
           and entry_c.business_id = entry.business_id
         where entry.business_id = p_business
           and not entry_c.is_synthetic), 0
      )
    ),
    'counts', jsonb_build_object(
      'customers', (
        select count(*) from public.clients client
        where client.business_id = p_business
          and coalesce(client.is_synthetic, false) = false
      ),
      'active_staff', (
        select count(*) from public.staff member
        where member.business_id = p_business and member.active
      ),
      'active_branches', (
        select count(*) from public.branches branch
        where branch.business_id = p_business and branch.active
      )
    )
  );
end
$function$
;

do $check_app_v177_overview$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$        'outstanding', case when app.live_balance_programme_v381(p_business) is null then null
          else coalesce((select sum(entry.points) from public.points_ledger entry
                          where entry.business_id = p_business
                            and entry.programme_id = app.live_balance_programme_v381(p_business)), 0)
          end
      ),$lit$;
  v_new1 constant text := $lit$        'outstanding', case when app.live_balance_programme_v381(p_business) is null then null
          else coalesce((select sum(entry.points) from public.points_ledger entry
                          join public.clients entry_c on entry_c.id = entry.client_id
                            and entry_c.business_id = entry.business_id
                          where entry.business_id = p_business
                            and entry.programme_id = app.live_balance_programme_v381(p_business)
                            and not entry_c.is_synthetic), 0)
          end
      ),$lit$;
  v_old2 constant text := $lit$      'historical_programmes', coalesce((
        select jsonb_agg(jsonb_build_object('unit', spine.kind, 'outstanding', tag.points)
                 order by spine.sort)
          from (
            select entry.programme_id, sum(entry.points) as points
              from public.points_ledger entry
             where entry.business_id = p_business
               and entry.programme_id is distinct from app.live_balance_programme_v381(p_business)
             group by entry.programme_id
          ) tag
          join public.business_programmes spine on spine.id = tag.programme_id
         where tag.points <> 0
      ), '[]'::jsonb),$lit$;
  v_new2 constant text := $lit$      'historical_programmes', coalesce((
        select jsonb_agg(jsonb_build_object('unit', spine.kind, 'outstanding', tag.points)
                 order by spine.sort)
          from (
            select entry.programme_id, sum(entry.points) as points
              from public.points_ledger entry
              join public.clients entry_c on entry_c.id = entry.client_id
                and entry_c.business_id = entry.business_id
             where entry.business_id = p_business
               and entry.programme_id is distinct from app.live_balance_programme_v381(p_business)
               and not entry_c.is_synthetic
             group by entry.programme_id
          ) tag
          join public.business_programmes spine on spine.id = tag.programme_id
         where tag.points <> 0
      ), '[]'::jsonb),$lit$;
  v_old3 constant text := $lit$      'credit_cents', coalesce(
        (select sum(entry.amount_cents) from public.credit_ledger entry
         where entry.business_id = p_business), 0
      )$lit$;
  v_new3 constant text := $lit$      'credit_cents', coalesce(
        (select sum(entry.amount_cents) from public.credit_ledger entry
         join public.clients entry_c on entry_c.id = entry.client_id
           and entry_c.business_id = entry.business_id
         where entry.business_id = p_business
           and not entry_c.is_synthetic), 0
      )$lit$;
begin
  select def into v_before from _v744_before where fn = $lit$v177_overview$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = $lit$app$lit$ and p.proname = $lit$v177_overview$lit$;
  if position(v_old1 in v_before) = 0 then
    raise exception 'app.v177_overview: hunk 1 anchor not found in captured body';
  end if;
  if position(v_old2 in v_before) = 0 then
    raise exception 'app.v177_overview: hunk 2 anchor not found in captured body';
  end if;
  if position(v_old3 in v_before) = 0 then
    raise exception 'app.v177_overview: hunk 3 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  v_expect := replace(v_expect, v_old2, v_new2);
  v_expect := replace(v_expect, v_old3, v_new3);
  if v_expect <> v_after then
    raise exception 'app.v177_overview: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check_app_v177_overview$;

-- =============================================================================================
-- 7 . app.v179_business_insights -- points_window earn/redeem, outstanding, historical_programmes
-- =============================================================================================
CREATE OR REPLACE FUNCTION app.v179_business_insights(p_business uuid, p_from date, p_to date, p_prior_from date, p_prior_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
  with tzinfo as (
    select app.ci_bucket_tz_v698(p_business, null) as info
  ), bounds as (
    select
      p_from::timestamp at time zone 'Asia/Singapore' as from_ts,
      (p_to + 1)::timestamp at time zone 'Asia/Singapore' as to_ts,
      p_prior_from::timestamp at time zone 'Asia/Singapore' as prior_from_ts,
      (p_prior_to + 1)::timestamp at time zone 'Asia/Singapore' as prior_to_ts,
      (p_to + 1)::timestamp at time zone 'Asia/Singapore' - interval '45 days' as at_risk_before_ts,
      (p_to + 1)::timestamp at time zone 'Asia/Singapore' - interval '180 days' as at_risk_after_ts
  ), lifetime_sales as (
    -- All unreversed visit/revenue-bearing sales for real clients of this firm.
    select sale.id, sale.client_id, sale.amount_cents, sale.occurred_at,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and coalesce(client.is_synthetic, false) = false
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.client_id is not null
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), client_lifetime as (
    select client_id,
      min(occurred_at) filter (where counts_as_visit) as first_visit_at,
      max(occurred_at) filter (where counts_as_visit) as last_visit_at,
      count(distinct app.ci_visit_day_v699(occurred_at)) filter (where counts_as_visit) as lifetime_visits,
      coalesce(sum(amount_cents) filter (where counts_as_revenue), 0) as lifetime_revenue_cents
    from lifetime_sales
    group by client_id
  ), window_sales as (
    select lifetime_sales.*
    from lifetime_sales, bounds
    where occurred_at >= bounds.from_ts and occurred_at < bounds.to_ts
  ), window_clients as (
    select ws.client_id,
      coalesce(sum(ws.amount_cents) filter (where ws.counts_as_revenue), 0) as revenue_cents,
      count(distinct app.ci_visit_day_v699(ws.occurred_at)) filter (where ws.counts_as_visit) as visits,
      bool_and(cl.first_visit_at >= bounds.from_ts) as is_new
    from window_sales ws
    join client_lifetime cl on cl.client_id = ws.client_id
    cross join bounds
    group by ws.client_id
  ), window_revenue as (
    select coalesce(sum(revenue_cents), 0) as total_cents from window_clients
  ), prior_new_clients as (
    -- Clients whose first-ever visit fell in the PRIOR window.
    select cl.client_id
    from client_lifetime cl, bounds
    where cl.first_visit_at >= bounds.prior_from_ts
      and cl.first_visit_at < bounds.prior_to_ts
  ), prior_new_returned as (
    select count(*) as returned
    from prior_new_clients pnc
    where exists(select 1 from window_clients wc
                 where wc.client_id = pnc.client_id and wc.visits > 0)
  ), at_risk as (
    -- Regulars (2+ lifetime visits) whose last visit is 45-180 days old at
    -- period end. Recovery value = one visit each at their own average ticket.
    select cl.client_id,
      cl.lifetime_visits,
      cl.lifetime_revenue_cents,
      case when cl.lifetime_visits > 0
        then (cl.lifetime_revenue_cents / cl.lifetime_visits)::bigint
        else 0 end as avg_ticket_cents
    from client_lifetime cl, bounds
    where cl.lifetime_visits >= 2
      and cl.last_visit_at < bounds.at_risk_before_ts
      and cl.last_visit_at >= bounds.at_risk_after_ts
  ), window_all_sales as (
    -- v548: THE headline population. These filters replicate app.v176_sales_window.valid_sales
    -- verbatim (no client filter, no synthetic-client exclusion), so any partition built on this
    -- CTE sums to the headline by construction. Do not "tidy" the filters into matching
    -- lifetime_sales - the mismatch is the bug this migration exists to end.
    select sale.id, sale.client_id, sale.amount_cents, sale.occurred_at,
           sale.counts_as_revenue as counts_as_revenue,
           sale.counts_as_visit as counts_as_visit
      from public.sales sale, bounds
     where sale.business_id = p_business
       and sale.reversal_of is null
       and sale.occurred_at >= bounds.from_ts and sale.occurred_at < bounds.to_ts
       and not exists(
         select 1 from public.sales reversal
          where reversal.business_id = sale.business_id
            and reversal.reversal_of = sale.id
       )
  ), window_all_revenue as (
    select coalesce(sum(amount_cents) filter (where counts_as_revenue), 0) as total_cents
      from window_all_sales
  ), weekday as (
    -- nestly_v715: visits dedupe by (client_id, app.ci_visit_day_v699(occurred_at)) -- the same
    -- SG-anchored visit-day identity every other visit-counting reader in the estate uses since
    -- nestly_v699 -- grouped into the isodow bucket the resolved bucket_timezone assigns each row
    -- to. Anonymous (no client_id) sales cannot be deduped by customer identity and each still
    -- counts on its own, same fallback as nestly_v714.
    select isodow,
      coalesce(sum(amount_cents) filter (where counts_as_revenue), 0) as revenue_cents,
      count(distinct (client_id, visit_day)) filter (where counts_as_visit and client_id is not null)
        + count(*) filter (where counts_as_visit and client_id is null) as visits
    from (
      select
        extract(isodow from (occurred_at at time zone (select info->>'timezone' from tzinfo)))::int as isodow,
        client_id,
        app.ci_visit_day_v699(occurred_at) as visit_day,
        amount_cents,
        counts_as_revenue,
        counts_as_visit
      from window_all_sales
    ) w
    group by isodow
  ), items as (
    select si.description,
      sum(si.qty)::bigint as qty,
      coalesce(sum(si.line_cents), 0)::bigint as revenue_cents
    from public.sale_items si
    join window_all_sales ws on ws.id = si.sale_id
    where si.business_id = p_business
    group by si.description
  ), points_window as (
    select
      coalesce(sum(points) filter (where entry_type = 'earn'), 0)::bigint as earned,
      coalesce(-sum(points) filter (where entry_type = 'redeem'), 0)::bigint as redeemed
    from public.points_ledger
    join public.clients points_ledger_c on points_ledger_c.id = points_ledger.client_id
      and points_ledger_c.business_id = points_ledger.business_id, bounds
    where points_ledger.business_id = p_business
      -- v545: earn and redeem belong to ONE pot. Unscoped, Cubbly read 4893 where the
      -- pot-scoped figure every other surface reports for the same window is 4840.
      and programme_id is not distinct from app.live_balance_programme_v381(p_business)
      and points_ledger.created_at >= bounds.from_ts and points_ledger.created_at < bounds.to_ts
      and not points_ledger_c.is_synthetic
  )
  select pg_catalog.jsonb_build_object(
    'contract_version', 'v179',
    'visit_definition',
      'one per customer per calendar day (Asia/Singapore); split bills count once; lifetime_visits and top_customers.visits count distinct visit-days, not raw sales',
    'identification', pg_catalog.jsonb_build_object(
      'total_revenue_cents', (select total_cents from window_all_revenue),
      'identified_revenue_cents', (select total_cents from window_revenue),
      'identified_revenue_share_pct', (
        select case when a.total_cents = 0 then null
          else round(100.0 * i.total_cents / a.total_cents, 1) end
        from window_all_revenue a, window_revenue i
      ),
      'anonymous_sales', (select count(*) from window_all_sales where client_id is null),
      'note', 'retention, at_risk and top_customers describe identified customers only; weekday_pattern and items cover all sales including anonymous'
    ),
    'retention', pg_catalog.jsonb_build_object(
      'scope', 'identified_customers_only',
      'customers_served', (select count(*) from window_clients where visits > 0),
      'new_customers', (select count(*) from window_clients where is_new and visits > 0),
      /* v545: this counts customers who had bought BEFORE the window and bought again in it.
         That is an existing-customer return share, not a repeat rate, and the two differ by 20
         points on the same tenant and month. The computation is unchanged; only the name is. */
      'existing_customers_who_returned', (select count(*) from window_clients where not is_new and visits > 0),
      'existing_customer_return_rate_pct',
        case when (app.subgroup_evidence_v1((select count(*) filter (where visits > 0) from window_clients)::int)->>'status') = 'insufficient'
          then null
          else (
            select case when count(*) filter (where visits > 0) = 0 then null
              else round(100.0 * count(*) filter (where not is_new and visits > 0)
                         / count(*) filter (where visits > 0), 1) end
            from window_clients
          ) end,
      'existing_customer_return_evidence',
        app.subgroup_evidence_v1((select count(*) filter (where visits > 0) from window_clients)::int),
      'prior_period_new_customers', (select count(*) from prior_new_clients),
      'prior_new_who_returned_this_period', (select returned from prior_new_returned),
      'prior_new_return_rate_pct',
        case when (app.subgroup_evidence_v1((select count(*) from prior_new_clients)::int)->>'status') = 'insufficient'
          then null
          else (
            select case when (select count(*) from prior_new_clients) = 0 then null
              else round(100.0 * (select returned from prior_new_returned)
                         / (select count(*) from prior_new_clients), 1) end
          ) end,
      'prior_new_evidence', app.subgroup_evidence_v1((select count(*) from prior_new_clients)::int),
      'evidence_class', 'DIRECT_FACT'
    ),
    'at_risk', pg_catalog.jsonb_build_object(
      'scope', 'identified_customers_only',
      'definition', 'customers with 2+ lifetime visits whose last visit is 45-180 days before period end',
      'customers', (select count(*) from at_risk),
      'their_lifetime_revenue_cents', (select coalesce(sum(lifetime_revenue_cents), 0) from at_risk),
      'recovery_value_one_visit_each_cents',
        case when (app.subgroup_evidence_v1((select count(*) from at_risk)::int)->>'status') = 'insufficient'
          then null
          else (select coalesce(sum(avg_ticket_cents), 0) from at_risk) end,
      'evidence', app.subgroup_evidence_v1((select count(*) from at_risk)::int),
      'evidence_class', 'ASSOCIATION',
      'evidence_class_note', 'a fixed 45-180 day absence window is a heuristic threshold, not a customer-specific prediction of return'
    ),
    'top_customers', pg_catalog.jsonb_build_object(
      'scope', 'identified_customers_only',
      'rows',
        case when (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>'status') = 'insufficient'
          then '[]'::jsonb
          else coalesce((
            select jsonb_agg(jsonb_build_object(
              'label', app.v177_person_label(client.full_name, wc.client_id),
              'revenue_cents', wc.revenue_cents,
              'visits', wc.visits,
              'is_new_this_period', wc.is_new
            ) order by wc.revenue_cents desc, wc.client_id)
            from (select * from window_clients order by revenue_cents desc limit 5) wc
            join public.clients client on client.id = wc.client_id
            where wc.revenue_cents > 0
          ), '[]'::jsonb) end,
      'top1_share_of_total_revenue_pct',
        case when (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>'status') = 'insufficient'
          then null
          else (
            select case when wa.total_cents = 0 then null
              else round(100.0 * (select max(revenue_cents) from window_clients) / wa.total_cents, 1) end
            from window_all_revenue wa
          ) end,
      'top5_share_of_total_revenue_pct',
        case when (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>'status') = 'insufficient'
          then null
          else (
            select case when wa.total_cents = 0 then null
              else round(100.0 * (
                select coalesce(sum(revenue_cents), 0)
                  from (select revenue_cents from window_clients order by revenue_cents desc limit 5) top5
              ) / wa.total_cents, 1) end
            from window_all_revenue wa
          ) end,
      /* v551: the expressions below are the PRE-v551 fields verbatim — only the names changed,
         to say what the denominator has always been. */
      'top1_share_of_identified_revenue_pct',
        case when (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>'status') = 'insufficient'
          then null
          else (
            select case when wr.total_cents = 0 then null
              else round(100.0 * (select max(revenue_cents) from window_clients) / wr.total_cents, 1) end
            from window_revenue wr
          ) end,
      'top5_share_of_identified_revenue_pct',
        case when (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>'status') = 'insufficient'
          then null
          else (
            select case when wr.total_cents = 0 then null
              else round(100.0 * (
                select coalesce(sum(revenue_cents), 0)
                from (select revenue_cents from window_clients
                      order by revenue_cents desc limit 5) top5
              ) / wr.total_cents, 1) end
            from window_revenue wr
          ) end,
      'evidence', app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int),
      'suppressed',
        case when (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>'status') = 'insufficient'
          then jsonb_build_object(
            'reason', 'below_small_cell_floor',
            'floor', (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>'floor')::int,
            'cohort_size', (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>'n')::int)
          else null end,
      'evidence_class', 'DIRECT_FACT'
    ),
    'weekday_pattern', pg_catalog.jsonb_build_object(
      'note', 'isodow: 1=Monday .. 7=Sunday, bucketed at bucket_timezone (see below); all sales including anonymous',
      'bucket_timezone', (select info->>'timezone' from tzinfo),
      'timezone_basis', (select info->>'timezone_basis' from tzinfo),
      'visit_definition', 'visits count distinct customer-visit-days (Asia/Singapore-anchored, via app.ci_visit_day_v699), placed in the weekday their sales fell on at bucket_timezone; a same-day split bill counts once, anonymous (no client_id) sales each count as their own visit',
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
          'isodow', isodow, 'revenue_cents', revenue_cents, 'visits', visits
        ) order by isodow) from weekday
      ), '[]'::jsonb),
      'best_isodow', (select isodow from weekday order by revenue_cents desc, isodow limit 1),
      'quietest_isodow', (select isodow from weekday order by revenue_cents asc, isodow limit 1),
      'evidence_class', 'DIRECT_FACT'
    ),
    'items', pg_catalog.jsonb_build_object(
      'note', 'line-item data may cover only part of revenue; see coverage_pct before generalising',
      'coverage_pct', (
        select case when wr.total_cents = 0 then null
          else round(100.0 * (select coalesce(sum(revenue_cents), 0) from items) / wr.total_cents, 1) end
        from window_all_revenue wr
      ),
      'top_items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'description', description, 'qty', qty, 'revenue_cents', revenue_cents
        ) order by revenue_cents desc)
        from (select * from items order by revenue_cents desc limit 5) top_items
      ), '[]'::jsonb)
    ),
    /* v545: one programme per figure, every figure carrying its unit. There is deliberately no
       total: adding points to stamps produces a number with no unit, and a field holding it is an
       invitation to quote it. Split pots now get MORE detail, not less - the old shape withheld
       the breakdown precisely when the pots were split. */
    'loyalty', pg_catalog.jsonb_build_object(
      'active_programme', pg_catalog.jsonb_build_object(
        'programme_id', app.live_balance_programme_v381(p_business),
        'unit', (select spine.kind from public.business_programmes spine
                    where spine.id = app.live_balance_programme_v381(p_business)),
        'is_running', app.live_balance_programme_v381(p_business) is not null,
        'outstanding', case when app.live_balance_programme_v381(p_business) is null then null
          else coalesce((select sum(entry.points) from public.points_ledger entry
                          join public.clients entry_c on entry_c.id = entry.client_id
                            and entry_c.business_id = entry.business_id
                          where entry.business_id = p_business
                            and entry.programme_id = app.live_balance_programme_v381(p_business)
                            and not entry_c.is_synthetic), 0)
          end,
        'earned_this_period', (select earned from points_window),
        'redeemed_this_period', (select redeemed from points_window),
        'redemption_rate_pct', (
          select case when earned = 0 then null
            else round(100.0 * redeemed / earned, 1) end from points_window
        )
      ),
      'historical_programmes', coalesce((
        select pg_catalog.jsonb_agg(
                 pg_catalog.jsonb_build_object('unit', spine.kind, 'outstanding', tag.points)
                 order by spine.sort)
          from (
            select entry.programme_id, sum(entry.points) as points
              from public.points_ledger entry
              join public.clients entry_c on entry_c.id = entry.client_id
                and entry_c.business_id = entry.business_id
             where entry.business_id = p_business
               and entry.programme_id is distinct from app.live_balance_programme_v381(p_business)
               and not entry_c.is_synthetic
             group by entry.programme_id
          ) tag
          join public.business_programmes spine on spine.id = tag.programme_id
         where tag.points <> 0
      ), '[]'::jsonb),
      'unit_rule',
        'Each figure belongs to one programme and carries its unit. Points and stamps are different things: never add them together, never convert between them, and never state a total across programmes.'
    )
  )
$function$
;

do $check_app_v179_business_insights$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$  ), points_window as (
    select
      coalesce(sum(points) filter (where entry_type = 'earn'), 0)::bigint as earned,
      coalesce(-sum(points) filter (where entry_type = 'redeem'), 0)::bigint as redeemed
    from public.points_ledger, bounds
    where business_id = p_business
      -- v545: earn and redeem belong to ONE pot. Unscoped, Cubbly read 4893 where the
      -- pot-scoped figure every other surface reports for the same window is 4840.
      and programme_id is not distinct from app.live_balance_programme_v381(p_business)
      and created_at >= bounds.from_ts and created_at < bounds.to_ts
  )$lit$;
  v_new1 constant text := $lit$  ), points_window as (
    select
      coalesce(sum(points) filter (where entry_type = 'earn'), 0)::bigint as earned,
      coalesce(-sum(points) filter (where entry_type = 'redeem'), 0)::bigint as redeemed
    from public.points_ledger
    join public.clients points_ledger_c on points_ledger_c.id = points_ledger.client_id
      and points_ledger_c.business_id = points_ledger.business_id, bounds
    where points_ledger.business_id = p_business
      -- v545: earn and redeem belong to ONE pot. Unscoped, Cubbly read 4893 where the
      -- pot-scoped figure every other surface reports for the same window is 4840.
      and programme_id is not distinct from app.live_balance_programme_v381(p_business)
      and points_ledger.created_at >= bounds.from_ts and points_ledger.created_at < bounds.to_ts
      and not points_ledger_c.is_synthetic
  )$lit$;
  v_old2 constant text := $lit$        'outstanding', case when app.live_balance_programme_v381(p_business) is null then null
          else coalesce((select sum(entry.points) from public.points_ledger entry
                          where entry.business_id = p_business
                            and entry.programme_id = app.live_balance_programme_v381(p_business)), 0)
          end,$lit$;
  v_new2 constant text := $lit$        'outstanding', case when app.live_balance_programme_v381(p_business) is null then null
          else coalesce((select sum(entry.points) from public.points_ledger entry
                          join public.clients entry_c on entry_c.id = entry.client_id
                            and entry_c.business_id = entry.business_id
                          where entry.business_id = p_business
                            and entry.programme_id = app.live_balance_programme_v381(p_business)
                            and not entry_c.is_synthetic), 0)
          end,$lit$;
  v_old3 constant text := $lit$      'historical_programmes', coalesce((
        select pg_catalog.jsonb_agg(
                 pg_catalog.jsonb_build_object('unit', spine.kind, 'outstanding', tag.points)
                 order by spine.sort)
          from (
            select entry.programme_id, sum(entry.points) as points
              from public.points_ledger entry
             where entry.business_id = p_business
               and entry.programme_id is distinct from app.live_balance_programme_v381(p_business)
             group by entry.programme_id
          ) tag
          join public.business_programmes spine on spine.id = tag.programme_id$lit$;
  v_new3 constant text := $lit$      'historical_programmes', coalesce((
        select pg_catalog.jsonb_agg(
                 pg_catalog.jsonb_build_object('unit', spine.kind, 'outstanding', tag.points)
                 order by spine.sort)
          from (
            select entry.programme_id, sum(entry.points) as points
              from public.points_ledger entry
              join public.clients entry_c on entry_c.id = entry.client_id
                and entry_c.business_id = entry.business_id
             where entry.business_id = p_business
               and entry.programme_id is distinct from app.live_balance_programme_v381(p_business)
               and not entry_c.is_synthetic
             group by entry.programme_id
          ) tag
          join public.business_programmes spine on spine.id = tag.programme_id$lit$;
begin
  select def into v_before from _v744_before where fn = $lit$v179_business_insights$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = $lit$app$lit$ and p.proname = $lit$v179_business_insights$lit$;
  if position(v_old1 in v_before) = 0 then
    raise exception 'app.v179_business_insights: hunk 1 anchor not found in captured body';
  end if;
  if position(v_old2 in v_before) = 0 then
    raise exception 'app.v179_business_insights: hunk 2 anchor not found in captured body';
  end if;
  if position(v_old3 in v_before) = 0 then
    raise exception 'app.v179_business_insights: hunk 3 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  v_expect := replace(v_expect, v_old2, v_new2);
  v_expect := replace(v_expect, v_old3, v_new3);
  if v_expect <> v_after then
    raise exception 'app.v179_business_insights: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check_app_v179_business_insights$;

-- =============================================================================================
-- 8 . app.get_growth_execution_result_at_v108 -- v_overlap identity-overlap detector
-- =============================================================================================
CREATE OR REPLACE FUNCTION app.get_growth_execution_result_at_v108(p_execution uuid, p_as_of timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_execution public.growth_executions_v108%rowtype;
  v_t_members integer:=0;
  v_h_members integer:=0;
  v_t_buyers integer:=0;
  v_h_buyers integer:=0;
  v_t_revenue bigint:=0;
  v_h_revenue bigint:=0;
  v_t_rate numeric:=0;
  v_h_rate numeric:=0;
  v_lift numeric:=0;
  v_se numeric:=0;
  v_aov numeric:=0;
  v_estimate bigint:=0;
  v_low bigint:=0;
  v_high bigint:=0;
  v_overlap integer:=0;
  v_identity_overlap integer:=0;
  v_measurement text;
begin
  if p_as_of is null then
    raise exception 'reporting cutoff is required' using errcode='22004';
  end if;
  select * into v_execution
    from public.growth_executions_v108 execution
   where execution.id=p_execution;
  if not found then raise exception 'execution not found'; end if;
  if auth.uid() is null or (
    not app.is_super_admin()
    and (
      not app.has_perm(v_execution.business_id,'view_finance')
      or not app.can_module_read(v_execution.business_id,'retention')
    )
  ) then
    raise exception 'finance and retention access required' using errcode='42501';
  end if;
  if not app.can_see_branch(v_execution.business_id,v_execution.branch_id) then
    raise exception 'execution branch is outside actor scope' using errcode='42501';
  end if;

  with effective_members as (
    select member.*,
      app.v113_effective_client_id(member.business_id,member.client_id)
        as effective_client_id,
      row_number() over (
        partition by app.v113_effective_client_id(
          member.business_id,member.client_id
        )
        order by member.assignment_rank,member.id
      ) as identity_rank,
      count(*) over (
        partition by app.v113_effective_client_id(
          member.business_id,member.client_id
        )
      ) as identity_count
    from public.growth_execution_members_v108 member
    join public.clients client
      on client.id=member.client_id and client.business_id=member.business_id
    where member.execution_id=p_execution
      and not client.is_synthetic
  ),
  member_result as (
    select member.assignment,member.client_id,member.effective_client_id,
      member.identity_count,
      exists (
        select 1 from public.sales sale
         where sale.business_id=v_execution.business_id
           and sale.client_id is not null
           and app.v113_effective_client_id(sale.business_id,sale.client_id)
               =member.effective_client_id
           and sale.counts_as_visit
           and sale.counts_as_revenue
           and sale.reversal_of is null
           and sale.created_at<=p_as_of
           and sale.occurred_at<=p_as_of
           and (
             v_execution.branch_id is null
             or sale.branch_id=v_execution.branch_id
           )
           and sale.occurred_at>=v_execution.started_at
           and sale.occurred_at<v_execution.ends_at
           and app.v106_sale_residual_minor(sale.id,p_as_of)>0
      ) as purchased,
      coalesce((
        select sum(app.v106_sale_residual_minor(sale.id,p_as_of))
          from public.sales sale
         where sale.business_id=v_execution.business_id
           and sale.client_id is not null
           and app.v113_effective_client_id(sale.business_id,sale.client_id)
               =member.effective_client_id
           and sale.counts_as_revenue
           and sale.reversal_of is null
           and sale.created_at<=p_as_of
           and sale.occurred_at<=p_as_of
           and (
             v_execution.branch_id is null
             or sale.branch_id=v_execution.branch_id
           )
           and sale.occurred_at>=v_execution.started_at
           and sale.occurred_at<v_execution.ends_at
           and app.v106_sale_residual_minor(sale.id,p_as_of)>0
      ),0)::bigint as revenue_cents
    from effective_members member
    where member.identity_rank=1
  )
  select
    count(*) filter(where assignment='treatment'),
    count(*) filter(where assignment='holdout'),
    count(*) filter(where assignment='treatment' and purchased),
    count(*) filter(where assignment='holdout' and purchased),
    coalesce(sum(revenue_cents) filter(where assignment='treatment'),0),
    coalesce(sum(revenue_cents) filter(where assignment='holdout'),0),
    count(*) filter(where identity_count>1)
  into v_t_members,v_h_members,v_t_buyers,v_h_buyers,
       v_t_revenue,v_h_revenue,v_identity_overlap
  from member_result;

  select count(*) into v_overlap
    from public.growth_outcomes_v108 outcome
    join public.growth_execution_members_v108 member
      on member.id=outcome.execution_member_id
     and member.business_id=outcome.business_id
    join public.sales sale
      on sale.id=outcome.sale_id
     and sale.business_id=outcome.business_id
    join public.clients member_client
      on member_client.id=member.client_id
     and member_client.business_id=member.business_id
   where outcome.execution_id=p_execution
     and not outcome.causal_eligible
     and outcome.occurred_at<=p_as_of
     and app.v106_sale_residual_minor(outcome.sale_id,p_as_of)>0
     and sale.client_id is not null
     and app.v113_effective_client_id(sale.business_id,sale.client_id)
         =app.v113_effective_client_id(member.business_id,member.client_id)
     and not member_client.is_synthetic;
  v_t_rate:=case when v_t_members>0
    then v_t_buyers::numeric/v_t_members else 0 end;
  v_h_rate:=case when v_h_members>0
    then v_h_buyers::numeric/v_h_members else 0 end;
  v_lift:=v_t_rate-v_h_rate;
  v_se:=case when v_t_members>0 and v_h_members>0 then sqrt(
    greatest(0,v_t_rate*(1-v_t_rate)/v_t_members)
    +greatest(0,v_h_rate*(1-v_h_rate)/v_h_members)
  ) else 0 end;
  v_aov:=case when v_t_buyers+v_h_buyers>0
    then (v_t_revenue+v_h_revenue)::numeric/(v_t_buyers+v_h_buyers)
    else 0 end;
  v_estimate:=round(v_lift*v_t_members*v_aov);
  v_low:=round((v_lift-1.96*v_se)*v_t_members*v_aov);
  v_high:=round((v_lift+1.96*v_se)*v_t_members*v_aov);
  v_measurement:=case
    when v_identity_overlap>0 then 'invalid_overlap'
    when v_overlap>0 then 'invalid_overlap'
    when v_t_members<v_execution.minimum_arm_size
      or v_h_members<v_execution.minimum_arm_size
      then 'inconclusive_small_sample'
    when p_as_of<v_execution.ends_at then 'provisional'
    else 'final'
  end;
  return jsonb_build_object(
    'execution_id',p_execution,'business_id',v_execution.business_id,
    'as_of',p_as_of,'status',v_execution.status,
    'window',jsonb_build_object(
      'start',v_execution.started_at,'end',v_execution.ends_at
    ),
    'method','randomized_intent_to_treat_holdout',
    'identity_attribution','v111_current_effective_identity',
    'measurement_status',v_measurement,
    'arms',jsonb_build_object(
      'treatment',jsonb_build_object(
        'members',v_t_members,'buyers',v_t_buyers,
        'conversion_rate_bps',round(v_t_rate*10000),
        'associated_revenue_cents',v_t_revenue
      ),
      'holdout',jsonb_build_object(
        'members',v_h_members,'buyers',v_h_buyers,
        'conversion_rate_bps',round(v_h_rate*10000),
        'associated_revenue_cents',v_h_revenue
      )
    ),
    'incremental_conversion_lift_bps',round(v_lift*10000),
    'estimated_incremental_revenue',case
      when v_measurement in ('invalid_overlap','inconclusive_small_sample')
        then null
      else jsonb_build_object(
        'currency',v_execution.currency,'point_estimate_cents',v_estimate,
        'low_cents',least(v_low,v_high),
        'high_cents',greatest(v_low,v_high),
        'confidence_level','approximate_95_percent'
      )
    end,
    'incremental_gross_profit',null,
    'cost',jsonb_build_object(
      'estimated_offer_cost_cents',coalesce((
        select sum(delivery.estimated_cost_cents)
          from public.growth_deliveries_v108 delivery
         where delivery.execution_id=p_execution
           and delivery.delivery_status='delivered'
      ),0),
      'actual_redeemed_cost_cents',coalesce((
        select sum(entitlement.estimated_cost_cents)
          from public.growth_entitlements_v108 entitlement
         where entitlement.execution_id=p_execution
           and entitlement.status='redeemed'
      ),0),
      'reversed_offer_cost_cents',coalesce((
        select sum(entitlement.estimated_cost_cents)
          from public.growth_entitlements_v108 entitlement
         where entitlement.execution_id=p_execution
           and entitlement.status='reversed'
      ),0)
    ),
    'overlap_outcomes',v_overlap,
    'identity_overlap_members',v_identity_overlap,
    'limitations',jsonb_build_array(
      'revenue result is not gross profit',
      'confidence interval uses a transparent normal approximation',
      'small, overlapping or identity-ambiguous experiments are suppressed'
    )
  );
end
$function$
;

do $check_app_get_growth_execution_result_at_v108$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$  select count(*) into v_overlap
    from public.growth_outcomes_v108 outcome
    join public.growth_execution_members_v108 member
      on member.id=outcome.execution_member_id
     and member.business_id=outcome.business_id
    join public.sales sale
      on sale.id=outcome.sale_id
     and sale.business_id=outcome.business_id
   where outcome.execution_id=p_execution
     and not outcome.causal_eligible
     and outcome.occurred_at<=p_as_of
     and app.v106_sale_residual_minor(outcome.sale_id,p_as_of)>0
     and sale.client_id is not null
     and app.v113_effective_client_id(sale.business_id,sale.client_id)
         =app.v113_effective_client_id(member.business_id,member.client_id);$lit$;
  v_new1 constant text := $lit$  select count(*) into v_overlap
    from public.growth_outcomes_v108 outcome
    join public.growth_execution_members_v108 member
      on member.id=outcome.execution_member_id
     and member.business_id=outcome.business_id
    join public.sales sale
      on sale.id=outcome.sale_id
     and sale.business_id=outcome.business_id
    join public.clients member_client
      on member_client.id=member.client_id
     and member_client.business_id=member.business_id
   where outcome.execution_id=p_execution
     and not outcome.causal_eligible
     and outcome.occurred_at<=p_as_of
     and app.v106_sale_residual_minor(outcome.sale_id,p_as_of)>0
     and sale.client_id is not null
     and app.v113_effective_client_id(sale.business_id,sale.client_id)
         =app.v113_effective_client_id(member.business_id,member.client_id)
     and not member_client.is_synthetic;$lit$;
begin
  select def into v_before from _v744_before where fn = $lit$get_growth_execution_result_at_v108_v744$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = $lit$app$lit$ and p.proname = $lit$get_growth_execution_result_at_v108$lit$;
  if position(v_old1 in v_before) = 0 then
    raise exception 'app.get_growth_execution_result_at_v108: hunk 1 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  if v_expect <> v_after then
    raise exception 'app.get_growth_execution_result_at_v108: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check_app_get_growth_execution_result_at_v108$;

-- =============================================================================================
-- 9 . public.platform_generate_my_report_v89 -- sales_count, appointment_count, completed_appointments
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.platform_generate_my_report_v89(p_business_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_ids uuid[];v_result jsonb;
begin
  if not app.v89_platform_can('reports','r') then
    raise exception 'platform reports access is required' using errcode='42501';
  end if;
  select coalesce(array_agg(distinct requested.id order by requested.id),'{}'::uuid[])
    into v_ids from unnest(coalesce(p_business_ids,'{}'::uuid[])) requested(id);
  if cardinality(v_ids)=0 or exists(select 1 from unnest(v_ids) id
    where not app.v89_business_in_role_scope(id)) then
    raise exception 'report contains an out-of-scope business' using errcode='42501';
  end if;
  select jsonb_build_object(
    'scope',jsonb_build_object('business_ids',to_jsonb(v_ids),
      'generated_at',now(),'currency','SGD'),
    'summary',jsonb_build_object(
      'business_count',cardinality(v_ids),
      'customer_count',(select count(*) from public.clients
        where business_id=any(v_ids) and not is_synthetic),
      'sales_count',(select count(*) from public.sales s where s.business_id=any(v_ids)
        and s.reversal_of is null
        and not exists(select 1 from public.clients c where c.id=s.client_id and c.is_synthetic)),
      'revenue_cents',coalesce((select sum(sale.amount_cents)::bigint
        from public.sales sale
        cross join lateral app.analytics_sale_class_v1(sale) sc
        where sale.business_id=any(v_ids)
          and sc.include_revenue and not sc.is_synthetic_client),0),
      'appointment_count',(select count(*) from public.appointments a where a.business_id=any(v_ids)
        and not exists(select 1 from public.clients c where c.id=a.client_id and c.is_synthetic)),
      'completed_appointments',(select count(*) from public.appointments a where a.business_id=any(v_ids) and a.status='completed'
        and not exists(select 1 from public.clients c where c.id=a.client_id and c.is_synthetic))
    ),
    'businesses',coalesce((select jsonb_agg(jsonb_build_object(
      'id',business.id,'name',business.name,'industry',business.industry,
      'customers',(select count(*) from public.clients
        where business_id=business.id and not is_synthetic),
      'revenue_cents',coalesce((select sum(sale.amount_cents)::bigint
        from public.sales sale
        cross join lateral app.analytics_sale_class_v1(sale) sc
        where sale.business_id=business.id
          and sc.include_revenue and not sc.is_synthetic_client),0)
    ) order by lower(business.name),business.id)
      from public.businesses business where business.id=any(v_ids)),'[]'::jsonb)
  ) into v_result;
  return v_result;
end
$function$
;

do $check_public_platform_generate_my_report_v89$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$      'sales_count',(select count(*) from public.sales where business_id=any(v_ids)
        and reversal_of is null),$lit$;
  v_new1 constant text := $lit$      'sales_count',(select count(*) from public.sales s where s.business_id=any(v_ids)
        and s.reversal_of is null
        and not exists(select 1 from public.clients c where c.id=s.client_id and c.is_synthetic)),$lit$;
  v_old2 constant text := $lit$      'appointment_count',(select count(*) from public.appointments
        where business_id=any(v_ids)),
      'completed_appointments',(select count(*) from public.appointments
        where business_id=any(v_ids) and status='completed')$lit$;
  v_new2 constant text := $lit$      'appointment_count',(select count(*) from public.appointments a where a.business_id=any(v_ids)
        and not exists(select 1 from public.clients c where c.id=a.client_id and c.is_synthetic)),
      'completed_appointments',(select count(*) from public.appointments a where a.business_id=any(v_ids) and a.status='completed'
        and not exists(select 1 from public.clients c where c.id=a.client_id and c.is_synthetic))$lit$;
begin
  select def into v_before from _v744_before where fn = $lit$platform_generate_my_report_v89$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = $lit$public$lit$ and p.proname = $lit$platform_generate_my_report_v89$lit$;
  if position(v_old1 in v_before) = 0 then
    raise exception 'public.platform_generate_my_report_v89: hunk 1 anchor not found in captured body';
  end if;
  if position(v_old2 in v_before) = 0 then
    raise exception 'public.platform_generate_my_report_v89: hunk 2 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  v_expect := replace(v_expect, v_old2, v_new2);
  if v_expect <> v_after then
    raise exception 'public.platform_generate_my_report_v89: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check_public_platform_generate_my_report_v89$;

-- =============================================================================================
-- 10 . public.get_legacy_value_inventory -- store_credit total
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_legacy_value_inventory(p_business uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_result jsonb;
begin
  if p_business is null then
    if not app.is_super_admin() then
      raise exception 'super-admin only for the platform-wide legacy value inventory' using errcode = '42501';
    end if;
  else
    if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
      raise exception 'not permitted to view legacy value inventory for this business' using errcode = '42501';
    end if;
  end if;

  select coalesce(jsonb_agg(row order by (row->>'business_name')), '[]'::jsonb) into v_result
  from (
    select jsonb_build_object(
      'business_id', b.id,
      'business_name', b.name,
      'is_synthetic', b.is_synthetic,
      'authority_state', coalesce(sa.state, 'unbuilt'),
      'classification', cls.classification,
      'classification_reason', cls.reason,
      'latest_acknowledged_cents', ack.acknowledged_cents,
      'gift_card_total_cents', coalesce(gc.total, 0),
      'gift_cards', coalesce(gc.rows, '[]'::jsonb),
      'store_credit_total_cents', coalesce(cr.total, 0),
      'store_credit', coalesce(cr.rows, '[]'::jsonb)
    ) as row
    from public.businesses b
    left join lateral (
      select a.state from public.sv_authority a
       where a.business_id = b.id and a.asset = 'stored_value') sa on true
    left join lateral (
      select c.classification, c.reason from public.sv_legacy_classifications c
       where c.business_id = b.id order by c.seq desc limit 1) cls on true
    left join lateral (
      select k.acknowledged_cents from public.sv_legacy_acknowledgements k
       where k.business_id = b.id and k.asset = 'stored_value'
       order by k.seq desc limit 1) ack on true
    left join lateral (
      select sum(g.balance_cents)::bigint as total,
             jsonb_agg(jsonb_build_object(
               'gift_card_id', g.id, 'code_suffix', right(g.code, 4), 'cents', g.balance_cents,
               'status', g.status,
               'age_days', floor(extract(epoch from (now() - g.created_at)) / 86400)::int)
               order by g.created_at, g.id) as rows
        from public.gift_cards g
       where g.business_id = b.id and g.balance_cents <> 0) gc on true
    left join lateral (
      select sum(t.bal)::bigint as total,
             jsonb_agg(jsonb_build_object(
               'client_id', t.client_id, 'cents', t.bal,
               'age_days', floor(extract(epoch from (now() - t.first_at)) / 86400)::int)
               order by t.client_id) as rows
        from (select cl.client_id, sum(cl.amount_cents) as bal, min(cl.created_at) as first_at
                from public.credit_ledger cl
                join public.clients clc on clc.id = cl.client_id and clc.business_id = cl.business_id
               where cl.business_id = b.id
                 and not clc.is_synthetic
               group by cl.client_id
              having sum(cl.amount_cents) <> 0) t) cr on true
    where p_business is null or b.id = p_business
  ) s;
  return v_result;
end $function$
;

do $check_public_get_legacy_value_inventory$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$        from (select cl.client_id, sum(cl.amount_cents) as bal, min(cl.created_at) as first_at
                from public.credit_ledger cl
               where cl.business_id = b.id
               group by cl.client_id
              having sum(cl.amount_cents) <> 0) t) cr on true$lit$;
  v_new1 constant text := $lit$        from (select cl.client_id, sum(cl.amount_cents) as bal, min(cl.created_at) as first_at
                from public.credit_ledger cl
                join public.clients clc on clc.id = cl.client_id and clc.business_id = cl.business_id
               where cl.business_id = b.id
                 and not clc.is_synthetic
               group by cl.client_id
              having sum(cl.amount_cents) <> 0) t) cr on true$lit$;
begin
  select def into v_before from _v744_before where fn = $lit$get_legacy_value_inventory$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = $lit$public$lit$ and p.proname = $lit$get_legacy_value_inventory$lit$;
  if position(v_old1 in v_before) = 0 then
    raise exception 'public.get_legacy_value_inventory: hunk 1 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  if v_expect <> v_after then
    raise exception 'public.get_legacy_value_inventory: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check_public_get_legacy_value_inventory$;

-- =============================================================================================
-- 11 . public.refresh_growth_recommendation_v108 -- canonical_sales candidate population
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.refresh_growth_recommendation_v108(p_business uuid, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();
  v_now timestamptz:=statement_timestamp();
  v_policy public.growth_policies_v108%rowtype;
  v_recommendation uuid:=gen_random_uuid();
  v_total_revenue bigint:=0;
  v_identified_revenue bigint:=0;
  v_total_sales integer:=0;
  v_identified_sales integer:=0;
  v_coverage_bps integer:=0;
  v_eligible integer:=0;
  v_excluded integer:=0;
  v_avg_value bigint:=0;
  v_confidence_bps integer:=0;
  v_status text;
  v_suppressions jsonb:='[]'::jsonb;
  v_dedupe text;
  v_existing uuid;
  v_member_fingerprint text;
  v_currency text;
  v_effective_policy jsonb;
  v_candidates jsonb:='[]'::jsonb;
begin
  if v_actor is null or (
    not app.is_super_admin()
    and (
      not app.has_perm(p_business,'view_finance')
      or not app.can_module_read(p_business,'retention')
    )
  ) then
    raise exception 'finance and retention access required' using errcode='42501';
  end if;
  if not app.can_see_branch(p_business,p_branch) then
    raise exception 'branch is outside actor scope' using errcode='42501';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches branch
     where branch.id=p_branch and branch.business_id=p_business
  ) then
    raise exception 'branch does not belong to business' using errcode='22023';
  end if;
  if not app.platform_feature_enabled('growth_closed_loop_v108') then
    raise exception 'growth closed loop is not enabled' using errcode='0A000';
  end if;
  select upper(currency) into strict v_currency
    from public.businesses where id=p_business;

  insert into public.growth_policies_v108(business_id,updated_by)
  values(p_business,v_actor)
  on conflict (business_id) do nothing;
  select * into strict v_policy
    from public.growth_policies_v108 where business_id=p_business;
  v_effective_policy:=app.growth_v108_effective_parameters(p_business);

  select
    coalesce(sum(app.v106_sale_residual_minor(sale.id,v_now))
      filter(where sale.counts_as_revenue),0),
    coalesce(sum(app.v106_sale_residual_minor(sale.id,v_now))
      filter(where sale.counts_as_revenue and sale.client_id is not null),0),
    count(*) filter(where sale.counts_as_revenue),
    count(*) filter(where sale.counts_as_revenue and sale.client_id is not null)
  into v_total_revenue,v_identified_revenue,v_total_sales,v_identified_sales
  from public.sales sale
  cross join lateral app.analytics_sale_class_v1(sale) sc
  where sale.business_id=p_business
    and (p_branch is null or sale.branch_id=p_branch)
    and sale.occurred_at>=v_now-interval '90 days'
    and sale.occurred_at<v_now
    and sale.reversal_of is null
    and not sc.is_synthetic_client
    and not exists (
      select 1 from public.sales reversal
       where reversal.business_id=sale.business_id
         and reversal.reversal_of=sale.id
    );
  v_coverage_bps:=case when v_total_revenue>0
    then least(10000,(v_identified_revenue*10000/v_total_revenue)::integer)
    else 0 end;

  with canonical_sales as (
    select
      app.v113_effective_client_id(sale.business_id,sale.client_id) as client_id,
      sale.occurred_at,
      sale.id,
      app.v106_sale_residual_minor(sale.id,v_now) as amount_cents
    from public.sales sale
    join public.clients sale_client
      on sale_client.id=sale.client_id
     and sale_client.business_id=sale.business_id
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and app.v106_sale_residual_minor(sale.id,v_now)>0
      and sale.occurred_at>=v_now-make_interval(days=>v_policy.observation_days)
      and sale.occurred_at<v_now
      and not sale_client.is_synthetic
      and not exists (
        select 1 from public.sales reversal
         where reversal.business_id=sale.business_id
           and reversal.reversal_of=sale.id
      )
  ),
  visit_days as (
    /* nestly_v711 (check 4 fix): collapse same-day sales (a split bill: several tickets, one
       customer, one afternoon) into ONE visit before prior_visits/cadence_days are computed. A
       visit-day is app.ci_visit_day_v699(occurred_at) (the one visit-day authority; nestly_v699),
       anchored at the day's FIRST qualifying sale's occurred_at, not the day boundary, and not
       the day's last sale (same anchor rule as nestly_v709's fix to
       app.customer_cadence_batch_v1). average_transaction_cents / historical_revenue_cents are
       computed separately, over every individual qualifying sale (see the amounts CTE below);
       only the visits denominator collapses, not the revenue sum. */
    select client_id,
      app.ci_visit_day_v699(occurred_at) as visit_day,
      min(occurred_at) as occurred_at
    from canonical_sales
    group by client_id, app.ci_visit_day_v699(occurred_at)
  ),
  visits as (
    select visit_days.*,
      extract(epoch from (
        occurred_at-lag(occurred_at) over (
          partition by client_id order by occurred_at
        )
      ))/86400.0 as interval_days
    from visit_days
  ),
  amounts as (
    select client_id,
      round(avg(amount_cents))::bigint as average_transaction_cents,
      sum(amount_cents)::bigint as historical_revenue_cents
    from canonical_sales
    group by client_id
  ),
  metrics as (
    select visit.client_id,
      count(*)::integer as prior_visits,
      max(visit.occurred_at) as last_visit_at,
      percentile_cont(0.5) within group(order by visit.interval_days)
        filter(where visit.interval_days is not null) as cadence_days,
      floor(extract(epoch from(v_now-max(visit.occurred_at)))/86400)::integer
        as lapse_days,
      amounts.average_transaction_cents,
      amounts.historical_revenue_cents
    from visits visit
    join amounts on amounts.client_id=visit.client_id
    group by visit.client_id, amounts.average_transaction_cents,
      amounts.historical_revenue_cents
  ),
  judged as (
    select metric.*,
      case
        when metric.prior_visits<
          (v_effective_policy#>>'{parameters,minimum_prior_visits}')::integer
          then 'insufficient_history'
        when metric.cadence_days is null then 'insufficient_history'
        when metric.lapse_days<greatest(
          (v_effective_policy#>>'{parameters,minimum_lapse_days}')::integer,
          ceil(metric.cadence_days*
            (v_effective_policy#>>'{parameters,cadence_multiplier}')::numeric
          )::integer
        ) then 'not_lapsed'
        when not exists (
          select 1
            from public.customer_links link
            join public.customer_identities identity_row
              on identity_row.id=link.identity_id
             and identity_row.status='active'
           where link.business_id=p_business
             and app.v113_effective_client_id(link.business_id,link.client_id)
                 =metric.client_id
             and link.state='verified'
        ) then 'no_verified_link'
        when not exists (
          select 1
            from public.customer_notification_preferences preference
            join public.customer_links link
              on link.id=preference.link_id
             and link.business_id=preference.business_id
            join public.customer_identities identity_row
              on identity_row.id=link.identity_id
             and identity_row.status='active'
           where preference.business_id=p_business
             and app.v113_effective_client_id(
                   preference.business_id,preference.client_id
                 )=metric.client_id
             and preference.channel='in_app'
             and preference.topic='marketing'
             and preference.opted_in
             and link.state='verified'
        ) then 'no_marketing_consent'
        when exists (
          select 1 from public.growth_deliveries_v108 delivery
           where delivery.business_id=p_business
             and app.v113_effective_client_id(
                   delivery.business_id,delivery.client_id
                 )=metric.client_id
             and delivery.delivery_status='delivered'
             and delivery.delivered_at>=
               v_now-make_interval(days=>v_policy.frequency_cap_days)
        ) then 'frequency_cap'
        when exists (
          select 1
            from public.growth_execution_members_v108 member
            join public.growth_executions_v108 execution
              on execution.id=member.execution_id
           where member.business_id=p_business
             and app.v113_effective_client_id(
                   member.business_id,member.client_id
                 )=metric.client_id
             and execution.status='running'
             and execution.ends_at>v_now
        ) then 'active_experiment'
        else null
      end as exclusion_reason
    from metrics metric
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'client_id',judged.client_id,
    'prior_visits',judged.prior_visits,
    'last_visit_at',judged.last_visit_at,
    'cadence_days',judged.cadence_days,
    'lapse_days',judged.lapse_days,
    'average_transaction_cents',judged.average_transaction_cents,
    'historical_revenue_cents',judged.historical_revenue_cents,
    'eligible',judged.exclusion_reason is null,
    'exclusion_reason',judged.exclusion_reason
  ) order by judged.client_id),'[]'::jsonb)
  into v_candidates
  from judged;

  select count(*) filter(where eligible),
         count(*) filter(where not eligible),
         coalesce(round(avg(average_transaction_cents)
           filter(where eligible)),0)::bigint
    into v_eligible,v_excluded,v_avg_value
    from jsonb_to_recordset(v_candidates) as candidate(
      client_id uuid,
      prior_visits integer,
      last_visit_at timestamptz,
      cadence_days numeric,
      lapse_days integer,
      average_transaction_cents bigint,
      historical_revenue_cents bigint,
      eligible boolean,
      exclusion_reason text
    );
  v_confidence_bps:=least(9500,
    greatest(0,v_coverage_bps*7/10)+least(2500,v_eligible*100)
  );

  if not v_policy.enabled then
    v_suppressions:=v_suppressions||jsonb_build_array('policy_disabled');
  end if;
  if v_total_sales<50 then
    v_suppressions:=v_suppressions||jsonb_build_array('cold_start_under_50_sales');
  end if;
  if v_coverage_bps<v_policy.minimum_identity_coverage_bps then
    v_suppressions:=v_suppressions||
      jsonb_build_array('identity_coverage_below_threshold');
  end if;
  if v_eligible<
     (v_effective_policy#>>'{parameters,minimum_audience}')::integer then
    v_suppressions:=v_suppressions||jsonb_build_array('audience_below_minimum');
  end if;
  v_suppressions:=v_suppressions||
    coalesce(v_effective_policy->'suppression_reasons','[]'::jsonb);
  if (app.subgroup_evidence_v1(floor(v_eligible*v_policy.holdout_percent/100.0)::integer,v_policy.minimum_arm_size)->>'status')='insufficient'
     or (app.subgroup_evidence_v1((v_eligible-floor(v_eligible*v_policy.holdout_percent/100.0))::integer,v_policy.minimum_arm_size)->>'status')='insufficient' then
    v_suppressions:=v_suppressions||
      jsonb_build_array('experiment_arms_too_small');
  end if;
  v_status:=case when jsonb_array_length(v_suppressions)=0
    then 'presented' else 'suppressed' end;

  select encode(extensions.digest(convert_to(
    coalesce(jsonb_agg(jsonb_build_array(
      candidate.client_id,candidate.eligible,candidate.exclusion_reason,
      candidate.prior_visits,candidate.last_visit_at,
      round(candidate.cadence_days,2),candidate.lapse_days,
      candidate.average_transaction_cents,candidate.historical_revenue_cents
    ) order by candidate.client_id)::text,'[]'),'UTF8'
  ),'sha256'),'hex')
  into v_member_fingerprint
  from jsonb_to_recordset(v_candidates) as candidate(
    client_id uuid,
    prior_visits integer,
    last_visit_at timestamptz,
    cadence_days numeric,
    lapse_days integer,
    average_transaction_cents bigint,
    historical_revenue_cents bigint,
    eligible boolean,
    exclusion_reason text
  );

  v_dedupe:=encode(extensions.digest(convert_to(concat_ws(':',
    'v113',p_business,coalesce(p_branch::text,'all'),v_policy.policy_version,
    date_trunc('day',v_now)::text,v_status,v_currency,v_total_sales,
    v_identified_sales,v_total_revenue,v_identified_revenue,v_eligible,
    v_excluded,v_avg_value,v_policy.default_credit_cents,
    v_policy.maximum_credit_cents,v_policy.frequency_cap_days,
    v_policy.attribution_days,v_policy.minimum_arm_size,
    v_policy.holdout_percent,v_member_fingerprint,v_effective_policy::text
  ),'UTF8'),'sha256'),'hex');
  perform pg_advisory_xact_lock(
    hashtextextended('growth-v108-refresh:'||v_dedupe,0)
  );
  select recommendation.id into v_existing
    from public.growth_recommendations_v108 recommendation
   where recommendation.dedupe_key=v_dedupe;
  if found then
    return jsonb_build_object(
      'recommendation_id',v_existing,'status',v_status,
      'eligible',v_eligible,'excluded',v_excluded,
      'coverage_bps',v_coverage_bps,
      'suppression_reasons',v_suppressions,'replayed',true
    );
  end if;

  insert into public.growth_recommendations_v108(
    id,business_id,branch_id,recommendation_type,policy_version,
    generated_at,valid_until,observation_start,observation_end,
    comparison_start,comparison_end,finding,supporting_evidence,baseline,
    opportunity,expected_incremental_revenue,expected_incremental_gross_profit,
    confidence,assumptions,recommended_action,recommended_channel,
    recommended_offer,estimated_cost_cents,audience_size,excluded_size,
    success_metric,frequency_cap_days,attribution_window_days,holdout_percent,
    stop_conditions,status,suppression_reasons,data_freshness_at,data_coverage,
    dedupe_key,created_by
  ) values (
    v_recommendation,p_business,p_branch,'lapsed_high_value_bring_back',
    v_policy.policy_version,v_now,v_now+interval '24 hours',
    v_now-make_interval(days=>v_policy.observation_days),v_now,
    v_now-interval '180 days',v_now-interval '90 days',
    case when v_status='presented'
      then v_eligible||
        ' previously active customers are beyond their observed visit cadence.'
      else 'No reliable bring-back action is available yet.' end,
    jsonb_build_array(
      jsonb_build_object('metric','eligible_customers','value',v_eligible),
      jsonb_build_object(
        'metric','identified_revenue_coverage_bps','value',v_coverage_bps
      ),
      jsonb_build_object(
        'metric','average_historical_transaction_cents','value',v_avg_value
      ),
      jsonb_build_object(
        'metric','effective_policy_lineage','value',v_effective_policy
      ),
      jsonb_build_object(
        'metric','identity_attribution','value','v111_current_effective_identity'
      )
    ),
    jsonb_build_object(
      'total_sales_90d',v_total_sales,
      'identified_sales_90d',v_identified_sales,
      'total_revenue_cents_90d',v_total_revenue,
      'identified_revenue_cents_90d',v_identified_revenue
    ),
    jsonb_build_object(
      'eligible_customers',v_eligible,
      'historical_average_transaction_cents',v_avg_value
    ),
    jsonb_build_object(
      'currency',v_currency,'status','withheld_uncalibrated',
      'kind','incremental_revenue_not_yet_available',
      'reason','no completed calibrated experiment evidence'
    ),
    null,
    jsonb_build_object(
      'score_bps',v_confidence_bps,'score_kind','data_quality_only',
      'level',case
        when v_confidence_bps>=8000 then 'high'
        when v_confidence_bps>=6500 then 'medium'
        else 'low' end,
      'reasons',jsonb_build_array(
        'identity coverage and audience size determine confidence',
        'causal result remains unavailable until a valid holdout completes'
      )
    ),
    jsonb_build_array(
      'future behaviour may differ from historical cadence',
      'expected revenue is a range, not a guarantee',
      'gross profit is unavailable until item cost coverage is complete'
    ),
    jsonb_build_object(
      'label','Approve measured bring-back','channel','in_app',
      'requires_owner_approval',true
    ),
    'in_app',
    jsonb_build_object(
      'type','credit_cents','value_cents',v_policy.default_credit_cents,
      'currency',v_currency,'expires_in_days',7
    ),
    greatest(0,
      (v_eligible-floor(v_eligible*v_policy.holdout_percent/100.0)::integer)
      *v_policy.default_credit_cents
    ),
    v_eligible,v_excluded,'incremental_completed_purchase_revenue',
    v_policy.frequency_cap_days,v_policy.attribution_days,
    v_policy.holdout_percent,
    jsonb_build_object(
      'budget_cap_cents',v_eligible*v_policy.maximum_credit_cents,
      'one_active_experiment_per_customer',true,
      'consent_rechecked_at_execution',true,
      'minimum_arm_size',v_policy.minimum_arm_size,
      'identity_attribution','v111_current_effective_identity'
    ),
    v_status,v_suppressions,v_now,
    jsonb_build_object(
      'identified_revenue_bps',v_coverage_bps,
      'total_sales',v_total_sales,'identified_sales',v_identified_sales,
      'effective_policy',v_effective_policy,
      'identity_attribution','v111_current_effective_identity','as_of',v_now
    ),
    v_dedupe,v_actor
  );

  insert into public.growth_recommendation_members_v108(
    recommendation_id,business_id,client_id,eligible,exclusion_reason,
    prior_visits,last_visit_at,cadence_days,lapse_days,
    average_transaction_cents,historical_revenue_cents,evidence
  )
  select v_recommendation,p_business,candidate.client_id,candidate.eligible,
    candidate.exclusion_reason,candidate.prior_visits,candidate.last_visit_at,
    round(candidate.cadence_days,2),candidate.lapse_days,
    candidate.average_transaction_cents,candidate.historical_revenue_cents,
    jsonb_build_object(
      'prior_visits',candidate.prior_visits,
      'last_visit_at',candidate.last_visit_at,
      'observed_median_cadence_days',round(candidate.cadence_days,2),
      'days_since_last_visit',candidate.lapse_days,
      'historical_average_transaction_cents',
        candidate.average_transaction_cents,
      'identity_attribution','v111_current_effective_identity'
    )
  from jsonb_to_recordset(v_candidates) as candidate(
    client_id uuid,
    prior_visits integer,
    last_visit_at timestamptz,
    cadence_days numeric,
    lapse_days integer,
    average_transaction_cents bigint,
    historical_revenue_cents bigint,
    eligible boolean,
    exclusion_reason text
  );

  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values (
    p_business,v_actor,'REFRESH_GROWTH_RECOMMENDATION_V108',
    'growth_recommendations_v108',v_recommendation,
    jsonb_build_object(
      'status',v_status,'eligible',v_eligible,'excluded',v_excluded,
      'coverage_bps',v_coverage_bps,
      'identity_attribution','v111_current_effective_identity'
    )
  );
  return jsonb_build_object(
    'recommendation_id',v_recommendation,'status',v_status,
    'eligible',v_eligible,'excluded',v_excluded,
    'coverage_bps',v_coverage_bps,
    'suppression_reasons',v_suppressions,'replayed',false
  );
end
$function$
;

do $check_public_refresh_growth_recommendation_v108$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$  with canonical_sales as (
    select
      app.v113_effective_client_id(sale.business_id,sale.client_id) as client_id,
      sale.occurred_at,
      sale.id,
      app.v106_sale_residual_minor(sale.id,v_now) as amount_cents
    from public.sales sale
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and app.v106_sale_residual_minor(sale.id,v_now)>0
      and sale.occurred_at>=v_now-make_interval(days=>v_policy.observation_days)
      and sale.occurred_at<v_now
      and not exists (
        select 1 from public.sales reversal
         where reversal.business_id=sale.business_id
           and reversal.reversal_of=sale.id
      )
  ),$lit$;
  v_new1 constant text := $lit$  with canonical_sales as (
    select
      app.v113_effective_client_id(sale.business_id,sale.client_id) as client_id,
      sale.occurred_at,
      sale.id,
      app.v106_sale_residual_minor(sale.id,v_now) as amount_cents
    from public.sales sale
    join public.clients sale_client
      on sale_client.id=sale.client_id
     and sale_client.business_id=sale.business_id
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and app.v106_sale_residual_minor(sale.id,v_now)>0
      and sale.occurred_at>=v_now-make_interval(days=>v_policy.observation_days)
      and sale.occurred_at<v_now
      and not sale_client.is_synthetic
      and not exists (
        select 1 from public.sales reversal
         where reversal.business_id=sale.business_id
           and reversal.reversal_of=sale.id
      )
  ),$lit$;
begin
  select def into v_before from _v744_before where fn = $lit$refresh_growth_recommendation_v108$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = $lit$public$lit$ and p.proname = $lit$refresh_growth_recommendation_v108$lit$;
  if position(v_old1 in v_before) = 0 then
    raise exception 'public.refresh_growth_recommendation_v108: hunk 1 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  if v_expect <> v_after then
    raise exception 'public.refresh_growth_recommendation_v108: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check_public_refresh_growth_recommendation_v108$;

-- =============================================================================================
-- 12 . public.get_period_economics_v109 -- growth_entitlements_v108 marketing-cost eligible population
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_period_economics_v109(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid, p_investment_cents bigint DEFAULT NULL::bigint, p_investment_reference text DEFAULT NULL::text, p_as_of timestamp with time zone DEFAULT statement_timestamp())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_sales integer:=0;
  v_covered_sales integer:=0;
  v_sale_lines integer:=0;
  v_covered_sale_lines integer:=0;
  v_ambiguous_sale_lines integer:=0;
  v_revenue bigint:=0;
  v_covered_revenue bigint:=0;
  v_traceable_cogs bigint:=0;
  v_sale_transaction_coverage_bps integer;
  v_sale_revenue_coverage_bps integer;
  v_sale_coverage_passes boolean:=false;
  v_benefits integer:=0;
  v_covered_benefits integer:=0;
  v_benefit_value bigint:=0;
  v_covered_benefit_value bigint:=0;
  v_traceable_benefit_cost bigint:=0;
  v_benefit_coverage_bps integer;
  v_benefit_coverage_passes boolean:=true;
  v_deliveries integer:=0;
  v_covered_deliveries integer:=0;
  v_traceable_delivery_cost bigint:=0;
  v_delivery_coverage_bps integer;
  v_delivery_coverage_passes boolean:=true;
  v_coverage_passes boolean:=false;
  v_gross_profit bigint;
  v_contribution bigint;
  v_growth_investment bigint;
  v_total_investment bigint;
  v_net_return bigint;
  v_roi_bps bigint;
  v_unavailable jsonb:='[]'::jsonb;
  v_currency text;
  v_currency_count integer;
  v_extra_reference text;
begin
  perform app.v109_require_feature();
  perform app.v109_require_finance_scope(p_business,p_branch);
  if not app.can_module(p_business,'customerintel') then
    raise exception 'customerintel_module_required' using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_from>=p_to or p_as_of is null then
    raise exception 'valid half-open local-date period and as-of are required'
      using errcode='22023';
  end if;
  if p_investment_cents is not null and p_investment_cents<0 then
    raise exception 'investment cannot be negative' using errcode='22023';
  end if;
  if p_investment_cents>0
     and length(btrim(coalesce(p_investment_reference,'')))<3 then
    raise exception 'positive additional investment requires a source reference'
      using errcode='22023';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches branch_row
    where branch_row.id=p_branch and branch_row.business_id=p_business
  ) then
    raise exception 'branch does not belong to business' using errcode='22023';
  end if;

  select count(distinct contract.currency),min(contract.currency)
  into v_currency_count,v_currency
  from public.sales sale
  cross join lateral app.v106_reporting_contract(
    sale.business_id,sale.branch_id,sale.occurred_at
  ) contract
  where sale.business_id=p_business
    and (p_branch is null or sale.branch_id=p_branch)
    and sale.counts_as_revenue and sale.reversal_of is null
    and sale.created_at<=p_as_of
    and (sale.occurred_at at time zone contract.timezone)::date>=p_from
    and (sale.occurred_at at time zone contract.timezone)::date<p_to;
  if v_currency_count>1 then
    raise exception 'cross-currency reporting periods are not supported'
      using errcode='22023';
  end if;
  if v_currency_count=0 then
    select upper(currency) into strict v_currency
    from public.businesses where id=p_business;
  end if;

  with eligible as (
    select sale.*,contract.currency,
      app.v106_sale_residual_minor(
        sale.id,p_to,p_as_of
      ) as residual_cents
    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.counts_as_revenue and sale.reversal_of is null
      and not sc.is_synthetic_client
      and sale.created_at<=p_as_of
      and (sale.occurred_at at time zone contract.timezone)::date>=p_from
      and (sale.occurred_at at time zone contract.timezone)::date<p_to
      and app.v106_sale_residual_minor(sale.id,p_to,p_as_of)>0
  ), sale_shape as (
    select sale.*,
      exists(
        select 1 from public.sale_items item
        where item.business_id=p_business and item.sale_id=sale.id
      ) as is_itemized,
      coalesce((
        select sum(item.line_cents)
        from public.sale_items item
        where item.business_id=p_business and item.sale_id=sale.id
          and item.line_cents>0
      ),0)::bigint as positive_line_cents
    from eligible sale
  ), itemized_base as (
    select sale.id as sale_id,item.id as cost_line_key,
      sale.branch_id,sale.occurred_at,sale.currency,sale.kind as sale_kind,
      true as is_itemized,item.qty,item.line_cents as source_line_cents,
      case
        when item.item_type='retail' and item.product_id is not null
          then 'product'
        when item.item_type='service' and item.ref_id is not null
          then 'service'
        when item.item_type='package' and item.ref_id is not null
          then 'package'
        else null
      end as desired_scope_kind,
      case
        when item.item_type='retail' and item.product_id is not null
          then item.product_id::text
        when item.item_type in ('service','package') and item.ref_id is not null
          then item.ref_id::text
        else null
      end as desired_scope_key,
      sale.amount_cents as sale_original_cents,
      sale.residual_cents as sale_residual_cents,
      floor(
        sale.residual_cents::numeric*item.line_cents
        /sale.positive_line_cents
      )::bigint as allocated_base_cents,
      mod(
        sale.residual_cents::numeric*item.line_cents,
        sale.positive_line_cents
      ) as allocation_remainder
    from sale_shape sale
    join public.sale_items item
      on item.business_id=p_business and item.sale_id=sale.id
    where sale.is_itemized and sale.positive_line_cents>0
      and item.line_cents>0
  ), itemized_ranked as (
    select itemized_base.*,
      itemized_base.sale_residual_cents
        -sum(itemized_base.allocated_base_cents) over(
          partition by itemized_base.sale_id
        ) as remainder_to_assign,
      row_number() over(
        partition by itemized_base.sale_id
        order by itemized_base.allocation_remainder desc,
          itemized_base.cost_line_key
      ) as allocation_rank
    from itemized_base
  ), economic_lines as (
    select sale_id,cost_line_key,branch_id,occurred_at,currency,sale_kind,
      is_itemized,qty,source_line_cents,desired_scope_kind,desired_scope_key,
      sale_original_cents,sale_residual_cents,
      allocated_base_cents
        +case when allocation_rank<=remainder_to_assign then 1 else 0 end
        as allocated_cents
    from itemized_ranked
    union all
    -- An itemized parent with no positive economic line is never silently
    -- reclassified as a parent sale.  Keep one uncovered line so the report
    -- fails closed while still reconciling its full residual revenue.
    select sale.id,sale.id,sale.branch_id,sale.occurred_at,sale.currency,
      sale.kind,true,coalesce(sale.qty,1),greatest(sale.amount_cents,1),
      null::text,null::text,sale.amount_cents,sale.residual_cents,
      sale.residual_cents
    from sale_shape sale
    where sale.is_itemized and sale.positive_line_cents=0
    union all
    -- Sale-kind fallback exists only for genuinely non-itemized legacy rows.
    select sale.id,sale.id,sale.branch_id,sale.occurred_at,sale.currency,
      sale.kind,false,coalesce(sale.qty,1),greatest(sale.amount_cents,1),
      case when sale.product_id is not null then 'product' else 'sale_kind' end,
      case
        when sale.product_id is not null then sale.product_id::text
        else sale.kind
      end,
      sale.amount_cents,sale.residual_cents,
      sale.residual_cents
    from sale_shape sale
    where not sale.is_itemized
  ), candidate_pool as (
    select line.*,candidate.id as candidate_rule_id,
      candidate.cost_method,candidate.cost_value,
      candidate.effective_from,candidate.version_no,
      case
        when candidate.scope_kind=line.desired_scope_kind
          and candidate.scope_key=line.desired_scope_key then 0
        when not line.is_itemized and candidate.scope_kind='sale_kind'
          and candidate.scope_key=line.sale_kind then 1
        else 2
      end as scope_priority,
      case when candidate.branch_id=line.branch_id then 0 else 1 end
        as branch_priority
    from economic_lines line
    left join public.economic_cost_rules_v109 candidate
      on candidate.business_id=p_business
      and candidate.currency=line.currency
      and (candidate.branch_id is null or candidate.branch_id=line.branch_id)
      and candidate.effective_from<=line.occurred_at
      and (
        candidate.effective_to is null
        or candidate.effective_to>line.occurred_at
      )
      and (
        (
          candidate.scope_kind=line.desired_scope_kind
          and candidate.scope_key=line.desired_scope_key
        )
        or (
          not line.is_itemized
          and line.desired_scope_kind='product'
          and candidate.scope_kind='sale_kind'
          and candidate.scope_key=line.sale_kind
        )
      )
  ), ranked_candidates as (
    select candidate_pool.*,
      row_number() over(
        partition by sale_id,cost_line_key
        order by scope_priority,branch_priority,
          effective_from desc nulls last,version_no desc nulls last
      ) as selection_rank,
      count(candidate_rule_id) over(
        partition by sale_id,cost_line_key,scope_priority,branch_priority,
          effective_from
      ) as equal_precedence_rules
    from candidate_pool
  ), selected as (
    select *,
      candidate_rule_id is not null and equal_precedence_rules=1
        as is_covered,
      candidate_rule_id is not null and equal_precedence_rules>1
        as is_ambiguous,
      case
        when candidate_rule_id is null or equal_precedence_rules<>1 then null
        when cost_method='revenue_bps' then
          round(allocated_cents*cost_value::numeric/10000)::bigint
        when cost_method='fixed_per_unit' then
          round(
            cost_value*qty*sale_residual_cents::numeric
            /greatest(sale_original_cents,1)
          )::bigint
        else null
      end as cost_cents
    from ranked_candidates
    where selection_rank=1
  ), sale_summary as (
    select sale_id,count(*)::integer as eligible_lines,
      count(*) filter(where is_covered)::integer as covered_lines,
      count(*) filter(where is_ambiguous)::integer as ambiguous_lines,
      sum(allocated_cents)::bigint as revenue_cents,
      coalesce(sum(allocated_cents) filter(where is_covered),0)::bigint
        as covered_revenue_cents,
      coalesce(sum(cost_cents) filter(where is_covered),0)::bigint
        as cost_cents
    from selected
    group by sale_id
  )
  select count(*)::integer,
    count(*) filter(
      where covered_lines=eligible_lines and ambiguous_lines=0
    )::integer,
    coalesce(sum(eligible_lines),0)::integer,
    coalesce(sum(covered_lines),0)::integer,
    coalesce(sum(ambiguous_lines),0)::integer,
    coalesce(sum(revenue_cents),0)::bigint,
    coalesce(sum(covered_revenue_cents),0)::bigint,
    coalesce(sum(cost_cents),0)::bigint
  into v_sales,v_covered_sales,v_sale_lines,v_covered_sale_lines,
    v_ambiguous_sale_lines,v_revenue,v_covered_revenue,v_traceable_cogs
  from sale_summary;

  with eligible as (
    select entitlement.id,entitlement.value_cents,
      entitlement.entitlement_type,entitlement.redeemed_at,
      execution_row.branch_id,contract.currency
    from public.growth_entitlements_v108 entitlement
    join public.growth_executions_v108 execution_row
      on execution_row.id=entitlement.execution_id
      and execution_row.business_id=entitlement.business_id
    join public.clients entitlement_client
      on entitlement_client.id=entitlement.client_id
     and entitlement_client.business_id=entitlement.business_id
    cross join lateral app.v106_reporting_contract(
      entitlement.business_id,execution_row.branch_id,entitlement.redeemed_at
    ) contract
    left join lateral (
      select event_row.sale_id,reversal_sale.occurred_at
      from public.growth_entitlement_events_v108 event_row
      join public.sales reversal_sale
        on reversal_sale.id=event_row.sale_id
        and reversal_sale.business_id=event_row.business_id
      where event_row.entitlement_id=entitlement.id
        and event_row.business_id=entitlement.business_id
        and event_row.event_type='reversed'
        and event_row.created_at<=p_as_of
        and reversal_sale.created_at<=p_as_of
        and reversal_sale.reversal_of=entitlement.redeemed_sale_id
      order by event_row.created_at desc,event_row.id desc
      limit 1
    ) reversal_evidence on true
    left join lateral app.v106_reporting_contract(
      entitlement.business_id,execution_row.branch_id,
      reversal_evidence.occurred_at
    ) reversal_contract on reversal_evidence.sale_id is not null
    where entitlement.business_id=p_business
      and (p_branch is null or execution_row.branch_id=p_branch)
      and entitlement.redeemed_at is not null
      and entitlement.redeemed_at<=p_as_of
      and not entitlement_client.is_synthetic
      and (
        entitlement.reversed_at is null
        or entitlement.reversed_at>p_as_of
        or (
          entitlement.reversed_at<=p_as_of
          and reversal_evidence.sale_id is not null
          and (
            reversal_evidence.occurred_at
              at time zone reversal_contract.timezone
          )::date>=p_to
        )
      )
      and (
        entitlement.redeemed_at at time zone contract.timezone
      )::date>=p_from
      and (
        entitlement.redeemed_at at time zone contract.timezone
      )::date<p_to
  ), matched as (
    select benefit.id,benefit.value_cents,rule_row.id as rule_id,
      case
        when rule_row.cost_method='value_bps' then
          round(
            benefit.value_cents*rule_row.cost_value::numeric/10000
          )::bigint
        when rule_row.cost_method='fixed_per_event' then rule_row.cost_value
        else null
      end as cost_cents
    from eligible benefit
    left join lateral (
      select candidate.*
      from public.growth_cost_rules_v114 candidate
      where candidate.business_id=p_business
        and candidate.cost_class='benefit'
        and candidate.scope_key=benefit.entitlement_type
        and candidate.currency=benefit.currency
        and (
          candidate.branch_id is null
          or candidate.branch_id=benefit.branch_id
        )
        and candidate.effective_from<=benefit.redeemed_at
        and (
          candidate.effective_to is null
          or candidate.effective_to>benefit.redeemed_at
        )
      order by
        case when candidate.branch_id=benefit.branch_id then 0 else 1 end,
        candidate.effective_from desc,candidate.version_no desc
      limit 1
    ) rule_row on true
  )
  select count(*),count(*) filter(where rule_id is not null),
    coalesce(sum(value_cents),0),
    coalesce(sum(value_cents) filter(where rule_id is not null),0),
    coalesce(sum(cost_cents) filter(where rule_id is not null),0)
  into v_benefits,v_covered_benefits,v_benefit_value,
    v_covered_benefit_value,v_traceable_benefit_cost
  from matched;

  with eligible as (
    select dispatch.id,dispatch.branch_id,dispatch.provider,
      dispatch.delivered_at,contract.currency
    from public.growth_delivery_dispatches_v110 dispatch
    cross join lateral app.v106_reporting_contract(
      dispatch.business_id,dispatch.branch_id,dispatch.delivered_at
    ) contract
    where dispatch.business_id=p_business
      and (p_branch is null or dispatch.branch_id=p_branch)
      and dispatch.delivered_at is not null
      and dispatch.delivered_at<=p_as_of
      and (
        dispatch.delivered_at at time zone contract.timezone
      )::date>=p_from
      and (
        dispatch.delivered_at at time zone contract.timezone
      )::date<p_to
  ), matched as (
    select delivery.id,rule_row.id as rule_id,
      rule_row.cost_value as cost_cents
    from eligible delivery
    left join lateral (
      select candidate.*
      from public.growth_cost_rules_v114 candidate
      where candidate.business_id=p_business
        and candidate.cost_class='delivery'
        and candidate.scope_key=delivery.provider
        and candidate.currency=delivery.currency
        and (
          candidate.branch_id is null
          or candidate.branch_id=delivery.branch_id
        )
        and candidate.effective_from<=delivery.delivered_at
        and (
          candidate.effective_to is null
          or candidate.effective_to>delivery.delivered_at
        )
      order by
        case when candidate.branch_id=delivery.branch_id then 0 else 1 end,
        candidate.effective_from desc,candidate.version_no desc
      limit 1
    ) rule_row on true
  )
  select count(*),count(*) filter(where rule_id is not null),
    coalesce(sum(cost_cents) filter(where rule_id is not null),0)
  into v_deliveries,v_covered_deliveries,v_traceable_delivery_cost
  from matched;

  v_sale_transaction_coverage_bps:=case
    when v_sales=0 then null
    else round(v_covered_sales*10000.0/v_sales)::integer
  end;
  v_sale_revenue_coverage_bps:=case
    when v_revenue=0 then null
    else round(v_covered_revenue*10000.0/v_revenue)::integer
  end;
  v_sale_coverage_passes:=v_sales>0
    and v_sale_lines>0
    and v_covered_sales=v_sales
    and v_covered_sale_lines=v_sale_lines
    and v_ambiguous_sale_lines=0
    and v_covered_revenue=v_revenue;
  v_benefit_coverage_bps:=case
    when v_benefits=0 then null
    else round(v_covered_benefits*10000.0/v_benefits)::integer
  end;
  v_benefit_coverage_passes:=v_benefits=0
    or v_covered_benefits=v_benefits;
  v_delivery_coverage_bps:=case
    when v_deliveries=0 then null
    else round(v_covered_deliveries*10000.0/v_deliveries)::integer
  end;
  v_delivery_coverage_passes:=v_deliveries=0
    or v_covered_deliveries=v_deliveries;
  v_coverage_passes:=v_sale_coverage_passes
    and v_benefit_coverage_passes and v_delivery_coverage_passes;

  if v_sales=0 then
    v_unavailable:=v_unavailable||jsonb_build_array('no_eligible_sales');
  elsif not v_sale_coverage_passes then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('incomplete_traceable_sale_cost_coverage');
  end if;
  if v_ambiguous_sale_lines>0 then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('ambiguous_traceable_sale_cost_rules');
  end if;
  if not v_benefit_coverage_passes then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('incomplete_traceable_benefit_cost_coverage');
  end if;
  if not v_delivery_coverage_passes then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('incomplete_traceable_delivery_cost_coverage');
  end if;

  if v_coverage_passes then
    v_gross_profit:=v_revenue-v_traceable_cogs;
    v_contribution:=v_gross_profit-v_traceable_benefit_cost
      -v_traceable_delivery_cost;
    v_growth_investment:=v_traceable_benefit_cost+v_traceable_delivery_cost;
    v_total_investment:=v_growth_investment+coalesce(p_investment_cents,0);
    if v_total_investment>0 then
      v_net_return:=v_contribution-coalesce(p_investment_cents,0);
      v_roi_bps:=round(v_net_return*10000.0/v_total_investment);
    else
      v_unavailable:=v_unavailable
        ||jsonb_build_array('positive_traceable_investment_required');
    end if;
  end if;
  v_extra_reference:=nullif(btrim(coalesce(p_investment_reference,'')),'');

  return jsonb_build_object(
    'contract_version','period_economics_v109',
    'cost_contract_version','growth_costs_v114',
    'business_id',p_business,'as_of',p_as_of,
    'period',jsonb_build_object(
      'from',p_from,'to',p_to,'basis','business_local_date'
    ),
    'status',case
      when v_sales=0 then 'no_data'
      when v_coverage_passes then 'ready'
      else 'insufficient_cost_coverage'
    end,
    'coverage',jsonb_build_object(
      'cost_contract_version','growth_costs_v114',
      'eligible_sales',v_sales,'covered_sales',v_covered_sales,
      'eligible_sale_lines',v_sale_lines,
      'covered_sale_lines',v_covered_sale_lines,
      'ambiguous_sale_lines',v_ambiguous_sale_lines,
      'transaction_coverage_bps',v_sale_transaction_coverage_bps,
      'eligible_revenue_cents',v_revenue,
      'covered_revenue_cents',v_covered_revenue,
      'revenue_coverage_bps',v_sale_revenue_coverage_bps,
      'sale_cost_coverage_passes',v_sale_coverage_passes,
      'eligible_redeemed_benefits',v_benefits,
      'covered_redeemed_benefits',v_covered_benefits,
      'eligible_redeemed_benefit_value_cents',v_benefit_value,
      'covered_redeemed_benefit_value_cents',v_covered_benefit_value,
      'benefit_cost_coverage_bps',v_benefit_coverage_bps,
      'benefit_cost_coverage_passes',v_benefit_coverage_passes,
      'eligible_deliveries',v_deliveries,
      'covered_deliveries',v_covered_deliveries,
      'delivery_cost_coverage_bps',v_delivery_coverage_bps,
      'delivery_cost_coverage_passes',v_delivery_coverage_passes,
      'traceable_cost_coverage_passes',v_coverage_passes
    ),
    'profit',case when v_coverage_passes then jsonb_build_object(
      'currency',v_currency,'revenue_cents',v_revenue,
      'traceable_cogs_cents',v_traceable_cogs,
      'gross_profit_before_growth_costs_cents',v_gross_profit,
      'traceable_benefit_cost_cents',v_traceable_benefit_cost,
      'traceable_delivery_cost_cents',v_traceable_delivery_cost,
      'traceable_growth_cost_cents',
        v_traceable_benefit_cost+v_traceable_delivery_cost,
      'total_traceable_cost_cents',
        v_traceable_cogs+v_traceable_benefit_cost+v_traceable_delivery_cost,
      'contribution_after_growth_costs_cents',v_contribution,
      -- Compatibility alias: this is gross profit before growth costs.
      'gross_profit_cents',v_gross_profit
    ) else 'null'::jsonb end,
    'roi',case when v_roi_bps is not null then jsonb_build_object(
      'investment_cents',v_total_investment,
      'traceable_growth_investment_cents',v_growth_investment,
      'additional_investment_cents',coalesce(p_investment_cents,0),
      'investment_reference',case
        when v_extra_reference is null then 'v114 traceable benefit and delivery cost rules'
        else 'v114 traceable growth costs + '||v_extra_reference
      end,
      'additional_investment_reference',v_extra_reference,
      'net_return_cents',v_net_return,
      'return_on_investment_bps',v_roi_bps
    ) else 'null'::jsonb end,
    'unavailable_reasons',v_unavailable,
    'limitations',jsonb_build_array(
      'profit and contribution are returned only at complete sale-line, redeemed-benefit and delivery cost coverage',
      'itemized sale residuals, including in-period refunds, are allocated proportionally with deterministic largest-remainder rounding',
      'fixed unit costs preserve full unit COGS across checkout discounts and are reduced only by the sale refund survival ratio',
      'benefit reversals use the recorded reversal sale business date rather than the entitlement wall-clock update time',
      'sale-kind cost fallback is used only for genuinely non-itemized legacy sales',
      'ROI uses traceable redeemed-benefit and delivered-provider costs plus any separately sourced additional investment',
      'this period result is descriptive and is not a causal increment claim'
    )
  );
end $function$
;

do $check_public_get_period_economics_v109$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$  with eligible as (
    select entitlement.id,entitlement.value_cents,
      entitlement.entitlement_type,entitlement.redeemed_at,
      execution_row.branch_id,contract.currency
    from public.growth_entitlements_v108 entitlement
    join public.growth_executions_v108 execution_row
      on execution_row.id=entitlement.execution_id
      and execution_row.business_id=entitlement.business_id
    cross join lateral app.v106_reporting_contract(
      entitlement.business_id,execution_row.branch_id,entitlement.redeemed_at
    ) contract
$lit$;
  v_new1 constant text := $lit$  with eligible as (
    select entitlement.id,entitlement.value_cents,
      entitlement.entitlement_type,entitlement.redeemed_at,
      execution_row.branch_id,contract.currency
    from public.growth_entitlements_v108 entitlement
    join public.growth_executions_v108 execution_row
      on execution_row.id=entitlement.execution_id
      and execution_row.business_id=entitlement.business_id
    join public.clients entitlement_client
      on entitlement_client.id=entitlement.client_id
     and entitlement_client.business_id=entitlement.business_id
    cross join lateral app.v106_reporting_contract(
      entitlement.business_id,execution_row.branch_id,entitlement.redeemed_at
    ) contract
$lit$;
  v_old2 constant text := $lit$    where entitlement.business_id=p_business
      and (p_branch is null or execution_row.branch_id=p_branch)
      and entitlement.redeemed_at is not null
      and entitlement.redeemed_at<=p_as_of
      and (
$lit$;
  v_new2 constant text := $lit$    where entitlement.business_id=p_business
      and (p_branch is null or execution_row.branch_id=p_branch)
      and entitlement.redeemed_at is not null
      and entitlement.redeemed_at<=p_as_of
      and not entitlement_client.is_synthetic
      and (
$lit$;
begin
  select def into v_before from _v744_before where fn = $lit$get_period_economics_v109$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = $lit$public$lit$ and p.proname = $lit$get_period_economics_v109$lit$;
  if position(v_old1 in v_before) = 0 then
    raise exception 'public.get_period_economics_v109: hunk 1 anchor not found in captured body';
  end if;
  if position(v_old2 in v_before) = 0 then
    raise exception 'public.get_period_economics_v109: hunk 2 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  v_expect := replace(v_expect, v_old2, v_new2);
  if v_expect <> v_after then
    raise exception 'public.get_period_economics_v109: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check_public_get_period_economics_v109$;

-- =============================================================================================
-- PART B -- allowlist re-seed. Same table, same discipline as nestly_v743's own seed: each row is
-- READ and JUSTIFIED, not a blanket exemption. These seventeen were caught by Part C's new
-- 'mixed' pass and confirmed, by hand, NOT to be bugs.
-- =============================================================================================

insert into app.ci_synthetic_scan_allowlist_v743 (function_signature, reason, added_by_migration) values
  ('app.ci_customer_classes_v1(p_business uuid, p_client uuid, p_as_of timestamp with time zone)', 'the lifetime-spend p80 percentile''s inner correlated sum(s.amount_cents) subquery is scoped to c.id from a population CTE that already requires not coalesce(c.is_synthetic, false) two lines above -- the marker is textually outside this specific subquery''s own statement boundary, not absent from the guard chain.', 'nestly_v744'),
  ('app.ci_exclusion_counts_v680(p_business uuid, p_branch uuid, p_from date, p_to date, p_as_of timestamp with time zone)', 'this IS the exclusion-count reconciliation kernel: every field (reversed_sales, synthetic_clients, anonymous_sales, missing_demographics, overlapping_campaigns) deliberately reports the size of a population OTHER readers exclude. Filtering synthetic clients out of "synthetic_clients" or reversed sales out of "reversed_sales" would make the count of what was excluded misstate what was actually excluded.', 'nestly_v744'),
  ('app.get_growth_execution_result_at_v108(p_execution uuid, p_as_of timestamp with time zone)', 'the member_result CTE''s two correlated sum(app.v106_sale_residual_minor(...)) subqueries (purchased / revenue_cents) are scoped to member.effective_client_id from the effective_members CTE, which already requires not client.is_synthetic (nestly_v743 fix #4) -- the marker sits outside these particular correlated subqueries'' own statement boundary. v_overlap itself is fixed in this migration (Part A #4).', 'nestly_v744'),
  ('app.v179_business_insights(p_business uuid, p_from date, p_to date, p_prior_from date, p_prior_to date)', 'two residual windows: (1) the top-selling-items sale_items aggregate reads window_all_sales, which its own in-file comment (nestly_v548) declares MUST replicate the unscoped dashboard headline verbatim, synthetic-client exclusion deliberately not included -- "do not tidy the filters into matching lifetime_sales, the mismatch is the bug this migration exists to end" refers to a different, already-tracked discrepancy, not this migration; (2) the top_customers jsonb_agg joins public.clients only for full_name/phone display -- its population is window_clients, built from window_sales -> lifetime_sales, which already requires not coalesce(client.is_synthetic, false). The three points-liability figures this same function got wrong are fixed in Part A #3.', 'nestly_v744'),
  ('public.get_campaign_results(p_campaign uuid)', 'the judged CTE''s two correlated exists(...) subqueries (returned / revenue_cents) are scoped to member.client_id from a population that already joins public.clients and requires not client.is_synthetic two lines above (nestly_v743 fix #3) -- the marker sits outside these correlated subqueries'' own statement boundary.', 'nestly_v744'),
  ('public.get_ci_acquisition_v1(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone)', 'the correlated count(distinct app.ci_visit_day_v699(...)) subquery is scoped to c.id from a public.clients query that already requires not coalesce(c.is_synthetic, false).', 'nestly_v744'),
  ('public.get_ci_demographic_cohort_v1(p_business uuid, p_gender text, p_age_from integer, p_age_to integer, p_node_key text, p_from date, p_to date, p_return_window_days integer, p_branch uuid, p_as_of timestamp with time zone)', 'cohort_observations'' count(*) is scoped to s.client_id in (select client_id from cohort), and cohort descends from classified -> demog -> qualifying_purchases, which already joins public.clients and requires not coalesce(c.is_synthetic, false).', 'nestly_v744'),
  ('public.get_ci_service_intelligence_v1(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone)', 'the correlated sum(si2.line_cents) subquery reads public.sale_items (which carries no client_id of its own) scoped to si2.sale_id = s.id, where s is drawn from a population already carrying app.analytics_sale_class_v1(s).is_synthetic_client filtering elsewhere in this same function.', 'nestly_v744'),
  ('public.get_ci_staff_identity_v1(p_business uuid, p_from date, p_to date, p_branch uuid)', 'the correlated jsonb_agg(distinct si.staff_id) subquery reads public.sale_items (no client_id of its own) scoped to si.sale_id = p.sale_id, where p is drawn from a population already filtered not coalesce(c.is_synthetic, false) elsewhere in this same function.', 'nestly_v744'),
  ('public.get_period_economics_v109(p_business uuid, p_from date, p_to date, p_branch uuid, p_investment_cents bigint, p_investment_reference text, p_as_of timestamp with time zone)', 'three residual windows: (1)/(2) two count(distinct contract.currency)/min(contract.currency) checks verify currency consistency across sales in scope -- a data-integrity check with no customer dimension, not a revenue or population aggregate; (3) the correlated sum(item.line_cents) subquery reads public.sale_items scoped to item.sale_id = sale.id, where sale is drawn from sale_summary, an already business/period-scoped population. The growth_entitlements_v108 marketing-cost defect this function had is fixed in Part A #8.', 'nestly_v744'),
  ('public.get_revenue_driver_decomposition_v109(p_business uuid, p_current_from date, p_current_to date, p_comparison_from date, p_comparison_to date, p_branch uuid, p_as_of timestamp with time zone)', 'both flagged windows are count(distinct contract.currency)/min(contract.currency) currency-consistency checks (current and comparison windows) -- a data-integrity check with no customer dimension, not a revenue or population aggregate.', 'nestly_v744'),
  ('public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone)', 'the correlated abs(sum(r.amount_cents)) reversal-amount subquery is scoped to r.reversal_of = s.id, where s is drawn from a population already carrying app.analytics_sale_class_v1(s).is_synthetic_client filtering in the same statement''s outer query.', 'nestly_v744'),
  ('public.platform_get_assigned_firm_report_v94(p_business uuid, p_branch uuid, p_from date, p_to date)', 'the catalogue/item-mix aggregates (max(...), count(distinct item.sale_id), etc.) read public.sale_items (no client_id of its own) joined to valid_sales, which already carries app.analytics_sale_class_v1(sale).is_synthetic_client filtering earlier in this function.', 'nestly_v744'),
  ('public.platform_get_catalogue_affinity_v94(p_business uuid, p_branch uuid, p_from date, p_to date, p_limit integer)', 'the catalogue-affinity aggregates (count(distinct ...), max(...), sum(product_item.qty)) read public.sale_items (no client_id of its own) joined to valid_sales, which already carries app.analytics_sale_class_v1(sale).is_synthetic_client filtering earlier in this function.', 'nestly_v744'),
  ('public.preview_campaign_audience_v155(p_business uuid, p_audience_key text, p_scope_mode text, p_branch_ids uuid[], p_operational_branch uuid)', 'visit_facts (max(sale.occurred_at)) and customer_scope (distinct sale.client_id) are per-client_id lookups joined downstream, by customer.id, to customer_rows, which already requires customer.is_synthetic = false before any count(*) is taken -- a synthetic client''s visit facts are computed but never surface, since no synthetic customer row exists in customer_rows to join against.', 'nestly_v744'),
  ('public.staff_customer_bucket_counts_v290(p_business uuid, p_search text, p_scope_mode text, p_branch_ids uuid[], p_operational_branch uuid)', 'same shape as preview_campaign_audience_v155: the correlated max(sale.occurred_at) visit_facts CTE is joined downstream by customer.id to a population that already filters customer.is_synthetic = false before any count(*) is taken.', 'nestly_v744'),
  ('public.staff_list_package_entitlements_v102(p_business uuid)', 'the correlated max(used.created_at) "last_used_at" subquery is scoped to used.client_package_id = customer_package.id, where customer_package is drawn from a join to public.clients that already requires not client.is_synthetic (nestly_v743 fix #10).', 'nestly_v744'),
  ('public.business_support_get_thread_v531(p_business uuid, p_conversation uuid, p_limit integer)', 'single-conversation-thread kernel (p_conversation) -- one support thread''s own messages, not a customer population aggregate. Newly caught by the v744 jsonb_agg addition to the aggregate regex, not by the table-list widening.', 'nestly_v744'),
  ('public.business_support_list_conversations_v531(p_business uuid, p_state text, p_limit integer)', 'business-wide support-inbox listing scoped by conversation state, not a customer identity population -- a synthetic fixture''s support thread, if one existed, would legitimately belong in the owner''s inbox same as any other. Newly caught by the v744 jsonb_agg addition.', 'nestly_v744'),
  ('public.customer_get_appointments(p_business_slug text)', 'per-customer self-view RPC -- the caller''s own appointments only. Newly caught by the v744 jsonb_agg addition.', 'nestly_v744'),
  ('public.customer_get_transaction_history_v167(p_business_slug text, p_cursor jsonb)', 'per-customer self-view RPC -- delegates to public.customer_get_transaction_history_v81 (already allowlisted) and paginates the caller''s own history. Newly caught by the v744 jsonb_agg addition.', 'nestly_v744'),
  ('public.customer_portal_capabilities(p_business_slug text)', 'bool_or over this business''s own programme-catalogue rows (kind/active flags) -- a business-level capability flag, no client/customer dimension at all. Newly caught by the v744 bool_or addition.', 'nestly_v744'),
  ('public.get_appointment_history_v1(p_business uuid, p_appointment uuid)', 'single-appointment kernel (p_appointment) -- one appointment''s own status-event and reschedule history, not a customer population aggregate. Newly caught by the v744 jsonb_agg addition.', 'nestly_v744'),
  ('public.get_sv_account(p_business uuid, p_client uuid)', 'single-client stored-value account kernel (p_client) -- one customer''s own lots and ledger. Newly caught by the v744 jsonb_agg addition.', 'nestly_v744'),
  ('public.internal_public_booking_availability(p_slug text, p_service uuid, p_staff uuid, p_from date, p_days integer, p_branch uuid)', 'staff/slot capacity engine for the public booking widget -- proposes availability from staff schedules, not a customer population aggregate. Newly caught by the v744 jsonb_agg addition.', 'nestly_v744'),
  ('public.list_my_appointments(p_slug text, p_phone text)', 'per-customer self-view RPC resolved by p_phone (the caller''s own verified number) -- the caller''s own appointments only. Newly caught by the v744 json_agg addition.', 'nestly_v744'),
  ('public.staff_get_client_credit_history(p_business uuid, p_client uuid, p_limit integer)', 'single-client credit/gift-card history kernel (p_client) -- one customer''s own movements. Newly caught by the v744 jsonb_agg addition.', 'nestly_v744'),
  ('public.staff_get_customer_entitlements_v102(p_business uuid, p_client uuid)', 'single-client package-entitlement kernel (p_client) -- one customer''s own packages. Newly caught by the v744 jsonb_agg addition.', 'nestly_v744'),
  ('public.staff_get_reward_entitlements_v99(p_business uuid, p_client uuid)', 'single-client reward-entitlement kernel (p_client) -- one customer''s own rewards. Newly caught by the v744 jsonb_agg addition.', 'nestly_v744'),
  ('public.staff_gift_reversal_workflows_v665(p_business uuid, p_client uuid, p_limit integer)', 'single-client gift-reversal-workflow kernel (p_client) -- one customer''s own reversible gifts. Newly caught by the v744 jsonb_agg addition.', 'nestly_v744'),
  ('public.staff_list_visit_feedback(p_business uuid, p_status text, p_limit integer)', 'visit_feedback rows require a verified customer identity/link a synthetic fixture client does not possess by construction -- the same structural-unreachability reasoning nestly_v743 already applied to the sibling public.staff_list_visit_feedback_v145. Newly caught by the v744 jsonb_agg addition.', 'nestly_v744');

-- =============================================================================================
-- PART C -- the hardened scanner. Same function name, same allowlist table. Internal version
-- note (the comment inside the function body) bumped to v744; the allowlist table name itself is
-- unchanged (still app.ci_synthetic_scan_allowlist_v743) since it is not being replaced, only
-- appended to.
-- =============================================================================================

create or replace function app.ci_synthetic_scan_mixed_v744()
 returns table(schema_name text, function_name text, reason text)
 language plpgsql
 stable
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  r record;
  v_body text;
  v_lower text;
  v_chars text[];
  v_agg_re constant text :=
    '(sum|count|avg|percentile_|lag|array_agg|string_agg|min|max|bool_or|bool_and|every|jsonb_agg|json_agg)\(';
  v_marker_re constant text := '(is_synthetic_client|is_synthetic|analytics_sale_class_v1)';
  v_table_re constant text :=
    '\ypublic\.(sales|sale_items|clients|appointments|client_packages|points_ledger|credit_ledger|reward_grants|client_credit_balance|client_points_balance|sale_balance)\y';
  v_len int;
  v_start int;
  v_end int;
  v_depth int;
  v_i int;
  v_win text;
  v_any_guarded boolean;
  v_any_unguarded boolean;
  v_cursor int;
  v_next int;
  v_word text;
  v_words constant text[] := array[
    'sum(', 'count(', 'avg(', 'percentile_', 'lag(', 'array_agg(', 'string_agg(',
    'min(', 'max(', 'bool_or(', 'bool_and(', 'every(', 'jsonb_agg(', 'json_agg('];
  v_best int;
  v_bestlen int;
  v_skip int;
begin
  for r in
    select p.oid, n.nspname::text as sn, p.proname::text as fn,
           pg_get_function_identity_arguments(p.oid) as args, p.prosrc as body
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app')
       and p.prokind = 'f'
       and p.prosrc ~* v_table_re
       and p.prosrc ~* v_agg_re
       and not exists (
         select 1 from app.ci_synthetic_scan_allowlist_v743 allow
          where allow.function_signature =
            n.nspname || '.' || p.proname || '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')'
       )
  loop
    v_body := r.body;
    v_lower := lower(v_body);
    v_len := length(v_body);
    v_chars := regexp_split_to_array(v_body, '');
    v_any_guarded := false;
    v_any_unguarded := false;
    v_cursor := 1;

    loop
      v_best := null;
      v_bestlen := 0;
      foreach v_word in array v_words loop
        v_next := strpos(substring(v_lower from v_cursor), v_word);
        if v_next > 0 then
          v_next := v_next + v_cursor - 1;
          if v_best is null or v_next < v_best then
            v_best := v_next;
            v_bestlen := length(v_word);
          end if;
        end if;
      end loop;
      exit when v_best is null;

      -- Backward: nearest TRUE statement boundary -- an unmatched '(' immediately followed by
      -- select/with (a subquery open), a depth-0 ';', or the start of the body. A plain
      -- function-call paren (coalesce(, round(, greatest(, ...) is transparent: it does not
      -- bound the window, so scanning continues past it looking further left.
      v_i := v_best - 1;
      v_depth := 0;
      v_start := 1;
      v_skip := 0;
      while v_i >= 1 loop
        if v_chars[v_i] = ')' then
          v_depth := v_depth + 1;
        elsif v_chars[v_i] = '(' then
          if v_depth = 0 then
            if substring(v_lower from v_i + 1) ~ '^\s*(select|with)\y' then
              v_start := v_i + 1;
              exit;
            else
              v_skip := v_skip + 1;
            end if;
          else
            v_depth := v_depth - 1;
          end if;
        elsif v_chars[v_i] = ';' and v_depth = 0 then
          v_start := v_i + 1;
          exit;
        end if;
        v_i := v_i - 1;
      end loop;

      -- Forward: the matching close of a subquery-open at depth 0, or the statement's own
      -- terminating ';' at depth 0 -- swallowing v_skip transparent wrapper closes first, since
      -- those parens were opened before this scan's own start and so are never seen as '(' here.
      v_i := v_best;
      v_depth := 0;
      v_end := v_len;
      while v_i <= v_len loop
        if v_chars[v_i] = '(' then
          v_depth := v_depth + 1;
        elsif v_chars[v_i] = ')' then
          if v_depth = 0 then
            if v_skip > 0 then
              v_skip := v_skip - 1;
            else
              v_end := v_i - 1;
              exit;
            end if;
          else
            v_depth := v_depth - 1;
          end if;
        elsif v_chars[v_i] = ';' and v_depth = 0 then
          v_end := v_i - 1;
          exit;
        end if;
        v_i := v_i + 1;
      end loop;

      v_win := substring(v_body from v_start for greatest(v_end - v_start + 1, 0));
      if v_win ~* v_table_re then
        if v_win ~* v_marker_re then
          v_any_guarded := true;
        else
          v_any_unguarded := true;
        end if;
      end if;

      v_cursor := v_best + v_bestlen;
    end loop;

    if v_any_guarded and v_any_unguarded then
      schema_name := r.sn;
      function_name := r.fn;
      reason := 'mixed: at least one aggregate statement over a guarded table/view lacks an '
                'exclusion marker while another statement in the same function has one';
      return next;
    end if;
  end loop;
end
$function$;

revoke all on function app.ci_synthetic_scan_mixed_v744() from public;
grant execute on function app.ci_synthetic_scan_mixed_v744() to postgres, service_role;

create or replace function app.ci_synthetic_scan_v743()
 returns table(schema_name text, function_name text, reason text)
 language sql
 stable
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  -- v744: table regex widened to the three synthetic-exposed VIEWS (client_credit_balance,
  -- client_points_balance, sale_balance) alongside the seven base tables; aggregate regex
  -- widened to bool_or/bool_and/every/jsonb_agg/json_agg/count(1/count(distinct (the last two
  -- already implied by the bare count\( alternative, kept explicit per instruction). Still
  -- reports a function only if it is not in the allowlist.
  select n.nspname::text, p.proname::text,
         'aggregates a synthetic-exposed table/view with no exclusion marker and no allowlist entry'::text
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public','app')
     and p.prokind = 'f'
     and pg_catalog.pg_get_functiondef(p.oid) ~* '\ypublic\.(sales|sale_items|clients|appointments|client_packages|points_ledger|credit_ledger|reward_grants|client_credit_balance|client_points_balance|sale_balance)\y'
     and pg_catalog.pg_get_functiondef(p.oid) ~* '\y(sum|count|avg|percentile_|lag|array_agg|string_agg|min|max|bool_or|bool_and|every|jsonb_agg|json_agg)\(|count\(1|count\(distinct'
     and pg_catalog.pg_get_functiondef(p.oid) !~* '(is_synthetic_client|is_synthetic|analytics_sale_class_v1)'
     and not exists (
       select 1 from app.ci_synthetic_scan_allowlist_v743 allow
        where allow.function_signature =
          n.nspname || '.' || p.proname || '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')'
     )
   union all
  select mixed.schema_name, mixed.function_name, mixed.reason
    from app.ci_synthetic_scan_mixed_v744() mixed
   order by 1, 2;
$function$;

revoke all on function app.ci_synthetic_scan_v743() from public;
grant execute on function app.ci_synthetic_scan_v743() to postgres, service_role;

-- Rollback-safe check: the moment this migration applies, the estate must already be clean.
do $v744_gate$
declare v_n integer;
begin
  select count(*) into v_n from app.ci_synthetic_scan_v743();
  if v_n <> 0 then
    raise exception 'v744: synthetic scanner found % unguarded/mixed, unallowlisted function(s) at '
      'the moment this migration applied -- see app.ci_synthetic_scan_v743()', v_n;
  end if;
end
$v744_gate$;

commit;
