-- Rollback-only acceptance for Nestly v117 effective loyalty boundaries.
-- Run after the canonical chain through v117 in a disposable local database.
-- The synthetic Glow Atelier fixture proves platform policy -> merchant branch
-- operation -> customer projection without leaving persistent rows.
begin;

create or replace function pg_temp.as_v117_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,
    true
  );
end
$$;
grant execute on function pg_temp.as_v117_user(uuid,text) to public;

do $v117_acceptance$
declare
  v_super uuid:=gen_random_uuid();
  v_owner uuid:=gen_random_uuid();
  v_frontdesk uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();
  v_identity uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_branch_disabled uuid:=gen_random_uuid();
  v_branch_enabled uuid:=gen_random_uuid();
  v_client uuid:=gen_random_uuid();
  v_frontdesk_staff uuid;
  v_config uuid:=gen_random_uuid();
  v_intent uuid;
  v_join_token text;
  v_qr_token text;
  v_scan_key uuid:=gen_random_uuid();
  v_card uuid;
  v_card_code text;
  v_result jsonb;
  v_wallet jsonb;
  v_actions jsonb;
  v_branch_projection jsonb;
  v_workspace_projection jsonb;
  v_denied boolean;
  v_before integer;
  v_after integer;
  v_points_before integer;
  v_credit_before integer;
  v_redemptions_before integer;
  v_cards_before integer;
  v_sales_before integer;
  v_operations_before integer;
  v_gift_loads_before integer;
  v_gift_redeem_key uuid:=gen_random_uuid();
  v_override_version bigint;
begin
  if to_regprocedure(
       'public.merchant_scan_redemption_qr_v117(uuid,uuid,text,uuid)'
     ) is null
     or to_regprocedure(
       'public.issue_gift_card_at_branch_v117(uuid,uuid,integer,uuid,text,uuid)'
     ) is null
     or to_regprocedure(
       'public.redeem_gift_card_at_branch_v117(uuid,uuid,text,uuid,integer,uuid)'
     ) is null
     or to_regprocedure(
       'public.business_has_active_gift_liability_v117(uuid,uuid)'
     ) is null then
    raise exception 'v117 effective loyalty contracts are not installed';
  end if;

  if has_function_privilege(
       'authenticated',
       'public.merchant_scan_redemption_qr_v89(uuid,text,uuid)',
       'EXECUTE'
     )
     or has_function_privilege(
       'anon',
       'public.merchant_scan_redemption_qr_v89(uuid,text,uuid)',
       'EXECUTE'
     )
     or has_function_privilege(
       'authenticated',
       'public.merchant_scan_redemption_qr_v93(uuid,uuid,text,uuid)',
       'EXECUTE'
     )
     or has_function_privilege(
       'anon',
       'public.merchant_scan_redemption_qr_v93(uuid,uuid,text,uuid)',
       'EXECUTE'
     )
     or coalesce(
       has_function_privilege(
         'authenticated',
         to_regprocedure(
           'public.redeem_gift_card_at_branch_v117(uuid,uuid,text,uuid,integer)'
         ),
         'EXECUTE'
       ),
       false
     ) then
    raise exception
      'obsolete redemption execution remained available to a browser role';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,phone,encrypted_password,
    email_confirmed_at,phone_confirmed_at,created_at,updated_at
  ) values
    (
      '00000000-0000-0000-0000-000000000000',v_super,
      'authenticated','authenticated','v117-super@example.test',null,'',
      now(),null,now(),now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',v_owner,
      'authenticated','authenticated','v117-owner@example.test',null,'',
      now(),null,now(),now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',v_frontdesk,
      'authenticated','authenticated','v117-frontdesk@example.test',null,'',
      now(),null,now(),now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',v_customer,
      'authenticated','authenticated','v117-customer@example.test',
      '+6581170117','',now(),now(),now(),now()
    );

  insert into public.super_admins(user_id,email,note)
  values(
    v_super,'v117-super@example.test',
    'rollback-only v117 effective loyalty acceptance'
  );

  update app.platform_feature_flags
  set enabled=true
  where feature_key in ('customer_wallet','customer_qr_redemption');

  insert into public.businesses(
    id,name,slug,industry,currency,is_synthetic,join_enabled,enabled_modules
  ) values(
    v_business,
    'V117 Glow Atelier',
    'v117-glow-'||substr(v_business::text,1,8),
    'facial','SGD',true,true,
    array[
      'dashboard','till','clients','sales','services','loyalty','giftcards'
    ]
  );
  insert into public.branches(id,business_id,name,is_default,active)
  values
    (
      v_branch_disabled,v_business,
      'Glow Atelier Orchard',true,true
    ),
    (
      v_branch_enabled,v_business,
      'Glow Atelier Tampines',false,true
    );
  insert into public.staff(
    business_id,user_id,role,full_name,active
  ) values(
    v_business,v_owner,'owner','Glow Atelier Owner',true
  );
  insert into public.staff(
    business_id,user_id,role,full_name,active,module_perms
  ) values(
    v_business,v_frontdesk,'frontdesk','Glow Atelier Front Desk',true,
    '{"till":"rw","clients":"r","loyalty":"rw"}'::jsonb
  ) returning id into v_frontdesk_staff;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business,v_frontdesk_staff,v_branch_enabled);
  insert into public.clients(
    id,business_id,full_name,phone
  ) values(
    v_client,v_business,'Alicia Tan','+6581170117'
  );

  perform pg_temp.as_v117_user(v_super);
  v_result:=public.platform_decide_business_approval_v94(
    v_business,'approved','v117 rollback acceptance fixture',1
  );
  reset role;
  if v_result->>'approval_status'<>'approved'
     or not (v_result->>'workspace_access')::boolean then
    raise exception 'v117 synthetic Glow Atelier workspace was not approved';
  end if;

  -- A real business with active branches never falls back to firm-level
  -- navigation merely because a non-owner lost every branch assignment.
  delete from public.staff_branches
  where business_id=v_business and staff_id=v_frontdesk_staff;
  perform pg_temp.as_v117_user(v_frontdesk);
  v_workspace_projection:=public.get_my_modules(v_business);
  v_branch_projection:=public.get_my_modules_at_v115(
    v_business,v_branch_enabled
  );
  reset role;
  if jsonb_array_length(v_workspace_projection->'modules')<>0
     or v_workspace_projection->'module_perms'<>'{}'::jsonb
     or jsonb_array_length(v_branch_projection->'modules')<>0
     or v_branch_projection->'module_perms'<>'{}'::jsonb then
    raise exception
      'unassigned front desk inherited firm or branch modules: % / %',
      v_workspace_projection,v_branch_projection;
  end if;

  insert into public.staff_branches(business_id,staff_id,branch_id)
  values
    (v_business,v_frontdesk_staff,v_branch_disabled),
    (v_business,v_frontdesk_staff,v_branch_enabled);

  insert into public.customer_identities(
    id,auth_user_id,status,created_via
  ) values(
    v_identity,v_customer,'active','phone_registration'
  );
  perform set_config('app.c42_profile_identity',v_identity::text,true);
  insert into public.customer_profiles(
    identity_id,auth_user_id,full_name,birth_date
  ) values(
    v_identity,v_customer,'Alicia Tan','1992-08-09'
  );
  perform set_config('app.c42_profile_identity','',true);
  perform pg_temp.as_v117_user(v_owner);
  v_result:=public.business_rotate_customer_join_qr_v90(
    v_business,now()+interval '1 day'
  );
  reset role;
  v_join_token:=v_result->>'join_token';
  perform pg_temp.as_v117_user(v_customer);
  v_result:=public.customer_join_business_from_qr_v89(
    v_join_token,gen_random_uuid()
  );
  reset role;
  if not exists(
    select 1
    from public.customer_links link
    where link.business_id=v_business
      and link.identity_id=v_identity
      and link.auth_user_id=v_customer
      and link.client_id=v_client
      and link.state='verified'
      and link.verification_method='qr_join'
  ) then
    raise exception 'v117 customer QR join did not link Glow Atelier';
  end if;

  -- Publish a realistic classic-points programme and fund it before platform
  -- policy is narrowed. Later assertions only change module policy.
  insert into public.firm_config_versions(
    id,business_id,version_no,status,source,snapshot_hash,created_by
  ) values(
    v_config,v_business,1,'draft','manual',
    md5('v117-glow-atelier-classic-points'),v_owner
  );
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text,
    true
  );
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,
    tier_basis,expiry_mode
  ) values(
    v_config,v_business,'points','classic',true,
    10,50,500,'points_earned','none'
  );
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  update public.firm_config_versions
  set status='published',published_at=now()
  where id=v_config;
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,
    current_config_version_id,earn_points_per_dollar,redeem_points,
    reward_credit_cents,tier_basis,expiry_mode
  ) values(
    v_business,'points',true,'classic','published',v_config,
    10,50,500,'points_earned','none'
  );
  perform set_config('app.v79_system_transition','on',true);
  update public.businesses
  set active_config_version_id=v_config
  where id=v_business;
  perform set_config('app.v79_system_transition','',true);

  perform pg_temp.as_v117_user(v_owner);
  perform public.business_set_customer_capabilities_v89(
    v_business,false,true,false
  );
  perform public.set_gift_card_sales_enabled_v102(v_business,true);
  perform public.adjust_points(
    v_business,v_client,500,'v117 Glow Atelier funded customer balance'
  );
  reset role;

  -- Firm-disabled Loyalty must disappear from the customer wallet and must
  -- refuse a new customer intent without creating a pending record.
  perform pg_temp.as_v117_user(v_super);
  perform public.platform_set_module_overrides_v105(
    v_business,null,
    '[{"module":"loyalty","mode":"disabled","expected_version":null}]'::jsonb,
    'v117 firm-disabled Loyalty acceptance'
  );
  reset role;

  perform pg_temp.as_v117_user(v_customer);
  v_wallet:=public.customer_get_wallet();
  reset role;
  if jsonb_array_length(v_wallet)<>1
     or coalesce((v_wallet#>>'{0,loyalty,enabled}')::boolean,false) then
    raise exception 'firm-disabled Loyalty exposed customer capability: %',
      v_wallet;
  end if;

  select count(*) into v_before
  from public.customer_redemption_intents_v89
  where business_id=v_business and auth_user_id=v_customer;
  v_denied:=false;
  begin
    perform pg_temp.as_v117_user(v_customer);
    perform public.customer_create_redemption_intent_v89(
      v_business,null,gen_random_uuid(),'classic_points'
    );
    reset role;
  exception when insufficient_privilege then
    reset role;
    v_denied:=true;
  end;
  select count(*) into v_after
  from public.customer_redemption_intents_v89
  where business_id=v_business and auth_user_id=v_customer;
  if not v_denied or v_after<>v_before then
    raise exception 'firm-disabled Loyalty created a redemption intent';
  end if;

  -- A read-only Loyalty branch may project programme information, but it
  -- cannot advertise or prepare a QR which no branch can confirm.
  perform pg_temp.as_v117_user(v_super);
  perform public.platform_set_module_overrides_v105(
    v_business,v_branch_enabled,
    '[{"module":"loyalty","mode":"r","expected_version":null}]'::jsonb,
    'v117 read-only Loyalty acceptance'
  );
  reset role;

  perform pg_temp.as_v117_user(v_customer);
  v_wallet:=public.customer_get_wallet();
  v_actions:=public.customer_get_business_actions_v89(v_business);
  reset role;
  if not coalesce((v_wallet#>>'{0,loyalty,enabled}')::boolean,false)
     or coalesce((v_actions#>>'{redemption,enabled}')::boolean,false)
     or v_actions#>>'{redemption,classic,availability}'<>'disabled' then
    raise exception 'read-only Loyalty advertised an unfulfillable QR: % / %',
      v_wallet,v_actions;
  end if;

  select count(*) into v_before
  from public.customer_redemption_intents_v89
  where business_id=v_business and auth_user_id=v_customer;
  v_denied:=false;
  begin
    perform pg_temp.as_v117_user(v_customer);
    perform public.customer_create_redemption_intent_v89(
      v_business,null,gen_random_uuid(),'classic_points'
    );
    reset role;
  exception when insufficient_privilege then
    reset role;
    v_denied:=true;
  end;
  select count(*) into v_after
  from public.customer_redemption_intents_v89
  where business_id=v_business and auth_user_id=v_customer;
  if not v_denied or v_after<>v_before then
    raise exception 'read-only Loyalty created an unfulfillable QR';
  end if;

  perform pg_temp.as_v117_user(v_owner);
  v_workspace_projection:=public.get_my_modules(v_business);
  v_branch_projection:=public.get_my_modules_at_v115(
    v_business,v_branch_disabled
  );
  if not (v_workspace_projection->'modules' @> '["loyalty"]'::jsonb)
     or v_branch_projection->'modules' @> '["loyalty"]'::jsonb then
    reset role;
    raise exception 'read-only Loyalty projection widened the wrong scope';
  end if;
  v_branch_projection:=public.get_my_modules_at_v115(
    v_business,v_branch_enabled
  );
  reset role;
  if not (v_branch_projection->'modules' @> '["loyalty"]'::jsonb)
     or v_branch_projection#>>'{module_perms,loyalty}'<>'r' then
    raise exception 'read-only Loyalty was absent at its exact branch';
  end if;

  -- Upgrading the exact branch to rw makes the action available without
  -- widening the disabled comparison branch.
  select version into v_override_version
  from public.platform_module_overrides_v94
  where business_id=v_business
    and branch_scope=v_branch_enabled
    and module_key='loyalty';
  perform pg_temp.as_v117_user(v_super);
  perform public.platform_set_module_overrides_v105(
    v_business,v_branch_enabled,
    jsonb_build_array(jsonb_build_object(
      'module','loyalty','mode','rw',
      'expected_version',v_override_version
    )),
    'v117 branch-only writable Loyalty acceptance'
  );
  reset role;
  perform pg_temp.as_v117_user(v_customer);
  v_actions:=public.customer_get_business_actions_v89(v_business);
  reset role;
  if not coalesce((v_actions#>>'{redemption,enabled}')::boolean,false)
     or v_actions#>>'{redemption,classic,availability}'
        <>'available_at_counter' then
    raise exception 'writable Loyalty did not restore customer action: %',
      v_actions;
  end if;
  perform pg_temp.as_v117_user(v_owner);
  v_branch_projection:=public.get_my_modules_at_v115(
    v_business,v_branch_disabled
  );
  if v_branch_projection->'modules' @> '["loyalty"]'::jsonb then
    reset role;
    raise exception 'writable Loyalty widened the disabled comparison branch';
  end if;
  v_branch_projection:=public.get_my_modules_at_v115(
    v_business,v_branch_enabled
  );
  reset role;
  if v_branch_projection#>>'{module_perms,loyalty}'<>'rw' then
    raise exception 'writable Loyalty was absent at its exact branch';
  end if;

  -- Customer presentation is non-economic. A denied scanner must leave the
  -- exact pending intent and all balances unchanged.
  perform pg_temp.as_v117_user(v_customer);
  v_result:=public.customer_create_redemption_intent_v89(
    v_business,null,gen_random_uuid(),'classic_points'
  );
  reset role;
  v_intent:=(v_result->>'intent_id')::uuid;
  v_qr_token:=v_result->>'qr_token';
  select coalesce(sum(points),0)::integer into v_points_before
  from public.points_ledger
  where business_id=v_business and client_id=v_client;
  select count(*) into v_redemptions_before
  from public.loyalty_operations
  where business_id=v_business
    and operation_type='redeem_points'
    and status='completed';
  select coalesce(sum(amount_cents),0)::integer into v_credit_before
  from public.credit_ledger
  where business_id=v_business and client_id=v_client;

  v_denied:=false;
  begin
    perform pg_temp.as_v117_user(v_frontdesk);
    perform public.merchant_scan_redemption_qr_v117(
      v_business,v_branch_disabled,v_qr_token,gen_random_uuid()
    );
    reset role;
  exception when insufficient_privilege then
    reset role;
    v_denied:=true;
  end;
  if not v_denied
     or (select status from public.customer_redemption_intents_v89
         where id=v_intent)<>'pending'
     or (select coalesce(sum(points),0)::integer
         from public.points_ledger
         where business_id=v_business and client_id=v_client)
        <>v_points_before
     or (select count(*) from public.loyalty_operations
         where business_id=v_business
           and operation_type='redeem_points'
           and status='completed')<>v_redemptions_before
     or (select coalesce(sum(amount_cents),0)::integer
         from public.credit_ledger
         where business_id=v_business and client_id=v_client)
        <>v_credit_before then
    raise exception 'branch-disabled Loyalty changed redemption state';
  end if;

  perform pg_temp.as_v117_user(v_frontdesk);
  v_result:=public.merchant_scan_redemption_qr_v117(
    v_business,v_branch_enabled,v_qr_token,v_scan_key
  );
  reset role;
  if v_result->>'status'<>'completed'
     or (v_result->>'branch_id')::uuid<>v_branch_enabled
     or (v_result->>'points_spent')::integer<>50
     or (select status from public.customer_redemption_intents_v89
         where id=v_intent)<>'completed'
     or (select coalesce(sum(points),0)::integer
         from public.points_ledger
         where business_id=v_business and client_id=v_client)
        <>v_points_before-50
     or (select count(*) from public.loyalty_operations
         where business_id=v_business
           and operation_type='redeem_points'
           and status='completed')<>v_redemptions_before+1
     or (select coalesce(sum(amount_cents),0)::integer
         from public.credit_ledger
         where business_id=v_business and client_id=v_client)
        <>v_credit_before+500 then
    raise exception 'branch-enabled Loyalty scanner did not complete once: %',
      v_result;
  end if;

  perform pg_temp.as_v117_user(v_frontdesk);
  v_result:=public.merchant_scan_redemption_qr_v117(
    v_business,v_branch_enabled,v_qr_token,v_scan_key
  );
  reset role;
  if not coalesce((v_result->>'replayed')::boolean,false)
     or (select coalesce(sum(points),0)::integer
         from public.points_ledger
         where business_id=v_business and client_id=v_client)
        <>v_points_before-50
     or (select count(*) from public.loyalty_operations
         where business_id=v_business
           and operation_type='redeem_points'
           and status='completed')<>v_redemptions_before+1
     or (select coalesce(sum(amount_cents),0)::integer
         from public.credit_ledger
         where business_id=v_business and client_id=v_client)
        <>v_credit_before+500 then
    raise exception 'branch-enabled Loyalty replay changed economic state: %',
      v_result;
  end if;

  -- Issue one real SGD 50 liability at an enabled branch, then prove a
  -- branch-disabled Gift cards writer creates neither liability, sale nor
  -- idempotency operation.
  perform pg_temp.as_v117_user(v_super);
  perform public.platform_set_module_overrides_v105(
    v_business,v_branch_disabled,
    '[{"module":"giftcards","mode":"disabled","expected_version":null}]'::jsonb,
    'v117 branch-disabled gift-card issuance acceptance'
  );
  reset role;

  perform pg_temp.as_v117_user(v_owner);
  v_result:=public.issue_gift_card_at_branch_v117(
    v_business,v_branch_enabled,5000,v_client,
    'alicia.v117@example.test',gen_random_uuid()
  );
  reset role;
  v_card:=(v_result->>'gift_card_id')::uuid;
  v_card_code:=v_result->>'code';
  if v_result->>'status'<>'completed'
     or (v_result->>'branch_id')::uuid<>v_branch_enabled
     or (select balance_cents from public.gift_cards where id=v_card)<>5000
     or (select branch_id from public.sales
         where id=(v_result->>'sale_id')::uuid)<>v_branch_enabled then
    raise exception 'enabled branch did not issue the SGD 50 gift liability';
  end if;

  select count(*) into v_cards_before
  from public.gift_cards where business_id=v_business;
  select count(*) into v_sales_before
  from public.sales where business_id=v_business and kind='gift_card';
  select count(*) into v_operations_before
  from public.gift_card_issue_operations where business_id=v_business;
  v_denied:=false;
  begin
    perform pg_temp.as_v117_user(v_owner);
    perform public.issue_gift_card_at_branch_v117(
      v_business,v_branch_disabled,2500,v_client,
      'blocked.v117@example.test',gen_random_uuid()
    );
    reset role;
  exception when insufficient_privilege then
    reset role;
    v_denied:=true;
  end;
  if not v_denied
     or (select count(*) from public.gift_cards
         where business_id=v_business)<>v_cards_before
     or (select count(*) from public.sales
         where business_id=v_business and kind='gift_card')<>v_sales_before
     or (select count(*) from public.gift_card_issue_operations
         where business_id=v_business)<>v_operations_before then
    raise exception 'branch-disabled gift-card issuance created value';
  end if;

  -- Once new Gift cards issuance is disabled firm-wide, the existing SGD 50
  -- liability must remain visible and partially redeemable through the exact
  -- Till + Clients branch path.
  perform pg_temp.as_v117_user(v_super);
  perform public.platform_set_module_overrides_v105(
    v_business,null,
    '[{"module":"giftcards","mode":"disabled","expected_version":null}]'::jsonb,
    'v117 disable new gift-card issuance after existing liability'
  );
  reset role;

  select coalesce(sum(amount_cents),0)::integer into v_credit_before
  from public.credit_ledger
  where business_id=v_business and client_id=v_client;
  select count(*) into v_operations_before
  from public.gift_card_redeem_operations_v117
  where business_id=v_business;
  select count(*) into v_gift_loads_before
  from public.credit_ledger
  where business_id=v_business
    and client_id=v_client
    and entry_type='gift_card_load';

  begin
    perform pg_temp.as_v117_user(v_owner);
    if not public.business_has_active_gift_liability_v117(
      v_business,v_branch_disabled
    ) then
      reset role;
      raise exception
        'existing gift liability was not redeemable through Till: liability hidden';
    end if;
    v_result:=public.redeem_gift_card_at_branch_v117(
      v_business,v_branch_disabled,v_card_code,v_client,1000,
      v_gift_redeem_key
    );
    reset role;
  exception when others then
    reset role;
    raise exception
      'existing gift liability was not redeemable through Till: %',sqlerrm;
  end;
  if (v_result->>'loaded_cents')::integer<>1000
     or (v_result->>'remaining_cents')::integer<>4000
     or (v_result->>'branch_id')::uuid<>v_branch_disabled
     or coalesce((v_result->>'replayed')::boolean,true)
     or (select balance_cents from public.gift_cards where id=v_card)<>4000
     or (select coalesce(sum(amount_cents),0)::integer
         from public.credit_ledger
         where business_id=v_business and client_id=v_client)
        <>v_credit_before+1000
     or (select count(*) from public.gift_card_redeem_operations_v117
         where business_id=v_business)<>v_operations_before+1
     or (select count(*) from public.credit_ledger
         where business_id=v_business
           and client_id=v_client
           and entry_type='gift_card_load')<>v_gift_loads_before+1 then
    raise exception
      'existing gift liability was not redeemable through Till: %',v_result;
  end if;

  perform pg_temp.as_v117_user(v_owner);
  v_result:=public.redeem_gift_card_at_branch_v117(
    v_business,v_branch_disabled,v_card_code,v_client,1000,
    v_gift_redeem_key
  );
  reset role;
  if not coalesce((v_result->>'replayed')::boolean,false)
     or (select balance_cents from public.gift_cards where id=v_card)<>4000
     or (select coalesce(sum(amount_cents),0)::integer
         from public.credit_ledger
         where business_id=v_business and client_id=v_client)
        <>v_credit_before+1000
     or (select count(*) from public.gift_card_redeem_operations_v117
         where business_id=v_business)<>v_operations_before+1
     or (select count(*) from public.credit_ledger
         where business_id=v_business
           and client_id=v_client
           and entry_type='gift_card_load')<>v_gift_loads_before+1 then
    raise exception 'gift-card redemption replay changed economic state: %',
      v_result;
  end if;
end
$v117_acceptance$;

rollback;
