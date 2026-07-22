-- Rollback-only v24b module dependency and authorization suite.
begin;
\ir fixtures/pristine_chain_fixture.psql

do $v24b_test$
declare
  v_business uuid;
  v_owner uuid;
  v_result json;
  v_modules text[];
begin
  select business_id, user_id into v_business, v_owner
    from public.staff
   where role = 'owner' and active and user_id is not null
   order by created_at limit 1;
  if v_business is null then
    raise exception 'v24b suite requires an active owner';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  v_result := public.set_business_modules(v_business, array['bookings']);
  v_modules := array(select json_array_elements_text(v_result->'modules'));
  if not (v_modules @> array['dashboard','bookings','appointments','clients','services']) then
    raise exception 'bookings dependency closure is incomplete: %', v_modules;
  end if;

  update public.businesses set enabled_modules = array['till'] where id = v_business;
  select enabled_modules into v_modules from public.businesses where id = v_business;
  if not (v_modules @> array['dashboard','till','clients','sales']) then
    raise exception 'direct update bypassed the dependency guard: %', v_modules;
  end if;

  begin
    perform public.set_business_modules(v_business, array['not_a_module']);
    raise exception 'unknown module was accepted';
  exception when sqlstate '22023' then null;
  end;

  if has_function_privilege('anon', 'public.set_business_modules(uuid,text[])', 'execute')
     or not has_function_privilege('authenticated', 'public.set_business_modules(uuid,text[])', 'execute')
     or has_table_privilege('authenticated', 'public.module_registry', 'insert') then
    raise exception 'module registry ACL contract is incorrect';
  end if;

  raise notice 'v24b module dependency suite: ALL PASS';
end $v24b_test$;

rollback;
