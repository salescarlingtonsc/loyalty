-- NESTLY v709 — check 4 refutation: a same-day split bill was inflating cadence "visits" and the
-- tiers ladder alike.
--
-- Contract: docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md (v672, frozen). Fixture guide:
-- docs/qa/CI-CORPUS-FIXTURE-GUIDE.md. Proven by
-- db/tests/executed/v709_corpus_visit_days_cadence_tiers.sql.
--
-- ============================================================================================
-- WHAT WAS WRONG (check 4). A client with 3 sales on the SAME calendar day (a split bill —
-- several tickets, one afternoon) read as 3 paid visits, not 1, in two places that were never
-- touched by nestly_v699's visit-day authority sweep:
--
--   1. app.customer_cadence_batch_v1 (nestly_v651, dispersion columns added by nestly_v690) —
--      its `sequenced` CTE lags over every qualifying SALE ROW, so three same-day tickets
--      produce two near-zero (same-instant) "intervals" instead of zero. Concretely: 3 same-day
--      sales + 1 next-day + 1 a week later reported paid_visits=5, interval_observations=4, and
--      a median corrupted toward zero by the two same-day gaps — which app.return_probability_v681
--      (nestly_v681) consumes as this customer's rhythm, and app.customer_cadence_v1 (nestly_v651/
--      v669/v690, NOT touched by this migration — nestly_v706 is re-emitting it separately)
--      exposes as median_interval_days and the deviation-state window.
--
--   2. app.tier_resolve_v426 (nestly_v426) — the `tier_basis = 'visits'` branch reads
--      `count(*) from sales where ... counts_as_visit`, one row per SALE. The same split-bill
--      customer climbs the visits ladder three rungs on one afternoon, exactly the class of bug
--      nestly_v699 fixed everywhere else visits are counted (category_customers, staff
--      performance, discount dependency, v179 business insights) — tier_resolve_v426 was never
--      touched by that sweep because it predates it (2026-08-22, three weeks before v699) and
--      nobody re-checked it once the authority existed.
--
-- Product note for the owner: tier qualification by visits now counts DAYS, not raw sale rows —
-- a customer who splits one visit across several tickets no longer climbs the ladder faster than
-- a customer who pays once. This is the same rule nestly_v699 already applies to every other
-- "visits" figure in Customer Intelligence, now closing the two surfaces check 4 found still
-- counting raw rows.
--
-- ============================================================================================
-- WHAT THIS DOES.
--
-- (a) app.customer_cadence_batch_v1 — extract-and-diff against the LIVE body (return type is
--     UNCHANGED, so this is a plain CREATE OR REPLACE, no drop). A new `visit_days` CTE sits
--     between `eligible` and `sequenced`: qualifying (residual_minor > 0) sales are grouped by
--     (client_id, app.ci_visit_day_v699(occurred_at)) — the one visit-day authority, nestly_v699
--     — and each visit-day is anchored at that day's FIRST qualifying sale's occurred_at (a
--     deliberate choice, stated here per the checklist: not the day boundary, and not the day's
--     LAST sale). `sequenced` then lags over visit-days instead of sale rows, so
--     interval_observations / median_interval_days / the p25/p75/iqr columns nestly_v690 added
--     are all computed on inter-visit-DAY gaps. paid_visits, which was `count(*)` over sale rows,
--     is now `count(*)` over visit-days — i.e. distinct visit-day count, same aggregate
--     expression, different (now correct) input cardinality. The visit-day collapse runs over
--     the FULL residual history, unrestricted by p_before, so previous_purchase_at always reflects
--     the true prior visit day regardless of the horizon being queried; the p_before cut moves
--     from a per-row `(occurred_at at time zone timezone)::date < p_before` to `visit_day <
--     p_before` — equivalent when the business's own reporting timezone is Asia/Singapore (true
--     for every production tenant today), which is what filtering on the fixed-SG visit_day
--     column now assumes instead of the per-outlet timezone this function otherwise reads.
--     last_visit_at is UNCHANGED semantics: it is still max(occurred_at) over the (now
--     day-collapsed) rows, so for a client whose sales are already on distinct days the output is
--     byte-identical to before this migration — the anchor-at-first-sale choice only bites a
--     collision on the CUSTOMER'S LAST visit day, where last_visit_at now reports that day's
--     first sale rather than its last; documented here as the direct, accepted consequence of the
--     anchor choice, not an oversight. Not touched: app.customer_cadence_v1 (nestly_v706 is
--     re-emitting it independently in this same build wave); every caller of the batch function
--     (get_customer_lifecycle_v107, get_ci_opportunities_v1, get_ci_service_intelligence_v1, the
--     v678/v688 consultant-spine functions, app.return_probability_v681) selects its five/eight
--     output columns by name and needs no change — they simply now receive correct numbers.
--
-- (b) app.tier_resolve_v426 — single-line extract-and-diff, unredefined since it shipped
--     2026-08-22 (confirmed: grep across every later migration file finds only calls, never a
--     redefinition). The `tier_basis = 'visits'` branch's `count(*)` becomes
--     `count(distinct app.ci_visit_day_v699(occurred_at))` — the same authority (a), and every
--     other visits-shaped CI reader nestly_v699 already fixed, now use. The five thin delegates
--     over this resolver (app.loyalty_tier_for, app.v365_client_tier, app.customer_tier_json_v393,
--     app.v176_tier_gate_metric, public.customer_get_effective_tier_v143) are untouched — they
--     all read app.tier_resolve_v426's payload key-for-key, so the fix cascades to every one of
--     them without a separate edit.
--
-- (c) app.ci_visit_registry_v699 — extract-and-diff, two new reader entries: this migration's
--     two fixed functions, both `uses_authority: true`. The fixture proves the registry against
--     reality (not merely against its own text) exactly as nestly_v699's own fixture did: it calls
--     app.customer_cadence_batch_v1 and app.tier_resolve_v426 against a same-day split-bill
--     fixture and asserts the day-collapsed counts, rather than trusting this registry's claim.
--
-- ============================================================================================
-- REGRESSION SURFACE CHECKED (not edited): every corpus fixture that seeds sales for
-- app.customer_cadence_batch_v1 or reads app.tier_resolve_v426 / app.loyalty_tier_for seeds each
-- client's sales on DISTINCT calendar days (offsets in whole days-ago, one sale per day per
-- client) — v651_corpus_cadence, v678_corpus_consultant_spine, v681_corpus_calibration,
-- v684_corpus_dictionary, v688_corpus_spine_v2, v690_corpus_dispersion_floor, v692_corpus_lineage,
-- v695_corpus_service_cadence, and v426_tier_resolver's own fixture B (2/1/5 sales per client,
-- one calendar day apart each). None seeds two sales for the same client on the same calendar
-- day, so the visit-day collapse this migration adds is a no-op for every one of them and their
-- existing truth tables hold exactly as written.
-- ============================================================================================
begin;

-- ---------------------------------------------------------------------------------------------
-- 1 · app.customer_cadence_batch_v1 — insert the visit-day collapse ahead of sequencing, and
--     move the p_before cut onto the visit-day column. Two anchors, each checked to occur
--     exactly once against the LIVE body (post-nestly_v690) before being patched, and the
--     combined patch is reversed against the AFTER text to prove nothing else moved.
-- ---------------------------------------------------------------------------------------------
do $patch_batch$
declare
  v_def  text;

  v_anchor_seq constant text :=
E'  ), sequenced as (
    select e.*,
           lag(e.occurred_at) over (
             partition by e.client_id order by e.occurred_at, e.id
           ) as previous_purchase_at
      from eligible e
     where e.residual_minor > 0
  )
  select client_id,';
  v_new_seq constant text :=
E'  ), visit_days as (
    /* nestly_v709 (check 4 fix): collapse same-day sales (a split bill: several tickets, one
       customer, one afternoon) into ONE visit before intervals are computed. A visit-day is
       app.ci_visit_day_v699(occurred_at) (the one visit-day authority; nestly_v699), anchored at
       the day''s FIRST qualifying (residual_minor > 0) sale occurred_at, not the day boundary,
       and not the day''s last sale. Computed over the FULL residual history, unrestricted by
       p_before, so previous_purchase_at below reflects the true prior visit day regardless of
       the horizon; the p_before cut moves to visit_day in the final select. */
    select client_id,
           app.ci_visit_day_v699(occurred_at) as visit_day,
           min(occurred_at) as occurred_at
      from eligible
     where residual_minor > 0
     group by client_id, app.ci_visit_day_v699(occurred_at)
  ), sequenced as (
    select v.*,
           lag(v.occurred_at) over (
             partition by v.client_id order by v.occurred_at
           ) as previous_purchase_at
      from visit_days v
  )
  select client_id,';

  v_anchor_where constant text :=
E'   where client_id is not null
     and (occurred_at at time zone timezone)::date < p_before
   group by client_id;';
  v_new_where constant text :=
E'   where client_id is not null
     and visit_day < p_before
   group by client_id;';

  v_count_seq   integer;
  v_count_where integer;
  v_expected    text;
  v_after       text;
  v_roundtrip   text;
begin
  select pg_get_functiondef(to_regprocedure(
    'app.customer_cadence_batch_v1(uuid,date,date,timestamptz,uuid,boolean)')) into v_def;
  if v_def is null then raise exception 'v709: app.customer_cadence_batch_v1 not found'; end if;

  v_count_seq := (length(v_def) - length(replace(v_def, v_anchor_seq, ''))) / length(v_anchor_seq);
  if v_count_seq <> 1 then
    raise exception 'v709: customer_cadence_batch_v1 sequenced anchor occurs % times (expected 1) — live body drifted', v_count_seq;
  end if;
  v_count_where := (length(v_def) - length(replace(v_def, v_anchor_where, ''))) / length(v_anchor_where);
  if v_count_where <> 1 then
    raise exception 'v709: customer_cadence_batch_v1 where anchor occurs % times (expected 1) — live body drifted', v_count_where;
  end if;

  v_expected := replace(v_def, v_anchor_seq, v_new_seq);
  v_expected := replace(v_expected, v_anchor_where, v_new_where);

  -- Return type is unchanged (same OUT columns, same order) — CREATE OR REPLACE is sufficient,
  -- no drop needed.
  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'app.customer_cadence_batch_v1(uuid,date,date,timestamptz,uuid,boolean)')) into v_after;

  v_roundtrip := replace(replace(v_after, v_new_seq, v_anchor_seq), v_new_where, v_anchor_where);
  if v_roundtrip <> v_def then
    raise exception
      'v709: customer_cadence_batch_v1 changed by more than the visit-day collapse. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_batch$;
-- ACL restated verbatim from the live proacl (unchanged by this migration — same argument list).
revoke all on function app.customer_cadence_batch_v1(uuid,date,date,timestamptz,uuid,boolean)
  from public, anon, authenticated;
grant execute on function app.customer_cadence_batch_v1(uuid,date,date,timestamptz,uuid,boolean)
  to service_role;

-- ---------------------------------------------------------------------------------------------
-- 2 · app.tier_resolve_v426 — the visits-basis metric moves from a raw sale count to a distinct
--     visit-day count, the same authority (a) above now uses. Single anchor, unredefined since
--     the function shipped (2026-08-22).
-- ---------------------------------------------------------------------------------------------
do $patch_tier$
declare
  v_def text;
  v_anchor constant text :=
E'    select count(*) into v_metric
      from public.sales
     where business_id = p_business and client_id = p_client and counts_as_visit;';
  v_new constant text :=
E'    select count(distinct app.ci_visit_day_v699(occurred_at)) into v_metric
      from public.sales
     where business_id = p_business and client_id = p_client and counts_as_visit;';
  v_count     integer;
  v_after     text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'app.tier_resolve_v426(uuid,uuid,timestamptz)')) into v_def;
  if v_def is null then raise exception 'v709: app.tier_resolve_v426 not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 1 then
    raise exception 'v709: tier_resolve_v426 visits-metric anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  execute replace(v_def, v_anchor, v_new);

  select pg_get_functiondef(to_regprocedure(
    'app.tier_resolve_v426(uuid,uuid,timestamptz)')) into v_after;
  v_roundtrip := replace(v_after, v_new, v_anchor);
  if v_roundtrip <> v_def then
    raise exception
      'v709: tier_resolve_v426 changed by more than the visits-metric authority swap. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_tier$;
-- ACL restated verbatim from the live proacl (unchanged — internal helper, reachable only
-- through its five SECURITY DEFINER delegates, never granted directly to any client role).
revoke all on function app.tier_resolve_v426(uuid, uuid, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 3 · app.ci_visit_registry_v699 — register both fixed readers. Extract-and-diff against the
--     live body; the anchor is the registry's own last entry (get_ci_retention_windows_v1),
--     unredefined since nestly_v699 shipped it.
-- ---------------------------------------------------------------------------------------------
do $patch_registry$
declare
  v_def text;
  v_anchor constant text :=
E'      ''get_ci_retention_windows_v1'', jsonb_build_object(
        ''uses_authority'', false,
        ''note'', ''min(visit_date) per stage, inherently deduped (nestly_v673)'')
    )
  );';
  v_new constant text :=
E'      ''get_ci_retention_windows_v1'', jsonb_build_object(
        ''uses_authority'', false,
        ''note'', ''min(visit_date) per stage, inherently deduped (nestly_v673)''),
      ''app.customer_cadence_batch_v1'', jsonb_build_object(
        ''uses_authority'', true,
        ''note'', ''paid_visits / interval_observations / median_interval_days (and the p25/p75/iqr dispersion columns) are computed over distinct visit-days, not raw sale rows; a split bill collapses to one visit before intervals are sequenced (nestly_v709, check 4)''),
      ''app.tier_resolve_v426'', jsonb_build_object(
        ''uses_authority'', true,
        ''note'', ''the tier_basis=visits metric counts distinct visit-days, the same authority every other visits-shaped CI reader in this registry uses (nestly_v709, check 4)'')
    )
  );';
  v_count     integer;
  v_after     text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('app.ci_visit_registry_v699()')) into v_def;
  if v_def is null then raise exception 'v709: app.ci_visit_registry_v699 not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 1 then
    raise exception 'v709: ci_visit_registry_v699 retention-windows anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  execute replace(v_def, v_anchor, v_new);

  select pg_get_functiondef(to_regprocedure('app.ci_visit_registry_v699()')) into v_after;
  v_roundtrip := replace(v_after, v_new, v_anchor);
  if v_roundtrip <> v_def then
    raise exception
      'v709: ci_visit_registry_v699 changed by more than the two new registry entries. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('app.customer_cadence_batch_v1' in v_after) = 0
     or position('app.tier_resolve_v426' in v_after) = 0 then
    raise exception 'v709: ci_visit_registry_v699 did not gain both new entries';
  end if;
end
$patch_registry$;
-- ACL restated verbatim from the live proacl (unchanged by this migration — same argument list).
revoke all on function app.ci_visit_registry_v699() from public, anon;
grant execute on function app.ci_visit_registry_v699() to service_role;

commit;
