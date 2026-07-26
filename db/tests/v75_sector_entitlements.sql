-- Rollback-only v75 sector entitlement acceptance evidence.
-- Run after the canonical chain through v75 in a disposable database.
begin;

create or replace function pg_temp.as_v75_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub',p_uid,'role',p_role
  )::text, true);
end
$$;
grant execute on function pg_temp.as_v75_user(uuid,text) to public;

do $v75_test$
declare
  v_sa uuid := gen_random_uuid();
  v_owner uuid := gen_random_uuid();
  v_consultant_user uuid := gen_random_uuid();
  v_business uuid;
  v_bundle uuid;
  v_draft uuid;
  v_before_modules text[];
  v_after_modules text[];
  v_before_version bigint;
  v_result jsonb;
  v_count integer;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_sa,'authenticated','authenticated',
     'v75-sa-'||substr(v_sa::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
     'v75-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_consultant_user,'authenticated','authenticated',
     'v75-consultant-'||substr(v_consultant_user::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note)
  values(v_sa,'v75-sa-'||substr(v_sa::text,1,8)||'@example.test','v75 rollback fixture');

  perform pg_temp.as_v75_user(v_owner);
  v_result := public.create_business(
    'V75 sector fixture',
    'v75-sector-'||substr(v_owner::text,1,8),
    'retail',
    array['dashboard']
  )::jsonb;
  reset role;
  v_business := (v_result->>'id')::uuid;
  select assignment.bundle_version_id, business.enabled_modules
    into v_bundle, v_before_modules
    from public.business_sector_assignments assignment
    join public.businesses business on business.id=assignment.business_id
   where assignment.business_id=v_business;
  if v_bundle is null
     or v_before_modules = array['dashboard']::text[]
     or v_before_modules is distinct from (
       select bundle.modules from public.sector_bundle_versions bundle where bundle.id=v_bundle
     ) then
    raise exception 'server onboarding did not assign the published sector bundle';
  end if;

  begin
    perform pg_temp.as_v75_user(v_owner);
    perform public.set_business_modules(v_business,array['dashboard']);
    reset role;
    raise exception 'owner changed fixed sector modules';
  exception when insufficient_privilege then reset role;
  end;
  begin
    perform pg_temp.as_v75_user(v_owner);
    update public.businesses set industry='fnb' where id=v_business;
    reset role;
    raise exception 'owner changed fixed sector label';
  exception when insufficient_privilege then reset role;
  end;

  perform pg_temp.as_v75_user(v_sa);
  v_result := public.platform_upsert_consultant_v75(
    null,v_consultant_user,'V75 Consultant','junior',current_date,true
  );
  reset role;
  if v_result->'consultant'->>'user_id' <> v_consultant_user::text then
    raise exception 'super admin consultant upsert failed';
  end if;

  select count(*) into v_count from public.sector_bundle_versions where sector_key='retail';
  perform pg_temp.as_v75_user(v_sa);
  v_result := public.platform_create_sector_bundle_v75(
    'retail','V75 retail preview',array['inventory'],true
  );
  reset role;
  if (select count(*) from public.sector_bundle_versions where sector_key='retail') <> v_count then
    raise exception 'bundle create dry-run persisted a row';
  end if;

  perform pg_temp.as_v75_user(v_sa);
  v_result := public.platform_create_sector_bundle_v75(
    'retail','V75 retail candidate',array['inventory','reports'],false
  );
  reset role;
  v_draft := (v_result->>'bundle_version_id')::uuid;
  perform pg_temp.as_v75_user(v_sa);
  v_result := public.platform_publish_sector_bundle_v75(v_draft,true);
  reset role;
  if (select status from public.sector_bundle_versions where id=v_draft) <> 'draft' then
    raise exception 'bundle publish dry-run changed status';
  end if;
  perform pg_temp.as_v75_user(v_sa);
  perform public.platform_publish_sector_bundle_v75(v_draft,false);
  reset role;

  select version into v_before_version from public.business_sector_assignments
   where business_id=v_business;
  perform pg_temp.as_v75_user(v_sa);
  v_result := public.platform_assign_business_sector_v75(
    v_business,v_draft,v_before_version,true
  );
  reset role;
  if (select version from public.business_sector_assignments where business_id=v_business)
       <> v_before_version
     or (select enabled_modules from public.businesses where id=v_business)
       is distinct from v_before_modules then
    raise exception 'assignment dry-run changed the business';
  end if;

  perform pg_temp.as_v75_user(v_sa);
  v_result := public.platform_assign_business_sector_v75(
    v_business,v_draft,v_before_version,false
  );
  reset role;
  select enabled_modules into v_after_modules from public.businesses where id=v_business;
  if v_after_modules is distinct from
     app.resolve_sector_entitlement_v75(v_draft,'{}','{}') then
    raise exception 'published assignment did not synchronize effective modules';
  end if;
  if (select industry from public.businesses where id=v_business) <> 'retail' then
    raise exception 'published assignment did not synchronize the sector label';
  end if;

  select version into v_before_version from public.business_sector_assignments
   where business_id=v_business;
  select count(*) into v_count from public.business_sector_override_versions
   where business_id=v_business;
  perform pg_temp.as_v75_user(v_sa);
  perform public.platform_set_business_sector_override_v75(
    v_business,array['loyalty'],array['reports'],'V75 preview',v_before_version,true
  );
  reset role;
  if (select count(*) from public.business_sector_override_versions where business_id=v_business)
       <> v_count then
    raise exception 'override dry-run persisted a row';
  end if;
  perform pg_temp.as_v75_user(v_sa);
  v_result := public.platform_set_business_sector_override_v75(
    v_business,array['loyalty'],array['reports'],'V75 accepted exception',v_before_version,false
  );
  reset role;
  if (select enabled_modules from public.businesses where id=v_business)
       is distinct from app.resolve_sector_entitlement_v75(
         v_draft,array['loyalty'],array['reports']
       ) then
    raise exception 'sector override did not update effective modules';
  end if;

  begin
    perform pg_temp.as_v75_user(v_sa);
    update public.businesses set name='ILLEGAL SA TENANT WRITE' where id=v_business;
    reset role;
    raise exception 'super admin gained general tenant update authority';
  exception when insufficient_privilege then reset role;
  end;
end
$v75_test$;

rollback;
