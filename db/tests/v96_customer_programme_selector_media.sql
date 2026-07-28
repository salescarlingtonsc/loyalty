-- Rollback-only acceptance for the v96 actionable programme logo projection.
begin;

create or replace function pg_temp.as_v96_user(
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
grant execute on function pg_temp.as_v96_user(uuid,text) to public;

do $v96_test$
declare
  v_customer uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_identity uuid:=gen_random_uuid();
  v_outsider_identity uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_other_business uuid:=gen_random_uuid();
  v_client uuid:=gen_random_uuid();
  v_other_client uuid:=gen_random_uuid();
  v_logo uuid:=gen_random_uuid();
  v_other_logo uuid:=gen_random_uuid();
  v_logo_path text;
  v_other_logo_path text;
  v_result jsonb;
begin
  v_logo_path:=v_business::text||'/logo/'||v_logo::text||'.png';
  v_other_logo_path:=v_other_business::text||'/logo/'||v_other_logo::text||'.png';

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_customer,
      'authenticated','authenticated','v96-customer@example.test','',
      now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,
      'authenticated','authenticated','v96-outsider@example.test','',
      now(),now(),now());

  insert into public.businesses(id,name,slug,enabled_modules)
  values
    (v_business,'V96 Linked Firm',
      'v96-linked-'||substr(v_business::text,1,8),array['loyalty']),
    (v_other_business,'V96 Foreign Firm',
      'v96-foreign-'||substr(v_other_business::text,1,8),array['loyalty']);
  insert into public.clients(id,business_id,full_name)
  values
    (v_client,v_business,'V96 Linked Customer'),
    (v_other_client,v_other_business,'V96 Foreign Customer');
  insert into public.customer_identities(
    id,auth_user_id,status,created_via
  ) values
    (v_identity,v_customer,'active','wallet_start'),
    (v_outsider_identity,v_outsider,'active','wallet_start');
  insert into public.customer_links(
    business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values(
    v_business,v_identity,v_customer,v_client,'verified',
    'firm_invitation',now()
  );

  insert into public.business_media_assets_v95(
    id,business_id,asset_kind,object_path,mime_type,width_px,height_px,
    alt_en,customer_visible
  ) values
    (v_logo,v_business,'logo',v_logo_path,'image/png',256,256,
      'Linked firm logo',true),
    (v_other_logo,v_other_business,'logo',v_other_logo_path,'image/png',
      256,256,'Foreign firm logo',true);
  update public.business_brand_presentation_v95
     set logo_asset_id=v_logo
   where business_id=v_business;
  update public.business_brand_presentation_v95
     set logo_asset_id=v_other_logo
   where business_id=v_other_business;
  update app.platform_feature_flags set enabled=true
   where feature_key='customer_wallet';

  -- Selector media remains available when optional actionable ranking is off.
  update app.platform_feature_flags set enabled=false
   where feature_key='customer_actionable_wallet';
  perform pg_temp.as_v96_user(v_customer);
  v_result:=public.customer_get_programme_selector_media_v96();
  reset role;
  if jsonb_array_length(v_result->'items')<>1
     or v_result#>>'{items,0,business_slug}'
       <>('v96-linked-'||substr(v_business::text,1,8))
     or v_result#>>'{items,0,logo_url}'
       <>('/storage/v1/object/public/business-public/'||v_logo_path) then
    raise exception 'legacy selector media batch is wrong: %',v_result;
  end if;

  update app.platform_feature_flags set enabled=true
   where feature_key='customer_actionable_wallet';

  perform pg_temp.as_v96_user(v_customer);
  v_result:=public.customer_get_actionable_wallet();
  reset role;
  if jsonb_array_length(v_result->'cards')<>1 then
    raise exception 'selector did not remain verified-link scoped: %',v_result;
  end if;
  if v_result#>>'{cards,0,business,logo_url}'
      <>('/storage/v1/object/public/business-public/'||v_logo_path) then
    raise exception 'linked customer-visible logo was not projected: %',v_result;
  end if;
  if v_result::text like '%'||v_other_logo_path||'%' then
    raise exception 'foreign tenant media leaked into selector: %',v_result;
  end if;

  update public.business_media_assets_v95
     set customer_visible=false
   where id=v_logo and business_id=v_business;
  perform pg_temp.as_v96_user(v_customer);
  v_result:=public.customer_get_actionable_wallet();
  reset role;
  if v_result#>'{cards,0,business,logo_url}'<>'null'::jsonb then
    raise exception 'hidden logo remained customer-visible: %',v_result;
  end if;

  perform pg_temp.as_v96_user(null,'anon');
  begin
    perform public.customer_get_actionable_wallet();
    raise exception 'anonymous caller read the actionable selector';
  exception when sqlstate '42501' then null;
  end;
  reset role;

  perform pg_temp.as_v96_user(v_outsider);
  v_result:=public.customer_get_programme_selector_media_v96();
  reset role;
  if jsonb_array_length(v_result->'items')<>0
     or (v_result->>'truncated')::boolean then
    raise exception 'unlinked active customer did not receive an empty batch: %',
      v_result;
  end if;

  if has_function_privilege('anon','public.customer_get_actionable_wallet()','EXECUTE')
     or not has_function_privilege(
       'authenticated','public.customer_get_actionable_wallet()','EXECUTE'
     )
     or has_function_privilege(
       'anon','public.customer_get_programme_selector_media_v96()','EXECUTE'
     )
     or not has_function_privilege(
       'authenticated',
       'public.customer_get_programme_selector_media_v96()','EXECUTE'
     ) then
    raise exception 'v96 actionable wallet ACL is not finite';
  end if;
end
$v96_test$;

rollback;
