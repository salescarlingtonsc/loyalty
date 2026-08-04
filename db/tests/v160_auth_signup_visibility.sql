-- Rollback-only acceptance for V160 Auth-only business signup visibility.
-- Run after the complete canonical chain on a disposable or production-safe database.
begin;

create or replace function pg_temp.as_v160_user(
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
grant execute on function pg_temp.as_v160_user(uuid,text) to public;

do $v160_test$
declare
  v_super uuid:=gen_random_uuid();
  v_normal uuid:=gen_random_uuid();
  v_auth_only uuid:=gen_random_uuid();
  v_unconfirmed uuid:=gen_random_uuid();
  v_phone_only uuid:=gen_random_uuid();
  v_google_business uuid:=gen_random_uuid();
  v_customer_user uuid:=gen_random_uuid();
  v_staff_invite_user uuid:=gen_random_uuid();
  v_no_intent_user uuid:=gen_random_uuid();
  v_staff_user uuid:=gen_random_uuid();
  v_application_user uuid:=gen_random_uuid();
  v_selfserve_user uuid:=gen_random_uuid();
  v_staff_business uuid:=gen_random_uuid();
  v_selfserve_business uuid:=gen_random_uuid();
  v_selfserve_branch uuid:=gen_random_uuid();
  v_selfserve_staff uuid:=gen_random_uuid();
  v_bundle uuid:=gen_random_uuid();
  v_catalog uuid:=gen_random_uuid();
  v_payload jsonb;
  v_overflow jsonb;
  v_denied boolean;
begin
  if has_function_privilege(
    'anon',
    'public.platform_list_account_signups_v160(text,integer)',
    'execute'
  ) then
    raise exception 'V160 account-signup list is exposed to anonymous callers';
  end if;
  if not has_function_privilege(
    'authenticated',
    'public.platform_list_account_signups_v160(text,integer)',
    'execute'
  ) then
    raise exception 'V160 account-signup list is unavailable to authenticated callers';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,phone,encrypted_password,
    email_confirmed_at,phone_confirmed_at,created_at,updated_at,raw_user_meta_data
  ) values
    ('00000000-0000-0000-0000-000000000000',v_super,
     'authenticated','authenticated','v160-super@example.test',null,'',
     now(),null,now(),now(),'{}'::jsonb),
    ('00000000-0000-0000-0000-000000000000',v_normal,
     'authenticated','authenticated','v160-normal@example.test',null,'',
     now(),null,now(),now(),'{}'::jsonb),
    ('00000000-0000-0000-0000-000000000000',v_auth_only,
     'authenticated','authenticated','v160-auth-only@example.test','+6581600001','',
     now(),null,now(),now(),'{"account_type":"business_owner"}'::jsonb),
    ('00000000-0000-0000-0000-000000000000',v_unconfirmed,
     'authenticated','authenticated','v160-unconfirmed@example.test',null,'',
     null,null,now(),now(),'{"account_type":"business_owner"}'::jsonb),
    ('00000000-0000-0000-0000-000000000000',v_phone_only,
     'authenticated','authenticated',null,'+6581600999','',
     null,now(),now(),now(),'{"account_type":"business_owner"}'::jsonb),
    ('00000000-0000-0000-0000-000000000000',v_google_business,
     'authenticated','authenticated','v160-google-business@example.test',null,'',
     now(),null,now(),now(),'{}'::jsonb),
    ('00000000-0000-0000-0000-000000000000',v_customer_user,
     'authenticated','authenticated','v160-customer@example.test',null,'',
     now(),null,now(),now(),'{"account_type":"customer"}'::jsonb),
    ('00000000-0000-0000-0000-000000000000',v_staff_invite_user,
     'authenticated','authenticated','v160-staff-invite@example.test',null,'',
     now(),null,now(),now(),'{"account_type":"business_staff_invite"}'::jsonb),
    ('00000000-0000-0000-0000-000000000000',v_no_intent_user,
     'authenticated','authenticated','v160-no-intent@example.test',null,'',
     now(),null,now(),now(),'{}'::jsonb),
    ('00000000-0000-0000-0000-000000000000',v_staff_user,
     'authenticated','authenticated','v160-staff@example.test',null,'',
     now(),null,now(),now(),'{"account_type":"business_owner"}'::jsonb),
    ('00000000-0000-0000-0000-000000000000',v_application_user,
     'authenticated','authenticated','v160-application@example.test',null,'',
     now(),null,now(),now(),'{"account_type":"business_owner"}'::jsonb),
    ('00000000-0000-0000-0000-000000000000',v_selfserve_user,
     'authenticated','authenticated','v160-selfserve@example.test',null,'',
     now(),null,now(),now(),'{"account_type":"business_owner"}'::jsonb);

  insert into public.super_admins(user_id,email,note)
  values(v_super,'v160-super@example.test','V160 rollback test');

  insert into app.business_account_legal_acceptances_v138(
    auth_user_id,source,terms_version,terms_sha256,privacy_version,
    privacy_sha256,accepted_at,idempotency_key,request_sha256
  ) values(
    v_google_business,'google_oauth_signup','2026-08-01',
    encode(digest('v160-terms','sha256'),'hex'),'2026-08-01',
    encode(digest('v160-privacy','sha256'),'hex'),now(),gen_random_uuid(),
    encode(digest('v160-google-request','sha256'),'hex')
  );

  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values(v_staff_business,'V160 Staff Business','v160-staff-business','facial',array['dashboard']);
  insert into public.staff(business_id,user_id,role,full_name,email,active)
  values(v_staff_business,v_staff_user,'owner','V160 Staff','v160-staff@example.test',true);

  insert into public.business_applications_v95(
    public_reference,idempotency_key,request_hash,contact_name,contact_email,
    contact_phone,business_name,sector_key,status,preferred_locale
  ) values(
    gen_random_uuid(),gen_random_uuid(),encode(digest('v160-application','sha256'),'hex'),
    'Application User','v160-application@example.test','+6581234567',
    'V160 Application Studio','facial','submitted','en'
  );

  insert into public.sector_profiles(sector_key,label,active)
  values('v160_facial','V160 Facial',true);
  insert into public.sector_bundle_versions(
    id,sector_key,version,label,status,modules,published_at
  ) values(
    v_bundle,'v160_facial',1,'V160 Facial Bundle','published',
    array['dashboard','customers','sales','loyalty'],now()
  );
  insert into public.billing_plan_catalog_v124(
    id,currency,cadence,cadence_months,provider_base_price_id,
    provider_capacity_price_id,base_amount_cents,included_customer_capacity,
    capacity_block_size,capacity_block_amount_cents,active,effective_from,effective_to
  ) values(
    v_catalog,'SGD','annual',12,'price_v160baseAuthVisibility',
    'price_v160capAuthVisibility',118800,1000,1000,12000,false,
    now(),now()+interval '1 day'
  );
  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values(v_selfserve_business,'V160 Self Serve Business','v160-selfserve-business','facial',array['dashboard']);
  insert into public.branches(id,business_id,name,is_default)
  values(v_selfserve_branch,v_selfserve_business,'Main',true);
  insert into public.staff(id,business_id,user_id,role,full_name,email,active)
  values(v_selfserve_staff,v_selfserve_business,v_selfserve_user,'owner','V160 Self Serve','v160-selfserve@example.test',true);
  insert into public.self_serve_business_onboarding_v130(
    business_id,owner_user_id,owner_staff_id,default_branch_id,bundle_version_id,
    setup_idempotency_key,request_hash,owner_name,owner_email,business_name,
    business_slug,sector_key,preferred_locale,selected_cadence,
    selected_customer_capacity,billing_catalog_id_v124,legal_accepted_at,status
  ) values(
    v_selfserve_business,v_selfserve_user,v_selfserve_staff,v_selfserve_branch,v_bundle,
    gen_random_uuid(),encode(digest('v160-selfserve','sha256'),'hex'),'V160 Owner',
    'v160-selfserve@example.test','V160 Self Serve Business','v160-selfserve-business',
    'v160_facial','en','annual',1000,v_catalog,now(),'payment_pending'
  );

  perform pg_temp.as_v160_user(v_normal);
  v_denied:=false;
  begin
    perform public.platform_list_account_signups_v160(null,100);
  exception when insufficient_privilege then v_denied:=true;end;
  reset role;
  if not v_denied then
    raise exception 'V160 allowed a non-super-admin to list Auth-only signups';
  end if;

  perform pg_temp.as_v160_user(v_super);
  v_payload:=public.platform_list_account_signups_v160('v160-',100);
  reset role;

  if not exists (
    select 1 from jsonb_array_elements(v_payload->'items') item
     where item->>'email'='v160-auth-only@example.test'
       and item->>'phone'='+6581600001'
       and item->>'status'='needs_business_details'
  ) then
    raise exception 'V160 did not include confirmed Auth-only business signup: %',v_payload;
  end if;
  if not exists (
    select 1 from jsonb_array_elements(v_payload->'items') item
     where item->>'email'='v160-unconfirmed@example.test'
       and item->>'status'='email_unconfirmed'
  ) then
    raise exception 'V160 did not include unconfirmed Auth-only business signup: %',v_payload;
  end if;
  if not exists (
    select 1 from jsonb_array_elements(v_payload->'items') item
     where item->>'email'='v160-google-business@example.test'
  ) then
    raise exception 'V160 did not include Google OAuth business acceptance signup: %',v_payload;
  end if;

  perform pg_temp.as_v160_user(v_super);
  v_payload:=public.platform_list_account_signups_v160('+6581600999',100);
  reset role;
  if not exists (
    select 1 from jsonb_array_elements(v_payload->'items') item
     where item->>'email' is null
       and item->>'phone'='+6581600999'
  ) then
    raise exception 'V160 did not include searchable phone-only business signup: %',v_payload;
  end if;

  perform pg_temp.as_v160_user(v_super);
  v_payload:=public.platform_list_account_signups_v160('v160-',100);
  reset role;
  if exists (
    select 1 from jsonb_array_elements(v_payload->'items') item
     where item->>'email' in (
       'v160-customer@example.test','v160-staff-invite@example.test',
       'v160-no-intent@example.test','v160-staff@example.test',
       'v160-application@example.test','v160-selfserve@example.test'
     )
  ) then
    raise exception 'V160 included a non-business, linked staff, application, or self-serve signup: %',v_payload;
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,phone,encrypted_password,
    email_confirmed_at,created_at,updated_at,raw_user_meta_data
  )
  select
    '00000000-0000-0000-0000-000000000000',gen_random_uuid(),
    'authenticated','authenticated',
    'v160-overflow-'||lpad(series::text,3,'0')||'@example.test',
    null,'',now(),now()-(series||' minutes')::interval,now(),
    '{"account_type":"business_owner"}'::jsonb
    from generate_series(1,101) series;

  perform pg_temp.as_v160_user(v_super);
  v_overflow:=public.platform_list_account_signups_v160('v160-overflow-',100);
  reset role;
  if (v_overflow->>'count')::integer<>100 or (v_overflow->>'truncated')::boolean is distinct from true then
    raise exception 'V160 did not enforce 100-row cap with truncation flag: %',v_overflow;
  end if;
end
$v160_test$;

rollback;
