-- EXECUTED acceptance fixture for nestly_v703 — the shared CI envelope reaching
-- get_ci_contactability_v1 / get_ci_engagement_v1 / get_ci_funnel_v1 / get_ci_marketing_funnel_v1,
-- and the floor gate on get_ci_retention_windows_v1's per-cohort per-horizon rate.
--
-- Named for v703 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md). Proves
-- db/migrations/20260902_nestly_v703_envelope_everywhere.sql.
--
-- AUTH CONTEXT. Same reasoning as db/tests/executed/v693_corpus_exclusions_verdicts.sql: a
-- super-admin session clears app.ci_access_gate_v667's platform arm outright, so this fixture
-- does not need a fully operational merchant workspace (staff/subscription/approval rows) — it
-- is not testing entitlement, v667's own corpus already does that.
--
-- TRUTH TABLE (computed before running anything):
--
-- PART A — exclusions travel to all five envelopes, identical counts.
--   MAIN window [w_from, w_to] = [d0, d0+10], d0 = current_date - 300 (comfortably inside
--   get_ci_engagement_v1's default 12-month trailing window, and comfortably inside "all of
--   history to date" for get_ci_contactability_v1 — see below for why that makes the three
--   different period conventions land on the SAME exclusion counts):
--     3 identified clients with full demographics (age_band + gender resolve) -- NOT counted.
--     2 identified clients with birth_date but no gender -- BOTH counted as missing_demographics.
--     1 synthetic client's sale -- counted as synthetic_clients=1, NOT missing_demographics.
--     2 anonymous sales (client_id null) -- counted as anonymous_sales=2.
--     1 reversed pair (original + reversal row) -- counted as reversed_sales=2.
--     2 customers each sent campaign A and campaign B 5 days apart (<=14) -- BOTH counted as
--       overlapping_campaigns=2. A third customer receiving only campaign A is not counted.
--   Expected exclusions on EVERY envelope that scans this data:
--     {reversed_sales:2, synthetic_clients:1, anonymous_sales:2, missing_demographics:2,
--      overlapping_campaigns:2}
--
--   get_ci_funnel_v1 and get_ci_marketing_funnel_v1 are called with the SAME explicit [w_from,w_to]
--   as get_ci_retention_windows_v1, so their exclusions must equal the main count exactly.
--
--   get_ci_contactability_v1 has no [from,to] of its own — its period is the whole history to
--   the as_of's SGT date, ['-infinity', today]. get_ci_engagement_v1's period is its own trailing
--   p_months window, [this_month - 12mo, today]. Both windows are WIDER than [w_from,w_to] but
--   this fixture seeds NOTHING outside the main window that would trip any of the five exclusion
--   categories (the retention floor-gate fixture in PART B below uses only full-demographic,
--   non-synthetic, non-reversed, non-anonymous, campaign-free clients) — so both wider-window
--   reads land on the exact same five numbers as the main window. Proven, not assumed: this
--   fixture independently recomputes each reader's own window via app.ci_exclusion_counts_v680
--   and asserts that recomputation equals the main count before trusting the reader's envelope.
--
-- PART B — get_ci_retention_windows_v1 floor gate (check 61). Three cohorts, three different
--   calendar months, all with every horizon (30/60/90/180/365) mature (month3's last day is >400
--   days before "today", clearing even the 365-day horizon with margin):
--     cohort n=1 (month1, one client, never returns): every horizon numerator=0, denominator=1,
--       evidence.status='insufficient' (1 < floor 5) -> pct NULL on every horizon, counts kept.
--     cohort n=6 (month2, six clients, three return within 15 days of first visit): every horizon
--       numerator=3, denominator=6, evidence.status='ok' (6 >= floor 5) -> pct=50.0 on every
--       horizon (the single return happens well inside even the 30-day horizon, so every wider
--       horizon counts the same three returns).
--     cohort n=5 (month3, five clients, none return) -- MUTATION-SENSITIVE BOUNDARY: n=5 sits
--       EXACTLY at the default floor. evidence.status='ok' (5 >= 5, not 5 > 5) -> pct=0.0, NOT
--       null. A mutant that floor-gates on `n > floor` instead of `n >= floor` turns this pct red
--       (null instead of 0.0) while leaving the n=1/n=6 assertions untouched -- this is this
--       fixture's "one flip -> red" proof for check 61.
--
-- VOCABULARY: this fixture never asserts on 'CAUSAL' — that vocabulary check belongs to v693's
-- own corpus and is not re-tested here.

\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

do $v703$
declare
  biz uuid := '00000000-0000-4000-8000-000000703001';
  br  uuid := '00000000-0000-4000-8000-000000703002';
  u_sa uuid := '00000000-0000-4000-8000-000000703003';
  v_err text;

  d0 date := current_date - 300;
  w_from date; w_to date;
  p_as_of timestamptz;

  -- PART A main-window population
  c_full1 uuid := '00000000-0000-4000-8000-000000703101';
  c_full2 uuid := '00000000-0000-4000-8000-000000703102';
  c_full3 uuid := '00000000-0000-4000-8000-000000703103';
  c_nog1  uuid := '00000000-0000-4000-8000-000000703104';
  c_nog2  uuid := '00000000-0000-4000-8000-000000703105';
  c_synth uuid := '00000000-0000-4000-8000-000000703106';
  c_reversed uuid := '00000000-0000-4000-8000-000000703107';
  s_rev_orig uuid := '00000000-0000-4000-8000-000000703108';
  s_rev_rev  uuid := '00000000-0000-4000-8000-000000703109';

  camp_a uuid := '00000000-0000-4000-8000-000000703110';
  camp_b uuid := '00000000-0000-4000-8000-000000703111';
  c_camp1 uuid := '00000000-0000-4000-8000-000000703112';
  c_camp2 uuid := '00000000-0000-4000-8000-000000703113';
  c_camp_only uuid := '00000000-0000-4000-8000-000000703114';

  r_excl jsonb;
  r_excl_contactability jsonb;
  r_excl_engagement jsonb;
  r_contact jsonb;
  r_engage jsonb;
  r_funnel jsonb;
  r_market jsonb;
  r_retention jsonb;

  v_today date;
  v_eng_from date;

  -- PART B retention floor-gate population
  month1_anchor date;
  month2_anchor date;
  month3_anchor date;
  fv1 date;
  fv2 date;
  fv3 date;
  ret_from date;
  ret_to date;

  c_ret1 uuid := '00000000-0000-4000-8000-000000703201';

  c_ret6_1 uuid := '00000000-0000-4000-8000-000000703211';
  c_ret6_2 uuid := '00000000-0000-4000-8000-000000703212';
  c_ret6_3 uuid := '00000000-0000-4000-8000-000000703213';
  c_ret6_4 uuid := '00000000-0000-4000-8000-000000703214';
  c_ret6_5 uuid := '00000000-0000-4000-8000-000000703215';
  c_ret6_6 uuid := '00000000-0000-4000-8000-000000703216';

  c_ret5_1 uuid := '00000000-0000-4000-8000-000000703221';
  c_ret5_2 uuid := '00000000-0000-4000-8000-000000703222';
  c_ret5_3 uuid := '00000000-0000-4000-8000-000000703223';
  c_ret5_4 uuid := '00000000-0000-4000-8000-000000703224';
  c_ret5_5 uuid := '00000000-0000-4000-8000-000000703225';

  r_ret jsonb;
  cohort_1 jsonb;
  cohort_6 jsonb;
  cohort_5 jsonb;
  month1_key text;
  month2_key text;
  month3_key text;
  h text;
  win jsonb;
begin
  ---------------------------------------------------------------------------
  -- platform (super admin) session — see CI-CORPUS-FIXTURE-GUIDE.md
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values (u_sa, 'zz-v703-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v703-sa@example.test')
    on conflict do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v703 envelope-everywhere fixture', 'zz-v703-envelope',
     array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v703 branch', true, true);

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  begin
    perform app.ci_access_gate_v667(biz, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PRE-gate',
      format('fixture super admin cannot pass app.ci_access_gate_v667 (sqlstate %s); every '
             'assertion below would be vacuous', v_err));
  end;

  ---------------------------------------------------------------------------
  -- PART A — main-window fixture (same shapes as v693's, new namespace)
  ---------------------------------------------------------------------------
  w_from := d0; w_to := d0 + 10;

  insert into public.clients (id, business_id, full_name, birth_date, gender) values
    (c_full1, biz, 'ZZ v703 full demo A', '1990-01-01', 'female'),
    (c_full2, biz, 'ZZ v703 full demo B', '1988-06-15', 'male'),
    (c_full3, biz, 'ZZ v703 full demo C', '1995-03-20', 'other'),
    (c_nog1,  biz, 'ZZ v703 no gender A', '1985-01-01', null),
    (c_nog2,  biz, 'ZZ v703 no gender B', '1982-09-09', null),
    (c_reversed, biz, 'ZZ v703 reversed', '1991-01-01', 'female');
  insert into public.clients (id, business_id, full_name, is_synthetic)
  values (c_synth, biz, 'ZZ v703 synthetic', true);
  insert into public.clients (id, business_id, full_name) values
    (c_camp1, biz, 'ZZ v703 camp overlap A'),
    (c_camp2, biz, 'ZZ v703 camp overlap B'),
    (c_camp_only, biz, 'ZZ v703 camp single');

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (gen_random_uuid(), biz, br, c_full1, 'service', 500,
     ((w_from + 1)::timestamp + time '09:00') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '09:00') at time zone 'Asia/Singapore'),
    (gen_random_uuid(), biz, br, c_full2, 'service', 500,
     ((w_from + 1)::timestamp + time '09:10') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '09:10') at time zone 'Asia/Singapore'),
    (gen_random_uuid(), biz, br, c_full3, 'service', 500,
     ((w_from + 1)::timestamp + time '09:20') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '09:20') at time zone 'Asia/Singapore'),
    (gen_random_uuid(), biz, br, c_nog1, 'service', 500,
     ((w_from + 1)::timestamp + time '09:30') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '09:30') at time zone 'Asia/Singapore'),
    (gen_random_uuid(), biz, br, c_nog2, 'service', 500,
     ((w_from + 1)::timestamp + time '09:40') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '09:40') at time zone 'Asia/Singapore');

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, br, c_synth, 'service', 500,
          ((w_from + 1)::timestamp + time '10:00') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '10:00') at time zone 'Asia/Singapore');

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (gen_random_uuid(), biz, br, null, 'retail', 200,
     ((w_from + 1)::timestamp + time '11:00') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '11:00') at time zone 'Asia/Singapore'),
    (gen_random_uuid(), biz, br, null, 'retail', 200,
     ((w_from + 1)::timestamp + time '11:10') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '11:10') at time zone 'Asia/Singapore');

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (s_rev_orig, biz, br, c_reversed, 'service', 500,
          ((w_from + 2)::timestamp + time '09:00') at time zone 'Asia/Singapore', ((w_from + 2)::timestamp + time '09:00') at time zone 'Asia/Singapore');

  perform set_config('app.sale_reversal_insert_id', s_rev_rev::text, true);
  perform set_config('app.sale_reversal_original_id', s_rev_orig::text, true);
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at,
                            created_at, reversal_of, reversal_reason, reversal_actor,
                            reversal_idempotency_key)
  values (s_rev_rev, biz, br, c_reversed, 'service', -500,
          ((w_from + 2)::timestamp + time '09:30') at time zone 'Asia/Singapore', ((w_from + 2)::timestamp + time '09:30') at time zone 'Asia/Singapore',
          s_rev_orig, 'ZZ v703 fixture reversal', u_sa, 'zz-v703-rev-idem-001');
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);

  insert into public.campaign_send_records_v255
    (business_id, campaign_kind, campaign_ref_id, send_kind, campaign_label, channel, client_id,
     occurred_at, retention_until)
  values
    (biz, 'promotion', camp_a, 'new', 'ZZ v703 campaign A', 'none', c_camp1,
     ((w_from + 1)::timestamp + time '08:00') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '08:00') at time zone 'Asia/Singapore' + interval '400 days'),
    (biz, 'promotion', camp_b, 'new', 'ZZ v703 campaign B', 'none', c_camp1,
     ((w_from + 6)::timestamp + time '08:00') at time zone 'Asia/Singapore', ((w_from + 6)::timestamp + time '08:00') at time zone 'Asia/Singapore' + interval '400 days'),
    (biz, 'promotion', camp_a, 'new', 'ZZ v703 campaign A', 'none', c_camp2,
     ((w_from + 1)::timestamp + time '08:05') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '08:05') at time zone 'Asia/Singapore' + interval '400 days'),
    (biz, 'promotion', camp_b, 'new', 'ZZ v703 campaign B', 'none', c_camp2,
     ((w_from + 6)::timestamp + time '08:05') at time zone 'Asia/Singapore', ((w_from + 6)::timestamp + time '08:05') at time zone 'Asia/Singapore' + interval '400 days'),
    (biz, 'promotion', camp_a, 'new', 'ZZ v703 campaign A', 'none', c_camp_only,
     ((w_from + 1)::timestamp + time '08:10') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '08:10') at time zone 'Asia/Singapore' + interval '400 days');

  ---------------------------------------------------------------------------
  -- pin ONE as_of for every reader call below
  ---------------------------------------------------------------------------
  p_as_of := clock_timestamp();
  v_today := (p_as_of at time zone 'Asia/Singapore')::date;
  v_eng_from := date_trunc('month', p_as_of at time zone 'Asia/Singapore')::date
                - make_interval(months => 12);

  r_excl := app.ci_exclusion_counts_v680(biz, null, w_from, w_to, p_as_of);
  if (r_excl->>'reversed_sales')::int is distinct from 2 then
    insert into _fail values ('MAIN-reversed', 'expected 2, got ' || coalesce(r_excl->>'reversed_sales','null'));
  end if;
  if (r_excl->>'synthetic_clients')::int is distinct from 1 then
    insert into _fail values ('MAIN-synthetic', 'expected 1, got ' || coalesce(r_excl->>'synthetic_clients','null'));
  end if;
  if (r_excl->>'anonymous_sales')::int is distinct from 2 then
    insert into _fail values ('MAIN-anonymous', 'expected 2, got ' || coalesce(r_excl->>'anonymous_sales','null'));
  end if;
  if (r_excl->>'missing_demographics')::int is distinct from 2 then
    insert into _fail values ('MAIN-missing-demo', 'expected 2, got ' || coalesce(r_excl->>'missing_demographics','null'));
  end if;
  if (r_excl->>'overlapping_campaigns')::int is distinct from 2 then
    insert into _fail values ('MAIN-overlap', 'expected 2, got ' || coalesce(r_excl->>'overlapping_campaigns','null'));
  end if;

  -- independently recompute the WIDER windows the two non-explicit-period readers use, and
  -- prove they land on the same five numbers before trusting the readers' own envelopes.
  r_excl_contactability := app.ci_exclusion_counts_v680(biz, null, '-infinity'::date, v_today, p_as_of);
  if r_excl_contactability is distinct from r_excl then
    insert into _fail values ('PRE-contactability-window',
      'full-history exclusions differ from the main window -- fixture contaminated: ' || r_excl_contactability::text);
  end if;
  r_excl_engagement := app.ci_exclusion_counts_v680(biz, null, v_eng_from, v_today, p_as_of);
  if r_excl_engagement is distinct from r_excl then
    insert into _fail values ('PRE-engagement-window',
      'trailing-12-month exclusions differ from the main window -- fixture contaminated: ' || r_excl_engagement::text);
  end if;

  ---------------------------------------------------------------------------
  -- ASSERT: all five envelopes carry the SAME exclusions, period, as_of, trace_id shape
  ---------------------------------------------------------------------------
  r_contact := public.get_ci_contactability_v1(biz, null, p_as_of);
  r_engage  := public.get_ci_engagement_v1(biz, 12, null, p_as_of);
  r_funnel  := public.get_ci_funnel_v1(biz, w_from, w_to, null, p_as_of);
  r_market  := public.get_ci_marketing_funnel_v1(biz, w_from, w_to, null, p_as_of);
  r_retention := public.get_ci_retention_windows_v1(biz, w_from, w_to, null, p_as_of);

  if not (r_contact ? 'generated_at' and r_contact ? 'as_of' and r_contact ? 'period'
          and r_contact ? 'exclusions' and r_contact ? 'trace_id') then
    insert into _fail values ('SHAPE-contactability', 'missing envelope key(s): ' || r_contact::text);
  end if;
  if not (r_engage ? 'generated_at' and r_engage ? 'as_of' and r_engage ? 'period'
          and r_engage ? 'exclusions' and r_engage ? 'trace_id') then
    insert into _fail values ('SHAPE-engagement', 'missing envelope key(s): ' || r_engage::text);
  end if;
  if not (r_funnel ? 'generated_at' and r_funnel ? 'as_of' and r_funnel ? 'period'
          and r_funnel ? 'exclusions' and r_funnel ? 'trace_id') then
    insert into _fail values ('SHAPE-funnel', 'missing envelope key(s): ' || r_funnel::text);
  end if;
  if not (r_market ? 'generated_at' and r_market ? 'as_of' and r_market ? 'period'
          and r_market ? 'exclusions' and r_market ? 'trace_id') then
    insert into _fail values ('SHAPE-marketing-funnel', 'missing envelope key(s): ' || r_market::text);
  end if;
  if not (r_retention ? 'generated_at' and r_retention ? 'as_of' and r_retention ? 'period'
          and r_retention ? 'exclusions' and r_retention ? 'trace_id') then
    insert into _fail values ('SHAPE-retention', 'missing envelope key(s): ' || r_retention::text);
  end if;

  if r_contact->'exclusions' is distinct from r_excl then
    insert into _fail values ('EXCL-contactability', (r_contact->'exclusions')::text);
  end if;
  if r_engage->'exclusions' is distinct from r_excl then
    insert into _fail values ('EXCL-engagement', (r_engage->'exclusions')::text);
  end if;
  if r_funnel->'exclusions' is distinct from r_excl then
    insert into _fail values ('EXCL-funnel', (r_funnel->'exclusions')::text);
  end if;
  if r_market->'exclusions' is distinct from r_excl then
    insert into _fail values ('EXCL-marketing-funnel', (r_market->'exclusions')::text);
  end if;
  if r_retention->'exclusions' is distinct from r_excl then
    insert into _fail values ('EXCL-retention', (r_retention->'exclusions')::text);
  end if;

  -- period/as_of shape, spot-checked on one explicit-window reader and one whole-history reader
  if r_funnel->'period'->>'interval' is distinct from '[from,to]' then
    insert into _fail values ('PERIOD-interval', coalesce(r_funnel->'period'->>'interval','null'));
  end if;
  if r_funnel->'period'->>'timezone' is distinct from 'Asia/Singapore' then
    insert into _fail values ('PERIOD-timezone', coalesce(r_funnel->'period'->>'timezone','null'));
  end if;
  if r_funnel->'as_of' is distinct from to_jsonb(p_as_of) then
    insert into _fail values ('ASOF-funnel', coalesce(r_funnel->>'as_of','null'));
  end if;
  if r_contact->'period'->>'from' is distinct from '-infinity' then
    insert into _fail values ('PERIOD-contactability-from', coalesce(r_contact->'period'->>'from','null'));
  end if;

  -- twin-overload proof: every touched signature still resolves when called WITHOUT p_as_of,
  -- exactly the shape every existing caller in app/ and supabase/ uses (see the migration's
  -- own header for the grep). If a stray old-signature overload survived, one of these four
  -- calls would raise 42883 (no function matches) or PGRST203-equivalent ambiguity.
  begin
    perform public.get_ci_contactability_v1(biz, null);
    perform public.get_ci_engagement_v1(biz, 12, null);
    perform public.get_ci_funnel_v1(biz, w_from, w_to, null);
    perform public.get_ci_marketing_funnel_v1(biz, w_from, w_to, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('TWIN-OVERLOAD',
      format('a caller using the old positional shape (no p_as_of) failed with sqlstate %s -- '
             'either a twin overload survived or the default broke', v_err));
  end;

  ---------------------------------------------------------------------------
  -- PART B — retention floor gate (check 61)
  ---------------------------------------------------------------------------
  month1_anchor := date_trunc('month', current_date - interval '600 days')::date;
  month2_anchor := (month1_anchor + interval '1 month')::date;
  month3_anchor := (month1_anchor + interval '2 months')::date;

  fv1 := month1_anchor + 5;
  fv2 := month2_anchor + 5;
  fv3 := month3_anchor + 5;

  ret_from := month1_anchor;
  ret_to := (month3_anchor + interval '1 month' - interval '1 day')::date;

  -- cohort n=1: one client, first (and only) visit in month1, never returns
  insert into public.clients (id, business_id, full_name, birth_date, gender) values
    (c_ret1, biz, 'ZZ v703 ret n1', '1993-01-01', 'female');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, br, c_ret1, 'service', 500,
          (fv1::timestamp + time '09:00') at time zone 'Asia/Singapore',
          (fv1::timestamp + time '09:00') at time zone 'Asia/Singapore');

  -- cohort n=6: six clients, first visit in month2; three return 15 days later, three never do
  insert into public.clients (id, business_id, full_name, birth_date, gender) values
    (c_ret6_1, biz, 'ZZ v703 ret n6 1', '1990-02-01', 'female'),
    (c_ret6_2, biz, 'ZZ v703 ret n6 2', '1990-02-02', 'male'),
    (c_ret6_3, biz, 'ZZ v703 ret n6 3', '1990-02-03', 'other'),
    (c_ret6_4, biz, 'ZZ v703 ret n6 4', '1990-02-04', 'female'),
    (c_ret6_5, biz, 'ZZ v703 ret n6 5', '1990-02-05', 'male'),
    (c_ret6_6, biz, 'ZZ v703 ret n6 6', '1990-02-06', 'other');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, cl, 'service', 500,
         (fv2::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (fv2::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from unnest(array[c_ret6_1, c_ret6_2, c_ret6_3, c_ret6_4, c_ret6_5, c_ret6_6]) as cl;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, cl, 'service', 500,
         ((fv2 + 15)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((fv2 + 15)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from unnest(array[c_ret6_1, c_ret6_2, c_ret6_3]) as cl;

  -- cohort n=5: five clients, exactly at the default floor, first visit in month3, none return
  insert into public.clients (id, business_id, full_name, birth_date, gender) values
    (c_ret5_1, biz, 'ZZ v703 ret n5 1', '1990-03-01', 'female'),
    (c_ret5_2, biz, 'ZZ v703 ret n5 2', '1990-03-02', 'male'),
    (c_ret5_3, biz, 'ZZ v703 ret n5 3', '1990-03-03', 'other'),
    (c_ret5_4, biz, 'ZZ v703 ret n5 4', '1990-03-04', 'female'),
    (c_ret5_5, biz, 'ZZ v703 ret n5 5', '1990-03-05', 'male');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, cl, 'service', 500,
         (fv3::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (fv3::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from unnest(array[c_ret5_1, c_ret5_2, c_ret5_3, c_ret5_4, c_ret5_5]) as cl;

  -- precondition: month3's last day clears even the 365-day horizon, or the maturity gate (not
  -- the floor gate) would hide these windows and every assertion below would be vacuous.
  if ((month3_anchor + interval '1 month - 1 day')::date + 365) > current_date then
    insert into _fail values ('PRE-maturity',
      'month3 does not clear the 365-day horizon yet -- widen the 600-day anchor');
  end if;

  r_ret := public.get_ci_retention_windows_v1(biz, ret_from, ret_to, null, p_as_of);

  month1_key := to_char(month1_anchor, 'YYYY-MM');
  month2_key := to_char(month2_anchor, 'YYYY-MM');
  month3_key := to_char(month3_anchor, 'YYYY-MM');

  select c into cohort_1 from jsonb_array_elements(r_ret->'cohorts') c where c->>'month' = month1_key;
  select c into cohort_6 from jsonb_array_elements(r_ret->'cohorts') c where c->>'month' = month2_key;
  select c into cohort_5 from jsonb_array_elements(r_ret->'cohorts') c where c->>'month' = month3_key;

  if cohort_1 is null then
    insert into _fail values ('RET-n1-missing', 'no cohort found for ' || month1_key);
  else
    if (cohort_1->>'n')::int is distinct from 1 then
      insert into _fail values ('RET-n1-n', coalesce(cohort_1->>'n','null'));
    end if;
    foreach h in array array['30','60','90','180','365'] loop
      win := cohort_1->'windows'->h;
      if win is null then
        insert into _fail values ('RET-n1-missing-horizon-' || h, 'expected horizon ' || h || ' to be mature and present');
      else
        if (win->>'numerator')::int is distinct from 0 then
          insert into _fail values ('RET-n1-num-' || h, coalesce(win->>'numerator','null'));
        end if;
        if (win->>'denominator')::int is distinct from 1 then
          insert into _fail values ('RET-n1-den-' || h, coalesce(win->>'denominator','null'));
        end if;
        if win->>'pct' is not null then
          insert into _fail values ('RET-n1-pct-' || h,
            'expected pct NULL below the evidence floor, got ' || (win->>'pct'));
        end if;
      end if;
    end loop;
  end if;

  if cohort_6 is null then
    insert into _fail values ('RET-n6-missing', 'no cohort found for ' || month2_key);
  else
    if (cohort_6->>'n')::int is distinct from 6 then
      insert into _fail values ('RET-n6-n', coalesce(cohort_6->>'n','null'));
    end if;
    foreach h in array array['30','60','90','180','365'] loop
      win := cohort_6->'windows'->h;
      if win is null then
        insert into _fail values ('RET-n6-missing-horizon-' || h, 'expected horizon ' || h || ' to be mature and present');
      else
        if (win->>'numerator')::int is distinct from 3 then
          insert into _fail values ('RET-n6-num-' || h, coalesce(win->>'numerator','null'));
        end if;
        if (win->>'denominator')::int is distinct from 6 then
          insert into _fail values ('RET-n6-den-' || h, coalesce(win->>'denominator','null'));
        end if;
        if (win->>'pct')::numeric is distinct from 50.0 then
          insert into _fail values ('RET-n6-pct-' || h, coalesce(win->>'pct','null'));
        end if;
      end if;
    end loop;
  end if;

  if cohort_5 is null then
    insert into _fail values ('RET-n5-missing', 'no cohort found for ' || month3_key);
  else
    if (cohort_5->>'n')::int is distinct from 5 then
      insert into _fail values ('RET-n5-n', coalesce(cohort_5->>'n','null'));
    end if;
    foreach h in array array['30','60','90','180','365'] loop
      win := cohort_5->'windows'->h;
      if win is null then
        insert into _fail values ('RET-n5-missing-horizon-' || h, 'expected horizon ' || h || ' to be mature and present');
      else
        if (win->>'numerator')::int is distinct from 0 then
          insert into _fail values ('RET-n5-num-' || h, coalesce(win->>'numerator','null'));
        end if;
        if (win->>'denominator')::int is distinct from 5 then
          insert into _fail values ('RET-n5-den-' || h, coalesce(win->>'denominator','null'));
        end if;
        -- THE MUTATION-SENSITIVE ASSERTION: n=5 sits exactly at the floor. status must be 'ok',
        -- so pct must be present (0.0), never null. Flip the gate to `n > floor` and this goes red.
        if win->>'pct' is null then
          insert into _fail values ('RET-n5-pct-' || h,
            'expected pct=0.0 at exactly the evidence floor (n=5, floor=5), got null -- '
            'the floor gate is off by one (using > instead of >=)');
        elsif (win->>'pct')::numeric is distinct from 0.0 then
          insert into _fail values ('RET-n5-pct-value-' || h, coalesce(win->>'pct','null'));
        end if;
      end if;
    end loop;
  end if;

end
$v703$;

select case when count(*) = 0
            then 'PASS — v703 envelope everywhere + retention-windows floor gate'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v703: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
