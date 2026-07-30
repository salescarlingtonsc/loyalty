-- Rollback-only v109 economics, deterministic driver and sector-policy evidence.
-- Run after the canonical chain through v109 in a disposable database.
begin;

do $contract$
declare
  v_table text;
begin
  if to_regprocedure(
    'public.set_effective_cost_rule_v109(uuid,uuid,text,text,text,bigint,text,text,jsonb,timestamp with time zone,uuid)'
  ) is null or to_regprocedure(
    'public.get_period_economics_v109(uuid,date,date,uuid,bigint,text,timestamp with time zone)'
  ) is null or to_regprocedure(
    'public.get_revenue_driver_decomposition_v109(uuid,date,date,date,date,uuid,timestamp with time zone)'
  ) is null or to_regprocedure(
    'public.get_effective_sector_policy_v109(uuid,text,timestamp with time zone)'
  ) is null or to_regprocedure(
    'public.set_business_sector_policy_override_v109(uuid,text,jsonb,text,timestamp with time zone,uuid)'
  ) is null then
    raise exception 'v109 public RPC contract is incomplete';
  end if;

  foreach v_table in array array[
    'economic_cost_rules_v109',
    'sector_policy_versions_v109',
    'business_sector_policy_overrides_v109'
  ] loop
    if not exists(
      select 1
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname=v_table and c.relrowsecurity
    ) then
      raise exception 'v109 table % does not enforce RLS',v_table;
    end if;
    if has_table_privilege('authenticated','public.'||v_table,'INSERT')
       or has_table_privilege('authenticated','public.'||v_table,'UPDATE')
       or has_table_privilege('authenticated','public.'||v_table,'DELETE') then
      raise exception 'authenticated has a direct mutation grant on %',v_table;
    end if;
  end loop;

  if has_function_privilege(
       'anon',
       'public.get_period_economics_v109(uuid,date,date,uuid,bigint,text,timestamp with time zone)',
       'EXECUTE'
     ) or not has_function_privilege(
       'authenticated',
       'public.get_period_economics_v109(uuid,date,date,uuid,bigint,text,timestamp with time zone)',
       'EXECUTE'
     ) then
    raise exception 'v109 economics grants are not fail-closed';
  end if;
  if not exists(
    select 1 from app.platform_feature_flags
    where feature_key='economics_driver_policy_v109' and not enabled
  ) then
    raise exception 'v109 feature flag must install disabled';
  end if;
  if(
    select count(distinct parameters->>'minimum_lapse_days')
    from public.sector_policy_versions_v109
    where policy_key='lapse_detection' and status='published'
  )<3 then
    raise exception 'v109 sector registry collapsed to a universal lapse number';
  end if;
  if exists(
    select 1
    from unnest(array[
      'fnb','facial','salon','fitness','retail','massage','other'
    ]) required(sector_key)
    where not exists(
      select 1
      from public.sector_policy_versions_v109 policy
      where policy.sector_key=required.sector_key
        and policy.policy_key='lapse_detection'
        and policy.status='published'
    )
  ) then
    raise exception 'v109 required sector policy coverage is incomplete';
  end if;
  if exists(
    select 1 from public.sector_policy_versions_v109
    where jsonb_array_length(evidence_basis)=0
       or jsonb_array_length(suppression_rules)=0
       or jsonb_array_length(limitations)=0
       or fallback_policy='{}'::jsonb
  ) then
    raise exception 'v109 sector registry lacks evidence/fallback/suppression metadata';
  end if;
end
$contract$;

do $runtime$
declare
  v_sa uuid:=gen_random_uuid();
  v_owner_user uuid:=gen_random_uuid();
  v_staff_user uuid:=gen_random_uuid();
  v_owner_staff uuid:=gen_random_uuid();
  v_staff uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_fallback_business uuid:=gen_random_uuid();
  v_branch uuid:=gen_random_uuid();
  v_client_1 uuid:=gen_random_uuid();
  v_client_2 uuid:=gen_random_uuid();
  v_client_3 uuid:=gen_random_uuid();
  v_service uuid:=gen_random_uuid();
  v_cost_key_1 uuid:=gen_random_uuid();
  v_cost_key_2 uuid:=gen_random_uuid();
  v_service_cost_key uuid:=gen_random_uuid();
  v_override_key uuid:=gen_random_uuid();
  v_refund_event uuid;
  v_refund_sale uuid;
  v_refund_as_of timestamptz;
  v_after_refund timestamptz;
  v_period_prior_start date:='2026-07-01';
  v_period_prior_end date:='2026-07-02';
  v_period_current_start date:='2026-07-08';
  v_period_current_end date:='2026-07-09';
  v_policy_effective timestamptz:=statement_timestamp();
  v_result jsonb;
  v_replay jsonb;
  v_count integer;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) values
  (
    '00000000-0000-0000-0000-000000000000',v_sa,'authenticated',
    'authenticated','v109-sa-'||v_sa||'@example.test','',now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_owner_user,'authenticated',
    'authenticated','v109-owner-'||v_owner_user||'@example.test','',now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_staff_user,'authenticated',
    'authenticated','v109-staff-'||v_staff_user||'@example.test','',now(),now(),now()
  );
  insert into public.super_admins(user_id,email,note)
  values(v_sa,'v109-sa-'||v_sa||'@example.test','v109 rollback fixture');
  insert into public.businesses(
    id,name,slug,currency,industry,enabled_modules,is_synthetic
  ) values
  (
    v_business,'V109 Facial Economics','v109-'||v_business,'SGD','facial',
    array['dashboard','clients','sales','reports','pnl'],true
  ),(
    v_fallback_business,'V109 Unregistered Sector',
    'v109-fallback-'||v_fallback_business,'SGD','pet_grooming',
    array['dashboard','clients','sales','reports','pnl'],true
  );
  insert into public.branches(id,business_id,name,timezone,is_default)
  values(v_branch,v_business,'V109 Singapore','Asia/Singapore',true);
  insert into public.reporting_contract_versions_v106(
    business_id,branch_id,version_no,effective_from,timezone,currency,
    legacy_assumption,created_by
  ) values(
    v_business,v_branch,2,'-infinity'::timestamptz,
    'Asia/Singapore','SGD',true,null
  );

  -- These rollback-only businesses are established synthetic fixtures.
  -- Economics and sector-policy verification must stay independent from
  -- onboarding/subscription concerns and must not reference phantom controls.

  insert into public.staff(
    id,business_id,user_id,role,full_name,email,active
  ) values
  (
    v_owner_staff,v_business,v_owner_user,'owner','V109 Owner',
    'v109-owner-'||v_owner_user||'@example.test',true
  ),(
    v_staff,v_business,v_staff_user,'staff','V109 Frontline Staff',
    'v109-staff-'||v_staff_user||'@example.test',true
  );
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business,v_staff,v_branch);
  insert into public.clients(id,business_id,full_name,is_synthetic)
  values
    (v_client_1,v_business,'V109 Client 1',true),
    (v_client_2,v_business,'V109 Client 2',true),
    (v_client_3,v_business,'V109 Client 3',true);

  -- Comparison: two identified customers with one SGD 10 visit each, plus SGD 5
  -- anonymous. Current: three identified customers with two SGD 10 visits each,
  -- one SGD 3 sale at 00:30 Singapore time (still the current local date), plus
  -- SGD 7 anonymous. Revenue rises from SGD 25 to SGD 70.
  insert into public.sales(
    business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,commission_rate_bps,commission_resolved_at
  ) values
  (v_business,v_client_1,'quick_sale',1000,'2026-07-01 09:00+00','2026-07-01 09:00+00',
    true,true,false,'2026-07-01 09:00+00',v_branch,0,'2026-07-01 09:00+00'),
  (v_business,v_client_2,'quick_sale',1000,'2026-07-01 10:00+00','2026-07-01 10:00+00',
    true,true,false,'2026-07-01 10:00+00',v_branch,0,'2026-07-01 10:00+00'),
  (v_business,null,'quick_sale',500,'2026-07-01 11:00+00','2026-07-01 11:00+00',
    true,true,false,'2026-07-01 11:00+00',v_branch,0,'2026-07-01 11:00+00'),
  (v_business,v_client_1,'quick_sale',1000,'2026-07-08 09:00+00','2026-07-08 09:00+00',
    true,true,false,'2026-07-08 09:00+00',v_branch,0,'2026-07-08 09:00+00'),
  (v_business,v_client_1,'quick_sale',1000,'2026-07-08 09:30+00','2026-07-08 09:30+00',
    true,true,false,'2026-07-08 09:30+00',v_branch,0,'2026-07-08 09:30+00'),
  (v_business,v_client_2,'quick_sale',1000,'2026-07-08 10:00+00','2026-07-08 10:00+00',
    true,true,false,'2026-07-08 10:00+00',v_branch,0,'2026-07-08 10:00+00'),
  (v_business,v_client_2,'quick_sale',1000,'2026-07-08 10:30+00','2026-07-08 10:30+00',
    true,true,false,'2026-07-08 10:30+00',v_branch,0,'2026-07-08 10:30+00'),
  (v_business,v_client_3,'quick_sale',1000,'2026-07-08 11:00+00','2026-07-08 11:00+00',
    true,true,false,'2026-07-08 11:00+00',v_branch,0,'2026-07-08 11:00+00'),
  (v_business,v_client_3,'quick_sale',1000,'2026-07-08 11:30+00','2026-07-08 11:30+00',
    true,true,false,'2026-07-08 11:30+00',v_branch,0,'2026-07-08 11:30+00'),
  (v_business,v_client_1,'quick_sale',300,'2026-07-07 16:30+00','2026-07-07 16:30+00',
    true,true,false,'2026-07-07 16:30+00',v_branch,0,'2026-07-07 16:30+00'),
  (v_business,null,'quick_sale',700,'2026-07-08 12:00+00','2026-07-08 12:00+00',
    true,true,false,'2026-07-08 12:00+00',v_branch,0,'2026-07-08 12:00+00');

  v_result:=app.growth_v108_effective_parameters(v_business);
  if not(v_result->'suppression_reasons' ? 'unknown_service_cadence')
     or (v_result#>>'{source_availability,service_cadence}')::boolean then
    raise exception 'v109 service evidence did not initially fail closed: %',v_result;
  end if;
  insert into public.sale_items(
    sale_id,business_id,item_type,ref_id,description,qty,unit_cents,line_cents
  )
  select sale.id,sale.business_id,'service',v_service,
    'V109 evidence-linked service',1,sale.amount_cents,sale.amount_cents
  from public.sales sale
  where sale.business_id=v_business and sale.client_id is not null
    and sale.occurred_at>='2026-07-08 00:00+00'
  order by sale.occurred_at,sale.id
  limit 3;
  v_result:=app.growth_v108_effective_parameters(v_business);
  if v_result->'suppression_reasons' ? 'unknown_service_cadence'
     or not(v_result#>>'{source_availability,service_cadence}')::boolean
     or (v_result#>>'{source_availability,service_linked_history_count}')::integer<>3 then
    raise exception 'v109 service evidence ingestion did not become available: %',v_result;
  end if;

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_sa::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text,true
  );
  begin
    perform public.get_period_economics_v109(
      v_business,v_period_current_start,v_period_current_end,v_branch
    );
    raise exception 'v109 executed while its feature flag was disabled';
  exception
    when feature_not_supported then null;
  end;
  execute 'reset role';
  update app.platform_feature_flags
  set enabled=true where feature_key='economics_driver_policy_v109';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_sa::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text,true
  );

  v_result:=public.get_period_economics_v109(
    v_business,v_period_current_start,v_period_current_end,v_branch
  );
  if v_result->>'status'<>'insufficient_cost_coverage'
     or v_result->'profit'<>'null'::jsonb
     or v_result->'roi'<>'null'::jsonb
     or not(v_result->'unavailable_reasons'
       ? 'incomplete_traceable_sale_cost_coverage') then
    raise exception 'v109 exposed economics without traceable cost coverage: %',
      v_result;
  end if;

  perform set_config('request.jwt.claim.sub',v_staff_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_staff_user,'role','authenticated')::text,true
  );
  begin
    perform public.set_effective_cost_rule_v109(
      v_business,v_branch,'sale_kind','quick_sale','revenue_bps',4000,
      'supplier_invoice','INV-V109-001','{"fixture":true}'::jsonb,
      '2026-06-01 00:00+00',v_cost_key_1
    );
    raise exception 'v109 non-finance staff changed a cost rule';
  exception
    when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub',v_owner_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_owner_user,'role','authenticated')::text,true
  );
  v_result:=public.set_effective_cost_rule_v109(
    v_business,v_branch,'sale_kind','quick_sale','revenue_bps',4000,
    'supplier_invoice','INV-V109-001',
    '{"fixture":true,"currency":"SGD"}'::jsonb,
    '2026-06-01 00:00+00',v_cost_key_1
  );
  v_replay:=public.set_effective_cost_rule_v109(
    v_business,v_branch,'sale_kind','quick_sale','revenue_bps',4000,
    'supplier_invoice','INV-V109-001',
    '{"fixture":true,"currency":"SGD"}'::jsonb,
    '2026-06-01 00:00+00',v_cost_key_1
  );
  if (v_result->>'replayed')::boolean
     or (v_replay->>'replayed')::boolean
     or v_result->>'rule_id'<>v_replay->>'rule_id' then
    raise exception 'v112 exact-receipt cost-rule idempotency failed: first %, replay %',
      v_result,v_replay;
  end if;
  -- v114 deliberately stops applying a generic sale-kind fallback to itemized
  -- rows.  When this older regression is run against the latest schema, give
  -- its three evidence-linked service lines the same traceable 40% rule so the
  -- original v109 arithmetic remains comparable.  Through v109 itself the
  -- parent sale-kind rule remains the applicable contract.
  if to_regprocedure(
       'public.set_growth_cost_rule_v114(uuid,uuid,text,text,text,bigint,text,text,jsonb,timestamp with time zone,uuid)'
     ) is not null then
    perform public.set_effective_cost_rule_v109(
      v_business,v_branch,'service',v_service::text,'revenue_bps',4000,
      'supplier_invoice','INV-V109-SERVICE-001',
      '{"fixture":true,"currency":"SGD","latest_schema_compatibility":true}'::jsonb,
      '2026-06-01 00:00+00',v_service_cost_key
    );
  end if;

  v_result:=public.get_period_economics_v109(
    v_business,v_period_current_start,v_period_current_end,v_branch,1000,
    'campaign-ledger-v109'
  );
  if v_result->>'status'<>'ready'
     or (v_result#>>'{coverage,eligible_sales}')::integer<>8
     or (v_result#>>'{coverage,covered_sales}')::integer<>8
     or (v_result#>>'{coverage,transaction_coverage_bps}')::integer<>10000
     or (v_result#>>'{coverage,revenue_coverage_bps}')::integer<>10000
     or (v_result#>>'{profit,revenue_cents}')::bigint<>7000
     or (v_result#>>'{profit,traceable_cogs_cents}')::bigint<>2800
     or (v_result#>>'{profit,gross_profit_cents}')::bigint<>4200
     or (v_result#>>'{roi,net_return_cents}')::bigint<>3200
     or (v_result#>>'{roi,return_on_investment_bps}')::bigint<>32000 then
    raise exception 'v109 covered economics math failed: %',v_result;
  end if;
  v_result:=public.get_period_economics_v109(
    v_business,v_period_current_start,v_period_current_end,v_branch,0,
    'campaign-ledger-v109'
  );
  if v_result->'profit'='null'::jsonb
     or v_result->'roi'<>'null'::jsonb
     or not(v_result->'unavailable_reasons'
       ? 'positive_traceable_investment_required') then
    raise exception 'v109 zero-investment ROI did not fail closed: %',v_result;
  end if;

  v_result:=public.set_effective_cost_rule_v109(
    v_business,v_branch,'sale_kind','quick_sale','revenue_bps',5000,
    'supplier_contract','CONTRACT-V109-002','{"fixture":true}'::jsonb,
    '2026-08-01 00:00+00',v_cost_key_2
  );
  v_replay:=public.set_effective_cost_rule_v109(
    v_business,v_branch,'sale_kind','quick_sale','revenue_bps',5000,
    'supplier_contract','CONTRACT-V109-002','{"fixture":true}'::jsonb,
    '2026-08-01 00:00+00',v_cost_key_2
  );
  execute 'reset role';
  select count(*) into v_count
  from public.economic_cost_rules_v109
  where business_id=v_business and branch_id=v_branch
    and scope_kind='sale_kind' and scope_key='quick_sale';
  if v_count<>2 or (v_result->>'version_no')::integer<>2
     or (v_replay->>'replayed')::boolean
     or not exists(
       select 1 from public.economic_cost_rules_v109
       where business_id=v_business and version_no=1
         and effective_to='2026-08-01 00:00+00'
  ) then
    raise exception 'v109 effective-dated cost versions failed';
  end if;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_owner_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_owner_user,'role','authenticated')::text,true
  );
  v_result:=public.get_period_economics_v109(
    v_business,v_period_current_start,v_period_current_end,v_branch
  );
  if (v_result#>>'{profit,traceable_cogs_cents}')::bigint<>2800 then
    raise exception 'v109 later cost version changed historical economics: %',
      v_result;
  end if;

  v_result:=public.get_revenue_driver_decomposition_v109(
    v_business,v_period_current_start,v_period_current_end,
    v_period_prior_start,v_period_prior_end,v_branch
  );
  if v_result->>'status'<>'ready'
     or (v_result#>>'{drivers,identified_customer_count_cents}')::bigint<>1000
     or (v_result#>>'{drivers,purchase_frequency_cents}')::bigint<>4000
     or (v_result#>>'{drivers,average_transaction_value_cents}')::bigint<>-700
     or (v_result#>>'{drivers,anonymous_revenue_cents}')::bigint<>200
     or (v_result#>>'{reconciliation,period_revenue_delta_cents}')::bigint<>4500
     or (v_result#>>'{reconciliation,sum_driver_contributions_cents}')::bigint<>4500
     or not(v_result#>>'{reconciliation,reconciles}')::boolean
     or (v_result#>>'{method,causal_claim}')::boolean then
    raise exception 'v109 driver decomposition did not reconcile: %',v_result;
  end if;
  v_result:=public.get_revenue_driver_decomposition_v109(
    v_business,v_period_current_start,v_period_current_end,
    '2026-06-01','2026-06-02',v_branch
  );
  if v_result->>'status'<>'unavailable'
     or v_result->>'unavailable_reason'<>'comparison_period_has_no_revenue'
     or v_result->'drivers'<>'null'::jsonb then
    raise exception 'v109 driver unavailable state drifted: %',v_result;
  end if;

  select sale.id into strict v_refund_sale
  from public.sales sale
  where sale.business_id=v_business and sale.client_id=v_client_1
    and sale.amount_cents=1000 and sale.occurred_at='2026-07-08 09:00+00'
  limit 1;
  v_refund_as_of:=clock_timestamp();
  v_result:=public.ingest_external_commerce_event_v106(
    v_business,v_branch,'refund_completed','v109.test.pos',
    'refund-current-1','refund-current-idem-1','2026-07-08 09:05+00',
    'SGD',-300,'{"fixture":"v109-partial-refund"}'::jsonb
  );
  v_refund_event:=(v_result->>'event_id')::uuid;
  perform public.reconcile_external_commerce_event_v106(
    v_refund_event,v_refund_sale,'v109-refund-reconcile-1',
    jsonb_build_array(jsonb_build_object('amount_minor',300))
  );
  v_after_refund:=clock_timestamp();
  v_result:=public.get_period_economics_v109(
    v_business,v_period_current_start,v_period_current_end,v_branch,
    null,null,v_refund_as_of
  );
  if (v_result#>>'{profit,revenue_cents}')::bigint<>7000 then
    raise exception 'v109 as-of cutoff leaked a later refund allocation: %',v_result;
  end if;
  v_result:=public.get_period_economics_v109(
    v_business,v_period_current_start,v_period_current_end,v_branch,
    null,null,v_after_refund
  );
  if (v_result#>>'{profit,revenue_cents}')::bigint<>6700
     or (v_result#>>'{profit,traceable_cogs_cents}')::bigint<>2680 then
    raise exception 'v109 economics ignored a reconciled partial refund: %',v_result;
  end if;
  v_result:=public.get_revenue_driver_decomposition_v109(
    v_business,v_period_current_start,v_period_current_end,
    v_period_prior_start,v_period_prior_end,v_branch,v_after_refund
  );
  if (v_result#>>'{reconciliation,period_revenue_delta_cents}')::bigint<>4200
     or not(v_result#>>'{reconciliation,reconciles}')::boolean then
    raise exception 'v109 drivers did not reconcile after a partial refund: %',v_result;
  end if;

  v_result:=public.get_effective_sector_policy_v109(
    v_business,'lapse_detection',v_policy_effective
  );
  if v_result->>'requested_sector'<>'facial'
     or v_result->>'resolved_sector'<>'facial'
     or (v_result->>'used_fallback_sector')::boolean
     or v_result->'universal_churn_number'<>'null'::jsonb
     or jsonb_array_length(v_result#>'{base_policy,evidence_basis}')=0
     or jsonb_array_length(v_result#>'{base_policy,suppression_rules}')=0 then
    raise exception 'v109 facial policy metadata failed: %',v_result;
  end if;
  begin
    perform public.set_business_sector_policy_override_v109(
      v_business,'lapse_detection',
      '{"minimum_lapse_days":null}'::jsonb,
      'Null values must fail closed',v_policy_effective,gen_random_uuid()
    );
    raise exception 'v109 accepted a JSON-null sector override';
  exception
    when invalid_parameter_value then null;
  end;
  v_result:=public.set_business_sector_policy_override_v109(
    v_business,'lapse_detection',
    '{"minimum_lapse_days":45,"cadence_multiplier":1.8}'::jsonb,
    'Owner reviewed treatment cadence',v_policy_effective,v_override_key
  );
  v_replay:=public.set_business_sector_policy_override_v109(
    v_business,'lapse_detection',
    '{"minimum_lapse_days":45,"cadence_multiplier":1.8}'::jsonb,
    'Owner reviewed treatment cadence',v_policy_effective,v_override_key
  );
  if (v_result->>'replayed')::boolean
     or (v_replay->>'replayed')::boolean
     or v_result->>'override_id'<>v_replay->>'override_id' then
    raise exception 'v112 exact-receipt sector override idempotency failed: %, %',
      v_result,v_replay;
  end if;
  v_result:=public.get_effective_sector_policy_v109(
    v_business,'lapse_detection',v_policy_effective
  );
  if (v_result#>>'{effective_parameters,minimum_lapse_days}')::integer<>45
     or (v_result#>>'{effective_parameters,cadence_multiplier}')::numeric<>1.8
     or v_result#>'{owner_override}'='null'::jsonb then
    raise exception 'v109 effective owner override did not resolve: %',v_result;
  end if;
  execute 'reset role';
  if not exists(
    select 1 from public.audit_log
    where business_id=v_business and actor=v_owner_user
      and action='SET_EFFECTIVE_COST_RULE_V109'
  ) or not exists(
    select 1 from public.audit_log
    where business_id=v_business and actor=v_owner_user
      and action='SET_SECTOR_POLICY_OVERRIDE_V109'
  ) then
    raise exception 'v109 finance/policy mutations were not audited';
  end if;

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_sa::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text,true
  );
  v_result:=public.get_effective_sector_policy_v109(
    v_fallback_business,'lapse_detection',v_policy_effective
  );
  if v_result->>'requested_sector'<>'pet_grooming'
     or v_result->>'resolved_sector'<>'other'
     or not(v_result->>'used_fallback_sector')::boolean
     or v_result->'universal_churn_number'<>'null'::jsonb then
    raise exception 'v109 explicit sector fallback failed: %',v_result;
  end if;

  perform set_config('request.jwt.claim.sub',v_staff_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_staff_user,'role','authenticated')::text,true
  );
  begin
    perform public.get_period_economics_v109(
      v_business,v_period_current_start,v_period_current_end,v_branch
    );
    raise exception 'v109 non-finance staff read economics';
  exception
    when insufficient_privilege then null;
  end;
  begin
    perform public.set_business_sector_policy_override_v109(
      v_business,'lapse_detection','{"minimum_lapse_days":60}'::jsonb,
      'unauthorized fixture',v_policy_effective+interval '1 day',gen_random_uuid()
    );
    raise exception 'v109 non-owner changed the sector policy';
  exception
    when insufficient_privilege then null;
  end;
  execute 'reset role';

  update public.businesses set currency='USD' where id=v_business;
  insert into public.sales(
    business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,commission_rate_bps,commission_resolved_at
  ) values(
    v_business,v_client_1,'quick_sale',1000,clock_timestamp(),clock_timestamp(),
    true,true,false,clock_timestamp(),v_branch,0,clock_timestamp()
  );
  v_after_refund:=clock_timestamp();
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_owner_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_owner_user,'role','authenticated')::text,true
  );
  begin
    perform public.get_period_economics_v109(
      v_business,'2026-07-01','2026-08-01',v_branch,null,null,v_after_refund
    );
    raise exception 'v109 economics combined historical currencies';
  exception
    when invalid_parameter_value then null;
  end;
  begin
    perform public.get_revenue_driver_decomposition_v109(
      v_business,'2026-07-01','2026-08-01',
      '2026-06-01','2026-07-01',v_branch,v_after_refund
    );
    raise exception 'v109 drivers combined historical currencies';
  exception
    when invalid_parameter_value then null;
  end;
  execute 'reset role';
end
$runtime$;

select 'V109 SUITE PASS' as result;
rollback;
