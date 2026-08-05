-- Rollback-only acceptance for Peekaa V167 phase 3.
begin;

create or replace function pg_temp.as_v167_phase3_user(p_uid uuid)
returns void language plpgsql as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role','authenticated')::text,true);
end
$$;
grant execute on function pg_temp.as_v167_phase3_user(uuid) to public;

do $v167_phase3$
declare
  v_customer uuid:=gen_random_uuid();
  v_other_customer uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_other_business uuid:=gen_random_uuid();
  v_client uuid:=gen_random_uuid();
  v_same_business_other_client uuid:=gen_random_uuid();
  v_other_client uuid:=gen_random_uuid();
  v_identity uuid:=gen_random_uuid();
  v_other_identity uuid:=gen_random_uuid();
  v_service uuid:=gen_random_uuid();
  v_retired_service uuid:=gen_random_uuid();
  v_other_service uuid:=gen_random_uuid();
  v_branch uuid:=gen_random_uuid();
  v_staff uuid:=gen_random_uuid();
  v_appointment uuid:=gen_random_uuid();
  v_same_business_other_appointment uuid:=gen_random_uuid();
  v_retired_appointment uuid:=gen_random_uuid();
  v_other_appointment uuid:=gen_random_uuid();
  v_plan uuid:=gen_random_uuid();
  v_package uuid:=gen_random_uuid();
  v_package_sale uuid:=gen_random_uuid();
  v_zero_sale uuid:=gen_random_uuid();
  v_other_sale uuid:=gen_random_uuid();
  v_payload jsonb:='{"fixture":"v167-phase3"}'::jsonb;
  v_result jsonb;
begin
  reset role;
  update app.platform_feature_flags set enabled=true,changed_at=now()
   where feature_key in('customer_identity','customer_wallet');
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values
    ('00000000-0000-0000-0000-000000000000',v_customer,'authenticated','authenticated','v167-phase3@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_other_customer,'authenticated','authenticated','v167-phase3-other@example.test','',now(),now(),now());
  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values
    (v_business,'V167 Phase3 Glow','v167-p3-'||substr(v_business::text,1,8),'facial',array['bookings','appointments','packages','sales','loyalty']),
    (v_other_business,'V167 Phase3 Other','v167-p3-other-'||substr(v_other_business::text,1,8),'facial',array['bookings','appointments','packages','sales','loyalty']);
  insert into public.clients(id,business_id,full_name,email)
  values
    (v_client,v_business,'Mei Tan','mei@example.test'),
    (v_same_business_other_client,v_business,'Aisha Lim','aisha@example.test'),
    (v_other_client,v_other_business,'Other Customer','other@example.test');
  insert into public.customer_identities(id,auth_user_id,status,created_via)
  values(v_identity,v_customer,'active','phone_registration'),(v_other_identity,v_other_customer,'active','phone_registration');
  perform set_config('app.customer_link_insert_id',gen_random_uuid()::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values(current_setting('app.customer_link_insert_id')::uuid,v_business,v_identity,v_customer,v_client,'verified','firm_invitation',now());
  perform set_config('app.customer_link_insert_id',gen_random_uuid()::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values(current_setting('app.customer_link_insert_id')::uuid,v_other_business,v_other_identity,v_other_customer,v_other_client,'verified','firm_invitation',now());
  perform set_config('app.customer_link_insert_id','',true);

  insert into public.services(id,business_id,name,price_cents,duration_min,active,show_on_booking_page)
  values
    (v_service,v_business,'Signature Facial',8800,60,true,true),
    (v_retired_service,v_business,'Retired Facial',8800,60,false,true),
    (v_other_service,v_other_business,'Other Service',5000,30,true,true);
  insert into public.branches(id,business_id,name,active,is_default)
  values(v_branch,v_business,'Orchard',true,true);
  insert into public.staff(id,business_id,role,full_name,active)
  values(v_staff,v_business,'staff','Jamie Tan',true);
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business,v_staff,v_branch);
  insert into public.staff_services(business_id,staff_id,service_id)
  values(v_business,v_staff,v_service);
  insert into public.appointments(id,business_id,client_id,service_id,branch_id,staff_id,starts_at,ends_at,status)
  values
    (v_appointment,v_business,v_client,v_service,v_branch,v_staff,now()-interval '8 days',now()-interval '8 days'+interval '1 hour','completed'),
    (v_same_business_other_appointment,v_business,v_same_business_other_client,v_service,v_branch,v_staff,now()-interval '7 days',now()-interval '7 days'+interval '1 hour','completed'),
    (v_retired_appointment,v_business,v_client,v_retired_service,null,null,now()-interval '6 days',now()-interval '6 days'+interval '1 hour','completed'),
    (v_other_appointment,v_other_business,v_other_client,v_other_service,null,null,now()-interval '4 days',now()-interval '4 days'+interval '30 minutes','completed');

  insert into public.package_plans(id,business_id,name,price_cents,sessions,service_id,active)
  values(v_plan,v_business,'Glow Five',40000,5,v_service,true);
  insert into public.client_packages(
    id,business_id,client_id,plan_id,remaining,status,purchased_at,
    plan_name_snapshot,plan_version_snapshot,sessions_snapshot,price_cents_snapshot,
    service_id_snapshot,service_name_snapshot
  ) values(
    v_package,v_business,v_client,v_plan,4,'active',now()-interval '30 days',
    'Glow Five',1,5,40000,v_service,'Signature Facial'
  );
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,note,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    commission_rate_bps,commission_resolved_at
  )
  values
    (v_package_sale,v_business,v_client,'service',0,now()-interval '2 days','package session used: Glow Five',false,false,false,now(),0,now()),
    (v_zero_sale,v_business,v_client,'service',0,now()-interval '1 day','complimentary correction',false,false,false,now(),0,now()),
    (v_other_sale,v_other_business,v_other_client,'service',0,now(),'other tenant sale',false,false,false,now(),0,now());
  insert into public.package_session_consumptions(
    id,business_id,client_package_id,client_id,sale_id,actor,idempotency_key,
    request_payload,request_hash,remaining_before,remaining_after,result
  ) values(
    gen_random_uuid(),v_business,v_package,v_client,v_package_sale,v_customer,
    'v167-phase3-package-session',v_payload,md5(v_payload::text),5,4,
    jsonb_build_object('sale_id',v_package_sale)
  );

  perform pg_temp.as_v167_phase3_user(v_customer);
  v_result:=public.customer_get_repeat_booking_preference_v167(
    'v167-p3-'||substr(v_business::text,1,8),v_appointment
  );
  if v_result->>'service_id'<>v_service::text then
    raise exception 'valid repeat service was not returned: %',v_result;
  end if;
  if v_result->>'staff_id'<>v_staff::text or v_result->>'staff_name'<>'Jamie Tan' then
    raise exception 'valid repeat staff preference was not returned: %',v_result;
  end if;
  v_result:=public.customer_get_repeat_booking_preference_v167(
    'v167-p3-'||substr(v_business::text,1,8),v_same_business_other_appointment
  );
  if v_result->>'service_id' is not null or v_result->>'staff_id' is not null then
    raise exception 'same-business other-customer appointment leaked: %',v_result;
  end if;
  v_result:=public.customer_get_repeat_booking_preference_v167(
    'v167-p3-'||substr(v_business::text,1,8),v_retired_appointment
  );
  if v_result->>'service_id' is not null then
    raise exception 'retired repeat service leaked: %',v_result;
  end if;
  v_result:=public.customer_get_repeat_booking_preference_v167(
    'v167-p3-'||substr(v_business::text,1,8),v_other_appointment
  );
  if v_result->>'service_id' is not null then
    raise exception 'other tenant appointment leaked: %',v_result;
  end if;

  v_result:=public.customer_get_transaction_history_v167(
    'v167-p3-'||substr(v_business::text,1,8),jsonb_build_object('limit',20)
  );
  if not exists(
    select 1 from jsonb_array_elements(v_result->'items') item
     where item->>'source_id'=v_package_sale::text
       and (item->>'is_package_session')::boolean
       and item->>'package_name'='Glow Five'
       and item->>'package_reference'=left(v_package::text,8)
  ) or not exists(
    select 1 from jsonb_array_elements(v_result->'items') item
     where item->>'source_id'=v_zero_sale::text
       and not (item->>'is_package_session')::boolean
  ) or (v_result->'items')::text like '%'||v_other_sale::text||'%' then
    raise exception 'package provenance or tenant history is wrong: %',v_result;
  end if;

  perform pg_temp.as_v167_phase3_user(v_other_customer);
  begin
    perform public.customer_get_repeat_booking_preference_v167(
      'v167-p3-'||substr(v_business::text,1,8),v_appointment
    );
    raise exception 'cross-tenant repeat preference was readable';
  exception when sqlstate '42501' then null;
  end;
end
$v167_phase3$;

rollback;
