-- EXECUTED scale measurement for the Customer Intelligence RPC family.
--
-- WHY THIS FILE EXISTS
-- Customer Intelligence was audited on 2026-08-26 before being considered for release. Every
-- figure it displays reconciled against base tables, but the reconciliation ran on Cubbly SPA,
-- which holds 72 sales — so it proved correctness and said nothing at all about cost. The
-- launch evidence for reporting scale (docs/launch/evidence-plan/P0-REPORTING-SCALE-006.md) is
-- classified OWNER-ACTION-SCRIPTED: the representative-volume dataset it describes has never
-- been seeded, and scripts/reporting-scale/reporting-scale.test.mjs is a STATIC source-analysis
-- test that executes no SQL. There was therefore no measured scale evidence for these RPCs at
-- all, and none for the reporting family generally.
--
-- Rather than stand up a second scale framework, this file uses the harness that already
-- exists: `npm run test:db` boots a real Postgres from the committed schema snapshot, so every
-- trigger, index, RLS policy and RPC body here is the real one. No production access.
--
-- WHAT IT MEASURES
--   200 businesses (multi-tenant table size, so no index degenerates to a single-tenant scan)
--   1 large tenant: 2,000 customers, 24,000 sales across 2 branches and 18 months
--   then every RPC the Customer Intelligence screen actually calls:
--     S1  get_customer_intelligence_v83   — the dominant customer-table read (250-row page)
--     S2  get_revenue_truth_v106          — the headline revenue block
--     S3  get_customer_lifecycle_v107     — the retention summary (also used by Business Insights)
--     S4  get_customer_intelligence_v83   — second page via the keyset cursor
--     S5  get_customer_intelligence_v83   — single-branch scope
--
-- THRESHOLD. Each call must finish inside 5000 ms. That is a generous ceiling chosen to catch
-- the failure this test exists to catch — an accidental O(n^2) or a missing index turning a
-- report into a timeout — and NOT to pin current performance. A tight budget here would fail on
-- CI hardware variance and teach everyone to ignore it. The observed numbers are raised as
-- NOTICEs so a regression is visible in the log even while the assertion passes.
--
-- HONEST LIMITS
--   * Sales are inserted with user triggers disabled on public.sales. The loyalty side-effects
--     (points_ledger, points_batches, retention) are therefore NOT seeded, so this file measures
--     the READ path of the reporting RPCs and must not be read as proof about the earn path.
--     Disabling is safe here and only here: this is a throwaway cluster inside one transaction.
--   * v109 economics/decomposition/sector-policy are deliberately absent. They are gated behind
--     the platform flag `economics_driver_policy_v109`, which is OFF in production, so they
--     refuse with 0A000 before touching data and there is nothing to measure. When that flag is
--     turned on they must be added here, and that is a precondition of turning it on.
--   * Timings come from clock_timestamp() around each call on a local cluster. They establish an
--     order of magnitude and a regression tripwire, not a production SLA.
--
-- WHY IT IS NAMED FOR THE WATERMARK, NOT FOR A MIGRATION
-- v83, v106 and v107 all long predate the snapshot watermark (v422), so this is a regression
-- FLOOR, not a migration gate: `npm run test:db` runs it against the frozen baseline AND against
-- the baseline with every pending migration applied, and it must pass in both. Naming it for a
-- migration that does not exist would make the harness report it as a suspicious already-green
-- migration test in the baseline phase.
--
-- The whole file is one transaction and rolls back. Failures RAISE.

\set ON_ERROR_STOP on

begin;

do $scale$
declare
  v_biz          uuid := '00000000-0000-4000-8000-00000000c1a1';
  v_owner        uuid := '00000000-0000-4000-8000-00000000c1a2';
  v_branch_a     uuid := '00000000-0000-4000-8000-00000000c1a3';
  v_branch_b     uuid := '00000000-0000-4000-8000-00000000c1a4';
  v_customers    integer := 2000;
  v_sales        integer := 24000;
  v_filler       integer := 199;
  v_budget_ms    numeric := 5000;
  t0             timestamptz;
  v_ms           numeric;
  v_payload      jsonb;
  v_cursor       timestamptz;
  v_cursor_id    uuid;
  v_rows         integer;
begin
  -- ---------------------------------------------------------------- multi-tenant table size
  insert into public.businesses (id, name, slug)
  select gen_random_uuid(), 'ZZ scale filler '||g, 'zz-scale-filler-'||g
  from generate_series(1, v_filler) g;

  /* nestly_v689 (ci_gate_alignment) tightened get_customer_intelligence_v83's own gate to
     app.has_perm(business,'view_finance') AND app.can_module(business,'customerintel'). The
     latter resolves through app.effective_platform_module_mode_v94's sector_entitlement branch,
     which reads businesses.enabled_modules directly (nestly_v668 removed the short-circuit that
     used to answer 'disabled' ahead of the entitlement — see the identical note in
     v667_ci_access_boundaries.sql). The default enabled_modules
     ('{dashboard,clients,sales,loyalty,retention}', frenly_v2_saas) has never included
     'customerintel', so even this fixture's owner failed can_module and hit
     'view_finance_required' until this column was set explicitly. */
  insert into public.businesses (id, name, slug, enabled_modules) values
    (v_biz, 'ZZ scale subject', 'zz-scale-subject',
      array['dashboard','clients','sales','reports','customerintel']);

  insert into public.branches (id, business_id, name) values
    (v_branch_a, v_biz, 'Scale branch A'),
    (v_branch_b, v_biz, 'Scale branch B');

  -- The reporting RPCs resolve the actor through auth.uid(); this is the owner they will find.
  insert into auth.users (id, email) values (v_owner, 'zz-scale-owner@example.test')
  on conflict (id) do nothing;
  insert into public.staff (business_id, user_id, role, active)
  values (v_biz, v_owner, 'owner', true);

  /* app.has_perm gates on app.business_workspace_open_v94 before it looks at the role at all —
     an unapproved or payment-paused workspace has no permissions, by design. A new business
     already gets both rows from its own insert trigger, in the PENDING shape, so this promotes
     them rather than creating them; without it every RPC below refuses view_finance_required. */
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (v_biz, 'approved', now(), 'scale fixture')
  on conflict (business_id) do update
    set approval_status='approved', decided_at=now(), decision_reason='scale fixture';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (v_biz, 'current', false)
  on conflict (business_id) do update set state='current', workspace_paused=false;
  /* v620 (nestly_v620_entitlement_authority): app.business_workspace_open_v94 now delegates to
     app.business_operational_v620, which additionally requires a paid (or trialing)
     subscriptions row via a LEFT JOIN -- an approved+unpaused workspace with no subscriptions
     row resolves both the paid and trialing conjuncts to NULL/false, so has_perm(...,
     'view_finance') refuses even the owner with 'view_finance_required'. This is a v689 report
     (the merchant arm of app.ci_access_gate_v667 now requires view_finance explicitly), not a
     permission-catalogue gap: app.role_perms('owner') has always included 'view_finance' — see
     the same note in v422_baseline_behaviours.sql / v425_referral_typed_payout.sql. */
  insert into public.subscriptions(business_id, status, payment_status, current_period_end)
  values (v_biz, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update
    set status = 'active', payment_status = 'paid',
        current_period_end = now() + interval '30 days';

  /* v106 assigns every sale to a period through app.v106_reporting_contract, a per
     (business, branch) timezone+currency contract. With no contract row the lateral join
     matches nothing and known_revenue comes back 0 — which would have made the S2 measurement
     below a timing of the empty set rather than of 24,000 sales. Production carries a
     branch_id IS NULL row plus one per branch, both effective from -infinity for legacy data.
     The table is append-only, and creating a business/branch already mints a version 1 effective
     from that moment — which would leave this fixture's backdated sales out of contract — so
     these are added as a second version reaching back to -infinity. */
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  values (v_biz, null,       2, '-infinity', 'Asia/Singapore', 'SGD', true),
         (v_biz, v_branch_a, 2, '-infinity', 'Asia/Singapore', 'SGD', true),
         (v_biz, v_branch_b, 2, '-infinity', 'Asia/Singapore', 'SGD', true)
  on conflict do nothing;

  -- ---------------------------------------------------------------- the large tenant
  insert into public.clients (id, business_id, full_name, phone, created_at)
  select gen_random_uuid(), v_biz, 'Scale customer '||g, '8'||lpad(g::text, 7, '0'),
         now() - make_interval(days => 540 - (g % 540))
  from generate_series(1, v_customers) g;

  /* Triggers off for the bulk insert — see HONEST LIMITS. Read-path measurement only. */
  alter table public.sales disable trigger user;

  insert into public.sales
    (id, business_id, branch_id, client_id, kind, amount_cents,
     counts_as_revenue, counts_as_visit, earns_points, policy_resolved_at,
     commission_rate_bps, commission_resolved_at, occurred_at, created_at)
  select
    gen_random_uuid(), v_biz,
    case when g % 2 = 0 then v_branch_a else v_branch_b end,
    c.id,
    case when g % 11 = 0 then 'retail' else 'quick_sale' end,
    /* A spread of amounts, plus a deliberate slice of zero-price rows so the "paid visit"
       (non-zero) definition is genuinely exercised rather than trivially equal to all rows. */
    case when g % 9 = 0 then 0 else 500 + (g % 400) * 25 end,
    true, true, true, now(), 0, now(),
    now() - make_interval(days => 540 - (g % 540), mins => g % 1440),
    now() - make_interval(days => 540 - (g % 540))
  from generate_series(1, v_sales) g
  join lateral (
    select cl.id from public.clients cl
     where cl.business_id = v_biz
     offset (g % v_customers) limit 1
  ) c on true;

  alter table public.sales enable trigger user;

  analyze public.sales;
  analyze public.clients;
  analyze public.businesses;

  raise notice 'seeded: % businesses, % customers, % sales',
    v_filler + 1, v_customers, v_sales;

  -- The RPCs are SECURITY DEFINER and read auth.uid(); become the owner for the measurements.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role', 'authenticated')::text, true);

  -- ---------------------------------------------------------------- S1 customer table
  t0 := clock_timestamp();
  v_payload := public.get_customer_intelligence_v83(
    v_biz, null, (now() - interval '180 days')::date, now()::date, 250, null, null, null);
  v_ms := extract(epoch from clock_timestamp() - t0) * 1000;
  v_rows := jsonb_array_length(v_payload -> 'customers');
  raise notice 'S1 get_customer_intelligence_v83 (page 1, % rows): % ms', v_rows, round(v_ms, 1);
  if v_ms > v_budget_ms then
    raise exception 'S1 get_customer_intelligence_v83 took % ms, over the % ms budget', round(v_ms,1), v_budget_ms;
  end if;
  if v_rows <> 250 then
    raise exception 'S1 expected a full 250-row page, got %', v_rows;
  end if;
  if (v_payload -> 'pagination' ->> 'has_more') <> 'true' then
    raise exception 'S1 expected has_more=true with % customers seeded', v_customers;
  end if;

  -- ---------------------------------------------------------------- S2 revenue truth
  t0 := clock_timestamp();
  v_payload := public.get_revenue_truth_v106(
    v_biz, (now() - interval '180 days')::date, (now() + interval '1 day')::date, null, now());
  v_ms := extract(epoch from clock_timestamp() - t0) * 1000;
  raise notice 'S2 get_revenue_truth_v106: % ms (known revenue %, % transactions)',
    round(v_ms, 1), v_payload -> 'totals' ->> 'known_revenue_minor',
    v_payload -> 'totals' ->> 'completed_transactions';
  /* A timing is only evidence if it measured the rows. The first run of this file reported a
     confident 141 ms against known_revenue 0, because the reporting contract above was missing. */
  if coalesce((v_payload -> 'totals' ->> 'completed_transactions')::bigint, 0) < 1000 then
    raise exception 'S2 measured an almost-empty set (% transactions) — the fixture, not the RPC, is wrong',
      v_payload -> 'totals' ->> 'completed_transactions';
  end if;
  if v_ms > v_budget_ms then
    raise exception 'S2 get_revenue_truth_v106 took % ms, over the % ms budget', round(v_ms,1), v_budget_ms;
  end if;

  -- ---------------------------------------------------------------- S3 lifecycle
  t0 := clock_timestamp();
  v_payload := public.get_customer_lifecycle_v107(
    v_biz, (now() - interval '180 days')::date, (now() + interval '1 day')::date, null, now());
  v_ms := extract(epoch from clock_timestamp() - t0) * 1000;
  raise notice 'S3 get_customer_lifecycle_v107: % ms', round(v_ms, 1);
  if v_ms > v_budget_ms then
    raise exception 'S3 get_customer_lifecycle_v107 took % ms, over the % ms budget', round(v_ms,1), v_budget_ms;
  end if;

  -- ---------------------------------------------------------------- S4 keyset second page
  v_payload := public.get_customer_intelligence_v83(
    v_biz, null, (now() - interval '180 days')::date, now()::date, 250, null, null, null);
  v_cursor := (v_payload -> 'customers' -> 249 ->> 'customer_since')::timestamptz;
  v_cursor_id := (v_payload -> 'customers' -> 249 ->> 'client_id')::uuid;
  t0 := clock_timestamp();
  v_payload := public.get_customer_intelligence_v83(
    v_biz, null, (now() - interval '180 days')::date, now()::date, 250, null, v_cursor, v_cursor_id);
  v_ms := extract(epoch from clock_timestamp() - t0) * 1000;
  v_rows := jsonb_array_length(v_payload -> 'customers');
  raise notice 'S4 get_customer_intelligence_v83 (page 2 via keyset, % rows): % ms', v_rows, round(v_ms, 1);
  if v_ms > v_budget_ms then
    raise exception 'S4 keyset page 2 took % ms, over the % ms budget', round(v_ms,1), v_budget_ms;
  end if;
  if v_rows = 0 then
    raise exception 'S4 keyset cursor returned nothing — pagination cannot walk the set';
  end if;

  -- ---------------------------------------------------------------- S5 single-branch scope
  t0 := clock_timestamp();
  v_payload := public.get_customer_intelligence_v83(
    v_biz, v_branch_a, (now() - interval '180 days')::date, now()::date, 250, null, null, null);
  v_ms := extract(epoch from clock_timestamp() - t0) * 1000;
  raise notice 'S5 get_customer_intelligence_v83 (single branch): % ms', round(v_ms, 1);
  if v_ms > v_budget_ms then
    raise exception 'S5 single-branch scope took % ms, over the % ms budget', round(v_ms,1), v_budget_ms;
  end if;

  raise notice 'Customer Intelligence scale measurement passed at % customers / % sales',
    v_customers, v_sales;
end
$scale$;

rollback;
