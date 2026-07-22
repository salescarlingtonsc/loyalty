-- Rollback-only v24c import staging, atomicity and replay suite.
begin;
\ir fixtures/pristine_chain_fixture.psql

do $v24c_test$
declare
  v_business uuid;
  v_owner uuid;
  v_stage json;
  v_replay json;
  v_done json;
  v_before integer;
  v_after integer;
  v_job uuid;
begin
  select business_id, user_id into v_business, v_owner
    from public.staff
   where role = 'owner' and active and user_id is not null
   order by created_at limit 1;
  if v_business is null then raise exception 'v24c suite requires an active owner'; end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  select count(*) into v_before from public.services where business_id = v_business;
  v_stage := public.stage_import_rows(v_business, 'services', jsonb_build_array(
    jsonb_build_object('name','v24c service A','price_cents',2500,'duration_min',30),
    jsonb_build_object('name','v24c service B','price_cents',4000,'duration_min',60)
  ), 'v24c-import-replay');
  v_replay := public.stage_import_rows(v_business, 'services', jsonb_build_array(
    jsonb_build_object('name','v24c service A','price_cents',2500,'duration_min',30),
    jsonb_build_object('name','v24c service B','price_cents',4000,'duration_min',60)
  ), 'v24c-import-replay');
  if v_replay->>'job_id' is distinct from v_stage->>'job_id' then
    raise exception 'staging replay returned another job';
  end if;
  v_job := (v_stage->>'job_id')::uuid;
  v_done := public.commit_import_job(v_job);
  if (v_done->>'imported')::integer <> 2 then raise exception 'expected two imported services'; end if;
  if public.commit_import_job(v_job)::jsonb is distinct from v_done::jsonb then
    raise exception 'commit replay did not return the original result';
  end if;
  select count(*) into v_after from public.services where business_id = v_business;
  if v_after - v_before <> 2 then raise exception 'commit replay inserted rows more than once'; end if;

  v_stage := public.stage_import_rows(v_business, 'customers', jsonb_build_array(
    jsonb_build_object('full_name','Duplicate One','phone','+6591234567'),
    jsonb_build_object('full_name','Duplicate Two','phone','+65 9123 4567')
  ), 'v24c-invalid-batch');
  if (v_stage->>'invalid')::integer <> 1 then
    raise exception 'within-file duplicate phone was not staged as a row error';
  end if;
  begin
    perform public.commit_import_job((v_stage->>'job_id')::uuid);
    raise exception 'invalid batch unexpectedly committed';
  exception when check_violation then null;
  end;

  if has_table_privilege('authenticated', 'public.import_jobs', 'insert')
     or has_table_privilege('authenticated', 'public.import_rows', 'update')
     or has_function_privilege('anon', 'public.stage_import_rows(uuid,text,jsonb,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.commit_import_job(uuid)', 'execute') then
    raise exception 'import ACL contract is incorrect';
  end if;

  raise notice 'v24c import foundation suite: ALL PASS';
end $v24c_test$;

rollback;
