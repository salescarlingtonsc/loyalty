-- Rollback-only v107 lifecycle definitions, policy and classification evidence.
-- Run after the canonical chain through v107 in a disposable database.
begin;

do $contract$
begin
  if to_regprocedure(
    'public.get_customer_lifecycle_v107(uuid,date,date,uuid,timestamp with time zone)'
  ) is null or to_regprocedure(
    'public.set_customer_lifecycle_policy_v107(uuid,integer,integer,numeric,text)'
  ) is null then
    raise exception 'v107 public RPC contract is incomplete';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname='customer_lifecycle_policies_v107'
      and c.relrowsecurity
  ) then
    raise exception 'v107 policy table does not enforce RLS';
  end if;
  if has_table_privilege(
       'authenticated','public.customer_lifecycle_policies_v107','INSERT'
     ) or has_table_privilege(
       'authenticated','public.customer_lifecycle_policies_v107','UPDATE'
     ) or has_table_privilege(
       'authenticated','public.customer_lifecycle_policies_v107','DELETE'
     ) then
    raise exception 'authenticated has a direct lifecycle-policy mutation grant';
  end if;
  if has_function_privilege(
       'anon',
       'public.get_customer_lifecycle_v107(uuid,date,date,uuid,timestamp with time zone)',
       'EXECUTE'
     ) or not has_function_privilege(
       'authenticated',
       'public.get_customer_lifecycle_v107(uuid,date,date,uuid,timestamp with time zone)',
       'EXECUTE'
     ) then
    raise exception 'v107 read RPC grants are not fail-closed';
  end if;
end
$contract$;

do $runtime$
declare
  v_sa uuid:=gen_random_uuid();
  v_branch_reader uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_branch uuid:=gen_random_uuid();
  v_other_branch uuid:=gen_random_uuid();
  v_empty_business uuid:=gen_random_uuid();
  v_empty_branch uuid:=gen_random_uuid();
  v_existing uuid:=gen_random_uuid();
  v_new uuid:=gen_random_uuid();
  v_cross_branch uuid:=gen_random_uuid();
  v_branch_reader_staff uuid:=gen_random_uuid();
  v_result jsonb;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_sa,'authenticated',
    'authenticated','v107-sa-'||v_sa||'@example.test','',now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_branch_reader,'authenticated',
    'authenticated','v107-branch-reader-'||v_branch_reader||'@example.test','',now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_outsider,'authenticated',
    'authenticated','v107-outsider-'||v_outsider||'@example.test','',now(),now(),now()
  );
  insert into public.super_admins(user_id,email,note)
  values(v_sa,'v107-sa-'||v_sa||'@example.test','v107 rollback fixture');
  insert into public.businesses(id,name,slug,currency,is_synthetic)
  values(v_business,'V107 Lifecycle','v107-'||v_business,'SGD',true);
  insert into public.branches(id,business_id,name,timezone,is_default)
  values
    (v_branch,v_business,'V107 Singapore','Asia/Singapore',true),
    (v_other_branch,v_business,'V107 Other Singapore','Asia/Singapore',false);
  -- The fixture deliberately contains pre-migration history.  Model the canonical
  -- backfill contract that a real pre-existing branch receives during v106.
  insert into public.reporting_contract_versions_v106(
    business_id,branch_id,version_no,effective_from,timezone,currency,
    legacy_assumption
  ) values (
    v_business,v_branch,2,'-infinity','Asia/Singapore','SGD',true
  ),(
    v_business,v_other_branch,2,'-infinity','Asia/Singapore','SGD',true
  );
  insert into public.businesses(id,name,slug,currency,is_synthetic)
  values(v_empty_business,'V107 Empty','v107-empty-'||v_empty_business,'SGD',true);
  insert into public.branches(id,business_id,name,timezone,is_default)
  values(v_empty_branch,v_empty_business,'V107 Empty Singapore','Asia/Singapore',true);

  -- These are ordinary completed-sale fixtures, so existing trigger behavior remains active.
  -- The transaction rolls back every loyalty/commission side effect after the assertions.
  insert into public.clients(id,business_id,full_name)
  values
    (v_existing,v_business,'V107 Existing'),
    (v_new,v_business,'V107 New'),
    (v_cross_branch,v_business,'V107 Cross Branch');
  insert into public.staff(
    id,business_id,user_id,role,full_name,active
  ) values (
    v_branch_reader_staff,v_business,v_branch_reader,'bookkeeper',
    'V107 Branch Reader',true
  );
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business,v_branch_reader_staff,v_branch);
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,commission_rate_bps,commission_resolved_at
  ) values
    (gen_random_uuid(),v_business,v_existing,'quick_sale',1000,
      '2026-01-01','2026-01-01',true,true,false,'2026-01-01',
      v_branch,0,'2026-01-01'),
    (gen_random_uuid(),v_business,v_existing,'quick_sale',1000,
      '2026-07-10','2026-07-10',true,true,false,'2026-07-10',
      v_branch,0,'2026-07-10'),
    (gen_random_uuid(),v_business,v_new,'quick_sale',1000,
      '2026-07-05','2026-07-05',true,true,false,'2026-07-05',
      v_branch,0,'2026-07-05'),
    (gen_random_uuid(),v_business,v_new,'quick_sale',1000,
      '2026-07-20','2026-07-20',true,true,false,'2026-07-20',
      v_branch,0,'2026-07-20'),
    (gen_random_uuid(),v_business,v_cross_branch,'quick_sale',1000,
      '2026-01-02','2026-01-02',true,true,false,'2026-01-02',
      v_other_branch,0,'2026-01-02'),
    (gen_random_uuid(),v_business,v_cross_branch,'quick_sale',1000,
      '2026-07-22','2026-07-22',true,true,false,'2026-07-22',
      v_branch,0,'2026-07-22'),
    (gen_random_uuid(),v_business,null,'quick_sale',1000,
      '2026-07-21','2026-07-21',true,true,false,'2026-07-21',
      v_branch,0,'2026-07-21');
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_sa::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text,true
  );
  v_result:=public.get_customer_lifecycle_v107(
    v_empty_business,'2026-07-01','2026-08-01',v_empty_branch,'2026-08-02'
  );
  if v_result->>'status'<>'no_data'
     or v_result#>'{coverage,identified_transaction_pct}'<>'null'::jsonb
     or v_result#>'{metrics,repeat_in_period_rate_pct}'<>'null'::jsonb then
    raise exception 'v107 safe empty state failed: %',v_result;
  end if;
  v_result:=public.set_customer_lifecycle_policy_v107(
    v_business,60,3,2.5,'v107 rollback policy'
  );
  if (v_result->>'version_no')::integer<>2
     or (v_result->>'fallback_lapse_days')::integer<>60 then
    raise exception 'v107 append-only policy version failed: %',v_result;
  end if;
  v_result:=public.get_customer_lifecycle_v107(
    v_business,'2026-07-01','2026-08-01',v_branch,'2026-08-02'
  );
  if (v_result#>>'{metrics,transacting_identified_customers}')::integer<>3
     or (v_result#>>'{metrics,new_customers}')::integer<>1
     or (v_result#>>'{metrics,existing_returning_customers}')::integer<>2
     or (v_result#>>'{metrics,repeat_purchasers_in_period}')::integer<>1
     or (v_result#>>'{metrics,reactivated_customers}')::integer<>2
     or (v_result#>>'{coverage,eligible_transactions}')::integer<>5
     or (v_result#>>'{coverage,identified_transactions}')::integer<>4
     or v_result#>>'{scope,identity_scope}'<>'business' then
    raise exception 'v107 lifecycle classification failed: %',v_result;
  end if;
  perform set_config('request.jwt.claim.sub',v_branch_reader::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_branch_reader,'role','authenticated')::text,true
  );
  v_result:=public.get_customer_lifecycle_v107(
    v_business,'2026-07-01','2026-08-01',v_branch,'2026-08-02'
  );
  if (v_result#>>'{metrics,transacting_identified_customers}')::integer<>3
     or (v_result#>>'{metrics,new_customers}')::integer<>2
     or (v_result#>>'{metrics,existing_returning_customers}')::integer<>1
     or (v_result#>>'{metrics,reactivated_customers}')::integer<>1
     or v_result#>>'{scope,identity_scope}'<>'selected_branch' then
    raise exception 'v107 branch reader leaked cross-branch identity history: %',v_result;
  end if;
  perform set_config('request.jwt.claim.sub',v_outsider::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_outsider,'role','authenticated')::text,true
  );
  begin
    perform public.get_customer_lifecycle_v107(
      v_business,'2026-07-01','2026-08-01',v_branch,'2026-08-02'
    );
    raise exception 'v107 outsider unexpectedly read tenant lifecycle data';
  exception
    when insufficient_privilege then null;
  end;
end
$runtime$;

reset role;
select 'V107 SUITE PASS' as result;
rollback;
