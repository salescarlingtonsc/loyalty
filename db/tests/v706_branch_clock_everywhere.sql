-- EXECUTED acceptance fixture for nestly_v706 -- branch clock everywhere (check 8) across
-- public.get_ci_funnel_conversion_v1, public.get_ci_retention_windows_v1,
-- public.get_ci_demographic_cohort_v1, app.customer_cadence_v1, app.v179_business_insights, and
-- get_ci_discovery_v1's weekday dimension -- plus the three floor-gate leaks folded into the same
-- migration (funnel per-stage gating, discovery seasonality current_pct, v179
-- existing_customer_return_rate_pct).
--
-- Named for v706 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md). Proves
-- db/migrations/20260920_nestly_v706_branch_clock_everywhere.sql.
--
-- AUTH CONTEXT. Same reasoning as v698/v693's corpus: a super-admin session clears
-- app.ci_access_gate_v667's platform arm outright, so this fixture does not need a fully
-- operational merchant workspace -- it is not testing entitlement.
--
-- THE PIVOT INSTANT (reused from v698, same fixture-guide-blessed truth table):
--   2026-08-09 17:00:00 UTC -> SGT/Perth (both +8, no DST) Monday 2026-08-10 01:00
--                            -> IST (+5:30) Sunday 2026-08-09 22:30
-- A single-day window of exactly [2026-08-09, 2026-08-09] therefore includes this sale under a
-- Kolkata-resolved clock (its own local date is the 9th) and EXCLUDES it under the SG/Perth clock
-- (local date is the 10th) -- the mutation-sensitive proof used for funnel population inclusion
-- and demographic-cohort qualifying-purchase inclusion below. Perth's identical offset to SG
-- proves the arithmetic only depends on the ZONE, not which same-offset zone NAME resolved.
--
-- THE MONTH-BOUNDARY PIVOT (retention cohort_month):
--   2026-07-31 17:00:00 UTC -> SGT/Perth Saturday 2026-08-01 01:00 (August)
--                            -> IST Friday 2026-07-31 22:30 (July)
-- Same sale, same window [2026-07-25, 2026-08-05] (wide enough to contain BOTH candidate dates so
-- inclusion itself never differs) -- but cohort_month resolves to 2026-07 under Kolkata and
-- 2026-08 under SG/Perth.

\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

do $v706$
declare
  u_sa uuid := '00000000-0000-4000-8000-000000706099';
  v_err text;
  v_node text;

  -- ===== Scenario A/B/C: bizM, 3 branches, shared pivot sales =====
  bizM   uuid := '00000000-0000-4000-8000-000000706001';
  br_sg  uuid := '00000000-0000-4000-8000-000000706002';
  br_kol uuid := '00000000-0000-4000-8000-000000706003';
  br_pt  uuid := '00000000-0000-4000-8000-000000706004';

  c_fun_kol uuid; c_fun_pt uuid;
  r_fun_kol jsonb; r_fun_mixed jsonb; r_fun_pt jsonb;

  c_ret uuid;
  r_ret_kol jsonb; r_ret_mixed jsonb;
  cohort_jul jsonb; cohort_aug jsonb;

  c_dem_kol uuid; c_dem_pt uuid;
  r_dem_kol jsonb; r_dem_mixed jsonb;

  s_id uuid;

  -- ===== Scenario D: v179 weekday_pattern, single-branch firm resolution =====
  bizKol uuid := '00000000-0000-4000-8000-000000706011';
  brKolOnly uuid := '00000000-0000-4000-8000-000000706012';
  bizSg  uuid := '00000000-0000-4000-8000-000000706013';
  brSgOnly  uuid := '00000000-0000-4000-8000-000000706014';
  c_v179k uuid; c_v179s uuid;
  r_v179k jsonb; r_v179s jsonb;
  row_kol jsonb; row_sg jsonb;

  -- ===== Scenario E: v179 existing_customer_return_rate_pct floor gate =====
  bizV179n3 uuid := '00000000-0000-4000-8000-000000706021';
  bizV179n5 uuid := '00000000-0000-4000-8000-000000706022';
  r_v179n3 jsonb; r_v179n5 jsonb;
  i int;
  cl uuid;

  -- ===== Scenario F: funnel per-stage floor gate (check 62, three-of-three trap) =====
  bizFunN3 uuid := '00000000-0000-4000-8000-000000706031';
  bizFunN5 uuid := '00000000-0000-4000-8000-000000706032';
  r_fun_n3 jsonb; r_fun_n5 jsonb;
  d0 date;

  -- ===== Scenario G: discovery bucket_timezone disclosure + seasonality current_pct floor gate =====
  bizDisc uuid := '00000000-0000-4000-8000-000000706041';
  brDisc uuid := '00000000-0000-4000-8000-000000706042';
  r_disc jsonb;
  bizDiscN3 uuid := '00000000-0000-4000-8000-000000706043';
  bizDiscN5 uuid := '00000000-0000-4000-8000-000000706044';
  r_discn3 jsonb; r_discn5 jsonb;
  disc_from date; disc_to date;
begin
  ---------------------------------------------------------------------------
  -- platform (super admin) session -- see CI-CORPUS-FIXTURE-GUIDE.md
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values (u_sa, 'zz-v706-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v706-sa@example.test')
    on conflict do nothing;

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  select n.node_key into v_node from public.taxonomy_nodes n where n.version_no = 1 limit 1;
  if v_node is null then
    insert into _fail values ('PRE-taxonomy', 'no taxonomy_nodes at version_no=1 -- fixture cannot build a category');
  end if;

  ---------------------------------------------------------------------------
  -- SCENARIOS A/B/C setup -- bizM, three branches on three timezones
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (bizM, 'ZZ v706 branch-clock fixture', 'zz-v706-branch-clock',
     array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active, timezone) values
    (br_sg, bizM, 'ZZ v706 branch SG', true, true, 'Asia/Singapore');
  insert into public.branches (id, business_id, name, is_default, active, timezone, billing_state)
  values (br_kol, bizM, 'ZZ v706 branch Kolkata', false, true, 'Asia/Kolkata', 'active');
  insert into public.branches (id, business_id, name, is_default, active, timezone, billing_state)
  values (br_pt, bizM, 'ZZ v706 branch Perth', false, true, 'Australia/Perth', 'active');

  if not (select br.active from public.branches br where br.id = br_kol) then
    insert into _fail values ('PRE-kol-inactive', 'br_kol was forced inactive by the second-branch billing trap');
  end if;
  if not (select br.active from public.branches br where br.id = br_pt) then
    insert into _fail values ('PRE-pt-inactive', 'br_pt was forced inactive by the second-branch billing trap');
  end if;

  begin
    perform app.ci_access_gate_v667(bizM, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PRE-gate-M', format('super admin cannot pass ci_access_gate_v667 for bizM (sqlstate %s)', v_err));
  end;

  ---------------------------------------------------------------------------
  -- SCENARIO A -- get_ci_funnel_conversion_v1 population-window inclusion
  ---------------------------------------------------------------------------
  c_fun_kol := gen_random_uuid();
  c_fun_pt := gen_random_uuid();
  insert into public.clients (id, business_id, full_name) values
    (c_fun_kol, bizM, 'ZZ v706 funnel client kol'),
    (c_fun_pt, bizM, 'ZZ v706 funnel client pt');

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), bizM, br_kol, c_fun_kol, 'service', 1000, '2026-08-09 17:00:00+00', '2026-08-09 17:00:00+00');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), bizM, br_pt, c_fun_pt, 'service', 1000, '2026-08-09 17:00:00+00', '2026-08-09 17:00:00+00');

  r_fun_kol := public.get_ci_funnel_conversion_v1(bizM, '2026-08-09', '2026-08-09', 60, br_kol, '2026-11-01T00:00:00+00');
  r_fun_mixed := public.get_ci_funnel_conversion_v1(bizM, '2026-08-09', '2026-08-09', 60, null, '2026-11-01T00:00:00+00');
  r_fun_pt := public.get_ci_funnel_conversion_v1(bizM, '2026-08-09', '2026-08-09', 60, br_pt, '2026-11-01T00:00:00+00');

  if r_fun_kol->>'bucket_timezone' is distinct from 'Asia/Kolkata' or r_fun_kol->>'timezone_basis' is distinct from 'branch' then
    insert into _fail values ('A-kol-tz', (r_fun_kol->>'bucket_timezone') || '/' || (r_fun_kol->>'timezone_basis'));
  end if;
  if (r_fun_kol->'evidence'->>'n')::int is distinct from 1 then
    insert into _fail values ('A-kol-n', coalesce(r_fun_kol->'evidence'->>'n','null'));
  end if;
  if r_fun_kol->'stage_1_to_2'->>'pct' is not null then
    insert into _fail values ('A-kol-stage-pct-leak', 'n=1 < floor(5) but stage_1_to_2.pct was not null: ' || (r_fun_kol->'stage_1_to_2'->>'pct'));
  end if;
  if r_fun_kol->'stage_1_to_2'->>'denominator' is distinct from '1' then
    insert into _fail values ('A-kol-stage-denom', coalesce(r_fun_kol->'stage_1_to_2'->>'denominator','null'));
  end if;

  if r_fun_mixed->>'bucket_timezone' is distinct from 'Asia/Singapore' or r_fun_mixed->>'timezone_basis' is distinct from 'mixed_branches_default' then
    insert into _fail values ('A-mixed-tz', (r_fun_mixed->>'bucket_timezone') || '/' || (r_fun_mixed->>'timezone_basis'));
  end if;
  if (r_fun_mixed->'evidence'->>'n')::int is distinct from 0 then
    insert into _fail values ('A-mixed-n', coalesce(r_fun_mixed->'evidence'->>'n','null'));
  end if;

  if r_fun_pt->>'bucket_timezone' is distinct from 'Australia/Perth' or r_fun_pt->>'timezone_basis' is distinct from 'branch' then
    insert into _fail values ('A-pt-tz', (r_fun_pt->>'bucket_timezone') || '/' || (r_fun_pt->>'timezone_basis'));
  end if;
  if (r_fun_pt->'evidence'->>'n')::int is distinct from 0 then
    insert into _fail values ('A-pt-no-change', 'Perth (same +8 offset as SG) should also exclude this client, got n=' || coalesce(r_fun_pt->'evidence'->>'n','null'));
  end if;

  ---------------------------------------------------------------------------
  -- SCENARIO B -- get_ci_retention_windows_v1 cohort_month
  ---------------------------------------------------------------------------
  c_ret := gen_random_uuid();
  insert into public.clients (id, business_id, full_name) values (c_ret, bizM, 'ZZ v706 retention client');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), bizM, br_kol, c_ret, 'service', 1000, '2026-07-31 17:00:00+00', '2026-07-31 17:00:00+00');

  r_ret_kol := public.get_ci_retention_windows_v1(bizM, '2026-07-25', '2026-08-05', br_kol, '2026-08-10T00:00:00+00');
  r_ret_mixed := public.get_ci_retention_windows_v1(bizM, '2026-07-25', '2026-08-05', null, '2026-08-10T00:00:00+00');

  select c into cohort_jul from jsonb_array_elements(r_ret_kol->'cohorts') c where c->>'month' = '2026-07';
  select c into cohort_aug from jsonb_array_elements(r_ret_kol->'cohorts') c where c->>'month' = '2026-08';
  if cohort_jul is null or (cohort_jul->>'n')::int is distinct from 1 then
    insert into _fail values ('B-kol-cohort-jul', 'expected a 2026-07 cohort of n=1 under Kolkata clock, got ' || coalesce(r_ret_kol->'cohorts'->>0, 'null'));
  end if;
  if cohort_aug is not null then
    insert into _fail values ('B-kol-cohort-aug-leak', 'client should NOT appear in the 2026-08 cohort under Kolkata clock');
  end if;

  select c into cohort_jul from jsonb_array_elements(r_ret_mixed->'cohorts') c where c->>'month' = '2026-07';
  select c into cohort_aug from jsonb_array_elements(r_ret_mixed->'cohorts') c where c->>'month' = '2026-08';
  if cohort_aug is null or (cohort_aug->>'n')::int is distinct from 1 then
    insert into _fail values ('B-mixed-cohort-aug', 'expected a 2026-08 cohort of n=1 under SG-default clock, got ' || coalesce(r_ret_mixed::text, 'null'));
  end if;
  if cohort_jul is not null then
    insert into _fail values ('B-mixed-cohort-jul-leak', 'client should NOT appear in the 2026-07 cohort under SG-default clock');
  end if;

  ---------------------------------------------------------------------------
  -- SCENARIO C -- get_ci_demographic_cohort_v1 qualifying-purchase window inclusion
  ---------------------------------------------------------------------------
  c_dem_kol := gen_random_uuid();
  c_dem_pt := gen_random_uuid();
  insert into public.clients (id, business_id, full_name, gender, birth_date) values
    (c_dem_kol, bizM, 'ZZ v706 demographic client kol', 'female', '1999-01-01'),
    (c_dem_pt, bizM, 'ZZ v706 demographic client pt', 'female', '1999-01-01');

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), bizM, br_kol, c_dem_kol, 'service', 1000, '2026-08-09 17:00:00+00', '2026-08-09 17:00:00+00')
  returning id into s_id;
  insert into public.sale_items (id, sale_id, business_id, item_type, qty, unit_cents, line_cents, canonical_node_key)
  values (gen_random_uuid(), s_id, bizM, 'service', 1, 1000, 1000, v_node);

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), bizM, br_pt, c_dem_pt, 'service', 1000, '2026-08-09 17:00:00+00', '2026-08-09 17:00:00+00')
  returning id into s_id;
  insert into public.sale_items (id, sale_id, business_id, item_type, qty, unit_cents, line_cents, canonical_node_key)
  values (gen_random_uuid(), s_id, bizM, 'service', 1, 1000, 1000, v_node);

  r_dem_kol := public.get_ci_demographic_cohort_v1(bizM, 'female', 20, 35, v_node, '2026-08-09', '2026-08-09', 60, br_kol, '2026-11-01T00:00:00+00');
  r_dem_mixed := public.get_ci_demographic_cohort_v1(bizM, 'female', 20, 35, v_node, '2026-08-09', '2026-08-09', 60, null, '2026-11-01T00:00:00+00');

  if r_dem_kol->>'bucket_timezone' is distinct from 'Asia/Kolkata' or r_dem_kol->>'timezone_basis' is distinct from 'branch' then
    insert into _fail values ('C-kol-tz', (r_dem_kol->>'bucket_timezone') || '/' || (r_dem_kol->>'timezone_basis'));
  end if;
  if (r_dem_kol->>'customers')::int is distinct from 1 then
    insert into _fail values ('C-kol-customers', coalesce(r_dem_kol->>'customers','null'));
  end if;

  if r_dem_mixed->>'bucket_timezone' is distinct from 'Asia/Singapore' or r_dem_mixed->>'timezone_basis' is distinct from 'mixed_branches_default' then
    insert into _fail values ('C-mixed-tz', (r_dem_mixed->>'bucket_timezone') || '/' || (r_dem_mixed->>'timezone_basis'));
  end if;
  if (r_dem_mixed->>'customers')::int is distinct from 0 then
    insert into _fail values ('C-mixed-customers', 'expected the Aug-10-under-SG-default purchase to fall OUTSIDE the single-day window, got ' || coalesce(r_dem_mixed->>'customers','null'));
  end if;

  ---------------------------------------------------------------------------
  -- SCENARIO D -- app.v179_business_insights weekday_pattern, firm-level resolution
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (bizKol, 'ZZ v706 v179 Kolkata firm', 'zz-v706-v179-kol', array['dashboard','clients','sales','reports']),
    (bizSg,  'ZZ v706 v179 SG firm',      'zz-v706-v179-sg',  array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active, timezone) values
    (brKolOnly, bizKol, 'ZZ v706 sole branch kol', true, true, 'Asia/Kolkata'),
    (brSgOnly,  bizSg,  'ZZ v706 sole branch sg',  true, true, 'Asia/Singapore');

  c_v179k := gen_random_uuid();
  c_v179s := gen_random_uuid();
  insert into public.clients (id, business_id, full_name) values
    (c_v179k, bizKol, 'ZZ v706 v179 client kol'),
    (c_v179s, bizSg, 'ZZ v706 v179 client sg');

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), bizKol, brKolOnly, c_v179k, 'service', 1000, '2026-08-09 17:00:00+00', '2026-08-09 17:00:00+00');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), bizSg, brSgOnly, c_v179s, 'service', 1000, '2026-08-09 17:00:00+00', '2026-08-09 17:00:00+00');

  r_v179k := app.v179_business_insights(bizKol, '2026-08-08', '2026-08-11', '2025-08-08', '2025-08-11');
  r_v179s := app.v179_business_insights(bizSg,  '2026-08-08', '2026-08-11', '2025-08-08', '2025-08-11');

  if r_v179k->'weekday_pattern'->>'bucket_timezone' is distinct from 'Asia/Kolkata'
     or r_v179k->'weekday_pattern'->>'timezone_basis' is distinct from 'firm_agreed' then
    insert into _fail values ('D-kol-tz', (r_v179k->'weekday_pattern'->>'bucket_timezone') || '/' || (r_v179k->'weekday_pattern'->>'timezone_basis'));
  end if;
  select rr into row_kol from jsonb_array_elements(r_v179k->'weekday_pattern'->'rows') rr where (rr->>'isodow')::int = 7;
  if row_kol is null or (row_kol->>'visits')::int is distinct from 1 or (row_kol->>'revenue_cents')::int is distinct from 1000 then
    insert into _fail values ('D-kol-sunday', 'expected isodow=7 (Sunday, IST-bucketed) with 1 visit/1000 cents, got ' || coalesce(r_v179k->'weekday_pattern'->'rows'->>0,'null'));
  end if;
  select rr into row_kol from jsonb_array_elements(r_v179k->'weekday_pattern'->'rows') rr where (rr->>'isodow')::int = 1;
  if row_kol is not null then
    insert into _fail values ('D-kol-monday-leak', 'sale should not have landed on isodow=1 (Monday) under the Kolkata firm clock');
  end if;

  if r_v179s->'weekday_pattern'->>'bucket_timezone' is distinct from 'Asia/Singapore'
     or r_v179s->'weekday_pattern'->>'timezone_basis' is distinct from 'firm_agreed' then
    insert into _fail values ('D-sg-tz', (r_v179s->'weekday_pattern'->>'bucket_timezone') || '/' || (r_v179s->'weekday_pattern'->>'timezone_basis'));
  end if;
  select rr into row_sg from jsonb_array_elements(r_v179s->'weekday_pattern'->'rows') rr where (rr->>'isodow')::int = 1;
  if row_sg is null or (row_sg->>'visits')::int is distinct from 1 or (row_sg->>'revenue_cents')::int is distinct from 1000 then
    insert into _fail values ('D-sg-monday', 'expected isodow=1 (Monday, SGT-bucketed) with 1 visit/1000 cents, got ' || coalesce(r_v179s->'weekday_pattern'->'rows'->>0,'null'));
  end if;

  ---------------------------------------------------------------------------
  -- SCENARIO E -- v179 existing_customer_return_rate_pct floor gate (n=3 vs n=5)
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (bizV179n3, 'ZZ v706 v179 n3', 'zz-v706-v179-n3', array['dashboard','clients','sales','reports']),
    (bizV179n5, 'ZZ v706 v179 n5', 'zz-v706-v179-n5', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active, timezone) values
    (gen_random_uuid(), bizV179n3, 'ZZ branch', true, true, 'Asia/Singapore'),
    (gen_random_uuid(), bizV179n5, 'ZZ branch', true, true, 'Asia/Singapore');

  for i in 1..3 loop
    cl := gen_random_uuid();
    insert into public.clients (id, business_id, full_name) values (cl, bizV179n3, 'ZZ v706 n3 client ' || i);
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at) values
      (gen_random_uuid(), bizV179n3, cl, 'service', 1000, '2026-06-01 03:00:00+00', '2026-06-01 03:00:00+00'),
      (gen_random_uuid(), bizV179n3, cl, 'service', 1000, '2026-08-09 03:00:00+00', '2026-08-09 03:00:00+00');
  end loop;

  for i in 1..5 loop
    cl := gen_random_uuid();
    insert into public.clients (id, business_id, full_name) values (cl, bizV179n5, 'ZZ v706 n5 client ' || i);
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at) values
      (gen_random_uuid(), bizV179n5, cl, 'service', 1000, '2026-06-01 03:00:00+00', '2026-06-01 03:00:00+00'),
      (gen_random_uuid(), bizV179n5, cl, 'service', 1000, '2026-08-09 03:00:00+00', '2026-08-09 03:00:00+00');
  end loop;

  r_v179n3 := app.v179_business_insights(bizV179n3, '2026-08-01', '2026-08-15', '2025-08-01', '2025-08-15');
  r_v179n5 := app.v179_business_insights(bizV179n5, '2026-08-01', '2026-08-15', '2025-08-01', '2025-08-15');

  if (r_v179n3->'retention'->>'customers_served')::int is distinct from 3 then
    insert into _fail values ('E-n3-denom', coalesce(r_v179n3->'retention'->>'customers_served','null'));
  end if;
  if (r_v179n3->'retention'->>'existing_customers_who_returned')::int is distinct from 3 then
    insert into _fail values ('E-n3-numer', coalesce(r_v179n3->'retention'->>'existing_customers_who_returned','null'));
  end if;
  if r_v179n3->'retention'->>'existing_customer_return_rate_pct' is not null then
    insert into _fail values ('E-n3-pct-leak', 'n=3 < floor(5): expected null pct, got ' || (r_v179n3->'retention'->>'existing_customer_return_rate_pct'));
  end if;
  if r_v179n3->'retention'->'existing_customer_return_evidence'->>'status' is distinct from 'insufficient' then
    insert into _fail values ('E-n3-evidence', coalesce(r_v179n3->'retention'->'existing_customer_return_evidence'->>'status','null'));
  end if;

  if (r_v179n5->'retention'->>'customers_served')::int is distinct from 5 then
    insert into _fail values ('E-n5-denom', coalesce(r_v179n5->'retention'->>'customers_served','null'));
  end if;
  if r_v179n5->'retention'->>'existing_customer_return_rate_pct' is distinct from '100.0' then
    insert into _fail values ('E-n5-pct', 'n=5 >= floor(5): expected pct=100.0, got ' || coalesce(r_v179n5->'retention'->>'existing_customer_return_rate_pct','null'));
  end if;
  if r_v179n5->'retention'->'existing_customer_return_evidence'->>'status' is distinct from 'ok' then
    insert into _fail values ('E-n5-evidence', coalesce(r_v179n5->'retention'->'existing_customer_return_evidence'->>'status','null'));
  end if;

  ---------------------------------------------------------------------------
  -- SCENARIO F -- funnel stage_1_to_2 / stage_2_to_3 floor gate (check 62: three-of-three trap)
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (bizFunN3, 'ZZ v706 funnel n3', 'zz-v706-funnel-n3', array['dashboard','clients','sales','reports']),
    (bizFunN5, 'ZZ v706 funnel n5', 'zz-v706-funnel-n5', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active, timezone) values
    (gen_random_uuid(), bizFunN3, 'ZZ branch', true, true, 'Asia/Singapore'),
    (gen_random_uuid(), bizFunN5, 'ZZ branch', true, true, 'Asia/Singapore');

  d0 := current_date - 300;

  for i in 1..3 loop
    cl := gen_random_uuid();
    insert into public.clients (id, business_id, full_name) values (cl, bizFunN3, 'ZZ v706 funnel n3 client ' || i);
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at) values
      (gen_random_uuid(), bizFunN3, cl, 'service', 1000, d0 + time '09:00', d0 + time '09:00'),
      (gen_random_uuid(), bizFunN3, cl, 'service', 1000, (d0+10) + time '09:00', (d0+10) + time '09:00');
  end loop;

  for i in 1..5 loop
    cl := gen_random_uuid();
    insert into public.clients (id, business_id, full_name) values (cl, bizFunN5, 'ZZ v706 funnel n5 client ' || i);
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at) values
      (gen_random_uuid(), bizFunN5, cl, 'service', 1000, d0 + time '09:00', d0 + time '09:00'),
      (gen_random_uuid(), bizFunN5, cl, 'service', 1000, (d0+10) + time '09:00', (d0+10) + time '09:00');
  end loop;

  r_fun_n3 := public.get_ci_funnel_conversion_v1(bizFunN3, d0 - 2, d0 + 2, 60, null, now());
  r_fun_n5 := public.get_ci_funnel_conversion_v1(bizFunN5, d0 - 2, d0 + 2, 60, null, now());

  if (r_fun_n3->'evidence'->>'n')::int is distinct from 3 then
    insert into _fail values ('F-n3-evidence-n', coalesce(r_fun_n3->'evidence'->>'n','null'));
  end if;
  if r_fun_n3->'stage_1_to_2'->>'numerator' is distinct from '3' or r_fun_n3->'stage_1_to_2'->>'denominator' is distinct from '3' then
    insert into _fail values ('F-n3-stage1-counts', coalesce(r_fun_n3->'stage_1_to_2'->>'numerator','null') || '/' || coalesce(r_fun_n3->'stage_1_to_2'->>'denominator','null'));
  end if;
  if r_fun_n3->'stage_1_to_2'->>'pct' is not null then
    insert into _fail values ('F-n3-stage1-pct-leak', 'three-of-three trap (check 62): 3/3=100% must be withheld below the floor, got ' || (r_fun_n3->'stage_1_to_2'->>'pct'));
  end if;
  if r_fun_n3->'stage_2_to_3'->>'pct' is not null then
    insert into _fail values ('F-n3-stage2-pct-leak', 'expected stage_2_to_3.pct withheld at n=3, got ' || (r_fun_n3->'stage_2_to_3'->>'pct'));
  end if;

  if (r_fun_n5->'evidence'->>'n')::int is distinct from 5 then
    insert into _fail values ('F-n5-evidence-n', coalesce(r_fun_n5->'evidence'->>'n','null'));
  end if;
  if r_fun_n5->'stage_1_to_2'->>'pct' is distinct from '100.0' then
    insert into _fail values ('F-n5-stage1-pct', 'expected 5/5=100.0 at n=5 (evidence sufficient), got ' || coalesce(r_fun_n5->'stage_1_to_2'->>'pct','null'));
  end if;
  if r_fun_n5->'stage_2_to_3'->>'pct' is distinct from '0.0' then
    insert into _fail values ('F-n5-stage2-pct', 'expected 0/5=0.0 (real value, not withheld) at n=5, got ' || coalesce(r_fun_n5->'stage_2_to_3'->>'pct','null'));
  end if;

  ---------------------------------------------------------------------------
  -- SCENARIO G -- discovery: bucket_timezone disclosure + seasonality current_pct floor gate
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (bizDisc, 'ZZ v706 discovery tz', 'zz-v706-discovery-tz', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active, timezone) values
    (brDisc, bizDisc, 'ZZ branch kol', true, true, 'Asia/Kolkata');

  begin
    perform app.ci_access_gate_v667(bizDisc, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PRE-gate-disc', format('super admin cannot pass ci_access_gate_v667 for bizDisc (sqlstate %s)', v_err));
  end;

  cl := gen_random_uuid();
  insert into public.clients (id, business_id, full_name) values (cl, bizDisc, 'ZZ v706 discovery client');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), bizDisc, brDisc, cl, 'service', 1000, '2026-08-03 09:00:00+00', '2026-08-03 09:00:00+00');

  r_disc := public.get_ci_discovery_v1(bizDisc, '2026-08-01', '2026-08-10', null, '2026-11-01T00:00:00+00');
  if r_disc->'scope'->>'bucket_timezone' is distinct from 'Asia/Kolkata'
     or r_disc->'scope'->>'timezone_basis' is distinct from 'firm_agreed' then
    insert into _fail values ('G-disc-tz', (r_disc->'scope'->>'bucket_timezone') || '/' || (r_disc->'scope'->>'timezone_basis'));
  end if;

  -- seasonality current_pct floor gate (n=3 vs n=5); mature := (current_date - anchor_date) >= 30,
  -- so anchor dates are pinned well in the past of the REAL wall clock, not p_as_of.
  insert into public.businesses (id, name, slug, enabled_modules) values
    (bizDiscN3, 'ZZ v706 discovery n3', 'zz-v706-discovery-n3', array['dashboard','clients','sales','reports']),
    (bizDiscN5, 'ZZ v706 discovery n5', 'zz-v706-discovery-n5', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active, timezone) values
    (gen_random_uuid(), bizDiscN3, 'ZZ branch', true, true, 'Asia/Singapore'),
    (gen_random_uuid(), bizDiscN5, 'ZZ branch', true, true, 'Asia/Singapore');

  disc_from := current_date - 100;
  disc_to := current_date - 90;

  for i in 1..3 loop
    cl := gen_random_uuid();
    insert into public.clients (id, business_id, full_name) values (cl, bizDiscN3, 'ZZ v706 disc n3 client ' || i);
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at) values
      (gen_random_uuid(), bizDiscN3, cl, 'service', 1000, disc_from + time '09:00', disc_from + time '09:00');
  end loop;

  for i in 1..5 loop
    cl := gen_random_uuid();
    insert into public.clients (id, business_id, full_name) values (cl, bizDiscN5, 'ZZ v706 disc n5 client ' || i);
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at) values
      (gen_random_uuid(), bizDiscN5, cl, 'service', 1000, disc_from + time '09:00', disc_from + time '09:00');
  end loop;

  r_discn3 := public.get_ci_discovery_v1(bizDiscN3, disc_from, disc_to, null, now());
  r_discn5 := public.get_ci_discovery_v1(bizDiscN5, disc_from, disc_to, null, now());

  if r_discn3->'seasonality'->>'current_pct' is not null then
    insert into _fail values ('G-n3-current-pct-leak', 'n=3 < floor(5): expected null current_pct, got ' || (r_discn3->'seasonality'->>'current_pct'));
  end if;
  if r_discn5->'seasonality'->>'current_pct' is distinct from '0.0' then
    insert into _fail values ('G-n5-current-pct', 'n=5 >= floor(5): expected real value 0.0 (no returns), got ' || coalesce(r_discn5->'seasonality'->>'current_pct','null'));
  end if;

  ---------------------------------------------------------------------------
  -- VOCABULARY -- no CAUSAL claim leaked into any payload touched by this migration.
  ---------------------------------------------------------------------------
  if r_fun_kol::text like '%CAUSAL%' or r_fun_mixed::text like '%CAUSAL%' or r_fun_pt::text like '%CAUSAL%'
     or r_ret_kol::text like '%CAUSAL%' or r_ret_mixed::text like '%CAUSAL%'
     or r_dem_kol::text like '%CAUSAL%' or r_dem_mixed::text like '%CAUSAL%'
     or r_v179k::text like '%CAUSAL%' or r_v179s::text like '%CAUSAL%'
     or r_disc::text like '%CAUSAL%' then
    insert into _fail values ('VOCAB', 'CAUSAL found in a v706-touched payload');
  end if;
end
$v706$;

select case when count(*) = 0
            then 'PASS -- v706 branch clock everywhere + three floor-gate leak fixes'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v706: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
