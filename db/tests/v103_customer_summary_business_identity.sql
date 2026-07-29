-- Rollback-only v103 customer summary business identity contract.
-- Proves that the projected UUID is self-derived from the verified link,
-- cannot be used to discover another firm, and preserves authenticated-only ACL.

begin;
select set_config('app.v79_system_transition', 'on', true);

create or replace function pg_temp.as_v103_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_uid, 'role', p_role
  )::text, true);
end
$$;
grant execute on function pg_temp.as_v103_user(uuid,text) to public;

do $v103_test$
declare
  v_customer uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid();
  v_business uuid;
  v_business_slug text;
  v_other_business uuid;
  v_other_slug text;
  v_client uuid;
  v_other_client uuid;
  v_identity uuid;
  v_link uuid := gen_random_uuid();
  v_summary jsonb;
  v_overloads integer;
begin
  reset role;
  insert into public.businesses(name,slug,industry,enabled_modules)
  values(
    'V103 linked business',
    'v103-linked-' || substr(gen_random_uuid()::text,1,8),
    'test',
    array['dashboard','clients','loyalty']
  ) returning id,slug into v_business,v_business_slug;
  insert into public.businesses(name,slug,industry,enabled_modules)
  values(
    'V103 unlinked business',
    'v103-unlinked-' || substr(gen_random_uuid()::text,1,8),
    'test',
    array['dashboard','clients','loyalty']
  ) returning id,slug into v_other_business,v_other_slug;
  perform set_config('app.v79_system_transition', '', true);

  update app.platform_feature_flags
     set enabled = true, changed_at = now()
   where feature_key = 'customer_wallet';

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values
    (
      '00000000-0000-0000-0000-000000000000',
      v_customer,'authenticated','authenticated',
      'v103-customer-' || substr(v_customer::text,1,8) || '@example.test',
      '',now(),now(),now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',
      v_outsider,'authenticated','authenticated',
      'v103-outsider-' || substr(v_outsider::text,1,8) || '@example.test',
      '',now(),now(),now()
    );
  insert into public.customer_identities(auth_user_id,status,created_via)
  values(v_customer,'active','phone_registration')
  returning id into v_identity;
  insert into public.clients(business_id,full_name,email)
  values(
    v_business,'V103 verified customer',
    'v103-customer-' || substr(v_customer::text,1,8) || '@example.test'
  ) returning id into v_client;
  insert into public.clients(business_id,full_name,email)
  values(
    v_other_business,'V103 unlinked customer record',
    'v103-customer-' || substr(v_customer::text,1,8) || '@example.test'
  ) returning id into v_other_client;

  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values(
    v_link,v_business,v_identity,v_customer,v_client,'verified',
    'firm_invitation',now()
  );
  perform set_config('app.customer_link_insert_id','',true);

  perform pg_temp.as_v103_user(v_customer);
  v_summary := public.customer_get_business_summary(v_business_slug);
  if v_summary#>>'{business,id}' is distinct from v_business::text
     or v_summary#>>'{business,slug}' is distinct from v_business_slug then
    raise exception
      'verified summary did not return its self-derived business identity: %',
      v_summary;
  end if;
  begin
    perform public.customer_get_business_summary(v_other_slug);
    raise exception 'verified customer discovered an unlinked business summary';
  exception when sqlstate '42501' then null;
  end;
  reset role;

  perform pg_temp.as_v103_user(v_outsider);
  begin
    perform public.customer_get_business_summary(v_business_slug);
    raise exception 'authenticated outsider read a linked customer summary';
  exception when sqlstate '42501' then null;
  end;
  reset role;

  perform pg_temp.as_v103_user(null,'anon');
  begin
    perform public.customer_get_business_summary(v_business_slug);
    raise exception 'anon executed customer_get_business_summary';
  exception when sqlstate '42501' then null;
  end;
  reset role;

  if has_function_privilege(
       'anon',
       'public.customer_get_business_summary(text)'::regprocedure,
       'EXECUTE'
     )
     or not has_function_privilege(
       'authenticated',
       'public.customer_get_business_summary(text)'::regprocedure,
       'EXECUTE'
     )
     or exists(
       select 1
       from pg_proc proc
       cross join lateral aclexplode(
         coalesce(proc.proacl,acldefault('f',proc.proowner))
       ) acl
       where proc.oid =
         'public.customer_get_business_summary(text)'::regprocedure
         and acl.grantee = 0
         and acl.privilege_type = 'EXECUTE'
     ) then
    raise exception
      'customer_get_business_summary ACL is not authenticated-only';
  end if;

  select count(*) into v_overloads
    from pg_proc proc
    join pg_namespace namespace on namespace.oid = proc.pronamespace
   where namespace.nspname = 'public'
     and proc.proname = 'customer_get_business_summary';
  if v_overloads <> 1
     or to_regprocedure(
       'public.customer_get_business_summary(text)'
     ) is null then
    raise exception
      'v103 changed the customer_get_business_summary signature';
  end if;
end
$v103_test$;

rollback;
