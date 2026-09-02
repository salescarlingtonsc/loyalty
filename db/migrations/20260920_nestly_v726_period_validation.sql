-- NESTLY v726 -- period validation on the 13 remaining get_ci_* readers (check 98 /
-- docs/qa/CI-100-CHECKLIST.md): a refuter proved every one of these readers accepted
-- p_to < p_from and returned a normal-looking, empty payload instead of an error -- an
-- inverted [from, to] window silently reads as "no rows in range" rather than "malformed
-- request", which is indistinguishable from a genuinely quiet period at the call site.
--
-- THE FIX. app.ci_period_validate_v726(p_from date, p_to date) raises 'invalid_report_window'
-- (errcode 22023, the same class app.ci_no_branch_dimension_v667 already uses for a malformed
-- Customer Intelligence request) when either bound is null or p_to < p_from. Every reader below
-- takes p_from/p_to as plain, non-defaulted date parameters -- there is no reading of the
-- signature where a caller is allowed to omit either -- so both are required, not just ordered.
--
-- PLACEMENT: the new call sits immediately AFTER app.ci_access_gate_v667(p_business, p_branch)
-- and nothing else. A refused caller must still learn they lack access (42501) before learning
-- anything about the shape of their request -- swapping the order would leak "your window is
-- malformed" to a caller who was never entitled to ask the question, and would change the
-- error a legitimately-refused caller sees for no reason. Every one of the 13 readers below
-- calls the shared gate as its very first statement, so "immediately after the gate" is
-- unambiguous and identical across all 13 -- one anchor, one edit, thirteen times.
--
-- Re-emits ONLY the 13 readers named in the corpus header below. Does NOT touch
-- get_ci_category_customers_v1 or get_customer_intelligence_v83 (their own period handling is
-- out of scope for this migration), app.shadow_reconciliation, the evidence pack (nestly_v720),
-- or app.ci_access_gate_v667/app.ci_envelope_v680 (the spine) -- all deliberately left alone.
--
-- Every patch below is an anchored extract-and-diff replace-equality edit of the LIVE body
-- (pg_get_functiondef captured at apply time), verified to round-trip back to the exact live
-- original once the intended edit is reversed -- same discipline as v668/v690/v706, never a
-- hand-retyped guess at the base text.
--
-- Proven by db/tests/executed/v726_corpus_period_validation.sql.

begin;

-- -------------------------------------------------------------------------------------------
-- app.ci_period_validate_v726 -- the new shared authority
-- -------------------------------------------------------------------------------------------
create or replace function app.ci_period_validate_v726(p_from date, p_to date)
returns void
language plpgsql
immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'invalid_report_window'
      using errcode = '22023';
  end if;
end;
$function$;

-- -------------------------------------------------------------------------------------------
-- public.get_ci_acquisition_v1
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
    raise exception 'v726: public.get_ci_acquisition_v1(uuid,date,date,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $v726t1a$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t1a$, ''))) / greatest(length($v726t1b$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t1b$), 1);
  if v_count <> 1 then
    raise exception 'v726: acquisition.gate anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $v726t1c$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t1c$, $v726t1d$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t1d$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_acquisition_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, $v726t1e$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t1e$, $v726t1f$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t1f$);
  if v_roundtrip <> v_def then
    raise exception
      'v726: get_ci_acquisition_v1 changed by more than the 1 intended edit [gate+period]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_acquisition$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_acquisition_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_acquisition_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- public.get_ci_category_mix_v1
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
    raise exception 'v726: public.get_ci_category_mix_v1(uuid,date,date,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $v726t2a$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t2a$, ''))) / greatest(length($v726t2b$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t2b$), 1);
  if v_count <> 1 then
    raise exception 'v726: category_mix.gate anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $v726t2c$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t2c$, $v726t2d$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t2d$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_category_mix_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, $v726t2e$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t2e$, $v726t2f$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t2f$);
  if v_roundtrip <> v_def then
    raise exception
      'v726: get_ci_category_mix_v1 changed by more than the 1 intended edit [gate+period]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_category_mix$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_category_mix_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_category_mix_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- public.get_ci_demographic_cohort_v1
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
    raise exception 'v726: public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $v726t3a$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t3a$, ''))) / greatest(length($v726t3b$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t3b$), 1);
  if v_count <> 1 then
    raise exception 'v726: demographic_cohort.gate anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $v726t3c$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t3c$, $v726t3d$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t3d$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, $v726t3e$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t3e$, $v726t3f$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t3f$);
  if v_roundtrip <> v_def then
    raise exception
      'v726: get_ci_demographic_cohort_v1 changed by more than the 1 intended edit [gate+period]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_demographic_cohort$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- public.get_ci_demographics_v1
-- -------------------------------------------------------------------------------------------
do $patch_demographics$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_demographics_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v726: public.get_ci_demographics_v1(uuid,date,date,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $v726t4a$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t4a$, ''))) / greatest(length($v726t4b$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t4b$), 1);
  if v_count <> 1 then
    raise exception 'v726: demographics.gate anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $v726t4c$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t4c$, $v726t4d$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t4d$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_demographics_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, $v726t4e$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t4e$, $v726t4f$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t4f$);
  if v_roundtrip <> v_def then
    raise exception
      'v726: get_ci_demographics_v1 changed by more than the 1 intended edit [gate+period]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_demographics$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_demographics_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_demographics_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- public.get_ci_discount_dependency_v1
-- -------------------------------------------------------------------------------------------
do $patch_discount_dependency$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_discount_dependency_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v726: public.get_ci_discount_dependency_v1(uuid,date,date,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $v726t5a$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t5a$, ''))) / greatest(length($v726t5b$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t5b$), 1);
  if v_count <> 1 then
    raise exception 'v726: discount_dependency.gate anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $v726t5c$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t5c$, $v726t5d$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t5d$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_discount_dependency_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, $v726t5e$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t5e$, $v726t5f$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t5f$);
  if v_roundtrip <> v_def then
    raise exception
      'v726: get_ci_discount_dependency_v1 changed by more than the 1 intended edit [gate+period]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_discount_dependency$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_discount_dependency_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_discount_dependency_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- public.get_ci_funnel_conversion_v1
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
    raise exception 'v726: public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $v726t6a$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t6a$, ''))) / greatest(length($v726t6b$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t6b$), 1);
  if v_count <> 1 then
    raise exception 'v726: funnel_conversion.gate anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $v726t6c$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t6c$, $v726t6d$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t6d$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, $v726t6e$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t6e$, $v726t6f$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t6f$);
  if v_roundtrip <> v_def then
    raise exception
      'v726: get_ci_funnel_conversion_v1 changed by more than the 1 intended edit [gate+period]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_funnel_conversion$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- public.get_ci_funnel_v1
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
    raise exception 'v726: public.get_ci_funnel_v1(uuid,date,date,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $v726t7a$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t7a$, ''))) / greatest(length($v726t7b$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t7b$), 1);
  if v_count <> 1 then
    raise exception 'v726: funnel.gate anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $v726t7c$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t7c$, $v726t7d$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t7d$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_funnel_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, $v726t7e$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t7e$, $v726t7f$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t7f$);
  if v_roundtrip <> v_def then
    raise exception
      'v726: get_ci_funnel_v1 changed by more than the 1 intended edit [gate+period]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_funnel$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_funnel_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_funnel_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- public.get_ci_loyalty_programmes_v1
-- -------------------------------------------------------------------------------------------
do $patch_loyalty_programmes$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid)')) into v_def;
  if v_def is null then
    raise exception 'v726: public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $v726t8a$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t8a$, ''))) / greatest(length($v726t8b$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t8b$), 1);
  if v_count <> 1 then
    raise exception 'v726: loyalty_programmes.gate anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $v726t8c$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t8c$, $v726t8d$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t8d$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid)')) into v_after;

  v_roundtrip := replace(v_after, $v726t8e$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t8e$, $v726t8f$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t8f$);
  if v_roundtrip <> v_def then
    raise exception
      'v726: get_ci_loyalty_programmes_v1 changed by more than the 1 intended edit [gate+period]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_loyalty_programmes$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- public.get_ci_marketing_funnel_v1
-- -------------------------------------------------------------------------------------------
do $patch_marketing_funnel$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_marketing_funnel_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v726: public.get_ci_marketing_funnel_v1(uuid,date,date,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $v726t9a$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t9a$, ''))) / greatest(length($v726t9b$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t9b$), 1);
  if v_count <> 1 then
    raise exception 'v726: marketing_funnel.gate anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $v726t9c$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t9c$, $v726t9d$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t9d$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_marketing_funnel_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, $v726t9e$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t9e$, $v726t9f$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t9f$);
  if v_roundtrip <> v_def then
    raise exception
      'v726: get_ci_marketing_funnel_v1 changed by more than the 1 intended edit [gate+period]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_marketing_funnel$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_marketing_funnel_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_marketing_funnel_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- public.get_ci_rebooking_v1
-- -------------------------------------------------------------------------------------------
do $patch_rebooking$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_rebooking_v1(uuid,date,date,uuid)')) into v_def;
  if v_def is null then
    raise exception 'v726: public.get_ci_rebooking_v1(uuid,date,date,uuid) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $v726t10a$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t10a$, ''))) / greatest(length($v726t10b$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t10b$), 1);
  if v_count <> 1 then
    raise exception 'v726: rebooking.gate anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $v726t10c$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t10c$, $v726t10d$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t10d$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_rebooking_v1(uuid,date,date,uuid)')) into v_after;

  v_roundtrip := replace(v_after, $v726t10e$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t10e$, $v726t10f$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t10f$);
  if v_roundtrip <> v_def then
    raise exception
      'v726: get_ci_rebooking_v1 changed by more than the 1 intended edit [gate+period]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_rebooking$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_rebooking_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_rebooking_v1(uuid,date,date,uuid) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- public.get_ci_retention_windows_v1
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
    raise exception 'v726: public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $v726t11a$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t11a$, ''))) / greatest(length($v726t11b$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t11b$), 1);
  if v_count <> 1 then
    raise exception 'v726: retention_windows.gate anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $v726t11c$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t11c$, $v726t11d$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t11d$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, $v726t11e$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t11e$, $v726t11f$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t11f$);
  if v_roundtrip <> v_def then
    raise exception
      'v726: get_ci_retention_windows_v1 changed by more than the 1 intended edit [gate+period]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_retention_windows$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- public.get_ci_staff_identity_v1
-- -------------------------------------------------------------------------------------------
do $patch_staff_identity$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_staff_identity_v1(uuid,date,date,uuid)')) into v_def;
  if v_def is null then
    raise exception 'v726: public.get_ci_staff_identity_v1(uuid,date,date,uuid) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $v726t12a$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t12a$, ''))) / greatest(length($v726t12b$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t12b$), 1);
  if v_count <> 1 then
    raise exception 'v726: staff_identity.gate anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $v726t12c$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t12c$, $v726t12d$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t12d$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_staff_identity_v1(uuid,date,date,uuid)')) into v_after;

  v_roundtrip := replace(v_after, $v726t12e$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t12e$, $v726t12f$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t12f$);
  if v_roundtrip <> v_def then
    raise exception
      'v726: get_ci_staff_identity_v1 changed by more than the 1 intended edit [gate+period]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_staff_identity$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_staff_identity_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_staff_identity_v1(uuid,date,date,uuid) to authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- public.get_ci_staff_performance_v1
-- -------------------------------------------------------------------------------------------
do $patch_staff_performance$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_staff_performance_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v726: public.get_ci_staff_performance_v1(uuid,date,date,uuid,timestamptz) not found';
  end if;
  v_count := (length(v_def) - length(replace(v_def, $v726t13a$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t13a$, ''))) / greatest(length($v726t13b$  perform app.ci_access_gate_v667(p_business, p_branch);
$v726t13b$), 1);
  if v_count <> 1 then
    raise exception 'v726: staff_performance.gate anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $v726t13c$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t13c$, $v726t13d$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t13d$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_staff_performance_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, $v726t13e$  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_period_validate_v726(p_from, p_to);$v726t13e$, $v726t13f$  perform app.ci_access_gate_v667(p_business, p_branch);$v726t13f$);
  if v_roundtrip <> v_def then
    raise exception
      'v726: get_ci_staff_performance_v1 changed by more than the 1 intended edit [gate+period]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_staff_performance$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_staff_performance_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_staff_performance_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

commit;
