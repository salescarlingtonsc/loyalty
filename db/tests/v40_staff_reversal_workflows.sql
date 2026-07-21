-- v40 rolled-back staff reversal workflow suite.
-- Run after the complete v20-v40 chain; v34 suite remains the authoritative loyalty
-- compensation/FEFO reconciliation fixture and must run immediately before this suite.
begin;

create or replace function pg_temp.as_v40_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role',p_role)::text,true);
end $$;
grant execute on function pg_temp.as_v40_user(uuid,text) to public;

do $v40$
declare
  v_business uuid; v_owner uuid; v_owner_staff uuid;
  v_manager uuid:=gen_random_uuid(); v_manager_staff uuid;
  v_staff_user uuid:=gen_random_uuid(); v_staff_id uuid;
  v_branch uuid; v_other_branch uuid; v_client uuid; v_service uuid; v_product uuid; v_plan uuid; v_cp uuid;
  v_sale uuid; v_result json; v_read jsonb; v_blocked boolean;
  v_draft uuid; v_reward uuid; v_redemption uuid; v_redeem json;
  v_reward_version uuid; v_missing_credit uuid; v_mismatch_credit uuid; v_spent_credit uuid;
  v_bad_credit uuid:=gen_random_uuid(); v_spend_sale uuid;
  v_loyalty_result json; v_ledger integer; v_batches integer;
  v_name text; v_def text;
begin
  foreach v_name in array array[
    'reverse_sale(uuid,uuid,text,text,text,text)',
    'reverse_loyalty_redemption(uuid,uuid,text,text)',
    'staff_get_reversal_workflows(uuid,uuid,integer,text)'
  ] loop
    if to_regprocedure('public.'||v_name) is null then raise exception 'missing v40 RPC %',v_name; end if;
    if has_function_privilege('anon',to_regprocedure('public.'||v_name),'EXECUTE')
       or not has_function_privilege('authenticated',to_regprocedure('public.'||v_name),'EXECUTE') then
      raise exception 'v40 RPC ACL is not authenticated-only: %',v_name;
    end if;
    select pg_get_functiondef(to_regprocedure('public.'||v_name)) into v_def;
    if v_def not ilike '%SECURITY DEFINER%'
       or v_def not ilike '%pg_catalog%public%app%pg_temp%' then
      raise exception 'v40 RPC lacks safe definer/search_path: %',v_name;
    end if;
  end loop;
  if to_regprocedure('public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text)') is null
     or has_function_privilege('authenticated',
       'public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text)'::regprocedure,'EXECUTE') then
    raise exception 'v34 loyalty compensation base must exist and remain internal';
  end if;
  if to_regprocedure('public.reverse_sale_v34_base(uuid,uuid,text,text,text,text)') is null
     or has_function_privilege('authenticated',
       'public.reverse_sale_v34_base(uuid,uuid,text,text,text,text)'::regprocedure,'EXECUTE') then
    raise exception 'v34 sale reversal base must exist and remain internal';
  end if;

  select s.business_id,s.user_id,s.id into v_business,v_owner,v_owner_staff
    from public.staff s
   where s.role='owner' and s.active and s.user_id is not null
   order by s.created_at,s.id limit 1;
  if v_business is null then raise exception 'v40 suite requires one active owner fixture'; end if;
  select id into v_branch from public.branches
   where business_id=v_business and active order by is_default desc,created_at,id limit 1;
  if v_branch is null then raise exception 'v40 suite requires one active branch fixture'; end if;

  reset role;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values('00000000-0000-0000-0000-000000000000',v_staff_user,'authenticated','authenticated',
    'v40-restricted-'||substr(v_staff_user::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_manager,'authenticated','authenticated',
    'v40-manager-'||substr(v_manager::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_staff_user,'frontdesk','V40 restricted frontdesk',true) returning id into v_staff_id;
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_manager,'manager','V40 authorized manager',true) returning id into v_manager_staff;
  insert into public.branches(business_id,name,is_default,active)
  values(v_business,'V40 restricted branch',false,true) returning id into v_other_branch;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business,v_staff_id,v_other_branch),(v_business,v_manager_staff,v_branch);
  insert into public.clients(business_id,full_name)
  values(v_business,'V40 reversal client') returning id into v_client;
  insert into public.services(business_id,name,price_cents,duration_min,active)
  values(v_business,'V40 package service',1000,30,true) returning id into v_service;
  insert into public.service_branches(business_id,service_id,branch_id)
  values(v_business,v_service,v_branch) on conflict do nothing;
  insert into public.package_plans(business_id,name,price_cents,sessions,service_id,active)
  values(v_business,'V40 two sessions',2000,2,v_service,true) returning id into v_plan;
  insert into public.client_packages(business_id,client_id,plan_id,remaining,status)
  values(v_business,v_client,v_plan,2,'active') returning id into v_cp;

  perform pg_temp.as_v40_user(v_staff_user);
  v_blocked:=false;
  begin perform public.staff_get_reversal_workflows(v_business,v_client,10);
  exception when insufficient_privilege then v_blocked:=true; end;
  if not v_blocked then raise exception 'restricted ordinary staff read reversal workflow'; end if;

  perform pg_temp.as_v40_user(v_owner);
  perform public.use_package_session(v_business,v_cp,'v40-package-use');
  reset role;
  select sale_id into v_sale from public.package_session_consumptions
   where business_id=v_business and idempotency_key='v40-package-use';
  perform pg_temp.as_v40_user(v_owner);
  v_blocked:=false;
  begin perform public.staff_get_reversal_workflows(v_business,v_client,10,'unsupported');
  exception when invalid_parameter_value then v_blocked:=true; end;
  if not v_blocked then raise exception 'unsupported reversal workflow mode was accepted'; end if;
  v_read:=public.staff_get_reversal_workflows(v_business,v_client,10,'package');
  if v_read->>'mode'<>'package' or (v_read->>'limit')::integer<>10
     or coalesce((v_read->>'bounded')::boolean,false) is not true
     or jsonb_array_length(v_read->'redemptions')<>0
     or exists (
       select 1 from jsonb_array_elements(v_read->'sales') x
        where not (x->>'is_package_session')::boolean
     ) then
    raise exception 'package mode did not remain bounded and package-only: %',v_read;
  end if;
  if not exists (
    select 1 from jsonb_array_elements(v_read->'sales') x
     where (x->>'id')::uuid=v_sale
       and (x->>'can_reverse')::boolean
       and (x->>'is_package_session')::boolean
       and (x->>'no_money_refund')::boolean
       and (x->>'net_amount_cents')::integer=0
  ) then raise exception 'package session was not projected as a reversible no-refund workflow: %',v_read; end if;

  -- A manager is an independently authorized refund actor, not merely an owner alias.
  perform pg_temp.as_v40_user(v_manager);
  v_result:=public.reverse_sale(v_business,v_sale,'v40 package correction reason',
    'v40-package-reverse','V40 case reference','none');
  if (v_result->>'restored_sessions')::integer<>1
     or coalesce((v_result->>'no_money_refund')::boolean,false) is not true
     or (select remaining from public.client_packages where id=v_cp)<>2
     or exists(select 1 from public.payments where sale_id in(v_sale,(v_result->>'reversal_sale_id')::uuid)) then
    raise exception 'package workflow did not restore exactly once without a payment refund: %',v_result;
  end if;
  if public.reverse_sale(v_business,v_sale,'v40 package correction reason',
       'v40-package-reverse','V40 case reference','none')->>'replayed'<>'true' then
    raise exception 'exact package reversal replay did not return completed result';
  end if;
  v_blocked:=false;
  begin
    perform public.reverse_sale(v_business,v_sale,'v40 changed correction reason',
      'v40-package-reverse','V40 case reference','none');
  exception when unique_violation then v_blocked:=true; end;
  if not v_blocked then raise exception 'changed package reversal request did not conflict'; end if;
  v_blocked:=false;
  begin
    perform public.reverse_sale(v_business,v_sale,'v40 package correction reason',
      'v40-package-reverse','V40 changed case reference','none');
  exception when unique_violation then v_blocked:=true; end;
  if not v_blocked then raise exception 'changed package reversal reference did not conflict'; end if;

  v_read:=public.staff_get_reversal_workflows(v_business,v_client,10,'package');
  if not exists (
    select 1 from jsonb_array_elements(v_read->'sales') x
     where (x->>'id')::uuid=v_sale
       and not (x->>'can_reverse')::boolean
       and (x->>'reversal_sale_id')::uuid=(v_result->>'reversal_sale_id')::uuid
       and x->'completed_result'->>'no_money_refund'='true'
       and (x->>'net_amount_cents')::integer=0
  ) then raise exception 'completed package relationship/result is missing from read model: %',v_read; end if;
  if not exists (
    select 1 from jsonb_array_elements(v_read->'sales') x
     where (x->>'id')::uuid=(v_result->>'reversal_sale_id')::uuid
       and (x->>'is_reversal')::boolean
       and (x->>'is_package_session')::boolean
       and (x->>'net_amount_cents')::integer=0
  ) then raise exception 'package reversal row did not expose the same zero relationship net: %',v_read; end if;
  if v_read::text ~ '"(operation_id|payment_refund_ids|effects)"' then
    raise exception 'staff reversal read leaked internal operation/payment result fields: %',v_read;
  end if;

  -- Build a fresh exact-provenance redemption, then exercise the v40 public wrapper as
  -- manager. This duplicates the critical compensation assertions instead of assuming
  -- that data from the separately rolled-back v34 suite is still present.
  perform pg_temp.as_v40_user(v_owner);
  insert into public.products(business_id,name,retail_price_cents,active)
  values(v_business,'V40 reward product',500,true) returning id into v_product;
  v_draft:=(public.create_loyalty_config_draft(v_business,null,'v40-reversal-suite')::jsonb->>'version_id')::uuid;
  perform public.save_loyalty_config_draft(v_draft,jsonb_build_object(
    'active',true,'kind','points','loyalty_model','points_tiers',
    'reward',jsonb_build_object(
      'internal_name','V40 internal reward',
      'customer_name','V40 reversible reward','fulfillment_kind','credit',
      'cost_points',20,'credit_cents',100,'estimated_cost_cents',50,'active',true
    ),
    'reward_branch_ids',jsonb_build_array(v_branch),
    'reward_service_ids',jsonb_build_array(v_service),
    'reward_product_ids',jsonb_build_array(v_product)
  ),null);
  reset role;
  select rv.reward_id,rv.id into v_reward,v_reward_version from public.loyalty_reward_versions rv
   where rv.config_version_id=v_draft and rv.customer_name='V40 reversible reward';
  if v_reward is null then raise exception 'v40 reward fixture was not created'; end if;
  perform pg_temp.as_v40_user(v_owner);
  perform public.publish_loyalty_config(v_draft);
  perform public.adjust_points(v_business,v_client,100,'v40 loyalty compensation fixture');
  v_redeem:=public.redeem_reward_at_context(
    v_business,v_client,v_reward,'v40-reward-redeem',v_branch,v_service,v_product
  );
  v_redemption:=(v_redeem->>'redemption_id')::uuid;
  if v_redemption is null then raise exception 'v40 loyalty fixture did not redeem'; end if;

  perform pg_temp.as_v40_user(v_manager);
  v_loyalty_result:=public.reverse_loyalty_redemption(
    v_business,v_redemption,'v40 exact loyalty correction','v40-loyalty-reverse'
  );
  if (v_loyalty_result->>'restored_points')::integer<>20
     or (v_loyalty_result->>'reversed_credit_cents')::integer<>100 then
    raise exception 'manager loyalty compensation result is incomplete: %',v_loyalty_result;
  end if;
  if public.reverse_loyalty_redemption(
       v_business,v_redemption,'v40 exact loyalty correction','v40-loyalty-reverse'
     )->>'replayed'<>'true' then
    raise exception 'exact loyalty reversal replay did not return completed result';
  end if;
  v_blocked:=false;
  begin
    perform public.reverse_loyalty_redemption(
      v_business,v_redemption,'v40 changed loyalty correction','v40-loyalty-reverse'
    );
  exception when unique_violation then v_blocked:=true; end;
  if not v_blocked then raise exception 'changed loyalty reversal request did not conflict'; end if;
  select coalesce(sum(points),0)::integer into v_ledger from public.points_ledger
   where business_id=v_business and client_id=v_client;
  select coalesce(sum(remaining),0)::integer into v_batches from public.points_batches
   where business_id=v_business and client_id=v_client;
  if v_ledger<>v_batches then
    raise exception 'v40 loyalty compensation diverged ledger % from FEFO batches %',v_ledger,v_batches;
  end if;
  v_read:=public.staff_get_reversal_workflows(v_business,v_client,20);
  if not exists (
    select 1 from jsonb_array_elements(v_read->'redemptions') x
     where (x->>'id')::uuid=v_redemption
       and not (x->>'can_reverse')::boolean
       and x->'completed_result'->>'restored_points'='20'
       and (x->>'has_exact_provenance')::boolean
       and not (x->>'credit_may_be_spent')::boolean
  ) then raise exception 'completed loyalty result/provenance is missing from read model: %',v_read; end if;

  -- Corrupted or consumed credit evidence must fail closed at both read and mutation
  -- boundaries. This rolled-back adversarial harness uses the same narrowly scoped
  -- internal ledger seam as the application, then disables only the named provenance
  -- immutability trigger long enough to model damage that production prevents.
  perform pg_temp.as_v40_user(v_owner);
  perform public.adjust_points(v_business,v_client,60,'v40 adverse credit fixtures');
  v_redeem:=public.redeem_reward_at_context(v_business,v_client,v_reward,
    'v40-missing-credit',v_branch,v_service,v_product);
  v_missing_credit:=(v_redeem->>'redemption_id')::uuid;
  v_redeem:=public.redeem_reward_at_context(v_business,v_client,v_reward,
    'v40-mismatch-credit',v_branch,v_service,v_product);
  v_mismatch_credit:=(v_redeem->>'redemption_id')::uuid;
  v_redeem:=public.redeem_reward_at_context(v_business,v_client,v_reward,
    'v40-spent-credit',v_branch,v_service,v_product);
  v_spent_credit:=(v_redeem->>'redemption_id')::uuid;
  reset role;
  perform set_config('app.credit_ledger_insert_id',v_bad_credit::text,true);
  perform set_config('app.credit_ledger_write_scope','redeem_points',true);
  insert into public.credit_ledger(
    id,business_id,client_id,entry_type,amount_cents,reference,actor,config_version_id
  ) values(
    v_bad_credit,v_business,v_client,'loyalty_earn',999,
    'v40 deliberately mismatched credit evidence',v_owner,v_draft
  );
  perform set_config('app.credit_ledger_insert_id','',true);
  perform set_config('app.credit_ledger_write_scope','',true);
  execute 'set constraints all immediate';
  execute 'alter table public.loyalty_redemption_provenance disable trigger trg_loyalty_redemption_provenance_immutable';
  update public.loyalty_redemption_provenance
     set credit_ledger_id=null where redemption_id=v_missing_credit;
  update public.loyalty_redemption_provenance
     set credit_ledger_id=v_bad_credit where redemption_id=v_mismatch_credit;
  execute 'alter table public.loyalty_redemption_provenance enable trigger trg_loyalty_redemption_provenance_immutable';

  perform pg_temp.as_v40_user(v_owner);
  insert into public.sales(business_id,branch_id,client_id,kind,amount_cents,note)
  values(v_business,v_branch,v_client,'service',100,'v40 spent-credit proof sale')
  returning id into v_spend_sale;
  perform public.record_credit_tender(
    v_business,v_spend_sale,100,'v40 consume reward credit','v40-spent-tender'
  );

  perform pg_temp.as_v40_user(v_manager);
  v_blocked:=false;
  begin
    perform public.reverse_loyalty_redemption(v_business,v_missing_credit,
      'v40 missing source refusal','v40-missing-reverse');
  exception when others then
    if position('credit provenance is missing' in sqlerrm)>0 then v_blocked:=true; else raise; end if;
  end;
  if not v_blocked then raise exception 'missing source credit provenance was reversible'; end if;
  v_blocked:=false;
  begin
    perform public.reverse_loyalty_redemption(v_business,v_mismatch_credit,
      'v40 mismatched source refusal','v40-mismatch-reverse');
  exception when others then
    if position('does not match' in sqlerrm)>0 then v_blocked:=true; else raise; end if;
  end;
  if not v_blocked then raise exception 'mismatched source credit provenance was reversible'; end if;
  v_blocked:=false;
  begin
    perform public.reverse_loyalty_redemption(v_business,v_spent_credit,
      'v40 spent source refusal','v40-spent-reverse');
  exception when others then
    if position('may have been spent' in sqlerrm)>0 then v_blocked:=true; else raise; end if;
  end;
  if not v_blocked then raise exception 'spent reward credit was reversible'; end if;
  v_read:=public.staff_get_reversal_workflows(v_business,v_client,30);
  if not exists(select 1 from jsonb_array_elements(v_read->'redemptions') x
      where (x->>'id')::uuid=v_missing_credit and not (x->>'has_exact_provenance')::boolean
        and x->>'refusal_reason' ilike '%missing%')
     or not exists(select 1 from jsonb_array_elements(v_read->'redemptions') x
      where (x->>'id')::uuid=v_mismatch_credit and not (x->>'has_exact_provenance')::boolean
        and x->>'refusal_reason' ilike '%does not match%')
     or not exists(select 1 from jsonb_array_elements(v_read->'redemptions') x
      where (x->>'id')::uuid=v_spent_credit and (x->>'credit_may_be_spent')::boolean
        and x->>'refusal_reason' ilike '%spent%') then
    raise exception 'read model did not fail closed for missing/mismatched/spent credit: %',v_read;
  end if;

  -- The current role vocabulary gives refund_sales only to owner/manager, both global to
  -- a firm. Temporarily grant the restricted frontdesk refund permission inside this
  -- rolled-back harness to prove the v40 branch predicate remains effective if a firm later
  -- delegates refunds to branch staff. Rollback restores the canonical role function.
  reset role;
  execute $ddl$
    create or replace function app.role_perms(p_role text)
    returns text[] language sql immutable as $body$
      select case p_role
        when 'owner' then array['view_sales','create_sales','refund_sales','reclassify_sales','view_finance','manage_sale_policy']
        when 'manager' then array['view_sales','create_sales','refund_sales','view_finance']
        when 'stylist' then array['view_sales','create_sales']
        when 'frontdesk' then array['view_sales','create_sales','refund_sales']
        else array[]::text[]
      end
    $body$
  $ddl$;
  perform pg_temp.as_v40_user(v_staff_user);
  v_blocked:=false;
  begin
    perform public.reverse_loyalty_redemption(
      v_business,v_redemption,'v40 restricted branch denial','v40-branch-denial'
    );
  exception when insufficient_privilege then
    if position('branch scope' in sqlerrm)>0 then v_blocked:=true; else raise; end if;
  end;
  if not v_blocked then raise exception 'refund-authorized restricted staff crossed redemption branch scope'; end if;
  v_read:=public.staff_get_reversal_workflows(v_business,v_client,20);
  if exists(select 1 from jsonb_array_elements(v_read->'redemptions') x where (x->>'id')::uuid=v_redemption) then
    raise exception 'restricted branch read model exposed another branch redemption';
  end if;

  perform pg_temp.as_v40_user(v_manager);
  v_blocked:=false;
  begin perform public.staff_get_reversal_workflows(gen_random_uuid(),v_client,10);
  exception when insufficient_privilege then v_blocked:=true; end;
  if not v_blocked then raise exception 'authorized manager crossed the business/tenant boundary'; end if;

  reset role;
  update public.staff set active=false where id=v_owner_staff;
  perform pg_temp.as_v40_user(v_owner);
  v_blocked:=false;
  begin perform public.staff_get_reversal_workflows(v_business,v_client,10);
  exception when insufficient_privilege then v_blocked:=true; end;
  reset role;
  update public.staff set active=true where id=v_owner_staff;
  if not v_blocked then raise exception 'inactive owner retained reversal workflow authority'; end if;

  perform pg_temp.as_v40_user(gen_random_uuid());
  v_blocked:=false;
  begin perform public.reverse_sale(v_business,v_sale,'v40 customer denial reason','v40-customer-denial','case','none');
  exception when insufficient_privilege then v_blocked:=true; end;
  if not v_blocked then raise exception 'customer/non-staff principal reached sale reversal'; end if;

  reset role;
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{"role":"anon"}',true);
  set local role anon;
  v_blocked:=false;
  begin perform public.staff_get_reversal_workflows(v_business,v_client,10);
  exception when insufficient_privilege then v_blocked:=true; end;
  if not v_blocked then raise exception 'anon executed staff reversal workflow read'; end if;

  raise notice 'v40 staff reversal workflow suite: ALL PASS';
end $v40$;

rollback;
