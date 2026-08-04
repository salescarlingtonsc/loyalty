-- Rollback-only acceptance for V159 self-serve manual application fallback.
-- Run after the complete canonical chain on a disposable database.
begin;

create or replace function pg_temp.as_v159_user(
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
grant execute on function pg_temp.as_v159_user(uuid,text) to public;

do $v159_test$
declare
  v_owner uuid:=gen_random_uuid();
  v_unconfirmed uuid:=gen_random_uuid();
  v_staff_user uuid:=gen_random_uuid();
  v_staff_business uuid:=gen_random_uuid();
  v_key uuid:=gen_random_uuid();
  v_result jsonb;
  v_replay jsonb;
  v_business_count integer;
  v_subscription_count integer;
  v_denied boolean;
begin
  if has_function_privilege(
    'anon',
    'public.request_self_serve_manual_application_v159(text,text,text,text,text,text,uuid)',
    'execute'
  ) then
    raise exception 'V159 manual fallback is exposed to anonymous callers';
  end if;
  if not has_function_privilege(
    'authenticated',
    'public.request_self_serve_manual_application_v159(text,text,text,text,text,text,uuid)',
    'execute'
  ) then
    raise exception 'V159 manual fallback is unavailable to authenticated owners';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner,
     'authenticated','authenticated','v159-owner@example.test','',
     now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_unconfirmed,
     'authenticated','authenticated','v159-unconfirmed@example.test','',
     null,now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_staff_user,
     'authenticated','authenticated','v159-staff@example.test','',
     now(),now(),now());

  insert into public.sector_profiles(sector_key,label,active)
  values('v159_facial','V159 Facial and Spa',true)
  on conflict(sector_key) do update set active=true;
  insert into public.sector_bundle_versions(
    sector_key,version,label,status,modules,published_at
  ) values(
    'v159_facial',1,'V159 Facial and Spa manual fallback',
    'published',array['dashboard','clients','appointments','loyalty'],now()
  );

  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values(
    v_staff_business,'V159 Existing Staff Business',
    'v159-existing-staff-'||substr(v_staff_business::text,1,8),
    'v159_facial',array['dashboard']
  );
  insert into public.staff(business_id,user_id,role,full_name,email,active)
  values(
    v_staff_business,v_staff_user,'owner','Existing Staff',
    'v159-staff@example.test',true
  );

  v_business_count:=(select count(*) from public.businesses);
  v_subscription_count:=(select count(*) from public.subscriptions);

  reset role;
  perform set_config('request.jwt.claim.sub','',true);
  v_denied:=false;
  begin
    perform public.request_self_serve_manual_application_v159(
      'No User','+6581234000','No User Studio','v159_facial',null,'en',gen_random_uuid()
    );
  exception when sqlstate '28000' then v_denied:=true;end;
  if not v_denied then
    raise exception 'V159 allowed unauthenticated manual fallback';
  end if;

  perform pg_temp.as_v159_user(v_unconfirmed);
  v_denied:=false;
  begin
    perform public.request_self_serve_manual_application_v159(
      'Unconfirmed Owner','+6581234001','Unconfirmed Studio',
      'v159_facial',null,'en',gen_random_uuid()
    );
  exception when insufficient_privilege then v_denied:=true;end;
  reset role;
  if not v_denied then
    raise exception 'V159 allowed unconfirmed email manual fallback';
  end if;

  perform pg_temp.as_v159_user(v_staff_user);
  v_denied:=false;
  begin
    perform public.request_self_serve_manual_application_v159(
      'Existing Staff','+6581234002','Existing Staff Studio',
      'v159_facial',null,'en',gen_random_uuid()
    );
  exception when insufficient_privilege then v_denied:=true;end;
  reset role;
  if not v_denied then
    raise exception 'V159 allowed an account already assigned to staff';
  end if;

  perform pg_temp.as_v159_user(v_owner);
  v_result:=public.request_self_serve_manual_application_v159(
    'Sofia Ng','+6581234003','Radiant Skin Studio',
    'v159_facial','202699999N','en',v_key
  );
  if coalesce((v_result->>'submitted_for_manual_help')::boolean,false) is not true
     or v_result->>'contact_email'<>'v159-owner@example.test'
     or v_result->>'status'<>'submitted'
     or coalesce((v_result->>'replayed')::boolean,true) then
    raise exception 'V159 first manual fallback result is incorrect: %',v_result;
  end if;

  v_replay:=public.request_self_serve_manual_application_v159(
    'Sofia Ng','+6581234003','Radiant Skin Studio',
    'v159_facial','202699999N','en',v_key
  );
  reset role;
  if coalesce((v_replay->>'replayed')::boolean,false) is not true
     or v_replay->>'application_id'<>v_result->>'application_id' then
    raise exception 'V159 replay did not return the same application: %',v_replay;
  end if;

  if (
    select count(*) from public.business_applications_v95
     where contact_email='v159-owner@example.test'
       and business_name='Radiant Skin Studio'
       and status='submitted'
  )<>1 then
    raise exception 'V159 did not create exactly one assisted application';
  end if;
  if (
    select count(*) from public.audit_log
     where action='SELF_SERVICE_MANUAL_APPLICATION_REQUESTED_V159'
       and entity='business_applications_v95'
       and entity_id=(v_result->>'application_id')::uuid
  )<>1 then
    raise exception 'V159 replay created duplicate manual-fallback audit rows';
  end if;
  if (select count(*) from public.businesses)<>v_business_count
     or (select count(*) from public.subscriptions)<>v_subscription_count then
    raise exception 'V159 fallback created business or subscription state before approval/payment';
  end if;

  perform pg_temp.as_v159_user(v_owner);
  v_denied:=false;
  begin
    perform public.request_self_serve_manual_application_v159(
      'Sofia Ng','+6581234003','Changed Studio',
      'v159_facial','202699999N','en',v_key
    );
  exception when invalid_parameter_value then v_denied:=true;end;
  reset role;
  if not v_denied then
    raise exception 'V159 allowed a changed payload under the same idempotency key';
  end if;
end
$v159_test$;

rollback;
