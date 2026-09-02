-- EXECUTED acceptance fixture for nestly_v699 — one visit-day authority (check 4 refutation) and
-- the app.ci_envelope_v680 wrap gap it exposed on two readers (check 16).
--
-- Named for v699 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- Reads db/migrations/20260920_nestly_v699_visit_day_authority.sql.
--
-- AUTH: every reader here goes through app.ci_access_gate_v667 (platform arm admits a super
-- admin outright) or, for get_customer_lifecycle_v107, its own `app.is_super_admin() or
-- app.has_perm(...)` / `app.can_see_branch` checks, which likewise admit a super admin
-- unconditionally (nestly_v17/v94) — so this fixture, like nestly_v683's own corpus, runs
-- entirely under one super-admin session and needs no operational-business plumbing (no staff
-- roster, no workspace approval, no subscription row).
--
-- PREDETERMINED TRUTH TABLE (computed before running anything):
--   CATEGORY_CUSTOMERS (client CC1, taxonomy node A): 3 sales on day1 (1000+1500+500 cents) and
--     1 sale on day2 (2000 cents) -> visits (new rule) = 2 distinct visit-days, revenue_cents =
--     5000. Under the OLD raw-row rule visits would have been 4. Four filler clients (1 node-A
--     sale each, day1) bring the node-A cohort to 5, at nestly_v667's k=5 small-cell floor, so
--     get_ci_category_customers_v1 does not suppress CC1's own row (CI-CORPUS-FIXTURE-GUIDE:
--     "assert your preconditions").
--   STAFF_PERFORMANCE (client SP1, staff Alice, service SVC): 3 sale_items on the SAME day
--     (500+700+300 cents), same client, same staff, same service -> visits (new rule) = 1 distinct
--     (client, visit-day) pair. Under the OLD raw-line rule visits would have been 3.
--     revenue_cents = 1500 either way (sums are unchanged by the definition change).
--   DISCOUNT_DEPENDENCY:
--     D1 (the literal case this migration's header quotes): day1 has 2 sales (one discounted,
--       one full-price) + day2 1 full-price sale + day3 1 full-price sale -> all_visits (new) = 3,
--       discounted_visits (new) = 1, full_price_visits (new) = 2 (>=2, so D1 counts toward
--       full_price_repeat_customers). Discounted-share = 1/3 = 33.3% -> class 'mixed' under BOTH
--       old and new counting (25% old vs 33.3% new; this client alone does not cross a
--       classification boundary — it exists to pin the literal all_visits/discounted numbers this
--       migration's header states, verified directly against public.sales/sale_items below,
--       bypassing the function entirely).
--     D2 (the class-boundary proof): 5 full-price days (1 sale each) + 1 further day carrying 2
--       DISCOUNTED sales -> OLD raw-row ratio = 2/7 = 28.6% -> 'mixed'. NEW visit-day ratio =
--       1/6 = 16.7% -> 'organic'. A customer who is 'organic' under the new rule and 'mixed' under
--       the old one is a real, observable classification flip in the function's own OUTPUT (not
--       merely an internal number this fixture computes by hand) — the strongest available proof
--       the reader's CODE changed, not just this fixture's arithmetic.
--     -> classes: organic n=1 (D2 only), mixed n=1 (D1 only), discount_dependent n=0,
--        insufficient n=0. full_price_repeat_customers = 2 (D1 has 2 full-price visit-days, D2
--        has 5).
--   V179_REGULARS (separate business bizv179, so its 45-180-day at_risk window cannot pick up any
--     other client above): V179A has 2 sales on ONE day ("two tickets one afternoon", 100 days
--     ago) -> lifetime_visits (new) = 1 -> NOT a regular (`lifetime_visits >= 2` fails) -> absent
--     from at_risk. V179B has 2 sales on TWO different days (100 and 99 days ago) -> lifetime_
--     visits (new) = 2 -> a regular, last_visit_at 99 days ago (inside the 45-180-day at_risk
--     window) -> IS in at_risk. -> at_risk.customers = 1 (V179B only; V179A's raw sale count of 2
--     would have wrongly qualified it under the OLD rule, which is exactly the bug), their_
--     lifetime_revenue_cents = V179B's own 2500. recovery_value_one_visit_each_cents is null: with
--     exactly one at-risk customer, evidence is 'insufficient' (n=1 < the v672 floor of 5) and
--     nestly_v690 already gates this rate-like figure behind that floor — raw counts (customers,
--     their_lifetime_revenue_cents) are never gated and stay populated.
--   REGISTRY: app.ci_visit_registry_v699() names 8 readers; the 5 'uses_authority':true entries
--     are each called above (or, for get_customer_lifecycle_v107, called directly below) and
--     shown to dedupe by day; the 3 'uses_authority':false entries' live bodies are checked, via
--     pg_get_functiondef, to not reference app.ci_visit_day_v699 at all — the registry does not
--     claim an authority a body does not use.

\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

do $v699$
declare
  biz        uuid := '00000000-0000-4000-8000-000000699001';
  bizv179    uuid := '00000000-0000-4000-8000-000000699002';
  bizdisc    uuid := '00000000-0000-4000-8000-000000699003';
  br1        uuid := '00000000-0000-4000-8000-000000699011';
  brv179     uuid := '00000000-0000-4000-8000-000000699012';
  brdisc     uuid := '00000000-0000-4000-8000-000000699013';
  u_sa       uuid := '00000000-0000-4000-8000-000000699091';
  staffA     uuid := '00000000-0000-4000-8000-000000699081';
  svc        uuid := '00000000-0000-4000-8000-000000699041';
  svcdisc    uuid := '00000000-0000-4000-8000-000000699042';

  cc1 uuid := '00000000-0000-4000-8000-000000699101';
  ccf1 uuid := '00000000-0000-4000-8000-000000699111';
  ccf2 uuid := '00000000-0000-4000-8000-000000699112';
  ccf3 uuid := '00000000-0000-4000-8000-000000699113';
  ccf4 uuid := '00000000-0000-4000-8000-000000699114';
  sp1  uuid := '00000000-0000-4000-8000-000000699121';
  d1   uuid := '00000000-0000-4000-8000-000000699131';
  d2   uuid := '00000000-0000-4000-8000-000000699132';
  v179a uuid := '00000000-0000-4000-8000-000000699141';
  v179b uuid := '00000000-0000-4000-8000-000000699142';

  nodeA text;
  day1 date; day2 date;

  p_from_cc date; p_to_cc date;
  p_from_disc date; p_to_disc date;
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_dlast date; v_dlast_minus1 date;
  v_from_v179 date; v_to_v179 date; v_prior_from_v179 date; v_prior_to_v179 date;

  v_as_of timestamptz := clock_timestamp();

  g_cc jsonb; g_sp jsonb; g_disc jsonb; g_v179 jsonb; g_life jsonb; g_reg jsonb;
  x_row jsonb; alice_row jsonb;
  v_err text;
  v_def text;
  n integer;
  i integer;
  cl uuid;
begin
  ---------------------------------------------------------------------------
  -- super-admin identity (nestly_v625 requires a real oauth-shaped session).
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values (u_sa, 'zz-v699-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v699-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  begin
    perform app.ci_access_gate_v667(biz, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('pre-gate', format('super admin cannot pass ci gate (sqlstate %s)', v_err));
    return;
  end;

  ---------------------------------------------------------------------------
  -- business/branch (reporting_contract_versions_v106 and customer_lifecycle_policies_v107
  -- both auto-seed via trigger on business/branch insert — no manual policy row needed).
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v699 fixture', 'zz-v699-fixture',
          array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (br1, biz, 'ZZ v699 branch', true, true);
  -- The auto-seed trigger stamps effective_from = NOW; every sale below is dated ~300 days in
  -- the past, so an explicit far-past contract row is needed or get_customer_lifecycle_v107's
  -- app.v106_reporting_contract lookup finds no matching row for those historical sales at all
  -- (lateral join excludes them from `eligible` entirely — the v692 fixture hits the same trap).
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  values (biz, null, 2, '-infinity', 'Asia/Singapore', 'SGD', true),
         (biz, br1,  2, '-infinity', 'Asia/Singapore', 'SGD', true)
  on conflict do nothing;

  insert into public.staff (id, business_id, user_id, role, full_name, active) values
    (staffA, biz, null, 'staff', 'ZZ v699 Alice', true);
  insert into public.services (id, business_id, name, price_cents, duration_min)
  values (svc, biz, 'ZZ v699 service', 500, 30);

  select n.node_key into nodeA from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 order by n.node_key limit 1;
  if nodeA is null then
    insert into _fail values ('pre-taxonomy', 'no level-2 taxonomy node at version 1');
    return;
  end if;

  day1 := current_date - 300;
  day2 := day1 + 1;
  p_from_cc := day1; p_to_cc := day2;

  insert into public.clients (id, business_id, full_name) values
    (cc1, biz, 'ZZ v699 CC1'),
    (ccf1, biz, 'ZZ v699 filler1'),
    (ccf2, biz, 'ZZ v699 filler2'),
    (ccf3, biz, 'ZZ v699 filler3'),
    (ccf4, biz, 'ZZ v699 filler4'),
    (sp1, biz, 'ZZ v699 SP1');

  -- Discount-dependency clients live in their OWN business: get_ci_discount_dependency_v1 scans
  -- every qualifying sale in the business (no category/service filter), so D1/D2 must not share
  -- `biz` with CC1/SP1 or their full-price visit-days would inflate full_price_repeat_customers.
  insert into public.businesses (id, name, slug, enabled_modules)
  values (bizdisc, 'ZZ v699 discount fixture', 'zz-v699-discount-fixture',
          array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (brdisc, bizdisc, 'ZZ v699 discount branch', true, true);
  insert into public.services (id, business_id, name, price_cents, duration_min)
  values (svcdisc, bizdisc, 'ZZ v699 discount service', 500, 30);
  insert into public.clients (id, business_id, full_name) values
    (d1, bizdisc, 'ZZ v699 D1'),
    (d2, bizdisc, 'ZZ v699 D2');

  -- ===========================================================================================
  -- CATEGORY_CUSTOMERS: CC1 3 same-day + 1 next-day, all node A. 4 fillers clear the k=5 floor.
  -- ===========================================================================================
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit)
  values
    ('00000000-0000-4000-8000-000000699201', biz, br1, cc1, 'service', 1000,
     (day1::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000699202', biz, br1, cc1, 'service', 1500,
     (day1::timestamp + time '11:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000699203', biz, br1, cc1, 'service', 500,
     (day1::timestamp + time '15:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000699204', biz, br1, cc1, 'service', 2000,
     (day2::timestamp + time '10:00') at time zone 'Asia/Singapore', v_as_of, true, true);
  insert into public.sale_items (business_id, sale_id, item_type, canonical_node_key, qty, unit_cents, line_cents)
  values
    (biz, '00000000-0000-4000-8000-000000699201', 'service', nodeA, 1, 1000, 1000),
    (biz, '00000000-0000-4000-8000-000000699202', 'service', nodeA, 1, 1500, 1500),
    (biz, '00000000-0000-4000-8000-000000699203', 'service', nodeA, 1, 500, 500),
    (biz, '00000000-0000-4000-8000-000000699204', 'service', nodeA, 1, 2000, 2000);

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit)
  values
    ('00000000-0000-4000-8000-000000699211', biz, br1, ccf1, 'service', 100,
     (day1::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000699212', biz, br1, ccf2, 'service', 100,
     (day1::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000699213', biz, br1, ccf3, 'service', 100,
     (day1::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000699214', biz, br1, ccf4, 'service', 100,
     (day1::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true);
  insert into public.sale_items (business_id, sale_id, item_type, canonical_node_key, qty, unit_cents, line_cents)
  values
    (biz, '00000000-0000-4000-8000-000000699211', 'service', nodeA, 1, 100, 100),
    (biz, '00000000-0000-4000-8000-000000699212', 'service', nodeA, 1, 100, 100),
    (biz, '00000000-0000-4000-8000-000000699213', 'service', nodeA, 1, 100, 100),
    (biz, '00000000-0000-4000-8000-000000699214', 'service', nodeA, 1, 100, 100);

  begin
    g_cc := public.get_ci_category_customers_v1(biz, nodeA, p_from_cc, p_to_cc, 100, null, v_as_of);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('CC-call', format('get_ci_category_customers_v1 raised %s', v_err));
    return;
  end;

  if (g_cc->>'visit_definition') is distinct from
     'one per customer per calendar day (Asia/Singapore); split bills count once' then
    insert into _fail values ('CC-visit-def', coalesce(g_cc->>'visit_definition', '<null>'));
  end if;

  select c into x_row from jsonb_array_elements(g_cc->'customers') c
   where (c->>'client_id')::uuid = cc1;
  if x_row is null then
    insert into _fail values ('CC-present', 'CC1 absent from get_ci_category_customers_v1 (k=5 floor not cleared?)');
  else
    if (x_row->>'visits')::bigint is distinct from 2 then
      insert into _fail values ('CC-visits', format('expected 2 distinct visit-days, got %s', x_row->>'visits'));
    end if;
    if (x_row->>'revenue_cents')::bigint is distinct from 5000 then
      insert into _fail values ('CC-revenue', format('expected 5000, got %s', x_row->>'revenue_cents'));
    end if;
    -- MUTATION: the wrong (old, raw-row) expectation must NOT match.
    if (x_row->>'visits')::bigint = 4 then
      insert into _fail values ('CC-mutation', 'visits still reads the OLD raw-row count (4), not the new visit-day count (2)');
    end if;
  end if;

  -- ===========================================================================================
  -- STAFF_PERFORMANCE: SP1, staff Alice, 3 same-day, same-service lines -> visits should be 1.
  -- ===========================================================================================
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit)
  values
    ('00000000-0000-4000-8000-000000699301', biz, br1, sp1, 'service', 500,
     (day1::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000699302', biz, br1, sp1, 'service', 700,
     (day1::timestamp + time '10:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000699303', biz, br1, sp1, 'service', 300,
     (day1::timestamp + time '11:00') at time zone 'Asia/Singapore', v_as_of, true, true);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents, staff_id)
  values
    (biz, '00000000-0000-4000-8000-000000699301', 'service', svc, 1, 500, 500, staffA),
    (biz, '00000000-0000-4000-8000-000000699302', 'service', svc, 1, 700, 700, staffA),
    (biz, '00000000-0000-4000-8000-000000699303', 'service', svc, 1, 300, 300, staffA);

  begin
    g_sp := public.get_ci_staff_performance_v1(biz, day1, day1, null, v_as_of);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SP-call', format('get_ci_staff_performance_v1 raised %s', v_err));
    return;
  end;

  if (g_sp->>'visit_definition') is distinct from
     'one per customer per calendar day (Asia/Singapore); split bills count once' then
    insert into _fail values ('SP-visit-def', coalesce(g_sp->>'visit_definition', '<null>'));
  end if;

  -- check 16: envelope now present.
  if (g_sp->'exclusions'->>'reversed_sales') is null
     or (g_sp->'exclusions'->>'synthetic_clients') is null
     or (g_sp->'exclusions'->>'anonymous_sales') is null
     or (g_sp->>'trace_id') is null
     or (g_sp->>'as_of') is null
     or (g_sp->'period'->>'from') is null then
    insert into _fail values ('SP-envelope', format('expected exclusions/trace_id/as_of/period keys from app.ci_envelope_v680, got %s', g_sp));
  end if;
  if (g_sp->'exclusions'->>'reversed_sales')::bigint is distinct from 0
     or (g_sp->'exclusions'->>'synthetic_clients')::bigint is distinct from 0
     or (g_sp->'exclusions'->>'anonymous_sales')::bigint is distinct from 0 then
    insert into _fail values ('SP-exclusions-zero', format('expected all-zero exclusions for this clean fixture, got %s', g_sp->'exclusions'));
  end if;

  select s into alice_row from jsonb_array_elements(coalesce(g_sp->'staff', '[]'::jsonb)) s
   where (s->>'staff_id')::uuid = staffA;
  if alice_row is null then
    insert into _fail values ('SP-present', 'Alice absent from get_ci_staff_performance_v1');
  else
    if (alice_row->'unadjusted'->>'visits')::bigint is distinct from 1 then
      insert into _fail values ('SP-visits', format('expected 1 distinct (client, day) pair, got %s',
        alice_row->'unadjusted'->>'visits'));
    end if;
    if (alice_row->'unadjusted'->>'revenue_cents')::bigint is distinct from 1500 then
      insert into _fail values ('SP-revenue', format('expected revenue_cents=1500 (unchanged by the visit definition), got %s',
        alice_row->'unadjusted'->>'revenue_cents'));
    end if;
    -- MUTATION: the wrong (old, raw-line) expectation must NOT match.
    if (alice_row->'unadjusted'->>'visits')::bigint = 3 then
      insert into _fail values ('SP-mutation', 'visits still reads the OLD raw-line count (3), not the new visit-day count (1)');
    end if;
  end if;

  -- ===========================================================================================
  -- DISCOUNT_DEPENDENCY: D1 pins the literal all_visits=3/discounted=1 numbers (verified
  -- independently against public.sales/sale_items, bypassing the function); D2 crosses a class
  -- boundary (mixed under the OLD rule, organic under the NEW one) — a proof the reader's CODE,
  -- not merely this fixture's arithmetic, changed.
  -- ===========================================================================================
  -- D1: day1 = 2 sales (one discounted), day2 + day3 = 1 full-price sale each.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit)
  values
    ('00000000-0000-4000-8000-000000699401', bizdisc, brdisc, d1, 'service',2000,
     (day1::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000699402', bizdisc, brdisc, d1, 'service',1000,
     (day1::timestamp + time '15:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000699403', bizdisc, brdisc, d1, 'service',1200,
     ((day1 + 1)::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000699404', bizdisc, brdisc, d1, 'service',1300,
     ((day1 + 2)::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values
    (bizdisc, '00000000-0000-4000-8000-000000699401', 'service', svcdisc, 1, 2000, 2000),
    (bizdisc, '00000000-0000-4000-8000-000000699402', 'service', svcdisc, 1, 1000, 1000),
    (bizdisc, '00000000-0000-4000-8000-000000699403', 'service', svcdisc, 1, 1200, 1200),
    (bizdisc, '00000000-0000-4000-8000-000000699404', 'service', svcdisc, 1, 1300, 1300);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (bizdisc, '00000000-0000-4000-8000-000000699401', 'studio_discount', null, 1, -300, -300);

  -- D2: 5 full-price days (1 sale each), then 1 further day with 2 discounted sales.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit)
  select ('00000000-0000-4000-8000-0000006994' || lpad((10+gs.k)::text, 2, '0'))::uuid,
         bizdisc, brdisc, d2, 'service', 1000,
         ((day1 + gs.k)::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true
    from generate_series(0, 4) as gs(k);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select bizdisc, ('00000000-0000-4000-8000-0000006994' || lpad((10+gs.k)::text, 2, '0'))::uuid,
         'service', svcdisc, 1, 1000, 1000
    from generate_series(0, 4) as gs(k);
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit)
  values
    ('00000000-0000-4000-8000-000000699420', bizdisc, brdisc, d2, 'service', 900,
     ((day1 + 5)::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000699421', bizdisc, brdisc, d2, 'service', 850,
     ((day1 + 5)::timestamp + time '11:00') at time zone 'Asia/Singapore', v_as_of, true, true);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values
    (bizdisc, '00000000-0000-4000-8000-000000699420', 'service', svcdisc, 1, 900, 900),
    (bizdisc, '00000000-0000-4000-8000-000000699421', 'service', svcdisc, 1, 850, 850);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values
    (bizdisc, '00000000-0000-4000-8000-000000699420', 'studio_discount', null, 1, -200, -200),
    (bizdisc, '00000000-0000-4000-8000-000000699421', 'studio_discount', null, 1, -150, -150);

  p_from_disc := day1; p_to_disc := day1 + 6;

  -- PRE-CHECK: pin the literal all_visits/discounted numbers for D1 directly against
  -- public.sales/sale_items, bypassing the function entirely (CI-CORPUS-FIXTURE-GUIDE style).
  select count(distinct app.ci_visit_day_v699(s.occurred_at)),
         count(distinct app.ci_visit_day_v699(s.occurred_at)) filter (
           where exists (select 1 from public.sale_items di where di.sale_id = s.id
                          and di.item_type = 'studio_discount' and di.line_cents < 0))
    into n, i
    from public.sales s
   where s.business_id = bizdisc and s.client_id = d1 and s.reversal_of is null
     and s.counts_as_visit
     and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from_disc and p_to_disc;
  if n <> 3 or i <> 1 then
    insert into _fail values ('DISC-pre-arith', format('expected D1 all_visits=3 discounted=1, got %s/%s', n, i));
  end if;

  begin
    g_disc := public.get_ci_discount_dependency_v1(bizdisc, p_from_disc, p_to_disc, null, v_as_of);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('DISC-call', format('get_ci_discount_dependency_v1 raised %s', v_err));
    return;
  end;

  if (g_disc->>'visit_definition') is null then
    insert into _fail values ('DISC-visit-def', 'visit_definition key missing');
  end if;
  if (g_disc->'exclusions'->>'reversed_sales') is null or (g_disc->>'trace_id') is null then
    insert into _fail values ('DISC-envelope', format('expected exclusions/trace_id from app.ci_envelope_v680, got %s', g_disc));
  end if;

  if (g_disc->'classes'->'organic'->>'n')::int is distinct from 1 then
    insert into _fail values ('DISC-organic-n', format('expected 1 (D2 only, new visit-day rule), got %s',
      g_disc->'classes'->'organic'->>'n'));
  end if;
  if (g_disc->'classes'->'mixed'->>'n')::int is distinct from 1 then
    insert into _fail values ('DISC-mixed-n', format('expected 1 (D1 only), got %s', g_disc->'classes'->'mixed'->>'n'));
  end if;
  if (g_disc->'classes'->'discount_dependent'->>'n')::int is distinct from 0 then
    insert into _fail values ('DISC-dependent-n', g_disc->'classes'->'discount_dependent'->>'n');
  end if;
  if (g_disc->>'full_price_repeat_customers')::int is distinct from 2 then
    insert into _fail values ('DISC-full-price-repeat', format('expected 2 (D1 and D2), got %s',
      g_disc->>'full_price_repeat_customers'));
  end if;
  -- MUTATION: the wrong (old, raw-row) classification for D2 must NOT hold — under the old rule
  -- D2's ratio is 2/7=28.6%, 'mixed', so organic.n would have been 0, not 1.
  if (g_disc->'classes'->'organic'->>'n')::int = 0 then
    insert into _fail values ('DISC-mutation', 'D2 still classifies as the OLD raw-row ''mixed'' (organic n=0), not the new visit-day ''organic''');
  end if;

  -- ===========================================================================================
  -- V179_REGULARS: separate business so its at_risk window cannot pick up any client above.
  -- ===========================================================================================
  insert into public.businesses (id, name, slug, enabled_modules)
  values (bizv179, 'ZZ v699 v179 fixture', 'zz-v699-v179-fixture',
          array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (brv179, bizv179, 'ZZ v699 v179 branch', true, true);
  insert into public.clients (id, business_id, full_name) values
    (v179a, bizv179, 'ZZ v699 V179A two-tickets-one-afternoon'),
    (v179b, bizv179, 'ZZ v699 V179B two-days');

  v_dlast := v_today - 100;
  v_dlast_minus1 := v_today - 99;

  -- V179A: 2 sales, SAME day (one afternoon) -> lifetime_visits should be 1, not a regular.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit)
  values
    ('00000000-0000-4000-8000-000000699501', bizv179, brv179, v179a, 'service', 1000,
     (v_dlast::timestamp + time '14:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000699502', bizv179, brv179, v179a, 'service', 1500,
     (v_dlast::timestamp + time '16:00') at time zone 'Asia/Singapore', v_as_of, true, true);

  -- V179B: 2 sales, TWO different days -> lifetime_visits = 2, a regular, last visit inside the
  -- 45-180-day at_risk window.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit)
  values
    ('00000000-0000-4000-8000-000000699511', bizv179, brv179, v179b, 'service', 1200,
     (v_dlast::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000699512', bizv179, brv179, v179b, 'service', 1300,
     (v_dlast_minus1::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true);

  v_to_v179 := v_today; v_from_v179 := v_today - 6;
  v_prior_to_v179 := v_from_v179; v_prior_from_v179 := v_prior_to_v179 - 6;

  begin
    g_v179 := app.v179_business_insights(bizv179, v_from_v179, v_to_v179, v_prior_from_v179, v_prior_to_v179);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('V179-call', format('app.v179_business_insights raised %s', v_err));
    return;
  end;

  if (g_v179->>'visit_definition') is null then
    insert into _fail values ('V179-visit-def', 'visit_definition key missing');
  end if;

  if (g_v179->'at_risk'->>'customers')::int is distinct from 1 then
    insert into _fail values ('V179-atrisk-customers', format(
      'expected 1 (V179B only; V179A''s 2 same-day sales are 1 visit-day, not a regular), got %s',
      g_v179->'at_risk'->>'customers'));
  end if;
  if (g_v179->'at_risk'->>'their_lifetime_revenue_cents')::bigint is distinct from 2500 then
    insert into _fail values ('V179-atrisk-revenue', format('expected 2500 (V179B only), got %s',
      g_v179->'at_risk'->>'their_lifetime_revenue_cents'));
  end if;
  -- CI-STAT-AUTHORITY-CONTRACT (nestly_v690): recovery_value_one_visit_each_cents is a rate-like
  -- verdict derived from avg_ticket_cents = lifetime_revenue_cents/lifetime_visits, so it is null
  -- below the v672 floor of 5 — this fixture deliberately has exactly ONE at-risk customer
  -- (evidence n=1, 'insufficient'), so the correct expectation is null, not a computed figure;
  -- 'customers' and 'their_lifetime_revenue_cents' are raw counts and stay populated regardless.
  if (g_v179->'at_risk'->'evidence'->>'status') is distinct from 'insufficient' then
    insert into _fail values ('V179-atrisk-evidence', format('expected insufficient (n=1 < floor 5), got %s',
      g_v179->'at_risk'->'evidence'));
  end if;
  if (g_v179->'at_risk'->>'recovery_value_one_visit_each_cents') is not null then
    insert into _fail values ('V179-atrisk-recovery', format(
      'expected null (below the v672 evidence floor), got %s',
      g_v179->'at_risk'->>'recovery_value_one_visit_each_cents'));
  end if;
  -- MUTATION: the wrong (old, raw-sale) expectation must NOT hold — under the old rule V179A ALSO
  -- has lifetime_visits=2 and would ALSO qualify, making customers=2 and revenue=5000.
  if (g_v179->'at_risk'->>'customers')::int = 2
     or (g_v179->'at_risk'->>'their_lifetime_revenue_cents')::bigint = 5000 then
    insert into _fail values ('V179-mutation', 'at_risk still admits V179A under the OLD raw-sale-count rule');
  end if;

  -- ===========================================================================================
  -- LIFECYCLE v107 (nestly_v692's own fix) — registry cross-check, not a re-proof of v692's own
  -- corpus: CC1 (3 same-day + 1 next-day sales, in `biz`) is a repeat purchaser (2 visit-days)
  -- over a window covering both days; the 4 filler clients (1 sale each) are not.
  -- ===========================================================================================
  begin
    g_life := public.get_customer_lifecycle_v107(biz, p_from_cc, p_to_cc + 1, null, v_as_of);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('LIFE-call', format('get_customer_lifecycle_v107 raised %s', v_err));
    return;
  end;
  if (g_life#>>'{metrics,repeat_purchasers_in_period}')::bigint is distinct from 1 then
    insert into _fail values ('LIFE-repeat', format('expected 1 (CC1 only, 2 visit-days), got %s',
      g_life#>>'{metrics,repeat_purchasers_in_period}'));
  end if;

  -- ===========================================================================================
  -- REGISTRY: named, and checked against reality.
  -- ===========================================================================================
  g_reg := app.ci_visit_registry_v699();
  if (g_reg->'readers'->'get_ci_category_customers_v1'->>'uses_authority')::boolean is distinct from true
     or (g_reg->'readers'->'get_ci_staff_performance_v1'->>'uses_authority')::boolean is distinct from true
     or (g_reg->'readers'->'get_ci_discount_dependency_v1'->>'uses_authority')::boolean is distinct from true
     or (g_reg->'readers'->'app.v179_business_insights'->>'uses_authority')::boolean is distinct from true
     or (g_reg->'readers'->'get_customer_lifecycle_v107'->>'uses_authority')::boolean is distinct from true then
    insert into _fail values ('REG-true-entries', format('one or more of the 5 authority readers is not marked true: %s', g_reg->'readers'));
  end if;
  if (g_reg->'readers'->'get_ci_daypart_v1'->>'uses_authority')::boolean is distinct from false
     or (g_reg->'readers'->'get_ci_funnel_conversion_v1'->>'uses_authority')::boolean is distinct from false
     or (g_reg->'readers'->'get_ci_retention_windows_v1'->>'uses_authority')::boolean is distinct from false then
    insert into _fail values ('REG-false-entries', format('one or more non-authority readers is not marked false: %s', g_reg->'readers'));
  end if;

  -- Honesty check: the three 'false' entries' own live bodies must not reference the authority
  -- function at all — the registry must not claim a deferral that does not exist.
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_daypart_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then
    insert into _fail values ('REG-daypart-missing', 'public.get_ci_daypart_v1(uuid,date,date,uuid,timestamptz) not found');
  elsif position('ci_visit_day_v699' in v_def) > 0 then
    insert into _fail values ('REG-daypart-honesty', 'get_ci_daypart_v1 references app.ci_visit_day_v699 but the registry marks it false');
  end if;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid,timestamptz)')) into v_def;
  if v_def is null then
    insert into _fail values ('REG-funnel-missing', 'public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid,timestamptz) not found');
  elsif position('ci_visit_day_v699' in v_def) > 0 then
    insert into _fail values ('REG-funnel-honesty', 'get_ci_funnel_conversion_v1 references app.ci_visit_day_v699 but the registry marks it false');
  end if;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then
    insert into _fail values ('REG-retention-missing', 'public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz) not found');
  elsif position('ci_visit_day_v699' in v_def) > 0 then
    insert into _fail values ('REG-retention-honesty', 'get_ci_retention_windows_v1 references app.ci_visit_day_v699 but the registry marks it false');
  end if;

  perform set_config('request.jwt.claims', null, true);
end
$v699$;

select case when count(*)=0
            then 'PASS — v699: one visit-day authority applied to category_customers, '
                 'staff_performance, discount_dependency and v179_business_insights; both '
                 'staff_performance and discount_dependency now carry the app.ci_envelope_v680 '
                 'exclusions block; the registry names 8 readers and matches reality'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v699: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
