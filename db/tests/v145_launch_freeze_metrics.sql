-- V145 rollback-only acceptance for launch-freeze metric truth.
-- Run after the complete canonical chain in a disposable database.
begin;

create temporary table pg_temp.v145_fixture(
  business_id uuid primary key,
  foreign_business_id uuid not null,
  branch_id uuid not null,
  other_branch_id uuid not null,
  foreign_branch_id uuid not null,
  owner_id uuid not null,
  report_reader_id uuid not null,
  frontdesk_id uuid not null,
  denied_id uuid not null,
  foreign_owner_id uuid not null,
  customer_user_id uuid not null,
  customer_identity_id uuid not null,
  customer_link_id uuid not null,
  client_valid_id uuid not null,
  client_reversed_id uuid not null,
  client_non_visit_id uuid not null,
  client_other_branch_id uuid not null,
  valid_sale_id uuid not null,
  other_branch_sale_id uuid not null
) on commit drop;

do $v145_fixture$
declare
  v_business uuid := '14500000-0000-4000-8000-000000000001';
  v_foreign_business uuid := '14500000-0000-4000-8000-000000000002';
  v_branch uuid := '14500000-0000-4000-8000-000000000011';
  v_other_branch uuid := '14500000-0000-4000-8000-000000000012';
  v_foreign_branch uuid := '14500000-0000-4000-8000-000000000013';
  v_owner uuid := '14500000-0000-4000-8000-000000000021';
  v_report_reader uuid := '14500000-0000-4000-8000-000000000022';
  v_denied uuid := '14500000-0000-4000-8000-000000000023';
  v_foreign_owner uuid := '14500000-0000-4000-8000-000000000024';
  v_frontdesk uuid := '14500000-0000-4000-8000-000000000025';
  v_customer_user uuid := '14500000-0000-4000-8000-000000000026';
  v_client_valid uuid := '14500000-0000-4000-8000-000000000031';
  v_client_reversed uuid := '14500000-0000-4000-8000-000000000032';
  v_client_non_visit uuid := '14500000-0000-4000-8000-000000000033';
  v_client_other_branch uuid := '14500000-0000-4000-8000-000000000034';
  v_customer_identity uuid := '14500000-0000-4000-8000-000000000035';
  v_customer_link uuid := '14500000-0000-4000-8000-000000000036';
  v_valid_sale uuid := '14500000-0000-4000-8000-000000000041';
  v_reversed_sale uuid := '14500000-0000-4000-8000-000000000042';
  v_reversal uuid := '14500000-0000-4000-8000-000000000043';
  v_non_visit_sale uuid := '14500000-0000-4000-8000-000000000044';
  v_other_branch_sale uuid := '14500000-0000-4000-8000-000000000045';
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  )
  select '00000000-0000-0000-0000-000000000000',user_id,
         'authenticated','authenticated',email,'',
         '2026-01-01 00:00:00+00','2026-01-01 00:00:00+00','2026-01-01 00:00:00+00'
    from (values
      (v_owner,'v145-owner@example.test'),
      (v_report_reader,'v145-reader@example.test'),
      (v_frontdesk,'v145-frontdesk@example.test'),
      (v_denied,'v145-denied@example.test'),
      (v_foreign_owner,'v145-foreign@example.test'),
      (v_customer_user,'v145-customer@example.test')
    ) users(user_id,email);

  insert into public.businesses(id,name,slug,industry,enabled_modules,created_at) values
    (v_business,'V145 launch freeze salon','v145-launch-freeze-salon','facial',
      array['dashboard','clients','sales','reports','expenses','pnl','loyalty','retention',
        'appointments','services','memberships','packages','referrals','staffperf','dailyreport','giftcards'],
      '2026-01-01 00:00:00+00'),
    (v_foreign_business,'V145 foreign salon','v145-foreign-salon','facial',
      array['dashboard','clients','sales','reports','expenses'],'2026-01-01 00:00:00+00');

  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,
         decided_at=statement_timestamp(),decision_reason='synthetic V145 fixture',
         updated_at=statement_timestamp()
   where business_id in (v_business,v_foreign_business)
     and approval_status='pending';

  insert into public.branches(id,business_id,name,timezone,active,is_default) values
    (v_branch,v_business,'Orchard','Asia/Singapore',true,true),
    (v_other_branch,v_business,'Tampines','Asia/Singapore',true,false),
    (v_foreign_branch,v_foreign_business,'Foreign','Asia/Singapore',true,true);

  insert into public.platform_module_overrides_v94(
    business_id,branch_scope,module_key,mode,reason,updated_by
  ) values (
    v_business,v_other_branch,'reports','disabled',
    'V145 synthetic branch-effective Reports denial',v_owner
  );

  insert into public.staff(id,business_id,user_id,role,full_name,active,modules,module_perms) values
    ('14500000-0000-4000-8000-000000000051',v_business,v_owner,'owner','V145 Owner',true,null,null),
    ('14500000-0000-4000-8000-000000000052',v_business,v_report_reader,'bookkeeper','V145 Report Reader',true,
      array['dashboard'],jsonb_build_object('reports','r')),
    ('14500000-0000-4000-8000-000000000053',v_business,v_denied,'staff','V145 Denied',false,
      array['appointments'],jsonb_build_object('appointments','r')),
    ('14500000-0000-4000-8000-000000000054',v_foreign_business,v_foreign_owner,'owner','V145 Foreign Owner',true,null,null),
    ('14500000-0000-4000-8000-000000000055',v_business,v_frontdesk,'frontdesk','V145 Orchard Front Desk',true,
      array['clients','giftcards','loyalty','sales'],jsonb_build_object('clients','r','giftcards','r','loyalty','r','sales','r'));
  insert into public.staff_branches(business_id,staff_id,branch_id) values
    (v_business,'14500000-0000-4000-8000-000000000052',v_branch),
    (v_business,'14500000-0000-4000-8000-000000000053',v_branch),
    (v_business,'14500000-0000-4000-8000-000000000055',v_branch),
    (v_foreign_business,'14500000-0000-4000-8000-000000000054',v_foreign_branch);

  insert into public.clients(id,business_id,full_name,email,phone,created_at) values
    (v_client_valid,v_business,'Aisha Valid','v145-valid@example.test','+6591450001','2026-08-01 00:30:00+00'),
    (v_client_reversed,v_business,'Ben Reversed','v145-reversed@example.test','+6591450002','2026-08-01 01:30:00+00'),
    (v_client_non_visit,v_business,'Chen Non Visit','v145-nonvisit@example.test','+6591450003','2026-08-01 02:30:00+00'),
    (v_client_other_branch,v_business,'Devi Other Branch','v145-other@example.test','+6591450004','2026-08-01 03:30:00+00');

  insert into public.customer_identities(id,auth_user_id,status,created_via)
  values(v_customer_identity,v_customer_user,'active','wallet_start');
  perform set_config('app.customer_link_insert_id',v_customer_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at
  ) values(
    v_customer_link,v_business,v_customer_identity,v_customer_user,v_client_valid,
    'verified','email_claim','2026-08-01 00:45:00+00'
  );
  perform set_config('app.customer_link_insert_id','',true);

  insert into public.sales(id,business_id,branch_id,client_id,staff_id,kind,amount_cents,occurred_at,note) values
    (v_valid_sale,v_business,v_branch,v_client_valid,'14500000-0000-4000-8000-000000000051','service',1000,'2026-08-01 02:00:00+00','V145 valid visit'),
    (v_reversed_sale,v_business,v_branch,v_client_reversed,'14500000-0000-4000-8000-000000000051','service',2000,'2026-08-01 03:00:00+00','V145 fully reversed visit'),
    (v_non_visit_sale,v_business,v_branch,v_client_non_visit,'14500000-0000-4000-8000-000000000051','gift_card',3000,'2026-08-01 04:00:00+00','V145 identified non-visit'),
    (v_other_branch_sale,v_business,v_other_branch,v_client_other_branch,'14500000-0000-4000-8000-000000000051','service',4000,'2026-08-01 05:00:00+00','V145 other branch visit');

  perform set_config('app.sale_reversal_insert_id',v_reversal::text,true);
  perform set_config('app.sale_reversal_original_id',v_reversed_sale::text,true);
  insert into public.sales(
    id,business_id,branch_id,client_id,staff_id,kind,amount_cents,occurred_at,note,
    reversal_of,reversal_reason,reversal_actor,reversal_idempotency_key
  ) values (
    v_reversal,v_business,v_branch,v_client_reversed,'14500000-0000-4000-8000-000000000051','service',-2000,
    '2026-08-02 03:00:00+00','V145 reversal','14500000-0000-4000-8000-000000000042',
    'V145 deterministic full reversal',v_owner,'v145-full-reversal'
  );
  perform set_config('app.sale_reversal_insert_id','',true);
  perform set_config('app.sale_reversal_original_id','',true);

  perform set_config('app.points_ledger_insert_id','14500000-0000-4000-8000-000000000061',true);
  perform set_config('app.points_ledger_write_scope','sale_trigger',true);
  insert into public.points_ledger(
    id,business_id,client_id,entry_type,points,sale_id,reference,created_at
  ) values (
    '14500000-0000-4000-8000-000000000061',v_business,v_client_valid,
    'earn',11,v_valid_sale,'V145 branch earn','2026-08-01 02:01:00+00'
  );
  perform set_config('app.points_ledger_insert_id','14500000-0000-4000-8000-000000000062',true);
  insert into public.points_ledger(
    id,business_id,client_id,entry_type,points,sale_id,reference,created_at
  ) values (
    '14500000-0000-4000-8000-000000000062',v_business,v_client_other_branch,
    'earn',22,v_other_branch_sale,'V145 other branch earn','2026-08-01 05:01:00+00'
  );
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);

  -- Credit has no branch column. Keep nonzero balances on customers whose valid visits
  -- are in different branches so a branch-limited aggregate cannot pass by coincidence.
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_owner,'role','authenticated')::text,true);
  perform set_config('app.credit_ledger_write_scope','redeem_points',true);
  perform set_config('app.credit_ledger_insert_id','14500000-0000-4000-8000-000000000063',true);
  insert into public.credit_ledger(
    id,business_id,client_id,entry_type,amount_cents,reference,actor
  ) values(
    '14500000-0000-4000-8000-000000000063',v_business,v_client_valid,
    'loyalty_earn',500,'V145 Orchard customer credit',v_owner
  );
  perform set_config('app.credit_ledger_insert_id','14500000-0000-4000-8000-000000000064',true);
  insert into public.credit_ledger(
    id,business_id,client_id,entry_type,amount_cents,reference,actor
  ) values(
    '14500000-0000-4000-8000-000000000064',v_business,v_client_other_branch,
    'loyalty_earn',900,'V145 Tampines customer credit',v_owner
  );
  perform set_config('app.credit_ledger_insert_id','',true);
  perform set_config('app.credit_ledger_write_scope','',true);
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);

  -- 1,001 rows prove server aggregates are not subject to the Data API default row cap.
  insert into public.sales(business_id,branch_id,staff_id,kind,amount_cents,occurred_at,note)
  select v_business,v_branch,'14500000-0000-4000-8000-000000000051','quick_sale',1,'2031-07-31 16:30:00+00',
         'V145 uncapped aggregate row '||n
    from generate_series(1,1001) n;
  insert into public.sales(business_id,branch_id,staff_id,kind,amount_cents,occurred_at,note)
  values(v_business,v_branch,'14500000-0000-4000-8000-000000000051','quick_sale',200,'2031-08-31 16:30:00+00','V145 September SG boundary');

  -- Existing customer-profile and service-recovery readers must remain complete beyond
  -- every browser/RPC page boundary. These are normal immutable sale facts, not toy rows.
  insert into public.sales(business_id,branch_id,client_id,kind,amount_cents,occurred_at,note)
  select v_business,v_branch,v_client_valid,'quick_sale',100,
         '2026-09-01 00:00:00+00'::timestamptz + make_interval(secs=>n),
         'V145 paged customer sale '||n
    from generate_series(1,205) n;

  insert into public.visit_feedback(
    business_id,identity_id,link_id,client_id,auth_user_id,sale_id,rating,comment,
    idempotency_key,recovery_status,created_at
  )
  select v_business,v_customer_identity,v_customer_link,v_client_valid,v_customer_user,
         sale.id,case when numbered.n%2=0 then 5 else 2 end,
         'V145 paged feedback '||numbered.n,gen_random_uuid(),
         case when numbered.n%2=0 then 'closed' else 'open' end,
         '2026-09-02 00:00:00+00'::timestamptz + make_interval(secs=>numbered.n)
    from (
      select sale.*,row_number() over(order by sale.id)::integer n
        from public.sales sale
       where sale.business_id=v_business
         and sale.note like 'V145 paged customer sale %'
    ) numbered
    join public.sales sale on sale.id=numbered.id;

  insert into public.gift_cards(
    business_id,code,initial_cents,balance_cents,purchaser_client_id,status,created_at
  )
  select v_business,'V145-PAGED-'||lpad(n::text,4,'0'),1000+n,500+n,
         v_client_valid,'active',
         '2026-09-03 00:00:00+00'::timestamptz + make_interval(secs=>n)
    from generate_series(1,205) n;

  insert into public.loyalty_redemptions(
    business_id,client_id,reward_name,points_spent,credit_cents,redeemed_at,actor,
    reward_snapshot,eligibility_snapshot,fulfillment_kind,usage_number
  )
  select v_business,v_client_valid,'V145 complete redemption '||n,1,0,
         '2026-09-04 00:00:00+00'::timestamptz + make_interval(secs=>n),v_owner,
         jsonb_build_object('fixture','v145','sequence',n),
         jsonb_build_object('eligible',true),'manual_item',n
    from generate_series(1,105) n;

  insert into public.expenses(
    business_id,branch_id,category,supplier,description,amount_cents,currency,
    fx_rate_to_base,occurred_on,voided_at,note
  ) values
    (v_business,v_branch,'Supplies','Synthetic supplier','V145 FX one',100,'USD',1.5,'2031-08-01',null,'rollback fixture'),
    (v_business,v_branch,'Supplies','Synthetic supplier','V145 FX two',50,'USD',2,'2031-08-20',null,'rollback fixture'),
    (v_business,null,'Overhead','Synthetic accountant','V145 business overhead',300,'SGD',1,'2031-08-15',null,'rollback fixture'),
    (v_business,v_branch,'Rent','Synthetic landlord','V145 September rent',500,'SGD',1,'2031-09-01',null,'rollback fixture'),
    (v_business,v_branch,null,'Synthetic supplier','V145 uncategorised expense',333,'SGD',1,'2031-10-01',null,'rollback fixture'),
    (v_business,v_branch,'Supplies','Synthetic supplier','V145 voided',999,'SGD',1,'2031-08-10','2031-08-11 00:00:00+00','rollback fixture');

  insert into pg_temp.v145_fixture values(
    v_business,v_foreign_business,v_branch,v_other_branch,v_foreign_branch,
    v_owner,v_report_reader,v_frontdesk,v_denied,v_foreign_owner,
    v_customer_user,v_customer_identity,v_customer_link,
    v_client_valid,v_client_reversed,v_client_non_visit,v_client_other_branch,
    v_valid_sale,v_other_branch_sale
  );
end
$v145_fixture$;

grant select on pg_temp.v145_fixture to public;

create or replace function pg_temp.as_v145_user(p_uid uuid,p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',p_uid,'role',p_role)::text,true);
  execute format('set local role %I',p_role);
end
$$;
grant execute on function pg_temp.as_v145_user(uuid,text) to public;

create or replace function pg_temp.expect_v145_error(
  p_sql text,p_label text,p_state text default '42501'
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
grant execute on function pg_temp.expect_v145_error(text,text,text) to public;

do $v145_catalog$
declare
  v_dashboard pg_proc%rowtype;
  v_reports pg_proc%rowtype;
  v_revenue pg_proc%rowtype;
  v_preflight pg_proc%rowtype;
  v_gift_liability pg_proc%rowtype;
  v_billing pg_proc%rowtype;
  v_checkout pg_proc%rowtype;
begin
  select * into strict v_dashboard from pg_proc
   where oid='public.get_dashboard_summary(uuid,date,date,uuid)'::regprocedure;
  select * into strict v_reports from pg_proc
   where oid='public.get_reports_summary(uuid,date,date,uuid)'::regprocedure;
  select * into strict v_revenue from pg_proc
   where oid='public.get_revenue_summary(uuid,date,date,uuid)'::regprocedure;
  select * into strict v_preflight from pg_proc
   where oid='public.require_module_scope_v145(uuid,uuid,text)'::regprocedure;
  select * into strict v_gift_liability from pg_proc
   where oid='app.reports_gift_card_liability_v49b(uuid,uuid)'::regprocedure;
  select * into strict v_billing from pg_proc
   where oid='public.get_business_billing_v124(uuid)'::regprocedure;
  select * into strict v_checkout from pg_proc
   where oid='public.get_self_serve_checkout_v130(uuid)'::regprocedure;

  if not v_dashboard.prosecdef or v_dashboard.provolatile<>'s'
     or coalesce(array_to_string(v_dashboard.proconfig,','),'')<>'search_path=pg_catalog, public, app, pg_temp'
     or position('not exists' in lower(v_dashboard.prosrc))=0
     or position('reversal_of = s.id' in v_dashboard.prosrc)=0 then
    raise exception 'V145 dashboard function attributes or valid-visit formula drifted';
  end if;
  if not v_reports.prosecdef or v_reports.provolatile<>'s'
     or coalesce(array_to_string(v_reports.proconfig,','),'')<>'search_path=pg_catalog, public, app, pg_temp'
     or position('app.require_branch_module_v94(p_business, p_branch, ''reports'', ''r'')' in v_reports.prosrc)=0
     or position('app.can_module_read_at_v94(p_business, branch.id, ''reports'')' in v_reports.prosrc)=0
     or position('explicit_branch_required_for_partial_report_scope' in v_reports.prosrc)=0
     or position('app.reports_gift_card_liability_v49b' in v_reports.prosrc)=0
     or position('public.gift_cards' in v_reports.prosrc)>0 then
    raise exception 'V145 Reports lost the latest read-only/private aggregate contract';
  end if;
  if not v_revenue.prosecdef or v_revenue.provolatile<>'s'
     or coalesce(array_to_string(v_revenue.proconfig,','),'')<>'search_path=pg_catalog, public, app, pg_temp'
     or position('expenses_by_category' in v_revenue.prosrc)=0
     or position('v_monthly' in v_revenue.prosrc)=0 then
    raise exception 'V145 finance aggregate attributes drifted';
  end if;
  if not v_preflight.prosecdef or v_preflight.provolatile<>'s'
     or coalesce(array_to_string(v_preflight.proconfig,','),'')<>'search_path=pg_catalog, public, app, pg_temp'
     or position('app.require_metric_module_scope_v145' in v_preflight.prosrc)=0 then
    raise exception 'V145 browser detail preflight attributes drifted';
  end if;
  if not exists (
    select 1
      from pg_attribute flat
      join pg_attribute revenue
        on revenue.attrelid=flat.attrelid
       and revenue.attname='counts_as_revenue'
       and not revenue.attisdropped
       and revenue.atttypid='boolean'::regtype
     where flat.attrelid='public.sale_commission'::regclass
       and flat.attname='flat_cents'
       and not flat.attisdropped
       and flat.attnum=10
       and revenue.attnum=11
  ) or not exists (
    select 1
     from pg_class relation
     where relation.oid='public.sale_commission'::regclass
       and coalesce(relation.reloptions,'{}'::text[])
           && array['security_invoker=on','security_invoker=true']::text[]
  ) then
    raise exception 'V145 sale_commission lost established flat commission order, immutable revenue treatment or security_invoker';
  end if;
  if not v_gift_liability.prosecdef or v_gift_liability.provolatile<>'s'
     or coalesce(array_to_string(v_gift_liability.proconfig,','),'')<>'search_path=pg_catalog, public, app, pg_temp'
     or position('app.metric_module_scope_available_v145' in v_gift_liability.prosrc)=0 then
    raise exception 'V145 Reports gift-card scalar lost branch-effective authorization';
  end if;
  if not v_billing.prosecdef or v_billing.provolatile<>'s'
     or coalesce(array_to_string(v_billing.proconfig,','),'')<>'search_path=pg_catalog, public, app, pg_temp'
     or position('template-assisted promotion wording' in v_billing.prosrc)=0
     or position('AI-assisted promotion' in v_billing.prosrc)>0 then
    raise exception 'V145 business billing copy overstates the shipped promotion helper';
  end if;
  if not v_checkout.prosecdef or v_checkout.provolatile<>'s'
     or coalesce(array_to_string(v_checkout.proconfig,','),'')<>'search_path=pg_catalog, public, app, pg_temp'
     or position('template-assisted promotion wording' in v_checkout.prosrc)=0
     or position('AI-assisted promotion' in v_checkout.prosrc)>0
     or position('non_refundable_after_payment' in v_checkout.prosrc)=0
     or position('legal_document_version < ''2026-08-03''' in v_checkout.prosrc)=0 then
    raise exception 'V145 checkout reader lost truthful module or refund-policy copy';
  end if;
  if has_function_privilege('anon',v_dashboard.oid,'execute')
     or has_function_privilege('anon',v_reports.oid,'execute')
     or has_function_privilege('anon',v_revenue.oid,'execute')
     or has_function_privilege('anon',v_preflight.oid,'execute')
     or has_function_privilege('anon',v_billing.oid,'execute')
     or has_function_privilege('anon',v_checkout.oid,'execute')
     or not has_function_privilege('authenticated',v_dashboard.oid,'execute')
     or not has_function_privilege('authenticated',v_reports.oid,'execute')
     or not has_function_privilege('authenticated',v_revenue.oid,'execute')
     or not has_function_privilege('authenticated',v_preflight.oid,'execute')
     or not has_function_privilege('authenticated',v_billing.oid,'execute')
     or not has_function_privilege('authenticated',v_checkout.oid,'execute') then
    raise exception 'V145 launch reader function ACLs are not authenticated-only';
  end if;
end
$v145_catalog$;

reset role;
do $v145_checkout_truth$
declare
  f pg_temp.v145_fixture%rowtype;
  v_checkout jsonb;
begin
  select * into f from pg_temp.v145_fixture;
  perform pg_temp.as_v145_user(f.owner_id);
  v_checkout:=public.get_self_serve_checkout_v130(null);
  if v_checkout->'onboarding'<>'null'::jsonb
     or v_checkout->'money_back_days'<>'null'::jsonb
     or v_checkout->>'refund_policy'<>'non_refundable_after_payment'
     or position('template-assisted promotion wording' in (v_checkout->'included_modules')::text)=0
     or position('AI-assisted promotion' in (v_checkout->'included_modules')::text)>0 then
    raise exception 'V145 checkout truth regressed for a prospective owner: %',v_checkout;
  end if;
end
$v145_checkout_truth$;

reset role;
do $v145_dashboard_truth$
declare
  f pg_temp.v145_fixture%rowtype;
  v_summary jsonb;
  v_zero_days integer;
  v_weekday_total integer;
begin
  select * into f from pg_temp.v145_fixture;
  perform pg_temp.as_v145_user(f.owner_id);
  v_summary:=public.get_dashboard_summary(
    f.business_id,date '2026-08-01',date '2026-08-03',f.branch_id
  );

  if (v_summary->>'visits')::integer<>1
     or (v_summary->>'unique_customers')::integer<>1
     or (v_summary->>'revenue_cents')::bigint<>1000
     or (v_summary->>'new_customers')::integer<>4
     or (v_summary->>'points_issued')::integer<>11
     or (v_summary->>'credit_liability_cents')::bigint<>1400 then
    raise exception 'V145 dashboard KPI truth mismatch: %',v_summary;
  end if;
  select count(*) filter(where (item->>'amount_cents')::bigint=0)
    into v_zero_days
    from jsonb_array_elements(v_summary->'revenue_by_day') item;
  select coalesce(sum(value::integer),0)
    into v_weekday_total
    from jsonb_array_elements_text(v_summary->'visits_by_weekday') value;
  if jsonb_array_length(v_summary->'revenue_by_day')<>3
     or v_zero_days<>1
     or v_weekday_total<>1
     or v_summary#>>'{scope,timezone}'<>'Asia/Singapore'
     or v_summary#>>'{scope,visits}'<>'selected_period_and_branch_valid_originals'
     or v_summary#>>'{scope,points_issued}'<>'selected_branch_sale_linked_gross_earn_in_selected_period'
     or v_summary#>>'{scope,credit_liability}'<>'business_wide_current_signed_credit_ledger_with_complete_business_sales_read'
     or (v_summary#>>'{availability,loyalty}')::boolean is distinct from true
     or (v_summary#>>'{availability,credit_liability}')::boolean is distinct from true then
    raise exception 'V145 dashboard series/scope mismatch: %',v_summary;
  end if;
end
$v145_dashboard_truth$;

reset role;
do $v145_dashboard_loyalty_scope_truth$
declare
  f pg_temp.v145_fixture%rowtype;
  v_owner_summary jsonb;
  v_staff_summary jsonb;
  v_business_summary jsonb;
begin
  select * into f from pg_temp.v145_fixture;

  insert into public.platform_module_overrides_v94(
    business_id,branch_scope,module_key,mode,reason,updated_by
  ) values (
    f.business_id,f.branch_id,'loyalty','disabled',
    'V145 synthetic selected-branch Loyalty denial',f.owner_id
  );

  perform pg_temp.as_v145_user(f.owner_id);
  v_owner_summary:=public.get_dashboard_summary(
    f.business_id,date '2026-08-01',date '2026-08-03',f.branch_id
  );
  if v_owner_summary->'points_issued'<>'null'::jsonb
     or (v_owner_summary#>>'{availability,loyalty}')::boolean is distinct from false
     or v_owner_summary#>>'{scope,points_issued}'<>'unavailable_without_complete_loyalty_scope'
     or (v_owner_summary->>'visits')::integer<>1
     or (v_owner_summary->>'revenue_cents')::bigint<>1000 then
    raise exception 'V145 owner Dashboard leaked or distorted disabled Loyalty: %',v_owner_summary;
  end if;

  perform pg_temp.as_v145_user(f.frontdesk_id);
  v_staff_summary:=public.get_dashboard_summary(
    f.business_id,date '2026-08-01',date '2026-08-03',f.branch_id
  );
  if v_staff_summary->'points_issued'<>'null'::jsonb
     or (v_staff_summary#>>'{availability,loyalty}')::boolean is distinct from false
     or v_staff_summary#>>'{scope,points_issued}'<>'unavailable_without_complete_loyalty_scope'
     or (v_staff_summary->>'visits')::integer<>1
     or v_staff_summary->'credit_liability_cents'<>'null'::jsonb
     or (v_staff_summary#>>'{availability,credit_liability}')::boolean is distinct from false
     or v_staff_summary#>>'{scope,credit_liability}'<>'unavailable_without_complete_business_sales_scope' then
    raise exception 'V145 staff Dashboard leaked or distorted disabled Loyalty: %',v_staff_summary;
  end if;

  reset role;
  delete from public.platform_module_overrides_v94
   where business_id=f.business_id
     and branch_scope=f.branch_id
     and module_key='loyalty';
  insert into public.platform_module_overrides_v94(
    business_id,branch_scope,module_key,mode,reason,updated_by
  ) values (
    f.business_id,f.other_branch_id,'loyalty','disabled',
    'V145 synthetic partial business Loyalty denial',f.owner_id
  );

  perform pg_temp.as_v145_user(f.owner_id);
  v_business_summary:=public.get_dashboard_summary(
    f.business_id,date '2026-08-01',date '2026-08-03',null
  );
  if v_business_summary->'points_issued'<>'null'::jsonb
     or (v_business_summary#>>'{availability,loyalty}')::boolean is distinct from false
     or v_business_summary#>>'{scope,points_issued}'<>'unavailable_without_complete_loyalty_scope'
     or (v_business_summary->>'visits')::integer<>2
     or (v_business_summary->>'revenue_cents')::bigint<>5000 then
    raise exception 'V145 consolidated Dashboard exposed partial Loyalty: %',v_business_summary;
  end if;

  reset role;
  delete from public.platform_module_overrides_v94
   where business_id=f.business_id
     and branch_scope=f.other_branch_id
     and module_key='loyalty';
end
$v145_dashboard_loyalty_scope_truth$;

reset role;
do $v145_staff_performance_truth$
declare
  f pg_temp.v145_fixture%rowtype;
  v_ledger_rows bigint;
  v_revenue_rows bigint;
  v_signed_revenue bigint;
  v_gift_rows bigint;
  v_large_rows bigint;
  v_large_revenue bigint;
begin
  select * into f from pg_temp.v145_fixture;
  perform pg_temp.as_v145_user(f.owner_id);
  select count(*),
         count(*) filter(where commission.counts_as_revenue),
         coalesce(sum(commission.amount_cents) filter(where commission.counts_as_revenue),0),
         count(*) filter(where commission.kind='gift_card' and not commission.counts_as_revenue)
    into v_ledger_rows,v_revenue_rows,v_signed_revenue,v_gift_rows
    from public.sale_commission commission
   where commission.business_id=f.business_id
     and commission.occurred_at>='2026-08-01 00:00:00+00'
     and commission.occurred_at<'2026-08-03 00:00:00+00';
  if v_ledger_rows<>5 or v_revenue_rows<>4 or v_signed_revenue<>5000 or v_gift_rows<>1 then
    raise exception 'V145 staff revenue treatment mismatch: ledger %, revenue rows %, signed %, gift %',
      v_ledger_rows,v_revenue_rows,v_signed_revenue,v_gift_rows;
  end if;
  select count(*),coalesce(sum(commission.amount_cents) filter(where commission.counts_as_revenue),0)
    into v_large_rows,v_large_revenue
    from public.sale_commission commission
   where commission.business_id=f.business_id
     and commission.occurred_at>='2031-07-31 16:00:00+00'
     and commission.occurred_at<'2031-08-01 16:00:00+00';
  if v_large_rows<>1001 or v_large_revenue<>1001 then
    raise exception 'V145 staff projection was capped or misclassified: rows %, revenue %',
      v_large_rows,v_large_revenue;
  end if;
end
$v145_staff_performance_truth$;

reset role;
do $v145_reports_truth$
declare
  f pg_temp.v145_fixture%rowtype;
  v_summary jsonb;
  v_owner_summary jsonb;
begin
  select * into f from pg_temp.v145_fixture;
  perform pg_temp.as_v145_user(f.report_reader_id);
  v_summary:=public.get_reports_summary(
    f.business_id,date '2026-08-01',date '2026-08-03',f.branch_id
  );
  if coalesce((v_summary#>>'{revenue_by_kind,service}')::bigint,-1)<>1000
     or coalesce((v_summary#>>'{non_revenue_by_kind,gift_card}')::bigint,-1)<>3000
     or v_summary->'points_by_type'<>'null'::jsonb
     or v_summary->'gift_card_liability_cents'<>'null'::jsonb
     or v_summary->'active_memberships'<>'null'::jsonb
     or coalesce((v_summary#>>'{reversal_reconciliation,compensating_rows}')::integer,-1)<>1
     or coalesce((v_summary#>>'{reversal_reconciliation,reversed_revenue_cents}')::bigint,-1)<>2000
     or coalesce((v_summary#>>'{reversal_reconciliation,net_revenue_cents}')::bigint,-1)<>1000
     or (v_summary#>>'{availability,sales_export}')::boolean is distinct from false
     or (v_summary#>>'{availability,clients_export}')::boolean is distinct from false
     or (v_summary#>>'{availability,loyalty}')::boolean is distinct from false
     or (v_summary#>>'{availability,gift_cards}')::boolean is distinct from false
     or (v_summary#>>'{availability,memberships}')::boolean is distinct from false
     or (v_summary#>>'{availability,credit_liability}')::boolean is distinct from false
     or v_summary->'credit_liability_cents'<>'null'::jsonb
     or v_summary#>>'{scope,credit_liability}' is distinct from 'unavailable_without_complete_business_reports_and_sales_source_scope'
     or v_summary#>>'{scope,gift_card_liability}' is distinct from 'unavailable_without_complete_giftcards_scope'
     or v_summary#>>'{scope,active_memberships}' is distinct from 'unavailable_without_complete_memberships_scope'
     or v_summary#>>'{scope,sales}' is distinct from 'selected_period_and_branch_signed_ledger'
     or v_summary#>>'{scope,points}' is distinct from 'unavailable_without_complete_loyalty_scope' then
    raise exception 'V145 Reports values/scopes mismatch: %',v_summary;
  end if;
  perform pg_temp.as_v145_user(f.owner_id);
  v_owner_summary:=public.get_reports_summary(
    f.business_id,date '2026-08-01',date '2026-08-03',f.branch_id
  );
  if (v_owner_summary#>>'{availability,sales_export}')::boolean is distinct from true
     or (v_owner_summary#>>'{availability,clients_export}')::boolean is distinct from true
     or (v_owner_summary#>>'{availability,loyalty}')::boolean is distinct from true
     or (v_owner_summary#>>'{availability,gift_cards}')::boolean is distinct from true
     or (v_owner_summary#>>'{availability,memberships}')::boolean is distinct from true
     or (v_owner_summary#>>'{availability,credit_liability}')::boolean is distinct from false
     or v_owner_summary->'credit_liability_cents'<>'null'::jsonb
     or coalesce((v_owner_summary#>>'{points_by_type,earn}')::integer,-1)<>33
     or (v_owner_summary->'gift_card_liability_cents')='null'::jsonb
     or (v_owner_summary->'active_memberships')='null'::jsonb
     or v_owner_summary#>>'{scope,credit_liability}' is distinct from 'unavailable_without_complete_business_reports_and_sales_source_scope'
     or v_owner_summary#>>'{scope,gift_card_liability}' is distinct from 'business_wide_current'
     or v_owner_summary#>>'{scope,active_memberships}' is distinct from 'business_wide_current'
     or v_owner_summary#>>'{scope,points}' is distinct from 'business_wide_selected_period' then
    raise exception 'V145 owner Reports availability/value mismatch: %',v_owner_summary;
  end if;
end
$v145_reports_truth$;

reset role;
do $v145_complete_business_credit_authority$
declare
  f pg_temp.v145_fixture%rowtype;
  v_summary jsonb;
begin
  select * into f from pg_temp.v145_fixture;
  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  delete from public.platform_module_overrides_v94
   where business_id=f.business_id
     and branch_scope=f.other_branch_id
     and module_key='reports';
  perform pg_temp.as_v145_user(f.owner_id);
  v_summary:=public.get_reports_summary(
    f.business_id,date '2026-08-01',date '2026-08-03',f.branch_id
  );
  if (v_summary#>>'{availability,credit_liability}')::boolean is distinct from true
     or (v_summary->>'credit_liability_cents')::bigint<>1400
     or v_summary#>>'{scope,credit_liability}'<>'business_wide_current_with_complete_business_reports_and_sales_source_scope' then
    raise exception 'V145 whole-business owner credit liability mismatch: %',v_summary;
  end if;
  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  insert into public.platform_module_overrides_v94(
    business_id,branch_scope,module_key,mode,reason,updated_by
  ) values(
    f.business_id,f.other_branch_id,'reports','disabled',
    'V145 synthetic branch-effective Reports denial',f.owner_id
  );
end
$v145_complete_business_credit_authority$;

reset role;
do $v145_reports_enabled_branch_over_disabled_firm$
declare
  f pg_temp.v145_fixture%rowtype;
  v_summary jsonb;
begin
  select * into f from pg_temp.v145_fixture;
  insert into public.platform_module_overrides_v94(
    business_id,branch_scope,module_key,mode,reason,updated_by
  ) values
    (f.business_id,null,'reports','disabled','V145 synthetic disabled Reports firm',f.owner_id),
    (f.business_id,f.branch_id,'reports','r','V145 synthetic enabled Reports branch',f.owner_id);

  perform pg_temp.as_v145_user(f.report_reader_id);
  v_summary:=public.get_reports_summary(
    f.business_id,date '2026-08-01',date '2026-08-03',f.branch_id
  );
  if coalesce((v_summary#>>'{revenue_by_kind,service}')::bigint,-1)<>1000
     or (v_summary#>>'{availability,sales_export}')::boolean is distinct from false then
    raise exception 'V145 Reports enabled branch over disabled firm failed: %',v_summary;
  end if;
  perform pg_temp.expect_v145_error(format(
    'select public.get_reports_summary(%L,date ''2026-08-01'',date ''2026-08-03'',null)',
    f.business_id
  ),'all-branch Reports while firm is disabled');

  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  delete from public.platform_module_overrides_v94
   where business_id=f.business_id and module_key='reports'
     and (branch_scope is null or branch_scope=f.branch_id);
end
$v145_reports_enabled_branch_over_disabled_firm$;

reset role;
do $v145_finance_truth$
declare
  f pg_temp.v145_fixture%rowtype;
  v_aug jsonb;
  v_all_aug jsonb;
  v_both jsonb;
  v_uncategorised jsonb;
  v_month_count integer;
begin
  select * into f from pg_temp.v145_fixture;
  perform pg_temp.as_v145_user(f.owner_id);
  v_aug:=public.get_revenue_summary(
    f.business_id,date '2031-08-01',date '2031-08-31',f.branch_id
  )::jsonb;
  if (v_aug->>'revenue_accrual_cents')::bigint<>1001
     or (v_aug->>'expenses_cents')::bigint<>250
     or (v_aug->>'net_accrual_cents')::bigint<>751
     or (v_aug#>>'{expenses_by_category,Supplies}')::bigint<>250
     or (v_aug#>>'{monthly,2031-08,revenue_accrual_cents}')::bigint<>1001
     or (v_aug#>>'{monthly,2031-08,expenses_cents}')::bigint<>250
     or v_aug->>'timezone'<>'Asia/Singapore' then
    raise exception 'V145 uncapped/FX August finance mismatch: %',v_aug;
  end if;

  v_all_aug:=public.get_revenue_summary(
    f.business_id,date '2031-08-01',date '2031-08-31',null
  )::jsonb;
  if (v_all_aug->>'revenue_accrual_cents')::bigint<>1001
     or (v_all_aug->>'expenses_cents')::bigint<>550
     or (v_all_aug->>'net_accrual_cents')::bigint<>451
     or v_all_aug->>'expenses_scope'<>'all_business_expenses'
     or (v_all_aug->>'business_wide_overhead_excluded')::boolean is distinct from false then
    raise exception 'V145 all-branch overhead finance mismatch: %',v_all_aug;
  end if;

  v_both:=public.get_revenue_summary(
    f.business_id,date '2031-08-01',date '2031-09-30',f.branch_id
  )::jsonb;
  select count(*) into v_month_count from jsonb_object_keys(v_both->'monthly');
  if v_month_count<>2
     or (v_both#>>'{monthly,2031-08,revenue_accrual_cents}')::bigint<>1001
     or (v_both#>>'{monthly,2031-09,revenue_accrual_cents}')::bigint<>200
     or (v_both#>>'{monthly,2031-09,expenses_cents}')::bigint<>500 then
    raise exception 'V145 Singapore monthly boundary mismatch: %',v_both;
  end if;

  v_uncategorised:=public.get_revenue_summary(
    f.business_id,date '2031-10-01',date '2031-10-31',f.branch_id
  )::jsonb;
  if (v_uncategorised->>'expenses_cents')::bigint<>333
     or (v_uncategorised->>'net_accrual_cents')::bigint<>-333
     or (v_uncategorised#>>'{expenses_by_category,Uncategorised}')::bigint<>333
     or (v_uncategorised#>>'{monthly,2031-10,expenses_cents}')::bigint<>333 then
    raise exception 'V145 null-category P&L reconciliation mismatch: %',v_uncategorised;
  end if;
end
$v145_finance_truth$;

reset role;
do $v145_preflight_and_range_bounds$
declare
  f pg_temp.v145_fixture%rowtype;
  v_ok jsonb;
begin
  select * into f from pg_temp.v145_fixture;
  perform pg_temp.as_v145_user(f.owner_id);
  foreach v_ok in array array[
    public.require_module_scope_v145(f.business_id,f.branch_id,'reports'),
    public.require_module_scope_v145(f.business_id,f.branch_id,'sales'),
    public.require_module_scope_v145(f.business_id,f.branch_id,'dailyreport'),
    public.require_module_scope_v145(f.business_id,f.branch_id,'staffperf'),
    public.require_module_scope_v145(f.business_id,f.branch_id,'appointments'),
    public.require_module_scope_v145(f.business_id,f.branch_id,'clients'),
    public.require_module_scope_v145(f.business_id,f.branch_id,'expenses'),
    public.require_module_scope_v145(f.business_id,f.branch_id,'retention'),
    public.require_module_scope_v145(f.business_id,f.branch_id,'loyalty'),
    public.require_module_scope_v145(f.business_id,f.branch_id,'memberships'),
    public.require_module_scope_v145(f.business_id,f.branch_id,'packages'),
    public.require_module_scope_v145(f.business_id,f.branch_id,'referrals')
  ] loop
    if v_ok->>'status'<>'ok' then raise exception 'V145 preflight did not return ok: %',v_ok;end if;
  end loop;

  perform pg_temp.expect_v145_error(format(
    'select public.get_dashboard_summary(%L,date ''2020-01-01'',date ''2025-01-01'',%L)',
    f.business_id,f.branch_id
  ),'dashboard over 1827 days','22023');
  perform pg_temp.expect_v145_error(format(
    'select public.get_reports_summary(%L,date ''2020-01-01'',date ''2025-01-01'',%L)',
    f.business_id,f.branch_id
  ),'Reports over 1827 days','22023');
  perform pg_temp.expect_v145_error(format(
    'select public.get_revenue_summary(%L,date ''2020-01-01'',date ''2025-01-01'',%L)',
    f.business_id,f.branch_id
  ),'P&L over 1827 days','22023');
  perform pg_temp.expect_v145_error(format(
    'select public.require_module_scope_v145(%L,%L,null)',f.business_id,f.branch_id
  ),'null metric module','22023');

  perform pg_temp.as_v145_user(f.report_reader_id);
  perform pg_temp.expect_v145_error(format(
    'select public.require_module_scope_v145(%L,%L,''reports'')',f.business_id,f.branch_id
  ),'Reports-only reader cannot open raw Reports detail');
end
$v145_preflight_and_range_bounds$;

reset role;
do $v145_complete_operational_lists$
declare
  f pg_temp.v145_fixture%rowtype;
  v_feedback_first jsonb;
  v_feedback_second jsonb;
  v_feedback_last jsonb;
  v_feedback_repeat jsonb;
  v_feedback_open jsonb;
  v_gifts_first jsonb;
  v_gifts_second jsonb;
  v_gifts_last jsonb;
  v_gifts_repeat jsonb;
  v_redemption_count integer;
  v_latest_reward text;
  v_reversal_unbounded jsonb;
  v_reversal_bounded jsonb;
  v_profile_scope jsonb;
begin
  select * into f from pg_temp.v145_fixture;

  -- This front-desk user is assigned only to Orchard. These operational customer and
  -- gift-card lists are business records, not all-branch metrics; requiring visibility
  -- of Tampines would regress the existing staff workflow.
  perform pg_temp.as_v145_user(f.frontdesk_id);
  foreach v_profile_scope in array array[
    public.require_module_scope_v145(f.business_id,f.branch_id,'clients'),
    public.require_module_scope_v145(f.business_id,f.branch_id,'sales'),
    public.require_module_scope_v145(f.business_id,f.branch_id,'loyalty')
  ] loop
    if v_profile_scope->>'status'<>'ok' then
      raise exception 'V145 assigned-branch Customer 360 preflight did not return ok: %',
        v_profile_scope;
    end if;
  end loop;
  perform pg_temp.expect_v145_error(format(
    'select public.require_module_scope_v145(%L,null,''sales'')',f.business_id
  ),'Orchard-only front desk cannot claim business-wide Customer 360 Sales scope');
  v_feedback_first:=public.staff_list_visit_feedback_v145(
    f.business_id,null,100,0,null
  );
  v_feedback_second:=public.staff_list_visit_feedback_v145(
    f.business_id,null,100,100,null
  );
  v_feedback_last:=public.staff_list_visit_feedback_v145(
    f.business_id,null,100,200,null
  );
  v_feedback_repeat:=public.staff_list_visit_feedback_v145(
    f.business_id,null,100,0,null
  );
  if (v_feedback_first->>'total')::integer<>205
     or jsonb_array_length(v_feedback_first->'feedback')<>100
     or jsonb_array_length(v_feedback_second->'feedback')<>100
     or jsonb_array_length(v_feedback_last->'feedback')<>5
     or v_feedback_first<>v_feedback_repeat
     or v_feedback_first#>>'{feedback,0,id}'=v_feedback_second#>>'{feedback,0,id}'
     or v_feedback_first#>>'{feedback,0,created_at}'<=v_feedback_first#>>'{feedback,99,created_at}' then
    raise exception 'V145 complete/stable feedback paging mismatch: %, %, %',
      v_feedback_first,v_feedback_second,v_feedback_last;
  end if;
  v_feedback_open:=public.staff_list_visit_feedback_v145(
    f.business_id,'open',500,-10,f.client_valid_id
  );
  if (v_feedback_open->>'total')::integer<>103
     or (v_feedback_open->>'limit')::integer<>100
     or (v_feedback_open->>'offset')::integer<>0
     or exists (
       select 1 from jsonb_array_elements(v_feedback_open->'feedback') row
        where row->>'recovery_status'<>'open'
          or (row->>'client_id')::uuid<>f.client_valid_id
     ) then
    raise exception 'V145 feedback filters/clamps mismatch: %',v_feedback_open;
  end if;
  perform pg_temp.expect_v145_error(format(
    'select public.staff_list_visit_feedback_v145(%L,''unsupported'',10,0,null)',
    f.business_id
  ),'invalid feedback status','22023');
  perform pg_temp.expect_v145_error(format(
    'select public.staff_list_visit_feedback_v145(%L,null,10,0,%L)',
    f.business_id,'14500000-0000-4000-8000-000000000099'
  ),'foreign feedback customer');

  v_gifts_first:=public.staff_list_gift_cards_v145(f.business_id,100,0);
  v_gifts_second:=public.staff_list_gift_cards_v145(f.business_id,100,100);
  v_gifts_last:=public.staff_list_gift_cards_v145(f.business_id,100,200);
  v_gifts_repeat:=public.staff_list_gift_cards_v145(f.business_id,100,0);
  if (v_gifts_first->>'total')::integer<>205
     or jsonb_array_length(v_gifts_first->'cards')<>100
     or jsonb_array_length(v_gifts_second->'cards')<>100
     or jsonb_array_length(v_gifts_last->'cards')<>5
     or v_gifts_first<>v_gifts_repeat
     or v_gifts_first#>>'{cards,0,gift_card_id}'=v_gifts_second#>>'{cards,0,gift_card_id}'
     or exists (
       select 1 from jsonb_array_elements(v_gifts_first->'cards') card
        where card ? 'code' or length(card->>'code_suffix')<>4
     ) then
    raise exception 'V145 complete/suffix-only gift-card paging mismatch: %, %, %',
      v_gifts_first,v_gifts_second,v_gifts_last;
  end if;
  if jsonb_array_length((public.staff_list_gift_cards_v145(
       f.business_id,0,-1
     ))->'cards')<>1 then
    raise exception 'V145 gift-card limit/offset clamp drifted';
  end if;

  select count(*)
    into v_redemption_count
    from public.list_customer_redemption_history_v145(
      f.business_id,f.client_valid_id
    );
  select reward_name
    into v_latest_reward
    from public.list_customer_redemption_history_v145(
      f.business_id,f.client_valid_id
    )
   order by redeemed_at desc,id desc
   limit 1;
  if v_redemption_count<>105 or v_latest_reward<>'V145 complete redemption 105' then
    raise exception 'V145 complete redemption history mismatch: %, %',
      v_redemption_count,v_latest_reward;
  end if;
  perform pg_temp.expect_v145_error(format(
    'select * from public.list_customer_redemption_history_v145(%L,%L)',
    f.business_id,'14500000-0000-4000-8000-000000000099'
  ),'foreign redemption customer');

  perform pg_temp.expect_v145_error(format(
    'select public.staff_list_gift_cards_v145(%L,10,0)',f.foreign_business_id
  ),'front desk foreign gift cards');
  perform pg_temp.expect_v145_error(format(
    'select public.staff_list_visit_feedback_v145(%L,null,10,0,null)',
    f.foreign_business_id
  ),'front desk foreign feedback');
  perform pg_temp.expect_v145_error(format(
    'select * from public.list_customer_redemption_history_v145(%L,%L)',
    f.foreign_business_id,f.client_valid_id
  ),'front desk foreign redemptions');

  perform pg_temp.as_v145_user(f.denied_id);
  perform pg_temp.expect_v145_error(format(
    'select public.staff_list_gift_cards_v145(%L,10,0)',f.business_id
  ),'inactive staff gift cards');
  perform pg_temp.expect_v145_error(format(
    'select public.staff_list_visit_feedback_v145(%L,null,10,0,null)',f.business_id
  ),'inactive staff feedback');
  perform pg_temp.expect_v145_error(format(
    'select * from public.list_customer_redemption_history_v145(%L,%L)',
    f.business_id,f.client_valid_id
  ),'inactive staff redemptions');

  perform pg_temp.as_v145_user(f.owner_id);
  v_reversal_unbounded:=public.staff_get_reversal_workflows(
    f.business_id,f.client_valid_id,0,'all'
  );
  v_reversal_bounded:=public.staff_get_reversal_workflows(
    f.business_id,f.client_valid_id,100,'all'
  );
  if (v_reversal_unbounded->>'bounded')::boolean is distinct from false
     or (v_reversal_unbounded->>'may_have_more')::boolean is distinct from false
     or jsonb_array_length(v_reversal_unbounded->'sales')<205
     or jsonb_array_length(v_reversal_unbounded->'redemptions')<>105
     or (v_reversal_bounded->>'bounded')::boolean is distinct from true
     or (v_reversal_bounded->>'may_have_more')::boolean is distinct from true
     or jsonb_array_length(v_reversal_bounded->'sales')<>100
     or jsonb_array_length(v_reversal_bounded->'redemptions')<>100 then
    raise exception 'V145 reversal bounded/unbounded contract mismatch: %, %',
      v_reversal_unbounded,v_reversal_bounded;
  end if;
end
$v145_complete_operational_lists$;

reset role;
do $v145_incomplete_scope_truth$
declare
  f pg_temp.v145_fixture%rowtype;
  v_summary jsonb;
begin
  select * into f from pg_temp.v145_fixture;
  insert into public.platform_module_overrides_v94(
    business_id,branch_scope,module_key,mode,reason,updated_by
  ) values (
    f.business_id,f.other_branch_id,'clients','disabled',
    'V145 synthetic incomplete Clients scope',f.owner_id
  );
  perform pg_temp.as_v145_user(f.owner_id);
  v_summary:=public.get_dashboard_summary(
    f.business_id,date '2026-08-01',date '2026-08-03',f.branch_id
  );
  if (v_summary#>>'{availability,sales}')::boolean is distinct from true
     or (v_summary#>>'{availability,clients}')::boolean is distinct from false
     or v_summary->'new_customers'<>'null'::jsonb
     or v_summary->'age_counts'<>'null'::jsonb then
    raise exception 'V145 Dashboard replaced incomplete Clients scope with data: %',v_summary;
  end if;
  perform pg_temp.expect_v145_error(format(
    'select public.require_module_scope_v145(%L,null,''clients'')',f.business_id
  ),'all-branch Clients preflight with one disabled branch');

  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  insert into public.platform_module_overrides_v94(
    business_id,branch_scope,module_key,mode,reason,updated_by
  ) values (
    f.business_id,f.other_branch_id,'sales','disabled',
    'V145 synthetic incomplete Sales scope',f.owner_id
  );
  perform pg_temp.as_v145_user(f.owner_id);
  v_summary:=public.get_dashboard_summary(
    f.business_id,date '2026-08-01',date '2026-08-03',f.other_branch_id
  );
  if (v_summary#>>'{availability,sales}')::boolean is distinct from false
     or v_summary ? 'visits' or v_summary ? 'revenue_cents' then
    raise exception 'V145 Dashboard replaced disabled Sales scope with zeros: %',v_summary;
  end if;
  v_summary:=public.get_dashboard_summary(
    f.business_id,date '2026-08-01',date '2026-08-03',null
  );
  if (v_summary#>>'{availability,sales}')::boolean is distinct from false then
    raise exception 'V145 all-branch Dashboard did not reject partial Sales scope: %',v_summary;
  end if;
  perform pg_temp.expect_v145_error(format(
    'select public.require_module_scope_v145(%L,null,''dailyreport'')',f.business_id
  ),'all-branch Daily report with one disabled Sales branch');
  perform pg_temp.expect_v145_error(format(
    'select public.require_module_scope_v145(%L,null,''staffperf'')',f.business_id
  ),'all-branch Staff performance with one disabled Sales branch');
  perform pg_temp.expect_v145_error(format(
    'select public.require_module_scope_v145(%L,null,''retention'')',f.business_id
  ),'all-branch retention with incomplete Clients and Sales');

  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  insert into public.platform_module_overrides_v94(
    business_id,branch_scope,module_key,mode,reason,updated_by
  ) values (
    f.business_id,f.other_branch_id,'expenses','disabled',
    'V145 synthetic incomplete Expenses scope',f.owner_id
  );
  perform pg_temp.as_v145_user(f.owner_id);
  perform pg_temp.expect_v145_error(format(
    'select public.require_module_scope_v145(%L,null,''expenses'')',f.business_id
  ),'all-branch Expenses with one disabled branch');
  perform pg_temp.expect_v145_error(format(
    'select public.get_revenue_summary(%L,date ''2031-08-01'',date ''2031-08-31'',null)',f.business_id
  ),'all-branch P&L with incomplete Sales and Expenses');

  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  insert into public.platform_module_overrides_v94(
    business_id,branch_scope,module_key,mode,reason,updated_by
  ) values (
    f.business_id,f.branch_id,'pnl','disabled',
    'V145 synthetic disabled P&L branch',f.owner_id
  );
  perform pg_temp.as_v145_user(f.owner_id);
  perform pg_temp.expect_v145_error(format(
    'select public.get_revenue_summary(%L,date ''2031-08-01'',date ''2031-08-31'',%L)',
    f.business_id,f.branch_id
  ),'P&L-disabled branch');

  -- This block proves fail-closed behaviour by changing effective module state.
  -- Restore only its synthetic overrides before later owner/staff/customer path
  -- assertions so those tests exercise the normal published workspace rather than
  -- inheriting a deliberately incomplete scope from this negative fixture.
  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  delete from public.platform_module_overrides_v94
   where business_id=f.business_id
     and (
       (branch_scope=f.other_branch_id and module_key in ('clients','sales','expenses'))
       or (branch_scope=f.branch_id and module_key='pnl')
     );
end
$v145_incomplete_scope_truth$;

reset role;
do $v145_studio_launch_guards$
declare
  f pg_temp.v145_fixture%rowtype;
  v_base uuid;
  v_bad_draft uuid;
  v_active_after_pause uuid;
  v_nonlive_rule uuid := '14500000-0000-4000-8000-000000000081';
  v_live_rule uuid := '14500000-0000-4000-8000-000000000082';
  v_no_owner_business uuid := '14500000-0000-4000-8000-000000000083';
  v_no_owner_config uuid := '14500000-0000-4000-8000-000000000084';
  v_no_owner_rule uuid := '14500000-0000-4000-8000-000000000085';
  v_snapshot_before text;
  v_rule_count_before integer;
  v_version_count_before integer;
  v_result jsonb;
begin
  select * into f from pg_temp.v145_fixture;

  -- Build a normal published loyalty base only after metric assertions, so sale fixtures
  -- above remain independent of loyalty earning triggers.
  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  perform set_config('app.v79_system_transition','on',true);
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,recommendation_source
  ) values(
    f.business_id,'points',true,'classic','published','v145_launch_guard_fixture'
  );
  perform set_config('app.v79_system_transition','',true);
  select active_config_version_id into v_base
    from public.businesses where id=f.business_id;
  if v_base is null then
    raise exception 'V145 Studio guard fixture did not create a published base';
  end if;
  if app.ps1c2_effect_state(f.business_id,'tier_multiplier')='live'
     or app.ps1c2_effect_state(f.business_id,'apply_discount_amount')<>'live' then
    raise exception 'V145 Studio effect-state fixture drifted: tier %, discount %',
      app.ps1c2_effect_state(f.business_id,'tier_multiplier'),
      app.ps1c2_effect_state(f.business_id,'apply_discount_amount');
  end if;

  -- Recreate the only state this migration must reconcile: an older immutable published
  -- config containing one active incomplete action and one genuinely live action.
  execute 'alter table public.program_rules disable trigger trg_program_rule_version_guard';
  with candidate(rule_id,name,if_conditions,then_effects) as (
    values
      (v_nonlive_rule,'V145 legacy incomplete tier action',
       jsonb_build_array(jsonb_build_object('field','amount_cents','op','eq','value',5100)),
       jsonb_build_array(jsonb_build_object('effect_type','tier_multiplier','multiplier',2))),
      (v_live_rule,'V145 legacy live discount action',
       jsonb_build_array(jsonb_build_object('field','amount_cents','op','eq','value',5200)),
       jsonb_build_array(jsonb_build_object('effect_type','apply_discount_amount','amount_cents',100)))
  )
  insert into public.program_rules(
    rule_id,config_version_id,business_id,schema_version,name,active,when_event,
    if_conditions,then_effects,rule_hash
  )
  select candidate.rule_id,v_base,f.business_id,1,candidate.name,true,'sale.completed',
         candidate.if_conditions,candidate.then_effects,
         app.program_rule_hash(jsonb_build_object(
           'schema_version',1,'when_event','sale.completed',
           'if_conditions',candidate.if_conditions,'then_effects',candidate.then_effects,
           'with_params','{}'::jsonb,'during_schedule','{}'::jsonb,
           'using_stacking','{}'::jsonb
         ))
    from candidate;
  execute 'alter table public.program_rules enable trigger trg_program_rule_version_guard';

  if app.reconcile_v145_incomplete_program_rule_pauses()<>1
     or app.reconcile_v145_incomplete_program_rule_pauses()<>0 then
    raise exception 'V145 incomplete-rule pause reconciliation is not complete and idempotent';
  end if;
  if (select count(*) from public.studio_rule_emergency_pauses
       where business_id=f.business_id and rule_id=v_nonlive_rule and lifted_at is null)<>1
     or exists(select 1 from public.studio_rule_emergency_pauses
       where business_id=f.business_id and rule_id=v_live_rule and lifted_at is null)
     or exists(select 1 from public.studio_rule_emergency_pauses
       where business_id=f.business_id and rule_id=v_nonlive_rule
         and actor<>'00000000-0000-0000-0000-000000000000'::uuid)
     or not exists(select 1 from public.audit_log
       where business_id=f.business_id and entity_id=v_nonlive_rule
         and action='STUDIO_RULE_EMERGENCY_PAUSE'
         and actor='00000000-0000-0000-0000-000000000000'::uuid
         and detail->>'source'='v145_launch_reconciliation') then
    raise exception 'V145 reconciliation did not pause exactly the incomplete active rule';
  end if;

  perform pg_temp.as_v145_user(f.owner_id);
  perform pg_temp.expect_v145_error(format(
    'select public.lift_emergency_pause(%L,%L,''must remain stopped'')',
    f.business_id,v_nonlive_rule
  ),'lift incomplete advanced-rule pause','55000');
  if not exists(select 1 from public.studio_rule_emergency_pauses
       where business_id=f.business_id and rule_id=v_nonlive_rule and lifted_at is null) then
    raise exception 'V145 rejected incomplete-rule lift still mutated the pause';
  end if;

  -- An older active incomplete rule cannot pass the draft publish boundary. The current
  -- published version and the rejected draft must remain unchanged.
  v_bad_draft:=(public.create_loyalty_config_draft(
    f.business_id,v_base,'v145_incomplete_publish_probe'
  )::jsonb->>'version_id')::uuid;
  select snapshot_hash into v_snapshot_before
    from public.firm_config_versions where id=v_bad_draft;
  select count(*) into v_rule_count_before
    from public.program_rules where config_version_id=v_bad_draft;
  perform pg_temp.expect_v145_error(format(
    'select public.publish_loyalty_config(%L)',v_bad_draft
  ),'publish active incomplete advanced rule','55000');
  if (select active_config_version_id from public.businesses where id=f.business_id)<>v_base
     or (select status from public.firm_config_versions where id=v_base)<>'published'
     or (select status from public.firm_config_versions where id=v_bad_draft)<>'draft' then
    raise exception 'V145 rejected incomplete publish mutated configuration authority';
  end if;

  -- The frozen authoring RPCs fail without changing the draft hash or rule set.
  perform pg_temp.expect_v145_error(format(
    'select public.save_program_rule_draft(%L,%L,%L::jsonb,%L)',
    v_bad_draft,v_nonlive_rule,'{}',v_snapshot_before
  ),'save frozen advanced-rule draft','55000');
  perform pg_temp.expect_v145_error(format(
    'select public.delete_program_rule_draft(%L,%L,%L)',
    v_bad_draft,v_nonlive_rule,v_snapshot_before
  ),'delete frozen advanced-rule draft','55000');
  if (select snapshot_hash from public.firm_config_versions where id=v_bad_draft)<>v_snapshot_before
     or (select count(*) from public.program_rules where config_version_id=v_bad_draft)<>v_rule_count_before then
    raise exception 'V145 frozen authoring RPC mutated a draft before refusing it';
  end if;

  -- Pausing the incomplete rule is allowed. Resuming it is refused atomically: no new
  -- config version and no active-config pointer movement may survive the error.
  v_result:=public.set_studio_rule_active(f.business_id,v_nonlive_rule,false);
  if (v_result->>'changed')::boolean is distinct from true then
    raise exception 'V145 could not pause an incomplete historical rule: %',v_result;
  end if;
  select active_config_version_id into v_active_after_pause
    from public.businesses where id=f.business_id;
  if coalesce((select active from public.program_rules
       where business_id=f.business_id and config_version_id=v_active_after_pause
         and rule_id=v_nonlive_rule),true) then
    raise exception 'V145 incomplete rule remained active after an explicit pause';
  end if;
  v_result:=public.lift_emergency_pause(
    f.business_id,v_nonlive_rule,'current version is safely inactive'
  );
  if (v_result->>'lifted')::boolean is distinct from true then
    raise exception 'V145 historical incomplete row incorrectly blocked a safe current-state lift: %',
      v_result;
  end if;
  select count(*) into v_version_count_before
    from public.firm_config_versions where business_id=f.business_id;
  perform pg_temp.expect_v145_error(format(
    'select public.set_studio_rule_active(%L,%L,true)',f.business_id,v_nonlive_rule
  ),'resume incomplete advanced rule','55000');
  if (select active_config_version_id from public.businesses where id=f.business_id)<>v_active_after_pause
     or (select count(*) from public.firm_config_versions where business_id=f.business_id)<>v_version_count_before
     or coalesce((select active from public.program_rules
          where business_id=f.business_id and config_version_id=v_active_after_pause
            and rule_id=v_nonlive_rule),true) then
    raise exception 'V145 rejected incomplete resume left persistent state behind';
  end if;

  -- Existing fully-live rules retain their established controls: emergency pause/lift
  -- and normal versioned pause/resume all remain functional.
  v_result:=public.emergency_pause_studio_rule(
    f.business_id,v_live_rule,'V145 live-rule pause check'
  );
  if (v_result->>'status')<>'ok' then
    raise exception 'V145 live rule emergency pause failed: %',v_result;
  end if;
  if not exists(select 1 from public.studio_rule_emergency_pauses
       where business_id=f.business_id and rule_id=v_live_rule and lifted_at is null
         and actor=f.owner_id) then
    raise exception 'V145 owner-initiated emergency pause lost owner provenance';
  end if;
  v_result:=public.lift_emergency_pause(
    f.business_id,v_live_rule,'V145 live-rule lift check'
  );
  if (v_result->>'lifted')::boolean is distinct from true then
    raise exception 'V145 live rule emergency lift failed: %',v_result;
  end if;
  v_result:=public.set_studio_rule_active(f.business_id,v_live_rule,false);
  if (v_result->>'changed')::boolean is distinct from true then
    raise exception 'V145 live rule versioned pause failed: %',v_result;
  end if;
  v_result:=public.set_studio_rule_active(f.business_id,v_live_rule,true);
  if (v_result->>'changed')::boolean is distinct from true
     or coalesce((select active from public.program_rules
          where business_id=f.business_id
            and config_version_id=(select active_config_version_id from public.businesses where id=f.business_id)
            and rule_id=v_live_rule),false) is distinct from true then
    raise exception 'V145 fully-live rule did not resume through the existing workflow: %',v_result;
  end if;

  -- Migration reconciliation is a system safety action, not an owner action. A business
  -- without an owner must still be paused and both records must use the system sentinel.
  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  insert into public.businesses(id,name,slug,industry,enabled_modules,created_at)
  values(
    v_no_owner_business,'V145 no-owner reconciliation fixture','v145-no-owner-reconciliation',
    'facial',array['dashboard','clients','sales','reports','expenses','pnl','loyalty','retention',
      'appointments','services','memberships','packages','referrals','staffperf','dailyreport','giftcards'],
    '2026-01-01 00:00:00+00'
  );
  insert into public.firm_config_versions(
    id,business_id,version_no,status,source,snapshot_hash,published_at
  ) values(
    v_no_owner_config,v_no_owner_business,1,'published','v145_no_owner_probe',
    md5('v145-no-owner-config'),'2026-01-01 00:00:00+00'
  );
  perform set_config('app.v79_system_transition','on',true);
  update public.businesses set active_config_version_id=v_no_owner_config
   where id=v_no_owner_business;
  perform set_config('app.v79_system_transition','',true);
  execute 'alter table public.program_rules disable trigger trg_program_rule_version_guard';
  insert into public.program_rules(
    rule_id,config_version_id,business_id,schema_version,name,active,when_event,
    if_conditions,then_effects,rule_hash
  ) values(
    v_no_owner_rule,v_no_owner_config,v_no_owner_business,1,
    'V145 no-owner incomplete action',true,'sale.completed',
    jsonb_build_array(jsonb_build_object('field','amount_cents','op','eq','value',5300)),
    jsonb_build_array(jsonb_build_object('effect_type','tier_multiplier','multiplier',2)),
    app.program_rule_hash(jsonb_build_object(
      'schema_version',1,'when_event','sale.completed',
      'if_conditions',jsonb_build_array(jsonb_build_object('field','amount_cents','op','eq','value',5300)),
      'then_effects',jsonb_build_array(jsonb_build_object('effect_type','tier_multiplier','multiplier',2)),
      'with_params','{}'::jsonb,'during_schedule','{}'::jsonb,'using_stacking','{}'::jsonb
    ))
  );
  execute 'alter table public.program_rules enable trigger trg_program_rule_version_guard';
  perform app.reconcile_v145_incomplete_program_rule_pauses();
  if app.reconcile_v145_incomplete_program_rule_pauses()<>0
     or not exists(select 1 from public.studio_rule_emergency_pauses
       where business_id=v_no_owner_business and rule_id=v_no_owner_rule
         and lifted_at is null
         and actor='00000000-0000-0000-0000-000000000000'::uuid)
     or not exists(select 1 from public.audit_log
       where business_id=v_no_owner_business and entity_id=v_no_owner_rule
         and action='STUDIO_RULE_EMERGENCY_PAUSE'
         and actor='00000000-0000-0000-0000-000000000000'::uuid
         and detail->>'source'='v145_launch_reconciliation') then
    raise exception 'V145 no-owner system reconciliation provenance mismatch';
  end if;
end
$v145_studio_launch_guards$;

reset role;
do $v145_reports_sales_dependency$
declare
  f pg_temp.v145_fixture%rowtype;
begin
  select * into f from pg_temp.v145_fixture;
  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  delete from public.platform_module_overrides_v94
   where business_id=f.business_id
     and branch_scope=f.other_branch_id
     and module_key='reports';
  insert into public.platform_module_overrides_v94(
    business_id,branch_scope,module_key,mode,reason,updated_by
  ) values(
    f.business_id,f.branch_id,'sales','disabled',
    'V145 synthetic Sales-derived Reports denial',f.owner_id
  );

  perform pg_temp.as_v145_user(f.owner_id);
  perform pg_temp.expect_v145_error(format(
    'select public.get_reports_summary(%L,date ''2026-08-01'',date ''2026-08-03'',%L)',
    f.business_id,f.branch_id
  ),'Reports with Sales disabled at exact branch');
  perform pg_temp.expect_v145_error(format(
    'select public.get_reports_summary(%L,date ''2026-08-01'',date ''2026-08-03'',null)',
    f.business_id
  ),'Reports all-branch scope with partial Sales');

  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  delete from public.platform_module_overrides_v94
   where business_id=f.business_id
     and branch_scope=f.branch_id
     and module_key='sales';
  insert into public.platform_module_overrides_v94(
    business_id,branch_scope,module_key,mode,reason,updated_by
  ) values(
    f.business_id,f.other_branch_id,'reports','disabled',
    'V145 synthetic branch-effective Reports denial',f.owner_id
  );
end
$v145_reports_sales_dependency$;

reset role;
do $v145_customer_actionable_loyalty$
declare
  f pg_temp.v145_fixture%rowtype;
  v_projection jsonb;
  v_config uuid;
  v_future_reward uuid := '14500000-0000-4000-8000-000000000091';
  v_ended_reward uuid := '14500000-0000-4000-8000-000000000092';
  v_exhausted_reward uuid := '14500000-0000-4000-8000-000000000093';
  v_restricted_reward uuid := '14500000-0000-4000-8000-000000000094';
  v_ready_reward uuid := '14500000-0000-4000-8000-000000000095';
  v_next_reward uuid := '14500000-0000-4000-8000-000000000096';
begin
  select * into f from pg_temp.v145_fixture;
  select active_config_version_id into v_config
    from public.businesses where id=f.business_id;

  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  update public.loyalty_programs
     set kind='points',active=true,loyalty_model='classic',
         configuration_status='published',redeem_points=10,
         reward_credit_cents=500,expiry_mode='fixed',expiry_days=30,
         current_config_version_id=v_config
   where business_id=f.business_id;
  insert into public.business_customer_capabilities_v89(
    business_id,redemption_enabled,updated_by
  ) values(f.business_id,false,f.owner_id)
  on conflict (business_id) do update
    set redemption_enabled=excluded.redemption_enabled,
        updated_by=excluded.updated_by;
  insert into public.points_batches(
    id,business_id,client_id,earned,remaining,earned_at,expires_at
  ) values(
    '14500000-0000-4000-8000-000000000097',f.business_id,
    f.client_valid_id,11,11,statement_timestamp()-interval '60 days',
    statement_timestamp()-interval '30 days'
  );

  perform pg_temp.as_v145_user(f.owner_id);
  v_projection:=public.staff_get_customer_actionable_loyalty_v145(
    f.business_id,f.client_valid_id,null
  );
  if (v_projection->>'points_balance')::integer<>0
     or v_projection->'expiry'<>'null'::jsonb
     or coalesce((v_projection#>>'{next_reward,available_now}')::boolean,false) then
    raise exception 'V145 expired batch became spendable or reward-ready: %',v_projection;
  end if;
  if (v_projection->>'redemption_enabled')::boolean then
    raise exception 'V145 disabled merchant redemption was reported enabled: %',v_projection;
  end if;

  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  update public.business_customer_capabilities_v89
     set redemption_enabled=true,updated_by=f.owner_id
   where business_id=f.business_id;
  insert into public.points_batches(
    id,business_id,client_id,earned,remaining,earned_at,expires_at
  ) values(
    '14500000-0000-4000-8000-000000000098',f.business_id,
    f.client_valid_id,11,11,statement_timestamp()-interval '1 day',
    statement_timestamp()+interval '20 days'
  );
  perform set_config(
    'app.credit_ledger_insert_id',
    '14500000-0000-4000-8000-000000000099',true
  );
  perform set_config('app.redemption_reversal_config_version_id',v_config::text,true);
  perform set_config('app.credit_ledger_write_scope','redemption_reversal',true);
  insert into public.credit_ledger(
    id,business_id,client_id,entry_type,amount_cents,reference,actor
  ) values(
    '14500000-0000-4000-8000-000000000099',f.business_id,
    f.client_valid_id,'manual_adjust',-700,
    'V145 signed-credit clamp fixture',f.owner_id
  );
  perform set_config('app.credit_ledger_insert_id','',true);
  perform set_config('app.credit_ledger_write_scope','',true);
  perform set_config('app.redemption_reversal_config_version_id','',true);

  perform pg_temp.as_v145_user(f.owner_id);
  v_projection:=public.staff_get_customer_actionable_loyalty_v145(
    f.business_id,f.client_valid_id,null
  );
  if (v_projection->>'points_balance')::integer<>11
     or (v_projection#>>'{expiry,units}')::integer<>11
     or (v_projection->>'credit_balance_cents')::integer<>0
     or (v_projection#>>'{next_reward,available_now}')::boolean is distinct from true then
    raise exception 'V145 classic actionable projection is not authoritative: %',v_projection;
  end if;

  -- Replace the classic candidate with a versioned catalogue in the already-published
  -- configuration. Claim windows, usage limits and context restrictions must be decided
  -- by the server; Customer 360 must not infer them from raw reward rows.
  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  update public.loyalty_programs
     set loyalty_model='points_tiers',current_config_version_id=v_config
   where business_id=f.business_id;
  insert into public.loyalty_rewards(
    id,business_id,name,cost_points,credit_cents,active,sort,
    internal_name,customer_name,fulfillment_kind,estimated_cost_cents,
    current_config_version_id
  ) values
    (v_future_reward,f.business_id,'Future facial credit',5,500,true,1,
      'Future facial credit','Future facial credit','credit',250,v_config),
    (v_ended_reward,f.business_id,'Ended facial credit',5,500,true,2,
      'Ended facial credit','Ended facial credit','credit',250,v_config),
    (v_exhausted_reward,f.business_id,'Used facial credit',5,500,true,3,
      'Used facial credit','Used facial credit','credit',250,v_config),
    (v_restricted_reward,f.business_id,'Service-only facial credit',5,500,true,4,
      'Service-only facial credit','Service-only facial credit','credit',250,v_config),
    (v_ready_reward,f.business_id,'Hydration facial credit',10,500,true,5,
      'Hydration facial credit','Hydration facial credit','credit',250,v_config),
    (v_next_reward,f.business_id,'Premium facial credit',15,800,true,6,
      'Premium facial credit','Premium facial credit','credit',400,v_config);
  insert into public.loyalty_reward_versions(
    id,reward_id,business_id,config_version_id,internal_name,customer_name,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,sort,
    claim_available_from,claim_available_until,usage_limit
  ) values
    ('14500000-0000-4000-8000-000000000101',v_future_reward,f.business_id,v_config,
      'Future facial credit','Future facial credit','credit',5,500,250,true,1,
      statement_timestamp()+interval '1 day',null,null),
    ('14500000-0000-4000-8000-000000000102',v_ended_reward,f.business_id,v_config,
      'Ended facial credit','Ended facial credit','credit',5,500,250,true,2,
      null,statement_timestamp()-interval '1 day',null),
    ('14500000-0000-4000-8000-000000000103',v_exhausted_reward,f.business_id,v_config,
      'Used facial credit','Used facial credit','credit',5,500,250,true,3,
      null,null,1),
    ('14500000-0000-4000-8000-000000000104',v_restricted_reward,f.business_id,v_config,
      'Service-only facial credit','Service-only facial credit','credit',5,500,250,true,4,
      null,null,null),
    ('14500000-0000-4000-8000-000000000105',v_ready_reward,f.business_id,v_config,
      'Hydration facial credit','Hydration facial credit','credit',10,500,250,true,5,
      null,null,null),
    ('14500000-0000-4000-8000-000000000106',v_next_reward,f.business_id,v_config,
      'Premium facial credit','Premium facial credit','credit',15,800,400,true,6,
      null,null,null);
  insert into public.loyalty_reward_branches(
    reward_version_id,reward_id,business_id,branch_id
  ) values(
    '14500000-0000-4000-8000-000000000104',v_restricted_reward,
    f.business_id,f.branch_id
  );
  insert into public.loyalty_redemptions(
    business_id,client_id,reward_id,reward_name,points_spent,credit_cents,
    actor,config_version_id,reward_version_id,fulfillment_kind,usage_number,
    eligibility_snapshot
  ) values(
    f.business_id,f.client_valid_id,v_exhausted_reward,'Used facial credit',
    5,500,f.owner_id,v_config,
    '14500000-0000-4000-8000-000000000103','credit',1,
    jsonb_build_object('selected',jsonb_build_object('branch_id',f.branch_id))
  );

  perform pg_temp.as_v145_user(f.owner_id);
  v_projection:=public.staff_get_customer_actionable_loyalty_v145(
    f.business_id,f.client_valid_id,null
  );
  if jsonb_array_length(v_projection->'rewards')<>2
     or not exists(
       select 1 from jsonb_array_elements(v_projection->'rewards') reward
        where reward->>'reward_id'=v_ready_reward::text
          and (reward->>'available_now')::boolean
     )
     or not exists(
       select 1 from jsonb_array_elements(v_projection->'rewards') reward
        where reward->>'reward_id'=v_next_reward::text
          and (reward->>'remaining_units')::integer=4
          and not (reward->>'available_now')::boolean
     )
     or exists(
       select 1 from jsonb_array_elements(v_projection->'rewards') reward
        where (reward->>'reward_id')::uuid in (
          v_future_reward,v_ended_reward,v_exhausted_reward,v_restricted_reward
        )
     ) then
    raise exception 'V145 catalogue projection advertised an ineligible reward: %',v_projection;
  end if;

  perform pg_temp.as_v145_user(f.frontdesk_id);
  v_projection:=public.staff_get_customer_actionable_loyalty_v145(
    f.business_id,f.client_valid_id,f.branch_id
  );
  if (v_projection->>'points_balance')::integer<>11 then
    raise exception 'V145 assigned front desk did not receive actionable balance: %',v_projection;
  end if;
  perform pg_temp.expect_v145_error(format(
    'select public.staff_get_customer_actionable_loyalty_v145(%L,%L,null)',
    f.business_id,f.client_valid_id
  ),'front desk all-branch loyalty projection');

  perform pg_temp.as_v145_user(f.denied_id);
  perform pg_temp.expect_v145_error(format(
    'select public.staff_get_customer_actionable_loyalty_v145(%L,%L,%L)',
    f.business_id,f.client_valid_id,f.branch_id
  ),'staff without loyalty projection permission');

  perform pg_temp.as_v145_user(f.foreign_owner_id);
  perform pg_temp.expect_v145_error(format(
    'select public.staff_get_customer_actionable_loyalty_v145(%L,%L,%L)',
    f.business_id,f.client_valid_id,f.branch_id
  ),'foreign owner loyalty projection');
end
$v145_customer_actionable_loyalty$;

reset role;
do $v145_customer_directory_truth$
declare
  f pg_temp.v145_fixture%rowtype;
  v_directory jsonb;
  v_retry jsonb;
  v_customer jsonb;
begin
  select * into f from pg_temp.v145_fixture;
  perform pg_temp.as_v145_user(f.owner_id);
  v_directory:=public.staff_list_customers_v129(
    f.business_id,'Aisha Valid',null,100,0
  );
  select customer into v_customer
    from jsonb_array_elements(v_directory->'customers') customer
   where customer->>'id'=f.client_valid_id::text;
  if v_customer is null
     or (v_directory->>'loyalty_available')::boolean is distinct from true
     or (v_directory->>'loyalty_program_enabled')::boolean is distinct from true
     or (v_directory->>'total')::integer<>1
     or (v_customer->>'points')::integer<>11
     or (v_customer->>'balance_cents')::integer<>0 then
    raise exception 'V145 customer directory did not match actionable balances: %',v_directory;
  end if;
  v_retry:=public.staff_list_customers_v129(
    f.business_id,'Aisha Valid',null,100,0
  );
  if v_retry->'customers'<>v_directory->'customers'
     or v_retry->>'total'<>v_directory->>'total' then
    raise exception 'V145 customer directory retry changed the persisted projection';
  end if;
  v_directory:=public.staff_list_customers_v129(
    f.business_id,'No matching synthetic customer',null,100,0
  );
  if (v_directory->>'total')::integer<>0
     or v_directory->'customers'<>'[]'::jsonb then
    raise exception 'V145 customer directory empty result is not stable: %',v_directory;
  end if;

  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  update public.loyalty_programs set active=false where business_id=f.business_id;
  perform pg_temp.as_v145_user(f.owner_id);
  v_directory:=public.staff_list_customers_v129(
    f.business_id,'Aisha Valid',null,100,0
  );
  if (v_directory#>>'{customers,0,points}')::integer<>0
     or (v_directory#>>'{customers,0,balance_cents}')::integer<>0 then
    raise exception 'V145 disabled programme exposed spendable directory value: %',v_directory;
  end if;

  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  update public.loyalty_programs
     set active=true,configuration_status='published'
   where business_id=f.business_id;
  insert into public.platform_module_overrides_v94(
    business_id,branch_scope,module_key,mode,reason,updated_by
  ) values(
    f.business_id,f.other_branch_id,'loyalty','disabled',
    'V145 synthetic incomplete Loyalty directory scope',f.owner_id
  );
  perform pg_temp.as_v145_user(f.owner_id);
  v_directory:=public.staff_list_customers_v129(
    f.business_id,'Aisha Valid',null,100,0
  );
  if (v_directory->>'loyalty_available')::boolean is distinct from false
     or v_directory#>'{customers,0,points}'<>'null'::jsonb
     or v_directory#>'{customers,0,balance_cents}'<>'null'::jsonb then
    raise exception 'V145 incomplete Loyalty scope was replaced with plausible balances: %',
      v_directory;
  end if;

  perform pg_temp.as_v145_user(f.owner_id,'postgres');
  delete from public.platform_module_overrides_v94
   where business_id=f.business_id
     and branch_scope=f.other_branch_id
     and module_key='loyalty';
  perform pg_temp.as_v145_user(f.frontdesk_id);
  v_directory:=public.staff_list_customers_v129(
    f.business_id,'Aisha Valid',null,100,0
  );
  if (v_directory->>'loyalty_available')::boolean is distinct from false
     or v_directory#>'{customers,0,points}'<>'null'::jsonb then
    raise exception 'V145 branch-limited staff received an unproven business-wide balance: %',
      v_directory;
  end if;

  perform pg_temp.as_v145_user(f.denied_id);
  perform pg_temp.expect_v145_error(format(
    'select public.staff_list_customers_v129(%L,null,null,100,0)',f.business_id
  ),'inactive staff customer directory');
  perform pg_temp.as_v145_user(f.foreign_owner_id);
  perform pg_temp.expect_v145_error(format(
    'select public.staff_list_customers_v129(%L,null,null,100,0)',f.business_id
  ),'foreign owner customer directory');
end
$v145_customer_directory_truth$;

reset role;
do $v145_denials$
declare
  f pg_temp.v145_fixture%rowtype;
begin
  select * into f from pg_temp.v145_fixture;
  perform pg_temp.as_v145_user(f.denied_id);
  perform pg_temp.expect_v145_error(format(
    'select public.get_dashboard_summary(%L,date ''2026-08-01'',date ''2026-08-03'',%L)',
    f.business_id,f.branch_id
  ),'staff without sales permission dashboard');
  perform pg_temp.expect_v145_error(format(
    'select public.get_reports_summary(%L,date ''2026-08-01'',date ''2026-08-03'',%L)',
    f.business_id,f.branch_id
  ),'staff without Reports read');
  perform pg_temp.expect_v145_error(format(
    'select public.get_revenue_summary(%L,date ''2031-08-01'',date ''2031-08-31'',%L)',
    f.business_id,f.branch_id
  ),'staff without finance permission');

  perform pg_temp.as_v145_user(f.report_reader_id);
  perform pg_temp.expect_v145_error(format(
    'select public.get_reports_summary(%L,date ''2026-08-01'',date ''2026-08-03'',%L)',
    f.business_id,f.other_branch_id
  ),'read-only reporter unassigned branch');
  perform pg_temp.expect_v145_error(format(
    'select public.get_reports_summary(%L,date ''2026-08-01'',date ''2026-08-03'',null)',
    f.business_id
  ),'read-only reporter partial all-branch scope');

  perform pg_temp.as_v145_user(f.owner_id);
  perform pg_temp.expect_v145_error(format(
    'select public.get_reports_summary(%L,date ''2026-08-01'',date ''2026-08-03'',%L)',
    f.business_id,f.other_branch_id
  ),'owner Reports-disabled branch');
  perform pg_temp.expect_v145_error(format(
    'select public.get_reports_summary(%L,date ''2026-08-01'',date ''2026-08-03'',null)',
    f.business_id
  ),'owner all-branch scope containing Reports-disabled branch');

  perform pg_temp.as_v145_user(f.foreign_owner_id);
  perform pg_temp.expect_v145_error(format(
    'select public.get_dashboard_summary(%L,date ''2026-08-01'',date ''2026-08-03'',%L)',
    f.business_id,f.branch_id
  ),'foreign owner dashboard');
  perform pg_temp.expect_v145_error(format(
    'select public.get_revenue_summary(%L,date ''2031-08-01'',date ''2031-08-31'',%L)',
    f.business_id,f.branch_id
  ),'foreign owner finance');
end
$v145_denials$;

reset role;
do $v145_empty_and_retry$
declare
  f pg_temp.v145_fixture%rowtype;
  v_empty jsonb;
begin
  select * into f from pg_temp.v145_fixture;
  perform pg_temp.as_v145_user(f.owner_id);
  v_empty:=public.get_dashboard_summary(
    f.business_id,date '2040-01-01',date '2040-01-02',f.branch_id
  );
  if (v_empty->>'visits')::integer<>0
     or (v_empty->>'revenue_cents')::bigint<>0
     or jsonb_array_length(v_empty->'revenue_by_day')<>2 then
    raise exception 'V145 dashboard empty state is not stable: %',v_empty;
  end if;
  -- Repeat the same read to prove refresh/retry is deterministic and write-free.
  if public.get_dashboard_summary(
       f.business_id,date '2040-01-01',date '2040-01-02',f.branch_id
     )<>v_empty then
    raise exception 'V145 dashboard retry returned a different projection';
  end if;
  perform pg_temp.expect_v145_error(format(
    'select public.get_dashboard_summary(%L,date ''2040-01-02'',date ''2040-01-01'',%L)',
    f.business_id,f.branch_id
  ),'invalid dashboard date range','22007');
end
$v145_empty_and_retry$;

reset role;
do $v145_done$
begin
  raise notice 'V145 launch-freeze metric suite: ALL PASS';
end
$v145_done$;

rollback;

do $v145_zero_residue$
begin
  if exists(select 1 from public.businesses where slug like 'v145-%')
     or exists(select 1 from auth.users where email like 'v145-%@example.test') then
    raise exception 'V145 rollback left synthetic fixture residue';
  end if;
  raise notice 'V145 rollback residue: ZERO';
end
$v145_zero_residue$;
