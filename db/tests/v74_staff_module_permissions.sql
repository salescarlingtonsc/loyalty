-- Rollback-only v74 staff module-permission acceptance suite.
-- Run after the complete canonical chain through v74 in a disposable database.
begin;

create or replace function pg_temp.as_v74_user(
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
grant execute on function pg_temp.as_v74_user(uuid,text) to public;

do $v74_test$
declare
  v_owner uuid := gen_random_uuid();
  v_manager_user uuid := gen_random_uuid();
  v_frontdesk_user uuid := gen_random_uuid();
  v_bookkeeper_user uuid := gen_random_uuid();
  v_outside_owner uuid := gen_random_uuid();
  v_business uuid;
  v_foreign_business uuid;
  v_owner_staff uuid;
  v_manager_staff uuid;
  v_dependency_staff uuid;
  v_legacy_staff uuid;
  v_frontdesk_staff uuid;
  v_staff_staff uuid;
  v_bookkeeper_staff uuid;
  v_inactive_staff uuid;
  v_foreign_staff uuid;
  v_invalid_role_staff uuid;
  v_template uuid;
  v_result jsonb;
  v_modules text[];
  v_perms jsonb;
  v_audits integer;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
      'v74-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_manager_user,'authenticated','authenticated',
      'v74-manager-'||substr(v_manager_user::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_frontdesk_user,'authenticated','authenticated',
      'v74-frontdesk-'||substr(v_frontdesk_user::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_bookkeeper_user,'authenticated','authenticated',
      'v74-bookkeeper-'||substr(v_bookkeeper_user::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outside_owner,'authenticated','authenticated',
      'v74-outside-'||substr(v_outside_owner::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.businesses(name,slug,industry,enabled_modules)
  values (
    'V74 permission fixture',
    'v74-perms-'||substr(v_owner::text,1,8),
    'test',
    array['dashboard','clients','inventory','expenses','pnl','branches','bookings']
  ) returning id into v_business;
  insert into public.businesses(name,slug,industry,enabled_modules)
  values (
    'V74 foreign fixture',
    'v74-foreign-'||substr(v_owner::text,1,8),
    'test',
    array['dashboard','clients','expenses']
  ) returning id into v_foreign_business;

  insert into public.staff(
    business_id,user_id,role,full_name,active,modules,module_perms
  ) values
    (v_business,v_owner,'owner','V74 Owner',true,null,null)
    returning id into v_owner_staff;
  insert into public.staff(
    business_id,user_id,role,full_name,active,modules,module_perms
  ) values
    (v_business,v_manager_user,'manager','V74 Manager',true,null,null)
    returning id into v_manager_staff;
  insert into public.staff(
    business_id,role,full_name,active,modules,module_perms
  ) values
    (v_business,'manager','V74 Dependency Manager',true,null,null)
    returning id into v_dependency_staff;
  insert into public.staff(
    business_id,role,full_name,active,modules,module_perms
  ) values
    (v_business,'manager','V74 Legacy Wrapper Manager',true,null,null)
    returning id into v_legacy_staff;
  insert into public.staff(
    business_id,user_id,role,full_name,active,modules,module_perms
  ) values
    (v_business,v_frontdesk_user,'frontdesk','V74 Front desk',true,null,null)
    returning id into v_frontdesk_staff;
  insert into public.staff(
    business_id,role,full_name,active,modules,module_perms
  ) values
    (v_business,'staff','V74 Staff',true,null,null)
    returning id into v_staff_staff;
  insert into public.staff(
    business_id,user_id,role,full_name,active,modules,module_perms
  ) values
    (v_business,v_bookkeeper_user,'bookkeeper','V74 Bookkeeper',true,null,null)
    returning id into v_bookkeeper_staff;
  insert into public.staff(
    business_id,role,full_name,active,modules,module_perms
  ) values
    (v_business,'staff','V74 Inactive',false,null,null)
    returning id into v_inactive_staff;
  insert into public.staff(
    business_id,user_id,role,full_name,active,modules,module_perms
  ) values
    (v_foreign_business,v_outside_owner,'owner','V74 Foreign Owner',true,null,null);
  insert into public.staff(
    business_id,role,full_name,active,modules,module_perms
  ) values
    (v_foreign_business,'manager','V74 Foreign Target',true,null,null)
    returning id into v_foreign_staff;

  -- Only required dependencies are expanded. Missing modes become r while an
  -- explicit dependency mode remains authoritative; recommendations do not leak in.
  perform pg_temp.as_v74_user(v_owner);
  v_result := public.set_staff_module_permissions_v74(
    v_dependency_staff,
    '{"bookings":"rw","appointments":"rw"}'::jsonb
  );
  reset role;
  if v_result->'module_perms'
       <> '{"appointments":"rw","bookings":"rw","clients":"r","services":"r"}'::jsonb
     or v_result->'modules'
       <> '["appointments","bookings","clients","services"]'::jsonb
     or v_result->'module_perms' ? 'waitlist'
     or v_result->'module_perms' ? 'branches' then
    raise exception 'required module closure did not add only required read dependencies';
  end if;

  -- The legacy signature is a compatibility adapter, not a second writer. It
  -- maps every listed module to rw, delegates dependency resolution, returns a
  -- staff-shaped row and emits only the delegated v74 audit.
  perform pg_temp.as_v74_user(v_owner);
  v_result := public.set_staff_modules(
    v_legacy_staff, array['bookings','appointments']
  )::jsonb;
  reset role;
  if v_result->'module_perms'
       <> '{"appointments":"rw","bookings":"rw","clients":"r","services":"r"}'::jsonb
     or v_result->'modules'
       <> '["appointments","bookings","clients","services"]'::jsonb then
    raise exception 'legacy module wrapper did not delegate resolved coherent permissions';
  end if;
  select count(*) into v_audits
    from public.audit_log audit
   where audit.business_id = v_business
     and audit.entity_id = v_legacy_staff
     and audit.action = 'STAFF_MODULE_PERMISSIONS_SET_V74';
  if v_audits <> 1 or exists (
    select 1 from public.audit_log audit
     where audit.business_id = v_business
       and audit.entity_id = v_legacy_staff
       and audit.action = 'STAFF_MODULES_SET'
  ) then
    raise exception 'legacy module wrapper emitted a second assignment audit';
  end if;

  insert into public.module_templates(business_id,name,modules)
  values (v_business,'V74 compatibility template',array['inventory'])
  returning id into v_template;
  perform pg_temp.as_v74_user(v_owner);
  v_result := public.apply_module_template(v_legacy_staff,v_template)::jsonb;
  reset role;
  if v_result->'module_perms' <> '{"inventory":"rw"}'::jsonb
     or v_result->'modules' <> '["inventory"]'::jsonb then
    raise exception 'apply_module_template did not remain functional through v74 wrapper';
  end if;
  select count(*) into v_audits
    from public.audit_log audit
   where audit.business_id = v_business
     and audit.entity_id = v_legacy_staff
     and audit.action = 'STAFF_MODULE_PERMISSIONS_SET_V74';
  if v_audits <> 2 then
    raise exception 'template compatibility call did not emit exactly one delegated v74 audit';
  end if;

  perform pg_temp.as_v74_user(v_owner);
  v_result := public.set_staff_modules(v_legacy_staff,null)::jsonb;
  reset role;
  if v_result->'module_perms' <> 'null'::jsonb
     or v_result->'modules' <> 'null'::jsonb
     or exists (
       select 1 from public.staff
        where id=v_legacy_staff
          and (module_perms is not null or modules is not null)
     ) then
    raise exception 'legacy NULL module wrapper did not restore coherent inheritance';
  end if;

  -- Owner assignment stores exact modes, mirrors sorted keys to legacy modules,
  -- and emits exactly one audit containing prior/new permission truth.
  perform pg_temp.as_v74_user(v_owner);
  v_result := public.set_staff_module_permissions_v74(
    v_manager_staff,
    '{"inventory":"rw","expenses":"r","clients":"r"}'::jsonb
  );
  reset role;
  select module_perms, modules into v_perms, v_modules
    from public.staff where id = v_manager_staff;
  if v_perms <> '{"clients":"r","expenses":"r","inventory":"rw"}'::jsonb
     or v_modules <> array['clients','expenses','inventory']::text[]
     or v_result->'module_perms' <> v_perms
     or v_result->'modules' <> to_jsonb(v_modules) then
    raise exception 'valid assignment did not preserve modes and sorted legacy keys';
  end if;
  select count(*) into v_audits
    from public.audit_log audit
   where audit.business_id = v_business
     and audit.action = 'STAFF_MODULE_PERMISSIONS_SET_V74'
     and audit.entity_id = v_manager_staff;
  if v_audits <> 1 or not exists (
    select 1
      from public.audit_log audit
     where audit.business_id = v_business
       and audit.action = 'STAFF_MODULE_PERMISSIONS_SET_V74'
       and audit.entity_id = v_manager_staff
       and audit.detail->'prior_module_perms' = 'null'::jsonb
       and audit.detail->'new_module_perms'
           = '{"clients":"r","expenses":"r","inventory":"rw"}'::jsonb
  ) then
    raise exception 'valid assignment did not emit exactly one prior/new audit';
  end if;

  -- SQL NULL restores current legacy inheritance and keeps both columns coherent.
  perform pg_temp.as_v74_user(v_owner);
  perform public.set_staff_module_permissions_v74(v_manager_staff, null);
  reset role;
  if exists (
    select 1 from public.staff
     where id = v_manager_staff
       and (module_perms is not null or modules is not null)
  ) then
    raise exception 'NULL assignment did not restore coherent inheritance';
  end if;

  -- A non-owner, foreign target, stale target and owner target all fail closed.
  begin
    perform pg_temp.as_v74_user(v_manager_user);
    perform public.set_staff_module_permissions_v74(
      v_frontdesk_staff, '{"clients":"r"}'::jsonb
    );
    reset role;
    raise exception 'non-owner assigned staff modules';
  exception when insufficient_privilege then
    reset role;
  end;
  begin
    perform pg_temp.as_v74_user(v_owner);
    perform public.set_staff_module_permissions_v74(
      v_foreign_staff, '{"clients":"r"}'::jsonb
    );
    reset role;
    raise exception 'owner assigned modules to foreign staff';
  exception when sqlstate '22023' then
    reset role;
  end;
  begin
    perform pg_temp.as_v74_user(v_owner);
    perform public.set_staff_module_permissions_v74(
      v_inactive_staff, '{"clients":"r"}'::jsonb
    );
    reset role;
    raise exception 'owner assigned modules to stale inactive staff';
  exception when sqlstate '22023' then
    reset role;
  end;
  begin
    perform pg_temp.as_v74_user(v_owner);
    perform public.set_staff_module_permissions_v74(
      v_owner_staff, '{"clients":"r"}'::jsonb
    );
    reset role;
    raise exception 'owner module restrictions were accepted';
  exception when sqlstate '22023' then
    reset role;
  end;

  -- Shape, mode, disabled, unknown and owner-only keys are rejected atomically.
  begin
    perform pg_temp.as_v74_user(v_owner);
    perform public.set_staff_module_permissions_v74(v_manager_staff, '[]'::jsonb);
    reset role;
    raise exception 'array module permissions were accepted';
  exception when sqlstate '22023' then
    reset role;
  end;
  begin
    perform pg_temp.as_v74_user(v_owner);
    perform public.set_staff_module_permissions_v74(
      v_manager_staff, '{"clients":"write"}'::jsonb
    );
    reset role;
    raise exception 'invalid text permission value was accepted';
  exception when sqlstate '22023' then
    reset role;
  end;
  begin
    perform pg_temp.as_v74_user(v_owner);
    perform public.set_staff_module_permissions_v74(
      v_manager_staff, '{"clients":true}'::jsonb
    );
    reset role;
    raise exception 'non-string permission value was accepted';
  exception when sqlstate '22023' then
    reset role;
  end;
  begin
    perform pg_temp.as_v74_user(v_owner);
    perform public.set_staff_module_permissions_v74(
      v_manager_staff, '{"retention":"r"}'::jsonb
    );
    reset role;
    raise exception 'disabled module key was accepted';
  exception when sqlstate '22023' then
    reset role;
  end;
  begin
    perform pg_temp.as_v74_user(v_owner);
    perform public.set_staff_module_permissions_v74(
      v_manager_staff, '{"not_a_module":"r"}'::jsonb
    );
    reset role;
    raise exception 'unknown module key was accepted';
  exception when sqlstate '22023' then
    reset role;
  end;
  foreach v_perms in array array[
    '{"branches":"r"}'::jsonb,
    '{"settings":"r"}'::jsonb,
    '{"setup":"r"}'::jsonb
  ] loop
    begin
      perform pg_temp.as_v74_user(v_owner);
      perform public.set_staff_module_permissions_v74(v_manager_staff, v_perms);
      reset role;
      raise exception 'owner-only or unusable module key was accepted: %', v_perms;
    exception when sqlstate '22023' then
      reset role;
    end;
  end loop;

  -- Expenses/P&L follow app.role_perms: manager/bookkeeper yes, staff/frontdesk no.
  perform pg_temp.as_v74_user(v_owner);
  perform public.set_staff_module_permissions_v74(
    v_bookkeeper_staff, '{"pnl":"r"}'::jsonb
  );
  reset role;
  foreach v_invalid_role_staff in array array[v_frontdesk_staff, v_staff_staff] loop
    begin
      perform pg_temp.as_v74_user(v_owner);
      perform public.set_staff_module_permissions_v74(
        v_invalid_role_staff, '{"expenses":"r"}'::jsonb
      );
      reset role;
      raise exception 'finance-ineligible role received expenses';
    exception when sqlstate '22023' then
      reset role;
    end;
  end loop;
  foreach v_invalid_role_staff in array array[v_frontdesk_staff, v_staff_staff] loop
    begin
      perform pg_temp.as_v74_user(v_owner);
      perform public.set_staff_module_permissions_v74(
        v_invalid_role_staff, '{"pnl":"r"}'::jsonb
      );
      reset role;
      raise exception 'finance-ineligible role received pnl';
    exception when sqlstate '22023' then
      reset role;
    end;
  end loop;

  -- Effective resolution closes legacy inherited owner-only/finance leakage but
  -- leaves Dashboard available through the existing app-level behavior.
  perform pg_temp.as_v74_user(v_frontdesk_user);
  v_result := public.get_my_modules(v_business)::jsonb;
  reset role;
  if v_result->'module_perms' ? 'expenses'
     or v_result->'module_perms' ? 'pnl'
     or v_result->'module_perms' ? 'branches'
     or v_result->'module_perms' ? 'settings'
     or v_result->'module_perms' ? 'setup'
     or not (v_result->'module_perms' ? 'dashboard') then
    raise exception 'effective resolver exposed unusable inherited modules: %', v_result;
  end if;

  -- Downgrading an explicit finance-capable assignment strips Expenses/P&L from
  -- both columns in the same transaction and writes one prior/new role audit.
  perform pg_temp.as_v74_user(v_owner);
  perform public.set_staff_module_permissions_v74(
    v_manager_staff,
    '{"expenses":"rw","pnl":"rw","inventory":"rw","clients":"r"}'::jsonb
  );
  v_result := public.set_staff_role_v74(v_manager_staff, 'frontdesk');
  reset role;
  select module_perms, modules into v_perms, v_modules
    from public.staff where id = v_manager_staff;
  if v_result->>'role' <> 'frontdesk'
     or v_perms <> '{"clients":"r","inventory":"rw","sales":"r"}'::jsonb
     or v_modules <> array['clients','inventory','sales']::text[] then
    raise exception 'finance downgrade retained explicit expenses or pnl';
  end if;
  select count(*) into v_audits
    from public.audit_log audit
   where audit.business_id = v_business
     and audit.action = 'STAFF_ROLE_SET_V74'
     and audit.entity_id = v_manager_staff;
  if v_audits <> 1 or not exists (
    select 1 from public.audit_log audit
     where audit.business_id = v_business
       and audit.action = 'STAFF_ROLE_SET_V74'
       and audit.entity_id = v_manager_staff
       and audit.detail->>'prior_role' = 'manager'
       and audit.detail->>'new_role' = 'frontdesk'
       and audit.detail->'prior_module_perms'
           = '{"clients":"r","expenses":"rw","inventory":"rw","pnl":"rw","sales":"r"}'::jsonb
       and audit.detail->'new_module_perms'
           = '{"clients":"r","inventory":"rw","sales":"r"}'::jsonb
  ) then
    raise exception 'role change did not emit exactly one prior/new role/perms audit';
  end if;

  -- NULL inheritance stays NULL through a downgrade; resolver filtering supplies
  -- the role-sensitive effective behavior rather than freezing a module snapshot.
  perform pg_temp.as_v74_user(v_owner);
  perform public.set_staff_role_v74(v_manager_staff, 'manager');
  perform public.set_staff_module_permissions_v74(v_manager_staff, null);
  perform public.set_staff_role_v74(v_manager_staff, 'frontdesk');
  reset role;
  if exists (
    select 1 from public.staff
     where id = v_manager_staff
       and (module_perms is not null or modules is not null)
  ) then
    raise exception 'role downgrade froze NULL inheritance';
  end if;

  -- A legacy explicit modules list is preserved except for the ineligible key.
  update public.staff
     set role = 'manager',
         module_perms = null,
         modules = array['inventory','expenses','pnl']
   where id = v_manager_staff;
  perform pg_temp.as_v74_user(v_owner);
  perform public.set_staff_role_v74(v_manager_staff, 'staff');
  reset role;
  if not exists (
    select 1 from public.staff
     where id = v_manager_staff
       and module_perms is null
       and modules = array['inventory']::text[]
  ) then
    raise exception 'role downgrade did not strip legacy explicit expenses or pnl';
  end if;

  -- Invalid requested roles and invalid stored target roles fail closed.
  begin
    perform pg_temp.as_v74_user(v_owner);
    perform public.set_staff_role_v74(v_frontdesk_staff, 'owner');
    reset role;
    raise exception 'owner role assignment was accepted';
  exception when sqlstate '22023' then
    reset role;
  end;
  begin
    perform pg_temp.as_v74_user(v_owner);
    perform public.set_staff_role_v74(v_frontdesk_staff, 'stylist');
    reset role;
    raise exception 'non-canonical requested role was accepted';
  exception when sqlstate '22023' then
    reset role;
  end;
  alter table public.staff drop constraint staff_role_check;
  insert into public.staff(
    business_id,role,full_name,active,modules,module_perms
  ) values (
    v_business,'legacy_unknown','V74 Invalid Stored Role',true,null,null
  ) returning id into v_invalid_role_staff;
  begin
    perform pg_temp.as_v74_user(v_owner);
    perform public.set_staff_module_permissions_v74(
      v_invalid_role_staff, '{"clients":"r"}'::jsonb
    );
    reset role;
    raise exception 'invalid stored target role received modules';
  exception when sqlstate '22023' then
    reset role;
  end;
  begin
    perform pg_temp.as_v74_user(v_owner);
    perform public.set_staff_role_v74(v_invalid_role_staff, 'staff');
    reset role;
    raise exception 'invalid stored target role was rewritten';
  exception when sqlstate '22023' then
    reset role;
  end;

  if has_function_privilege(
       'anon',
       'public.set_staff_module_permissions_v74(uuid,jsonb)',
       'execute'
     ) or not has_function_privilege(
       'authenticated',
       'public.set_staff_module_permissions_v74(uuid,jsonb)',
       'execute'
     ) or has_function_privilege(
       'anon',
       'public.set_staff_modules(uuid,text[])',
       'execute'
     ) or not has_function_privilege(
       'authenticated',
       'public.set_staff_modules(uuid,text[])',
       'execute'
     ) or has_function_privilege(
       'anon',
       'public.set_staff_role_v74(uuid,text)',
       'execute'
     ) or not has_function_privilege(
       'authenticated',
       'public.set_staff_role_v74(uuid,text)',
       'execute'
     ) then
    raise exception 'v74 staff permission RPC ACL drifted';
  end if;

  raise notice 'v74 staff module-permission suite: ALL PASS';
end
$v74_test$;

rollback;
