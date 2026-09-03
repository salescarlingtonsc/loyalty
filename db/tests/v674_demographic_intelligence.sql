-- EXECUTED acceptance fixture for nestly_v674 — demographic revenue/frequency/ATV
-- (public.get_ci_demographics_v1) and the flagship cohort-vs-baseline question
-- (public.get_ci_demographic_cohort_v1). Named for v674 because both RPCs are new above the
-- v422 baseline watermark: every assertion below is `n/a` in the baseline phase and gated
-- entirely on the migrated run (`--migrated-only`). See docs/qa/CI-CORPUS-FIXTURE-GUIDE.md for
-- the harness, the impersonation recipe, and the write-guard GUC table this fixture follows for
-- public.customer_profiles / public.customer_links.
--
-- Three independent groups of clients feed two DISJOINT time windows so the R1 (aggregates) and
-- R2 (flagship cohort) fixtures cannot contaminate each other even though they share one
-- business: R1's window is [today-30, today-20]; R2's primary window is [today-120, today];
-- R2's second (insufficient-confidence) call uses [today-210, today-190]. No group's sale dates
-- fall inside a window it does not belong to (checked by hand below, per group).
--
-- A fourth block, 'DC', proves the access-boundary fix in design decision 8: an assigned
-- consultant with no staff row on the fixture business must be SERVED by
-- get_ci_demographics_v1 (same cell as the super admin), while a plain, unrelated firm's owner
-- must still be REFUSED — reusing R1's business, window and truth table so "served" means
-- "served the SAME correct numbers," not merely "did not raise."
--
-- ===========================================================================================
-- TRUTH TABLE — R1 (public.get_ci_demographics_v1), window [today-30, today-20]
-- ===========================================================================================
--   Cell (25_30, female): 5 customers (R1-F1..F5). Four revenue sales (10000+20000+30000+15000
--     = 75000 cents) + one $0-revenue visit-only sale (counts_as_visit, not counts_as_revenue).
--     customers=5, revenue_cents=75000, visits=5, revenue_txns=4 -> atv_cents=75000/4=18750
--     exactly. 5 >= the k=5 evidence floor -> evidence.status='ok', atv is a real number.
--   Cell (31_40, male): 2 customers (R1-M1, R1-M2), revenue 8000+4000=12000, visits=2.
--     2 < 5 -> evidence.status='insufficient': customers/revenue_cents/visits are KEPT,
--     atv_cents is NULLED. This is the load-bearing assertion for the floor rule.
--   Unclassified: 2 customers (R1-U1, R1-U2; no birth_date, no gender), revenue 5000+7000=12000.
--   Synthetic (R1-Synthetic, is_synthetic=true, a 999999-cent sale in the same window and cell
--     as the F group): must be invisible everywhere — negative control for the F cell staying
--     at exactly 5/75000, not 6/1074999.
--   active_customers = 5+2+2 = 9. active_revenue_cents = 75000+12000+12000 = 99000.
--   resolved_customers = 5+2 = 7. resolved_revenue_cents = 75000+12000 = 87000.
--   coverage.demographics = 7/9 = 77.8%. coverage.revenue = 87000/99000 = 87.9%.
--
-- ===========================================================================================
-- TRUTH TABLE — DC (public.get_ci_demographics_v1, access boundary)
-- ===========================================================================================
--   An assigned consultant (platform_consultants + sme_prospects.converted_business_id = biz,
--   no staff row on biz) calls get_ci_demographics_v1(biz, ...) and must be SERVED: the SAME
--   (25_30,female) cell the super admin got (5 customers / 75000 revenue_cents / 5 visits /
--   18750 atv_cents / evidence.status='ok'). This is v667's P0-1 lesson re-proven against a new
--   reader — the reader classifies via the gate-free app.customer_demographics_core_v674, not
--   the merchant-only-gated public app.customer_demographics_v1, so the consultant is not
--   turned away on the very first LATERAL call after clearing the outer gate.
--   A second, unrelated firm's owner (firm B, no relationship to biz) calling the same RPC for
--   biz must still be REFUSED with 42501 — the tenant boundary itself is unweakened by the fix.
--
-- ===========================================================================================
-- TRUTH TABLE — R2 (public.get_ci_demographic_cohort_v1), primary call
-- ===========================================================================================
--   Cohort: female, age 25-30, node A, window [today-120, today], return_window_days=60.
--   6 women bought node A 90 days ago (mature: 90 >= 60): W1..W6. W1's STAFF-entered
--   birth_date says 45yo (would be OUT of the 25-30 band) but her VERIFIED wallet attestation
--   says 27yo (IN band) — proves v638's wallet-wins precedence flows through purchase-date
--   banding, because a broken precedence would silently drop her from the cohort and shift
--   every count below by one. 4 of the 6 (W1-W4) return within 60 days; W5, W6 do not.
--   1 more woman (W7) bought node A only 10 days ago: IMMATURE (10 < 60) — she IS one of the
--   "customers" but is excluded from the denominator.
--   -> customers=7, denominator=6, numerator=4, pct=4/6=66.7%, observations=7 (one purchase
--      each, all 7 within the period).
--   Baseline (ALL resolved, mature node-A purchasers, any gender/age): the 6 women + 4 men
--   (M1..M4, resolved, mature, node A 90 days ago; M1 returns, M2-M4 do not) = denom=10,
--   numer=4+1=5, pct=50.0%. difference = 66.7 - 50.0 = 16.7pp.
--   Coverage: the SAME mature node-A population widened to include 2 no-demographics
--   customers (ND1, ND2) = 6+4+2=12 identified, 6+4=10 resolved -> 10/12 = 83.3%.
--   A synthetic client (Synthetic-2, is_synthetic=true) and a decoy client (Decoy, same
--   demographic as the cohort but her purchase is mapped to node B, not node A) both exist in
--   the same window and would inflate customers to 8/9 if either exclusion were broken.
--   confidence: n=6, floor=5, status='ok' -> pct and difference are real numbers, not withheld.
--
-- ===========================================================================================
-- TRUTH TABLE — R2, second call: confidence insufficiency
-- ===========================================================================================
--   3 men aged ~50 (X1, X2, X3) bought node A 200 days ago, in an isolated window
--   [today-210, today-190] that no other group's sales touch. X1 returns within 60 days;
--   X2, X3 do not. denominator=3 < floor 5 -> confidence.status='insufficient': customers,
--   denominator and numerator stay visible (3, 3, 1) but pct and difference are NULL and
--   withheld_reason explains why.
\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v674$
declare
  biz         uuid := '00000000-0000-4000-8000-000000674001';
  u_sa        uuid := '00000000-0000-4000-8000-000000674002';
  u_owner     uuid := '00000000-0000-4000-8000-000000674003';
  u_wallet    uuid := '00000000-0000-4000-8000-000000674004';
  identity_id uuid := '00000000-0000-4000-8000-000000674005';
  link_id     uuid := '00000000-0000-4000-8000-000000674006';
  -- DC: an assigned consultant entitled to read `biz`, and a second firm whose owner is not.
  u_cons      uuid := '00000000-0000-4000-8000-000000674007';
  u_owner_b   uuid := '00000000-0000-4000-8000-000000674008';
  cons_id     uuid := '00000000-0000-4000-8000-000000674009';
  co_id       uuid := '00000000-0000-4000-8000-00000067400a';
  biz_b       uuid := '00000000-0000-4000-8000-00000067400b';

  svc_a uuid := '00000000-0000-4000-8000-000000674010';
  svc_b uuid := '00000000-0000-4000-8000-000000674011';
  node_a text;
  node_b text;

  -- R2 primary cohort: mature women
  w1 uuid := '00000000-0000-4000-8000-000000674101'; -- wallet-precedence
  w2 uuid := '00000000-0000-4000-8000-000000674102';
  w3 uuid := '00000000-0000-4000-8000-000000674103';
  w4 uuid := '00000000-0000-4000-8000-000000674104';
  w5 uuid := '00000000-0000-4000-8000-000000674105';
  w6 uuid := '00000000-0000-4000-8000-000000674106';
  w7 uuid := '00000000-0000-4000-8000-000000674107'; -- immature
  -- R2 baseline-only: mature men
  m1 uuid := '00000000-0000-4000-8000-000000674111';
  m2 uuid := '00000000-0000-4000-8000-000000674112';
  m3 uuid := '00000000-0000-4000-8000-000000674113';
  m4 uuid := '00000000-0000-4000-8000-000000674114';
  -- R2 coverage-only: no demographics
  nd1 uuid := '00000000-0000-4000-8000-000000674121';
  nd2 uuid := '00000000-0000-4000-8000-000000674122';
  -- R2 negative controls
  syn1    uuid := '00000000-0000-4000-8000-000000674123'; -- is_synthetic
  decoy1  uuid := '00000000-0000-4000-8000-000000674124'; -- node B, not node A
  -- R2 second call: isolated tiny cohort
  x1 uuid := '00000000-0000-4000-8000-000000674131';
  x2 uuid := '00000000-0000-4000-8000-000000674132';
  x3 uuid := '00000000-0000-4000-8000-000000674133';

  -- R1 clients
  r1_f1 uuid := '00000000-0000-4000-8000-000000674201';
  r1_f2 uuid := '00000000-0000-4000-8000-000000674202';
  r1_f3 uuid := '00000000-0000-4000-8000-000000674203';
  r1_f4 uuid := '00000000-0000-4000-8000-000000674204';
  r1_f5 uuid := '00000000-0000-4000-8000-000000674205';
  r1_u1 uuid := '00000000-0000-4000-8000-000000674206';
  r1_u2 uuid := '00000000-0000-4000-8000-000000674207';
  r1_m1 uuid := '00000000-0000-4000-8000-000000674208';
  r1_m2 uuid := '00000000-0000-4000-8000-000000674209';
  r1_syn uuid := '00000000-0000-4000-8000-00000067420a';

  d1_from date := current_date - 30;
  d1_to   date := current_date - 20;
  d1_sale date := current_date - 25;

  d2_from date := current_date - 120;
  d2_to   date := current_date;
  d2_anchor_mature   date := current_date - 90;
  d2_anchor_immature date := current_date - 10;
  d2_return          date := current_date - 60;

  d3_from date := current_date - 210;
  d3_to   date := current_date - 190;
  d3_anchor date := current_date - 200;
  d3_return date := current_date - 170;

  g1 jsonb; g2 jsonb; g3 jsonb; v_cell jsonb;
  v_err text;
begin
  ---------------------------------------------------------------------------
  -- actors: a Google-SSO super admin (v625) — the caller v638 was built to serve.
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_sa, 'zz-v674-sa@example.test'),
    (u_owner, 'zz-v674-owner@example.test'),
    (u_wallet, 'zz-v674-wallet@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (u_sa, 'zz-v674-sa@example.test') on conflict do nothing;

  ---------------------------------------------------------------------------
  -- an operational business (CI-CORPUS-FIXTURE-GUIDE.md recipe)
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v674 demographic fixture', 'zz-v674-demo',
      array['dashboard','clients','sales','reports','customerintel']);
  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
    values (biz, u_owner, 'owner', 'ZZ v674 owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v674 fixture')
    on conflict (business_id) do update
      set approval_status = 'approved', decided_at = now(), decision_reason = 'v674 fixture';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state = 'current', workspace_paused = false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status = 'active', payment_status = 'paid', current_period_end = now() + interval '30 days';

  ---------------------------------------------------------------------------
  -- DC actors: an assigned consultant entitled to read `biz` via the PLATFORM arm only (no
  -- staff row), and a second firm whose owner has no relationship to `biz` at all. Seeding
  -- idiom lifted from db/tests/executed/v667_ci_access_boundaries.sql (platform_consultants +
  -- sme_companies + sme_prospects; the ownership-shape check demands ownership_state='owned'
  -- with a consultant and a NULL queue_key, and the conversion-shape check demands all three
  -- converted_* fields together or none).
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_cons, 'zz-v674-cons@example.test'),
    (u_owner_b, 'zz-v674-ownerb@example.test')
    on conflict (id) do nothing;

  insert into public.platform_consultants (id, user_id, display_name, tier, employment_started_on, active)
    values (cons_id, u_cons, 'ZZ v674 consultant', 'senior', current_date - 400, true);
  insert into public.sme_companies (id, legal_name, trading_name)
    values (co_id, 'ZZ v674 Firm A Pte Ltd', 'ZZ v674 Firm A');
  insert into public.sme_prospects (company_id, legacy_stage_raw, assigned_consultant_id,
                                     ownership_state, queue_key,
                                     converted_business_id, converted_at, converted_by)
    values (co_id, 'zz-v674-fixture', cons_id, 'owned', null, biz, clock_timestamp(), u_sa);

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz_b, 'ZZ v674 firm B', 'zz-v674-b', array['dashboard','clients','sales','reports']);
  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
    values (biz_b, u_owner_b, 'owner', 'ZZ v674 owner B', true, 'approved');

  ---------------------------------------------------------------------------
  -- catalogue: two level-2 nodes (v667's fixture pattern) — node A carries every real
  -- purchase below, node B exists only for the decoy client so category filtering is
  -- provably not a no-op.
  ---------------------------------------------------------------------------
  select n.node_key into node_a from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 order by n.node_key limit 1;
  select n.node_key into node_b from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 and n.node_key <> node_a order by n.node_key limit 1;
  if node_a is null or node_b is null then
    insert into _fail values ('R0', 'taxonomy v1 has fewer than two level-2 nodes; fixture cannot run');
    return;
  end if;

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_a, biz, 'ZZ v674 node-A service', 5000, 45),
    (svc_b, biz, 'ZZ v674 node-B service', 5000, 45);
  insert into public.service_canonical_map
    (business_id, service_id, node_key, version_no, method, mapped_by) values
    (biz, svc_a, node_a, 1, 'owner_chosen', u_owner),
    (biz, svc_b, node_b, 1, 'owner_chosen', u_owner);

  ---------------------------------------------------------------------------
  -- clients
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name, birth_date, gender) values
    (w1, biz, 'ZZ v674 W1 wallet-precedence', current_date - interval '45 years', 'female'),
    (w2, biz, 'ZZ v674 W2', current_date - interval '27 years', 'female'),
    (w3, biz, 'ZZ v674 W3', current_date - interval '27 years', 'female'),
    (w4, biz, 'ZZ v674 W4', current_date - interval '27 years', 'female'),
    (w5, biz, 'ZZ v674 W5', current_date - interval '27 years', 'female'),
    (w6, biz, 'ZZ v674 W6', current_date - interval '27 years', 'female'),
    (w7, biz, 'ZZ v674 W7 immature', current_date - interval '27 years', 'female'),
    (m1, biz, 'ZZ v674 M1', current_date - interval '40 years', 'male'),
    (m2, biz, 'ZZ v674 M2', current_date - interval '40 years', 'male'),
    (m3, biz, 'ZZ v674 M3', current_date - interval '40 years', 'male'),
    (m4, biz, 'ZZ v674 M4', current_date - interval '40 years', 'male'),
    (nd1, biz, 'ZZ v674 ND1', null, null),
    (nd2, biz, 'ZZ v674 ND2', null, null),
    (decoy1, biz, 'ZZ v674 Decoy', current_date - interval '27 years', 'female'),
    (x1, biz, 'ZZ v674 X1', current_date - interval '50 years', 'male'),
    (x2, biz, 'ZZ v674 X2', current_date - interval '50 years', 'male'),
    (x3, biz, 'ZZ v674 X3', current_date - interval '50 years', 'male'),
    (r1_f1, biz, 'ZZ v674 R1-F1', current_date - interval '27 years', 'female'),
    (r1_f2, biz, 'ZZ v674 R1-F2', current_date - interval '27 years', 'female'),
    (r1_f3, biz, 'ZZ v674 R1-F3', current_date - interval '27 years', 'female'),
    (r1_f4, biz, 'ZZ v674 R1-F4', current_date - interval '27 years', 'female'),
    (r1_f5, biz, 'ZZ v674 R1-F5', current_date - interval '27 years', 'female'),
    (r1_u1, biz, 'ZZ v674 R1-U1', null, null),
    (r1_u2, biz, 'ZZ v674 R1-U2', null, null),
    (r1_m1, biz, 'ZZ v674 R1-M1', current_date - interval '35 years', 'male'),
    (r1_m2, biz, 'ZZ v674 R1-M2', current_date - interval '35 years', 'male');

  insert into public.clients (id, business_id, full_name, birth_date, gender, is_synthetic) values
    (syn1, biz, 'ZZ v674 Synthetic', current_date - interval '27 years', 'female', true),
    (r1_syn, biz, 'ZZ v674 R1-Synthetic', current_date - interval '27 years', 'female', true);

  -- W1's verified wallet attestation: 27yo, contradicting her staff-entered 45yo.
  insert into public.customer_identities (id, auth_user_id) values (identity_id, u_wallet);
  perform set_config('app.c42_profile_identity', identity_id::text, true);
  insert into public.customer_profiles (identity_id, auth_user_id, full_name, birth_date, gender)
    values (identity_id, u_wallet, 'ZZ v674 W1 wallet identity',
            current_date - interval '27 years', 'female');
  perform set_config('app.c42_profile_identity', '', true);
  perform set_config('app.customer_link_insert_id', link_id::text, true);
  insert into public.customer_links
    (id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at)
    values (link_id, biz, identity_id, u_wallet, w1, 'verified', 'email_claim', now());
  perform set_config('app.customer_link_insert_id', '', true);

  ---------------------------------------------------------------------------
  -- R2 anchor purchases (node A): 90-day-old cohort + baseline population + coverage-only
  ---------------------------------------------------------------------------
  with ins as (
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at,
                               counts_as_revenue, counts_as_visit)
    select gen_random_uuid(), biz, cid, 'service', 5000,
           d2_anchor_mature::timestamp at time zone 'Asia/Singapore', true, true
      from unnest(array[w1,w2,w3,w4,w5,w6,m1,m2,m3,m4,nd1,nd2,syn1]) as cid
    returning id, business_id
  )
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select business_id, id, 'service', svc_a, 1, 5000, 5000 from ins;

  -- W7: same category, only 10 days ago -> immature.
  with ins as (
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at,
                               counts_as_revenue, counts_as_visit)
    values (gen_random_uuid(), biz, w7, 'service', 5000,
            d2_anchor_immature::timestamp at time zone 'Asia/Singapore', true, true)
    returning id, business_id
  )
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select business_id, id, 'service', svc_a, 1, 5000, 5000 from ins;

  -- Decoy: same window, same demographic, but node B — must never enter the node-A cohort.
  with ins as (
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at,
                               counts_as_revenue, counts_as_visit)
    values (gen_random_uuid(), biz, decoy1, 'service', 5000,
            d2_anchor_mature::timestamp at time zone 'Asia/Singapore', true, true)
    returning id, business_id
  )
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select business_id, id, 'service', svc_b, 1, 5000, 5000 from ins;

  -- Return visits within the 60-day window (any category — "another qualifying visit").
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at,
                             counts_as_revenue, counts_as_visit)
  select gen_random_uuid(), biz, cid, 'service', 3000,
         d2_return::timestamp at time zone 'Asia/Singapore', true, true
    from unnest(array[w1,w2,w3,w4,m1,syn1]) as cid;

  ---------------------------------------------------------------------------
  -- R2 second call: an isolated 3-person cohort 200 days ago, window [-210,-190]
  ---------------------------------------------------------------------------
  with ins as (
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at,
                               counts_as_revenue, counts_as_visit)
    select gen_random_uuid(), biz, cid, 'service', 5000,
           d3_anchor::timestamp at time zone 'Asia/Singapore', true, true
      from unnest(array[x1,x2,x3]) as cid
    returning id, business_id
  )
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select business_id, id, 'service', svc_a, 1, 5000, 5000 from ins;

  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at,
                             counts_as_revenue, counts_as_visit)
  values (gen_random_uuid(), biz, x1, 'service', 3000,
          d3_return::timestamp at time zone 'Asia/Singapore', true, true);

  ---------------------------------------------------------------------------
  -- R1 sales: window [today-30, today-20], no sale_items (no category filter in R1).
  --
  -- app.on_sale_policy_snapshot() (v10.1/v20) is a BEFORE INSERT trigger that OVERWRITES
  -- new.counts_as_revenue/new.counts_as_visit from app.sale_policy(business_id, kind) —
  -- whatever the INSERT statement supplies for those two columns is discarded. 'service'
  -- defaults to (revenue=true, visit=true), which is what every other sale in this fixture
  -- wants. R1-F5 needs a real (revenue=false, visit=true) row to prove ATV divides by
  -- REVENUE transactions, not visits — that needs its own kind with a business-level policy
  -- override, not a per-row flag. 'quick_sale' is otherwise unused in this fixture.
  ---------------------------------------------------------------------------
  insert into public.sale_policies (business_id, kind, counts_as_revenue, counts_as_visit, earns_points)
  values (biz, 'quick_sale', false, true, false);

  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at,
                             counts_as_revenue, counts_as_visit)
  values
    (gen_random_uuid(), biz, r1_f1, 'service', 10000, d1_sale::timestamp at time zone 'Asia/Singapore', true, true),
    (gen_random_uuid(), biz, r1_f2, 'service', 20000, d1_sale::timestamp at time zone 'Asia/Singapore', true, true),
    (gen_random_uuid(), biz, r1_f3, 'service', 30000, d1_sale::timestamp at time zone 'Asia/Singapore', true, true),
    (gen_random_uuid(), biz, r1_f4, 'service', 15000, d1_sale::timestamp at time zone 'Asia/Singapore', true, true),
    (gen_random_uuid(), biz, r1_f5, 'quick_sale', 5000,  d1_sale::timestamp at time zone 'Asia/Singapore', false, true),
    (gen_random_uuid(), biz, r1_u1, 'service', 5000,  d1_sale::timestamp at time zone 'Asia/Singapore', true, true),
    (gen_random_uuid(), biz, r1_u2, 'service', 7000,  d1_sale::timestamp at time zone 'Asia/Singapore', true, true),
    (gen_random_uuid(), biz, r1_m1, 'service', 8000,  d1_sale::timestamp at time zone 'Asia/Singapore', true, true),
    (gen_random_uuid(), biz, r1_m2, 'service', 4000,  d1_sale::timestamp at time zone 'Asia/Singapore', true, true),
    (gen_random_uuid(), biz, r1_syn,'service', 999999,d1_sale::timestamp at time zone 'Asia/Singapore', true, true);

  ---------------------------------------------------------------------------
  -- impersonate the entitled caller: super admin via Google SSO (v625 claim shape)
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method', 'oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  ---------------------------------------------------------------------------
  -- R1 — public.get_ci_demographics_v1
  ---------------------------------------------------------------------------
  begin
    g1 := public.get_ci_demographics_v1(biz, d1_from, d1_to);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('R1-pre', format('super admin refused on get_ci_demographics_v1 (%s)', v_err));
    g1 := null;
  end;

  if g1 is null then
    insert into _fail values ('R1-pre', 'get_ci_demographics_v1 returned no payload');
  else
    v_cell := null;
    select rec into v_cell from jsonb_array_elements(g1->'cells') rec
     where rec->>'age_band' = '25_30' and rec->>'gender' = 'female';
    if v_cell is null then
      insert into _fail values ('R1-cellF', 'no (25_30,female) cell in the payload');
    else
      if (v_cell->>'customers')::int <> 5 then
        insert into _fail values ('R1-cellF-customers', format('got %s expected 5', v_cell->>'customers'));
      end if;
      if (v_cell->>'revenue_cents')::bigint <> 75000 then
        insert into _fail values ('R1-cellF-revenue', format('got %s expected 75000', v_cell->>'revenue_cents'));
      end if;
      if (v_cell->>'visits')::int <> 5 then
        insert into _fail values ('R1-cellF-visits', format('got %s expected 5', v_cell->>'visits'));
      end if;
      if (v_cell->>'atv_cents')::bigint <> 18750 then
        insert into _fail values ('R1-cellF-atv',
          format('got %s expected 18750', coalesce(v_cell->>'atv_cents', '<null>')));
      end if;
      if v_cell->'evidence'->>'status' <> 'ok' then
        insert into _fail values ('R1-cellF-evidence', format('got %s expected ok', v_cell->'evidence'->>'status'));
      end if;
    end if;

    v_cell := null;
    select rec into v_cell from jsonb_array_elements(g1->'cells') rec
     where rec->>'age_band' = '31_40' and rec->>'gender' = 'male';
    if v_cell is null then
      insert into _fail values ('R1-cellM', 'no (31_40,male) cell in the payload');
    else
      if (v_cell->>'customers')::int <> 2 then
        insert into _fail values ('R1-cellM-customers', format('got %s expected 2', v_cell->>'customers'));
      end if;
      if (v_cell->>'revenue_cents')::bigint <> 12000 then
        insert into _fail values ('R1-cellM-revenue', format('got %s expected 12000', v_cell->>'revenue_cents'));
      end if;
      if (v_cell->>'visits')::int <> 2 then
        insert into _fail values ('R1-cellM-visits', format('got %s expected 2', v_cell->>'visits'));
      end if;
      if v_cell->>'atv_cents' is not null then
        insert into _fail values ('R1-cellM-atv',
          format('atv=%s expected null (below the k=5 floor)', v_cell->>'atv_cents'));
      end if;
      if v_cell->'evidence'->>'status' <> 'insufficient' then
        insert into _fail values ('R1-cellM-evidence',
          format('got %s expected insufficient', v_cell->'evidence'->>'status'));
      end if;
    end if;

    if jsonb_array_length(coalesce(g1->'cells', '[]'::jsonb)) <> 2 then
      insert into _fail values ('R1-cellcount',
        format('%s cells, expected exactly 2 — the synthetic negative control leaked if higher',
               jsonb_array_length(coalesce(g1->'cells', '[]'::jsonb))));
    end if;

    if (g1->'unclassified'->>'customers')::int <> 2 then
      insert into _fail values ('R1-unclass-customers', format('got %s expected 2', g1->'unclassified'->>'customers'));
    end if;
    if (g1->'unclassified'->>'revenue_cents')::bigint <> 12000 then
      insert into _fail values ('R1-unclass-revenue', format('got %s expected 12000', g1->'unclassified'->>'revenue_cents'));
    end if;

    if (g1->'coverage'->'demographics'->>'numerator')::int <> 7
       or (g1->'coverage'->'demographics'->>'denominator')::int <> 9
       or (g1->'coverage'->'demographics'->>'pct')::numeric <> 77.8 then
      insert into _fail values ('R1-coverage-demo', format('got %s', g1->'coverage'->'demographics'));
    end if;
    if (g1->'coverage'->'revenue'->>'numerator')::bigint <> 87000
       or (g1->'coverage'->'revenue'->>'denominator')::bigint <> 99000
       or (g1->'coverage'->'revenue'->>'pct')::numeric <> 87.9 then
      insert into _fail values ('R1-coverage-rev', format('got %s', g1->'coverage'->'revenue'));
    end if;

    if g1->>'time_basis' <> 'sale_occurred_at' then
      insert into _fail values ('R1-time-basis', format('got %s', g1->>'time_basis'));
    end if;
    if g1->>'observed_since' is null then
      insert into _fail values ('R1-observed-since', 'missing');
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- DC — get_ci_demographics_v1 must SERVE the assigned consultant (v667's P0-1 fix exists
  -- precisely so this caller is not refused) and still REFUSE an unrelated firm's owner. The
  -- reader now classifies via app.customer_demographics_core_v674 (gate-free) instead of the
  -- public app.customer_demographics_v1 (merchant-only gate); this proves that repointing
  -- actually opened the surface, not merely that the outer gate admits the consultant.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_cons, 'role', 'authenticated')::text, true);

  -- PRECONDITION: the consultant genuinely holds no staff row on `biz` and is genuinely
  -- entitled only via the platform arm — otherwise a served result below would prove nothing.
  if app.is_salon_member(biz) then
    insert into _fail values ('DC-pre', 'the consultant is a staff member of biz; DC would be vacuous');
  end if;
  if not app.v176_can_read_firm_report(biz) then
    insert into _fail values ('DC-pre', 'the consultant is not entitled via the platform arm; DC would be vacuous');
  end if;

  begin
    g1 := public.get_ci_demographics_v1(biz, d1_from, d1_to);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('DC-served',
      format('the assigned consultant was refused (%s); v667''s P0-1 fix exists precisely so this caller is served', v_err));
    g1 := null;
  end;

  if g1 is null then
    insert into _fail values ('DC-served', 'the assigned consultant got no payload');
  else
    v_cell := null;
    select rec into v_cell from jsonb_array_elements(g1->'cells') rec
     where rec->>'age_band' = '25_30' and rec->>'gender' = 'female';
    if v_cell is null then
      insert into _fail values ('DC-cellF', 'no (25_30,female) cell for the consultant caller');
    else
      -- SAME (25_30,female) cell values the super admin got — served, not refused, and not a
      -- degraded/partial payload either.
      if (v_cell->>'customers')::int <> 5 then
        insert into _fail values ('DC-cellF-customers',
          format('got %s expected 5 (must match the super admin''s figure)', v_cell->>'customers'));
      end if;
      if (v_cell->>'revenue_cents')::bigint <> 75000 then
        insert into _fail values ('DC-cellF-revenue', format('got %s expected 75000', v_cell->>'revenue_cents'));
      end if;
      if (v_cell->>'visits')::int <> 5 then
        insert into _fail values ('DC-cellF-visits', format('got %s expected 5', v_cell->>'visits'));
      end if;
      if (v_cell->>'atv_cents')::bigint <> 18750 then
        insert into _fail values ('DC-cellF-atv',
          format('got %s expected 18750', coalesce(v_cell->>'atv_cents', '<null>')));
      end if;
      if v_cell->'evidence'->>'status' <> 'ok' then
        insert into _fail values ('DC-cellF-evidence', format('got %s expected ok', v_cell->'evidence'->>'status'));
      end if;
    end if;
  end if;

  -- The tenant boundary itself is unweakened: a plain, unrelated firm's owner must still be
  -- refused reading `biz`'s intelligence (v667's B2 pattern, re-proven against this new reader).
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_b, 'role', 'authenticated')::text, true);

  if app.is_salon_member(biz) or app.v176_can_read_firm_report(biz) then
    insert into _fail values ('DC-neg-pre',
      'firm B''s owner is unexpectedly entitled to read biz; the negative half of DC would be vacuous');
  end if;

  begin
    g1 := public.get_ci_demographics_v1(biz, d1_from, d1_to);
    insert into _fail values ('DC-refused', 'an unrelated firm''s owner read biz''s demographic intelligence');
  exception
    when insufficient_privilege then null; -- 42501, expected
    when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('DC-refused', format('refused with %s, expected 42501', v_err));
  end;

  ---------------------------------------------------------------------------
  -- R2 — public.get_ci_demographic_cohort_v1, the flagship primary call
  ---------------------------------------------------------------------------
  -- restore the entitled caller: super admin via Google SSO (v625 claim shape) — the DC block
  -- above impersonated the consultant and then firm B's owner in turn.
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method', 'oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  begin
    g2 := public.get_ci_demographic_cohort_v1(biz, 'female', 25, 30, node_a, d2_from, d2_to, 60, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('R2-pre', format('super admin refused on get_ci_demographic_cohort_v1 (%s)', v_err));
    g2 := null;
  end;

  if g2 is null then
    insert into _fail values ('R2-pre', 'get_ci_demographic_cohort_v1 returned no payload');
  else
    -- field 1: cohort
    if g2->'cohort'->>'gender' <> 'female' then
      insert into _fail values ('R2-cohort-gender', coalesce(g2->'cohort'->>'gender', '<null>'));
    end if;
    if (g2->'cohort'->>'age_from')::int <> 25 then
      insert into _fail values ('R2-cohort-age-from', g2->'cohort'->>'age_from');
    end if;
    if (g2->'cohort'->>'age_to')::int <> 30 then
      insert into _fail values ('R2-cohort-age-to', g2->'cohort'->>'age_to');
    end if;
    if g2->'cohort'->>'node_key' <> node_a then
      insert into _fail values ('R2-cohort-node', coalesce(g2->'cohort'->>'node_key', '<null>'));
    end if;
    if coalesce(g2->'cohort'->>'sentence', '') = '' then
      insert into _fail values ('R2-cohort-sentence', 'empty');
    end if;

    -- field 2: window
    if (g2->'window'->>'return_window_days')::int <> 60 then
      insert into _fail values ('R2-window-days', g2->'window'->>'return_window_days');
    end if;
    if coalesce(g2->'window'->>'maturity_rule', '') = '' then
      insert into _fail values ('R2-window-rule', 'empty');
    end if;

    -- fields 3-6: numerator, denominator, customers, observations
    if (g2->>'numerator')::int <> 4 then
      insert into _fail values ('R2-numerator', format('got %s expected 4', g2->>'numerator'));
    end if;
    if (g2->>'denominator')::int <> 6 then
      insert into _fail values ('R2-denominator', format('got %s expected 6', g2->>'denominator'));
    end if;
    if (g2->>'customers')::int <> 7 then
      insert into _fail values ('R2-customers', format('got %s expected 7', g2->>'customers'));
    end if;
    if (g2->>'observations')::int <> 7 then
      insert into _fail values ('R2-observations', format('got %s expected 7', g2->>'observations'));
    end if;

    -- field 7: baseline
    if (g2->'baseline'->>'numerator')::int <> 5 then
      insert into _fail values ('R2-baseline-num', g2->'baseline'->>'numerator');
    end if;
    if (g2->'baseline'->>'denominator')::int <> 10 then
      insert into _fail values ('R2-baseline-den', g2->'baseline'->>'denominator');
    end if;
    if (g2->'baseline'->>'pct')::numeric <> 50.0 then
      insert into _fail values ('R2-baseline-pct', g2->'baseline'->>'pct');
    end if;

    -- companion: the cohort's own pct
    if (g2->>'pct')::numeric <> 66.7 then
      insert into _fail values ('R2-pct', format('got %s expected 66.7', g2->>'pct'));
    end if;

    -- field 8: difference
    if (g2->>'difference')::numeric <> 16.7 then
      insert into _fail values ('R2-difference', format('got %s expected 16.7', g2->>'difference'));
    end if;

    -- field 9: period
    if (g2->'period'->>'from')::date <> d2_from then
      insert into _fail values ('R2-period-from', g2->'period'->>'from');
    end if;
    if (g2->'period'->>'to')::date <> d2_to then
      insert into _fail values ('R2-period-to', g2->'period'->>'to');
    end if;
    if g2->'period'->>'time_basis' <> 'sale_occurred_at' then
      insert into _fail values ('R2-period-basis', coalesce(g2->'period'->>'time_basis', '<null>'));
    end if;

    -- field 10: coverage
    if (g2->'coverage'->>'numerator')::int <> 10 then
      insert into _fail values ('R2-coverage-num', g2->'coverage'->>'numerator');
    end if;
    if (g2->'coverage'->>'denominator')::int <> 12 then
      insert into _fail values ('R2-coverage-den', g2->'coverage'->>'denominator');
    end if;
    if (g2->'coverage'->>'pct')::numeric <> 83.3 then
      insert into _fail values ('R2-coverage-pct', g2->'coverage'->>'pct');
    end if;

    if g2->>'age_basis' <> 'purchase_date' then
      insert into _fail values ('R2-age-basis', coalesce(g2->>'age_basis', '<null>'));
    end if;

    -- field 11: confidence
    if (g2->'confidence'->>'n')::int <> 6 then
      insert into _fail values ('R2-confidence-n', g2->'confidence'->>'n');
    end if;
    if (g2->'confidence'->>'floor')::int <> 5 then
      insert into _fail values ('R2-confidence-floor', g2->'confidence'->>'floor');
    end if;
    if g2->'confidence'->>'status' <> 'ok' then
      insert into _fail values ('R2-confidence-status', coalesce(g2->'confidence'->>'status', '<null>'));
    end if;
    if g2->>'withheld_reason' is not null then
      insert into _fail values ('R2-withheld-reason', format('expected null, got %s', g2->>'withheld_reason'));
    end if;
    if g2->>'observed_since' is null then
      insert into _fail values ('R2-observed-since', 'missing');
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- R2 — second call: 3-person cohort, confidence insufficiency
  ---------------------------------------------------------------------------
  begin
    g3 := public.get_ci_demographic_cohort_v1(biz, 'male', 45, 55, node_a, d3_from, d3_to, 60, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('R2b-pre', format('super admin refused on the insufficient-cohort call (%s)', v_err));
    g3 := null;
  end;

  if g3 is null then
    insert into _fail values ('R2b-pre', 'get_ci_demographic_cohort_v1 returned no payload');
  else
    if (g3->>'customers')::int <> 3 then
      insert into _fail values ('R2b-customers', format('got %s expected 3', g3->>'customers'));
    end if;
    if (g3->>'denominator')::int <> 3 then
      insert into _fail values ('R2b-denominator', format('got %s expected 3', g3->>'denominator'));
    end if;
    if (g3->>'numerator')::int <> 1 then
      insert into _fail values ('R2b-numerator', format('got %s expected 1', g3->>'numerator'));
    end if;
    if g3->'confidence'->>'status' <> 'insufficient' then
      insert into _fail values ('R2b-status', coalesce(g3->'confidence'->>'status', '<null>'));
    end if;
    if (g3->'confidence'->>'n')::int <> 3 then
      insert into _fail values ('R2b-conf-n', g3->'confidence'->>'n');
    end if;
    if (g3->'confidence'->>'floor')::int <> 5 then
      insert into _fail values ('R2b-conf-floor', g3->'confidence'->>'floor');
    end if;
    if g3->>'pct' is not null then
      insert into _fail values ('R2b-pct', format('expected null, got %s', g3->>'pct'));
    end if;
    if g3->>'difference' is not null then
      insert into _fail values ('R2b-difference', format('expected null, got %s', g3->>'difference'));
    end if;
    if coalesce(g3->>'withheld_reason', '') = '' then
      insert into _fail values ('R2b-withheld-reason', 'expected a non-empty explanation');
    end if;
    if (g3->'baseline'->>'denominator')::int <> 3 then
      insert into _fail values ('R2b-baseline-den', g3->'baseline'->>'denominator');
    end if;
    if (g3->'baseline'->>'numerator')::int <> 1 then
      insert into _fail values ('R2b-baseline-num', g3->'baseline'->>'numerator');
    end if;
  end if;

  perform set_config('request.jwt.claims', null, true);
end
$v674$;

select case when count(*) = 0
            then 'PASS — v674 demographic grid + flagship cohort question hold exactly'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v674: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
