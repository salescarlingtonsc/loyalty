-- Rollback-only acceptance for Nestly v95 approval-first onboarding,
-- bilingual programme presentation, and customer-visible media.
begin;

create or replace function pg_temp.as_v95_user(
  p_uid uuid,p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true
  );
end
$$;
grant execute on function pg_temp.as_v95_user(uuid,text) to public;

do $v95_test$
declare
  v_super uuid:=gen_random_uuid();
  v_owner uuid:=gen_random_uuid();
  v_wrong uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_application uuid;
  v_rejected_application uuid;
  v_public_reference uuid;
  v_token text;
  v_business uuid;
  v_branch uuid;
  v_second_branch uuid;
  v_client uuid;
  v_identity uuid;
  v_link uuid:=gen_random_uuid();
  v_programme uuid;
  v_service uuid;
  v_product uuid;
  v_reward uuid;
  v_tier uuid;
  v_benefit uuid;
  v_other_branch_benefit uuid;
  v_logo uuid;
  v_service_media uuid;
  v_cleanup uuid;
  v_logo_path text;
  v_replacement_logo_path text;
  v_service_path text;
  v_sector text;
  v_result jsonb;
  v_count integer;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) select
    '00000000-0000-0000-0000-000000000000',user_id,
    'authenticated','authenticated',email,'',now(),now(),now()
  from (values
    (v_super,'v95-super@example.test'),
    (v_owner,'approved-owner@example.test'),
    (v_wrong,'wrong-owner@example.test'),
    (v_customer,'v95-customer@example.test'),
    (v_outsider,'v95-outsider@example.test')
  ) fixture(user_id,email);
  insert into public.super_admins(user_id,email,note)
  values(v_super,'v95-super@example.test','rollback-only v95 fixture');
  select sector_key into v_sector from public.sector_bundle_versions
  where status='published' order by sector_key limit 1;
  if v_sector is null then raise exception 'published sector fixture missing';end if;

  select count(*) into v_count from public.businesses;
  perform pg_temp.as_v95_user(null,'anon');
  begin
    perform public.internal_submit_business_application_v95(
      'Approved Owner','approved-owner@example.test','+6581234567',
      'V95 Approved Firm',v_sector,null,'zh-CN',gen_random_uuid()
    );
    raise exception 'anon bypassed the Edge application gateway';
  exception when insufficient_privilege then null;
  end;
  reset role;
  perform pg_temp.as_v95_user(v_wrong);
  begin
    perform public.internal_submit_business_application_v95(
      'Approved Owner','approved-owner@example.test','+6581234567',
      'V95 Approved Firm',v_sector,null,'zh-CN',gen_random_uuid()
    );
    raise exception 'authenticated browser bypassed the Edge application gateway';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.create_business(
      'Bypass Firm','v95-bypass-firm',v_sector,'{}'::text[]
    );
    raise exception 'legacy self-service workspace creation remained open';
  exception when sqlstate '42501' then null;
  end;
  reset role;

  perform pg_temp.as_v95_user(null,'service_role');
  v_result:=public.internal_submit_business_application_v95(
    'Approved Owner','approved-owner@example.test','+6581234567',
    'V95 Approved Firm',v_sector,'202600001A','zh-CN',
    '11111111-1111-4111-8111-111111111111'
  );
  v_application:=(v_result->>'application_id')::uuid;
  v_public_reference:=(v_result->>'public_reference')::uuid;
  if v_result->>'status'<>'submitted' or (v_result->>'replayed')::boolean then
    raise exception 'service application submission failed: %',v_result;
  end if;
  v_result:=public.internal_submit_business_application_v95(
    'Approved Owner','approved-owner@example.test','+6581234567',
    'V95 Approved Firm',v_sector,'202600001A','zh-CN',
    '11111111-1111-4111-8111-111111111111'
  );
  if not (v_result->>'replayed')::boolean then
    raise exception 'application submission replay was not idempotent';
  end if;
  reset role;
  if (select count(*) from public.businesses)<>v_count
     or exists(select 1 from public.staff where user_id=v_owner) then
    raise exception 'pre-auth application created workspace or owner';
  end if;
  perform pg_temp.as_v95_user(null,'anon');
  v_result:=public.get_business_application_status_v95(v_public_reference);
  if v_result->>'status'<>'submitted' or v_result?'contact_email'
     or v_result?'decision_reason' then
    raise exception 'public status leaked PII or omitted status: %',v_result;
  end if;
  reset role;

  perform pg_temp.as_v95_user(v_wrong);
  begin
    perform public.platform_list_business_applications_v95(
      'submitted','V95 Approved',100
    );
    raise exception 'non-superadmin listed business applications';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.platform_decide_business_application_v95(
      v_application,'approved','must fail',1
    );
    raise exception 'non-superadmin approved application';
  exception when sqlstate '42501' then null;
  end;
  reset role;
  perform pg_temp.as_v95_user(v_super);
  v_result:=public.platform_list_business_applications_v95(
    'submitted','V95 Approved',100
  );
  if jsonb_array_length(v_result->'applications')<>1
     or v_result#>>'{applications,0,contact_email}'
       <>'approved-owner@example.test'
     or v_result::text like '%request_hash%' then
    raise exception 'superadmin application queue is wrong: %',v_result;
  end if;
  v_result:=public.platform_decide_business_application_v95(
    v_application,'approved','approved rollback-only application',1
  );
  v_token:=v_result->>'invitation_token';
  if length(v_token)<>64 or v_result->>'approved_email'
       <>'approved-owner@example.test'
     or (v_result->>'version')::integer<>2 then
    raise exception 'approval did not issue one raw invitation: %',v_result;
  end if;
  v_result:=public.platform_get_business_application_v95(v_application);
  if v_result::text like '%'||v_token||'%'
     or v_result#>>'{application,status}'<>'approved'
     or v_result#>>'{invitation,expires_at}' is null then
    raise exception 'inspection leaked token or lost approval: %',v_result;
  end if;
  reset role;

  perform pg_temp.as_v95_user(v_wrong);
  begin
    perform public.internal_get_approved_business_invitation_v95(v_token);
    raise exception 'browser directly validated approved invitation';
  exception when insufficient_privilege then null;
  end;
  reset role;
  perform pg_temp.as_v95_user(null,'service_role');
  v_result:=public.internal_get_approved_business_invitation_v95(v_token);
  if not (v_result->>'valid')::boolean
     or v_result->>'approved_email'<>'approved-owner@example.test'
     or v_result->>'business_name'<>'V95 Approved Firm' then
    raise exception 'Edge invitation validation contract is wrong: %',v_result;
  end if;
  reset role;

  perform pg_temp.as_v95_user(v_wrong);
  v_result:=public.activate_approved_business_application_v95(
    v_token,'v95-approved-firm',gen_random_uuid()
  );
  if v_result->>'status'<>'refused'
     or (v_result->>'workspace_created')::boolean then
    raise exception 'email-mismatched account consumed invitation: %',v_result;
  end if;
  reset role;
  if not exists(
    select 1 from public.business_application_audit_v95
    where application_id=v_application and event_type='activation_refused'
  ) then raise exception 'email mismatch refusal was not audited';end if;

  perform pg_temp.as_v95_user(v_owner);
  v_result:=public.activate_approved_business_application_v95(
    v_token,'v95-approved-firm',
    '22222222-2222-4222-8222-222222222222'
  );
  v_business:=(v_result->>'business_id')::uuid;
  v_branch:=(v_result->>'default_branch_id')::uuid;
  if v_result->>'status'<>'consumed'
     or not (v_result->>'workspace_access')::boolean then
    raise exception 'approved owner activation failed: %',v_result;
  end if;
  v_result:=public.activate_approved_business_application_v95(
    v_token,'v95-approved-firm',
    '22222222-2222-4222-8222-222222222222'
  );
  if not (v_result->>'replayed')::boolean then
    raise exception 'activation exact replay was not idempotent';
  end if;
  begin
    perform public.activate_approved_business_application_v95(
      v_token,'v95-approved-firm',gen_random_uuid()
    );
    raise exception 'single-use invitation accepted another activation';
  exception when sqlstate '42501' then null;
  end;
  reset role;
  if not exists(
    select 1 from public.staff where business_id=v_business
      and user_id=v_owner and role='owner' and active
  ) or not exists(
    select 1 from public.business_workspace_controls_v94
    where business_id=v_business and approval_status='approved'
  ) or not exists(
    select 1 from public.business_application_audit_v95
    where application_id=v_application and event_type='invitation_consumed'
  ) then raise exception 'owner/workspace/audit activation facts diverged';end if;

  -- Rejection returns no invitation.
  perform pg_temp.as_v95_user(null,'service_role');
  v_result:=public.internal_submit_business_application_v95(
    'Rejected Owner','rejected-owner@example.test','+6581234568',
    'V95 Rejected Firm',v_sector,null,'en',gen_random_uuid()
  );
  v_rejected_application:=(v_result->>'application_id')::uuid;
  reset role;
  perform pg_temp.as_v95_user(v_super);
  v_result:=public.platform_decide_business_application_v95(
    v_rejected_application,'rejected','application not accepted',1
  );
  if v_result->'invitation_token'<>'null'::jsonb then
    raise exception 'rejected application received invitation';
  end if;
  reset role;
  if exists(select 1 from public.business_application_invitations_v95
       where application_id=v_rejected_application) then
    raise exception 'rejected application persisted invitation';
  end if;

  -- Owner-authored bilingual programme presentation.
  insert into public.branches(business_id,name,active)
  values(v_business,'Other Branch',true) returning id into v_second_branch;
  perform pg_temp.as_v95_user(v_owner);
  reset role;
  update public.loyalty_programs
  set active=true,configuration_status='published'
  where business_id=v_business returning id into v_programme;
  insert into public.services(
    business_id,name,price_cents,duration_min,active,show_on_booking_page
  ) values(v_business,'English Facial',5000,60,true,true)
  returning id into v_service;
  insert into public.products(
    business_id,name,sku,retail_price_cents,active
  ) values(v_business,'English Serum','V95-SERUM',2500,true)
  returning id into v_product;
  insert into public.loyalty_rewards(
    business_id,name,cost_points,credit_cents,active,sort,
    internal_name,customer_name,fulfillment_kind,estimated_cost_cents
  ) values(
    v_business,'English Reward',100,500,true,1,
    'English Reward','English Reward','credit',500
  )
  returning id into v_reward;
  insert into public.loyalty_tiers(
    business_id,name,threshold,points_multiplier,sort
  ) values(v_business,'English Starter',0,1,1)
  returning id into v_tier;
  perform pg_temp.as_v95_user(v_owner);
  perform public.business_set_customer_capabilities_v89(
    v_business,true,true,true
  );
  perform public.business_upsert_localized_copy_v95(
    v_business,'programme',v_programme,'en','Nestly Rewards',
    'English tagline','English programme description',null,0
  );
  perform public.business_upsert_localized_copy_v95(
    v_business,'programme',v_programme,'zh-CN','Nestly 奖励',
    '中文标语',null,null,0
  );
  perform public.business_upsert_localized_copy_v95(
    v_business,'service',v_service,'en','English Facial',
    null,'English service description',null,0
  );
  perform public.business_upsert_localized_copy_v95(
    v_business,'reward',v_reward,'zh-CN','中文奖励',
    null,'中文奖励说明','中文条款',0
  );
  perform public.business_upsert_localized_copy_v95(
    v_business,'tier',v_tier,'zh-CN','入门会员',null,null,null,0
  );
  v_result:=public.business_upsert_customer_content_v95(
    v_business,'benefit',null,v_branch,true,1,null,null,
    '{"icon":"gift"}'::jsonb,0
  );
  v_benefit:=(v_result->>'id')::uuid;
  perform public.business_upsert_localized_copy_v95(
    v_business,'benefit',v_benefit,'en','Birthday perk',
    null,'English benefit fallback',null,0
  );
  v_result:=public.business_upsert_customer_content_v95(
    v_business,'benefit',null,v_second_branch,true,1,null,null,
    '{}'::jsonb,0
  );
  v_other_branch_benefit:=(v_result->>'id')::uuid;
  perform public.business_upsert_localized_copy_v95(
    v_business,'benefit',v_other_branch_benefit,'en','Other branch only',
    null,null,null,0
  );
  v_logo_path:=v_business||
    '/logo/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.png';
  v_replacement_logo_path:=v_business||
    '/logo/cccccccc-cccc-4ccc-8ccc-cccccccccccc.png';
  v_service_path:=v_business||
    '/service/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.webp';
  reset role;
  insert into storage.objects(bucket_id,name,metadata)
  values
    ('business-public',v_logo_path,
      '{"mimetype":"image/png","size":"2048"}'::jsonb),
    ('business-public',v_replacement_logo_path,
      '{"mimetype":"image/png","size":"3072"}'::jsonb),
    ('business-public',v_service_path,
      '{"mimetype":"image/webp","size":"4096"}'::jsonb);
  perform pg_temp.as_v95_user(v_owner);

  begin
    perform public.business_upsert_media_asset_v95(
      v_business,'logo',null,null,v_logo_path,
      'image/png',512,512,'V95 logo','V95 标志',true,0
    );
    raise exception 'legacy two-step RPC published customer-visible media';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.business_publish_media_replacement_v95(
      v_business,'hero',null,null,v_logo_path,
      'image/png',512,512,'Wrong kind',null,'#123ABC',0,1
    );
    raise exception 'path-kind mismatch was published';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.business_publish_media_replacement_v95(
      v_business,'logo',null,null,
      v_business||'/logo/dddddddd-dddd-4ddd-8ddd-dddddddddddd.png',
      'image/png',512,512,'Missing object',null,'#123ABC',0,1
    );
    raise exception 'missing storage object was published';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.business_publish_media_replacement_v95(
      v_business,'logo',null,null,v_logo_path,
      'image/webp',512,512,'Wrong MIME',null,'#123ABC',0,1
    );
    raise exception 'storage MIME mismatch was published';
  exception when sqlstate '22023' then null;
  end;

  v_result:=public.business_publish_media_replacement_v95(
    v_business,'logo',null,null,v_logo_path,
    'image/png',512,512,'V95 logo','V95 标志','#123ABC',0,1
  );
  v_logo:=(v_result->>'id')::uuid;
  if v_result->>'brand_version'<>'2'
     or v_result->>'previous_object_path' is not null then
    raise exception 'initial atomic brand publication is wrong: %',v_result;
  end if;
  begin
    perform public.business_publish_media_replacement_v95(
      v_business,'logo',null,null,v_replacement_logo_path,
      'image/png',640,640,'Replacement logo',null,'#654321',1,1
    );
    raise exception 'stale brand version unexpectedly published replacement';
  exception when sqlstate '40001' then null;
  end;
  reset role;
  if not exists(
    select 1 from public.business_media_assets_v95
    where id=v_logo and object_path=v_logo_path and customer_visible
  ) or not exists(
    select 1 from public.business_brand_presentation_v95
    where business_id=v_business and logo_asset_id=v_logo
      and hero_color='#123ABC' and version=2
  ) then
    raise exception 'brand conflict left partial customer-visible media';
  end if;
  perform pg_temp.as_v95_user(v_owner);
  v_result:=public.business_publish_media_replacement_v95(
    v_business,'logo',null,null,v_replacement_logo_path,
    'image/png',640,640,'Replacement logo',null,'#654321',1,2
  );
  if v_result->>'previous_object_path'<>v_logo_path
     or v_result->>'brand_version'<>'3'
     or v_result->>'id'<>v_logo::text then
    raise exception 'atomic replacement contract is wrong: %',v_result;
  end if;
  v_result:=public.business_publish_media_replacement_v95(
    v_business,'service',v_service,v_branch,v_service_path,
    'image/webp',1200,800,'Facial service',null,null,0,null
  );
  v_service_media:=(v_result->>'id')::uuid;
  v_result:=public.business_queue_media_cleanup_v95(
    v_business,v_logo_path,'replaced brand asset'
  );
  v_cleanup:=(v_result->>'id')::uuid;
  if v_result->>'status'<>'pending' then
    raise exception 'storage cleanup was not durably queued: %',v_result;
  end if;
  v_result:=public.business_mark_media_cleanup_result_v95(
    v_business,v_cleanup,false,'simulated Storage API failure'
  );
  if v_result->>'status'<>'pending'
     or (v_result->>'attempts')::integer<>1
     or v_result->>'last_error'<>'simulated Storage API failure' then
    raise exception 'failed cleanup was not truthfully retained: %',v_result;
  end if;
  begin
    perform public.business_mark_media_cleanup_result_v95(
      v_business,v_cleanup,true,null
    );
    raise exception 'cleanup completed while Storage object still existed';
  exception when sqlstate '22023' then null;
  end;
  reset role;
  delete from storage.objects
  where bucket_id='business-public' and name=v_logo_path;
  perform pg_temp.as_v95_user(v_owner);
  v_result:=public.business_mark_media_cleanup_result_v95(
    v_business,v_cleanup,true,null
  );
  if v_result->>'status'<>'completed'
     or (v_result->>'attempts')::integer<>2 then
    raise exception 'successful retry did not complete cleanup: %',v_result;
  end if;
  v_result:=public.business_list_media_cleanup_queue_v95(v_business,20);
  if jsonb_array_length(v_result->'pending')<>0 then
    raise exception 'completed cleanup remained pending: %',v_result;
  end if;
  v_result:=public.business_get_presentation_editor_v95(v_business);
  if (v_result#>>'{brand,version}')::integer<>3
     or v_result#>>'{brand,logo_asset,id}'<>v_logo::text
     or v_result#>>'{brand,logo_asset,object_path}'
       <>v_replacement_logo_path
     or v_result#>>'{brand,logo_asset,url}'
       not like '/storage/v1/object/public/business-public/%'
     or jsonb_array_length(v_result->'programmes')<>1
     or v_result#>>'{programmes,0,copies,0,locale}'<>'en'
     or jsonb_array_length(v_result->'rewards')<>1
     or jsonb_array_length(v_result->'products')<>1
     or jsonb_array_length(v_result->'services')<>1
     or v_result#>>'{services,0,media,0,id}'<>v_service_media::text
     or v_result#>>'{services,0,media,0,url}'
       not like '/storage/v1/object/public/business-public/%' then
    raise exception 'owner presentation editor contract is wrong: %',v_result;
  end if;
  reset role;
  if has_table_privilege(
       'authenticated','public.business_localized_copy_v95','select'
     )
     or has_table_privilege(
       'authenticated','public.business_media_assets_v95','select'
     )
     or has_table_privilege(
       'authenticated','public.business_brand_presentation_v95','select'
     )
     or has_table_privilege(
       'authenticated','public.business_media_cleanup_queue_v95','select'
     ) then
    raise exception 'presentation editor tables leaked direct browser SELECT';
  end if;
  perform pg_temp.as_v95_user(v_wrong);
  begin
    perform public.business_get_presentation_editor_v95(v_business);
    raise exception 'non-owner read the presentation editor contract';
  exception when sqlstate '42501' then null;
  end;
  reset role;
  perform pg_temp.as_v95_user(v_super);
  v_result:=public.business_get_presentation_editor_v95(v_business);
  if v_result->>'business_id'<>v_business::text
     or v_result#>>'{brand,logo_asset,id}'<>v_logo::text then
    raise exception 'superadmin could not read presentation editor contract';
  end if;
  reset role;

  insert into public.clients(business_id,full_name,email,phone)
  values(v_business,'V95 Customer','v95-customer@example.test','+6581234599')
  returning id into v_client;
  insert into public.customer_identities(auth_user_id)
  values(v_customer) returning id into v_identity;
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values(
    v_link,v_business,v_identity,v_customer,v_client,'verified',
    'firm_invitation',now()
  );
  perform set_config('app.customer_link_insert_id','',true);

  perform pg_temp.as_v95_user(v_customer);
  v_result:=public.customer_get_locale_preference_v95();
  if v_result->>'locale'<>'en' or (v_result->>'version')::integer<>0 then
    raise exception 'locale default is not English/version zero: %',v_result;
  end if;
  v_result:=public.customer_set_locale_preference_v95('zh-CN',0);
  if v_result->>'locale'<>'zh-CN' or (v_result->>'version')::integer<>1 then
    raise exception 'locale preference did not persist: %',v_result;
  end if;
  v_result:=public.customer_get_business_presentation_v95(
    v_business,v_branch,null
  );
  if v_result->>'locale'<>'zh-CN'
     or v_result#>>'{programme,name}'<>'Nestly 奖励'
     or v_result#>>'{programme,description}'<>'English programme description'
     or v_result#>>'{catalogue,services,0,name}'<>'English Facial'
     or v_result#>>'{catalogue,rewards,0,name}'<>'中文奖励'
     or v_result#>>'{programme,tier,label}'<>'入门会员'
     or jsonb_array_length(v_result#>'{programme,benefits}')<>1
     or v_result#>>'{brand,hero_color}'<>'#654321'
     or v_result#>>'{brand,logo_url}'
       not like '/storage/v1/object/public/business-public/%'
     or v_result#>>'{catalogue,services,0,image_url}'
       not like '/storage/v1/object/public/business-public/%'
     or not (v_result#>>'{capabilities,booking_enabled}')::boolean then
    raise exception 'localized branch-aware presentation is wrong: %',v_result;
  end if;
  begin
    perform public.business_upsert_localized_copy_v95(
      v_business,'service',v_service,'zh-CN','Forbidden',null,null,null,0
    );
    raise exception 'customer wrote owner-localized copy';
  exception when sqlstate '42501' then null;
  end;
  reset role;
  perform pg_temp.as_v95_user(v_outsider);
  begin
    perform public.customer_get_business_presentation_v95(
      v_business,v_branch,'en'
    );
    raise exception 'unlinked customer read business presentation';
  exception when sqlstate '42501' then null;
  end;
  reset role;
end
$v95_test$;

rollback;
