-- EXECUTED acceptance fixture for nestly_v705 — the consultant spine v3.
--
-- Above the v422 watermark: reported n/a in the BASELINE phase, gated on the MIGRATED run
-- (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- Proves db/migrations/20260920_nestly_v705_spine_v3.sql closes checks 22 (campaigns generator),
-- 23 (materiality threshold + classification), 25 (capacity), 66 (concentration surfacing), 74
-- (margin guard), 77 (rebooking + operational_change alternatives).
--
-- =================================================================================================
-- PREDETERMINED TRUTH TABLE (every number below computed before the first run)
-- =================================================================================================
--
-- A. app.ci_margin_guard_v705 (check 74), BIZ_MG, direct calls (no spine, no operational recipe
--    needed — the function is an internal helper with no access gate):
--    SVC_COSTED  price_cents=5000, cost_cents=2000 -> margin=3000.
--      ci_margin_guard_v705(biz, svc_costed, 4000)  -> status='blocked', margin_cents=3000,
--        reason mentions "incentive 4000 cents would exceed the 3000-cent margin (price 5000,
--        cost 2000)". NOTE the brief's own worked example (price 5000/cost 2000/incentive 4000)
--        computes margin=3000, not 2000 — 5000-2000=3000 is the correct arithmetic, so this fixture
--        asserts the ARITHMETICALLY CORRECT margin (3000) rather than reproducing the brief's typo.
--      ci_margin_guard_v705(biz, svc_costed, 1000)  -> status='ok', margin_cents=3000 (1000<=3000).
--    SVC_NOCOST  price_cents=5000, cost_cents=NULL.
--      ci_margin_guard_v705(biz, svc_nocost, 1000)  -> status='unavailable', margin_cents=null,
--        reason EXACTLY 'no cost recorded for this service; enter costs in Settings'.
--    ci_margin_guard_v705(biz, null, 1000) -> status='unavailable', reason EXACTLY
--        'no service specified for this incentive'.
--
-- B. app.ci_capacity_v705 (check 25), BIZ_CAP direct calls:
--    One staff member, weekday=1 (Tuesday, dow=2 is Tue in Postgres extract(dow) where 0=Sunday —
--    weekday column is smallint 0-6, matched against extract(dow); we pick weekday=2 to mean
--    Tuesday and pick p_from/p_to spanning EXACTLY 2 Tuesdays), staff_hours 09:00-13:00 (4 hours =
--    240 minutes) each Tuesday. p_from/p_to is a 14-day window containing exactly 2 Tuesdays (dow=2)
--    -> available_minutes = 240 * 2 = 480. Two completed appointments of 90 minutes each on those
--    Tuesdays -> booked_minutes = 180. pct = round(100*180/480, 1) = 37.5.
--    BIZ_CAP0 (same shape, zero staff_hours rows at all): ci_capacity_v705 returns
--      {status:'unavailable', reason:'no staff schedule rows recorded'}.
--
-- C. Materiality (check 23), BIZ_CORE (full spine, p_extended=>true, single-day window [d1,d1]):
--    app.ci_materiality_threshold_bps_v705() = 100 directly.
--    PLAN_BIG (price 20000/10 sessions, 5 holders H1..H5, H1 rhythm-established exactly as
--      nestly_v688's own BIZ1 fixture — 5 visits @3000, 10-day gaps, before d1): EV = round(10 *
--      2000 * 0.950212932) = 19004 (H2..H5 abstain, contribute 0). This EV is NON-NULL and, by the
--      PRE-EXISTING v688 EV-materiality gate, must ALSO be >= v_ev_bar (round(period_revenue*1%))
--      to survive to ranking at all — the two gates share the same 1% bar, so any EV-bearing
--      candidate that reaches ranking is, by construction, 'material' here (see this migration's
--      header note on why 'minor' cannot come from an EV-bearing candidate sharing this bar,
--      hence BIZ_MINOR below for a real 'minor' example). Asserted: materiality.numerator=19004,
--      materiality.denominator = the ACTUAL period revenue this business's window resolves to
--      (read back from a second, independent hand-count — see the fixture body), materiality_class
--      = 'material'.
--    gateway_followthrough:<svc_gw> (from the same funnel population as v688's BIZ1 — F1..F20 buy
--      svc_gw at d1, all return at d1+10, 18/20 return at d1+20; svc_gw's window-scoped repeat rate
--      is 0% against the firm's 100%, so it fires): impact.cents is null and expected_value.status
--      is 'unavailable' (no behavioural model), so materiality.numerator is null and
--      materiality_class = 'unquantified'. This, plus category_concentration (below, also
--      'unquantified' — its impact.cents is always null by generator D's own design), plus
--      package_leakage:<plan_big> ('material'), gives real, structurally distinct examples of two
--      of the three classes from the SAME real ranked payload.
--    EVERY candidate in the extended ranked array carries BOTH 'materiality' (an object with
--      numerator/denominator/pct) and 'materiality_class' (one of material/minor/unquantified) —
--      asserted generically, not just for the two named above.
--
-- D. Materiality 'minor' (check 23), BIZ_MINOR (full spine, dedicated, isolated business): ONE
--    package plan (price_cents=4, sessions=2), 5 holders M1..M5, none with any other sale ever (so
--    app.return_probability_v681 abstains for every one -> EV=0 exactly). This is the ONLY revenue
--    in the window: period_revenue = 5*4 = 20 cents. v_ev_bar = round(20*0.01) = round(0.2) = 0.
--    EV cents (0) >= v_ev_bar (0) -> survives the pre-existing v688 EV-materiality gate (0 is not
--    < 0). materiality.numerator=0, materiality.denominator=20, materiality.pct=0.0,
--    materiality_class = 'minor' (0 bps < the 100 bps bar) — a REAL candidate from a REAL RPC call,
--    not a reimplementation, in the class that BIZ_CORE structurally cannot produce.
--
-- E. Category concentration (check 66), BIZ_CORE: 5 customers (W the whale, O1..O4) each buy ONE
--    retail item (item_type='retail', no product_canonical_map row -> falls back to the 'generic'
--    pack's 'retail_product' node, the only category in this business, so it is trivially "the top
--    category" and its OWN share of classified revenue is 100% by construction — a fact orthogonal
--    to the per-CUSTOMER distribution this check is actually about). W pays 60000 cents, O1..O4 pay
--    10000 cents each. Total classified revenue = 100000. app.distribution_block_v1 on
--    [60000,10000,10000,10000,10000]: n=5, mean=20000, median=10000, top1_share_bps =
--    10000*60000/100000 = 6000 (>=3000 -> skew_material=true independent of the mean/median ratio,
--    which is ALSO >=1.5 here: 20000/10000=2.0). mean_excl_top1 = (100000-60000)/4 = 10000.00.
--    skew_note = 'top customer carries 60.0% of this category; the mean overstates the typical
--    customer' (round(6000::numeric/100,1) = 60.0) — asserted VERBATIM, string equality.
--    category_concentration candidate: concentration.top1_share_bps=6000,
--    concentration.mean_excl_top1=10000.00, concentration.skew_note matches the reader's own
--    skew_note VERBATIM, and candidate.pattern contains 'Its top customer alone accounts for 60.0%
--    of the category.'.
--
-- F. Campaigns (check 22), BIZ_CORE: 6 clients sent a 'promotion' campaign (channel='web_push') at
--    d1 (= current_date - 200, so the 30-day maturity window has long elapsed against real now()).
--    4 of the 6 make a purchase within 30 days (sale at d1+5); 2 do not. matured=6 (all mature),
--    returned=4. associated_purchase.rate = {numerator:4, denominator:6, pct:66.7}, evidence
--    n=6>=floor(5) -> status ok -> the 'campaigns' candidate FIRES: evidence_class 'ASSOCIATION'
--    (agreeing with app.ci_verdict_class_v696('campaigns')), limitation contains 'Incremental
--    effect is unavailable', pattern/comparison reproduce 66.7%/4/6 exactly. A SECOND business
--    (BIZ_CAMPAIGN_ABSTAIN) sends to only 3 clients (below the floor of 5) -> NO campaigns
--    candidate is emitted; an abstention with generator='campaigns' exists instead.
--
-- G. Daypart operational_change alternative (check 77), BIZ_DAYPART: a 14-day window containing
--    both a Monday (10 visits @1000 cents = revenue_per_visit 1000, the busiest day by volume) and
--    a Thursday (5 visits @4000 cents = revenue_per_visit 4000, the most valuable day; ratio 4.0x >=
--    the 2.0x bar). daypart_shift fires (domain='daypart'). Asserted: its alternatives array
--    contains a THIRD entry, kind='operational_change', naming both weekdays in its 'what' text,
--    cost_basis {status:'declared',cents:0}.
--
-- H. Cadence rebooking alternative (check 77), BIZ_CADENCE: L1..L5 (nestly_v688 BIZ4's shape, with
--    ONE deliberate change: L3 here is 4x@6000/20d gaps (k=3 intervals), not v688 BIZ4's 3x@6000/20d
--    (k=2) — this fixture does NOT lower customer_interval_min_observations (unlike v688 BIZ4, which
--    lowered it to 2 specifically to demonstrate a k=2 divergence this fixture doesn't need), so
--    under the DEFAULT floor of 3, k=2 would not resolve evidence_source='customer_median_interval'
--    at all and the overdue population would be only 4, one short of the n=5 sample floor. L1
--    5x@5000/10d gaps, L2 5x@8000/15d, L3 4x@6000/20d, L4 5x@7000/12d, L5 5x@4000/25d; all overdue
--    by as_of=d1+150) -> lapsed_regulars fires
--    (domain='cadence', n=5>=floor). SEPARATELY, in the SAME business/window [d1,d1]: 5 "rebooked"
--    appointments (booked_from_appointment_id set via public.link_rebooked_appointment_v1) and 5
--    "other" appointments (not linked), all completed at d1 (>=60 days before real now(), so
--    mature against get_ci_rebooking_v1's own now()-based window), 3 of the 5 rebooked returning
--    within 60 days and 1 of the 5 other returning within 60 days — exactly nestly_v683's own
--    proven recipe (db/tests/executed/v683_corpus_behavioural_authorities.sql, check 51). This
--    resolves cohorts.rebooked_at_departure.within_window = {numerator:3,denominator:5,pct:60.0},
--    evidence n_mature=5>=floor -> status ok. Asserted: lapsed_regulars' alternatives array
--    contains a THIRD entry, kind='rebooking', naming '60.0%' (n=5) and the other cohort's own
--    within_window pct (20.0%) in its 'what' text, cost_basis {status:'declared',cents:0}.
--
-- I. Alternatives kind superset (check 77): across BIZ_DAYPART + BIZ_CADENCE + BIZ_CORE's
--    gateway_followthrough (service_intelligence -> service_recovery, unchanged from v688) +
--    every candidate's ubiquitous reminder_only/incentive, the UNION of alternatives[*].kind across
--    all ranked candidates observed by this fixture is a superset of
--    {reminder_only, rebooking, service_recovery, operational_change, incentive}.
--
-- =================================================================================================
-- LANDMINES HANDLED (learned from docs/qa/CI-CORPUS-FIXTURE-GUIDE.md and the v678/v683/v688/v696
-- fixtures; not re-discovered here)
-- =================================================================================================
--  * created_at pinned to occurred_at/purchased_at on every backdated row.
--  * counts_as_revenue / counts_as_visit are NEVER passed on insert — they are trigger-resolved.
--  * the operational recipe (workspace controls + subscription lifecycle + subscriptions +
--    reporting_contract_versions_v106 backdated) is required for every business that calls the
--    full public.get_ci_opportunities_v1 RPC (app.ci_margin_guard_v705 / app.ci_capacity_v705 do
--    NOT gate, so BIZ_MG/BIZ_CAP/BIZ_CAP0 skip this).
--  * link_rebooked_appointment_v1 needs a real staff/owner JWT session, not the platform SA one —
--    switched briefly, then switched back, exactly as v683's own fixture does.
--  * every assertion of a denial/abstention first checks the population it rests on is what this
--    fixture intends (the "assert your preconditions" rule).

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000705ee1', 'zz-v705-owner1@example.test'),
  ('00000000-0000-4000-8000-000000705ee2', 'zz-v705-owner2@example.test'),
  ('00000000-0000-4000-8000-000000705ee3', 'zz-v705-owner3@example.test'),
  ('00000000-0000-4000-8000-000000705ee4', 'zz-v705-owner4@example.test'),
  ('00000000-0000-4000-8000-000000705ee5', 'zz-v705-owner5@example.test'),
  ('00000000-0000-4000-8000-000000705ee6', 'zz-v705-owner6@example.test'),
  ('00000000-0000-4000-8000-000000705eee', 'zz-v705-sa@example.test')
  on conflict (id) do nothing;
insert into public.super_admins (user_id, email) values
  ('00000000-0000-4000-8000-000000705eee', 'zz-v705-sa@example.test')
  on conflict do nothing;

select set_config('request.jwt.claims', json_build_object(
    'sub', '00000000-0000-4000-8000-000000705eee', 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google'))
  )::text, true);

-- =================================================================================================
-- A · BIZ_MG — app.ci_margin_guard_v705 direct calls (no gate, no operational recipe needed).
-- =================================================================================================
do $v705mg$
declare
  biz         uuid := '00000000-0000-4000-8000-000000705001';
  svc_costed  uuid := '00000000-0000-4000-8000-000000705011';
  svc_nocost  uuid := '00000000-0000-4000-8000-000000705012';
  r jsonb;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v705 margin', 'zz-v705-margin', array['dashboard','clients','sales','reports']);
  insert into public.services (id, business_id, name, price_cents, duration_min, cost_cents) values
    (svc_costed, biz, 'ZZ v705 costed service', 5000, 30, 2000);
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_nocost, biz, 'ZZ v705 no-cost service', 5000, 30);

  r := app.ci_margin_guard_v705(biz, svc_costed, 4000);
  if r->>'status' <> 'blocked' or (r->>'margin_cents')::int <> 3000 then
    insert into _fail values ('A1-blocked', format('expected blocked/3000, got %s', r));
  end if;
  if position('3000' in coalesce(r->>'reason','')) = 0 or position('4000' in coalesce(r->>'reason','')) = 0 then
    insert into _fail values ('A1-blocked-reason', format('reason did not name both figures: %s', r->>'reason'));
  end if;

  r := app.ci_margin_guard_v705(biz, svc_costed, 1000);
  if r->>'status' <> 'ok' or (r->>'margin_cents')::int <> 3000 then
    insert into _fail values ('A2-ok', format('expected ok/3000, got %s', r));
  end if;

  r := app.ci_margin_guard_v705(biz, svc_nocost, 1000);
  if r->>'status' <> 'unavailable' or r->>'margin_cents' is not null then
    insert into _fail values ('A3-nocost', format('expected unavailable/null margin, got %s', r));
  end if;
  if r->>'reason' <> 'no cost recorded for this service; enter costs in Settings' then
    insert into _fail values ('A3-nocost-reason', format('reason was not verbatim: %s', r->>'reason'));
  end if;

  r := app.ci_margin_guard_v705(biz, null, 1000);
  if r->>'status' <> 'unavailable' or r->>'reason' <> 'no service specified for this incentive' then
    insert into _fail values ('A4-noservice', format('expected the no-service-specified reason, got %s', r));
  end if;
end
$v705mg$;

select case when count(*)=0 then 'PASS — A: app.ci_margin_guard_v705' else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

-- =================================================================================================
-- B · BIZ_CAP / BIZ_CAP0 — app.ci_capacity_v705 direct calls.
-- =================================================================================================
do $v705cap$
declare
  biz      uuid := '00000000-0000-4000-8000-000000705002';
  biz0     uuid := '00000000-0000-4000-8000-000000705003';
  u_owner  uuid := '00000000-0000-4000-8000-000000705ee2';
  st       uuid := '00000000-0000-4000-8000-000000705021';
  tue1 date; tue2 date; from_d date; to_d date;
  r jsonb;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v705 capacity', 'zz-v705-capacity', array['dashboard','clients','sales','reports']),
    (biz0, 'ZZ v705 capacity zero', 'zz-v705-capacity-zero', array['dashboard','clients','sales','reports']);
  insert into public.staff (id, business_id, user_id, role, full_name, active, access_state) values
    (st, biz, u_owner, 'owner', 'ZZ v705 cap owner', true, 'approved');

  -- Anchor from_d on a real Monday, so from_d+1 is a real Tuesday, and pick a 14-day window that
  -- contains exactly two Tuesdays (dow=2).
  from_d := (current_date - 300) - (extract(dow from (current_date - 300))::int - 1);
  tue1 := from_d + 1;
  tue2 := tue1 + 7;
  to_d := from_d + 13;

  insert into public.staff_hours (business_id, staff_id, weekday, starts_at, ends_at) values
    (biz, st, 2, '09:00', '13:00');  -- Tuesday, 240 minutes.

  insert into public.clients (id, business_id, full_name) values
    ('00000000-0000-4000-8000-000000705091'::uuid, biz, 'ZZ v705 cap client 1'),
    ('00000000-0000-4000-8000-000000705092'::uuid, biz, 'ZZ v705 cap client 2');

  insert into public.appointments
    (id, business_id, branch_id, client_id, staff_id, starts_at, ends_at, status, created_at)
  values
    ('00000000-0000-4000-8000-000000705081'::uuid, biz, null, '00000000-0000-4000-8000-000000705091'::uuid,
     st, (tue1::timestamp + time '09:00') at time zone 'Asia/Singapore',
     (tue1::timestamp + time '10:30') at time zone 'Asia/Singapore', 'completed', now()),
    ('00000000-0000-4000-8000-000000705082'::uuid, biz, null, '00000000-0000-4000-8000-000000705092'::uuid,
     st, (tue2::timestamp + time '09:00') at time zone 'Asia/Singapore',
     (tue2::timestamp + time '10:30') at time zone 'Asia/Singapore', 'completed', now());

  r := app.ci_capacity_v705(biz, null, from_d, to_d);
  if r->>'status' <> 'ok' then
    insert into _fail values ('B1-status', format('expected ok, got %s', r));
  end if;
  if (r->>'available_minutes')::numeric <> 480 then
    insert into _fail values ('B1-available', format('expected 480, got %s', r->>'available_minutes'));
  end if;
  if (r->>'booked_minutes')::numeric <> 180 then
    insert into _fail values ('B1-booked', format('expected 180, got %s', r->>'booked_minutes'));
  end if;
  if (r->>'pct')::numeric <> 37.5 then
    insert into _fail values ('B1-pct', format('expected 37.5, got %s', r->>'pct'));
  end if;

  r := app.ci_capacity_v705(biz0, null, from_d, to_d);
  if r->>'status' <> 'unavailable' or r->>'reason' <> 'no staff schedule rows recorded' then
    insert into _fail values ('B2-zero', format('expected the no-schedule-rows reason, got %s', r));
  end if;
end
$v705cap$;

select case when count(*)=0 then 'PASS — B: app.ci_capacity_v705' else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

-- =================================================================================================
-- C/E/F · BIZ_CORE — materiality (material + unquantified), concentration, campaigns.
-- =================================================================================================
do $v705core$
declare
  biz      uuid := '00000000-0000-4000-8000-000000705004';
  br       uuid := '00000000-0000-4000-8000-000000705014';
  u_owner  uuid := '00000000-0000-4000-8000-000000705ee3';
  svc_gw   uuid := '00000000-0000-4000-8000-0000007050a1';
  plan_big uuid := '00000000-0000-4000-8000-0000007050b1';
  d1       date := current_date - 200;
  as_of    timestamptz := ((d1 + 150)::timestamp + time '12:00') at time zone 'Asia/Singapore';
  g        jsonb;
  cand     jsonb;
  v_period_revenue bigint;
  v_thr    int;
  v_num    numeric;
  v_int    bigint;
  v_txt    text;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v705 core', 'zz-v705-core', array['dashboard','clients','sales','reports','packages']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v705 core main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz, u_owner, 'owner', 'ZZ v705 core owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v705 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_gw, biz, 'ZZ v705 gateway service', 1000, 30);
  insert into public.package_plans (id, business_id, name, price_cents, sessions, active) values
    (plan_big, biz, 'ZZ v705 plan big (10 sessions)', 20000, 10, true);

  ---------------------------------------------------------------------------
  -- FUNNEL: F1..F20, same shape as nestly_v688 BIZ1 -- gateway_followthrough fires.
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000705' || lpad((100+s)::text,3,'0'))::uuid,
         biz, 'ZZ v705 funnel ' || s from generate_series(1,20) s;
  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000705' || lpad((300+s)::text,3,'0'))::uuid,
         biz, 'ZZ v705 plan-big holder ' || s from generate_series(1,5) s;   -- H1..H5

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000705' || lpad((500+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000705' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 1000,
         (d1::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (d1::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,20) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000705' || lpad((500+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 1000, 1000 from generate_series(1,20) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000705' || lpad((520+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000705' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 1000,
         ((d1+10)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1+10)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,20) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000705' || lpad((520+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 1000, 1000 from generate_series(1,20) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000705' || lpad((540+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000705' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 1000,
         ((d1+20)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1+20)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,18) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000705' || lpad((540+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 1000, 1000 from generate_series(1,18) s;

  ---------------------------------------------------------------------------
  -- H1 rhythm (identical to v688 BIZ1): 5 visits, 10-day gaps, before d1.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000705' || lpad((630+s)::text,3,'0'))::uuid,
         biz, br, '00000000-0000-4000-8000-000000705301'::uuid, 'service', 3000,
         ((d1 - (60 - s*10))::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1 - (60 - s*10))::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000705' || lpad((630+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 3000, 3000 from generate_series(1,5) s;

  ---------------------------------------------------------------------------
  -- PLAN_BIG: H1..H5 buy on d1 (H2..H5 never touch a session and have no other sale ever).
  ---------------------------------------------------------------------------
  insert into public.client_packages
    (id, business_id, plan_id, client_id, sessions_snapshot, remaining, status, purchased_at,
     plan_name_snapshot, plan_version_snapshot, price_cents_snapshot)
  select gen_random_uuid(), biz, plan_big,
         ('00000000-0000-4000-8000-000000705' || lpad((300+s)::text,3,'0'))::uuid,
         10, 10, 'active', (d1::timestamp + time '10:00') at time zone 'Asia/Singapore',
         'ZZ v705 plan big (10 sessions)', 1, 20000
    from generate_series(1,5) s;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000705' || lpad((650+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000705' || lpad((300+s)::text,3,'0'))::uuid,
         'package', 20000,
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore',
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;

  ---------------------------------------------------------------------------
  -- WHALE RETAIL CATEGORY: W + O1..O4, one retail item each, no product_canonical_map row so
  -- classification falls back to 'retail_product' (this business's industry is unset -> 'generic').
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name) values
    ('00000000-0000-4000-8000-000000705700'::uuid, biz, 'ZZ v705 whale W'),
    ('00000000-0000-4000-8000-000000705701'::uuid, biz, 'ZZ v705 other O1'),
    ('00000000-0000-4000-8000-000000705702'::uuid, biz, 'ZZ v705 other O2'),
    ('00000000-0000-4000-8000-000000705703'::uuid, biz, 'ZZ v705 other O3'),
    ('00000000-0000-4000-8000-000000705704'::uuid, biz, 'ZZ v705 other O4');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at) values
    ('00000000-0000-4000-8000-000000705710'::uuid, biz, br, '00000000-0000-4000-8000-000000705700'::uuid,
     'retail', 60000, (d1::timestamp + time '11:00') at time zone 'Asia/Singapore',
     (d1::timestamp + time '11:00') at time zone 'Asia/Singapore'),
    ('00000000-0000-4000-8000-000000705711'::uuid, biz, br, '00000000-0000-4000-8000-000000705701'::uuid,
     'retail', 10000, (d1::timestamp + time '11:00') at time zone 'Asia/Singapore',
     (d1::timestamp + time '11:00') at time zone 'Asia/Singapore'),
    ('00000000-0000-4000-8000-000000705712'::uuid, biz, br, '00000000-0000-4000-8000-000000705702'::uuid,
     'retail', 10000, (d1::timestamp + time '11:00') at time zone 'Asia/Singapore',
     (d1::timestamp + time '11:00') at time zone 'Asia/Singapore'),
    ('00000000-0000-4000-8000-000000705713'::uuid, biz, br, '00000000-0000-4000-8000-000000705703'::uuid,
     'retail', 10000, (d1::timestamp + time '11:00') at time zone 'Asia/Singapore',
     (d1::timestamp + time '11:00') at time zone 'Asia/Singapore'),
    ('00000000-0000-4000-8000-000000705714'::uuid, biz, br, '00000000-0000-4000-8000-000000705704'::uuid,
     'retail', 10000, (d1::timestamp + time '11:00') at time zone 'Asia/Singapore',
     (d1::timestamp + time '11:00') at time zone 'Asia/Singapore');
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents) values
    (biz, '00000000-0000-4000-8000-000000705710'::uuid, 'retail', gen_random_uuid(), 1, 60000, 60000),
    (biz, '00000000-0000-4000-8000-000000705711'::uuid, 'retail', gen_random_uuid(), 1, 10000, 10000),
    (biz, '00000000-0000-4000-8000-000000705712'::uuid, 'retail', gen_random_uuid(), 1, 10000, 10000),
    (biz, '00000000-0000-4000-8000-000000705713'::uuid, 'retail', gen_random_uuid(), 1, 10000, 10000),
    (biz, '00000000-0000-4000-8000-000000705714'::uuid, 'retail', gen_random_uuid(), 1, 10000, 10000);

  ---------------------------------------------------------------------------
  -- CAMPAIGNS: 6 sends at d1, 4 return within 30 days.
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000705' || lpad((800+s)::text,3,'0'))::uuid,
         biz, 'ZZ v705 campaign client ' || s from generate_series(1,6) s;
  insert into public.campaign_send_records_v255
    (business_id, campaign_kind, campaign_ref_id, send_kind, campaign_label, channel, client_id,
     occurred_at, retention_until)
  select biz, 'promotion', gen_random_uuid(), 'blast', 'ZZ v705 campaign', 'web_push',
         ('00000000-0000-4000-8000-000000705' || lpad((800+s)::text,3,'0'))::uuid,
         (d1::timestamp + time '08:00') at time zone 'Asia/Singapore',
         ((d1::timestamp + time '08:00') at time zone 'Asia/Singapore') + interval '400 days'
    from generate_series(1,6) s;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000705' || lpad((820+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000705' || lpad((800+s)::text,3,'0'))::uuid,
         'service', 500,
         ((d1+5)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1+5)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,4) s;   -- only 4 of the 6 return
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000705' || lpad((820+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 500, 500 from generate_series(1,4) s;

  ---------------------------------------------------------------------------
  -- THE CALL
  ---------------------------------------------------------------------------
  g := public.get_ci_opportunities_v1(biz, d1, d1, null, as_of, true);
  if g is null then
    insert into _fail values ('C0', 'get_ci_opportunities_v1 returned no payload');
    return;
  end if;

  -- independent hand-count of period revenue (service-kind funnel first visits + package + retail),
  -- exactly the same population rule v_period_revenue itself uses (counts_as_revenue, not synthetic,
  -- not reversed, within [d1,d1]).
  select coalesce(sum(s.amount_cents), 0) into v_period_revenue
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
   where s.business_id = biz and sc.include_revenue and not sc.is_synthetic_client
     and s.created_at <= as_of
     and (s.occurred_at at time zone 'Asia/Singapore')::date between d1 and d1;
  if v_period_revenue <> 220000 then
    insert into _fail values ('C-PRE-revenue',
      format('hand-counted period revenue was %s, expected 220000 (20000 funnel + 100000 plan_big + '
             '100000 whale retail)', v_period_revenue));
  end if;

  -- C1 · materiality threshold, the one place.
  select app.ci_materiality_threshold_bps_v705() into v_thr;
  if v_thr <> 100 then
    insert into _fail values ('C1-threshold', format('expected 100, got %s', v_thr));
  end if;

  -- C2 · every extended candidate carries materiality + materiality_class.
  for cand in select c from jsonb_array_elements(g->'ranked') c loop
    if not (cand ? 'materiality') or not (cand ? 'materiality_class') then
      insert into _fail values ('C2-missing', format('%s lacks materiality/materiality_class', cand->>'id'));
    elsif cand->>'materiality_class' not in ('material','minor','unquantified') then
      insert into _fail values ('C2-invalid', format('%s has invalid materiality_class %s',
        cand->>'id', cand->>'materiality_class'));
    end if;
  end loop;

  -- C3 · package_leakage:<plan_big> is 'material', EV=19004, materiality matches the hand-count.
  select c into cand from jsonb_array_elements(g->'ranked') c where c->>'id' = 'package_leakage:' || plan_big::text;
  if cand is null then
    insert into _fail values ('C3-missing', 'package_leakage:plan_big was not promoted');
  else
    if (cand->'impact'->'expected_value'->>'cents')::bigint <> 19004 then
      insert into _fail values ('C3-ev', format('expected 19004, got %s', cand->'impact'->'expected_value'->>'cents'));
    end if;
    if cand->>'materiality_class' <> 'material' then
      insert into _fail values ('C3-class', format('expected material, got %s', cand->>'materiality_class'));
    end if;
    if (cand->'materiality'->>'numerator')::bigint <> 19004
       or (cand->'materiality'->>'denominator')::bigint <> v_period_revenue then
      insert into _fail values ('C3-materiality', format('materiality was %s', cand->'materiality'));
    end if;
  end if;

  -- E1 · category_concentration: 'unquantified' + concentration block, verbatim skew_note.
  select c into cand from jsonb_array_elements(g->'ranked') c where c->>'id' = 'category_concentration';
  if cand is null then
    insert into _fail values ('E1-missing', 'category_concentration was not promoted');
  else
    if cand->>'materiality_class' <> 'unquantified' then
      insert into _fail values ('E1-class', format('expected unquantified, got %s', cand->>'materiality_class'));
    end if;
    if (cand->'concentration'->>'top1_share_bps')::int <> 6000 then
      insert into _fail values ('E1-share', format('expected 6000, got %s', cand->'concentration'->>'top1_share_bps'));
    end if;
    if (cand->'concentration'->>'mean_excl_top1')::numeric <> 10000.00 then
      insert into _fail values ('E1-mean', format('expected 10000.00, got %s', cand->'concentration'->>'mean_excl_top1'));
    end if;
    if cand->'concentration'->>'skew_note' <>
       'top customer carries 60.0% of this category; the mean overstates the typical customer' then
      insert into _fail values ('E1-skewnote', format('skew_note was not verbatim: %s', cand->'concentration'->>'skew_note'));
    end if;
    if position('Its top customer alone accounts for 60.0% of the category.' in (cand->>'pattern')) = 0 then
      insert into _fail values ('E1-pattern', format('pattern did not carry the top-customer clause: %s', cand->>'pattern'));
    end if;
  end if;

  -- F1 · gateway_followthrough: unquantified (real, distinct from package_leakage's material).
  select c into cand from jsonb_array_elements(g->'ranked') c where c->>'id' = 'gateway_followthrough:' || svc_gw::text;
  if cand is null then
    insert into _fail values ('F1-missing', 'gateway_followthrough:svc_gw was not promoted');
  elsif cand->>'materiality_class' <> 'unquantified' then
    insert into _fail values ('F1-class', format('expected unquantified, got %s', cand->>'materiality_class'));
  end if;

  -- F2 · campaigns.
  select c into cand from jsonb_array_elements(g->'ranked') c where c->>'id' = 'campaigns';
  if cand is null then
    insert into _fail values ('F2-missing', 'campaigns was not promoted');
  else
    if cand->>'evidence_class' <> 'ASSOCIATION' then
      insert into _fail values ('F2-class', format('expected ASSOCIATION, got %s', cand->>'evidence_class'));
    end if;
    if (cand->'evidence'->'refs'->'rate'->>'numerator')::int <> 4
       or (cand->'evidence'->'refs'->'rate'->>'denominator')::int <> 6
       or (cand->'evidence'->'refs'->'rate'->>'pct')::numeric <> 66.7 then
      insert into _fail values ('F2-rate', format('rate was %s', cand->'evidence'->'refs'->'rate'));
    end if;
    if position('4' in (cand->>'pattern')) = 0 or position('6' in (cand->>'pattern')) = 0 then
      insert into _fail values ('F2-pattern', format('pattern did not carry 4/6: %s', cand->>'pattern'));
    end if;
    if position('Incremental effect is unavailable' in (cand->>'limitation')) = 0 then
      insert into _fail values ('F2-limitation', format('limitation missing the honest incremental-unavailable wording: %s', cand->>'limitation'));
    end if;
  end if;
end
$v705core$;

select case when count(*)=0 then 'PASS — C/E/F: BIZ_CORE materiality/concentration/campaigns' else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

-- =================================================================================================
-- D · BIZ_MINOR — a real 'minor' materiality_class candidate.
-- =================================================================================================
do $v705minor$
declare
  biz      uuid := '00000000-0000-4000-8000-000000705005';
  br       uuid := '00000000-0000-4000-8000-000000705015';
  u_owner  uuid := '00000000-0000-4000-8000-000000705ee4';
  plan_tiny uuid := '00000000-0000-4000-8000-0000007050c1';
  d1       date := current_date - 200;
  as_of    timestamptz := ((d1 + 150)::timestamp + time '12:00') at time zone 'Asia/Singapore';
  g        jsonb;
  cand     jsonb;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v705 minor', 'zz-v705-minor', array['dashboard','clients','sales','reports','packages']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v705 minor main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz, u_owner, 'owner', 'ZZ v705 minor owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v705 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.package_plans (id, business_id, name, price_cents, sessions, active) values
    (plan_tiny, biz, 'ZZ v705 plan tiny (2 sessions)', 4, 2, true);

  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000705' || lpad((900+s)::text,3,'0'))::uuid,
         biz, 'ZZ v705 minor holder ' || s from generate_series(1,5) s;   -- M1..M5, no other sale ever

  insert into public.client_packages
    (id, business_id, plan_id, client_id, sessions_snapshot, remaining, status, purchased_at,
     plan_name_snapshot, plan_version_snapshot, price_cents_snapshot)
  select gen_random_uuid(), biz, plan_tiny,
         ('00000000-0000-4000-8000-000000705' || lpad((900+s)::text,3,'0'))::uuid,
         2, 2, 'active', (d1::timestamp + time '10:00') at time zone 'Asia/Singapore',
         'ZZ v705 plan tiny (2 sessions)', 1, 4
    from generate_series(1,5) s;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000705' || lpad((950+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000705' || lpad((900+s)::text,3,'0'))::uuid,
         'package', 4,
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore',
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;

  g := public.get_ci_opportunities_v1(biz, d1, d1, null, as_of, true);
  select c into cand from jsonb_array_elements(g->'ranked') c where c->>'id' = 'package_leakage:' || plan_tiny::text;
  if cand is null then
    insert into _fail values ('D1-missing', 'package_leakage:plan_tiny was not promoted');
  else
    if (cand->'impact'->'expected_value'->>'cents')::bigint <> 0 then
      insert into _fail values ('D1-ev', format('expected EV 0, got %s', cand->'impact'->'expected_value'->>'cents'));
    end if;
    if cand->>'materiality_class' <> 'minor' then
      insert into _fail values ('D1-class', format('expected minor, got %s', cand->>'materiality_class'));
    end if;
    if (cand->'materiality'->>'numerator')::bigint <> 0 or (cand->'materiality'->>'denominator')::bigint <> 20 then
      insert into _fail values ('D1-materiality', format('materiality was %s', cand->'materiality'));
    end if;
  end if;
end
$v705minor$;

select case when count(*)=0 then 'PASS — D: BIZ_MINOR real minor materiality_class' else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

-- =================================================================================================
-- F3 · BIZ_CAMPAIGN_ABSTAIN — below the sample floor -> no campaigns candidate, an abstention instead.
-- =================================================================================================
do $v705campabst$
declare
  biz      uuid := '00000000-0000-4000-8000-000000705006';
  br       uuid := '00000000-0000-4000-8000-000000705016';
  u_owner  uuid := '00000000-0000-4000-8000-000000705ee5';
  d1       date := current_date - 200;
  as_of    timestamptz := ((d1 + 150)::timestamp + time '12:00') at time zone 'Asia/Singapore';
  g        jsonb;
  cand     jsonb;
  v_txt    text;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v705 camp abstain', 'zz-v705-camp-abstain', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v705 camp abstain main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz, u_owner, 'owner', 'ZZ v705 camp abstain owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v705 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000705' || lpad((960+s)::text,3,'0'))::uuid,
         biz, 'ZZ v705 camp-abstain client ' || s from generate_series(1,3) s;   -- only 3, below floor 5
  insert into public.campaign_send_records_v255
    (business_id, campaign_kind, campaign_ref_id, send_kind, campaign_label, channel, client_id,
     occurred_at, retention_until)
  select biz, 'promotion', gen_random_uuid(), 'blast', 'ZZ v705 camp abstain', 'web_push',
         ('00000000-0000-4000-8000-000000705' || lpad((960+s)::text,3,'0'))::uuid,
         (d1::timestamp + time '08:00') at time zone 'Asia/Singapore',
         ((d1::timestamp + time '08:00') at time zone 'Asia/Singapore') + interval '400 days'
    from generate_series(1,3) s;

  g := public.get_ci_opportunities_v1(biz, d1, d1, null, as_of, true);
  select c into cand from jsonb_array_elements(g->'ranked') c where c->>'id' = 'campaigns';
  if cand is not null then
    insert into _fail values ('F3-fired', 'campaigns fired below the sample floor');
  end if;
  select a->>'reason' into v_txt from jsonb_array_elements(g->'abstentions') a where a->>'generator' = 'campaigns';
  if v_txt is null then
    insert into _fail values ('F3-noabstention', 'no campaigns abstention was recorded');
  end if;
end
$v705campabst$;

select case when count(*)=0 then 'PASS — F3: campaigns abstains below the sample floor' else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

-- =================================================================================================
-- G · BIZ_DAYPART — operational_change alternative.
-- =================================================================================================
do $v705daypart$
declare
  biz      uuid := '00000000-0000-4000-8000-000000705007';
  br       uuid := '00000000-0000-4000-8000-000000705017';
  u_owner  uuid := '00000000-0000-4000-8000-000000705ee6';
  svc      uuid := '00000000-0000-4000-8000-0000007050d1';
  mon      date;
  thu      date;
  from_d   date;
  to_d     date;
  as_of    timestamptz;
  g        jsonb;
  cand     jsonb;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v705 daypart', 'zz-v705-daypart', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v705 daypart main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz, u_owner, 'owner', 'ZZ v705 daypart owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v705 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc, biz, 'ZZ v705 daypart service', 1000, 30);

  from_d := (current_date - 400) - (extract(dow from (current_date - 400))::int - 1);  -- a Monday
  mon := from_d;
  thu := from_d + 3;
  to_d := from_d + 13;
  as_of := ((to_d + 1)::timestamp + time '12:00') at time zone 'Asia/Singapore';

  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000705' || lpad((200+s)::text,3,'0'))::uuid,
         biz, 'ZZ v705 mon client ' || s from generate_series(1,10) s;
  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000705' || lpad((220+s)::text,3,'0'))::uuid,
         biz, 'ZZ v705 thu client ' || s from generate_series(1,5) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000705' || lpad((240+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000705' || lpad((200+s)::text,3,'0'))::uuid,
         'service', 1000,
         (mon::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (mon::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,10) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000705' || lpad((240+s)::text,3,'0'))::uuid,
         'service', svc, 1, 1000, 1000 from generate_series(1,10) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000705' || lpad((260+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000705' || lpad((220+s)::text,3,'0'))::uuid,
         'service', 4000,
         (thu::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (thu::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000705' || lpad((260+s)::text,3,'0'))::uuid,
         'service', svc, 1, 4000, 4000 from generate_series(1,5) s;

  g := public.get_ci_opportunities_v1(biz, from_d, to_d, null, as_of, true);
  select c into cand from jsonb_array_elements(g->'ranked') c where c->>'id' = 'daypart_shift';
  if cand is null then
    insert into _fail values ('G1-missing', 'daypart_shift was not promoted');
  else
    if jsonb_array_length(cand->'alternatives') < 3 then
      insert into _fail values ('G1-count', 'fewer than 3 alternatives on daypart_shift');
    end if;
    if not exists (select 1 from jsonb_array_elements(cand->'alternatives') a
                    where a->>'kind' = 'operational_change'
                      and a->'cost_basis'->>'status' = 'declared'
                      and (a->'cost_basis'->>'cents')::int = 0) then
      insert into _fail values ('G1-alt', 'no declared-zero-cost operational_change alternative');
    end if;
  end if;
end
$v705daypart$;

select case when count(*)=0 then 'PASS — G: BIZ_DAYPART operational_change alternative' else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

-- =================================================================================================
-- H · BIZ_CADENCE — lapsed_regulars + rebooking alternative.
-- =================================================================================================
do $v705cadence$
declare
  biz       uuid := '00000000-0000-4000-8000-000000705008';
  br        uuid := '00000000-0000-4000-8000-000000705018';
  u_owner   uuid := '00000000-0000-4000-8000-00000070501e';
  u_sa      uuid := '00000000-0000-4000-8000-000000705eee';
  st_owner  uuid := '00000000-0000-4000-8000-000000705081';
  svc       uuid := '00000000-0000-4000-8000-0000007050e1';
  appt_src  uuid := '00000000-0000-4000-8000-000000705890';
  d1        date := current_date - 200;
  as_of     timestamptz := ((d1 + 150)::timestamp + time '12:00') at time zone 'Asia/Singapore';
  cl_src    uuid := '00000000-0000-4000-8000-000000705898';
  g         jsonb;
  cand      jsonb;
  i         integer;
  cl        uuid;
  appt      uuid;
  sale      uuid;
  returns_flag boolean;
begin
  insert into auth.users (id, email) values (u_owner, 'zz-v705-cadence-owner@example.test')
    on conflict (id) do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v705 cadence', 'zz-v705-cadence', array['dashboard','clients','sales','reports','appointments']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v705 cadence main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.staff (id, business_id, user_id, role, full_name, active, access_state) values
    (st_owner, biz, u_owner, 'owner', 'ZZ v705 cadence owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v705 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc, biz, 'ZZ v705 cadence service', 1000, 30);

  ---------------------------------------------------------------------------
  -- L1..L5 (identical shape to nestly_v688 BIZ4).
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name) values
    ('00000000-0000-4000-8000-000000705460'::uuid, biz, 'ZZ v705 L1'),
    ('00000000-0000-4000-8000-000000705461'::uuid, biz, 'ZZ v705 L2'),
    ('00000000-0000-4000-8000-000000705462'::uuid, biz, 'ZZ v705 L3'),
    ('00000000-0000-4000-8000-000000705479'::uuid, biz, 'ZZ v705 L4'),
    ('00000000-0000-4000-8000-000000705485'::uuid, biz, 'ZZ v705 L5');

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000705' || lpad((462+s)::text,3,'0'))::uuid,
         biz, br, '00000000-0000-4000-8000-000000705460'::uuid, 'service', 5000,
         ((d1 - (60 - s*10))::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1 - (60 - s*10))::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000705' || lpad((462+s)::text,3,'0'))::uuid,
         'service', svc, 1, 5000, 5000 from generate_series(1,5) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000705' || lpad((467+s)::text,3,'0'))::uuid,
         biz, br, '00000000-0000-4000-8000-000000705461'::uuid, 'service', 8000,
         ((d1 - (90 - s*15))::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1 - (90 - s*15))::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000705' || lpad((467+s)::text,3,'0'))::uuid,
         'service', svc, 1, 8000, 8000 from generate_series(1,5) s;

  -- L3: 4 visits @6000, gaps of 20 days (k=3 intervals -- clears the DEFAULT lifecycle floor of 3
  -- unmodified by this fixture, unlike nestly_v688's BIZ4 which deliberately lowered that floor to
  -- demonstrate a k=2 divergence; this fixture does not need that divergence, only a fifth genuinely
  -- overdue regular so the n=5 sample floor is cleared).
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000705' || lpad((472+s)::text,3,'0'))::uuid,
         biz, br, '00000000-0000-4000-8000-000000705462'::uuid, 'service', 6000,
         ((d1 - (100 - s*20))::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1 - (100 - s*20))::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,4) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000705' || lpad((472+s)::text,3,'0'))::uuid,
         'service', svc, 1, 6000, 6000 from generate_series(1,4) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000705' || lpad((479+s)::text,3,'0'))::uuid,
         biz, br, '00000000-0000-4000-8000-000000705479'::uuid, 'service', 7000,
         ((d1 - (72 - s*12))::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1 - (72 - s*12))::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000705' || lpad((479+s)::text,3,'0'))::uuid,
         'service', svc, 1, 7000, 7000 from generate_series(1,5) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000705' || lpad((485+s)::text,3,'0'))::uuid,
         biz, br, '00000000-0000-4000-8000-000000705485'::uuid, 'service', 4000,
         ((d1 - (150 - s*25))::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1 - (150 - s*25))::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000705' || lpad((485+s)::text,3,'0'))::uuid,
         'service', svc, 1, 4000, 4000 from generate_series(1,5) s;

  ---------------------------------------------------------------------------
  -- REBOOKING cohorts (identical shape to nestly_v683's own proven fixture): a source appointment,
  -- 5 rebooked (3 return), 5 other (1 returns), all completed at d1.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);

  insert into public.clients (id, business_id, full_name) values (cl_src, biz, 'ZZ v705 rebook src client');
  insert into public.appointments
    (id, business_id, branch_id, client_id, staff_id, starts_at, ends_at, status, service_id, created_at)
  values (appt_src, biz, br, cl_src, st_owner,
          (d1 - 200)::timestamp at time zone 'Asia/Singapore',
          (d1 - 200)::timestamp at time zone 'Asia/Singapore' + interval '1 hour',
          'completed', svc, (d1 - 200)::timestamp at time zone 'Asia/Singapore');

  for i in 1..5 loop
    cl := ('00000000-0000-4000-8000-0000007058' || (60 + i)::text)::uuid;
    appt := ('00000000-0000-4000-8000-0000007058' || (50 + i)::text)::uuid;
    sale := ('00000000-0000-4000-8000-0000007058' || (70 + i)::text)::uuid;
    returns_flag := (i <= 3);

    insert into public.clients (id, business_id, full_name) values (cl, biz, 'ZZ v705 rebooked client ' || i);
    insert into public.appointments
      (id, business_id, branch_id, client_id, staff_id, starts_at, ends_at, status, service_id, created_at)
    values (appt, biz, br, cl, st_owner,
            (d1::timestamp) at time zone 'Asia/Singapore',
            (d1::timestamp) at time zone 'Asia/Singapore' + interval '1 hour',
            'completed', svc, (d1::timestamp) at time zone 'Asia/Singapore');

    perform public.link_rebooked_appointment_v1(biz, appt, appt_src);

    insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                              occurred_at, created_at, appointment_id)
    values (sale, biz, br, cl, 'service', 2000, (d1::timestamp) at time zone 'Asia/Singapore',
            (d1::timestamp) at time zone 'Asia/Singapore', appt);

    if returns_flag then
      insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
      values (('00000000-0000-4000-8000-0000007058' || (80 + i)::text)::uuid, biz, br, cl, 'service', 1000,
              ((d1+20)::timestamp) at time zone 'Asia/Singapore', ((d1+20)::timestamp) at time zone 'Asia/Singapore');
    end if;
  end loop;

  for i in 1..5 loop
    cl := ('00000000-0000-4000-8000-0000007059' || (10 + i)::text)::uuid;
    appt := ('00000000-0000-4000-8000-0000007059' || (20 + i)::text)::uuid;
    sale := ('00000000-0000-4000-8000-0000007059' || (30 + i)::text)::uuid;
    returns_flag := (i = 1);

    insert into public.clients (id, business_id, full_name) values (cl, biz, 'ZZ v705 other client ' || i);
    insert into public.appointments
      (id, business_id, branch_id, client_id, staff_id, starts_at, ends_at, status, service_id, created_at)
    values (appt, biz, br, cl, st_owner,
            (d1::timestamp) at time zone 'Asia/Singapore',
            (d1::timestamp) at time zone 'Asia/Singapore' + interval '1 hour',
            'completed', svc, (d1::timestamp) at time zone 'Asia/Singapore');

    insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                              occurred_at, created_at, appointment_id)
    values (sale, biz, br, cl, 'service', 2000, (d1::timestamp) at time zone 'Asia/Singapore',
            (d1::timestamp) at time zone 'Asia/Singapore', appt);

    if returns_flag then
      insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
      values (('00000000-0000-4000-8000-0000007059' || (40 + i)::text)::uuid, biz, br, cl, 'service', 1000,
              ((d1+20)::timestamp) at time zone 'Asia/Singapore', ((d1+20)::timestamp) at time zone 'Asia/Singapore');
    end if;
  end loop;

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  ---------------------------------------------------------------------------
  -- PRECONDITION: the rebooking reader itself resolves the rates this fixture's truth table states.
  ---------------------------------------------------------------------------
  declare
    v_rb jsonb;
  begin
    v_rb := public.get_ci_rebooking_v1(biz, d1, d1, null);
    if (v_rb->'cohorts'->'rebooked_at_departure'->>'n')::int is distinct from 5
       or (v_rb->'cohorts'->'rebooked_at_departure'->'within_window'->>'numerator')::int is distinct from 3 then
      insert into _fail values ('H-PRE-rebooking', format('rebooking reader did not resolve the intended '
        'cohort shape: %s', v_rb->'cohorts'->'rebooked_at_departure'));
    end if;
  end;

  g := public.get_ci_opportunities_v1(biz, d1, d1, null, as_of, true);
  select c into cand from jsonb_array_elements(g->'ranked') c where c->>'id' = 'lapsed_regulars';
  if cand is null then
    insert into _fail values ('H1-missing', 'lapsed_regulars was not promoted');
  else
    if jsonb_array_length(cand->'alternatives') < 3 then
      insert into _fail values ('H1-count', 'fewer than 3 alternatives on lapsed_regulars');
    end if;
    if not exists (select 1 from jsonb_array_elements(cand->'alternatives') a
                    where a->>'kind' = 'rebooking'
                      and position('60.0' in (a->>'what')) > 0
                      and position('20.0' in (a->>'what')) > 0
                      and a->'cost_basis'->>'status' = 'declared'
                      and (a->'cost_basis'->>'cents')::int = 0) then
      insert into _fail values ('H1-alt', format('no rebooking alternative naming 60.0%%/20.0%%: %s', cand->'alternatives'));
    end if;
  end if;
end
$v705cadence$;

select case when count(*)=0 then 'PASS — H: BIZ_CADENCE rebooking alternative' else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

-- =================================================================================================
-- I · alternatives kind superset, across every ranked candidate this fixture has produced.
-- =================================================================================================
do $v705altset$
declare
  kinds text[];
begin
  select array_agg(distinct a->>'kind') into kinds
    from (
      select jsonb_array_elements(public.get_ci_opportunities_v1(
               '00000000-0000-4000-8000-000000705004'::uuid,
               (current_date - 200), (current_date - 200), null,
               (((current_date - 200) + 150)::timestamp + time '12:00') at time zone 'Asia/Singapore',
               true)->'ranked') c
      union all
      select jsonb_array_elements(public.get_ci_opportunities_v1(
               '00000000-0000-4000-8000-000000705007'::uuid,
               ((current_date - 400) - (extract(dow from (current_date - 400))::int - 1)),
               ((current_date - 400) - (extract(dow from (current_date - 400))::int - 1)) + 13, null,
               ((((current_date - 400) - (extract(dow from (current_date - 400))::int - 1)) + 14)::timestamp
                 + time '12:00') at time zone 'Asia/Singapore',
               true)->'ranked') c
      union all
      select jsonb_array_elements(public.get_ci_opportunities_v1(
               '00000000-0000-4000-8000-000000705008'::uuid,
               (current_date - 200), (current_date - 200), null,
               (((current_date - 200) + 150)::timestamp + time '12:00') at time zone 'Asia/Singapore',
               true)->'ranked') c
    ) x(c), jsonb_array_elements(x.c->'alternatives') a;

  if not (kinds @> array['reminder_only','rebooking','service_recovery','operational_change','incentive']) then
    insert into _fail values ('I1-superset', format('observed kinds were %s, missing one of the required five', kinds));
  end if;
end
$v705altset$;

select case when count(*)=0 then 'PASS — I: alternatives kind superset covers all five' else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

-- =================================================================================================
-- J · BIZ_LOYALTY — regression proof for the v_has_v683 gate hotfix (this migration's anchor 8).
--
-- nestly_v699 dropped the 4-arg overloads of get_ci_discount_dependency_v1 and
-- get_ci_staff_performance_v1, replacing both with 5-arg (trailing p_as_of) ones. v688/v696's
-- v_has_v683 gate asked to_regprocedure for the literal OLD 4-arg signature text for those two
-- functions, which stopped naming any real catalogue object the moment v699 applied — so the
-- ENTIRE `if v_has_v683 and p_branch is null then ... end if;` block (no_discount_reminder,
-- loyalty_cannibalisation_gap, staff_mix_underperformance) silently stopped running altogether,
-- in both p_extended modes, for every business, regardless of whether any of the three
-- generators' own preconditions were met. This is not a "candidate vs abstention" question — under
-- the bug, NEITHER appears: the generator's name never enters v_new_cands NOR v_abst.
--
-- TRUTH TABLE: BIZ_LOYALTY has one client (CL1) with one qualifying visit inside [from_d,to_d]
-- (eligible for app.ci_loyalty_eligible_v683) and a `business_programmes` row (kind='points',
-- active=true) — a live points programme. One `loyalty_redemptions` row for CL1, redeemed_at
-- inside the window, consumes_balance default true. This redemption population (n=1) is far below
-- the sample floor (5) that app.ci_loyalty_outcomes_v683's cannibalisation_proxy is floor-gated on,
-- so the EXPECTED outcome under a CORRECTLY GATED engine is an ABSTENTION (generator =
-- 'loyalty_cannibalisation_gap', reason citing the 50% bar), never a candidate — asserted exactly,
-- not just "either". no_discount_reminder and staff_mix_underperformance are asserted more loosely
-- (present as EITHER a candidate or an abstention — this fixture makes no claim about their own
-- internal thresholds, only that the gate itself no longer silently deletes them).
-- =================================================================================================
do $v705loyalty$
declare
  biz     uuid := '00000000-0000-4000-8000-000000705009';
  br      uuid := '00000000-0000-4000-8000-000000705019';
  u_owner uuid := '00000000-0000-4000-8000-000000705ee9';
  cl1     uuid := '00000000-0000-4000-8000-000000705029';
  from_d  date := current_date - 200;
  to_d    date := current_date - 200;
  as_of   timestamptz := ((current_date - 200 + 150)::timestamp + time '12:00') at time zone 'Asia/Singapore';
  g       jsonb;
  cand    jsonb;
  abst    jsonb;
begin
  insert into auth.users (id, email) values (u_owner, 'zz-v705-loyalty-owner@example.test')
    on conflict (id) do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v705 loyalty', 'zz-v705-loyalty', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v705 loyalty main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz, u_owner, 'owner', 'ZZ v705 loyalty owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v705 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.clients (id, business_id, full_name) values (cl1, biz, 'ZZ v705 loyalty CL1');

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values ('00000000-0000-4000-8000-000000705039'::uuid, biz, br, cl1, 'service', 1000,
          (from_d::timestamp + time '09:00') at time zone 'Asia/Singapore',
          (from_d::timestamp + time '09:00') at time zone 'Asia/Singapore');

  -- a live points programme (a business-creation trigger already auto-seeds a default row per
  -- programme kind — v565 "every business born the same" — so this is an upsert, not a plain insert)
  insert into public.business_programmes (business_id, kind, active, sort)
  values (biz, 'points', true, 1)
    on conflict (business_id, kind) do update set active = true;

  -- one redemption, inside the window — n=1, below the floor of 5 the cannibalisation proxy needs
  insert into public.loyalty_redemptions
    (business_id, client_id, reward_name, points_spent, credit_cents, redeemed_at)
  values (biz, cl1, 'ZZ v705 test reward', 100, 500,
          (from_d::timestamp + time '10:00') at time zone 'Asia/Singapore');

  g := public.get_ci_opportunities_v1(biz, from_d, to_d, null, as_of, true);

  select c into cand from jsonb_array_elements(coalesce(g->'ranked','[]'::jsonb)) c
   where c->>'id' = 'loyalty_cannibalisation_gap';
  select a into abst from jsonb_array_elements(coalesce(g->'abstentions','[]'::jsonb)) a
   where a->>'generator' = 'loyalty_cannibalisation_gap';

  if cand is null and abst is null then
    insert into _fail values ('J1-absent',
      'loyalty_cannibalisation_gap is in neither ranked nor abstentions — the v_has_v683 gate is '
      'silently disabling the whole v683-gated generator block again');
  end if;
  if cand is not null then
    insert into _fail values ('J1-unexpected-candidate',
      'n=1 redemption is below the sample floor of 5; loyalty_cannibalisation_gap should have '
      'abstained, not fired as a candidate');
  end if;

  if not (
    exists (select 1 from jsonb_array_elements(coalesce(g->'ranked','[]'::jsonb)) c
             where c->>'id' = 'no_discount_reminder')
    or exists (select 1 from jsonb_array_elements(coalesce(g->'abstentions','[]'::jsonb)) a
                where a->>'generator' = 'no_discount_reminder')
  ) then
    insert into _fail values ('J2-absent', 'no_discount_reminder is in neither ranked nor abstentions');
  end if;

  if not (
    exists (select 1 from jsonb_array_elements(coalesce(g->'ranked','[]'::jsonb)) c
             where c->>'id' like 'staff_mix_underperformance%')
    or exists (select 1 from jsonb_array_elements(coalesce(g->'abstentions','[]'::jsonb)) a
                where a->>'generator' = 'staff_mix_underperformance')
  ) then
    insert into _fail values ('J3-absent', 'staff_mix_underperformance is in neither ranked nor abstentions');
  end if;
end
$v705loyalty$;

select case when count(*)=0 then 'PASS — J: BIZ_LOYALTY v_has_v683 gate regression proof' else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v705: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
