-- Rollback-only v89 customer capability and scoped platform-access evidence.
-- Run after the canonical chain through v89 in a disposable database.
begin;

create or replace function pg_temp.as_v89_user(
  p_uid uuid,p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v89_user(uuid,text) to public;

-- These call-stack probes exercise the real PG_CONTEXT dispatcher used by
-- legacy platform RPCs. Their names deliberately contain the same trusted
-- module/read-or-write words as the production callers.
do $probes$
declare v_probe text;
begin
  foreach v_probe in array array[
    'reports','billing','commissions','sectors','automation','enterprise',
    'onboarding'
  ] loop
    execute format(
      'create or replace function pg_temp.platform_%s_read_probe()
       returns boolean language sql stable security definer
       set search_path to pg_catalog,public,app,pg_temp
       as %L',
      v_probe,'select app.is_platform_operator_v75()'
    );
    execute format(
      'create or replace function pg_temp.platform_%s_update_probe()
       returns boolean language sql stable security definer
       set search_path to pg_catalog,public,app,pg_temp
       as %L',
      v_probe,'select app.is_platform_operator_v75()'
    );
    execute format(
      'grant execute on function pg_temp.platform_%s_read_probe() to public',
      v_probe
    );
    execute format(
      'grant execute on function pg_temp.platform_%s_update_probe() to public',
      v_probe
    );
  end loop;
end
$probes$;

do $v89$
declare
  v_sa uuid:=gen_random_uuid();
  v_admin uuid:=gen_random_uuid();
  v_sales_a uuid:=gen_random_uuid();
  v_sales_b uuid:=gen_random_uuid();
  v_owner uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_consultant_a uuid:=gen_random_uuid();
  v_consultant_b uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_other_business uuid:=gen_random_uuid();
  v_customer_a uuid:=gen_random_uuid();
  v_customer_b uuid:=gen_random_uuid();
  v_identity_a uuid:=gen_random_uuid();
  v_identity_b uuid:=gen_random_uuid();
  v_client_a uuid;
  v_client_b uuid;
  v_service uuid:=gen_random_uuid();
  v_hidden_service uuid:=gen_random_uuid();
  v_appointment uuid:=gen_random_uuid();
  v_link_a uuid;
  v_config uuid:=gen_random_uuid();
  v_reward uuid:=gen_random_uuid();
  v_reward_version uuid:=gen_random_uuid();
  v_join_token text;
  v_other_join_token text;
  v_expired_join_token text:=repeat('e',64);
  v_join_idem uuid:=gen_random_uuid();
  v_intent_id uuid;
  v_qr_token text;
  v_redemption_count integer;
  v_points integer;
  v_cancelled_intent uuid;
  v_expired_intent uuid:=gen_random_uuid();
  v_expired_redemption_key uuid:=gen_random_uuid();
  v_balance_intent uuid;
  v_module text;
  v_probe text;
  v_read_allowed boolean;
  v_write_allowed boolean;
  v_result jsonb;
  v_catalog_receipt jsonb;
  v_classic_receipt jsonb;
  v_prospect_a uuid;
  v_prospect_b uuid;
  v_version bigint;
begin
  if to_regprocedure(
    'public.customer_join_business_from_qr_v89(text,uuid)'
  ) is null or to_regprocedure(
    'public.merchant_scan_redemption_qr_v89(uuid,text,uuid)'
  ) is null or to_regprocedure(
    'public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'
  ) is null or to_regprocedure(
    'public.platform_list_assignment_consultants_v89()'
  ) is null or to_regprocedure(
    'public.platform_lookup_access_user_v89(text)'
  ) is null or to_regprocedure(
    'public.platform_create_my_prospect_v89(text,text,text,text,text)'
  ) is null then
    raise exception 'v89 public contracts are incomplete';
  end if;

  if has_function_privilege(
      'authenticated','public.customer_claim_link_by_email(text,text)','EXECUTE')
     or has_function_privilege(
      'authenticated',
      'public.customer_claim_link_by_verified_phone(text,text)','EXECUTE')
     or has_function_privilege(
      'authenticated',
      'public.customer_sync_verified_relationships_v81(text)','EXECUTE')
     or has_function_privilege(
      'authenticated','public.join_program(text,text,text,text,boolean)','EXECUTE')
  then
    raise exception 'a legacy customer self-link route remains executable';
  end if;

  if has_table_privilege(
      'authenticated','public.customer_redemption_intents_v89','SELECT')
     or has_table_privilege(
      'authenticated','public.platform_access_grants_v89','SELECT')
     or has_table_privilege(
      'authenticated','app.v89_token_secrets','SELECT')
  then
    raise exception 'a private v89 table is browser readable';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,phone,encrypted_password,email_confirmed_at,
    phone_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_sa,'authenticated',
      'authenticated','v89-sa@example.test',null,'',now(),null,now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_admin,'authenticated',
      'authenticated','v89-admin@example.test',null,'',now(),null,now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_sales_a,'authenticated',
      'authenticated','v89-sales-a@example.test',null,'',now(),null,now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_sales_b,'authenticated',
      'authenticated','v89-sales-b@example.test',null,'',now(),null,now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated',
      'authenticated','v89-owner@example.test',null,'',now(),null,now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,'authenticated',
      'authenticated','v89-outsider@example.test',null,'',now(),null,now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_customer_a,'authenticated',
      'authenticated','v89-customer-a@example.test','+6581230089','',
      now(),now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_customer_b,'authenticated',
      'authenticated','v89-customer-b@example.test','+6581230189','',
      now(),now(),now(),now());
  insert into public.super_admins(user_id,email,note)
  values(v_sa,'v89-sa@example.test','v89 rollback fixture');
  insert into public.platform_consultants(
    id,user_id,display_name,tier,employment_started_on,created_by
  ) values
    (v_consultant_a,v_sales_a,'V89 Sales A','senior',
      current_date-400,v_sa),
    (v_consultant_b,v_sales_b,'V89 Sales B','junior',
      current_date-30,v_sa);
  insert into public.businesses(id,name,slug,join_enabled,enabled_modules)
  values
    (v_business,'V89 Capability Firm',
      'v89-capability-'||substr(v_business::text,1,8),true,
      array['dashboard','clients','bookings','appointments','loyalty']),
    (v_other_business,'V89 Other Firm',
      'v89-other-'||substr(v_other_business::text,1,8),true,
      array['dashboard','clients','bookings','appointments','loyalty']);
  insert into public.staff(business_id,user_id,role,full_name)
  values
    (v_business,v_owner,'owner','V89 Owner'),
    (v_other_business,v_owner,'owner','V89 Owner');

  perform pg_temp.as_v89_user(v_owner);
  v_result:=public.business_get_customer_capabilities_v89(v_business);
  if (v_result->>'booking_enabled')::boolean
     or (v_result->>'redemption_enabled')::boolean
     or (v_result->>'appointment_changes_enabled')::boolean then
    raise exception 'customer capabilities did not default closed: %',v_result;
  end if;
  v_result:=public.business_set_customer_capabilities_v89(
    v_business,true,true,true
  );
  reset role;
  if not (v_result->>'booking_enabled')::boolean
     or not (v_result->>'redemption_enabled')::boolean
     or not (v_result->>'appointment_changes_enabled')::boolean then
    raise exception 'owner capability update was not persisted: %',v_result;
  end if;

  begin
    perform pg_temp.as_v89_user(v_outsider);
    perform public.business_set_customer_capabilities_v89(
      v_business,false,false,false
    );
    reset role;
    raise exception 'outsider changed customer capabilities';
  exception when insufficient_privilege then
    reset role;
  end;

  -- Merely authenticating creates no business relationship. A merchant-issued
  -- QR is the only customer-side enrolment authority.
  insert into public.customer_identities(
    id,auth_user_id,status,created_via
  ) values
    (v_identity_a,v_customer_a,'active','phone_registration'),
    (v_identity_b,v_customer_b,'active','phone_registration');
  perform set_config('app.c42_profile_identity',v_identity_a::text,true);
  insert into public.customer_profiles(
    identity_id,auth_user_id,full_name,birth_date
  ) values(v_identity_a,v_customer_a,'V89 Customer A','1990-01-01');
  perform set_config('app.c42_profile_identity',v_identity_b::text,true);
  insert into public.customer_profiles(
    identity_id,auth_user_id,full_name,birth_date
  ) values(v_identity_b,v_customer_b,'V89 Customer B','1991-01-01');
  perform set_config('app.c42_profile_identity','',true);
  if exists(select 1 from public.customer_links
      where auth_user_id in(v_customer_a,v_customer_b)) then
    raise exception 'customer login auto-linked a business without a QR';
  end if;

  perform pg_temp.as_v89_user(v_owner);
  v_result:=public.business_create_customer_join_qr_v89(
    v_business,now()+interval '1 day'
  );
  v_join_token:=v_result->>'join_token';
  v_result:=public.business_create_customer_join_qr_v89(
    v_other_business,now()+interval '1 day'
  );
  v_other_join_token:=v_result->>'join_token';
  reset role;

  -- Existing CRM client: public QR form creates/updates the firm-side person,
  -- but only the authenticated QR claim creates a verified customer link.
  perform pg_temp.as_v89_user(null,'service_role');
  perform public.internal_public_join_v89(
    v_join_token,'V89 Customer A','81230089',
    'v89-customer-a@example.test',false
  );
  reset role;
  select id into v_client_a from public.clients
   where business_id=v_business and phone_norm=app.norm_phone('+6581230089');
  if v_client_a is null or exists(select 1 from public.customer_links
      where auth_user_id=v_customer_a) then
    raise exception 'public QR handoff linked before authenticated claim';
  end if;

  perform pg_temp.as_v89_user(v_customer_a);
  v_result:=public.customer_join_business_from_qr_v89(
    v_join_token,v_join_idem
  );
  reset role;
  if (v_result->>'replayed')::boolean
     or not exists(select 1 from public.customer_links
       where business_id=v_business and auth_user_id=v_customer_a
         and client_id=v_client_a and state='verified'
         and verification_method='qr_join') then
    raise exception 'existing client QR join did not create the canonical link: %',
      v_result;
  end if;
  perform pg_temp.as_v89_user(v_customer_a);
  v_result:=public.customer_join_business_from_qr_v89(
    v_join_token,v_join_idem
  );
  reset role;
  if not (v_result->>'replayed')::boolean
     or (select count(*) from public.customer_links
       where business_id=v_business and auth_user_id=v_customer_a)<>1 then
    raise exception 'QR join idempotency created duplicate links: %',v_result;
  end if;
  begin
    perform pg_temp.as_v89_user(v_customer_a);
    perform public.customer_join_business_from_qr_v89(
      v_other_join_token,v_join_idem
    );
    reset role;
    raise exception 'QR join idempotency key accepted a mismatched token';
  exception when unique_violation then
    reset role;
  end;

  -- New CRM client: the authenticated QR claim creates both the client and the
  -- single verified link from the verified phone/profile.
  perform pg_temp.as_v89_user(v_customer_b);
  v_result:=public.customer_join_business_from_qr_v89(
    v_join_token,gen_random_uuid()
  );
  reset role;
  select client_id into v_client_b from public.customer_links
   where business_id=v_business and auth_user_id=v_customer_b
     and state='verified';
  if v_client_b is null
     or (select count(*) from public.clients
       where business_id=v_business and phone_norm=app.norm_phone('+6581230189'))<>1
     or (select count(*) from public.customer_links
       where business_id=v_business and auth_user_id=v_customer_b)<>1 then
    raise exception 'new customer QR join was not one client plus one link';
  end if;

  insert into public.business_customer_join_qr_v89(
    business_id,token_hash,status,expires_at,issued_by,created_at
  ) values(
    v_business,app.v89_sha256(v_expired_join_token),'active',
    now()-interval '1 hour',v_owner,now()-interval '2 hours'
  );
  begin
    perform pg_temp.as_v89_user(v_customer_b);
    perform public.customer_join_business_from_qr_v89(
      v_expired_join_token,gen_random_uuid()
    );
    reset role;
    raise exception 'expired join QR was accepted';
  exception when invalid_parameter_value then
    reset role;
  end;

  -- Customer-bound booking inserts are closed until the owner enables booking.
  insert into public.services(
    id,business_id,name,price_cents,duration_min,active,show_on_booking_page
  ) values
    (v_service,v_business,'V89 Public Service',1000,30,true,true),
    (v_hidden_service,v_business,'V89 Hidden Service',1200,30,true,false);
  v_result:=public.get_business_public(
    (select slug from public.businesses where id=v_business)
  )::jsonb;
  if jsonb_array_length(v_result->'services')<>1
     or v_result#>>'{services,0,id}'<>v_service::text
     or v_result::text like '%V89 Hidden Service%' then
    raise exception 'public booking GET exposed a non-bookable service: %',
      v_result;
  end if;
  begin
    perform public.internal_public_booking_submit(
      (select slug from public.businesses where id=v_business),
      'Hidden Service Customer','hidden@example.test','+6581230089',
      v_hidden_service,1,now()+interval '1 day',null,null,false,
      encode(gen_random_bytes(32),'hex'),encode(gen_random_bytes(32),'hex'),
      encode(gen_random_bytes(32),'hex'),null
    );
    raise exception 'public booking submit accepted a hidden service';
  exception when invalid_parameter_value then null;
  end;
  perform pg_temp.as_v89_user(v_owner);
  perform public.business_set_customer_capabilities_v89(
    v_business,false,true,true
  );
  reset role;
  begin
    insert into public.booking_requests(
      business_id,name,phone,service_id,preferred_at,customer_client_id
    ) values(
      v_business,'V89 Customer A','81230089',v_service,
      now()+interval '1 day',v_client_a
    );
    raise exception 'customer booking bypassed the disabled business switch';
  exception when insufficient_privilege then null;
  end;
  perform pg_temp.as_v89_user(v_owner);
  perform public.business_set_customer_capabilities_v89(
    v_business,true,true,true
  );
  reset role;
  insert into public.booking_requests(
    business_id,name,phone,service_id,preferred_at,customer_client_id
  ) values(
    v_business,'V89 Customer A','81230089',v_service,
    now()+interval '1 day',v_client_a
  );
  select id into v_link_a from public.customer_links
    where business_id=v_business and auth_user_id=v_customer_a;
  insert into public.appointments(
    id,business_id,client_id,starts_at,ends_at,status
  ) values(
    v_appointment,v_business,v_client_a,now()+interval '2 days',
    now()+interval '2 days 30 minutes','booked'
  );
  perform pg_temp.as_v89_user(v_customer_a);
  v_result:=public.customer_list_programmes_v89();
  reset role;
  if jsonb_array_length(v_result->'programmes')<>1 then
    raise exception 'programme reader did not return one card per business: %',v_result;
  end if;
  update public.businesses set enabled_modules=
    array_remove(enabled_modules,'bookings') where id=v_business;
  perform pg_temp.as_v89_user(v_customer_a);
  v_result:=public.customer_get_business_actions_v89(v_business);
  reset role;
  if (v_result#>>'{booking,enabled}')::boolean then
    raise exception 'booking CTA stayed enabled after module removal';
  end if;
  begin
    insert into public.booking_requests(
      business_id,name,phone,service_id,preferred_at,customer_client_id
    ) values(
      v_business,'V89 Customer A','81230089',v_service,
      now()+interval '3 days',v_client_a
    );
    raise exception 'booking mutation survived bookings-module removal';
  exception when insufficient_privilege then null;
  end;
  update public.businesses set enabled_modules=
    array_append(enabled_modules,'bookings') where id=v_business;

  update public.businesses set enabled_modules=
    array_remove(array_remove(enabled_modules,'bookings'),'appointments')
    where id=v_business;
  perform pg_temp.as_v89_user(v_customer_a);
  v_result:=public.customer_get_business_actions_v89(v_business);
  reset role;
  if (v_result#>>'{appointment_changes,enabled}')::boolean then
    raise exception 'appointment CTA stayed enabled after module removal';
  end if;
  begin
    insert into public.customer_appointment_action_requests(
      business_id,identity_id,auth_user_id,link_id,client_id,appointment_id,
      action,idempotency_key,request_hash
    ) values(
      v_business,v_identity_a,v_customer_a,v_link_a,v_client_a,v_appointment,
      'cancel','v89-module-off',repeat('a',64)
    );
    raise exception 'appointment mutation survived appointments-module removal';
  exception when insufficient_privilege then null;
  end;
  update public.businesses set enabled_modules=
    array_append(enabled_modules,'bookings') where id=v_business;

  -- Publish a minimal canonical loyalty configuration and fund both the ledger
  -- and its provenance batch. The intent itself must mutate neither.
  insert into public.firm_config_versions(
    id,business_id,version_no,status,source,snapshot_hash,created_by
  ) values(v_config,v_business,1,'draft','manual',md5('v89-config'),v_owner);
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config('request.jwt.claims',json_build_object(
    'sub',v_owner,'role','authenticated')::text,true);
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,
    expiry_mode
  ) values(
    v_config,v_business,'points','points_tiers',true,1,40,0,
    'points_earned','none'
  );
  insert into public.loyalty_rewards(
    id,business_id,name,cost_points,credit_cents,active,internal_name,
    customer_name,fulfillment_kind,estimated_cost_cents
  ) values(
    v_reward,v_business,'V89 Reward',40,0,true,'V89 Reward','V89 Reward',
    'manual_item',0
  );
  insert into public.loyalty_reward_versions(
    id,reward_id,business_id,config_version_id,internal_name,customer_name,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active
  ) values(
    v_reward_version,v_reward,v_business,v_config,'V89 Reward','V89 Reward',
    'manual_item',40,0,0,true
  );
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
  update public.firm_config_versions set status='published',published_at=now()
   where id=v_config;
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,
    current_config_version_id
  ) values(
    v_business,'points',true,'points_tiers','published',v_config
  ) on conflict(business_id) do update set
    active=true,loyalty_model='points_tiers',configuration_status='published',
    current_config_version_id=v_config;
  perform set_config('app.v79_system_transition','on',true);
  update public.businesses set active_config_version_id=v_config
   where id=v_business;
  perform set_config('app.v79_system_transition','',true);
  perform pg_temp.as_v89_user(v_owner);
  perform public.adjust_points(
    v_business,v_client_a,100,'v89 funded redemption fixture'
  );
  reset role;

  perform pg_temp.as_v89_user(v_customer_a);
  v_result:=public.customer_get_business_actions_v89(v_business);
  reset role;
  if v_result#>>'{rewards,0,availability}'<>'available_at_counter' then
    raise exception 'catalog action did not use the canonical availability enum: %',
      v_result;
  end if;
  update public.businesses set enabled_modules=
    array_remove(enabled_modules,'loyalty') where id=v_business;
  perform pg_temp.as_v89_user(v_customer_a);
  v_result:=public.customer_get_business_actions_v89(v_business);
  reset role;
  if (v_result#>>'{redemption,enabled}')::boolean then
    raise exception 'redemption CTA stayed enabled after loyalty-module removal';
  end if;
  begin
    perform pg_temp.as_v89_user(v_customer_a);
    perform public.customer_create_redemption_intent_v89(
      v_business,v_reward,gen_random_uuid(),'catalog_reward'
    );
    reset role;
    raise exception 'redemption intent survived loyalty-module removal';
  exception when insufficient_privilege then
    reset role;
  end;
  update public.businesses set enabled_modules=
    array_append(enabled_modules,'loyalty') where id=v_business;

  select count(*) into v_redemption_count from public.loyalty_redemptions
   where business_id=v_business and client_id=v_client_a;
  select coalesce(sum(points),0)::integer into v_points from public.points_ledger
   where business_id=v_business and client_id=v_client_a;
  perform pg_temp.as_v89_user(v_customer_a);
  v_result:=public.customer_create_redemption_intent_v89(
    v_business,v_reward,gen_random_uuid()
  );
  reset role;
  v_intent_id:=(v_result->>'intent_id')::uuid;
  v_qr_token:=v_result->>'qr_token';
  if v_result->>'status'<>'pending'
     or (select count(*) from public.loyalty_redemptions
       where business_id=v_business and client_id=v_client_a)<>v_redemption_count
     or (select coalesce(sum(points),0)::integer from public.points_ledger
       where business_id=v_business and client_id=v_client_a)<>v_points then
    raise exception 'pending redemption mutated canonical balances: %',v_result;
  end if;

  begin
    perform pg_temp.as_v89_user(v_customer_b);
    perform public.customer_get_redemption_intent_v89(v_intent_id);
    reset role;
    raise exception 'another customer polled a redemption intent';
  exception when insufficient_privilege then
    reset role;
  end;
  begin
    perform pg_temp.as_v89_user(v_owner);
    perform public.merchant_scan_redemption_qr_v89(
      v_other_business,v_qr_token,gen_random_uuid()
    );
    reset role;
    raise exception 'wrong business completed a redemption QR';
  exception when invalid_parameter_value or insufficient_privilege then
    reset role;
  end;
  perform pg_temp.as_v89_user(v_owner);
  v_result:=public.merchant_scan_redemption_qr_v89(
    v_business,v_qr_token,gen_random_uuid()
  );
  reset role;
  v_catalog_receipt:=v_result;
  if v_result->>'status'<>'completed'
     or v_result->>'redemption_kind'<>'catalog_reward'
     or v_result->>'customer_name'<>'V89 Customer A'
     or v_result->>'reward_label'<>'V89 Reward'
     or (v_result->>'points_spent')::integer<>40
     or (v_result->>'credit_cents')::integer<>0
     or nullif(v_result->>'operation_id','') is null
     or nullif(v_result->>'redemption_id','') is null
     or (select count(*) from public.loyalty_redemptions
       where business_id=v_business and client_id=v_client_a)<>v_redemption_count+1
     or (select coalesce(sum(points),0)::integer from public.points_ledger
       where business_id=v_business and client_id=v_client_a)<>60 then
    raise exception 'merchant scan did not complete exactly one redemption: %',
      v_result;
  end if;
  perform pg_temp.as_v89_user(v_owner);
  v_result:=public.merchant_scan_redemption_qr_v89(
    v_business,v_qr_token,gen_random_uuid()
  );
  reset role;
  if not (v_result->>'replayed')::boolean
     or (v_result-'replayed')<>(v_catalog_receipt-'replayed')
     or (select count(*) from public.loyalty_redemptions
       where business_id=v_business and client_id=v_client_a)<>v_redemption_count+1 then
    raise exception 'merchant replay created a second redemption: %',v_result;
  end if;

  -- A merchant disabling redemption after presentation must leave the intent
  -- pending and all canonical value rows untouched.
  perform pg_temp.as_v89_user(v_customer_a);
  v_result:=public.customer_create_redemption_intent_v89(
    v_business,v_reward,gen_random_uuid(),'catalog_reward'
  );
  reset role;
  v_intent_id:=(v_result->>'intent_id')::uuid;
  v_qr_token:=v_result->>'qr_token';
  perform pg_temp.as_v89_user(v_owner);
  perform public.business_set_customer_capabilities_v89(
    v_business,true,false,true
  );
  reset role;
  begin
    perform pg_temp.as_v89_user(v_owner);
    perform public.merchant_scan_redemption_qr_v89(
      v_business,v_qr_token,gen_random_uuid()
    );
    reset role;
    raise exception 'disabled-after-intent redemption completed';
  exception when insufficient_privilege then
    reset role;
  end;
  if (select status from public.customer_redemption_intents_v89
      where id=v_intent_id)<>'pending'
     or (select count(*) from public.loyalty_redemptions
       where business_id=v_business and client_id=v_client_a)
        <>v_redemption_count+1 then
    raise exception 'disabled scan left partial catalog state';
  end if;
  perform pg_temp.as_v89_user(v_owner);
  perform public.business_set_customer_capabilities_v89(
    v_business,true,true,true
  );
  reset role;
  perform pg_temp.as_v89_user(v_customer_a);
  perform public.customer_cancel_redemption_intent_v89(
    v_intent_id,gen_random_uuid()
  );
  reset role;

  -- The five-minute QR is a quote, not permission to silently apply changed
  -- programme terms.
  perform pg_temp.as_v89_user(v_customer_a);
  v_result:=public.customer_create_redemption_intent_v89(
    v_business,v_reward,gen_random_uuid(),'catalog_reward'
  );
  reset role;
  v_intent_id:=(v_result->>'intent_id')::uuid;
  v_qr_token:=v_result->>'qr_token';
  update public.loyalty_programs set active=false where business_id=v_business;
  begin
    perform pg_temp.as_v89_user(v_owner);
    perform public.merchant_scan_redemption_qr_v89(
      v_business,v_qr_token,gen_random_uuid()
    );
    reset role;
    raise exception 'catalog configuration changed after intent but scan completed';
  exception when check_violation then
    reset role;
  end;
  update public.loyalty_programs set active=true where business_id=v_business;
  if (select status from public.customer_redemption_intents_v89
      where id=v_intent_id)<>'pending' then
    raise exception 'catalog quote refusal changed intent state';
  end if;
  perform pg_temp.as_v89_user(v_customer_a);
  perform public.customer_cancel_redemption_intent_v89(
    v_intent_id,gen_random_uuid()
  );
  reset role;

  perform pg_temp.as_v89_user(v_customer_a);
  v_result:=public.customer_create_redemption_intent_v89(
    v_business,v_reward,gen_random_uuid()
  );
  v_cancelled_intent:=(v_result->>'intent_id')::uuid;
  v_qr_token:=v_result->>'qr_token';
  perform public.customer_cancel_redemption_intent_v89(
    v_cancelled_intent,gen_random_uuid()
  );
  reset role;
  begin
    perform pg_temp.as_v89_user(v_owner);
    perform public.merchant_scan_redemption_qr_v89(
      v_business,v_qr_token,gen_random_uuid()
    );
    reset role;
    raise exception 'cancelled redemption was completed';
  exception when invalid_parameter_value then
    reset role;
  end;

  insert into public.customer_redemption_intents_v89(
    id,business_id,identity_id,auth_user_id,client_id,redemption_kind,reward_id,
    quoted_program_id,quoted_config_version_id,quoted_reward_version_id,
    quoted_points_spent,quoted_credit_cents,quoted_terms,token_hash,
    idempotency_key,request_hash,expires_at,created_at
  ) values(
    v_expired_intent,v_business,v_identity_a,v_customer_a,v_client_a,
    'catalog_reward',v_reward,
    (select id from public.loyalty_programs where business_id=v_business),
    v_config,v_reward_version,40,0,'{}'::jsonb,
    app.v89_sha256(app.v89_redemption_token(
      v_identity_a,v_business,'catalog_reward',v_reward,
      v_expired_redemption_key)),
    v_expired_redemption_key,
    app.v89_sha256(v_business::text||':catalog_reward:'||v_reward::text),
    now()-interval '1 minute',now()-interval '6 minutes'
  );
  v_qr_token:=app.v89_redemption_token(
    v_identity_a,v_business,'catalog_reward',v_reward,
    v_expired_redemption_key
  );
  perform pg_temp.as_v89_user(v_owner);
  v_result:=public.merchant_scan_redemption_qr_v89(
    v_business,v_qr_token,gen_random_uuid()
  );
  reset role;
  if v_result->>'status'<>'expired'
     or (select count(*) from public.loyalty_redemptions
       where business_id=v_business and client_id=v_client_a)<>v_redemption_count+1 then
    raise exception 'expired redemption changed canonical redemption rows: %',
      v_result;
  end if;

  -- A balance can change between presentation and scan. The scan must recheck
  -- canonical ledger + batches and fail without recording another redemption.
  perform pg_temp.as_v89_user(v_customer_a);
  v_result:=public.customer_create_redemption_intent_v89(
    v_business,v_reward,gen_random_uuid()
  );
  reset role;
  v_balance_intent:=(v_result->>'intent_id')::uuid;
  v_qr_token:=v_result->>'qr_token';
  perform pg_temp.as_v89_user(v_owner);
  perform public.adjust_points(
    v_business,v_client_a,-30,'v89 intervening adjustment'
  );
  reset role;
  begin
    perform pg_temp.as_v89_user(v_owner);
    perform public.merchant_scan_redemption_qr_v89(
      v_business,v_qr_token,gen_random_uuid()
    );
    reset role;
    raise exception 'balance-changed redemption was completed';
  exception when check_violation then
    reset role;
  end;
  if (select count(*) from public.loyalty_redemptions
       where business_id=v_business and client_id=v_client_a)<>v_redemption_count+1
     or (select status from public.customer_redemption_intents_v89
       where id=v_balance_intent)<>'pending' then
    raise exception 'failed balance recheck left partial redemption state';
  end if;

  -- Simple Points uses the same pending/scan flow but delegates to the
  -- canonical redeem_points -> credit writer.
  perform set_config('app.v79_system_transition','on',true);
  update public.loyalty_programs set
    loyalty_model='classic',kind='points',redeem_points=20,
    reward_credit_cents=500 where business_id=v_business;
  perform set_config('app.v79_system_transition','',true);
  perform pg_temp.as_v89_user(v_customer_a);
  v_result:=public.customer_get_business_actions_v89(v_business);
  reset role;
  if v_result#>>'{redemption,classic,redemption_kind}'<>'classic_points'
     or v_result#>>'{redemption,classic,availability}'<>'available_at_counter'
     or jsonb_array_length(v_result->'rewards')<>0 then
    raise exception 'classic redemption descriptor is inconsistent: %',v_result;
  end if;
  perform pg_temp.as_v89_user(v_customer_a);
  v_result:=public.customer_create_redemption_intent_v89(
    v_business,null,gen_random_uuid(),'classic_points'
  );
  reset role;
  v_intent_id:=(v_result->>'intent_id')::uuid;
  v_qr_token:=v_result->>'qr_token';
  perform set_config('app.v79_system_transition','on',true);
  update public.loyalty_programs set redeem_points=25 where business_id=v_business;
  perform set_config('app.v79_system_transition','',true);
  begin
    perform pg_temp.as_v89_user(v_owner);
    perform public.merchant_scan_redemption_qr_v89(
      v_business,v_qr_token,gen_random_uuid()
    );
    reset role;
    raise exception 'classic terms changed after intent but scan completed';
  exception when check_violation then
    reset role;
  end;
  perform set_config('app.v79_system_transition','on',true);
  update public.loyalty_programs set redeem_points=20 where business_id=v_business;
  perform set_config('app.v79_system_transition','',true);
  perform pg_temp.as_v89_user(v_owner);
  v_classic_receipt:=public.merchant_scan_redemption_qr_v89(
    v_business,v_qr_token,gen_random_uuid()
  );
  reset role;
  if v_classic_receipt->>'redemption_kind'<>'classic_points'
     or v_classic_receipt->>'customer_name'<>'V89 Customer A'
     or v_classic_receipt->>'reward_label'<>'Store credit'
     or (v_classic_receipt->>'points_spent')::integer<>20
     or (v_classic_receipt->>'credit_cents')::integer<>500
     or nullif(v_classic_receipt->>'operation_id','') is null
     or v_classic_receipt->>'redemption_id' is not null
     or (select coalesce(sum(points),0)::integer from public.points_ledger
       where business_id=v_business and client_id=v_client_a)<>10
     or (select coalesce(sum(amount_cents),0)::integer from public.credit_ledger
       where business_id=v_business and client_id=v_client_a)<>500 then
    raise exception 'classic merchant receipt/value is inconsistent: %',
      v_classic_receipt;
  end if;
  perform pg_temp.as_v89_user(v_owner);
  v_result:=public.merchant_scan_redemption_qr_v89(
    v_business,v_qr_token,gen_random_uuid()
  );
  reset role;
  if not (v_result->>'replayed')::boolean
     or (v_result-'replayed')<>(v_classic_receipt-'replayed') then
    raise exception 'classic redemption replay changed its receipt: %',v_result;
  end if;

  perform pg_temp.as_v89_user(v_sa);
  perform public.platform_upsert_access_grant_v89(
    v_admin,'admin','{"overview":"r","onboarding":"r","reports":"r"}',true
  );
  perform public.platform_upsert_access_grant_v89(
    v_sales_a,'sales_staff',
    '{"onboarding":"rw","firms":"r","reports":"r"}',true
  );
  perform public.platform_upsert_access_grant_v89(
    v_sales_b,'sales_staff',
    '{"onboarding":"rw","firms":"r","reports":"r"}',true
  );
  reset role;

  begin
    perform pg_temp.as_v89_user(v_sa);
    perform public.platform_upsert_access_grant_v89(
      v_admin,'admin','{"unknown_module":"rw"}',true
    );
    reset role;
    raise exception 'unknown platform module permission was accepted';
  exception when invalid_parameter_value then
    reset role;
  end;

  -- The PG_CONTEXT compatibility dispatcher must preserve independent r/rw/off
  -- controls for every legacy module family.
  for v_module,v_probe in
    select * from (values
      ('reports','reports'),
      ('billing','billing'),
      ('commissions','commissions'),
      ('sectors','sectors'),
      ('automation','automation'),
      ('firms','enterprise'),
      ('onboarding','onboarding')
    ) mapping(module_key,probe_key)
  loop
    update public.platform_access_grants_v89
       set module_perms=jsonb_build_object(v_module,'r'),updated_by=v_sa,
           updated_at=now()
     where user_id=v_admin;
    perform pg_temp.as_v89_user(v_admin);
    execute format('select pg_temp.platform_%s_read_probe()',v_probe)
      into v_read_allowed;
    execute format('select pg_temp.platform_%s_update_probe()',v_probe)
      into v_write_allowed;
    reset role;
    if not v_read_allowed or v_write_allowed then
      raise exception 'PG_CONTEXT r-mode failed for module %: read %, write %',
        v_module,v_read_allowed,v_write_allowed;
    end if;

    update public.platform_access_grants_v89
       set module_perms=jsonb_build_object(v_module,'rw'),updated_by=v_sa,
           updated_at=now()
     where user_id=v_admin;
    perform pg_temp.as_v89_user(v_admin);
    execute format('select pg_temp.platform_%s_read_probe()',v_probe)
      into v_read_allowed;
    execute format('select pg_temp.platform_%s_update_probe()',v_probe)
      into v_write_allowed;
    reset role;
    if not v_read_allowed or not v_write_allowed then
      raise exception 'PG_CONTEXT rw-mode failed for module %: read %, write %',
        v_module,v_read_allowed,v_write_allowed;
    end if;

    update public.platform_access_grants_v89
       set module_perms='{}'::jsonb,updated_by=v_sa,updated_at=now()
     where user_id=v_admin;
    perform pg_temp.as_v89_user(v_admin);
    execute format('select pg_temp.platform_%s_read_probe()',v_probe)
      into v_read_allowed;
    execute format('select pg_temp.platform_%s_update_probe()',v_probe)
      into v_write_allowed;
    reset role;
    if v_read_allowed or v_write_allowed then
      raise exception 'PG_CONTEXT off-mode failed for module %: read %, write %',
        v_module,v_read_allowed,v_write_allowed;
    end if;
  end loop;

  update public.platform_access_grants_v89
     set module_perms='{"overview":"r","onboarding":"r","reports":"r"}'::jsonb,
         updated_by=v_sa,updated_at=now()
   where user_id=v_admin;
  begin
    perform pg_temp.as_v89_user(v_admin);
    perform public.super_admin_list_businesses();
    reset role;
    raise exception 'platform admin bypassed the SA-only business inventory';
  exception when insufficient_privilege then
    reset role;
  end;
  perform pg_temp.as_v89_user(v_admin);
  v_result:=public.platform_list_my_firms_v89('V89',100);
  reset role;
  if v_result->>'scope'<>'all' then
    raise exception 'admin overview did not use the v89 scoped firm reader';
  end if;

  -- Core reporting is an independent module contract. A reports-only admin can
  -- generate the core operational report without firms, onboarding, or billing;
  -- a firms-only admin cannot use the report RPC.
  update public.platform_access_grants_v89
     set module_perms='{"reports":"r"}'::jsonb,
         updated_by=v_sa,updated_at=now()
   where user_id=v_admin;
  perform pg_temp.as_v89_user(v_admin);
  v_result:=public.platform_generate_my_report_v89(array[v_business]);
  reset role;
  if (v_result#>>'{summary,business_count}')::integer<>1
     or (v_result#>>'{scope,business_ids,0}')::uuid<>v_business then
    raise exception 'reports-only admin did not receive the core report: %',
      v_result;
  end if;
  update public.platform_access_grants_v89
     set module_perms='{"firms":"r"}'::jsonb,
         updated_by=v_sa,updated_at=now()
   where user_id=v_admin;
  perform pg_temp.as_v89_user(v_admin);
  v_result:=public.platform_list_my_firms_v89('V89',100);
  reset role;
  if v_result->>'scope'<>'all' then
    raise exception 'firms-only admin did not receive the firm list: %',v_result;
  end if;
  begin
    perform pg_temp.as_v89_user(v_admin);
    perform public.platform_generate_my_report_v89(array[v_business]);
    reset role;
    raise exception 'firms-only admin generated a report';
  exception when insufficient_privilege then
    reset role;
  end;
  update public.platform_access_grants_v89
     set module_perms='{"overview":"r","onboarding":"r","reports":"r"}'::jsonb,
         updated_by=v_sa,updated_at=now()
   where user_id=v_admin;

  perform pg_temp.as_v89_user(v_sales_a);
  v_result:=public.platform_create_my_prospect_v89(
    'V89 Sales A Firm','retail','81230001','a-owner@example.test','Owner A'
  );
  reset role;
  v_prospect_a:=(v_result->>'prospect_id')::uuid;
  if v_prospect_a is null
     or (select created_by from public.sme_prospects
       where id=v_prospect_a)<>v_sales_a
     or (select assigned_consultant_id from public.sme_prospects
       where id=v_prospect_a)<>v_consultant_a then
    raise exception 'sales-created prospect did not retain ownership and assignment';
  end if;

  perform pg_temp.as_v89_user(v_sales_b);
  v_result:=public.platform_create_my_prospect_v89(
    'V89 Sales B Firm','retail','81230002','b-owner@example.test','Owner B'
  );
  reset role;
  v_prospect_b:=(v_result->>'prospect_id')::uuid;

  perform pg_temp.as_v89_user(v_sales_a);
  v_result:=public.platform_get_my_prospect_v89(v_prospect_a);
  reset role;
  if v_result#>>'{company,trading_name}'<>'V89 Sales A Firm' then
    raise exception 'sales staff could not read their own prospect';
  end if;

  begin
    perform pg_temp.as_v89_user(v_sales_a);
    perform public.platform_get_my_prospect_v89(v_prospect_b);
    reset role;
    raise exception 'sales staff read another sales representative prospect';
  exception when insufficient_privilege then
    reset role;
  end;

  begin
    perform pg_temp.as_v89_user(v_sales_a);
    perform public.platform_list_prospects_v86('{}',null,100,null,null);
    reset role;
    raise exception 'sales staff bypassed scope through the legacy broad reader';
  exception when insufficient_privilege then
    reset role;
  end;

  select version into v_version from public.sme_prospects where id=v_prospect_a;
  begin
    perform pg_temp.as_v89_user(v_admin);
    perform public.platform_move_my_prospect_stage_v89(
      v_prospect_a,'appt_set',v_version,'read-only admin must fail'
    );
    reset role;
    raise exception 'read-only admin moved a prospect';
  exception when insufficient_privilege then
    reset role;
  end;

  perform pg_temp.as_v89_user(v_sa);
  perform public.platform_upsert_access_grant_v89(
    v_admin,'admin','{"overview":"r","onboarding":"rw","reports":"r"}',true
  );
  reset role;
  perform pg_temp.as_v89_user(v_admin);
  v_result:=public.platform_move_my_prospect_stage_v89(
    v_prospect_a,'appt_set',v_version,'admin write permission accepted'
  );
  reset role;
  if v_result->>'stage_key'<>'appt_set' then
    raise exception 'write-enabled admin did not move the prospect';
  end if;

  perform pg_temp.as_v89_user(v_sa);
  perform public.platform_upsert_access_grant_v89(
    v_sales_a,'sales_staff',
    '{"onboarding":"rw","firms":"r","reports":"r"}',false
  );
  reset role;
  begin
    perform pg_temp.as_v89_user(v_sales_a);
    perform public.platform_get_my_prospect_v89(v_prospect_a);
    reset role;
    raise exception 'disabled platform grant remained active';
  exception when insufficient_privilege then
    reset role;
  end;
end
$v89$;

rollback;
