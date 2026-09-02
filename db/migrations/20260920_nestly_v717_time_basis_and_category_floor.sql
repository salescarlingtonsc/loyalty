-- NESTLY v717 -- time basis everywhere (check 35/13) + category-mix floor gate (check 61).
--
-- Part A (additive, 5 of the 7 readers): public.get_ci_acquisition_v1, get_ci_category_mix_v1,
-- get_ci_contactability_v1, get_ci_engagement_v1 and get_ci_funnel_v1 did not carry a
-- `time_basis` key naming the timestamp column their bucketing actually reads (the frozen
-- contract, docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md convention 2: "every time-derived
-- payload carries time_basis naming the timestamp used"). Read each body to name the real
-- column instead of guessing:
--   * get_ci_acquisition_v1     buckets 'new_in_period' on clients.created_at            -> 'client_created_at'
--   * get_ci_category_mix_v1    buckets its whole window on sales.occurred_at            -> 'sale_occurred_at'
--   * get_ci_contactability_v1  has no historical timestamp column at all -- it evaluates
--                                current consent state at p_as_of, already an envelope key -> 'as_of'
--   * get_ci_engagement_v1      buckets 'current_month' on product_adoption_events_v100.occurred_at
--                                (history comes pre-aggregated from engagement_monthly_rollup_v1.month,
--                                itself built from the same occurred_at column)            -> 'engagement_event_occurred_at'
--   * get_ci_funnel_v1          buckets on public_funnel_counters.day                     -> 'funnel_counter_day'
-- get_ci_daypart_v1 (v698) already emits a top-level 'time_basis':'sale_occurred_at' that
-- reaches callers untouched -- not re-emitted here, only proven (regression floor) in
-- db/tests/executed/v717_corpus_time_basis.sql.
--
-- get_ci_demographic_cohort_v1 (v706) is NOT already compliant, despite v706 appearing to add
-- exactly this: v706 nested 'time_basis' INSIDE the reader's own 'period' object, but
-- app.ci_envelope_v680 unconditionally overwrites the whole top-level 'period' key with its own
-- version (no time_basis) via jsonb `||`, where the right-hand operand wins on key collision --
-- so the nested copy never reaches a caller (proven empirically below, not just read off the
-- source). Fixed here with a second, additive patch to the SAME function: a top-level
-- 'time_basis' key, the one place in this migration where a "re-emit ONLY" function needed two
-- edits for two different reasons.
--
-- Part B (get_ci_category_mix_v1 only, check 61): a category's 'distribution' block
-- (app.distribution_block_v1, v672) and its derived 'skew_note' can describe a 2- or 3-customer
-- category as confidently as a 200-customer one -- the same "3-of-3 trap" (check 62) the frozen
-- statistical-authority contract exists to close everywhere else. Both are now null, and a new
-- per-category 'evidence' block (app.subgroup_evidence_v1 on the category's own customer_count,
-- default floor 5) is added, when that category's customer_count is below the floor. Revenue,
-- line_count, customer_count and projected_share_bps -- none of them rate-like or distribution-
-- shaped -- are unaffected: counts stay.
--
-- Re-emits ONLY: public.get_ci_acquisition_v1, public.get_ci_category_mix_v1,
-- public.get_ci_contactability_v1, public.get_ci_engagement_v1, public.get_ci_funnel_v1. Does NOT
-- touch get_ci_daypart_v1, get_ci_demographic_cohort_v1, get_ci_discovery_v1 (v708's tie-strata
-- work), app.v179_business_insights or app.customer_cadence_v1 (v714/v715's visit-days estate) --
-- all out of scope for this migration and owned by sibling sessions.
--
-- Every patch below is an anchored extract-and-diff replace-equality edit of the LIVE body
-- (pg_get_functiondef captured at apply time), verified to round-trip back to the exact live
-- original once the intended edit is reversed -- same discipline as v668/v690/v698/v706, never a
-- hand-retyped guess at the base text.
--
-- Proven by db/tests/executed/v717_corpus_time_basis.sql.

begin;

-- -------------------------------------------------------------------------------------------
-- get_ci_acquisition_v1
-- -------------------------------------------------------------------------------------------
do $patch_acquisition$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_acquisition_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v717: public.get_ci_acquisition_v1(uuid,date,date,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv717tag1zzz$  v_result := jsonb_build_object('sources', v_rows,
    'observed_since', app.metric_observed_since_v1('first_acquisition', p_business));$zzv717tag1zzz$, ''))) / greatest(length($zzv717tag2zzz$  v_result := jsonb_build_object('sources', v_rows,
    'observed_since', app.metric_observed_since_v1('first_acquisition', p_business));$zzv717tag2zzz$), 1);
  if v_count <> 1 then
    raise exception 'v717: acquisition.result anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $zzv717tag3zzz$  v_result := jsonb_build_object('sources', v_rows,
    'observed_since', app.metric_observed_since_v1('first_acquisition', p_business));$zzv717tag3zzz$, $zzv717tag4zzz$  v_result := jsonb_build_object('sources', v_rows,
    'time_basis', 'client_created_at',
    'observed_since', app.metric_observed_since_v1('first_acquisition', p_business));$zzv717tag4zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_acquisition_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, $zzv717tag5zzz$  v_result := jsonb_build_object('sources', v_rows,
    'time_basis', 'client_created_at',
    'observed_since', app.metric_observed_since_v1('first_acquisition', p_business));$zzv717tag5zzz$, $zzv717tag6zzz$  v_result := jsonb_build_object('sources', v_rows,
    'observed_since', app.metric_observed_since_v1('first_acquisition', p_business));$zzv717tag6zzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v717: get_ci_acquisition_v1 changed by more than the 1 intended edit [result]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_acquisition$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_acquisition_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_acquisition_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- get_ci_category_mix_v1
-- -------------------------------------------------------------------------------------------
do $patch_category_mix$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_category_mix_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v717: public.get_ci_category_mix_v1(uuid,date,date,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv717tag7zzz$    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'categories', coalesce(($zzv717tag7zzz$, ''))) / greatest(length($zzv717tag8zzz$    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'categories', coalesce(($zzv717tag8zzz$), 1);
  if v_count <> 1 then
    raise exception 'v717: category_mix.scope anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv717tag9zzz$        'distribution', ld.dist,
        'skew_note', case when coalesce((ld.dist->>'skew_material')::boolean, false)
          then format('top customer carries %s%% of this category; the mean overstates the typical customer',
                       round((ld.dist->>'top1_share_bps')::numeric / 100, 1))
          else null end)$zzv717tag9zzz$, ''))) / greatest(length($zzv717tag10zzz$        'distribution', ld.dist,
        'skew_note', case when coalesce((ld.dist->>'skew_material')::boolean, false)
          then format('top customer carries %s%% of this category; the mean overstates the typical customer',
                       round((ld.dist->>'top1_share_bps')::numeric / 100, 1))
          else null end)$zzv717tag10zzz$), 1);
  if v_count <> 1 then
    raise exception 'v717: category_mix.distribution anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := v_def;
  v_expected := replace(v_expected, $zzv717tag11zzz$    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'categories', coalesce(($zzv717tag11zzz$, $zzv717tag12zzz$    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'categories', coalesce(($zzv717tag12zzz$);
  v_expected := replace(v_expected, $zzv717tag13zzz$        'distribution', ld.dist,
        'skew_note', case when coalesce((ld.dist->>'skew_material')::boolean, false)
          then format('top customer carries %s%% of this category; the mean overstates the typical customer',
                       round((ld.dist->>'top1_share_bps')::numeric / 100, 1))
          else null end)$zzv717tag13zzz$, $zzv717tag14zzz$        'distribution', case when (app.subgroup_evidence_v1(l2.customer_count::int)->>'status') = 'insufficient'
          then null else ld.dist end,
        'skew_note', case when (app.subgroup_evidence_v1(l2.customer_count::int)->>'status') = 'insufficient'
          then null
          else case when coalesce((ld.dist->>'skew_material')::boolean, false)
            then format('top customer carries %s%% of this category; the mean overstates the typical customer',
                         round((ld.dist->>'top1_share_bps')::numeric / 100, 1))
            else null end end,
        'evidence', app.subgroup_evidence_v1(l2.customer_count::int))$zzv717tag14zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_category_mix_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $zzv717tag15zzz$        'distribution', case when (app.subgroup_evidence_v1(l2.customer_count::int)->>'status') = 'insufficient'
          then null else ld.dist end,
        'skew_note', case when (app.subgroup_evidence_v1(l2.customer_count::int)->>'status') = 'insufficient'
          then null
          else case when coalesce((ld.dist->>'skew_material')::boolean, false)
            then format('top customer carries %s%% of this category; the mean overstates the typical customer',
                         round((ld.dist->>'top1_share_bps')::numeric / 100, 1))
            else null end end,
        'evidence', app.subgroup_evidence_v1(l2.customer_count::int))$zzv717tag15zzz$, $zzv717tag16zzz$        'distribution', ld.dist,
        'skew_note', case when coalesce((ld.dist->>'skew_material')::boolean, false)
          then format('top customer carries %s%% of this category; the mean overstates the typical customer',
                       round((ld.dist->>'top1_share_bps')::numeric / 100, 1))
          else null end)$zzv717tag16zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv717tag17zzz$    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'categories', coalesce(($zzv717tag17zzz$, $zzv717tag18zzz$    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'categories', coalesce(($zzv717tag18zzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v717: get_ci_category_mix_v1 changed by more than the 2 intended edits [scope, distribution]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_category_mix$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_category_mix_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_category_mix_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- get_ci_contactability_v1
-- -------------------------------------------------------------------------------------------
do $patch_contactability$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_contactability_v1(uuid,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v717: public.get_ci_contactability_v1(uuid,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv717tag19zzz$  v_result := jsonb_build_object(
    'business_offers', app.contactable_counts_v1(p_business, 'business_offers'),
    'rewards_and_points', app.contactable_counts_v1(p_business, 'rewards_and_points'),
    'note', 'A customer counts only with an affirmative recorded consent for the channel; nobody is grandfathered.');$zzv717tag19zzz$, ''))) / greatest(length($zzv717tag20zzz$  v_result := jsonb_build_object(
    'business_offers', app.contactable_counts_v1(p_business, 'business_offers'),
    'rewards_and_points', app.contactable_counts_v1(p_business, 'rewards_and_points'),
    'note', 'A customer counts only with an affirmative recorded consent for the channel; nobody is grandfathered.');$zzv717tag20zzz$), 1);
  if v_count <> 1 then
    raise exception 'v717: contactability.result anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $zzv717tag21zzz$  v_result := jsonb_build_object(
    'business_offers', app.contactable_counts_v1(p_business, 'business_offers'),
    'rewards_and_points', app.contactable_counts_v1(p_business, 'rewards_and_points'),
    'note', 'A customer counts only with an affirmative recorded consent for the channel; nobody is grandfathered.');$zzv717tag21zzz$, $zzv717tag22zzz$  v_result := jsonb_build_object(
    'business_offers', app.contactable_counts_v1(p_business, 'business_offers'),
    'rewards_and_points', app.contactable_counts_v1(p_business, 'rewards_and_points'),
    'time_basis', 'as_of',
    'note', 'A customer counts only with an affirmative recorded consent for the channel; nobody is grandfathered.');$zzv717tag22zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_contactability_v1(uuid,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, $zzv717tag23zzz$  v_result := jsonb_build_object(
    'business_offers', app.contactable_counts_v1(p_business, 'business_offers'),
    'rewards_and_points', app.contactable_counts_v1(p_business, 'rewards_and_points'),
    'time_basis', 'as_of',
    'note', 'A customer counts only with an affirmative recorded consent for the channel; nobody is grandfathered.');$zzv717tag23zzz$, $zzv717tag24zzz$  v_result := jsonb_build_object(
    'business_offers', app.contactable_counts_v1(p_business, 'business_offers'),
    'rewards_and_points', app.contactable_counts_v1(p_business, 'rewards_and_points'),
    'note', 'A customer counts only with an affirmative recorded consent for the channel; nobody is grandfathered.');$zzv717tag24zzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v717: get_ci_contactability_v1 changed by more than the 1 intended edit [result]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_contactability$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_contactability_v1(uuid,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_contactability_v1(uuid,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- get_ci_engagement_v1
-- -------------------------------------------------------------------------------------------
do $patch_engagement$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_engagement_v1(uuid,integer,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v717: public.get_ci_engagement_v1(uuid,integer,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv717tag25zzz$  v_result := jsonb_build_object('months', v_hist, 'current_month', v_current,
    'observed_since', app.metric_observed_since_v1('engagement_rollups', p_business));$zzv717tag25zzz$, ''))) / greatest(length($zzv717tag26zzz$  v_result := jsonb_build_object('months', v_hist, 'current_month', v_current,
    'observed_since', app.metric_observed_since_v1('engagement_rollups', p_business));$zzv717tag26zzz$), 1);
  if v_count <> 1 then
    raise exception 'v717: engagement.result anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $zzv717tag27zzz$  v_result := jsonb_build_object('months', v_hist, 'current_month', v_current,
    'observed_since', app.metric_observed_since_v1('engagement_rollups', p_business));$zzv717tag27zzz$, $zzv717tag28zzz$  v_result := jsonb_build_object('months', v_hist, 'current_month', v_current,
    'time_basis', 'engagement_event_occurred_at',
    'observed_since', app.metric_observed_since_v1('engagement_rollups', p_business));$zzv717tag28zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_engagement_v1(uuid,integer,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, $zzv717tag29zzz$  v_result := jsonb_build_object('months', v_hist, 'current_month', v_current,
    'time_basis', 'engagement_event_occurred_at',
    'observed_since', app.metric_observed_since_v1('engagement_rollups', p_business));$zzv717tag29zzz$, $zzv717tag30zzz$  v_result := jsonb_build_object('months', v_hist, 'current_month', v_current,
    'observed_since', app.metric_observed_since_v1('engagement_rollups', p_business));$zzv717tag30zzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v717: get_ci_engagement_v1 changed by more than the 1 intended edit [result]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_engagement$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_engagement_v1(uuid,integer,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_engagement_v1(uuid,integer,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- get_ci_funnel_v1
-- -------------------------------------------------------------------------------------------
do $patch_funnel$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_funnel_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v717: public.get_ci_funnel_v1(uuid,date,date,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv717tag31zzz$  v_result := jsonb_build_object('funnel', v_rows,
    'observed_since', app.metric_observed_since_v1('public_funnel_counters', p_business));$zzv717tag31zzz$, ''))) / greatest(length($zzv717tag32zzz$  v_result := jsonb_build_object('funnel', v_rows,
    'observed_since', app.metric_observed_since_v1('public_funnel_counters', p_business));$zzv717tag32zzz$), 1);
  if v_count <> 1 then
    raise exception 'v717: funnel.result anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $zzv717tag33zzz$  v_result := jsonb_build_object('funnel', v_rows,
    'observed_since', app.metric_observed_since_v1('public_funnel_counters', p_business));$zzv717tag33zzz$, $zzv717tag34zzz$  v_result := jsonb_build_object('funnel', v_rows,
    'time_basis', 'funnel_counter_day',
    'observed_since', app.metric_observed_since_v1('public_funnel_counters', p_business));$zzv717tag34zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_funnel_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, $zzv717tag35zzz$  v_result := jsonb_build_object('funnel', v_rows,
    'time_basis', 'funnel_counter_day',
    'observed_since', app.metric_observed_since_v1('public_funnel_counters', p_business));$zzv717tag35zzz$, $zzv717tag36zzz$  v_result := jsonb_build_object('funnel', v_rows,
    'observed_since', app.metric_observed_since_v1('public_funnel_counters', p_business));$zzv717tag36zzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v717: get_ci_funnel_v1 changed by more than the 1 intended edit [result]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_funnel$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_funnel_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_funnel_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- get_ci_demographic_cohort_v1 -- CORRECTION to this migration's own header claim that this
-- reader was "already compliant" per v706. It is not: v706 nested 'time_basis' INSIDE the
-- reader's own 'period' object, but app.ci_envelope_v680 (v680) unconditionally overwrites the
-- WHOLE top-level 'period' key with its own (from/to/interval/timezone, no time_basis) via
-- `p_payload || jsonb_build_object(..., 'period', ..., ...)` -- jsonb `||` lets the right-hand
-- operand win on key collision, so the reader's nested time_basis was silently discarded on
-- every call and never reached a caller. Proven empirically against the live envelope output,
-- not merely read off the source. bucket_timezone/timezone_basis survive (different, non-
-- colliding top-level keys); only the nested 'period'->>'time_basis' was lost. Fixed the way
-- every other reader in this migration does it: a top-level 'time_basis' key, sibling to
-- bucket_timezone/timezone_basis, which the envelope's `||` cannot touch. The dead nested copy
-- inside 'period' is left alone (harmless, unreachable) rather than risk a second edit to the
-- same jsonb_build_object call.
-- -------------------------------------------------------------------------------------------
do $patch_demographic_cohort_time_basis$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v717: public.get_ci_demographic_cohort_v1(...) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv717tag37zzz$    'bucket_timezone', v_tz,
    'timezone_basis', v_tz_basis,$zzv717tag37zzz$, ''))) / greatest(length($zzv717tag38zzz$    'bucket_timezone', v_tz,
    'timezone_basis', v_tz_basis,$zzv717tag38zzz$), 1);
  if v_count <> 1 then
    raise exception 'v717: demographic_cohort.tzkeys anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $zzv717tag39zzz$    'bucket_timezone', v_tz,
    'timezone_basis', v_tz_basis,$zzv717tag39zzz$, $zzv717tag40zzz$    'time_basis', 'sale_occurred_at',
    'bucket_timezone', v_tz,
    'timezone_basis', v_tz_basis,$zzv717tag40zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, $zzv717tag41zzz$    'time_basis', 'sale_occurred_at',
    'bucket_timezone', v_tz,
    'timezone_basis', v_tz_basis,$zzv717tag41zzz$, $zzv717tag42zzz$    'bucket_timezone', v_tz,
    'timezone_basis', v_tz_basis,$zzv717tag42zzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v717: get_ci_demographic_cohort_v1 changed by more than the 1 intended edit [tzkeys]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_demographic_cohort_time_basis$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid,timestamptz) to authenticated, service_role;

commit;
