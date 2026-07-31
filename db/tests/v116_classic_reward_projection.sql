-- Rollback-only acceptance for Nestly v116 classic reward projection.
-- Run after the canonical chain through v116 in a disposable database.
begin;

create or replace function pg_temp.as_v116_user(
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
grant execute on function pg_temp.as_v116_user(uuid,text) to public;

do $v116_test$
declare
  v_super uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_identity uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_client uuid:=gen_random_uuid();
  v_link uuid:=gen_random_uuid();
  v_slug text:='v116-glow-'||substr(v_business::text,1,8);
  v_result jsonb;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values
  (
    '00000000-0000-0000-0000-000000000000',v_super,
    'authenticated','authenticated','v116-super@example.test','',
    now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_customer,
    'authenticated','authenticated','v116-customer@example.test','',
    now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_outsider,
    'authenticated','authenticated','v116-outsider@example.test','',
    now(),now(),now()
  );

  insert into public.businesses(
    id,name,slug,industry,enabled_modules,is_synthetic
  ) values(
    v_business,'V116 Glow Atelier',v_slug,'facial',
    array['dashboard','clients','loyalty'],true
  );
  insert into public.super_admins(user_id,email,note)
  values(
    v_super,'v116-super@example.test',
    'rollback-only v116 forward-chain acceptance'
  );
  perform pg_temp.as_v116_user(v_super);
  v_result:=public.platform_decide_business_approval_v94(
    v_business,'approved','v116 forward-chain acceptance',1
  );
  reset role;
  if v_result->>'approval_status'<>'approved'
     or not (v_result->>'workspace_access')::boolean then
    raise exception 'v116 synthetic business was not approved: %',v_result;
  end if;
  insert into public.customer_identities(
    id,auth_user_id,status,created_via
  ) values(
    v_identity,v_customer,'active','phone_registration'
  );
  insert into public.clients(
    id,business_id,full_name,email
  ) values(
    v_client,v_business,'V116 Mei Lin','v116-customer@example.test'
  );
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values(
    v_link,v_business,v_identity,v_customer,v_client,'verified',
    'firm_invitation',now()
  );
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,
    redeem_points,reward_credit_cents
  ) values(
    v_business,'points',true,'classic','published',1000,1000
  );

  perform pg_temp.as_v116_user(v_customer);
  v_result:=public.customer_portal_capabilities(v_slug);
  if coalesce((v_result->>'rewards')::boolean,false) is not true then
    raise exception
      'active classic reward was hidden without a catalogue row: %',
      v_result;
  end if;
  reset role;

  update public.loyalty_programs
     set active=false
   where business_id=v_business;
  perform pg_temp.as_v116_user(v_customer);
  v_result:=public.customer_portal_capabilities(v_slug);
  if coalesce((v_result->>'rewards')::boolean,false) then
    raise exception 'inactive classic programme exposed rewards: %',v_result;
  end if;
  reset role;

  update public.loyalty_programs
     set active=true
   where business_id=v_business;
  update public.businesses
     set enabled_modules=array_remove(enabled_modules,'loyalty')
   where id=v_business;
  perform pg_temp.as_v116_user(v_customer);
  v_result:=public.customer_portal_capabilities(v_slug);
  if coalesce((v_result->>'rewards')::boolean,false) then
    raise exception 'disabled Loyalty module exposed rewards: %',v_result;
  end if;
  reset role;

  update public.businesses
     set enabled_modules=array_append(enabled_modules,'loyalty')
   where id=v_business;
  update public.loyalty_programs
     set loyalty_model='points_tiers'
   where business_id=v_business;
  perform pg_temp.as_v116_user(v_customer);
  v_result:=public.customer_portal_capabilities(v_slug);
  if coalesce((v_result->>'rewards')::boolean,false) then
    raise exception
      'points-tiers programme without a catalogue row exposed rewards: %',
      v_result;
  end if;
  reset role;

  begin
    perform pg_temp.as_v116_user(v_outsider);
    perform public.customer_portal_capabilities(v_slug);
    reset role;
    raise exception 'unlinked customer read reward capabilities';
  exception when insufficient_privilege then
    reset role;
  end;
end
$v116_test$;

rollback;
