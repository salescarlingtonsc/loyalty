begin;

do $v97_test$
declare
  v_user uuid:=gen_random_uuid();
  v_other uuid:=gen_random_uuid();
  v_result jsonb;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_user,'authenticated','authenticated',
      'v97-workspace@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_other,'authenticated','authenticated',
      'v97-other@example.test','',now(),now(),now());

  perform set_config('request.jwt.claim.sub',v_user::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',v_user,'role','authenticated')::text,true);
  set local role authenticated;
  v_result:=public.get_workspace_locale_preference_v97();
  if v_result<>jsonb_build_object('locale','en','version',0) then
    raise exception 'unexpected default preference: %',v_result;
  end if;
  v_result:=public.set_workspace_locale_preference_v97('ms',0);
  if v_result#>>'{locale}'<>'ms' or (v_result->>'version')::bigint<>1 then
    raise exception 'Malay preference was not persisted: %',v_result;
  end if;
  reset role;

  perform set_config('request.jwt.claim.sub',v_other::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',v_other,'role','authenticated')::text,true);
  set local role authenticated;
  if public.get_workspace_locale_preference_v97()<>jsonb_build_object('locale','en','version',0) then
    raise exception 'preference leaked across users';
  end if;
  reset role;

  perform set_config('request.jwt.claim.sub',v_user::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',v_user,'role','authenticated')::text,true);
  set local role authenticated;
  begin
    perform public.set_workspace_locale_preference_v97('zh-CN',0);
    raise exception 'stale locale update unexpectedly succeeded';
  exception when serialization_failure then null;
  end;
  v_result:=public.set_workspace_locale_preference_v97('zh-CN',1);
  if v_result#>>'{locale}'<>'zh-CN' or (v_result->>'version')::bigint<>2 then
    raise exception 'Chinese preference was not persisted: %',v_result;
  end if;
  reset role;
end
$v97_test$;

do $v97_malay_application$
declare
  v_sector text;
  v_result jsonb;
  v_locale text;
begin
  select sector_key into v_sector
  from public.sector_bundle_versions
  where status='published'
  order by sector_key
  limit 1;
  if v_sector is null then
    raise exception 'v97 Malay application test requires a published sector bundle';
  end if;

  v_result:=public.internal_submit_business_application_v95(
    'V97 Malay Applicant',
    concat('v97-ms-',replace(gen_random_uuid()::text,'-',''),'@example.test'),
    '+6581234567',
    'V97 Malay Business',
    v_sector,
    null,
    'ms',
    gen_random_uuid()
  );
  select preferred_locale into v_locale
  from public.business_applications_v95
  where id=(v_result->>'application_id')::uuid;
  if v_locale<>'ms' then
    raise exception 'Malay application locale was not preserved: %',v_locale;
  end if;
end
$v97_malay_application$;

rollback;
