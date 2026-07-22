-- Rollback-only v27 rich rewards suite. Run after v26 and v27 in a rehearsal database.
begin;
\ir fixtures/pristine_chain_fixture.psql

do $v27_test$
declare
  v_business uuid; v_owner uuid; v_other_business uuid; v_branch uuid; v_other_branch uuid;
  v_service uuid; v_product uuid; v_client uuid; v_draft uuid; v_reward uuid; v_manual_reward uuid; v_reward_version uuid; v_tier uuid;
  v_result json; v_redemption json; v_redemption_id uuid; v_snapshot jsonb; v_eligibility_snapshot jsonb;
begin
  select business_id, user_id into v_business, v_owner
    from public.staff
   where role = 'owner' and active and user_id is not null
   order by created_at limit 1;
  if v_business is null then raise exception 'v27 suite requires an active owner'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub',v_owner,'role','authenticated')::text, true);
  if exists (
    select 1 from public.loyalty_rewards
     where internal_name is null or customer_name is null or fulfillment_kind is null or estimated_cost_cents is null
  ) then raise exception 'v27 backfill left a legacy reward without required compatibility fields'; end if;

  -- Create an isolated second firm so the composite FK checks a real cross-tenant identifier.
  v_result := public.create_business(
    'v27 other tenant', 'v27-' || substr(md5(clock_timestamp()::text),1,16), 'other', array['loyalty']
  );
  v_other_business := (v_result->>'id')::uuid;
  select id into v_other_branch from public.branches where business_id=v_other_business and is_default;
  select id into v_branch from public.branches where business_id=v_business and is_default;
  if v_branch is null then
    insert into public.branches(business_id,name,is_default,active) values(v_business,'v27 branch',true,true) returning id into v_branch;
  end if;
  insert into public.services(business_id,name,price_cents,duration_min,active)
    values(v_business,'v27 eligible service',1000,30,true) returning id into v_service;
  insert into public.products(business_id,name,retail_price_cents,active)
    values(v_business,'v27 eligible product',500,true) returning id into v_product;
  insert into public.clients(business_id,full_name) values(v_business,'v27 reward client') returning id into v_client;

  v_result := public.create_loyalty_config_draft(v_business, null, 'v27_test');
  v_draft := (v_result->>'version_id')::uuid;
  perform public.save_loyalty_config_draft(v_draft, jsonb_build_object(
    'active',true,'kind','points','loyalty_model','points_tiers','redeem_points',50,'reward_credit_cents',100,'stamp_target',7,
    'reward',jsonb_build_object(
      'business_id',v_business,'name','v27 staff name','customer_name','v27 $1 reward',
      'description','Rich reward contract fixture','fulfillment_kind','credit',
      'taxonomy_label','Member reward','cost_points',20,'credit_cents',100,
      'estimated_cost_cents',60,'active',true,'sort',1,
      'claim_available_from',now() - interval '1 minute','entitlement_expiry_days',30,'usage_limit',1,
      'instructions','Apply at checkout','terms','One use per customer',
      'image_ref','https://cdn.example.test/rewards/v27-reward.webp'
    ),
    'reward_branch_ids',jsonb_build_array(v_branch),
    'reward_service_ids',jsonb_build_array(v_service),
    'reward_product_ids',jsonb_build_array(v_product)
  ));
  select reward_id into v_reward
    from public.loyalty_reward_versions
   where config_version_id=v_draft and customer_name='v27 $1 reward';
  v_tier:=gen_random_uuid();
  perform public.save_loyalty_config_draft(v_draft,jsonb_build_object(
    'tier',jsonb_build_object('id',v_tier,'name','v27 Gold','threshold',10,
      'points_multiplier',1.5,'perk_note','fixture perk','active',true)
  ));
  select id into v_reward_version from public.loyalty_reward_versions
   where reward_id=v_reward and config_version_id=v_draft;
  if v_reward_version is null then raise exception 'UI reward envelope did not create a draft reward version'; end if;
  if (select stamp_target from public.loyalty_program_versions where config_version_id=v_draft) <> 7 then
    raise exception 'v27 save wrapper dropped v26 stamp_target edits';
  end if;
  perform public.save_loyalty_config_draft(v_draft, jsonb_build_object(
    'reward',jsonb_build_object(
      'business_id',v_business,'name','v27 manual item',
      'customer_name','v27 manual item','cost_points',5,'credit_cents',0,
      'estimated_cost_cents',25,'fulfillment_kind','manual_item','active',true
    ),
    'reward_branch_ids','[]'::jsonb,'reward_service_ids','[]'::jsonb,'reward_product_ids','[]'::jsonb
  ));
  select reward_id into v_manual_reward
    from public.loyalty_reward_versions
   where config_version_id=v_draft and customer_name='v27 manual item';
  if not exists (
    select 1 from public.loyalty_reward_versions
     where reward_id=v_manual_reward and config_version_id=v_draft and fulfillment_kind='manual_item'
  ) then raise exception 'manual-item reward was rejected by the v27 fulfillment contract'; end if;

  begin
    insert into public.loyalty_reward_branches(reward_version_id,reward_id,business_id,branch_id)
      values(v_reward_version,v_reward,v_business,v_other_branch);
    raise exception 'cross-tenant branch eligibility unexpectedly succeeded';
  exception when foreign_key_violation then null;
  end;

  perform public.publish_loyalty_config(v_draft);
  if not exists(select 1 from public.loyalty_tiers
    where id=v_tier and business_id=v_business and points_multiplier=1.5) then
    raise exception 'published tier compatibility projection was not updated';
  end if;
  if (select current_config_version_id from public.loyalty_rewards where id=v_reward) is distinct from v_draft then
    raise exception 'published reward compatibility projection was not updated';
  end if;
  begin
    update public.loyalty_reward_versions set customer_name='tampered' where id=v_reward_version;
    raise exception 'published reward version was mutable';
  exception when restrict_violation then null;
  end;

  perform public.adjust_points(v_business,v_client,100,'v27 rich reward fixture');
  begin
    perform public.redeem_reward(v_business,v_client,v_reward,'v27-unscoped-key');
    raise exception 'restricted reward redeemed without contextual proof';
  exception when others then
    if position('eligible' in sqlerrm) = 0 then raise; end if;
  end;
  v_redemption := public.redeem_reward_at_context(
    v_business,v_client,v_reward,'v27-context-key',v_branch,v_service,v_product
  );
  if (v_redemption->>'reward_version_id')::uuid is distinct from v_reward_version then
    raise exception 'redemption did not resolve the published reward version';
  end if;
  select id,reward_snapshot,eligibility_snapshot into v_redemption_id,v_snapshot,v_eligibility_snapshot
    from public.loyalty_redemptions
   where business_id=v_business and client_id=v_client and reward_id=v_reward
   order by redeemed_at desc limit 1;
  if v_redemption_id is null or v_snapshot->>'customer_name' <> 'v27 $1 reward' then
    raise exception 'redemption did not retain the immutable reward snapshot';
  end if;
  if v_eligibility_snapshot->'selected'->>'branch_id' is distinct from v_branch::text then
    raise exception 'redemption did not retain its eligibility decision';
  end if;
  if not exists (
    select 1 from public.loyalty_redemptions
     where id=v_redemption_id
       and entitlement_expires_at between now() + interval '29 days' and now() + interval '31 days'
  ) then raise exception 'redemption did not snapshot entitlement expiry from the reward version'; end if;
  begin
    perform public.redeem_reward_at_context(v_business,v_client,v_reward,'v27-second-use',v_branch,v_service,v_product);
    raise exception 'per-client reward usage limit was not enforced';
  exception when check_violation then null;
  end;
  begin
    update public.loyalty_redemptions set reward_name='tampered' where id=v_redemption_id;
    raise exception 'redemption history was mutable';
  exception when restrict_violation then null;
  end;

  if has_function_privilege('anon','public.save_loyalty_reward_draft(uuid,uuid,jsonb,jsonb)','execute')
     or has_function_privilege('authenticated','public.save_loyalty_reward_draft(uuid,uuid,jsonb,jsonb)','execute')
     or has_function_privilege('anon','public.save_loyalty_config_draft(uuid,jsonb)','execute')
     or has_function_privilege('authenticated','public.save_loyalty_config_draft(uuid,jsonb)','execute')
     or has_function_privilege('anon','public.save_loyalty_config_draft(uuid,jsonb,text)','execute')
     or has_function_privilege('anon','public.redeem_reward_at_context(uuid,uuid,uuid,text,uuid,uuid,uuid)','execute')
     or not has_function_privilege('authenticated','public.save_loyalty_config_draft(uuid,jsonb,text)','execute') then
    raise exception 'v27 reward RPC ACL contract is incorrect';
  end if;
  if pg_get_functiondef('public.publish_loyalty_config(uuid)'::regprocedure) like '%earn_rate_bps%' then
    raise exception 'v27 publish wrapper retained the removed earn_rate_bps column';
  end if;
  if exists (
    select 1 from public.loyalty_redemptions x
     where x.reward_snapshot->>'legacy' = 'true'
       and ((x.credit_cents > 0 and x.fulfillment_kind <> 'credit')
         or (x.credit_cents = 0 and x.fulfillment_kind <> 'manual_item'))
  ) then raise exception 'legacy reward fulfillment meaning was misclassified'; end if;
  if exists (
    select 1
     from pg_policy p
      join pg_class c on c.oid=p.polrelid
     where c.relname in ('loyalty_reward_branches','loyalty_reward_services','loyalty_reward_products')
       and p.polname like 'loyalty_reward_%_read'
       and p.polname not like '%_sa_read'
       and pg_get_expr(p.polqual,p.polrelid) not like '%' || c.relname || '.business_id%'
  ) then raise exception 'eligibility read policy does not qualify its outer business_id'; end if;
  raise notice 'v27 rich rewards suite: ALL PASS';
end $v27_test$;

rollback;
