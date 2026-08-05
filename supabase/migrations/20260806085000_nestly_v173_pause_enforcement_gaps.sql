-- v173: close the four remaining day-14 pause enforcement gaps at the DB layer.
--
-- Context: v94 already wires app.business_workspace_open_v94 into the core RLS
-- helpers (is_salon_member / is_salon_owner / has_perm / can_see_branch /
-- staff_module_mode_v94), so a paused firm's staff lose table access through
-- every policy routed via those helpers. A full sweep of deployed pg_policies
-- and SECURITY DEFINER writers (2026-08-06) found exactly four paths that
-- bypass the gate; this migration closes them. Customer identity/preference
-- paths, self-serve signup, invite acceptance, and account deletion remain
-- deliberately exempt (they must work while a firm is paused).

begin;

-- ---------------------------------------------------------------------------
-- 1. Shared guard: raise a uniform, client-recognisable error when the
--    workspace is not open (unapproved or billing-paused).
-- ---------------------------------------------------------------------------
create or replace function app.require_workspace_open_v173(p_business uuid)
returns void
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.business_workspace_open_v94(p_business) then
    raise exception 'workspace_paused' using errcode='42501',
      hint='The workspace is paused until billing is settled.';
  end if;
end
$$;
revoke all on function app.require_workspace_open_v173(uuid)
  from public,anon,authenticated;

-- ---------------------------------------------------------------------------
-- 2. can_sell_topups: the owner branch was already gated via is_salon_owner,
--    but the manager / module_perms branch bypassed the pause. Gate it.
-- ---------------------------------------------------------------------------
create or replace function app.can_sell_topups(p_business uuid)
returns boolean language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select app.is_salon_owner(p_business)
    or (app.business_workspace_open_v94(p_business)
        and exists (select 1 from public.staff s
            where s.business_id = p_business and s.user_id = auth.uid() and s.active
              and (s.role = 'manager' or coalesce((s.module_perms->>'sell_topups')::boolean, false))))
$$;

-- ---------------------------------------------------------------------------
-- 3. adjust_points: owner-only manual points adjustment lacked the pause gate.
--    Redefinition is the deployed body plus the guard after the owner check
--    (authorization errors keep precedence over the pause error).
-- ---------------------------------------------------------------------------
create or replace function public.adjust_points(
  p_business uuid, p_client uuid, p_points integer, p_reason text
)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_balance integer;
  v_batch_balance integer;
  v_remaining integer;
  v_take integer;
  v_points_id uuid := gen_random_uuid();
  v_expiry timestamptz;
  v_batch record;
  lp public.loyalty_programs%rowtype;
begin
  if coalesce(p_points, 0) = 0 then
    raise exception 'points adjustment must be non-zero';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 3 then
    raise exception 'points adjustment reason must be at least 3 characters';
  end if;

  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and s.role = 'owner'
   order by s.created_at
   limit 1
   for update;
  if not found then
    raise exception 'only an active owner may adjust points'
      using errcode = '42501';
  end if;

  perform app.require_workspace_open_v173(p_business);

  perform 1 from public.clients c
   where c.id = p_client and c.business_id = p_business
   for update;
  if not found then
    raise exception 'client does not belong to this business';
  end if;

  select coalesce(sum(pl.points), 0)::integer into v_balance
    from public.points_ledger pl
   where pl.business_id = p_business and pl.client_id = p_client;
  if p_points < 0 and v_balance + p_points < 0 then
    raise exception 'points adjustment would overdraw balance % by %', v_balance, -p_points;
  end if;

  if p_points < 0 then
    select coalesce(sum(pb.remaining), 0)::integer into v_batch_balance
      from public.points_batches pb
     where pb.business_id = p_business
       and pb.client_id = p_client
       and pb.remaining > 0;
    if v_batch_balance < -p_points then
      raise exception 'points batches % cannot prove negative adjustment %',
        v_batch_balance, -p_points
        using errcode = 'check_violation';
    end if;

    v_remaining := -p_points;
    for v_batch in
      select pb.id, pb.remaining
        from public.points_batches pb
       where pb.business_id = p_business
         and pb.client_id = p_client
         and pb.remaining > 0
       order by pb.expires_at nulls last, pb.earned_at, pb.id
       for update
    loop
      exit when v_remaining = 0;
      v_take := least(v_batch.remaining, v_remaining);
      update public.points_batches
         set remaining = remaining - v_take
       where id = v_batch.id;
      v_remaining := v_remaining - v_take;
    end loop;
  else
    select * into lp
      from public.loyalty_programs
     where business_id = p_business
       and active
       and kind = 'points'
     limit 1;
    v_expiry := case
      when found and lp.expiry_mode = 'fixed' and coalesce(lp.expiry_days, 0) > 0
        then now() + make_interval(days => lp.expiry_days)
      else null
    end;
    insert into public.points_batches (
      business_id, client_id, earned, remaining, earned_at, expires_at
    ) values (
      p_business, p_client, p_points, p_points, now(), v_expiry
    );
  end if;

  perform set_config('app.points_ledger_insert_id', v_points_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
  insert into public.points_ledger (
    id, business_id, client_id, entry_type, points, reference, actor
  ) values (
    v_points_id, p_business, p_client, 'adjust', p_points, btrim(p_reason), v_actor
  );
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);

  return v_balance + p_points;
end $function$;
revoke all on function public.adjust_points(uuid,uuid,integer,text) from public,anon;
grant execute on function public.adjust_points(uuid,uuid,integer,text)
  to authenticated,service_role;

-- ---------------------------------------------------------------------------
-- 4. set_staff_role_v74 / set_staff_module_permissions_v74: staff
--    administration by the owner of a paused firm was still possible. Add the
--    guard once the target business is resolved. Bodies are the deployed
--    definitions plus the single guard line each.
-- ---------------------------------------------------------------------------
create or replace function public.set_staff_role_v74(p_staff uuid, p_role text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
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

  perform app.require_workspace_open_v173(v_target.business_id);

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
$function$;
revoke all on function public.set_staff_role_v74(uuid,text) from public,anon;
grant execute on function public.set_staff_role_v74(uuid,text)
  to authenticated,service_role;

create or replace function public.set_staff_module_permissions_v74(
  p_staff uuid, p_module_perms jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
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

  perform app.require_workspace_open_v173(v_target.business_id);

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
$function$;
revoke all on function public.set_staff_module_permissions_v74(uuid,jsonb) from public,anon;
grant execute on function public.set_staff_module_permissions_v74(uuid,jsonb)
  to authenticated,service_role;

commit;
