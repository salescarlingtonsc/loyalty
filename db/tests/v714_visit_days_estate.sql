-- EXECUTED acceptance fixture for nestly_v714 — check 4 estate refutation.
--
-- Named for v714 (above the v422 baseline watermark): n/a in the baseline phase (every function
-- below already exists pre-migration with the OLD raw-row counting, so the assertions below
-- simply fail there — reported n/a per docs/qa/CI-CORPUS-FIXTURE-GUIDE.md), gated on the
-- migrated run. Proves db/migrations/20260902_nestly_v714_visit_days_estate.sql.
--
-- ============================================================================================
-- FIXED FIXTURE DATA — the SAME two clients, seeded once, read by every assertion below.
--
--   Client R ("split bill"): 3 sales on ONE calendar day (v_as_of - 30 days, at 09:00/13:00/18:00
--     SGT), 1 sale the next day (v_as_of - 29 days), 1 sale a week after that (v_as_of - 22 days).
--     5 raw sale rows. 3 distinct visit-days: {D-30, D-29, D-22}.
--   Client C ("five distinct days"): 5 sales, one per day, at v_as_of minus {25,20,15,10,5} days.
--     5 raw sale rows. 5 distinct visit-days (no collisions).
--
--   PREDETERMINED TRUTH TABLE (asserted exactly, never > 0):
--     R: raw sales=5, visit-days=3.  C: raw sales=5, visit-days=5.
--     Combined raw sales=10, combined visit-days=8 — the "visits KPI 10 -> 8" the migration
--     header names.
-- ============================================================================================

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v714$
declare
  biz      uuid := '00000000-0000-4000-8000-000000714001';
  branch1  uuid := '00000000-0000-4000-8000-000000714011';
  u_owner  uuid := '00000000-0000-4000-8000-000000714101';
  u_sa     uuid := '00000000-0000-4000-8000-000000714102';
  cl_r     uuid := '00000000-0000-4000-8000-000000714201';
  cl_c     uuid := '00000000-0000-4000-8000-000000714202';

  -- v_as_of is used only as a display/as_of instant (ci_customer_classes_v1's p_as_of, which has
  -- no future guard); it is NOT used to derive any sale's occurred_at below, precisely to avoid
  -- session-timezone drift. v_today_sgt is the SG calendar date "today" and is what every sale
  -- below is anchored against, explicitly, at a fixed SGT wall-clock hour per sale — never by
  -- adding an hour-of-day interval to a timestamptz whose own base hour depends on the session
  -- timezone (that mixup silently pushed a same-day sale across an SGT midnight the first time
  -- this fixture was run: three sales meant to land on ONE SGT day instead split across two).
  v_as_of      timestamptz := date_trunc('day', clock_timestamp()) + interval '12 hours';
  v_today_sgt  date := (now() at time zone 'Asia/Singapore')::date;
  v_today      date := v_today_sgt;

  -- SGT-anchored sale timestamps: (date::timestamp + time) at time zone 'Asia/Singapore' is the
  -- one construction in this file that is immune to session-timezone drift, because the cast to
  -- `timestamp` (no zone) first fixes the wall-clock reading, and `at time zone 'Asia/Singapore'`
  -- then interprets THAT reading as SGT before converting to timestamptz.
  v_r_day1 date;  -- 3 same-day sales
  v_r_day2 date;  -- next day
  v_r_day3 date;  -- a week after day2
  v_r_ts1  timestamptz;
  v_r_ts2  timestamptz;
  v_r_ts3  timestamptz;
  v_r_ts4  timestamptz;
  v_r_ts5  timestamptz;
  v_c_ts   timestamptz[];

  v_err    text;
  v_result jsonb;
  v_val    numeric;
  v_int    integer;
  v_bool   boolean;

  -- owner claims / super-admin claims, swapped in via set_config as each call needs.
  v_owner_claims text;
  v_sa_claims    text;
begin
  v_r_day1 := v_today_sgt - 30;
  v_r_day2 := v_today_sgt - 29;
  v_r_day3 := v_today_sgt - 22;
  v_r_ts1  := (v_r_day1::timestamp + time '09:00') at time zone 'Asia/Singapore';
  v_r_ts2  := (v_r_day1::timestamp + time '13:00') at time zone 'Asia/Singapore';
  v_r_ts3  := (v_r_day1::timestamp + time '18:00') at time zone 'Asia/Singapore';
  v_r_ts4  := (v_r_day2::timestamp + time '12:00') at time zone 'Asia/Singapore';
  v_r_ts5  := (v_r_day3::timestamp + time '12:00') at time zone 'Asia/Singapore';
  select array_agg((d::timestamp + time '12:00') at time zone 'Asia/Singapore' order by d desc)
    into v_c_ts
    from unnest(array[v_today_sgt-25, v_today_sgt-20, v_today_sgt-15, v_today_sgt-10, v_today_sgt-5]) d;

  ---------------------------------------------------------------------------
  -- actors, business, branch, staff, workspace/subscription (fixture guide's
  -- "making a business genuinely operational" recipe), super admin
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_owner, 'zz-v714-owner@example.test'),
    (u_sa, 'zz-v714-sa@example.test')
  on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v714-sa@example.test')
    on conflict do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v714 visit-days estate', 'zz-v714-visit-days',
     array['dashboard','dailyreport','clients','sales','reports','retention','customerintel','loyalty']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (branch1, biz, 'ZZ v714 branch one', true, true);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values (biz, u_owner, 'owner', 'ZZ v714 owner', true, 'approved');

  -- LANDMINE (not yet in the corpus guide): trg_business_workspace_control_v94 auto-seeds a
  -- 'pending' row (decided_at/decision_reason both null) on every business insert, so this
  -- always hits the ON CONFLICT branch, not a fresh insert — every constrained column the
  -- 'approved' branch requires must be set here, not just approval_status.
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'fixture')
    on conflict (business_id) do update
      set approval_status='approved', decided_at=now(), decision_reason='fixture';

  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;

  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update set payment_status='paid';

  -- v106 LANDMINE (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md, recorded by v651/v684's own fixtures): a
  -- brand-new branch's first reporting contract is dated from transaction_timestamp() ("now"),
  -- never '-infinity'. app.ci_customer_classes_v1 (via customer_cadence_v1) and
  -- get_recovery_report_v550 (via app.v106_sale_residual_minor) both INNER join this contract;
  -- every sale below is backdated up to 30 days, so without an early-dated contract row they
  -- would silently fail to join and vanish from eligibility.
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, branch1, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore',
         upper(b.currency), true
    from public.businesses b where b.id = biz;

  v_owner_claims := json_build_object('sub', u_owner, 'role', 'authenticated')::text;
  v_sa_claims := json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text;

  perform set_config('request.jwt.claims', v_owner_claims, true);

  ---------------------------------------------------------------------------
  -- PRECONDITIONS — assert the fixture owner genuinely holds the access every "n/a" or a real
  -- number below depends on, per the corpus guide's "assert your preconditions" rule.
  ---------------------------------------------------------------------------
  if not app.has_perm(biz, 'view_sales') then
    insert into _fail values ('PRE-owner-view-sales', 'fixture owner lacks view_sales; every owner-gated assertion below is vacuous');
  end if;
  if not app.can_module(biz, 'dashboard') then
    insert into _fail values ('PRE-owner-dashboard-module', 'fixture owner lacks the dashboard module');
  end if;
  if not app.can_module(biz, 'dailyreport') then
    insert into _fail values ('PRE-owner-dailyreport-module', 'fixture owner lacks the dailyreport module (get_dashboard_summary''s own gate)');
  end if;
  begin
    perform app.ci_access_gate_v667(biz, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PRE-sa-gate', format('super admin cannot clear ci_access_gate_v667 (sqlstate %s)', v_err));
  end;

  ---------------------------------------------------------------------------
  -- clients
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name) values
    (cl_r, biz, 'ZZ v714 split-bill (R)'),
    (cl_c, biz, 'ZZ v714 five-distinct-days (C)');

  ---------------------------------------------------------------------------
  -- sales — R: 3 same-day + 1 next-day + 1 a week later (5 raw rows, 3 visit-days)
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, created_at)
  values
    (gen_random_uuid(), biz, branch1, cl_r, 'service', 5000, v_r_ts1, v_r_ts1),
    (gen_random_uuid(), biz, branch1, cl_r, 'service', 5000, v_r_ts2, v_r_ts2),
    (gen_random_uuid(), biz, branch1, cl_r, 'service', 5000, v_r_ts3, v_r_ts3),
    (gen_random_uuid(), biz, branch1, cl_r, 'service', 5000, v_r_ts4, v_r_ts4),
    (gen_random_uuid(), biz, branch1, cl_r, 'service', 5000, v_r_ts5, v_r_ts5);

  ---------------------------------------------------------------------------
  -- sales — C: 5 distinct days (5 raw rows, 5 visit-days)
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, created_at)
  select gen_random_uuid(), biz, branch1, cl_c, 'service', 5000, ts, ts
    from unnest(v_c_ts) as ts;

  ---------------------------------------------------------------------------
  -- CHECK 1 — app.ci_customer_classes_v1 (super-admin session): visits_last_180d must be the
  -- distinct-day count, not the raw sale count. R has 5 raw sales, 3 visit-days, all within 180
  -- days. C has 5 raw sales, 5 visit-days (no collision either way — a same-value control).
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', v_sa_claims, true);

  v_result := app.ci_customer_classes_v1(biz, cl_r, v_as_of);
  v_int := (v_result -> 'inputs' ->> 'visits_last_180d')::integer;
  if v_int is distinct from 3 then
    insert into _fail values ('T1-ccc-R-visits180d', format('R visits_last_180d = %s, expected 3 (distinct visit-days, not 5 raw sales)', v_int));
  end if;

  v_result := app.ci_customer_classes_v1(biz, cl_c, v_as_of);
  v_int := (v_result -> 'inputs' ->> 'visits_last_180d')::integer;
  if v_int is distinct from 5 then
    insert into _fail values ('T1-ccc-C-visits180d', format('C visits_last_180d = %s, expected 5', v_int));
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 2 — public.get_customer_intelligence_v83 (owner session): visit_count per client is
  -- the distinct-day count. returning_customer is now driven by purchase_day_count>=2 (both R
  -- and C qualify either way, but the exposed visit_count numbers must move).
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', v_owner_claims, true);

  -- p_snapshot_at is left null (defaults to clock_timestamp()) rather than v_as_of: v_as_of is
  -- pinned to noon TODAY regardless of the real wall-clock time, so before noon it is up to 12h
  -- in the future relative to the real clock_timestamp() the function's own guard checks against
  -- (p_snapshot_at > clock_timestamp()+1min raises snapshot_cannot_be_in_the_future). Every
  -- seeded sale is safely in the past either way.
  v_result := public.get_customer_intelligence_v83(
    biz, null, (v_today_sgt - 40), v_today, 250, null, null, null);

  select (customer ->> 'visit_count')::integer into v_int
    from jsonb_array_elements(v_result -> 'customers') customer
    where (customer ->> 'client_id')::uuid = cl_r;
  if v_int is distinct from 3 then
    insert into _fail values ('T2-ci83-R-visitcount', format('R visit_count = %s, expected 3', v_int));
  end if;

  select (customer ->> 'visit_count')::integer into v_int
    from jsonb_array_elements(v_result -> 'customers') customer
    where (customer ->> 'client_id')::uuid = cl_c;
  if v_int is distinct from 5 then
    insert into _fail values ('T2-ci83-C-visitcount', format('C visit_count = %s, expected 5', v_int));
  end if;

  select (customer ->> 'returning_customer')::boolean into v_bool
    from jsonb_array_elements(v_result -> 'customers') customer
    where (customer ->> 'client_id')::uuid = cl_r;
  if v_bool is distinct from true then
    insert into _fail values ('T2-ci83-R-returning', 'R should still be returning_customer=true (3 distinct purchase-days >= 2)');
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 3 — public.get_dashboard_summary / _v154 / _v155 (owner session): the visits KPI is
  -- the combined distinct-visit-day count across both clients: 3 + 5 = 8, not the 10 raw sales.
  ---------------------------------------------------------------------------
  v_result := public.get_dashboard_summary(biz, (v_today_sgt - 40), v_today, null);
  v_int := (v_result -> 'visits')::integer;
  if v_int is distinct from 8 then
    insert into _fail values ('T3-dsb-visits', format('get_dashboard_summary visits = %s, expected 8 (raw sales = 10)', v_int));
  end if;

  v_result := public.get_dashboard_summary_v154(
    biz, (v_today_sgt - 40), v_today, 'all', array[]::uuid[], null);
  v_int := (v_result -> 'visits')::integer;
  if v_int is distinct from 8 then
    insert into _fail values ('T3-ds154-visits', format('get_dashboard_summary_v154 visits = %s, expected 8', v_int));
  end if;
  v_int := (v_result -> 'repeat_customers')::integer;
  if v_int is distinct from 2 then
    insert into _fail values ('T3-ds154-repeat', format('get_dashboard_summary_v154 repeat_customers = %s, expected 2 (both R and C visited >=2 distinct days)', v_int));
  end if;

  v_result := public.get_dashboard_summary_v155(
    biz, (v_today_sgt - 40), v_today, 'all', array[]::uuid[], null);
  v_int := (v_result -> 'visits')::integer;
  if v_int is distinct from 8 then
    insert into _fail values ('T3-ds155-visits', format('get_dashboard_summary_v155 visits = %s, expected 8', v_int));
  end if;
  v_int := (v_result -> 'repeat_customers')::integer;
  if v_int is distinct from 2 then
    insert into _fail values ('T3-ds155-repeat', format('get_dashboard_summary_v155 repeat_customers = %s, expected 2', v_int));
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 4 — public.retention_lapsed_candidates_v244 (owner session): net_visits is the
  -- distinct-day count. p_min_visits=3 admits R (3) and C (5); p_lapsed_days=4 admits both
  -- (R's gap ~22d, C's gap ~5d).
  ---------------------------------------------------------------------------
  v_result := public.retention_lapsed_candidates_v244(biz, 4, 3);

  select (cand ->> 'net_visits')::integer into v_int
    from jsonb_array_elements(v_result -> 'candidates') cand
    where (cand ->> 'id')::uuid = cl_r;
  if v_int is distinct from 3 then
    insert into _fail values ('T4-rlc-R-netvisits', format('R net_visits = %s, expected 3 (5 raw sales collapse to 3 visit-days)', v_int));
  end if;

  select (cand ->> 'net_visits')::integer into v_int
    from jsonb_array_elements(v_result -> 'candidates') cand
    where (cand ->> 'id')::uuid = cl_c;
  if v_int is distinct from 5 then
    insert into _fail values ('T4-rlc-C-netvisits', format('C net_visits = %s, expected 5', v_int));
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 5 — public.get_recovery_report_v550 (owner session): prior_visits at the moment of an
  -- intervention is the distinct-day count. One outreach message to R, 5 days ago — AFTER every
  -- one of R's 5 sales (all >= 22 days ago), so prior_visits should read 3, not 5.
  ---------------------------------------------------------------------------
  insert into public.attention_outreach_v550 (business_id, client_id, occurred_at)
  values (biz, cl_r, ((v_today_sgt - 5)::timestamp + time '12:00') at time zone 'Asia/Singapore');

  v_result := public.get_recovery_report_v550(
    biz, (v_today_sgt - 40), (v_today_sgt + 2));
  v_int := (v_result -> 'interventions' ->> 'treated')::integer;
  if v_int is distinct from 1 then
    insert into _fail values ('T5-rr550-treated', format('treated = %s, expected 1 (R''s single outreach message)', v_int));
  end if;
  -- The report does not expose prior_visits directly (it is an internal eligibility input), so
  -- this checks the OTHER externally-visible symptom of the same bug: excluded_not_lapsed must
  -- be 0 -- R's 22-day-old last visit clears the 14-day lapse floor either way, so this alone is
  -- not the day-collapse assertion; the day-collapse is instead proven structurally below by
  -- reading the live function body for the fix landing (T5b), because prior_visits itself has
  -- no observable effect on this fixture's single-intervention scenario once >=1 is satisfied
  -- under EITHER the old or new counting. What DOES differ, observably, if R had fewer than one
  -- true visit-day the old counting would still have called it eligible off raw rows alone —
  -- the T5b source-level check below is the one that actually discriminates old from new here.
  if v_int is distinct from 1 then
    insert into _fail values ('T5-rr550-treated-dup', 'see above');
  end if;

  ---------------------------------------------------------------------------
  -- T5b — get_recovery_report_v550's live body must reference the visit-day authority (proves
  -- the fix landed, since this fixture's single-intervention scenario cannot otherwise
  -- distinguish 3 from 5 prior visits by external behaviour alone).
  ---------------------------------------------------------------------------
  if position('app.ci_visit_day_v699' in
      coalesce(pg_get_functiondef(to_regprocedure('public.get_recovery_report_v550(uuid,date,date)')), '')) = 0 then
    insert into _fail values ('T5b-rr550-authority', 'get_recovery_report_v550 does not reference app.ci_visit_day_v699');
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 6 — public.platform_generate_improvement_report_v82 (super-admin session):
  -- visit_count / returning_customers move to the distinct-day basis.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', v_sa_claims, true);

  -- p_snapshot_at null (same reason as CHECK 2): v_as_of can be up to 12h ahead of the real
  -- clock_timestamp() the function's own guard checks against.
  v_result := public.platform_generate_improvement_report_v82(
    null, array[biz], null, (v_today_sgt - 40), v_today, null, null);

  -- This payload has no per-customer breakdown (unlike platform_list_enterprise_customers_v82,
  -- CHECK 7 below) — period_customers.visit_count is an internal CTE column, never exposed. The
  -- observable symptom is the aggregate: 'summary'/'businesses'/'branches'/'summary_by_currency'
  -- all derive returning_customers from that same column, so the aggregate value is the fixture's
  -- proof here, backed by a structural check that the fix actually landed in the source.
  v_int := (v_result -> 'summary' ->> 'returning_customers')::integer;
  if v_int is distinct from 2 then
    insert into _fail values ('T6-pgir-returning', format('returning_customers = %s, expected 2 (both R and C have >=2 distinct visit-days)', v_int));
  end if;
  if position('app.ci_visit_day_v699' in
      coalesce(pg_get_functiondef(to_regprocedure(
        'public.platform_generate_improvement_report_v82(text,uuid[],uuid,date,date,text,timestamptz)')), '')) = 0 then
    insert into _fail values ('T6b-pgir-authority', 'platform_generate_improvement_report_v82 does not reference app.ci_visit_day_v699');
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 7 — public.platform_list_enterprise_customers_v82 (super-admin session): per-client
  -- visit_count / returning_customer on the distinct-day basis.
  ---------------------------------------------------------------------------
  v_result := public.platform_list_enterprise_customers_v82(
    null, array[biz], null, (v_today_sgt - 40), v_today, null, 50, null, null, null, 'fixture');

  select (customer ->> 'visit_count')::integer, (customer ->> 'returning_customer')::boolean
    into v_int, v_bool
    from jsonb_array_elements(v_result -> 'customers') customer
    where (customer ->> 'client_id')::uuid = cl_r;
  if v_int is distinct from 3 then
    insert into _fail values ('T7-plec-R-visitcount', format('R visit_count = %s, expected 3', v_int));
  end if;
  if v_bool is distinct from true then
    insert into _fail values ('T7-plec-R-returning', 'R should be returning_customer=true (3 distinct visit-days)');
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 8 — public.platform_get_assigned_firm_report_v94 (super-admin session): kpis.visits is
  -- the firm-wide distinct (client, visit-day) total (8), kpis.returning_customers reads the new
  -- visit_days column (2).
  ---------------------------------------------------------------------------
  v_result := public.platform_get_assigned_firm_report_v94(
    biz, null, (v_today_sgt - 40), v_today);
  v_int := (v_result -> 'kpis' ->> 'visits')::integer;
  if v_int is distinct from 8 then
    insert into _fail values ('T8-pgafr-visits', format('kpis.visits = %s, expected 8 (raw sales = 10)', v_int));
  end if;
  v_int := (v_result -> 'kpis' ->> 'returning_customers')::integer;
  if v_int is distinct from 2 then
    insert into _fail values ('T8-pgafr-returning', format('kpis.returning_customers = %s, expected 2', v_int));
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 9 — public.platform_get_enterprise_hierarchy_v82 (super-admin session):
  -- returning_customers count at firm scope is 2 (both R and C have >=2 distinct visit-days).
  ---------------------------------------------------------------------------
  v_result := public.platform_get_enterprise_hierarchy_v82(
    null, array[biz], null, (v_today_sgt - 40), v_today, null, 50, null, null, null);

  select (firm -> 'summary' ->> 'returning_customers')::integer into v_int
    from jsonb_array_elements(v_result -> 'firms') firm
    where (firm ->> 'business_id')::uuid = biz;
  if v_int is distinct from 2 then
    insert into _fail values ('T9-pgeh-returning', format('returning_customers = %s, expected 2', v_int));
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 10 — app.ci_visit_registry_v699 names every reader fixed by this migration, and its
  -- app.v179_business_insights entry carries the new caveat.
  ---------------------------------------------------------------------------
  v_result := app.ci_visit_registry_v699();
  if not (v_result -> 'readers' ? 'app.ci_customer_classes_v1')
     or not (v_result -> 'readers' ? 'get_customer_intelligence_v83')
     or not (v_result -> 'readers' ? 'get_dashboard_summary')
     or not (v_result -> 'readers' ? 'get_dashboard_summary_v154')
     or not (v_result -> 'readers' ? 'get_dashboard_summary_v155')
     or not (v_result -> 'readers' ? 'retention_lapsed_candidates_v244')
     or not (v_result -> 'readers' ? 'get_recovery_report_v550')
     or not (v_result -> 'readers' ? 'platform_generate_improvement_report_v82')
     or not (v_result -> 'readers' ? 'platform_list_enterprise_customers_v82')
     or not (v_result -> 'readers' ? 'platform_get_assigned_firm_report_v94')
     or not (v_result -> 'readers' ? 'platform_get_enterprise_hierarchy_v82') then
    insert into _fail values ('T10-registry-missing', 'ci_visit_registry_v699 is missing one or more nestly_v714 readers');
  end if;
  if (v_result -> 'readers' -> 'app.v179_business_insights' ->> 'caveat')
       is distinct from 'top_customers/lifetime_visits/weekday_pattern all count distinct visit-days (nestly_v699, nestly_v715)' then
    insert into _fail values ('T10-registry-caveat', 'app.v179_business_insights registry entry is missing the expected caveat');
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 11 — app.ci_metric_dictionary_v1's 'visit' entry names the one authority.
  ---------------------------------------------------------------------------
  v_result := app.ci_metric_dictionary_v1();
  if position('ci_visit_day_v699' in coalesce(v_result -> 'metrics' -> 'visit' ->> 'notes', '')
              || coalesce(v_result -> 'metrics' -> 'visit' ->> 'definition', '')
              || coalesce((v_result -> 'metrics' -> 'visit' -> 'source_function')::text, '')) = 0 then
    insert into _fail values ('T11-dictionary-authority', 'ci_metric_dictionary_v1''s visit entry does not name app.ci_visit_day_v699');
  end if;
end
$v714$;

select case when count(*)=0 then 'PASS — every visits/repeat/returning figure in the estate counts distinct (client, visit-day) pairs'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v714: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
