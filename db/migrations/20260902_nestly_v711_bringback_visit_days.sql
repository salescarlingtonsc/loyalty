-- NESTLY v711 — check 4 refutation: a same-day split bill was inflating the measured bring-back
-- loop's "prior visits" and corrupting its cadence, the same class of bug nestly_v699 fixed across
-- every other CI "visits" reader and nestly_v709 fixed in cadence-batch and tier resolution.
--
-- Contract: docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md (v672, frozen). Fixture guide:
-- docs/qa/CI-CORPUS-FIXTURE-GUIDE.md. Proven by
-- db/tests/executed/v711_corpus_bringback_visit_days.sql.
--
-- ============================================================================================
-- WHAT WAS WRONG (check 4). public.refresh_growth_recommendation_v108's metrics CTE
-- (db/migrations/20260729_nestly_v108_measured_bringback_loop.sql:809-819, unchanged by nestly_
-- v113's re-serialization or nestly_v690's arm-size patch) lags over every qualifying SALE ROW,
-- not over distinct visit-days:
--
--   visits as (
--     select canonical_sales.*,
--       extract(epoch from (occurred_at - lag(occurred_at) over (
--         partition by client_id order by occurred_at, id))) / 86400.0 as interval_days
--     from canonical_sales
--   ), metrics as (
--     select client_id, count(*)::integer as prior_visits, ...
--       percentile_cont(0.5) within group (order by interval_days)
--         filter (where interval_days is not null) as cadence_days, ...
--   )
--
-- A client with 3 sales on the SAME calendar day (a split bill) plus 1 sale the next day plus 1
-- sale much later reads as prior_visits=5, not 3, and the two near-zero same-day "intervals" drag
-- cadence_days toward zero (the refuter fixture's raw arithmetic gives ~0.42; a materially similar
-- shape to the ~0.50 example this migration was commissioned against). Both figures are
-- materialised into growth_recommendation_members_v108 and feed the
-- `minimum_prior_visits` gate (judged CTE, exclusion_reason='insufficient_history') and the lapse
-- test (`lapse_days < greatest(minimum_lapse_days, ceil(cadence_days * cadence_multiplier))`) —
-- exactly the two consumers nestly_v699's header warned every "visits" figure eventually feeds.
--
-- refresh_growth_recommendation_v108 was untouched by both nestly_v699 (which swept category_
-- customers, staff_performance, discount_dependency, v179_business_insights) and nestly_v709
-- (which swept customer_cadence_batch_v1 and tier_resolve_v426) because nobody had re-checked
-- v108's own metrics CTE once the authority existed. This migration closes that gap.
--
-- ============================================================================================
-- WHAT THIS DOES. Extract-and-diff against the LIVE body (anchored on the post-v113/v690 text
-- exactly as pg_get_functiondef returns it today — condensed, no operator spacing — per the
-- fixture guide and the v668/v690/v695/v709 precedent of anchoring on the live body, never an
-- assumed source formatting).
--
-- The `visits`/`metrics` CTE pair is replaced by four CTEs:
--   1. visit_days — canonical_sales collapsed to one row per (client_id,
--      app.ci_visit_day_v699(occurred_at)) — the one visit-day authority, nestly_v699 — anchored
--      at that day's FIRST qualifying sale's occurred_at. Not the day boundary, and not the day's
--      LAST sale: the same anchor rule nestly_v709 stated for app.customer_cadence_batch_v1's
--      visit_days CTE, restated here for a second consumer of the same authority.
--   2. visits — lags over visit-days instead of sale rows, so interval_days is an inter-visit-DAY
--      gap.
--   3. amounts — average_transaction_cents and historical_revenue_cents are computed separately,
--      over every individual qualifying sale (unchanged from before this migration): only the
--      visits denominator collapses, the revenue/ticket-size figures do not, because nothing in
--      check 4 or this migration's brief asked them to.
--   4. metrics — prior_visits is now `count(*)` over the day-collapsed `visits` rows (same
--      aggregate expression, corrected input cardinality — a split bill counts once).
--      cadence_days keeps the same statistic (percentile_cont(0.5), i.e. the median) over the
--      now-correct inter-visit-DAY gaps. last_visit_at is `max(visit.occurred_at)` over the
--      day-collapsed rows: for a client whose sales already land on distinct days this is
--      byte-identical to before (no day has more than one sale, so the day's "first sale" IS its
--      only sale); the anchor choice only bites a collision on the customer's own LAST visit day,
--      where last_visit_at now reports that day's first sale rather than its last — the
--      documented, accepted consequence of the anchor rule, not an oversight (same tradeoff
--      nestly_v709 accepted for customer_cadence_batch_v1).
--
-- Every other column judged/returned by the function (lapse_days, eligible, exclusion_reason,
-- the suppression list, the recommendation row, the audit_log entry) is computed exactly as
-- before from these same five output columns — nothing downstream of `metrics` needed a separate
-- edit, because prior_visits/cadence_days/last_visit_at are corrected at their source and every
-- reader of them (the `judged` CTE's minimum_prior_visits/lapse gates, the jsonb_agg into
-- v_candidates, the INSERT into growth_recommendation_members_v108) already reads those columns
-- by name.
--
-- app.ci_visit_registry_v699 gains one new entry: 'refresh_growth_recommendation_v108',
-- uses_authority=true — the same extract-and-diff, anchored on the registry's own current last
-- entry, that nestly_v709 used to add its two entries.
--
-- ============================================================================================
-- REGRESSION SURFACE CHECKED (not edited). The only EXECUTED fixture that touches
-- refresh_growth_recommendation_v108 at all is db/tests/executed/v690_corpus_dispersion_floor.sql
-- (its D5 block) — and D5 never calls the function with seeded sales; it only (a) greps the live
-- pg_get_functiondef for the app.subgroup_evidence_v1(...) arm-size calls nestly_v690 added and
-- the absence of the old raw `<` comparison, both of which are unrelated to and untouched by this
-- migration's CTE surgery, and (b) evaluates app.subgroup_evidence_v1 directly against literal
-- arm-size numbers, calling neither the metrics CTE nor any sale data. Every other test file that
-- mentions refresh_growth_recommendation_v108 (db/tests/v108_measured_bringback_loop.sql,
-- db/tests/v113_effective_identity_consumers.sql, db/tests/v690_dispersion_and_one_floor.sql) has
-- no `executed/` counterpart and is read by nobody per the harness's own contract
-- (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md), so nothing there can regress. D5 verified unaffected by
-- rerunning db/tests/executed/v690_corpus_dispersion_floor.sql against this migration's cluster.
-- ============================================================================================
begin;

-- ---------------------------------------------------------------------------------------------
-- 1 · public.refresh_growth_recommendation_v108 — extract-and-diff, single anchor (the
--     visits/metrics CTE pair), checked to occur exactly once against the LIVE body before being
--     patched, and the patch reversed against the AFTER text to prove nothing else moved.
-- ---------------------------------------------------------------------------------------------
do $patch_v108$
declare
  v_def text;

  v_anchor constant text :=
E'  visits as (
    select canonical_sales.*,
      extract(epoch from (
        occurred_at-lag(occurred_at) over (
          partition by client_id order by occurred_at,id
        )
      ))/86400.0 as interval_days
    from canonical_sales
  ),
  metrics as (
    select visit.client_id,
      count(*)::integer as prior_visits,
      max(visit.occurred_at) as last_visit_at,
      percentile_cont(0.5) within group(order by visit.interval_days)
        filter(where visit.interval_days is not null) as cadence_days,
      floor(extract(epoch from(v_now-max(visit.occurred_at)))/86400)::integer
        as lapse_days,
      round(avg(visit.amount_cents))::bigint as average_transaction_cents,
      sum(visit.amount_cents)::bigint as historical_revenue_cents
    from visits visit
    group by visit.client_id
  ),';

  v_new constant text :=
E'  visit_days as (
    /* nestly_v711 (check 4 fix): collapse same-day sales (a split bill: several tickets, one
       customer, one afternoon) into ONE visit before prior_visits/cadence_days are computed. A
       visit-day is app.ci_visit_day_v699(occurred_at) (the one visit-day authority; nestly_v699),
       anchored at the day''s FIRST qualifying sale''s occurred_at, not the day boundary, and not
       the day''s last sale (same anchor rule as nestly_v709''s fix to
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
  ),';

  v_count     integer;
  v_expected  text;
  v_after     text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.refresh_growth_recommendation_v108(uuid,uuid)')) into v_def;
  if v_def is null then
    raise exception 'v711: public.refresh_growth_recommendation_v108 not found';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 1 then
    raise exception 'v711: refresh_growth_recommendation_v108 visits/metrics anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor, v_new);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.refresh_growth_recommendation_v108(uuid,uuid)')) into v_after;

  v_roundtrip := replace(v_after, v_new, v_anchor);
  if v_roundtrip <> v_def then
    raise exception
      'v711: refresh_growth_recommendation_v108 changed by more than the visit-day collapse. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v711: refresh_growth_recommendation_v108 visit-day authority did not land';
  end if;
end
$patch_v108$;
-- ACL restated verbatim from the live proacl (unchanged by this migration — same argument list).
revoke all on function public.refresh_growth_recommendation_v108(uuid,uuid) from public, anon;
grant execute on function public.refresh_growth_recommendation_v108(uuid,uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 2 · app.ci_visit_registry_v699 — register the fixed reader. Extract-and-diff against the live
--     body; the anchor is the registry's own current last entry (app.tier_resolve_v426, added by
--     nestly_v709), unredefined since v709 shipped it.
-- ---------------------------------------------------------------------------------------------
do $patch_registry$
declare
  v_def text;
  v_anchor constant text :=
E'      ''app.tier_resolve_v426'', jsonb_build_object(
        ''uses_authority'', true,
        ''note'', ''the tier_basis=visits metric counts distinct visit-days, the same authority every other visits-shaped CI reader in this registry uses (nestly_v709, check 4)'')
    )
  );';
  v_new constant text :=
E'      ''app.tier_resolve_v426'', jsonb_build_object(
        ''uses_authority'', true,
        ''note'', ''the tier_basis=visits metric counts distinct visit-days, the same authority every other visits-shaped CI reader in this registry uses (nestly_v709, check 4)''),
      ''refresh_growth_recommendation_v108'', jsonb_build_object(
        ''uses_authority'', true,
        ''note'', ''prior_visits / cadence_days are computed over distinct visit-days, not raw sale rows; a visit-day is anchored at that day''''s first qualifying sale; last_visit_at and the average/historical revenue amounts are unchanged (nestly_v711, check 4)'')
    )
  );';
  v_count     integer;
  v_after     text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('app.ci_visit_registry_v699()')) into v_def;
  if v_def is null then raise exception 'v711: app.ci_visit_registry_v699 not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 1 then
    raise exception 'v711: ci_visit_registry_v699 tier_resolve_v426 anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  execute replace(v_def, v_anchor, v_new);

  select pg_get_functiondef(to_regprocedure('app.ci_visit_registry_v699()')) into v_after;
  v_roundtrip := replace(v_after, v_new, v_anchor);
  if v_roundtrip <> v_def then
    raise exception
      'v711: ci_visit_registry_v699 changed by more than the one new registry entry. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('refresh_growth_recommendation_v108' in v_after) = 0 then
    raise exception 'v711: ci_visit_registry_v699 did not gain the new entry';
  end if;
end
$patch_registry$;
-- ACL restated verbatim from the live proacl (unchanged by this migration — same argument list).
revoke all on function app.ci_visit_registry_v699() from public, anon;
grant execute on function app.ci_visit_registry_v699() to service_role;

commit;
