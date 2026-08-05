-- Rollback-only acceptance for Peekaa v167 customer Home offers.
begin;
select set_config('app.v79_system_transition','on',true);

create or replace function pg_temp.as_v167_user(p_uid uuid,p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v167_user(uuid,text) to public;

do $v167$
declare
  v_super uuid:=gen_random_uuid();
  v_owner uuid:=gen_random_uuid();
  v_other_owner uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_other_business uuid:=gen_random_uuid();
  v_branch uuid:=gen_random_uuid();
  v_inactive_branch uuid:=gen_random_uuid();
  v_client uuid;
  v_identity uuid;
  v_offer uuid:=gen_random_uuid();
  v_draft_offer uuid:=gen_random_uuid();
  v_expired_offer uuid:=gen_random_uuid();
  v_inactive_branch_offer uuid:=gen_random_uuid();
  v_future_offer uuid:=gen_random_uuid();
  v_generated_offer uuid;
  v_index integer;
  v_other_offer uuid:=gen_random_uuid();
  v_pending_intent uuid:=gen_random_uuid();
  v_program uuid;
  v_path text;
  v_other_path text;
  v_draft jsonb;
  v_result jsonb;
  v_content_version bigint;
  v_copy_version bigint;
begin
  reset role;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values
    ('00000000-0000-0000-0000-000000000000',v_super,'authenticated','authenticated','v167-super@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated','v167-owner@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_other_owner,'authenticated','authenticated','v167-other-owner@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_customer,'authenticated','authenticated','v167-customer@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,'authenticated','authenticated','v167-outsider@example.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note) values(v_super,'v167-super@example.test','v167 rollback fixture');
  insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules)
  values
    (v_business,'V167 Glow Atelier','v167-glow-'||substr(v_business::text,1,8),'facial',true,array['dashboard','clients','sales','loyalty','retention']),
    (v_other_business,'V167 Other Atelier','v167-other-'||substr(v_other_business::text,1,8),'facial',true,array['dashboard','clients','sales','loyalty','retention']);
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_owner,'owner','V167 Owner',true),(v_other_business,v_other_owner,'owner','V167 Other Owner',true);
  insert into public.branches(id,business_id,name,is_default,active)
  values(v_branch,v_business,'Orchard',true,true),(v_inactive_branch,v_business,'Retired',false,false),
    (gen_random_uuid(),v_other_business,'Other',true,true);
  update public.business_workspace_controls_v94 set
    approval_status='approved',decided_by=v_super,decided_at=now(),
    decision_reason='v167 rollback fixture approval'
  where business_id in(v_business,v_other_business);
  insert into public.business_workspace_controls_v94(
    business_id,approval_status,version,decided_by,decided_at,decision_reason
  ) select fixture.business_id,'approved',1,v_super,now(),'v167 rollback fixture approval'
    from unnest(array[v_business,v_other_business]) fixture(business_id)
    where not exists(select 1 from public.business_workspace_controls_v94 control where control.business_id=fixture.business_id);
  insert into public.business_subscription_lifecycle_v94(business_id)
  select fixture.business_id from unnest(array[v_business,v_other_business]) fixture(business_id)
  where not exists(select 1 from public.business_subscription_lifecycle_v94 lifecycle where lifecycle.business_id=fixture.business_id);
  perform set_config('app.v79_system_transition','',true);

  update app.platform_feature_flags set enabled=true,changed_at=now()
  where feature_key in('customer_identity','customer_claims','customer_wallet');
  insert into public.clients(business_id,full_name,email)
  values(v_business,'V167 Customer','v167-customer@example.test') returning id into v_client;
  insert into public.customer_identities(auth_user_id,status,created_via)
  values(v_customer,'active','phone_registration') returning id into v_identity;
  perform set_config('app.customer_link_insert_id',gen_random_uuid()::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values(current_setting('app.customer_link_insert_id')::uuid,v_business,v_identity,v_customer,v_client,'verified','firm_invitation',now());
  perform set_config('app.customer_link_insert_id','',true);
  insert into public.loyalty_programs(business_id,kind,active,loyalty_model,configuration_status)
  values(v_business,'points',true,'classic','published') returning id into v_program;

  -- Publish one canonical offer in each tenant through the existing guarded RPC.
  perform pg_temp.as_v167_user(v_owner);
  v_draft:=public.business_create_promotion_draft_v104(
    v_business,v_offer,gen_random_uuid(),null,'Return facial offer',null,
    'A current offer for the linked business.','One redemption.',now()-interval '1 hour',now()+interval '2 days',10,
    'programme','View offer','Current linked offer',null
  );
  v_path:=v_business||'/offer/'||gen_random_uuid()||'.png';
  reset role;
  insert into storage.objects(bucket_id,name,metadata) values('business-public',v_path,'{"mimetype":"image/png","size":"4096"}'::jsonb);
  select version into v_content_version from public.business_customer_content_v95 where id=v_offer;
  select version into v_copy_version from public.business_localized_copy_v95
  where business_id=v_business and entity_type='offer' and entity_id=v_offer and locale='en';
  perform pg_temp.as_v167_user(v_owner);
  perform public.business_finalize_promotion_v104(
    v_business,v_offer,null,'Return facial offer',null,'A current offer for the linked business.','One redemption.',
    now()-interval '1 hour',now()+interval '2 days',10,'programme','View offer','Current linked offer',null,true,
    v_path,'image/png',1200,800,'Facial treatment room',v_content_version,v_copy_version,0,gen_random_uuid()
  );
  reset role;
  insert into public.promotion_branch_scopes_v155(promotion_id,business_id,branch_id,created_by)
  values(v_offer,v_business,v_branch,v_owner);

  -- Add thirteen later-ending visible offers to prove the deterministic twelve-item cap.
  for v_index in 1..13 loop
    v_generated_offer:=gen_random_uuid();
    v_path:=v_business||'/offer/'||gen_random_uuid()||'.png';
    insert into storage.objects(bucket_id,name,metadata) values('business-public',v_path,'{"mimetype":"image/png","size":"4096"}'::jsonb);
    perform set_config('app.v104_promotion_write','on',true);
    insert into public.business_customer_content_v95(
      id,business_id,content_type,branch_id,active,display_order,starts_at,ends_at,metadata,version,updated_by
    ) values(v_generated_offer,v_business,'offer',null,true,100+v_index,now()-interval '1 hour',now()+interval '3 days','{}',2,v_owner);
    perform set_config('app.v104_promotion_write','',true);
    perform set_config('app.v104_promotion_copy_write','on',true);
    insert into public.business_localized_copy_v95(
      business_id,entity_type,entity_id,locale,name,description,terms,version,updated_by
    ) values(v_business,'offer',v_generated_offer,'en','Later offer '||v_index,'Cap fixture.','One redemption.',2,v_owner);
    perform set_config('app.v104_promotion_copy_write','',true);
    perform set_config('app.v104_promotion_media_write','on',true);
    insert into public.business_media_assets_v95(
      business_id,asset_kind,entity_id,bucket_id,object_path,mime_type,width_px,height_px,alt_en,customer_visible,version,updated_by
    ) values(v_business,'offer',v_generated_offer,'business-public',v_path,'image/png',1200,800,'Offer '||v_index,true,1,v_owner);
    perform set_config('app.v104_promotion_media_write','',true);
  end loop;

  -- Draft and expired offers in the linked tenant must not reach Home.
  perform pg_temp.as_v167_user(v_owner);
  v_draft:=public.business_create_promotion_draft_v104(
    v_business,v_draft_offer,gen_random_uuid(),null,'Draft hidden offer',null,
    'Must remain private.','Draft only.',now(),now()+interval '1 day',20,
    'programme','View offer','Draft',null
  );
  v_draft:=public.business_create_promotion_draft_v104(
    v_business,v_expired_offer,gen_random_uuid(),null,'Expired hidden offer',null,
    'Must disappear after expiry.','Expired.',now()-interval '2 days',now()+interval '1 day',30,
    'programme','View offer','Expired',null
  );
  v_path:=v_business||'/offer/'||gen_random_uuid()||'.png';
  reset role;
  insert into storage.objects(bucket_id,name,metadata) values('business-public',v_path,'{"mimetype":"image/png","size":"4096"}'::jsonb);
  select version into v_content_version from public.business_customer_content_v95 where id=v_expired_offer;
  select version into v_copy_version from public.business_localized_copy_v95
  where business_id=v_business and entity_type='offer' and entity_id=v_expired_offer and locale='en';
  perform pg_temp.as_v167_user(v_owner);
  perform public.business_finalize_promotion_v104(
    v_business,v_expired_offer,null,'Expired hidden offer',null,'Must disappear after expiry.','Expired.',
    now()-interval '2 days',now()+interval '1 day',30,'programme','View offer','Expired',null,true,
    v_path,'image/png',1200,800,'Expired offer',v_content_version,v_copy_version,0,gen_random_uuid()
  );
  reset role;
  perform set_config('app.v104_promotion_write','on',true);
  update public.business_customer_content_v95
  set starts_at=statement_timestamp()-interval '2 days',ends_at=statement_timestamp()-interval '1 day'
  where id=v_expired_offer;
  perform set_config('app.v104_promotion_write','',true);

  -- A current offer mapped only to an inactive branch is not customer-visible.
  perform set_config('app.v104_promotion_write','on',true);
  insert into public.business_customer_content_v95(
    id,business_id,content_type,active,display_order,starts_at,ends_at,metadata,version,updated_by
  ) values(v_inactive_branch_offer,v_business,'offer',true,40,now()-interval '1 hour',now()+interval '1 day','{}',2,v_owner);
  perform set_config('app.v104_promotion_write','',true);
  perform set_config('app.v104_promotion_copy_write','on',true);
  insert into public.business_localized_copy_v95(business_id,entity_type,entity_id,locale,name,version,updated_by)
  values(v_business,'offer',v_inactive_branch_offer,'en','Inactive branch offer',2,v_owner);
  perform set_config('app.v104_promotion_copy_write','',true);
  v_path:=v_business||'/offer/'||gen_random_uuid()||'.png';
  insert into storage.objects(bucket_id,name,metadata) values('business-public',v_path,'{"mimetype":"image/png","size":"4096"}'::jsonb);
  perform set_config('app.v104_promotion_media_write','on',true);
  insert into public.business_media_assets_v95(business_id,asset_kind,entity_id,object_path,mime_type,width_px,height_px,alt_en,customer_visible,version,updated_by)
  values(v_business,'offer',v_inactive_branch_offer,v_path,'image/png',1200,800,'Inactive branch offer',true,1,v_owner);
  perform set_config('app.v104_promotion_media_write','',true);
  insert into public.promotion_branch_scopes_v155(promotion_id,business_id,branch_id,created_by)
  values(v_inactive_branch_offer,v_business,v_inactive_branch,v_owner);

  perform set_config('app.v104_promotion_write','on',true);
  insert into public.business_customer_content_v95(
    id,business_id,content_type,active,display_order,starts_at,ends_at,metadata,version,updated_by
  ) values(v_future_offer,v_business,'offer',true,50,now()+interval '1 day',now()+interval '2 days','{}',2,v_owner);
  perform set_config('app.v104_promotion_write','',true);
  perform set_config('app.v104_promotion_copy_write','on',true);
  insert into public.business_localized_copy_v95(business_id,entity_type,entity_id,locale,name,version,updated_by)
  values(v_business,'offer',v_future_offer,'en','Future offer',2,v_owner);
  perform set_config('app.v104_promotion_copy_write','',true);
  v_path:=v_business||'/offer/'||gen_random_uuid()||'.png';
  insert into storage.objects(bucket_id,name,metadata) values('business-public',v_path,'{"mimetype":"image/png","size":"4096"}'::jsonb);
  perform set_config('app.v104_promotion_media_write','on',true);
  insert into public.business_media_assets_v95(business_id,asset_kind,entity_id,object_path,mime_type,width_px,height_px,alt_en,customer_visible,version,updated_by)
  values(v_business,'offer',v_future_offer,v_path,'image/png',1200,800,'Future offer',true,1,v_owner);
  perform set_config('app.v104_promotion_media_write','',true);

  insert into public.customer_redemption_intents_v89(
    id,business_id,identity_id,auth_user_id,client_id,redemption_kind,reward_id,
    quoted_program_id,quoted_config_version_id,quoted_reward_version_id,
    quoted_points_spent,quoted_credit_cents,quoted_terms,token_hash,
    idempotency_key,request_hash,expires_at
  ) values(
    v_pending_intent,v_business,v_identity,v_customer,v_client,'classic_points',null,
    v_program,null,null,10,0,'{}'::jsonb,
    md5(v_pending_intent::text)||md5(v_business::text),gen_random_uuid(),
    md5(v_business::text)||md5(v_pending_intent::text),now()+interval '10 minutes'
  );

  perform pg_temp.as_v167_user(v_other_owner);
  v_draft:=public.business_create_promotion_draft_v104(
    v_other_business,v_other_offer,gen_random_uuid(),null,'Private other offer',null,
    'Must not cross tenant boundaries.','One redemption.',now()-interval '1 hour',now()+interval '2 days',10,
    'programme','View offer','Other tenant offer',null
  );
  v_other_path:=v_other_business||'/offer/'||gen_random_uuid()||'.png';
  reset role;
  insert into storage.objects(bucket_id,name,metadata) values('business-public',v_other_path,'{"mimetype":"image/png","size":"4096"}'::jsonb);
  select version into v_content_version from public.business_customer_content_v95 where id=v_other_offer;
  select version into v_copy_version from public.business_localized_copy_v95
  where business_id=v_other_business and entity_type='offer' and entity_id=v_other_offer and locale='en';
  perform pg_temp.as_v167_user(v_other_owner);
  perform public.business_finalize_promotion_v104(
    v_other_business,v_other_offer,null,'Private other offer',null,'Must not cross tenant boundaries.','One redemption.',
    now()-interval '1 hour',now()+interval '2 days',10,'programme','View offer','Other tenant offer',null,true,
    v_other_path,'image/png',1200,800,'Other treatment room',v_content_version,v_copy_version,0,gen_random_uuid()
  );

  perform pg_temp.as_v167_user(v_customer);
  begin
    v_result:=public.customer_get_home_offers_v167('en');
  exception when others then
    reset role;
    raise exception 'customer offer reader failed (%): actor %, identities %',
      sqlerrm,current_setting('request.jwt.claim.sub',true),
      (select jsonb_agg(jsonb_build_object('user',auth_user_id,'status',status)) from public.customer_identities);
  end;
  if jsonb_array_length(v_result->'items')<>12
     or v_result#>>'{items,0,id}'<>v_offer::text
     or v_result#>>'{items,0,business,id}'<>v_business::text
     or v_result#>>'{items,0,version_id}'<>v_offer::text||':2'
     or v_result#>>'{items,0,availability_label}'<>'Available at Orchard'
     or (v_result->>'truncated')::boolean is not true
     or (v_result->'items')::text like '%'||v_inactive_branch_offer::text||'%'
     or (v_result->'items')::text like '%'||v_expired_offer::text||'%'
     or (v_result->'items')::text like '%'||v_draft_offer::text||'%'
     or (v_result->'items')::text like '%'||v_future_offer::text||'%'
     or v_result#>>'{pending_redemption,intent_id}'<>v_pending_intent::text then
    raise exception 'verified-link offer projection leaked or omitted data: %',v_result;
  end if;
  begin
    perform public.business_get_visible_promotion_count_v167(v_business);
    raise exception 'customer read owner-only supply status';
  exception when sqlstate '42501' then null;
  end;

  perform pg_temp.as_v167_user(v_outsider);
  begin
    perform public.customer_get_home_offers_v167('en');
    raise exception 'unlinked account read customer offers';
  exception when sqlstate '42501' then null;
  end;

  perform pg_temp.as_v167_user(v_owner);
  v_result:=public.business_get_visible_promotion_count_v167(v_business);
  if (v_result->>'visible_count')::integer<>14 then
    raise exception 'canonical visible count is wrong: %',v_result;
  end if;
  begin
    perform public.business_get_visible_promotion_count_v167(v_other_business);
    raise exception 'owner read another tenant supply status';
  exception when sqlstate '42501' then null;
  end;
end
$v167$;

rollback;
