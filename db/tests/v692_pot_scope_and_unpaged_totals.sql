-- Rollback-only nestly_v692 acceptance: two readers that answered with the wrong rows.
--
-- WHAT THE BUGS WERE
--   F079  Every points-pot reader summed a customer's points with
--
--           and (v_balance_scope = 'programme_pot' and ledger.programme_id is not distinct from
--                v_live_programme)
--
--         The predicate is inverted. When app.programme_balance_scope_v312 resolves to
--         'business_pot' the first conjunct is false for every row, the sum is over nothing, and
--         every customer's points column coalesces to 0. 'business_pot' means "sum every
--         programme"; the expression says "sum nothing". A read-only scan of production on
--         2026-09-02 found FIVE instances across four functions and no correct one:
--         app.client_points_balance_v409 (1), staff_get_customer_actionable_loyalty_v145 (2),
--         staff_list_customers_v129 (1), staff_list_customers_v155 (1). 'business_pot' is not
--         hypothetical — app.programme_balance_scope_v312 returns it while a points-pot migration
--         is pending or running, and as its safe fallback whenever a (client, programme) pot is
--         momentarily incoherent.
--   F123  public.platform_engagement_monthly_v255 built `page` as `select * from rows_out ...
--         limit p_limit`, stored it in v_rows, and then derived BOTH the four KPI tiles and the
--         platform-wide "Monthly trend" table by aggregating that TRUNCATED page. has_more
--         correctly gated the per-firm table's Load-more button; nothing gated the tiles or the
--         trend. Because the page is ordered month DESC, truncation deleted the OLDEST months
--         from the trend outright and undercounted every total.
--
-- WHAT THIS SUITE PROVES, against two tenants it builds itself:
--    1. F079 in business_pot scope the Customers directory reports the customer's REAL balance —
--       every pot summed — instead of 0.
--    2. F079 the whole defect class is closed, not one instance: all four readers the estate scan
--       found — staff_list_customers_v155, staff_list_customers_v129,
--       staff_get_customer_actionable_loyalty_v145 and app.client_points_balance_v409 — report
--       the same real balance for the same customer. Fixing only the list would have made them
--       disagree in the opposite direction, which reads as a data loss rather than as an outage.
--    3. F079 sensitivity control — the fix is not "always sum everything". With the pot migration
--       gone the firm resolves to programme_pot again and all three readers report the LIVE
--       programme's pot only, which is a different, smaller number. Without this, assertions 1
--       and 2 would pass on readers that had simply dropped the scope rule.
--    4. F079 a customer with no ledger rows at all still reports 0, not null — the coalesce
--       around the (now non-empty) sum is intact.
--    5. F123 the paged list is still a page: with p_limit 2 over 3 business-months the
--       `businesses` array holds 2 rows, total_count is 3 and has_more is true.
--    6. F123 the monthly trend covers the WHOLE range, not the page: 3 months, including the
--       oldest one that truncation used to delete outright.
--    7. F123 the KPI tiles total the whole range: summary.months is 3 and summary.sends counts
--       every send record, not the two that fitted on the page.
--    8. F123 equivalence control — the same call with a limit large enough to hold everything
--       returns the IDENTICAL summary and monthly_trend. The unpaged aggregate is not a second,
--       differently-shaped computation; it is what the paged one was always meant to say.
--    9. F123 the reader is still super-admin only: an ordinary authenticated session is refused
--       42501.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v692_pot_scope_and_unpaged_totals.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v692_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v692_out to public;

create or replace function pg_temp.as_v692_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v692_system() to public;

create or replace function pg_temp.as_v692_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v692_user(uuid,text) to public;

-- nestly_v625: app.is_super_admin() additionally requires a Google-SSO session (amr method
-- 'oauth' plus app_metadata.providers containing 'google'), not merely a super_admins row.
create or replace function pg_temp.as_v692_platform(p_uid uuid)
returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',p_uid,'role','authenticated',
      'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
      'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
end
$$;
grant execute on function pg_temp.as_v692_platform(uuid) to public;

create or replace function pg_temp.v692_tenant(
  p_business uuid, p_owner uuid, p_branch uuid, p_label text
) returns void language plpgsql as $$
declare
  v_owner_staff uuid;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v692-owner-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (p_business,'V692 '||p_label,'v692-'||substr(p_business::text,1,8),
          'fnb','SGD',
          array['dashboard','clients','sales','services','till','loyalty'],'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=p_owner,
         decided_at=clock_timestamp(), decision_reason='v692 rollback fixture',
         updated_at=clock_timestamp()
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (p_business,false)
  on conflict (business_id) do update set workspace_paused=false;
  insert into public.subscriptions(business_id,status,payment_status,current_period_end)
  values (p_business,'active','paid',now()+interval '30 days')
  on conflict (business_id) do update
    set status='active', payment_status='paid', current_period_end=now()+interval '30 days';

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_business,p_owner,'owner','V692 Owner '||p_label,true,'approved')
  returning id into v_owner_staff;
  insert into public.branches(id,business_id,name,active,is_default)
  values (p_branch,p_business,'V692 Main '||p_label,true,true);
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values (p_business,v_owner_staff,p_branch);
end
$$;
grant execute on function pg_temp.v692_tenant(uuid,uuid,uuid,text) to public;

-- One append to points_ledger through the single route app.loyalty_ledger_write_guard admits
-- from a system principal: entry_type 'adjust', a named programme, a NULL actor.
create or replace function pg_temp.v692_seed_points(
  p_business uuid, p_client uuid, p_programme uuid, p_points integer
) returns void language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  perform app.acquire_loyalty_shared_v480(p_business);
  perform set_config('app.points_ledger_insert_id',v_id::text,true);
  perform set_config('app.points_ledger_write_scope','programme_pot_transfer',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,programme_id)
  values (v_id,p_business,p_client,'adjust',p_points,'v692 seed',null,p_programme);
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
  insert into public.points_batches(business_id,client_id,programme_id,earned,remaining)
  values (p_business,p_client,p_programme,p_points,p_points);
end
$$;
grant execute on function pg_temp.v692_seed_points(uuid,uuid,uuid,integer) to public;

do $v692_test$
declare
  -- F079
  bA uuid := gen_random_uuid();
  oA uuid := gen_random_uuid();
  brA uuid := gen_random_uuid();
  spinePoints uuid;
  spineStamps uuid;
  cSplit uuid := gen_random_uuid();
  cEmpty uuid := gen_random_uuid();
  migration uuid := gen_random_uuid();
  -- F123
  bRep uuid := gen_random_uuid();
  oRep uuid := gen_random_uuid();
  brRep uuid := gen_random_uuid();
  cSend uuid := gen_random_uuid();
  admin uuid := gen_random_uuid();
  -- working
  v_res jsonb;
  v_res2 jsonb;
  v_err text;
  v_msg text;
  v_list_points bigint;
  v_empty_points jsonb;
  v_profile bigint;
  v_scope text;
  v_helper bigint;
  v_legacy bigint;
begin
  perform pg_temp.as_v692_system();

  -- ============================================================ FIXTURE: the two-pot tenant
  perform pg_temp.v692_tenant(bA,oA,brA,'Pots');
  select id into spinePoints from public.business_programmes where business_id=bA and kind='points';
  select id into spineStamps from public.business_programmes where business_id=bA and kind='stamps';
  update public.business_programmes set active=true  where id=spinePoints;
  update public.business_programmes set active=false where id=spineStamps;

  -- staff_get_customer_actionable_loyalty_v145 reports 0 unless the firm's loyalty programme is
  -- active AND published, so the fixture gives it one; without this the profile reader is dark
  -- and assertion 2 could never tell a fixed reader from a broken one.
  insert into public.loyalty_programs(business_id,active,loyalty_model,kind,configuration_status)
  values (bA,true,'points_tiers','points','published')
  on conflict (business_id) do update
    set active=true, loyalty_model='points_tiers', kind='points', configuration_status='published';

  insert into public.clients(id,business_id,full_name,phone) values
    (cSplit,bA,'V692 Two Pots','+65 9692 0001'),
    (cEmpty,bA,'V692 No Ledger','+65 9692 0002');

  -- A real two-pot history: 30 on the live points programme and 70 left on the retired stamps
  -- programme. points_ledger is append-only, so a firm that ever switched keeps both tags —
  -- which is exactly why the two scopes give different, both-legitimate answers.
  perform pg_temp.v692_seed_points(bA,cSplit,spinePoints,30);
  perform pg_temp.v692_seed_points(bA,cSplit,spineStamps,70);

  -- Put the firm in business_pot scope the way production does: a pot migration that is pending.
  insert into public.programme_pot_migrations(id,business_id,from_programme_id,to_programme_id,status)
  values (migration,bA,spineStamps,spinePoints,'pending');
  v_scope := app.programme_balance_scope_v312(bA);
  if v_scope <> 'business_pot' then
    raise exception 'FIXTURE: the firm resolves to %, not business_pot', v_scope;
  end if;

  -- ------------------------------------------------------------------ 1. the directory
  perform pg_temp.as_v692_user(oA);
  v_res := public.staff_list_customers_v155(bA,null,null,'all',array[]::uuid[],brA,100,0);
  select (item->>'points')::bigint into v_list_points
    from pg_catalog.jsonb_array_elements(coalesce(v_res->'items',v_res->'customers','[]'::jsonb)) as e(item)
   where (item->>'id')::uuid = cSplit;
  if v_list_points = 100 then
    insert into v692_out values (1,'F079 in business_pot scope the directory reports the real balance (every pot), not 0','PASS');
  else
    insert into v692_out values (1,'F079 in business_pot scope the directory reports the real balance (every pot), not 0',
      format('FAIL - the list says %s, the customer holds 100 (30 points pot + 70 stamps pot)',
             coalesce(v_list_points::text,'<not listed>')));
  end if;

  -- ------------------------------------------------------------------ 2. the two readers agree
  v_res2 := public.staff_get_customer_actionable_loyalty_v145(bA,cSplit,brA);
  v_profile := (v_res2 ->> 'points_balance')::bigint;
  if v_profile is null then
    raise exception 'FIXTURE: the profile reader reports no balance to compare: %', v_res2;
  end if;
  perform pg_temp.as_v692_system();
  v_helper := app.client_points_balance_v409(bA,cSplit);
  perform pg_temp.as_v692_user(oA);
  select (item->>'points')::bigint into v_legacy
    from pg_catalog.jsonb_array_elements(
           coalesce(public.staff_list_customers_v129(bA,null,null,100,0)->'customers','[]'::jsonb)) as e(item)
   where (item->>'id')::uuid = cSplit;
  if v_list_points = 100 and v_profile = 100 and v_helper = 100 and v_legacy = 100 then
    insert into v692_out values (2,'F079 the whole class is closed: all four readers say 100','PASS');
  else
    insert into v692_out values (2,'F079 the whole class is closed: all four readers say 100',
      format('FAIL - v155=%s v145=%s client_points_balance_v409=%s v129=%s',
             coalesce(v_list_points::text,'<not listed>'),v_profile,v_helper,
             coalesce(v_legacy::text,'<not listed>')));
  end if;

  -- ------------------------------------------------------------------ 4. a customer with no ledger
  select item into v_empty_points
    from pg_catalog.jsonb_array_elements(coalesce(v_res->'items',v_res->'customers','[]'::jsonb)) as e(item)
   where (item->>'id')::uuid = cEmpty;
  if v_empty_points is not null and jsonb_typeof(v_empty_points->'points') = 'number'
     and (v_empty_points->>'points')::bigint = 0 then
    insert into v692_out values (4,'F079 a customer with no ledger rows still reports 0, not null','PASS');
  else
    insert into v692_out values (4,'F079 a customer with no ledger rows still reports 0, not null',
      format('FAIL - row=%s',coalesce(v_empty_points::text,'<not listed>')));
  end if;

  -- ------------------------------------------------------------------ 3. the sensitivity control
  perform pg_temp.as_v692_system();
  delete from public.programme_pot_migrations where id = migration;
  v_scope := app.programme_balance_scope_v312(bA);
  if v_scope <> 'programme_pot' then
    raise exception 'FIXTURE: without the migration the firm resolves to %, not programme_pot', v_scope;
  end if;
  perform pg_temp.as_v692_user(oA);
  v_res := public.staff_list_customers_v155(bA,null,null,'all',array[]::uuid[],brA,100,0);
  select (item->>'points')::bigint into v_list_points
    from pg_catalog.jsonb_array_elements(coalesce(v_res->'items',v_res->'customers','[]'::jsonb)) as e(item)
   where (item->>'id')::uuid = cSplit;
  v_profile := (public.staff_get_customer_actionable_loyalty_v145(bA,cSplit,brA) ->> 'points_balance')::bigint;
  perform pg_temp.as_v692_system();
  v_helper := app.client_points_balance_v409(bA,cSplit);
  perform pg_temp.as_v692_user(oA);
  select (item->>'points')::bigint into v_legacy
    from pg_catalog.jsonb_array_elements(
           coalesce(public.staff_list_customers_v129(bA,null,null,100,0)->'customers','[]'::jsonb)) as e(item)
   where (item->>'id')::uuid = cSplit;
  if v_list_points = 30 and v_profile = 30 and v_helper = 30 and v_legacy = 30 then
    insert into v692_out values (3,'F079 sensitivity: programme_pot scope still reports the LIVE pot only (30, not 100)','PASS');
  else
    insert into v692_out values (3,'F079 sensitivity: programme_pot scope still reports the LIVE pot only (30, not 100)',
      format('FAIL - v155=%s v145=%s helper=%s v129=%s; the scope rule may have been dropped rather than corrected',
             coalesce(v_list_points::text,'<not listed>'),v_profile,v_helper,
             coalesce(v_legacy::text,'<not listed>')));
  end if;

  -- ============================================================ FIXTURE: the reporting tenant
  perform pg_temp.as_v692_system();
  perform pg_temp.v692_tenant(bRep,oRep,brRep,'Report');
  insert into public.clients(id,business_id,full_name,phone)
  values (cSend,bRep,'V692 Recipient','+65 9692 0003');
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',admin,'authenticated','authenticated',
          'v692-admin-'||substr(admin::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note)
  values (admin,'v692-admin-'||substr(admin::text,1,8)||'@example.test',
          'synthetic rolled-back v692 proof');

  -- Three business-months for ONE firm: one send record in each of the last three months, so
  -- rows_out holds exactly three rows and a limit of 2 truncates the OLDEST one.
  insert into public.campaign_send_records_v255(
    business_id,campaign_kind,campaign_ref_id,send_kind,campaign_label,channel,
    client_id,occurred_at,retention_until)
  select bRep,'promotion',gen_random_uuid(),'push','V692 '||n::text,'web_push',
         cSend,
         (date_trunc('month', now() at time zone 'Asia/Singapore') - make_interval(months => n)
          + interval '5 days') at time zone 'Asia/Singapore',
         ((date_trunc('month', now() at time zone 'Asia/Singapore') - make_interval(months => n)
          + interval '5 days') at time zone 'Asia/Singapore') + interval '400 days'
    from generate_series(0,2) as n;

  perform pg_temp.as_v692_platform(admin);
  v_res := public.platform_engagement_monthly_v255(
    (date_trunc('month', now() at time zone 'Asia/Singapore') - interval '3 months')::date,
    (now() at time zone 'Asia/Singapore')::date,
    array[bRep], 2);

  -- ------------------------------------------------------------------ 5. the page is still a page
  if pg_catalog.jsonb_array_length(v_res->'businesses') = 2
     and (v_res->>'total_count') = '3'
     and (v_res->>'has_more') = 'true' then
    insert into v692_out values (5,'F123 the per-firm list is still a page: 2 of 3, has_more true','PASS');
  else
    insert into v692_out values (5,'F123 the per-firm list is still a page: 2 of 3, has_more true',
      format('FAIL - rows=%s total_count=%s has_more=%s',
             pg_catalog.jsonb_array_length(v_res->'businesses'),
             v_res->>'total_count',v_res->>'has_more'));
  end if;

  -- ------------------------------------------------------------------ 6. the trend covers the range
  if pg_catalog.jsonb_array_length(v_res->'monthly_trend') = 3 then
    insert into v692_out values (6,'F123 the monthly trend covers all 3 months, including the one the page dropped','PASS');
  else
    insert into v692_out values (6,'F123 the monthly trend covers all 3 months, including the one the page dropped',
      format('FAIL - the trend has %s month(s): %s',
             pg_catalog.jsonb_array_length(v_res->'monthly_trend'),v_res->'monthly_trend'));
  end if;

  -- ------------------------------------------------------------------ 7. the tiles total the range
  if (v_res #>> '{summary,months}') = '3' and (v_res #>> '{summary,sends}') = '3'
     and (v_res #>> '{summary,campaigns}') = '3' then
    insert into v692_out values (7,'F123 the KPI tiles total the whole range, not the page','PASS');
  else
    insert into v692_out values (7,'F123 the KPI tiles total the whole range, not the page',
      format('FAIL - summary=%s',v_res->'summary'));
  end if;

  -- ------------------------------------------------------------------ 8. the equivalence control
  v_res2 := public.platform_engagement_monthly_v255(
    (date_trunc('month', now() at time zone 'Asia/Singapore') - interval '3 months')::date,
    (now() at time zone 'Asia/Singapore')::date,
    array[bRep], 100);
  if (v_res->'summary') = (v_res2->'summary')
     and (v_res->'monthly_trend') = (v_res2->'monthly_trend')
     and (v_res2->>'has_more') = 'false'
     and pg_catalog.jsonb_array_length(v_res2->'businesses') = 3 then
    insert into v692_out values (8,'F123 equivalence: a limit big enough to hold everything gives the IDENTICAL summary and trend','PASS');
  else
    insert into v692_out values (8,'F123 equivalence: a limit big enough to hold everything gives the IDENTICAL summary and trend',
      format('FAIL - paged_summary=%s unpaged_summary=%s paged_trend=%s unpaged_trend=%s',
             v_res->'summary',v_res2->'summary',v_res->'monthly_trend',v_res2->'monthly_trend'));
  end if;

  -- ------------------------------------------------------------------ 9. still super-admin only
  perform pg_temp.as_v692_user(oRep);
  v_err := null;
  begin
    perform public.platform_engagement_monthly_v255(
      (date_trunc('month', now() at time zone 'Asia/Singapore') - interval '3 months')::date,
      (now() at time zone 'Asia/Singapore')::date,
      array[bRep], 100);
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm;
  end;
  perform pg_temp.as_v692_system();
  if v_err = '42501' then
    insert into v692_out values (9,'F123 the engagement report is still super-admin only (42501)','PASS');
  else
    insert into v692_out values (9,'F123 the engagement report is still super-admin only (42501)',
      format('FAIL - sqlstate=%s message=%s',coalesce(v_err,'<none>'),coalesce(v_msg,'')));
  end if;
end
$v692_test$;

select seq, step, outcome from v692_out order by seq;

/* The report above is printed first so a human sees WHICH assertion failed; this block then
   makes the failure fatal. It matters because scripts/db-tests/run.mjs judges a file purely by
   psql's exit code — a suite that only records FAIL rows is reported green. */
do $v692_gate$
declare
  v_bad integer;
  v_all integer;
begin
  select count(*) filter (where outcome not like 'PASS%'), count(*) into v_bad, v_all from v692_out;
  if v_all <> 9 then
    raise exception 'nestly_v692: % of 9 assertions ran — the suite aborted early', v_all;
  end if;
  if v_bad > 0 then
    raise exception 'nestly_v692: % assertion(s) FAILED — see the report above', v_bad;
  end if;
end
$v692_gate$;

rollback;
