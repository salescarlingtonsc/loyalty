-- EXECUTED acceptance fixture for nestly_v734
-- (db/migrations/20260902_nestly_v734_synthetic_excluded_everywhere.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v734 --migrated-only
--
-- WHY THIS EXISTS. CI-100-CHECKLIST.md checks 1 (canonical transaction population), 3
-- (identified vs anonymous revenue reconciles exactly) and 10 (golden reconciliation) all
-- require ONE population definition for "which sales count as this business's revenue and
-- visits". db/tests/executed/v731_reconciliation_report.sql proved that public.
-- get_dashboard_summary_v155, app.v176_sales_window and public.platform_get_assigned_firm_
-- report_v94 disagreed with public.get_revenue_truth_v106 whenever a synthetic client had real
-- sales. nestly_v734 closed that gap (plus public.get_dashboard_summary,
-- public.get_dashboard_summary_v154, app.v177_sales_window, public.retention_lapsed_
-- candidates_v244 and the 90-day revenue block of public.refresh_growth_recommendation_v108).
-- This fixture is the RED-BEFORE/GREEN-AFTER proof.
--
-- FIXTURE, exactly as the checklist item asks: one business, 5 real clients whose sales total
-- EXACTLY 50000 cents over 8 distinct visit-days, plus one synthetic client (clients.
-- is_synthetic = true) whose 3 sales total 10000 cents over 3 more distinct days. The naive
-- (pre-v734) totals would be 60000 cents / 11 visit-days -- every reader below must report
-- 50000 / 8 and never 60000 / 11.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v734$
declare
  v_owner   uuid := '00000000-0000-4000-8000-000000734001';
  v_sa      uuid := '00000000-0000-4000-8000-000000734002';
  v_biz     uuid := gen_random_uuid();
  v_branch  uuid := gen_random_uuid();
  v_today   date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_from    date := v_today - 40;   -- first real-client sale day
  v_to_incl date := v_today - 30;   -- last synthetic-client sale day (dashboard/window convention: p_to inclusive)
  v_to_excl date := v_today - 29;   -- v106 convention: p_to exclusive

  v_cA uuid := gen_random_uuid();
  v_cB uuid := gen_random_uuid();
  v_cC uuid := gen_random_uuid();
  v_cD uuid := gen_random_uuid();
  v_cE uuid := gen_random_uuid();
  v_cS uuid := gen_random_uuid();  -- synthetic

  g        jsonb;
  v_err    text;
  v_val    bigint;
  v_visits bigint;
  v_direct bigint;
  v_rec_id uuid;
begin
  insert into auth.users (id, email) values
    (v_owner, 'zz-v734-owner@example.test'),
    (v_sa,    'zz-v734-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (v_sa, 'zz-v734-sa@example.test') on conflict do nothing;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  ----------------------------------------------------------------------------------------------
  -- control rows: business, branch, staff, workspace/subscription, reporting contract.
  ----------------------------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, industry, enabled_modules)
  values (v_biz, 'ZZ v734 synthetic exclusion', 'zz-v734-synth-excl', 'fnb',
          array['dashboard','dailyreport','clients','sales','reports','customerintel',
                'loyalty','retention']);

  insert into public.branches (id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'ZZ v734 branch', true, true);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values (v_biz, v_owner, 'owner', 'ZZ v734 owner', true, 'approved');

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (v_biz, 'approved', now(), 'v734 fixture')
  on conflict (business_id) do update
    set approval_status = 'approved', decided_at = now(), decision_reason = 'v734 fixture';

  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (v_biz, 'current', false)
  on conflict (business_id) do update set state = 'current', workspace_paused = false;

  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (v_biz, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update
    set status = 'active', payment_status = 'paid', current_period_end = now() + interval '30 days';

  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  values (v_biz, null,     2, '-infinity', 'Asia/Singapore', 'SGD', true),
         (v_biz, v_branch, 2, '-infinity', 'Asia/Singapore', 'SGD', true)
  on conflict do nothing;

  -- refresh_growth_recommendation_v108 is gated behind a platform feature flag; enable it for
  -- this rolled-back transaction only.
  update app.platform_feature_flags
     set enabled = true
   where feature_key = 'growth_closed_loop_v108';

  ----------------------------------------------------------------------------------------------
  -- 5 real clients + 1 synthetic client, precisely dated and priced.
  ----------------------------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name, is_synthetic) values
    (v_cA, v_biz, 'ZZ v734 real A', false),
    (v_cB, v_biz, 'ZZ v734 real B', false),
    (v_cC, v_biz, 'ZZ v734 real C', false),
    (v_cD, v_biz, 'ZZ v734 real D', false),
    (v_cE, v_biz, 'ZZ v734 real E', false),
    (v_cS, v_biz, 'ZZ v734 synthetic', true);

  alter table public.sales disable trigger user;

  -- 5 real clients, 8 sales, 8 distinct visit-days, totalling exactly 50000 cents.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  select gen_random_uuid(), v_biz, v_branch, x.client_id, 'service', x.amount_cents,
         t.v_ts, t.v_ts, true, true, true, t.v_ts, 0, t.v_ts
    from (values
      (v_cA, 0,  5000::bigint),
      (v_cA, 1,  5000::bigint),
      (v_cB, 2, 10000::bigint),
      (v_cB, 3, 10000::bigint),
      (v_cC, 4,  5000::bigint),
      (v_cD, 5,  5000::bigint),
      (v_cE, 6,  5000::bigint),
      (v_cE, 7,  5000::bigint)
    ) as x(client_id, day_offset, amount_cents)
    cross join lateral (
      select ((v_from + x.day_offset)::timestamp + interval '12 hours')
               at time zone 'Asia/Singapore' as v_ts
    ) t;

  -- 1 synthetic client, 3 sales, 3 MORE distinct days, totalling exactly 10000 cents. The
  -- pre-v734 (buggy) combined total is 60000 cents / 11 visit-days; every reader below must
  -- report 50000 / 8 instead.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  select gen_random_uuid(), v_biz, v_branch, x.client_id, 'service', x.amount_cents,
         t.v_ts, t.v_ts, true, true, true, t.v_ts, 0, t.v_ts
    from (values
      (v_cS, 8,  4000::bigint),
      (v_cS, 9,  3000::bigint),
      (v_cS, 10, 3000::bigint)
    ) as x(client_id, day_offset, amount_cents)
    cross join lateral (
      select ((v_from + x.day_offset)::timestamp + interval '12 hours')
               at time zone 'Asia/Singapore' as v_ts
    ) t;

  alter table public.sales enable trigger user;

  ----------------------------------------------------------------------------------------------
  -- A. get_revenue_truth_v106 -- the control, already fixed by nestly_v687.
  ----------------------------------------------------------------------------------------------
  begin
    g := public.get_revenue_truth_v106(v_biz, v_from, v_to_excl, v_branch);
    v_val := (g #>> '{totals,known_revenue_minor}')::bigint;
    if v_val <> 50000 then
      insert into _fail values ('A_revenue_truth',
        format('known_revenue_minor = % (expected 50000)', v_val));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('A_revenue_truth', format('raised %', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- 1. public.get_dashboard_summary
  ----------------------------------------------------------------------------------------------
  begin
    g := public.get_dashboard_summary(v_biz, v_from, v_to_incl, v_branch);
    v_val := (g->>'revenue_cents')::bigint;
    v_visits := (g->>'visits')::bigint;
    if v_val <> 50000 or v_visits <> 8 then
      insert into _fail values ('1_get_dashboard_summary',
        format('revenue_cents=% visits=% (expected 50000/8)', v_val, v_visits));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('1_get_dashboard_summary', format('raised %', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- 2. public.get_dashboard_summary_v154
  ----------------------------------------------------------------------------------------------
  begin
    g := public.get_dashboard_summary_v154(v_biz, v_from, v_to_incl, 'current', array[]::uuid[], v_branch);
    v_val := (g->>'revenue_cents')::bigint;
    v_visits := (g->>'visits')::bigint;
    if v_val <> 50000 or v_visits <> 8 then
      insert into _fail values ('2_get_dashboard_summary_v154',
        format('revenue_cents=% visits=% (expected 50000/8)', v_val, v_visits));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('2_get_dashboard_summary_v154', format('raised %', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- 3. public.get_dashboard_summary_v155
  ----------------------------------------------------------------------------------------------
  begin
    g := public.get_dashboard_summary_v155(v_biz, v_from, v_to_incl, 'current', array[]::uuid[], v_branch);
    v_val := (g->>'revenue_cents')::bigint;
    v_visits := (g->>'visits')::bigint;
    if v_val <> 50000 or v_visits <> 8 then
      insert into _fail values ('3_get_dashboard_summary_v155',
        format('revenue_cents=% visits=% (expected 50000/8)', v_val, v_visits));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('3_get_dashboard_summary_v155', format('raised %', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- 4. app.v176_sales_window
  ----------------------------------------------------------------------------------------------
  begin
    g := app.v176_sales_window(v_biz, v_from, v_to_incl);
    v_val := (g->>'net_revenue_cents')::bigint;
    v_visits := (g->>'visits')::bigint;
    if v_val <> 50000 or v_visits <> 8 then
      insert into _fail values ('4_v176_sales_window',
        format('net_revenue_cents=% visits=% (expected 50000/8)', v_val, v_visits));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('4_v176_sales_window', format('raised %', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- 5. app.v177_sales_window
  ----------------------------------------------------------------------------------------------
  begin
    g := app.v177_sales_window(v_biz, v_branch, v_from, v_to_incl);
    v_val := (g->>'net_revenue_cents')::bigint;
    v_visits := (g->>'visits')::bigint;
    if v_val <> 50000 or v_visits <> 8 then
      insert into _fail values ('5_v177_sales_window',
        format('net_revenue_cents=% visits=% (expected 50000/8)', v_val, v_visits));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('5_v177_sales_window', format('raised %', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- 6. public.platform_get_assigned_firm_report_v94 -- as a real Google-SSO super admin (v625).
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', v_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method', 'oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  begin
    g := public.platform_get_assigned_firm_report_v94(v_biz, v_branch, v_from, v_to_incl);
    v_val := (g #>> '{kpis,net_revenue_cents}')::bigint;
    v_visits := (g #>> '{kpis,visits}')::bigint;
    if v_val <> 50000 or v_visits <> 8 then
      insert into _fail values ('6_platform_get_assigned_firm_report_v94',
        format('net_revenue_cents=% visits=% (expected 50000/8)', v_val, v_visits));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('6_platform_get_assigned_firm_report_v94', format('raised %', v_err));
  end;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  ----------------------------------------------------------------------------------------------
  -- 7. public.retention_lapsed_candidates_v244 -- the synthetic client must never appear, even
  --    though its 3 sales and 30-day lapse would otherwise qualify it.
  ----------------------------------------------------------------------------------------------
  begin
    g := public.retention_lapsed_candidates_v244(v_biz, 5, 1);
    v_val := (g->>'total')::bigint;
    if v_val <> 5 then
      insert into _fail values ('7_retention_lapsed_candidates_v244',
        format('total=% (expected 5 real candidates)', v_val));
    end if;
    if exists (
      select 1 from jsonb_array_elements(g->'candidates') row
       where (row->>'id')::uuid = v_cS
    ) then
      insert into _fail values ('7_retention_lapsed_candidates_v244',
        'the synthetic client appears among the candidates');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('7_retention_lapsed_candidates_v244', format('raised %', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- 8. public.refresh_growth_recommendation_v108 -- the 90-day revenue block. All 11 fixture
  --    sales are within 90 days of "now" by construction (v_from = v_today-40).
  ----------------------------------------------------------------------------------------------
  begin
    g := public.refresh_growth_recommendation_v108(v_biz, v_branch);
    v_rec_id := (g->>'recommendation_id')::uuid;
    select (data_coverage->>'total_revenue_cents_90d')::bigint,
           (data_coverage->>'identified_revenue_cents_90d')::bigint
      into v_val, v_visits
      from public.growth_recommendations_v108
     where id = v_rec_id;
    if v_val <> 50000 or v_visits <> 50000 then
      insert into _fail values ('8_refresh_growth_recommendation_v108',
        format('total_revenue_cents_90d=% identified_revenue_cents_90d=% (expected 50000/50000)',
          v_val, v_visits));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('8_refresh_growth_recommendation_v108', format('raised %', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- E. direct SQL -- the same "what SHOULD this figure be" independent check v731 uses,
  --    against get_revenue_truth_v106's own documented contract (nestly_v687): a sale
  --    attributed to an is_synthetic client is excluded.
  ----------------------------------------------------------------------------------------------
  select coalesce(sum(sale.amount_cents), 0) into v_direct
    from public.sales sale
   where sale.business_id = v_biz
     and sale.reversal_of is null
     and coalesce(sale.counts_as_revenue, true)
     and sale.occurred_at >= (v_from::timestamp at time zone 'Asia/Singapore')
     and sale.occurred_at <  ((v_to_incl + 1)::timestamp at time zone 'Asia/Singapore')
     and not exists (
       select 1 from public.sales reversal
       where reversal.business_id = sale.business_id
         and reversal.reversal_of = sale.id
     )
     and not exists (
       select 1 from public.clients synth
       where synth.id = sale.client_id
         and synth.is_synthetic = true
     );
  if v_direct <> 50000 then
    insert into _fail values ('E_direct_sql', format('direct SQL sum = % (expected 50000)', v_direct));
  end if;

  raise notice 'v734 | business_id=% | real: 50000 cents / 8 visit-days (5 clients) | synthetic: 10000 cents / 3 more days (1 client, excluded) | naive-buggy total would have been 60000 / 11',
    v_biz;

  perform set_config('request.jwt.claims', null, true);
end
$v734$;

select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v734: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

select case when count(*) = 0
            then 'PASS — v734: every touched reader (get_dashboard_summary/_v154/_v155, '
                 'app.v176/v177_sales_window, platform_get_assigned_firm_report_v94, '
                 'retention_lapsed_candidates_v244, refresh_growth_recommendation_v108) reports '
                 '50000 cents / 8 visit-days, excluding the synthetic client entirely, matching '
                 'get_revenue_truth_v106 and a direct-SQL sum'
            else 'FAIL' end as verdict,
       count(*) as failures
from _fail;

rollback;
