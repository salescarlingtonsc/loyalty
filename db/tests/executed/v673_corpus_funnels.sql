-- EXECUTED acceptance fixture for nestly_v673 — lifecycle funnel + fixed-window retention.
--
-- Named for v673 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md). Proves
-- db/migrations/20260902_nestly_v673_retention_funnels.sql's two readers,
-- public.get_ci_funnel_conversion_v1 and public.get_ci_retention_windows_v1, against
-- PREDETERMINED truth tables — exact numerator/denominator/pct assertions throughout, never
-- `> 0` spot checks.
--
-- AUTH CONTEXT. Both readers open with app.ci_access_gate_v667(p_business, p_branch), whose
-- platform arm admits a super admin outright. A super admin session avoids needing a fully
-- operational merchant workspace (approval + subscription + staff rows) for a fixture that is
-- not testing entitlement at all — v667's own corpus already proves the entitlement boundary.
-- Per docs/qa/CI-CORPUS-FIXTURE-GUIDE.md, a platform session needs the Google-session claims
-- app.is_super_admin() now requires (nestly_v625): amr[0].method='oauth' and
-- app_metadata.providers containing 'google', in addition to a public.super_admins row.
--
-- TIME BASE. Every "today" in this fixture is v_today_sgt := (now() at time zone
-- 'Asia/Singapore')::date, and every occurred_at is midnight-SGT on (v_today_sgt - N) — not
-- bare current_date, which can read a different calendar day near a UTC/SGT midnight boundary
-- from the session's own timezone. This makes every day-offset in the truth table below an
-- exact integer number of days regardless of the wall-clock instant the harness runs at, the
-- same discipline db/tests/executed/v651_corpus_cadence.sql documents.
--
-- POPULATION FILTER. Both readers use the same three-part sale eligibility filter as every
-- other v650/v667 CI reader (counts_as_visit, reversal_of is null, not itself later reversed)
-- plus client-level is_synthetic exclusion — no v106 reporting-contract join, per this phase's
-- own instruction that raw sales filters are sufficient here.
--
-- ============================================================================================
-- TRUTH TABLE — get_ci_funnel_conversion_v1, window_days = 30
-- ============================================================================================
-- Business biz1, all sales on branch1 unless noted. Main scenario window
-- [v_today_sgt-150, v_today_sgt-1]:
--
--   cl_m1, cl_m2   first visit 100d ago, second visit 85d ago (15d gap, <=30 -> converts),
--                  third visit 75d ago (10d gap from second, <=30 -> converts). MATURE for both
--                  stages (100+30=130d in the past <= today; 85+30=115d in the past <= today).
--   cl_m3, cl_m4   first 100d ago, second 85d ago (converts second). No third visit.
--   cl_m5, cl_m6   first 100d ago only. Never converts.
--   -> mature_first = 6 (all six share the 100d-ago first visit; window fully elapsed).
--   -> stage_1_to_2: converted = {m1,m2,m3,m4} = 4. rate_block(4,6) = 66.7%.
--   -> stage_2_to_3: mature_second = {m1,m2,m3,m4} = 4 (85d-ago second visit is also mature).
--                     converted_third = {m1,m2} = 2. rate_block(2,4) = 50.0%.
--   -> bottleneck = 'second_to_third' (50.0 < 66.7).
--   -> evidence = subgroup_evidence_v1(6): n=6 >= floor 5 -> status 'ok'.
--
--   cl_immature    first visit 10d ago only. 10+30=40d needed, has not elapsed -> immature.
--   -> immature.first_stage = 1, immature.second_stage = 0 (nobody mature-converted is
--      themselves immature for stage 2 — mature_second is a subset of mature_first).
--
--   cl_synth (is_synthetic=true)  first 100d ago, second 85d ago — would add a 7th mature
--   customer and a 5th converter if counted. Excluded everywhere: the assertions above (6 and
--   4, not 7 and 5) are the exclusion proof.
--
-- Second scenario, small: window [v_today_sgt-210, v_today_sgt-190] —
--   cl_small1/2/3  first visit 200d ago only (mature, no returns).
--   -> stage_1_to_2 = rate_block(0,3) = 0/3/0.0% (counts present, not stripped).
--   -> stage_2_to_3 = rate_block(0,0) = 0/0/null (nobody converted to a second visit at all).
--   -> evidence = subgroup_evidence_v1(3): n=3 < floor 5 -> status 'insufficient'.
--   -> bottleneck MUST be null (insufficient evidence -> no diagnosis from thin data, though
--      the counts above are still returned in full).
--
-- Branch scoping, same main window and window_days=30:
--   p_branch = branch2 (a real branch of biz1 with zero sales) -> population empty: mature=0,
--     immature=0. Proves the branch filter genuinely restricts, not merely accepts the arg.
--   p_branch = branch1 (every main-scenario sale's branch) -> IDENTICAL to the unscoped call
--     (mature=6, immature=1). Proves the filter does not wrongly exclude legitimate members.
--
-- Reversed first visit (the corrected-first-visit rule), two narrow windows:
--   cl_reversed    a sale 500d ago, THEN REVERSED (a linked reversal row, reversal_of set), THEN
--                  a real, unreversed sale 300d ago. Per this migration's population rule (the
--                  three-part exclusion filter, not bespoke reversal logic), the reversed sale
--                  never enters the "first visit" candidate set, so the client's counted first
--                  visit is the 300-days-ago sale.
--   -> call A, window [v_today_sgt-310, v_today_sgt-290] (brackets the CORRECTED date):
--        mature_first = 1, immature_first = 0 — the corrected date is used.
--   -> call B, window [v_today_sgt-510, v_today_sgt-490] (brackets the REVERSED sale's OWN
--        date): mature_first = 0, immature_first = 0 — the reversed sale creates no phantom
--        population entry at its own (wrong) date.
--
-- ============================================================================================
-- TRUTH TABLE — get_ci_retention_windows_v1
-- ============================================================================================
-- Business biz2, branch2a, window [v_today_sgt-410, v_today_sgt-1]. horizons = {30,60,90,180,365}.
--
--   FAR cohort (5 customers, all first-visit v_today_sgt-400, same calendar day -> one cohort
--   month): 400 days comfortably clears even the worst-case month-end padding (<=30 days) for
--   every horizon up to 365 (worst case needs N >= padding+365 <= 395; 400 >= 395), so every
--   cell for this cohort is mature.
--     far1  returns +10d after first visit (390d ago)  -> counted at every horizon.
--     far2  returns +20d after first visit (380d ago)  -> counted at every horizon.
--     far3  returns +29d after first visit (371d ago)  -> counted at every horizon (<=30).
--     far4  returns +200d after first visit (200d ago) -> counted at 365d only (200>180).
--     far5  never returns                               -> counted nowhere.
--   -> n = 5. 30d/60d/90d/180d cells: numerator {far1,far2,far3} = 3 -> rate_block(3,5) = 60.0%.
--      365d cell: numerator {far1,far2,far3,far4} = 4 -> rate_block(4,5) = 80.0%.
--   -> evidence: n=5 >= floor 5 -> status 'ok'. No immature_cells entries for this month.
--
--   NEAR cohort (1 customer, first-visit v_today_sgt-50, no returns): 50 days is BELOW the
--   guaranteed-mature threshold for every horizon >= 60 (worst case needs N >= padding+60 <=
--   90; 50 < 60 unconditionally, since even zero month-end padding needs N>=60) — so 60d, 90d,
--   180d, 365d are UNCONDITIONALLY immature for this cohort regardless of which real calendar
--   date the harness runs on. The 30d cell sits in the genuinely ambiguous band (guaranteed
--   mature needs N>=60, guaranteed immature needs N<30, and 50 is neither) — its maturity
--   depends on the actual month-end padding for whichever date v_today_sgt-50 turns out to be
--   on a given run, so this fixture computes the expected 30d outcome from the SAME month-end
--   formula the reader uses (cohort_month_last_day + 30 <= v_today_sgt) rather than
--   hand-guessing a number, and asserts the reader agrees with that formula in whichever
--   direction it lands.
--   -> n = 1. 60d/90d/180d/365d: absent from windows, present in immature_cells.
--   -> 30d: present in windows (0/1/0.0%) and absent from immature_cells IF the month-end
--      formula says mature; otherwise absent from windows and present in immature_cells.
-- ============================================================================================

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v673$
declare
  biz1        uuid := '00000000-0000-4000-8000-000000673001';
  branch1     uuid := '00000000-0000-4000-8000-000000673011';
  branch2     uuid := '00000000-0000-4000-8000-000000673012';
  biz2        uuid := '00000000-0000-4000-8000-000000673002';
  branch2a    uuid := '00000000-0000-4000-8000-000000673021';
  u_sa        uuid := '00000000-0000-4000-8000-000000673101';
  cl_m1       uuid := '00000000-0000-4000-8000-000000673201';
  cl_m2       uuid := '00000000-0000-4000-8000-000000673202';
  cl_m3       uuid := '00000000-0000-4000-8000-000000673203';
  cl_m4       uuid := '00000000-0000-4000-8000-000000673204';
  cl_m5       uuid := '00000000-0000-4000-8000-000000673205';
  cl_m6       uuid := '00000000-0000-4000-8000-000000673206';
  cl_immature uuid := '00000000-0000-4000-8000-000000673207';
  cl_synth    uuid := '00000000-0000-4000-8000-000000673208';
  cl_reversed uuid := '00000000-0000-4000-8000-000000673209';
  cl_small1   uuid := '00000000-0000-4000-8000-000000673210';
  cl_small2   uuid := '00000000-0000-4000-8000-000000673211';
  cl_small3   uuid := '00000000-0000-4000-8000-000000673212';
  cl_far1     uuid := '00000000-0000-4000-8000-000000673301';
  cl_far2     uuid := '00000000-0000-4000-8000-000000673302';
  cl_far3     uuid := '00000000-0000-4000-8000-000000673303';
  cl_far4     uuid := '00000000-0000-4000-8000-000000673304';
  cl_far5     uuid := '00000000-0000-4000-8000-000000673305';
  cl_near1    uuid := '00000000-0000-4000-8000-000000673306';
  rev_orig_id uuid := '00000000-0000-4000-8000-000000673410';
  rev_row_id  uuid := '00000000-0000-4000-8000-000000673411';

  v_today_sgt date := (now() at time zone 'Asia/Singapore')::date;
  v_main_from date;
  v_main_to   date;
  v_small_from date;
  v_small_to   date;
  v_rev_hit_from  date;
  v_rev_hit_to    date;
  v_rev_miss_from date;
  v_rev_miss_to   date;
  v_ret_from date;
  v_ret_to   date;

  v_far_month      date;
  v_far_month_str  text;
  v_near_month     date;
  v_near_month_str text;
  v_near_last_day  date;
  v_near_30_mature boolean;

  g       jsonb;
  g_small jsonb;
  g_be    jsonb;
  g_bm    jsonb;
  g_rev_hit  jsonb;
  g_rev_miss jsonb;
  g2      jsonb;
  v_far   jsonb;
  v_near  jsonb;
  v_found boolean;
  v_err   text;
begin
  v_main_from := v_today_sgt - 150;
  v_main_to   := v_today_sgt - 1;
  v_small_from := v_today_sgt - 210;
  v_small_to   := v_today_sgt - 190;
  v_rev_hit_from  := v_today_sgt - 310;
  v_rev_hit_to    := v_today_sgt - 290;
  v_rev_miss_from := v_today_sgt - 510;
  v_rev_miss_to   := v_today_sgt - 490;
  v_ret_from := v_today_sgt - 410;
  v_ret_to   := v_today_sgt - 1;

  v_far_month     := date_trunc('month', v_today_sgt - 400)::date;
  v_far_month_str := to_char(v_far_month, 'YYYY-MM');
  v_near_month     := date_trunc('month', v_today_sgt - 50)::date;
  v_near_month_str := to_char(v_near_month, 'YYYY-MM');
  v_near_last_day  := (v_near_month + interval '1 month - 1 day')::date;
  v_near_30_mature := (v_near_last_day + 30) <= v_today_sgt;

  ---------------------------------------------------------------------------
  -- actors, businesses, branches
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values (u_sa, 'zz-v673-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v673-sa@example.test')
    on conflict do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz1, 'ZZ v673 funnel fixture', 'zz-v673-funnel', array['dashboard','clients','sales','reports']),
    (biz2, 'ZZ v673 retention fixture', 'zz-v673-retention', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (branch1, biz1, 'ZZ v673 branch one', true, true),
    (branch2, biz1, 'ZZ v673 branch two (empty)', false, true),
    (branch2a, biz2, 'ZZ v673 retention branch', true, true);

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  -- PRECONDITION: the fixture's platform session must actually clear the gate, or every
  -- assertion below is vacuous.
  begin
    perform app.ci_access_gate_v667(biz1, null);
    perform app.ci_access_gate_v667(biz2, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PRE-gate',
      format('fixture super admin cannot pass app.ci_access_gate_v667 (sqlstate %s); every '
             'assertion below would be vacuous', v_err));
  end;

  ---------------------------------------------------------------------------
  -- clients — biz1
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name) values
    (cl_m1, biz1, 'ZZ v673 mature convert-3 A'),
    (cl_m2, biz1, 'ZZ v673 mature convert-3 B'),
    (cl_m3, biz1, 'ZZ v673 mature convert-2 A'),
    (cl_m4, biz1, 'ZZ v673 mature convert-2 B'),
    (cl_m5, biz1, 'ZZ v673 mature no-return A'),
    (cl_m6, biz1, 'ZZ v673 mature no-return B'),
    (cl_immature, biz1, 'ZZ v673 immature first visit'),
    (cl_reversed, biz1, 'ZZ v673 reversed first visit'),
    (cl_small1, biz1, 'ZZ v673 small cohort A'),
    (cl_small2, biz1, 'ZZ v673 small cohort B'),
    (cl_small3, biz1, 'ZZ v673 small cohort C');
  insert into public.clients (id, business_id, full_name, is_synthetic) values
    (cl_synth, biz1, 'ZZ v673 synthetic (must be excluded)', true);

  ---------------------------------------------------------------------------
  -- sales — main scenario (6 mature + 1 immature + 1 synthetic)
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz1, branch1, c.id, 'service', 1000,
         (v_today_sgt - o)::timestamp at time zone 'Asia/Singapore',
         (v_today_sgt - o)::timestamp at time zone 'Asia/Singapore'
    from (values (cl_m1),(cl_m2)) as c(id)
    cross join unnest(array[100,85,75]) as o;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz1, branch1, c.id, 'service', 1000,
         (v_today_sgt - o)::timestamp at time zone 'Asia/Singapore',
         (v_today_sgt - o)::timestamp at time zone 'Asia/Singapore'
    from (values (cl_m3),(cl_m4)) as c(id)
    cross join unnest(array[100,85]) as o;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz1, branch1, c.id, 'service', 1000,
         (v_today_sgt - o)::timestamp at time zone 'Asia/Singapore',
         (v_today_sgt - o)::timestamp at time zone 'Asia/Singapore'
    from (values (cl_m5),(cl_m6)) as c(id)
    cross join unnest(array[100]) as o;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz1, branch1, cl_immature, 'service', 1000,
          (v_today_sgt - 10)::timestamp at time zone 'Asia/Singapore',
          (v_today_sgt - 10)::timestamp at time zone 'Asia/Singapore');

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz1, branch1, cl_synth, 'service', 1000,
         (v_today_sgt - o)::timestamp at time zone 'Asia/Singapore',
         (v_today_sgt - o)::timestamp at time zone 'Asia/Singapore'
    from unnest(array[100,85]) as o;

  ---------------------------------------------------------------------------
  -- sales — small (insufficient-evidence) scenario, isolated 200d-ago window
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz1, branch1, c.id, 'service', 1000,
         (v_today_sgt - 200)::timestamp at time zone 'Asia/Singapore',
         (v_today_sgt - 200)::timestamp at time zone 'Asia/Singapore'
    from (values (cl_small1),(cl_small2),(cl_small3)) as c(id);

  ---------------------------------------------------------------------------
  -- sales — reversed first visit: 500d-ago sale, reversed, then a real 300d-ago sale
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (rev_orig_id, biz1, branch1, cl_reversed, 'service', 1000,
          (v_today_sgt - 500)::timestamp at time zone 'Asia/Singapore',
          (v_today_sgt - 500)::timestamp at time zone 'Asia/Singapore');

  -- app.sales_reversal_insert_guard() (v20) blocks a direct reversal-row INSERT unless the
  -- session names both the new row's own id and the id it reverses in advance — the "open a
  -- one-row token only inside reverse_sale()" mechanism. A raw fixture insert must present the
  -- same two GUCs, or the trigger raises 42501 regardless of how correct the row shape is.
  perform set_config('app.sale_reversal_insert_id', rev_row_id::text, true);
  perform set_config('app.sale_reversal_original_id', rev_orig_id::text, true);
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at,
                             reversal_of, reversal_reason, reversal_actor, reversal_idempotency_key)
  values (rev_row_id, biz1, branch1, cl_reversed, 'service', -1000,
          (v_today_sgt - 499)::timestamp at time zone 'Asia/Singapore',
          (v_today_sgt - 499)::timestamp at time zone 'Asia/Singapore',
          rev_orig_id, 'ZZ v673 fixture reversal for corrected-first-visit proof', u_sa,
          'zz-v673-rev-idem-001');
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz1, branch1, cl_reversed, 'service', 1000,
          (v_today_sgt - 300)::timestamp at time zone 'Asia/Singapore',
          (v_today_sgt - 300)::timestamp at time zone 'Asia/Singapore');

  ---------------------------------------------------------------------------
  -- clients + sales — biz2 retention cohorts
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name) values
    (cl_far1, biz2, 'ZZ v673 far cohort +10d'),
    (cl_far2, biz2, 'ZZ v673 far cohort +20d'),
    (cl_far3, biz2, 'ZZ v673 far cohort +29d'),
    (cl_far4, biz2, 'ZZ v673 far cohort +200d'),
    (cl_far5, biz2, 'ZZ v673 far cohort no-return'),
    (cl_near1, biz2, 'ZZ v673 near cohort no-return');

  -- far cohort: first visit 400d ago for all five, same calendar day
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz2, branch2a, c.id, 'service', 1000,
         (v_today_sgt - 400)::timestamp at time zone 'Asia/Singapore',
         (v_today_sgt - 400)::timestamp at time zone 'Asia/Singapore'
    from (values (cl_far1),(cl_far2),(cl_far3),(cl_far4),(cl_far5)) as c(id);

  -- returns: far1 +10d (390d ago), far2 +20d (380d ago), far3 +29d (371d ago), far4 +200d (200d ago)
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (gen_random_uuid(), biz2, branch2a, cl_far1, 'service', 1000,
       (v_today_sgt - 390)::timestamp at time zone 'Asia/Singapore',
       (v_today_sgt - 390)::timestamp at time zone 'Asia/Singapore'),
    (gen_random_uuid(), biz2, branch2a, cl_far2, 'service', 1000,
       (v_today_sgt - 380)::timestamp at time zone 'Asia/Singapore',
       (v_today_sgt - 380)::timestamp at time zone 'Asia/Singapore'),
    (gen_random_uuid(), biz2, branch2a, cl_far3, 'service', 1000,
       (v_today_sgt - 371)::timestamp at time zone 'Asia/Singapore',
       (v_today_sgt - 371)::timestamp at time zone 'Asia/Singapore'),
    (gen_random_uuid(), biz2, branch2a, cl_far4, 'service', 1000,
       (v_today_sgt - 200)::timestamp at time zone 'Asia/Singapore',
       (v_today_sgt - 200)::timestamp at time zone 'Asia/Singapore');

  -- near cohort: first visit 50d ago, no returns
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz2, branch2a, cl_near1, 'service', 1000,
          (v_today_sgt - 50)::timestamp at time zone 'Asia/Singapore',
          (v_today_sgt - 50)::timestamp at time zone 'Asia/Singapore');

  ---------------------------------------------------------------------------
  -- M1 — main funnel scenario: 6 mature, 4 convert second, 2 convert third,
  --      1 immature, synthetic client excluded.
  ---------------------------------------------------------------------------
  begin
    g := public.get_ci_funnel_conversion_v1(biz1, v_main_from, v_main_to, 30, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('M1', format('get_ci_funnel_conversion_v1(main) raised %s', v_err));
  end;

  if g is not null then
    if (g->>'window_days')::int <> 30 then
      insert into _fail values ('M1', format('window_days=%s, expected 30', g->>'window_days'));
    end if;
    if g->>'time_basis' <> 'sale_occurred_at' then
      insert into _fail values ('M1', format('time_basis=%s, expected sale_occurred_at', g->>'time_basis'));
    end if;
    if (g->'stage_1_to_2'->>'numerator')::int <> 4
       or (g->'stage_1_to_2'->>'denominator')::int <> 6
       or (g->'stage_1_to_2'->>'pct')::numeric <> 66.7 then
      insert into _fail values ('M1',
        format('stage_1_to_2=%s, expected 4/6/66.7 (synthetic client must be excluded)', g->'stage_1_to_2'));
    end if;
    if (g->'stage_2_to_3'->>'numerator')::int <> 2
       or (g->'stage_2_to_3'->>'denominator')::int <> 4
       or (g->'stage_2_to_3'->>'pct')::numeric <> 50.0 then
      insert into _fail values ('M1',
        format('stage_2_to_3=%s, expected 2/4/50.0', g->'stage_2_to_3'));
    end if;
    if (g->'immature'->>'first_stage')::int <> 1 then
      insert into _fail values ('M1',
        format('immature.first_stage=%s, expected 1 (cl_immature)', g->'immature'->>'first_stage'));
    end if;
    if (g->'immature'->>'second_stage')::int <> 0 then
      insert into _fail values ('M1',
        format('immature.second_stage=%s, expected 0', g->'immature'->>'second_stage'));
    end if;
    if g->>'bottleneck' <> 'second_to_third' then
      insert into _fail values ('M1',
        format('bottleneck=%s, expected second_to_third (50.0 < 66.7)', g->>'bottleneck'));
    end if;
    if g->'evidence'->>'status' <> 'ok' or (g->'evidence'->>'n')::int <> 6 then
      insert into _fail values ('M1',
        format('evidence=%s, expected n=6 status=ok', g->'evidence'));
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- M2 — small scenario: evidence insufficient, bottleneck null, counts present.
  ---------------------------------------------------------------------------
  begin
    g_small := public.get_ci_funnel_conversion_v1(biz1, v_small_from, v_small_to, 30, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('M2', format('get_ci_funnel_conversion_v1(small) raised %s', v_err));
  end;

  if g_small is not null then
    if (g_small->'stage_1_to_2'->>'numerator')::int <> 0
       or (g_small->'stage_1_to_2'->>'denominator')::int <> 3
       or (g_small->'stage_1_to_2'->>'pct')::numeric <> 0.0 then
      insert into _fail values ('M2',
        format('stage_1_to_2=%s, expected 0/3/0.0 (counts must still be present)', g_small->'stage_1_to_2'));
    end if;
    if (g_small->'stage_2_to_3'->>'numerator')::int <> 0
       or (g_small->'stage_2_to_3'->>'denominator')::int <> 0
       or (g_small->'stage_2_to_3') -> 'pct' is distinct from 'null'::jsonb then
      insert into _fail values ('M2',
        format('stage_2_to_3=%s, expected 0/0/null', g_small->'stage_2_to_3'));
    end if;
    if g_small->'evidence'->>'status' <> 'insufficient' or (g_small->'evidence'->>'n')::int <> 3 then
      insert into _fail values ('M2',
        format('evidence=%s, expected n=3 status=insufficient', g_small->'evidence'));
    end if;
    if g_small->'bottleneck' is distinct from 'null'::jsonb then
      insert into _fail values ('M2',
        format('bottleneck=%s, expected null (insufficient evidence -> no diagnosis)', g_small->>'bottleneck'));
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- M3 — branch scoping: an empty branch yields an empty population; the
  --      matching branch yields exactly the same figures as the unscoped call.
  ---------------------------------------------------------------------------
  begin
    g_be := public.get_ci_funnel_conversion_v1(biz1, v_main_from, v_main_to, 30, branch2);
    g_bm := public.get_ci_funnel_conversion_v1(biz1, v_main_from, v_main_to, 30, branch1);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('M3', format('branch-scoped calls raised %s', v_err));
  end;

  if g_be is not null then
    if (g_be->'stage_1_to_2'->>'denominator')::int <> 0
       or (g_be->'immature'->>'first_stage')::int <> 0 then
      insert into _fail values ('M3',
        format('branch2 (empty) population not empty: stage_1_to_2=%s immature=%s',
               g_be->'stage_1_to_2', g_be->'immature'));
    end if;
  end if;
  if g_bm is not null and g is not null then
    if g_bm->'stage_1_to_2' is distinct from g->'stage_1_to_2'
       or g_bm->'immature' is distinct from g->'immature' then
      insert into _fail values ('M3',
        format('branch1-scoped call diverged from the unscoped call: %s vs %s',
               g_bm->'stage_1_to_2', g->'stage_1_to_2'));
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- M4 — reversed first visit: corrected date is used, reversed date is not.
  ---------------------------------------------------------------------------
  begin
    g_rev_hit  := public.get_ci_funnel_conversion_v1(biz1, v_rev_hit_from, v_rev_hit_to, 30, null);
    g_rev_miss := public.get_ci_funnel_conversion_v1(biz1, v_rev_miss_from, v_rev_miss_to, 30, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('M4', format('reversed-visit calls raised %s', v_err));
  end;

  if g_rev_hit is not null then
    if (g_rev_hit->'stage_1_to_2'->>'denominator')::int <> 1
       or (g_rev_hit->'immature'->>'first_stage')::int <> 0 then
      insert into _fail values ('M4',
        format('corrected-date window (300d ago) population=%s, expected exactly 1 mature '
               'client (cl_reversed at its corrected first visit)', g_rev_hit->'stage_1_to_2'));
    end if;
  end if;
  if g_rev_miss is not null then
    if (g_rev_miss->'stage_1_to_2'->>'denominator')::int <> 0
       or (g_rev_miss->'immature'->>'first_stage')::int <> 0 then
      insert into _fail values ('M4',
        format('reversed-date window (500d ago) population=%s, expected EMPTY — the reversed '
               'sale must not create a phantom entry at its own date', g_rev_miss->'stage_1_to_2'));
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- R1 — retention windows: far cohort (5, mature at every horizon) and
  --      near cohort (1, immature at 60/90/180/365, ambiguous at 30).
  ---------------------------------------------------------------------------
  begin
    g2 := public.get_ci_retention_windows_v1(biz2, v_ret_from, v_ret_to, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('R1', format('get_ci_retention_windows_v1 raised %s', v_err));
  end;

  if g2 is not null then
    if g2->>'time_basis' <> 'sale_occurred_at' then
      insert into _fail values ('R1', format('time_basis=%s, expected sale_occurred_at', g2->>'time_basis'));
    end if;
    if g2->'horizons' <> to_jsonb(array[30,60,90,180,365]) then
      insert into _fail values ('R1', format('horizons=%s, expected [30,60,90,180,365]', g2->'horizons'));
    end if;

    select elem into v_far from jsonb_array_elements(g2->'cohorts') elem
     where elem->>'month' = v_far_month_str;
    if v_far is null then
      insert into _fail values ('R1-far', format('no cohort found for month %s', v_far_month_str));
    else
      if (v_far->>'n')::int <> 5 then
        insert into _fail values ('R1-far', format('n=%s, expected 5', v_far->>'n'));
      end if;
      if v_far->'evidence'->>'status' <> 'ok' then
        insert into _fail values ('R1-far', format('evidence=%s, expected status ok (5>=5)', v_far->'evidence'));
      end if;
      if (v_far->'windows'->'30'->>'numerator')::int <> 3
         or (v_far->'windows'->'30'->>'denominator')::int <> 5
         or (v_far->'windows'->'30'->>'pct')::numeric <> 60.0 then
        insert into _fail values ('R1-far', format('windows.30=%s, expected 3/5/60.0', v_far->'windows'->'30'));
      end if;
      if (v_far->'windows'->'60'->>'pct')::numeric <> 60.0
         or (v_far->'windows'->'90'->>'pct')::numeric <> 60.0
         or (v_far->'windows'->'180'->>'pct')::numeric <> 60.0 then
        insert into _fail values ('R1-far',
          format('windows.60/90/180=%s/%s/%s, expected 60.0/60.0/60.0 (far4''s +200d return only '
                 'clears the 365d horizon)',
                 v_far->'windows'->'60'->>'pct', v_far->'windows'->'90'->>'pct', v_far->'windows'->'180'->>'pct'));
      end if;
      if (v_far->'windows'->'365'->>'numerator')::int <> 4
         or (v_far->'windows'->'365'->>'denominator')::int <> 5
         or (v_far->'windows'->'365'->>'pct')::numeric <> 80.0 then
        insert into _fail values ('R1-far', format('windows.365=%s, expected 4/5/80.0', v_far->'windows'->'365'));
      end if;
      select exists(select 1 from jsonb_array_elements(g2->'immature_cells') e
                     where e->>'month' = v_far_month_str) into v_found;
      if v_found then
        insert into _fail values ('R1-far', 'far cohort (400d ago, mature at every horizon) has an immature_cells entry');
      end if;
    end if;

    select elem into v_near from jsonb_array_elements(g2->'cohorts') elem
     where elem->>'month' = v_near_month_str;
    if v_near is null then
      insert into _fail values ('R1-near', format('no cohort found for month %s', v_near_month_str));
    else
      if (v_near->>'n')::int <> 1 then
        insert into _fail values ('R1-near', format('n=%s, expected 1', v_near->>'n'));
      end if;
      -- 60/90/180/365 are unconditionally immature at 50 days: absent from windows, present
      -- in immature_cells.
      if v_near->'windows' ? '60' or v_near->'windows' ? '90'
         or v_near->'windows' ? '180' or v_near->'windows' ? '365' then
        insert into _fail values ('R1-near',
          format('near cohort windows=%s, expected 60/90/180/365 all absent (unconditionally '
                 'immature at 50 days)', v_near->'windows'));
      end if;
      -- there must be exactly 4 such entries (60,90,180,365), not merely "at least one"
      select count(*) = 4 into v_found from jsonb_array_elements(g2->'immature_cells') e
       where e->>'month' = v_near_month_str and (e->>'horizon')::int in (60,90,180,365);
      if not v_found then
        insert into _fail values ('R1-near',
          'near cohort does not have all four of 60/90/180/365 in immature_cells');
      end if;

      if v_near_30_mature then
        if not (v_near->'windows' ? '30') then
          insert into _fail values ('R1-near-30',
            format('month-end formula says the 30d cell for %s IS mature (last_day=%s), but '
                   'windows.30 is absent', v_near_month_str, v_near_last_day));
        elsif (v_near->'windows'->'30'->>'numerator')::int <> 0
           or (v_near->'windows'->'30'->>'denominator')::int <> 1
           or (v_near->'windows'->'30'->>'pct')::numeric <> 0.0 then
          insert into _fail values ('R1-near-30',
            format('windows.30=%s, expected 0/1/0.0', v_near->'windows'->'30'));
        end if;
        select exists(select 1 from jsonb_array_elements(g2->'immature_cells') e
                       where e->>'month' = v_near_month_str and (e->>'horizon')::int = 30) into v_found;
        if v_found then
          insert into _fail values ('R1-near-30',
            'month-end formula says the 30d cell IS mature, but it also appears in immature_cells');
        end if;
      else
        if v_near->'windows' ? '30' then
          insert into _fail values ('R1-near-30',
            format('month-end formula says the 30d cell for %s is NOT yet mature (last_day=%s), '
                   'but windows.30 is present', v_near_month_str, v_near_last_day));
        end if;
        select exists(select 1 from jsonb_array_elements(g2->'immature_cells') e
                       where e->>'month' = v_near_month_str and (e->>'horizon')::int = 30) into v_found;
        if not v_found then
          insert into _fail values ('R1-near-30',
            'month-end formula says the 30d cell is NOT yet mature, but it is missing from immature_cells');
        end if;
      end if;
    end if;
  end if;
end
$v673$;

select case when count(*)=0
            then 'PASS — v673 lifecycle funnel + fixed-window retention: maturity gating, '
                 'small-cell evidence, branch scoping, corrected-first-visit reversal rule, '
                 'month-end cohort censoring'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v673: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
