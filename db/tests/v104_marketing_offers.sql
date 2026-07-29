-- Rollback-only acceptance for Nestly v104 owner-authored customer promotions.
-- Exercises owner authoring, super-admin entitlement/read authority, optimistic versions, image-gated
-- publication, launch quota/window, company-wide scope, deterministic two-card
-- customer projection, verified-link scope, and finite browser ACLs.

begin;
select set_config('app.v79_system_transition','on',true);

create or replace function pg_temp.as_v104_user(
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
grant execute on function pg_temp.as_v104_user(uuid,text) to public;

do $v104_test$
declare
  v_super uuid:=gen_random_uuid();
  v_owner uuid:=gen_random_uuid();
  v_other_owner uuid:=gen_random_uuid();
  v_manager uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_other_business uuid:=gen_random_uuid();
  v_branch uuid;
  v_second_branch uuid;
  v_client uuid;
  v_identity uuid;
  v_link uuid:=gen_random_uuid();
  v_first uuid;
  v_second uuid;
  v_third uuid;
  v_fourth uuid;
  v_late uuid;
  v_super_fresh uuid;
  v_first_path text;
  v_second_path text;
  v_third_path text;
  v_fourth_path text;
  v_stale_path text;
  v_global_retry_path text;
  v_late_path text;
  v_super_path text;
  v_legacy uuid:=gen_random_uuid();
  v_legacy_path text;
  v_attempt uuid;
  v_super_attempt uuid;
  v_super_finalize_attempt uuid;
  v_result jsonb;
  v_replay jsonb;
  v_content_version bigint;
  v_copy_version bigint;
  v_media_version bigint;
  v_before_copy text;
  v_before_path text;
begin
  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values
    (
      '00000000-0000-0000-0000-000000000000',
      v_super,'authenticated','authenticated',
      'v104-super-'||substr(v_super::text,1,8)||'@example.test',
      '',now(),now(),now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',
      v_owner,'authenticated','authenticated',
      'v104-owner-'||substr(v_owner::text,1,8)||'@example.test',
      '',now(),now(),now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',
      v_other_owner,'authenticated','authenticated',
      'v104-other-owner-'||substr(v_other_owner::text,1,8)||'@example.test',
      '',now(),now(),now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',
      v_manager,'authenticated','authenticated',
      'v104-manager-'||substr(v_manager::text,1,8)||'@example.test',
      '',now(),now(),now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',
      v_customer,'authenticated','authenticated',
      'v104-customer-'||substr(v_customer::text,1,8)||'@example.test',
      '',now(),now(),now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',
      v_outsider,'authenticated','authenticated',
      'v104-outsider-'||substr(v_outsider::text,1,8)||'@example.test',
      '',now(),now(),now()
    );
  insert into public.super_admins(user_id,email,note)
  values(
    v_super,
    'v104-super-'||substr(v_super::text,1,8)||'@example.test',
    'rollback-only v104 fixture'
  );
  insert into public.businesses(
    id,name,slug,industry,join_enabled,enabled_modules
  ) values
    (
      v_business,'V104 Glow Atelier',
      'v104-glow-'||substr(v_business::text,1,8),'facial',true,
      array['dashboard','clients','sales','loyalty','retention']
    ),
    (
      v_other_business,'V104 Other Firm',
      'v104-other-'||substr(v_other_business::text,1,8),'facial',true,
      array['dashboard','clients','sales','loyalty','retention']
    );
  insert into public.staff(
    business_id,user_id,role,full_name,active
  ) values
    (v_business,v_owner,'owner','V104 Owner',true),
    (v_business,v_manager,'manager','V104 Manager',true),
    (v_other_business,v_other_owner,'owner','V104 Other Owner',true);
  insert into public.branches(
    business_id,name,is_default,active
  ) values(v_business,'Orchard',true,true)
  returning id into v_branch;
  insert into public.branches(
    business_id,name,is_default,active
  ) values(v_business,'Tampines',false,true)
  returning id into v_second_branch;
  insert into public.branches(
    business_id,name,is_default,active
  ) values(v_other_business,'Other',true,true);
  perform set_config('app.v79_system_transition','',true);

  update app.platform_feature_flags
  set enabled=true,changed_at=now()
  where feature_key in(
    'customer_identity','customer_claims','customer_wallet'
  );
  perform pg_temp.as_v104_user(v_super);
  perform public.platform_decide_business_approval_v94(
    v_business,'approved','v104 rollback-only acceptance firm',1
  );
  perform public.platform_decide_business_approval_v94(
    v_other_business,'approved','v104 legacy-adoption acceptance firm',1
  );
  reset role;

  insert into public.clients(business_id,full_name,email)
  values(
    v_business,'V104 Customer',
    'v104-customer-'||substr(v_customer::text,1,8)||'@example.test'
  )
  returning id into v_client;
  insert into public.customer_identities(
    auth_user_id,status,created_via
  ) values(v_customer,'active','phone_registration')
  returning id into v_identity;
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values(
    v_link,v_business,v_identity,v_customer,v_client,'verified',
    'firm_invitation',now()
  );
  perform set_config('app.customer_link_insert_id','',true);

  -- Manager and another tenant's owner cannot author or inspect promotions.
  perform pg_temp.as_v104_user(v_manager);
  begin
    perform public.business_save_promotion_v104(
      v_business,null,null,'Forbidden offer',null,
      'A manager must not publish this promotion.',null,
      now(),now()+interval '1 day',1,'counter','View offer',
      '10% off','Test',false,0,0
    );
    raise exception 'manager authored owner-only promotion';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.business_get_promotion_editor_v104(v_business);
    raise exception 'manager read owner-only promotion editor';
  exception when sqlstate '42501' then null;
  end;
  reset role;
  perform pg_temp.as_v104_user(v_other_owner);
  begin
    perform public.business_get_promotion_editor_v104(v_business);
    raise exception 'foreign owner read another tenant promotion editor';
  exception when sqlstate '42501' then null;
  end;
  reset role;

  -- Super admins manage platform entitlements and may replay receipts, but
  -- fresh customer-facing promotion authorship remains owner-only.
  v_super_fresh:=gen_random_uuid();
  v_super_attempt:=gen_random_uuid();
  perform pg_temp.as_v104_user(v_super);
  begin
    perform public.business_create_promotion_draft_v104(
      v_business,v_super_fresh,v_super_attempt,null,
      'Forbidden super-admin draft',null,
      'A platform administrator must not author merchant promotion copy.',null,
      now(),now()+interval '1 day',1,'counter','View offer',
      'Super-admin fresh draft',null
    );
    raise exception 'super admin created a fresh promotion draft';
  exception when sqlstate '42501' then null;
  end;
  reset role;
  if exists(
       select 1 from public.business_customer_content_v95
       where id=v_super_fresh
     )
     or exists(
       select 1 from public.business_promotion_attempt_receipts_v104
       where business_id=v_business and attempt_key=v_super_attempt
     )
  then
    raise exception 'denied super-admin draft mutated content or receipt';
  end if;

  -- Owner saves a draft. Publication fails closed until its photo is published.
  perform pg_temp.as_v104_user(v_owner);
  v_first:=gen_random_uuid();
  v_attempt:=gen_random_uuid();
  v_result:=public.business_create_promotion_draft_v104(
    v_business,v_first,v_attempt,null,'NDP spa celebration',
    '30% off until 30 August 2026',
    'Celebrate National Day with 30% off the 60-minute Spa Ritual.',
    'Valid for one redemption per customer.',
    now()-interval '1 minute',now()+interval '30 days',30,
    'book','Book now','30% off the 60-minute Spa Ritual until 30 August 2026',
    'National Day'
  );
  if v_result->>'publish_state'<>'draft'
     or (v_result#>>'{item,content_version}')::bigint<>1
     or v_result#>>'{metadata,cta,kind}'<>'book' then
    raise exception 'owner promotion draft contract is wrong: %',v_result;
  end if;
  -- A lost successful draft response is replayed, not duplicated.
  v_replay:=public.business_create_promotion_draft_v104(
    v_business,v_first,v_attempt,null,'NDP spa celebration',
    '30% off until 30 August 2026',
    'Celebrate National Day with 30% off the 60-minute Spa Ritual.',
    'Valid for one redemption per customer.',
    now()-interval '1 minute',now()+interval '30 days',30,
    'book','Book now','30% off the 60-minute Spa Ritual until 30 August 2026',
    'National Day'
  );
  if not (v_replay->>'replayed')::boolean
     or v_replay->>'promotion_id'<>v_first::text then
    raise exception 'lost draft-create response did not replay exactly: %',
      v_replay;
  end if;

  -- A super admin may recover the owner's exact recorded response, but cannot
  -- change the payload or turn replay authority into fresh authorship.
  reset role;
  perform pg_temp.as_v104_user(v_super);
  v_replay:=public.business_create_promotion_draft_v104(
    v_business,v_first,v_attempt,null,'NDP spa celebration',
    '30% off until 30 August 2026',
    'Celebrate National Day with 30% off the 60-minute Spa Ritual.',
    'Valid for one redemption per customer.',
    now()-interval '1 minute',now()+interval '30 days',30,
    'book','Book now','30% off the 60-minute Spa Ritual until 30 August 2026',
    'National Day'
  );
  if not (v_replay->>'replayed')::boolean
     or v_replay->>'promotion_id'<>v_first::text then
    raise exception 'super admin could not replay exact recorded receipt: %',
      v_replay;
  end if;
  begin
    perform public.business_create_promotion_draft_v104(
      v_business,v_first,v_attempt,null,'Changed replay payload',
      '30% off until 30 August 2026',
      'Celebrate National Day with 30% off the 60-minute Spa Ritual.',
      'Valid for one redemption per customer.',
      now()-interval '1 minute',now()+interval '30 days',30,
      'book','Book now','30% off the 60-minute Spa Ritual until 30 August 2026',
      'National Day'
    );
    raise exception 'super admin changed payload on an existing attempt key';
  exception when sqlstate '23505' then null;
  end;
  reset role;

  -- Fresh super-admin finalization is denied before content/copy/media or
  -- receipt mutation, even when a valid storage object exists.
  v_super_finalize_attempt:=gen_random_uuid();
  v_super_path:=v_business||'/offer/'||gen_random_uuid()||'.png';
  insert into storage.objects(bucket_id,name,metadata)
  values(
    'business-public',v_super_path,
    '{"mimetype":"image/png","size":"4096"}'::jsonb
  );
  select version into v_content_version
  from public.business_customer_content_v95 where id=v_first;
  select version,name into v_copy_version,v_before_copy
  from public.business_localized_copy_v95
  where business_id=v_business and entity_type='offer'
    and entity_id=v_first and locale='en';
  perform pg_temp.as_v104_user(v_super);
  begin
    perform public.business_finalize_promotion_v104(
      v_business,v_first,null,'Forbidden super-admin finalization',null,
      'A platform administrator must not finalize merchant promotion copy.',null,
      now()-interval '1 minute',now()+interval '30 days',30,
      'book','Book now','Forbidden super-admin finalization',null,
      true,v_super_path,'image/png',1200,800,'Forbidden platform image',
      v_content_version,v_copy_version,0,v_super_finalize_attempt
    );
    raise exception 'super admin performed a fresh promotion finalization';
  exception when sqlstate '42501' then null;
  end;
  reset role;
  if (select version from public.business_customer_content_v95
      where id=v_first)<>v_content_version
     or (select version from public.business_localized_copy_v95
         where business_id=v_business and entity_type='offer'
           and entity_id=v_first and locale='en')<>v_copy_version
     or (select name from public.business_localized_copy_v95
         where business_id=v_business and entity_type='offer'
           and entity_id=v_first and locale='en')<>v_before_copy
     or exists(
       select 1 from public.business_media_assets_v95
       where business_id=v_business and object_path=v_super_path
     )
     or exists(
       select 1 from public.business_promotion_attempt_receipts_v104
       where business_id=v_business
         and attempt_key=v_super_finalize_attempt
     )
  then
    raise exception 'denied super-admin finalization mutated promotion state';
  end if;

  perform pg_temp.as_v104_user(v_owner);
  begin
    perform public.business_upsert_customer_content_v95(
      v_business,'offer',null,null,true,0,now(),now()+interval '1 day',
      '{"legacy":"bypass"}'::jsonb,0
    );
    raise exception 'legacy v95 owner offer writer bypassed v104 authority';
  exception when sqlstate '42501' then null;
  end;
  reset role;
  perform pg_temp.as_v104_user(v_super);
  begin
    perform public.business_upsert_customer_content_v95(
      v_business,'offer',null,null,true,0,now(),now()+interval '1 day',
      '{"super_admin_legacy":"bypass"}'::jsonb,0
    );
    raise exception 'super admin generic offer writer bypassed v104 authority';
  exception when sqlstate '42501' then null;
  end;
  reset role;
  perform pg_temp.as_v104_user(v_owner);
  begin
    perform public.business_finalize_promotion_v104(
      v_business,v_first,null,'NDP spa celebration',
      '30% off until 30 August 2026',
      'Celebrate National Day with 30% off the 60-minute Spa Ritual.',
      'Valid for one redemption per customer.',
      now()-interval '1 minute',now()+interval '30 days',30,
      'book','Book now','30% off the 60-minute Spa Ritual until 30 August 2026',
      'National Day',true,null,null,null,null,null,1,1,0,gen_random_uuid()
    );
    raise exception 'promotion published without a customer-visible image';
  exception when sqlstate '23514' then null;
  end;
  reset role;

  v_first_path:=v_business||'/offer/'||gen_random_uuid()||'.png';
  insert into storage.objects(bucket_id,name,metadata)
  values(
    'business-public',v_first_path,
    '{"mimetype":"image/png","size":"4096"}'::jsonb
  );
  perform pg_temp.as_v104_user(v_owner);
  begin
    perform public.business_publish_media_replacement_v95(
      v_business,'offer',v_first,null,v_first_path,'image/png',
      1200,800,'National Day spa promotion',null,null,0,null
    );
    raise exception 'legacy v95 owner offer media writer bypassed v104 authority';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.business_upsert_localized_copy_v95(
      v_business,'offer',v_first,'en','Bypassed copy',null,
      'Legacy copy writer must not change promotion marketing facts.',null,1
    );
    raise exception 'legacy v95 owner offer copy writer bypassed v104 authority';
  exception when sqlstate '42501' then null;
  end;
  v_attempt:=gen_random_uuid();
  v_result:=public.business_finalize_promotion_v104(
    v_business,v_first,null,'NDP spa celebration',
    '30% off until 30 August 2026',
    'Celebrate National Day with 30% off the 60-minute Spa Ritual.',
    'Valid for one redemption per customer.',
    now()-interval '1 minute',now()+interval '30 days',30,
    'book','Book now','30% off the 60-minute Spa Ritual until 30 August 2026',
    'National Day',true,v_first_path,'image/png',1200,800,
    'National Day spa promotion',1,1,0,v_attempt
  );
  if v_result->>'publish_state'<>'published'
     or (v_result#>>'{item,content_version}')::bigint<>2
     or (v_result#>>'{item,copy_version}')::bigint<>2
     or v_result#>>'{item,image_url}'
       not like '/storage/v1/object/public/business-public/%' then
    raise exception 'image-backed publication failed: %',v_result;
  end if;
  -- A lost publish response replays before optimistic checks and consumes one
  -- immutable launch slot only once.
  v_replay:=public.business_finalize_promotion_v104(
    v_business,v_first,null,'NDP spa celebration',
    '30% off until 30 August 2026',
    'Celebrate National Day with 30% off the 60-minute Spa Ritual.',
    'Valid for one redemption per customer.',
    now()-interval '1 minute',now()+interval '30 days',30,
    'book','Book now','30% off the 60-minute Spa Ritual until 30 August 2026',
    'National Day',true,v_first_path,'image/png',1200,800,
    'National Day spa promotion',1,1,0,v_attempt
  );
  if not (v_replay->>'replayed')::boolean
     or (v_replay->>'quota_used')::integer<>1
     or v_replay->>'promotion_id'<>v_first::text then
    raise exception 'lost publish response did not replay exactly: %',v_replay;
  end if;

  v_stale_path:=v_business||'/offer/'||gen_random_uuid()||'.png';
  reset role;
  insert into storage.objects(bucket_id,name,metadata)
  values(
    'business-public',v_stale_path,
    '{"mimetype":"image/png","size":"4096"}'::jsonb
  );
  select copy.name,asset.object_path
  into v_before_copy,v_before_path
  from public.business_localized_copy_v95 copy
  join public.business_media_assets_v95 asset
    on asset.business_id=copy.business_id
    and asset.entity_id=copy.entity_id
    and asset.asset_kind='offer'
    and asset.branch_id is null
  where copy.business_id=v_business
    and copy.entity_type='offer'
    and copy.entity_id=v_first
    and copy.locale='en';
  perform pg_temp.as_v104_user(v_owner);
  begin
    perform public.business_finalize_promotion_v104(
      v_business,v_first,null,'Stale edit',null,
      'This stale edit must roll back without changing copy.',null,
      now(),now()+interval '30 days',30,'counter','View offer',
      'stale facts',null,true,v_stale_path,'image/png',1200,800,
      'Stale replacement',1,1,1,gen_random_uuid()
    );
    raise exception 'stale promotion versions overwrote publication';
  exception when sqlstate '40001' then null;
  end;
  reset role;
  if exists(
       select 1 from public.business_media_assets_v95
       where business_id=v_business and object_path=v_stale_path
     )
     or not exists(
       select 1 from storage.objects
       where bucket_id='business-public' and name=v_stale_path
     )
     or (select name from public.business_localized_copy_v95
         where business_id=v_business and entity_type='offer'
           and entity_id=v_first and locale='en')<>v_before_copy
     or (select object_path from public.business_media_assets_v95
         where business_id=v_business and asset_kind='offer'
           and entity_id=v_first and branch_id is null)<>v_before_path then
    raise exception 'stale active replacement changed old image/copy or lost orphan';
  end if;

  -- Super admin lowers the launch quota to one. Owner cannot first-publish a
  -- second offer until the platform deliberately extends the entitlement.
  perform pg_temp.as_v104_user(v_owner);
  begin
    perform public.platform_set_promotion_entitlement_v104(
      v_business,1,now()+interval '30 days',0
    );
    raise exception 'owner changed platform promotion entitlement';
  exception when sqlstate '42501' then null;
  end;
  reset role;
  perform pg_temp.as_v104_user(v_super);
  v_result:=public.platform_set_promotion_entitlement_v104(
    v_business,1,now()+interval '30 days',0
  );
  if (v_result->>'version')::bigint<>1 then
    raise exception 'initial platform entitlement was not version one';
  end if;
  reset role;

  perform pg_temp.as_v104_user(v_owner);
  v_second:=gen_random_uuid();
  v_result:=public.business_create_promotion_draft_v104(
    v_business,v_second,gen_random_uuid(),null,'Second offer',null,
    'A second global offer for deterministic ordering.',null,
    now()-interval '1 minute',now()+interval '20 days',1,
    'programme','View offer','20% off a selected facial',null
  );
  reset role;
  v_second_path:=v_business||'/offer/'||gen_random_uuid()||'.png';
  insert into storage.objects(bucket_id,name,metadata)
  values(
    'business-public',v_second_path,
    '{"mimetype":"image/png","size":"4096"}'::jsonb
  );
  perform pg_temp.as_v104_user(v_owner);
  v_result:=public.business_finalize_promotion_v104(
    v_business,v_second,null,'Second offer',null,
    'A second global offer for deterministic ordering.',null,
    now()-interval '1 minute',now()+interval '20 days',1,
    'programme','View offer','20% off a selected facial',null,
    false,v_second_path,'image/png',1200,800,
    'Selected facial promotion',1,1,0,gen_random_uuid()
  );
  if v_result->>'publish_state'<>'draft'
     or (v_result->>'media_version')::bigint<>1 then
    raise exception 'draft photo was not atomically stored: %',v_result;
  end if;
  v_result:=public.business_get_promotion_editor_v104(v_business);
  if v_result#>>'{items,1,image_url}' is null
     or (v_result#>>'{items,1,image_customer_visible}')::boolean
     or v_result#>>'{items,1,media_versions_by_scope,global,media_version}'<>'1'
  then
    raise exception 'hidden draft photo did not reload in editor: %',v_result;
  end if;
  begin
    perform public.business_finalize_promotion_v104(
      v_business,v_second,null,'Second offer',null,
      'A second global offer for deterministic ordering.',null,
      now()-interval '1 minute',now()+interval '20 days',1,
      'programme','View offer','20% off a selected facial',null,
      true,null,null,null,null,null,2,2,1,gen_random_uuid()
    );
    raise exception 'owner exceeded one-offer platform quota';
  exception when sqlstate '23514' then null;
  end;
  reset role;

  perform pg_temp.as_v104_user(v_super);
  perform public.platform_set_promotion_entitlement_v104(
    v_business,3,now()+interval '30 days',1
  );
  reset role;
  perform pg_temp.as_v104_user(v_owner);
  v_result:=public.business_finalize_promotion_v104(
    v_business,v_second,null,'Second offer',null,
    'A second global offer for deterministic ordering.',null,
    now()-interval '1 minute',now()+interval '20 days',1,
    'programme','View offer','20% off a selected facial',null,
    true,null,null,null,null,null,2,2,1,gen_random_uuid()
  );
  if v_result->>'publish_state'<>'published'
     or (v_result->>'media_version')::bigint<>2 then
    raise exception 'draft photo did not publish without reselecting: %',
      v_result;
  end if;

  -- Promotions are company-wide. A branch-scoped authoring attempt fails
  -- before it can create a receipt or mutable offer state.
  begin
    perform public.business_create_promotion_draft_v104(
      v_business,gen_random_uuid(),gen_random_uuid(),v_second_branch,
      'Branch-only offer',null,
      'This branch-only promotion must never be created.',null,
      now()-interval '1 minute',now()+interval '10 days',2,
      'counter','Show at counter','Free branch-only upgrade',null
    );
    raise exception 'branch-scoped promotion draft was created';
  exception when sqlstate '22023' then null;
  end;

  -- The third offer is another company-wide promotion.
  v_third:=gen_random_uuid();
  v_result:=public.business_create_promotion_draft_v104(
    v_business,v_third,gen_random_uuid(),null,
    'Third company-wide offer',null,
    'A third promotion visible across the entire company.',null,
    now()-interval '1 minute',now()+interval '10 days',2,
    'counter','Show at counter','Free company-wide upgrade','New launch'
  );
  reset role;
  v_third_path:=v_business||'/offer/'||gen_random_uuid()||'.png';
  insert into storage.objects(bucket_id,name,metadata)
  values(
    'business-public',v_third_path,
    '{"mimetype":"image/png","size":"4096"}'::jsonb
  );
  perform pg_temp.as_v104_user(v_owner);
  perform public.business_finalize_promotion_v104(
    v_business,v_third,null,'Third company-wide offer',null,
    'A third promotion visible across the entire company.',null,
    now()-interval '1 minute',now()+interval '10 days',2,
    'counter','Show at counter','Free company-wide upgrade','New launch',
    true,v_third_path,'image/png',1200,800,'Company-wide offer',
    1,1,0,gen_random_uuid()
  );

  -- Fourth draft may be saved inside the launch window, but quota refuses its
  -- publication after all three slots are occupied.
  v_fourth:=gen_random_uuid();
  v_result:=public.business_create_promotion_draft_v104(
    v_business,v_fourth,gen_random_uuid(),null,'Fourth offer',null,
    'This fourth offer remains a draft after the quota refusal.',null,
    now(),now()+interval '5 days',3,'counter','View offer',
    'Fourth offer',null
  );
  reset role;
  v_fourth_path:=v_business||'/offer/'||gen_random_uuid()||'.png';
  insert into storage.objects(bucket_id,name,metadata)
  values(
    'business-public',v_fourth_path,
    '{"mimetype":"image/png","size":"4096"}'::jsonb
  );
  perform pg_temp.as_v104_user(v_owner);
  begin
    perform public.business_finalize_promotion_v104(
      v_business,v_fourth,null,'Fourth offer',null,
      'This fourth offer remains a draft after the quota refusal.',null,
      now(),now()+interval '5 days',3,'counter','View offer',
      'Fourth offer',null,true,v_fourth_path,'image/png',1200,800,
      'Fourth promotion',1,1,0,gen_random_uuid()
    );
    raise exception 'fourth active offer exceeded max three';
  exception when sqlstate '23514' then null;
  end;

  -- A used launch slot is permanent for that promotion: unpublishing changes
  -- current visibility but does not replenish the ten-offer launch allowance.
  reset role;
  select version into v_content_version
  from public.business_customer_content_v95 where id=v_first;
  select version into v_copy_version
  from public.business_localized_copy_v95
  where business_id=v_business and entity_type='offer'
    and entity_id=v_first and locale='en';
  perform pg_temp.as_v104_user(v_owner);
  v_result:=public.business_finalize_promotion_v104(
    v_business,v_first,null,'NDP spa celebration',
    '30% off until 30 August 2026',
    'Celebrate National Day with 30% off the 60-minute Spa Ritual.',
    'Valid for one redemption per customer.',
    now()-interval '1 minute',now()+interval '30 days',30,
    'book','Book now','30% off the 60-minute Spa Ritual until 30 August 2026',
    'National Day',false,null,null,null,null,null,
    v_content_version,v_copy_version,1,gen_random_uuid()
  );
  if (v_result->>'quota_used')::integer<>3
     or (v_result->>'published_count')::integer<>2 then
    raise exception 'unpublishing restored a consumed promotion quota slot: %',
      v_result;
  end if;
  begin
    perform public.business_finalize_promotion_v104(
      v_business,v_fourth,null,'Fourth offer',null,
      'This fourth offer remains a draft after the quota refusal.',null,
      now(),now()+interval '5 days',3,'counter','View offer',
      'Fourth offer',null,true,v_fourth_path,'image/png',1200,800,
      'Fourth promotion',1,1,0,gen_random_uuid()
    );
    raise exception 'unpublishing an offer incorrectly restored a quota slot';
  exception when sqlstate '23514' then null;
  end;
  v_result:=public.business_finalize_promotion_v104(
    v_business,v_first,null,'NDP spa celebration',
    '30% off until 30 August 2026',
    'Celebrate National Day with 30% off the 60-minute Spa Ritual.',
    'Valid for one redemption per customer.',
    now()-interval '1 minute',now()+interval '30 days',30,
    'book','Book now','30% off the 60-minute Spa Ritual until 30 August 2026',
    'National Day',true,null,null,null,null,null,
    (v_result->>'content_version')::bigint,
    (v_result->>'copy_version')::bigint,
    1,gen_random_uuid()
  );

  v_result:=public.business_get_promotion_editor_v104(v_business);
  if jsonb_array_length(v_result->'items')<>4
     or (v_result#>>'{entitlement,published_count}')::integer<>3
     or (v_result#>>'{entitlement,quota_used}')::integer<>3
     or (v_result#>>'{entitlement,quota_remaining}')::integer<>0
     or (v_result#>>'{entitlement,can_publish_new}')::boolean
     or v_result#>>'{items,0,media_asset_id}' is null
     or v_result#>>'{items,0,image_alt}' is null
     or v_result#>>'{items,0,publish_state}'<>'published' then
    raise exception 'owner promotion editor or quota truth is wrong: %',v_result;
  end if;
  reset role;

  -- Customer sees at most two current image-backed company-wide offers in
  -- deterministic display order. Supplying a branch is rejected.
  perform pg_temp.as_v104_user(v_customer);
  v_result:=public.customer_get_promotions_v104(v_business,null,'en');
  if (v_result->>'limit')::integer<>2
     or jsonb_array_length(v_result->'items')<>2
     or v_result#>>'{items,0,id}'<>v_second::text
     or v_result#>>'{items,1,id}'<>v_third::text
     or v_result#>>'{items,0,image_alt}' is null
     or v_result#>>'{items,1,metadata,cta,kind}'<>'counter' then
    raise exception 'company-wide two-card promotion projection is wrong: %',
      v_result;
  end if;
  begin
    perform public.customer_get_promotions_v104(v_business,v_branch,'en');
    raise exception 'branch-scoped customer promotion reader was allowed';
  exception when sqlstate '22023' then null;
  end;
  reset role;

  -- Simulate an independently refreshed global image. A stale global version
  -- fails without changing copy/image, and editor refresh exposes the exact
  -- global version needed for a recoverable retry.
  reset role;
  select content.version,copy.version,copy.name,asset.object_path
  into v_content_version,v_copy_version,v_before_copy,v_before_path
  from public.business_customer_content_v95 content
  join public.business_localized_copy_v95 copy
    on copy.business_id=content.business_id
    and copy.entity_type='offer'
    and copy.entity_id=content.id
    and copy.locale='en'
  join public.business_media_assets_v95 asset
    on asset.business_id=content.business_id
    and asset.asset_kind='offer'
    and asset.entity_id=content.id
    and asset.branch_id is null
  where content.id=v_third;

  v_before_path:=v_business||'/offer/'||gen_random_uuid()||'.png';
  v_global_retry_path:=v_business||'/offer/'||gen_random_uuid()||'.png';
  insert into storage.objects(bucket_id,name,metadata) values
    (
      'business-public',v_before_path,
      '{"mimetype":"image/png","size":"4096"}'::jsonb
    ),
    (
      'business-public',v_global_retry_path,
      '{"mimetype":"image/png","size":"4096"}'::jsonb
    );
  perform pg_temp.as_v104_user(v_super);
  perform set_config('app.v104_promotion_media_write','on',true);
  perform public.business_publish_media_replacement_v95(
    v_business,'offer',v_third,null,v_before_path,'image/png',
    1200,800,'Newer company-wide image',null,null,1,null
  );
  perform set_config('app.v104_promotion_media_write','',true);
  reset role;
  select name into v_before_copy
  from public.business_localized_copy_v95
  where business_id=v_business and entity_type='offer'
    and entity_id=v_third and locale='en';
  perform pg_temp.as_v104_user(v_owner);
  begin
    perform public.business_finalize_promotion_v104(
      v_business,v_third,null,'Stale global replacement',null,
      'This stale global media edit must not change copy or image.',null,
      now()-interval '1 minute',now()+interval '10 days',2,
      'counter','Show at counter','Stale global facts','Global edit',
      true,v_global_retry_path,'image/png',1200,800,'Stale global image',
      v_content_version,v_copy_version,1,gen_random_uuid()
    );
    raise exception 'stale global media version overwrote active image';
  exception when sqlstate '40001' then null;
  end;
  reset role;
  if (select name from public.business_localized_copy_v95
      where business_id=v_business and entity_type='offer'
        and entity_id=v_third and locale='en')<>v_before_copy
     or (select object_path from public.business_media_assets_v95
         where business_id=v_business and asset_kind='offer'
           and entity_id=v_third and branch_id is null)<>v_before_path
     or exists(
       select 1 from public.business_media_assets_v95
       where business_id=v_business and object_path=v_global_retry_path
     )
  then
    raise exception 'stale global failure changed copy/image or linked orphan';
  end if;
  perform pg_temp.as_v104_user(v_owner);
  v_result:=public.business_get_promotion_editor_v104(v_business);
  select (
    item#>>'{media_versions_by_scope,global,media_version}'
  )::bigint into v_media_version
  from jsonb_array_elements(v_result->'items') item
  where item->>'id'=v_third::text;
  if v_media_version<>2 then
    raise exception 'editor did not expose refreshed global media version: %',
      v_result;
  end if;
  v_result:=public.business_finalize_promotion_v104(
    v_business,v_third,null,'Recovered global replacement',null,
    'This refreshed global media edit succeeds without ambiguity.',null,
    now()-interval '1 minute',now()+interval '10 days',2,
    'counter','Show at counter','Recovered global facts','Global edit',
    true,v_global_retry_path,'image/png',1200,800,'Recovered global image',
    v_content_version,v_copy_version,v_media_version,gen_random_uuid()
  );
  if (v_result->>'target_media_version')::bigint<>3
     or v_result->>'previous_object_path'<>v_before_path then
    raise exception 'refreshed global retry did not replace exact scope: %',
      v_result;
  end if;
  reset role;

  perform pg_temp.as_v104_user(v_outsider);
  begin
    perform public.customer_get_promotions_v104(v_business,null,'en');
    raise exception 'unlinked customer read business promotions';
  exception when sqlstate '42501' then null;
  end;
  reset role;

  -- An already-active legacy offer has no immutable v104 allocation marker.
  -- First v104 adoption must allocate/check a slot; active-to-active is not a
  -- quota bypass.
  v_legacy_path:=v_other_business||'/offer/'||gen_random_uuid()||'.png';
  perform pg_temp.as_v104_user(v_super);
  reset role;
  perform set_config('app.v104_promotion_write','on',true);
  insert into public.business_customer_content_v95(
    id,business_id,content_type,branch_id,active,display_order,
    starts_at,ends_at,metadata,updated_by
  ) values(
    v_legacy,v_other_business,'offer',null,true,1,
    now()-interval '1 day',now()+interval '10 days',
    '{"legacy":true}'::jsonb,v_super
  );
  perform set_config('app.v104_promotion_write','',true);
  perform set_config('app.v104_promotion_copy_write','on',true);
  insert into public.business_localized_copy_v95(
    business_id,entity_type,entity_id,locale,name,description,updated_by
  ) values(
    v_other_business,'offer',v_legacy,'en','Legacy active offer',
    'This active legacy offer must allocate a v104 promotion slot.',v_super
  );
  perform set_config('app.v104_promotion_copy_write','',true);
  insert into storage.objects(bucket_id,name,metadata)
  values(
    'business-public',v_legacy_path,
    '{"mimetype":"image/png","size":"4096"}'::jsonb
  );
  perform set_config('app.v104_promotion_media_write','on',true);
  insert into public.business_media_assets_v95(
    business_id,asset_kind,entity_id,branch_id,object_path,mime_type,
    width_px,height_px,alt_en,customer_visible,updated_by
  ) values(
    v_other_business,'offer',v_legacy,null,v_legacy_path,'image/png',
    1200,800,'Legacy active promotion',true,v_super
  );
  perform set_config('app.v104_promotion_media_write','',true);
  perform pg_temp.as_v104_user(v_super);
  perform public.platform_set_promotion_entitlement_v104(
    v_other_business,0,now()+interval '30 days',0
  );
  reset role;
  perform pg_temp.as_v104_user(v_other_owner);
  begin
    perform public.business_finalize_promotion_v104(
      v_other_business,v_legacy,null,'Legacy active offer',null,
      'This active legacy offer must allocate a v104 promotion slot.',null,
      now()-interval '1 day',now()+interval '10 days',1,
      'counter','Show at counter','Legacy offer adoption',null,
      true,null,null,null,null,null,1,1,1,gen_random_uuid()
    );
    raise exception 'active legacy conversion bypassed v104 allocation quota';
  exception when sqlstate '23514' then null;
  end;
  reset role;
  perform pg_temp.as_v104_user(v_super);
  perform public.platform_set_promotion_entitlement_v104(
    v_other_business,1,now()+interval '30 days',1
  );
  reset role;
  perform pg_temp.as_v104_user(v_other_owner);
  v_result:=public.business_finalize_promotion_v104(
    v_other_business,v_legacy,null,'Legacy active offer',null,
    'This active legacy offer now owns one immutable v104 slot.',null,
    now()-interval '1 day',now()+interval '10 days',1,
    'counter','Show at counter','Legacy offer adoption',null,
    true,null,null,null,null,null,1,1,1,gen_random_uuid()
  );
  if (v_result->>'quota_used')::integer<>1
     or v_result#>>'{metadata,published_once_at}' is null then
    raise exception 'active legacy conversion did not allocate one slot: %',
      v_result;
  end if;
  reset role;

  -- Closing the complimentary window still permits private draft creation.
  -- The first publication is the billable entitlement boundary.
  perform pg_temp.as_v104_user(v_super);
  perform public.platform_set_promotion_entitlement_v104(
    v_business,10,now()-interval '1 second',2
  );
  reset role;
  perform pg_temp.as_v104_user(v_owner);
  v_late:=gen_random_uuid();
  v_attempt:=gen_random_uuid();
  v_result:=public.business_create_promotion_draft_v104(
    v_business,v_late,v_attempt,null,'Late private draft',null,
    'This private draft remains editable after the launch window.',null,
    now(),now()+interval '1 day',5,'counter','View offer',
    'Late private draft',null
  );
  if v_result->>'publish_state'<>'draft'
     or v_result->>'promotion_id'<>v_late::text then
    raise exception 'private draft was blocked after quota or cutoff: %',
      v_result;
  end if;

  -- Exact lost-response replay belongs to the original actor and returns before
  -- current owner authority or mutable entitlement checks.
  reset role;
  update public.staff
  set active=false
  where business_id=v_business and user_id=v_owner;
  perform pg_temp.as_v104_user(v_owner);
  v_replay:=public.business_create_promotion_draft_v104(
    v_business,v_late,v_attempt,null,'Late private draft',null,
    'This private draft remains editable after the launch window.',null,
    now(),now()+interval '1 day',5,'counter','View offer',
    'Late private draft',null
  );
  if not (v_replay->>'replayed')::boolean
     or v_replay->>'promotion_id'<>v_late::text then
    raise exception 'original creator lost-response replay failed after owner revocation: %',
      v_replay;
  end if;

  -- A deleted actor leaves created_by NULL. NULL must not fail open for a
  -- different, non-owner actor replaying the receipt.
  reset role;
  update public.business_promotion_attempt_receipts_v104
  set created_by=null
  where business_id=v_business and attempt_key=v_attempt;
  perform pg_temp.as_v104_user(v_outsider);
  begin
    perform public.business_create_promotion_draft_v104(
      v_business,v_late,v_attempt,null,'Late private draft',null,
      'This private draft remains editable after the launch window.',null,
      now(),now()+interval '1 day',5,'counter','View offer',
      'Late private draft',null
    );
    raise exception 'orphaned NULL-created_by receipt replayed for non-owner';
  exception when sqlstate '42501' then null;
  end;
  reset role;
  update public.staff
  set active=true
  where business_id=v_business and user_id=v_owner;

  v_late_path:=v_business||'/offer/'||gen_random_uuid()||'.png';
  insert into storage.objects(bucket_id,name,metadata)
  values(
    'business-public',v_late_path,
    '{"mimetype":"image/png","size":"4096"}'::jsonb
  );
  perform pg_temp.as_v104_user(v_owner);
  begin
    perform public.business_finalize_promotion_v104(
      v_business,v_late,null,'Late private draft',null,
      'This private draft remains editable after the launch window.',null,
      now(),now()+interval '1 day',5,'counter','View offer',
      'Late private draft',null,true,v_late_path,'image/png',1200,800,
      'Late private promotion',1,1,0,gen_random_uuid()
    );
    raise exception 'first publication succeeded after publishing window closed';
  exception when sqlstate '42501' then null;
  end;

  -- Existing active offers remain editable because their own dates still
  -- govern customer visibility.
  reset role;
  select version into v_content_version
  from public.business_customer_content_v95 where id=v_first;
  select version into v_copy_version
  from public.business_localized_copy_v95
  where business_id=v_business and entity_type='offer'
    and entity_id=v_first and locale='en';
  perform pg_temp.as_v104_user(v_owner);
  v_result:=public.business_finalize_promotion_v104(
    v_business,v_first,null,'NDP spa celebration updated',
    '30% off until 30 August 2026',
    'Celebrate National Day with 30% off the 60-minute Spa Ritual.',
    'Valid for one redemption per customer.',
    now()-interval '1 minute',now()+interval '30 days',30,
    'book','Book now','30% off the 60-minute Spa Ritual until 30 August 2026',
    'National Day',true,null,null,null,null,null,
    v_content_version,v_copy_version,1,gen_random_uuid()
  );
  if v_result->>'publish_state'<>'published' then
    raise exception 'closed launch window invalidated an existing publication';
  end if;
  reset role;

  -- Browser roles receive RPC execution only; no raw entitlement-table access
  -- and no anonymous or residual PUBLIC function execution.
  if has_table_privilege(
       'authenticated',
       'public.business_promotion_entitlements_v104',
       'select'
     )
     or has_table_privilege(
       'authenticated',
       'public.business_promotion_entitlements_v104',
       'insert'
     )
     or has_table_privilege(
       'authenticated',
       'public.business_promotion_attempt_receipts_v104',
       'select'
     )
     or has_function_privilege(
       'anon',
       'public.customer_get_promotions_v104(uuid,uuid,text)'::regprocedure,
       'EXECUTE'
     )
     or not has_function_privilege(
       'authenticated',
       'public.customer_get_promotions_v104(uuid,uuid,text)'::regprocedure,
       'EXECUTE'
     )
     or exists(
       select 1
       from pg_proc proc
       cross join lateral aclexplode(
         coalesce(proc.proacl,acldefault('f',proc.proowner))
       ) acl
       where proc.oid in(
         'public.business_save_promotion_v104(uuid,uuid,uuid,text,text,text,text,timestamptz,timestamptz,integer,text,text,text,text,boolean,bigint,bigint)'::regprocedure,
         'public.business_create_promotion_draft_v104(uuid,uuid,uuid,uuid,text,text,text,text,timestamptz,timestamptz,integer,text,text,text,text)'::regprocedure,
         'public.business_finalize_promotion_v104(uuid,uuid,uuid,text,text,text,text,timestamptz,timestamptz,integer,text,text,text,text,boolean,text,text,integer,integer,text,bigint,bigint,bigint,uuid)'::regprocedure,
         'public.business_get_promotion_editor_v104(uuid)'::regprocedure,
         'public.customer_get_promotions_v104(uuid,uuid,text)'::regprocedure,
         'public.platform_set_promotion_entitlement_v104(uuid,integer,timestamptz,bigint)'::regprocedure
       )
       and acl.grantee=0
       and acl.privilege_type='EXECUTE'
     ) then
    raise exception 'v104 promotion ACL is not finite and authenticated-only';
  end if;
end
$v104_test$;

rollback;
