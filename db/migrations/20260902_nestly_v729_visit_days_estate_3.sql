-- NESTLY v729 -- visit-day estate sweep 3: the tier-basis metric the customer wallet screen
-- itself reads, and the two cadence-fallback pooled authorities underneath it, were never swept
-- by nestly_v699/v709/v711/v714/v724. This migration closes both, registers two readers that
-- were already correct but never named in app.ci_visit_registry_v699, and reconciles
-- app.ci_metric_dictionary_v1's 'visit' entry, whose notes still claimed an owed client-side fix
-- that shipped in commit 4ec3e040.
--
-- Contract: docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md (v672, frozen). Fixture guide:
-- docs/qa/CI-CORPUS-FIXTURE-GUIDE.md. Proven by
-- db/tests/executed/v729_corpus_visit_days_estate_3.sql.
--
-- ============================================================================================
-- WHAT WAS WRONG.
--
--   1. public.customer_get_business_presentation_v95 (nestly_v566:147) -- the tier_basis='visits'
--      branch read `count(*) from public.sales where ... counts_as_visit`, one row per SALE, the
--      exact defect app.tier_resolve_v426 carried until nestly_v709 fixed it. This is the
--      customer-facing wallet screen's OWN tier metric/progress bar, computed independently of
--      app.tier_resolve_v426 rather than delegating to it (nestly_v310's D1 twin, unchanged by
--      this migration), so v709's fix never reached it. A same-day split bill therefore let a
--      customer's own wallet screen show them one rung higher than app.tier_resolve_v426 (the
--      authority every other tier reader in the product uses) would say.
--
--   2. app.service_cadence_v695 and app.segment_cadence_v695 (nestly_v695) -- the pooled
--      cadence-fallback authorities app.customer_cadence_v1 asks when a customer's own purchase
--      history does not clear the observations floor. Both pooled over raw SALE rows: a same-day
--      split purchase of one service (two tickets, one afternoon) counted as two purchases toward
--      the ">= 2 times" qualification and contributed a near-zero interval to the pooled median,
--      the same shape of defect nestly_v709 fixed for app.customer_cadence_batch_v1 and
--      app.tier_resolve_v426.
--
--   3. app.ci_visit_registry_v699 never named public.get_ci_service_intelligence_v1 (already
--      correct since nestly_v710) or app.customer_cadence_v1 (computes no visit count of its own;
--      it inherits the fix transitively through app.customer_cadence_batch_v1, which nestly_v709
--      already fixed) -- so the registry's own claim to be the "definitive list of which readers
--      defer to this authority" was incomplete for two readers that were either already correct
--      or already fixed by inheritance.
--
--   4. app.ci_metric_dictionary_v1's 'visit' entry still said the owner dashboard's Visits-KPI
--      drill-down dialog was "an owed client-side fix, not a database one" -- that shipped in
--      commit 4ec3e040 (2026-09-02) and is no longer owed. The entry named no path for the two
--      genuinely open, owner-decision item this authority does NOT cover: RETENTION-VISIT-
--      UNIT-001 (app.c45_base_actionable_wallet_card's visits_remaining figure, and the
--      retention engine's withdrawn goal-visits reward loop) still disagree with this authority
--      and are deliberately left alone here pending that ruling -- see
--      docs/qa/OWNER-ISSUE-LEDGER.md and db/tests/executed/v728_retention_visit_unit_pin.sql,
--      which pins the current (pre-decision) behaviour. STAMP-MILESTONE-OFF-001 is a separate,
--      unrelated open item (stamp-programme-off gift visibility) and is not a visits question, so
--      it is not named here.
--
-- ============================================================================================
-- WHAT THIS DOES.
--
-- (a) public.customer_get_business_presentation_v95 -- single anchor, unredefined since
--     nestly_v566 shipped it (grepped: no later migration touches this function). The
--     tier_basis='visits' branch's `count(*)` becomes
--     `count(distinct app.ci_visit_day_v699(occurred_at))` -- byte-identical to the fix
--     nestly_v709 applied to app.tier_resolve_v426's own visits branch. The wallet screen's
--     metric is not repointed to call app.tier_resolve_v426 itself in this pass (that resolver
--     reads tier_basis from public.loyalty_programs without this function's own `active`/
--     `current_config_version_id` programme-selection ordering, and rebuilding the tier/next/
--     progress payload around its jsonb shape is a larger, separately-risked change) -- it is
--     given the SAME authority app.tier_resolve_v426 already uses, so the two numbers agree for
--     every business this migration's fixture and the existing v566/v709 fixtures cover.
--
-- (b) app.service_cadence_v695 -- three anchors (comment-free spans only; the CTE this function
--     opens with is preceded by a two-line comment in the committed migration text, so the
--     anchors below start and end on pure-code boundaries that occur identically whether or not
--     that comment survives a stripping pass). A new `visit_days` CTE sits between `purchases`
--     and `qualifying_clients`: purchases are grouped by
--     (client_id, app.ci_visit_day_v699(occurred_at)), each visit-day anchored at that day's
--     FIRST purchase occurred_at (the same anchor rule nestly_v709/v711/v714/v724 already use).
--     `qualifying_clients` (">= 2 times") now counts distinct visit-days, not raw sale rows, so a
--     client with a single same-day pair (one visit, two tickets) contributes zero intervals and
--     zero evidence. `sequenced` lags over visit-days instead of purchase rows.
--
-- (c) app.segment_cadence_v695 -- single anchor (this function has no interior comments; the
--     whole `qualifying`/`sequenced` block is replaced in one span, the same style
--     nestly_v709 used for app.tier_resolve_v426). Same visit-day collapse, one level coarser.
--
-- (d) app.ci_visit_registry_v699 -- five new entries: the two functions patched above, plus
--     public.get_ci_service_intelligence_v1 (uses_authority true, already correct since
--     nestly_v710, registered here for the first time) and app.customer_cadence_v1
--     (uses_authority true, inherits without its own code change -- it reads
--     app.customer_cadence_batch_v1's already visit-day-collapsed columns).
--
-- (e) app.ci_metric_dictionary_v1 -- the 'visit' entry's 'notes' value is replaced: the
--     drill-down dialog line is removed (fixed, no longer owed) and RETENTION-VISIT-UNIT-001 is
--     named as the one open, owner-decision item this authority does not reach.
--
-- ============================================================================================
-- REGRESSION SURFACE CHECKED (not edited): db/tests/executed/v695_corpus_service_cadence.sql,
-- v709_corpus_visit_days_cadence_tiers.sql, v714_corpus_visit_days_estate.sql,
-- v724_corpus_visit_days_estate_2.sql and db/tests/v566_one_claimable_answer.sql all seed every
-- client's qualifying sales on DISTINCT calendar days (grepped: whole-day `unnest(array[...])`
-- offsets, one sale per day per client, in every T1-T6/A/B/control scenario those fixtures use)
-- -- the visit-day collapse this migration adds to app.service_cadence_v695/
-- app.segment_cadence_v695 is therefore a no-op for all of them, and
-- public.customer_get_business_presentation_v95's only sales-shaped truth-table dependency in
-- v566's own fixture (the tier switched OFF, metric not asserted numerically) is unaffected by
-- a metric-computation change that only bites when the ladder is running.
-- ============================================================================================

begin;

-- ---------------------------------------------------------------------------------------------
-- (a) public.customer_get_business_presentation_v95
-- ---------------------------------------------------------------------------------------------
do $v729_presentation$
declare
  v_def text;
  v_anchor constant text :=
E'  else
    select count(*) into v_metric from public.sales
    where business_id=p_business and client_id=v_client and counts_as_visit;';
  v_new constant text :=
E'  else
    select count(distinct app.ci_visit_day_v699(occurred_at)) into v_metric from public.sales
    where business_id=p_business and client_id=v_client and counts_as_visit;';
  v_count     integer;
  v_after     text;
  v_roundtrip text;
begin
  if to_regprocedure('app.ci_visit_day_v699(timestamptz)') is null then
    raise exception 'v729: app.ci_visit_day_v699 is missing';
  end if;

  select pg_get_functiondef(to_regprocedure(
    'public.customer_get_business_presentation_v95(uuid,uuid,text)')) into v_def;
  if v_def is null then raise exception 'v729: public.customer_get_business_presentation_v95 not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 1 then
    raise exception 'v729: customer_get_business_presentation_v95 visits-metric anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  execute replace(v_def, v_anchor, v_new);

  select pg_get_functiondef(to_regprocedure(
    'public.customer_get_business_presentation_v95(uuid,uuid,text)')) into v_after;
  v_roundtrip := replace(v_after, v_new, v_anchor);
  if v_roundtrip <> v_def then
    raise exception
      'v729: customer_get_business_presentation_v95 changed by more than the visits-metric authority swap. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$v729_presentation$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.customer_get_business_presentation_v95(uuid,uuid,text) from public, anon;
grant execute on function public.customer_get_business_presentation_v95(uuid,uuid,text) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- (b) app.service_cadence_v695 -- three comment-free anchors, applied against the same v_def and
--     verified in combination by a single round-trip check.
-- ---------------------------------------------------------------------------------------------
do $v729_service_cadence$
declare
  v_def text;

  v_anchor_insert constant text :=
E'       and si.ref_id = p_service_id
  ), qualifying_clients as (';
  v_new_insert constant text :=
E'       and si.ref_id = p_service_id
  ), visit_days as (
    select client_id,
           app.ci_visit_day_v699(occurred_at) as visit_day,
           min(occurred_at) as occurred_at
      from purchases
     group by client_id, app.ci_visit_day_v699(occurred_at)
  ), qualifying_clients as (';

  v_anchor_source constant text :=
E'    select client_id from purchases group by client_id having count(*) >= 2';
  v_new_source constant text :=
E'    select client_id from visit_days group by client_id having count(*) >= 2';

  v_anchor_sequenced constant text :=
E'  ), sequenced as (
    select p.client_id, p.occurred_at,
           lag(p.occurred_at) over (
             partition by p.client_id order by p.occurred_at, p.sale_id
           ) as previous_purchase_at
      from purchases p
      join qualifying_clients q on q.client_id = p.client_id
  ), intervals as (';
  v_new_sequenced constant text :=
E'  ), sequenced as (
    select vd.client_id, vd.occurred_at,
           lag(vd.occurred_at) over (
             partition by vd.client_id order by vd.occurred_at
           ) as previous_purchase_at
      from visit_days vd
      join qualifying_clients q on q.client_id = vd.client_id
  ), intervals as (';

  v_count     integer;
  v_expected  text;
  v_after     text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'app.service_cadence_v695(uuid,uuid,timestamptz)')) into v_def;
  if v_def is null then raise exception 'v729: app.service_cadence_v695 not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_insert, ''))) / length(v_anchor_insert);
  if v_count <> 1 then
    raise exception 'v729: service_cadence_v695 insert anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_source, ''))) / length(v_anchor_source);
  if v_count <> 1 then
    raise exception 'v729: service_cadence_v695 source anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_sequenced, ''))) / length(v_anchor_sequenced);
  if v_count <> 1 then
    raise exception 'v729: service_cadence_v695 sequenced anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_insert, v_new_insert);
  v_expected := replace(v_expected, v_anchor_source, v_new_source);
  v_expected := replace(v_expected, v_anchor_sequenced, v_new_sequenced);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'app.service_cadence_v695(uuid,uuid,timestamptz)')) into v_after;
  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, v_new_insert, v_anchor_insert);
  v_roundtrip := replace(v_roundtrip, v_new_source, v_anchor_source);
  v_roundtrip := replace(v_roundtrip, v_new_sequenced, v_anchor_sequenced);
  if v_roundtrip <> v_def then
    raise exception
      'v729: service_cadence_v695 changed by more than the three intended visit-day edits. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$v729_service_cadence$;
revoke all on function app.service_cadence_v695(uuid,uuid,timestamptz) from public, anon, authenticated;
grant execute on function app.service_cadence_v695(uuid,uuid,timestamptz) to service_role;

-- ---------------------------------------------------------------------------------------------
-- (c) app.segment_cadence_v695 -- single anchor; this function carries no interior comments, so
--     the whole qualifying/sequenced block is replaced in one span (the nestly_v709 style).
-- ---------------------------------------------------------------------------------------------
do $v729_segment_cadence$
declare
  v_def text;
  v_anchor constant text :=
E'  ), qualifying as (
    select client_id from visits group by client_id having count(*) >= 2
  ), sequenced as (
    select v.client_id, v.occurred_at,
           lag(v.occurred_at) over (
             partition by v.client_id order by v.occurred_at, v.sale_id
           ) as previous_purchase_at
      from visits v
      join qualifying q on q.client_id = v.client_id
  ), intervals as (';
  v_new constant text :=
E'  ), visit_days as (
    select client_id,
           app.ci_visit_day_v699(occurred_at) as visit_day,
           min(occurred_at) as occurred_at
      from visits
     group by client_id, app.ci_visit_day_v699(occurred_at)
  ), qualifying as (
    select client_id from visit_days group by client_id having count(*) >= 2
  ), sequenced as (
    select vd.client_id, vd.occurred_at,
           lag(vd.occurred_at) over (
             partition by vd.client_id order by vd.occurred_at
           ) as previous_purchase_at
      from visit_days vd
      join qualifying q on q.client_id = vd.client_id
  ), intervals as (';
  v_count     integer;
  v_after     text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'app.segment_cadence_v695(uuid,text,text,timestamptz)')) into v_def;
  if v_def is null then raise exception 'v729: app.segment_cadence_v695 not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 1 then
    raise exception 'v729: segment_cadence_v695 anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  execute replace(v_def, v_anchor, v_new);

  select pg_get_functiondef(to_regprocedure(
    'app.segment_cadence_v695(uuid,text,text,timestamptz)')) into v_after;
  v_roundtrip := replace(v_after, v_new, v_anchor);
  if v_roundtrip <> v_def then
    raise exception
      'v729: segment_cadence_v695 changed by more than the visit-day collapse. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$v729_segment_cadence$;
revoke all on function app.segment_cadence_v695(uuid,text,text,timestamptz) from public, anon, authenticated;
grant execute on function app.segment_cadence_v695(uuid,text,text,timestamptz) to service_role;

-- ---------------------------------------------------------------------------------------------
-- (d) app.ci_visit_registry_v699 -- five new entries appended after the registry's current last
--     entry (public.staff_list_returned_customers_v300, nestly_v724).
-- ---------------------------------------------------------------------------------------------
do $v729_registry$
declare
  v_def text;
  v_anchor constant text :=
E'      ''public.staff_list_returned_customers_v300'', jsonb_build_object(
        ''uses_authority'', true,
        ''note'', ''previous_visit_at / away_days are computed over distinct visit-days; a same-day split bill on the return visit itself can no longer become its own previous_visit_at and zero away_days, hiding a real lapse (nestly_v724, estate sweep 2)'')
    )
  );
$function$';
  v_new constant text :=
E'      ''public.staff_list_returned_customers_v300'', jsonb_build_object(
        ''uses_authority'', true,
        ''note'', ''previous_visit_at / away_days are computed over distinct visit-days; a same-day split bill on the return visit itself can no longer become its own previous_visit_at and zero away_days, hiding a real lapse (nestly_v724, estate sweep 2)''),
      ''public.customer_get_business_presentation_v95'', jsonb_build_object(
        ''uses_authority'', true,
        ''note'', ''the tier_basis=visits progress metric counts distinct visit-days via app.ci_visit_day_v699, the same computation app.tier_resolve_v426 has used since nestly_v709 (nestly_v729)''),
      ''app.service_cadence_v695'', jsonb_build_object(
        ''uses_authority'', true,
        ''note'', ''purchases are collapsed into visit-days, anchored at each day''''s first purchase, before the >=2 qualification and before intervals are sequenced; a client with a single same-day pair contributes zero intervals (nestly_v729)''),
      ''app.segment_cadence_v695'', jsonb_build_object(
        ''uses_authority'', true,
        ''note'', ''the pooled category/acquisition cadence collapses same-day sales into visit-days the same way app.service_cadence_v695 now does (nestly_v729)''),
      ''public.get_ci_service_intelligence_v1'', jsonb_build_object(
        ''uses_authority'', true,
        ''note'', ''n_visits and repeat_visit_rate already counted distinct (client, visit-day) pairs since nestly_v710; this entry only registers the existing behaviour (nestly_v729)''),
      ''app.customer_cadence_v1'', jsonb_build_object(
        ''uses_authority'', true,
        ''note'', ''computes no visit count of its own; its customer_median_interval tier reads app.customer_cadence_batch_v1, which nestly_v709 already collapsed to visit-days, so this reader inherits without its own patch (nestly_v729)'')
    )
  );
$function$';
  v_count     integer;
  v_after     text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('app.ci_visit_registry_v699()')) into v_def;
  if v_def is null then raise exception 'v729: app.ci_visit_registry_v699 not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 1 then
    raise exception 'v729: ci_visit_registry_v699 anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  execute replace(v_def, v_anchor, v_new);

  select pg_get_functiondef(to_regprocedure('app.ci_visit_registry_v699()')) into v_after;
  v_roundtrip := replace(v_after, v_new, v_anchor);
  if v_roundtrip <> v_def then
    raise exception
      'v729: ci_visit_registry_v699 changed by more than the five new entries. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('public.customer_get_business_presentation_v95' in v_after) = 0
     or position('app.service_cadence_v695' in v_after) = 0
     or position('app.segment_cadence_v695' in v_after) = 0
     or position('public.get_ci_service_intelligence_v1' in v_after) = 0
     or position('app.customer_cadence_v1' in v_after) = 0 then
    raise exception 'v729: ci_visit_registry_v699 did not gain all five new entries';
  end if;
end
$v729_registry$;
revoke all on function app.ci_visit_registry_v699() from public, anon, authenticated;
grant execute on function app.ci_visit_registry_v699() to service_role;

-- ---------------------------------------------------------------------------------------------
-- (e) app.ci_metric_dictionary_v1 -- replace only the 'visit' entry's 'notes' value.
-- ---------------------------------------------------------------------------------------------
do $v729_dictionary$
declare
  v_def text;
  v_anchor constant text :=
E'        ''notes'', ''RECONCILED as of nestly_v714: call app.ci_visit_registry_v699() for the ''
          || ''definitive, fixture-proven list of which readers defer to this authority and how. ''
          || ''One item remains OUTSIDE the database: the owner dashboard''''s Visits-KPI drill-down ''
          || ''dialog (app/app.js) still lists one row per raw sale, not per visit-day, so the ''
          || ''dialog''''s row count can exceed the tile it opened from -'
  || '- an owed client-side fix, ''
          || ''not a database one; see this migration''''s header.''';
  v_new constant text :=
E'        ''notes'', ''RECONCILED as of nestly_v714, extended by nestly_v729: call ''
          || ''app.ci_visit_registry_v699() for the definitive, fixture-proven list of which ''
          || ''readers defer to this authority and how. nestly_v729 added public.customer_get_''
          || ''business_presentation_v95 (the tier progress metric), app.service_cadence_v695 and ''
          || ''app.segment_cadence_v695 (the pooled cadence-fallback authorities), and registered ''
          || ''app.customer_cadence_v1 (inherits via app.customer_cadence_batch_v1) and public.''
          || ''get_ci_service_intelligence_v1 (already correct since nestly_v710, now named). The ''
          || ''owner dashboard Visits-KPI drill-down dialog was fixed in app/app.js by commit ''
          || ''4ec3e040; it is no longer an owed client-side fix. One owner-decision item remains ''
          || ''open and is outside this authority''''s reach: RETENTION-VISIT-UNIT-001 (docs/qa/''
          || ''OWNER-ISSUE-LEDGER.md, pinned by db/tests/executed/v728_retention_visit_unit_pin.''
          || ''sql) records that app.c45_base_actionable_wallet_card''''s visits_remaining figure ''
          || ''and the retention engine''''s withdrawn goal-visits reward loop still disagree with ''
          || ''this authority; app.c45_base_actionable_wallet_card is deliberately left untouched ''
          || ''by nestly_v729 pending that owner ruling.''';
  v_count     integer;
  v_after     text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('app.ci_metric_dictionary_v1()')) into v_def;
  if v_def is null then raise exception 'v729: app.ci_metric_dictionary_v1 not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 1 then
    raise exception 'v729: ci_metric_dictionary_v1 visit-notes anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  execute replace(v_def, v_anchor, v_new);

  select pg_get_functiondef(to_regprocedure('app.ci_metric_dictionary_v1()')) into v_after;
  v_roundtrip := replace(v_after, v_new, v_anchor);
  if v_roundtrip <> v_def then
    raise exception
      'v729: ci_metric_dictionary_v1 changed by more than the visit-notes replacement. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('RETENTION-VISIT-UNIT-001' in v_after) = 0 then
    raise exception 'v729: ci_metric_dictionary_v1 visit notes did not gain the RETENTION-VISIT-UNIT-001 reference';
  end if;
  if position('an owed client-side fix, not a database one' in v_after) > 0 then
    raise exception 'v729: ci_metric_dictionary_v1 visit notes still claim the drill-down dialog is an owed client-side fix';
  end if;
end
$v729_dictionary$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function app.ci_metric_dictionary_v1() from public, anon, authenticated;
grant execute on function app.ci_metric_dictionary_v1() to service_role;

commit;
