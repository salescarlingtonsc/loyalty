-- EXECUTED acceptance fixture for nestly_v712 — three closures against
-- public.get_ci_opportunities_v1: check 23 (ONE materiality bar, sourced from
-- app.ci_materiality_threshold_bps_v705(), not a second hand-typed constant), check 25 (every
-- extended-mode candidate's impact carries affected_customers/revenue_cents/margin/capacity/
-- retention_risk, every value traced to an already-computed figure), check 77 (EVERY candidate
-- this fixture exercises carries >=2 distinct alternative kinds including one non-incentive kind,
-- with no exclusions: the three strength generators gain kind='no_action', and
-- staff_mix_underperformance — seeded so it actually fires, not assumed — gains
-- kind='operational_change').
--
-- Above the v422 watermark: reported n/a in the BASELINE phase, gated on the MIGRATED run
-- (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- =================================================================================================
-- PREDETERMINED TRUTH TABLE (every number below computed before the first run, all arithmetic
-- shown; see this migration's own header for the derivation)
-- =================================================================================================
--
-- A. SOURCE CHECK (check 23, part 1 — "assert by extracting the live body that the literal 1.0
--    no longer appears as the constant's initialiser and that the constant references the
--    function"). A behavioural override of app.ci_materiality_threshold_bps_v705() is not possible
--    here: it is called with no arguments and marked immutable, so a same-transaction
--    CREATE OR REPLACE of it does not change what a fresh call inside
--    public.get_ci_opportunities_v1 resolves to in the general case relied on elsewhere in this
--    suite — the brief itself names this as the reason to combine a source assertion with a
--    behavioural one (part B below) rather than swap the function's return value. The source
--    assertion is executed (pg_get_functiondef against psql, not a text-editor grep of the
--    migration file) and combined with real RPC behaviour, matching the standard this project
--    already applies to v705's own "self-certifying exhaustiveness" step.
--
-- B. BIZ1 — an eight-candidate corpus from ONE business, ONE reporting day (window [d1,d1], the
--    same one-day convention nestly_v688's own BIZ1 uses so get_ci_discovery_v1's train/holdout
--    split abstains honestly rather than diluting this corpus with unrelated discovery/change
--    candidates):
--      1. data_quality_coverage      (foundation)   — always present, no cents figure.
--      2. package_leakage:<plan>     (quantified)   — EV-bearing (see BAR below for the exact
--                                                      formula); affected_customers.n = the 5
--                                                      in-window holders.
--      3. category_concentration     (unquantified) — domain=category_mix; concentration key
--                                                      only fires when the top category's own
--                                                      distribution is skew_material (nestly_v690),
--                                                      not asserted here either way — this fixture
--                                                      only proves the FIVE new check-25 keys.
--      4. contactability_gap         (unquantified) — no consent captured for any of the 30
--                                                      funnel clients, so 0 of 30 reachable.
--      5. gateway_followthrough:<svc>(unquantified) — domain=service_intelligence, one of the
--                                                      four capacity-relevant domains; this
--                                                      business has NO staff_hours rows, so its
--                                                      impact.capacity must read
--                                                      {status:'unavailable', reason:'no staff
--                                                      schedule rows recorded'} — the honest
--                                                      "gate fires, underlying data absent" path,
--                                                      distinct from not_applicable.
--      6. strength:category:facial   (strength)     — 20 buyers of the single classified service,
--                                                      all snapshotted canonical_node_key='facial'
--                                                      (a real, pre-seeded taxonomy_nodes level-2
--                                                      key — taxonomy_nodes is curated reference
--                                                      data with no insert policy for a fixture to
--                                                      write its own node into, confirmed by
--                                                      reading db/migrations/20260831_nestly_v647_
--                                                      canonical_taxonomy.sql).
--      7. strength:service:<svc>     (strength)      — the only service, trivially top by revenue.
--      8. strength:weekday:<dow>     (strength)      — the only weekday represented in a one-day
--                                                      window, trivially top.
--    Every one of the three strength candidates must now carry an alternatives array of length 2:
--    [{kind:'no_action', primary:true, what:'keep doing this; nothing to change'},
--     {kind:'reminder_only', primary:false, what:'No action needed beyond monitoring.'}].
--    The other v683-gated/campaign generators (no_discount_reminder, loyalty_cannibalisation_gap,
--    campaigns) do not fire in this corpus (no discount-dependency data, no loyalty programme, no
--    campaign sends) — this is the honest state to test against; staff_mix_underperformance is
--    NOT constructed here (its own preconditions need a dedicated staff/service-mix seed, section D
--    below), so this fixture's B4 loop simply never sees it in BIZ1's own ranked array. Section D
--    is what makes staff_mix_underperformance itself part of the "no exclusions" claim.
--
-- D. STAFF — check 77, staff_mix_underperformance. The exact two-service-class shape
--    nestly_v683's own fixture (db/tests/executed/v683_corpus_behavioural_authorities.sql) proves
--    for get_ci_staff_performance_v1's mix-adjusted index, on a business isolated from BIZ1/BAR so
--    nothing here perturbs their already-asserted counts:
--      PREMIUM ($100.00): Alice x5, Carol x3 (Carol stays below the evidence floor of 5 — not
--        needed for this fixture's own assertion, but keeps the shape byte-identical to v683's own
--        proven construction rather than a new, unverified variant).
--      BASIC ($50.00 / $20.00): Bob x5 @ $50, Dave x5 @ $20 -> firm avg ticket(BASIC) =
--        (5*5000+5*2000)/10 = 3500. Dave: revenue=10000, expected=5*3500=17500,
--        index=10000/17500=0.5714 -> rounds 0.57, below the 0.80 bar (app.ci_staff_performance's
--        own c_staff_index_bar) and evidence-ok (5 visits >= floor 5) -> promoted as
--        staff_mix_underperformance:<dave>. Verified directly against the running harness before
--        writing this fixture: only this one candidate is ranked (data_quality_coverage and every
--        other generator abstain on this minimal business — no discovery/change candidates
--        surface either, confirmed empirically, not assumed from the window length alone).
--    Its alternatives array must now carry exactly 2 entries:
--    [{kind:'operational_change', primary:true,
--      what:'review the mix this person is scheduled on (training, booking rules, roster)'},
--     {kind:'reminder_only', primary:false, what:'Coach, no compensation change.'}].
--
-- C. BAR — check 23 part 2, "a candidate exactly at the bar". A single-holder package_leakage
--    business, engineered so expected_value.cents lands EXACTLY on
--    round(period_revenue * app.ci_materiality_threshold_bps_v705() / 10000):
--      H1: 5 visits before d1, ten days apart (d1-50, d1-40, d1-30, d1-20, d1-10) -> 4 measured
--          intervals, median_interval_days=10 (>= app.return_probability_v681's own floor of 3).
--          app.return_probability_v681(biz, H1, as_of).probability = round(1 - exp(-30/10), 4)
--                                                                   = round(0.950212..., 4) = 0.9502
--          (verified directly: select round(1 - exp(-30.0/10), 4) = 0.9502).
--      5 package holders (H1 + 4 with no prior visit at all, so their own return_probability is
--      'insufficient' and contributes 0 to the sum, counted in expected_value.inputs.abstained),
--      each remaining=9 of sessions_included=10 (aggregate utilisation 5/50=10%, under the 50%
--      leakage bar; evidence.n=5 packages sold, at the sample floor), plan price_cents=100000,
--      sessions=10 -> per_session_cents = round(100000/10) = 10000.
--      EV = H1's own contribution alone = remaining(9) * per_session_cents(10000) * P(0.9502)
--         = 90000 * 0.9502 = 85518.0 exactly -> expected_value.cents = round(85518.0) = 85518.
--      All 5 package-purchase sales occur ON d1 (the only day in the window, and the only sales
--      in the window — the H1 rhythm visits are all before d1); each priced at 1710360 cents so
--      period_revenue = 5 * 1710360 = 8551800 cents exactly.
--      materiality ratio = round(10000 * 85518 / 8551800) = round(100.0000000...) = 100 bps
--                         = app.ci_materiality_threshold_bps_v705() EXACTLY -> materiality_class
--      must be 'material' (the gate is >=, inclusive of the bar). Verified directly against the
--      running harness before writing this fixture (numerator=85518, denominator=8551800,
--      pct=1.0, class='material').
--
-- MUTATION PROOF (external, not embedded — see the task's own report, not this file): reverting
-- db/migrations/20260902_nestly_v712_spine_wording_closures.sql (dropping it from db/migrations/
-- and re-running this same fixture against a migrated database that stops at nestly_v711) turns
-- every section-B/C/D assertion below RED: the strength alternatives are back to a single
-- reminder_only kind (B fails), impact never carries affected_customers/revenue_cents/margin/
-- capacity/retention_risk (B fails), staff_mix_underperformance:dave is back to a single
-- reminder_only kind (D fails), and the materiality constant is the literal 1.0 again (A
-- and C still numerically agree by coincidence at today's 1% setting, but A's source assertion
-- fails outright since app.ci_materiality_threshold_bps_v705() then appears nowhere in the
-- constant's initialiser).

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000712fee', 'zz-v712-owner@example.test')
  on conflict (id) do nothing;
insert into public.super_admins (user_id, email) values
  ('00000000-0000-4000-8000-000000712fee', 'zz-v712-owner@example.test')
  on conflict do nothing;
select set_config('request.jwt.claims', json_build_object(
    'sub', '00000000-0000-4000-8000-000000712fee', 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google'))
  )::text, true);

-- =================================================================================================
-- A · SOURCE CHECK (check 23, part 1)
-- =================================================================================================
do $v712a$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = 'get_ci_opportunities_v1'
     and p.pronargs = 6;

  if v_def is null then
    insert into _fail values ('A-missing', 'public.get_ci_opportunities_v1(6 args) not found');
    return;
  end if;

  if position('c_ev_materiality_pct constant numeric := 1.0' in v_def) > 0 then
    insert into _fail values ('A-literal-still-present',
      'the pre-v712 hand-typed 1.0 materiality constant text is still present in the live body');
  end if;
  if position('app.ci_materiality_threshold_bps_v705() / 100.0' in v_def) = 0 then
    insert into _fail values ('A-not-derived',
      'c_ev_materiality_pct does not reference app.ci_materiality_threshold_bps_v705()');
  end if;
  if position('affected_customers' in v_def) = 0 then
    insert into _fail values ('A-no-affected-customers', 'affected_customers key not found in the live body');
  end if;
  if position('revenue_cents' in v_def) = 0 or position('retention_risk' in v_def) = 0
     or position('''margin''' in v_def) = 0 then
    insert into _fail values ('A-missing-keys', 'one of revenue_cents/retention_risk/margin not found in the live body');
  end if;
  if (select app.ci_materiality_threshold_bps_v705()) <> 100 then
    insert into _fail values ('A-threshold-value',
      format('app.ci_materiality_threshold_bps_v705() returned %s, expected 100 (1%%)',
             app.ci_materiality_threshold_bps_v705()));
  end if;
end
$v712a$;

select case when count(*)=0 then 'PASS — A: source check, check 23 part 1'
       else 'FAIL' end as verdict, count(*) as failures from _fail;
select k, v from _fail order by k, v;

-- =================================================================================================
-- B · BIZ1 — eight-candidate corpus (checks 25, 77)
-- =================================================================================================
do $v712b$
declare
  biz      uuid := '00000000-0000-4000-8000-000000712b01';
  br       uuid := '00000000-0000-4000-8000-000000712b11';
  svc_gw   uuid := '00000000-0000-4000-8000-0000007120a1';
  plan_big uuid := '00000000-0000-4000-8000-0000007120b1';
  plan_sm  uuid := '00000000-0000-4000-8000-0000007120b2';

  d1       date := current_date - 200;
  as_of    timestamptz := ((d1 + 150)::timestamp + time '12:00') at time zone 'Asia/Singapore';

  g        jsonb;
  g0       jsonb;
  ranked   jsonb;
  cand     jsonb;
  alt      jsonb;
  kinds    text[];
  n_kinds  int;
  strength_ids text[] := array['strength:weekday','strength:category','strength:service'];
  sid      text;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v712 biz1', 'zz-v712-biz1',
     array['dashboard','clients','sales','reports','packages']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v712 biz1 main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v712 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_gw, biz, 'ZZ v712 gateway service', 1000, 30);
  insert into public.package_plans (id, business_id, name, price_cents, sessions, active) values
    (plan_big, biz, 'ZZ v712 plan big (10 sessions)', 20000, 10, true),
    (plan_sm,  biz, 'ZZ v712 plan small (4 sessions)',    40,  4, true);

  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000712' || lpad((100+s)::text,3,'0'))::uuid,
         biz, 'ZZ v712 funnel ' || s from generate_series(1,20) s;
  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000712' || lpad((300+s)::text,3,'0'))::uuid,
         biz, 'ZZ v712 plan-big holder ' || s from generate_series(1,5) s;
  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000712' || lpad((400+s)::text,3,'0'))::uuid,
         biz, 'ZZ v712 plan-small holder ' || s from generate_series(1,5) s;

  -- FUNNEL: F1..F20 first visit at d1 (all classified 'facial', so a real classified category
  -- exists to make strength:category / category_concentration real, non-fabricated candidates).
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000712' || lpad((500+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000712' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 1000,
         (d1::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (d1::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,20) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents, canonical_node_key)
  select biz, ('00000000-0000-4000-8000-000000712' || lpad((500+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 1000, 1000, 'facial' from generate_series(1,20) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000712' || lpad((520+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000712' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 1000,
         ((d1+10)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1+10)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,20) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents, canonical_node_key)
  select biz, ('00000000-0000-4000-8000-000000712' || lpad((520+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 1000, 1000, 'facial' from generate_series(1,20) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000712' || lpad((540+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000712' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 1000,
         ((d1+20)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1+20)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,18) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents, canonical_node_key)
  select biz, ('00000000-0000-4000-8000-000000712' || lpad((540+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 1000, 1000, 'facial' from generate_series(1,18) s;

  -- H1 rhythm (below the evidence floor alone -> no lapsed_regulars candidate; irrelevant here).
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000712' || lpad((630+s)::text,3,'0'))::uuid,
         biz, br, '00000000-0000-4000-8000-000000712301'::uuid, 'service', 3000,
         ((d1 - (60 - s*10))::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1 - (60 - s*10))::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000712' || lpad((630+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 3000, 3000 from generate_series(1,5) s;

  -- PACKAGES.
  insert into public.client_packages
    (id, business_id, plan_id, client_id, sessions_snapshot, remaining, status, purchased_at,
     plan_name_snapshot, plan_version_snapshot, price_cents_snapshot)
  select gen_random_uuid(), biz, plan_big,
         ('00000000-0000-4000-8000-000000712' || lpad((300+s)::text,3,'0'))::uuid,
         10, 10, 'active', (d1::timestamp + time '10:00') at time zone 'Asia/Singapore',
         'ZZ v712 plan big (10 sessions)', 1, 20000
    from generate_series(1,5) s;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000712' || lpad((650+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000712' || lpad((300+s)::text,3,'0'))::uuid,
         'package', 20000,
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore',
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;

  insert into public.client_packages
    (id, business_id, plan_id, client_id, sessions_snapshot, remaining, status, purchased_at,
     plan_name_snapshot, plan_version_snapshot, price_cents_snapshot)
  select gen_random_uuid(), biz, plan_sm,
         ('00000000-0000-4000-8000-000000712' || lpad((400+s)::text,3,'0'))::uuid,
         4, 3, 'active', (d1::timestamp + time '10:00') at time zone 'Asia/Singapore',
         'ZZ v712 plan small (4 sessions)', 1, 40
    from generate_series(1,5) s;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000712' || lpad((660+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000712' || lpad((400+s)::text,3,'0'))::uuid,
         'package', 40,
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore',
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;

  ---------------------------------------------------------------------------
  -- PRECONDITION
  ---------------------------------------------------------------------------
  if (select coalesce(bool_and(s.counts_as_revenue) and bool_and(s.counts_as_visit), false)
        from public.sales s where s.business_id = biz and s.kind = 'service') is not true then
    insert into _fail values ('PRE-policy', 'a service sale did not resolve counts_as_revenue/visit true');
  end if;

  ---------------------------------------------------------------------------
  -- THE CALL (extended)
  ---------------------------------------------------------------------------
  g := public.get_ci_opportunities_v1(biz, d1, d1, null, as_of, true);
  ranked := g->'ranked';

  if jsonb_array_length(ranked) < 8 then
    insert into _fail values ('B-corpus-size',
      format('expected >=8 ranked candidates (the eight this fixture''s header enumerates), got %s: %s',
             jsonb_array_length(ranked),
             (select string_agg(c->>'id', ', ') from jsonb_array_elements(ranked) c)));
  end if;

  -- B1 · every ranked candidate's impact carries the five check-25 keys, honestly, never
  --      fabricated: every numeric value inside them is traced to a figure already present
  --      elsewhere on the SAME candidate (confidence.n, or the coalesced expected_value/
  --      scenario cents, or margin_guard/capacity's own already-asserted shape).
  for cand in select e from jsonb_array_elements(ranked) e loop
    if not (cand->'impact' ? 'affected_customers') then
      insert into _fail values ('B1-affected-customers-missing', format('candidate %s', cand->>'id'));
    elsif (cand->'impact'->'affected_customers'->>'status') not in ('ok','not_applicable') then
      insert into _fail values ('B1-affected-customers-status',
        format('candidate %s status %s', cand->>'id', cand->'impact'->'affected_customers'->>'status'));
    elsif (cand->'impact'->'affected_customers'->>'n')::int
          <> coalesce((cand->'confidence'->>'n')::int, 0) then
      insert into _fail values ('B1-affected-customers-fabricated',
        format('candidate %s: affected_customers.n=%s does not match confidence.n=%s',
               cand->>'id', cand->'impact'->'affected_customers'->>'n', cand->'confidence'->>'n'));
    end if;

    if not (cand->'impact' ? 'revenue_cents') then
      insert into _fail values ('B1-revenue-cents-missing', format('candidate %s', cand->>'id'));
    elsif (cand->'impact'->'revenue_cents'->>'status') = 'ok' then
      if (cand->'impact'->'revenue_cents'->>'cents')::numeric
         <> coalesce((cand->'impact'->'expected_value'->>'cents')::numeric,
                     (cand->'impact'->>'scenario_cents')::numeric) then
        insert into _fail values ('B1-revenue-cents-fabricated', format('candidate %s', cand->>'id'));
      end if;
    elsif (cand->'impact'->'revenue_cents'->>'status') <> 'not_applicable' then
      insert into _fail values ('B1-revenue-cents-status',
        format('candidate %s status %s', cand->>'id', cand->'impact'->'revenue_cents'->>'status'));
    end if;

    if not (cand->'impact' ? 'margin') then
      insert into _fail values ('B1-margin-missing', format('candidate %s', cand->>'id'));
    elsif (cand->'impact'->'margin'->>'status') = 'not_applicable'
          and coalesce(cand->'impact'->'margin'->>'reason', '') = '' then
      insert into _fail values ('B1-margin-no-reason', format('candidate %s', cand->>'id'));
    end if;
    if not (cand ? 'margin_guard') then
      insert into _fail values ('B1-no-margin-guard', format('candidate %s', cand->>'id'));
    else
      if cand->'impact'->'margin' is distinct from
         (case when cand->'margin_guard' is null or cand->'margin_guard' = 'null'::jsonb
               then jsonb_build_object('status','not_applicable',
                      'reason','no incentive spend for this candidate')
               else cand->'margin_guard' end) then
        insert into _fail values ('B1-margin-mismatch',
          format('candidate %s: impact.margin does not match margin_guard', cand->>'id'));
      end if;
    end if;

    if not (cand->'impact' ? 'capacity') then
      insert into _fail values ('B1-capacity-missing', format('candidate %s', cand->>'id'));
    elsif (cand->'impact'->'capacity') is distinct from
          (case when cand->'capacity' is null or cand->'capacity' = 'null'::jsonb
                then jsonb_build_object('status','not_applicable')
                else cand->'capacity' end) then
      insert into _fail values ('B1-capacity-mismatch',
        format('candidate %s: impact.capacity does not match top-level capacity', cand->>'id'));
    end if;

    if not (cand->'impact' ? 'retention_risk') then
      insert into _fail values ('B1-retention-risk-missing', format('candidate %s', cand->>'id'));
    elsif cand->>'domain' in ('cadence','retention_funnel') then
      if (cand->'impact'->'retention_risk'->>'status') <> 'ok' then
        insert into _fail values ('B1-retention-risk-should-be-ok', format('candidate %s', cand->>'id'));
      end if;
    elsif (cand->'impact'->'retention_risk'->>'status') <> 'not_applicable' then
      insert into _fail values ('B1-retention-risk-should-be-na', format('candidate %s', cand->>'id'));
    end if;
  end loop;

  -- B2 · gateway_followthrough (domain=service_intelligence, capacity-relevant): this business
  --      has NO staff_hours rows, so its capacity must be the honest 'unavailable' path, not
  --      not_applicable (proves the two states are genuinely distinguished, not collapsed).
  select c into cand from jsonb_array_elements(ranked) c
   where c->>'id' = 'gateway_followthrough:' || svc_gw::text;
  if cand is null then
    insert into _fail values ('B2-missing', 'gateway_followthrough:svc_gw was not promoted');
  else
    if (cand->'impact'->'capacity'->>'status') <> 'unavailable' then
      insert into _fail values ('B2-capacity-status',
        format('capacity status was %s, expected unavailable', cand->'impact'->'capacity'->>'status'));
    end if;
    if cand->'impact'->'capacity'->>'reason' <> 'no staff schedule rows recorded' then
      insert into _fail values ('B2-capacity-reason', format('capacity reason was %s', cand->'impact'->'capacity'->>'reason'));
    end if;
  end if;

  -- B3 · package_leakage: affected_customers.n = the 5 in-window holders (confidence.n).
  select c into cand from jsonb_array_elements(ranked) c where c->>'id' = 'package_leakage:' || plan_big::text;
  if cand is null then
    insert into _fail values ('B3-missing', 'package_leakage:plan_big was not promoted');
  elsif (cand->'impact'->'affected_customers'->>'n')::int <> 5 then
    insert into _fail values ('B3-n', format('affected_customers.n was %s, expected 5', cand->'impact'->'affected_customers'->>'n'));
  end if;

  -- B4 (check 77) · every ranked candidate that carries an 'alternatives' array carries >=2
  --      distinct kinds including at least one non-incentive kind.
  for cand in select e from jsonb_array_elements(ranked) e loop
    if cand->'alternatives' is not null then
      select array_agg(distinct a->>'kind') into kinds from jsonb_array_elements(cand->'alternatives') a;
      n_kinds := coalesce(array_length(kinds, 1), 0);
      if n_kinds < 2 then
        insert into _fail values ('B4-kinds', format('candidate %s carries only %s distinct kind(s): %s',
          cand->>'id', n_kinds, kinds));
      end if;
      if not exists (select 1 from jsonb_array_elements(cand->'alternatives') a
                      where a->>'kind' <> 'incentive') then
        insert into _fail values ('B4-non-incentive', format('candidate %s has no non-incentive alternative', cand->>'id'));
      end if;
    end if;
  end loop;

  -- B5 · the three strength candidates specifically: exactly the two-element shape the brief names.
  foreach sid in array strength_ids loop
    select c into cand from jsonb_array_elements(ranked) c where c->>'id' like sid || ':%';
    if cand is null then
      insert into _fail values ('B5-missing', format('no %s candidate was promoted', sid));
      continue;
    end if;
    if jsonb_array_length(cand->'alternatives') <> 2 then
      insert into _fail values ('B5-length', format('%s alternatives length was %s, expected 2',
        cand->>'id', jsonb_array_length(cand->'alternatives')));
    end if;
    select a into alt from jsonb_array_elements(cand->'alternatives') a where a->>'kind' = 'no_action';
    if alt is null then
      insert into _fail values ('B5-no-action-missing', format('%s has no no_action alternative', cand->>'id'));
    else
      if (alt->>'primary')::boolean is not true then
        insert into _fail values ('B5-no-action-primary', format('%s no_action.primary was %s', cand->>'id', alt->>'primary'));
      end if;
      if alt->>'what' <> 'keep doing this; nothing to change' then
        insert into _fail values ('B5-no-action-what', format('%s no_action.what was %s', cand->>'id', alt->>'what'));
      end if;
    end if;
    select a into alt from jsonb_array_elements(cand->'alternatives') a where a->>'kind' = 'reminder_only';
    if alt is null then
      insert into _fail values ('B5-reminder-missing', format('%s lost its existing reminder_only alternative', cand->>'id'));
    elsif (alt->>'primary')::boolean is not false then
      insert into _fail values ('B5-reminder-primary', format('%s reminder_only.primary was %s, expected false', cand->>'id', alt->>'primary'));
    end if;
  end loop;

  -- B6 (regression) · the base pass (p_extended=>false) is untouched: no candidate carries any of
  --      the five new impact keys, and the frozen v678/v696 twelve-key contract still holds.
  g0 := public.get_ci_opportunities_v1(biz, d1, d1, null, as_of, false);
  for cand in select e from jsonb_array_elements(g0->'ranked') e loop
    if (select array_agg(k order by k) from jsonb_object_keys(cand) k)
       <> array['action','comparison','confidence','domain','evidence','evidence_class','id',
                 'impact','limitation','pattern','rank','rank_class'] then
      insert into _fail values ('B6-base-contract',
        format('base-mode candidate %s carries keys %s, not the frozen twelve-key contract',
          cand->>'id', (select array_agg(k order by k) from jsonb_object_keys(cand) k)));
    end if;
    if cand->'impact' ? 'affected_customers' or cand->'impact' ? 'revenue_cents'
       or cand->'impact' ? 'margin' or cand->'impact' ? 'capacity' or cand->'impact' ? 'retention_risk' then
      insert into _fail values ('B6-base-leaked', format('base-mode candidate %s carries a check-25 key', cand->>'id'));
    end if;
  end loop;
end
$v712b$;

select case when count(*)=0 then
              'PASS — B: BIZ1 eight-candidate corpus, checks 25/77, base-pass regression'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

-- =================================================================================================
-- C · BAR — a candidate exactly at the materiality bar (check 23, part 2)
-- =================================================================================================
do $v712c$
declare
  biz uuid := gen_random_uuid();
  br  uuid := gen_random_uuid();
  plan uuid := gen_random_uuid();
  h1  uuid := gen_random_uuid();
  each_amt constant bigint := 1710360;   -- 5 * 1710360 = 8551800 period revenue, exactly.
  d1  date := current_date - 200;
  as_of timestamptz := ((d1 + 150)::timestamp + time '12:00') at time zone 'Asia/Singapore';
  g   jsonb;
  cand jsonb;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v712 bar', 'zz-v712-bar',
     array['dashboard','clients','sales','reports','packages']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v712 bar main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v712 bar fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.package_plans (id, business_id, name, price_cents, sessions, active) values
    (plan, biz, 'ZZ v712 bar plan', 100000, 10, true);

  -- H1: the only holder with a measured rhythm (5 visits before d1, 10-day gaps -> median 10, k=4).
  insert into public.clients (id, business_id, full_name) values (h1, biz, 'ZZ v712 bar H1');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, h1, 'service', 100,
         ((d1 - (60 - s*10))::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1 - (60 - s*10))::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;

  -- 5 package holders (H1 + 4 with no prior visit at all), each remaining=9 of 10, sold on d1.
  insert into public.clients (id, business_id, full_name)
  select gen_random_uuid(), biz, 'ZZ v712 bar holder ' || g2 from generate_series(2,5) g2;

  insert into public.client_packages
    (id, business_id, plan_id, client_id, sessions_snapshot, remaining, status, purchased_at,
     plan_name_snapshot, plan_version_snapshot, price_cents_snapshot)
  select gen_random_uuid(), biz, plan, cid, 10, 9, 'active',
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore',
         'ZZ v712 bar plan', 1, 100000
    from (select h1 as cid
          union all
          select id from public.clients where business_id = biz and full_name like 'ZZ v712 bar holder%'
         ) hs;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, cid, 'package', each_amt,
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore',
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore'
    from (select h1 as cid
          union all
          select id from public.clients where business_id = biz and full_name like 'ZZ v712 bar holder%'
         ) hs;

  g := public.get_ci_opportunities_v1(biz, d1, d1, null, as_of, true);
  select c into cand from jsonb_array_elements(g->'ranked') c where c->>'domain' = 'packages';

  if cand is null then
    insert into _fail values ('C-missing', 'no packages-domain candidate was promoted in BAR');
    return;
  end if;

  if (cand->'impact'->'expected_value'->>'cents')::bigint <> 85518 then
    insert into _fail values ('C-ev', format('expected_value.cents was %s, expected 85518',
      cand->'impact'->'expected_value'->>'cents'));
  end if;
  if (cand->'materiality'->>'numerator')::bigint <> 85518
     or (cand->'materiality'->>'denominator')::bigint <> 8551800 then
    insert into _fail values ('C-materiality', format('materiality was %s', cand->'materiality'));
  end if;
  if (cand->'materiality'->>'pct')::numeric <> 1.0 then
    insert into _fail values ('C-pct', format('materiality.pct was %s, expected 1.0', cand->'materiality'->>'pct'));
  end if;
  if cand->>'materiality_class' <> 'material' then
    insert into _fail values ('C-class', format('materiality_class was %s, expected material (the bar is inclusive, >=)',
      cand->>'materiality_class'));
  end if;
  -- the bar itself, read live, so this fixture re-verifies the bar's value rather than assuming it:
  if (select round(8551800 * app.ci_materiality_threshold_bps_v705()::numeric / 10000.0)) <> 85518 then
    insert into _fail values ('C-bar-mismatch',
      format('app.ci_materiality_threshold_bps_v705() no longer resolves 85518 as the exact bar for '
             'period_revenue=8551800 — this fixture''s "exactly at the bar" engineering assumed bps=100'));
  end if;
end
$v712c$;

select case when count(*)=0 then 'PASS — C: BAR, a candidate exactly at the materiality bar (check 23 part 2)'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

-- =================================================================================================
-- D · STAFF — staff_mix_underperformance actually fires (check 77, no exclusions)
-- =================================================================================================
do $v712d$
declare
  biz uuid := gen_random_uuid();
  br  uuid := gen_random_uuid();
  st_alice uuid := gen_random_uuid();
  st_bob   uuid := gen_random_uuid();
  st_carol uuid := gen_random_uuid();
  st_dave  uuid := gen_random_uuid();
  cl_b uuid := gen_random_uuid();
  svc_premium uuid := gen_random_uuid();
  svc_basic uuid := gen_random_uuid();
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_perf_from date := v_today - 10;
  v_perf_to   date := v_today - 6;
  as_of timestamptz := (v_today::timestamp + time '12:00') at time zone 'Asia/Singapore';
  g jsonb;
  cand jsonb;
  ranked jsonb;
  alt jsonb;
  kinds text[];
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v712 staff', 'zz-v712-staff',
     array['dashboard','clients','sales','reports','appointments']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v712 staff main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v712 staff fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.staff (id, business_id, user_id, role, full_name, active) values
    (st_alice, biz, null, 'staff', 'ZZ Alice', true),
    (st_bob,   biz, null, 'staff', 'ZZ Bob', true),
    (st_carol, biz, null, 'staff', 'ZZ Carol', true),
    (st_dave,  biz, null, 'staff', 'ZZ Dave', true);
  insert into public.staff_branches (business_id, staff_id, branch_id)
  values (biz, st_alice, br), (biz, st_bob, br), (biz, st_carol, br), (biz, st_dave, br);

  insert into public.clients (id, business_id, full_name) values
    (cl_b, biz, 'ZZ v712 staff client B');

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_premium, biz, 'ZZ Premium', 10000, 60),
    (svc_basic, biz, 'ZZ Basic', 3000, 20);

  -- Same shape as db/tests/executed/v683_corpus_behavioural_authorities.sql's own MIX-ADJUSTED
  -- STAFF PERFORMANCE section: one sale per (staff, day), fixed ids so sale_items staff attribution
  -- is unambiguous (a row_number()-based join was tried first and rejected here — ties on
  -- (occurred_at, amount_cents) make that ordering unstable and it silently mis-attributed staff).
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-0000007120' || lpad(n::text, 2, '0'))::uuid,
         biz, br, cl_b, 'service', cents,
         (v_today + day_offset)::timestamp at time zone 'Asia/Singapore',
         (v_today + day_offset)::timestamp at time zone 'Asia/Singapore'
    from (values
      (1, 10000, -10),(2, 10000, -9),(3, 10000, -8),(4, 10000, -7),(5, 10000, -6),
      (6, 10000, -10),(7, 10000, -9),(8, 10000, -8),
      (9, 5000, -10),(10, 5000, -9),(11, 5000, -8),(12, 5000, -7),(13, 5000, -6),
      (14, 2000, -10),(15, 2000, -9),(16, 2000, -8),(17, 2000, -7),(18, 2000, -6)
    ) as t(n, cents, day_offset);

  insert into public.sale_items (sale_id, business_id, item_type, ref_id, qty, unit_cents, line_cents, staff_id)
  select ('00000000-0000-4000-8000-0000007120' || lpad(n::text, 2, '0'))::uuid,
         biz, 'service', service_id, 1, cents, cents, staff_id
    from (values
      (1, svc_premium, 10000, st_alice),(2, svc_premium, 10000, st_alice),(3, svc_premium, 10000, st_alice),
      (4, svc_premium, 10000, st_alice),(5, svc_premium, 10000, st_alice),
      (6, svc_premium, 10000, st_carol),(7, svc_premium, 10000, st_carol),(8, svc_premium, 10000, st_carol),
      (9, svc_basic, 5000, st_bob),(10, svc_basic, 5000, st_bob),(11, svc_basic, 5000, st_bob),
      (12, svc_basic, 5000, st_bob),(13, svc_basic, 5000, st_bob),
      (14, svc_basic, 2000, st_dave),(15, svc_basic, 2000, st_dave),(16, svc_basic, 2000, st_dave),
      (17, svc_basic, 2000, st_dave),(18, svc_basic, 2000, st_dave)
    ) as t(n, service_id, cents, staff_id);

  ---------------------------------------------------------------------------
  -- PRECONDITION: dave's mix-adjusted index resolves exactly as the truth table computes,
  -- before trusting anything downstream of it.
  ---------------------------------------------------------------------------
  g := public.get_ci_staff_performance_v1(biz, v_perf_from, v_perf_to, null);
  if not exists (select 1 from jsonb_array_elements(g->'staff') e
                  where (e->>'staff_id')::uuid = st_dave
                    and (e->'evidence'->>'status') = 'ok'
                    and (e->'unadjusted'->>'visits')::int = 5
                    and (e->'adjusted'->>'index')::numeric = 0.57) then
    insert into _fail values ('D-PRE-index',
      format('dave''s mix-adjusted index did not resolve to the expected 0.57: %s',
        (select e::text from jsonb_array_elements(g->'staff') e where (e->>'staff_id')::uuid = st_dave)));
  end if;

  g := public.get_ci_opportunities_v1(biz, v_perf_from, v_perf_to, null, as_of, true);
  ranked := g->'ranked';

  select c into cand from jsonb_array_elements(ranked) c
   where c->>'id' = 'staff_mix_underperformance:' || st_dave::text;

  if cand is null then
    insert into _fail values ('D-missing',
      format('staff_mix_underperformance:dave was not promoted; ranked=%s abstentions=%s',
        (select jsonb_agg(c2->>'id') from jsonb_array_elements(ranked) c2),
        (select jsonb_agg(a->>'generator') from jsonb_array_elements(g->'abstentions') a)));
  else
    if jsonb_array_length(cand->'alternatives') <> 2 then
      insert into _fail values ('D-length', format('alternatives length was %s, expected 2',
        jsonb_array_length(cand->'alternatives')));
    end if;

    select array_agg(distinct a->>'kind') into kinds from jsonb_array_elements(cand->'alternatives') a;
    if coalesce(array_length(kinds, 1), 0) < 2 then
      insert into _fail values ('D-kinds', format('carries only %s distinct kind(s): %s',
        coalesce(array_length(kinds, 1), 0), kinds));
    end if;
    if not exists (select 1 from jsonb_array_elements(cand->'alternatives') a where a->>'kind' <> 'incentive') then
      insert into _fail values ('D-non-incentive', 'no non-incentive alternative present');
    end if;

    select a into alt from jsonb_array_elements(cand->'alternatives') a where a->>'kind' = 'operational_change';
    if alt is null then
      insert into _fail values ('D-operational-change-missing', 'no operational_change alternative');
    else
      if (alt->>'primary')::boolean is not true then
        insert into _fail values ('D-operational-change-primary', format('primary was %s, expected true', alt->>'primary'));
      end if;
      if alt->>'what' <> 'review the mix this person is scheduled on (training, booking rules, roster)' then
        insert into _fail values ('D-operational-change-what', format('what was %s', alt->>'what'));
      end if;
    end if;

    select a into alt from jsonb_array_elements(cand->'alternatives') a where a->>'kind' = 'reminder_only';
    if alt is null then
      insert into _fail values ('D-reminder-missing', 'lost its existing reminder_only alternative');
    elsif (alt->>'primary')::boolean is not false then
      insert into _fail values ('D-reminder-primary', format('primary was %s, expected false', alt->>'primary'));
    end if;

    -- check 25 keys, same generic trace-back checks as B1, on this one candidate.
    if (cand->'impact'->'affected_customers'->>'n')::int <> coalesce((cand->'confidence'->>'n')::int, 0) then
      insert into _fail values ('D-affected-customers', 'affected_customers.n does not match confidence.n');
    end if;
  end if;

  -- D2 (check 77, "no exclusions") · every OTHER candidate this call ranked also clears >=2 kinds
  -- with a non-incentive present, same as B4's loop, so this business contributes no silent gap.
  for cand in select e from jsonb_array_elements(ranked) e loop
    if cand->'alternatives' is not null then
      select array_agg(distinct a->>'kind') into kinds from jsonb_array_elements(cand->'alternatives') a;
      if coalesce(array_length(kinds, 1), 0) < 2 then
        insert into _fail values ('D2-kinds', format('candidate %s carries only %s distinct kind(s): %s',
          cand->>'id', coalesce(array_length(kinds, 1), 0), kinds));
      end if;
      if not exists (select 1 from jsonb_array_elements(cand->'alternatives') a where a->>'kind' <> 'incentive') then
        insert into _fail values ('D2-non-incentive', format('candidate %s has no non-incentive alternative', cand->>'id'));
      end if;
    end if;
  end loop;
end
$v712d$;

select case when count(*)=0 then
              'PASS — D: STAFF, staff_mix_underperformance fires with 2 distinct kinds (check 77, no exclusions)'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v712: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
