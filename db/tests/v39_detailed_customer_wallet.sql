-- Rollback-only v39 detailed customer wallet adversarial suite.
-- Covers cross-business isolation, pagination/next_cursor behavior, unknown
-- cursor rejection, disabled module denial, prohibited output keys, raw table
-- denial through RLS, and PUBLIC/anon/authenticated/search_path ACL contracts.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v39_user(p_uid uuid) returns void
language plpgsql as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_uid, 'role', 'authenticated'
  )::text, true);
end;
$$;
grant execute on function pg_temp.as_v39_user(uuid) to public;

do $v39_test$
declare
  v_business uuid;
  v_other_business uuid;
  v_slug text;
  v_other_slug text;
  v_owner uuid;
  v_customer uuid := gen_random_uuid();
  v_customer_b uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_identity_b uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_client_b uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_link_b uuid := gen_random_uuid();
  v_draft uuid;
  v_reward uuid;
  v_taxonomy uuid;
  v_taxonomy_label text;
  v_retention_program uuid;
  v_retention_draft uuid;
  v_retention_hash text;
  v_plan uuid;
  v_client_package uuid;
  v_package_sale uuid;
  v_redemption uuid;
  v_membership_plan uuid;
  v_page_one jsonb;
  v_page_two jsonb;
  v_activity_one jsonb;
  v_activity_two jsonb;
  v_catalog jsonb;
  v_packages jsonb;
  v_memberships jsonb;
  v_capabilities jsonb;
  v_visible integer;
  v_name text;
  v_oid oid;
  v_definition text;
begin
  reset role;
  select b.id, b.slug, s.user_id
    into v_business, v_slug, v_owner
    from public.businesses b
    join public.staff s on s.business_id = b.id
    join public.loyalty_programs lp on lp.business_id = b.id and lp.active
   where s.role = 'owner' and s.active and s.user_id is not null
   order by b.created_at, s.created_at
   limit 1;
  select b.id, b.slug into v_other_business, v_other_slug
    from public.businesses b where b.id <> v_business
   order by b.created_at, b.id limit 1;
  if v_business is null or v_other_business is null or v_owner is null then
    raise exception 'v39 suite requires two businesses and one active owner loyalty fixture';
  end if;

  update public.businesses
     set enabled_modules = array['loyalty','appointments','bookings','packages','memberships']
   where id = v_business;
  update app.platform_feature_flags set enabled = true, changed_at = now()
   where feature_key = 'customer_wallet';

  -- Build one published customer-facing reward and fixed-expiry program through
  -- the reviewed draft APIs, never by mutating the live projection directly.
  perform pg_temp.as_v39_user(v_owner);
  v_draft := (public.create_loyalty_config_draft(
    v_business,null,'v39-wallet-suite'
  )::jsonb->>'version_id')::uuid;
  perform public.save_loyalty_config_draft(v_draft,jsonb_build_object(
    'active',true,
    'kind','points',
    'loyalty_model','points_tiers',
    'expiry_mode','fixed',
    'expiry_days',10,
    'reward',jsonb_build_object(
      'internal_name','V39 internal fixture name',
      'customer_name','V39 customer reward',
      'description','Customer-safe description',
      'fulfillment_kind','manual_item',
      'cost_points',50,
      'credit_cents',0,
      'estimated_cost_cents',999,
      'active',true,
      'instructions','Ask the team at the counter',
      'terms','One claim per customer',
      'image_ref','rewards/v39.webp',
      'entitlement_expiry_days',30,
      'usage_limit',1
    ),
    'reward_branch_ids','[]'::jsonb,
    'reward_service_ids','[]'::jsonb,
    'reward_product_ids','[]'::jsonb
  ),null);
  reset role;
  select rv.reward_id into v_reward from public.loyalty_reward_versions rv
   where rv.config_version_id=v_draft and rv.customer_name='V39 customer reward';
  if v_reward is null then raise exception 'v39 reward fixture was not created'; end if;
  perform pg_temp.as_v39_user(v_owner);
  perform public.publish_loyalty_config(v_draft);
  reset role;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
  (
    '00000000-0000-0000-0000-000000000000',v_customer,
    'authenticated','authenticated','v39-wallet@example.test','',now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_customer_b,
    'authenticated','authenticated','v39-wallet-b@example.test','',now(),now(),now()
  );
  insert into public.customer_identities(id,auth_user_id,status,created_via)
  values(v_identity,v_customer,'active','wallet_start'),
        (v_identity_b,v_customer_b,'active','wallet_start');
  insert into public.clients(id,business_id,full_name,email)
  values(v_client,v_business,'V39 wallet customer','v39-wallet@example.test'),
        (v_client_b,v_business,'V39 wallet customer B','v39-wallet-b@example.test');
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at
  ) values (
    v_link,v_business,v_identity,v_customer,v_client,'verified','firm_invitation',now()
  );
  perform set_config('app.customer_link_insert_id',v_link_b::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at
  ) values (
    v_link_b,v_business,v_identity_b,v_customer_b,v_client_b,'verified','firm_invitation',now()
  );

  insert into public.appointments(
    business_id,client_id,starts_at,ends_at,status,total_cents,source
  ) values
    (v_business,v_client,now()+interval '1 day',now()+interval '1 day 30 minutes','booked',0,'admin'),
    (v_business,v_client,now()+interval '2 days',now()+interval '2 days 30 minutes','booked',0,'admin'),
    (v_business,v_client,now()+interval '3 days',now()+interval '3 days 30 minutes','booked',0,'admin'),
    (v_business,v_client,now()-interval '1 day',now()-interval '23 hours 30 minutes','completed',0,'admin'),
    (v_business,v_client,now()-interval '2 days',now()-interval '47 hours 30 minutes','completed',0,'admin');
  insert into public.package_plans(business_id,name,price_cents,sessions,service_id,active)
  values(v_business,'V39 five visits',5000,5,null,true) returning id into v_plan;
  insert into public.client_packages(business_id,client_id,plan_id,remaining,status)
  values(v_business,v_client,v_plan,4,'active') returning id into v_client_package;
  insert into public.client_packages(business_id,client_id,plan_id,remaining,status)
  values(v_business,v_client_b,v_plan,2,'active');
  insert into public.membership_plans(business_id,name,price_cents,cadence,credit_cents,active)
  values(v_business,'V39 monthly',3000,'monthly',2000,true) returning id into v_membership_plan;
  insert into public.memberships(
    business_id,client_id,plan_id,status,current_period_start,current_period_end
  ) values (
    v_business,v_client,v_membership_plan,'active',now(),now()+interval '1 month'
  ),(
    v_business,v_client_b,v_membership_plan,'paused',now(),now()+interval '1 month'
  );

  perform pg_temp.as_v39_user(v_owner);
  perform public.adjust_points(v_business,v_client,10,'v39 activity one');
  perform public.adjust_points(v_business,v_client,20,'v39 activity two');
  perform public.adjust_points(v_business,v_client,30,'v39 activity three');
  perform public.adjust_points(v_business,v_client_b,500,'v39 customer B isolation');
  reset role;
  select id,label into v_taxonomy,v_taxonomy_label from public.firm_reward_taxonomy
   where business_id=v_business and fulfillment_kind='free_item' and active
   order by sort,id limit 1;
  if v_taxonomy is null then
    perform pg_temp.as_v39_user(v_owner);
    v_page_one:=public.save_reward_taxonomy(v_business,null,jsonb_build_object(
      'label','V39 fixture reward type','fulfillment_kind','free_item','active',true,'sort',9000));
    v_taxonomy:=(v_page_one->>'id')::uuid;
    v_taxonomy_label:=v_page_one->>'label';
    reset role;
  end if;
  perform pg_temp.as_v39_user(v_owner);
  v_retention_draft:=(public.create_loyalty_config_draft(
    v_business,null,'v39-retention-fixture')::jsonb->>'version_id')::uuid;
  select snapshot_hash into v_retention_hash from public.firm_config_versions where id=v_retention_draft;
  v_retention_program:=gen_random_uuid();
  perform public.save_retention_program_draft(v_retention_draft,v_retention_program,jsonb_build_object(
    'name','V39 retention fixture','active',true,'goal_visits',2,'period_days',30,
    'starts_on',current_date,'reward_taxonomy_id',v_taxonomy,'manual_item','Fixture service'),v_retention_hash);
  perform public.publish_loyalty_config(v_retention_draft);
  reset role;
  if not exists (
    select 1 from public.loyalty_programs
     where business_id=v_business and active
       and current_config_version_id=v_retention_draft
  ) then
    raise exception 'v39 retention publish did not preserve loyalty projection (active %, current %, draft active %)',
      (select active from public.loyalty_programs where business_id=v_business),
      (select current_config_version_id from public.loyalty_programs where business_id=v_business),
      (select active from public.loyalty_program_versions where config_version_id=v_retention_draft);
  end if;
  insert into public.reward_grants(
    business_id,program_id,client_id,period_index,reward_type,reward_value,reward_item,status
  ) values (
    v_business,v_retention_program,v_client,0,'free_item',0,'Fixture service','granted'
  );
  perform pg_temp.as_v39_user(v_owner);
  perform public.use_package_session(v_business,v_client_package,'v39-package-use');
  reset role;
  select sale_id into v_package_sale from public.package_session_consumptions
   where business_id=v_business and idempotency_key='v39-package-use';
  perform pg_temp.as_v39_user(v_owner);
  perform public.reverse_sale(
    v_business,v_package_sale,'v39 package history reversal','v39-package-reverse',null,'none'
  );

  perform pg_temp.as_v39_user(v_customer);
  v_page_one := public.customer_get_appointments_page(v_slug,'{"limit":3}'::jsonb);
  if jsonb_array_length(v_page_one->'items') <> 3
     or v_page_one->'next_cursor' = 'null'::jsonb
     or (v_page_one#>>'{items,0,starts_at}')::timestamptz
          >= (v_page_one#>>'{items,1,starts_at}')::timestamptz
     or (v_page_one#>>'{items,1,starts_at}')::timestamptz
          >= (v_page_one#>>'{items,2,starts_at}')::timestamptz
     or not (v_page_one->'next_cursor' ? 'as_of')
     or not (v_page_one->'next_cursor' ? 'sort_group') then
    raise exception 'upcoming appointments were not nearest-first with a next_cursor: %',v_page_one;
  end if;
  v_page_two := public.customer_get_appointments_page(v_slug,v_page_one->'next_cursor');
  if jsonb_array_length(v_page_two->'items') <> 2
     or v_page_two->'next_cursor' <> 'null'::jsonb
     or (v_page_two#>>'{items,0,starts_at}')::timestamptz
          <= (v_page_two#>>'{items,1,starts_at}')::timestamptz
     or exists (
       select 1 from jsonb_array_elements(v_page_one->'items') a
       join jsonb_array_elements(v_page_two->'items') b
         on a->>'appointment_id' = b->>'appointment_id'
     ) then
    raise exception 'upcoming-to-recent transition or recent descending order failed: %',v_page_two;
  end if;

  v_activity_one := public.customer_get_loyalty_details(v_slug,'{"limit":2}'::jsonb);
  if jsonb_array_length(v_activity_one->'items') <> 2
     or v_activity_one->'next_cursor' = 'null'::jsonb
     or (v_activity_one->>'balance')::integer <> 60
     or (v_activity_one#>>'{expiry,expiring_next_30_days}')::integer <> 60 then
    raise exception 'loyalty activity pagination or balance is incorrect: %',v_activity_one;
  end if;
  v_activity_two := public.customer_get_loyalty_details(v_slug,v_activity_one->'next_cursor');
  if jsonb_array_length(v_activity_two->'items') <> 2
     or not exists (
       select 1 from jsonb_array_elements(
         public.customer_get_loyalty_details(v_slug,'{"limit":20}'::jsonb)->'items'
       ) event where event->>'event_type'='retention_reward'
          and event->>'title'=v_taxonomy_label
     ) then
    raise exception 'loyalty activity next_cursor or retention grant projection is incomplete';
  end if;

  v_catalog := public.customer_get_reward_catalog(v_slug);
  v_packages := public.customer_get_packages(v_slug,'{"limit":2}'::jsonb);
  v_memberships := public.customer_get_memberships(v_slug);
  v_capabilities := public.customer_portal_capabilities(v_slug);
  if jsonb_typeof(v_catalog) <> 'array' or jsonb_array_length(v_catalog) < 1
     or not exists (
       select 1 from jsonb_array_elements(v_catalog) reward
        where reward->>'customer_name'='V39 customer reward'
          and reward->>'description'='Customer-safe description'
          and reward->>'image_ref'='rewards/v39.webp'
          and reward->>'terms'='One claim per customer'
          and reward->>'instructions'='Ask the team at the counter'
          and reward->>'availability'='available_at_counter'
          and reward->>'claim_method'='counter'
          and reward#>>'{eligibility,branches,scope}'='all'
          and not (reward ? 'internal_name')
          and not (reward ? 'estimated_cost_cents')
     )
     or jsonb_array_length(v_packages->'items') <> 1
     or v_packages#>>'{items,0,plan_name}' <> 'V39 five visits'
     or (v_packages#>>'{items,0,sessions_remaining}')::integer <> 4
     or v_packages#>>'{items,0,usage_history,0,status}' <> 'reversed'
     or jsonb_array_length(v_memberships) <> 1
     or v_memberships#>>'{0,plan_name}' <> 'V39 monthly'
     or v_memberships#>>'{0,status}' <> 'active'
     or coalesce((v_capabilities->>'activity')::boolean,false) is not true
     or coalesce((v_capabilities->>'rewards')::boolean,false) is not true
     or coalesce((v_capabilities->>'appointments')::boolean,false) is not true
     or coalesce((v_capabilities->>'packages')::boolean,false) is not true
     or coalesce((v_capabilities->>'membership')::boolean,false) is not true then
    raise exception 'v39 detailed data or capabilities are incomplete: %',v_capabilities;
  end if;

  -- Customer B is linked to the same business but every relationship reader
  -- must resolve B's client row, never customer A's richer fixtures.
  perform pg_temp.as_v39_user(v_customer_b);
  if (public.customer_get_loyalty_details(v_slug,'{}'::jsonb)->>'balance')::integer <> 500
     or jsonb_array_length(public.customer_get_appointments_page(v_slug,'{}'::jsonb)->'items') <> 0
     or (public.customer_get_packages(v_slug,'{}'::jsonb)#>>'{items,0,sessions_remaining}')::integer <> 2
     or public.customer_get_memberships(v_slug)#>>'{0,status}' <> 'paused'
     or jsonb_array_length(public.customer_get_reward_catalog(v_slug)) < 1
     or coalesce((public.customer_portal_capabilities(v_slug)->>'wallet')::boolean,false) is not true
     or coalesce((public.customer_portal_capabilities(v_slug)->>'rewards')::boolean,false) is not true
     or coalesce((public.customer_portal_capabilities(v_slug)->>'activity')::boolean,false) is not true
     or coalesce((public.customer_portal_capabilities(v_slug)->>'appointments')::boolean,true) is not false
     or coalesce((public.customer_portal_capabilities(v_slug)->>'packages')::boolean,false) is not true
     or coalesce((public.customer_portal_capabilities(v_slug)->>'membership')::boolean,false) is not true then
    raise exception 'same-business Customer A/B isolation failed';
  end if;
  perform pg_temp.as_v39_user(v_customer);

  if (v_activity_one||v_catalog||v_packages||v_memberships||v_page_one)::text
       ~* '"(business_id|client_id|identity_id|auth_user_id|actor|sale_id|payment_id|email|phone|notes|internal_name|estimated_cost_cents|price_cents)"' then
    raise exception 'v39 response contains a prohibited output key';
  end if;

  -- Catalog availability must follow the authoritative usage-limit semantics,
  -- including after the append-only reversal compensates the economic entries.
  reset role;
  perform pg_temp.as_v39_user(v_owner);
  perform public.redeem_reward_at_context(
    v_business,v_client,v_reward,'v39-reward-redeem',null,null,null
  );
  select id into v_redemption from public.loyalty_redemptions
   where business_id=v_business and client_id=v_client and reward_id=v_reward
   order by redeemed_at desc limit 1;
  perform public.reverse_loyalty_redemption(
    v_business,v_redemption,'v39 reward reversal evidence','v39-reward-reverse'
  );
  perform pg_temp.as_v39_user(v_customer);
  v_activity_one := public.customer_get_loyalty_details(v_slug,'{"limit":20}'::jsonb);
  v_catalog := public.customer_get_reward_catalog(v_slug);
  if not exists (
       select 1 from jsonb_array_elements(v_activity_one->'items') event
        where event->>'event_type'='reward_claimed' and event->>'status'='reversed'
     ) or not exists (
       select 1 from jsonb_array_elements(v_catalog) reward
        where reward->>'customer_name'='V39 customer reward'
          and reward->>'availability'='limit_reached'
     ) then
    raise exception 'redemption/reversal activity or authoritative usage-limit availability is incorrect';
  end if;

  -- The same-business customer must retain independent catalog eligibility;
  -- A's immutable usage-limit row cannot make B's reward unavailable.
  perform pg_temp.as_v39_user(v_customer_b);
  if not exists (
       select 1 from jsonb_array_elements(public.customer_get_reward_catalog(v_slug)) reward
        where reward->>'customer_name'='V39 customer reward'
          and reward->>'availability'='available_at_counter'
     ) then
    raise exception 'Customer A reward usage leaked into Customer B catalog availability';
  end if;
  perform pg_temp.as_v39_user(v_customer);

  begin
    perform public.customer_get_loyalty_details(v_slug,'{"unknown cursor":true}'::jsonb);
    raise exception 'unknown cursor key was accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.customer_get_appointments_page(v_other_slug,'{}'::jsonb);
    raise exception 'cross-business appointment read was accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.customer_get_packages(v_other_slug,'{}'::jsonb);
    raise exception 'cross-business package read was accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.customer_get_loyalty_details(v_other_slug,'{}'::jsonb);
    raise exception 'cross-business loyalty activity read was accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.customer_get_reward_catalog(v_other_slug);
    raise exception 'cross-business reward catalog read was accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.customer_get_memberships(v_other_slug);
    raise exception 'cross-business membership read was accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.customer_portal_capabilities(v_other_slug);
    raise exception 'cross-business capabilities read was accepted';
  exception when insufficient_privilege then null;
  end;

  -- Raw table access by this customer must either be denied by ACL or resolve
  -- to zero rows under staff-only RLS; SECURITY DEFINER RPCs are the only view.
  foreach v_name in array array[
    'loyalty_programs','points_ledger','points_batches','loyalty_redemptions','reward_grants',
    'retention_programs','firm_reward_taxonomy',
    'loyalty_reward_versions','loyalty_reward_branches','loyalty_reward_services','loyalty_reward_products',
    'appointments','package_plans','client_packages','package_session_consumptions','package_session_reversals',
    'membership_plans','memberships'
  ] loop
    v_visible := 0;
    begin
      execute format('select count(*) from public.%I where business_id=$1',v_name)
        into v_visible using v_business;
      if v_visible <> 0 then
        raise exception 'raw table % exposed % customer-visible rows',v_name,v_visible;
      end if;
    exception when insufficient_privilege then null;
    end;
  end loop;

  reset role;
  update public.businesses
     set enabled_modules = array_remove(enabled_modules,'packages')
   where id = v_business;
  perform pg_temp.as_v39_user(v_customer);
  begin
    perform public.customer_get_packages(v_slug,'{}'::jsonb);
    raise exception 'disabled module packages reader was accepted';
  exception when insufficient_privilege then null;
  end;
  v_capabilities := public.customer_portal_capabilities(v_slug);
  if coalesce((v_capabilities->>'packages')::boolean,true) then
    raise exception 'disabled module remained present in customer capabilities';
  end if;

  reset role;
  foreach v_name in array array[
    'customer_get_loyalty_details(text,jsonb)',
    'customer_get_reward_catalog(text)',
    'customer_get_packages(text,jsonb)',
    'customer_get_memberships(text)',
    'customer_get_appointments_page(text,jsonb)'
  ] loop
    v_oid := to_regprocedure('public.'||v_name);
    if v_oid is null then raise exception 'missing v39 RPC %',v_name; end if;
    if has_function_privilege('anon',v_oid,'execute')
       or not has_function_privilege('authenticated',v_oid,'execute')
       or exists (
         select 1 from aclexplode(coalesce((select proacl from pg_proc where oid=v_oid),
                                            acldefault('f',(select proowner from pg_proc where oid=v_oid)))) acl
          where acl.grantee=0 and acl.privilege_type='EXECUTE'
       ) then
      raise exception 'PUBLIC/anon/authenticated ACL mismatch for %',v_name;
    end if;
    select pg_get_functiondef(v_oid) into v_definition;
    if v_definition not ilike '%SECURITY DEFINER%'
       or v_definition not ilike '%pg_catalog%public%app%pg_temp%' then
      raise exception 'SECURITY DEFINER search_path mismatch for %',v_name;
    end if;
  end loop;

  raise notice 'v39 detailed customer wallet suite: ALL PASS';
end $v39_test$;

rollback;
