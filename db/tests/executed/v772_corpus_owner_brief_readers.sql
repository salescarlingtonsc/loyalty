-- EXECUTED acceptance fixture for nestly_v772 — the five Owner-brief readers:
--   public.get_ci_cash_gap_v1, public.get_ci_staff_rebooking_v1,
--   public.get_ci_reward_popularity_v1, public.get_ci_visit_rhythm_v1,
--   public.get_ci_demographic_totals_v1.
--
-- Proves db/migrations/20261003_nestly_v772_owner_brief_readers.sql.
--
-- Named for v772 because all five RPCs are new above the v422 baseline watermark: every
-- assertion below is `n/a` in the baseline phase and gated entirely on the migrated run
-- (`--migrated-only`). See docs/qa/CI-CORPUS-FIXTURE-GUIDE.md for the harness, the
-- impersonation recipe and the write-guard GUC table this fixture follows for the sale
-- reversal, the payments ledger and the points ledger.
--
-- WHY THE DATES ARE ABSOLUTE. The window is 2026-03-02 (Monday) .. 2026-03-29 (Sunday) — 28
-- days, exactly four occurrences of every weekday, so get_ci_visit_rhythm_v1's weekday evidence
-- floor (k=4 occurrences) is cleared by all seven and the per-weekday arithmetic is a fixed
-- number rather than "whatever today happens to be". Every fixture row carries an EXPLICIT
-- created_at inside that window, and every call passes an explicit p_as_of, so nothing below
-- depends on the wall clock. The only clock-dependent input is a birth date, which is written
-- relative to current_date so the age bands stay put.
--
-- ===========================================================================================
-- THE CORPUS (all of it; nothing else is inserted for this business)
-- ===========================================================================================
-- Staff:  A = 'ZZ Alpha' (active), B = 'ZZ Beta' (INACTIVE — must still appear).
-- Clients: c1..c5 female 27y (25_30) · c6 female 45y (41_50) · c7 male 45y (41_50)
--          c8 male, NO birth date (age unknown) · c9 NO gender, 27y (gender unknown)
--          syn = synthetic (must be invisible everywhere).
--
--  #   client  staff        date        SGT     amount   items
--  s1   c1     A(sale)      03-02 Mon   10:30   10000    Haircut 10000
--  s2   c2     A(sale)      03-02 Mon   10:30   10000    Haircut 10000
--  s3   c3     A(sale)      03-03 Tue   10:30   10000    Haircut 10000
--  s4   c4     A(sale)      03-03 Tue   10:30   10000    Haircut 10000
--  s5   c5     A(sale)      03-04 Wed   10:30   10000    Haircut 10000
--  s6   c6     B(sale)      03-04 Wed   14:30   20000    Colour  20000
--  s7   c7     B(sale)      03-05 Thu   14:30   20000    Colour  20000
--  s8   c1     A(sale)      03-09 Mon   10:30    5000    Haircut  5000
--  s9   c2     A(sale)      03-09 Mon   10:30    5000    Haircut  5000
--  s10  c3     A(sale)      03-10 Tue   10:30    5000    Haircut  5000
--  s11  c4     B(sale)      03-11 Wed   14:30    5000    Colour   5000
--  s12  c8     AMBIGUOUS    03-12 Thu   10:30    7000    Haircut 4000 (line A) + 3000 (line B)
--  s13  anon   none         03-13 Fri   10:30    3000    Haircut  3000
--  s14  c9     LINE-ONLY B  03-16 Mon   18:30    4000    Colour   4000 (line B)
--  sR1  c5     A(sale)      03-05 Thu   10:30   50000    Haircut 50000   <- REVERSED by sR2
--  sS1  syn    A(sale)      03-02 Mon   10:30   99000    Haircut 99000   <- SYNTHETIC
--  sP1  c1     A(sale)      02-10        10:30   10000   Haircut 10000   <- PREVIOUS window only
--
-- s12 proves the line-level fallback REFUSES an ambiguous ticket (two different line staff, no
-- sale-level staff -> unattributed). s14 proves the fallback FIRES on an unambiguous one.
-- sR1/sS1 are the two negative controls every reader must ignore.
--
-- ===========================================================================================
-- TRUTH TABLE 1 — get_ci_cash_gap_v1(biz, 03-02, 03-29, null, as_of 2026-04-01 00:00+08)
-- ===========================================================================================
-- In scope: the 14 revenue sales s1..s14. revenue_recorded_cents
--   = 10000*5 + 20000*2 + 5000*4 + 7000 + 3000 + 4000 = 124000.
-- Payments (refunds are stored NEGATIVE, so paid_cents is a plain signed sum):
--   s1  cash   +10000                 -> paid 10000  FULLY   collected 10000 outstanding     0
--   s2  card   + 4000                 -> paid  4000  PARTLY  collected  4000 outstanding  6000
--   s3  (deposit cash +2000 only)     -> paid     0  UNPAID  collected     0 outstanding 10000
--   s4  paynow +10000                 -> paid 10000  FULLY   collected 10000 outstanding     0
--   s5  cash   +12000                 -> paid 12000  FULLY   collected 10000 overpaid    2000
--   s6  card   +20000, refund -5000   -> paid 15000  PARTLY  collected 15000 outstanding  5000
--   s7..s14 no payments               -> paid     0  UNPAID
--   totals: sales_count 14, fully 3, partly 2, unpaid 9
--           collected 10000+4000+0+10000+10000+15000 = 49000
--           outstanding 6000+10000+5000+20000+5000+5000+5000+5000+7000+3000+4000 = 75000
--           overpaid 2000
--           collected_share = 49000/124000 -> 39.5
--   by_method (kind='payment' only, cents desc): card 24000/2, cash 22000/2, paynow 10000/1
--   refunds_cents 5000 (positive magnitude)
--   unapplied_payment_kinds: [{deposit, 2000, 1}]  (reported, never counted as collected)
--   unlinked_payments: 2 rows / 4500 cents — one with sale_id null (3500) and one attached to
--     the SYNTHETIC client's sale (1000), which is a sale outside this reader's scope.
--   outstanding_sales: 11 rows; [0] = s7, c7, amount 20000, paid 0, outstanding 20000,
--     days_outstanding = 2026-04-01 - 2026-03-05 = 27.
--   outstanding_by_customer: 8 rows (the anonymous ticket is not a customer);
--     [0] c7 20000 / 1 sale, [1] c3 15000 / 2 sales.
--   envelope exclusions: reversed_sales 2 (sR1 and sR2 both match), synthetic_clients 1,
--     anonymous_sales 1.
--   NAME GATING: the owner sees client_name 'ZZ Gil' and names_visible true; the manager whose
--     staff.modules omits 'clients' sees the same 20000 with client_name NULL and
--     names_visible false.
--
-- ===========================================================================================
-- TRUTH TABLE 2 — get_ci_staff_rebooking_v1(biz, 03-02, 03-29, 60, null, as_of ...)
-- ===========================================================================================
-- Attribution: s1..s5, s8, s9, s10 -> A. s6, s7, s11 -> B. s14 -> B (single line staff).
--              s12 -> NOBODY (two different line staff). s13 anonymous. sR1/sS1 excluded.
-- Cohort pairs (customer, staff) with their first visit-day inside the window:
--   A: (c1,03-02) (c2,03-02) (c3,03-03) (c4,03-03) (c5,03-04)          -> 5 pairs
--   B: (c6,03-04) (c7,03-05) (c4,03-11) (c9,03-16)                     -> 4 pairs
-- CALL D — p_as_of '2026-06-01 00:00+08' (everything matured):
--   A: visits 8 (c1/02, c2/02, c3/03, c4/03, c5/04, c1/09, c2/09, c3/10), customers 5,
--      revenue 50000+15000 = 65000, revenue_per_visit 8125,
--      matured 5, immature 0, evidence n=5 ok,
--      returned_any  4/5 -> 80.0  (c1 03-09, c2 03-09, c3 03-10, c4 03-11; c5 never — and sR1
--                                  on 03-05 would have made it 5/5 if the reversal leaked)
--      returned_same 3/5 -> 60.0  (c4's return was with B, not A)
--   B: visits 4, customers 4, revenue 20000+20000+5000+4000 = 49000, revenue_per_visit 12250,
--      matured 4, evidence n=4 INSUFFICIENT -> both pcts NULL, numerator 0 / denominator 4 kept,
--      vs_firm_points NULL, active = false (an inactive staff member still appears).
--   firm: matured 8 (c1..c7 + c9), returned_any 4/8 -> 50.0, evidence ok.
--   A.vs_firm_points = 80.0 - 50.0 = 30.0.
--   unattributed_visits 1 (c8 on 03-12), anonymous_visits 1 (s13).
--   staff order: A (8 visits) then B (4).
-- CALL E — p_as_of '2026-04-01 00:00+08' (nothing has matured yet: 03-02 + 60 = 05-01 > 04-01):
--   A: matured 0, immature 5, returned_any.denominator 0 and pct NULL.
--   firm: matured 0, immature 8.
--
-- ===========================================================================================
-- TRUTH TABLE 3 — get_ci_reward_popularity_v1(biz, 03-02, 03-29, null, as_of 2026-04-01)
-- ===========================================================================================
-- Rewards: rw1 'ZZ Free Coffee' (active, live) · rw2 'ZZ Free Cake' (active, live)
--          rw3 'ZZ Never Redeemed' (active, live, ZERO redemptions) · rw4 'ZZ Retired Treat'
--          (active=false, still has history).
-- Redemptions in window: red1..red5 c1..c5 on rw1 @30pts · red6 c6 on rw2 @50 ·
--   red7 c7 on rw4 @20 · red8 c8 on rw1 @30 REVERSED (excluded) · red9 syn on rw1 (excluded) ·
--   red10 c9 with reward_id NULL @10 (unattributed).
--   totals: redemptions 8, customers 8 (c1..c7, c9), points_spent 150+50+20+10 = 230.
--   eligible_customers 9 (c1..c9 each have a qualifying visit; anon and syn excluded).
--   rw1: 5 redemptions / 5 customers / 150 pts, evidence n=5 ok,
--        share_of_redemptions 5/8 -> 62.5, redeemers_share 5/9 -> 55.6,
--        reward_name 'ZZ Free Coffee' — the LIVE customer_name, not the redemption rows'
--        stale 'ZZ Coffee Snapshot'.
--   rw2: 1/1/50, insufficient -> both pcts NULL (numerators 1, denominators 8 and 9).
--   rw4: 1/1/20, active false.
--   rw3: 0/0/0, active true, paused false — a live reward nobody redeemed, emitted at zero.
--   order (redemptions desc, then name): rw1, rw2 'ZZ Free Cake', rw4 'ZZ Retired Treat',
--        rw3 'ZZ Never Redeemed'.
--   unattributed_redemptions: 1 redemption / 1 customer / 10 points.
--
-- ===========================================================================================
-- TRUTH TABLE 4 — get_ci_visit_rhythm_v1(biz, 03-02, 03-29, null, as_of 2026-04-01)
-- ===========================================================================================
-- Visits are qualifying SALE ROWS (get_ci_daypart_v1's own grain). 14 in the window, 124000.
--   days: 28 rows. 03-02 -> 2 visits / 20000 / 2 identified. 03-13 -> 1 visit / 3000 /
--         0 identified (anonymous). Every other listed day above; the rest are zero-filled.
--   weekdays (4 occurrences each):
--     Mon 5 visits -> 5/4 = 1.3 (rev 34000) · Tue 3 -> 0.8 · Wed 3 -> 0.8 · Thu 2 -> 0.5
--     Fri 1 -> 0.3 · Sat 0 -> 0.0 · Sun 0 -> 0.0    (all evidence ok: occurrences 4 >= floor 4)
--     slowest_weekdays = [Sat 0.0, Sun 0.0]   busiest_weekdays = [Mon 1.3, Tue 0.8]
--   hour blocks: 10 -> 10 visits / 75000 / 7 days · 14 -> 3 / 45000 / 3 days ·
--                18 -> 1 / 4000 / 1 day. share(10) = 10/14 -> 71.4.
--     open_blocks (days_with_visits >= 3) = [10, 14]; block 18 is NOT open.
--     slowest_blocks = [14 (3 visits), 10 (10)]   busiest_blocks = [10, 14]
--     labels: 10 -> '10am–12pm', 14 -> '2pm–4pm', 18 -> '6pm–8pm'
--   current (nestly_v775): the window's OWN totals, straight off the same cur_tot CTE that
--     feeds every `share` denominator and `change` — visits 14, revenue_cents 124000, which is
--     also exactly sum(days[].visits) and sum(days[].revenue_cents) for this call.
--   previous window = 2026-02-02 .. 2026-03-01, one sale sP1 (1 visit, 10000):
--     change.visits_pct  = 100*(14-1)/1      = 1300.0
--     change.revenue_pct = 100*(124000-10000)/10000 = 1140.0
--   age_by_block (identified visits only, k=5 floor, NEVER dropped, NEVER zero):
--     (10, 25_30) 8 visits -> visits 8, suppressed false
--     (14, 25_30) 1        -> visits NULL, suppressed true
--     (14, 41_50) 2        -> visits NULL, suppressed true
--     (18, 25_30) 1        -> visits NULL, suppressed true
--     4 cells. coverage.age_known = 12/13 -> 92.3 (c8's visit has no birth date).
--
-- ===========================================================================================
-- TRUTH TABLE 5 — get_ci_demographic_totals_v1(biz, 03-02, 03-29, null, as_of 2026-04-01)
-- ===========================================================================================
-- Population = 9 identified non-synthetic customers with a qualifying visit; revenue 121000
--   (124000 less the 3000 anonymous ticket, which belongs to nobody).
--   per client: c1 15000 · c2 15000 · c3 15000 · c4 15000 · c5 10000 (sR1 reversed) ·
--               c6 20000 · c7 20000 · c8 7000 · c9 4000
--   gender: known 8. female 6 customers / 90000 -> share 6/8 = 75.0
--                    male   2 customers / 27000 -> share 2/8 = 25.0
--           unknown_gender {customers 1, revenue 4000}  (c9, OUTSIDE the share denominator)
--   age:    known 8. 25_30 6 customers / 74000 -> 75.0 · 41_50 2 / 40000 -> 25.0
--           unknown_age {customers 1, revenue 7000}     (c8)
--   coverage: gender_known 8/9 -> 88.9 · age_known 8/9 -> 88.9
--   by_item (revenue desc): 'ZZ Haircut' 72000 / 6 buyers (c1..c5, c8 — the anonymous line is
--       not a buyer) and 'ZZ Colour' 49000 / 4 buyers (c4, c6, c7, c9).
--     Haircut buyers_known_gender 6: female 5 buyers / 65000 -> 5/6 = 83.3 (evidence ok);
--       male 1 buyer / 7000 -> pct NULL below the floor, buyers count KEPT.
--     Haircut buyers_known_age 5: 25_30 5 buyers / 65000 -> 5/5 = 100.0.
--
-- ===========================================================================================
-- ACCESS: a second business's owner is refused (42501) by every one of the five readers, and
-- the biz owner passing biz2's branch is refused too. Both refusals carry a precondition
-- assertion that the refused caller genuinely holds the access the refusal is about.
-- ===========================================================================================
\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v772$
declare
  biz      uuid := '00000000-0000-4000-8000-000000772001';
  u_sa     uuid := '00000000-0000-4000-8000-000000772002';
  u_owner  uuid := '00000000-0000-4000-8000-000000772003';
  u_mgr    uuid := '00000000-0000-4000-8000-000000772004';
  biz2     uuid := '00000000-0000-4000-8000-000000772005';
  u_owner2 uuid := '00000000-0000-4000-8000-000000772006';

  c1  uuid := '00000000-0000-4000-8000-000000772101';
  c2  uuid := '00000000-0000-4000-8000-000000772102';
  c3  uuid := '00000000-0000-4000-8000-000000772103';
  c4  uuid := '00000000-0000-4000-8000-000000772104';
  c5  uuid := '00000000-0000-4000-8000-000000772105';
  c6  uuid := '00000000-0000-4000-8000-000000772106';
  c7  uuid := '00000000-0000-4000-8000-000000772107';
  c8  uuid := '00000000-0000-4000-8000-000000772108';
  c9  uuid := '00000000-0000-4000-8000-000000772109';
  syn uuid := '00000000-0000-4000-8000-000000772110';

  st_a uuid := '00000000-0000-4000-8000-000000772201';
  st_b uuid := '00000000-0000-4000-8000-000000772202';

  svc_cut   uuid := '00000000-0000-4000-8000-000000772301';
  svc_color uuid := '00000000-0000-4000-8000-000000772302';

  rw1 uuid := '00000000-0000-4000-8000-000000772401';
  rw2 uuid := '00000000-0000-4000-8000-000000772402';
  rw3 uuid := '00000000-0000-4000-8000-000000772403';
  rw4 uuid := '00000000-0000-4000-8000-000000772404';

  red1  uuid := '00000000-0000-4000-8000-000000772501';
  red2  uuid := '00000000-0000-4000-8000-000000772502';
  red3  uuid := '00000000-0000-4000-8000-000000772503';
  red4  uuid := '00000000-0000-4000-8000-000000772504';
  red5  uuid := '00000000-0000-4000-8000-000000772505';
  red6  uuid := '00000000-0000-4000-8000-000000772506';
  red7  uuid := '00000000-0000-4000-8000-000000772507';
  red8  uuid := '00000000-0000-4000-8000-000000772508';
  red9  uuid := '00000000-0000-4000-8000-000000772509';
  red10 uuid := '00000000-0000-4000-8000-000000772510';

  s1  uuid := '00000000-0000-4000-8000-000000772601';
  s2  uuid := '00000000-0000-4000-8000-000000772602';
  s3  uuid := '00000000-0000-4000-8000-000000772603';
  s4  uuid := '00000000-0000-4000-8000-000000772604';
  s5  uuid := '00000000-0000-4000-8000-000000772605';
  s6  uuid := '00000000-0000-4000-8000-000000772606';
  s7  uuid := '00000000-0000-4000-8000-000000772607';
  s8  uuid := '00000000-0000-4000-8000-000000772608';
  s9  uuid := '00000000-0000-4000-8000-000000772609';
  s10 uuid := '00000000-0000-4000-8000-000000772610';
  s11 uuid := '00000000-0000-4000-8000-000000772611';
  s12 uuid := '00000000-0000-4000-8000-000000772612';
  s13 uuid := '00000000-0000-4000-8000-000000772613';
  s14 uuid := '00000000-0000-4000-8000-000000772614';
  sr1 uuid := '00000000-0000-4000-8000-000000772620';
  sr2 uuid := '00000000-0000-4000-8000-000000772621';
  ss1 uuid := '00000000-0000-4000-8000-000000772622';
  sp1 uuid := '00000000-0000-4000-8000-000000772623';

  pay1 uuid := '00000000-0000-4000-8000-000000772701';
  pay2 uuid := '00000000-0000-4000-8000-000000772702';
  pay3 uuid := '00000000-0000-4000-8000-000000772703';
  pay4 uuid := '00000000-0000-4000-8000-000000772704';
  pay5 uuid := '00000000-0000-4000-8000-000000772705';
  pay6 uuid := '00000000-0000-4000-8000-000000772706';
  pay7 uuid := '00000000-0000-4000-8000-000000772707';
  pay8 uuid := '00000000-0000-4000-8000-000000772708';
  pay9 uuid := '00000000-0000-4000-8000-000000772709';

  v_spine  uuid;
  v_cfg    uuid;
  v_pl     uuid := '00000000-0000-4000-8000-000000772801';
  v_prov   uuid := '00000000-0000-4000-8000-000000772802';
  v_op     uuid := '00000000-0000-4000-8000-000000772803';
  v_payload jsonb := '{"fixture":"v772"}'::jsonb;
  v_branch2 uuid;

  w_from date := date '2026-03-02';
  w_to   date := date '2026-03-29';
  as_of_apr timestamptz := timestamptz '2026-04-01 00:00:00+08';
  as_of_jun timestamptz := timestamptz '2026-06-01 00:00:00+08';

  sa_claims text;
  owner_claims text;
  mgr_claims text;
  owner2_claims text;

  g_cash jsonb; g_cash_owner jsonb; g_cash_mgr jsonb;
  g_staff jsonb; g_staff_imm jsonb;
  g_rew jsonb; g_rhy jsonb; g_dem jsonb;
  v_row jsonb; v_row2 jsonb; v_a jsonb; v_b jsonb; v_firm jsonb;
  v_err text;
  v_ok boolean;
begin
  sa_claims := json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method', 'oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google')))::text;
  owner_claims  := json_build_object('sub', u_owner,  'role', 'authenticated')::text;
  mgr_claims    := json_build_object('sub', u_mgr,    'role', 'authenticated')::text;
  owner2_claims := json_build_object('sub', u_owner2, 'role', 'authenticated')::text;

  ---------------------------------------------------------------------------
  -- actors
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_sa,     'zz-v772-sa@example.test'),
    (u_owner,  'zz-v772-owner@example.test'),
    (u_mgr,    'zz-v772-mgr@example.test'),
    (u_owner2, 'zz-v772-owner2@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (u_sa, 'zz-v772-sa@example.test') on conflict do nothing;

  ---------------------------------------------------------------------------
  -- two operational businesses (CI-CORPUS-FIXTURE-GUIDE.md recipe)
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz,  'ZZ v772 owner brief fixture', 'zz-v772-brief',
       array['dashboard','clients','sales','reports','loyalty','customerintel']),
    (biz2, 'ZZ v772 other firm', 'zz-v772-other',
       array['dashboard','clients','sales','reports','loyalty','customerintel']);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz,  u_owner,  'owner',   'ZZ v772 owner',   true, 'approved'),
    (biz2, u_owner2, 'owner',   'ZZ v772 owner2',  true, 'approved');
  -- the restricted caller: clears the CI gate (customerintel + view_finance via 'manager')
  -- but holds NO 'clients' module, so names must be withheld and nothing else.
  insert into public.staff (business_id, user_id, role, full_name, active, access_state, modules)
  values (biz, u_mgr, 'manager', 'ZZ v772 manager', true, 'approved',
          array['dashboard','sales','reports','customerintel']);
  -- rota-only staff (no login): A active, B deliberately INACTIVE
  insert into public.staff (id, business_id, user_id, role, full_name, active, access_state) values
    (st_a, biz, null, 'staff', 'ZZ Alpha', true,  'approved'),
    (st_b, biz, null, 'staff', 'ZZ Beta',  false, 'approved');

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz,  'approved', now(), 'v772 fixture'), (biz2, 'approved', now(), 'v772 fixture')
    on conflict (business_id) do update
      set approval_status = 'approved', decided_at = now(), decision_reason = 'v772 fixture';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false), (biz2, 'current', false)
    on conflict (business_id) do update set state = 'current', workspace_paused = false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz,  'active', 'paid', now() + interval '30 days'),
         (biz2, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status = 'active', payment_status = 'paid',
          current_period_end = now() + interval '30 days';

  select br.id into v_branch2 from public.branches br
   where br.business_id = biz2 order by br.created_at, br.id limit 1;
  if v_branch2 is null then
    v_branch2 := gen_random_uuid();
    insert into public.branches (id, business_id, name) values (v_branch2, biz2, 'ZZ v772 other');
  end if;

  ---------------------------------------------------------------------------
  -- loyalty spine + published config version (v423's recipe: the business insert seeds the
  -- programme spine, the loyalty_programs insert seeds firm_config_versions v1 published).
  ---------------------------------------------------------------------------
  insert into public.business_programmes (business_id, kind, active, sort)
  values (biz, 'points', true, 1)
    on conflict (business_id, kind) do update set active = true
  returning id into v_spine;
  insert into public.loyalty_programs (business_id, active, loyalty_model, configuration_status)
  values (biz, true, 'classic', 'published')
    on conflict (business_id) do update
      set active = true, loyalty_model = 'classic', configuration_status = 'published';
  select fcv.id into v_cfg from public.firm_config_versions fcv
   where fcv.business_id = biz and fcv.status = 'published'
   order by fcv.version_no desc limit 1;
  if v_cfg is null then
    v_cfg := gen_random_uuid();
    insert into public.firm_config_versions
      (id, business_id, version_no, status, snapshot_hash, published_at)
    select v_cfg, biz, coalesce(max(fcv.version_no), 0) + 1, 'published',
           md5('zz-v772-published'), now()
      from public.firm_config_versions fcv where fcv.business_id = biz;
  end if;
  update public.businesses set active_config_version_id = v_cfg where id = biz;

  ---------------------------------------------------------------------------
  -- catalogue + rewards
  ---------------------------------------------------------------------------
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_cut,   biz, 'ZZ Haircut', 10000, 45),
    (svc_color, biz, 'ZZ Colour',  20000, 90);

  insert into public.loyalty_rewards
    (id, business_id, programme_id, name, internal_name, customer_name, fulfillment_kind,
     cost_points, credit_cents, estimated_cost_cents, active, paused) values
    (rw1, biz, v_spine, 'ZZ Coffee Live', 'ZZ Coffee Internal', 'ZZ Free Coffee',
       'manual_item', 30, 0, 300, true,  false),
    (rw2, biz, v_spine, 'ZZ Cake Live',   'ZZ Cake Internal',   'ZZ Free Cake',
       'manual_item', 50, 0, 500, true,  false),
    (rw3, biz, v_spine, 'ZZ Never Live',  'ZZ Never Internal',  'ZZ Never Redeemed',
       'manual_item', 40, 0, 400, true,  false),
    (rw4, biz, v_spine, 'ZZ Retired',     'ZZ Retired Internal','ZZ Retired Treat',
       'manual_item', 20, 0, 200, false, false);

  ---------------------------------------------------------------------------
  -- clients
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name, birth_date, gender) values
    (c1, biz, 'ZZ Ann',  current_date - interval '27 years', 'female'),
    (c2, biz, 'ZZ Bea',  current_date - interval '27 years', 'female'),
    (c3, biz, 'ZZ Cara', current_date - interval '27 years', 'female'),
    (c4, biz, 'ZZ Dee',  current_date - interval '27 years', 'female'),
    (c5, biz, 'ZZ Eve',  current_date - interval '27 years', 'female'),
    (c6, biz, 'ZZ Fay',  current_date - interval '45 years', 'female'),
    (c7, biz, 'ZZ Gil',  current_date - interval '45 years', 'male');
  insert into public.clients (id, business_id, full_name, gender) values
    (c8, biz, 'ZZ Hal', 'male');                                   -- no birth date
  insert into public.clients (id, business_id, full_name, birth_date) values
    (c9, biz, 'ZZ Ivy', current_date - interval '27 years');       -- no gender
  insert into public.clients (id, business_id, full_name, birth_date, gender, is_synthetic)
  values (syn, biz, 'ZZ Synthetic', current_date - interval '27 years', 'female', true);

  ---------------------------------------------------------------------------
  -- sales (explicit created_at so every p_as_of below is deterministic)
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, client_id, staff_id, kind, amount_cents,
                            occurred_at, created_at, counts_as_revenue, counts_as_visit) values
    (s1,  biz, c1,   st_a, 'service', 10000, timestamptz '2026-03-02 10:30:00+08',
                                             timestamptz '2026-03-02 10:30:00+08', true, true),
    (s2,  biz, c2,   st_a, 'service', 10000, timestamptz '2026-03-02 10:30:00+08',
                                             timestamptz '2026-03-02 10:30:00+08', true, true),
    (s3,  biz, c3,   st_a, 'service', 10000, timestamptz '2026-03-03 10:30:00+08',
                                             timestamptz '2026-03-03 10:30:00+08', true, true),
    (s4,  biz, c4,   st_a, 'service', 10000, timestamptz '2026-03-03 10:30:00+08',
                                             timestamptz '2026-03-03 10:30:00+08', true, true),
    (s5,  biz, c5,   st_a, 'service', 10000, timestamptz '2026-03-04 10:30:00+08',
                                             timestamptz '2026-03-04 10:30:00+08', true, true),
    (s6,  biz, c6,   st_b, 'service', 20000, timestamptz '2026-03-04 14:30:00+08',
                                             timestamptz '2026-03-04 14:30:00+08', true, true),
    (s7,  biz, c7,   st_b, 'service', 20000, timestamptz '2026-03-05 14:30:00+08',
                                             timestamptz '2026-03-05 14:30:00+08', true, true),
    (s8,  biz, c1,   st_a, 'service',  5000, timestamptz '2026-03-09 10:30:00+08',
                                             timestamptz '2026-03-09 10:30:00+08', true, true),
    (s9,  biz, c2,   st_a, 'service',  5000, timestamptz '2026-03-09 10:30:00+08',
                                             timestamptz '2026-03-09 10:30:00+08', true, true),
    (s10, biz, c3,   st_a, 'service',  5000, timestamptz '2026-03-10 10:30:00+08',
                                             timestamptz '2026-03-10 10:30:00+08', true, true),
    (s11, biz, c4,   st_b, 'service',  5000, timestamptz '2026-03-11 14:30:00+08',
                                             timestamptz '2026-03-11 14:30:00+08', true, true),
    (s12, biz, c8,   null, 'service',  7000, timestamptz '2026-03-12 10:30:00+08',
                                             timestamptz '2026-03-12 10:30:00+08', true, true),
    (s13, biz, null, null, 'service',  3000, timestamptz '2026-03-13 10:30:00+08',
                                             timestamptz '2026-03-13 10:30:00+08', true, true),
    (s14, biz, c9,   null, 'service',  4000, timestamptz '2026-03-16 18:30:00+08',
                                             timestamptz '2026-03-16 18:30:00+08', true, true),
    (ss1, biz, syn,  st_a, 'service', 99000, timestamptz '2026-03-02 10:30:00+08',
                                             timestamptz '2026-03-02 10:30:00+08', true, true),
    (sp1, biz, c1,   st_a, 'service', 10000, timestamptz '2026-02-10 10:30:00+08',
                                             timestamptz '2026-02-10 10:30:00+08', true, true);

  insert into public.sale_items
    (business_id, sale_id, item_type, ref_id, description, qty, unit_cents, line_cents, staff_id)
  values
    (biz, s1,  'service', svc_cut,   'ZZ Haircut', 1, 10000, 10000, null),
    (biz, s2,  'service', svc_cut,   'ZZ Haircut', 1, 10000, 10000, null),
    (biz, s3,  'service', svc_cut,   'ZZ Haircut', 1, 10000, 10000, null),
    (biz, s4,  'service', svc_cut,   'ZZ Haircut', 1, 10000, 10000, null),
    (biz, s5,  'service', svc_cut,   'ZZ Haircut', 1, 10000, 10000, null),
    (biz, s6,  'service', svc_color, 'ZZ Colour',  1, 20000, 20000, null),
    (biz, s7,  'service', svc_color, 'ZZ Colour',  1, 20000, 20000, null),
    (biz, s8,  'service', svc_cut,   'ZZ Haircut', 1,  5000,  5000, null),
    (biz, s9,  'service', svc_cut,   'ZZ Haircut', 1,  5000,  5000, null),
    (biz, s10, 'service', svc_cut,   'ZZ Haircut', 1,  5000,  5000, null),
    (biz, s11, 'service', svc_color, 'ZZ Colour',  1,  5000,  5000, null),
    -- AMBIGUOUS ticket: two different line staff, no sale-level staff -> attributed to nobody
    (biz, s12, 'service', svc_cut,   'ZZ Haircut', 1,  4000,  4000, st_a),
    (biz, s12, 'service', svc_cut,   'ZZ Haircut', 1,  3000,  3000, st_b),
    (biz, s13, 'service', svc_cut,   'ZZ Haircut', 1,  3000,  3000, null),
    -- UNAMBIGUOUS line-only ticket: the fallback fires
    (biz, s14, 'service', svc_color, 'ZZ Colour',  1,  4000,  4000, st_b),
    (biz, ss1, 'service', svc_cut,   'ZZ Haircut', 1, 99000, 99000, null),
    (biz, sp1, 'service', svc_cut,   'ZZ Haircut', 1, 10000, 10000, null);

  -- negative control: a genuine reversal pair on c5 (write-guard GUC recipe). If it leaked,
  -- c5 would look like a return with A, revenue would read 174000 and Thursday would double.
  insert into public.sales (id, business_id, client_id, staff_id, kind, amount_cents,
                            occurred_at, created_at, counts_as_revenue, counts_as_visit)
  values (sr1, biz, c5, st_a, 'service', 50000, timestamptz '2026-03-05 10:30:00+08',
          timestamptz '2026-03-05 10:30:00+08', true, true);
  insert into public.sale_items
    (business_id, sale_id, item_type, ref_id, description, qty, unit_cents, line_cents)
  values (biz, sr1, 'service', svc_cut, 'ZZ Haircut', 1, 50000, 50000);
  perform set_config('app.sale_reversal_insert_id', sr2::text, true);
  perform set_config('app.sale_reversal_original_id', sr1::text, true);
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at,
                            created_at, reversal_of, reversal_reason, reversal_actor,
                            reversal_idempotency_key)
  values (sr2, biz, c5, 'service', -50000, timestamptz '2026-03-05 10:30:00+08',
          timestamptz '2026-03-05 10:30:00+08', sr1, 'ZZ v772 fixture reversal', u_owner,
          'zz-v772-sale-rev-001');
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);

  ---------------------------------------------------------------------------
  -- payments (branch_id deliberately NULL: a cash payment WITH a branch opens a drawer
  -- session, which this fixture has no business creating). Write-guard GUC pair per row.
  ---------------------------------------------------------------------------
  -- s1 fully paid, cash
  perform set_config('app.payment_insert_id', pay1::text, true);
  perform set_config('app.payment_write_scope', 'record_payment', true);
  insert into public.payments (id, business_id, sale_id, client_id, method, kind, amount_cents,
                               occurred_at, created_at)
  values (pay1, biz, s1, c1, 'cash', 'payment', 10000,
          timestamptz '2026-03-02 11:00:00+08', timestamptz '2026-03-02 11:00:00+08');
  -- s2 partly paid, card
  perform set_config('app.payment_insert_id', pay2::text, true);
  insert into public.payments (id, business_id, sale_id, client_id, method, kind, amount_cents,
                               occurred_at, created_at)
  values (pay2, biz, s2, c2, 'card', 'payment', 4000,
          timestamptz '2026-03-02 11:00:00+08', timestamptz '2026-03-02 11:00:00+08');
  -- s3 a DEPOSIT only: reported, never counted as collected
  perform set_config('app.payment_insert_id', pay3::text, true);
  insert into public.payments (id, business_id, sale_id, client_id, method, kind, amount_cents,
                               occurred_at, created_at)
  values (pay3, biz, s3, c3, 'cash', 'deposit', 2000,
          timestamptz '2026-03-03 11:00:00+08', timestamptz '2026-03-03 11:00:00+08');
  -- s4 fully paid, paynow
  perform set_config('app.payment_insert_id', pay4::text, true);
  insert into public.payments (id, business_id, sale_id, client_id, method, kind, amount_cents,
                               occurred_at, created_at)
  values (pay4, biz, s4, c4, 'paynow', 'payment', 10000,
          timestamptz '2026-03-03 11:00:00+08', timestamptz '2026-03-03 11:00:00+08');
  -- s5 OVERPAID, cash
  perform set_config('app.payment_insert_id', pay5::text, true);
  insert into public.payments (id, business_id, sale_id, client_id, method, kind, amount_cents,
                               occurred_at, created_at)
  values (pay5, biz, s5, c5, 'cash', 'payment', 12000,
          timestamptz '2026-03-04 11:00:00+08', timestamptz '2026-03-04 11:00:00+08');
  -- s6 paid then partly refunded
  perform set_config('app.payment_insert_id', pay6::text, true);
  insert into public.payments (id, business_id, sale_id, client_id, method, kind, amount_cents,
                               occurred_at, created_at)
  values (pay6, biz, s6, c6, 'card', 'payment', 20000,
          timestamptz '2026-03-04 15:00:00+08', timestamptz '2026-03-04 15:00:00+08');
  perform set_config('app.payment_insert_id', pay7::text, true);
  perform set_config('app.payment_write_scope', 'sale_reversal', true);
  insert into public.payments (id, business_id, sale_id, client_id, method, kind, amount_cents,
                               occurred_at, created_at)
  values (pay7, biz, s6, c6, 'cash', 'refund', -5000,
          timestamptz '2026-03-06 15:00:00+08', timestamptz '2026-03-06 15:00:00+08');
  -- unlinked: no sale at all
  perform set_config('app.payment_insert_id', pay8::text, true);
  perform set_config('app.payment_write_scope', 'record_payment', true);
  insert into public.payments (id, business_id, sale_id, client_id, method, kind, amount_cents,
                               occurred_at, created_at)
  values (pay8, biz, null, null, 'cash', 'payment', 3500,
          timestamptz '2026-03-20 10:30:00+08', timestamptz '2026-03-20 10:30:00+08');
  -- unlinked in the other sense: attached to a sale OUTSIDE this reader's scope (synthetic)
  perform set_config('app.payment_insert_id', pay9::text, true);
  insert into public.payments (id, business_id, sale_id, client_id, method, kind, amount_cents,
                               occurred_at, created_at)
  values (pay9, biz, ss1, syn, 'cash', 'payment', 1000,
          timestamptz '2026-03-21 10:30:00+08', timestamptz '2026-03-21 10:30:00+08');
  perform set_config('app.payment_insert_id', '', true);
  perform set_config('app.payment_write_scope', '', true);

  ---------------------------------------------------------------------------
  -- redemptions. Inserted while auth.uid() is still NULL so the v94 branch-module guard on
  -- loyalty_redemptions short-circuits (it only applies to a real signed-in merchant caller).
  -- reward_name deliberately carries a STALE snapshot; the reader must prefer the live
  -- customer_name.
  ---------------------------------------------------------------------------
  insert into public.loyalty_redemptions
    (id, business_id, client_id, reward_id, reward_name, points_spent, credit_cents, redeemed_at)
  values
    (red1,  biz, c1,  rw1,  'ZZ Coffee Snapshot', 30, 0, timestamptz '2026-03-05 12:00:00+08'),
    (red2,  biz, c2,  rw1,  'ZZ Coffee Snapshot', 30, 0, timestamptz '2026-03-06 12:00:00+08'),
    (red3,  biz, c3,  rw1,  'ZZ Coffee Snapshot', 30, 0, timestamptz '2026-03-07 12:00:00+08'),
    (red4,  biz, c4,  rw1,  'ZZ Coffee Snapshot', 30, 0, timestamptz '2026-03-08 12:00:00+08'),
    (red5,  biz, c5,  rw1,  'ZZ Coffee Snapshot', 30, 0, timestamptz '2026-03-09 12:00:00+08'),
    (red6,  biz, c6,  rw2,  'ZZ Cake Snapshot',   50, 0, timestamptz '2026-03-10 12:00:00+08'),
    (red7,  biz, c7,  rw4,  'ZZ Retired Snapshot',20, 0, timestamptz '2026-03-11 12:00:00+08'),
    (red8,  biz, c8,  rw1,  'ZZ Coffee Snapshot', 30, 0, timestamptz '2026-03-12 12:00:00+08'),
    (red9,  biz, syn, rw1,  'ZZ Coffee Snapshot', 30, 0, timestamptz '2026-03-13 12:00:00+08'),
    (red10, biz, c9,  null, 'ZZ Ad-hoc Gift',     10, 0, timestamptz '2026-03-14 12:00:00+08');

  ---------------------------------------------------------------------------
  -- reverse red8: points ledger (redemption_reversal scope needs a signed-in actor) ->
  -- provenance -> the reversal row itself.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', sa_claims, true);
  perform set_config('app.points_ledger_insert_id', v_pl::text, true);
  perform set_config('app.points_ledger_write_scope', 'redemption_reversal', true);
  perform set_config('app.redemption_reversal_config_version_id', coalesce(v_cfg::text, ''), true);
  insert into public.points_ledger
    (id, business_id, client_id, entry_type, points, actor, programme_id, config_version_id,
     created_at)
  values (v_pl, biz, c8, 'adjust', 30, u_sa, v_spine, v_cfg,
          timestamptz '2026-03-12 12:05:00+08');
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
  perform set_config('request.jwt.claims', null, true);

  -- provenance.operation_id is a composite FK into loyalty_operations, whose own write guard
  -- wants app.loyalty_operation_insert_id (another entry for the GUC table in the fixture guide).
  perform set_config('app.loyalty_operation_insert_id', v_op::text, true);
  insert into public.loyalty_operations
    (id, business_id, client_id, reward_id, operation_type, actor, idempotency_key,
     request_payload, request_hash, status, result, completed_at, created_at)
  values (v_op, biz, c8, rw1, 'redeem_reward', u_sa, 'zz-v772-red-op-001',
          v_payload, md5(v_payload::text), 'reserved', null, null,
          timestamptz '2026-03-12 12:00:00+08');
  perform set_config('app.loyalty_operation_insert_id', '', true);

  insert into public.loyalty_redemption_provenance
    (id, business_id, client_id, operation_id, redemption_id, points_ledger_id,
     config_version_id, consumes_balance, created_at)
  values (v_prov, biz, c8, v_op, red8, v_pl, v_cfg, true,
          timestamptz '2026-03-12 12:05:00+08');

  insert into public.loyalty_redemption_reversals
    (business_id, redemption_id, provenance_id, client_id, actor, idempotency_key,
     request_payload, request_hash, restored_points_ledger_id, result, created_at)
  values (biz, red8, v_prov, c8, u_sa, 'zz-v772-red-rev-001',
          v_payload, md5(v_payload::text), v_pl, '{"status":"reversed"}'::jsonb,
          timestamptz '2026-03-12 12:05:00+08');

  ---------------------------------------------------------------------------
  -- impersonate the entitled platform caller for the numeric battery
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', sa_claims, true);

  -- ======================================================================== 1. CASH GAP
  begin
    g_cash := public.get_ci_cash_gap_v1(biz, w_from, w_to, null, as_of_apr);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('C-pre', format('super admin refused (%s)', v_err));
    g_cash := null;
  end;

  if g_cash is null then
    insert into _fail values ('C-pre', 'get_ci_cash_gap_v1 returned no payload');
  else
    if (g_cash->'totals'->>'revenue_recorded_cents')::bigint <> 124000 then
      insert into _fail values ('C-revenue', g_cash->'totals'->>'revenue_recorded_cents');
    end if;
    if (g_cash->'totals'->>'collected_cents')::bigint <> 49000 then
      insert into _fail values ('C-collected', g_cash->'totals'->>'collected_cents');
    end if;
    if (g_cash->'totals'->>'outstanding_cents')::bigint <> 75000 then
      insert into _fail values ('C-outstanding', g_cash->'totals'->>'outstanding_cents');
    end if;
    if (g_cash->'totals'->>'overpaid_cents')::bigint <> 2000 then
      insert into _fail values ('C-overpaid', g_cash->'totals'->>'overpaid_cents');
    end if;
    if (g_cash->'totals'->>'sales_count')::bigint <> 14 then
      insert into _fail values ('C-sales-count', g_cash->'totals'->>'sales_count');
    end if;
    if (g_cash->'totals'->>'sales_fully_paid')::bigint <> 3
       or (g_cash->'totals'->>'sales_partly_paid')::bigint <> 2
       or (g_cash->'totals'->>'sales_unpaid')::bigint <> 9 then
      insert into _fail values ('C-pay-states',
        format('fully=%s partly=%s unpaid=%s',
          g_cash->'totals'->>'sales_fully_paid',
          g_cash->'totals'->>'sales_partly_paid',
          g_cash->'totals'->>'sales_unpaid'));
    end if;
    if (g_cash->'totals'->'collected_share'->>'pct')::numeric <> 39.5 then
      insert into _fail values ('C-collected-share',
        coalesce(g_cash->'totals'->'collected_share'->>'pct', '<null>'));
    end if;
    if (g_cash->>'refunds_cents')::bigint <> 5000 then
      insert into _fail values ('C-refunds', coalesce(g_cash->>'refunds_cents', '<null>'));
    end if;

    -- by_method: card 24000/2, cash 22000/2, paynow 10000/1, in that order
    if jsonb_array_length(coalesce(g_cash->'by_method', '[]'::jsonb)) <> 3 then
      insert into _fail values ('C-method-count',
        jsonb_array_length(coalesce(g_cash->'by_method', '[]'::jsonb))::text);
    else
      v_row := g_cash->'by_method'->0;
      if v_row->>'method' <> 'card' or (v_row->>'cents')::bigint <> 24000
         or (v_row->>'payments')::bigint <> 2 then
        insert into _fail values ('C-method-0', v_row::text);
      end if;
      v_row := g_cash->'by_method'->1;
      if v_row->>'method' <> 'cash' or (v_row->>'cents')::bigint <> 22000
         or (v_row->>'payments')::bigint <> 2 then
        insert into _fail values ('C-method-1', v_row::text);
      end if;
      v_row := g_cash->'by_method'->2;
      if v_row->>'method' <> 'paynow' or (v_row->>'cents')::bigint <> 10000 then
        insert into _fail values ('C-method-2', v_row::text);
      end if;
    end if;

    -- the deposit is reported, never collected
    if jsonb_array_length(coalesce(g_cash->'unapplied_payment_kinds', '[]'::jsonb)) <> 1
       or g_cash->'unapplied_payment_kinds'->0->>'kind' <> 'deposit'
       or (g_cash->'unapplied_payment_kinds'->0->>'cents')::bigint <> 2000 then
      insert into _fail values ('C-unapplied',
        coalesce(g_cash->'unapplied_payment_kinds', 'null'::jsonb)::text);
    end if;

    if (g_cash->'unlinked_payments'->>'count')::bigint <> 2
       or (g_cash->'unlinked_payments'->>'cents')::bigint <> 4500 then
      insert into _fail values ('C-unlinked', (g_cash->'unlinked_payments')::text);
    end if;

    if jsonb_array_length(coalesce(g_cash->'outstanding_sales', '[]'::jsonb)) <> 11 then
      insert into _fail values ('C-outstanding-rows',
        jsonb_array_length(coalesce(g_cash->'outstanding_sales', '[]'::jsonb))::text);
    else
      v_row := g_cash->'outstanding_sales'->0;
      if (v_row->>'sale_id')::uuid <> s7
         or (v_row->>'client_id')::uuid <> c7
         or (v_row->>'amount_cents')::bigint <> 20000
         or (v_row->>'paid_cents')::bigint <> 0
         or (v_row->>'outstanding_cents')::bigint <> 20000
         or (v_row->>'days_outstanding')::int <> 27 then
        insert into _fail values ('C-outstanding-0', v_row::text);
      end if;
      -- the super admin holds every module, so names travel here
      if v_row->>'client_name' <> 'ZZ Gil' then
        insert into _fail values ('C-outstanding-0-name',
          coalesce(v_row->>'client_name', '<null>'));
      end if;
    end if;

    if jsonb_array_length(coalesce(g_cash->'outstanding_by_customer', '[]'::jsonb)) <> 8 then
      insert into _fail values ('C-by-customer-rows',
        jsonb_array_length(coalesce(g_cash->'outstanding_by_customer', '[]'::jsonb))::text);
    else
      v_row := g_cash->'outstanding_by_customer'->0;
      if (v_row->>'client_id')::uuid <> c7 or (v_row->>'outstanding_cents')::bigint <> 20000
         or (v_row->>'sales')::bigint <> 1 then
        insert into _fail values ('C-by-customer-0', v_row::text);
      end if;
      v_row := g_cash->'outstanding_by_customer'->1;
      if (v_row->>'client_id')::uuid <> c3 or (v_row->>'outstanding_cents')::bigint <> 15000
         or (v_row->>'sales')::bigint <> 2 then
        insert into _fail values ('C-by-customer-1', v_row::text);
      end if;
    end if;

    if g_cash->>'time_basis' <> 'sale_occurred_at' then
      insert into _fail values ('C-time-basis', coalesce(g_cash->>'time_basis', '<null>'));
    end if;
    if g_cash->>'evidence_class' <> 'DIRECT_FACT' then
      insert into _fail values ('C-evidence-class', coalesce(g_cash->>'evidence_class', '<null>'));
    end if;
    if g_cash->>'basis_note' <>
       'A sale with no payment row is either unpaid or was paid without being recorded; this '
       'reader cannot tell the two apart.' then
      insert into _fail values ('C-basis-note', coalesce(g_cash->>'basis_note', '<null>'));
    end if;

    -- envelope + shared exclusions
    if g_cash->>'generated_at' is null or g_cash->>'trace_id' is null
       or g_cash->'period'->>'timezone' <> 'Asia/Singapore' then
      insert into _fail values ('C-envelope', coalesce((g_cash->'period')::text, '<null>'));
    end if;
    if (g_cash->'exclusions'->>'reversed_sales')::bigint <> 2
       or (g_cash->'exclusions'->>'synthetic_clients')::bigint <> 1
       or (g_cash->'exclusions'->>'anonymous_sales')::bigint <> 1 then
      insert into _fail values ('C-exclusions', (g_cash->'exclusions')::text);
    end if;
  end if;

  -- ======================================================================== 2. STAFF REBOOKING
  begin
    g_staff := public.get_ci_staff_rebooking_v1(biz, w_from, w_to, 60, null, as_of_jun);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('S-pre', format('super admin refused (%s)', v_err));
    g_staff := null;
  end;

  if g_staff is null then
    insert into _fail values ('S-pre', 'get_ci_staff_rebooking_v1 returned no payload');
  else
    v_firm := g_staff->'firm';
    if (v_firm->>'matured')::bigint <> 8 then
      insert into _fail values ('S-firm-matured', coalesce(v_firm->>'matured', '<null>'));
    end if;
    if (v_firm->'returned_any'->>'numerator')::bigint <> 4
       or (v_firm->'returned_any'->>'denominator')::bigint <> 8
       or (v_firm->'returned_any'->>'pct')::numeric <> 50.0 then
      insert into _fail values ('S-firm-return', (v_firm->'returned_any')::text);
    end if;

    if jsonb_array_length(coalesce(g_staff->'staff', '[]'::jsonb)) <> 2 then
      insert into _fail values ('S-staff-count',
        jsonb_array_length(coalesce(g_staff->'staff', '[]'::jsonb))::text);
    else
      v_a := g_staff->'staff'->0;
      v_b := g_staff->'staff'->1;
      if (v_a->>'staff_id')::uuid <> st_a or v_a->>'full_name' <> 'ZZ Alpha' then
        insert into _fail values ('S-order', v_a::text);
      end if;
      if (v_a->>'active')::boolean is distinct from true then
        insert into _fail values ('S-a-active', coalesce(v_a->>'active', '<null>'));
      end if;
      if (v_a->>'visits')::bigint <> 8 or (v_a->>'customers')::bigint <> 5
         or (v_a->>'revenue_cents')::bigint <> 65000
         or (v_a->>'revenue_per_visit_cents')::bigint <> 8125 then
        insert into _fail values ('S-a-shape', v_a::text);
      end if;
      if (v_a->>'matured')::bigint <> 5 or (v_a->>'immature')::bigint <> 0 then
        insert into _fail values ('S-a-maturity',
          format('matured=%s immature=%s', v_a->>'matured', v_a->>'immature'));
      end if;
      if v_a->'evidence'->>'status' <> 'ok' or (v_a->'evidence'->>'n')::int <> 5 then
        insert into _fail values ('S-a-evidence', (v_a->'evidence')::text);
      end if;
      if (v_a->'returned_any'->>'numerator')::bigint <> 4
         or (v_a->'returned_any'->>'denominator')::bigint <> 5
         or (v_a->'returned_any'->>'pct')::numeric <> 80.0 then
        insert into _fail values ('S-a-returned-any', (v_a->'returned_any')::text);
      end if;
      if (v_a->'returned_same_staff'->>'numerator')::bigint <> 3
         or (v_a->'returned_same_staff'->>'pct')::numeric <> 60.0 then
        insert into _fail values ('S-a-returned-same', (v_a->'returned_same_staff')::text);
      end if;
      if (v_a->>'vs_firm_points')::numeric <> 30.0 then
        insert into _fail values ('S-a-vs-firm', coalesce(v_a->>'vs_firm_points', '<null>'));
      end if;

      -- B: below the floor. Counts kept, percentages withheld, and an INACTIVE staff member
      -- still appears.
      if (v_b->>'staff_id')::uuid <> st_b or v_b->>'full_name' <> 'ZZ Beta' then
        insert into _fail values ('S-b-identity', v_b::text);
      end if;
      if (v_b->>'active')::boolean is distinct from false then
        insert into _fail values ('S-b-active', coalesce(v_b->>'active', '<null>'));
      end if;
      if (v_b->>'visits')::bigint <> 4 or (v_b->>'customers')::bigint <> 4
         or (v_b->>'revenue_cents')::bigint <> 49000
         or (v_b->>'revenue_per_visit_cents')::bigint <> 12250 then
        insert into _fail values ('S-b-shape', v_b::text);
      end if;
      if v_b->'evidence'->>'status' <> 'insufficient' or (v_b->'evidence'->>'n')::int <> 4 then
        insert into _fail values ('S-b-evidence', (v_b->'evidence')::text);
      end if;
      if v_b->'returned_any'->>'pct' is not null
         or v_b->'returned_same_staff'->>'pct' is not null then
        insert into _fail values ('S-b-suppressed',
          format('any=%s same=%s', v_b->'returned_any'->>'pct',
                 v_b->'returned_same_staff'->>'pct'));
      end if;
      if (v_b->'returned_any'->>'numerator')::bigint <> 0
         or (v_b->'returned_any'->>'denominator')::bigint <> 4 then
        insert into _fail values ('S-b-counts-kept', (v_b->'returned_any')::text);
      end if;
      if v_b->>'vs_firm_points' is not null then
        insert into _fail values ('S-b-vs-firm', v_b->>'vs_firm_points');
      end if;
    end if;

    if (g_staff->>'unattributed_visits')::bigint <> 1 then
      insert into _fail values ('S-unattributed',
        coalesce(g_staff->>'unattributed_visits', '<null>'));
    end if;
    if (g_staff->>'anonymous_visits')::bigint <> 1 then
      insert into _fail values ('S-anonymous', coalesce(g_staff->>'anonymous_visits', '<null>'));
    end if;
    if (g_staff->>'window_days')::int <> 60 then
      insert into _fail values ('S-window-days', coalesce(g_staff->>'window_days', '<null>'));
    end if;
    if g_staff->>'evidence_class' <> 'ASSOCIATION' then
      insert into _fail values ('S-evidence-class',
        coalesce(g_staff->>'evidence_class', '<null>'));
    end if;
    if g_staff->>'limitation' <>
       'Which customers a staff member serves is not random; a higher return rate is an '
       'association, not proof the staff member caused it.' then
      insert into _fail values ('S-limitation', coalesce(g_staff->>'limitation', '<null>'));
    end if;
    if position('CAUSAL' in upper(g_staff::text)) > 0 then
      insert into _fail values ('S-no-causal', 'the word CAUSAL appears in the payload');
    end if;
  end if;

  -- immature arm: same window, an as_of at which nothing has matured yet
  begin
    g_staff_imm := public.get_ci_staff_rebooking_v1(biz, w_from, w_to, 60, null, as_of_apr);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SI-pre', format('super admin refused (%s)', v_err));
    g_staff_imm := null;
  end;
  if g_staff_imm is null then
    insert into _fail values ('SI-pre', 'immature call returned no payload');
  else
    if (g_staff_imm->'firm'->>'matured')::bigint <> 0
       or (g_staff_imm->'firm'->>'immature')::bigint <> 8 then
      insert into _fail values ('SI-firm', (g_staff_imm->'firm')::text);
    end if;
    v_a := null;
    select rec into v_a from jsonb_array_elements(g_staff_imm->'staff') rec
     where (rec->>'staff_id')::uuid = st_a;
    if v_a is null then
      insert into _fail values ('SI-a-missing', 'staff A absent from the immature call');
    else
      if (v_a->>'matured')::bigint <> 0 or (v_a->>'immature')::bigint <> 5 then
        insert into _fail values ('SI-a-maturity',
          format('matured=%s immature=%s', v_a->>'matured', v_a->>'immature'));
      end if;
      if v_a->'returned_any'->>'pct' is not null
         or (v_a->'returned_any'->>'denominator')::bigint <> 0 then
        insert into _fail values ('SI-a-rate', (v_a->'returned_any')::text);
      end if;
    end if;
  end if;

  -- ======================================================================== 3. REWARDS
  begin
    g_rew := public.get_ci_reward_popularity_v1(biz, w_from, w_to, null, as_of_apr);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('R-pre', format('super admin refused (%s)', v_err));
    g_rew := null;
  end;

  if g_rew is null then
    insert into _fail values ('R-pre', 'get_ci_reward_popularity_v1 returned no payload');
  else
    if (g_rew->'totals'->>'redemptions')::bigint <> 8
       or (g_rew->'totals'->>'customers')::bigint <> 8
       or (g_rew->'totals'->>'points_spent')::bigint <> 230
       or (g_rew->'totals'->>'eligible_customers')::bigint <> 9 then
      insert into _fail values ('R-totals', (g_rew->'totals')::text);
    end if;

    if jsonb_array_length(coalesce(g_rew->'rewards', '[]'::jsonb)) <> 4 then
      insert into _fail values ('R-reward-count',
        jsonb_array_length(coalesce(g_rew->'rewards', '[]'::jsonb))::text);
    else
      v_row := g_rew->'rewards'->0;
      if (v_row->>'reward_id')::uuid <> rw1 or v_row->>'reward_name' <> 'ZZ Free Coffee' then
        insert into _fail values ('R-rw1-identity', v_row::text);
      end if;
      if (v_row->>'redemptions')::bigint <> 5 or (v_row->>'customers')::bigint <> 5
         or (v_row->>'points_spent')::bigint <> 150 then
        insert into _fail values ('R-rw1-counts', v_row::text);
      end if;
      if v_row->'evidence'->>'status' <> 'ok' then
        insert into _fail values ('R-rw1-evidence', (v_row->'evidence')::text);
      end if;
      if (v_row->'share_of_redemptions'->>'numerator')::bigint <> 5
         or (v_row->'share_of_redemptions'->>'denominator')::bigint <> 8
         or (v_row->'share_of_redemptions'->>'pct')::numeric <> 62.5 then
        insert into _fail values ('R-rw1-share', (v_row->'share_of_redemptions')::text);
      end if;
      if (v_row->'redeemers_share'->>'numerator')::bigint <> 5
         or (v_row->'redeemers_share'->>'denominator')::bigint <> 9
         or (v_row->'redeemers_share'->>'pct')::numeric <> 55.6 then
        insert into _fail values ('R-rw1-redeemers', (v_row->'redeemers_share')::text);
      end if;

      v_row := g_rew->'rewards'->1;
      if (v_row->>'reward_id')::uuid <> rw2 or (v_row->>'redemptions')::bigint <> 1 then
        insert into _fail values ('R-rw2', v_row::text);
      end if;
      if v_row->'share_of_redemptions'->>'pct' is not null
         or (v_row->'share_of_redemptions'->>'numerator')::bigint <> 1
         or (v_row->'share_of_redemptions'->>'denominator')::bigint <> 8 then
        insert into _fail values ('R-rw2-suppressed', (v_row->'share_of_redemptions')::text);
      end if;

      v_row := g_rew->'rewards'->2;
      if (v_row->>'reward_id')::uuid <> rw4 or (v_row->>'active')::boolean is distinct from false
      then
        insert into _fail values ('R-rw4', v_row::text);
      end if;

      -- the live reward nobody redeemed, at zero
      v_row := g_rew->'rewards'->3;
      if (v_row->>'reward_id')::uuid <> rw3
         or v_row->>'reward_name' <> 'ZZ Never Redeemed'
         or (v_row->>'redemptions')::bigint <> 0
         or (v_row->>'customers')::bigint <> 0
         or (v_row->>'points_spent')::bigint <> 0
         or (v_row->>'active')::boolean is distinct from true
         or (v_row->>'paused')::boolean is distinct from false then
        insert into _fail values ('R-rw3-zero', v_row::text);
      end if;
      if v_row->'share_of_redemptions'->>'pct' is not null then
        insert into _fail values ('R-rw3-pct', v_row->'share_of_redemptions'->>'pct');
      end if;
    end if;

    if (g_rew->'unattributed_redemptions'->>'redemptions')::bigint <> 1
       or (g_rew->'unattributed_redemptions'->>'points_spent')::bigint <> 10 then
      insert into _fail values ('R-unattributed', (g_rew->'unattributed_redemptions')::text);
    end if;
    if g_rew->>'time_basis' <> 'redemption_redeemed_at' then
      insert into _fail values ('R-time-basis', coalesce(g_rew->>'time_basis', '<null>'));
    end if;
    if g_rew->>'scope_note' <>
       'Redemptions are business-wide; the branch filter does not apply to this reader.' then
      insert into _fail values ('R-scope-note', coalesce(g_rew->>'scope_note', '<null>'));
    end if;
  end if;

  -- ======================================================================== 4. VISIT RHYTHM
  begin
    g_rhy := public.get_ci_visit_rhythm_v1(biz, w_from, w_to, null, as_of_apr);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('V-pre', format('super admin refused (%s)', v_err));
    g_rhy := null;
  end;

  if g_rhy is null then
    insert into _fail values ('V-pre', 'get_ci_visit_rhythm_v1 returned no payload');
  else
    if jsonb_array_length(coalesce(g_rhy->'days', '[]'::jsonb)) <> 28 then
      insert into _fail values ('V-day-count',
        jsonb_array_length(coalesce(g_rhy->'days', '[]'::jsonb))::text);
    end if;
    v_row := null;
    select rec into v_row from jsonb_array_elements(g_rhy->'days') rec
     where (rec->>'date')::date = date '2026-03-02';
    if v_row is null or (v_row->>'visits')::bigint <> 2
       or (v_row->>'revenue_cents')::bigint <> 20000
       or (v_row->>'identified_customers')::bigint <> 2
       or (v_row->>'dow')::int <> 1 then
      insert into _fail values ('V-day-0302', coalesce(v_row::text, '<missing>'));
    end if;
    v_row := null;
    select rec into v_row from jsonb_array_elements(g_rhy->'days') rec
     where (rec->>'date')::date = date '2026-03-13';
    if v_row is null or (v_row->>'visits')::bigint <> 1
       or (v_row->>'revenue_cents')::bigint <> 3000
       or (v_row->>'identified_customers')::bigint <> 0 then
      insert into _fail values ('V-day-0313', coalesce(v_row::text, '<missing>'));
    end if;

    -- nestly_v775: the reader states its own window total instead of making the caller sum
    -- days[]. Asserted BOTH against the hand-computed truth table and against that summation,
    -- so the two can never silently disagree.
    -- `is distinct from`, not `<>`: a MISSING 'current' key yields NULL, and `NULL <> 14` is
    -- NULL, which an `if` treats as false — the assertion would pass on the very absence it
    -- exists to catch. (Found by mutation-checking this fixture with v775 removed.)
    if (g_rhy->'current'->>'visits')::bigint is distinct from 14
       or (g_rhy->'current'->>'revenue_cents')::bigint is distinct from 124000 then
      insert into _fail values ('V-current', coalesce((g_rhy->'current')::text, '<missing>'));
    end if;
    if (select coalesce(sum((rec->>'visits')::bigint), 0)
          from jsonb_array_elements(g_rhy->'days') rec)
       is distinct from (g_rhy->'current'->>'visits')::bigint
       or (select coalesce(sum((rec->>'revenue_cents')::bigint), 0)
             from jsonb_array_elements(g_rhy->'days') rec)
          is distinct from (g_rhy->'current'->>'revenue_cents')::bigint then
      insert into _fail values ('V-current-matches-days',
        format('current=%s but days[] sums to visits=%s revenue=%s', g_rhy->'current',
          (select coalesce(sum((rec->>'visits')::bigint), 0)
             from jsonb_array_elements(g_rhy->'days') rec),
          (select coalesce(sum((rec->>'revenue_cents')::bigint), 0)
             from jsonb_array_elements(g_rhy->'days') rec)));
    end if;

    if (g_rhy->'previous'->>'visits')::bigint <> 1
       or (g_rhy->'previous'->>'revenue_cents')::bigint <> 10000
       or (g_rhy->'previous'->>'from')::date <> date '2026-02-02'
       or (g_rhy->'previous'->>'to')::date <> date '2026-03-01' then
      insert into _fail values ('V-previous', (g_rhy->'previous')::text);
    end if;
    if (g_rhy->'change'->>'visits_pct')::numeric <> 1300.0
       or (g_rhy->'change'->>'revenue_pct')::numeric <> 1140.0 then
      insert into _fail values ('V-change', (g_rhy->'change')::text);
    end if;

    if jsonb_array_length(coalesce(g_rhy->'weekdays', '[]'::jsonb)) <> 7 then
      insert into _fail values ('V-weekday-count',
        jsonb_array_length(coalesce(g_rhy->'weekdays', '[]'::jsonb))::text);
    else
      v_row := g_rhy->'weekdays'->0;   -- Monday
      if v_row->>'label' <> 'Monday' or (v_row->>'visits')::bigint <> 5
         or (v_row->>'occurrences')::bigint <> 4
         or (v_row->>'per_occurrence')::numeric <> 1.3
         or (v_row->>'revenue_cents')::bigint <> 34000
         or v_row->'evidence'->>'status' <> 'ok'
         or (v_row->'evidence'->>'floor')::int <> 4 then
        insert into _fail values ('V-monday', v_row::text);
      end if;
      v_row := g_rhy->'weekdays'->4;   -- Friday
      if v_row->>'label' <> 'Friday' or (v_row->>'per_occurrence')::numeric <> 0.3 then
        insert into _fail values ('V-friday', v_row::text);
      end if;
    end if;

    if jsonb_array_length(coalesce(g_rhy->'slowest_weekdays', '[]'::jsonb)) <> 2
       or (g_rhy->'slowest_weekdays'->0->>'dow')::int <> 6
       or (g_rhy->'slowest_weekdays'->0->>'per_occurrence')::numeric <> 0.0
       or (g_rhy->'slowest_weekdays'->1->>'dow')::int <> 7 then
      insert into _fail values ('V-slowest-weekdays',
        coalesce((g_rhy->'slowest_weekdays')::text, '<null>'));
    end if;
    if (g_rhy->'busiest_weekdays'->0->>'dow')::int <> 1
       or (g_rhy->'busiest_weekdays'->1->>'dow')::int <> 2 then
      insert into _fail values ('V-busiest-weekdays',
        coalesce((g_rhy->'busiest_weekdays')::text, '<null>'));
    end if;

    if jsonb_array_length(coalesce(g_rhy->'hour_blocks', '[]'::jsonb)) <> 12 then
      insert into _fail values ('V-block-count',
        jsonb_array_length(coalesce(g_rhy->'hour_blocks', '[]'::jsonb))::text);
    end if;
    v_row := null;
    select rec into v_row from jsonb_array_elements(g_rhy->'hour_blocks') rec
     where (rec->>'block_start')::int = 10;
    if v_row is null or v_row->>'label' <> '10am–12pm'
       or (v_row->>'visits')::bigint <> 10
       or (v_row->>'revenue_cents')::bigint <> 75000
       or (v_row->>'days_with_visits')::bigint <> 7
       or (v_row->'share'->>'pct')::numeric <> 71.4 then
      insert into _fail values ('V-block-10', coalesce(v_row::text, '<missing>'));
    end if;
    v_row := null;
    select rec into v_row from jsonb_array_elements(g_rhy->'hour_blocks') rec
     where (rec->>'block_start')::int = 18;
    if v_row is null or v_row->>'label' <> '6pm–8pm'
       or (v_row->>'days_with_visits')::bigint <> 1 then
      insert into _fail values ('V-block-18', coalesce(v_row::text, '<missing>'));
    end if;

    if jsonb_array_length(coalesce(g_rhy->'open_blocks', '[]'::jsonb)) <> 2
       or (g_rhy->'open_blocks'->0->>'block_start')::int <> 10
       or (g_rhy->'open_blocks'->1->>'block_start')::int <> 14 then
      insert into _fail values ('V-open-blocks', coalesce((g_rhy->'open_blocks')::text, '<null>'));
    end if;
    if (g_rhy->'slowest_blocks'->0->>'block_start')::int <> 14
       or (g_rhy->'busiest_blocks'->0->>'block_start')::int <> 10 then
      insert into _fail values ('V-block-extremes',
        format('slowest=%s busiest=%s', g_rhy->'slowest_blocks', g_rhy->'busiest_blocks'));
    end if;

    if jsonb_array_length(coalesce(g_rhy->'age_by_block', '[]'::jsonb)) <> 4 then
      insert into _fail values ('V-age-cell-count',
        jsonb_array_length(coalesce(g_rhy->'age_by_block', '[]'::jsonb))::text);
    else
      v_row := g_rhy->'age_by_block'->0;
      if (v_row->>'block_start')::int <> 10 or v_row->>'age_band' <> '25_30'
         or (v_row->>'visits')::bigint <> 8
         or (v_row->>'suppressed')::boolean is distinct from false then
        insert into _fail values ('V-age-cell-0', v_row::text);
      end if;
      -- a below-floor cell keeps its place, reports NULL visits and says it was suppressed
      v_row := g_rhy->'age_by_block'->1;
      if (v_row->>'block_start')::int <> 14 or v_row->>'age_band' <> '25_30'
         or v_row->>'visits' is not null
         or (v_row->>'suppressed')::boolean is distinct from true then
        insert into _fail values ('V-age-cell-1', v_row::text);
      end if;
      v_row := g_rhy->'age_by_block'->3;
      if (v_row->>'block_start')::int <> 18 or v_row->>'visits' is not null then
        insert into _fail values ('V-age-cell-3', v_row::text);
      end if;
    end if;

    if (g_rhy->'coverage'->'age_known'->>'numerator')::bigint <> 12
       or (g_rhy->'coverage'->'age_known'->>'denominator')::bigint <> 13
       or (g_rhy->'coverage'->'age_known'->>'pct')::numeric <> 92.3 then
      insert into _fail values ('V-age-coverage', (g_rhy->'coverage'->'age_known')::text);
    end if;
  end if;

  -- ======================================================================== 5. DEMOGRAPHICS
  begin
    g_dem := public.get_ci_demographic_totals_v1(biz, w_from, w_to, null, as_of_apr);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('D-pre', format('super admin refused (%s)', v_err));
    g_dem := null;
  end;

  if g_dem is null then
    insert into _fail values ('D-pre', 'get_ci_demographic_totals_v1 returned no payload');
  else
    if (g_dem->'population'->>'customers')::bigint <> 9
       or (g_dem->'population'->>'revenue_cents')::bigint <> 121000 then
      insert into _fail values ('D-population', (g_dem->'population')::text);
    end if;

    if jsonb_array_length(coalesce(g_dem->'gender', '[]'::jsonb)) <> 2 then
      insert into _fail values ('D-gender-count',
        jsonb_array_length(coalesce(g_dem->'gender', '[]'::jsonb))::text);
    else
      v_row := g_dem->'gender'->0;
      if v_row->>'gender' <> 'female' or (v_row->>'customers')::bigint <> 6
         or (v_row->>'revenue_cents')::bigint <> 90000
         or (v_row->'share'->>'numerator')::bigint <> 6
         or (v_row->'share'->>'denominator')::bigint <> 8
         or (v_row->'share'->>'pct')::numeric <> 75.0 then
        insert into _fail values ('D-female', v_row::text);
      end if;
      v_row := g_dem->'gender'->1;
      if v_row->>'gender' <> 'male' or (v_row->>'customers')::bigint <> 2
         or (v_row->'share'->>'pct')::numeric <> 25.0 then
        insert into _fail values ('D-male', v_row::text);
      end if;
    end if;
    -- the unknown bucket sits OUTSIDE the share denominator
    if (g_dem->'unknown_gender'->>'customers')::bigint <> 1
       or (g_dem->'unknown_gender'->>'revenue_cents')::bigint <> 4000 then
      insert into _fail values ('D-unknown-gender', (g_dem->'unknown_gender')::text);
    end if;

    if jsonb_array_length(coalesce(g_dem->'age_bands', '[]'::jsonb)) <> 2 then
      insert into _fail values ('D-age-count',
        jsonb_array_length(coalesce(g_dem->'age_bands', '[]'::jsonb))::text);
    else
      v_row := g_dem->'age_bands'->0;
      if v_row->>'age_band' <> '25_30' or (v_row->>'customers')::bigint <> 6
         or (v_row->>'revenue_cents')::bigint <> 74000
         or (v_row->'share'->>'pct')::numeric <> 75.0 then
        insert into _fail values ('D-band-25-30', v_row::text);
      end if;
      v_row := g_dem->'age_bands'->1;
      if v_row->>'age_band' <> '41_50' or (v_row->>'customers')::bigint <> 2 then
        insert into _fail values ('D-band-41-50', v_row::text);
      end if;
    end if;
    if (g_dem->'unknown_age'->>'customers')::bigint <> 1
       or (g_dem->'unknown_age'->>'revenue_cents')::bigint <> 7000 then
      insert into _fail values ('D-unknown-age', (g_dem->'unknown_age')::text);
    end if;

    if (g_dem->'coverage'->'gender_known'->>'pct')::numeric <> 88.9
       or (g_dem->'coverage'->'age_known'->>'pct')::numeric <> 88.9 then
      insert into _fail values ('D-coverage', (g_dem->'coverage')::text);
    end if;

    if jsonb_array_length(coalesce(g_dem->'by_item', '[]'::jsonb)) <> 2 then
      insert into _fail values ('D-item-count',
        jsonb_array_length(coalesce(g_dem->'by_item', '[]'::jsonb))::text);
    else
      v_row := g_dem->'by_item'->0;
      if v_row->>'item_name' <> 'ZZ Haircut'
         or (v_row->>'revenue_cents')::bigint <> 72000
         or (v_row->>'buyers')::bigint <> 6
         or (v_row->>'buyers_known_gender')::bigint <> 6
         or (v_row->>'buyers_known_age')::bigint <> 5 then
        insert into _fail values ('D-item-haircut', v_row::text);
      else
        v_row2 := null;
        select rec into v_row2 from jsonb_array_elements(v_row->'by_gender') rec
         where rec->>'gender' = 'female';
        if v_row2 is null or (v_row2->>'buyers')::bigint <> 5
           or (v_row2->>'revenue_cents')::bigint <> 65000
           or (v_row2->'share_of_item_buyers'->>'pct')::numeric <> 83.3 then
          insert into _fail values ('D-item-female', coalesce(v_row2::text, '<missing>'));
        end if;
        -- below the floor: the buyers count is kept, the percentage is not
        v_row2 := null;
        select rec into v_row2 from jsonb_array_elements(v_row->'by_gender') rec
         where rec->>'gender' = 'male';
        if v_row2 is null or (v_row2->>'buyers')::bigint <> 1
           or v_row2->'share_of_item_buyers'->>'pct' is not null
           or (v_row2->'share_of_item_buyers'->>'denominator')::bigint <> 6 then
          insert into _fail values ('D-item-male', coalesce(v_row2::text, '<missing>'));
        end if;
        v_row2 := null;
        select rec into v_row2 from jsonb_array_elements(v_row->'by_age_band') rec
         where rec->>'age_band' = '25_30';
        if v_row2 is null or (v_row2->>'buyers')::bigint <> 5
           or (v_row2->'share_of_item_buyers'->>'pct')::numeric <> 100.0 then
          insert into _fail values ('D-item-age', coalesce(v_row2::text, '<missing>'));
        end if;
      end if;

      v_row := g_dem->'by_item'->1;
      if v_row->>'item_name' <> 'ZZ Colour' or (v_row->>'revenue_cents')::bigint <> 49000
         or (v_row->>'buyers')::bigint <> 4
         or (v_row->>'buyers_known_gender')::bigint <> 3 then
        insert into _fail values ('D-item-colour', v_row::text);
      end if;
    end if;

    if g_dem->>'limitation' <>
       'Gender and date of birth are known only for customers who gave them when creating their '
       'Peekaa account or whose profile a staff member completed; walk-ins added at the till '
       'have neither until someone records it.' then
      insert into _fail values ('D-limitation', coalesce(g_dem->>'limitation', '<null>'));
    end if;
  end if;

  -- ======================================================================== 6. NAME GATING
  perform set_config('request.jwt.claims', owner_claims, true);
  v_ok := app.can_module(biz, 'clients');
  if v_ok is distinct from true then
    insert into _fail values ('N-owner-pre',
      'the fixture owner does not hold the clients module, so the name test proves nothing');
  end if;
  begin
    g_cash_owner := public.get_ci_cash_gap_v1(biz, w_from, w_to, null, as_of_apr);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('N-owner-call', format('owner refused by the CI gate (%s)', v_err));
    g_cash_owner := null;
  end;
  if g_cash_owner is not null then
    if (g_cash_owner->>'names_visible')::boolean is distinct from true then
      insert into _fail values ('N-owner-flag',
        coalesce(g_cash_owner->>'names_visible', '<null>'));
    end if;
    if g_cash_owner->'outstanding_sales'->0->>'client_name' <> 'ZZ Gil' then
      insert into _fail values ('N-owner-name',
        coalesce(g_cash_owner->'outstanding_sales'->0->>'client_name', '<null>'));
    end if;
  end if;

  perform set_config('request.jwt.claims', mgr_claims, true);
  -- preconditions: the manager genuinely clears the CI gate and genuinely lacks 'clients'
  if app.can_module(biz, 'customerintel') is distinct from true
     or app.has_perm(biz, 'view_finance') is distinct from true then
    insert into _fail values ('N-mgr-pre-gate',
      'the restricted manager cannot reach Customer Intelligence at all, so the name '
      'suppression below proves nothing');
  end if;
  if app.can_module(biz, 'clients') is distinct from false then
    insert into _fail values ('N-mgr-pre-clients',
      'the restricted manager still holds the clients module');
  end if;
  begin
    g_cash_mgr := public.get_ci_cash_gap_v1(biz, w_from, w_to, null, as_of_apr);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('N-mgr-call', format('manager refused (%s)', v_err));
    g_cash_mgr := null;
  end;
  if g_cash_mgr is not null then
    if (g_cash_mgr->>'names_visible')::boolean is distinct from false then
      insert into _fail values ('N-mgr-flag', coalesce(g_cash_mgr->>'names_visible', '<null>'));
    end if;
    if g_cash_mgr->'outstanding_sales'->0->>'client_name' is not null then
      insert into _fail values ('N-mgr-name',
        g_cash_mgr->'outstanding_sales'->0->>'client_name');
    end if;
    -- every figure is still there
    if (g_cash_mgr->'outstanding_sales'->0->>'outstanding_cents')::bigint <> 20000
       or (g_cash_mgr->'totals'->>'outstanding_cents')::bigint <> 75000 then
      insert into _fail values ('N-mgr-figures', (g_cash_mgr->'totals')::text);
    end if;
    if g_cash_mgr->'outstanding_by_customer'->0->>'client_name' is not null then
      insert into _fail values ('N-mgr-customer-name',
        g_cash_mgr->'outstanding_by_customer'->0->>'client_name');
    end if;
  end if;

  -- ======================================================================== 7. ISOLATION
  perform set_config('request.jwt.claims', owner2_claims, true);
  -- precondition: this caller genuinely holds CI access — on their OWN firm
  begin
    perform public.get_ci_cash_gap_v1(biz2, w_from, w_to, null, as_of_apr);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('X-pre',
      format('the other firm''s owner cannot read their OWN firm (%s), so the refusal below '
             'proves nothing', v_err));
  end;

  begin
    perform public.get_ci_cash_gap_v1(biz, w_from, w_to, null, as_of_apr);
    insert into _fail values ('X-cash', 'a foreign owner read this firm''s cash gap');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '42501' then
      insert into _fail values ('X-cash-code', v_err);
    end if;
  end;
  begin
    perform public.get_ci_staff_rebooking_v1(biz, w_from, w_to, 60, null, as_of_jun);
    insert into _fail values ('X-staff', 'a foreign owner read this firm''s staff rebooking');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '42501' then insert into _fail values ('X-staff-code', v_err); end if;
  end;
  begin
    perform public.get_ci_reward_popularity_v1(biz, w_from, w_to, null, as_of_apr);
    insert into _fail values ('X-reward', 'a foreign owner read this firm''s reward popularity');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '42501' then insert into _fail values ('X-reward-code', v_err); end if;
  end;
  begin
    perform public.get_ci_visit_rhythm_v1(biz, w_from, w_to, null, as_of_apr);
    insert into _fail values ('X-rhythm', 'a foreign owner read this firm''s visit rhythm');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '42501' then insert into _fail values ('X-rhythm-code', v_err); end if;
  end;
  begin
    perform public.get_ci_demographic_totals_v1(biz, w_from, w_to, null, as_of_apr);
    insert into _fail values ('X-demog', 'a foreign owner read this firm''s demographics');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '42501' then insert into _fail values ('X-demog-code', v_err); end if;
  end;

  -- ======================================================================== 8. BRANCH REFUSAL
  perform set_config('request.jwt.claims', sa_claims, true);
  begin
    perform public.get_ci_cash_gap_v1(biz, w_from, w_to, v_branch2, as_of_apr);
    insert into _fail values ('B-branch', 'another firm''s branch was accepted, not refused');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '42501' then insert into _fail values ('B-branch-code', v_err); end if;
  end;
  begin
    perform public.get_ci_visit_rhythm_v1(biz, w_from, w_to, v_branch2, as_of_apr);
    insert into _fail values ('B-branch-rhythm',
      'another firm''s branch was accepted by the rhythm reader');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '42501' then insert into _fail values ('B-branch-rhythm-code', v_err); end if;
  end;

  -- an invalid window is refused, not silently emptied
  begin
    perform public.get_ci_cash_gap_v1(biz, w_to, w_from, null, as_of_apr);
    insert into _fail values ('B-window', 'an inverted window was accepted');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then insert into _fail values ('B-window-code', v_err); end if;
  end;
  begin
    perform public.get_ci_staff_rebooking_v1(biz, w_from, w_to, 0, null, as_of_jun);
    insert into _fail values ('B-window-days', 'a zero return window was accepted');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then insert into _fail values ('B-window-days-code', v_err); end if;
  end;

  perform set_config('request.jwt.claims', null, true);
end
$v772$;

select case when count(*) = 0
            then 'PASS — v772 owner-brief readers hold their predetermined truth table'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v772: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
