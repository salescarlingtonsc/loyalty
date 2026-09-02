-- EXECUTED acceptance fixture for nestly_v740
-- (db/migrations/20260902_nestly_v740_synthetic_excluded_estate_3.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v740_corpus --migrated-only
--
-- WHY THIS EXISTS. CI-100-CHECKLIST.md checks 1 (canonical transaction population), 5 (refund/
-- reversal correctness) and 10 (golden reconciliation) require every reader to agree on which
-- sales count. nestly_v734/v737 closed the gap for the dashboard/report/CI readers a refuter had
-- already proven broken. A further refuter pass proved SEVEN more readers still leaking a
-- synthetic client's real, partially-reversed sales into a total or roster, plus this migration's
-- own estate scan (execution-checked, not grep-checked) found TWO more with the identical shape.
-- This fixture is the RED-BEFORE/GREEN-AFTER proof for all nine, run as each reader's real
-- principal: the firm owner for owner-scoped reports, a non-owner staff row for the staff_*
-- readers, and an SA-with-Google session for the platform_* readers.
--
-- FIXTURE, same shape as v734/v737 for continuity: one business, 5 real clients whose sales total
-- EXACTLY 50000 cents over 8 distinct visit-days, plus one synthetic client (clients.
-- is_synthetic = true) with 3 sales -- one (4000 cents) fully reversed via a native reversal_of
-- row, unreversed net 6000 cents -- plus 2 anonymous sales (client_id null) totalling 10000 cents.
-- All 13 days are placed inside the last 25 days so they also fall inside public.
-- get_studio_sales_baseline_v145's fixed "trailing 30 days from now" window, which takes no date
-- parameters of its own.
--
-- TRUTH TABLE (predetermined, asserted with exact equality throughout, never `> 0`):
--   known revenue (identified + anonymous, synthetic excluded)              = 60000 cents
--   naive/pre-fix revenue some readers reported (includes synthetic net)     = 66000 cents
--   platform_generate_my_report_v89's OWN pre-fix bug was worse: gross, not net of reversal
--   AND including synthetic                                                 = 70000 cents
--   identified customers (real clients only)                                = 5
--   naive/pre-fix customer counts (real + synthetic)                        = 6
--   unreversed transaction rows (real 8 + synthetic 2 + anonymous 2)        = 12 (naive)
--   unreversed transaction rows after synthetic exclusion (8 real + 2 anon) = 10 (fixed)
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v740$
declare
  v_owner   uuid := '00000000-0000-4000-8000-000000740001';
  v_staff   uuid := '00000000-0000-4000-8000-000000740002';
  v_sa      uuid := '00000000-0000-4000-8000-000000740003';
  v_biz     uuid := gen_random_uuid();
  v_branch  uuid := gen_random_uuid();
  v_today   date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_from    date := v_today - 25;   -- first real-client sale day; also inside v145's 30-day window
  v_to_incl date := v_today - 13;   -- last anonymous-sale day (inclusive convention)
  v_to_excl date := v_today - 12;

  v_cA uuid := gen_random_uuid();
  v_cB uuid := gen_random_uuid();
  v_cC uuid := gen_random_uuid();
  v_cD uuid := gen_random_uuid();
  v_cE uuid := gen_random_uuid();
  v_cS uuid := gen_random_uuid();  -- synthetic

  v_sale_syn1 uuid := gen_random_uuid();  -- the 4000-cent synthetic sale that gets reversed
  v_rev_syn1  uuid := gen_random_uuid();  -- its -4000 reversal row

  g          jsonb;
  v_err      text;
  v_val      bigint;
  v_val2     bigint;
  v_monthly_sum bigint;
begin
  insert into auth.users (id, email) values
    (v_owner, 'zz-v740-owner@example.test'),
    (v_staff, 'zz-v740-staff@example.test'),
    (v_sa,    'zz-v740-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (v_sa, 'zz-v740-sa@example.test') on conflict do nothing;

  ----------------------------------------------------------------------------------------------
  -- control rows: business, branch, staff (owner + a plain non-owner staff), workspace/
  -- subscription, so every module gate below can resolve without special-casing.
  ----------------------------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, industry, enabled_modules)
  values (v_biz, 'ZZ v740 synthetic estate 3', 'zz-v740-synth-estate-3', 'fnb',
          array['dashboard','dailyreport','clients','sales','reports','customerintel',
                'loyalty','retention','pnl','expenses']);

  insert into public.branches (id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'ZZ v740 branch', true, true);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values
    (v_biz, v_owner, 'owner', 'ZZ v740 owner', true, 'approved'),
    (v_biz, v_staff, 'staff', 'ZZ v740 staff', true, 'approved');

  -- app.can_see_branch requires an explicit public.staff_branches assignment for any non-owner/
  -- admin role (a plain 'staff' role class is neither) -- without it, resolve_reporting_branch_
  -- scope_v155's 'all' mode (used by staff_list_customers_v155 and staff_customer_bucket_
  -- counts_v290) resolves to zero visible branches and every downstream count is silently 0, not
  -- 5 or 6 -- indistinguishable from "no bug" without this assignment.
  insert into public.staff_branches (business_id, staff_id, branch_id)
  select v_biz, staff_row.id, v_branch
    from public.staff staff_row
   where staff_row.business_id = v_biz and staff_row.user_id = v_staff;

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (v_biz, 'approved', now(), 'v740 fixture')
  on conflict (business_id) do update
    set approval_status = 'approved', decided_at = now(), decision_reason = 'v740 fixture';

  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (v_biz, 'current', false)
  on conflict (business_id) do update set state = 'current', workspace_paused = false;

  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (v_biz, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update
    set status = 'active', payment_status = 'paid', current_period_end = now() + interval '30 days';

  -- app.v106_sale_residual_minor (used both by the precondition check below and, transitively,
  -- by nothing in the 9 functions under test -- but the precondition check itself needs it) cross
  -- joins app.v106_reporting_contract, which is an INNER lateral: with no contract row for this
  -- business, EVERY reversal row is silently dropped from the residual computation and the
  -- precondition would report a nonzero residual for a fully-reversed sale. Same rows v734/v737
  -- insert for the same reason.
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  values (v_biz, null,     2, '-infinity', 'Asia/Singapore', 'SGD', true),
         (v_biz, v_branch, 2, '-infinity', 'Asia/Singapore', 'SGD', true)
  on conflict do nothing;

  ----------------------------------------------------------------------------------------------
  -- 5 real clients + 1 synthetic client, precisely dated and priced.
  ----------------------------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name, is_synthetic) values
    (v_cA, v_biz, 'ZZ v740 real A', false),
    (v_cB, v_biz, 'ZZ v740 real B', false),
    (v_cC, v_biz, 'ZZ v740 real C', false),
    (v_cD, v_biz, 'ZZ v740 real D', false),
    (v_cE, v_biz, 'ZZ v740 real E', false),
    (v_cS, v_biz, 'ZZ v740 synthetic', true);

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

  -- 1 synthetic client, 3 sales: day 8's 4000-cent sale is fully reversed (net 0), day 9/10 are
  -- untouched (3000 each) -- unreversed synthetic net = 6000.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  values
    (v_sale_syn1, v_biz, v_branch, v_cS, 'service', 4000,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore',
     (v_from + 8)::timestamp at time zone 'Asia/Singapore',
     true, true, true,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore', 0,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  select gen_random_uuid(), v_biz, v_branch, v_cS, 'service', x.amount_cents,
         t.v_ts, t.v_ts, true, true, true, t.v_ts, 0, t.v_ts
    from (values
      (v_cS, 9,  3000::bigint),
      (v_cS, 10, 3000::bigint)
    ) as x(client_id, day_offset, amount_cents)
    cross join lateral (
      select ((v_from + x.day_offset)::timestamp + interval '12 hours')
               at time zone 'Asia/Singapore' as v_ts
    ) t;

  -- the native full reversal of the day-8 synthetic sale (same guard token door
  -- public.reverse_sale() uses -- see db/tests/executed/v106_corpus_revenue_truth.sql's R2, and
  -- v737's identical fixture step).
  perform set_config('app.sale_reversal_insert_id', v_rev_syn1::text, true);
  perform set_config('app.sale_reversal_original_id', v_sale_syn1::text, true);
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at,
    reversal_of, reversal_reason, reversal_actor, reversal_idempotency_key)
  values
    (v_rev_syn1, v_biz, v_branch, v_cS, 'service', -4000,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore',
     (v_from + 8)::timestamp at time zone 'Asia/Singapore',
     true, false, false,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore', 0,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore',
     v_sale_syn1, 'v740 fixture full reversal', v_owner, 'v740-syn1-reversal-1');
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);

  -- 2 anonymous sales, no client_id, 5000 + 5000 = 10000 cents.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  select gen_random_uuid(), v_biz, v_branch, null, 'service', x.amount_cents,
         t.v_ts, t.v_ts, true, true, false, t.v_ts, 0, t.v_ts
    from (values
      (11, 5000::bigint),
      (12, 5000::bigint)
    ) as x(day_offset, amount_cents)
    cross join lateral (
      select ((v_from + x.day_offset)::timestamp + interval '12 hours')
               at time zone 'Asia/Singapore' as v_ts
    ) t;

  alter table public.sales enable trigger user;

  ----------------------------------------------------------------------------------------------
  -- PRECONDITIONS.
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  if not app.is_salon_member(v_biz) then
    insert into _fail values ('pre-owner', 'the owner fixture row is not a salon member');
  end if;
  if not app.has_perm(v_biz, 'view_sales') then
    insert into _fail values ('pre-owner-perm', 'the owner does not resolve view_sales');
  end if;
  if not app.has_perm(v_biz, 'view_finance') then
    insert into _fail values ('pre-owner-finance', 'the owner does not resolve view_finance');
  end if;
  if app.v106_sale_residual_minor(v_sale_syn1, v_to_excl, clock_timestamp()) <> 0 then
    insert into _fail values ('pre-reversal', format(
      'the day-8 synthetic sale residual was %s, expected exactly 0 -- the reversal fixture '
      'itself is broken and nothing below would prove anything about synthetic exclusion',
      app.v106_sale_residual_minor(v_sale_syn1, v_to_excl, clock_timestamp())));
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);
  if not app.can_module_read(v_biz, 'clients') then
    insert into _fail values ('pre-staff', 'the non-owner staff fixture row cannot read clients');
  end if;

  perform set_config('request.jwt.claims', json_build_object(
      'sub', v_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  if not app.is_super_admin() then
    insert into _fail values ('pre-sa',
      'the Google-session fixture user does not resolve is_super_admin() -- the platform_* '
      'assertions below would be vacuous');
  end if;

  ----------------------------------------------------------------------------------------------
  -- 1. public.get_reports_summary -- owner. revenue_by_kind.service must be 60000, never 66000.
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin
    g := public.get_reports_summary(v_biz, v_from, v_to_incl, v_branch);
    v_val := (g #>> '{revenue_by_kind,service}')::bigint;
    if v_val <> 60000 then
      insert into _fail values ('1_get_reports_summary',
        format('revenue_by_kind.service = %s (expected 60000)', v_val));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('1_get_reports_summary', format('raised %s', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- 2/3/4. staff_list_customers_v154/_v155, staff_customer_bucket_counts_v290 -- a non-owner
  --        staff principal. total must be 5, never 6, and the synthetic client must not appear.
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);

  begin
    g := public.staff_list_customers_v154(v_biz);
    v_val := (g->>'total')::bigint;
    if v_val <> 5 then
      insert into _fail values ('2_staff_list_customers_v154_total',
        format('total = %s (expected 5)', v_val));
    end if;
    if exists (
      select 1 from jsonb_array_elements(g->'customers') row
       where (row->>'id')::uuid = v_cS
    ) then
      insert into _fail values ('2_staff_list_customers_v154_roster',
        'the synthetic client appears inside customers[]');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('2_staff_list_customers_v154', format('raised %s', v_err));
  end;

  begin
    g := public.staff_list_customers_v155(v_biz);
    v_val := (g->>'total')::bigint;
    if v_val <> 5 then
      insert into _fail values ('3_staff_list_customers_v155_total',
        format('total = %s (expected 5)', v_val));
    end if;
    if exists (
      select 1 from jsonb_array_elements(g->'customers') row
       where (row->>'id')::uuid = v_cS
    ) then
      insert into _fail values ('3_staff_list_customers_v155_roster',
        'the synthetic client appears inside customers[]');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('3_staff_list_customers_v155', format('raised %s', v_err));
  end;

  begin
    g := public.staff_customer_bucket_counts_v290(v_biz);
    v_val := (g #>> '{counts,total}')::bigint;
    if v_val <> 5 then
      insert into _fail values ('4_staff_customer_bucket_counts_v290',
        format('counts.total = %s (expected 5)', v_val));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('4_staff_customer_bucket_counts_v290', format('raised %s', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- 5. public.get_customer_identity_coverage_v111 -- owner. raw/canonical identified customer
  --    counts must be 5, never 6; eligible/identified transaction counts must exclude the 2
  --    unreversed synthetic sales (10/8, never 12/10).
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin
    g := public.get_customer_identity_coverage_v111(v_biz, v_branch);
    v_val  := (g->>'raw_identified_customer_count')::bigint;
    v_val2 := (g->>'canonical_identified_customer_count')::bigint;
    if v_val <> 5 then
      insert into _fail values ('5_v111_raw',
        format('raw_identified_customer_count = %s (expected 5)', v_val));
    end if;
    if v_val2 <> 5 then
      insert into _fail values ('5_v111_canonical',
        format('canonical_identified_customer_count = %s (expected 5)', v_val2));
    end if;
    if (g->>'eligible_transaction_count')::bigint <> 10 then
      insert into _fail values ('5_v111_eligible',
        format('eligible_transaction_count = %s (expected 10)',
          g->>'eligible_transaction_count'));
    end if;
    if (g->>'identified_transaction_count')::bigint <> 8 then
      insert into _fail values ('5_v111_identified',
        format('identified_transaction_count = %s (expected 8)',
          g->>'identified_transaction_count'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('5_v111', format('raised %s', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- 6. public.platform_generate_my_report_v89 -- SA-with-Google. summary.revenue_cents must be
  --    60000 (never 70000: gross-and-synthetic-inflated), customer_count must be 5.
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', v_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  begin
    g := public.platform_generate_my_report_v89(array[v_biz]);
    v_val := (g #>> '{summary,revenue_cents}')::bigint;
    if v_val <> 60000 then
      insert into _fail values ('6_v89_revenue',
        format('summary.revenue_cents = %s (expected 60000)', v_val));
    end if;
    v_val2 := (g #>> '{summary,customer_count}')::bigint;
    if v_val2 <> 5 then
      insert into _fail values ('6_v89_customer_count',
        format('summary.customer_count = %s (expected 5)', v_val2));
    end if;
    if exists (
      select 1 from jsonb_array_elements(g->'businesses') row
       where (row->>'id')::uuid = v_biz
         and ((row->>'revenue_cents')::bigint <> 60000 or (row->>'customers')::bigint <> 5)
    ) then
      insert into _fail values ('6_v89_businesses_row',
        format('businesses[] row for this business did not also reconcile to 60000/5: %s',
          (select row from jsonb_array_elements(g->'businesses') row
            where (row->>'id')::uuid = v_biz)));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('6_v89', format('raised %s', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- 7. public.platform_get_catalogue_affinity_v94 -- SA-with-Google.
  --    readiness.observed.customers must be 5, never 6.
  ----------------------------------------------------------------------------------------------
  begin
    g := public.platform_get_catalogue_affinity_v94(v_biz, v_branch, v_from, v_to_incl);
    v_val := (g #>> '{readiness,observed,customers}')::bigint;
    if v_val <> 5 then
      insert into _fail values ('7_v94_affinity_customers',
        format('readiness.observed.customers = %s (expected 5)', v_val));
    end if;
    v_val2 := (g #>> '{readiness,observed,transactions}')::bigint;
    if v_val2 <> 10 then
      insert into _fail values ('7_v94_affinity_transactions',
        format('readiness.observed.transactions = %s (expected 10)', v_val2));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('7_v94_affinity', format('raised %s', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- 8. public.get_revenue_summary -- owner. revenue_accrual_cents must be 60000, never 66000;
  --    the monthly[].revenue_accrual_cents values must sum to the same 60000.
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin
    g := public.get_revenue_summary(v_biz, v_from, v_to_incl, v_branch);
    v_val := (g->>'revenue_accrual_cents')::bigint;
    if v_val <> 60000 then
      insert into _fail values ('8_get_revenue_summary_accrual',
        format('revenue_accrual_cents = %s (expected 60000)', v_val));
    end if;
    select coalesce(sum((month_value->>'revenue_accrual_cents')::bigint), 0)
      into v_monthly_sum
      from jsonb_each(g->'monthly') as m(month_key, month_value);
    if v_monthly_sum <> 60000 then
      insert into _fail values ('8_get_revenue_summary_monthly',
        format('sum(monthly[].revenue_accrual_cents) = %s (expected 60000)', v_monthly_sum));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('8_get_revenue_summary', format('raised %s', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- 9. public.get_studio_sales_baseline_v145 -- owner. count30 must be 10, never 12;
  --    avg_bill_cents must be 6000 (60000/10), never 5500 (66000/12).
  ----------------------------------------------------------------------------------------------
  begin
    g := public.get_studio_sales_baseline_v145(v_biz);
    v_val := (g->>'count30')::bigint;
    if v_val <> 10 then
      insert into _fail values ('9_get_studio_sales_baseline_v145_count',
        format('count30 = %s (expected 10)', v_val));
    end if;
    v_val2 := (g->>'avg_bill_cents')::bigint;
    if v_val2 <> 6000 then
      insert into _fail values ('9_get_studio_sales_baseline_v145_avg',
        format('avg_bill_cents = %s (expected 6000)', v_val2));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('9_get_studio_sales_baseline_v145', format('raised %s', v_err));
  end;

  perform set_config('request.jwt.claims', null, true);

  raise notice 'v740 | business_id=% | real: 50000 cents / 8 visit-days (5 clients) | synthetic: 3 sales, one fully reversed, unreversed net 6000 cents (1 client, excluded everywhere) | anonymous: 10000 cents (2 sales) | known revenue=60000 | identified customers=5 | unreversed txns=10',
    v_biz;
end
$v740$;

select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v740: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

select case when count(*) = 0
            then 'PASS — v740: get_reports_summary, staff_list_customers_v154/_v155, '
                 'staff_customer_bucket_counts_v290, get_customer_identity_coverage_v111, '
                 'platform_generate_my_report_v89, platform_get_catalogue_affinity_v94, '
                 'get_revenue_summary and get_studio_sales_baseline_v145 all exclude a synthetic '
                 'client''s real, partially-reversed sales from every reported total and roster, '
                 'each verified as its real principal (owner / non-owner staff / SA-with-Google)'
            else 'FAIL' end as verdict,
       count(*) as failures
from _fail;

rollback;
