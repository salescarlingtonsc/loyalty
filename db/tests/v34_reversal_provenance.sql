-- v34 rolled-back security and structural regression suite.
-- Run only after the complete v20, v21, and v24a-v34 migration chain is present.
begin;

do $test$
declare
  v_name text;
  v_acl boolean;
  v_def text;
  v_redemption uuid;
  v_blocked boolean;
  v_drift integer;
begin
  -- v21 invariant: every public entry point is authenticated-only, SECURITY DEFINER,
  -- and has the pinned pg_catalog/public/app/pg_temp search_path.
  foreach v_name in array array[
    'use_package_session(uuid,uuid,text)',
    'reverse_sale(uuid,uuid,text,text,text,text)',
    'reverse_loyalty_redemption(uuid,uuid,text,text)'
  ] loop
    if to_regprocedure('public.' || v_name) is null then
      raise exception 'expected v34 RPC is missing: %', v_name;
    end if;
    select has_function_privilege('anon', to_regprocedure('public.'||v_name), 'EXECUTE')
      into v_acl;
    if v_acl then raise exception 'anon/PUBLIC must not execute %', v_name; end if;
    select has_function_privilege('authenticated', to_regprocedure('public.'||v_name), 'EXECUTE')
      into v_acl;
    if not v_acl then raise exception 'authenticated must execute %', v_name; end if;
    select pg_get_functiondef(to_regprocedure('public.'||v_name)) into v_def;
    if v_def not ilike '%SECURITY DEFINER%'
       or v_def not ilike '%pg_catalog%public%app%pg_temp%' then
      raise exception 'unsafe search_path or invoker function: %', v_name;
    end if;
  end loop;

  if has_function_privilege('authenticated', 'public.use_package_session(uuid,uuid)'::regprocedure, 'EXECUTE') then
    raise exception 'legacy keyless package session overload remains executable';
  end if;

  -- The immutable evidence model proves exact package session -> $0 sale relationships,
  -- exactly-one restoration, no refund/payment/money movement, and FEFO batch drains.
  if not exists (
    select 1 from pg_constraint where conrelid='public.package_session_consumptions'::regclass
      and contype='u' and pg_get_constraintdef(oid) ilike '%sale_id%'
  ) then raise exception 'package sale provenance uniqueness is missing'; end if;
  if not exists (
    select 1 from pg_constraint where conrelid='public.package_session_reversals'::regclass
      and contype='u' and pg_get_constraintdef(oid) ilike '%consumption_id%'
  ) then raise exception 'package session exactly-one restore evidence is missing'; end if;
  if not exists (
    select 1 from pg_constraint where conrelid='public.loyalty_redemption_batch_drains'::regclass
      and contype='u' and pg_get_constraintdef(oid) ilike '%redemption_id%points_batch_id%'
  ) then raise exception 'redemption FEFO drain uniqueness is missing'; end if;

  -- No direct authenticated writes to append-only provenance or loyalty_redemptions.
  if has_table_privilege('authenticated','public.loyalty_redemptions','INSERT,UPDATE,DELETE')
     or has_table_privilege('authenticated','public.loyalty_redemption_provenance','INSERT,UPDATE,DELETE')
     or has_table_privilege('authenticated','public.package_session_consumptions','INSERT,UPDATE,DELETE') then
    raise exception 'authenticated has forbidden provenance mutation privileges';
  end if;

  -- Exercise the immutable trigger against an existing row when the fixture has one.
  select id into v_redemption from public.loyalty_redemptions limit 1;
  if v_redemption is not null then
    v_blocked := false;
    begin
      update public.loyalty_redemptions set actor=actor where id=v_redemption;
    exception when restrict_violation then v_blocked := true;
    end;
    if not v_blocked then raise exception 'expected append-only UPDATE rejection'; end if;
    v_blocked := false;
    begin
      delete from public.loyalty_redemptions where id=v_redemption;
    exception when restrict_violation then v_blocked := true;
    end;
    if not v_blocked then raise exception 'expected immutable DELETE rejection'; end if;
  end if;

  -- Unauthenticated calls cannot cross business/tenant boundaries or impersonate staff/owner.
  v_blocked := false;
  begin
    perform public.use_package_session(gen_random_uuid(),gen_random_uuid(),'v34-test-key');
  exception when others then v_blocked := true;
  end;
  if not v_blocked then raise exception 'expected unauthorized package call to be forbidden'; end if;

  v_blocked := false;
  begin
    perform public.reverse_loyalty_redemption(
      gen_random_uuid(),gen_random_uuid(),'missing legacy provenance test','v34-reverse-key'
    );
  exception when others then v_blocked := true;
  end;
  if not v_blocked then raise exception 'expected missing/incomplete legacy provenance rejection'; end if;

  -- The v20 positive-sale reverse_sale path remains installed behind the v34 wrapper.
  if to_regprocedure('public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)') is null
     or has_function_privilege('authenticated',
          'public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)'::regprocedure,'EXECUTE') then
    raise exception 'v20 base reversal must exist and remain internal';
  end if;

  -- Ledger/batch invariant used by the behavioral fixtures after redeem, replay, conflict,
  -- exact reversal, and exact replay. A complete fixture must compare these two expressions:
  -- sum(points_ledger.points) == sum(points_batches.remaining).
  select count(*) into v_drift from (
    select pl.business_id,pl.client_id,sum(pl.points) as ledger_points
      from public.points_ledger pl group by pl.business_id,pl.client_id
  ) x full join (
    select pb.business_id,pb.client_id,sum(pb.remaining) as batch_remaining
      from public.points_batches pb group by pb.business_id,pb.client_id
  ) y using(business_id,client_id)
  where coalesce(x.ledger_points,0)<>coalesce(y.batch_remaining,0);
  if v_drift <> 0 then
    raise exception 'points ledger and batch remaining invariant differs for % client balances',v_drift;
  end if;
  perform (
    select count(*) from (
      select pl.business_id,pl.client_id,sum(pl.points) as ledger_points
        from public.points_ledger pl group by pl.business_id,pl.client_id
    ) x full join (
      select pb.business_id,pb.client_id,sum(pb.remaining) as batch_remaining
        from public.points_batches pb group by pb.business_id,pb.client_id
    ) y using(business_id,client_id)
    where coalesce(x.ledger_points,0)<>coalesce(y.batch_remaining,0)
  );
end $test$;

do $behavior$
declare
  v_business uuid; v_owner uuid; v_owner_staff uuid; v_branch uuid;
  v_client uuid; v_service uuid; v_product uuid; v_plan uuid; v_cp uuid;
  v_sale uuid; v_reverse json; v_reversal_sale uuid; v_before integer;
  v_draft uuid; v_next_draft uuid; v_reward uuid; v_reward_version uuid;
  v_redeem json; v_redemption uuid; v_loyalty_reverse json; v_legacy uuid;
  v_old_config uuid; v_blocked boolean;
begin
  select s.business_id,s.user_id,s.id into v_business,v_owner,v_owner_staff
    from public.staff s where s.role='owner' and s.active and s.user_id is not null
    order by s.created_at limit 1;
  if v_business is null then raise exception 'v34 behavioral suite requires an active owner fixture'; end if;
  perform set_config('request.jwt.claims',json_build_object('sub',v_owner,'role','authenticated')::text,true);
  select id into v_branch from public.branches
   where business_id=v_business and active order by is_default desc,created_at limit 1;
  if v_branch is null then
    insert into public.branches(business_id,name,is_default,active)
    values(v_business,'v34 fixture branch',true,true) returning id into v_branch;
  end if;
  insert into public.clients(business_id,full_name)
  values(v_business,'v34 provenance client') returning id into v_client;
  insert into public.services(business_id,name,price_cents,duration_min,active)
  values(v_business,'v34 package service',1000,30,true) returning id into v_service;
  insert into public.service_branches(business_id,service_id,branch_id)
  values(v_business,v_service,v_branch) on conflict do nothing;
  insert into public.package_plans(business_id,name,price_cents,sessions,service_id,active)
  values(v_business,'v34 two sessions',2000,2,v_service,true) returning id into v_plan;
  insert into public.client_packages(business_id,client_id,plan_id,remaining,status)
  values(v_business,v_client,v_plan,2,'active') returning id into v_cp;

  if public.use_package_session(v_business,v_cp,'v34-package-use') <> 1
     or public.use_package_session(v_business,v_cp,'v34-package-use') <> 1 then
    raise exception 'package idempotent replay changed remaining sessions';
  end if;
  select sale_id into v_sale from public.package_session_consumptions
   where business_id=v_business and idempotency_key='v34-package-use';
  if v_sale is null or (select count(*) from public.package_session_consumptions where sale_id=v_sale)<>1
     or (select amount_cents from public.sales where id=v_sale)<>0 then
    raise exception 'package use did not create exactly one proven zero-dollar sale';
  end if;
  v_blocked:=false;
  begin
    perform public.use_package_session(v_business,gen_random_uuid(),'v34-package-use');
  exception when unique_violation then v_blocked:=true;
  end;
  if not v_blocked then raise exception 'package idempotency conflict was not rejected'; end if;
  v_reverse:=public.reverse_sale(v_business,v_sale,'v34 package session reversal','v34-package-reverse');
  v_reversal_sale:=(v_reverse->>'reversal_sale_id')::uuid;
  if (select remaining from public.client_packages where id=v_cp)<>2
     or (select count(*) from public.package_session_reversals where original_sale_id=v_sale)<>1
     or (select amount_cents from public.sales where id=v_reversal_sale)<>0
     or exists(select 1 from public.payments where sale_id in(v_sale,v_reversal_sale)) then
    raise exception 'package reversal did not restore exactly one session without money refund';
  end if;
  if public.reverse_sale(v_business,v_sale,'v34 package session reversal','v34-package-reverse')->>'replayed'<>'true' then
    raise exception 'package reversal replay was not stable';
  end if;

  update public.staff set active=false where id=v_owner_staff;
  v_blocked:=false;
  begin
    perform public.use_package_session(v_business,v_cp,'v34-inactive-staff');
  exception when insufficient_privilege then v_blocked:=true;
  end;
  update public.staff set active=true where id=v_owner_staff;
  if not v_blocked then raise exception 'inactive staff consumed a package session'; end if;

  insert into public.products(business_id,name,retail_price_cents,active)
  values(v_business,'v34 reward product',500,true) returning id into v_product;
  v_draft:=(public.create_loyalty_config_draft(v_business,null,'v34_test')->>'version_id')::uuid;
  perform public.save_loyalty_config_draft(v_draft,jsonb_build_object(
    'active',true,'kind','points','loyalty_model','points_tiers',
    'reward',jsonb_build_object('business_id',v_business,
      'name','v34 reward','customer_name','v34 reward','fulfillment_kind','credit',
      'cost_points',20,'credit_cents',100,'estimated_cost_cents',50,'active',true),
    'reward_branch_ids',jsonb_build_array(v_branch),
    'reward_service_ids',jsonb_build_array(v_service),
    'reward_product_ids',jsonb_build_array(v_product)
  ));
  select reward_id, id into v_reward, v_reward_version
    from public.loyalty_reward_versions
   where config_version_id=v_draft and customer_name='v34 reward';
  perform public.publish_loyalty_config(v_draft);
  v_old_config:=v_draft;
  perform public.adjust_points(v_business,v_client,100,'v34 provenance fixture');
  v_redeem:=public.redeem_reward_at_context(
    v_business,v_client,v_reward,'v34-redeem-reward',v_branch,v_service,v_product
  );
  v_redemption:=(v_redeem->>'redemption_id')::uuid;
  if v_redemption is null
     or (select coalesce(sum(drained_points),0) from public.loyalty_redemption_batch_drains
          where redemption_id=v_redemption)<>20
     or not exists(select 1 from public.loyalty_redemption_provenance
          where redemption_id=v_redemption and config_version_id=v_old_config) then
    raise exception 'reward redemption did not capture exact operation/ledger/FEFO provenance';
  end if;
  v_next_draft:=(public.create_loyalty_config_draft(v_business,v_old_config,'v34_next')->>'version_id')::uuid;
  perform public.publish_loyalty_config(v_next_draft);
  v_loyalty_reverse:=public.reverse_loyalty_redemption(
    v_business,v_redemption,'v34 exact reward reversal','v34-reward-reverse'
  );
  if (v_loyalty_reverse->>'restored_points')::integer<>20
     or (select config_version_id from public.points_ledger
          where id=(select restored_points_ledger_id from public.loyalty_redemption_reversals
                     where redemption_id=v_redemption)) is distinct from v_old_config
     or (select config_version_id from public.credit_ledger
          where id=(select reversed_credit_ledger_id from public.loyalty_redemption_reversals
                     where redemption_id=v_redemption)) is distinct from v_old_config then
    raise exception 'reward reversal did not retain exact historical configuration provenance';
  end if;
  if public.reverse_loyalty_redemption(
       v_business,v_redemption,'v34 exact reward reversal','v34-reward-reverse'
     )->>'replayed'<>'true' then raise exception 'reward reversal replay was not stable'; end if;
  if (select coalesce(sum(points),0) from public.points_ledger where business_id=v_business and client_id=v_client)
     <> (select coalesce(sum(remaining),0) from public.points_batches where business_id=v_business and client_id=v_client) then
    raise exception 'fixture points ledger and batch remaining diverged after reversal';
  end if;

  insert into public.loyalty_redemptions
    (business_id,client_id,reward_id,reward_name,points_spent,credit_cents,actor,
     reward_snapshot,eligibility_snapshot,fulfillment_kind,usage_number)
  values(v_business,v_client,v_reward,'v34 legacy',1,0,v_owner,
    jsonb_build_object('legacy',true),jsonb_build_object('legacy',true),'manual_item',99)
  returning id into v_legacy;
  v_blocked:=false;
  begin
    perform public.reverse_loyalty_redemption(
      v_business,v_legacy,'v34 legacy evidence rejection','v34-legacy-reverse'
    );
  exception when others then
    if position('provenance' in sqlerrm)>0 then v_blocked:=true; else raise; end if;
  end;
  if not v_blocked then raise exception 'legacy redemption without provenance was accepted'; end if;
  raise notice 'v34 behavioral suite: ALL PASS';
end $behavior$;

-- Fixture scenarios required before release acceptance:
-- These scenarios exercise idempotency, including exact replay and key conflicts.
-- 1. use_package_session exact replay returns one sale and one consumption; conflicting payload fails.
-- 2. reverse_sale on that zero/$0 sale restores remaining exactly once and creates no refund payment.
-- 3. cross-business and inactive staff calls are forbidden.
-- 4. reward redemption captures operation, loyalty_redemptions, points_ledger,
--    optional credit_ledger and every FEFO points_batches drain.
-- 5. reverse_loyalty_redemption restores exact batches, appends positive points and exact
--    credit clawback; replay is stable; legacy/missing provenance evidence is refused.
-- 6. v20 and v21 regression suites remain green after the full chain.

rollback;
