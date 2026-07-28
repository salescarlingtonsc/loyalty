-- NESTLY v92 — synthetic rehearsal isolation and firm-attention null repair.
--
-- Structural test tenants are useful for production-parity acceptance, but their
-- customers, sales and balances must never affect enterprise management reports
-- or the real-firm onboarding queue. Merchant reports remain tenant-scoped, so a
-- synthetic tenant can still inspect its own end-to-end evidence.

begin;

-- Patch the three v82 enterprise readers in place. Each function has exactly one
-- business anchor. The occurrence assertion makes migration drift fail closed
-- instead of silently leaving a reader unfiltered.
do $v92_enterprise$
declare
  v_signature regprocedure;
  v_definition text;
  v_needle constant text := 'where business.created_at<=v_snapshot_at';
  v_replacement constant text :=
    'where business.is_synthetic=false and business.created_at<=v_snapshot_at';
  v_occurrences integer;
begin
  foreach v_signature in array array[
    'public.platform_get_enterprise_hierarchy_v82(text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid)'::regprocedure,
    'public.platform_list_enterprise_customers_v82(text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid)'::regprocedure,
    'public.platform_generate_improvement_report_v82(text,uuid[],uuid,date,date,text,timestamptz)'::regprocedure
  ] loop
    v_definition:=pg_get_functiondef(v_signature);
    v_occurrences:=(length(v_definition)-length(replace(v_definition,v_needle,'')))
      /length(v_needle);
    if v_occurrences<>1 then
      raise exception 'v92 expected one enterprise business anchor in %, found %',
        v_signature,v_occurrences using errcode='55000';
    end if;
    execute replace(v_definition,v_needle,v_replacement);
  end loop;
end
$v92_enterprise$;

-- v88 used SQL three-valued logic for attention_due. With no next action and
-- fewer than seven unattended days, `NULL OR false` became NULL and violated
-- the frozen snapshot table's required boolean. Also exclude structurally
-- synthetic businesses from the real-firm onboarding directory.
do $v92_firms$
declare
  v_signature regprocedure :=
    'app.platform_firm_rows_v88(timestamptz)'::regprocedure;
  v_definition text:=pg_get_functiondef(v_signature);
  v_business_anchor constant text :=
    'where business.created_at<=p_snapshot_at';
  v_business_replacement constant text :=
    'where business.is_synthetic=false and business.created_at<=p_snapshot_at';
  v_prospect_anchor constant text :=
    'where prospect.created_at<=p_snapshot_at';
  v_prospect_replacement constant text :=
    'where prospect.created_at <= p_snapshot_at
      and (business.id is null or business.is_synthetic = false)';
  v_occurrences integer;
begin
  -- pg_get_functiondef normalises the original SQL. Assert and replace only the
  -- two stable anchor fragments first.
  v_occurrences:=(length(v_definition)-length(replace(
    v_definition,v_business_anchor,'')))/length(v_business_anchor);
  if v_occurrences<>1 then
    raise exception 'v92 expected one v88 business anchor, found %',v_occurrences
      using errcode='55000';
  end if;
  v_definition:=replace(v_definition,v_business_anchor,v_business_replacement);

  v_occurrences:=(length(v_definition)-length(replace(
    v_definition,v_prospect_anchor,'')))/length(v_prospect_anchor);
  if v_occurrences<>1 then
    raise exception 'v92 expected one v88 prospect anchor, found %',v_occurrences
      using errcode='55000';
  end if;
  v_definition:=replace(v_definition,v_prospect_anchor,v_prospect_replacement);

  -- Replace the complete normalised attention_due projection. Keeping the
  -- coalesce at the source also guarantees JSON clients receive a boolean.
  if position(
    'aged.resolved_lane_key not in (''case_won'',''closed'') and (
      aged.next_action_at<p_snapshot_at or aged.resolved_days_unattended>=7
    ) as attention_due'
    in v_definition
  )=0 then
    raise exception 'v92 could not locate the v88 attention_due projection'
      using errcode='55000';
  end if;
  v_definition:=replace(
    v_definition,
    'aged.resolved_lane_key not in (''case_won'',''closed'') and (
      aged.next_action_at<p_snapshot_at or aged.resolved_days_unattended>=7
    ) as attention_due',
    'coalesce(aged.resolved_lane_key not in (''case_won'',''closed'') and (
      aged.next_action_at<p_snapshot_at or aged.resolved_days_unattended>=7
    ),false) as attention_due'
  );
  execute v_definition;
end
$v92_firms$;

comment on function app.platform_firm_rows_v88(timestamptz)
  is 'v92: real-firm-only platform onboarding source; attention_due is always boolean.';
comment on function public.platform_get_enterprise_hierarchy_v82(
  text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid
) is 'v92: enterprise hierarchy excludes structurally synthetic businesses.';
comment on function public.platform_list_enterprise_customers_v82(
  text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid
) is 'v92: enterprise customer export excludes structurally synthetic businesses.';
comment on function public.platform_generate_improvement_report_v82(
  text,uuid[],uuid,date,date,text,timestamptz
) is 'v92: enterprise improvement reports exclude structurally synthetic businesses.';

commit;
