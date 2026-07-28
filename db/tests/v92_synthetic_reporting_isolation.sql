-- Rollback-only v92 regression evidence.
begin;

create or replace function pg_temp.as_v92_user(
  p_uid uuid,p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v92_user(uuid,text) to public;

do $v92$
declare
  v_sa uuid:='92000000-0000-4000-8000-000000000001';
  v_real_business uuid:='92000000-0000-4000-8000-000000000010';
  v_synthetic_business uuid:='92000000-0000-4000-8000-000000000020';
  v_synthetic_client uuid:='92000000-0000-4000-8000-000000000021';
  v_result jsonb;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) values(
    '00000000-0000-0000-0000-000000000000',v_sa,'authenticated',
    'authenticated','v92-sa@example.test','',now(),now(),now()
  );
  insert into public.super_admins(user_id,email,note)
  values(v_sa,'v92-sa@example.test','v92 rollback fixture');

  insert into public.businesses(
    id,name,slug,industry,is_synthetic,created_at,updated_at
  ) values
    (v_real_business,'V92 Real Firm','v92-real-firm','fnb',false,
      now()-interval '1 day',now()),
    (v_synthetic_business,'ZZZ SYNTHETIC V92 E2E','zzz-synthetic-v92-e2e',
      'fnb',true,now()-interval '1 day',now());
  insert into public.clients(
    id,business_id,full_name,email,is_synthetic
  ) values(
    v_synthetic_client,v_synthetic_business,'V92 Synthetic Customer',
    'v92-customer@example.test',true
  );

  perform pg_temp.as_v92_user(v_sa);
  v_result:=public.platform_get_enterprise_hierarchy_v82(
    null,null,null,current_date-7,current_date,null,100,null,null,null
  );
  reset role;
  if jsonb_array_length(v_result->'firms')<>1
     or v_result#>>'{firms,0,business_id}'<>v_real_business::text
     or v_result::text like '%ZZZ SYNTHETIC V92 E2E%' then
    raise exception 'synthetic business leaked into enterprise hierarchy: %',
      v_result;
  end if;

  perform pg_temp.as_v92_user(v_sa);
  v_result:=public.platform_list_enterprise_customers_v82(
    null,array[v_synthetic_business],null,current_date-7,current_date,
    null,100,null,null,null
  );
  reset role;
  if jsonb_array_length(v_result->'customers')<>0 then
    raise exception 'synthetic customer leaked into enterprise customer export: %',
      v_result;
  end if;

  perform pg_temp.as_v92_user(v_sa);
  v_result:=public.platform_generate_improvement_report_v82(
    null,null,null,current_date-7,current_date,null,null
  );
  reset role;
  if v_result::text like '%ZZZ SYNTHETIC V92 E2E%' then
    raise exception 'synthetic business leaked into enterprise improvement report';
  end if;

  perform pg_temp.as_v92_user(v_sa);
  v_result:=public.platform_list_firm_onboarding_v88(
    '{"search":"V92"}',null,100,null,null
  );
  reset role;
  if (v_result->>'total_count')::integer<>1
     or v_result#>>'{items,0,business_id}'<>v_real_business::text
     or jsonb_typeof(v_result#>'{items,0,attention_due}')<>'boolean' then
    raise exception 'firm directory isolation/boolean contract failed: %',v_result;
  end if;
end
$v92$;

rollback;
