-- Rollback-only Nestly v102 checkout/history acceptance suite.
-- Run after the complete canonical chain through v102 in a disposable database.
begin;

do $fixture$
declare
  v_owner uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_client uuid:=gen_random_uuid();
  v_service uuid:=gen_random_uuid();
  v_branch_a uuid:=gen_random_uuid();
  v_branch_b uuid:=gen_random_uuid();
  v_config uuid:=gen_random_uuid();
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values(
    '00000000-0000-0000-0000-000000000000',v_owner,
    'authenticated','authenticated',
    'v102-owner-'||substr(v_owner::text,1,8)||'@example.test',
    '',now(),now(),now()
  );
  insert into public.businesses(
    id,name,slug,industry,enabled_modules
  ) values(
    v_business,'V102 checkout fixture',
    'v102-'||substr(v_business::text,1,8),'test',
    array['dashboard','clients','sales','till','packages','giftcards','loyalty']
  );
  insert into public.staff(
    business_id,user_id,role,full_name,active
  ) values(v_business,v_owner,'owner','V102 Owner',true);
  insert into public.branches(
    id,business_id,name,is_default,active
  ) values
    (v_branch_a,v_business,'Main',true,true),
    (v_branch_b,v_business,'Other',false,true);
  insert into public.clients(
    id,business_id,full_name,phone
  ) values(v_client,v_business,'Frozen Package Customer','+6581234567');
  insert into public.services(
    id,business_id,name,variant_label,price_cents,duration_min,active
  ) values(
    v_service,v_business,'Overflow-safe service','Long',2147483647,60,true
  );
  update public.business_workspace_controls_v94
  set approval_status='approved',
      version=version+1,
      decided_at=clock_timestamp(),
      decision_reason='v102 rollback acceptance fixture',
      updated_at=clock_timestamp()
  where business_id=v_business;

  -- Minimum real published loyalty programme consumed by the final sale
  -- trigger. The behaviour block toggles only the package-sale policy.
  insert into public.firm_config_versions(
    id,business_id,version_no,status,source,snapshot_hash,created_by
  ) values(
    v_config,v_business,1,'draft','manual',
    md5('v102-package-points-programme'),v_owner
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
    2,50,500,'points_earned','none'
  );
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  update public.firm_config_versions
  set status='published',published_at=clock_timestamp()
  where id=v_config;
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,
    current_config_version_id
  ) values(
    v_business,'points',true,'classic','published',v_config
  );
  perform set_config('app.v79_system_transition','on',true);
  update public.businesses
  set active_config_version_id=v_config
  where id=v_business;
  perform set_config('app.v79_system_transition','',true);

  perform set_config('test.v102_owner',v_owner::text,true);
  perform set_config('test.v102_business',v_business::text,true);
  perform set_config('test.v102_client',v_client::text,true);
  perform set_config('test.v102_service',v_service::text,true);
  perform set_config('test.v102_branch_a',v_branch_a::text,true);
  perform set_config('test.v102_branch_b',v_branch_b::text,true);
end
$fixture$;

create or replace function pg_temp.as_v102_user(p_uid uuid)
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role','authenticated')::text,
    true
  );
end
$$;
grant execute on function pg_temp.as_v102_user(uuid) to authenticated;

do $acl$
begin
  if not has_function_privilege(
       'authenticated',
       'public.sell_package_v102(uuid,uuid,uuid,uuid,uuid)','EXECUTE'
     )
     or not has_function_privilege(
       'authenticated',
       'public.use_package_session_v102(uuid,uuid,uuid,text)','EXECUTE'
     )
     or not has_function_privilege(
       'authenticated',
       'public.issue_gift_card(uuid,integer,uuid,text,uuid)','EXECUTE'
     )
     or not has_function_privilege(
       'authenticated',
       'public.staff_list_package_entitlements_v102(uuid)','EXECUTE'
     ) then
    raise exception 'v102 authenticated RPC grants are incomplete';
  end if;
  if has_function_privilege(
       'anon','public.sell_package_v102(uuid,uuid,uuid,uuid,uuid)','EXECUTE'
     )
     or has_function_privilege(
       'anon','public.use_package_session_v102(uuid,uuid,uuid,text)','EXECUTE'
     )
     or has_function_privilege(
       'authenticated','public.sell_package(uuid,uuid,uuid)','EXECUTE'
     )
     or has_function_privilege(
       'authenticated','public.sell_package(uuid,uuid,uuid,uuid)','EXECUTE'
     )
     or has_function_privilege(
       'authenticated','public.use_package_session(uuid,uuid,text)','EXECUTE'
     ) then
    raise exception 'v102 legacy/anonymous writer ACL is open';
  end if;
  if exists(
    select 1
    from pg_catalog.pg_proc procedure
    join pg_catalog.pg_namespace namespace
      on namespace.oid=procedure.pronamespace
    where namespace.nspname='public'
      and procedure.proname='sell_package'
      and (
        has_function_privilege('authenticated',procedure.oid,'EXECUTE')
        or has_function_privilege('anon',procedure.oid,'EXECUTE')
      )
  ) then
    raise exception 'a legacy sell_package overload remains Data API executable';
  end if;
  if has_table_privilege(
       'authenticated','public.package_plans','INSERT,UPDATE,DELETE'
     ) then
    raise exception 'authenticated still has direct package_plans write access';
  end if;
  if not has_function_privilege(
       'authenticated','app.v95_storage_path_owned(text)','EXECUTE'
     )
     or has_function_privilege(
       'anon','app.v95_storage_path_owned(text)','EXECUTE'
     ) then
    raise exception 'v102 storage helper ACL is wrong';
  end if;
end
$acl$;

select pg_temp.as_v102_user(current_setting('test.v102_owner')::uuid);
select public.adjust_points(
  current_setting('test.v102_business')::uuid,
  current_setting('test.v102_client')::uuid,
  7,
  'v102 ledger truth fixture'
);

do $behaviour$
declare
  v_business uuid:=current_setting('test.v102_business')::uuid;
  v_client uuid:=current_setting('test.v102_client')::uuid;
  v_service uuid:=current_setting('test.v102_service')::uuid;
  v_branch_a uuid:=current_setting('test.v102_branch_a')::uuid;
  v_branch_b uuid:=current_setting('test.v102_branch_b')::uuid;
  v_plan public.package_plans%rowtype;
  v_next public.package_plans%rowtype;
  v_off_key uuid:=gen_random_uuid();
  v_on_key uuid:=gen_random_uuid();
  v_gift_key uuid:=gen_random_uuid();
  v_sale_off jsonb;
  v_sale_on jsonb;
  v_replay jsonb;
  v_session jsonb;
  v_session_replay jsonb;
  v_gift jsonb;
  v_entitlements jsonb;
  v_conflicted boolean:=false;
  v_disabled boolean:=false;
  v_old_plan_blocked boolean:=false;
  v_legacy_three_blocked boolean:=false;
  v_legacy_four_blocked boolean:=false;
begin
  select * into v_plan from public.save_package_plan_v102(
    v_business,null,'Frozen original',5000,1000,v_service,true
  );
  if v_plan.version_no<>1
     or v_plan.list_unit_cents_snapshot<>2147483647::bigint
     or v_plan.list_value_cents_snapshot<>2147483647000::bigint then
    raise exception 'v102 bigint package snapshots overflowed or drifted';
  end if;

  -- Data API callers cannot bypass branch/idempotency/snapshot enforcement.
  begin
    perform public.sell_package(v_business,v_client,v_plan.id);
  exception when insufficient_privilege then
    v_legacy_three_blocked:=true;
  end;
  begin
    perform public.sell_package(
      v_business,v_client,v_plan.id,gen_random_uuid()
    );
  exception when insufficient_privilege then
    v_legacy_four_blocked:=true;
  end;
  if not v_legacy_three_blocked or not v_legacy_four_blocked then
    raise exception 'v102 authenticated caller executed legacy package sale overload';
  end if;

  -- OFF: a real active loyalty programme exists, but the owner package policy
  -- prevents any award. The pre-existing seven-point adjustment remains truth.
  perform public.set_package_points_policy_v102(v_business,false);
  v_sale_off:=public.sell_package_v102(
    v_business,v_client,v_plan.id,v_branch_a,v_off_key
  );
  v_replay:=public.sell_package_v102(
    v_business,v_client,v_plan.id,v_branch_a,v_off_key
  );
  if v_sale_off is distinct from v_replay
     or (v_sale_off->>'sale_id')::uuid is null
     or (v_sale_off->>'client_package_id')::uuid is null
     or (v_sale_off->>'points_earned')::bigint<>0
     or (v_sale_off->>'points_total')::bigint<>7 then
    raise exception 'v102 points-off package sale awarded or replay drifted';
  end if;

  -- ON: the same $50 package earns exactly 100 points at 2 points/SGD.
  -- Lost-response retry must return the identical persisted receipt.
  perform public.set_package_points_policy_v102(v_business,true);
  v_sale_on:=public.sell_package_v102(
    v_business,v_client,v_plan.id,v_branch_a,v_on_key
  );
  v_replay:=public.sell_package_v102(
    v_business,v_client,v_plan.id,v_branch_a,v_on_key
  );
  if v_sale_on is distinct from v_replay
     or (v_sale_on->>'points_earned')::bigint<>100
     or (v_sale_on->>'points_total')::bigint<>107 then
    raise exception 'v102 points-on package sale/replay is not exact ledger truth';
  end if;
  -- Replaying the earlier OFF operation after the ledger has changed must
  -- still return its original total=7 receipt, not recompute against 107.
  if public.sell_package_v102(
       v_business,v_client,v_plan.id,v_branch_a,v_off_key
     ) is distinct from v_sale_off then
    raise exception 'v102 completed package receipt drifted after later points';
  end if;
  perform set_config('test.v102_off_sale',v_sale_off->>'sale_id',true);
  perform set_config('test.v102_on_sale',v_sale_on->>'sale_id',true);

  begin
    perform public.sell_package_v102(
      v_business,v_client,v_plan.id,v_branch_b,v_on_key
    );
  exception when unique_violation then
    v_conflicted:=true;
  end;
  if not v_conflicted then
    raise exception 'v102 package sale key accepted changed branch payload';
  end if;

  select * into v_next from public.save_package_plan_v102(
    v_business,v_plan.id,'Edited replacement',6000,10,v_service,true
  );
  if v_next.id=v_plan.id or v_next.version_no<>2
     or v_next.supersedes_plan_id<>v_plan.id then
    raise exception 'v102 plan edit did not clone/version';
  end if;
  begin
    perform public.sell_package_v102(
      v_business,v_client,v_plan.id,v_branch_a,gen_random_uuid()
    );
  exception when invalid_parameter_value then
    v_old_plan_blocked:=true;
  end;
  if not v_old_plan_blocked then
    raise exception 'v102 superseded plan remains sellable';
  end if;
  v_entitlements:=public.staff_list_package_entitlements_v102(v_business);
  if jsonb_array_length(v_entitlements)<>2
     or exists(
       select 1 from jsonb_array_elements(v_entitlements) entitlement
       where entitlement->>'plan_name'<>'Frozen original'
          or (entitlement->>'sessions')::integer<>1000
          or (entitlement->>'price_cents')::bigint<>5000
     ) then
    raise exception 'v102 sold package history followed mutable plan data';
  end if;

  v_session:=public.use_package_session_v102(
    v_business,(v_sale_on->>'client_package_id')::uuid,v_branch_a,
    'v102-session-retry'
  );
  v_session_replay:=public.use_package_session_v102(
    v_business,(v_sale_on->>'client_package_id')::uuid,v_branch_a,
    'v102-session-retry'
  );
  if v_session is distinct from v_session_replay
     or (v_session->>'branch_id')::uuid<>v_branch_a
     or (v_session->>'remaining_before')::integer<>1000
     or (v_session->>'remaining_after')::integer<>999
     or (v_session->>'points_earned')::integer<>0
     or (v_session->>'points_total')::integer<>107 then
    raise exception 'v102 branch session earned again or did not replay exact result';
  end if;
  perform set_config('test.v102_session_sale',v_session->>'sale_id',true);
  v_conflicted:=false;
  begin
    perform public.use_package_session_v102(
      v_business,(v_sale_on->>'client_package_id')::uuid,v_branch_b,
      'v102-session-retry'
    );
  exception when unique_violation then
    v_conflicted:=true;
  end;
  if not v_conflicted then
    raise exception 'v102 package session key accepted changed branch payload';
  end if;

  perform public.set_gift_card_sales_enabled_v102(v_business,true);
  v_gift:=public.issue_gift_card(
    v_business,2500,v_client,null,v_gift_key
  );
  perform public.set_gift_card_sales_enabled_v102(v_business,false);
  if public.issue_gift_card(
       v_business,2500,v_client,null,v_gift_key
     ) is distinct from v_gift then
    raise exception 'disabled gift-card switch broke exact completed replay';
  end if;
  begin
    perform public.issue_gift_card(
      v_business,2500,v_client,null,gen_random_uuid()
    );
  exception when sqlstate '55000' then
    v_disabled:=true;
  end;
  if not v_disabled then
    raise exception 'disabled gift-card switch allowed new issuance';
  end if;
end
$behaviour$;

reset role;
select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claims','{}',true);

do $evidence$
declare
  v_business uuid:=current_setting('test.v102_business')::uuid;
  v_off_sale uuid:=current_setting('test.v102_off_sale')::uuid;
  v_on_sale uuid:=current_setting('test.v102_on_sale')::uuid;
  v_session_sale uuid:=current_setting('test.v102_session_sale')::uuid;
begin
  if (
    select count(*) from public.sale_intent_operations
    where business_id=v_business and operation_type='package_sale'
  )<>2 then
    raise exception 'v102 lost-response package retry duplicated operation';
  end if;
  if (
    select count(*) from public.package_session_consumptions
    where business_id=v_business
  )<>1 then
    raise exception 'v102 lost-response session retry duplicated consumption';
  end if;
  if (
    select count(*) from public.gift_card_issue_operations
    where business_id=v_business
  )<>1 then
    raise exception 'v102 gift switch/replay duplicated issuance';
  end if;
  if not exists(
    select 1 from public.package_session_consumptions consumption
    where consumption.business_id=v_business
      and consumption.result->>'sale_id'=consumption.sale_id::text
      and consumption.request_payload ? 'branch_id'
  ) then
    raise exception 'v102 immutable session result/branch evidence missing';
  end if;
  if exists(
    select 1 from public.points_ledger ledger
    where ledger.business_id=v_business and ledger.sale_id=v_off_sale
  ) then
    raise exception 'v102 points-off package sale wrote a ledger award';
  end if;
  if (
    select coalesce(sum(ledger.points),0)
    from public.points_ledger ledger
    where ledger.business_id=v_business and ledger.sale_id=v_on_sale
  )<>100 then
    raise exception 'v102 points-on package sale did not write exact award';
  end if;
  if (
    select count(*) from public.points_ledger ledger
    where ledger.business_id=v_business and ledger.sale_id=v_on_sale
  )<>1 then
    raise exception 'v102 points-on lost-response replay double-earned';
  end if;
  if exists(
    select 1 from public.points_ledger ledger
    where ledger.business_id=v_business and ledger.sale_id=v_session_sale
  ) then
    raise exception 'v102 package session earned points a second time';
  end if;
  if (
    select coalesce(sum(ledger.points),0)
    from public.points_ledger ledger
    where ledger.business_id=v_business
      and ledger.client_id=current_setting('test.v102_client')::uuid
  )<>107 then
    raise exception 'v102 final ledger total is not adjustment plus one package award';
  end if;
end
$evidence$;

rollback;
