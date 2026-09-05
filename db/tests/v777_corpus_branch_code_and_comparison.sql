-- EXECUTED acceptance fixture for nestly_v777 — public.branches.code, its BEFORE INSERT
-- generator, and the two readers built on it:
--   public.get_ci_branch_directory_v1, public.get_ci_branch_comparison_v1.
--
-- Proves db/migrations/20261006_nestly_v777_branch_code_and_comparison.sql.
--
-- Named for v777 because the column, the trigger and both RPCs are new above the v422 baseline
-- watermark: every assertion below is `n/a` in the baseline phase and gated entirely on the
-- migrated run (`--migrated-only`). See docs/qa/CI-CORPUS-FIXTURE-GUIDE.md for the harness, the
-- impersonation recipe and the operational-business recipe this fixture follows.
--
-- WHY THE DATES ARE ABSOLUTE. The window is 2026-03-02 (Monday) .. 2026-03-29 (Sunday) — 28
-- days, exactly four occurrences of every weekday, so the k=4 weekday-occurrence floor is
-- cleared by all seven and every per_occurrence below is a fixed number rather than "whatever
-- today happens to be". Every fixture row carries an EXPLICIT created_at inside that window and
-- every call passes an explicit p_as_of, so nothing depends on the wall clock. The only
-- clock-dependent inputs are birth dates, written relative to current_date so the age bands
-- stay put.
--
-- ===========================================================================================
-- THE CORPUS (all of it; nothing else is inserted for this business)
-- ===========================================================================================
-- Branches, inserted in this order, three of them WITHOUT a code so the generator runs:
--   brA  'ZZ Bugis'    is_default, active,   code omitted  -> B01   (first, and the default)
--   brB  'ZZ Tampines' active,                code omitted  -> B02
--   brC  'ZZ Jurong'   active,                code omitted  -> B03
--   brD  'ZZ Depot'    INACTIVE,              code 'MAIN'   -> MAIN (supplied: untouched)
--   (brB, brC and brD are inserted with billing_state 'active': nestly_v665 switches an unpaid
--    extra branch OFF at insert time, so without it B02 and B03 would not be trading at all)
--   brE  'ZZ Yishun'   INACTIVE,              code omitted  -> B04  (inserted LAST, after the
--        reader assertions: proves next-free reads max(Bnn)+1 and IGNORES 'MAIN', which a
--        count-based generator would have collided with at B04 only by luck and at B03 by rule)
--
-- Clients: c1..c6 female 27y (25_30) · c7 male 45y (41_50) · c8 NO gender, 27y (25_30)
--          c9 male, NO birth date (age unknown) · c10 female 45y (41_50)
--          syn = synthetic (must be invisible everywhere).
--
--  #    branch  client  date        SGT     amount  item
--  a1   brA     c1      03-02 Mon   10:30   10000   Haircut
--  a2   brA     c2      03-02 Mon   10:30   10000   Haircut
--  a3   brA     c3      03-09 Mon   10:30   10000   Haircut
--  a4   brA     c4      03-16 Mon   10:30   10000   Haircut
--  a5   brA     c5      03-03 Tue   10:30   10000   Colour
--  a6   brA     c6      03-04 Wed   10:30   10000   Colour
--  a7   brA     c7      03-05 Thu   10:30   20000   Colour
--  a8   brA     c8      03-06 Fri   10:30    5000   Haircut
--  b1   brB     c9      03-07 Sat   14:30   20000   Colour
--  b2   brB     c10     03-14 Sat   14:30   20000   Colour
--  b3   brB     c7      03-21 Sat   14:30   10000   Haircut
--  b4   brB     c9      03-28 Sat   14:30   10000   Haircut
--  k1   brC     c1      03-13 Fri   10:30    5000   Haircut
--  k2   brC     anon    03-13 Fri   10:30    3000   Haircut
--  sr1  brA     c5      03-05 Thu   10:30   50000   Haircut   <- REVERSED by sr2
--  ss1  brA     syn     03-02 Mon   10:30   99000   Haircut   <- SYNTHETIC
--  sp1  brA     c1      02-10       10:30   10000   Haircut   <- BEFORE the window
--  brD gets NO sales at all, so `business` totals equal the sum of the compared branches.
--
-- sr1/ss1 are the two negative controls every figure must ignore; sp1 is the control that makes
-- c1 NOT a new customer anywhere (their first-ever visit is outside the window), which is the
-- only way to tell "new_customers" apart from "customers".
--
-- ===========================================================================================
-- TRUTH TABLE 1 — the codes
-- ===========================================================================================
-- brA 'B01' · brB 'B02' · brC 'B03' · brD 'MAIN' (supplied, untouched) · brE 'B04'.
-- THE BACKFILL is driven, not observed. A third firm (biz3) holds p1 (created 01-05), p2 (the
-- DEFAULT, created 01-10) and p3 (created 01-07); the codes of biz3's three branches AND of
-- biz2's single branch are cleared and app.branch_code_backfill_v777() is run over all four at
-- once, which is the only way to test the ordering at all from a fixture that runs after the
-- migration. (is_default desc, created_at, id) gives p2 -> B01, p1 -> B02, p3 -> B03, while
-- biz2's branch independently gets B01 in the same call; ordering by created_at alone would
-- give p1, p3, p2, and an estate-wide counter would number all four 1..4 between them. A second
-- call codes 0 rows, and clearing p1's B02 and re-running gives it B04, never the freed B02.
-- `update brC set code='B02'` (brB's code) raises 23505 on branches_code_unique_v777.
--
-- ===========================================================================================
-- TRUTH TABLE 2 — get_ci_branch_directory_v1(biz), as the owner
-- ===========================================================================================
-- business: the fixture firm, slug 'zz-v777-branches'.
-- branches: FOUR rows ordered by code — B01 (default, active), B02, B03, MAIN (active FALSE,
--   present: a retired outlet keeps its identity). branches_hidden 0.
--
-- ===========================================================================================
-- TRUTH TABLE 3 — get_ci_branch_comparison_v1(biz, 03-02, 03-29, as_of 2026-04-01 00:00+08)
-- ===========================================================================================
-- business: visits 14, revenue_cents 153000, customers 10 (c1..c10).
-- branches_compared 3 (MAIN is inactive) · branches_hidden 0 · unattributed_visits 0.
--
--   B01 'ZZ Bugis'   visits 8  revenue 85000  customers 8  new_customers 7 (c2..c8; c1 is not)
--        share_of_visits 8/14 -> 57.1 · share_of_revenue 85000/153000 -> 55.6
--        gender: known 7 -> female 6 (6/7 -> 85.7) · male 1 (1/7 -> 14.3); unknown_gender 1 (c8,
--                OUTSIDE the share denominator)
--        age: known 8 -> 25_30 7 (7/8 -> 87.5) · 41_50 1 (1/8 -> 12.5); unknown_age 0
--        coverage gender_known 7/8 -> 87.5 · age_known 8/8 -> 100.0
--        top_age_band {25_30, 7}  (7 >= the k=5 floor)
--        weekdays: Mon 4/4 = 1.0 · Tue/Wed/Thu/Fri 1/4 = 0.3 · Sat 0.0 · Sun 0.0
--          busiest Monday 1.0 · slowest Saturday 0.0 (the 0.0 tie breaks on dow, Sat before Sun)
--        top_item Haircut 45000 / 5 buyers (Colour is 40000 / 3)
--   B02 'ZZ Tampines' visits 4  revenue 60000  customers 3  new_customers 2 (c9, c10; c7's
--        first-ever visit was at B01 on 03-05, so B02 does not get to call them new)
--        share_of_visits 4/14 -> 28.6 · share_of_revenue 60000/153000 -> 39.2
--        gender: known 3 -> BELOW the floor, so male 2 and female 1 keep their counts and their
--                denominator 3 while both pcts are NULL; unknown_gender 0
--        age: known 2 -> 41_50 2, pct NULL; unknown_age 1 (c9)
--        coverage gender_known 3/3 -> 100.0 · age_known 2/3 -> 66.7
--        top_age_band NULL (41_50 has 2 customers, below the floor — never printed as a finding)
--        busiest Saturday 1.0 · slowest Monday 0.0 (six weekdays tie at 0.0; dow asc picks Mon)
--        top_item Colour 40000 / 2 buyers
--   B03 'ZZ Jurong'   visits 2  revenue 8000   customers 1  new_customers 0
--        share_of_visits 2/14 -> 14.3
--        top_item Haircut 5000 / 1 buyer — the anonymous 3000 line is neither revenue nor a
--        buyer here, which is get_ci_demographic_totals_v1.by_item's own identified-only base
-- sum(branches[].visits) = 8 + 4 + 2 = 14 = business.visits, and the same for revenue.
--
-- ===========================================================================================
-- ACCESS
-- ===========================================================================================
-- * A second business's owner is refused 42501 by BOTH readers, after a precondition proving
--   they can read their OWN firm.
-- * BRANCH SCOPE. A bookkeeper (role_class 'employee', so branch-restricted; view_finance via
--   app.role_perms; customerintel in staff.modules) assigned to B01 only is refused 42501 by
--   both readers — because nestly_v721's own rule inside app.ci_access_gate_v667 refuses a
--   branch-restricted employee a FIRM-WIDE (p_branch null) call outright. The precondition
--   asserts the refusal is earned and is about branch scope and nothing else: the same caller
--   clears app.ci_access_gate_v667 for their OWN branch, holds customerintel and view_finance,
--   and app.can_see_branch(biz, B01) is true while app.can_see_branch(biz, null) is false.
--   There is therefore NO principal this product can currently produce that reaches these
--   readers and still has a branch hidden from it, so `branches_hidden` is asserted at 0 for
--   every caller that gets an answer at all. The per-branch gate loop is not dead code — it is
--   what keeps that true if the firm-wide rule is ever relaxed — but it is not reachable today
--   and this fixture does not pretend otherwise.
-- * An inverted window is refused 22023, not silently emptied.
-- ===========================================================================================
\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v777$
declare
  biz      uuid := '00000000-0000-4000-8000-000000777001';
  u_owner  uuid := '00000000-0000-4000-8000-000000777002';
  u_bk     uuid := '00000000-0000-4000-8000-000000777003';
  biz2     uuid := '00000000-0000-4000-8000-000000777004';
  u_owner2 uuid := '00000000-0000-4000-8000-000000777005';

  brA uuid := '00000000-0000-4000-8000-000000777011';
  brB uuid := '00000000-0000-4000-8000-000000777012';
  brC uuid := '00000000-0000-4000-8000-000000777013';
  brD uuid := '00000000-0000-4000-8000-000000777014';
  brE uuid := '00000000-0000-4000-8000-000000777015';
  br2 uuid := '00000000-0000-4000-8000-000000777016';

  biz3 uuid := '00000000-0000-4000-8000-000000777006';
  p1   uuid := '00000000-0000-4000-8000-000000777017';
  p2   uuid := '00000000-0000-4000-8000-000000777018';
  p3   uuid := '00000000-0000-4000-8000-000000777019';

  st_bk uuid := '00000000-0000-4000-8000-000000777021';

  c1  uuid := '00000000-0000-4000-8000-000000777101';
  c2  uuid := '00000000-0000-4000-8000-000000777102';
  c3  uuid := '00000000-0000-4000-8000-000000777103';
  c4  uuid := '00000000-0000-4000-8000-000000777104';
  c5  uuid := '00000000-0000-4000-8000-000000777105';
  c6  uuid := '00000000-0000-4000-8000-000000777106';
  c7  uuid := '00000000-0000-4000-8000-000000777107';
  c8  uuid := '00000000-0000-4000-8000-000000777108';
  c9  uuid := '00000000-0000-4000-8000-000000777109';
  c10 uuid := '00000000-0000-4000-8000-000000777110';
  syn uuid := '00000000-0000-4000-8000-000000777111';

  svc_cut   uuid := '00000000-0000-4000-8000-000000777201';
  svc_color uuid := '00000000-0000-4000-8000-000000777202';

  a1 uuid := '00000000-0000-4000-8000-000000777301';
  a2 uuid := '00000000-0000-4000-8000-000000777302';
  a3 uuid := '00000000-0000-4000-8000-000000777303';
  a4 uuid := '00000000-0000-4000-8000-000000777304';
  a5 uuid := '00000000-0000-4000-8000-000000777305';
  a6 uuid := '00000000-0000-4000-8000-000000777306';
  a7 uuid := '00000000-0000-4000-8000-000000777307';
  a8 uuid := '00000000-0000-4000-8000-000000777308';
  b1 uuid := '00000000-0000-4000-8000-000000777311';
  b2 uuid := '00000000-0000-4000-8000-000000777312';
  b3 uuid := '00000000-0000-4000-8000-000000777313';
  b4 uuid := '00000000-0000-4000-8000-000000777314';
  k1 uuid := '00000000-0000-4000-8000-000000777321';
  k2 uuid := '00000000-0000-4000-8000-000000777322';
  sr1 uuid := '00000000-0000-4000-8000-000000777331';
  sr2 uuid := '00000000-0000-4000-8000-000000777332';
  ss1 uuid := '00000000-0000-4000-8000-000000777333';
  sp1 uuid := '00000000-0000-4000-8000-000000777334';

  v_spine uuid;
  v_cfg   uuid;

  w_from date := date '2026-03-02';
  w_to   date := date '2026-03-29';
  as_of  timestamptz := timestamptz '2026-04-01 00:00:00+08';

  owner_claims  text;
  bk_claims     text;
  owner2_claims text;

  g_dir jsonb; g_cmp jsonb;
  v_row jsonb; v_sub jsonb;
  v_err text;
  v_txt text;
  v_n   bigint;
  v_n2  bigint;
begin
  owner_claims  := json_build_object('sub', u_owner,  'role', 'authenticated')::text;
  bk_claims     := json_build_object('sub', u_bk,     'role', 'authenticated')::text;
  owner2_claims := json_build_object('sub', u_owner2, 'role', 'authenticated')::text;

  ---------------------------------------------------------------------------
  -- actors + two operational businesses (CI-CORPUS-FIXTURE-GUIDE.md recipe)
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_owner,  'zz-v777-owner@example.test'),
    (u_bk,     'zz-v777-bk@example.test'),
    (u_owner2, 'zz-v777-owner2@example.test')
    on conflict (id) do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz,  'ZZ v777 branch fixture', 'zz-v777-branches',
       array['dashboard','clients','sales','reports','loyalty','customerintel']),
    (biz2, 'ZZ v777 other firm', 'zz-v777-other',
       array['dashboard','clients','sales','reports','loyalty','customerintel']),
    (biz3, 'ZZ v777 backfill firm', 'zz-v777-backfill',
       array['dashboard','clients','sales','reports']);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz,  u_owner,  'owner', 'ZZ v777 owner',  true, 'approved'),
    (biz2, u_owner2, 'owner', 'ZZ v777 owner2', true, 'approved');
  -- The branch-restricted caller: role_class('bookkeeper') = 'employee', app.role_perms gives
  -- it view_finance, and staff.modules grants customerintel. Everything the CI gate's merchant
  -- arm asks for; nothing that would make app.can_see_branch(biz, null) true.
  insert into public.staff (id, business_id, user_id, role, full_name, active, access_state, modules)
  values (st_bk, biz, u_bk, 'bookkeeper', 'ZZ v777 bookkeeper', true, 'approved',
          array['dashboard','sales','reports','customerintel']);

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v777 fixture'), (biz2, 'approved', now(), 'v777 fixture')
    on conflict (business_id) do update
      set approval_status = 'approved', decided_at = now(), decision_reason = 'v777 fixture';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false), (biz2, 'current', false)
    on conflict (business_id) do update set state = 'current', workspace_paused = false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz,  'active', 'paid', now() + interval '30 days'),
         (biz2, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status = 'active', payment_status = 'paid',
          current_period_end = now() + interval '30 days';

  ---------------------------------------------------------------------------
  -- BRANCHES. Three inserts omit `code` entirely; one supplies it.
  ---------------------------------------------------------------------------
  -- billing_state is NOT decoration here: app.assign_branch_billing_state_v665 (nestly_v665)
  -- forces every branch after a firm's first one to 'pending_payment' AND sets active := false,
  -- so a second outlet inserted with active=true is silently switched off. B02/B03 are inserted
  -- as PAID units so they are genuinely trading; MAIN is paid and deliberately switched off, so
  -- the directory has a retired outlet to show and the comparison has one to leave out.
  insert into public.branches (id, business_id, name, is_default, active, created_at) values
    (brA, biz, 'ZZ Bugis',    true,  true,  timestamptz '2026-01-01 09:00:00+08');
  insert into public.branches
    (id, business_id, name, is_default, active, created_at, billing_state) values
    (brB, biz, 'ZZ Tampines', false, true,  timestamptz '2026-01-02 09:00:00+08', 'active');
  insert into public.branches
    (id, business_id, name, is_default, active, created_at, billing_state) values
    (brC, biz, 'ZZ Jurong',   false, true,  timestamptz '2026-01-03 09:00:00+08', 'active');
  insert into public.branches
    (id, business_id, name, is_default, active, created_at, billing_state, code) values
    (brD, biz, 'ZZ Depot',    false, false, timestamptz '2026-01-04 09:00:00+08', 'active', 'MAIN');
  insert into public.branches (id, business_id, name, is_default, active) values
    (br2, biz2, 'ZZ other main', true, true);

  -- The backfill firm. Its DEFAULT branch is deliberately NOT the earliest created, which is a
  -- shape the BEFORE INSERT generator can never produce: the generator numbers in insert order,
  -- so only a set backfill can put a later-created default first. p1 is inserted first so v665
  -- gives it the 'included' base unit; p2 is the default; p3 sits between them by created_at.
  insert into public.branches
    (id, business_id, name, is_default, active, created_at, billing_state) values
    (p1, biz3, 'ZZ P One',   false, true,  timestamptz '2026-01-05 09:00:00+08', 'active');
  insert into public.branches
    (id, business_id, name, is_default, active, created_at, billing_state) values
    (p2, biz3, 'ZZ P Two',   true,  true,  timestamptz '2026-01-10 09:00:00+08', 'active');
  insert into public.branches
    (id, business_id, name, is_default, active, created_at, billing_state) values
    (p3, biz3, 'ZZ P Three', false, true,  timestamptz '2026-01-07 09:00:00+08', 'active');

  ---------------------------------------------------------------------------
  -- loyalty spine + published config version (v423's recipe, as v772's fixture uses it) so the
  -- AFTER INSERT sale triggers have a published configuration to resolve against.
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
           md5('zz-v777-published'), now()
      from public.firm_config_versions fcv where fcv.business_id = biz;
  end if;
  update public.businesses set active_config_version_id = v_cfg where id = biz;

  ---------------------------------------------------------------------------
  -- catalogue + clients
  ---------------------------------------------------------------------------
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_cut,   biz, 'ZZ Haircut', 10000, 45),
    (svc_color, biz, 'ZZ Colour',  20000, 90);

  insert into public.clients (id, business_id, full_name, birth_date, gender) values
    (c1,  biz, 'ZZ Ann',  current_date - interval '27 years', 'female'),
    (c2,  biz, 'ZZ Bea',  current_date - interval '27 years', 'female'),
    (c3,  biz, 'ZZ Cara', current_date - interval '27 years', 'female'),
    (c4,  biz, 'ZZ Dee',  current_date - interval '27 years', 'female'),
    (c5,  biz, 'ZZ Eve',  current_date - interval '27 years', 'female'),
    (c6,  biz, 'ZZ Fay',  current_date - interval '27 years', 'female'),
    (c7,  biz, 'ZZ Gil',  current_date - interval '45 years', 'male'),
    (c10, biz, 'ZZ Joy',  current_date - interval '45 years', 'female');
  insert into public.clients (id, business_id, full_name, birth_date) values
    (c8, biz, 'ZZ Hal', current_date - interval '27 years');   -- no gender
  insert into public.clients (id, business_id, full_name, gender) values
    (c9, biz, 'ZZ Ivan', 'male');                              -- no birth date
  insert into public.clients (id, business_id, full_name, birth_date, gender, is_synthetic)
  values (syn, biz, 'ZZ Synthetic', current_date - interval '27 years', 'female', true);

  ---------------------------------------------------------------------------
  -- sales (branch_id ALWAYS explicit; explicit created_at so p_as_of is deterministic)
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                            occurred_at, created_at, counts_as_revenue, counts_as_visit) values
    (a1,  biz, brA, c1,   'service', 10000, timestamptz '2026-03-02 10:30:00+08',
                                            timestamptz '2026-03-02 10:30:00+08', true, true),
    (a2,  biz, brA, c2,   'service', 10000, timestamptz '2026-03-02 10:30:00+08',
                                            timestamptz '2026-03-02 10:30:00+08', true, true),
    (a3,  biz, brA, c3,   'service', 10000, timestamptz '2026-03-09 10:30:00+08',
                                            timestamptz '2026-03-09 10:30:00+08', true, true),
    (a4,  biz, brA, c4,   'service', 10000, timestamptz '2026-03-16 10:30:00+08',
                                            timestamptz '2026-03-16 10:30:00+08', true, true),
    (a5,  biz, brA, c5,   'service', 10000, timestamptz '2026-03-03 10:30:00+08',
                                            timestamptz '2026-03-03 10:30:00+08', true, true),
    (a6,  biz, brA, c6,   'service', 10000, timestamptz '2026-03-04 10:30:00+08',
                                            timestamptz '2026-03-04 10:30:00+08', true, true),
    (a7,  biz, brA, c7,   'service', 20000, timestamptz '2026-03-05 10:30:00+08',
                                            timestamptz '2026-03-05 10:30:00+08', true, true),
    (a8,  biz, brA, c8,   'service',  5000, timestamptz '2026-03-06 10:30:00+08',
                                            timestamptz '2026-03-06 10:30:00+08', true, true),
    (b1,  biz, brB, c9,   'service', 20000, timestamptz '2026-03-07 14:30:00+08',
                                            timestamptz '2026-03-07 14:30:00+08', true, true),
    (b2,  biz, brB, c10,  'service', 20000, timestamptz '2026-03-14 14:30:00+08',
                                            timestamptz '2026-03-14 14:30:00+08', true, true),
    (b3,  biz, brB, c7,   'service', 10000, timestamptz '2026-03-21 14:30:00+08',
                                            timestamptz '2026-03-21 14:30:00+08', true, true),
    (b4,  biz, brB, c9,   'service', 10000, timestamptz '2026-03-28 14:30:00+08',
                                            timestamptz '2026-03-28 14:30:00+08', true, true),
    (k1,  biz, brC, c1,   'service',  5000, timestamptz '2026-03-13 10:30:00+08',
                                            timestamptz '2026-03-13 10:30:00+08', true, true),
    (k2,  biz, brC, null, 'service',  3000, timestamptz '2026-03-13 10:30:00+08',
                                            timestamptz '2026-03-13 10:30:00+08', true, true),
    (ss1, biz, brA, syn,  'service', 99000, timestamptz '2026-03-02 10:30:00+08',
                                            timestamptz '2026-03-02 10:30:00+08', true, true),
    (sp1, biz, brA, c1,   'service', 10000, timestamptz '2026-02-10 10:30:00+08',
                                            timestamptz '2026-02-10 10:30:00+08', true, true);

  insert into public.sale_items
    (business_id, sale_id, item_type, ref_id, description, qty, unit_cents, line_cents) values
    (biz, a1,  'service', svc_cut,   'ZZ Haircut', 1, 10000, 10000),
    (biz, a2,  'service', svc_cut,   'ZZ Haircut', 1, 10000, 10000),
    (biz, a3,  'service', svc_cut,   'ZZ Haircut', 1, 10000, 10000),
    (biz, a4,  'service', svc_cut,   'ZZ Haircut', 1, 10000, 10000),
    (biz, a5,  'service', svc_color, 'ZZ Colour',  1, 10000, 10000),
    (biz, a6,  'service', svc_color, 'ZZ Colour',  1, 10000, 10000),
    (biz, a7,  'service', svc_color, 'ZZ Colour',  1, 20000, 20000),
    (biz, a8,  'service', svc_cut,   'ZZ Haircut', 1,  5000,  5000),
    (biz, b1,  'service', svc_color, 'ZZ Colour',  1, 20000, 20000),
    (biz, b2,  'service', svc_color, 'ZZ Colour',  1, 20000, 20000),
    (biz, b3,  'service', svc_cut,   'ZZ Haircut', 1, 10000, 10000),
    (biz, b4,  'service', svc_cut,   'ZZ Haircut', 1, 10000, 10000),
    (biz, k1,  'service', svc_cut,   'ZZ Haircut', 1,  5000,  5000),
    -- the anonymous line: a real 3000 of Haircut that must NOT reach top_item
    (biz, k2,  'service', svc_cut,   'ZZ Haircut', 1,  3000,  3000),
    (biz, ss1, 'service', svc_cut,   'ZZ Haircut', 1, 99000, 99000),
    (biz, sp1, 'service', svc_cut,   'ZZ Haircut', 1, 10000, 10000);

  -- negative control: a genuine reversal pair on c5 at B01 (write-guard GUC recipe). If it
  -- leaked, B01 would read 9 visits / 135000 and Thursday would become the busiest weekday.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                            occurred_at, created_at, counts_as_revenue, counts_as_visit)
  values (sr1, biz, brA, c5, 'service', 50000, timestamptz '2026-03-05 10:30:00+08',
          timestamptz '2026-03-05 10:30:00+08', true, true);
  insert into public.sale_items
    (business_id, sale_id, item_type, ref_id, description, qty, unit_cents, line_cents)
  values (biz, sr1, 'service', svc_cut, 'ZZ Haircut', 1, 50000, 50000);
  perform set_config('app.sale_reversal_insert_id', sr2::text, true);
  perform set_config('app.sale_reversal_original_id', sr1::text, true);
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                            occurred_at, created_at, reversal_of, reversal_reason,
                            reversal_actor, reversal_idempotency_key)
  values (sr2, biz, brA, c5, 'service', -50000, timestamptz '2026-03-05 10:30:00+08',
          timestamptz '2026-03-05 10:30:00+08', sr1, 'ZZ v777 fixture reversal', u_owner,
          'zz-v777-sale-rev-001');
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);

  -- the bookkeeper works at B01 and nowhere else
  insert into public.staff_branches (business_id, staff_id, branch_id)
  values (biz, st_bk, brA);

  -- ======================================================================== 1. THE CODES
  select br.code into v_txt from public.branches br where br.id = brA;
  if v_txt is distinct from 'B01' then
    insert into _fail values ('C-brA', coalesce(v_txt, '<null>'));
  end if;
  select br.code into v_txt from public.branches br where br.id = brB;
  if v_txt is distinct from 'B02' then
    insert into _fail values ('C-brB', coalesce(v_txt, '<null>'));
  end if;
  select br.code into v_txt from public.branches br where br.id = brC;
  if v_txt is distinct from 'B03' then
    insert into _fail values ('C-brC', coalesce(v_txt, '<null>'));
  end if;
  -- the supplied code is the caller's, verbatim
  select br.code into v_txt from public.branches br where br.id = brD;
  if v_txt is distinct from 'MAIN' then
    insert into _fail values ('C-brD', coalesce(v_txt, '<null>'));
  end if;

  -- ======================================================================== THE BACKFILL
  -- An acceptance fixture runs AFTER the migration, so by the time it looks, every branch
  -- already carries a code and any assertion about the backfill's ORDERING is vacuous. Measured,
  -- not assumed: an earlier draft of this file asserted the estate-wide shape and stayed green
  -- when `is_default desc` was deleted from the ordering, because this harness database holds no
  -- branch older than the fixture itself. So the rule is driven directly instead: clear the
  -- three codes the trigger just generated for the backfill firm and run
  -- app.branch_code_backfill_v777() over them, exactly as the migration ran it over production.
  -- TWO firms are cleared, not one, and backfilled in the SAME call: with only one firm
  -- uncoded an estate-wide counter is indistinguishable from a per-business one, and the
  -- `partition by business_id` would go untested. (Measured: it did.)
  update public.branches set code = null where business_id in (biz2, biz3);
  select count(*) into v_n
    from public.branches where business_id in (biz2, biz3) and code is null;
  if v_n <> 4 then
    insert into _fail values ('C-backfill-pre',
      format('%s branches were cleared, expected 4 (biz2 has 1, biz3 has 3)', v_n));
  end if;

  v_n := app.branch_code_backfill_v777();
  if v_n <> 4 then
    insert into _fail values ('C-backfill-rows', v_n::text);
  end if;
  -- (is_default desc, created_at, id): the DEFAULT p2 first even though p1 and p3 were created
  -- before it, then p1 (01-05), then p3 (01-07). Ordering by created_at alone would say
  -- p1, p3, p2; ordering desc would say p2, p3, p1.
  select br.code into v_txt from public.branches br where br.id = p2;
  if v_txt is distinct from 'B01' then
    insert into _fail values ('C-backfill-default-b01', coalesce(v_txt, '<null>'));
  end if;
  select br.code into v_txt from public.branches br where br.id = p1;
  if v_txt is distinct from 'B02' then
    insert into _fail values ('C-backfill-second', coalesce(v_txt, '<null>'));
  end if;
  select br.code into v_txt from public.branches br where br.id = p3;
  if v_txt is distinct from 'B03' then
    insert into _fail values ('C-backfill-third', coalesce(v_txt, '<null>'));
  end if;
  -- the numbering restarts inside every business: biz2's only branch is B01 in the very same
  -- backfill call that made biz3's default B01, so this is per-business and not an estate-wide
  -- counter (which would have numbered them 1..4 between them)
  select br.code into v_txt from public.branches br where br.id = br2;
  if v_txt is distinct from 'B01' then
    insert into _fail values ('C-backfill-per-business', coalesce(v_txt, '<null>'));
  end if;

  -- idempotent, and it numbers UPWARD rather than reusing: a second call with nothing null
  -- changes nothing, and a freed B02 is not handed back out.
  v_n := app.branch_code_backfill_v777();
  if v_n <> 0 then
    insert into _fail values ('C-backfill-idempotent', v_n::text);
  end if;
  update public.branches set code = null where id = p1;
  v_n := app.branch_code_backfill_v777();
  select br.code into v_txt from public.branches br where br.id = p1;
  if v_n <> 1 or v_txt is distinct from 'B04' then
    insert into _fail values ('C-backfill-next-free',
      format('rows=%s code=%s', v_n, coalesce(v_txt, '<null>')));
  end if;
  -- nothing anywhere is left uncoded, and every code the two rules produced fits the constraint
  select count(*) into v_n from public.branches br where br.code is null;
  if v_n <> 0 then
    insert into _fail values ('C-backfill-null', v_n::text);
  end if;
  select count(*) into v_n from public.branches br where br.code !~ '^[A-Z0-9]{2,8}$';
  if v_n <> 0 then
    insert into _fail values ('C-backfill-shape', v_n::text);
  end if;

  -- precondition for every count below: B02 and B03 really are trading. v665 switches an
  -- unpaid extra branch off at INSERT, and a comparison over one silently-off branch would look
  -- exactly like a comparison that lost two branches to the scope loop.
  select count(*) into v_n
    from public.branches br
   where br.business_id = biz and br.active;
  if v_n <> 3 then
    insert into _fail values ('C-active-pre',
      format('%s active branches, expected 3 (B01, B02, B03)', v_n));
  end if;

  -- a duplicate code inside the firm is refused by the unique index
  begin
    update public.branches set code = 'B02' where id = brC;
    insert into _fail values ('C-dup', 'a duplicate branch code was accepted');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '23505' then insert into _fail values ('C-dup-code', v_err); end if;
  end;
  -- ...and two firms may hold the same code at once: uniqueness is per business, and biz2's
  -- own default branch was generated 'B01' while biz's brA already held it.
  select br.code into v_txt from public.branches br where br.id = br2;
  if v_txt is distinct from 'B01' then
    insert into _fail values ('C-cross-firm', coalesce(v_txt, '<null>'));
  end if;

  -- ======================================================================== 2. DIRECTORY
  perform set_config('request.jwt.claims', owner_claims, true);
  begin
    g_dir := public.get_ci_branch_directory_v1(biz);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('D-call', format('owner refused by the CI gate (%s)', v_err));
    g_dir := null;
  end;
  if g_dir is not null then
    if g_dir->'business'->>'slug' is distinct from 'zz-v777-branches' then
      insert into _fail values ('D-slug', coalesce(g_dir->'business'->>'slug', '<null>'));
    end if;
    if jsonb_array_length(coalesce(g_dir->'branches', '[]'::jsonb)) <> 4 then
      insert into _fail values ('D-count',
        jsonb_array_length(coalesce(g_dir->'branches', '[]'::jsonb))::text);
    else
      v_row := g_dir->'branches'->0;
      if v_row->>'code' <> 'B01' or v_row->>'name' <> 'ZZ Bugis'
         or (v_row->>'is_default')::boolean is distinct from true
         or (v_row->>'active')::boolean is distinct from true then
        insert into _fail values ('D-row0', v_row::text);
      end if;
      if g_dir->'branches'->1->>'code' <> 'B02'
         or g_dir->'branches'->2->>'code' <> 'B03' then
        insert into _fail values ('D-order',
          format('%s,%s', g_dir->'branches'->1->>'code', g_dir->'branches'->2->>'code'));
      end if;
      -- the retired outlet keeps its identity and says it is retired
      v_row := g_dir->'branches'->3;
      if v_row->>'code' <> 'MAIN' or (v_row->>'active')::boolean is distinct from false then
        insert into _fail values ('D-inactive', v_row::text);
      end if;
    end if;
    if (g_dir->>'branches_hidden')::bigint <> 0 then
      insert into _fail values ('D-hidden', coalesce(g_dir->>'branches_hidden', '<null>'));
    end if;
  end if;

  -- ======================================================================== 3. COMPARISON
  begin
    g_cmp := public.get_ci_branch_comparison_v1(biz, w_from, w_to, as_of);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('P-call', format('owner refused by the CI gate (%s)', v_err));
    g_cmp := null;
  end;

  if g_cmp is not null then
    if (g_cmp->'business'->>'visits')::bigint <> 14
       or (g_cmp->'business'->>'revenue_cents')::bigint <> 153000
       or (g_cmp->'business'->>'customers')::bigint <> 10 then
      insert into _fail values ('P-business', (g_cmp->'business')::text);
    end if;
    if (g_cmp->>'branches_compared')::bigint <> 3
       or (g_cmp->>'branches_hidden')::bigint <> 0
       or (g_cmp->>'unattributed_visits')::bigint <> 0 then
      insert into _fail values ('P-counts',
        format('compared=%s hidden=%s unattributed=%s', g_cmp->>'branches_compared',
               g_cmp->>'branches_hidden', g_cmp->>'unattributed_visits'));
    end if;
    if g_cmp->>'limitation' <>
       'Branches are compared on where the sale was recorded. A customer who visits two '
       'branches is counted at each.' then
      insert into _fail values ('P-limitation', coalesce(g_cmp->>'limitation', '<null>'));
    end if;
    if g_cmp->>'evidence_class' <> 'DIRECT_FACT' then
      insert into _fail values ('P-evidence-class', coalesce(g_cmp->>'evidence_class', '<null>'));
    end if;

    if jsonb_array_length(coalesce(g_cmp->'branches', '[]'::jsonb)) <> 3 then
      insert into _fail values ('P-branch-count',
        jsonb_array_length(coalesce(g_cmp->'branches', '[]'::jsonb))::text);
    else
      -- the compared rows sum to the firm, which is what makes the shares readable
      select coalesce(sum((r->>'visits')::bigint), 0),
             coalesce(sum((r->>'revenue_cents')::bigint), 0)
        into v_n, v_n2
        from jsonb_array_elements(g_cmp->'branches') r;
      if v_n <> (g_cmp->'business'->>'visits')::bigint
         or v_n2 <> (g_cmp->'business'->>'revenue_cents')::bigint then
        insert into _fail values ('P-sum',
          format('visits=%s revenue=%s', v_n, v_n2));
      end if;

      ---------------------------------------------------------------- B01
      v_row := g_cmp->'branches'->0;
      if v_row->'branch'->>'code' <> 'B01'
         or v_row->'branch'->>'name' <> 'ZZ Bugis'
         or (v_row->'branch'->>'is_default')::boolean is distinct from true then
        insert into _fail values ('P-b01-identity', (v_row->'branch')::text);
      end if;
      if (v_row->>'visits')::bigint <> 8
         or (v_row->>'revenue_cents')::bigint <> 85000
         or (v_row->>'customers')::bigint <> 8
         or (v_row->>'new_customers')::bigint <> 7 then
        insert into _fail values ('P-b01-totals',
          format('visits=%s revenue=%s customers=%s new=%s', v_row->>'visits',
                 v_row->>'revenue_cents', v_row->>'customers', v_row->>'new_customers'));
      end if;
      if (v_row->'share_of_visits'->>'pct')::numeric <> 57.1
         or (v_row->'share_of_visits'->>'numerator')::bigint <> 8
         or (v_row->'share_of_visits'->>'denominator')::bigint <> 14
         or (v_row->'share_of_revenue'->>'pct')::numeric <> 55.6 then
        insert into _fail values ('P-b01-shares',
          format('%s / %s', (v_row->'share_of_visits')::text,
                 (v_row->'share_of_revenue')::text));
      end if;
      -- gender: the known population is the denominator, and the unknown sits outside it
      if jsonb_array_length(coalesce(v_row->'gender', '[]'::jsonb)) <> 2 then
        insert into _fail values ('P-b01-gender-count',
          jsonb_array_length(coalesce(v_row->'gender', '[]'::jsonb))::text);
      else
        v_sub := v_row->'gender'->0;
        if v_sub->>'gender' <> 'female' or (v_sub->>'customers')::bigint <> 6
           or (v_sub->'share'->>'numerator')::bigint <> 6
           or (v_sub->'share'->>'denominator')::bigint <> 7
           or (v_sub->'share'->>'pct')::numeric <> 85.7 then
          insert into _fail values ('P-b01-female', v_sub::text);
        end if;
        v_sub := v_row->'gender'->1;
        if v_sub->>'gender' <> 'male' or (v_sub->>'customers')::bigint <> 1
           or (v_sub->'share'->>'pct')::numeric <> 14.3 then
          insert into _fail values ('P-b01-male', v_sub::text);
        end if;
      end if;
      if (v_row->>'unknown_gender')::bigint <> 1 or (v_row->>'unknown_age')::bigint <> 0 then
        insert into _fail values ('P-b01-unknown',
          format('gender=%s age=%s', v_row->>'unknown_gender', v_row->>'unknown_age'));
      end if;
      if (v_row->'coverage'->'gender_known'->>'pct')::numeric <> 87.5
         or (v_row->'coverage'->'age_known'->>'pct')::numeric <> 100.0 then
        insert into _fail values ('P-b01-coverage', (v_row->'coverage')::text);
      end if;
      if v_row->'top_age_band'->>'age_band' <> '25_30'
         or (v_row->'top_age_band'->>'customers')::bigint <> 7 then
        insert into _fail values ('P-b01-top-band',
          coalesce((v_row->'top_age_band')::text, '<null>'));
      end if;
      if v_row->'busiest_weekday'->>'label' <> 'Monday'
         or (v_row->'busiest_weekday'->>'per_occurrence')::numeric <> 1.0 then
        insert into _fail values ('P-b01-busiest',
          coalesce((v_row->'busiest_weekday')::text, '<null>'));
      end if;
      if v_row->'slowest_weekday'->>'label' <> 'Saturday'
         or (v_row->'slowest_weekday'->>'per_occurrence')::numeric <> 0.0 then
        insert into _fail values ('P-b01-slowest',
          coalesce((v_row->'slowest_weekday')::text, '<null>'));
      end if;
      if v_row->'top_item'->>'item_name' <> 'ZZ Haircut'
         or (v_row->'top_item'->>'revenue_cents')::bigint <> 45000
         or (v_row->'top_item'->>'buyers')::bigint <> 5 then
        insert into _fail values ('P-b01-top-item',
          coalesce((v_row->'top_item')::text, '<null>'));
      end if;

      ---------------------------------------------------------------- B02
      v_row := g_cmp->'branches'->1;
      if v_row->'branch'->>'code' <> 'B02' then
        insert into _fail values ('P-b02-identity', (v_row->'branch')::text);
      end if;
      if (v_row->>'visits')::bigint <> 4
         or (v_row->>'revenue_cents')::bigint <> 60000
         or (v_row->>'customers')::bigint <> 3
         or (v_row->>'new_customers')::bigint <> 2 then
        insert into _fail values ('P-b02-totals',
          format('visits=%s revenue=%s customers=%s new=%s', v_row->>'visits',
                 v_row->>'revenue_cents', v_row->>'customers', v_row->>'new_customers'));
      end if;
      if (v_row->'share_of_visits'->>'pct')::numeric <> 28.6
         or (v_row->'share_of_revenue'->>'pct')::numeric <> 39.2 then
        insert into _fail values ('P-b02-shares',
          format('%s / %s', (v_row->'share_of_visits')::text,
                 (v_row->'share_of_revenue')::text));
      end if;
      -- below the k=5 floor: counts and denominator survive, the percentage does not
      v_sub := null;
      select rec into v_sub from jsonb_array_elements(v_row->'gender') rec
       where rec->>'gender' = 'male';
      if v_sub is null or (v_sub->>'customers')::bigint <> 2
         or (v_sub->'share'->>'denominator')::bigint <> 3
         or v_sub->'share'->>'pct' is not null then
        insert into _fail values ('P-b02-male', coalesce(v_sub::text, '<missing>'));
      end if;
      if v_row->'top_age_band' <> 'null'::jsonb then
        insert into _fail values ('P-b02-top-band', (v_row->'top_age_band')::text);
      end if;
      if (v_row->>'unknown_age')::bigint <> 1
         or (v_row->'coverage'->'age_known'->>'pct')::numeric <> 66.7 then
        insert into _fail values ('P-b02-age',
          format('unknown=%s coverage=%s', v_row->>'unknown_age',
                 (v_row->'coverage'->'age_known')::text));
      end if;
      if v_row->'busiest_weekday'->>'label' <> 'Saturday'
         or (v_row->'busiest_weekday'->>'per_occurrence')::numeric <> 1.0
         or v_row->'slowest_weekday'->>'label' <> 'Monday' then
        insert into _fail values ('P-b02-weekdays',
          format('%s / %s', (v_row->'busiest_weekday')::text,
                 (v_row->'slowest_weekday')::text));
      end if;
      if v_row->'top_item'->>'item_name' <> 'ZZ Colour'
         or (v_row->'top_item'->>'revenue_cents')::bigint <> 40000
         or (v_row->'top_item'->>'buyers')::bigint <> 2 then
        insert into _fail values ('P-b02-top-item',
          coalesce((v_row->'top_item')::text, '<null>'));
      end if;

      ---------------------------------------------------------------- B03
      v_row := g_cmp->'branches'->2;
      if v_row->'branch'->>'code' <> 'B03' then
        insert into _fail values ('P-b03-identity', (v_row->'branch')::text);
      end if;
      -- two visits, one of them anonymous: a visit without a person
      if (v_row->>'visits')::bigint <> 2
         or (v_row->>'revenue_cents')::bigint <> 8000
         or (v_row->>'customers')::bigint <> 1
         or (v_row->>'new_customers')::bigint <> 0 then
        insert into _fail values ('P-b03-totals',
          format('visits=%s revenue=%s customers=%s new=%s', v_row->>'visits',
                 v_row->>'revenue_cents', v_row->>'customers', v_row->>'new_customers'));
      end if;
      if (v_row->'share_of_visits'->>'pct')::numeric <> 14.3 then
        insert into _fail values ('P-b03-share', (v_row->'share_of_visits')::text);
      end if;
      -- the anonymous 3000 Haircut line is neither revenue nor a buyer here
      if v_row->'top_item'->>'item_name' <> 'ZZ Haircut'
         or (v_row->'top_item'->>'revenue_cents')::bigint <> 5000
         or (v_row->'top_item'->>'buyers')::bigint <> 1 then
        insert into _fail values ('P-b03-top-item',
          coalesce((v_row->'top_item')::text, '<null>'));
      end if;
    end if;
  end if;

  -- ======================================================================== 4. BRANCH SCOPE
  perform set_config('request.jwt.claims', bk_claims, true);
  -- preconditions: this caller genuinely holds Customer Intelligence, genuinely holds B01, and
  -- genuinely does NOT hold the firm-wide scope the refusal below is about.
  if app.can_module(biz, 'customerintel') is distinct from true
     or app.has_perm(biz, 'view_finance') is distinct from true then
    insert into _fail values ('S-pre-gate',
      'the bookkeeper cannot reach Customer Intelligence at all, so the refusal proves nothing');
  end if;
  if app.can_see_branch(biz, brA) is distinct from true then
    insert into _fail values ('S-pre-branch',
      'the bookkeeper is not assigned B01, so the refusal is not about firm-wide scope');
  end if;
  if app.can_see_branch(biz, null) is distinct from false then
    insert into _fail values ('S-pre-firmwide',
      'the bookkeeper already holds firm-wide branch scope, so nothing is being restricted');
  end if;
  begin
    perform app.ci_access_gate_v667(biz, brA);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('S-pre-own-branch',
      format('the bookkeeper cannot even read their OWN branch (%s)', v_err));
  end;
  -- the refusal itself: firm-wide is not theirs to ask for
  begin
    perform public.get_ci_branch_comparison_v1(biz, w_from, w_to, as_of);
    insert into _fail values ('S-cmp', 'a branch-restricted employee read the firm-wide comparison');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '42501' then insert into _fail values ('S-cmp-code', v_err); end if;
  end;
  begin
    perform public.get_ci_branch_directory_v1(biz);
    insert into _fail values ('S-dir', 'a branch-restricted employee read the firm-wide directory');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '42501' then insert into _fail values ('S-dir-code', v_err); end if;
  end;

  -- ======================================================================== 5. ISOLATION
  perform set_config('request.jwt.claims', owner2_claims, true);
  -- precondition: this caller genuinely holds CI access — on their OWN firm
  begin
    perform public.get_ci_branch_directory_v1(biz2);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('X-pre',
      format('the other firm''s owner cannot read their OWN firm (%s), so the refusal below '
             'proves nothing', v_err));
  end;
  begin
    perform public.get_ci_branch_directory_v1(biz);
    insert into _fail values ('X-dir', 'a foreign owner read this firm''s branch directory');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '42501' then insert into _fail values ('X-dir-code', v_err); end if;
  end;
  begin
    perform public.get_ci_branch_comparison_v1(biz, w_from, w_to, as_of);
    insert into _fail values ('X-cmp', 'a foreign owner read this firm''s branch comparison');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '42501' then insert into _fail values ('X-cmp-code', v_err); end if;
  end;

  -- ======================================================================== 6. WINDOW
  perform set_config('request.jwt.claims', owner_claims, true);
  begin
    perform public.get_ci_branch_comparison_v1(biz, w_to, w_from, as_of);
    insert into _fail values ('W-window', 'an inverted window was accepted');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then insert into _fail values ('W-window-code', v_err); end if;
  end;

  -- ======================================================================== 7. NEXT FREE
  -- Inserted LAST so it cannot disturb the directory or the comparison. The firm now holds
  -- B01, B02, B03 and MAIN; next-free is max(Bnn)+1 = B04, and 'MAIN' contributes nothing.
  insert into public.branches (id, business_id, name, is_default, active)
  values (brE, biz, 'ZZ Yishun', false, false);
  select br.code into v_txt from public.branches br where br.id = brE;
  if v_txt is distinct from 'B04' then
    insert into _fail values ('N-next-free', coalesce(v_txt, '<null>'));
  end if;

  perform set_config('request.jwt.claims', null, true);
end
$v777$;

select case when count(*) = 0
            then 'PASS — v777 branch codes and the branch comparison hold their predetermined truth table'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v777: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
