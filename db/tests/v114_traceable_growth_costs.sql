-- Rollback-only v114 traceable benefit and delivery economics.
-- Run after the canonical chain through v114 in a disposable database.
begin;

create or replace function pg_temp.approve_workspace_v94(p_business uuid)
returns void language sql as $$
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,
         decided_at=statement_timestamp(),
         decision_reason='approved synthetic rollback fixture',
         updated_at=statement_timestamp()
   where business_id=p_business and approval_status='pending'
$$;

do $contract$
begin
  if to_regclass('public.growth_cost_rules_v114') is null
     or to_regprocedure(
       'public.set_growth_cost_rule_v114(uuid,uuid,text,text,text,bigint,text,text,jsonb,timestamp with time zone,uuid)'
     ) is null then
    raise exception 'v114 growth-cost contract is incomplete';
  end if;
  if not exists (
    select 1
    from pg_catalog.pg_class class_row
    join pg_catalog.pg_namespace namespace_row
      on namespace_row.oid=class_row.relnamespace
    where namespace_row.nspname='public'
      and class_row.relname='growth_cost_rules_v114'
      and class_row.relrowsecurity
  ) then
    raise exception 'v114 growth-cost rules do not enforce RLS';
  end if;
  if has_table_privilege(
       'authenticated','public.growth_cost_rules_v114','INSERT'
     ) or has_table_privilege(
       'authenticated','public.growth_cost_rules_v114','UPDATE'
     ) or has_table_privilege(
       'authenticated','public.growth_cost_rules_v114','DELETE'
     ) then
    raise exception 'authenticated can mutate v114 rules directly';
  end if;
  if has_function_privilege(
       'anon',
       'public.set_growth_cost_rule_v114(uuid,uuid,text,text,text,bigint,text,text,jsonb,timestamp with time zone,uuid)',
       'EXECUTE'
     ) or not has_function_privilege(
       'authenticated',
       'public.set_growth_cost_rule_v114(uuid,uuid,text,text,text,bigint,text,text,jsonb,timestamp with time zone,uuid)',
       'EXECUTE'
     ) then
    raise exception 'v114 writer grants are not fail-closed';
  end if;
end
$contract$;

do $runtime$
declare
  v_owner_user uuid:=gen_random_uuid();
  v_customer_user uuid:=gen_random_uuid();
  v_owner_staff uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_branch uuid:=gen_random_uuid();
  v_client uuid:=gen_random_uuid();
  v_identity uuid:=gen_random_uuid();
  v_link uuid:=gen_random_uuid();
  v_sale uuid:=gen_random_uuid();
  v_recommendation uuid:=gen_random_uuid();
  v_recommendation_member uuid:=gen_random_uuid();
  v_execution uuid:=gen_random_uuid();
  v_execution_member uuid:=gen_random_uuid();
  v_delivery uuid:=gen_random_uuid();
  v_dispatch uuid;
  v_entitlement uuid:=gen_random_uuid();
  v_post_period_reversal uuid:=gen_random_uuid();
  v_in_period_reversal uuid:=gen_random_uuid();
  v_sale_cost_key uuid:=gen_random_uuid();
  v_benefit_cost_key uuid:=gen_random_uuid();
  v_delivery_cost_key uuid:=gen_random_uuid();
  v_result jsonb;
  v_replay jsonb;
  v_copy jsonb;
  v_before jsonb;
  v_after jsonb;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_owner_user,
    'authenticated','authenticated',
    'v114-owner-'||v_owner_user||'@example.test','',now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_customer_user,
    'authenticated','authenticated',
    'v114-customer-'||v_customer_user||'@example.test','',now(),now(),now()
  );
  insert into public.businesses(
    id,name,slug,currency,industry,enabled_modules,is_synthetic
  ) values (
    v_business,'V114 Traceable Growth Costs','v114-'||v_business,
    'SGD','facial',
    array[
      'dashboard','clients','till','sales','reports','pnl',
      'loyalty','retention'
    ],
    true
  );
  perform pg_temp.approve_workspace_v94(v_business);
  insert into public.branches(id,business_id,name,timezone,is_default)
  values(v_branch,v_business,'V114 Singapore','Asia/Singapore',true);
  insert into public.reporting_contract_versions_v106(
    business_id,branch_id,version_no,effective_from,timezone,currency,
    legacy_assumption,created_by
  ) values (
    v_business,v_branch,2,'-infinity'::timestamptz,
    'Asia/Singapore','SGD',true,null
  );
  insert into public.staff(
    id,business_id,user_id,role,full_name,email,active
  ) values (
    v_owner_staff,v_business,v_owner_user,'owner','V114 Owner',
    'v114-owner-'||v_owner_user||'@example.test',true
  );
  insert into public.clients(
    id,business_id,full_name,email,marketing_consent,is_synthetic
  ) values (
    v_client,v_business,'V114 Customer',
    'v114-customer@example.test',true,true
  );
  insert into public.customer_identities(
    id,auth_user_id,status,created_via
  ) values(v_identity,v_customer_user,'active','phone_registration');
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values (
    v_link,v_business,v_identity,v_customer_user,v_client,'verified',
    'qr_join','2026-07-01 00:00+00'
  );
  perform set_config('app.customer_link_insert_id','',true);

  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,commission_rate_bps,commission_resolved_at,qty
  ) values (
    v_sale,v_business,v_client,'quick_sale',1000,
    '2026-07-30 02:00+00','2026-07-30 02:00+00',
    true,true,false,'2026-07-30 02:00+00',
    v_branch,0,'2026-07-30 02:00+00',1
  );

  insert into public.growth_recommendations_v108(
    id,business_id,branch_id,recommendation_type,policy_version,
    generated_at,valid_until,observation_start,observation_end,
    comparison_start,comparison_end,finding,supporting_evidence,
    baseline,opportunity,expected_incremental_revenue,
    expected_incremental_gross_profit,confidence,assumptions,
    recommended_action,recommended_channel,recommended_offer,
    estimated_cost_cents,audience_size,excluded_size,frequency_cap_days,
    approval_required,success_metric,attribution_window_days,
    holdout_percent,stop_conditions,status,suppression_reasons,
    data_freshness_at,data_coverage,dedupe_key,created_by
  ) values (
    v_recommendation,v_business,v_branch,
    'lapsed_high_value_bring_back','bring_back_v1',
    '2026-07-29 00:00+00','2026-07-31 00:00+00',
    '2026-01-01 00:00+00','2026-07-29 00:00+00',
    '2025-07-01 00:00+00','2025-12-31 00:00+00',
    'V114 rollback-only evidence','[]'::jsonb,'{}'::jsonb,'{}'::jsonb,
    '{}'::jsonb,null,'{}'::jsonb,'[]'::jsonb,'{}'::jsonb,
    'in_app','{}'::jsonb,300,1,0,30,true,
    'incremental_completed_purchase_revenue',14,20,'{}'::jsonb,
    'executed','[]'::jsonb,'2026-07-29 00:00+00','{}'::jsonb,
    encode(
      extensions.digest(convert_to(v_recommendation::text,'UTF8'),'sha256'),
      'hex'
    ),
    v_owner_user
  );
  insert into public.growth_recommendation_members_v108(
    id,recommendation_id,business_id,client_id,eligible,prior_visits,
    last_visit_at,cadence_days,lapse_days,average_transaction_cents,
    historical_revenue_cents,evidence
  ) values (
    v_recommendation_member,v_recommendation,v_business,v_client,true,3,
    '2026-05-01 00:00+00',14,60,1000,3000,'{}'::jsonb
  );
  v_copy:=jsonb_build_object(
    'schema','nestly.growth_offer_copy','version',1,
    'title','A reward is ready','body','Enjoy SGD 3.00 off.',
    'cta_label','Redeem now',
    'cta_destination','customer_growth_offer_qr',
    'eligibility',jsonb_build_object(
      'business_id',v_business,'branch_id',v_branch
    ),
    'conditions',jsonb_build_object(
      'expires_at','2026-08-06 00:00+00'::timestamptz,
      'timezone','Asia/Singapore'
    ),
    'locked_facts',jsonb_build_object(
      'template_id','member_thank_you','offer_value_cents',300,
      'currency','SGD',
      'expires_at','2026-08-06 00:00+00'::timestamptz,
      'timezone','Asia/Singapore'
    )
  );
  insert into public.growth_executions_v108(
    id,recommendation_id,business_id,branch_id,channel,offer_type,
    offer_value_cents,offer_label,currency,offer_timezone,offer_expires_at,
    governed_copy_schema,governed_copy_version,governed_copy,
    budget_cap_cents,holdout_percent,attribution_window_days,
    minimum_arm_size,status,approved_by,approved_at,started_at,ends_at,
    idempotency_key,request_hash
  ) values (
    v_execution,v_recommendation,v_business,v_branch,'in_app',
    'credit_cents',300,'member_thank_you','SGD','Asia/Singapore',
    '2026-08-06 00:00+00','nestly.growth_offer_copy',1,v_copy,
    300,20,14,3,'running',v_owner_user,'2026-07-29 00:00+00',
    '2026-07-29 00:00+00','2026-08-12 00:00+00',
    gen_random_uuid(),repeat('a',64)
  );
  insert into public.growth_execution_members_v108(
    id,execution_id,business_id,recommendation_member_id,client_id,
    assignment,assignment_rank,assignment_score
  ) values (
    v_execution_member,v_execution,v_business,v_recommendation_member,
    v_client,'treatment',1,repeat('b',64)
  );
  insert into public.growth_deliveries_v108(
    id,execution_id,execution_member_id,business_id,client_id,
    identity_id,link_id,assignment,channel,delivery_status,
    title,body,estimated_cost_cents,delivered_at
  ) values (
    v_delivery,v_execution,v_execution_member,v_business,v_client,
    v_identity,v_link,'treatment','in_app','delivered',
    'V114 delivery','V114 delivery body',300,'2026-07-30 01:00+00'
  );
  select id into strict v_dispatch
  from public.growth_delivery_dispatches_v110
  where delivery_id=v_delivery;
  perform app.v110_transition_delivery(
    v_dispatch,'delivering',null,null,gen_random_uuid(),
    '{"worker_id":"v114-fixture"}'::jsonb
  );
  perform app.v110_transition_delivery(
    v_dispatch,'delivered',null,'v114-provider-message',gen_random_uuid(),
    '{"worker_id":"v114-fixture"}'::jsonb
  );
  perform set_config('app.growth_delivery_v110_transition','on',true);
  update public.growth_delivery_dispatches_v110
  set claimed_at='2026-07-30 00:59+00',
      delivered_at='2026-07-30 01:00+00',
      updated_at='2026-07-30 01:00+00'
  where id=v_dispatch;
  update public.growth_deliveries_v108
  set delivered_at='2026-07-30 01:00+00'
  where id=v_delivery;
  perform set_config('app.growth_delivery_v110_transition','',true);
  insert into public.growth_entitlements_v108(
    id,delivery_id,execution_id,business_id,client_id,identity_id,
    entitlement_type,value_cents,estimated_cost_cents,status,issued_at,
    expires_at,redeemed_at,redeemed_sale_id
  ) values (
    v_entitlement,v_delivery,v_execution,v_business,v_client,v_identity,
    'credit_cents',300,300,'redeemed','2026-07-30 01:00+00',
    '2026-08-06 00:00+00','2026-07-30 02:00+00',v_sale
  );

  update app.platform_feature_flags
  set enabled=true
  where feature_key in ('growth_closed_loop_v108','economics_driver_policy_v109');
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_owner_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_owner_user,'role','authenticated')::text,true
  );

  perform public.set_effective_cost_rule_v109(
    v_business,v_branch,'sale_kind','quick_sale','revenue_bps',4000,
    'supplier_invoice','V114-SALE-001','{"fixture":true}'::jsonb,
    '2026-07-01 00:00+00',v_sale_cost_key
  );
  v_result:=public.get_period_economics_v109(
    v_business,'2026-07-30','2026-07-31',v_branch,
    null,null,'2026-07-30 12:00+00'
  );
  if v_result->>'status'<>'insufficient_cost_coverage'
     or not(v_result->'unavailable_reasons'
       ? 'incomplete_traceable_benefit_cost_coverage')
     or not(v_result->'unavailable_reasons'
       ? 'incomplete_traceable_delivery_cost_coverage')
     or v_result->'profit'<>'null'::jsonb then
    raise exception 'v114 exposed economics before all growth costs: %',
      v_result;
  end if;

  v_result:=public.set_growth_cost_rule_v114(
    v_business,v_branch,'benefit','credit_cents','fixed_per_event',200,
    'supplier_invoice','V114-BENEFIT-001','{"fixture":true}'::jsonb,
    '2026-07-01 00:00+00',v_benefit_cost_key
  );
  if (v_result->>'version_no')::integer<>1
     or (v_result->>'replayed')::boolean then
    raise exception 'v114 benefit cost write failed: %',v_result;
  end if;
  v_replay:=public.set_growth_cost_rule_v114(
    v_business,v_branch,'benefit','credit_cents','fixed_per_event',200,
    'supplier_invoice','V114-BENEFIT-001','{"fixture":true}'::jsonb,
    '2026-07-01 00:00+00',v_benefit_cost_key
  );
  if v_replay is distinct from v_result
     or (v_replay->>'replayed')::boolean then
    raise exception 'v114 identical replay changed its receipt: % / %',
      v_result,v_replay;
  end if;
  begin
    perform public.set_growth_cost_rule_v114(
      v_business,v_branch,'benefit','credit_cents','fixed_per_event',201,
      'supplier_invoice','V114-BENEFIT-001','{"fixture":true}'::jsonb,
      '2026-07-01 00:00+00',v_benefit_cost_key
    );
    raise exception 'v114 changed-payload idempotency reuse succeeded';
  exception
    when unique_violation then null;
  end;
  perform public.set_growth_cost_rule_v114(
    v_business,v_branch,'delivery','in_app','fixed_per_event',10,
    'provider_invoice','V114-DELIVERY-001','{"fixture":true}'::jsonb,
    '2026-07-01 00:00+00',v_delivery_cost_key
  );

  v_result:=public.get_period_economics_v109(
    v_business,'2026-07-30','2026-07-31',v_branch,
    null,null,'2026-07-30 12:00+00'
  );
  if v_result->>'status'<>'ready'
     or not(v_result#>>'{coverage,traceable_cost_coverage_passes}')::boolean
     or (v_result#>>'{coverage,eligible_redeemed_benefits}')::integer<>1
     or (v_result#>>'{coverage,covered_redeemed_benefits}')::integer<>1
     or (v_result#>>'{coverage,eligible_deliveries}')::integer<>1
     or (v_result#>>'{coverage,covered_deliveries}')::integer<>1
     or (v_result#>>'{profit,traceable_cogs_cents}')::bigint<>400
     or (v_result#>>'{profit,traceable_benefit_cost_cents}')::bigint<>200
     or (v_result#>>'{profit,traceable_delivery_cost_cents}')::bigint<>10
     or (v_result#>>'{profit,contribution_after_growth_costs_cents}')::bigint<>390
     or (v_result#>>'{roi,traceable_growth_investment_cents}')::bigint<>210 then
    raise exception 'v114 period economics did not consume exact costs: %',
      v_result;
  end if;

  -- The real reversal-sale trigger stamps entitlement.reversed_at with wall
  -- clock time.  Reporting must instead use the linked reversal sale's
  -- effective business date.  This subtransaction proves a post-period
  -- reversal without retaining it, then the next journey proves in-period.
  v_before:=public.get_period_economics_v109(
    v_business,'2026-07-30','2026-07-31',v_branch,
    null,null,'2026-08-02 00:00+00'
  );
  execute 'reset role';
  begin
    perform set_config(
      'app.sale_reversal_insert_id',v_post_period_reversal::text,true
    );
    perform set_config(
      'app.sale_reversal_original_id',v_sale::text,true
    );
    insert into public.sales(
      id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
      counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
      branch_id,commission_rate_bps,commission_resolved_at,qty,
      reversal_of,reversal_reason,reversal_actor,reversal_idempotency_key
    ) values (
      v_post_period_reversal,v_business,v_client,'quick_sale',-1000,
      '2026-08-01 01:00+00','2026-08-01 01:00+00',
      true,false,false,'2026-08-01 01:00+00',
      v_branch,0,'2026-08-01 01:00+00',1,
      v_sale,'V114 post-period entitlement reversal',v_owner_user,
      'v114-entitlement-post-period'
    );
    perform set_config('app.sale_reversal_insert_id','',true);
    perform set_config('app.sale_reversal_original_id','',true);
    execute 'set local role authenticated';
    perform set_config('request.jwt.claim.sub',v_owner_user::text,true);
    perform set_config(
      'request.jwt.claims',
      json_build_object('sub',v_owner_user,'role','authenticated')::text,true
    );
    v_after:=public.get_period_economics_v109(
      v_business,'2026-07-30','2026-07-31',v_branch,
      null,null,'2026-08-02 00:00+00'
    );
    if v_after is distinct from v_before then
      raise exception
        'v114 post-period entitlement reversal rewrote prior economics: % / %',
        v_before,v_after;
    end if;
    execute 'reset role';
    raise sqlstate 'ZX001';
  exception when sqlstate 'ZX001' then
    null;
  end;

  perform set_config(
    'app.sale_reversal_insert_id',v_in_period_reversal::text,true
  );
  perform set_config('app.sale_reversal_original_id',v_sale::text,true);
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,commission_rate_bps,commission_resolved_at,qty,
    reversal_of,reversal_reason,reversal_actor,reversal_idempotency_key
  ) values (
    v_in_period_reversal,v_business,v_client,'quick_sale',-1000,
    '2026-07-30 03:00+00','2026-07-30 03:00+00',
    true,false,false,'2026-07-30 03:00+00',
    v_branch,0,'2026-07-30 03:00+00',1,
    v_sale,'V114 in-period entitlement reversal',v_owner_user,
    'v114-entitlement-in-period'
  );
  perform set_config('app.sale_reversal_insert_id','',true);
  perform set_config('app.sale_reversal_original_id','',true);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_owner_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_owner_user,'role','authenticated')::text,true
  );
  v_after:=public.get_period_economics_v109(
    v_business,'2026-07-30','2026-07-31',v_branch,
    null,null,'2026-08-02 00:00+00'
  );
  if v_after->>'status'<>'no_data'
     or (v_after#>>'{coverage,eligible_redeemed_benefits}')::integer<>0
     or (v_after#>>'{coverage,covered_redeemed_benefits}')::integer<>0
     or not(v_after->'unavailable_reasons' ? 'no_eligible_sales')
     or v_after->'profit'<>'null'::jsonb
     or v_after->'roi'<>'null'::jsonb then
    raise exception
      'v114 in-period entitlement reversal retained benefit economics: %',
      v_after;
  end if;
  execute 'reset role';
end
$runtime$;

do $sale_line_economics$
declare
  v_owner_user uuid:=gen_random_uuid();
  v_owner_staff uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_branch uuid:=gen_random_uuid();
  v_discount_branch uuid:=gen_random_uuid();
  v_client uuid:=gen_random_uuid();
  v_service uuid:=gen_random_uuid();
  v_product uuid:=gen_random_uuid();
  v_discount_product uuid:=gen_random_uuid();
  v_package uuid:=gen_random_uuid();
  v_ambiguous_product uuid:=gen_random_uuid();
  v_mixed_sale uuid:=gen_random_uuid();
  v_discount_sale uuid:=gen_random_uuid();
  v_native_sale uuid:=gen_random_uuid();
  v_native_reversal uuid:=gen_random_uuid();
  v_missing_sale uuid:=gen_random_uuid();
  v_ambiguous_sale uuid:=gen_random_uuid();
  v_refund_event uuid;
  v_result jsonb;
  v_before jsonb;
  v_after jsonb;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_owner_user,
    'authenticated','authenticated',
    'v114-lines-'||v_owner_user||'@example.test','',now(),now(),now()
  );
  insert into public.businesses(
    id,name,slug,currency,industry,enabled_modules,is_synthetic
  ) values (
    v_business,'V114 Mixed Line Economics','v114-lines-'||v_business,
    'SGD','facial',
    array[
      'dashboard','clients','till','sales','reports','pnl','services',
      'packages','inventory'
    ],
    true
  );
  perform pg_temp.approve_workspace_v94(v_business);
  insert into public.branches(id,business_id,name,timezone,is_default)
  values(v_branch,v_business,'V114 Lines Singapore','Asia/Singapore',true);
  insert into public.branches(id,business_id,name,timezone,is_default)
  values(
    v_discount_branch,v_business,'V114 Discount Singapore',
    'Asia/Singapore',false
  );
  insert into public.reporting_contract_versions_v106(
    business_id,branch_id,version_no,effective_from,timezone,currency,
    legacy_assumption,created_by
  ) values
  (
    v_business,v_branch,2,'-infinity'::timestamptz,
    'Asia/Singapore','SGD',true,null
  ),(
    v_business,v_discount_branch,2,'-infinity'::timestamptz,
    'Asia/Singapore','SGD',true,null
  );
  insert into public.staff(
    id,business_id,user_id,role,full_name,email,active
  ) values (
    v_owner_staff,v_business,v_owner_user,'owner','V114 Line Owner',
    'v114-lines-'||v_owner_user||'@example.test',true
  );
  insert into public.clients(
    id,business_id,full_name,email,marketing_consent,is_synthetic
  ) values (
    v_client,v_business,'V114 Mixed Cart Customer',
    'v114-lines-customer@example.test',true,true
  );
  insert into public.services(
    id,business_id,name,price_cents,duration_min
  ) values(v_service,v_business,'V114 Traceable Service',4000,60);
  insert into public.products(
    id,business_id,name,sku,retail_price_cents
  ) values
    (v_product,v_business,'V114 Traceable Product','V114-PRODUCT',3000),
    (
      v_discount_product,v_business,'V114 Discounted Product',
      'V114-DISCOUNTED',10000
    ),
    (
      v_ambiguous_product,v_business,'V114 Ambiguous Product',
      'V114-AMBIGUOUS',700
    );
  insert into public.package_plans(
    id,business_id,name,price_cents,sessions,service_id
  ) values(
    v_package,v_business,'V114 Traceable Package',3000,1,v_service
  );

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_owner_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_owner_user,'role','authenticated')::text,true
  );
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,commission_rate_bps,commission_resolved_at,qty
  ) values
    (
      v_discount_sale,v_business,v_client,'quick_sale',8000,
      '2026-07-30 02:15+00','2026-07-30 02:15+00',
      true,true,false,'2026-07-30 02:15+00',
      v_discount_branch,0,'2026-07-30 02:15+00',1
    ),
    (
      v_mixed_sale,v_business,v_client,'package',10000,
      '2026-07-30 02:00+00','2026-07-30 02:00+00',
      true,true,false,'2026-07-30 02:00+00',
      v_branch,0,'2026-07-30 02:00+00',1
    ),
    (
      v_native_sale,v_business,v_client,'quick_sale',2000,
      '2026-07-30 02:30+00','2026-07-30 02:30+00',
      true,true,false,'2026-07-30 02:30+00',
      v_branch,0,'2026-07-30 02:30+00',1
    );
  execute 'reset role';
  insert into public.sale_items(
    sale_id,business_id,item_type,ref_id,description,qty,
    unit_cents,line_cents,product_id
  ) values
    (
      v_discount_sale,v_business,'retail',v_discount_product,
      'Gross product line',1,10000,10000,v_discount_product
    ),
    (
      v_discount_sale,v_business,'studio_discount',gen_random_uuid(),
      'Discount: NDP 20 percent',1,-2000,-2000,null
    ),
    (
      v_mixed_sale,v_business,'retail',v_product,'Product line',1,
      3000,3000,v_product
    ),
    (
      v_mixed_sale,v_business,'service',v_service,'Service line',1,
      4000,4000,null
    ),
    (
      v_mixed_sale,v_business,'package',v_package,'Package line',1,
      3000,3000,null
    );

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_owner_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_owner_user,'role','authenticated')::text,true
  );
  perform public.set_effective_cost_rule_v109(
    v_business,v_branch,'product',v_product::text,'revenue_bps',5000,
    'supplier_invoice','V114-LINE-PRODUCT','{"fixture":true}'::jsonb,
    '2026-07-01 00:00+00',gen_random_uuid()
  );
  perform public.set_effective_cost_rule_v109(
    v_business,v_discount_branch,'product',v_discount_product::text,
    'fixed_per_unit',4000,
    'supplier_invoice','V114-DISCOUNTED-FIXED-COGS',
    '{"fixture":true}'::jsonb,
    '2026-07-01 00:00+00',gen_random_uuid()
  );
  perform public.set_effective_cost_rule_v109(
    v_business,v_branch,'service',v_service::text,'fixed_per_unit',1000,
    'supplier_invoice','V114-LINE-SERVICE','{"fixture":true}'::jsonb,
    '2026-07-01 00:00+00',gen_random_uuid()
  );
  perform public.set_effective_cost_rule_v109(
    v_business,v_branch,'package',v_package::text,'revenue_bps',2000,
    'supplier_contract','V114-LINE-PACKAGE','{"fixture":true}'::jsonb,
    '2026-07-01 00:00+00',gen_random_uuid()
  );
  perform public.set_effective_cost_rule_v109(
    v_business,v_branch,'sale_kind','package','revenue_bps',9000,
    'owner_attestation','V114-ITEMIZED-FALLBACK-MUST-NOT-RUN',
    '{"fixture":true}'::jsonb,
    '2026-07-01 00:00+00',gen_random_uuid()
  );
  perform public.set_effective_cost_rule_v109(
    v_business,v_branch,'sale_kind','quick_sale','revenue_bps',4000,
    'owner_attestation','V114-LEGACY-FALLBACK',
    '{"fixture":true}'::jsonb,
    '2026-07-01 00:00+00',gen_random_uuid()
  );

  v_result:=public.get_period_economics_v109(
    v_business,'2026-07-30','2026-07-31',v_discount_branch,
    null,null,'2099-01-01 00:00+00'
  );
  if v_result->>'status'<>'ready'
     or (v_result#>>'{coverage,eligible_sales}')::integer<>1
     or (v_result#>>'{coverage,eligible_sale_lines}')::integer<>1
     or (v_result#>>'{coverage,covered_sale_lines}')::integer<>1
     or (v_result#>>'{coverage,ambiguous_sale_lines}')::integer<>0
     or (v_result#>>'{profit,revenue_cents}')::bigint<>8000
     or (v_result#>>'{profit,traceable_cogs_cents}')::bigint<>4000
     or (v_result#>>'{profit,gross_profit_cents}')::bigint<>4000 then
    raise exception
      'v114 discounted fixed-per-unit COGS was scaled by net revenue: %',
      v_result;
  end if;

  v_result:=public.ingest_external_commerce_event_v106(
    v_business,v_branch,'refund_completed','v114.test.pos',
    'mixed-refund-in-period','mixed-refund-in-period',
    '2026-07-30 03:00+00','SGD',-2000,
    '{"fixture":"mixed-partial-refund"}'::jsonb
  );
  v_refund_event:=(v_result->>'event_id')::uuid;
  perform public.reconcile_external_commerce_event_v106(
    v_refund_event,v_mixed_sale,'mixed-refund-in-period',
    jsonb_build_array(jsonb_build_object('amount_minor',2000))
  );

  v_before:=public.get_period_economics_v109(
    v_business,'2026-07-30','2026-07-31',v_branch,
    null,null,'2099-01-01 00:00+00'
  );
  if v_before->>'status'<>'ready'
     or (v_before#>>'{coverage,eligible_sales}')::integer<>2
     or (v_before#>>'{coverage,eligible_sale_lines}')::integer<>4
     or (v_before#>>'{coverage,covered_sale_lines}')::integer<>4
     or (v_before#>>'{coverage,ambiguous_sale_lines}')::integer<>0
     or (v_before#>>'{profit,revenue_cents}')::bigint<>10000
     or (v_before#>>'{profit,traceable_cogs_cents}')::bigint<>3280 then
    raise exception
      'v114 mixed product/service/package allocation is incorrect: %',
      v_before;
  end if;

  -- Both adjustments are recorded before the as-of, but their business date is
  -- after p_to.  The earlier [p_from,p_to) result must remain byte-for-byte
  -- stable: later operational events do not rewrite a closed reporting period.
  v_result:=public.ingest_external_commerce_event_v106(
    v_business,v_branch,'refund_completed','v114.test.pos',
    'mixed-refund-after-period','mixed-refund-after-period',
    '2026-08-01 03:00+00','SGD',-1000,
    '{"fixture":"post-period-refund"}'::jsonb
  );
  v_refund_event:=(v_result->>'event_id')::uuid;
  perform public.reconcile_external_commerce_event_v106(
    v_refund_event,v_mixed_sale,'mixed-refund-after-period',
    jsonb_build_array(jsonb_build_object('amount_minor',1000))
  );
  execute 'reset role';

  perform set_config(
    'app.sale_reversal_insert_id',v_native_reversal::text,true
  );
  perform set_config(
    'app.sale_reversal_original_id',v_native_sale::text,true
  );
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,commission_rate_bps,commission_resolved_at,qty,
    reversal_of,reversal_reason,reversal_actor,reversal_idempotency_key
  ) values (
    v_native_reversal,v_business,v_client,'quick_sale',-2000,
    '2026-08-01 04:00+00','2026-08-01 04:00+00',
    true,false,false,'2026-08-01 04:00+00',
    v_branch,0,'2026-08-01 04:00+00',1,
    v_native_sale,'V114 post-period native reversal',v_owner_user,
    'v114-native-after-period'
  );
  perform set_config('app.sale_reversal_insert_id','',true);
  perform set_config('app.sale_reversal_original_id','',true);

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_owner_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_owner_user,'role','authenticated')::text,true
  );
  v_after:=public.get_period_economics_v109(
    v_business,'2026-07-30','2026-07-31',v_branch,
    null,null,'2099-01-01 00:00+00'
  );
  if v_after is distinct from v_before then
    raise exception
      'v114 post-period native/external reversal rewrote prior economics: % / %',
      v_before,v_after;
  end if;
  execute 'reset role';

  -- An itemized custom row stays uncovered even though a generic quick_sale
  -- rule exists.  An equal-precedence duplicate product rule is separately
  -- detected as ambiguous; neither condition may produce guessed profit.
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,commission_rate_bps,commission_resolved_at,qty
  ) values
    (
      v_missing_sale,v_business,v_client,'quick_sale',500,
      '2026-07-30 05:00+00','2026-07-30 05:00+00',
      true,true,false,'2026-07-30 05:00+00',
      v_branch,0,'2026-07-30 05:00+00',1
    ),
    (
      v_ambiguous_sale,v_business,v_client,'quick_sale',700,
      '2026-07-30 05:30+00','2026-07-30 05:30+00',
      true,true,false,'2026-07-30 05:30+00',
      v_branch,0,'2026-07-30 05:30+00',1
    );
  insert into public.sale_items(
    sale_id,business_id,item_type,ref_id,description,qty,
    unit_cents,line_cents,product_id
  ) values
    (
      v_missing_sale,v_business,'custom',null,'Unsupported cost scope',1,
      500,500,null
    ),
    (
      v_ambiguous_sale,v_business,'retail',v_ambiguous_product,
      'Ambiguous cost scope',1,700,700,v_ambiguous_product
    );
  insert into public.economic_cost_rules_v109(
    business_id,branch_id,scope_kind,scope_key,cost_method,cost_value,
    currency,source_type,source_reference,evidence,effective_from,version_no,
    created_by,idempotency_key,request_hash
  ) values
    (
      v_business,v_branch,'product',v_ambiguous_product::text,
      'revenue_bps',1000,'SGD','supplier_invoice','V114-AMBIGUOUS-A',
      '{"fixture":true}'::jsonb,'2026-07-01 00:00+00',1,
      v_owner_user,gen_random_uuid(),repeat('a',64)
    ),
    (
      v_business,v_branch,'product',v_ambiguous_product::text,
      'revenue_bps',2000,'SGD','supplier_invoice','V114-AMBIGUOUS-B',
      '{"fixture":true}'::jsonb,'2026-07-01 00:00+00',2,
      v_owner_user,gen_random_uuid(),repeat('b',64)
    );

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_owner_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_owner_user,'role','authenticated')::text,true
  );
  v_result:=public.get_period_economics_v109(
    v_business,'2026-07-30','2026-07-31',v_branch,
    null,null,'2099-01-01 00:00+00'
  );
  if v_result->>'status'<>'insufficient_cost_coverage'
     or (v_result#>>'{coverage,eligible_sale_lines}')::integer<>6
     or (v_result#>>'{coverage,covered_sale_lines}')::integer<>4
     or (v_result#>>'{coverage,ambiguous_sale_lines}')::integer<>1
     or not(v_result->'unavailable_reasons'
       ? 'incomplete_traceable_sale_cost_coverage')
     or not(v_result->'unavailable_reasons'
       ? 'ambiguous_traceable_sale_cost_rules')
     or v_result->'profit'<>'null'::jsonb then
    raise exception 'v114 missing/ambiguous line costs did not fail closed: %',
      v_result;
  end if;
  execute 'reset role';
end
$sale_line_economics$;

rollback;
