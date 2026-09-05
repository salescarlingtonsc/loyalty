-- nestly_v792 rollback suite — a claim only hands over ids from the provider billing today.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production.
--
-- WHAT IT PROVES
--   E1  app.platform_billing_provider_v792() answers the active tier catalogue's provider, is
--       server-only, and never returns null.
--   E2  a business whose customer row and subscription belong to a RETIRED provider gets NULL
--       provider ids from both claims — the exact failure observed live (a Razorpay cust_... sent
--       to Stripe Checkout, resource_missing).
--   E3  the same business, moved onto the platform provider, gets its ids back.
--   E4  a branch left PAID on a retired provider can still buy a fresh subscription here, and the
--       claim hands over no id from it; on the platform provider its id comes back.
--   E5  the company read presents a retired-provider subscription as no plan (no provider object,
--       no plan label, state 'none'), and says which provider it was.
--   E6  a 'manual' company subscription is NOT treated as retired.
begin;

create or replace function pg_temp.as_v792_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  if p_uid is null then return; end if;
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', p_role,
    'amr', jsonb_build_array(jsonb_build_object('method','password','timestamp',1756500000)),
    'app_metadata', jsonb_build_object('provider','email','providers',jsonb_build_array('email')))::text, true);
end
$$;
grant execute on function pg_temp.as_v792_user(uuid,text) to public;

do $v792_main$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_main uuid; v_branch uuid;
  v_platform text;
  v_retired text;
  v_cmd uuid;
  v_key uuid := gen_random_uuid();
  v_claim jsonb;
  v_billing jsonb;
  v_tier public.billing_capacity_tier_catalog_v664%rowtype;
begin
  reset role;

  -- E1
  v_platform := app.platform_billing_provider_v792();
  if v_platform is null or v_platform = '' then raise exception 'v792 E1: no platform provider'; end if;
  select tier.provider into v_retired from public.billing_capacity_tier_catalog_v664 tier
   where tier.active and tier.provider_base_price_id is not null limit 1;
  if v_retired is distinct from v_platform then
    raise exception 'v792 E1: platform provider % does not match the catalogue %', v_platform, v_retired;
  end if;
  if has_function_privilege('authenticated','app.platform_billing_provider_v792()','EXECUTE')
     or has_function_privilege('anon','app.platform_billing_provider_v792()','EXECUTE') then
    raise exception 'v792 E1: platform provider ACL is not server-only';
  end if;
  v_retired := case when v_platform = 'stripe' then 'razorpay' else 'stripe' end;

  -- fixture: a business carrying the RETIRED provider's ids, exactly as a switched tenant does
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
         'v792-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values (v_business,'V792 fixture','v792-'||substr(v_business::text,1,8),'test',array['dashboard','clients','sales']);
  insert into public.staff(business_id,user_id,role,full_name,active) values (v_business,v_owner,'owner','V792 Owner',true);
  insert into public.branches(business_id,name,is_default,active) values (v_business,'Main',true,true) returning id into v_main;
  insert into public.branches(business_id,name,is_default,active,billing_state,billing_mode)
  values (v_business,'Own',false,false,'pending_payment','own') returning id into v_branch;
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_at=clock_timestamp(),
         decision_reason='v792 fixture',updated_at=clock_timestamp()
   where business_id=v_business;
  insert into public.subscriptions(business_id,status,payment_status,current_period_start,current_period_end,
                                   billing_provider,billing_cadence,provider_customer_id,provider_subscription_id,
                                   provider_base_item_id,provider_base_price_id)
  values (v_business,'active','paid',now()-interval '10 days',now()+interval '355 days',v_retired,'annual',
          'cust_v792retired','sub_v792retired','sub_v792retired','plan_v792retired');
  insert into public.billing_provider_customers(business_id,provider,provider_customer_id,currency,livemode,
                                                provider_event_created_at,provider_event_rank,last_event_id)
  values (v_business,v_retired,'cust_v792retired','SGD',false,now(),1,'evt_v792');
  insert into public.branch_subscriptions_v786(business_id,branch_id,provider,provider_customer_id,
                                               provider_subscription_id,status,payment_status,cadence,unit_amount_cents)
  values (v_business,v_branch,v_retired,'cust_v792retired','sub_v792retiredbranch','active','paid','annual',118800);

  -- E2 · the business claim hands over nothing that belongs to the retired provider
  select * into v_tier from public.billing_capacity_tier_catalog_v664
   where active and provider_base_price_id is not null and cadence='annual' order by capacity_ceiling limit 1;
  perform pg_temp.as_v792_user(v_owner);
  v_cmd := (public.request_billing_command_v124(v_business,'create_checkout','annual',
             v_tier.capacity_ceiling,v_key)->>'command_id')::uuid;
  perform pg_temp.as_v792_user(null);
  set local role service_role;
  v_claim := public.claim_billing_command_v786(v_cmd, v_owner);
  reset role;
  if v_claim->>'provider_customer_id' is not null
     or v_claim->>'provider_subscription_id' is not null
     or v_claim->>'provider_base_item_id' is not null then
    raise exception 'v792 E2: a retired provider id reached the executor: %', v_claim;
  end if;
  if v_claim->>'provider_base_price_id' is distinct from v_tier.provider_base_price_id then
    raise exception 'v792 E2: the price id must still come from the catalogue';
  end if;

  -- E3 · once the tenant is on the platform provider, its ids come back
  update public.subscriptions set billing_provider=v_platform where business_id=v_business;
  update public.billing_provider_customers set provider=v_platform where business_id=v_business;
  set local role service_role;
  v_claim := public.claim_billing_command_v786(v_cmd, v_owner);
  reset role;
  if v_claim->>'provider_customer_id' <> 'cust_v792retired'
     or v_claim->>'provider_subscription_id' <> 'sub_v792retired' then
    raise exception 'v792 E3: the platform provider ids were withheld: %', v_claim;
  end if;
  update public.subscriptions set billing_provider=v_retired where business_id=v_business;
  update public.billing_provider_customers set provider=v_retired where business_id=v_business;

  -- E4 · the branch claim
  perform pg_temp.as_v792_user(v_owner);
  v_cmd := (public.request_branch_billing_command_v786(v_business,v_branch,'create_checkout','annual',
             gen_random_uuid())->>'command_id')::uuid;
  perform pg_temp.as_v792_user(null);
  set local role service_role;
  v_claim := public.claim_billing_command_v786(v_cmd, v_owner);
  reset role;
  if v_claim->>'scope' <> 'branch' then raise exception 'v792 E4: not a branch claim'; end if;
  if v_claim->>'provider_subscription_id' is not null or v_claim->>'provider_customer_id' is not null then
    raise exception 'v792 E4: a retired branch id reached the executor: %', v_claim;
  end if;
  update public.branch_subscriptions_v786 set provider=v_platform where branch_id=v_branch;
  set local role service_role;
  v_claim := public.claim_billing_command_v786(v_cmd, v_owner);
  reset role;
  if v_claim->>'provider_subscription_id' <> 'sub_v792retiredbranch' then
    raise exception 'v792 E4: the platform branch id was withheld: %', v_claim;
  end if;
  update public.branch_subscriptions_v786 set provider=v_retired where branch_id=v_branch;

  -- E5 · the read
  perform pg_temp.as_v792_user(v_owner);
  v_billing := public.get_business_billing_v786(v_business);
  if v_billing->'provider' <> 'null'::jsonb and v_billing #>> '{provider,subscription_id}' is not null then
    raise exception 'v792 E5: a retired provider subscription is still presented: %', v_billing->'provider';
  end if;
  if v_billing #>> '{summary,plan_label}' is not null
     or v_billing #>> '{summary,state}' <> 'none'
     or (v_billing #>> '{summary,total_cents}')::integer <> 0 then
    raise exception 'v792 E5: the summary still claims a plan: %', v_billing->'summary';
  end if;
  if v_billing #>> '{summary,retired_provider}' <> v_retired then
    raise exception 'v792 E5: the read does not say which provider was retired';
  end if;
  if v_billing #>> '{branch_subscriptions,0,state}' <> 'none' then
    raise exception 'v792 E5: a retired branch subscription still reads as live';
  end if;

  -- E6 · manual is not retired
  perform pg_temp.as_v792_user(null);
  update public.subscriptions set billing_provider='manual' where business_id=v_business;
  perform pg_temp.as_v792_user(v_owner);
  v_billing := public.get_business_billing_v786(v_business);
  if v_billing #>> '{summary,retired_provider}' is not null then
    raise exception 'v792 E6: a manual subscription was treated as a retired provider';
  end if;

  perform pg_temp.as_v792_user(null);
  raise notice 'v792 acceptance: E1–E6 passed';
end
$v792_main$;

rollback;
