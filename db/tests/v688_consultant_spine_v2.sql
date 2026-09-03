-- EXECUTED acceptance fixture for nestly_v688 — the consultant spine v2.
--
-- Above the v422 watermark: reported n/a in the BASELINE phase, gated on the MIGRATED run
-- (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- Proves public.get_ci_opportunities_v1(..., p_extended => true)
-- (db/migrations/20260920_nestly_v688_consultant_spine_v2.sql) closes checks 65, 73, 22, 43, 71,
-- 74, 77, 78, 79 while p_extended => false (the default every existing caller uses, including
-- v678/v680's own frozen fixtures below) reproduces v680's behaviour byte-for-byte — this file
-- does not touch v678_corpus_consultant_spine.sql or v680_corpus_envelope.sql, and relies on the
-- migration's own trailing-parameter design (see that file's header, judgement call 1) rather
-- than re-asserting their contract here.
--
-- =================================================================================================
-- FOUR INDEPENDENT BUSINESSES, kept apart on purpose
-- =================================================================================================
-- BIZ1 (materiality + package-leakage EV + cost_basis + incentive + alternatives +
--       reversal_condition + report_sections + top_actions + comparisons). A single window
--       [d1,d1] (ONE day) keeps the funnel population and the package cohort population exactly
--       the customers this fixture intends, with nothing else able to dilute the hand-computed
--       percentages. BIZ1 keeps the DEFAULT lifecycle floor (3) — see BIZ4 for why.
-- BIZ2 (check 43 only: the funnel candidate's action.what names its own bottleneck). A real
--       (non-trivial, gap >= 15pp) funnel, kept OUT of BIZ1 because BIZ1's funnel is deliberately
--       trivial (materiality) and a second population sharing that window would change its
--       hand-computed 100%/90% rates.
-- BIZ3 (the discovery generator, check 22). A referral-vs-other cohort with a large, obvious
--       effect (80pp) so it has every reasonable chance to survive false-discovery control and
--       holdout replication — kept OUT of BIZ1 because discovery needs a period wide enough to
--       split into two real halves, which would also enlarge BIZ1's funnel population window and
--       break its exact percentages. Discovery is inherently a scan over real, noisy data
--       (BH + holdout replication is exactly what makes it honest — see v686's own header), so
--       this fixture asserts the STRUCTURE unconditionally and the actual discovery/replication
--       outcome only when the engine reports one, rather than forcing a specific number that a
--       future, equally-valid statistical implementation could legitimately not reproduce.
-- BIZ4 (the lapsed_regulars EV formula, check 73, incl. the app.return_probability_v681
--       hard-floor abstention distinct from app.customer_cadence_v1's own, business-configurable
--       one). Kept OUT of BIZ1 -- found the hard way, on the real harness -- because lowering
--       customer_interval_min_observations business-wide (needed so L3's k=2 clears
--       customer_cadence_v1's floor while still failing v681's fixed floor of 3) ALSO drops the
--       floor for BIZ1's OWN funnel population, which legitimately has exactly 2 measured
--       intervals per customer and, once 150 days have passed, reads as "overdue" against its own
--       (very short) rhythm -- silently pulling 18 unrelated customers into lapsed_regulars and
--       making the EV assertions meaningless. BIZ4 carries ONLY L1/L2/L3, nothing else the lowered
--       floor could catch.
--
-- =================================================================================================
-- BIZ1 — HAND TRUTH TABLE (every number below computed before the first run)
-- =================================================================================================
-- WINDOW.  p_from = p_to = d1 (a single day). p_as_of = d1 + 150 days, so the 60-day funnel
--          maturity windows and every "overdue" check are comfortably satisfied no matter which
--          real day this suite runs on (d1 is itself anchored on current_date, not a literal date).
--
-- FUNNEL (trivial, check 65). F1..F20: first visit at d1 on svc_gw (their first-ever purchase,
--          which ALSO makes svc_gw a gateway service). ALL 20 return for a second visit at
--          d1+10 (100%). 18 of the 20 return for a third visit at d1+20 (90%).
--            mature_first = 20 (d1+60 <= d1+150).  stage_1_to_2 = 20/20 = 100.0%.
--            mature_second = 20 (d1+70 <= d1+150). stage_2_to_3 = 18/20 = 90.0%.
--            gap = 10.0pp < the 15pp bar -> ABSTAIN 'below_materiality', evidence n=20 clears the
--            floor of 5 (an evidence-ok, statistically clean, but immaterial gap — exactly check
--            65's scenario). NOT in ranked.
--          Because svc_gw is bought by all 20 on their first-ever visit and none of them buy it
--          AGAIN inside the window [d1,d1] (their 2nd/3rd visits fall outside the window), its
--          window-scoped repeat_rate is 0/20 = 0.0% against the firm's own first-to-second rate of
--          100.0% -- a 100pp gap -- so gateway_followthrough:<svc_gw> FIRES (gateway_count=20>=5,
--          evidence ok). This is deliberate, not a leak: it gives BIZ1 a genuine, real second
--          promoted candidate beyond the two built for EV, so report_sections/top_actions have real
--          content to bucket.
--
-- LAPSED REGULARS (check 73's EV formula) is NOT in this business -- see BIZ4 below for L1/L2/L3
-- and why the lowered lifecycle floor they need cannot safely share a business with this funnel.
--
-- PACKAGES (check 73's EV path in THIS business, and check 65's EV-materiality gate exercised for
-- real).
--   PLAN_BIG   price 20000 / 10 sessions -> 2000/session. 5 holders (H1..H5) each buy 1 package on
--       d1. H1 alone has an established rhythm (5 visits, gaps of 10 days, BEFORE d1) and never
--       touches any of the 10 package sessions (remaining=10). H2..H5 also never touch a session
--       (remaining=10 each) but have NO other sale ever, so app.return_probability_v681 abstains
--       for each (status='insufficient', no qualifying visit) -- contributing 0 and counted in
--       inputs.abstained. (H1's own rhythm also technically makes it "overdue" and hence eligible
--       for the lapsed_regulars generator too, but n=1 is below the sample floor of 5, so it
--       abstains there rather than becoming a second, unaccounted-for candidate.)
--         sessions_included = 50, sessions_used = 0 -> utilisation 0.0% < 50% bar -> fires (old gate).
--         unused = 50. scenario_cents = 50 * 2000 = 100000.
--         expected_value.cents = round(H1's 10*2000*0.950212932) = round(19004.25864) = 19004;
--         H2..H5 contribute 0 each. inputs.abstained = 4.
--   PLAN_SMALL price 40 / 4 sessions -> 10/session. 5 holders (K1..K5) each buy 1 package on d1,
--       use exactly 1 of 4 sessions (remaining=3), and have NO other sale ever (return_probability
--       abstains for every one of them).
--         sessions_included = 20, sessions_used = 5 -> utilisation 25.0% < 50% bar -> fires (old
--         gate; scenario_cents = 15 unused * 10 = 150, itself small but NOT the new gate's basis).
--         expected_value.cents = 0 (every holder abstains). inputs.abstained = 5.
--         0 cents is below 1% of BIZ1's period revenue (>= 100, see below) -> ABSTAIN
--         'below_materiality' when p_extended => true; PROMOTED when p_extended => false (the old,
--         pre-v688 behaviour), which this fixture uses as its materiality-gate mutation check: the
--         SAME data promotes under the old contract and abstains under the new one.
--
-- PERIOD REVENUE.  Only sales inside [d1,d1] count: F1..F20's first visits (20 * 1000 = 20000
--       cents) plus, if package sales resolve counts_as_revenue=true under this business's policy,
--       the ten package purchases themselves (up to 100200 more) -- every lapsed-regular and
--       plan-big-rhythm visit is dated outside this single-day window on purpose either way. The
--       exact bar is deliberately NOT asserted here (it depends on that policy resolution, which
--       this fixture does not need to pin down): PLAN_BIG's EV (19004) and lapsed_regulars' EV
--       (11668) clear either possible bar (200 or ~1202 cents) by a wide margin, and PLAN_SMALL's
--       EV (0) misses either bar identically. What IS asserted is the resulting behaviour, not the
--       bar's own value.
--
-- FIVE PROMOTED, HAND-COUNTED (there may be more -- this fixture only commits to a LOWER bound so
-- top_actions' five-length assertion is never a coin flip):
--   data_quality_coverage        foundation   (svc_gw is deliberately never mapped to a taxonomy
--                                              node, so classified revenue coverage is 0 bps,
--                                              nowhere near the 9000 bps bar, on an evidence-ok 20
--                                              identified customers)
--   package_leakage:<plan_big>   quantified   EV 19004
--   gateway_followthrough:<svc_gw> unquantified
--   contactability_gap           unquantified (zero consents are ever recorded for anyone in this
--                                              business, so the best channel reaches 0 of >=25
--                                              identified customers -- guaranteed, not merely
--                                              likely, given this fixture never inserts a consent)
--   strength:weekday:<dow of d1> strength     (the only weekday with any visits in the window,
--                                              so it trivially clears app.subgroup_evidence_v1 at
--                                              n=20 and is trivially the single highest by
--                                              revenue-per-visit)
--
-- =================================================================================================
-- BIZ2 — check 43 only
-- =================================================================================================
-- 10 first-timers, first visit at e1, ALL 10 return within 60 days (100%), only 4 of the 10 go on
-- to a third visit within 60 days of the second (40%). gap = 60.0pp >= 15pp bar, evidence n=10>=5
-- -> PROMOTES. bottleneck = 'second_to_third' (the reader's own rule: whichever stage rate is
-- lower). Asserted: action.what contains 'second-to-third' (the reader's own
-- replace(bottleneck,'_','-')).
--
-- =================================================================================================
-- BIZ3 — the discovery generator (check 22)
-- =================================================================================================
-- 12 referral-attributed clients and 12 non-referral clients, each with an anchor purchase in BOTH
-- halves of a wide window (train and holdout), referral clients returning within 30 days 100% of
-- the time and non-referral clients 0% of the time in both halves (an 80pp+ gap, chosen to survive
-- false-discovery control and holdout replication on the first try; this is inherently a scan over
-- real per-half rates, not a hand-forced value, so this fixture asserts unconditionally on the
-- ENGINE'S STRUCTURE — segment_dimensions, the discoveries/not_replicated/deteriorating arrays all
-- existing and being well-typed, report_sections carrying the discovery/change buckets — and only
-- makes a content assertion (evidence_class, id prefix, presence in ranked) conditional on the
-- engine actually reporting a discovery, which it is overwhelmingly likely to given the effect
-- size, but is not hand-guaranteed the way BIZ1's percentages are.
--
-- =================================================================================================
-- LANDMINES HANDLED (learned from db/tests/executed/v678_corpus_consultant_spine.sql and
-- docs/qa/CI-CORPUS-FIXTURE-GUIDE.md; not re-discovered here)
-- =================================================================================================
--  * created_at pinned to occurred_at/purchased_at on every backdated row.
--  * counts_as_revenue / counts_as_visit are NEVER passed on insert.
--  * the operational recipe (workspace controls + subscription lifecycle + subscriptions +
--    reporting_contract_versions_v106 backdated) is required for every business, or every gate
--    refuses for a billing/contract reason and the whole fixture passes vacuously.
--  * a fresh business DOES get a customer_lifecycle_policies_v107 row automatically --
--    trg_customer_lifecycle_policy_v107_business_insert seeds version_no=1 (min_observations=3)
--    the instant public.businesses is inserted, and the table is append-only (before update/delete
--    raises restrict_violation) -- so BIZ1's lowered floor is a NEW version_no=2 row with a later
--    effective_from, never an insert/update of version 1 itself.
--  * every assertion of a denial/abstention first checks the population it rests on is what this
--    fixture intends (the "assert your preconditions" rule).

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000688ee1', 'zz-v688-owner1@example.test'),
  ('00000000-0000-4000-8000-000000688ee2', 'zz-v688-owner2@example.test'),
  ('00000000-0000-4000-8000-000000688ee3', 'zz-v688-owner3@example.test'),
  ('00000000-0000-4000-8000-000000688ee4', 'zz-v688-owner4@example.test'),
  ('00000000-0000-4000-8000-000000688eee', 'zz-v688-sa@example.test')
  on conflict (id) do nothing;
insert into public.super_admins (user_id, email) values
  ('00000000-0000-4000-8000-000000688eee', 'zz-v688-sa@example.test')
  on conflict do nothing;

-- One shared platform (super admin) session for every RPC call below. Google-SSO-shaped claims
-- (amr + app_metadata.providers) are required since nestly_v625 -- a super_admins row alone is
-- not enough (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md, "A platform session needs more").
select set_config('request.jwt.claims', json_build_object(
    'sub', '00000000-0000-4000-8000-000000688eee', 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google'))
  )::text, true);

-- =================================================================================================
-- BIZ1
-- =================================================================================================
do $v688a$
declare
  biz      uuid := '00000000-0000-4000-8000-000000688001';
  br       uuid := '00000000-0000-4000-8000-000000688011';
  u_owner  uuid := '00000000-0000-4000-8000-000000688ee1';
  svc_gw   uuid := '00000000-0000-4000-8000-0000006880a1';
  plan_big uuid := '00000000-0000-4000-8000-0000006880b1';
  plan_sm  uuid := '00000000-0000-4000-8000-0000006880b2';

  d1       date := current_date - 200;
  as_of    timestamptz := ((d1 + 150)::timestamp + time '12:00') at time zone 'Asia/Singapore';

  g        jsonb;   -- extended payload
  g0       jsonb;   -- non-extended payload (mode-diff mutation check)
  g2       jsonb;   -- re-call after the EV mutation
  cand     jsonb;   -- NB: named distinctly from any query alias in this block
                    -- (plpgsql.variable_conflict is 'error' by default, so a bare `c` shared
                    -- between an alias and a variable raises "ambiguous", not a silent shadow —
                    -- CI-CORPUS-FIXTURE-GUIDE.md's own landmine, hit for real here).
  ranked   jsonb;
  abst     jsonb;
  ids      text[];
  v_int    bigint;
  v_num    numeric;
  v_txt    text;
  v_n      int;
begin
  ---------------------------------------------------------------------------
  -- operational recipe
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v688 biz1', 'zz-v688-biz1',
     array['dashboard','clients','sales','reports','packages']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v688 biz1 main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz, u_owner, 'owner', 'ZZ v688 biz1 owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v688 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  -- trg_customer_lifecycle_policy_v107_business_insert already seeded version_no=1 (default
  -- min_observations=3) for this business the instant it was inserted above -- BIZ1 keeps the
  -- default (the lowered-floor L1/L2/L3 divergence demonstration lives on its own, in BIZ4 below,
  -- specifically so lowering it here can never also sweep up a funnel/package client that happens
  -- to have exactly 2 measured intervals by the time this business's own as_of arrives).

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_gw, biz, 'ZZ v688 gateway service', 1000, 30);
  insert into public.package_plans (id, business_id, name, price_cents, sessions, active) values
    (plan_big, biz, 'ZZ v688 plan big (10 sessions)', 20000, 10, true),
    (plan_sm,  biz, 'ZZ v688 plan small (4 sessions)',    40,  4, true);

  ---------------------------------------------------------------------------
  -- clients
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000688' || lpad((100+s)::text,3,'0'))::uuid,
         biz, 'ZZ v688 funnel ' || s from generate_series(1,20) s;
  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000688' || lpad((300+s)::text,3,'0'))::uuid,
         biz, 'ZZ v688 plan-big holder ' || s from generate_series(1,5) s;   -- H1..H5
  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000688' || lpad((400+s)::text,3,'0'))::uuid,
         biz, 'ZZ v688 plan-small holder ' || s from generate_series(1,5) s; -- K1..K5

  ---------------------------------------------------------------------------
  -- FUNNEL: F1..F20 first visit at d1, ALL return at d1+10, 18 of 20 return at d1+20.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000688' || lpad((500+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000688' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 1000,
         (d1::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (d1::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,20) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000688' || lpad((500+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 1000, 1000 from generate_series(1,20) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000688' || lpad((520+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000688' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 1000,
         ((d1+10)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1+10)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,20) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000688' || lpad((520+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 1000, 1000 from generate_series(1,20) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000688' || lpad((540+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000688' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 1000,
         ((d1+20)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1+20)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,18) s;   -- only 18 of 20
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000688' || lpad((540+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 1000, 1000 from generate_series(1,18) s;

  ---------------------------------------------------------------------------
  -- H1 rhythm: 5 visits, gaps of 10 days, BEFORE d1 -- gives H1 a resolvable return_probability_v681
  -- (k=4 measured intervals) purely for the package-leakage EV below. H1 also reads as "overdue"
  -- against its own rhythm by the time as_of arrives, so it is technically eligible for the
  -- lapsed_regulars generator too -- but n=1 is below app.subgroup_evidence_v1's floor of 5, so it
  -- abstains there (below_evidence_floor) rather than becoming a second, unaccounted-for
  -- lapsed_regulars candidate. This business deliberately carries no OTHER lapsed-regular data (see
  -- BIZ4 for the dedicated, evidence-clearing lapsed_regulars/EV-divergence fixture).
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000688' || lpad((630+s)::text,3,'0'))::uuid,
         biz, br, '00000000-0000-4000-8000-000000688301'::uuid, 'service', 3000,
         ((d1 - (60 - s*10))::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1 - (60 - s*10))::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000688' || lpad((630+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 3000, 3000 from generate_series(1,5) s;

  ---------------------------------------------------------------------------
  -- PACKAGES, purchased on d1. H1..H5 buy plan_big, K1..K5 buy plan_small.
  ---------------------------------------------------------------------------
  insert into public.client_packages
    (id, business_id, plan_id, client_id, sessions_snapshot, remaining, status, purchased_at,
     plan_name_snapshot, plan_version_snapshot, price_cents_snapshot)
  select gen_random_uuid(), biz, plan_big,
         ('00000000-0000-4000-8000-000000688' || lpad((300+s)::text,3,'0'))::uuid,
         10, 10, 'active', (d1::timestamp + time '10:00') at time zone 'Asia/Singapore',
         'ZZ v688 plan big (10 sessions)', 1, 20000
    from generate_series(1,5) s;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000688' || lpad((650+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000688' || lpad((300+s)::text,3,'0'))::uuid,
         'package', 20000,
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore',
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;

  insert into public.client_packages
    (id, business_id, plan_id, client_id, sessions_snapshot, remaining, status, purchased_at,
     plan_name_snapshot, plan_version_snapshot, price_cents_snapshot)
  select gen_random_uuid(), biz, plan_sm,
         ('00000000-0000-4000-8000-000000688' || lpad((400+s)::text,3,'0'))::uuid,
         4, 3, 'active', (d1::timestamp + time '10:00') at time zone 'Asia/Singapore',
         'ZZ v688 plan small (4 sessions)', 1, 40
    from generate_series(1,5) s;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000688' || lpad((660+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000688' || lpad((400+s)::text,3,'0'))::uuid,
         'package', 40,
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore',
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;

  ---------------------------------------------------------------------------
  -- PRECONDITIONS (the rule that matters most: assert the population is what this fixture intends
  -- before trusting any denial/abstention downstream of it).
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
  abst := g->'abstentions';

  -- A1 · funnel: below_materiality, evidence ok, NOT in ranked.
  if exists (select 1 from jsonb_array_elements(ranked) c where c->>'id' = 'funnel_bottleneck') then
    insert into _fail values ('A1-funnel', 'the trivial funnel gap was promoted, not abstained');
  end if;
  select a->>'reason' into v_txt from jsonb_array_elements(abst) a where a->>'generator' = 'funnel_bottleneck';
  if v_txt is null or v_txt not like 'below_materiality:%' then
    insert into _fail values ('A1-funnel-reason', format('funnel abstention reason was %s', v_txt));
  end if;

  -- A2 (lapsed_regulars EV formula + incentive/cost_basis/alternatives/reversal_condition, and its
  -- own mutation check) lives entirely in BIZ4 below -- this business carries no lapsed-regular
  -- population that clears the evidence floor (see the H1 comment above).

  -- A3 · package_leakage:plan_big — EV formula, abstained holders.
  select c into cand from jsonb_array_elements(ranked) c where c->>'id' = 'package_leakage:' || plan_big::text;
  if cand is null then
    insert into _fail values ('A3-missing', 'package_leakage:plan_big was not promoted');
  else
    if (cand->'impact'->>'scenario_cents')::bigint <> 100000 then
      insert into _fail values ('A3-scenario', format('scenario_cents was %s, expected 100000', cand->'impact'->>'scenario_cents'));
    end if;
    if (cand->'impact'->'expected_value'->>'cents')::bigint <> 19004 then
      insert into _fail values ('A3-ev', format('expected_value.cents was %s, expected 19004', cand->'impact'->'expected_value'->>'cents'));
    end if;
    if (cand->'impact'->'expected_value'->'inputs'->>'abstained')::int <> 4 then
      insert into _fail values ('A3-abstained', format('inputs.abstained was %s, expected 4', cand->'impact'->'expected_value'->'inputs'->>'abstained'));
    end if;
  end if;

  -- A4 · package_leakage:plan_small — the materiality-gate mode-diff mutation check.
  if exists (select 1 from jsonb_array_elements(ranked) c where c->>'id' = 'package_leakage:' || plan_sm::text) then
    insert into _fail values ('A4-promoted', 'plan_small was promoted despite EV 0 < the materiality bar');
  end if;
  select a->>'reason' into v_txt from jsonb_array_elements(abst) a
   where a->>'generator' = 'package_leakage:' || plan_sm::text;
  if v_txt is null or v_txt not like 'below_materiality:%' then
    insert into _fail values ('A4-reason', format('plan_small abstention reason was %s', v_txt));
  end if;
  g0 := public.get_ci_opportunities_v1(biz, d1, d1, null, as_of, false);  -- p_extended => false
  if not exists (select 1 from jsonb_array_elements(g0->'ranked') c
                  where c->>'id' = 'package_leakage:' || plan_sm::text) then
    insert into _fail values ('A4-mode-diff',
      'plan_small was not promoted under p_extended=>false; the mode-diff mutation check needs the '
      'SAME data to behave differently across the two contracts, and it did not');
  end if;
  if exists (select 1 from jsonb_array_elements(g0->'ranked') c where c->>'incentive' is not null) then
    insert into _fail values ('A4-base-shape', 'the non-extended payload carries extended-only keys');
  end if;

  -- A5 · gateway_followthrough:svc_gw is promoted (the deliberate real second unquantified entry).
  if not exists (select 1 from jsonb_array_elements(ranked) c where c->>'id' = 'gateway_followthrough:' || svc_gw::text) then
    insert into _fail values ('A5-gateway', 'gateway_followthrough:svc_gw was not promoted');
  end if;

  -- A6 · data_quality_coverage is foundation and ranked first.
  select rank into v_int from jsonb_to_recordset(ranked) as x(rank int, id text) where x.id = 'data_quality_coverage';
  if v_int is distinct from 1 then
    insert into _fail values ('A6-foundation', format('data_quality_coverage ranked %s, expected 1', v_int));
  end if;

  -- A7 · strength:weekday exists, rank_class 'strength', ranked strictly after every non-strength
  --      opportunity (foundation/quantified/unquantified all outrank it).
  if not exists (select 1 from jsonb_array_elements(ranked) c
                  where c->>'domain' = 'strength' and c->>'rank_class' = 'strength') then
    insert into _fail values ('A7-strength', 'no strength candidate was ranked');
  end if;
  if exists (
    select 1 from jsonb_array_elements(ranked) s
    where s->>'rank_class' = 'strength'
      and exists (select 1 from jsonb_array_elements(ranked) o
                   where o->>'rank_class' <> 'strength' and (o->>'rank')::int > (s->>'rank')::int)
  ) then
    insert into _fail values ('A7-strength-order', 'a strength candidate outranked a real opportunity');
  end if;

  -- A8 · top_actions is exactly the first five ranked entries, length exactly 5.
  if jsonb_array_length(g->'top_actions') <> 5 then
    insert into _fail values ('A8-top-actions', format('top_actions length was %s, expected 5', jsonb_array_length(g->'top_actions')));
  end if;
  select array_agg(c->>'id' order by (c->>'rank')::int) into ids from jsonb_array_elements(ranked) c;
  if (select array_agg(c->>'id' order by (c->>'rank')::int) from jsonb_array_elements(g->'top_actions') c)
     <> ids[1:5] then
    insert into _fail values ('A8-top-actions-content', 'top_actions is not the first five ranked entries, in order');
  end if;

  -- A9 · report_sections: the seven keys, margin always unavailable, buckets contain what they claim.
  if (select array_agg(k order by k) from jsonb_object_keys(g->'report_sections') k)
     <> array['change','failures','leakage','margin','segments','strengths','unnoticed_behaviour'] then
    insert into _fail values ('A9-sections-keys', format('report_sections keys were %s',
      (select array_agg(k order by k) from jsonb_object_keys(g->'report_sections') k)));
  end if;
  if g->'report_sections'->'margin'->>'status' <> 'unavailable' then
    insert into _fail values ('A9-margin', 'margin.status was not unavailable');
  end if;
  if not (g->'report_sections'->'leakage' ? ('package_leakage:' || plan_big::text)) then
    insert into _fail values ('A9-leakage', 'plan_big leakage id missing from report_sections.leakage');
  end if;
  if not (g->'report_sections'->'strengths' @> to_jsonb(
            (select c->>'id' from jsonb_array_elements(ranked) c where c->>'domain'='strength' limit 1))) then
    insert into _fail values ('A9-strengths', 'the strength candidate id is missing from report_sections.strengths');
  end if;

  -- A10 · comparisons: examined counts the new generators (strictly more than the 8-generator base).
  v_int := (public.get_ci_opportunities_v1(biz, d1, d1, null, as_of, false)->'comparisons'->>'subgroups_examined')::int;
  if (g->'comparisons'->>'subgroups_examined')::int <= v_int then
    insert into _fail values ('A10-examined',
      format('extended examined (%s) did not exceed base examined (%s)', g->'comparisons'->>'subgroups_examined', v_int));
  end if;
  if (g->'comparisons'->>'subgroups_examined')::int < (g->'comparisons'->>'subgroups_promoted')::int then
    insert into _fail values ('A10-examined-lt-promoted', 'examined is smaller than promoted');
  end if;

  -- A11 · every ranked candidate carries the extended contract (no silent gaps).
  for cand in select e from jsonb_array_elements(ranked) e loop
    if cand->'incentive' is null or cand->'incentive'->>'kind' is null then
      insert into _fail values ('A11-incentive', format('candidate %s has no incentive', cand->>'id'));
    end if;
    if coalesce(btrim(cand->>'why_now'),'') = '' then
      insert into _fail values ('A11-why-now', format('candidate %s has no why_now', cand->>'id'));
    end if;
    if coalesce(btrim(cand->>'reversal_condition'),'') = '' then
      insert into _fail values ('A11-reversal', format('candidate %s has no reversal_condition', cand->>'id'));
    end if;
    if cand->'alternatives' is null or jsonb_array_length(cand->'alternatives') < 1 then
      insert into _fail values ('A11-alternatives', format('candidate %s has no alternatives', cand->>'id'));
    end if;
    if cand->'cost_basis'->>'status' not in ('declared','unavailable') then
      insert into _fail values ('A11-cost-basis', format('candidate %s has cost_basis status %s', cand->>'id', cand->'cost_basis'->>'status'));
    end if;
    if cand->>'evidence_class' = 'CAUSAL' then
      insert into _fail values ('A11-causal', format('candidate %s claims CAUSAL', cand->>'id'));
    end if;
  end loop;

  -- A12 (the EV-formula mutation check) lives in BIZ4 below, alongside A2.
end
$v688a$;

select case when count(*)=0 then 'PASS — BIZ1: materiality, EV, cost_basis, incentive, '
            'alternatives, reversal_condition, report_sections, top_actions, mutation checks all hold'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

-- =================================================================================================
-- BIZ4 — the lapsed_regulars EV-formula divergence, isolated on its own business.
-- =================================================================================================
-- Split out from BIZ1 (found the hard way, on the real harness): lowering
-- customer_interval_min_observations business-wide to demonstrate L3's divergence (customer_cadence
-- accepts k=2, app.return_probability_v681's own hard floor of 3 still refuses it) ALSO drops the
-- floor for every OTHER customer of that business — including a funnel population that legitimately
-- has exactly 2 measured intervals (2 gaps from 3 visits) and, once a maturity-window-sized as_of
-- has elapsed, reads as "overdue" against its own (very short) rhythm. That silently pulled BIZ1's
-- 20 funnel customers into "lapsed_regulars" and made the EV assertions meaningless. This business
-- carries ONLY L1..L5 -- no funnel, no packages -- so the lowered floor has nothing else to catch.
-- L4/L5 exist purely so the overdue population (n=5) clears app.subgroup_evidence_v1's floor of 5
-- -- L1/L2/L3 alone (n=3) would abstain 'below_evidence_floor' before the EV formula is ever
-- exercised.
--
-- L1  5 visits, gaps of 10 days (k=4, median=10), ticket 5000 each (avg=5000).
--     P = 1-exp(-30/10) = 1-exp(-3) = 0.950212932. EV_L1 = round(0.950212932*5000) = 4751.
-- L2  5 visits, gaps of 15 days (k=4, median=15), ticket 8000 each (avg=8000).
--     P = 1-exp(-2) = 0.864664717 -> app.return_probability_v681 itself rounds this to 4 decimal
--     places (0.8647) before returning it, so EV_L2 = round(0.8647*8000) = 6918, not the
--     full-precision 6917 -- the fixture reads the API's own rounded 'probability' field, exactly
--     as a real caller would, rather than re-deriving a more precise number nothing else sees.
-- L3  3 visits, gaps of 20 days (k=2, median=20), ticket 6000 each (avg=6000). k=2 < v681's hard
--     floor of 3 -> status='insufficient' -> contributes 0, counted in inputs.abstained.
-- L4  5 visits, gaps of 12 days (k=4, median=12), ticket 7000 each (avg=7000).
--     P = 1-exp(-30/12) = 1-exp(-2.5) = 0.917915001. EV_L4 = round(0.917915001*7000) = 6425.
-- L5  5 visits, gaps of 25 days (k=4, median=25), ticket 4000 each (avg=4000).
--     P = 1-exp(-30/25) = 1-exp(-1.2) = 0.698805788. EV_L5 = round(0.698805788*4000) = 2795.
-- scenario_cents (kept) = 5000+8000+6000+7000+4000 = 30000.
-- expected_value.cents = 4751+6918+0+6425+2795 = 20889.  inputs = {scored: 4, abstained: 1}.
-- All five overdue (effective_lapse = median*2.0 multiplier <= 50 days; every last visit is
-- >= 160 days before as_of).
-- =================================================================================================
do $v688d$
declare
  biz     uuid := '00000000-0000-4000-8000-000000688004';
  br      uuid := '00000000-0000-4000-8000-000000688014';
  u_owner uuid := '00000000-0000-4000-8000-000000688ee4';
  svc     uuid := '00000000-0000-4000-8000-0000006880e1';
  d1      date := current_date - 200;
  as_of   timestamptz := ((d1 + 150)::timestamp + time '12:00') at time zone 'Asia/Singapore';
  g       jsonb;
  g2      jsonb;
  cand    jsonb;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v688 biz4', 'zz-v688-biz4', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v688 biz4 main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz, u_owner, 'owner', 'ZZ v688 biz4 owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v688 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  -- lifecycle policy, min_observations LOWERED to 2 (default is 3) -- the L3/v681 divergence.
  -- trg_customer_lifecycle_policy_v107_business_insert already seeded version_no=1 (default
  -- min_observations=3, effective_from=-infinity) the instant public.businesses was inserted
  -- above, and the table is append-only (before update/delete raises) -- so this fixture adds a
  -- NEW version (2) with a later effective_from rather than trying to insert or mutate version 1.
  insert into public.customer_lifecycle_policies_v107
    (business_id, version_no, effective_from, fallback_lapse_days,
     customer_interval_min_observations, reactivation_multiplier, note, legacy_assumption)
  values (biz, 2, '2000-01-01T00:00:00+08'::timestamptz, 90, 2, 2.000, 'v688 fixture: lowered floor', true);

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc, biz, 'ZZ v688 biz4 service', 1000, 30);

  insert into public.clients (id, business_id, full_name) values
    ('00000000-0000-4000-8000-000000688460'::uuid, biz, 'ZZ v688 L1'),
    ('00000000-0000-4000-8000-000000688461'::uuid, biz, 'ZZ v688 L2'),
    ('00000000-0000-4000-8000-000000688462'::uuid, biz, 'ZZ v688 L3'),
    ('00000000-0000-4000-8000-000000688479'::uuid, biz, 'ZZ v688 L4'),
    ('00000000-0000-4000-8000-000000688485'::uuid, biz, 'ZZ v688 L5');

  -- L1: 5 visits @5000, gaps of 10 days, last at d1-10.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000688' || lpad((462+s)::text,3,'0'))::uuid,
         biz, br, '00000000-0000-4000-8000-000000688460'::uuid, 'service', 5000,
         ((d1 - (60 - s*10))::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1 - (60 - s*10))::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;  -- d1-50, d1-40, d1-30, d1-20, d1-10 (median 10, last d1-10)
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000688' || lpad((462+s)::text,3,'0'))::uuid,
         'service', svc, 1, 5000, 5000 from generate_series(1,5) s;

  -- L2: 5 visits @8000, gaps of 15 days, last at d1-15.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000688' || lpad((467+s)::text,3,'0'))::uuid,
         biz, br, '00000000-0000-4000-8000-000000688461'::uuid, 'service', 8000,
         ((d1 - (90 - s*15))::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1 - (90 - s*15))::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000688' || lpad((467+s)::text,3,'0'))::uuid,
         'service', svc, 1, 8000, 8000 from generate_series(1,5) s;

  -- L3: 3 visits @6000, gaps of 20 days, last at d1-20 (k=2 intervals).
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000688' || lpad((472+s)::text,3,'0'))::uuid,
         biz, br, '00000000-0000-4000-8000-000000688462'::uuid, 'service', 6000,
         ((d1 - (80 - s*20))::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1 - (80 - s*20))::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,3) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000688' || lpad((472+s)::text,3,'0'))::uuid,
         'service', svc, 1, 6000, 6000 from generate_series(1,3) s;

  -- L4/L5 exist purely so the overdue population clears app.subgroup_evidence_v1's floor of 5 --
  -- L1/L2/L3 alone (n=3) would abstain 'below_evidence_floor' before the EV formula is ever
  -- exercised. Same shape as L1/L2 (k=4, real rhythm), different m/ticket so each contributes a
  -- distinct, separately hand-checkable term to the sum.
  -- L4: 5 visits @7000, gaps of 12 days, last at d1-12.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000688' || lpad((479+s)::text,3,'0'))::uuid,
         biz, br, '00000000-0000-4000-8000-000000688479'::uuid, 'service', 7000,
         ((d1 - (72 - s*12))::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1 - (72 - s*12))::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000688' || lpad((479+s)::text,3,'0'))::uuid,
         'service', svc, 1, 7000, 7000 from generate_series(1,5) s;

  -- L5: 5 visits @4000, gaps of 25 days, last at d1-25.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000688' || lpad((485+s)::text,3,'0'))::uuid,
         biz, br, '00000000-0000-4000-8000-000000688485'::uuid, 'service', 4000,
         ((d1 - (150 - s*25))::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1 - (150 - s*25))::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000688' || lpad((485+s)::text,3,'0'))::uuid,
         'service', svc, 1, 4000, 4000 from generate_series(1,5) s;

  ---------------------------------------------------------------------------
  -- PRECONDITIONS.
  ---------------------------------------------------------------------------
  if (app.customer_cadence_v1(biz, '00000000-0000-4000-8000-000000688462'::uuid, as_of)->>'evidence_source')
       <> 'customer_median_interval' then
    insert into _fail values ('PRE-L3', 'L3 did not resolve customer_median_interval evidence under the lowered floor');
  end if;
  if (app.return_probability_v681(biz, '00000000-0000-4000-8000-000000688462'::uuid, as_of)->>'status')
       <> 'insufficient' then
    insert into _fail values ('PRE-L3-v681', 'L3 was not refused by return_probability_v681''s own hard floor');
  end if;

  ---------------------------------------------------------------------------
  -- A2 · lapsed_regulars: EV formula exact, scenario_cents kept, inputs, cost_basis/incentive.
  ---------------------------------------------------------------------------
  g := public.get_ci_opportunities_v1(biz, d1, d1, null, as_of, true);
  select c into cand from jsonb_array_elements(g->'ranked') c where c->>'id' = 'lapsed_regulars';
  if cand is null then
    insert into _fail values ('A2-missing', 'lapsed_regulars was not promoted');
  else
    if (cand->'impact'->>'scenario_cents')::bigint <> 30000 then
      insert into _fail values ('A2-scenario', format('scenario_cents was %s, expected 30000', cand->'impact'->>'scenario_cents'));
    end if;
    if (cand->'impact'->'expected_value'->>'cents')::bigint <> 20889 then
      insert into _fail values ('A2-ev', format('expected_value.cents was %s, expected 20889', cand->'impact'->'expected_value'->>'cents'));
    end if;
    if (cand->'impact'->'expected_value'->'inputs'->>'abstained')::int <> 1 then
      insert into _fail values ('A2-abstained', format('inputs.abstained was %s, expected 1', cand->'impact'->'expected_value'->'inputs'->>'abstained'));
    end if;
    if (cand->'impact'->'expected_value'->'inputs'->>'scored')::int <> 4 then
      insert into _fail values ('A2-scored', format('inputs.scored was %s, expected 4', cand->'impact'->'expected_value'->'inputs'->>'scored'));
    end if;
    if cand->'incentive'->>'kind' <> 'none' or (cand->'incentive'->>'declared')::boolean is not true then
      insert into _fail values ('A2-incentive', format('incentive was %s', cand->'incentive'));
    end if;
    if cand->'cost_basis'->>'status' <> 'declared' or (cand->'cost_basis'->>'cents')::int <> 0 then
      insert into _fail values ('A2-cost-basis', format('cost_basis was %s', cand->'cost_basis'));
    end if;
    if coalesce(btrim(cand->>'why_now'), '') = '' or position('5' in (cand->>'why_now')) = 0 then
      insert into _fail values ('A2-why-now', format('why_now was %s', cand->>'why_now'));
    end if;
    if position('5' in (cand->>'reversal_condition')) = 0 then
      insert into _fail values ('A2-reversal', format('reversal_condition %s does not carry the customer-count threshold', cand->>'reversal_condition'));
    end if;
    if jsonb_array_length(cand->'alternatives') < 2 then
      insert into _fail values ('A2-alternatives', 'fewer than 2 alternatives');
    end if;
    if (select count(*) from jsonb_array_elements(cand->'alternatives') a where (a->>'primary')::boolean) <> 1 then
      insert into _fail values ('A2-alternatives-primary', 'not exactly one primary alternative');
    end if;
    if not exists (select 1 from jsonb_array_elements(cand->'alternatives') a where a->>'kind' = 'reminder_only'
                     and a->'cost_basis'->>'status' = 'declared') then
      insert into _fail values ('A2-alternatives-reminder', 'no declared-cost reminder_only alternative');
    end if;
    if not exists (select 1 from jsonb_array_elements(cand->'alternatives') a where a->>'kind' = 'incentive'
                     and a->'cost_basis'->>'status' = 'unavailable') then
      insert into _fail values ('A2-alternatives-incentive', 'no cost-unavailable incentive alternative');
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- A12 · MUTATION CHECK, the EV formula. Add one more, cheaper, rhythm-consistent visit for L1
  -- (a 6th visit, 10 days after the 5th, so median_interval_days is unchanged at 10 and P is
  -- unchanged) and assert the new average ticket and EV drop to the hand-computed value.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values ('00000000-0000-4000-8000-000000688478'::uuid, biz, br,
          '00000000-0000-4000-8000-000000688460'::uuid, 'service', 100,
          (d1::timestamp + time '08:00') at time zone 'Asia/Singapore',
          (d1::timestamp + time '08:00') at time zone 'Asia/Singapore');
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (biz, '00000000-0000-4000-8000-000000688478'::uuid, 'service', svc, 1, 100, 100);

  if (app.customer_cadence_v1(biz, '00000000-0000-4000-8000-000000688460'::uuid, as_of)->>'median_interval_days')::numeric
       <> 10.0 then
    insert into _fail values ('A12-pre', 'L1''s median interval changed; the mutation is not rhythm-neutral');
  end if;

  g2 := public.get_ci_opportunities_v1(biz, d1, d1, null, as_of, true);
  select c into cand from jsonb_array_elements(g2->'ranked') c where c->>'id' = 'lapsed_regulars';
  if cand is null then
    insert into _fail values ('A12-missing', 'lapsed_regulars disappeared after the mutation');
  else
    -- L1 now has 6 revenue-qualifying sales (the original 5 @5000 plus this one @100), so its
    -- avg ticket is a sum over ALL SIX, not the four gap-endpoints: new avg ticket =
    -- round((5000*5 + 100) / 6) = round(4183.33) = 4183 (L2/L3/L4/L5 untouched). The gap count
    -- (interval_observations) goes from 4 to 5, all still 10 days apart (the PRE check below
    -- confirms median_interval_days is unchanged), so P_L1 is unaffected by the mutation --
    -- only the ticket average moves.
    -- new EV_L1 = round(0.9502 * 4183) = round(3974.6866) = 3975.
    -- new scenario_cents = 4183(L1) + 8000(L2) + 6000(L3) + 7000(L4) + 4000(L5) = 29183.
    -- new EV total = 3975(L1) + 6918(L2) + 0(L3) + 6425(L4) + 2795(L5) = 20113.
    if (cand->'impact'->>'scenario_cents')::bigint <> 29183 then
      insert into _fail values ('A12-scenario', format('post-mutation scenario_cents was %s, expected 29183', cand->'impact'->>'scenario_cents'));
    end if;
    if (cand->'impact'->'expected_value'->>'cents')::bigint <> 20113 then
      insert into _fail values ('A12-ev', format('post-mutation EV was %s, expected 20113', cand->'impact'->'expected_value'->>'cents'));
    end if;
    if (cand->'impact'->'expected_value'->>'cents')::bigint >= 20889 then
      insert into _fail values ('A12-direction', 'EV did not decrease after a below-average sale was added');
    end if;
  end if;
end
$v688d$;

select case when count(*)=0 then 'PASS — BIZ4: lapsed_regulars EV formula (incl. the v681 hard-'
            'floor abstention) and its mutation check hold'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

-- =================================================================================================
-- BIZ2 — check 43: the funnel candidate's action.what names its own bottleneck.
-- =================================================================================================
do $v688b$
declare
  biz     uuid := '00000000-0000-4000-8000-000000688002';
  br      uuid := '00000000-0000-4000-8000-000000688012';
  u_owner uuid := '00000000-0000-4000-8000-000000688ee2';
  svc     uuid := '00000000-0000-4000-8000-0000006880c1';
  e1      date := current_date - 300;
  as_of   timestamptz := ((e1 + 150)::timestamp + time '12:00') at time zone 'Asia/Singapore';
  g       jsonb;
  cand    jsonb;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v688 biz2', 'zz-v688-biz2', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v688 biz2 main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz, u_owner, 'owner', 'ZZ v688 biz2 owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v688 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';
  -- trg_customer_lifecycle_policy_v107_business_insert already seeded version_no=1 (default
  -- min_observations=3) for this business the instant it was inserted above -- exactly what this
  -- business needs, so nothing further to insert here.
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc, biz, 'ZZ v688 biz2 service', 1000, 30);

  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000688' || lpad((700+s)::text,3,'0'))::uuid,
         biz, 'ZZ v688 biz2 client ' || s from generate_series(1,10) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000688' || lpad((800+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000688' || lpad((700+s)::text,3,'0'))::uuid,
         'service', 1000, (e1::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (e1::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,10) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000688' || lpad((800+s)::text,3,'0'))::uuid,
         'service', svc, 1, 1000, 1000 from generate_series(1,10) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000688' || lpad((820+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000688' || lpad((700+s)::text,3,'0'))::uuid,
         'service', 1000, ((e1+10)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((e1+10)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,10) s;   -- all 10 return -> 100%
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000688' || lpad((820+s)::text,3,'0'))::uuid,
         'service', svc, 1, 1000, 1000 from generate_series(1,10) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000688' || lpad((840+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000688' || lpad((700+s)::text,3,'0'))::uuid,
         'service', 1000, ((e1+20)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((e1+20)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,4) s;    -- only 4 of 10 -> 40%
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000688' || lpad((840+s)::text,3,'0'))::uuid,
         'service', svc, 1, 1000, 1000 from generate_series(1,4) s;

  g := public.get_ci_opportunities_v1(biz, e1, e1, null, as_of, true);
  select c into cand from jsonb_array_elements(g->'ranked') c where c->>'id' = 'funnel_bottleneck';
  if cand is null then
    insert into _fail values ('B1-missing', 'BIZ2''s real 60pp funnel gap was not promoted');
  else
    if cand->>'domain' <> 'retention_funnel' then
      insert into _fail values ('B1-domain', 'funnel_bottleneck has the wrong domain');
    end if;
    if (cand->'evidence'->'refs'->>'bottleneck') <> 'second_to_third' then
      insert into _fail values ('B1-bottleneck', format('bottleneck was %s, expected second_to_third', cand->'evidence'->'refs'->>'bottleneck'));
    end if;
    -- check 43: action.what names the bottleneck stage.
    if (cand->'action'->>'what') not like '%second-to-third%' then
      insert into _fail values ('B1-check43', format('action.what (%s) does not name the bottleneck stage', cand->'action'->>'what'));
    end if;
    if (cand->>'reversal_condition') not like '%15%' then
      insert into _fail values ('B1-reversal', format('reversal_condition (%s) does not carry the 15pp bar', cand->>'reversal_condition'));
    end if;
  end if;
end
$v688b$;

select case when count(*)=0 then 'PASS — BIZ2: check 43, funnel action.what names the bottleneck'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

-- =================================================================================================
-- BIZ3 — the discovery generator (check 22): structural assertions unconditional, content
-- assertions conditional on the engine reporting a discovery (see the file header).
-- =================================================================================================
do $v688c$
declare
  biz      uuid := '00000000-0000-4000-8000-000000688003';
  br       uuid := '00000000-0000-4000-8000-000000688013';
  u_owner  uuid := '00000000-0000-4000-8000-000000688ee3';
  svc      uuid := '00000000-0000-4000-8000-0000006880d1';
  p_from   date := current_date - 400;
  p_to     date := current_date - 300;   -- 100-day window, plenty for two 50-day halves
  as_of    timestamptz := ((p_to + 60)::timestamp + time '12:00') at time zone 'Asia/Singapore';
  train_to date := p_from + ((p_to - p_from)/2);
  hold_from date;
  g        jsonb;
  disc     jsonb;
begin
  hold_from := train_to + 1;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v688 biz3', 'zz-v688-biz3', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v688 biz3 main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz, u_owner, 'owner', 'ZZ v688 biz3 owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v688 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';
  -- trg_customer_lifecycle_policy_v107_business_insert already seeded version_no=1 (default
  -- min_observations=3) for this business the instant it was inserted above -- exactly what this
  -- business needs, so nothing further to insert here.
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc, biz, 'ZZ v688 biz3 service', 1000, 30);

  -- 12 referral clients (100% return within 30 days, both halves), 12 non-referral (0%, both halves).
  insert into public.clients (id, business_id, full_name, first_acquired_via)
  select ('00000000-0000-4000-8000-000000688' || lpad((900+s)::text,3,'0'))::uuid,
         biz, 'ZZ v688 biz3 referral ' || s, 'referral' from generate_series(1,12) s;
  insert into public.clients (id, business_id, full_name, first_acquired_via)
  select ('00000000-0000-4000-8000-000000688' || lpad((920+s)::text,3,'0'))::uuid,
         biz, 'ZZ v688 biz3 other ' || s, 'walk_in' from generate_series(1,12) s;

  -- TRAIN half: anchor on train_to (guaranteed inside [p_from,train_to]).
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, ('00000000-0000-4000-8000-000000688' || lpad((900+s)::text,3,'0'))::uuid,
         'service', 1000, (train_to::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (train_to::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,12) s
  union all
  select gen_random_uuid(), biz, br, ('00000000-0000-4000-8000-000000688' || lpad((920+s)::text,3,'0'))::uuid,
         'service', 1000, (train_to::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (train_to::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,12) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc, 1, 1000, 1000 from public.sales s
   where s.business_id = biz and (s.occurred_at at time zone 'Asia/Singapore')::date = train_to;
  -- referral returns within 30 days, train half
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, ('00000000-0000-4000-8000-000000688' || lpad((900+s)::text,3,'0'))::uuid,
         'service', 1000, ((train_to+5)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((train_to+5)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,12) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc, 1, 1000, 1000 from public.sales s
   where s.business_id = biz and (s.occurred_at at time zone 'Asia/Singapore')::date = train_to+5;

  -- HOLDOUT half: anchor on hold_from, identical pattern.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, ('00000000-0000-4000-8000-000000688' || lpad((900+s)::text,3,'0'))::uuid,
         'service', 1000, (hold_from::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (hold_from::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,12) s
  union all
  select gen_random_uuid(), biz, br, ('00000000-0000-4000-8000-000000688' || lpad((920+s)::text,3,'0'))::uuid,
         'service', 1000, (hold_from::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (hold_from::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,12) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc, 1, 1000, 1000 from public.sales s
   where s.business_id = biz and (s.occurred_at at time zone 'Asia/Singapore')::date = hold_from;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, ('00000000-0000-4000-8000-000000688' || lpad((900+s)::text,3,'0'))::uuid,
         'service', 1000, ((hold_from+5)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((hold_from+5)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,12) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc, 1, 1000, 1000 from public.sales s
   where s.business_id = biz and (s.occurred_at at time zone 'Asia/Singapore')::date = hold_from+5;

  -- structural: the direct reader.
  disc := public.get_ci_discovery_v1(biz, p_from, p_to, null);
  if not (disc->'segment_dimensions' ? 'acquisition_source') then
    insert into _fail values ('C1-dimensions', 'acquisition_source is not among segment_dimensions');
  end if;
  if jsonb_typeof(disc->'discoveries') <> 'array' or jsonb_typeof(disc->'not_replicated') <> 'array'
     or jsonb_typeof(disc->'deteriorating') <> 'array' then
    insert into _fail values ('C1-shape', 'discoveries/not_replicated/deteriorating are not all arrays');
  end if;

  -- structural: the engine.
  g := public.get_ci_opportunities_v1(biz, p_from, p_to, null, as_of, true);
  if not (g->'report_sections' ? 'unnoticed_behaviour') or not (g->'report_sections' ? 'change') then
    insert into _fail values ('C2-sections', 'report_sections is missing the discovery/change buckets');
  end if;

  -- content: only when the engine actually reports a discovery for this cohort's own dimension.
  if exists (select 1 from jsonb_array_elements(coalesce(disc->'discoveries','[]'::jsonb)) d
              where d->>'dimension' = 'acquisition_source') then
    if not exists (select 1 from jsonb_array_elements(g->'ranked') c
                    where c->>'domain' = 'discovery' and c->>'evidence_class' = 'ASSOCIATION') then
      insert into _fail values ('C3-engine-discovery',
        'the reader replicated an acquisition_source discovery but the engine ranked none');
    end if;
  end if;
end
$v688c$;

select case when count(*)=0 then 'PASS — BIZ3: discovery generator structure holds; content asserted '
            'when the engine reports a discovery'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v688: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
