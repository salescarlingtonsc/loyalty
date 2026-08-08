-- Rollback-only v244 acceptance: can_request_ai_report is true exactly when
-- platform_request_ai_firm_report_v176 will accept the request.
--
-- The bug this closes: v226 set the flag from "has a converted business" alone,
-- so a converted DEMO firm was offered a button that v176 refuses outright. The
-- decisive assertion here is D — it does not re-state the rule, it CALLS v176
-- and checks the two agree.
begin;

do $v244$
declare
  v_sa uuid; v_sme uuid;
  v_p_real uuid; v_p_demo uuid; v_p_synth uuid; v_p_unconverted uuid;
  v_b_real uuid; v_b_demo uuid; v_b_synth uuid;
  a jsonb;
  flag_real boolean; flag_demo boolean; flag_synth boolean; flag_unconverted boolean;
  v_accepted boolean;
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;

  ---------------------------------------------------------------- seed
  insert into public.sme_companies(legal_name, trading_name, industry)
    values ('ZZ V244 ACCEPTANCE PTE LTD','ZZ V244','cafe') returning id into v_sme;

  insert into public.businesses(name, slug, industry, is_demo, is_synthetic)
    values ('ZZ V244 Real','zz-v244-real','cafe',false,false) returning id into v_b_real;
  insert into public.businesses(name, slug, industry, is_demo, is_synthetic)
    values ('ZZ V244 Demo','zz-v244-demo','cafe',true,false) returning id into v_b_demo;
  insert into public.businesses(name, slug, industry, is_demo, is_synthetic)
    values ('ZZ V244 Synth','zz-v244-synth','cafe',false,true) returning id into v_b_synth;

  insert into public.sme_prospects(company_id, legacy_stage_raw,
      converted_business_id, converted_at, converted_by)
    values (v_sme,'v244-real',v_b_real,now(),v_sa) returning id into v_p_real;
  insert into public.sme_prospects(company_id, legacy_stage_raw,
      converted_business_id, converted_at, converted_by)
    values (v_sme,'v244-demo',v_b_demo,now(),v_sa) returning id into v_p_demo;
  insert into public.sme_prospects(company_id, legacy_stage_raw,
      converted_business_id, converted_at, converted_by)
    values (v_sme,'v244-synth',v_b_synth,now(),v_sa) returning id into v_p_synth;
  insert into public.sme_prospects(company_id, legacy_stage_raw)
    values (v_sme,'v244-unconverted') returning id into v_p_unconverted;

  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text, true);

  a := public.platform_crm_pipeline_v226(p_search => 'ZZ V244');
  select (i->>'can_request_ai_report')::boolean into flag_real
    from jsonb_array_elements(a->'items') i where i->>'id' = v_p_real::text;
  select (i->>'can_request_ai_report')::boolean into flag_demo
    from jsonb_array_elements(a->'items') i where i->>'id' = v_p_demo::text;
  select (i->>'can_request_ai_report')::boolean into flag_synth
    from jsonb_array_elements(a->'items') i where i->>'id' = v_p_synth::text;
  select (i->>'can_request_ai_report')::boolean into flag_unconverted
    from jsonb_array_elements(a->'items') i where i->>'id' = v_p_unconverted::text;

  ---------------------------------------------------------------- A. a real converted firm may be reported on
  if flag_real is not true then
    raise exception 'A: a real converted firm was not offered an AI report';
  end if;

  ---------------------------------------------------------------- B. demo and synthetic firms may not
  if flag_demo is not false then
    raise exception 'B: a DEMO firm was offered an AI report v176 will refuse';
  end if;
  if flag_synth is not false then
    raise exception 'B: a SYNTHETIC firm was offered an AI report v176 will refuse';
  end if;

  ---------------------------------------------------------------- C. an unconverted prospect may not
  if flag_unconverted is not false then
    raise exception 'C: an unconverted prospect was offered an AI report';
  end if;

  ---------------------------------------------------------------- D. the flag agrees with v176 itself
  -- Not a restatement of the rule: this calls the real function and compares.
  -- A valid CLOSED monthly period is required, so use the first day of last month.
  declare
    v_start date := (date_trunc('month',
      ((clock_timestamp() at time zone 'Asia/Singapore')::date)) - interval '1 month')::date;
    v_case record;
  begin
    for v_case in
      select 'real' as label, v_b_real as business, flag_real as flag
      union all select 'demo', v_b_demo, flag_demo
      union all select 'synthetic', v_b_synth, flag_synth
    loop
      begin
        perform public.platform_request_ai_firm_report_v176(
          v_case.business, 'monthly', v_start);
        v_accepted := true;
      exception when others then
        v_accepted := false;
      end;
      if v_accepted is distinct from v_case.flag then
        raise exception
          'D: % firm — flag says % but v176 %',
          v_case.label, v_case.flag,
          case when v_accepted then 'accepted it' else 'refused it' end;
      end if;
    end loop;
  end;

  raise notice 'v244 AI report flag: all assertions passed';
end $v244$;

rollback;
