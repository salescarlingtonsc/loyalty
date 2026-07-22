-- Rollback-only v49b Reports authorization and gift-card aggregate suite.
-- Fixed synthetic identifiers and dates keep the fixture deterministic; nothing commits.
begin;

create temporary table pg_temp.v49b_fixture(
  business_id uuid primary key,
  foreign_business_id uuid not null,
  branch_id uuid not null,
  other_branch_id uuid not null,
  foreign_branch_id uuid not null,
  owner_id uuid not null,
  manager_id uuid not null,
  bookkeeper_id uuid not null,
  missing_reports_id uuid not null,
  giftcards_only_id uuid not null,
  inactive_id uuid not null,
  unaffiliated_id uuid not null,
  foreign_id uuid not null
) on commit drop;

do $v49b_fixture$
declare
  v_business uuid := '49b00000-0000-4000-8000-000000000001';
  v_foreign_business uuid := '49b00000-0000-4000-8000-000000000002';
  v_branch uuid := '49b00000-0000-4000-8000-000000000011';
  v_other_branch uuid := '49b00000-0000-4000-8000-000000000012';
  v_foreign_branch uuid := '49b00000-0000-4000-8000-000000000013';
  v_owner uuid := '49b00000-0000-4000-8000-000000000021';
  v_manager uuid := '49b00000-0000-4000-8000-000000000022';
  v_bookkeeper uuid := '49b00000-0000-4000-8000-000000000023';
  v_missing_reports uuid := '49b00000-0000-4000-8000-000000000024';
  v_giftcards_only uuid := '49b00000-0000-4000-8000-000000000025';
  v_inactive uuid := '49b00000-0000-4000-8000-000000000026';
  v_unaffiliated uuid := '49b00000-0000-4000-8000-000000000027';
  v_foreign uuid := '49b00000-0000-4000-8000-000000000028';
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  )
  select '00000000-0000-0000-0000-000000000000',identity_id,'authenticated','authenticated',
         email,'',timestamp with time zone '2026-01-01 00:00:00+00',
         timestamp with time zone '2026-01-01 00:00:00+00',timestamp with time zone '2026-01-01 00:00:00+00'
    from (values
      (v_owner,'v49b-owner@example.test'),
      (v_manager,'v49b-manager@example.test'),
      (v_bookkeeper,'v49b-bookkeeper@example.test'),
      (v_missing_reports,'v49b-missing@example.test'),
      (v_giftcards_only,'v49b-giftcards-only@example.test'),
      (v_inactive,'v49b-inactive@example.test'),
      (v_unaffiliated,'v49b-unaffiliated@example.test'),
      (v_foreign,'v49b-foreign@example.test')
    ) fixture_user(identity_id,email);

  insert into public.businesses(id,name,slug,industry,enabled_modules) values
    (v_business,'V49b synthetic reports','v49b-synthetic-reports','test',array['sales','reports','giftcards']),
    (v_foreign_business,'V49b foreign reports','v49b-foreign-reports','test',array['sales','reports','giftcards']);
  insert into public.branches(id,business_id,name,timezone,active,is_default) values
    (v_branch,v_business,'V49b assigned branch','Asia/Singapore',true,true),
    (v_other_branch,v_business,'V49b unassigned branch','Asia/Singapore',true,false),
    (v_foreign_branch,v_foreign_business,'V49b foreign branch','Asia/Singapore',true,true);

  insert into public.staff(id,business_id,user_id,role,full_name,active,modules,module_perms) values
    ('49b00000-0000-4000-8000-000000000031',v_business,v_owner,'owner','V49b Owner',true,null,null),
    ('49b00000-0000-4000-8000-000000000032',v_business,v_manager,'manager','V49b Read-only Manager',true,array['dashboard'],'{"reports":"r"}'::jsonb),
    ('49b00000-0000-4000-8000-000000000033',v_business,v_bookkeeper,'bookkeeper','V49b Read-only Bookkeeper',true,array['dashboard'],'{"reports":"r"}'::jsonb),
    ('49b00000-0000-4000-8000-000000000034',v_business,v_missing_reports,'bookkeeper','V49b Missing Reports',true,array['reports'],'{}'::jsonb),
    ('49b00000-0000-4000-8000-000000000035',v_business,v_giftcards_only,'bookkeeper','V49b Giftcards Only',true,array['reports'],'{"giftcards":"r"}'::jsonb),
    ('49b00000-0000-4000-8000-000000000036',v_business,v_inactive,'bookkeeper','V49b Inactive',false,array['dashboard'],'{"reports":"r"}'::jsonb),
    ('49b00000-0000-4000-8000-000000000037',v_foreign_business,v_foreign,'owner','V49b Foreign Owner',true,null,null);
  insert into public.staff_branches(business_id,staff_id,branch_id) values
    (v_business,'49b00000-0000-4000-8000-000000000033',v_branch),
    (v_business,'49b00000-0000-4000-8000-000000000034',v_branch),
    (v_business,'49b00000-0000-4000-8000-000000000035',v_branch),
    (v_business,'49b00000-0000-4000-8000-000000000036',v_branch),
    (v_foreign_business,'49b00000-0000-4000-8000-000000000037',v_foreign_branch);

  insert into public.sales(id,business_id,branch_id,kind,amount_cents,occurred_at,note) values
    ('49b00000-0000-4000-8000-000000000041',v_business,v_branch,'quick_sale',1234,timestamp with time zone '2026-07-22 02:00:00+00','v49b assigned branch'),
    ('49b00000-0000-4000-8000-000000000042',v_business,v_other_branch,'quick_sale',9876,timestamp with time zone '2026-07-22 03:00:00+00','v49b unassigned branch'),
    ('49b00000-0000-4000-8000-000000000043',v_foreign_business,v_foreign_branch,'quick_sale',7777,timestamp with time zone '2026-07-22 04:00:00+00','v49b foreign tenant');

  insert into public.gift_cards(id,business_id,code,initial_cents,balance_cents,recipient_email,status,created_at) values
    ('49b00000-0000-4000-8000-000000000051',v_business,'V49B-ACTIVE-1',1200,1200,'synthetic-active-1@example.test','active',timestamp with time zone '2026-07-20 00:00:00+00'),
    ('49b00000-0000-4000-8000-000000000052',v_business,'V49B-ACTIVE-2',500,300,'synthetic-active-2@example.test','active',timestamp with time zone '2026-07-20 00:01:00+00'),
    ('49b00000-0000-4000-8000-000000000053',v_business,'V49B-REDEEMED',500,500,'synthetic-redeemed@example.test','redeemed',timestamp with time zone '2026-07-20 00:02:00+00'),
    ('49b00000-0000-4000-8000-000000000054',v_business,'V49B-VOID',700,700,'synthetic-void@example.test','void',timestamp with time zone '2026-07-20 00:03:00+00'),
    ('49b00000-0000-4000-8000-000000000055',v_foreign_business,'V49B-FOREIGN-REDEEMED',400,400,'synthetic-foreign@example.test','redeemed',timestamp with time zone '2026-07-20 00:04:00+00');

  insert into pg_temp.v49b_fixture values(
    v_business,v_foreign_business,v_branch,v_other_branch,v_foreign_branch,
    v_owner,v_manager,v_bookkeeper,v_missing_reports,v_giftcards_only,v_inactive,
    v_unaffiliated,v_foreign
  );
end
$v49b_fixture$;

grant select on pg_temp.v49b_fixture to public;

create or replace function pg_temp.as_v49b_user(p_uid uuid,p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v49b_user(uuid,text) to public;

create or replace function pg_temp.expect_v49b_error(
  p_sql text,p_label text,p_sqlstate text default '42501'
)
returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception '% unexpectedly succeeded',p_label;
exception when others then
  if sqlstate<>p_sqlstate then
    raise exception '% failed with %, expected %: %',p_label,sqlstate,p_sqlstate,sqlerrm;
  end if;
end
$$;
grant execute on function pg_temp.expect_v49b_error(text,text,text) to public;

do $v49b_catalog$
declare
  v_report pg_proc%rowtype;
  v_helper pg_proc%rowtype;
  v_report_path text;
  v_helper_path text;
begin
  select p.* into strict v_report from pg_proc p
   where p.oid='public.get_reports_summary(uuid,date,date,uuid)'::regprocedure;
  select p.* into strict v_helper from pg_proc p
   where p.oid='app.reports_gift_card_liability_v49b(uuid,uuid)'::regprocedure;
  v_report_path:=coalesce(array_to_string(v_report.proconfig,','),'');
  v_helper_path:=coalesce(array_to_string(v_helper.proconfig,','),'');

  if v_report.provolatile<>'s' or v_report.prosecdef
     or v_report_path not in ('search_path=', 'search_path=""')
     or position('app.can_module_read(p_business, ''reports'')' in v_report.prosrc)=0
     or position('app.can_module(p_business, ''reports'')' in v_report.prosrc)>0
     or position('public.gift_cards' in v_report.prosrc)>0
     or position('app.reports_gift_card_liability_v49b(p_business, p_branch)' in v_report.prosrc)=0 then
    raise exception 'v49b Reports definition drifted from stable invoker aggregate delegation';
  end if;
  if v_helper.provolatile<>'s' or not v_helper.prosecdef
     or v_helper_path<>'search_path=pg_catalog, public, app, pg_temp'
     or position('from public.gift_cards card' in v_helper.prosrc)=0
     or position('card.status = ''active''' in v_helper.prosrc)=0
     or position('execute ' in lower(v_helper.prosrc))>0 then
    raise exception 'v49b private gift-card aggregate helper attributes drifted';
  end if;
  if not has_function_privilege('authenticated',v_report.oid,'execute')
     or has_function_privilege('anon',v_report.oid,'execute')
     or not has_function_privilege('authenticated',v_helper.oid,'execute')
     or has_function_privilege('anon',v_helper.oid,'execute')
     or exists (
       select 1 from aclexplode(coalesce(v_report.proacl,acldefault('f',v_report.proowner))) acl
        where acl.grantee=0 and acl.privilege_type='EXECUTE'
     )
     or exists (
       select 1 from aclexplode(coalesce(v_helper.proacl,acldefault('f',v_helper.proowner))) acl
        where acl.grantee=0 and acl.privilege_type='EXECUTE'
     ) then
    raise exception 'v49b function ACLs are not authenticated-only';
  end if;
  if has_table_privilege('authenticated','public.gift_cards','select') then
    raise exception 'v49b widened raw gift-card SELECT access';
  end if;
end
$v49b_catalog$;

reset role;
do $v49b_owner_allowed$
declare f pg_temp.v49b_fixture%rowtype;v_result jsonb;
begin
  select * into f from pg_temp.v49b_fixture;perform pg_temp.as_v49b_user(f.owner_id);
  v_result:=public.get_reports_summary(f.business_id,date '2026-07-22',date '2026-07-22',f.branch_id);
  if (v_result->>'gift_card_liability_cents')::bigint<>1500 then raise exception 'owner liability mismatch: %',v_result;end if;
end
$v49b_owner_allowed$;

reset role;
do $v49b_manager_allowed$
declare f pg_temp.v49b_fixture%rowtype;v_result jsonb;
begin
  select * into f from pg_temp.v49b_fixture;perform pg_temp.as_v49b_user(f.manager_id);
  if not app.has_perm(f.business_id,'view_sales') or not app.can_module_read(f.business_id,'reports')
     or app.can_module_read(f.business_id,'giftcards') then
    raise exception 'manager fixture requires Reports read without Gift cards access';
  end if;
  v_result:=public.get_reports_summary(f.business_id,date '2026-07-22',date '2026-07-22',f.branch_id);
  if (v_result->>'gift_card_liability_cents')::bigint<>1500 then raise exception 'manager liability mismatch: %',v_result;end if;
end
$v49b_manager_allowed$;

reset role;
do $v49b_bookkeeper_allowed$
declare f pg_temp.v49b_fixture%rowtype;v_result jsonb;v_key_count integer;
begin
  select * into f from pg_temp.v49b_fixture;perform pg_temp.as_v49b_user(f.bookkeeper_id);
  if not app.has_perm(f.business_id,'view_sales') or not app.can_module_read(f.business_id,'reports')
     or app.can_module(f.business_id,'reports') or app.can_module_read(f.business_id,'giftcards') then
    raise exception 'bookkeeper fixture does not isolate v41 Reports read authorization';
  end if;
  v_result:=public.get_reports_summary(f.business_id,date '2026-07-22',date '2026-07-22',f.branch_id);
  if (v_result->>'gift_card_liability_cents')::bigint<>1500
     or coalesce((v_result#>>'{revenue_by_kind,quick_sale}')::bigint,-1)<>1234 then
    raise exception 'bookkeeper branch/report result mismatch: %',v_result;
  end if;
  select count(*) into v_key_count from jsonb_object_keys(v_result);
  if v_key_count<>6 or not v_result ?& array[
    'revenue_by_kind','non_revenue_by_kind','points_by_type','credit_liability_cents',
    'gift_card_liability_cents','active_memberships'
  ] or v_result::text ~* '(code|recipient|email|purchaser|client_id)' then
    raise exception 'Reports output exposed card/customer detail fields: %',v_result;
  end if;
  perform pg_temp.expect_v49b_error('select count(*) from public.gift_cards','direct raw gift-card SELECT');
end
$v49b_bookkeeper_allowed$;

reset role;
do $v49b_zero_liability$
declare f pg_temp.v49b_fixture%rowtype;v_result jsonb;
begin
  select * into f from pg_temp.v49b_fixture;perform pg_temp.as_v49b_user(f.foreign_id);
  v_result:=public.get_reports_summary(f.foreign_business_id,date '2026-07-22',date '2026-07-22',f.foreign_branch_id);
  if (v_result->>'gift_card_liability_cents')::bigint<>0 then raise exception 'zero liability must be numeric zero: %',v_result;end if;
end
$v49b_zero_liability$;

reset role;
do $v49b_unassigned_branch_denied$
declare f pg_temp.v49b_fixture%rowtype;
begin
  select * into f from pg_temp.v49b_fixture;perform pg_temp.as_v49b_user(f.bookkeeper_id);
  perform pg_temp.expect_v49b_error(format(
    'select public.get_reports_summary(%L,date ''2026-07-22'',date ''2026-07-22'',%L)',f.business_id,f.other_branch_id
  ),'read-only unassigned branch Reports read');
end
$v49b_unassigned_branch_denied$;

reset role;
do $v49b_identity_denials$
declare f pg_temp.v49b_fixture%rowtype;v_case record;
begin
  select * into f from pg_temp.v49b_fixture;
  for v_case in select * from (values
    (f.missing_reports_id,'missing Reports module read'),
    (f.giftcards_only_id,'giftcards-only module read'),
    (f.inactive_id,'inactive Reports read'),
    (f.unaffiliated_id,'unaffiliated Reports read')
  ) denied(user_id,label) loop
    perform pg_temp.as_v49b_user(v_case.user_id);
    perform pg_temp.expect_v49b_error(format(
      'select public.get_reports_summary(%L,date ''2026-07-22'',date ''2026-07-22'',%L)',f.business_id,f.branch_id
    ),v_case.label);
    execute 'reset role';
  end loop;
end
$v49b_identity_denials$;

reset role;
do $v49b_foreign_denied$
declare f pg_temp.v49b_fixture%rowtype;
begin
  select * into f from pg_temp.v49b_fixture;perform pg_temp.as_v49b_user(f.foreign_id);
  perform pg_temp.expect_v49b_error(format(
    'select public.get_reports_summary(%L,date ''2026-07-22'',date ''2026-07-22'',%L)',f.business_id,f.branch_id
  ),'foreign tenant Reports read');
end
$v49b_foreign_denied$;

reset role;
do $v49b_anon_denied$
declare f pg_temp.v49b_fixture%rowtype;
begin
  select * into f from pg_temp.v49b_fixture;perform pg_temp.as_v49b_user(null,'anon');
  perform pg_temp.expect_v49b_error(format(
    'select public.get_reports_summary(%L,date ''2026-07-22'',date ''2026-07-22'',%L)',f.business_id,f.branch_id
  ),'anonymous Reports read');
  perform pg_temp.expect_v49b_error(format(
    'select app.reports_gift_card_liability_v49b(%L,%L)',f.business_id,f.branch_id
  ),'anonymous gift-card aggregate helper');
end
$v49b_anon_denied$;

reset role;
do $v49b_done$
begin
  raise notice 'v49b Reports read authorization suite: ALL PASS';
end
$v49b_done$;

rollback;
