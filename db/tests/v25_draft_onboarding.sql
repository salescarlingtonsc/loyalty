-- Rollback-only v25 contract suite.
begin;
\ir fixtures/pristine_chain_fixture.psql

do $v25_test$
declare
  v_bad integer;
  v_owner uuid;
  v_business uuid;
  v_workspace json;
begin
  select count(*) into v_bad from public.loyalty_programs
   where configuration_status = 'draft' and active;
  if v_bad <> 0 then raise exception 'an active loyalty draft exists'; end if;

  begin
    update public.loyalty_programs
       set active = true, configuration_status = 'draft'
     where id = (select id from public.loyalty_programs limit 1);
    raise exception 'active draft unexpectedly passed the database constraint';
  exception when check_violation then null;
  end;

  if has_function_privilege('anon', 'public.create_business(text,text,text,text[])', 'execute')
     or not has_function_privilege('authenticated', 'public.create_business(text,text,text,text[])', 'execute') then
    raise exception 'create_business ACL contract is incorrect';
  end if;

  select user_id into v_owner
    from public.staff
   where role = 'owner' and active and user_id is not null
   order by created_at limit 1;
  if v_owner is null then raise exception 'v25 suite requires an active owner fixture'; end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  v_workspace := public.create_business(
    'v25 onboarding fixture',
    'v25-' || replace(gen_random_uuid()::text, '-', ''),
    'salon',
    array['dashboard','loyalty']
  );
  v_business := (v_workspace->>'id')::uuid;
  if v_business is null
     or (select count(*) from public.staff where business_id=v_business and role='owner' and user_id=v_owner) <> 1
     or (select count(*) from public.branches where business_id=v_business and is_default and active) <> 1
     or (select count(*) from public.staff_branches where business_id=v_business) <> 1
     or (select count(*) from public.subscriptions where business_id=v_business) <> 1
     or (select count(*) from public.loyalty_programs where business_id=v_business and configuration_status='draft' and not active) <> 1
     or (select count(*) from public.audit_log where business_id=v_business and action='ONBOARD' and entity_id=v_business) <> 1 then
    raise exception 'create_business did not preserve the complete atomic onboarding contract';
  end if;
  raise notice 'v25 draft onboarding suite: ALL PASS';
end $v25_test$;

rollback;
