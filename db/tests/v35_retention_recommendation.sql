-- Rollback-only recommendation draft contract.
begin;
do $v35_test$
declare v_business uuid;v_owner uuid;v_before uuid;v_result json;v_draft uuid;
begin
  select business_id,user_id into v_business,v_owner from public.staff
   where role='owner' and active and user_id is not null order by created_at limit 1;
  if v_business is null then raise exception 'v35 suite requires owner fixture';end if;
  perform set_config('request.jwt.claims',json_build_object('sub',v_owner,'role','authenticated')::text,true);
  select active_config_version_id into v_before from public.businesses where id=v_business;
  v_result:=public.generate_retention_recommendation(v_business,'v35-test-key');
  v_draft:=(v_result->>'draft_config_version_id')::uuid;
  if (v_result->>'published')::boolean then raise exception 'recommendation auto-published';end if;
  if (select status from public.firm_config_versions where id=v_draft)<>'draft' then raise exception 'recommendation is not draft';end if;
  if (select active_config_version_id from public.businesses where id=v_business) is distinct from v_before then raise exception 'recommendation changed live config';end if;
  if (select active from public.loyalty_program_versions where config_version_id=v_draft) then raise exception 'recommendation draft active';end if;
  if public.generate_retention_recommendation(v_business,'v35-test-key')::text<>v_result::text then raise exception 'retry changed result';end if;
  if has_function_privilege('anon','public.generate_retention_recommendation(uuid,text)','execute') then raise exception 'anon recommendation execute';end if;
  raise notice 'v35 retention recommendation suite: ALL PASS';
end $v35_test$;
rollback;
