-- Rollback-only V123 atomic service-bundle acceptance.
-- Run after the canonical chain through V123 in a disposable database.
begin;

create temporary table pg_temp.v123_fixture (
  business_id uuid primary key,
  owner_user_id uuid not null,
  readonly_user_id uuid not null,
  service_a uuid not null,
  service_b uuid not null,
  foreign_service uuid not null
) on commit drop;

do $fixture$
declare
  v_owner uuid:=gen_random_uuid();
  v_readonly uuid:=gen_random_uuid();
  v_foreign_owner uuid:=gen_random_uuid();
  v_business uuid;
  v_foreign_business uuid;
  v_service_a uuid;
  v_service_b uuid;
  v_foreign_service uuid;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
      'v123-owner-'||v_owner::text||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_readonly,'authenticated','authenticated',
      'v123-readonly-'||v_readonly::text||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_foreign_owner,'authenticated','authenticated',
      'v123-foreign-'||v_foreign_owner::text||'@example.test','',now(),now(),now());

  insert into public.businesses(name,slug,industry,enabled_modules,created_at)
  values (
    'Glow Atelier V123','glow-v123-'||replace(v_owner::text,'-',''),'spa',
    array['dashboard','services'],'2000-01-01'
  ) returning id into v_business;
  insert into public.businesses(name,slug,industry,enabled_modules,created_at)
  values (
    'Harbour Wellness V123','harbour-v123-'||replace(v_foreign_owner::text,'-',''),'spa',
    array['dashboard','services'],'2000-01-01'
  ) returning id into v_foreign_business;

  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,
         decided_at=statement_timestamp(),decision_reason='synthetic V123 fixture',
         updated_at=statement_timestamp()
   where business_id in (v_business,v_foreign_business)
     and approval_status='pending';
  if not found then raise exception 'V123 workspace controls were not created'; end if;

  insert into public.staff(
    business_id,user_id,role,full_name,active,modules,module_perms
  ) values
    (v_business,v_owner,'owner','Olivia Tan',true,null,null),
    (v_business,v_readonly,'staff','Aisha Rahman',true,array['services'],'{"services":"r"}'),
    (v_foreign_business,v_foreign_owner,'owner','Daniel Lim',true,null,null);

  insert into public.services(
    business_id,name,variant_label,price_cents,duration_min,active
  ) values
    (v_business,'Radiance Facial','60 min',8800,60,true)
  returning id into v_service_a;
  insert into public.services(
    business_id,name,variant_label,price_cents,duration_min,active
  ) values
    (v_business,'Scalp Ritual','45 min',6800,45,true)
  returning id into v_service_b;
  insert into public.services(
    business_id,name,variant_label,price_cents,duration_min,active
  ) values
    (v_foreign_business,'Foreign Service','30 min',4800,30,true)
  returning id into v_foreign_service;

  insert into pg_temp.v123_fixture values(
    v_business,v_owner,v_readonly,v_service_a,v_service_b,v_foreign_service
  );
end
$fixture$;

create or replace function pg_temp.as_v123_user(p_user uuid)
returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claim.sub',p_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_user,'role','authenticated')::text,
    true
  );
  execute 'set local role authenticated';
end
$$;
grant execute on function pg_temp.as_v123_user(uuid) to public;

create or replace function pg_temp.expect_v123_error(
  p_sql text,p_state text,p_label text
) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception '% unexpectedly succeeded',p_label;
exception when others then
  if sqlstate<>p_state then
    raise exception '% returned %, expected %: %',p_label,sqlstate,p_state,sqlerrm;
  end if;
end
$$;
grant execute on function pg_temp.expect_v123_error(text,text,text) to public;

do $acceptance$
declare
  f pg_temp.v123_fixture%rowtype;
  v_created jsonb;
  v_replayed jsonb;
  v_bundle uuid;
  v_count integer;
begin
  select * into f from pg_temp.v123_fixture;

  if to_regprocedure(
       'public.create_service_bundle_v123(uuid,text,integer,uuid[],text)'
     ) is null then
    raise exception 'V123 bundle RPC is absent';
  end if;
  if has_function_privilege(
       'public',
       'public.create_service_bundle_v123(uuid,text,integer,uuid[],text)',
       'execute'
     )
     or has_function_privilege(
       'anon',
       'public.create_service_bundle_v123(uuid,text,integer,uuid[],text)',
       'execute'
     )
     or not has_function_privilege(
       'authenticated',
       'public.create_service_bundle_v123(uuid,text,integer,uuid[],text)',
       'execute'
     ) then
    raise exception 'V123 bundle RPC ACL is not authenticated-only';
  end if;
  if has_table_privilege(
       'authenticated','app.service_bundle_operations_v123','select'
     )
     or has_table_privilege('authenticated','public.bundles','insert')
     or has_table_privilege('authenticated','public.bundle_items','insert') then
    raise exception 'V123 internal receipt or direct bundle writes remain API-visible';
  end if;

  perform pg_temp.as_v123_user(f.owner_user_id);
  v_created:=public.create_service_bundle_v123(
    f.business_id,'Radiance Reset',12900,
    array[f.service_a,f.service_b],'bundle-attempt-1'
  );
  v_bundle:=(v_created->>'bundle_id')::uuid;
  if v_created->>'status'<>'created'
     or (v_created->>'replayed')::boolean then
    raise exception 'first V123 bundle response is not a new receipt: %',v_created;
  end if;

  v_replayed:=public.create_service_bundle_v123(
    f.business_id,'Radiance Reset',12900,
    array[f.service_b,f.service_a],'bundle-attempt-1'
  );
  if not (v_replayed->>'replayed')::boolean
     or (v_replayed->>'bundle_id')::uuid<>v_bundle then
    raise exception 'V123 lost-response replay changed the bundle: %',v_replayed;
  end if;

  execute 'reset role';
  select count(*) into v_count from public.bundles
   where business_id=f.business_id and name='Radiance Reset';
  if v_count<>1 then raise exception 'V123 replay created % bundles',v_count; end if;
  select count(*) into v_count from public.bundle_items where bundle_id=v_bundle;
  if v_count<>2 then raise exception 'V123 atomic bundle has % items',v_count; end if;
  select count(*) into v_count from app.service_bundle_operations_v123
   where business_id=f.business_id and bundle_id=v_bundle;
  if v_count<>1 then raise exception 'V123 bundle has % receipts',v_count; end if;

  perform pg_temp.as_v123_user(f.owner_user_id);
  perform pg_temp.expect_v123_error(format(
    $q$select public.create_service_bundle_v123(
      %L,'Edited bundle',12900,array[%L::uuid,%L::uuid],'bundle-attempt-1')$q$,
    f.business_id,f.service_a,f.service_b
  ),'22023','same key with edited bundle');
  perform pg_temp.expect_v123_error(format(
    $q$select public.create_service_bundle_v123(
      %L,'Cross tenant bundle',12900,array[%L::uuid,%L::uuid],'bundle-attempt-2')$q$,
    f.business_id,f.service_a,f.foreign_service
  ),'22023','cross-tenant bundle service');

  perform pg_temp.as_v123_user(f.readonly_user_id);
  perform pg_temp.expect_v123_error(format(
    $q$select public.create_service_bundle_v123(
      %L,'Read only bundle',12900,array[%L::uuid,%L::uuid],'bundle-attempt-3')$q$,
    f.business_id,f.service_a,f.service_b
  ),'42501','read-only services staff bundle write');
end
$acceptance$;

rollback;
