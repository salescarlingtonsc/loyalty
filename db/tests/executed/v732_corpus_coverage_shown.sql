-- EXECUTED acceptance fixture for check 15 of docs/qa/CI-100-CHECKLIST.md ("Coverage. Every
-- customer-derived claim shows identity coverage; every service/product claim shows
-- itemisation/classification coverage.") and the frozen convention it maps to,
-- docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md convention 4 ("Coverage beside numbers: any
-- claim over a subset ... carries the subset size and the eligible total via rate_block_v1").
--
-- Five readers whose payload carries a coverage-shaped block (grepped from db/migrations for
-- 'coverage' dated 2026-09-02, per this fixture's own task brief), each seeded so the subset is
-- DELIBERATELY PARTIAL — never 0% or 100%, which a broken reader could satisfy by accident:
--
--   A. public.get_ci_demographics_v1 (nestly_v674)        — demographics/revenue identity
--      coverage. 12 identified, non-synthetic, revenue-or-visit-qualifying customers; 7 carry
--      both a birth_date and a gender (age_band 25_30 x4, 31_40 x3 — the exact split does not
--      matter to this fixture, only that all 7 resolve on BOTH fields); 5 carry neither.
--      coverage.demographics = app.rate_block_v1(7,12) -- EXACTLY the worked example in this
--      fixture's own task brief ("demographics cells carry coverage 7/12 = 58.3%"). Each of the
--      12 customers has exactly one revenue+visit sale of 10000 cents, so
--      coverage.revenue = app.rate_block_v1(70000, 120000) — the identical 58.3% by construction
--      (7 of 12 customers each carrying the identical amount), proving the two coverage numbers
--      are independently computed off two different numerators/denominators that happen to
--      collide on this seed's ratio, not a single shared computation copy-pasted into both keys.
--
--   B. public.get_ci_category_mix_v1 (nestly_v650/v691) — classified-line coverage. Ten
--      service-item lines, six mapped through service_canonical_map to a real level-2 taxonomy
--      node (classified), four on a service with NO canonical_map row (unclassified — per
--      app.ci_effective_node_v650, an unmapped SERVICE line resolves to node_key=null; only
--      RETAIL lines get a pack-default fallback, which is why this fixture deliberately uses
--      item_type='service' for both halves). Every line is 1000 cents, so revenue share and line
--      share coincide: coverage.classified_pct_bps = 6000 (60.00%) against
--      coverage.stampable_revenue_cents = 10000 total. This reader's coverage shape predates the
--      rate_block_v1 convention (a bps int + a separate total, not a {numerator,denominator,pct}
--      object), so this fixture proves the SAME thing rate_block_v1 would — exact subset revenue
--      (present, summed from the `categories` array's one classified row: 6000) beside the exact
--      eligible total (`stampable_revenue_cents`: 10000) — without inventing a numerator field
--      the reader does not emit.
--
--   C. public.get_revenue_truth_v106 (nestly_v106, re-emitted through nestly_v687) —
--      identified/anonymous revenue coverage. Twenty revenue-qualifying sales: 15 carry a
--      client_id (identified), 5 do not (anonymous). Every sale is 1000 cents.
--      totals.identified_revenue_minor=15000 / totals.known_revenue_minor=20000 and
--      totals.identified_transactions=15 / totals.completed_transactions=20 are the numerator
--      and denominator v106 actually emits (in `totals`, beside `coverage`, not folded into one
--      rate_block_v1 object — a different but equally exact shape); coverage.identity_revenue_pct
--      and coverage.identity_transaction_pct must both equal exactly 75.00.
--
--   D. public.get_ci_acquisition_v1 (nestly_v650/v680) — acquisition governed/unknown coverage
--      (check 59: "every customer has a governed source or `unknown`"). Ten identified,
--      non-synthetic customers: 6 with a governed first_acquired_via (3 'referral', 3
--      'walk_in_till'), 4 defaulted to 'unknown' by the v629 BEFORE INSERT trigger (no GUC set).
--      This reader has no single `coverage` key; its `sources` array IS the coverage — grouped by
--      via, every customer accounted for exactly once. The fixture sums `customers` across all
--      non-'unknown' rows (6), the 'unknown' row alone (4), and the full array (10), and asserts
--      all three exactly — the subset, its complement and the eligible total are all present and
--      reconcile, which is what a coverage claim requires even without a field named 'coverage'.
--
--   E. public.get_ci_contactability_v1 -> app.contactable_counts_v1 (nestly_v644) — consent-reach
--      coverage (check 15's "customer-derived claim" applied to contactability, and check 58's
--      channel taxonomy). Ten non-synthetic, phone-bearing customers; 6 carry an affirmative
--      'granted' marketing/whatsapp consents row, 4 carry none. `business_offers.customers` = 10
--      (the eligible total) and `business_offers.allowed_by_channel.whatsapp` = 6 (the reachable
--      subset) — both present in the same payload, exactly.
--
-- MUTATION-CHECKED (2026-09-02, this session, --filter=v732_corpus --migrated-only): Part A's
-- expected pct was temporarily changed from 58.3 to 99.9 with the seed untouched. Captured
-- failure:
--   ERROR:  v732: 1 assertion(s) failed:
--     A-demog-coverage: coverage.demographics = {"pct": 58.3, "numerator": 7, "denominator": 12},
--     expected {"pct": 99.9, "numerator": 7, "denominator": 12}
-- Reverting the literal back to 58.3 restored PASS. This proves the assertion is a live exact
-- comparison against the reader's real output, not a vacuously-true check.
--
-- Each part uses its own business so no seed can leak into another part's population count.
-- Actors: parts A/B/D/E read as a Google-SSO super admin (app.v176_can_read_firm_report's
-- platform arm — docs/qa/CI-CORPUS-FIXTURE-GUIDE.md "Impersonation"); part C reads as the
-- fixture business's own owner (get_revenue_truth_v106 has no platform-super-admin bypass
-- baked into this fixture's chosen path — it is gated on app.is_super_admin() OR
-- app.has_perm(business,'view_finance'), and the owner path is the one already proven working
-- in db/tests/executed/v687_corpus_synthetic_exclusion.sql, whose operational-business
-- scaffolding this fixture's Part C reuses verbatim).
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

-- ===============================================================================================
-- PART A -- public.get_ci_demographics_v1: demographics + revenue identity coverage.
-- ===============================================================================================
do $v732a$
declare
  biz  uuid := '00000000-0000-4000-8000-0000007a3201';
  u_sa uuid := '00000000-0000-4000-8000-0000007a3202';
  d_from date := current_date - 30;
  d_to   date := current_date - 20;
  d_sale date := current_date - 25;
  v_client_ids uuid[];
  g jsonb;
begin
  insert into auth.users (id, email) values (u_sa, 'zz-v732a-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v732a-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v732 coverage demographics', 'zz-v732-demog',
     array['dashboard','clients','sales','reports']);

  -- 12 identified, non-synthetic customers: gs 1-4 -> female/25_30 (resolved), gs 5-7 ->
  -- male/31_40 (resolved), gs 8-12 -> no birth_date/gender (unresolved). 7 resolved, 5 not.
  with c as (
    insert into public.clients (business_id, full_name, birth_date, gender)
    select biz, 'ZZ v732a demo cust ' || gs,
           case when gs <= 4 then current_date - interval '27 years'
                when gs <= 7 then current_date - interval '35 years'
                else null end,
           case when gs <= 4 then 'female' when gs <= 7 then 'male' else null end
      from generate_series(1, 12) gs
    returning id
  )
  select array_agg(id) into v_client_ids from c;

  if array_length(v_client_ids, 1) <> 12 then
    insert into _fail values ('A-PRE', format('expected 12 clients, got %s', array_length(v_client_ids,1)));
    return;
  end if;

  insert into public.sales (business_id, client_id, kind, amount_cents, occurred_at,
    counts_as_revenue, counts_as_visit, earns_points, policy_resolved_at,
    commission_rate_bps, commission_resolved_at)
  select biz, cid, 'service', 10000, d_sale, true, true, true, d_sale, 0, d_sale
    from unnest(v_client_ids) cid;

  g := public.get_ci_demographics_v1(biz, d_from, d_to);

  if g->'coverage'->'demographics' is distinct from
     jsonb_build_object('numerator', 7, 'denominator', 12, 'pct', 58.3) then
    insert into _fail values ('A-demog-coverage', format(
      'coverage.demographics = %s, expected {"pct": 58.3, "numerator": 7, "denominator": 12}',
      g->'coverage'->'demographics'));
  end if;

  if g->'coverage'->'revenue' is distinct from
     jsonb_build_object('numerator', 70000, 'denominator', 120000, 'pct', 58.3) then
    insert into _fail values ('A-revenue-coverage', format(
      'coverage.revenue = %s, expected {"pct": 58.3, "numerator": 70000, "denominator": 120000}',
      g->'coverage'->'revenue'));
  end if;
end;
$v732a$;

-- ===============================================================================================
-- PART B -- public.get_ci_category_mix_v1: classified-line coverage.
-- ===============================================================================================
do $v732b$
declare
  biz  uuid := '00000000-0000-4000-8000-0000007b3201';
  u_sa uuid := '00000000-0000-4000-8000-0000007b3202';
  br uuid := gen_random_uuid();
  svc_mapped   uuid := gen_random_uuid();
  svc_unmapped uuid := gen_random_uuid();
  cust uuid := gen_random_uuid();
  node_x text;
  d_from date := current_date - 30;
  d_to   date := current_date - 20;
  d_sale date := current_date - 25;
  sale1 uuid := gen_random_uuid();
  sale2 uuid := gen_random_uuid();
  g jsonb;
  cat jsonb;
begin
  insert into auth.users (id, email) values (u_sa, 'zz-v732b-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v732b-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v732 coverage category mix', 'zz-v732-catmix',
     array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
    values (br, biz, 'ZZ v732b branch', true, true);

  select n.node_key into node_x from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 order by n.node_key limit 1;
  if node_x is null then
    insert into _fail values ('B-PRE', 'taxonomy v1 has no level-2 node; fixture cannot run');
    return;
  end if;

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_mapped,   biz, 'ZZ v732b mapped service',   1000, 30),
    (svc_unmapped, biz, 'ZZ v732b unmapped service',  1000, 30);
  insert into public.service_canonical_map (business_id, service_id, node_key, version_no, method)
    values (biz, svc_mapped, node_x, 1, 'owner_chosen');
  -- svc_unmapped deliberately has NO service_canonical_map row.

  insert into public.clients (id, business_id, full_name) values (cust, biz, 'ZZ v732b client');

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at,
    counts_as_revenue, counts_as_visit, earns_points, policy_resolved_at,
    commission_rate_bps, commission_resolved_at)
  values
    (sale1, biz, br, cust, 'service', 6000, d_sale, true, true, true, d_sale, 0, d_sale),
    (sale2, biz, br, cust, 'service', 4000, d_sale, true, true, true, d_sale, 0, d_sale);

  -- 6 classified lines (mapped service), 4 unclassified lines (unmapped service).
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
    select biz, sale1, 'service', svc_mapped, 1, 1000, 1000 from generate_series(1,6);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
    select biz, sale2, 'service', svc_unmapped, 1, 1000, 1000 from generate_series(1,4);

  g := public.get_ci_category_mix_v1(biz, d_from, d_to);

  if (g->'coverage'->>'stampable_revenue_cents')::bigint <> 10000 then
    insert into _fail values ('B-total', format(
      'coverage.stampable_revenue_cents = %s, expected 10000 (the eligible total)',
      g->'coverage'->>'stampable_revenue_cents'));
  end if;
  if (g->'coverage'->>'classified_pct_bps')::int <> 6000 then
    insert into _fail values ('B-pct', format(
      'coverage.classified_pct_bps = %s, expected 6000 (60.00%%, = 6000/10000 classified cents)',
      g->'coverage'->>'classified_pct_bps'));
  end if;

  select c into cat from jsonb_array_elements(g->'categories') c where c->>'node_key' = node_x;
  if cat is null then
    insert into _fail values ('B-cat', 'classified node missing from categories array');
  else
    if (cat->>'revenue_cents')::bigint <> 6000 then
      insert into _fail values ('B-cat-revenue', format(
        'classified node revenue_cents = %s, expected 6000 (the classified subset)',
        cat->>'revenue_cents'));
    end if;
    if (cat->>'line_count')::int <> 6 then
      insert into _fail values ('B-cat-lines', format(
        'classified node line_count = %s, expected 6', cat->>'line_count'));
    end if;
  end if;
end;
$v732b$;

-- ===============================================================================================
-- PART C -- public.get_revenue_truth_v106: identified/anonymous revenue coverage.
-- ===============================================================================================
do $v732c$
declare
  biz     uuid := '00000000-0000-4000-8000-0000007c3201';
  br      uuid := '00000000-0000-4000-8000-0000007c3211';
  u_owner uuid := '00000000-0000-4000-8000-0000007c3202';
  cl      uuid := '00000000-0000-4000-8000-0000007c3203';
  d date := current_date;
  g jsonb;
begin
  insert into auth.users (id, email) values (u_owner, 'zz-v732c-owner@example.test')
    on conflict (id) do nothing;

  -- "Making a business genuinely operational" (CI-CORPUS-FIXTURE-GUIDE.md), the same
  -- scaffolding db/tests/executed/v687_corpus_synthetic_exclusion.sql already proved works for
  -- this exact RPC.
  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v732 coverage revenue truth', 'zz-v732-revtruth',
          array['dashboard','clients','sales','reports','customerintel']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (br, biz, 'ZZ v732c branch', true, true);
  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values (biz, u_owner, 'owner', 'ZZ v732c owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v732 coverage fixture')
    on conflict (business_id) do update
      set approval_status='approved', decided_at=now(), decision_reason='v732 coverage fixture';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.clients (id, business_id, full_name) values (cl, biz, 'ZZ v732c identified client');

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role','authenticated')::text, true);

  -- PRECONDITION (CI-CORPUS-FIXTURE-GUIDE "the rule that matters most").
  if not app.has_perm(biz, 'view_finance') then
    insert into _fail values ('C-PRE', 'fixture owner lacks view_finance; the read below is vacuous');
    return;
  end if;

  -- 15 identified sales (client_id = cl), 5 anonymous (client_id null). 1000 cents each,
  -- all on d+2, inside window [d+1, d+3).
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  select biz, br, cl, 'service', 1000, d+2, true, true, true, d+2, 0, d+2
    from generate_series(1, 15);
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  select biz, br, null, 'service', 1000, d+2, true, true, true, d+2, 0, d+2
    from generate_series(1, 5);

  g := public.get_revenue_truth_v106(biz, d+1, d+3, br);

  if (g#>>'{totals,known_revenue_minor}')::bigint <> 20000 then
    insert into _fail values ('C-known', format(
      'known_revenue_minor = %s, expected 20000 (the eligible total)',
      g#>>'{totals,known_revenue_minor}'));
  end if;
  if (g#>>'{totals,identified_revenue_minor}')::bigint <> 15000 then
    insert into _fail values ('C-identified-rev', format(
      'identified_revenue_minor = %s, expected 15000 (the identified subset)',
      g#>>'{totals,identified_revenue_minor}'));
  end if;
  if (g#>>'{totals,anonymous_revenue_minor}')::bigint <> 5000 then
    insert into _fail values ('C-anon-rev', format(
      'anonymous_revenue_minor = %s, expected 5000', g#>>'{totals,anonymous_revenue_minor}'));
  end if;
  if (g#>>'{totals,completed_transactions}')::bigint <> 20 then
    insert into _fail values ('C-completed', format(
      'completed_transactions = %s, expected 20 (the eligible total)',
      g#>>'{totals,completed_transactions}'));
  end if;
  if (g#>>'{totals,identified_transactions}')::bigint <> 15 then
    insert into _fail values ('C-identified-txn', format(
      'identified_transactions = %s, expected 15 (the identified subset)',
      g#>>'{totals,identified_transactions}'));
  end if;
  if (g#>>'{coverage,identity_revenue_pct}')::numeric <> 75.00 then
    insert into _fail values ('C-pct-rev', format(
      'coverage.identity_revenue_pct = %s, expected 75.00 (15000/20000)',
      g#>>'{coverage,identity_revenue_pct}'));
  end if;
  if (g#>>'{coverage,identity_transaction_pct}')::numeric <> 75.00 then
    insert into _fail values ('C-pct-txn', format(
      'coverage.identity_transaction_pct = %s, expected 75.00 (15/20)',
      g#>>'{coverage,identity_transaction_pct}'));
  end if;
end;
$v732c$;

-- ===============================================================================================
-- PART D -- public.get_ci_acquisition_v1: acquisition governed/unknown coverage (check 59).
-- ===============================================================================================
do $v732d$
declare
  biz  uuid := '00000000-0000-4000-8000-0000007d3201';
  u_sa uuid := '00000000-0000-4000-8000-0000007d3202';
  d_from date := current_date - 10;
  d_to   date := current_date;
  g jsonb;
  v_governed int;
  v_unknown  int;
  v_total    int;
begin
  insert into auth.users (id, email) values (u_sa, 'zz-v732d-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v732d-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v732 coverage acquisition', 'zz-v732-acq',
     array['dashboard','clients','sales','reports']);

  -- 3 referral, 3 walk_in_till (governed, 6 total), 4 unknown (no GUC -> v629's BEFORE INSERT
  -- default). The GUC is transaction-local; each batch sets it fresh before its own insert.
  perform set_config('app.first_acquired_via', 'referral', true);
  insert into public.clients (business_id, full_name)
    select biz, 'ZZ v732d referral ' || gs from generate_series(1,3) gs;

  perform set_config('app.first_acquired_via', 'walk_in_till', true);
  insert into public.clients (business_id, full_name)
    select biz, 'ZZ v732d walkin ' || gs from generate_series(1,3) gs;

  perform set_config('app.first_acquired_via', '', true);
  insert into public.clients (business_id, full_name)
    select biz, 'ZZ v732d unknown ' || gs from generate_series(1,4) gs;

  g := public.get_ci_acquisition_v1(biz, d_from, d_to);

  select coalesce(sum((r->>'customers')::int) filter (where r->>'via' <> 'unknown'), 0),
         coalesce(sum((r->>'customers')::int) filter (where r->>'via' = 'unknown'), 0),
         coalesce(sum((r->>'customers')::int), 0)
    into v_governed, v_unknown, v_total
    from jsonb_array_elements(g->'sources') r;

  if v_governed <> 6 then
    insert into _fail values ('D-governed', format(
      'governed (non-unknown) customers = %s, expected 6 (the subset)', v_governed));
  end if;
  if v_unknown <> 4 then
    insert into _fail values ('D-unknown', format(
      'unknown customers = %s, expected 4 (the complement)', v_unknown));
  end if;
  if v_total <> 10 then
    insert into _fail values ('D-total', format(
      'total customers across sources = %s, expected 10 (the eligible total)', v_total));
  end if;
end;
$v732d$;

-- ===============================================================================================
-- PART E -- public.get_ci_contactability_v1 (app.contactable_counts_v1): consent-reach coverage.
-- ===============================================================================================
do $v732e$
declare
  biz  uuid := '00000000-0000-4000-8000-0000007e3201';
  u_sa uuid := '00000000-0000-4000-8000-0000007e3202';
  g jsonb;
  v_total   int;
  v_allowed int;
begin
  insert into auth.users (id, email) values (u_sa, 'zz-v732e-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v732e-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v732 coverage contactability', 'zz-v732-contact',
     array['dashboard','clients','sales','reports']);

  create temp table zz_v732e_clients (gs int, cid uuid) on commit drop;
  insert into zz_v732e_clients (gs, cid)
    select gs, gen_random_uuid() from generate_series(1,10) gs;

  -- All 10 are phone-reachable (a valid 8-digit SG mobile per app.norm_phone). 6 carry an
  -- affirmative granted marketing/whatsapp consent; 4 carry none.
  insert into public.clients (id, business_id, full_name, phone)
    select cid, biz, 'ZZ v732e contact ' || gs, '8100' || lpad(gs::text, 4, '0')
    from zz_v732e_clients;

  insert into public.consents (business_id, client_id, channel, action, source, purpose)
    select biz, cid, 'whatsapp', 'granted', 'v732 fixture', 'marketing'
    from zz_v732e_clients where gs <= 6;

  g := public.get_ci_contactability_v1(biz, null);

  v_total   := (g->'business_offers'->>'customers')::int;
  v_allowed := (g->'business_offers'->'allowed_by_channel'->>'whatsapp')::int;

  if v_total <> 10 then
    insert into _fail values ('E-total', format(
      'business_offers.customers = %s, expected 10 (the eligible total)', v_total));
  end if;
  if v_allowed <> 6 then
    insert into _fail values ('E-allowed', format(
      'business_offers.allowed_by_channel.whatsapp = %s, expected 6 (the reachable subset)',
      v_allowed));
  end if;
end;
$v732e$;

select case when count(*)=0 then 'PASS — every coverage-bearing reader shows exact numerator/denominator/pct'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v732: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
