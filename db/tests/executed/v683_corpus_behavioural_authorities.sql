-- EXECUTED acceptance fixture for nestly_v683 — staff identity, mix-adjusted staff performance,
-- rebooking, loyalty programme value, discount dependency, and the marketing attribution
-- taxonomy (checks 39, 40, 51-58).
--
-- Named for v683 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md). Every reader is proved against a
-- PREDETERMINED truth table — exact counts/pct/index assertions, never `> 0` spot checks.
--
-- AUTH CONTEXT. Every READ call goes through app.ci_access_gate_v667, whose platform arm admits
-- a super admin outright — the v673 fixture's approach, adopted here for the same reason: a
-- super-admin session avoids needing a fully operational merchant workspace (approval +
-- subscription + staff rows) for fixtures that are not testing entitlement (v667's own corpus
-- already proves that boundary). The two WRITE RPCs this migration adds
-- (public.set_actual_provider_v683, and the pre-existing public.link_rebooked_appointment_v1
-- exercised here for its write-once guard) are gated by app.can_module_write / app.can_see_branch,
-- which do NOT admit a super admin for the module-write check — so those two calls run under a
-- real staff-owner impersonation instead, set up minimally (an active 'owner' staff row; no
-- workspace-approval/subscription rows are needed because can_module_write reads only public.staff).
--
-- TIME BASE. Every "today" is v_today_sgt := (now() at time zone 'Asia/Singapore')::date, and
-- every event timestamp is midnight-SGT on (v_today_sgt - N), matching the v673/v651 discipline,
-- so every day-offset below is an exact integer regardless of the wall-clock instant the harness
-- runs at.
--
-- ============================================================================================
-- TRUTH TABLE — get_ci_staff_identity_v1 (check 39)
-- ============================================================================================
-- biz, branch1. Four sales in the window [today-10, today-1]:
--   s1  full identity: linked appointment (booked staff = alice), sales.staff_id = alice,
--       one sale_items service line staff_id = alice, operator_user_id explicitly set = u_owner,
--       appointments.actual_provider_staff_id set via set_actual_provider_v683 = bob (a
--       deliberate "booked one, served by another" case).
--   s2  no linked appointment; sales.staff_id = bob; one sale_items line staff_id = bob;
--       operator_user_id left unset at INSERT time (still under the fixture's super-admin
--       session — the only session that can write public.sales here at all, since
--       app.require_branch_module_v94 admits a super admin outright but refuses an ordinary
--       staff session with no branch/module grant), so trg_sales_operator_default_v683 fills
--       it from auth.uid() = u_sa.
--   s3  no appointment, no staff_id, no sale_items staff; operator_user_id likewise defaulted
--       to u_sa for the same reason. A genuinely NULL operator_user_id only arises from a
--       service-role write with no JWT claims at all, which this environment's write-gate does
--       not admit — not exercised here, recorded as a limitation. What IS proven: the trigger
--       never leaves the column unset when a caller identity exists (s2, s3), and never
--       overwrites an explicit value when one is supplied (s1).
--   s4  reversed (excluded from the population entirely, not merely zeroed).
-- -> total = 3 (s1,s2,s3; s4 excluded). booked=1/3, credited=2/3, line_staff=2/3,
--    operator=3/3 (s1 explicit, s2+s3 defaulted), actual_provider=1/3 (s1 only).
--
-- ============================================================================================
-- TRUTH TABLE — get_ci_staff_performance_v1 (check 40, the Alice/Bob trap + the floor)
-- ============================================================================================
-- CI-STAT-AUTHORITY-CONTRACT: a rate-like verdict (revenue_per_visit_cents, the adjusted index,
-- and the expected-revenue figure behind it) is null whenever evidence.status is 'insufficient'
-- (n below the v672 floor, 5) — raw COUNTS (visits, revenue_cents) are never gated. Alice and Bob
-- both clear the floor at exactly 5 visits each; Carol is deliberately kept at 3 (insufficient)
-- so the null-below-floor path has a real, asserted example alongside the two real verdicts.
--
-- VISITS ARE DAYS (nestly_v699): get_ci_staff_performance_v1's 'visits' counts distinct (client,
-- Asia/Singapore calendar day) pairs per staff and service, not raw sale-item lines. Every sale
-- below is therefore dated on its OWN day (one sale per staff per day) — alice/bob/dave each get
-- five distinct days, carol three — so the "visits" figures in this truth table are visit-days by
-- construction, and the numbers are otherwise identical to the pre-v699 shape (this fixture never
-- relied on same-day multi-sale collapsing).
--
-- Service PREMIUM (firm-wide lines): alice x5 @ $100.00, carol x3 @ $100.00
--   -> firm avg ticket(PREMIUM) = (5*10000 + 3*10000) / 8 = 10000 (both sell at exactly the
--      firm average, by construction, so alice's index lands on exactly 1.00).
--   alice: visits=5 (evidence 'ok', floor 5), revenue=50000, revenue_per_visit=10000 (raw,
--          HIGHEST). expected = 5*10000 = 50000 -> index = 50000/50000 = 1.00.
--   carol: visits=3 (evidence 'insufficient', floor 5) -> unadjusted.revenue_per_visit_cents,
--          adjusted.expected_revenue_cents and adjusted.index are ALL null. visits=3 and
--          revenue_cents=30000 still appear (counts are never gated).
-- Service BASIC (firm-wide lines): bob x5 @ $50.00, dave x5 @ $20.00
--   -> firm avg ticket(BASIC) = (5*5000 + 5*2000) / 10 = 3500.
--   bob:   visits=5 (evidence 'ok'), revenue=25000, revenue_per_visit=5000 (raw, LOWER than
--          alice's 10000). expected = 5*3500 = 17500 -> index = 25000/17500 = 1.42857... ->
--          rounds 1.43 (> 1.00, beats the firm average for the mix bob actually sells).
--   dave:  visits=5 (evidence 'ok', not otherwise asserted), revenue=10000, revenue_per_visit=
--          2000. expected=5*3500=17500 -> index = 10000/17500 = 0.5714 -> rounds 0.57.
-- -> RANKING ASSERTION: raw revenue_per_visit orders alice(10000) > bob(5000); adjusted index
--    orders bob(1.43) > alice(1.00) — the two orderings disagree, which is the entire point of
--    the metric — and this comparison considers ONLY evidence-'ok' staff (carol's null index
--    cannot participate in any numeric ordering at all: NULL compared to anything is NULL, never
--    true, so she is excluded from the ranking by construction, not by an extra filter clause).
-- -> MUTATION CHECK: adding one more alice sale at a price BELOW the firm average for PREMIUM
--    (a discount) must pull alice's adjusted index below 1.00 while her raw revenue_per_visit
--    merely drops (it must not silently stay at exactly 1.00 — proves the index recomputes from
--    live data rather than being hardcoded to "top raw earner = 1.00"). Alice stays evidence-'ok'
--    throughout (6 visits after the mutation, still >= floor).
--
-- ============================================================================================
-- TRUTH TABLE — get_ci_rebooking_v1 (checks 51-53)
-- ============================================================================================
-- biz, window [today-100, today-1], window_days=60. Ten completed appointments, each with its
-- one linked sale at occurred_at = today-90 (visit_date), so every one is MATURE
-- (90+60=150 days in the past... wait: maturity rule is visit_date+60<=today i.e. today-90+60 =
-- today-30 <= today: true for all ten.
--   REBOOKED cohort (booked_from_appointment_id set at insert, 5 appointments):
--     3 on service SVC_A, 2 on service SVC_B. 3 of the 5 clients return within 60 days
--     (a further qualifying sale at occurred_at = today-90+20); 2 do not.
--     -> n=5, evidence n=5>=floor 5 -> 'ok'. within_window = rate_block(3,5) = 60.0%.
--     -> composition: SVC_A share = rate_block(3,5)=60.0%, SVC_B share = rate_block(2,5)=40.0%.
--   OTHER cohort (booked_from_appointment_id null, 5 appointments), all on SVC_A:
--     1 of the 5 clients returns within 60 days; 4 do not.
--     -> n=5, evidence 'ok'. within_window = rate_block(1,5) = 20.0%.
-- -> The two rates differ (60.0% vs 20.0%) — exactly the pattern the fixed limitation string
--    warns against over-reading as causal.
-- -> evidence_class = 'ASSOCIATION' always; limitation string present; the ENTIRE jsonb payload
--    (cast to text) must not contain the substring 'caused' anywhere.
-- -> WRITE-ONCE (check 51): a fresh appointment with booked_from_appointment_id NULL accepts
--    ONE link_rebooked_appointment_v1 call, then a SECOND call (even to the same source) must
--    raise (errcode 42501, "write-once").
--
-- ============================================================================================
-- TRUTH TABLE — get_ci_loyalty_programmes_v1 (checks 54-55)
-- ============================================================================================
-- v308's spine gives every business four rows (points/tiers/stamps/referral) the moment it is
-- created, so those four always resolve 'ready' (never 'not_configured') for a business that
-- exists at all -- this fixture proves that invariant rather than fighting it. welcome/birthday/
-- bring-back have NO spine row and, with no config row inserted for this business, must report
-- 'not_configured' honestly.
--
-- A business-specific v107 policy override (version_no=2, fallback_lapse_days=30,
-- effective_from well in the past) replaces the v107-migration default of 90 days, so every
-- client below (with only one or two lifetime visits, far below the min_observations=3 gate)
-- resolves through 'business_fallback' at exactly the 30-day threshold this truth table needs.
--
-- Eligible population is whatever app.ci_loyalty_eligible_v683 actually counts for this business
-- in the window [today-60, today-1] — read from the reader's own 'eligible_customers' field
-- (v_eligible below) rather than hardcoded, because six independent clients each contribute their
-- own qualifying sale to it (five points-story clients + one dedicated referral-story client, kept
-- separate on purpose: a shared client's redemption-window and cadence-window arithmetic collide
-- across programmes, which is exactly the trap this design avoids). v_eligible is asserted to
-- equal 6 directly (a straight count of the six clients seeded), so the "read from the reader"
-- choice is not a way to dodge a hardcoded assertion — it is cross-checked against one.
--
-- POINTS clients (5, all counted in the eligible set):
--   P1  sales at today-50 and today-25 (no other sales, ever). loyalty_redemptions row:
--       redeemed_at=today-40 (mature: 40>=30). Last sale before today-40 is today-50 (today-25 is
--       AFTER the redemption, excluded from "before") -> days_since=10<=30 -> 'within_cycle'.
--       today-25 falls inside the paid-return window (today-40, today-10] -> paid_return=true.
--   P2  sales at today-100 and today-5 (no others). loyalty_redemptions row: redeemed_at=today-45
--       (mature). Last sale before today-45 is today-100 (today-5 is after, excluded) ->
--       days_since=55>30 -> 'overdue'. today-5 is AFTER the paid-return window (today-45,today-15]
--       closes -> paid_return=false.
--   P3  one sale at today-30. loyalty_redemptions row: redeemed_at=today-10 (redeemed_at+30 =
--       today+20 > today -> IMMATURE) -> counted only in redemptions_total and immature.
--   P4  one sale at today-15, one points_ledger row (enrolled), no redemption.
--   P5  one sale at today-3, NO points_ledger row (not enrolled).
-- -> POINTS enrolled = P1,P2,P3,P4 = 4 of v_eligible.
-- -> redemptions_total=3, redemptions_mature=2 (P1,P2), immature=1 (P3).
-- -> paid_return_within_30d = rate_block(1,2) = 50.0% (P1 true, P2 false).
-- -> cannibalisation_proxy.within_cycle = rate_block(1,2) = 50.0% (P1 within_cycle, P2 overdue).
--
-- REFERRAL client RF1 — deliberately its OWN client, not reused from the points story, so its
-- redemption/cadence windows cannot collide with P1..P5's: exactly one sale, at today-45 (no
-- others, ever). One referrals row: referrer_client_id=RF1, status='rewarded',
-- qualified_at=today-35 (mature: 35>=30). RF1's only sale (today-45) is before qualification ->
-- days_since=10<=30 -> 'within_cycle'. RF1 has no OTHER sale at all, so none can fall inside the
-- paid-return window (today-35,today-5] -> paid_return=false.
-- -> REFERRAL enrolled = RF1 = 1 of v_eligible.
-- -> redemptions_total=1, redemptions_mature=1, immature=0.
-- -> paid_return_within_30d = rate_block(0,1) = 0.0%.
-- -> cannibalisation_proxy.within_cycle = rate_block(1,1) = 100.0%.
--
-- TIERS, STAMPS: spine row exists (status='ready') but NO tier_transition_events /
--   benefit_fulfilments / stamp_milestone_claims rows are seeded for this business -> enrolled=0,
--   redemptions_total=0, every rate_block has denominator/numerator 0 (pct null, per the v672
--   contract — never fabricated 0.0%).
--
-- WELCOME, BIRTHDAY, BRING-BACK: no config row exists for this business at all ->
--   status = 'not_configured' for all three.
--
-- ============================================================================================
-- TRUTH TABLE — get_ci_discount_dependency_v1 (checks 56-57)
-- ============================================================================================
-- biz, window [today-60, today-1]. Six identified clients, each visit a distinct sale with one
-- 'service' sale_items line and, on a discounted visit, a companion negative
-- item_type='studio_discount' line on the SAME sale:
--   D_organic     4 full-price visits, 0 discounted -> promotion_share=0%<20% -> 'organic'.
--   D_dependent   1 full-price, 4 discounted (5 total) -> share=80%>=60% -> 'discount_dependent'.
--   D_mixed       2 full-price, 2 discounted (4 total) -> share=50% (20%<=50%<60%) -> 'mixed'.
--   D_thin        2 full-price visits only (<3 total) -> 'insufficient'.
--   D_organic2    3 full-price visits, 0 discounted -> 'organic' (a SECOND organic customer, so
--                 the organic cell clears the k=5 small-cell floor together with D_organic —
--                 no, it needs 5 total organic to clear the floor; see below).
--   D_organic3..5 three more purely full-price clients (3 visits each) -> 'organic', bringing the
--                 organic class to 5 members total (D_organic, D_organic2..5), clearing the k=5
--                 floor so reminder_only_candidates is NOT suppressed.
-- -> classes: organic n=5, discount_dependent n=1, mixed n=1, insufficient n=1 (total 8).
-- -> full_price_repeat_customers (>=2 full-price visits): D_organic(3), D_organic2(3),
--    D_organic3(3), D_organic4(3), D_organic5(3), D_mixed(2), D_thin(2) = 7. D_dependent has only
--    1 full-price visit (excluded). Every organic client is given exactly 3 total visits (2
--    inter-visit intervals), deliberately kept BELOW the v107 policy's
--    customer_interval_min_observations=3 gate, so app.customer_cadence_v1 stays on the
--    business_fallback path (fallback_lapse_days=30, same override as the loyalty fixture) for
--    every organic client rather than switching to a customer-median-interval calculation that
--    this truth table does not attempt to hand-compute.
-- -> reminder_only_candidates: of the 5 organic clients, exactly D_organic (whose last visit is
--    far in the past, days_since > the business's fallback_lapse_days=30) is 'overdue' per
--    app.customer_cadence_v1 as of NOW; the other four organic clients visited recently and are
--    'within_cycle'. -> candidates = {D_organic}, n=1 (BELOW the k=5 floor) -> SUPPRESSED, with
--    cohort_size=1 reported. A second scenario in a separate business proves the un-suppressed
--    (>=5) path returns real client_id/full_name/action rows.
-- -> MUTATION CHECK: reclassifying one of D_mixed's full-price sales into a discounted one (by
--    adding a studio_discount line to it) must move D_mixed's promotion_share from 50% to a value
--    that changes its class boundary in the direction the added discount implies, and the
--    'mixed' class count must change accordingly.
--
-- ============================================================================================
-- TRUTH TABLE — get_ci_marketing_funnel_v1 (check 58)
-- ============================================================================================
-- biz, window [today-30, today-1]. Maturity for 'associated_purchase' requires
-- send_date+30<=today, i.e. send_date<=today-30 — inside a 30-day window that is only true at
-- the window's own earliest edge, so every "mature" send below is dated exactly today-30, and
-- the "immature" one is dated recently instead. Five campaign_send_records_v255 rows:
--   M1  channel=in_app, sent today-30 (mature), read (customer_in_app_inbox_state.read_at set),
--       client has a qualifying return sale at today-20 (within 30 days after the send).
--   M2  channel=in_app, sent today-30 (mature), NOT read, no return sale.
--   M3  channel=in_app, sent today-30 (mature), NOT read, no return sale.
--   M4  channel=web_push, sent today-30 (mature). No inbox row at all (web_push has none) --
--       excluded from the 'read' denominator (which is in_app-scoped), counted in 'sent' and in
--       the associated_purchase denominator.
--   M5  channel=web_push, sent today-5 — too recent to be mature (today-5+30=today+25>today) --
--       excluded from the associated_purchase rate's denominator, counted in 'immature'.
-- -> sent.count = 5. read: scope in_app only, rate_block(1,3) = 33.3% (M1 of M1/M2/M3).
-- -> associated_purchase: mature = 4 (M1..M4), returned = 1 (M1) -> rate_block(1,4) = 25.0%,
--    immature = 1 (M5).
-- -> contacted/queued/delivered/replied/redeemed all {'status':'not_observed'}; incremental
--    {'status':'unavailable'} (no growth_execution_results_v108 row for this business).

\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

-- ============================================================================================
-- SECTION A — staff identity (39) + mix-adjusted staff performance (40)
-- ============================================================================================
do $v683a$
declare
  biz         uuid := '00000000-0000-4000-8000-000000068301';
  branch1     uuid := '00000000-0000-4000-8000-000000068311';
  u_sa        uuid := '00000000-0000-4000-8000-000000068391';
  u_owner     uuid := '00000000-0000-4000-8000-000000068392';
  u_bob_login uuid := '00000000-0000-4000-8000-000000068393';
  st_owner    uuid := '00000000-0000-4000-8000-000000068381';
  st_alice    uuid := '00000000-0000-4000-8000-000000068382';
  st_bob      uuid := '00000000-0000-4000-8000-000000068383';
  st_carol    uuid := '00000000-0000-4000-8000-000000068384';
  st_dave     uuid := '00000000-0000-4000-8000-000000068385';
  cl_a        uuid := '00000000-0000-4000-8000-000000068321';
  cl_b        uuid := '00000000-0000-4000-8000-000000068322';
  cl_c        uuid := '00000000-0000-4000-8000-000000068323';
  svc_premium uuid := '00000000-0000-4000-8000-000000068341';
  svc_basic   uuid := '00000000-0000-4000-8000-000000068342';
  appt1       uuid := '00000000-0000-4000-8000-000000068351';
  sale_s1     uuid := '00000000-0000-4000-8000-000000068361';
  sale_s2     uuid := '00000000-0000-4000-8000-000000068362';
  sale_s3     uuid := '00000000-0000-4000-8000-000000068363';
  sale_s4     uuid := '00000000-0000-4000-8000-000000068364';
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_from date; v_to date;
  v_perf_from date; v_perf_to date;
  g jsonb; g2 jsonb;
  v_err text;
begin
  v_from := v_today - 10; v_to := v_today - 1;
  -- The mix-adjusted staff-performance check gets its OWN, narrower window: s1/s2/s3/s4 above
  -- (dated today-5..today-2) share this business and would otherwise leak into Bob's/Alice's
  -- visit counts here (s2 in particular is bob + svc_basic + $50, identical in shape to the
  -- mix-adjusted rows) since get_ci_staff_performance_v1 has no concept of "which sub-fixture a
  -- sale belongs to" -- only occurred_at and business_id. [today-11, today-6] holds only the
  -- deliberately-inserted rows below, now one PER DAY (nestly_v699: visits count distinct
  -- (client, Asia/Singapore calendar day) pairs, not raw sale-item lines — five distinct days
  -- gives alice/bob/dave their five visits and carol her three, and the spare today-11 slot is
  -- reserved for the mutation check's sixth alice sale below, without any row sharing a day with
  -- another row for the same staff member).
  v_perf_from := v_today - 11; v_perf_to := v_today - 6;

  insert into auth.users (id, email) values
    (u_sa, 'zz-v683-sa@example.test'),
    (u_owner, 'zz-v683-owner@example.test'),
    (u_bob_login, 'zz-v683-bob@example.test')
  on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v683-sa@example.test')
    on conflict do nothing;

  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v683 fixture', 'zz-v683-fixture',
          array['dashboard','clients','sales','reports','appointments','loyalty']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (branch1, biz, 'ZZ v683 branch one', true, true);

  -- Genuinely operational (app.business_workspace_open_v94, read by app.can_module_write via
  -- app.staff_module_mode_v94) -- needed only because set_actual_provider_v683 and
  -- link_rebooked_appointment_v1 require REAL staff write access, unlike the read-only ci_*
  -- functions which a super admin session satisfies outright.
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_by, decided_at, decision_reason)
  values (biz, 'approved', u_sa, now(), 'zz-v683 fixture')
    on conflict (business_id) do update set approval_status = 'approved',
      decided_by = u_sa, decided_at = now(), decision_reason = 'zz-v683 fixture';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state = 'current', workspace_paused = false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update set status = 'active', payment_status = 'paid',
      current_period_end = now() + interval '30 days';
  insert into public.staff (id, business_id, user_id, role, full_name, active) values
    (st_owner, biz, u_owner, 'owner', 'ZZ Owner', true),
    (st_alice, biz, null, 'staff', 'ZZ Alice', true),
    (st_bob,   biz, u_bob_login, 'staff', 'ZZ Bob', true),
    (st_carol, biz, null, 'staff', 'ZZ Carol', true),
    (st_dave,  biz, null, 'staff', 'ZZ Dave', true);
  insert into public.staff_branches (business_id, staff_id, branch_id)
  values (biz, st_owner, branch1), (biz, st_alice, branch1), (biz, st_bob, branch1),
         (biz, st_carol, branch1), (biz, st_dave, branch1);

  insert into public.clients (id, business_id, full_name) values
    (cl_a, biz, 'ZZ v683 client A'),
    (cl_b, biz, 'ZZ v683 client B'),
    (cl_c, biz, 'ZZ v683 client C');

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_premium, biz, 'ZZ Premium Facial', 10000, 60),
    (svc_basic, biz, 'ZZ Basic Trim', 3000, 20);

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  begin
    perform app.ci_access_gate_v667(biz, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PRE-gate', format('super admin cannot pass ci gate (sqlstate %s)', v_err));
  end;

  ------------------------------------------------------------------------------------------
  -- STAFF IDENTITY (check 39): appointment appt1 links s1; s2/s3 have no appointment; s4 is
  -- reversed and must be entirely excluded.
  ------------------------------------------------------------------------------------------
  insert into public.appointments
    (id, business_id, branch_id, client_id, staff_id, starts_at, ends_at, status, service_id)
  values (appt1, biz, branch1, cl_a, st_alice,
          (v_today - 5)::timestamp at time zone 'Asia/Singapore',
          (v_today - 5)::timestamp at time zone 'Asia/Singapore' + interval '1 hour',
          'completed', svc_premium);

  -- s1: appointment-linked, sales.staff_id=alice, explicit operator_user_id=u_owner.
  insert into public.sales
    (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at,
     appointment_id, staff_id, operator_user_id)
  values (sale_s1, biz, branch1, cl_a, 'service', 10000,
          (v_today - 5)::timestamp at time zone 'Asia/Singapore',
          (v_today - 5)::timestamp at time zone 'Asia/Singapore',
          appt1, st_alice, u_owner);
  insert into public.sale_items (sale_id, business_id, item_type, ref_id, qty, unit_cents, line_cents, staff_id)
  values (sale_s1, biz, 'service', svc_premium, 1, 10000, 10000, st_alice);

  -- s2: no appointment, staff_id=bob, one service line staff_id=bob, operator_user_id left
  -- unset at INSERT time (still under the super-admin session, since public.sales' own
  -- app.require_branch_module_v94 write-gate admits a super admin outright but refuses an
  -- ordinary staff session with no branch/module grant of its own — is_super_admin() is exactly
  -- the bypass v667's own gate reuses) -> trg_sales_operator_default_v683 fills it from
  -- auth.uid() = u_sa, proving the trigger defaults a genuinely-unset value rather than leaving
  -- it null.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at, staff_id)
  values (sale_s2, biz, branch1, cl_b, 'service', 5000,
          (v_today - 4)::timestamp at time zone 'Asia/Singapore',
          (v_today - 4)::timestamp at time zone 'Asia/Singapore', st_bob);
  insert into public.sale_items (sale_id, business_id, item_type, ref_id, qty, unit_cents, line_cents, staff_id)
  values (sale_s2, biz, 'service', svc_basic, 1, 5000, 5000, st_bob);

  -- s3: no appointment, no staff_id, no sale_items line, operator likewise defaulted (to u_sa,
  -- for the same reason as s2 above -- this fixture's session is always authenticated as SOME
  -- identity; a genuinely NULL operator_user_id only arises from a service-role write with no
  -- JWT claims at all, which this environment's own write-gate does not admit, so it is not
  -- exercised here. What IS proven: the trigger never leaves the column unset when a caller
  -- identity exists, and never overwrites an explicit value (s1) when one is supplied.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (sale_s3, biz, branch1, cl_c, 'service', 2000,
          (v_today - 3)::timestamp at time zone 'Asia/Singapore',
          (v_today - 3)::timestamp at time zone 'Asia/Singapore');

  -- s4: reversed, must be excluded entirely.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (sale_s4, biz, branch1, cl_a, 'service', 9000,
          (v_today - 2)::timestamp at time zone 'Asia/Singapore',
          (v_today - 2)::timestamp at time zone 'Asia/Singapore');
  perform set_config('app.sale_reversal_insert_id', '00000000-0000-4000-8000-000000068365'::text, true);
  perform set_config('app.sale_reversal_original_id', sale_s4::text, true);
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at,
                             reversal_of, reversal_reason, reversal_actor, reversal_idempotency_key)
  values ('00000000-0000-4000-8000-000000068365', biz, branch1, cl_a, 'service', -9000,
          (v_today - 2)::timestamp at time zone 'Asia/Singapore',
          (v_today - 2)::timestamp at time zone 'Asia/Singapore', sale_s4,
          'ZZ v683 fixture reversal', u_sa, gen_random_uuid());
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);

  -- set_actual_provider_v683 needs REAL staff-write access -> impersonate the owner.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);
  perform public.set_actual_provider_v683(biz, appt1, st_bob);

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  g := public.get_ci_staff_identity_v1(biz, v_from, v_to, null);
  if (g->'coverage'->>'total_sales')::int is distinct from 3 then
    insert into _fail values ('39-total', format('expected 3, got %s', g->'coverage'->>'total_sales'));
  end if;
  if (g->'coverage'->'booked_staff_id'->>'numerator')::int is distinct from 1 then
    insert into _fail values ('39-booked', g->'coverage'->'booked_staff_id'->>'numerator');
  end if;
  if (g->'coverage'->'credited_staff_id'->>'numerator')::int is distinct from 2 then
    insert into _fail values ('39-credited', g->'coverage'->'credited_staff_id'->>'numerator');
  end if;
  if (g->'coverage'->'line_staff'->>'numerator')::int is distinct from 2 then
    insert into _fail values ('39-line', g->'coverage'->'line_staff'->>'numerator');
  end if;
  if (g->'coverage'->'operator_user_id'->>'numerator')::int is distinct from 3 then
    insert into _fail values ('39-operator', g->'coverage'->'operator_user_id'->>'numerator');
  end if;
  if (g->'coverage'->'actual_provider'->>'numerator')::int is distinct from 1 then
    insert into _fail values ('39-actual-provider', g->'coverage'->'actual_provider'->>'numerator');
  end if;
  if not exists (select 1 from jsonb_array_elements(g->'sales') e
                  where (e->>'sale_id')::uuid = sale_s1
                    and (e->>'booked_staff_id')::uuid = st_alice
                    and (e->>'actual_provider')::uuid = st_bob) then
    insert into _fail values ('39-s1-row', 'sale_s1 does not carry booked=alice/actual=bob');
  end if;

  ------------------------------------------------------------------------------------------
  -- MIX-ADJUSTED STAFF PERFORMANCE (check 40) — the Alice/Bob trap.
  ------------------------------------------------------------------------------------------
  -- One sale per service line, fixed ids, so staff attribution can be inserted with certainty:
  -- alice x5 + carol x3 on PREMIUM ($100 each, so alice AND carol clear the floor/miss it
  -- respectively); bob x5 + dave x5 on BASIC ($50/$20, so both clear the floor). nestly_v699:
  -- get_ci_staff_performance_v1's 'visits' now counts distinct (client, Asia/Singapore calendar
  -- day) pairs, not raw sale-item lines, so each staff member's own sales are spread across
  -- DISTINCT days (day_offset below) rather than all landing on today-7 as before — the truth
  -- table (alice/bob/dave 5 visits, carol 3) is unchanged; only the day each row falls on moved.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-0000000684' || lpad(n::text, 2, '0'))::uuid,
         biz, branch1, cl_b, 'service', cents,
         (v_today + day_offset)::timestamp at time zone 'Asia/Singapore',
         (v_today + day_offset)::timestamp at time zone 'Asia/Singapore'
    from (values
      (1, 10000, -10),(2, 10000, -9),(3, 10000, -8),(4, 10000, -7),(5, 10000, -6),
      (6, 10000, -10),(7, 10000, -9),(8, 10000, -8),
      (9, 5000, -10),(10, 5000, -9),(11, 5000, -8),(12, 5000, -7),(13, 5000, -6),
      (14, 2000, -10),(15, 2000, -9),(16, 2000, -8),(17, 2000, -7),(18, 2000, -6)
    ) as t(n, cents, day_offset)
  on conflict (id) do nothing;

  insert into public.sale_items (sale_id, business_id, item_type, ref_id, qty, unit_cents, line_cents, staff_id)
  select ('00000000-0000-4000-8000-0000000684' || lpad(n::text, 2, '0'))::uuid,
         biz, 'service', service_id, 1, cents, cents, staff_id
    from (values
      (1, svc_premium, 10000, st_alice),(2, svc_premium, 10000, st_alice),(3, svc_premium, 10000, st_alice),
      (4, svc_premium, 10000, st_alice),(5, svc_premium, 10000, st_alice),
      (6, svc_premium, 10000, st_carol),(7, svc_premium, 10000, st_carol),(8, svc_premium, 10000, st_carol),
      (9, svc_basic, 5000, st_bob),(10, svc_basic, 5000, st_bob),(11, svc_basic, 5000, st_bob),
      (12, svc_basic, 5000, st_bob),(13, svc_basic, 5000, st_bob),
      (14, svc_basic, 2000, st_dave),(15, svc_basic, 2000, st_dave),(16, svc_basic, 2000, st_dave),
      (17, svc_basic, 2000, st_dave),(18, svc_basic, 2000, st_dave)
    ) as t(n, service_id, cents, staff_id)
  on conflict do nothing;

  g := public.get_ci_staff_performance_v1(biz, v_perf_from, v_perf_to, null);

  if not exists (select 1 from jsonb_array_elements(g->'staff') e
                  where (e->>'staff_id')::uuid = st_alice
                    and (e->'evidence'->>'status') = 'ok'
                    and (e->'unadjusted'->>'visits')::int = 5
                    and (e->'unadjusted'->>'revenue_per_visit_cents')::numeric = 10000
                    and (e->'adjusted'->>'index')::numeric = 1.00) then
    insert into _fail values ('40-alice',
      'alice must be evidence ok, raw revenue_per_visit=10000, adjusted index=1.00: ' ||
      coalesce((select e::text from jsonb_array_elements(g->'staff') e where (e->>'staff_id')::uuid=st_alice), 'MISSING'));
  end if;
  if not exists (select 1 from jsonb_array_elements(g->'staff') e
                  where (e->>'staff_id')::uuid = st_bob
                    and (e->'evidence'->>'status') = 'ok'
                    and (e->'unadjusted'->>'visits')::int = 5
                    and (e->'unadjusted'->>'revenue_per_visit_cents')::numeric = 5000
                    and (e->'adjusted'->>'index')::numeric = 1.43) then
    insert into _fail values ('40-bob',
      'bob must be evidence ok, raw revenue_per_visit=5000, adjusted index=1.43: ' ||
      coalesce((select e::text from jsonb_array_elements(g->'staff') e where (e->>'staff_id')::uuid=st_bob), 'MISSING'));
  end if;
  -- CI-STAT-AUTHORITY-CONTRACT: carol has only 3 visits (below the floor of 5) -> evidence
  -- 'insufficient'. Her raw COUNTS (visits, revenue_cents) still appear; every rate-like verdict
  -- derived from them (revenue_per_visit_cents, adjusted.expected_revenue_cents, adjusted.index)
  -- must be null rather than a number computed from below-floor evidence.
  if not exists (select 1 from jsonb_array_elements(g->'staff') e
                  where (e->>'staff_id')::uuid = st_carol
                    and (e->'evidence'->>'status') = 'insufficient'
                    and (e->'evidence'->>'n')::int = 3
                    and (e->'unadjusted'->>'visits')::int = 3
                    and (e->'unadjusted'->>'revenue_cents')::int = 30000
                    and (e->'unadjusted'->'revenue_per_visit_cents') = 'null'::jsonb
                    and (e->'adjusted'->'expected_revenue_cents') = 'null'::jsonb
                    and (e->'adjusted'->'index') = 'null'::jsonb) then
    insert into _fail values ('40-carol-insufficient',
      'carol (3 visits, below floor) must show counts with every rate-like field null: ' ||
      coalesce((select e::text from jsonb_array_elements(g->'staff') e where (e->>'staff_id')::uuid=st_carol), 'MISSING'));
  end if;
  -- RANKING ASSERTION: raw orders alice above bob; adjusted orders bob above alice. This
  -- comparison only ever touches evidence-'ok' staff (alice, bob) — carol's null index cannot
  -- win or lose any numeric comparison (NULL op anything is NULL, never true), so she is excluded
  -- from the ranking by construction rather than by an explicit "where evidence='ok'" filter.
  if not (
    (select (e->'unadjusted'->>'revenue_per_visit_cents')::numeric from jsonb_array_elements(g->'staff') e where (e->>'staff_id')::uuid=st_alice)
    >
    (select (e->'unadjusted'->>'revenue_per_visit_cents')::numeric from jsonb_array_elements(g->'staff') e where (e->>'staff_id')::uuid=st_bob)
    and
    (select (e->'adjusted'->>'index')::numeric from jsonb_array_elements(g->'staff') e where (e->>'staff_id')::uuid=st_bob)
    >
    (select (e->'adjusted'->>'index')::numeric from jsonb_array_elements(g->'staff') e where (e->>'staff_id')::uuid=st_alice)
  ) then
    insert into _fail values ('40-ranking', 'raw and adjusted rankings must disagree between alice and bob');
  end if;
  if exists (select 1 from jsonb_array_elements(g->'staff') e
              where (e->>'staff_id')::uuid = st_carol
                and ((e->'adjusted'->>'index') is not null)) then
    insert into _fail values ('40-carol-ranking-leak', 'carol (insufficient evidence) must never carry a non-null index');
  end if;

  -- MUTATION CHECK: one more alice sale on PREMIUM at a discount price (6000, well below the
  -- firm average of 10000) must pull her adjusted index below 1.00. Alice has 6 visits after
  -- this (still >= floor 5), so she stays evidence-'ok' throughout. Dated today-11 — the one day
  -- in [v_perf_from, v_perf_to] none of alice's five base-truth-table sales already occupies —
  -- so this is a genuine SIXTH distinct visit-day, not a second same-day sale that would leave
  -- her visit count at 5 under nestly_v699's per-day counting.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values ('00000000-0000-4000-8000-000000068499', biz, branch1, cl_b, 'service', 6000,
          (v_today - 11)::timestamp at time zone 'Asia/Singapore',
          (v_today - 11)::timestamp at time zone 'Asia/Singapore');
  insert into public.sale_items (sale_id, business_id, item_type, ref_id, qty, unit_cents, line_cents, staff_id)
  values ('00000000-0000-4000-8000-000000068499', biz, 'service', svc_premium, 1, 6000, 6000, st_alice);

  g2 := public.get_ci_staff_performance_v1(biz, v_perf_from, v_perf_to, null);
  if not (
    (select (e->'adjusted'->>'index')::numeric from jsonb_array_elements(g2->'staff') e where (e->>'staff_id')::uuid=st_alice)
    <
    (select (e->'adjusted'->>'index')::numeric from jsonb_array_elements(g->'staff') e where (e->>'staff_id')::uuid=st_alice)
  ) then
    insert into _fail values ('40-mutation',
      'adding a below-average alice sale must lower her adjusted index, not leave it unchanged');
  end if;
end
$v683a$;

-- ============================================================================================
-- SECTION B — rebooking (checks 51-53)
-- ============================================================================================
do $v683b$
declare
  biz         uuid := '00000000-0000-4000-8000-000000068501';
  branch1     uuid := '00000000-0000-4000-8000-000000068511';
  u_sa        uuid := '00000000-0000-4000-8000-000000068391';
  u_owner     uuid := '00000000-0000-4000-8000-000000068392';
  st_owner    uuid := '00000000-0000-4000-8000-000000068581';
  svc_a       uuid := '00000000-0000-4000-8000-000000068541';
  svc_b       uuid := '00000000-0000-4000-8000-000000068542';
  appt_src    uuid := '00000000-0000-4000-8000-000000068590';
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_from date; v_to date;
  g jsonb;
  i integer;
  cl uuid; appt uuid; sale uuid;
  svc uuid; returns_flag boolean;
  wo_appt uuid := '00000000-0000-4000-8000-000000068595';
  wo_src1 uuid := '00000000-0000-4000-8000-000000068596';
  wo_src2 uuid := '00000000-0000-4000-8000-000000068597';
  v_err text;
begin
  v_from := v_today - 100; v_to := v_today - 1;

  insert into auth.users (id, email) values
    (u_sa, 'zz-v683-sa@example.test'),
    (u_owner, 'zz-v683-owner@example.test')
  on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v683-sa@example.test')
    on conflict do nothing;

  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v683 rebooking fixture', 'zz-v683-rebooking',
          array['dashboard','clients','sales','reports','appointments']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (branch1, biz, 'ZZ v683 rebooking branch', true, true);

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_by, decided_at, decision_reason)
  values (biz, 'approved', u_sa, now(), 'zz-v683 fixture')
    on conflict (business_id) do update set approval_status = 'approved',
      decided_by = u_sa, decided_at = now(), decision_reason = 'zz-v683 fixture';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state = 'current', workspace_paused = false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update set status = 'active', payment_status = 'paid',
      current_period_end = now() + interval '30 days';
  insert into public.staff (id, business_id, user_id, role, full_name, active) values
    (st_owner, biz, u_owner, 'owner', 'ZZ Owner', true);
  insert into public.staff_branches (business_id, staff_id, branch_id)
  values (biz, st_owner, branch1);

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_a, biz, 'ZZ Rebook Service A', 5000, 30),
    (svc_b, biz, 'ZZ Rebook Service B', 8000, 45);

  -- Real staff-write access is needed for link_rebooked_appointment_v1.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);

  -- A dummy earlier "source" appointment every rebooked row links back to.
  -- cl_src: the client of the dummy source appointment.
  declare cl_src uuid := '00000000-0000-4000-8000-000000068598';
  begin
    insert into public.clients (id, business_id, full_name) values (cl_src, biz, 'ZZ v683 rebook src client');
    insert into public.appointments
      (id, business_id, branch_id, client_id, staff_id, starts_at, ends_at, status, service_id, created_at)
    values (appt_src, biz, branch1, cl_src, st_owner,
            (v_today - 200)::timestamp at time zone 'Asia/Singapore',
            (v_today - 200)::timestamp at time zone 'Asia/Singapore' + interval '1 hour',
            'completed', svc_a, now() - interval '200 days');
  end;

  -- REBOOKED cohort: 5 appointments, 3xSVC_A (return), 2xSVC_B (r4,r5 no return except r3 returns per plan).
  for i in 1..5 loop
    cl := ('00000000-0000-4000-8000-0000000685' || (60 + i)::text)::uuid;
    appt := ('00000000-0000-4000-8000-0000000685' || (50 + i)::text)::uuid;
    sale := ('00000000-0000-4000-8000-0000000685' || (70 + i)::text)::uuid;
    svc := case when i <= 3 then svc_a else svc_b end;
    returns_flag := (i <= 3); -- r1,r2,r3 return within window; r4,r5 do not

    insert into public.clients (id, business_id, full_name)
    values (cl, biz, 'ZZ v683 rebooked client ' || i);

    insert into public.appointments
      (id, business_id, branch_id, client_id, staff_id, starts_at, ends_at, status, service_id, created_at)
    values (appt, biz, branch1, cl, st_owner,
            (v_today - 90)::timestamp at time zone 'Asia/Singapore',
            (v_today - 90)::timestamp at time zone 'Asia/Singapore' + interval '1 hour',
            'completed', svc, now() - interval '95 days');

    perform public.link_rebooked_appointment_v1(biz, appt, appt_src);

    insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                              occurred_at, created_at, appointment_id)
    values (sale, biz, branch1, cl, 'service', 5000,
            (v_today - 90)::timestamp at time zone 'Asia/Singapore',
            (v_today - 90)::timestamp at time zone 'Asia/Singapore', appt);

    if returns_flag then
      insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
      values (('00000000-0000-4000-8000-0000000685' || (80 + i)::text)::uuid, biz, branch1, cl,
              'service', 3000,
              (v_today - 70)::timestamp at time zone 'Asia/Singapore',
              (v_today - 70)::timestamp at time zone 'Asia/Singapore');
    end if;
  end loop;

  -- OTHER cohort: 5 appointments, all SVC_A, no rebooking link. Only o1 returns.
  for i in 1..5 loop
    cl := ('00000000-0000-4000-8000-0000000686' || (10 + i)::text)::uuid;
    appt := ('00000000-0000-4000-8000-0000000686' || (20 + i)::text)::uuid;
    sale := ('00000000-0000-4000-8000-0000000686' || (30 + i)::text)::uuid;
    returns_flag := (i = 1);

    insert into public.clients (id, business_id, full_name)
    values (cl, biz, 'ZZ v683 other client ' || i);

    insert into public.appointments
      (id, business_id, branch_id, client_id, staff_id, starts_at, ends_at, status, service_id, created_at)
    values (appt, biz, branch1, cl, st_owner,
            (v_today - 90)::timestamp at time zone 'Asia/Singapore',
            (v_today - 90)::timestamp at time zone 'Asia/Singapore' + interval '1 hour',
            'completed', svc_a, now() - interval '95 days');

    insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                              occurred_at, created_at, appointment_id)
    values (sale, biz, branch1, cl, 'service', 5000,
            (v_today - 90)::timestamp at time zone 'Asia/Singapore',
            (v_today - 90)::timestamp at time zone 'Asia/Singapore', appt);

    if returns_flag then
      insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
      values (('00000000-0000-4000-8000-0000000686' || (40 + i)::text)::uuid, biz, branch1, cl,
              'service', 3000,
              (v_today - 70)::timestamp at time zone 'Asia/Singapore',
              (v_today - 70)::timestamp at time zone 'Asia/Singapore');
    end if;
  end loop;

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  g := public.get_ci_rebooking_v1(biz, v_from, v_to, null);

  if (g->'cohorts'->'rebooked_at_departure'->>'n')::int is distinct from 5 then
    insert into _fail values ('51-rebooked-n', g->'cohorts'->'rebooked_at_departure'->>'n');
  end if;
  if (g->'cohorts'->'rebooked_at_departure'->'within_window'->>'numerator')::int is distinct from 3
     or (g->'cohorts'->'rebooked_at_departure'->'within_window'->>'denominator')::int is distinct from 5 then
    insert into _fail values ('51-rebooked-within', g->'cohorts'->'rebooked_at_departure'->'within_window');
  end if;
  if (g->'cohorts'->'other'->>'n')::int is distinct from 5 then
    insert into _fail values ('51-other-n', g->'cohorts'->'other'->>'n');
  end if;
  if (g->'cohorts'->'other'->'within_window'->>'numerator')::int is distinct from 1
     or (g->'cohorts'->'other'->'within_window'->>'denominator')::int is distinct from 5 then
    insert into _fail values ('51-other-within', g->'cohorts'->'other'->'within_window');
  end if;

  -- composition: SVC_A 3/5, SVC_B 2/5 for the rebooked cohort.
  if not exists (select 1 from jsonb_array_elements(g->'cohorts'->'rebooked_at_departure'->'composition') e
                  where (e->>'service_id')::uuid = svc_a
                    and (e->'share'->>'numerator')::int = 3 and (e->'share'->>'denominator')::int = 5) then
    insert into _fail values ('52-composition-a', g->'cohorts'->'rebooked_at_departure'->'composition');
  end if;
  if not exists (select 1 from jsonb_array_elements(g->'cohorts'->'rebooked_at_departure'->'composition') e
                  where (e->>'service_id')::uuid = svc_b
                    and (e->'share'->>'numerator')::int = 2 and (e->'share'->>'denominator')::int = 5) then
    insert into _fail values ('52-composition-b', g->'cohorts'->'rebooked_at_departure'->'composition');
  end if;

  if (g->>'evidence_class') is distinct from 'ASSOCIATION' then
    insert into _fail values ('53-evidence-class', g->>'evidence_class');
  end if;
  if (g->>'limitation') is null or (g->>'limitation') = '' then
    insert into _fail values ('53-limitation-missing', 'no limitation string');
  end if;
  if (g::text) ilike '%caused%' then
    insert into _fail values ('53-caused-wording', 'payload must never claim causation');
  end if;

  -- WRITE-ONCE (check 51): fresh appointment, first link succeeds, second link (even to the
  -- same source) must raise 42501.
  insert into public.clients (id, business_id, full_name)
  values ('00000000-0000-4000-8000-000000068599', biz, 'ZZ v683 write-once client');
  insert into public.appointments
    (id, business_id, branch_id, client_id, staff_id, starts_at, ends_at, status, service_id, created_at)
  values (wo_src1, biz, branch1, '00000000-0000-4000-8000-000000068599', st_owner,
          (v_today - 200)::timestamp at time zone 'Asia/Singapore',
          (v_today - 200)::timestamp at time zone 'Asia/Singapore' + interval '1 hour',
          'completed', svc_a, now() - interval '250 days'),
         (wo_src2, biz, branch1, '00000000-0000-4000-8000-000000068599', st_owner,
          (v_today - 199)::timestamp at time zone 'Asia/Singapore',
          (v_today - 199)::timestamp at time zone 'Asia/Singapore' + interval '1 hour',
          'completed', svc_a, now() - interval '240 days'),
         (wo_appt, biz, branch1, '00000000-0000-4000-8000-000000068599', st_owner,
          (v_today - 5)::timestamp at time zone 'Asia/Singapore',
          (v_today - 5)::timestamp at time zone 'Asia/Singapore' + interval '1 hour',
          'completed', svc_a, now() - interval '4 days');

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);

  perform public.link_rebooked_appointment_v1(biz, wo_appt, wo_src1);

  begin
    perform public.link_rebooked_appointment_v1(biz, wo_appt, wo_src2);
    insert into _fail values ('51-write-once', 'a second link call must raise, but it succeeded');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err is distinct from '42501' then
      insert into _fail values ('51-write-once-sqlstate', format('expected 42501, got %s', v_err));
    end if;
  end;
end
$v683b$;

-- ============================================================================================
-- SECTION B2 — rebooking below the floor (CI-STAT-AUTHORITY-CONTRACT null-below-floor case)
-- ============================================================================================
-- Section B's own cohorts both clear the floor (n_mature=5 each, floor 5) by design — the whole
-- point there is a real, non-null 60% vs 20% contrast. This tiny separate business supplies the
-- OTHER half of the contract: a rebooked cohort with only 2 mature appointments (below the floor)
-- must still report its raw n=2 while within_window.pct is null.
do $v683b2$
declare
  biz     uuid := '00000000-0000-4000-8000-000000068a91';
  branch1 uuid := '00000000-0000-4000-8000-000000068a92';
  u_sa    uuid := '00000000-0000-4000-8000-000000068391';
  u_owner uuid := '00000000-0000-4000-8000-000000068a93';
  st_owner uuid := '00000000-0000-4000-8000-000000068a94';
  cl1 uuid := '00000000-0000-4000-8000-000000068a95';
  cl2 uuid := '00000000-0000-4000-8000-000000068a96';
  appt_src uuid := '00000000-0000-4000-8000-000000068a97';
  appt1 uuid := '00000000-0000-4000-8000-000000068a98';
  appt2 uuid := '00000000-0000-4000-8000-000000068a99';
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_from date; v_to date;
  g jsonb;
begin
  v_from := v_today - 100; v_to := v_today - 1;

  insert into auth.users (id, email) values
    (u_sa, 'zz-v683-sa@example.test'), (u_owner, 'zz-v683-b2-owner@example.test')
  on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v683-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v683 rebooking floor fixture', 'zz-v683-rebooking-floor',
          array['dashboard','clients','sales','reports','appointments']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (branch1, biz, 'ZZ v683 rebooking floor branch', true, true);
  -- Genuinely operational (see the fixture guide): link_rebooked_appointment_v1's write-gate
  -- (app.can_module_write) needs an approved, non-paused, paid workspace, not just a staff row.
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_by, decided_at, decision_reason)
  values (biz, 'approved', u_sa, now(), 'zz-v683 fixture')
    on conflict (business_id) do update set approval_status = 'approved',
      decided_by = u_sa, decided_at = now(), decision_reason = 'zz-v683 fixture';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state = 'current', workspace_paused = false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update set status = 'active', payment_status = 'paid',
      current_period_end = now() + interval '30 days';
  insert into public.staff (id, business_id, user_id, role, full_name, active) values
    (st_owner, biz, u_owner, 'owner', 'ZZ B2 Owner', true);
  insert into public.staff_branches (business_id, staff_id, branch_id) values (biz, st_owner, branch1);
  insert into public.clients (id, business_id, full_name) values
    (cl1, biz, 'ZZ v683 b2 client 1'), (cl2, biz, 'ZZ v683 b2 client 2');

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);

  insert into public.appointments
    (id, business_id, branch_id, client_id, staff_id, starts_at, ends_at, status, created_at)
  values (appt_src, biz, branch1, cl1, st_owner,
          (v_today - 200)::timestamp at time zone 'Asia/Singapore',
          (v_today - 200)::timestamp at time zone 'Asia/Singapore' + interval '1 hour',
          'completed', now() - interval '200 days');

  -- Two rebooked, mature appointments -- below the k=5 floor on purpose.
  insert into public.appointments
    (id, business_id, branch_id, client_id, staff_id, starts_at, ends_at, status, created_at)
  values
    (appt1, biz, branch1, cl1, st_owner,
     (v_today - 90)::timestamp at time zone 'Asia/Singapore',
     (v_today - 90)::timestamp at time zone 'Asia/Singapore' + interval '1 hour',
     'completed', now() - interval '95 days'),
    (appt2, biz, branch1, cl2, st_owner,
     (v_today - 90)::timestamp at time zone 'Asia/Singapore',
     (v_today - 90)::timestamp at time zone 'Asia/Singapore' + interval '1 hour',
     'completed', now() - interval '95 days');
  perform public.link_rebooked_appointment_v1(biz, appt1, appt_src);
  perform public.link_rebooked_appointment_v1(biz, appt2, appt_src);

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at, appointment_id)
  values
    (gen_random_uuid(), biz, branch1, cl1, 'service', 5000,
     (v_today - 90)::timestamp at time zone 'Asia/Singapore',
     (v_today - 90)::timestamp at time zone 'Asia/Singapore', appt1),
    (gen_random_uuid(), biz, branch1, cl2, 'service', 5000,
     (v_today - 90)::timestamp at time zone 'Asia/Singapore',
     (v_today - 90)::timestamp at time zone 'Asia/Singapore', appt2);

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  g := public.get_ci_rebooking_v1(biz, v_from, v_to, null);

  if (g->'cohorts'->'rebooked_at_departure'->>'n')::int is distinct from 2 then
    insert into _fail values ('51b-floor-n', g->'cohorts'->'rebooked_at_departure'->>'n');
  end if;
  if (g->'cohorts'->'rebooked_at_departure'->'evidence'->>'status') is distinct from 'insufficient' then
    insert into _fail values ('51b-floor-evidence', g->'cohorts'->'rebooked_at_departure'->'evidence');
  end if;
  if (g->'cohorts'->'rebooked_at_departure'->'within_window'->>'numerator')::int is distinct from 0
     or (g->'cohorts'->'rebooked_at_departure'->'within_window'->>'denominator')::int is distinct from 2 then
    insert into _fail values ('51b-floor-counts', g->'cohorts'->'rebooked_at_departure'->'within_window');
  end if;
  if (g->'cohorts'->'rebooked_at_departure'->'within_window'->>'pct') is not null then
    insert into _fail values ('51b-floor-pct-not-null',
      'n_mature=2 is below the floor of 5 -- within_window.pct must be null, counts (0,2) may stand');
  end if;
end
$v683b2$;

-- Top-level helper: app.customer_cadence_v1 (v651) resolves a per-branch timezone/currency
-- "reporting contract" (app.v106_reporting_contract) whose FIRST version is auto-created by a
-- trigger on the businesses/branches insert with effective_from = transaction_timestamp() — i.e.
-- essentially "now", the instant this whole test's outer transaction began. Every sale in these
-- fixtures is backdated (occurred_at 30-100+ days in the past), so effective_from<=occurred_at
-- fails for that auto-row on every one of them and the cadence/residual machinery silently sees
-- zero visits ("no paid visit on record") rather than erroring — a second, EARLIER version for
-- the (business, branch) pair the sales actually use fixes it the same way the v107 policy
-- override does, and for the same reason: an append-only, effective-dated table needs a row
-- whose effective_from actually predates the historical facts being read.
create or replace procedure zz_v683_seed_reporting_contract(p_biz uuid, p_branch uuid)
language plpgsql as $$
begin
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  values (p_biz, p_branch, 2, '2020-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', 'SGD', false);
end;
$$;

-- Top-level helper: points_ledger is guarded by app.loyalty_ledger_write_guard (v20/v34), which
-- demands a matching (app.points_ledger_insert_id, app.points_ledger_write_scope) GUC pair and,
-- for the 'adjust_points' scope, that new.actor equals the calling session's own auth.uid(). Used
-- here purely to mark a client "enrolled" (a points_ledger row exists), not to test earning itself.
create or replace procedure zz_v683_mk_points_ledger(p_biz uuid, p_client uuid, p_actor uuid)
language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
  v_programme uuid;
begin
  -- v313 retired the v309 auto-tag trigger ("every money writer is explicit") -- programme_id
  -- must be supplied directly; it is the business's own points-kind row on the v308 spine.
  select id into v_programme from public.business_programmes
   where business_id = p_biz and kind = 'points';
  perform set_config('app.points_ledger_insert_id', v_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
  insert into public.points_ledger (id, business_id, client_id, entry_type, points, actor, programme_id)
  values (v_id, p_biz, p_client, 'adjust', 100, p_actor, v_programme);
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
end;
$$;

-- ============================================================================================
-- SECTION C — loyalty programme value (checks 54-55)
-- ============================================================================================
do $v683c$
declare
  biz      uuid := '00000000-0000-4000-8000-000000068701';
  branch1  uuid := '00000000-0000-4000-8000-000000068711';
  u_sa     uuid := '00000000-0000-4000-8000-000000068391';
  cl_p1    uuid := '00000000-0000-4000-8000-000000068721';
  cl_p2    uuid := '00000000-0000-4000-8000-000000068722';
  cl_p3    uuid := '00000000-0000-4000-8000-000000068723';
  cl_p4    uuid := '00000000-0000-4000-8000-000000068724';
  cl_p5    uuid := '00000000-0000-4000-8000-000000068725';
  cl_rf1   uuid := '00000000-0000-4000-8000-000000068726';
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_from date; v_to date;
  g jsonb;
  v_eligible integer;
begin
  v_from := v_today - 60; v_to := v_today - 1;

  insert into auth.users (id, email) values (u_sa, 'zz-v683-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v683-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v683 loyalty fixture', 'zz-v683-loyalty',
          array['dashboard','clients','sales','reports','loyalty']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (branch1, biz, 'ZZ v683 loyalty branch', true, true);
  call zz_v683_seed_reporting_contract(biz, branch1);

  -- Business-specific v107 lapse policy override: fallback_lapse_days=30 (the v107-migration
  -- default is 90). Append-only table; version_no=2, effective_from safely before every test
  -- timestamp below so it is chosen over the version_no=1 default (-infinity) for every as_of
  -- this fixture uses.
  insert into public.customer_lifecycle_policies_v107
    (business_id, version_no, effective_from, fallback_lapse_days,
     customer_interval_min_observations, reactivation_multiplier, note, legacy_assumption)
  values (biz, 2, now() - interval '400 days', 30, 3, 2.000, 'zz-v683 fixture override', false);

  insert into public.clients (id, business_id, full_name) values
    (cl_p1, biz, 'ZZ v683 loyalty P1'),
    (cl_p2, biz, 'ZZ v683 loyalty P2'),
    (cl_p3, biz, 'ZZ v683 loyalty P3'),
    (cl_p4, biz, 'ZZ v683 loyalty P4'),
    (cl_p5, biz, 'ZZ v683 loyalty P5'),
    (cl_rf1, biz, 'ZZ v683 loyalty RF1');

  -- P1: sales at today-50, today-25 (no others, ever).
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (gen_random_uuid(), biz, branch1, cl_p1, 'service', 5000,
     (v_today - 50)::timestamp at time zone 'Asia/Singapore', (v_today - 50)::timestamp at time zone 'Asia/Singapore'),
    (gen_random_uuid(), biz, branch1, cl_p1, 'service', 5000,
     (v_today - 25)::timestamp at time zone 'Asia/Singapore', (v_today - 25)::timestamp at time zone 'Asia/Singapore');
  call zz_v683_mk_points_ledger(biz, cl_p1, u_sa);
  insert into public.loyalty_redemptions
    (business_id, client_id, reward_name, points_spent, credit_cents, consumes_balance, fulfillment_kind, redeemed_at, reward_snapshot)
  values (biz, cl_p1, 'ZZ v683 P1 reward', 50, 0, true, 'manual_item',
          (v_today - 40)::timestamp at time zone 'Asia/Singapore', jsonb_build_object('x', 1));

  -- P2: sales at today-100, today-5 (no others).
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (gen_random_uuid(), biz, branch1, cl_p2, 'service', 5000,
     (v_today - 100)::timestamp at time zone 'Asia/Singapore', (v_today - 100)::timestamp at time zone 'Asia/Singapore'),
    (gen_random_uuid(), biz, branch1, cl_p2, 'service', 5000,
     (v_today - 5)::timestamp at time zone 'Asia/Singapore', (v_today - 5)::timestamp at time zone 'Asia/Singapore');
  call zz_v683_mk_points_ledger(biz, cl_p2, u_sa);
  insert into public.loyalty_redemptions
    (business_id, client_id, reward_name, points_spent, credit_cents, consumes_balance, fulfillment_kind, redeemed_at, reward_snapshot)
  values (biz, cl_p2, 'ZZ v683 P2 reward', 50, 0, true, 'manual_item',
          (v_today - 45)::timestamp at time zone 'Asia/Singapore', jsonb_build_object('x', 1));

  -- P3: one sale at today-30. Immature redemption at today-10.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, branch1, cl_p3, 'service', 5000,
          (v_today - 30)::timestamp at time zone 'Asia/Singapore', (v_today - 30)::timestamp at time zone 'Asia/Singapore');
  call zz_v683_mk_points_ledger(biz, cl_p3, u_sa);
  insert into public.loyalty_redemptions
    (business_id, client_id, reward_name, points_spent, credit_cents, consumes_balance, fulfillment_kind, redeemed_at, reward_snapshot)
  values (biz, cl_p3, 'ZZ v683 P3 reward', 50, 0, true, 'manual_item',
          (v_today - 10)::timestamp at time zone 'Asia/Singapore', jsonb_build_object('x', 1));

  -- P4: one sale at today-15, enrolled (points_ledger row), no redemption.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, branch1, cl_p4, 'service', 5000,
          (v_today - 15)::timestamp at time zone 'Asia/Singapore', (v_today - 15)::timestamp at time zone 'Asia/Singapore');
  call zz_v683_mk_points_ledger(biz, cl_p4, u_sa);

  -- P5: one sale at today-3, NOT enrolled (no points_ledger row at all).
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, branch1, cl_p5, 'service', 5000,
          (v_today - 3)::timestamp at time zone 'Asia/Singapore', (v_today - 3)::timestamp at time zone 'Asia/Singapore');

  -- RF1: one sale at today-45 (no others, ever). Referral row qualifies at today-35.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, branch1, cl_rf1, 'service', 5000,
          (v_today - 45)::timestamp at time zone 'Asia/Singapore', (v_today - 45)::timestamp at time zone 'Asia/Singapore');
  insert into public.referrals (business_id, referrer_client_id, status, qualified_at)
  values (biz, cl_rf1, 'rewarded', (v_today - 35)::timestamp at time zone 'Asia/Singapore');

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  g := public.get_ci_loyalty_programmes_v1(biz, v_from, v_to, null);
  v_eligible := (g->>'eligible_customers')::int;

  if v_eligible is distinct from 6 then
    insert into _fail values ('54-eligible', format('expected 6 (P1..P5 + RF1), got %s', v_eligible));
  end if;

  -- POINTS
  if (g->'programmes'->'points'->>'status') is distinct from 'ready' then
    insert into _fail values ('54-points-status', g->'programmes'->'points'->>'status');
  end if;
  if (g->'programmes'->'points'->'participation'->>'numerator')::int is distinct from 4
     or (g->'programmes'->'points'->'participation'->>'denominator')::int is distinct from v_eligible then
    insert into _fail values ('54-points-participation', g->'programmes'->'points'->'participation');
  end if;
  if (g->'programmes'->'points'->>'redemptions')::int is distinct from 3 then
    insert into _fail values ('54-points-redemptions', g->'programmes'->'points'->>'redemptions');
  end if;
  if (g->'programmes'->'points'->>'immature')::int is distinct from 1 then
    insert into _fail values ('54-points-immature', g->'programmes'->'points'->>'immature');
  end if;
  if (g->'programmes'->'points'->'paid_return_within_30d'->>'numerator')::int is distinct from 1
     or (g->'programmes'->'points'->'paid_return_within_30d'->>'denominator')::int is distinct from 2 then
    insert into _fail values ('54-points-paid-return', g->'programmes'->'points'->'paid_return_within_30d');
  end if;
  if (g->'programmes'->'points'->'cannibalisation_proxy'->'within_cycle'->>'numerator')::int is distinct from 1
     or (g->'programmes'->'points'->'cannibalisation_proxy'->'within_cycle'->>'denominator')::int is distinct from 2 then
    insert into _fail values ('54-points-cannibalisation', g->'programmes'->'points'->'cannibalisation_proxy');
  end if;
  -- CI-STAT-AUTHORITY-CONTRACT: redemptions_mature=2 (points) is below the floor of 5 ->
  -- paid_return_within_30d.pct and cannibalisation_proxy.within_cycle.pct must be null even
  -- though their numerator/denominator (1/2 both) are populated exactly as computed.
  if (g->'programmes'->'points'->'paid_return_within_30d'->>'pct') is not null then
    insert into _fail values ('54-points-paid-return-pct-not-null',
      'redemptions_mature=2 < floor 5 -- pct must be null, numerator/denominator may stand');
  end if;
  if (g->'programmes'->'points'->'cannibalisation_proxy'->'within_cycle'->>'pct') is not null then
    insert into _fail values ('54-points-cannibalisation-pct-not-null',
      'v_known=2 < floor 5 -- pct must be null, numerator/denominator may stand');
  end if;
  if (g->'programmes'->'points'->'incrementality'->>'status') is distinct from 'unavailable' then
    insert into _fail values ('54-points-incrementality', g->'programmes'->'points'->'incrementality');
  end if;

  -- REFERRAL
  if (g->'programmes'->'referral'->>'status') is distinct from 'ready' then
    insert into _fail values ('54-referral-status', g->'programmes'->'referral'->>'status');
  end if;
  if (g->'programmes'->'referral'->'participation'->>'numerator')::int is distinct from 1
     or (g->'programmes'->'referral'->'participation'->>'denominator')::int is distinct from v_eligible then
    insert into _fail values ('54-referral-participation', g->'programmes'->'referral'->'participation');
  end if;
  if (g->'programmes'->'referral'->>'redemptions')::int is distinct from 1 then
    insert into _fail values ('54-referral-redemptions', g->'programmes'->'referral'->>'redemptions');
  end if;
  if (g->'programmes'->'referral'->>'immature')::int is distinct from 0 then
    insert into _fail values ('54-referral-immature', g->'programmes'->'referral'->>'immature');
  end if;
  if (g->'programmes'->'referral'->'paid_return_within_30d'->>'numerator')::int is distinct from 0
     or (g->'programmes'->'referral'->'paid_return_within_30d'->>'denominator')::int is distinct from 1 then
    insert into _fail values ('54-referral-paid-return', g->'programmes'->'referral'->'paid_return_within_30d');
  end if;
  if (g->'programmes'->'referral'->'cannibalisation_proxy'->'within_cycle'->>'numerator')::int is distinct from 1
     or (g->'programmes'->'referral'->'cannibalisation_proxy'->'within_cycle'->>'denominator')::int is distinct from 1 then
    insert into _fail values ('54-referral-cannibalisation', g->'programmes'->'referral'->'cannibalisation_proxy');
  end if;
  -- CI-STAT-AUTHORITY-CONTRACT: mature=1 (referral) is also below the floor of 5 -> both pcts
  -- null, counts (0/1 and 1/1) stand.
  if (g->'programmes'->'referral'->'paid_return_within_30d'->>'pct') is not null then
    insert into _fail values ('54-referral-paid-return-pct-not-null',
      'redemptions_mature=1 < floor 5 -- pct must be null, numerator/denominator may stand');
  end if;
  if (g->'programmes'->'referral'->'cannibalisation_proxy'->'within_cycle'->>'pct') is not null then
    insert into _fail values ('54-referral-cannibalisation-pct-not-null',
      'v_known=1 < floor 5 -- pct must be null, numerator/denominator may stand');
  end if;

  -- TIERS, STAMPS: spine exists (auto-seeded by v308), zero engagement -> ready, zero rate_blocks.
  if (g->'programmes'->'tiers'->>'status') is distinct from 'ready' then
    insert into _fail values ('55-tiers-status', g->'programmes'->'tiers'->>'status');
  end if;
  if (g->'programmes'->'tiers'->'participation'->>'numerator')::int is distinct from 0
     or (g->'programmes'->'tiers'->>'redemptions')::int is distinct from 0
     or (g->'programmes'->'tiers'->'paid_return_within_30d'->>'pct') is not null then
    insert into _fail values ('55-tiers-zero', g->'programmes'->'tiers');
  end if;
  if (g->'programmes'->'stamps'->>'status') is distinct from 'ready' then
    insert into _fail values ('55-stamps-status', g->'programmes'->'stamps'->>'status');
  end if;
  if (g->'programmes'->'stamps'->'participation'->>'numerator')::int is distinct from 0
     or (g->'programmes'->'stamps'->>'redemptions')::int is distinct from 0
     or (g->'programmes'->'stamps'->'paid_return_within_30d'->>'pct') is not null then
    insert into _fail values ('55-stamps-zero', g->'programmes'->'stamps');
  end if;

  -- WELCOME, BIRTHDAY, BRING-BACK: no config row at all -> not_configured.
  if (g->'programmes'->'welcome'->>'status') is distinct from 'not_configured' then
    insert into _fail values ('55-welcome-status', g->'programmes'->'welcome'->>'status');
  end if;
  if (g->'programmes'->'birthday'->>'status') is distinct from 'not_configured' then
    insert into _fail values ('55-birthday-status', g->'programmes'->'birthday'->>'status');
  end if;
  if (g->'programmes'->'bring_back'->>'status') is distinct from 'not_configured' then
    insert into _fail values ('55-bringback-status', g->'programmes'->'bring_back'->>'status');
  end if;
end
$v683c$;

-- ============================================================================================
-- SECTION D — discount dependency (checks 56-57)
-- ============================================================================================
-- Top-level helper (PL/pgSQL has no nested procedure/function declarations inside a DO block's
-- DECLARE section — this must be a real, transaction-scoped object; it disappears along with
-- everything else when the file's outer transaction rolls back at the end).
create or replace procedure zz_v683d_mk_visit(
  p_biz uuid, p_branch uuid, p_svc uuid, p_client uuid, p_sale uuid,
  p_days_ago integer, p_discounted boolean)
language plpgsql as $$
declare
  v_today date := (now() at time zone 'Asia/Singapore')::date;
begin
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (p_sale, p_biz, p_branch, p_client, 'service', 5000,
          (v_today - p_days_ago)::timestamp at time zone 'Asia/Singapore',
          (v_today - p_days_ago)::timestamp at time zone 'Asia/Singapore');
  insert into public.sale_items (sale_id, business_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (p_sale, p_biz, 'service', p_svc, 1, 5000, 5000);
  if p_discounted then
    insert into public.sale_items (sale_id, business_id, item_type, ref_id, qty, unit_cents, line_cents)
    values (p_sale, p_biz, 'studio_discount', null, 1, -1000, -1000);
  end if;
end;
$$;

do $v683d$
declare
  biz      uuid := '00000000-0000-4000-8000-000000068801';
  branch1  uuid := '00000000-0000-4000-8000-000000068811';
  u_sa     uuid := '00000000-0000-4000-8000-000000068391';
  svc      uuid := '00000000-0000-4000-8000-000000068841';
  d_organic  uuid := '00000000-0000-4000-8000-000000068821';
  d_organic2 uuid := '00000000-0000-4000-8000-000000068822';
  d_organic3 uuid := '00000000-0000-4000-8000-000000068823';
  d_organic4 uuid := '00000000-0000-4000-8000-000000068824';
  d_organic5 uuid := '00000000-0000-4000-8000-000000068825';
  d_mixed    uuid := '00000000-0000-4000-8000-000000068826';
  d_dependent uuid := '00000000-0000-4000-8000-000000068827';
  d_thin     uuid := '00000000-0000-4000-8000-000000068828';
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_from date; v_to date;
  g jsonb; g2 jsonb;
  v_mixed_sale_1 uuid := '00000000-0000-4000-8000-000000068861';
  v_full_price_repeat_before integer;
  v_mixed_pct_before numeric;
  v_mixed_pct_after numeric;
begin
  v_from := v_today - 60; v_to := v_today - 1;

  insert into auth.users (id, email) values (u_sa, 'zz-v683-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v683-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v683 discount fixture', 'zz-v683-discount',
          array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (branch1, biz, 'ZZ v683 discount branch', true, true);
  call zz_v683_seed_reporting_contract(biz, branch1);
  insert into public.customer_lifecycle_policies_v107
    (business_id, version_no, effective_from, fallback_lapse_days,
     customer_interval_min_observations, reactivation_multiplier, note, legacy_assumption)
  values (biz, 2, now() - interval '400 days', 30, 3, 2.000, 'zz-v683 fixture override', false);
  insert into public.services (id, business_id, name, price_cents, duration_min)
  values (svc, biz, 'ZZ discount service', 5000, 30);

  insert into public.clients (id, business_id, full_name) values
    (d_organic, biz, 'ZZ v683 D organic'),
    (d_organic2, biz, 'ZZ v683 D organic2'),
    (d_organic3, biz, 'ZZ v683 D organic3'),
    (d_organic4, biz, 'ZZ v683 D organic4'),
    (d_organic5, biz, 'ZZ v683 D organic5'),
    (d_mixed, biz, 'ZZ v683 D mixed'),
    (d_dependent, biz, 'ZZ v683 D dependent'),
    (d_thin, biz, 'ZZ v683 D thin');

  -- D_organic: 3 full-price visits, all far in the past -> overdue as of now.
  call zz_v683d_mk_visit(biz, branch1, svc, d_organic, gen_random_uuid(), 58, false);
  call zz_v683d_mk_visit(biz, branch1, svc, d_organic, gen_random_uuid(), 50, false);
  call zz_v683d_mk_visit(biz, branch1, svc, d_organic, gen_random_uuid(), 40, false);

  -- D_organic2..5: 3 full-price visits each, all recent -> within_cycle as of now.
  call zz_v683d_mk_visit(biz, branch1, svc, d_organic2, gen_random_uuid(), 30, false);
  call zz_v683d_mk_visit(biz, branch1, svc, d_organic2, gen_random_uuid(), 20, false);
  call zz_v683d_mk_visit(biz, branch1, svc, d_organic2, gen_random_uuid(), 10, false);

  call zz_v683d_mk_visit(biz, branch1, svc, d_organic3, gen_random_uuid(), 28, false);
  call zz_v683d_mk_visit(biz, branch1, svc, d_organic3, gen_random_uuid(), 18, false);
  call zz_v683d_mk_visit(biz, branch1, svc, d_organic3, gen_random_uuid(), 8, false);

  call zz_v683d_mk_visit(biz, branch1, svc, d_organic4, gen_random_uuid(), 26, false);
  call zz_v683d_mk_visit(biz, branch1, svc, d_organic4, gen_random_uuid(), 16, false);
  call zz_v683d_mk_visit(biz, branch1, svc, d_organic4, gen_random_uuid(), 6, false);

  call zz_v683d_mk_visit(biz, branch1, svc, d_organic5, gen_random_uuid(), 24, false);
  call zz_v683d_mk_visit(biz, branch1, svc, d_organic5, gen_random_uuid(), 14, false);
  call zz_v683d_mk_visit(biz, branch1, svc, d_organic5, gen_random_uuid(), 4, false);

  -- D_mixed: 2 full-price + 2 discounted (50% share -> 'mixed').
  call zz_v683d_mk_visit(biz, branch1, svc, d_mixed, v_mixed_sale_1, 45, false);
  call zz_v683d_mk_visit(biz, branch1, svc, d_mixed, gen_random_uuid(), 35, false);
  call zz_v683d_mk_visit(biz, branch1, svc, d_mixed, gen_random_uuid(), 25, true);
  call zz_v683d_mk_visit(biz, branch1, svc, d_mixed, gen_random_uuid(), 15, true);

  -- D_dependent: 1 full-price + 4 discounted (80% share -> 'discount_dependent').
  call zz_v683d_mk_visit(biz, branch1, svc, d_dependent, gen_random_uuid(), 55, false);
  call zz_v683d_mk_visit(biz, branch1, svc, d_dependent, gen_random_uuid(), 45, true);
  call zz_v683d_mk_visit(biz, branch1, svc, d_dependent, gen_random_uuid(), 35, true);
  call zz_v683d_mk_visit(biz, branch1, svc, d_dependent, gen_random_uuid(), 25, true);
  call zz_v683d_mk_visit(biz, branch1, svc, d_dependent, gen_random_uuid(), 15, true);

  -- D_thin: 2 full-price visits only -> 'insufficient' (<3 total).
  call zz_v683d_mk_visit(biz, branch1, svc, d_thin, gen_random_uuid(), 45, false);
  call zz_v683d_mk_visit(biz, branch1, svc, d_thin, gen_random_uuid(), 40, false);

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  g := public.get_ci_discount_dependency_v1(biz, v_from, v_to, null);

  if (g->'classes'->'organic'->>'n')::int is distinct from 5 then
    insert into _fail values ('56-organic-n', g->'classes'->'organic'->>'n');
  end if;
  if (g->'classes'->'discount_dependent'->>'n')::int is distinct from 1 then
    insert into _fail values ('56-dependent-n', g->'classes'->'discount_dependent'->>'n');
  end if;
  if (g->'classes'->'mixed'->>'n')::int is distinct from 1 then
    insert into _fail values ('56-mixed-n', g->'classes'->'mixed'->>'n');
  end if;
  if (g->'classes'->'insufficient'->>'n')::int is distinct from 1 then
    insert into _fail values ('56-insufficient-n', g->'classes'->'insufficient'->>'n');
  end if;
  if (g->'classes'->'organic'->'evidence'->>'status') is distinct from 'ok' then
    insert into _fail values ('56-organic-evidence', g->'classes'->'organic'->'evidence');
  end if;

  v_full_price_repeat_before := (g->>'full_price_repeat_customers')::int;
  if v_full_price_repeat_before is distinct from 7 then
    insert into _fail values ('56-full-price-repeat',
      format('expected 7 (organic x5 + mixed + thin), got %s', v_full_price_repeat_before));
  end if;

  -- reminder_only_candidates: only D_organic is overdue among the 5 organic clients; n=1 is
  -- below the k=5 floor -> suppressed.
  if (g->'reminder_only_candidates'->'suppressed'->>'reason') is distinct from 'below_small_cell_floor' then
    insert into _fail values ('57-reminder-suppressed', g->'reminder_only_candidates');
  end if;
  if (g->'reminder_only_candidates'->'suppressed'->>'cohort_size')::int is distinct from 1 then
    insert into _fail values ('57-reminder-cohort-size', g->'reminder_only_candidates'->'suppressed');
  end if;
  if jsonb_array_length(g->'reminder_only_candidates'->'candidates') is distinct from 0 then
    insert into _fail values ('57-reminder-candidates-empty', g->'reminder_only_candidates'->'candidates');
  end if;

  -- CI-STAT-AUTHORITY-CONTRACT: organic clears the floor (n=5, evidence 'ok') and shows a real
  -- share.pct; mixed/discount_dependent/insufficient are all below the floor (n=1 each) and must
  -- show share.pct = null even though their 'n' (count) is populated. One reader, both sides of
  -- the rule, asserted together.
  if (g->'classes'->'organic'->'evidence'->>'status') is distinct from 'ok'
     or (g->'classes'->'organic'->'share'->>'pct') is null then
    insert into _fail values ('56-organic-share-real', g->'classes'->'organic');
  end if;
  if (g->'classes'->'mixed'->'evidence'->>'status') is distinct from 'insufficient'
     or (g->'classes'->'mixed'->'share'->>'pct') is not null
     or (g->'classes'->'mixed'->'share'->>'numerator')::int is distinct from 1 then
    insert into _fail values ('56-mixed-share-null-below-floor', g->'classes'->'mixed');
  end if;
  v_mixed_pct_before := (g->'classes'->'mixed'->'share'->>'pct')::numeric;

  -- MUTATION CHECK: push D_mixed's first full-price sale into a discount -> 3/4 = 75% ->
  -- crosses the 60% discount_dependent boundary. mixed n must drop, discount_dependent n must
  -- rise. Both classes stay below the floor (0 and 2, vs. floor 5) throughout, so both continue
  -- to report a null share.pct even as their 'n' counts move — the mutation signal here is the
  -- count, not the (correctly still-null) rate.
  insert into public.sale_items (sale_id, business_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (v_mixed_sale_1, biz, 'studio_discount', null, 1, -1000, -1000);

  g2 := public.get_ci_discount_dependency_v1(biz, v_from, v_to, null);
  v_mixed_pct_after := (g2->'classes'->'mixed'->'share'->>'pct')::numeric;

  if (g2->'classes'->'mixed'->>'n')::int is distinct from 0 then
    insert into _fail values ('57-mutation-mixed-n', g2->'classes'->'mixed'->>'n');
  end if;
  if (g2->'classes'->'discount_dependent'->>'n')::int is distinct from 2 then
    insert into _fail values ('57-mutation-dependent-n', g2->'classes'->'discount_dependent'->>'n');
  end if;
  if v_mixed_pct_before is not null or v_mixed_pct_after is not null then
    insert into _fail values ('57-mutation-share-still-below-floor',
      'both below-floor readings must stay null even as n moves');
  end if;
end
$v683d$;

-- Second scenario: an un-suppressed reminder path (>=5 candidates), proving the real-row shape.
do $v683d2$
declare
  biz      uuid := '00000000-0000-4000-8000-000000068901';
  branch1  uuid := '00000000-0000-4000-8000-000000068911';
  u_sa     uuid := '00000000-0000-4000-8000-000000068391';
  svc      uuid := '00000000-0000-4000-8000-000000068941';
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_from date; v_to date;
  g jsonb;
  i integer;
  cl uuid;
begin
  v_from := v_today - 60; v_to := v_today - 1;

  insert into auth.users (id, email) values (u_sa, 'zz-v683-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v683-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v683 discount fixture 2', 'zz-v683-discount-2',
          array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (branch1, biz, 'ZZ v683 discount branch 2', true, true);
  call zz_v683_seed_reporting_contract(biz, branch1);
  insert into public.customer_lifecycle_policies_v107
    (business_id, version_no, effective_from, fallback_lapse_days,
     customer_interval_min_observations, reactivation_multiplier, note, legacy_assumption)
  values (biz, 2, now() - interval '400 days', 30, 3, 2.000, 'zz-v683 fixture override', false);
  insert into public.services (id, business_id, name, price_cents, duration_min)
  values (svc, biz, 'ZZ discount service 2', 5000, 30);

  -- Five organic clients, all overdue (3 full-price visits each, all far in the past).
  for i in 1..5 loop
    cl := ('00000000-0000-4000-8000-0000000689' || (20 + i)::text)::uuid;
    insert into public.clients (id, business_id, full_name) values (cl, biz, 'ZZ v683 D2 organic ' || i);
    call zz_v683d_mk_visit(biz, branch1, svc, cl, gen_random_uuid(), 58, false);
    call zz_v683d_mk_visit(biz, branch1, svc, cl, gen_random_uuid(), 50, false);
    call zz_v683d_mk_visit(biz, branch1, svc, cl, gen_random_uuid(), 40, false);
  end loop;

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  g := public.get_ci_discount_dependency_v1(biz, v_from, v_to, null);

  if (g->'classes'->'organic'->>'n')::int is distinct from 5 then
    insert into _fail values ('57b-organic-n', g->'classes'->'organic'->>'n');
  end if;
  -- jsonb_build_object('suppressed', null) stores a JSON null, not an absent key: g->'suppressed'
  -- is a real (non-SQL-NULL) jsonb datum equal to 'null'::jsonb, so "IS NOT NULL" is always true
  -- here regardless of which branch produced it. jsonb_typeof is the correct way to ask "is this
  -- JSON null" (a naive IS NULL/IS NOT NULL check would silently pass in both branches).
  if jsonb_typeof(g->'reminder_only_candidates'->'suppressed') is distinct from 'null' then
    insert into _fail values ('57b-not-suppressed', g->'reminder_only_candidates'->'suppressed');
  end if;
  if jsonb_array_length(g->'reminder_only_candidates'->'candidates') is distinct from 5 then
    insert into _fail values ('57b-candidate-count', g->'reminder_only_candidates'->'candidates');
  end if;
  if not exists (select 1 from jsonb_array_elements(g->'reminder_only_candidates'->'candidates') e
                  where (e->>'client_id') is not null
                    and (e->>'full_name') is not null
                    and (e->'action'->>'who') = 'front desk'
                    and (e->'action'->>'what') like '%no incentive%') then
    insert into _fail values ('57b-candidate-shape', g->'reminder_only_candidates'->'candidates');
  end if;
end
$v683d2$;

-- ============================================================================================
-- SECTION E — marketing attribution taxonomy (check 58)
-- ============================================================================================
do $v683e$
declare
  biz      uuid := '00000000-0000-4000-8000-000000068a01';
  u_sa     uuid := '00000000-0000-4000-8000-000000068391';
  cl1 uuid := '00000000-0000-4000-8000-000000068a21';
  cl2 uuid := '00000000-0000-4000-8000-000000068a22';
  cl3 uuid := '00000000-0000-4000-8000-000000068a23';
  cl4 uuid := '00000000-0000-4000-8000-000000068a24';
  cl5 uuid := '00000000-0000-4000-8000-000000068a25';
  u1 uuid := '00000000-0000-4000-8000-000000068a31';
  u2 uuid := '00000000-0000-4000-8000-000000068a32';
  u3 uuid := '00000000-0000-4000-8000-000000068a33';
  id1 uuid := '00000000-0000-4000-8000-000000068a41';
  id2 uuid := '00000000-0000-4000-8000-000000068a42';
  id3 uuid := '00000000-0000-4000-8000-000000068a43';
  lk1 uuid := '00000000-0000-4000-8000-000000068a51';
  lk2 uuid := '00000000-0000-4000-8000-000000068a52';
  lk3 uuid := '00000000-0000-4000-8000-000000068a53';
  ev1 uuid := '00000000-0000-4000-8000-000000068a61';
  ev2 uuid := '00000000-0000-4000-8000-000000068a62';
  ev3 uuid := '00000000-0000-4000-8000-000000068a63';
  send1 uuid := '00000000-0000-4000-8000-000000068a71';
  send2 uuid := '00000000-0000-4000-8000-000000068a72';
  send3 uuid := '00000000-0000-4000-8000-000000068a73';
  send4 uuid := '00000000-0000-4000-8000-000000068a74';
  send5 uuid := '00000000-0000-4000-8000-000000068a75';
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_from date; v_to date;
  g jsonb;
begin
  v_from := v_today - 30; v_to := v_today - 1;

  insert into auth.users (id, email) values
    (u_sa, 'zz-v683-sa@example.test'), (u1, 'zz-v683-e1@example.test'),
    (u2, 'zz-v683-e2@example.test'), (u3, 'zz-v683-e3@example.test')
  on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v683-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v683 funnel fixture', 'zz-v683-funnel',
          array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
  values ('00000000-0000-4000-8000-000000068a11', biz, 'ZZ v683 funnel branch', true, true);

  insert into public.clients (id, business_id, full_name) values
    (cl1, biz, 'ZZ v683 funnel c1'), (cl2, biz, 'ZZ v683 funnel c2'),
    (cl3, biz, 'ZZ v683 funnel c3'), (cl4, biz, 'ZZ v683 funnel c4'),
    (cl5, biz, 'ZZ v683 funnel c5');

  -- Identity/link scaffolding for the three in_app sends (M1, M2, M3).
  insert into public.customer_identities (id, auth_user_id, status) values
    (id1, u1, 'active'), (id2, u2, 'active'), (id3, u3, 'active');

  declare
    v_link uuid;
  begin
    v_link := lk1;
    perform set_config('app.customer_link_insert_id', v_link::text, true);
    insert into public.customer_links (id, business_id, identity_id, auth_user_id, client_id,
                                       state, verification_method, verified_at)
    values (v_link, biz, id1, u1, cl1, 'verified', 'email_claim', now());
    perform set_config('app.customer_link_insert_id', '', true);

    v_link := lk2;
    perform set_config('app.customer_link_insert_id', v_link::text, true);
    insert into public.customer_links (id, business_id, identity_id, auth_user_id, client_id,
                                       state, verification_method, verified_at)
    values (v_link, biz, id2, u2, cl2, 'verified', 'email_claim', now());
    perform set_config('app.customer_link_insert_id', '', true);

    v_link := lk3;
    perform set_config('app.customer_link_insert_id', v_link::text, true);
    insert into public.customer_links (id, business_id, identity_id, auth_user_id, client_id,
                                       state, verification_method, verified_at)
    values (v_link, biz, id3, u3, cl3, 'verified', 'email_claim', now());
    perform set_config('app.customer_link_insert_id', '', true);
  end;

  insert into public.customer_in_app_inbox_events
    (id, business_id, identity_id, auth_user_id, link_id, client_id,
     source_kind, topic, route_key, source_fingerprint, dedupe_key, title, body)
  values
    (ev1, biz, id1, u1, lk1, cl1, 'c44_actionable_wallet', 'reward_ready', 'wallet_business',
     app.c46_sha256_hex('zz-v683-e-ev1-fp'), app.c46_sha256_hex('zz-v683-e-ev1-dd'),
     'A reward is ready', 'Open this business wallet to view the available reward.'),
    (ev2, biz, id2, u2, lk2, cl2, 'c44_actionable_wallet', 'reward_ready', 'wallet_business',
     app.c46_sha256_hex('zz-v683-e-ev2-fp'), app.c46_sha256_hex('zz-v683-e-ev2-dd'),
     'A reward is ready', 'Open this business wallet to view the available reward.'),
    (ev3, biz, id3, u3, lk3, cl3, 'c44_actionable_wallet', 'reward_ready', 'wallet_business',
     app.c46_sha256_hex('zz-v683-e-ev3-fp'), app.c46_sha256_hex('zz-v683-e-ev3-dd'),
     'A reward is ready', 'Open this business wallet to view the available reward.');

  -- Only M1 is read. c46_inbox_state_guard (v46) demands app.c46_inbox_state_event match the
  -- row's own event_id, so a direct insert is indistinguishable from the real operation RPC.
  perform set_config('app.c46_inbox_state_event', ev1::text, true);
  insert into public.customer_in_app_inbox_state
    (event_id, business_id, identity_id, auth_user_id, link_id, client_id, read_at)
  values (ev1, biz, id1, u1, lk1, cl1, now());
  perform set_config('app.c46_inbox_state_event', '', true);

  -- Five sends, all campaign_kind='retention' (arbitrary, allowed value).
  -- retention_until must land in [occurred_at+399d, occurred_at+401d] (campaign_send_records_v255
  -- _retention_check); the column's own default is now()+400d, which only satisfies that check
  -- when occurred_at IS now(), so every backdated send here sets it explicitly off its own
  -- occurred_at instead of relying on the default.
  insert into public.campaign_send_records_v255
    (id, business_id, campaign_kind, campaign_ref_id, send_kind, campaign_label,
     channel, inbox_event_id, identity_id, link_id, client_id, occurred_at, retention_until)
  values
    (send1, biz, 'retention', gen_random_uuid(), 'zz_v683_send', 'ZZ v683 funnel campaign',
     'in_app', ev1, id1, lk1, cl1, (v_today - 30)::timestamp at time zone 'Asia/Singapore',
     (v_today - 30)::timestamp at time zone 'Asia/Singapore' + interval '400 days'),
    (send2, biz, 'retention', gen_random_uuid(), 'zz_v683_send', 'ZZ v683 funnel campaign',
     'in_app', ev2, id2, lk2, cl2, (v_today - 30)::timestamp at time zone 'Asia/Singapore',
     (v_today - 30)::timestamp at time zone 'Asia/Singapore' + interval '400 days'),
    (send3, biz, 'retention', gen_random_uuid(), 'zz_v683_send', 'ZZ v683 funnel campaign',
     'in_app', ev3, id3, lk3, cl3, (v_today - 30)::timestamp at time zone 'Asia/Singapore',
     (v_today - 30)::timestamp at time zone 'Asia/Singapore' + interval '400 days'),
    (send4, biz, 'retention', gen_random_uuid(), 'zz_v683_send', 'ZZ v683 funnel campaign',
     'web_push', null, null, null, cl4, (v_today - 30)::timestamp at time zone 'Asia/Singapore',
     (v_today - 30)::timestamp at time zone 'Asia/Singapore' + interval '400 days'),
    (send5, biz, 'retention', gen_random_uuid(), 'zz_v683_send', 'ZZ v683 funnel campaign',
     'web_push', null, null, null, cl5, (v_today - 5)::timestamp at time zone 'Asia/Singapore',
     (v_today - 5)::timestamp at time zone 'Asia/Singapore' + interval '400 days');

  -- M1's client returns within 30 days of the send (today-30 -> today-20).
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, cl1, 'service', 5000,
          (v_today - 20)::timestamp at time zone 'Asia/Singapore',
          (v_today - 20)::timestamp at time zone 'Asia/Singapore');

  g := public.get_ci_marketing_funnel_v1(biz, v_from, v_to, null);

  if (g->'stages'->'sent'->>'count')::int is distinct from 5 then
    insert into _fail values ('58-sent', g->'stages'->'sent'->>'count');
  end if;
  if (g->'stages'->'read'->'rate'->>'numerator')::int is distinct from 1
     or (g->'stages'->'read'->'rate'->>'denominator')::int is distinct from 3 then
    insert into _fail values ('58-read', g->'stages'->'read');
  end if;
  if (g->'stages'->'read'->>'scope') is distinct from 'in_app channel only' then
    insert into _fail values ('58-read-scope', g->'stages'->'read'->>'scope');
  end if;
  if (g->'stages'->'associated_purchase'->'rate'->>'numerator')::int is distinct from 1
     or (g->'stages'->'associated_purchase'->'rate'->>'denominator')::int is distinct from 4 then
    insert into _fail values ('58-associated', g->'stages'->'associated_purchase');
  end if;
  if (g->'stages'->'associated_purchase'->>'immature')::int is distinct from 1 then
    insert into _fail values ('58-immature', g->'stages'->'associated_purchase'->>'immature');
  end if;
  -- CI-STAT-AUTHORITY-CONTRACT: both denominators here (3 in_app sends, 4 mature sends) are below
  -- the floor of 5 -> both rates' pct must be null, numerator/denominator stand as computed.
  if (g->'stages'->'read'->'evidence'->>'status') is distinct from 'insufficient'
     or (g->'stages'->'read'->'rate'->>'pct') is not null then
    insert into _fail values ('58-read-pct-not-null',
      'denominator=3 < floor 5 -- read.rate.pct must be null');
  end if;
  if (g->'stages'->'associated_purchase'->'evidence'->>'status') is distinct from 'insufficient'
     or (g->'stages'->'associated_purchase'->'rate'->>'pct') is not null then
    insert into _fail values ('58-associated-pct-not-null',
      'denominator=4 < floor 5 -- associated_purchase.rate.pct must be null');
  end if;

  if (g->'stages'->'contacted'->>'status') is distinct from 'not_observed'
     or (g->'stages'->'queued'->>'status') is distinct from 'not_observed'
     or (g->'stages'->'delivered'->>'status') is distinct from 'not_observed'
     or (g->'stages'->'replied'->>'status') is distinct from 'not_observed'
     or (g->'stages'->'redeemed'->>'status') is distinct from 'not_observed' then
    insert into _fail values ('58-not-observed', g->'stages');
  end if;
  if (g->'incremental'->>'status') is distinct from 'unavailable' then
    insert into _fail values ('58-incremental', g->'incremental');
  end if;
end
$v683e$;

-- ============================================================================================
-- VERDICT
-- ============================================================================================
select case when count(*)=0 then 'PASS — every v683 CI-C reader matches its predetermined truth table'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v683: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
