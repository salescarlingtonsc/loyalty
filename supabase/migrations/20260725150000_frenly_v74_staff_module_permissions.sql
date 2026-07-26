-- FRENLY v74 - OWNER-CONTROLLED STAFF MODULE PERMISSIONS
--
-- Local forward-only review candidate. This increment creates the only browser
-- write boundary for per-staff module modes and role changes. It does not grant
-- direct UPDATE on staff, change RLS, or broaden any role.

begin;

-- Effective discovery must not advertise configuration routes that non-owners
-- cannot use. Expenses is additionally filtered by the canonical role permission
-- truth, including for legacy NULL-inherit rows.
create or replace function app.staff_module_perms(p_business uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce(jsonb_object_agg(e.module_name, e.access_mode), '{}'::jsonb)
    from (
      select module_name,
             case when s.role = 'owner' or s.module_perms is null
                  then 'rw' else s.module_perms ->> module_name end as access_mode
        from public.staff s
        join public.businesses b on b.id = s.business_id
        cross join lateral unnest(b.enabled_modules) as enabled(module_name)
       where s.business_id = p_business
         and s.user_id = auth.uid()
         and s.active
         and (
           s.role = 'owner'
           or (s.module_perms is not null and s.module_perms ? module_name)
           or (s.module_perms is null and (s.modules is null or module_name = any(s.modules)))
         )
         and (
           s.role = 'owner'
           or module_name not in ('branches', 'settings', 'setup')
         )
         and (
           module_name not in ('expenses', 'pnl')
           or 'view_finance' = any(app.role_perms(s.role))
         )
    ) e
$$;

revoke all privileges on function app.staff_module_perms(uuid)
  from public, anon, authenticated;

create or replace function public.set_staff_module_permissions_v74(
  p_staff uuid,
  p_module_perms jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_target public.staff%rowtype;
  v_enabled_modules text[];
  v_new_modules text[];
  v_permission_closure text[];
  v_resolved_perms jsonb;
  v_invalid_keys text[];
  v_invalid_values text[];
begin
  if v_actor is null then
    raise exception 'authenticated owner session is required'
      using errcode = '42501';
  end if;
  if p_staff is null then
    raise exception 'staff member is required' using errcode = '22023';
  end if;
  if not exists (
    select 1
      from public.staff actor_staff
     where actor_staff.user_id = v_actor
       and actor_staff.role = 'owner'
       and actor_staff.active
  ) then
    raise exception 'owner role is required' using errcode = '42501';
  end if;

  select target.* into v_target
    from public.staff target
   where target.id = p_staff
     and target.active
     and exists (
       select 1
         from public.staff owner_staff
        where owner_staff.business_id = target.business_id
          and owner_staff.user_id = v_actor
          and owner_staff.role = 'owner'
          and owner_staff.active
     )
   for update;
  if not found then
    raise exception 'active staff member was not found in an owned business'
      using errcode = '22023';
  end if;
  if v_target.role = 'owner' then
    raise exception 'the owner cannot be module-restricted'
      using errcode = '22023';
  end if;
  if v_target.role not in ('manager', 'staff', 'frontdesk', 'bookkeeper') then
    raise exception 'target staff role is invalid' using errcode = '22023';
  end if;

  select business.enabled_modules into v_enabled_modules
    from public.businesses business
   where business.id = v_target.business_id
   for share;
  if not found then
    raise exception 'staff business was not found' using errcode = '22023';
  end if;

  if p_module_perms is not null then
    if jsonb_typeof(p_module_perms) <> 'object' then
      raise exception 'module permissions must be an object or SQL NULL'
        using errcode = '22023';
    end if;

    select array_agg(entry.key order by entry.key)
      into v_invalid_values
      from jsonb_each(p_module_perms) entry
     where jsonb_typeof(entry.value) <> 'string'
        or entry.value #>> '{}' not in ('r', 'rw');
    if coalesce(cardinality(v_invalid_values), 0) > 0 then
      raise exception 'module permission values must be r or rw: %',
        array_to_string(v_invalid_values, ', ')
        using errcode = '22023';
    end if;

    select array_agg(key_row.module_key order by key_row.module_key)
      into v_invalid_keys
      from jsonb_object_keys(p_module_perms) key_row(module_key)
      left join public.module_registry registry
        on registry.module_key = key_row.module_key
     where registry.module_key is null
        or not (key_row.module_key = any(coalesce(v_enabled_modules, '{}'::text[])))
        or key_row.module_key in ('branches', 'settings', 'setup');
    if coalesce(cardinality(v_invalid_keys), 0) > 0 then
      raise exception 'module keys are not currently enabled and assignable: %',
        array_to_string(v_invalid_keys, ', ')
        using errcode = '22023';
    end if;

    -- Resolve required (not recommended) dependencies. Missing dependencies
    -- receive read access; an explicitly requested rw mode always wins.
    with recursive permission_closure(module_key) as (
      select requested.module_key
        from jsonb_object_keys(p_module_perms) requested(module_key)
      union
      select dependency.module_key
        from permission_closure current_key
        join public.module_registry registry
          on registry.module_key = current_key.module_key
        cross join lateral unnest(registry.requires_modules) dependency(module_key)
    )
    select coalesce(
      array_agg(permission_closure.module_key order by permission_closure.module_key),
      '{}'::text[]
    ) into v_permission_closure
      from permission_closure;

    select array_agg(module_key order by module_key)
      into v_invalid_keys
      from unnest(v_permission_closure) module_key
     where not (module_key = any(coalesce(v_enabled_modules, '{}'::text[])))
        or module_key in ('branches', 'settings', 'setup');
    if coalesce(cardinality(v_invalid_keys), 0) > 0 then
      raise exception 'required module dependencies are not currently enabled and assignable: %',
        array_to_string(v_invalid_keys, ', ')
        using errcode = '22023';
    end if;

    if (
         'expenses' = any(v_permission_closure)
         or 'pnl' = any(v_permission_closure)
       )
       and not ('view_finance' = any(app.role_perms(v_target.role))) then
      raise exception 'expenses and pnl require a finance-capable staff role'
        using errcode = '22023';
    end if;

    select coalesce(
      jsonb_object_agg(
        module_key,
        coalesce(p_module_perms ->> module_key, 'r')
      ),
      '{}'::jsonb
    ) into v_resolved_perms
      from unnest(v_permission_closure) module_key;
    v_new_modules := v_permission_closure;
  else
    -- SQL NULL restores the legacy all-enabled inheritance contract.
    v_resolved_perms := null;
    v_new_modules := null;
  end if;

  update public.staff
     set module_perms = v_resolved_perms,
         modules = v_new_modules
   where id = v_target.id
     and business_id = v_target.business_id;

  insert into public.audit_log(
    business_id, actor, action, entity, entity_id, detail
  ) values (
    v_target.business_id, v_actor, 'STAFF_MODULE_PERMISSIONS_SET_V74',
    'staff', v_target.id,
    jsonb_build_object(
      'prior_module_perms', v_target.module_perms,
      'new_module_perms', v_resolved_perms,
      'prior_modules', to_jsonb(v_target.modules),
      'new_modules', to_jsonb(v_new_modules)
    )
  );

  return jsonb_build_object(
    'staff_id', v_target.id,
    'module_perms', v_resolved_perms,
    'modules', to_jsonb(v_new_modules)
  );
end
$$;

-- Preserve the v14b browser/template signature without preserving its split-brain
-- write. The v74 RPC remains the only mutation/audit authority: NULL inherits;
-- a legacy text allowlist becomes an all-rw permission object and is then resolved
-- through the same dependency, tenancy, role and module validation. Returning the
-- staff row keeps legacy callers practical, while the delegated v74 call emits the
-- one and only assignment audit.
create or replace function public.set_staff_modules(
  p_staff uuid,
  p_modules text[]
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_module_perms jsonb;
  v_staff public.staff%rowtype;
begin
  if p_modules is null then
    v_module_perms := null;
  else
    if array_position(p_modules, null) is not null then
      raise exception 'legacy module list cannot contain NULL'
        using errcode = '22023';
    end if;
    select coalesce(
      jsonb_object_agg(module_name, 'rw'::text order by module_name),
      '{}'::jsonb
    ) into v_module_perms
      from (
        select distinct requested_module as module_name
          from unnest(p_modules) requested_module
      ) requested;
  end if;

  perform public.set_staff_module_permissions_v74(p_staff, v_module_perms);
  select staff_row.* into strict v_staff
    from public.staff staff_row
   where staff_row.id = p_staff;
  return row_to_json(v_staff);
end
$$;

create or replace function public.set_staff_role_v74(
  p_staff uuid,
  p_role text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_target public.staff%rowtype;
  v_new_module_perms jsonb;
  v_new_modules text[];
begin
  if v_actor is null then
    raise exception 'authenticated owner session is required'
      using errcode = '42501';
  end if;
  if p_staff is null then
    raise exception 'staff member is required' using errcode = '22023';
  end if;
  if p_role is null
     or p_role not in ('manager', 'staff', 'frontdesk', 'bookkeeper') then
    raise exception 'staff role must be manager, staff, frontdesk, or bookkeeper'
      using errcode = '22023';
  end if;
  if not exists (
    select 1
      from public.staff actor_staff
     where actor_staff.user_id = v_actor
       and actor_staff.role = 'owner'
       and actor_staff.active
  ) then
    raise exception 'owner role is required' using errcode = '42501';
  end if;

  select target.* into v_target
    from public.staff target
   where target.id = p_staff
     and target.active
     and exists (
       select 1
         from public.staff owner_staff
        where owner_staff.business_id = target.business_id
          and owner_staff.user_id = v_actor
          and owner_staff.role = 'owner'
          and owner_staff.active
     )
   for update;
  if not found then
    raise exception 'active staff member was not found in an owned business'
      using errcode = '22023';
  end if;
  if v_target.role = 'owner' then
    raise exception 'the owner role cannot be changed here'
      using errcode = '22023';
  end if;
  if v_target.role not in ('manager', 'staff', 'frontdesk', 'bookkeeper') then
    raise exception 'target staff role is invalid' using errcode = '22023';
  end if;

  v_new_module_perms := v_target.module_perms;
  v_new_modules := v_target.modules;
  if not ('view_finance' = any(app.role_perms(p_role))) then
    if v_new_module_perms is not null then
      v_new_module_perms := v_new_module_perms - 'expenses' - 'pnl';
      select coalesce(array_agg(key_row.module_key order by key_row.module_key), '{}'::text[])
        into v_new_modules
        from jsonb_object_keys(v_new_module_perms) key_row(module_key);
    elsif v_new_modules is not null then
      select coalesce(array_agg(module_name order by module_name), '{}'::text[])
        into v_new_modules
        from unnest(v_new_modules) module_name
       where module_name not in ('expenses', 'pnl');
    end if;
  end if;

  update public.staff
     set role = p_role,
         module_perms = v_new_module_perms,
         modules = v_new_modules
   where id = v_target.id
     and business_id = v_target.business_id;

  insert into public.audit_log(
    business_id, actor, action, entity, entity_id, detail
  ) values (
    v_target.business_id, v_actor, 'STAFF_ROLE_SET_V74',
    'staff', v_target.id,
    jsonb_build_object(
      'prior_role', v_target.role,
      'new_role', p_role,
      'prior_module_perms', v_target.module_perms,
      'new_module_perms', v_new_module_perms,
      'prior_modules', to_jsonb(v_target.modules),
      'new_modules', to_jsonb(v_new_modules)
    )
  );

  return jsonb_build_object(
    'staff_id', v_target.id,
    'role', p_role,
    'module_perms', v_new_module_perms,
    'modules', to_jsonb(v_new_modules)
  );
end
$$;

revoke all on function public.set_staff_module_permissions_v74(uuid,jsonb)
  from public, anon, authenticated;
grant execute on function public.set_staff_module_permissions_v74(uuid,jsonb)
  to authenticated;
revoke all on function public.set_staff_modules(uuid,text[])
  from public, anon, authenticated;
grant execute on function public.set_staff_modules(uuid,text[])
  to authenticated;
revoke all on function public.set_staff_role_v74(uuid,text)
  from public, anon, authenticated;
grant execute on function public.set_staff_role_v74(uuid,text)
  to authenticated;

do $v74_catalog_gate$
begin
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
end
$v74_catalog_gate$;

commit;
