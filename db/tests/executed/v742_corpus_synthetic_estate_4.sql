-- EXECUTED acceptance fixture for nestly_v742
-- (db/migrations/20260902_nestly_v742_synthetic_excluded_estate_4.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v742_corpus --migrated-only
--
-- WHY THIS EXISTS. CI-100-CHECKLIST.md checks 1 (canonical transaction population), 5 (refund/
-- reversal correctness) and 10 (golden reconciliation) require every reader to agree on which
-- sales count. nestly_v740 closed the gap for nine readers a refuter and its own estate scan had
-- proven broken, and named eight more candidates it could not reach inside its time budget. This
-- migration worked six of those eight by execution (the remaining two, get_campaign_results and
-- app.get_growth_execution_result_at_v108, are per-campaign/per-execution-member readers that need
-- their own dedicated membership fixture -- see this migration's header). This is the RED-BEFORE/
-- GREEN-AFTER proof for all six, run as each reader's real principal.
--
-- FIXTURE. One business, the same shape v734/v737/v740 use for the shared population: 5 real
-- clients whose sales total EXACTLY 50000 cents over 8 distinct visit-days, one synthetic client
-- (clients.is_synthetic = true) with 3 sales -- one (4000 cents) fully reversed via a native
-- reversal_of row, unreversed net 6000 cents -- plus 2 anonymous sales (client_id null) totalling
-- 10000 cents. That shared shape alone does not exercise two of this migration's fixes, so two
-- dedicated pairs are added, both placed outside the shared fixture's date window so they cannot
-- perturb any of the shared totals above:
--   * an inactivity-bucket pair (one real client, one synthetic), each with exactly ONE sale
--     placed 65 days ago -- lands in the 60-89-day inactivity bucket, for
--     preview_campaign_audience_v155.
--   * an away/return pair (one real client, one synthetic), each with an old sale 200 days ago
--     then a return sale 10 days ago -- closes a 190-day gap, well inside an 80-day-away/30-day-
--     window query, for staff_list_returned_customers_v300.
-- Real clients in this fixture now number 7 (5 shared + 1 inactivity-bucket + 1 away/return);
-- synthetic clients number 3 (1 shared + 1 inactivity-bucket + 1 away/return). Every assertion
-- below is exact equality, never `> 0`.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v742$
declare
  v_owner   uuid := '00000000-0000-4000-8000-000000742001';
  v_staff   uuid := '00000000-0000-4000-8000-000000742002';
  v_manager uuid := '00000000-0000-4000-8000-000000742004';
  v_biz     uuid := gen_random_uuid();
  v_branch  uuid := gen_random_uuid();
  v_today   date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_from    date := v_today - 25;   -- first real-client sale day
  v_to_excl date := v_today - 12;   -- half-open period end shared by v107/v109/v109driver
  v_day65   date := v_today - 65;   -- inactivity-bucket pair (60_89 bucket)
  v_day200  date := v_today - 200;  -- away/return pair: old visit
  v_day10   date := v_today - 10;   -- away/return pair: return visit (closes a 190-day gap)

  v_cA uuid := gen_random_uuid();
  v_cB uuid := gen_random_uuid();
  v_cC uuid := gen_random_uuid();
  v_cD uuid := gen_random_uuid();
  v_cE uuid := gen_random_uuid();
  v_cS uuid := gen_random_uuid();         -- synthetic, shared fixture
  v_cInactive uuid := gen_random_uuid();  -- real, inactivity-bucket pair
  v_cS2 uuid := gen_random_uuid();        -- synthetic, inactivity-bucket pair
  v_cReturn uuid := gen_random_uuid();    -- real, away/return pair
  v_cS3 uuid := gen_random_uuid();        -- synthetic, away/return pair

  v_sale_syn1 uuid := gen_random_uuid();  -- the 4000-cent synthetic sale that gets reversed
  v_rev_syn1  uuid := gen_random_uuid();  -- its -4000 reversal row

  g          jsonb;
  v_err      text;
  v_val      bigint;
begin
  insert into auth.users (id, email) values
    (v_owner, 'zz-v742-owner@example.test'),
    (v_staff, 'zz-v742-staff@example.test'),
    (v_manager, 'zz-v742-manager@example.test')
    on conflict (id) do nothing;

  ----------------------------------------------------------------------------------------------
  -- control rows: business, branch, staff (owner + a plain non-owner staff + a non-owner manager),
  -- workspace/subscription, so every module gate below can resolve without special-casing.
  ----------------------------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, industry, enabled_modules)
  values (v_biz, 'ZZ v742 synthetic estate 4', 'zz-v742-synth-estate-4', 'fnb',
          array['dashboard','dailyreport','clients','sales','reports','customerintel',
                'loyalty','retention','pnl','expenses']);

  insert into public.branches (id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'ZZ v742 branch', true, true);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values
    (v_biz, v_owner, 'owner', 'ZZ v742 owner', true, 'approved'),
    (v_biz, v_staff, 'staff', 'ZZ v742 staff', true, 'approved'),
    (v_biz, v_manager, 'manager', 'ZZ v742 manager', true, 'approved');

  -- app.can_see_branch requires an explicit public.staff_branches assignment for any non-owner/
  -- admin role -- without it every branch-scoped read below resolves to zero visible branches and
  -- every downstream count is silently 0, indistinguishable from "no bug" (same v740 note).
  insert into public.staff_branches (business_id, staff_id, branch_id)
  select v_biz, staff_row.id, v_branch
    from public.staff staff_row
   where staff_row.business_id = v_biz and staff_row.user_id in (v_staff, v_manager);

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (v_biz, 'approved', now(), 'v742 fixture')
  on conflict (business_id) do update
    set approval_status = 'approved', decided_at = now(), decision_reason = 'v742 fixture';

  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (v_biz, 'current', false)
  on conflict (business_id) do update set state = 'current', workspace_paused = false;

  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (v_biz, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update
    set status = 'active', payment_status = 'paid', current_period_end = now() + interval '30 days';

  -- app.v106_sale_residual_minor cross joins app.v106_reporting_contract, an INNER lateral: with
  -- no contract row for this business every reversal row is silently dropped from the residual
  -- computation. Same rows v734/v737/v740 insert for the same reason.
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  values (v_biz, null,     2, '-infinity', 'Asia/Singapore', 'SGD', true),
         (v_biz, v_branch, 2, '-infinity', 'Asia/Singapore', 'SGD', true)
  on conflict do nothing;

  ----------------------------------------------------------------------------------------------
  -- 7 real clients + 3 synthetic clients.
  ----------------------------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name, is_synthetic) values
    (v_cA, v_biz, 'ZZ v742 real A', false),
    (v_cB, v_biz, 'ZZ v742 real B', false),
    (v_cC, v_biz, 'ZZ v742 real C', false),
    (v_cD, v_biz, 'ZZ v742 real D', false),
    (v_cE, v_biz, 'ZZ v742 real E', false),
    (v_cS, v_biz, 'ZZ v742 synthetic', true),
    (v_cInactive, v_biz, 'ZZ v742 real inactive-bucket', false),
    (v_cS2, v_biz, 'ZZ v742 synthetic inactive-bucket', true),
    (v_cReturn, v_biz, 'ZZ v742 real returner', false),
    (v_cS3, v_biz, 'ZZ v742 synthetic returner', true);

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
      (9,  3000::bigint),
      (10, 3000::bigint)
    ) as x(day_offset, amount_cents)
    cross join lateral (
      select ((v_from + x.day_offset)::timestamp + interval '12 hours')
               at time zone 'Asia/Singapore' as v_ts
    ) t;

  -- the native full reversal of the day-8 synthetic sale (same guard token door
  -- public.reverse_sale() uses -- see v740's identical fixture step).
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
     v_sale_syn1, 'v742 fixture full reversal', v_owner, 'v742-syn1-reversal-1');
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

  -- inactivity-bucket pair: exactly one visit each, 65 days ago (60_89 bucket), outside the
  -- shared fixture's date window so it cannot perturb any of the totals above.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  values
    (gen_random_uuid(), v_biz, v_branch, v_cInactive, 'service', 7000,
     v_day65::timestamp at time zone 'Asia/Singapore', v_day65::timestamp at time zone 'Asia/Singapore',
     true, true, true, v_day65::timestamp at time zone 'Asia/Singapore', 0,
     v_day65::timestamp at time zone 'Asia/Singapore'),
    (gen_random_uuid(), v_biz, v_branch, v_cS2, 'service', 4000,
     v_day65::timestamp at time zone 'Asia/Singapore', v_day65::timestamp at time zone 'Asia/Singapore',
     true, true, true, v_day65::timestamp at time zone 'Asia/Singapore', 0,
     v_day65::timestamp at time zone 'Asia/Singapore');

  -- away/return pair: an old visit (200 days ago) then a return visit (10 days ago), closing a
  -- 190-day gap -- qualifies as "returned" at away_days=80/window_days=30. Also outside the
  -- shared fixture's date window.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  values
    (gen_random_uuid(), v_biz, v_branch, v_cReturn, 'service', 2000,
     v_day200::timestamp at time zone 'Asia/Singapore', v_day200::timestamp at time zone 'Asia/Singapore',
     true, true, true, v_day200::timestamp at time zone 'Asia/Singapore', 0,
     v_day200::timestamp at time zone 'Asia/Singapore'),
    (gen_random_uuid(), v_biz, v_branch, v_cReturn, 'service', 2000,
     v_day10::timestamp at time zone 'Asia/Singapore', v_day10::timestamp at time zone 'Asia/Singapore',
     true, true, true, v_day10::timestamp at time zone 'Asia/Singapore', 0,
     v_day10::timestamp at time zone 'Asia/Singapore'),
    (gen_random_uuid(), v_biz, v_branch, v_cS3, 'service', 2000,
     v_day200::timestamp at time zone 'Asia/Singapore', v_day200::timestamp at time zone 'Asia/Singapore',
     true, true, true, v_day200::timestamp at time zone 'Asia/Singapore', 0,
     v_day200::timestamp at time zone 'Asia/Singapore'),
    (gen_random_uuid(), v_biz, v_branch, v_cS3, 'service', 2000,
     v_day10::timestamp at time zone 'Asia/Singapore', v_day10::timestamp at time zone 'Asia/Singapore',
     true, true, true, v_day10::timestamp at time zone 'Asia/Singapore', 0,
     v_day10::timestamp at time zone 'Asia/Singapore');

  alter table public.sales enable trigger user;

  -- get_period_economics_v109 / get_revenue_driver_decomposition_v109 fail closed behind this
  -- platform feature flag; enabling it inside this rolled-back transaction has no lasting effect.
  update app.platform_feature_flags set enabled = true
   where feature_key = 'economics_driver_policy_v109';

  ----------------------------------------------------------------------------------------------
  -- PRECONDITIONS.
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  if not app.is_salon_member(v_biz) then
    insert into _fail values ('pre-owner', 'the owner fixture row is not a salon member');
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
  if not app.platform_feature_enabled('economics_driver_policy_v109') then
    insert into _fail values ('pre-v109-feature',
      'economics_driver_policy_v109 did not enable -- the v109 assertions below would be vacuous');
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);
  if not app.can_module_read(v_biz, 'clients') then
    insert into _fail values ('pre-staff', 'the non-owner staff fixture row cannot read clients');
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_manager, 'role', 'authenticated')::text, true);
  if not app.can_see_branch(v_biz, null) then
    insert into _fail values ('pre-manager',
      'the non-owner manager fixture row cannot see the whole business -- staff_list_returned_'
      'customers_v300''s own require_module_scope_v145(..., null, ...) gate would reject it '
      'regardless of the fix under test');
  end if;

  ----------------------------------------------------------------------------------------------
  -- A. public.staff_list_returned_customers_v300 -- a non-owner manager principal (its own
  --    require_module_scope_v145(p_business, null, 'retention') call demands business-wide
  --    can_see_branch, which a plain 'staff' role_class never satisfies -- app.role_class maps
  --    'manager' to 'admin', the non-owner role class that does). total_returned must be 1
  --    (cReturn only), and cS3 must never appear in rows.
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_manager, 'role', 'authenticated')::text, true);
  begin
    g := public.staff_list_returned_customers_v300(v_biz, 80, 30);
    v_val := (g->>'total_returned')::bigint;
    if v_val <> 1 then
      insert into _fail values ('A_v300_total', format('total_returned = %s (expected 1)', v_val));
    end if;
    if not exists (
      select 1 from jsonb_array_elements(g->'rows') row where (row->>'id')::uuid = v_cReturn
    ) then
      insert into _fail values ('A_v300_missing_real', 'the real returner (cReturn) is missing from rows');
    end if;
    if exists (
      select 1 from jsonb_array_elements(g->'rows') row where (row->>'id')::uuid = v_cS3
    ) then
      insert into _fail values ('A_v300_leaked_synthetic', 'the synthetic returner (cS3) appears inside rows');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('A_v300', format('raised %s', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- B. public.get_customer_lifecycle_v107 -- owner. transacting_identified_customers must be 5,
  --    never 6; coverage.identified_transactions must be 8, never 10 (coverage.eligible_
  --    transactions is not identity-scoped, so it correctly stays 10 -- 8 real + 2 anonymous --
  --    once the synthetic client's 2 unreversed sales are excluded from it too, never 12).
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin
    g := public.get_customer_lifecycle_v107(v_biz, v_from, v_to_excl, v_branch);
    v_val := (g #>> '{metrics,transacting_identified_customers}')::bigint;
    if v_val <> 5 then
      insert into _fail values ('B_v107_customers',
        format('metrics.transacting_identified_customers = %s (expected 5)', v_val));
    end if;
    v_val := (g #>> '{coverage,eligible_transactions}')::bigint;
    if v_val <> 10 then
      insert into _fail values ('B_v107_eligible',
        format('coverage.eligible_transactions = %s (expected 10)', v_val));
    end if;
    v_val := (g #>> '{coverage,identified_transactions}')::bigint;
    if v_val <> 8 then
      insert into _fail values ('B_v107_identified',
        format('coverage.identified_transactions = %s (expected 8)', v_val));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('B_v107', format('raised %s', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- C. public.preview_campaign_audience_v155 -- staff. matching_customers for the 60_89
  --    inactivity bucket must be 1 (cInactive only), never 2.
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);
  begin
    g := public.preview_campaign_audience_v155(v_biz, '60_89');
    v_val := (g->>'matching_customers')::bigint;
    if v_val <> 1 then
      insert into _fail values ('C_v155_matching', format('matching_customers = %s (expected 1)', v_val));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('C_v155', format('raised %s', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- D. public.staff_list_customers_v129 -- staff. total must be 7 (the 5 shared real clients
  --    plus cInactive plus cReturn), never 10 (also counting the 3 synthetic clients); no
  --    synthetic client id may appear in customers[].
  ----------------------------------------------------------------------------------------------
  begin
    g := public.staff_list_customers_v129(v_biz);
    v_val := (g->>'total')::bigint;
    if v_val <> 7 then
      insert into _fail values ('D_v129_total', format('total = %s (expected 7)', v_val));
    end if;
    if exists (
      select 1 from jsonb_array_elements(g->'customers') row
       where (row->>'id')::uuid in (v_cS, v_cS2, v_cS3)
    ) then
      insert into _fail values ('D_v129_leaked_synthetic', 'a synthetic client appears inside customers[]');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('D_v129', format('raised %s', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- E. public.get_revenue_driver_decomposition_v109 -- owner. Current period (the shared
  --    fixture's window): revenue_cents must be 60000 (never 66000), identified_revenue_cents
  --    must be 50000 (never 56000). Comparison period (the day-65 inactivity-bucket pair,
  --    reused here since it sits in a clean, otherwise-empty window): revenue_cents and
  --    identified_revenue_cents must both be 7000 (cInactive only), never 11000.
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin
    g := public.get_revenue_driver_decomposition_v109(
      v_biz, v_from, v_to_excl, v_today - 70, v_today - 60, v_branch);
    v_val := (g #>> '{periods,current,revenue_cents}')::bigint;
    if v_val <> 60000 then
      insert into _fail values ('E_v109driver_current',
        format('periods.current.revenue_cents = %s (expected 60000)', v_val));
    end if;
    v_val := (g #>> '{periods,current,identified_revenue_cents}')::bigint;
    if v_val <> 50000 then
      insert into _fail values ('E_v109driver_current_id',
        format('periods.current.identified_revenue_cents = %s (expected 50000)', v_val));
    end if;
    v_val := (g #>> '{periods,comparison,revenue_cents}')::bigint;
    if v_val <> 7000 then
      insert into _fail values ('E_v109driver_comparison',
        format('periods.comparison.revenue_cents = %s (expected 7000)', v_val));
    end if;
    v_val := (g #>> '{periods,comparison,identified_revenue_cents}')::bigint;
    if v_val <> 7000 then
      insert into _fail values ('E_v109driver_comparison_id',
        format('periods.comparison.identified_revenue_cents = %s (expected 7000)', v_val));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('E_v109driver', format('raised %s', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- F. public.get_period_economics_v109 -- owner. coverage.eligible_sales must be 10 (8 real +
  --    2 anonymous, never 12), coverage.eligible_revenue_cents must be 60000, never 66000.
  ----------------------------------------------------------------------------------------------
  begin
    g := public.get_period_economics_v109(v_biz, v_from, v_to_excl, v_branch);
    v_val := (g #>> '{coverage,eligible_sales}')::bigint;
    if v_val <> 10 then
      insert into _fail values ('F_v109econ_sales', format('coverage.eligible_sales = %s (expected 10)', v_val));
    end if;
    v_val := (g #>> '{coverage,eligible_revenue_cents}')::bigint;
    if v_val <> 60000 then
      insert into _fail values ('F_v109econ_revenue',
        format('coverage.eligible_revenue_cents = %s (expected 60000)', v_val));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('F_v109econ', format('raised %s', v_err));
  end;

  perform set_config('request.jwt.claims', null, true);

  raise notice 'v742 | business_id=% | real: 50000 cents / 8 visit-days (5 clients) + inactivity-bucket (1) + away/return (1) = 7 real | synthetic: shared (net 6000, 1 client) + inactivity-bucket (1) + away/return (1) = 3 synthetic, excluded everywhere | anonymous: 10000 cents (2 sales)',
    v_biz;
end
$v742$;

select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v742: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

select case when count(*) = 0
            then 'PASS -- v742: staff_list_returned_customers_v300, get_customer_lifecycle_v107, '
                 'preview_campaign_audience_v155, staff_list_customers_v129, '
                 'get_revenue_driver_decomposition_v109 and get_period_economics_v109 all exclude '
                 'a synthetic client''s real sales/visits from every reported total and roster, '
                 'each verified as its real principal (owner / non-owner staff / non-owner manager)'
            else 'FAIL' end as verdict,
       count(*) as failures
from _fail;

rollback;
