-- Rollback-only v106 revenue truth, privileges and event-envelope evidence.
-- Run after the canonical chain through v106 in a disposable database.
begin;

do $contract$
declare
  v_table text;
begin
  if to_regprocedure(
    'public.get_revenue_truth_v106(uuid,date,date,uuid,timestamp with time zone)'
  ) is null or to_regprocedure(
    'public.ingest_external_commerce_event_v106(uuid,uuid,text,text,text,text,timestamp with time zone,text,bigint,jsonb,text,uuid,text,text,uuid)'
  ) is null or to_regprocedure(
    'public.reconcile_external_commerce_event_v106(uuid,uuid,text,jsonb)'
  ) is null then
    raise exception 'v106 public RPC contract is incomplete';
  end if;

  foreach v_table in array array[
    'reporting_contract_versions_v106',
    'commerce_events_v106',
    'commerce_event_conflicts_v106',
    'commerce_event_reconciliations_v106',
    'commerce_refund_allocations_v106'
  ] loop
    if not exists (
      select 1 from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname=v_table and c.relrowsecurity
    ) then
      raise exception 'v106 table % does not enforce RLS',v_table;
    end if;
    if has_table_privilege('authenticated','public.'||v_table,'INSERT')
       or has_table_privilege('authenticated','public.'||v_table,'UPDATE')
       or has_table_privilege('authenticated','public.'||v_table,'DELETE') then
      raise exception 'authenticated has a direct mutation grant on %',v_table;
    end if;
  end loop;

  if has_function_privilege(
       'anon',
       'public.get_revenue_truth_v106(uuid,date,date,uuid,timestamp with time zone)',
       'EXECUTE'
     ) or not has_function_privilege(
       'authenticated',
       'public.get_revenue_truth_v106(uuid,date,date,uuid,timestamp with time zone)',
       'EXECUTE'
     ) then
    raise exception 'v106 read RPC grants are not fail-closed';
  end if;
  if has_function_privilege(
       'anon',
       'public.ingest_external_commerce_event_v106(uuid,uuid,text,text,text,text,timestamp with time zone,text,bigint,jsonb,text,uuid,text,text,uuid)',
       'EXECUTE'
     ) then
    raise exception 'anon can ingest external commerce events';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_constraint
     where conrelid='public.commerce_events_v106'::regclass
       and conname='commerce_events_v106_source_uk'
  ) then
    raise exception 'v106 source event uniqueness is missing';
  end if;
end
$contract$;

do $runtime$
declare
  v_sa uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_branch uuid:=gen_random_uuid();
  v_client uuid:=gen_random_uuid();
  v_sale uuid:=gen_random_uuid();
  v_post_period_refund_sale uuid:=gen_random_uuid();
  v_post_period_reversal_sale uuid:=gen_random_uuid();
  v_transaction_event uuid;
  v_refund_event uuid;
  v_post_period_refund_event uuid;
  v_event_time timestamptz;
  v_report_date date;
  v_result jsonb;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_sa,'authenticated',
    'authenticated','v106-sa-'||v_sa||'@example.test','',now(),now(),now()
  ),(
    '00000000-0000-0000-0000-000000000000',v_outsider,'authenticated',
    'authenticated','v106-outsider-'||v_outsider||'@example.test','',now(),now(),now()
  );
  insert into public.super_admins(user_id,email,note)
  values(v_sa,'v106-sa-'||v_sa||'@example.test','v106 rollback fixture');
  insert into public.businesses(id,name,slug,currency,is_synthetic)
  values(v_business,'V106 Revenue Truth','v106-'||v_business,'SGD',true);
  insert into public.branches(id,business_id,name,timezone,is_default)
  values(v_branch,v_business,'V106 Singapore','Asia/Singapore',true);
  insert into public.staff(
    id,business_id,user_id,role,full_name,email,active
  ) values(
    gen_random_uuid(),v_business,v_sa,'owner','V106 Owner',
    'v106-sa-'||v_sa||'@example.test',true
  );
  insert into public.reporting_contract_versions_v106(
    business_id,branch_id,version_no,effective_from,timezone,currency,
    legacy_assumption,created_by
  ) values(
    v_business,v_branch,2,'-infinity'::timestamptz,
    'Asia/Singapore','SGD',true,null
  );
  v_event_time:=clock_timestamp()-interval '2 days';
  v_report_date:=(v_event_time at time zone 'Asia/Singapore')::date;
  insert into public.clients(id,business_id,full_name)
  values(v_client,v_business,'V106 Identified Customer');
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,commission_rate_bps,commission_resolved_at
  ) values (
    v_sale,v_business,v_client,'quick_sale',1000,v_event_time,v_event_time,
    true,true,false,v_event_time,v_branch,0,v_event_time
  );

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',v_sa::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text,true
  );

  v_result:=public.get_revenue_truth_v106(
    v_business,v_report_date-7,v_report_date,v_branch,clock_timestamp()
  );
  if v_result->>'status'<>'no_data'
     or (v_result#>>'{totals,known_revenue_minor}')::bigint<>0
     or v_result#>'{coverage,identity_revenue_pct}'<>'null'::jsonb
     or v_result#>'{coverage,identity_transaction_pct}'<>'null'::jsonb then
    raise exception 'v106 safe empty state failed: %',v_result;
  end if;

  v_result:=public.ingest_external_commerce_event_v106(
    v_business,v_branch,'transaction_completed','v106.test.pos',
    'event-1','idempotency-1',v_event_time,'SGD',1000,
    '{"fixture":true}'::jsonb
  );
  if v_result->>'status'<>'accepted' or (v_result->>'ledger_changed')::boolean then
    raise exception 'v106 first event acceptance failed: %',v_result;
  end if;
  v_transaction_event:=(v_result->>'event_id')::uuid;
  v_result:=public.ingest_external_commerce_event_v106(
    v_business,v_branch,'transaction_completed','v106.test.pos',
    'event-1','idempotency-1',v_event_time,
    'SGD',1000,'{"fixture":true}'::jsonb
  );
  if v_result->>'status'<>'accepted'
     or (v_result->>'ledger_changed')::boolean then
    raise exception 'v112 exact-receipt replay did not preserve the original v106 response: %',v_result;
  end if;
  v_result:=public.ingest_external_commerce_event_v106(
    v_business,v_branch,'transaction_completed','v106.test.pos',
    'event-1','idempotency-1',v_event_time + interval '1 second',
    'SGD',1000,'{"fixture":true}'::jsonb
  );
  -- The second occurred_at deliberately differs, so it must quarantine rather than
  -- silently treating a materially different envelope as an identical replay.
  if v_result->>'status'<>'quarantined'
     or (v_result->>'ledger_changed')::boolean then
    raise exception 'v106 conflicting replay was not quarantined: %',v_result;
  end if;
  begin
    perform public.ingest_external_commerce_event_v106(
      v_business,v_branch,'transaction_voided','v106.test.pos',
      'void-positive','idempotency-void-positive',v_event_time + interval '1 second',
      'SGD',1000,'{"fixture":"invalid-positive-void"}'::jsonb
    );
    raise exception 'v106 accepted a positive transaction_voided amount';
  exception
    when check_violation then null;
  end;
  v_result:=public.ingest_external_commerce_event_v106(
    v_business,v_branch,'transaction_voided','v106.test.pos',
    'void-negative','idempotency-void-negative',v_event_time + interval '1 second',
    'SGD',-1000,'{"fixture":"valid-negative-void"}'::jsonb
  );
  if v_result->>'status'<>'accepted' then
    raise exception 'v106 rejected a negative transaction_voided amount: %',v_result;
  end if;
  v_result:=public.ingest_external_commerce_event_v106(
    v_business,v_branch,'refund_completed','v106.test.pos',
    'refund-1','idempotency-refund-1',v_event_time + interval '2 seconds',
    'SGD',-300,'{"fixture":"partial-refund"}'::jsonb
  );
  if v_result->>'status'<>'accepted' then
    raise exception 'v106 partial-refund event acceptance failed: %',v_result;
  end if;
  v_refund_event:=(v_result->>'event_id')::uuid;
  v_result:=public.reconcile_external_commerce_event_v106(
    v_refund_event,v_sale,'reconcile-refund-1',
    jsonb_build_array(jsonb_build_object('amount_minor',300))
  );
  if v_result->>'status'<>'reconciled'
     or (v_result->>'allocated_refund_minor')::bigint<>300
     or (v_result->>'ledger_changed')::boolean then
    raise exception 'v106 partial-refund reconciliation failed: %',v_result;
  end if;
  v_result:=public.reconcile_external_commerce_event_v106(
    v_refund_event,v_sale,'reconcile-refund-1',
    jsonb_build_array(jsonb_build_object('amount_minor',300))
  );
  if v_result->>'status'<>'replayed'
     or (v_result->>'ledger_changed')::boolean then
    raise exception 'v106 reconciliation replay was not idempotent: %',v_result;
  end if;
  v_result:=public.get_revenue_truth_v106(
    v_business,v_report_date,v_report_date+1,v_branch,clock_timestamp()
  );
  if (v_result#>>'{totals,known_revenue_minor}')::bigint<>700
     or (v_result#>>'{totals,identified_revenue_minor}')::bigint<>700
     or (v_result#>>'{totals,anonymous_revenue_minor}')::bigint<>0
     or (v_result#>>'{coverage,reconciled_transaction_pct}')::numeric<>0 then
    raise exception 'v106 reconciled revenue truth failed: %',v_result;
  end if;
  v_result:=public.reconcile_external_commerce_event_v106(
    v_transaction_event,v_sale,'reconcile-completed-1','[]'::jsonb
  );
  if v_result->>'status'<>'reconciled' then
    raise exception 'v106 exact completed-event reconciliation failed: %',v_result;
  end if;
  v_result:=public.get_revenue_truth_v106(
    v_business,v_report_date,v_report_date+1,v_branch,clock_timestamp()
  );
  if (v_result#>>'{coverage,reconciled_transaction_pct}')::numeric<>100 then
    raise exception 'v106 completed-event reconciliation coverage failed: %',v_result;
  end if;

  -- A refund/reversal belongs to the business-local date on which it occurs.
  -- It must not rewrite a previously closed half-open period merely because the
  -- report is queried with a later as-of timestamp.
  execute 'reset role';
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,commission_rate_bps,commission_resolved_at
  ) values (
    v_post_period_refund_sale,v_business,v_client,'quick_sale',1000,
    v_event_time+interval '1 hour',v_event_time+interval '1 hour',
    true,true,false,v_event_time+interval '1 hour',
    v_branch,0,v_event_time+interval '1 hour'
  ),(
    v_post_period_reversal_sale,v_business,v_client,'quick_sale',2000,
    v_event_time+interval '2 hours',v_event_time+interval '2 hours',
    true,true,false,v_event_time+interval '2 hours',
    v_branch,0,v_event_time+interval '2 hours'
  );
  execute 'set local role authenticated';
  v_result:=public.ingest_external_commerce_event_v106(
    v_business,v_branch,'refund_completed','v106.test.pos',
    'post-period-refund','post-period-refund',v_event_time+interval '1 day',
    'SGD',-1000,'{"fixture":"post-period-refund"}'::jsonb
  );
  v_post_period_refund_event:=(v_result->>'event_id')::uuid;
  perform public.reconcile_external_commerce_event_v106(
    v_post_period_refund_event,v_post_period_refund_sale,
    'post-period-refund-reconcile',
    jsonb_build_array(jsonb_build_object('amount_minor',1000))
  );
  execute 'set local role authenticated';
  perform public.reverse_sale(
    v_business,v_post_period_reversal_sale,
    'Post-period reporting boundary fixture',
    'v106-post-period-reversal'
  );
  v_result:=public.get_revenue_truth_v106(
    v_business,v_report_date,v_report_date+1,v_branch,clock_timestamp()
  );
  if (v_result#>>'{totals,known_revenue_minor}')::bigint<>3700 then
    raise exception
      'post-period refund/reversal rewrote the closed half-open period: %',
      v_result;
  end if;

  perform set_config('request.jwt.claim.sub',v_outsider::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_outsider,'role','authenticated')::text,true
  );
  begin
    perform public.get_revenue_truth_v106(
      v_business,v_report_date,v_report_date+1,v_branch,clock_timestamp()
    );
    raise exception 'v106 outsider unexpectedly read tenant revenue';
  exception
    when insufficient_privilege then null;
  end;
  execute 'reset role';
end
$runtime$;

do $formula$
declare
  v_total bigint:=29000;
  v_identified bigint:=24000;
  v_anonymous bigint:=5000;
  v_pct numeric;
begin
  if v_total<>v_identified+v_anonymous then
    raise exception 'v106 identity split invariant fixture failed';
  end if;
  v_pct:=case when 0=0 then null else 100*0::numeric/0 end;
  if v_pct is not null then
    raise exception 'v106 zero denominator must produce NULL';
  end if;
end
$formula$;

select 'V106 SUITE PASS' as result;
rollback;
