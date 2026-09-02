-- NESTLY v706 -- branch clock everywhere (check 8): route the remaining hardcoded
-- 'Asia/Singapore' bucketing sites through app.ci_bucket_tz_v698(p_business, p_branch), the one
-- bucketing-timezone authority v698 introduced (branch tz when p_branch is given, firm-agreed tz
-- when every active branch shares one, else a disclosed 'mixed_branches_default'). Also folds in
-- three floor-gate leaks the refuter found (n=3) inside functions already being re-emitted here:
--   1. get_ci_discovery_v1 seasonality.current_pct gated on h.n > 0 instead of h.n >= v_floor.
--   2. get_ci_funnel_conversion_v1 stage_1_to_2/stage_2_to_3 used the ungated app.rate_block_v1
--      even when the stage's own evidence was insufficient -- now app.rate_block_floor_gated_v683
--      with the STAGE's own evidence (v_mature_first / v_mature_second respectively), exactly as
--      v703 already did for get_ci_retention_windows_v1's per-cohort windows.
--   3. app.v179_business_insights retention.existing_customer_return_rate_pct returned a bare 0.0
--      at tiny n with no evidence block, while its sibling prior_new_return_rate_pct was already
--      gated -- now gated the identical way, with its own evidence field.
--
-- Re-emits ONLY: public.get_ci_funnel_conversion_v1, public.get_ci_retention_windows_v1,
-- public.get_ci_demographic_cohort_v1, app.customer_cadence_v1, app.v179_business_insights, and
-- get_ci_discovery_v1's weekday dimension (the anchor-date computation that feeds isodow, plus
-- the seasonality current_pct gate). Does NOT touch get_ci_service_intelligence_v1 (v707) or
-- get_ci_opportunities_v1 (v705) -- both in flight in sibling sessions -- nor any other function,
-- table or column those own.
--
-- v179 and app.customer_cadence_v1 have no p_branch parameter: both resolve the firm-level
-- timezone via app.ci_bucket_tz_v698(p_business, null) (branch resolution never applies to them).
-- app.ci_visit_day_v699 stays SG-only ON PURPOSE, per its own header and v699's migration --
-- NOT changed here. v179 counts visit-DAYS with app.ci_visit_day_v699 (deliberately SG-anchored)
-- while its weekday_pattern BUCKETS on the resolved branch-clock timezone: a reader that both
-- counts visit-days and buckets by wall-clock keeps the visit-day count on SG (the identity used
-- everywhere else visit-days are counted) and discloses the bucketing zone separately via
-- bucket_timezone/timezone_basis, rather than quietly making one function's visit-day definition
-- diverge from every other reader's.
--
-- THE ENVELOPE STAYS SG, ON PURPOSE (same reasoning as v698): app.ci_envelope_v680's
-- 'period.timezone' is the firm's own SG-anchored reporting calendar and is NOT touched here.
-- 'bucket_timezone'/'timezone_basis' are new reader-level keys disclosing what actually drove
-- THIS reader's date/weekday arithmetic; the two can legitimately differ (a Perth-timezone
-- branch bucketed at its own clock, reported inside an SG-dated period).
--
-- Every patch below is an anchored extract-and-diff replace-equality edit of the LIVE body
-- (pg_get_functiondef captured at apply time), verified to round-trip back to the exact live
-- original once the intended edits are reversed -- same discipline as v668/v690/v695/v698/v703,
-- never a hand-retyped guess at the base text.
--
-- Proven by db/tests/executed/v706_corpus_branch_clock.sql.

begin;
-- -------------------------------------------------------------------------------------------
-- get_ci_funnel_conversion_v1
-- -------------------------------------------------------------------------------------------
do $patch_funnel_conversion$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v706: public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag1zzz$declare
  v_today date := (p_as_of at time zone 'Asia/Singapore')::date;$zzv706tag1zzz$, ''))) / greatest(length($zzv706tag2zzz$declare
  v_today date := (p_as_of at time zone 'Asia/Singapore')::date;$zzv706tag2zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: funnel_conversion.decl anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag3zzz$           (s.occurred_at at time zone 'Asia/Singapore')::date as visit_date$zzv706tag3zzz$, ''))) / greatest(length($zzv706tag4zzz$           (s.occurred_at at time zone 'Asia/Singapore')::date as visit_date$zzv706tag4zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: funnel_conversion.visit anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag5zzz$  v_evidence := app.subgroup_evidence_v1(v_mature_first);
  v_stage_1_to_2 := app.rate_block_v1(v_converted_second_mature, v_mature_first);
  v_stage_2_to_3 := app.rate_block_v1(v_converted_third, v_mature_second);$zzv706tag5zzz$, ''))) / greatest(length($zzv706tag6zzz$  v_evidence := app.subgroup_evidence_v1(v_mature_first);
  v_stage_1_to_2 := app.rate_block_v1(v_converted_second_mature, v_mature_first);
  v_stage_2_to_3 := app.rate_block_v1(v_converted_third, v_mature_second);$zzv706tag6zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: funnel_conversion.stage anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag7zzz$  v_result := jsonb_build_object(
    'window_days', p_window_days,
    'time_basis', 'sale_occurred_at',
    'stage_1_to_2', v_stage_1_to_2,$zzv706tag7zzz$, ''))) / greatest(length($zzv706tag8zzz$  v_result := jsonb_build_object(
    'window_days', p_window_days,
    'time_basis', 'sale_occurred_at',
    'stage_1_to_2', v_stage_1_to_2,$zzv706tag8zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: funnel_conversion.result anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := v_def;
  v_expected := replace(v_expected, $zzv706tag9zzz$declare
  v_today date := (p_as_of at time zone 'Asia/Singapore')::date;$zzv706tag9zzz$, $zzv706tag10zzz$declare
  v_tzinfo jsonb := app.ci_bucket_tz_v698(p_business, p_branch);
  v_tz text := coalesce(v_tzinfo->>'timezone', 'Asia/Singapore');
  v_tz_basis text := coalesce(v_tzinfo->>'timezone_basis', 'mixed_branches_default');
  v_today date := (p_as_of at time zone v_tz)::date;$zzv706tag10zzz$);
  v_expected := replace(v_expected, $zzv706tag11zzz$           (s.occurred_at at time zone 'Asia/Singapore')::date as visit_date$zzv706tag11zzz$, $zzv706tag12zzz$           (s.occurred_at at time zone v_tz)::date as visit_date$zzv706tag12zzz$);
  v_expected := replace(v_expected, $zzv706tag13zzz$  v_evidence := app.subgroup_evidence_v1(v_mature_first);
  v_stage_1_to_2 := app.rate_block_v1(v_converted_second_mature, v_mature_first);
  v_stage_2_to_3 := app.rate_block_v1(v_converted_third, v_mature_second);$zzv706tag13zzz$, $zzv706tag14zzz$  v_evidence := app.subgroup_evidence_v1(v_mature_first);
  v_stage_1_to_2 := app.rate_block_floor_gated_v683(v_converted_second_mature, v_mature_first,
    app.subgroup_evidence_v1(v_mature_first));
  v_stage_2_to_3 := app.rate_block_floor_gated_v683(v_converted_third, v_mature_second,
    app.subgroup_evidence_v1(v_mature_second));$zzv706tag14zzz$);
  v_expected := replace(v_expected, $zzv706tag15zzz$  v_result := jsonb_build_object(
    'window_days', p_window_days,
    'time_basis', 'sale_occurred_at',
    'stage_1_to_2', v_stage_1_to_2,$zzv706tag15zzz$, $zzv706tag16zzz$  v_result := jsonb_build_object(
    'window_days', p_window_days,
    'time_basis', 'sale_occurred_at',
    'bucket_timezone', v_tz,
    'timezone_basis', v_tz_basis,
    'stage_1_to_2', v_stage_1_to_2,$zzv706tag16zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid,timestamptz)')) into v_after;

  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $zzv706tag17zzz$  v_result := jsonb_build_object(
    'window_days', p_window_days,
    'time_basis', 'sale_occurred_at',
    'bucket_timezone', v_tz,
    'timezone_basis', v_tz_basis,
    'stage_1_to_2', v_stage_1_to_2,$zzv706tag17zzz$, $zzv706tag18zzz$  v_result := jsonb_build_object(
    'window_days', p_window_days,
    'time_basis', 'sale_occurred_at',
    'stage_1_to_2', v_stage_1_to_2,$zzv706tag18zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag19zzz$  v_evidence := app.subgroup_evidence_v1(v_mature_first);
  v_stage_1_to_2 := app.rate_block_floor_gated_v683(v_converted_second_mature, v_mature_first,
    app.subgroup_evidence_v1(v_mature_first));
  v_stage_2_to_3 := app.rate_block_floor_gated_v683(v_converted_third, v_mature_second,
    app.subgroup_evidence_v1(v_mature_second));$zzv706tag19zzz$, $zzv706tag20zzz$  v_evidence := app.subgroup_evidence_v1(v_mature_first);
  v_stage_1_to_2 := app.rate_block_v1(v_converted_second_mature, v_mature_first);
  v_stage_2_to_3 := app.rate_block_v1(v_converted_third, v_mature_second);$zzv706tag20zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag21zzz$           (s.occurred_at at time zone v_tz)::date as visit_date$zzv706tag21zzz$, $zzv706tag22zzz$           (s.occurred_at at time zone 'Asia/Singapore')::date as visit_date$zzv706tag22zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag23zzz$declare
  v_tzinfo jsonb := app.ci_bucket_tz_v698(p_business, p_branch);
  v_tz text := coalesce(v_tzinfo->>'timezone', 'Asia/Singapore');
  v_tz_basis text := coalesce(v_tzinfo->>'timezone_basis', 'mixed_branches_default');
  v_today date := (p_as_of at time zone v_tz)::date;$zzv706tag23zzz$, $zzv706tag24zzz$declare
  v_today date := (p_as_of at time zone 'Asia/Singapore')::date;$zzv706tag24zzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v706: get_ci_funnel_conversion_v1 changed by more than the 4 intended edit(s) [decl, visit, stage, result]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_funnel_conversion$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- get_ci_retention_windows_v1
-- -------------------------------------------------------------------------------------------
do $patch_retention_windows$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v706: public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag25zzz$declare
  v_today date := (p_as_of at time zone 'Asia/Singapore')::date;$zzv706tag25zzz$, ''))) / greatest(length($zzv706tag26zzz$declare
  v_today date := (p_as_of at time zone 'Asia/Singapore')::date;$zzv706tag26zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: retention_windows.decl anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag27zzz$           (s.occurred_at at time zone 'Asia/Singapore')::date as visit_date$zzv706tag27zzz$, ''))) / greatest(length($zzv706tag28zzz$           (s.occurred_at at time zone 'Asia/Singapore')::date as visit_date$zzv706tag28zzz$), 1);
  if v_count <> 2 then
    raise exception 'v706: retention_windows.visit anchor occurs % times (expected 2) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag29zzz$  v_result := jsonb_build_object(
    'horizons', to_jsonb(v_horizons),
    'cohorts', v_cohorts,
    'immature_cells', v_immature,
    'time_basis', 'sale_occurred_at',$zzv706tag29zzz$, ''))) / greatest(length($zzv706tag30zzz$  v_result := jsonb_build_object(
    'horizons', to_jsonb(v_horizons),
    'cohorts', v_cohorts,
    'immature_cells', v_immature,
    'time_basis', 'sale_occurred_at',$zzv706tag30zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: retention_windows.result anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := v_def;
  v_expected := replace(v_expected, $zzv706tag31zzz$declare
  v_today date := (p_as_of at time zone 'Asia/Singapore')::date;$zzv706tag31zzz$, $zzv706tag32zzz$declare
  v_tzinfo jsonb := app.ci_bucket_tz_v698(p_business, p_branch);
  v_tz text := coalesce(v_tzinfo->>'timezone', 'Asia/Singapore');
  v_tz_basis text := coalesce(v_tzinfo->>'timezone_basis', 'mixed_branches_default');
  v_today date := (p_as_of at time zone v_tz)::date;$zzv706tag32zzz$);
  v_expected := replace(v_expected, $zzv706tag33zzz$           (s.occurred_at at time zone 'Asia/Singapore')::date as visit_date$zzv706tag33zzz$, $zzv706tag34zzz$           (s.occurred_at at time zone v_tz)::date as visit_date$zzv706tag34zzz$);
  v_expected := replace(v_expected, $zzv706tag35zzz$  v_result := jsonb_build_object(
    'horizons', to_jsonb(v_horizons),
    'cohorts', v_cohorts,
    'immature_cells', v_immature,
    'time_basis', 'sale_occurred_at',$zzv706tag35zzz$, $zzv706tag36zzz$  v_result := jsonb_build_object(
    'horizons', to_jsonb(v_horizons),
    'cohorts', v_cohorts,
    'immature_cells', v_immature,
    'time_basis', 'sale_occurred_at',
    'bucket_timezone', v_tz,
    'timezone_basis', v_tz_basis,$zzv706tag36zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $zzv706tag37zzz$  v_result := jsonb_build_object(
    'horizons', to_jsonb(v_horizons),
    'cohorts', v_cohorts,
    'immature_cells', v_immature,
    'time_basis', 'sale_occurred_at',
    'bucket_timezone', v_tz,
    'timezone_basis', v_tz_basis,$zzv706tag37zzz$, $zzv706tag38zzz$  v_result := jsonb_build_object(
    'horizons', to_jsonb(v_horizons),
    'cohorts', v_cohorts,
    'immature_cells', v_immature,
    'time_basis', 'sale_occurred_at',$zzv706tag38zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag39zzz$           (s.occurred_at at time zone v_tz)::date as visit_date$zzv706tag39zzz$, $zzv706tag40zzz$           (s.occurred_at at time zone 'Asia/Singapore')::date as visit_date$zzv706tag40zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag41zzz$declare
  v_tzinfo jsonb := app.ci_bucket_tz_v698(p_business, p_branch);
  v_tz text := coalesce(v_tzinfo->>'timezone', 'Asia/Singapore');
  v_tz_basis text := coalesce(v_tzinfo->>'timezone_basis', 'mixed_branches_default');
  v_today date := (p_as_of at time zone v_tz)::date;$zzv706tag41zzz$, $zzv706tag42zzz$declare
  v_today date := (p_as_of at time zone 'Asia/Singapore')::date;$zzv706tag42zzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v706: get_ci_retention_windows_v1 changed by more than the 3 intended edit(s) [decl, visit, result]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_retention_windows$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- get_ci_demographic_cohort_v1
-- -------------------------------------------------------------------------------------------
do $patch_demographic_cohort$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v706: public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag43zzz$declare
  v_result jsonb;$zzv706tag43zzz$, ''))) / greatest(length($zzv706tag44zzz$declare
  v_result jsonb;$zzv706tag44zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: demographic_cohort.decl anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag45zzz$at time zone 'Asia/Singapore'$zzv706tag45zzz$, ''))) / greatest(length($zzv706tag46zzz$at time zone 'Asia/Singapore'$zzv706tag46zzz$), 1);
  if v_count <> 8 then
    raise exception 'v706: demographic_cohort.tz anchor occurs % times (expected 8) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag47zzz$    'period', jsonb_build_object('from', p_from, 'to', p_to, 'time_basis', 'sale_occurred_at'),$zzv706tag47zzz$, ''))) / greatest(length($zzv706tag48zzz$    'period', jsonb_build_object('from', p_from, 'to', p_to, 'time_basis', 'sale_occurred_at'),$zzv706tag48zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: demographic_cohort.result anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := v_def;
  v_expected := replace(v_expected, $zzv706tag49zzz$declare
  v_result jsonb;$zzv706tag49zzz$, $zzv706tag50zzz$declare
  v_tzinfo jsonb := app.ci_bucket_tz_v698(p_business, p_branch);
  v_tz text := coalesce(v_tzinfo->>'timezone', 'Asia/Singapore');
  v_tz_basis text := coalesce(v_tzinfo->>'timezone_basis', 'mixed_branches_default');
  v_result jsonb;$zzv706tag50zzz$);
  v_expected := replace(v_expected, $zzv706tag51zzz$at time zone 'Asia/Singapore'$zzv706tag51zzz$, $zzv706tag52zzz$at time zone v_tz$zzv706tag52zzz$);
  v_expected := replace(v_expected, $zzv706tag53zzz$    'period', jsonb_build_object('from', p_from, 'to', p_to, 'time_basis', 'sale_occurred_at'),$zzv706tag53zzz$, $zzv706tag54zzz$    'period', jsonb_build_object('from', p_from, 'to', p_to, 'time_basis', 'sale_occurred_at'),
    'bucket_timezone', v_tz,
    'timezone_basis', v_tz_basis,$zzv706tag54zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid,timestamptz)')) into v_after;

  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $zzv706tag55zzz$    'period', jsonb_build_object('from', p_from, 'to', p_to, 'time_basis', 'sale_occurred_at'),
    'bucket_timezone', v_tz,
    'timezone_basis', v_tz_basis,$zzv706tag55zzz$, $zzv706tag56zzz$    'period', jsonb_build_object('from', p_from, 'to', p_to, 'time_basis', 'sale_occurred_at'),$zzv706tag56zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag57zzz$at time zone v_tz$zzv706tag57zzz$, $zzv706tag58zzz$at time zone 'Asia/Singapore'$zzv706tag58zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag59zzz$declare
  v_tzinfo jsonb := app.ci_bucket_tz_v698(p_business, p_branch);
  v_tz text := coalesce(v_tzinfo->>'timezone', 'Asia/Singapore');
  v_tz_basis text := coalesce(v_tzinfo->>'timezone_basis', 'mixed_branches_default');
  v_result jsonb;$zzv706tag59zzz$, $zzv706tag60zzz$declare
  v_result jsonb;$zzv706tag60zzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v706: get_ci_demographic_cohort_v1 changed by more than the 3 intended edit(s) [decl, tz, result]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_demographic_cohort$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- app.customer_cadence_v1
-- -------------------------------------------------------------------------------------------
do $patch_customer_cadence$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('app.customer_cadence_v1(uuid,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v706: app.customer_cadence_v1(uuid,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag61zzz$  v_evidence_class text;
begin$zzv706tag61zzz$, ''))) / greatest(length($zzv706tag62zzz$  v_evidence_class text;
begin$zzv706tag62zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: customer_cadence.decl anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag63zzz$at time zone 'Asia/Singapore'$zzv706tag63zzz$, ''))) / greatest(length($zzv706tag64zzz$at time zone 'Asia/Singapore'$zzv706tag64zzz$), 1);
  if v_count <> 2 then
    raise exception 'v706: customer_cadence.tz anchor occurs % times (expected 2) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag65zzz$    return jsonb_build_object('status','no_policy');$zzv706tag65zzz$, ''))) / greatest(length($zzv706tag66zzz$    return jsonb_build_object('status','no_policy');$zzv706tag66zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: customer_cadence.r1 anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag67zzz$    return jsonb_build_object(
      'status','insufficient',
      'evidence_source','none',
      'interval_observations', 0,
      'reason','no paid visit on record');$zzv706tag67zzz$, ''))) / greatest(length($zzv706tag68zzz$    return jsonb_build_object(
      'status','insufficient',
      'evidence_source','none',
      'interval_observations', 0,
      'reason','no paid visit on record');$zzv706tag68zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: customer_cadence.r2 anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag69zzz$  return jsonb_build_object(
    'status','ready',$zzv706tag69zzz$, ''))) / greatest(length($zzv706tag70zzz$  return jsonb_build_object(
    'status','ready',$zzv706tag70zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: customer_cadence.r3 anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := v_def;
  v_expected := replace(v_expected, $zzv706tag71zzz$  v_evidence_class text;
begin$zzv706tag71zzz$, $zzv706tag72zzz$  v_evidence_class text;
  v_tzinfo jsonb := app.ci_bucket_tz_v698(p_business, null);
  v_tz text := coalesce(v_tzinfo->>'timezone', 'Asia/Singapore');
  v_tz_basis text := coalesce(v_tzinfo->>'timezone_basis', 'mixed_branches_default');
begin$zzv706tag72zzz$);
  v_expected := replace(v_expected, $zzv706tag73zzz$at time zone 'Asia/Singapore'$zzv706tag73zzz$, $zzv706tag74zzz$at time zone v_tz$zzv706tag74zzz$);
  v_expected := replace(v_expected, $zzv706tag75zzz$    return jsonb_build_object('status','no_policy');$zzv706tag75zzz$, $zzv706tag76zzz$    return jsonb_build_object('status','no_policy', 'bucket_timezone', v_tz, 'timezone_basis', v_tz_basis);$zzv706tag76zzz$);
  v_expected := replace(v_expected, $zzv706tag77zzz$    return jsonb_build_object(
      'status','insufficient',
      'evidence_source','none',
      'interval_observations', 0,
      'reason','no paid visit on record');$zzv706tag77zzz$, $zzv706tag78zzz$    return jsonb_build_object(
      'status','insufficient',
      'evidence_source','none',
      'interval_observations', 0,
      'bucket_timezone', v_tz,
      'timezone_basis', v_tz_basis,
      'reason','no paid visit on record');$zzv706tag78zzz$);
  v_expected := replace(v_expected, $zzv706tag79zzz$  return jsonb_build_object(
    'status','ready',$zzv706tag79zzz$, $zzv706tag80zzz$  return jsonb_build_object(
    'status','ready',
    'bucket_timezone', v_tz,
    'timezone_basis', v_tz_basis,$zzv706tag80zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('app.customer_cadence_v1(uuid,uuid,timestamptz)')) into v_after;

  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $zzv706tag81zzz$  return jsonb_build_object(
    'status','ready',
    'bucket_timezone', v_tz,
    'timezone_basis', v_tz_basis,$zzv706tag81zzz$, $zzv706tag82zzz$  return jsonb_build_object(
    'status','ready',$zzv706tag82zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag83zzz$    return jsonb_build_object(
      'status','insufficient',
      'evidence_source','none',
      'interval_observations', 0,
      'bucket_timezone', v_tz,
      'timezone_basis', v_tz_basis,
      'reason','no paid visit on record');$zzv706tag83zzz$, $zzv706tag84zzz$    return jsonb_build_object(
      'status','insufficient',
      'evidence_source','none',
      'interval_observations', 0,
      'reason','no paid visit on record');$zzv706tag84zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag85zzz$    return jsonb_build_object('status','no_policy', 'bucket_timezone', v_tz, 'timezone_basis', v_tz_basis);$zzv706tag85zzz$, $zzv706tag86zzz$    return jsonb_build_object('status','no_policy');$zzv706tag86zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag87zzz$at time zone v_tz$zzv706tag87zzz$, $zzv706tag88zzz$at time zone 'Asia/Singapore'$zzv706tag88zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag89zzz$  v_evidence_class text;
  v_tzinfo jsonb := app.ci_bucket_tz_v698(p_business, null);
  v_tz text := coalesce(v_tzinfo->>'timezone', 'Asia/Singapore');
  v_tz_basis text := coalesce(v_tzinfo->>'timezone_basis', 'mixed_branches_default');
begin$zzv706tag89zzz$, $zzv706tag90zzz$  v_evidence_class text;
begin$zzv706tag90zzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v706: app.customer_cadence_v1 changed by more than the 5 intended edit(s) [decl, tz, r1, r2, r3]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_customer_cadence$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function app.customer_cadence_v1(uuid,uuid,timestamptz) from public, anon, authenticated;
grant execute on function app.customer_cadence_v1(uuid,uuid,timestamptz) to service_role;

-- -------------------------------------------------------------------------------------------
-- app.v179_business_insights
-- -------------------------------------------------------------------------------------------
do $patch_v179$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('app.v179_business_insights(uuid,date,date,date,date)')) into v_def;
  if v_def is null then
    raise exception 'v706: app.v179_business_insights(uuid,date,date,date,date) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag91zzz$  with bounds as ($zzv706tag91zzz$, ''))) / greatest(length($zzv706tag92zzz$  with bounds as ($zzv706tag92zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: v179.with anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag93zzz$    select extract(isodow from (occurred_at at time zone 'Asia/Singapore'))::int as isodow,$zzv706tag93zzz$, ''))) / greatest(length($zzv706tag94zzz$    select extract(isodow from (occurred_at at time zone 'Asia/Singapore'))::int as isodow,$zzv706tag94zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: v179.weekday anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag95zzz$    'weekday_pattern', pg_catalog.jsonb_build_object(
      'note', 'isodow: 1=Monday .. 7=Sunday, Singapore time; all sales including anonymous',
      'rows', coalesce(($zzv706tag95zzz$, ''))) / greatest(length($zzv706tag96zzz$    'weekday_pattern', pg_catalog.jsonb_build_object(
      'note', 'isodow: 1=Monday .. 7=Sunday, Singapore time; all sales including anonymous',
      'rows', coalesce(($zzv706tag96zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: v179.pattern anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag97zzz$      'existing_customer_return_rate_pct', (
        select case when count(*) filter (where visits > 0) = 0 then null
          else round(100.0 * count(*) filter (where not is_new and visits > 0)
                     / count(*) filter (where visits > 0), 1) end
        from window_clients
      ),$zzv706tag97zzz$, ''))) / greatest(length($zzv706tag98zzz$      'existing_customer_return_rate_pct', (
        select case when count(*) filter (where visits > 0) = 0 then null
          else round(100.0 * count(*) filter (where not is_new and visits > 0)
                     / count(*) filter (where visits > 0), 1) end
        from window_clients
      ),$zzv706tag98zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: v179.existing anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := v_def;
  v_expected := replace(v_expected, $zzv706tag99zzz$  with bounds as ($zzv706tag99zzz$, $zzv706tag100zzz$  with tzinfo as (
    select app.ci_bucket_tz_v698(p_business, null) as info
  ), bounds as ($zzv706tag100zzz$);
  v_expected := replace(v_expected, $zzv706tag101zzz$    select extract(isodow from (occurred_at at time zone 'Asia/Singapore'))::int as isodow,$zzv706tag101zzz$, $zzv706tag102zzz$    select extract(isodow from (occurred_at at time zone (select info->>'timezone' from tzinfo)))::int as isodow,$zzv706tag102zzz$);
  v_expected := replace(v_expected, $zzv706tag103zzz$    'weekday_pattern', pg_catalog.jsonb_build_object(
      'note', 'isodow: 1=Monday .. 7=Sunday, Singapore time; all sales including anonymous',
      'rows', coalesce(($zzv706tag103zzz$, $zzv706tag104zzz$    'weekday_pattern', pg_catalog.jsonb_build_object(
      'note', 'isodow: 1=Monday .. 7=Sunday, bucketed at bucket_timezone (see below); all sales including anonymous',
      'bucket_timezone', (select info->>'timezone' from tzinfo),
      'timezone_basis', (select info->>'timezone_basis' from tzinfo),
      'rows', coalesce(($zzv706tag104zzz$);
  v_expected := replace(v_expected, $zzv706tag105zzz$      'existing_customer_return_rate_pct', (
        select case when count(*) filter (where visits > 0) = 0 then null
          else round(100.0 * count(*) filter (where not is_new and visits > 0)
                     / count(*) filter (where visits > 0), 1) end
        from window_clients
      ),$zzv706tag105zzz$, $zzv706tag106zzz$      'existing_customer_return_rate_pct',
        case when (app.subgroup_evidence_v1((select count(*) filter (where visits > 0) from window_clients)::int)->>'status') = 'insufficient'
          then null
          else (
            select case when count(*) filter (where visits > 0) = 0 then null
              else round(100.0 * count(*) filter (where not is_new and visits > 0)
                         / count(*) filter (where visits > 0), 1) end
            from window_clients
          ) end,
      'existing_customer_return_evidence',
        app.subgroup_evidence_v1((select count(*) filter (where visits > 0) from window_clients)::int),$zzv706tag106zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('app.v179_business_insights(uuid,date,date,date,date)')) into v_after;

  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $zzv706tag107zzz$      'existing_customer_return_rate_pct',
        case when (app.subgroup_evidence_v1((select count(*) filter (where visits > 0) from window_clients)::int)->>'status') = 'insufficient'
          then null
          else (
            select case when count(*) filter (where visits > 0) = 0 then null
              else round(100.0 * count(*) filter (where not is_new and visits > 0)
                         / count(*) filter (where visits > 0), 1) end
            from window_clients
          ) end,
      'existing_customer_return_evidence',
        app.subgroup_evidence_v1((select count(*) filter (where visits > 0) from window_clients)::int),$zzv706tag107zzz$, $zzv706tag108zzz$      'existing_customer_return_rate_pct', (
        select case when count(*) filter (where visits > 0) = 0 then null
          else round(100.0 * count(*) filter (where not is_new and visits > 0)
                     / count(*) filter (where visits > 0), 1) end
        from window_clients
      ),$zzv706tag108zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag109zzz$    'weekday_pattern', pg_catalog.jsonb_build_object(
      'note', 'isodow: 1=Monday .. 7=Sunday, bucketed at bucket_timezone (see below); all sales including anonymous',
      'bucket_timezone', (select info->>'timezone' from tzinfo),
      'timezone_basis', (select info->>'timezone_basis' from tzinfo),
      'rows', coalesce(($zzv706tag109zzz$, $zzv706tag110zzz$    'weekday_pattern', pg_catalog.jsonb_build_object(
      'note', 'isodow: 1=Monday .. 7=Sunday, Singapore time; all sales including anonymous',
      'rows', coalesce(($zzv706tag110zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag111zzz$    select extract(isodow from (occurred_at at time zone (select info->>'timezone' from tzinfo)))::int as isodow,$zzv706tag111zzz$, $zzv706tag112zzz$    select extract(isodow from (occurred_at at time zone 'Asia/Singapore'))::int as isodow,$zzv706tag112zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag113zzz$  with tzinfo as (
    select app.ci_bucket_tz_v698(p_business, null) as info
  ), bounds as ($zzv706tag113zzz$, $zzv706tag114zzz$  with bounds as ($zzv706tag114zzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v706: app.v179_business_insights changed by more than the 4 intended edit(s) [with, weekday, pattern, existing]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_v179$;

-- -------------------------------------------------------------------------------------------
-- get_ci_discovery_v1
-- -------------------------------------------------------------------------------------------
do $patch_discovery$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_discovery_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v706: public.get_ci_discovery_v1(uuid,date,date,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag115zzz$  v_current_pct numeric;
begin$zzv706tag115zzz$, ''))) / greatest(length($zzv706tag116zzz$  v_current_pct numeric;
begin$zzv706tag116zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: discovery.decl anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag117zzz$  anchors as (
    select h.half, s.client_id,
           min((s.occurred_at at time zone 'Asia/Singapore')::date) as anchor_date
      from halves h
      join public.sales s on s.business_id = p_business
      cross join lateral app.analytics_sale_class_v1(s) sc
     where (p_branch is null or s.branch_id = p_branch)
       and sc.include_visit
       and not sc.is_synthetic_client
       and s.client_id is not null
       and (s.occurred_at at time zone 'Asia/Singapore')::date between h.h_from and h.h_to
     group by h.half, s.client_id
  ),
  anchor_sale as (
    -- the specific sale row for that anchor date (min id breaks a same-day tie deterministically).
    select a.half, a.client_id, a.anchor_date,
           (select s.id from public.sales s
              cross join lateral app.analytics_sale_class_v1(s) sc
             where s.business_id = p_business and s.client_id = a.client_id
               and (p_branch is null or s.branch_id = p_branch)
               and sc.include_visit and not sc.is_synthetic_client
               and (s.occurred_at at time zone 'Asia/Singapore')::date = a.anchor_date
             order by s.id asc limit 1) as anchor_sale_id
      from anchors a
  ),$zzv706tag117zzz$, ''))) / greatest(length($zzv706tag118zzz$  anchors as (
    select h.half, s.client_id,
           min((s.occurred_at at time zone 'Asia/Singapore')::date) as anchor_date
      from halves h
      join public.sales s on s.business_id = p_business
      cross join lateral app.analytics_sale_class_v1(s) sc
     where (p_branch is null or s.branch_id = p_branch)
       and sc.include_visit
       and not sc.is_synthetic_client
       and s.client_id is not null
       and (s.occurred_at at time zone 'Asia/Singapore')::date between h.h_from and h.h_to
     group by h.half, s.client_id
  ),
  anchor_sale as (
    -- the specific sale row for that anchor date (min id breaks a same-day tie deterministically).
    select a.half, a.client_id, a.anchor_date,
           (select s.id from public.sales s
              cross join lateral app.analytics_sale_class_v1(s) sc
             where s.business_id = p_business and s.client_id = a.client_id
               and (p_branch is null or s.branch_id = p_branch)
               and sc.include_visit and not sc.is_synthetic_client
               and (s.occurred_at at time zone 'Asia/Singapore')::date = a.anchor_date
             order by s.id asc limit 1) as anchor_sale_id
      from anchors a
  ),$zzv706tag118zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: discovery.anchors anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag119zzz$      'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                   'from', p_from, 'to', p_to),$zzv706tag119zzz$, ''))) / greatest(length($zzv706tag120zzz$      'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                   'from', p_from, 'to', p_to),$zzv706tag120zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: discovery.scope anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, $zzv706tag121zzz$        'current_pct', (select case when h.n > 0 then round(100.0*h.numer/h.n,1) else null end from headline h),$zzv706tag121zzz$, ''))) / greatest(length($zzv706tag122zzz$        'current_pct', (select case when h.n > 0 then round(100.0*h.numer/h.n,1) else null end from headline h),$zzv706tag122zzz$), 1);
  if v_count <> 1 then
    raise exception 'v706: discovery.current_pct anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := v_def;
  v_expected := replace(v_expected, $zzv706tag123zzz$  v_current_pct numeric;
begin$zzv706tag123zzz$, $zzv706tag124zzz$  v_current_pct numeric;
  v_tzinfo jsonb := app.ci_bucket_tz_v698(p_business, p_branch);
  v_tz text := coalesce(v_tzinfo->>'timezone', 'Asia/Singapore');
  v_tz_basis text := coalesce(v_tzinfo->>'timezone_basis', 'mixed_branches_default');
begin$zzv706tag124zzz$);
  v_expected := replace(v_expected, $zzv706tag125zzz$  anchors as (
    select h.half, s.client_id,
           min((s.occurred_at at time zone 'Asia/Singapore')::date) as anchor_date
      from halves h
      join public.sales s on s.business_id = p_business
      cross join lateral app.analytics_sale_class_v1(s) sc
     where (p_branch is null or s.branch_id = p_branch)
       and sc.include_visit
       and not sc.is_synthetic_client
       and s.client_id is not null
       and (s.occurred_at at time zone 'Asia/Singapore')::date between h.h_from and h.h_to
     group by h.half, s.client_id
  ),
  anchor_sale as (
    -- the specific sale row for that anchor date (min id breaks a same-day tie deterministically).
    select a.half, a.client_id, a.anchor_date,
           (select s.id from public.sales s
              cross join lateral app.analytics_sale_class_v1(s) sc
             where s.business_id = p_business and s.client_id = a.client_id
               and (p_branch is null or s.branch_id = p_branch)
               and sc.include_visit and not sc.is_synthetic_client
               and (s.occurred_at at time zone 'Asia/Singapore')::date = a.anchor_date
             order by s.id asc limit 1) as anchor_sale_id
      from anchors a
  ),$zzv706tag125zzz$, $zzv706tag126zzz$  anchors as (
    select h.half, s.client_id,
           min((s.occurred_at at time zone v_tz)::date) as anchor_date
      from halves h
      join public.sales s on s.business_id = p_business
      cross join lateral app.analytics_sale_class_v1(s) sc
     where (p_branch is null or s.branch_id = p_branch)
       and sc.include_visit
       and not sc.is_synthetic_client
       and s.client_id is not null
       and (s.occurred_at at time zone v_tz)::date between h.h_from and h.h_to
     group by h.half, s.client_id
  ),
  anchor_sale as (
    -- the specific sale row for that anchor date (min id breaks a same-day tie deterministically).
    select a.half, a.client_id, a.anchor_date,
           (select s.id from public.sales s
              cross join lateral app.analytics_sale_class_v1(s) sc
             where s.business_id = p_business and s.client_id = a.client_id
               and (p_branch is null or s.branch_id = p_branch)
               and sc.include_visit and not sc.is_synthetic_client
               and (s.occurred_at at time zone v_tz)::date = a.anchor_date
             order by s.id asc limit 1) as anchor_sale_id
      from anchors a
  ),$zzv706tag126zzz$);
  v_expected := replace(v_expected, $zzv706tag127zzz$      'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                   'from', p_from, 'to', p_to),$zzv706tag127zzz$, $zzv706tag128zzz$      'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                   'from', p_from, 'to', p_to,
                                   'bucket_timezone', v_tz, 'timezone_basis', v_tz_basis),$zzv706tag128zzz$);
  v_expected := replace(v_expected, $zzv706tag129zzz$        'current_pct', (select case when h.n > 0 then round(100.0*h.numer/h.n,1) else null end from headline h),$zzv706tag129zzz$, $zzv706tag130zzz$        'current_pct', (select case when h.n >= v_floor then round(100.0*h.numer/h.n,1) else null end from headline h),$zzv706tag130zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_discovery_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $zzv706tag131zzz$        'current_pct', (select case when h.n >= v_floor then round(100.0*h.numer/h.n,1) else null end from headline h),$zzv706tag131zzz$, $zzv706tag132zzz$        'current_pct', (select case when h.n > 0 then round(100.0*h.numer/h.n,1) else null end from headline h),$zzv706tag132zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag133zzz$      'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                   'from', p_from, 'to', p_to,
                                   'bucket_timezone', v_tz, 'timezone_basis', v_tz_basis),$zzv706tag133zzz$, $zzv706tag134zzz$      'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                   'from', p_from, 'to', p_to),$zzv706tag134zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag135zzz$  anchors as (
    select h.half, s.client_id,
           min((s.occurred_at at time zone v_tz)::date) as anchor_date
      from halves h
      join public.sales s on s.business_id = p_business
      cross join lateral app.analytics_sale_class_v1(s) sc
     where (p_branch is null or s.branch_id = p_branch)
       and sc.include_visit
       and not sc.is_synthetic_client
       and s.client_id is not null
       and (s.occurred_at at time zone v_tz)::date between h.h_from and h.h_to
     group by h.half, s.client_id
  ),
  anchor_sale as (
    -- the specific sale row for that anchor date (min id breaks a same-day tie deterministically).
    select a.half, a.client_id, a.anchor_date,
           (select s.id from public.sales s
              cross join lateral app.analytics_sale_class_v1(s) sc
             where s.business_id = p_business and s.client_id = a.client_id
               and (p_branch is null or s.branch_id = p_branch)
               and sc.include_visit and not sc.is_synthetic_client
               and (s.occurred_at at time zone v_tz)::date = a.anchor_date
             order by s.id asc limit 1) as anchor_sale_id
      from anchors a
  ),$zzv706tag135zzz$, $zzv706tag136zzz$  anchors as (
    select h.half, s.client_id,
           min((s.occurred_at at time zone 'Asia/Singapore')::date) as anchor_date
      from halves h
      join public.sales s on s.business_id = p_business
      cross join lateral app.analytics_sale_class_v1(s) sc
     where (p_branch is null or s.branch_id = p_branch)
       and sc.include_visit
       and not sc.is_synthetic_client
       and s.client_id is not null
       and (s.occurred_at at time zone 'Asia/Singapore')::date between h.h_from and h.h_to
     group by h.half, s.client_id
  ),
  anchor_sale as (
    -- the specific sale row for that anchor date (min id breaks a same-day tie deterministically).
    select a.half, a.client_id, a.anchor_date,
           (select s.id from public.sales s
              cross join lateral app.analytics_sale_class_v1(s) sc
             where s.business_id = p_business and s.client_id = a.client_id
               and (p_branch is null or s.branch_id = p_branch)
               and sc.include_visit and not sc.is_synthetic_client
               and (s.occurred_at at time zone 'Asia/Singapore')::date = a.anchor_date
             order by s.id asc limit 1) as anchor_sale_id
      from anchors a
  ),$zzv706tag136zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv706tag137zzz$  v_current_pct numeric;
  v_tzinfo jsonb := app.ci_bucket_tz_v698(p_business, p_branch);
  v_tz text := coalesce(v_tzinfo->>'timezone', 'Asia/Singapore');
  v_tz_basis text := coalesce(v_tzinfo->>'timezone_basis', 'mixed_branches_default');
begin$zzv706tag137zzz$, $zzv706tag138zzz$  v_current_pct numeric;
begin$zzv706tag138zzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v706: get_ci_discovery_v1 changed by more than the 4 intended edit(s) [decl, anchors, scope, current_pct]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_discovery$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_discovery_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_discovery_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

commit;
