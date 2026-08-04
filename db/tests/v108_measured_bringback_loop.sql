-- Rollback-only v108 measured bring-back contract and fail-closed runtime evidence.
-- Run after the canonical chain through v108 in a disposable database.
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
declare
  v_table text;
begin
  if to_regprocedure(
    'public.refresh_growth_recommendation_v108(uuid,uuid)'
  ) is null or to_regprocedure(
    'public.get_growth_daily_briefing_v108(uuid,uuid)'
  ) is null or to_regprocedure(
    'public.approve_growth_recommendation_v108(uuid,uuid,integer,text,uuid)'
  ) is null or to_regprocedure(
    'public.customer_prepare_growth_offer_qr_v108(uuid,uuid)'
  ) is null or to_regprocedure(
    'public.redeem_growth_offer_v108(uuid,text,uuid,uuid)'
  ) is null then
    raise exception 'v108 public RPC contract is incomplete';
  end if;

  foreach v_table in array array[
    'growth_policies_v108',
    'growth_recommendations_v108',
    'growth_recommendation_members_v108',
    'growth_recommendation_decisions_v108',
    'growth_executions_v108',
    'growth_execution_members_v108',
    'growth_deliveries_v108',
    'growth_entitlements_v108',
    'growth_entitlement_events_v108',
    'growth_redemption_intents_v108',
    'growth_outcomes_v108',
    'growth_execution_results_v108'
  ] loop
    if not exists (
      select 1
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname=v_table and c.relrowsecurity
    ) then
      raise exception 'v108 table % does not enforce RLS',v_table;
    end if;
    if has_table_privilege('authenticated','public.'||v_table,'INSERT')
       or has_table_privilege('authenticated','public.'||v_table,'UPDATE')
       or has_table_privilege('authenticated','public.'||v_table,'DELETE') then
      raise exception 'authenticated has a direct mutation grant on %',v_table;
    end if;
  end loop;

  if has_function_privilege(
       'anon','public.get_growth_daily_briefing_v108(uuid,uuid)','EXECUTE'
     ) or not has_function_privilege(
       'authenticated','public.get_growth_daily_briefing_v108(uuid,uuid)','EXECUTE'
     ) then
    raise exception 'v108 briefing RPC grants are not fail-closed';
  end if;
  if not exists (
    select 1 from app.platform_feature_flags
    where feature_key='growth_closed_loop_v108' and not enabled
  ) then
    raise exception 'v108 feature flag must install disabled';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid='public.growth_entitlements_v108'::regclass
      and conname='growth_entitlements_v108_delivery_id_key'
  ) then
    raise exception 'v108 does not enforce one entitlement per delivery';
  end if;
end
$contract$;

do $runtime$
declare
  v_sa uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_branch uuid:=gen_random_uuid();
  v_refresh jsonb;
  v_briefing jsonb;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_sa,'authenticated',
    'authenticated','v108-sa-'||v_sa||'@example.test','',now(),now(),now()
  );
  insert into public.super_admins(user_id,email,note)
  values(v_sa,'v108-sa-'||v_sa||'@example.test','v108 rollback fixture');
  insert into public.businesses(id,name,slug,currency,is_synthetic)
  values(v_business,'V108 Measured Bring-back','v108-'||v_business,'SGD',true);
  perform pg_temp.approve_workspace_v94(v_business);
  insert into public.branches(id,business_id,name,timezone,is_default)
  values(v_branch,v_business,'V108 Singapore','Asia/Singapore',true);
  update app.platform_feature_flags
  set enabled=true
  where feature_key='growth_closed_loop_v108';

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_sa::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text,true
  );

  v_refresh:=public.refresh_growth_recommendation_v108(
    v_business,v_branch
  );
  if v_refresh->>'status'<>'suppressed'
     or not (v_refresh->'suppression_reasons' ? 'cold_start_under_50_sales')
     or not (v_refresh->'suppression_reasons' ? 'audience_below_minimum')
     or not (v_refresh->'suppression_reasons' ? 'experiment_arms_too_small') then
    raise exception 'v108 cold-start gates did not fail closed: %',v_refresh;
  end if;

  v_briefing:=public.get_growth_daily_briefing_v108(v_business,v_branch);
  if v_briefing->>'contract_version'<>'growth_daily_briefing_v108'
     or v_briefing->>'data_status'<>'insufficient_evidence'
     or v_briefing->'top_action'<>'null'::jsonb then
    raise exception 'v108 suppressed briefing contract drifted: %',v_briefing;
  end if;

  begin
    perform public.approve_growth_recommendation_v108(
      v_business,(v_refresh->>'recommendation_id')::uuid,300,'welcome_back',gen_random_uuid()
    );
    raise exception 'v108 approved a suppressed recommendation';
  exception
    when others then
      if sqlerrm='v108 approved a suppressed recommendation' then raise; end if;
  end;
end
$runtime$;

reset role;

do $e2e$
declare
  v_sa uuid:=gen_random_uuid();
  v_owner_user uuid:=gen_random_uuid();
  v_staff_user uuid:=gen_random_uuid();
  v_owner_staff uuid:=gen_random_uuid();
  v_staff uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_branch uuid:=gen_random_uuid();
  v_customer_user uuid;
  v_identity uuid;
  v_client uuid;
  v_link uuid;
  v_i integer;
  v_refresh jsonb;
  v_briefing jsonb;
  v_approval jsonb;
  v_replay jsonb;
  v_offers jsonb;
  v_qr jsonb;
  v_qr_replay jsonb;
  v_redeem jsonb;
  v_redeem_replay jsonb;
  v_sale_result jsonb;
  v_result jsonb;
  v_final jsonb;
  v_final_replay jsonb;
  v_claims jsonb;
  v_dispatch jsonb;
  v_recommendation uuid;
  v_execution uuid;
  v_treatment_client uuid;
  v_treatment_identity uuid;
  v_treatment_user uuid;
  v_treatment_entitlement uuid;
  v_second_treatment_client uuid;
  v_holdout_client uuid;
  v_sale uuid;
  v_future_sale uuid:=gen_random_uuid();
  v_second_sale uuid;
  v_holdout_sale uuid;
  v_reversal uuid;
  v_refund_event uuid;
  v_approval_key uuid:=gen_random_uuid();
  v_qr_key uuid:=gen_random_uuid();
  v_redeem_key uuid:=gen_random_uuid();
  v_final_key uuid:=gen_random_uuid();
  v_closed_at timestamptz;
  v_count integer;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) values
  (
    '00000000-0000-0000-0000-000000000000',v_sa,'authenticated',
    'authenticated','v108-e2e-sa-'||v_sa||'@example.test','',now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_owner_user,'authenticated',
    'authenticated','v108-e2e-owner-'||v_owner_user||'@example.test','',now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_staff_user,'authenticated',
    'authenticated','v108-e2e-staff-'||v_staff_user||'@example.test','',now(),now(),now()
  );
  insert into public.super_admins(user_id,email,note)
  values(
    v_sa,'v108-e2e-sa-'||v_sa||'@example.test',
    'v108 realistic rollback-only fixture'
  );
  insert into public.businesses(
    id,name,slug,currency,industry,enabled_modules,is_synthetic
  ) values (
    v_business,'V108 Measured Bring-back E2E','v108-e2e-'||v_business,
    'SGD','fnb',
    array['dashboard','till','clients','sales','loyalty','retention'],
    true
  );
  perform pg_temp.approve_workspace_v94(v_business);
  insert into public.branches(id,business_id,name,timezone,is_default)
  values(v_branch,v_business,'V108 E2E Singapore','Asia/Singapore',true);

  -- This rollback-only fixture starts with an existing synthetic business.
  -- Owner onboarding approval and subscription lifecycle are outside v108's
  -- measured bring-back contract, so the fixture must not depend on phantom
  -- platform-control tables.

  insert into public.staff(
    id,business_id,user_id,role,full_name,email,active
  ) values
  (
    v_owner_staff,v_business,v_owner_user,'owner','V108 Owner',
    'v108-e2e-owner-'||v_owner_user||'@example.test',true
  ),(
    v_staff,v_business,v_staff_user,'staff','V108 Frontline Staff',
    'v108-e2e-staff-'||v_staff_user||'@example.test',true
  );
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business,v_staff,v_branch);

  -- Twenty-five realistic, verified, consented customers with four historical
  -- identified purchases each.  Three are inside the 90-day reporting window
  -- (75 sales total); the fourth supplies the fnb sector policy's required
  -- fourth prior visit.  Identity coverage is 100%, cadence is ten days, and
  -- the last visit was 65 days ago.
  for v_i in 1..25 loop
    v_customer_user:=gen_random_uuid();
    v_identity:=gen_random_uuid();
    v_client:=gen_random_uuid();
    v_link:=gen_random_uuid();
    insert into auth.users(
      instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
      created_at,updated_at
    ) values (
      '00000000-0000-0000-0000-000000000000',v_customer_user,'authenticated',
      'authenticated',
      'v108-e2e-customer-'||v_i||'-'||v_customer_user||'@example.test',
      '',now(),now(),now()
    );
    insert into public.clients(
      id,business_id,full_name,email,marketing_consent,is_synthetic
    ) values (
      v_client,v_business,'V108 Customer '||lpad(v_i::text,2,'0'),
      'v108-e2e-customer-'||v_i||'@example.test',true,true
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
      'qr_join',statement_timestamp()-interval '100 days'
    );
    perform set_config('app.customer_link_insert_id','',true);
    insert into public.customer_notification_preferences(
      business_id,identity_id,auth_user_id,link_id,client_id,
      channel,topic,opted_in,consent_at
    ) values (
      v_business,v_identity,v_customer_user,v_link,v_client,
      'in_app','marketing',true,statement_timestamp()-interval '100 days'
    );
    insert into public.sales(
      id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
      counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
      branch_id,commission_rate_bps,commission_resolved_at
    ) values
    (
      gen_random_uuid(),v_business,v_client,'quick_sale',1000+v_i,
      statement_timestamp()-interval '95 days',
      statement_timestamp()-interval '95 days',
      true,true,false,statement_timestamp()-interval '95 days',
      v_branch,0,statement_timestamp()-interval '95 days'
    ),
    (
      gen_random_uuid(),v_business,v_client,'quick_sale',1000+v_i,
      statement_timestamp()-interval '85 days',
      statement_timestamp()-interval '85 days',
      true,true,false,statement_timestamp()-interval '85 days',
      v_branch,0,statement_timestamp()-interval '85 days'
    ),(
      gen_random_uuid(),v_business,v_client,'quick_sale',1000+v_i,
      statement_timestamp()-interval '75 days',
      statement_timestamp()-interval '75 days',
      true,true,false,statement_timestamp()-interval '75 days',
      v_branch,0,statement_timestamp()-interval '75 days'
    ),(
      gen_random_uuid(),v_business,v_client,'quick_sale',1000+v_i,
      statement_timestamp()-interval '65 days',
      statement_timestamp()-interval '65 days',
      true,true,false,statement_timestamp()-interval '65 days',
      v_branch,0,statement_timestamp()-interval '65 days'
    );
  end loop;

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_sa::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text,true
  );
  v_refresh:=public.refresh_growth_recommendation_v108(v_business,v_branch);
  if v_refresh->>'status'<>'presented'
     or (v_refresh->>'eligible')::integer<>25
     or (v_refresh->>'coverage_bps')::integer<>10000
     or jsonb_array_length(v_refresh->'suppression_reasons')<>0 then
    raise exception 'v108 realistic evidence was not presented: %',v_refresh;
  end if;
  v_recommendation:=(v_refresh->>'recommendation_id')::uuid;
  v_briefing:=public.get_growth_daily_briefing_v108(v_business,v_branch);
  if v_briefing->>'data_status'<>'ready'
     or (v_briefing#>>'{top_action,recommendation_id}')::uuid<>v_recommendation then
    raise exception 'v108 presented daily briefing drifted: %',v_briefing;
  end if;

  perform set_config('request.jwt.claim.sub',v_owner_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_owner_user,'role','authenticated')::text,true
  );
  v_approval:=public.approve_growth_recommendation_v108(
    v_business,v_recommendation,300,'welcome_back',v_approval_key
  );
  if (v_approval->>'replayed')::boolean
     or (v_approval#>>'{delivery,queued}')::integer<>20
     or (v_approval#>>'{delivery,held_out}')::integer<>5
     or (v_approval#>>'{delivery,suppressed}')::integer<>0 then
    raise exception 'v108 owner approval/delivery failed: %',v_approval;
  end if;
  v_execution:=(v_approval->>'execution_id')::uuid;
  v_replay:=public.approve_growth_recommendation_v108(
    v_business,v_recommendation,300,'welcome_back',v_approval_key
  );
  if (v_replay->>'replayed')::boolean
     or (v_replay->>'execution_id')::uuid<>v_execution then
    raise exception 'v112 exact-receipt replay did not preserve the original v108 approval: %',v_replay;
  end if;

  select count(*) into v_count
  from public.growth_execution_members_v108 em
  where em.execution_id=v_execution
    and em.assignment_score=encode(extensions.digest(convert_to(
      v_execution::text||':'||em.client_id::text,'UTF8'
    ),'sha256'),'hex')
    and (
      (em.assignment_rank<=5 and em.assignment='holdout')
      or (em.assignment_rank>5 and em.assignment='treatment')
    );
  if v_count<>25 or (
    select count(distinct assignment_rank)
    from public.growth_execution_members_v108 where execution_id=v_execution
  )<>25 then
    raise exception 'v108 deterministic assignment/rank evidence failed';
  end if;

  -- v110 intentionally queues treatment delivery.  Only a verified provider
  -- callback may create the v108 entitlement that the rest of this end-to-end
  -- exercise redeems.
  execute 'set local role service_role';
  perform set_config(
    'request.jwt.claims',
    json_build_object('role','service_role')::text,true
  );
  v_claims:=public.service_claim_growth_deliveries_v110(
    100,'v108-e2e-provider',gen_random_uuid()
  );
  if (
    select count(*)
    from jsonb_array_elements(v_claims->'claims') claim
    where claim->>'execution_id'=v_execution::text
  )<>20 then
    raise exception 'v108/v110 delivery claim did not return all treatment members: %',
      v_claims;
  end if;
  for v_dispatch in
    select value
    from jsonb_array_elements(v_claims->'claims')
    where value->>'execution_id'=v_execution::text
  loop
    v_result:=public.service_complete_growth_delivery_v110(
      (v_dispatch->>'dispatch_id')::uuid,
      'v108-e2e-provider-'||(v_dispatch->>'dispatch_id'),
      true,null,gen_random_uuid()
    );
    if v_result->>'status'<>'delivered' then
      raise exception 'v108/v110 provider callback did not deliver: %',v_result;
    end if;
  end loop;
  if (
    select count(*) from public.growth_entitlements_v108
    where execution_id=v_execution and status='issued'
  )<>20 or (
    select count(*) from public.growth_entitlement_events_v108
    where business_id=v_business and event_type='issued'
  )<>20 then
    raise exception
      'v108 delivered offers did not create one issued entitlement/event (entitlements %, events %, statuses %)',
      (select count(*) from public.growth_entitlements_v108
       where execution_id=v_execution and status='issued'),
      (select count(*) from public.growth_entitlement_events_v108
       where business_id=v_business and event_type='issued'),
      (select jsonb_agg(jsonb_build_object(
         'status',status,'count',count
       ) order by status)
       from (
         select status,count(*) count
         from public.growth_entitlements_v108
         where execution_id=v_execution group by status
       ) entitlement_counts);
  end if;

  execute 'reset role';
  select em.client_id,e.identity_id,i.auth_user_id,e.id
  into v_treatment_client,v_treatment_identity,v_treatment_user,v_treatment_entitlement
  from public.growth_execution_members_v108 em
  join public.growth_entitlements_v108 e
    on e.execution_id=em.execution_id and e.client_id=em.client_id
  join public.customer_identities i on i.id=e.identity_id
  where em.execution_id=v_execution and em.assignment='treatment'
  order by em.assignment_rank
  limit 1;
  select em.client_id into v_second_treatment_client
  from public.growth_execution_members_v108 em
  where em.execution_id=v_execution and em.assignment='treatment'
    and em.client_id<>v_treatment_client
  order by em.assignment_rank
  limit 1;
  select em.client_id into v_holdout_client
  from public.growth_execution_members_v108 em
  where em.execution_id=v_execution and em.assignment='holdout'
  order by em.assignment_rank
  limit 1;

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_treatment_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_treatment_user,'role','authenticated')::text,true
  );
  v_offers:=public.customer_get_growth_offers_v108(v_business);
  if jsonb_array_length(v_offers->'offers')<>1
     or (v_offers#>>'{offers,0,entitlement_id}')::uuid<>v_treatment_entitlement
     or v_offers#>>'{offers,0,status}'<>'issued' then
    raise exception 'v108 customer offer projection failed: %',v_offers;
  end if;
  v_qr:=public.customer_prepare_growth_offer_qr_v108(
    v_treatment_entitlement,v_qr_key
  );
  if (v_qr->>'replayed')::boolean
     or (v_qr->>'token') !~ '^[0-9a-f]{64}$'
     or (v_qr->>'token') like '%'||v_treatment_entitlement::text||'%' then
    raise exception 'v108 customer QR was not opaque/single-purpose: %',v_qr;
  end if;
  v_qr_replay:=public.customer_prepare_growth_offer_qr_v108(
    v_treatment_entitlement,v_qr_key
  );
  if not (v_qr_replay->>'replayed')::boolean
     or v_qr_replay->>'token'<>v_qr->>'token' then
    raise exception 'v108 QR preparation replay was not idempotent: %',v_qr_replay;
  end if;

  -- Move the test execution's start before transaction-time sales.  This is an
  -- isolated-clock fixture only; all changes roll back.
  execute 'reset role';
  update public.growth_executions_v108
  set started_at=transaction_timestamp()-interval '1 day'
  where id=v_execution;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_staff_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_staff_user,'role','authenticated')::text,true
  );
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,commission_rate_bps,commission_resolved_at
  ) values(
    v_future_sale,v_business,v_treatment_client,'quick_sale',2500,
    statement_timestamp()+interval '1 day',
    statement_timestamp(),true,true,false,statement_timestamp(),
    v_branch,0,statement_timestamp()
  );
  begin
    perform public.redeem_growth_offer_v108(
      v_business,v_qr->>'token',v_future_sale,gen_random_uuid()
    );
    raise exception 'v108 future-dated sale unexpectedly redeemed an offer';
  exception
    when invalid_parameter_value then
      if sqlerrm<>'offer must attach to this customer''s qualifying sale' then
        raise;
      end if;
  end;
  v_sale:=gen_random_uuid();
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,staff_id,commission_rate_bps,commission_resolved_at,note
  ) values(
    v_sale,v_business,v_treatment_client,'quick_sale',2500,
    clock_timestamp(),clock_timestamp(),true,true,false,clock_timestamp(),
    v_branch,v_staff,0,clock_timestamp(),'v108 redeemed treatment sale'
  );
  execute 'reset role';
  if not (
    select sale.business_id=v_business
      and sale.client_id=v_treatment_client
      and sale.reversal_of is null
      and sale.amount_cents>0
      and sale.created_at<=clock_timestamp()
      and sale.occurred_at<=clock_timestamp()
      and app.v106_sale_residual_minor(sale.id,clock_timestamp())>0
      and sale.created_at>=greatest(entitlement.issued_at,execution.started_at)
      and sale.occurred_at>=greatest(entitlement.issued_at,execution.started_at)
      and sale.occurred_at<least(entitlement.expires_at,execution.ends_at)
      and (
        execution.branch_id is null
        or sale.branch_id is not distinct from execution.branch_id
      )
      and app.can_see_branch(sale.business_id,sale.branch_id)
    from public.sales sale
    join public.growth_entitlements_v108 entitlement
      on entitlement.id=v_treatment_entitlement
    join public.growth_executions_v108 execution
      on execution.id=entitlement.execution_id
    where sale.id=v_sale
  ) then
    raise exception
      'v108 immediate sale fixture did not satisfy redemption preconditions: sale %, entitlement %, execution %, residual %',
      (select to_jsonb(sale) from public.sales sale where sale.id=v_sale),
      (select to_jsonb(entitlement) from public.growth_entitlements_v108 entitlement
       where entitlement.id=v_treatment_entitlement),
      (select to_jsonb(execution) from public.growth_executions_v108 execution
       where execution.id=v_execution),
      app.v106_sale_residual_minor(v_sale,clock_timestamp());
  end if;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_staff_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_staff_user,'role','authenticated')::text,true
  );
  v_redeem:=public.redeem_growth_offer_v108(
    v_business,v_qr->>'token',v_sale,v_redeem_key
  );
  if v_redeem->>'status'<>'redeemed'
     or (v_redeem->>'sale_id')::uuid<>v_sale then
    raise exception 'v108 staff-bound offer redemption failed: %',v_redeem;
  end if;
  v_redeem_replay:=public.redeem_growth_offer_v108(
    v_business,v_qr->>'token',v_sale,v_redeem_key
  );
  if v_redeem_replay is distinct from v_redeem then
    raise exception 'v108 redemption replay did not return the exact receipt: first %, replay %',
      v_redeem,v_redeem_replay;
  end if;
  begin
    perform public.redeem_growth_offer_v108(
      v_business,v_qr->>'token',v_future_sale,v_redeem_key
    );
    raise exception 'v108 changed redemption payload reused one idempotency key';
  exception
    when unique_violation then null;
  end;
  begin
    perform public.redeem_growth_offer_v108(
      v_business,v_qr->>'token',v_sale,gen_random_uuid()
    );
    raise exception 'v108 duplicate redemption unexpectedly succeeded';
  exception
    when insufficient_privilege then
      if sqlerrm<>'offer QR is no longer valid' then raise; end if;
  end;

  v_second_sale:=gen_random_uuid();
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,staff_id,commission_rate_bps,commission_resolved_at,note
  ) values(
    v_second_sale,v_business,v_second_treatment_client,'quick_sale',2000,
    clock_timestamp(),clock_timestamp(),true,true,false,clock_timestamp(),
    v_branch,v_staff,0,clock_timestamp(),'v108 second treatment outcome'
  );
  v_holdout_sale:=gen_random_uuid();
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,staff_id,commission_rate_bps,commission_resolved_at,note
  ) values(
    v_holdout_sale,v_business,v_holdout_client,'quick_sale',1000,
    clock_timestamp(),clock_timestamp(),true,true,false,clock_timestamp(),
    v_branch,v_staff,0,clock_timestamp(),'v108 holdout outcome'
  );

  perform set_config('request.jwt.claim.sub',v_owner_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_owner_user,'role','authenticated')::text,true
  );
  v_sale_result:=public.reverse_sale_fast_v84(
    v_business,v_sale,'v108 rollback reversal','v108-e2e-reversal'
  )::jsonb;
  v_reversal:=(v_sale_result->>'reversal_sale_id')::uuid;
  if v_reversal is null or not exists (
    select 1 from public.growth_entitlements_v108
    where id=v_treatment_entitlement and status='reversed'
      and redeemed_sale_id=v_sale and reversed_at is not null
  ) or not exists (
    select 1 from public.growth_entitlement_events_v108
    where entitlement_id=v_treatment_entitlement and event_type='reversed'
      and sale_id=v_reversal
  ) then
    raise exception
      'v108 reversal did not reverse entitlement cost/outcome evidence: result %, reversal %, entitlement %, status %, events %',
      v_sale_result,v_reversal,v_treatment_entitlement,
      (select status from public.growth_entitlements_v108 where id=v_treatment_entitlement),
      (select jsonb_agg(to_jsonb(ev)) from public.growth_entitlement_events_v108 ev
       where ev.entitlement_id=v_treatment_entitlement);
  end if;

  v_result:=public.get_growth_execution_result_v108(v_execution);
  if v_result->>'measurement_status'<>'provisional'
     or v_result->>'as_of' is null
     or (v_result#>>'{arms,treatment,members}')::integer<>20
     or (v_result#>>'{arms,holdout,members}')::integer<>5
     or (v_result#>>'{arms,treatment,buyers}')::integer<>1
     or (v_result#>>'{arms,holdout,buyers}')::integer<>1
     or (v_result#>>'{arms,treatment,associated_revenue_cents}')::bigint<>2000
     or (v_result#>>'{arms,holdout,associated_revenue_cents}')::bigint<>1000
     or (v_result#>>'{cost,actual_redeemed_cost_cents}')::bigint<>0
     or (v_result#>>'{cost,reversed_offer_cost_cents}')::bigint<>300 then
    raise exception 'v108 reversal-aware provisional result failed: %',v_result;
  end if;
  if (
    select count(*) from public.growth_outcomes_v108
    where execution_id=v_execution
  )<>3 then
    raise exception 'v108 qualifying treatment/holdout outcomes were not captured';
  end if;

  -- A reconciled external partial refund must update the already-persisted
  -- outcome, not merely alter a later reporting projection.
  v_sale_result:=public.ingest_external_commerce_event_v106(
    v_business,v_branch,'refund_completed',
    'v108.test.pos','refund-treatment',
    'v108-e2e-refund-treatment',
    clock_timestamp(),'SGD',-500,
    jsonb_build_object('fixture','v108 partial refund')
  )::jsonb;
  v_refund_event:=(v_sale_result->>'event_id')::uuid;
  perform public.reconcile_external_commerce_event_v106(
    v_refund_event,v_second_sale,'v108-e2e-refund-reconcile',
    jsonb_build_array(jsonb_build_object('amount_minor',500))
  );
  if (
    select revenue_cents
    from public.growth_outcomes_v108
    where execution_id=v_execution and sale_id=v_second_sale
  )<>1500 then
    raise exception
      'v108 reconciled partial refund did not update the persisted outcome: %',
      (select to_jsonb(o) from public.growth_outcomes_v108 o
       where o.execution_id=v_execution and o.sale_id=v_second_sale);
  end if;
  execute 'reset role';
  begin
    update public.growth_outcomes_v108
    set revenue_cents=1499
    where execution_id=v_execution and sale_id=v_second_sale;
    raise exception 'v108 outcome accepted a direct residual mutation';
  exception
    when integrity_constraint_violation then null;
  end;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_owner_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_owner_user,'role','authenticated')::text,true
  );
  v_result:=public.get_growth_execution_result_v108(v_execution);
  if (v_result#>>'{arms,treatment,associated_revenue_cents}')::bigint<>1500 then
    raise exception
      'v108 result did not reflect the reconciled partial refund: %',v_result;
  end if;

  execute 'reset role';
  v_closed_at:=clock_timestamp();
  update public.growth_executions_v108
  set ends_at=v_closed_at,
      offer_expires_at=v_closed_at,
      governed_copy=jsonb_set(
        jsonb_set(
          governed_copy,
          '{locked_facts,expires_at}',
          to_jsonb(v_closed_at)
        ),
        '{conditions,expires_at}',
        to_jsonb(v_closed_at)
      )
  where id=v_execution;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_owner_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_owner_user,'role','authenticated')::text,true
  );
  v_final:=public.finalize_growth_execution_v108(
    v_business,v_execution,v_final_key
  );
  if v_final->>'measurement_status' is distinct from 'final'
     or v_final->>'result_status' is distinct from 'inconclusive'
     or v_final->>'as_of' is null
     or (v_final#>>'{arms,treatment,associated_revenue_cents}')::bigint<>1500 then
    raise exception 'v108 final measurement/claim status failed: %',v_final;
  end if;
  v_final_replay:=public.finalize_growth_execution_v108(
    v_business,v_execution,v_final_key
  );
  if v_final_replay is distinct from v_final then
    raise exception 'v108 finalized result replay did not return the exact receipt: first %, replay %',
      v_final,v_final_replay;
  end if;
  begin
    perform public.finalize_growth_execution_v108(
      v_business,v_execution,gen_random_uuid()
    );
    raise exception 'v108 finalization accepted another idempotency key';
  exception
    when unique_violation then null;
  end;
  if not exists (
    select 1 from public.growth_execution_results_v108
    where execution_id=v_execution and result_status='inconclusive'
  ) or not exists (
    select 1 from public.growth_executions_v108
    where id=v_execution and status='completed' and completed_at is not null
  ) or not exists (
    select 1 from public.growth_recommendations_v108
    where id=v_recommendation and status='completed'
  ) then
    raise exception 'v108 final execution/recommendation/result lifecycle is incomplete';
  end if;
end
$e2e$;

reset role;
select 'V108 SUITE PASS' as result;
rollback;
