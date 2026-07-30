-- Rollback-only v113 effective-identity consumer evidence.
-- Run after the canonical chain through v113 in a disposable PostgreSQL database.
begin;

do $contract$
begin
  if to_regprocedure('app.v113_effective_client_id(uuid,uuid)') is null
     or to_regprocedure(
       'app.v113_customer_effective_client_id(uuid,uuid)'
     ) is null
     or to_regprocedure(
       'public.refresh_growth_recommendation_v108(uuid,uuid)'
     ) is null
     or to_regprocedure(
       'public.customer_get_growth_offers_v108(uuid)'
     ) is null
     or to_regprocedure(
       'public.customer_prepare_growth_offer_qr_v108(uuid,uuid)'
     ) is null
     or to_regprocedure(
       'public.redeem_growth_offer_v108(uuid,text,uuid,uuid)'
     ) is null
     or to_regprocedure(
       'public.get_revenue_driver_decomposition_v109(uuid,date,date,date,date,uuid,timestamp with time zone)'
     ) is null then
    raise exception 'v113 effective-identity consumer contract is incomplete';
  end if;
  if has_function_privilege(
       'anon','public.customer_get_growth_offers_v108(uuid)','EXECUTE'
     ) or not has_function_privilege(
       'authenticated',
       'public.customer_get_growth_offers_v108(uuid)',
       'EXECUTE'
     ) then
    raise exception 'v113 customer offer grants are not fail-closed';
  end if;
  if has_function_privilege(
       'authenticated',
       'app.v113_customer_effective_client_id(uuid,uuid)',
       'EXECUTE'
     ) then
    raise exception 'v113 internal identity resolver is publicly executable';
  end if;
  if not exists (
    select 1
      from pg_catalog.pg_trigger trigger_row
     where trigger_row.tgrelid='public.growth_executions_v108'::regclass
       and trigger_row.tgname='growth_executions_v113_identity_guard'
       and not trigger_row.tgisinternal
  ) or not exists (
    select 1
      from pg_catalog.pg_trigger trigger_row
     where trigger_row.tgrelid='public.growth_execution_members_v108'::regclass
       and trigger_row.tgname=
         'growth_execution_members_v113_effective_identity'
       and not trigger_row.tgisinternal
  ) then
    raise exception 'v113 effective-identity reservation triggers are missing';
  end if;
end
$contract$;

create or replace function pg_temp.v113_actor(p_actor uuid)
returns void
language plpgsql
as $$
begin
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub',p_actor,'role','authenticated')::text,
    true
  );
  perform set_config('request.jwt.claim.sub',p_actor::text,true);
end
$$;

create or replace function pg_temp.v113_recommendation(
  p_business uuid,
  p_branch uuid,
  p_actor uuid,
  p_audience integer
)
returns uuid
language plpgsql
as $$
declare
  v_id uuid:=gen_random_uuid();
begin
  insert into public.growth_recommendations_v108(
    id,business_id,branch_id,recommendation_type,policy_version,
    generated_at,valid_until,observation_start,observation_end,
    comparison_start,comparison_end,finding,supporting_evidence,baseline,
    opportunity,expected_incremental_revenue,expected_incremental_gross_profit,
    confidence,assumptions,recommended_action,recommended_channel,
    recommended_offer,estimated_cost_cents,audience_size,excluded_size,
    success_metric,frequency_cap_days,attribution_window_days,holdout_percent,
    stop_conditions,status,suppression_reasons,data_freshness_at,data_coverage,
    dedupe_key,created_by
  ) values (
    v_id,p_business,p_branch,'lapsed_high_value_bring_back','bring_back_v1',
    statement_timestamp(),statement_timestamp()+interval '1 day',
    statement_timestamp()-interval '90 days',statement_timestamp(),
    statement_timestamp()-interval '180 days',
    statement_timestamp()-interval '90 days',
    'Rollback fixture: approved measured identity attribution.',
    '[]'::jsonb,'{}'::jsonb,'{}'::jsonb,
    jsonb_build_object(
      'status','withheld_uncalibrated',
      'kind','incremental_revenue_not_yet_available'
    ),
    null,jsonb_build_object('score_bps',8000),
    '[]'::jsonb,jsonb_build_object('label','Approve measured bring-back'),
    'in_app',
    jsonb_build_object(
      'type','credit_cents','value_cents',300,'currency','SGD'
    ),
    p_audience*300,p_audience,0,
    'incremental_completed_purchase_revenue',30,14,20,
    jsonb_build_object('one_active_experiment_per_customer',true),
    'presented','[]'::jsonb,statement_timestamp(),
    jsonb_build_object(
      'identified_revenue_bps',10000,
      'effective_policy',
        app.growth_v108_effective_parameters(p_business)
    ),
    encode(
      extensions.digest(convert_to(v_id::text,'UTF8'),'sha256'),
      'hex'
    ),
    p_actor
  );
  return v_id;
end
$$;

create or replace function pg_temp.v113_execution(
  p_recommendation uuid,
  p_business uuid,
  p_branch uuid,
  p_actor uuid
)
returns uuid
language plpgsql
as $$
declare
  v_id uuid:=gen_random_uuid();
  v_expires timestamptz:=statement_timestamp()+interval '5 days';
  v_ends timestamptz:=statement_timestamp()+interval '7 days';
  v_copy jsonb;
begin
  v_copy:=jsonb_build_object(
    'schema','nestly.growth_offer_copy','version',1,
    'title','A saving is ready for you',
    'body','Enjoy SGD 3.00 in credit on your next eligible visit.',
    'cta_label','Redeem now',
    'cta_destination','customer_growth_offer_qr',
    'eligibility',jsonb_build_object(
      'business_id',p_business,'branch_id',p_branch,
      'recommendation_id',p_recommendation,
      'eligible_member_snapshot',true,
      'verified_customer_link_required',true,
      'marketing_consent_required',true,
      'one_active_experiment_per_customer',true
    ),
    'conditions',jsonb_build_object(
      'single_use',true,'qualifying_completed_sale_required',true,
      'sale_after_issuance_required',true,'exact_branch_when_scoped',true,
      'expires_at',v_expires,'timezone','Asia/Singapore'
    ),
    'locked_facts',jsonb_build_object(
      'template_id','simple_saving','offer_value_cents',300,
      'currency','SGD','expires_at',v_expires,
      'timezone','Asia/Singapore','branch_id',p_branch,
      'recommendation_id',p_recommendation,
      'cta_label','Redeem now',
      'cta_destination','customer_growth_offer_qr'
    )
  );
  insert into public.growth_executions_v108(
    id,recommendation_id,business_id,branch_id,channel,offer_type,
    offer_value_cents,offer_label,currency,offer_timezone,offer_expires_at,
    governed_copy,budget_cap_cents,holdout_percent,attribution_window_days,
    minimum_arm_size,status,approved_by,approved_at,started_at,ends_at,
    idempotency_key,request_hash
  ) values (
    v_id,p_recommendation,p_business,p_branch,'in_app','credit_cents',
    300,'simple_saving','SGD','Asia/Singapore',v_expires,
    v_copy,30000,20,14,3,'running',p_actor,
    statement_timestamp(),statement_timestamp()-interval '1 hour',v_ends,
    gen_random_uuid(),
    encode(
      extensions.digest(convert_to(v_id::text,'UTF8'),'sha256'),
      'hex'
    )
  );
  return v_id;
end
$$;

do $runtime$
declare
  v_owner uuid:=gen_random_uuid();
  v_customer_user uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_other_business uuid:=gen_random_uuid();
  v_branch uuid:=gen_random_uuid();
  v_other_branch uuid:=gen_random_uuid();
  v_owner_staff uuid:=gen_random_uuid();
  v_source uuid:=gen_random_uuid();
  v_target uuid:=gen_random_uuid();
  v_source_link uuid:=gen_random_uuid();
  v_target_link uuid:=gen_random_uuid();
  v_identity uuid:=gen_random_uuid();
  v_recommendation uuid;
  v_recommendation_member uuid:=gen_random_uuid();
  v_execution uuid;
  v_execution_member uuid:=gen_random_uuid();
  v_delivery uuid:=gen_random_uuid();
  v_entitlement uuid:=gen_random_uuid();
  v_comparison_source_sale uuid:=gen_random_uuid();
  v_comparison_target_sale uuid:=gen_random_uuid();
  v_current_source_sale uuid:=gen_random_uuid();
  v_current_target_sale uuid:=gen_random_uuid();
  v_wrong_branch_sale uuid:=gen_random_uuid();
  v_proposal uuid;
  v_receipt jsonb;
  v_offers jsonb;
  v_qr jsonb;
  v_result jsonb;
  v_driver jsonb;
  v_duplicate_recommendation uuid;
  v_duplicate_source_member uuid:=gen_random_uuid();
  v_duplicate_target_member uuid:=gen_random_uuid();
  v_overlap_recommendation uuid;
  v_overlap_member uuid:=gen_random_uuid();
  v_count integer;
  v_local_today date:=
    (statement_timestamp() at time zone 'Asia/Singapore')::date;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) values
  (
    '00000000-0000-0000-0000-000000000000',v_owner,'authenticated',
    'authenticated','v113-owner-'||v_owner||'@example.test','',
    now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_customer_user,
    'authenticated','authenticated','v113-customer@example.test','',
    now(),now(),now()
  );
  insert into public.businesses(
    id,name,slug,currency,industry,enabled_modules,is_synthetic
  ) values
  (
    v_business,'V113 Effective Identity',
    'v113-'||v_business,'SGD','facial',
    array['dashboard','clients','sales','loyalty','retention'],true
  ),(
    v_other_business,'V113 Tenant Boundary',
    'v113-other-'||v_other_business,'SGD','facial',
    array['dashboard','clients','sales','loyalty','retention'],true
  );
  insert into public.branches(id,business_id,name,timezone,is_default)
  values
    (v_branch,v_business,'V113 Main','Asia/Singapore',true),
    (v_other_branch,v_business,'V113 Other Branch','Asia/Singapore',false);
  insert into public.reporting_contract_versions_v106(
    business_id,branch_id,version_no,effective_from,timezone,currency,
    legacy_assumption,created_by
  ) values
  (
    v_business,v_branch,2,'-infinity'::timestamptz,
    'Asia/Singapore','SGD',true,null
  ),(
    v_business,v_other_branch,2,'-infinity'::timestamptz,
    'Asia/Singapore','SGD',true,null
  );
  insert into public.staff(
    id,business_id,user_id,role,full_name,email,active
  ) values (
    v_owner_staff,v_business,v_owner,'owner','V113 Owner',
    'v113-owner-'||v_owner||'@example.test',true
  );
  insert into public.clients(
    id,business_id,full_name,email,marketing_consent,is_synthetic
  ) values
  (
    v_source,v_business,'V113 Historical Source',
    'v113-customer@example.test',true,true
  ),(
    v_target,v_business,'V113 Verified Target',
    'v113-customer@example.test',true,true
  );
  insert into public.customer_identities(
    id,auth_user_id,status,created_via
  ) values(v_identity,v_customer_user,'active','phone_registration');
  perform set_config('app.customer_link_insert_id',v_source_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values (
    v_source_link,v_business,v_identity,v_customer_user,v_source,
    'verified','qr_join',statement_timestamp()-interval '60 days'
  );
  perform set_config('app.customer_link_insert_id','',true);
  insert into public.customer_notification_preferences(
    business_id,identity_id,auth_user_id,link_id,client_id,
    channel,topic,opted_in,consent_at
  ) values (
    v_business,v_identity,v_customer_user,v_source_link,v_source,
    'in_app','marketing',true,statement_timestamp()-interval '60 days'
  );
  insert into public.growth_policies_v108(
    business_id,minimum_audience,minimum_arm_size,updated_by
  ) values(v_business,10,3,v_owner);
  update app.platform_feature_flags
     set enabled=true
   where feature_key in (
     'growth_closed_loop_v108','economics_driver_policy_v109'
   );

  -- Immutable source records exist on both sides before the correction.
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,commission_rate_bps,commission_resolved_at
  ) values
  (
    v_comparison_source_sale,v_business,v_source,'quick_sale',1000,
    statement_timestamp()-interval '25 days',
    statement_timestamp()-interval '25 days',
    true,true,false,statement_timestamp()-interval '25 days',
    v_branch,0,statement_timestamp()-interval '25 days'
  ),(
    v_comparison_target_sale,v_business,v_target,'quick_sale',2000,
    statement_timestamp()-interval '24 days',
    statement_timestamp()-interval '24 days',
    true,true,false,statement_timestamp()-interval '24 days',
    v_branch,0,statement_timestamp()-interval '24 days'
  ),(
    v_current_source_sale,v_business,v_source,'quick_sale',3000,
    statement_timestamp()-interval '5 days',
    statement_timestamp()-interval '5 days',
    true,true,false,statement_timestamp()-interval '5 days',
    v_branch,0,statement_timestamp()-interval '5 days'
  );
  insert into public.sale_items(
    sale_id,business_id,item_type,description,qty,unit_cents,line_cents
  ) values (
    v_current_source_sale,v_business,'service','Identity regression service',
    1,3000,3000
  );

  -- The offer is approved and issued while the immutable member is the source.
  v_recommendation:=pg_temp.v113_recommendation(
    v_business,v_branch,v_owner,1
  );
  insert into public.growth_recommendation_members_v108(
    id,recommendation_id,business_id,client_id,eligible,
    prior_visits,last_visit_at,cadence_days,lapse_days,
    average_transaction_cents,historical_revenue_cents,evidence
  ) values (
    v_recommendation_member,v_recommendation,v_business,v_source,true,
    3,statement_timestamp()-interval '5 days',10,5,2000,6000,
    jsonb_build_object('identity_attribution','source_snapshot')
  );
  v_execution:=pg_temp.v113_execution(
    v_recommendation,v_business,v_branch,v_owner
  );
  insert into public.growth_execution_members_v108(
    id,execution_id,business_id,recommendation_member_id,client_id,
    assignment,assignment_rank,assignment_score
  ) values (
    v_execution_member,v_execution,v_business,v_recommendation_member,
    v_source,'treatment',1,repeat('a',64)
  );
  if (
    select client_id from public.growth_execution_members_v108
     where id=v_execution_member
  ) is distinct from v_source then
    raise exception 'v113 rewrote the immutable pre-correction member snapshot';
  end if;
  insert into public.growth_deliveries_v108(
    id,execution_id,execution_member_id,business_id,client_id,
    identity_id,link_id,assignment,channel,delivery_status,title,body,
    estimated_cost_cents,delivered_at
  ) values (
    v_delivery,v_execution,v_execution_member,v_business,v_source,
    v_identity,v_source_link,'treatment','in_app','delivered',
    'A saving is ready','Use the saving at the counter.',300,
    statement_timestamp()
  );
  insert into public.growth_entitlements_v108(
    id,delivery_id,execution_id,business_id,client_id,identity_id,
    entitlement_type,value_cents,estimated_cost_cents,status,
    issued_at,expires_at
  ) values (
    v_entitlement,v_delivery,v_execution,v_business,v_source,v_identity,
    'credit_cents',300,300,'issued',statement_timestamp(),
    statement_timestamp()+interval '5 days'
  );

  -- The verified relationship moves to the target before the audited correction.
  perform set_config(
    'app.customer_link_transition_id',v_source_link::text,true
  );
  update public.customer_links
     set state='unlinked',unlinked_at=statement_timestamp(),
         unlinked_by_auth_user_id=v_owner,updated_at=statement_timestamp()
   where id=v_source_link;
  perform set_config('app.customer_link_transition_id','',true);
  perform set_config('app.customer_link_insert_id',v_target_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values (
    v_target_link,v_business,v_identity,v_customer_user,v_target,
    'verified','qr_join',statement_timestamp()
  );
  perform set_config('app.customer_link_insert_id','',true);
  update public.customer_notification_preferences
     set link_id=v_target_link,client_id=v_target,updated_at=statement_timestamp()
   where business_id=v_business and identity_id=v_identity
     and channel='in_app' and topic='marketing';

  perform pg_temp.v113_actor(v_owner);
  v_receipt:=public.propose_customer_identity_correction_v111(
    v_business,v_branch,v_source,v_target,
    'Verified duplicate created before the current customer link',
    gen_random_uuid()
  );
  v_proposal:=(v_receipt->>'proposal_id')::uuid;
  perform public.attach_customer_identity_proof_v111(
    v_proposal,'verified_contact_pair',
    jsonb_build_object(
      'contact_type','email','contact_value','v113-customer@example.test'
    ),
    gen_random_uuid()
  );
  perform public.approve_customer_identity_correction_v111(
    v_proposal,gen_random_uuid()
  );
  if app.v113_effective_client_id(v_business,v_source)
       is distinct from v_target then
    raise exception 'approved correction did not become current attribution';
  end if;

  -- A stale source+target snapshot is ambiguous and cannot be approved.
  v_duplicate_recommendation:=pg_temp.v113_recommendation(
    v_business,v_branch,v_owner,2
  );
  insert into public.growth_recommendation_members_v108(
    id,recommendation_id,business_id,client_id,eligible,
    prior_visits,average_transaction_cents,historical_revenue_cents,evidence
  ) values
  (
    v_duplicate_source_member,v_duplicate_recommendation,v_business,
    v_source,true,3,1000,3000,'{}'::jsonb
  ),(
    v_duplicate_target_member,v_duplicate_recommendation,v_business,
    v_target,true,3,1000,3000,'{}'::jsonb
  );
  begin
    perform pg_temp.v113_execution(
      v_duplicate_recommendation,v_business,v_branch,v_owner
    );
    raise exception 'stale duplicate-effective recommendation was executed';
  exception
    when sqlstate '55000' then null;
  end;

  -- Even a canonical target-only recommendation cannot overlap the running source
  -- snapshot, because both now resolve to the same person.
  v_overlap_recommendation:=pg_temp.v113_recommendation(
    v_business,v_branch,v_owner,1
  );
  insert into public.growth_recommendation_members_v108(
    id,recommendation_id,business_id,client_id,eligible,
    prior_visits,average_transaction_cents,historical_revenue_cents,evidence
  ) values (
    v_overlap_member,v_overlap_recommendation,v_business,v_target,
    true,3,1000,3000,'{}'::jsonb
  );
  begin
    perform pg_temp.v113_execution(
      v_overlap_recommendation,v_business,v_branch,v_owner
    );
    raise exception 'effective target entered an overlapping experiment';
  exception
    when sqlstate '23P01' then null;
  end;

  -- Disabled and cross-tenant identities fail closed.
  perform pg_temp.v113_actor(v_customer_user);
  update public.customer_identities set status='disabled' where id=v_identity;
  begin
    perform public.customer_get_growth_offers_v108(v_business);
    raise exception 'disabled identity read an effective-client offer';
  exception
    when insufficient_privilege then null;
  end;
  update public.customer_identities set status='active' where id=v_identity;
  begin
    perform public.customer_get_growth_offers_v108(v_other_business);
    raise exception 'customer offer access crossed a tenant boundary';
  exception
    when insufficient_privilege then null;
  end;
  v_offers:=public.customer_get_growth_offers_v108(v_business);
  select count(*) into v_count
    from jsonb_array_elements(v_offers->'offers') offer
   where (offer->>'entitlement_id')::uuid=v_entitlement;
  if v_count<>1 then
    raise exception 'approved correction made the issued source offer disappear: %',
      v_offers;
  end if;
  v_qr:=public.customer_prepare_growth_offer_qr_v108(
    v_entitlement,gen_random_uuid()
  );

  -- Purchases remain on their source client ids.  The current target purchase is
  -- nevertheless attributed to the source experiment member.
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,commission_rate_bps,commission_resolved_at
  ) values
  (
    v_wrong_branch_sale,v_business,v_target,'quick_sale',4000,
    statement_timestamp(),statement_timestamp(),
    true,true,false,statement_timestamp(),
    v_other_branch,0,statement_timestamp()
  ),(
    v_current_target_sale,v_business,v_target,'quick_sale',5000,
    statement_timestamp(),statement_timestamp(),
    true,true,false,statement_timestamp(),
    v_branch,0,statement_timestamp()
  );
  if (
    select client_id from public.sales where id=v_current_target_sale
  ) is distinct from v_target then
    raise exception 'v113 rewrote an immutable sale source client id';
  end if;
  if not exists (
    select 1
      from public.growth_outcomes_v108 outcome
     where outcome.execution_id=v_execution
       and outcome.client_id=v_source
       and outcome.sale_id=v_current_target_sale
  ) then
    raise exception 'later target purchase was not attributed to source member';
  end if;

  perform pg_temp.v113_actor(v_owner);
  begin
    perform public.redeem_growth_offer_v108(
      v_business,v_qr->>'token',v_wrong_branch_sale,gen_random_uuid()
    );
    raise exception 'branch-mismatched target sale redeemed the offer';
  exception
    when invalid_parameter_value then null;
  end;
  v_receipt:=public.redeem_growth_offer_v108(
    v_business,v_qr->>'token',v_current_target_sale,gen_random_uuid()
  );
  if v_receipt->>'status'<>'redeemed'
     or (v_receipt->>'entitlement_id')::uuid<>v_entitlement then
    raise exception 'effective target could not redeem source entitlement: %',
      v_receipt;
  end if;
  v_result:=app.get_growth_execution_result_at_v108(
    v_execution,statement_timestamp()
  );
  if (v_result#>>'{arms,treatment,buyers}')::integer<>1
     or (v_result#>>'{arms,treatment,associated_revenue_cents}')::bigint
        <>5000 then
    raise exception 'effective target purchase was absent from results: %',
      v_result;
  end if;
  v_driver:=public.get_revenue_driver_decomposition_v109(
    v_business,v_local_today-10,v_local_today+1,
    v_local_today-30,v_local_today-20,v_branch,statement_timestamp()
  );
  if (v_driver#>>'{periods,current,identified_customers}')::integer<>1
     or (v_driver#>>'{periods,current,identified_transactions}')::integer<>2
     or (v_driver#>>'{periods,comparison,identified_customers}')::integer<>1
     or (v_driver#>>'{periods,comparison,identified_transactions}')::integer<>2
     or v_driver->>'identity_attribution'
        <>'v111_current_effective_identity'
     or (v_driver#>>'{coverage,current_itemized_transaction_bps}')::integer
        <>5000
     or (v_driver#>>'{coverage,current_itemized_revenue_bps}')::integer
        <>3750
     or (v_driver#>>'{coverage,comparison_itemized_transaction_bps}')::integer
        <>0
     or v_driver#>>'{line_item_analysis,price_volume_mix_status}'
        <>'not_claimed' then
    raise exception 'driver counts/frequency split corrected identity: %',
      v_driver;
  end if;

  -- Reversal restores source attribution without mutating sales, member snapshots,
  -- entitlements or outcomes.  Every current consumer follows the restored state.
  perform public.reverse_customer_identity_correction_v111(
    v_proposal,'Owner reversed the evidence after review',gen_random_uuid()
  );
  if app.v113_effective_client_id(v_business,v_source)
       is distinct from v_source then
    raise exception 'reversal did not restore prior source attribution';
  end if;
  v_result:=app.get_growth_execution_result_at_v108(
    v_execution,statement_timestamp()
  );
  if (v_result#>>'{arms,treatment,buyers}')::integer<>0
     or (v_result#>>'{arms,treatment,associated_revenue_cents}')::bigint<>0 then
    raise exception 'execution result did not follow reversed attribution: %',
      v_result;
  end if;
  v_driver:=public.get_revenue_driver_decomposition_v109(
    v_business,v_local_today-10,v_local_today+1,
    v_local_today-30,v_local_today-20,v_branch,statement_timestamp()
  );
  if (v_driver#>>'{periods,current,identified_customers}')::integer<>2
     or (v_driver#>>'{periods,current,identified_transactions}')::integer<>2
     or (v_driver#>>'{periods,comparison,identified_customers}')::integer<>2
     or (v_driver#>>'{periods,comparison,identified_transactions}')::integer<>2 then
    raise exception 'driver decomposition did not restore source/target split: %',
      v_driver;
  end if;
  perform pg_temp.v113_actor(v_customer_user);
  v_offers:=public.customer_get_growth_offers_v108(v_business);
  select count(*) into v_count
    from jsonb_array_elements(v_offers->'offers') offer
   where (offer->>'entitlement_id')::uuid=v_entitlement;
  if v_count<>0 then
    raise exception 'reversal left source entitlement attributed to target: %',
      v_offers;
  end if;
  if (
    select client_id from public.sales where id=v_current_source_sale
  ) is distinct from v_source
     or (
       select client_id from public.sales where id=v_current_target_sale
     ) is distinct from v_target
     or (
       select client_id from public.growth_execution_members_v108
        where id=v_execution_member
     ) is distinct from v_source then
    raise exception 'v113 changed immutable source identifiers';
  end if;
end
$runtime$;

-- A pre-existing execution can contain two immutable member snapshots that a
-- later historical correction collapses.  Ordinary checkout must still commit;
-- the experiment becomes invalid instead of emitting duplicate outcomes.
do $collapsed_outcome$
declare
  v_owner uuid:=gen_random_uuid();
  v_customer_user uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_branch uuid:=gen_random_uuid();
  v_staff uuid:=gen_random_uuid();
  v_source uuid:=gen_random_uuid();
  v_target uuid:=gen_random_uuid();
  v_identity uuid:=gen_random_uuid();
  v_link uuid:=gen_random_uuid();
  v_proposal uuid:=gen_random_uuid();
  v_decision uuid:=gen_random_uuid();
  v_recommendation uuid;
  v_source_recommendation_member uuid:=gen_random_uuid();
  v_target_recommendation_member uuid:=gen_random_uuid();
  v_execution uuid;
  v_sale uuid:=gen_random_uuid();
  v_result jsonb;
  v_count integer;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) values
  (
    '00000000-0000-0000-0000-000000000000',v_owner,'authenticated',
    'authenticated','v113-collapse-owner-'||v_owner||'@example.test','',
    now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_customer_user,
    'authenticated','authenticated',
    'v113-collapse-customer-'||v_customer_user||'@example.test','',
    now(),now(),now()
  );
  insert into public.businesses(
    id,name,slug,currency,industry,enabled_modules,is_synthetic
  ) values (
    v_business,'V113 Collapsed Outcome',
    'v113-collapse-'||v_business,'SGD','facial',
    array['dashboard','clients','sales','loyalty','retention'],true
  );
  insert into public.branches(id,business_id,name,timezone,is_default)
  values(v_branch,v_business,'V113 Collapse Main','Asia/Singapore',true);
  insert into public.staff(
    id,business_id,user_id,role,full_name,email,active
  ) values (
    v_staff,v_business,v_owner,'owner','V113 Collapse Owner',
    'v113-collapse-owner-'||v_owner||'@example.test',true
  );
  insert into public.clients(
    id,business_id,full_name,email,marketing_consent,is_synthetic
  ) values
  (
    v_source,v_business,'V113 Collapse Source',
    'v113-collapse-customer@example.test',true,true
  ),(
    v_target,v_business,'V113 Collapse Target',
    'v113-collapse-customer@example.test',true,true
  );
  insert into public.customer_identities(
    id,auth_user_id,status,created_via
  ) values(v_identity,v_customer_user,'active','phone_registration');
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values (
    v_link,v_business,v_identity,v_customer_user,v_target,
    'verified','qr_join',statement_timestamp()
  );
  perform set_config('app.customer_link_insert_id','',true);
  insert into public.growth_policies_v108(
    business_id,minimum_audience,minimum_arm_size,updated_by
  ) values(v_business,10,3,v_owner);

  v_recommendation:=pg_temp.v113_recommendation(
    v_business,v_branch,v_owner,2
  );
  insert into public.growth_recommendation_members_v108(
    id,recommendation_id,business_id,client_id,eligible,
    prior_visits,average_transaction_cents,historical_revenue_cents,evidence
  ) values
  (
    v_source_recommendation_member,v_recommendation,v_business,
    v_source,true,3,1000,3000,'{}'::jsonb
  ),(
    v_target_recommendation_member,v_recommendation,v_business,
    v_target,true,3,1000,3000,'{}'::jsonb
  );
  v_execution:=pg_temp.v113_execution(
    v_recommendation,v_business,v_branch,v_owner
  );
  insert into public.growth_execution_members_v108(
    execution_id,business_id,recommendation_member_id,client_id,
    assignment,assignment_rank,assignment_score
  ) values
  (
    v_execution,v_business,v_source_recommendation_member,v_source,
    'treatment',1,repeat('b',64)
  ),(
    v_execution,v_business,v_target_recommendation_member,v_target,
    'holdout',2,repeat('c',64)
  );

  -- This direct append represents immutable historical state created before the
  -- v113 shared approval boundary existed.
  insert into public.customer_identity_proposals_v111(
    id,business_id,branch_id,source_client_id,target_client_id,
    target_identity_id,target_link_id,reason,proposed_by,status,decided_at
  ) values (
    v_proposal,v_business,v_branch,v_source,v_target,
    v_identity,v_link,'Historical correction fixture',v_owner,
    'approved',statement_timestamp()
  );
  insert into public.customer_identity_decisions_v111(
    id,proposal_id,business_id,decision_type,
    before_client_id,after_client_id,before_attribution,after_attribution,
    decided_by
  ) values (
    v_decision,v_proposal,v_business,'approve',
    v_source,v_target,'{}'::jsonb,'{}'::jsonb,v_owner
  );
  insert into public.customer_identity_attribution_events_v111(
    proposal_id,decision_id,business_id,source_client_id,
    before_client_id,after_client_id,event_type,actor_auth_user_id
  ) values (
    v_proposal,v_decision,v_business,v_source,
    v_source,v_target,'correction_approved',v_owner
  );

  perform pg_temp.v113_actor(v_owner);
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,commission_rate_bps,commission_resolved_at
  ) values (
    v_sale,v_business,v_target,'quick_sale',2500,
    statement_timestamp(),statement_timestamp(),
    true,true,false,statement_timestamp(),
    v_branch,0,statement_timestamp()
  );
  select count(*) into v_count
    from public.growth_outcomes_v108 outcome
   where outcome.execution_id=v_execution and outcome.sale_id=v_sale;
  if v_count<>1 or not exists (
    select 1 from public.growth_outcomes_v108 outcome
     where outcome.execution_id=v_execution
       and outcome.sale_id=v_sale
       and outcome.overlap_count=2
       and outcome.causal_eligible=false
  ) then
    raise exception
      'collapsed immutable members did not emit one fail-closed outcome';
  end if;
  v_result:=app.get_growth_execution_result_at_v108(
    v_execution,statement_timestamp()
  );
  if v_result->>'measurement_status'<>'invalid_overlap'
     or v_result->>'status' not in ('running','complete') then
    raise exception 'collapsed identity result was not invalidated: %',v_result;
  end if;
end
$collapsed_outcome$;

rollback;
