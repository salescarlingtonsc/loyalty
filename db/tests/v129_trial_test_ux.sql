-- Rollback-only V129 customer inactivity reader acceptance.
-- Run after the canonical chain through V129 in a disposable database.
begin;

create temporary table pg_temp.v129_fixture(
  business_id uuid primary key,
  foreign_business_id uuid not null,
  owner_user_id uuid not null,
  denied_user_id uuid not null,
  active_client_id uuid not null,
  day30_client_id uuid not null,
  day60_client_id uuid not null,
  day90_client_id uuid not null,
  never_client_id uuid not null,
  reversed_client_id uuid not null,
  package_client_id uuid not null,
  reversed_package_client_id uuid not null,
  partial_refund_client_id uuid not null,
  non_visit_client_id uuid not null
) on commit drop;

do $fixture$
declare
  v_owner uuid:=gen_random_uuid();
  v_denied uuid:=gen_random_uuid();
  v_foreign_owner uuid:=gen_random_uuid();
  v_business uuid;
  v_foreign_business uuid;
  v_branch uuid;
  v_active uuid;
  v_day30 uuid;
  v_day60 uuid;
  v_day90 uuid;
  v_never uuid;
  v_reversed uuid;
  v_package uuid;
  v_reversed_package uuid;
  v_partial uuid;
  v_non_visit uuid;
  v_original_sale uuid;
  v_partial_sale uuid;
  v_plan public.package_plans%rowtype;
  v_package_sale jsonb;
  v_package_use jsonb;
  v_reversed_package_sale jsonb;
  v_reversed_package_use jsonb;
  v_refund_event jsonb;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
      'v129-owner-'||v_owner::text||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_denied,'authenticated','authenticated',
      'v129-denied-'||v_denied::text||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_foreign_owner,'authenticated','authenticated',
      'v129-foreign-'||v_foreign_owner::text||'@example.test','',now(),now(),now());

  insert into public.businesses(name,slug,industry,enabled_modules,created_at)
  values('Glow Atelier V129','glow-v129-'||replace(v_owner::text,'-',''),'facial',
    array['dashboard','clients','till','sales','packages'],'2000-01-01') returning id into v_business;
  insert into public.businesses(name,slug,industry,enabled_modules,created_at)
  values('Foreign Atelier V129','foreign-v129-'||replace(v_foreign_owner::text,'-',''),'facial',
    array['dashboard','clients'],'2000-01-01') returning id into v_foreign_business;

  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,
         decided_at=statement_timestamp(),decision_reason='synthetic V129 fixture',
         updated_at=statement_timestamp()
   where business_id in(v_business,v_foreign_business)
     and approval_status='pending';

  insert into public.branches(business_id,name,timezone,active,is_default)
  values(v_business,'Orchard Road','Asia/Singapore',true,true)
  returning id into v_branch;

  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values
    (v_business,v_owner,'owner','Olivia Tan',true,null,null),
    (v_business,v_denied,'staff','Chen Wei',true,array['appointments'],'{"appointments":"r"}'),
    (v_foreign_business,v_foreign_owner,'owner','Foreign Owner',true,null,null);

  insert into public.clients(business_id,full_name,phone,marketing_consent)
  values(v_business,'Mei Active','81230001',true) returning id into v_active;
  insert into public.clients(business_id,full_name,phone,marketing_consent)
  values(v_business,'Lee Thirty','81230030',true) returning id into v_day30;
  insert into public.clients(business_id,full_name,phone,marketing_consent)
  values(v_business,'Lee Sixty','81230060',false) returning id into v_day60;
  insert into public.clients(business_id,full_name,phone,marketing_consent)
  values(v_business,'Arun Ninety','81230090',true) returning id into v_day90;
  insert into public.clients(business_id,full_name,phone,marketing_consent)
  values(v_business,'New Never','81230999',false) returning id into v_never;
  insert into public.clients(business_id,full_name,phone,marketing_consent)
  values(v_business,'Reverse Only','81230888',false) returning id into v_reversed;
  insert into public.clients(business_id,full_name,phone,marketing_consent)
  values(v_business,'Package Active','81230777',true) returning id into v_package;
  insert into public.clients(business_id,full_name,phone,marketing_consent)
  values(v_business,'Package Reversed','81230776',false) returning id into v_reversed_package;
  insert into public.clients(business_id,full_name,phone,marketing_consent)
  values(v_business,'Partial Refund','81230450',true) returning id into v_partial;
  insert into public.clients(business_id,full_name,phone,marketing_consent)
  values(v_business,'Non Visit Sale','81230000',false) returning id into v_non_visit;

  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,note,branch_id)
  values(v_business,v_active,'service',6000,statement_timestamp()-interval '20 days','V129 active visit',v_branch);
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,note,branch_id)
  values(v_business,v_day30,'service',6000,statement_timestamp()-interval '30 days','V129 exact 30 day visit',v_branch);
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,note,branch_id)
  values(v_business,v_day60,'service',6000,statement_timestamp()-interval '60 days','V129 exact 60 day visit',v_branch);
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,note,branch_id)
  values(v_business,v_day90,'service',6000,statement_timestamp()-interval '90 days','V129 exact 90 day visit',v_branch);
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,note,branch_id)
  values(v_business,v_reversed,'service',6000,statement_timestamp()-interval '120 days','V129 reversed visit',v_branch)
  returning id into v_original_sale;
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,note,branch_id)
  values(v_business,v_partial,'service',6000,statement_timestamp()-interval '45 days','V129 partially refunded visit',v_branch)
  returning id into v_partial_sale;
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,note,branch_id)
  values(v_business,v_non_visit,'gift_card',5000,statement_timestamp()-interval '10 days','V129 non-visit sale',v_branch);

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config('request.jwt.claims',json_build_object(
    'sub',v_owner,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  perform public.reverse_sale(
    v_business,v_original_sale,'V129 synthetic full reversal',
    'v129-reversal-'||v_original_sale::text,null,'none'
  );

  -- A partial external refund does not erase the qualifying visit. Revenue and
  -- visit truth are deliberately separate contracts.
  v_refund_event:=public.ingest_external_commerce_event_v106(
    v_business,v_branch,'refund_completed','v129.partial-refund',
    'partial-'||v_partial_sale::text,'partial-'||v_partial_sale::text,
    statement_timestamp(),'SGD',-3000,'{"fixture":"V129 partial refund"}'::jsonb
  );
  perform public.reconcile_external_commerce_event_v106(
    (v_refund_event->>'event_id')::uuid,v_partial_sale,
    'v129-partial-reconcile-'||v_partial_sale::text,
    jsonb_build_array(jsonb_build_object('amount_minor',3000))
  );

  -- Exercise the canonical V102 package workflow. Its SGD 0 session sale is a
  -- visit; restoring a session creates a zero-value reversal and removes it.
  select * into v_plan from public.save_package_plan_v102(
    v_business,null,'Radiance facial package',8800,5,null::uuid,true
  );
  v_package_sale:=public.sell_package_v102(
    v_business,v_package,v_plan.id,v_branch,gen_random_uuid()
  );
  v_package_use:=public.use_package_session_v102(
    v_business,(v_package_sale->>'client_package_id')::uuid,v_branch,
    'v129-package-active'
  );
  v_reversed_package_sale:=public.sell_package_v102(
    v_business,v_reversed_package,v_plan.id,v_branch,gen_random_uuid()
  );
  v_reversed_package_use:=public.use_package_session_v102(
    v_business,(v_reversed_package_sale->>'client_package_id')::uuid,v_branch,
    'v129-package-reversed'
  );
  perform public.reverse_sale(
    v_business,(v_reversed_package_use->>'sale_id')::uuid,
    'V129 synthetic package session restore',
    'v129-package-restore',null,'none'
  );
  execute 'reset role';

  insert into pg_temp.v129_fixture values(
    v_business,v_foreign_business,v_owner,v_denied,v_active,v_day30,v_day60,
    v_day90,v_never,v_reversed,v_package,v_reversed_package,v_partial,v_non_visit
  );
end
$fixture$;

create or replace function pg_temp.as_v129_user(p_user uuid)
returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claim.sub',p_user::text,true);
  perform set_config('request.jwt.claims',json_build_object(
    'sub',p_user,'role','authenticated')::text,true);
  execute 'set local role authenticated';
end
$$;
grant execute on function pg_temp.as_v129_user(uuid) to public;

create or replace function pg_temp.expect_v129_error(
  p_sql text,p_state text,p_label text
) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception '% unexpectedly succeeded',p_label;
exception when others then
  if sqlstate<>p_state then
    raise exception '% returned %, expected %: %',p_label,sqlstate,p_state,sqlerrm;
  end if;
end
$$;
grant execute on function pg_temp.expect_v129_error(text,text,text) to public;

do $acceptance$
declare
  f pg_temp.v129_fixture%rowtype;
  v_all jsonb;
  v_30 jsonb;
  v_60 jsonb;
  v_90 jsonb;
  v_search jsonb;
  v_clients_before bigint;
  v_sales_before bigint;
begin
  select * into f from pg_temp.v129_fixture;
  select count(*) into v_clients_before from public.clients where business_id=f.business_id;
  select count(*) into v_sales_before from public.sales where business_id=f.business_id;

  if to_regprocedure('public.staff_list_customers_v129(uuid,text,integer,integer,integer)') is null then
    raise exception 'V129 customer reader is absent';
  end if;
  if has_function_privilege('public','public.staff_list_customers_v129(uuid,text,integer,integer,integer)','execute')
     or has_function_privilege('anon','public.staff_list_customers_v129(uuid,text,integer,integer,integer)','execute')
     or not has_function_privilege('authenticated','public.staff_list_customers_v129(uuid,text,integer,integer,integer)','execute') then
    raise exception 'V129 customer reader ACL is not authenticated-only';
  end if;

  perform pg_temp.as_v129_user(f.owner_user_id);
  v_all:=public.staff_list_customers_v129(f.business_id,null,null,100,0);
  v_30:=public.staff_list_customers_v129(f.business_id,null,30,100,0);
  v_60:=public.staff_list_customers_v129(f.business_id,null,60,100,0);
  v_90:=public.staff_list_customers_v129(f.business_id,null,90,100,0);

  if (v_all->>'total')::integer<>10 then raise exception 'V129 all count mismatch: %',v_all; end if;
  if (v_30->>'total')::integer<>8 then raise exception 'V129 30-day count mismatch: %',v_30; end if;
  if (v_60->>'total')::integer<>6 then raise exception 'V129 60-day count mismatch: %',v_60; end if;
  if (v_90->>'total')::integer<>5 then raise exception 'V129 90-day count mismatch: %',v_90; end if;

  if v_30#>'{customers,0}' is null
     or not exists(select 1 from jsonb_array_elements(v_30->'customers') row
       where row->>'full_name'='New Never' and row->'last_visit_at'='null'::jsonb)
     or not exists(select 1 from jsonb_array_elements(v_30->'customers') row
       where row->>'full_name'='Reverse Only' and row->'last_visit_at'='null'::jsonb)
     or not exists(select 1 from jsonb_array_elements(v_30->'customers') row
       where row->>'full_name'='Package Reversed' and row->'last_visit_at'='null'::jsonb)
     or not exists(select 1 from jsonb_array_elements(v_30->'customers') row
       where row->>'full_name'='Non Visit Sale' and row->'last_visit_at'='null'::jsonb) then
    raise exception 'V129 never/reversed/non-visit customers are not labelled without a valid visit: %',v_30;
  end if;
  if exists(select 1 from jsonb_array_elements(v_30->'customers') row
       where row->>'full_name'='Mei Active') then
    raise exception 'V129 active customer leaked into 30-day filter';
  end if;
  if exists(select 1 from jsonb_array_elements(v_30->'customers') row
       where row->>'full_name'='Package Active')
     or not exists(select 1 from jsonb_array_elements(v_all->'customers') row
       where row->>'full_name'='Package Active' and row->'last_visit_at'<>'null'::jsonb) then
    raise exception 'V129 canonical SGD 0 package session was not treated as a valid recent visit: %',v_all;
  end if;
  if not exists(select 1 from jsonb_array_elements(v_30->'customers') row
       where row->>'full_name'='Partial Refund'
         and (row->>'days_since_last_visit')::integer=45) then
    raise exception 'V129 partially refunded visit was erased or misdated: %',v_30;
  end if;
  if exists(select 1 from jsonb_array_elements(v_60->'customers') row
       where row->>'full_name'='Lee Thirty') then
    raise exception 'V129 exact-30-day customer leaked into 60-day filter';
  end if;

  v_search:=public.staff_list_customers_v129(f.business_id,'0060',60,100,0);
  if (v_search->>'total')::integer<>1
     or v_search#>>'{customers,0,full_name}'<>'Lee Sixty' then
    raise exception 'V129 combined phone/inactivity filter mismatch: %',v_search;
  end if;

  perform pg_temp.expect_v129_error(format(
    'select public.staff_list_customers_v129(%L,null,45,100,0)',f.business_id
  ),'22023','unsupported inactivity threshold');
  perform pg_temp.expect_v129_error(format(
    'select public.staff_list_customers_v129(%L,null,null,101,0)',f.business_id
  ),'22023','oversized customer page');
  perform pg_temp.expect_v129_error(format(
    'select public.staff_list_customers_v129(%L,null,null,100,0)',f.foreign_business_id
  ),'42501','cross-tenant customer list');

  perform pg_temp.as_v129_user(f.denied_user_id);
  perform pg_temp.expect_v129_error(format(
    'select public.staff_list_customers_v129(%L,null,null,100,0)',f.business_id
  ),'42501','staff without Clients read');

  execute 'reset role';
  if (select count(*) from public.clients where business_id=f.business_id)<>v_clients_before
     or (select count(*) from public.sales where business_id=f.business_id)<>v_sales_before then
    raise exception 'V129 read-only acceptance mutated customer or sale counts';
  end if;
end
$acceptance$;

rollback;
