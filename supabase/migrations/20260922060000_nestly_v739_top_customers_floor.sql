-- NESTLY v739 -- CI-100-CHECKLIST check 96 (Privacy and small-cell protection): closes the gap
-- v736's finding F2 recorded but did not fail on. app.v179_business_insights.insights.top_customers
-- always rendered up to 5 named rows ("First L." + revenue rank, via app.v177_person_label) even
-- when the identified population was as small as 2 customers -- only the aggregate share fields
-- (top1/top5 _share_of_total/identified_revenue_pct) nulled out below the floor. In a 2-customer
-- window that is a first-name-plus-revenue-rank disclosure the owner-facing category-customers
-- floor (public.get_ci_category_customers_v1, nestly_v667/v690) would refuse to make about the
-- same two people. Fix: when the same app.subgroup_evidence_v1 check used for the share fields
-- reports 'insufficient', top_customers.rows becomes [] and a `suppressed` object is emitted,
-- mirroring get_ci_category_customers_v1's own shape exactly (reason/floor/cohort_size). The
-- `evidence` block and every count (customers_served etc, in sibling sections) are untouched --
-- only the row-level identity disclosure is gated, same as every other reader in the v690/v699
-- estate already gates its rate-like fields.
--
-- Re-emits ONLY app.v179_business_insights. Anchored extract-and-diff replace-equality against
-- the LIVE body (pg_get_functiondef captured at apply time), same discipline as nestly_v668/v690/
-- v699/v706/v715 -- never a hand-retyped guess at the base text. Live body going in is nestly_v715's
-- re-emit (committed): weekday_pattern.visits deduped by visit-day; top_customers itself untouched
-- since nestly_v551 (share-field renames) and nestly_v690 (the floor gating those share fields --
-- the SAME app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)
-- expression this migration reuses verbatim for rows/suppressed, so all three -- shares, rows,
-- suppressed -- agree on what "insufficient" means for this population by construction).
--
-- TWO edits, both inside the `top_customers` object:
--   1. `rows`: was an unconditional `coalesce((select jsonb_agg(...) ...), '[]'::jsonb)`. Now a
--      `case` on the same evidence expression already used by the four share fields: insufficient
--      -> '[]'::jsonb; ok -> the original coalesce expression, byte-identical, just re-indented one
--      level deeper inside the `else` branch.
--   2. `suppressed`: new field, inserted between `evidence` and `evidence_class` (both untouched).
--      null when evidence is ok; when insufficient, an object shaped exactly like
--      get_ci_category_customers_v1's own `suppressed` block --
--      {reason:'below_small_cell_floor', floor:<n>, cohort_size:<n>} -- reusing that same
--      subgroup_evidence_v1 call's own 'floor'/'n' fields rather than a second hardcoded 5, so a
--      future floor-policy change (there is none today -- subgroup_evidence_v1's default is a
--      literal 5) cannot desync the two disclosures. get_ci_category_customers_v1 additionally
--      carries a `note`; omitted here since v179's caller (the AI evidence pack, app.v176_evidence_pack)
--      already gets its own reason string and does not need a second free-text copy.
--
-- Every OTHER field in insights.top_customers (scope, the four *_share_of_*_revenue_pct fields,
-- evidence, evidence_class) is untouched -- confirmed by the round-trip check below, which proves
-- the live body changed by exactly these two edits and nothing else.
--
-- Fixture: db/tests/executed/v739_corpus_top_customers_floor.sql. biz_below: exactly 2 identified
-- customers with revenue in the window (< floor 5) -> top_customers.rows = [], suppressed =
-- {reason:'below_small_cell_floor', floor:5, cohort_size:2}, evidence.status='insufficient', the
-- four share fields remain null (nestly_v690's existing behaviour, unchanged). biz_ok: 6 identified
-- customers with revenue (>= floor 5) -> rows carries 5 named rows (top 5 of 6, unchanged
-- shape/order), suppressed IS NULL, evidence.status='ok', share fields present. A mutation that
-- reverts the row-suppression (or that breaks the anonymous/no-revenue exclusion the original
-- `where wc.revenue_cents > 0` predicate already enforced) turns the fixture red.
--
-- db/tests/executed/v736_corpus_small_cell_principals.sql T7/F2 (the finding this migration
-- closes) is UPDATED by this same migration's authoring session (explicitly authorised -- see
-- this repo's v736 finding text and the task that produced this migration): the biz_c (2-client)
-- assertions that pinned "rows render, never suppressed to []" now assert the opposite (rows=[],
-- suppressed present), and the F2 finding-header prose is corrected to describe the fix instead of
-- the historical gap. The header now reads DIRECT_FACT for T7-bizA (no change: 9-client window
-- stays >= floor, rows unchanged) and the new below-floor shape for T7-bizC. No other
-- v179-touching fixture (v179, v545, v548, v551, v556, v690, v695, v699, v706, v715) asserts a
-- top_customers.rows value below the floor, so none of them changes.

begin;

do $patch_v739$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('app.v179_business_insights(uuid,date,date,date,date)')) into v_def;
  if v_def is null then
    raise exception 'v739: app.v179_business_insights(uuid,date,date,date,date) not found';
  end if;

  -- anchor 1: the unconditional top_customers.rows coalesce expression.
  v_count := (length(v_def) - length(replace(v_def, $zzv739tag1zzz$      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
          'label', app.v177_person_label(client.full_name, wc.client_id),
          'revenue_cents', wc.revenue_cents,
          'visits', wc.visits,
          'is_new_this_period', wc.is_new
        ) order by wc.revenue_cents desc, wc.client_id)
        from (select * from window_clients order by revenue_cents desc limit 5) wc
        join public.clients client on client.id = wc.client_id
        where wc.revenue_cents > 0
      ), '[]'::jsonb),
$zzv739tag1zzz$, ''))) / greatest(length($zzv739tag2zzz$      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
          'label', app.v177_person_label(client.full_name, wc.client_id),
          'revenue_cents', wc.revenue_cents,
          'visits', wc.visits,
          'is_new_this_period', wc.is_new
        ) order by wc.revenue_cents desc, wc.client_id)
        from (select * from window_clients order by revenue_cents desc limit 5) wc
        join public.clients client on client.id = wc.client_id
        where wc.revenue_cents > 0
      ), '[]'::jsonb),
$zzv739tag2zzz$), 1);
  if v_count <> 1 then
    raise exception 'v739: v179.top_customers_rows anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  -- anchor 2: the evidence / evidence_class pair (no suppressed field yet).
  v_count := (length(v_def) - length(replace(v_def, $zzv739tag3zzz$      'evidence', app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int),
      'evidence_class', 'DIRECT_FACT'
$zzv739tag3zzz$, ''))) / greatest(length($zzv739tag4zzz$      'evidence', app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int),
      'evidence_class', 'DIRECT_FACT'
$zzv739tag4zzz$), 1);
  if v_count <> 1 then
    raise exception 'v739: v179.top_customers_evidence_class anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := v_def;
  v_expected := replace(v_expected, $zzv739tag5zzz$      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
          'label', app.v177_person_label(client.full_name, wc.client_id),
          'revenue_cents', wc.revenue_cents,
          'visits', wc.visits,
          'is_new_this_period', wc.is_new
        ) order by wc.revenue_cents desc, wc.client_id)
        from (select * from window_clients order by revenue_cents desc limit 5) wc
        join public.clients client on client.id = wc.client_id
        where wc.revenue_cents > 0
      ), '[]'::jsonb),
$zzv739tag5zzz$, $zzv739tag6zzz$      'rows',
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
$zzv739tag6zzz$);
  v_expected := replace(v_expected, $zzv739tag7zzz$      'evidence', app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int),
      'evidence_class', 'DIRECT_FACT'
$zzv739tag7zzz$, $zzv739tag8zzz$      'evidence', app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int),
      'suppressed',
        case when (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>'status') = 'insufficient'
          then jsonb_build_object(
            'reason', 'below_small_cell_floor',
            'floor', (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>'floor')::int,
            'cohort_size', (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>'n')::int)
          else null end,
      'evidence_class', 'DIRECT_FACT'
$zzv739tag8zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('app.v179_business_insights(uuid,date,date,date,date)')) into v_after;

  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $zzv739tag9zzz$      'rows',
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
$zzv739tag9zzz$, $zzv739tag10zzz$      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
          'label', app.v177_person_label(client.full_name, wc.client_id),
          'revenue_cents', wc.revenue_cents,
          'visits', wc.visits,
          'is_new_this_period', wc.is_new
        ) order by wc.revenue_cents desc, wc.client_id)
        from (select * from window_clients order by revenue_cents desc limit 5) wc
        join public.clients client on client.id = wc.client_id
        where wc.revenue_cents > 0
      ), '[]'::jsonb),
$zzv739tag10zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv739tag11zzz$      'evidence', app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int),
      'suppressed',
        case when (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>'status') = 'insufficient'
          then jsonb_build_object(
            'reason', 'below_small_cell_floor',
            'floor', (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>'floor')::int,
            'cohort_size', (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>'n')::int)
          else null end,
      'evidence_class', 'DIRECT_FACT'
$zzv739tag11zzz$, $zzv739tag12zzz$      'evidence', app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int),
      'evidence_class', 'DIRECT_FACT'
$zzv739tag12zzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v739: app.v179_business_insights changed by more than the 2 intended edit(s) [top_customers_rows, top_customers_suppressed]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_v739$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- no direct grants;
-- this SECURITY DEFINER function is reached only via other server-side callers).
revoke all privileges on function
  app.v179_business_insights(uuid, date, date, date, date)
  from public, anon, authenticated, service_role;

commit;
