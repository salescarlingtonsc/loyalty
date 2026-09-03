-- EXECUTED acceptance fixture for nestly_v693 — exclusion completeness (missing_demographics,
-- overlapping_campaigns) and typed evidence-class verdicts.
--
-- Named for v693 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md). Proves
-- db/migrations/20260920_nestly_v693_exclusions_and_typed_verdicts.sql.
--
-- AUTH CONTEXT. Same reasoning as db/tests/executed/v673_corpus_funnels.sql: a super-admin
-- session clears app.ci_access_gate_v667's platform arm outright, so this fixture does not need
-- a fully operational merchant workspace (staff/subscription/approval rows) — it is not testing
-- entitlement, v667's own corpus already does that.
--
-- TRUTH TABLE (computed before running anything):
--   MAIN window [w_from, w_to]:
--     3 identified clients with full demographics (age_band + gender resolve) -- NOT counted.
--     2 identified clients with birth_date but no gender -- BOTH counted as missing_demographics.
--     1 synthetic client's sale -- counted as synthetic_clients=1, NOT missing_demographics
--       (synthetic clients are never "identified" for this purpose).
--     2 anonymous sales (client_id null) -- counted as anonymous_sales=2.
--     1 reversed pair (original + reversal row) -- counted as reversed_sales=2; the reversed
--       original is excluded from the missing_demographics qualifying population entirely.
--     2 customers (c_camp1, c_camp2) each sent campaign A and campaign B 5 days apart (<=14) --
--       BOTH counted as overlapping_campaigns=2. A third customer (c_camp_only) receives only
--       campaign A -- not counted (needs >=2 distinct campaigns to overlap).
--   Expected exclusions on EVERY envelope over the main window:
--     {reversed_sales:2, synthetic_clients:1, anonymous_sales:2, missing_demographics:2,
--      overlapping_campaigns:2}
--   Asserted identically on three DIFFERENT readers' envelopes: get_ci_funnel_conversion_v1 and
--   get_ci_retention_windows_v1 (both re-emitted by this migration) AND get_ci_demographics_v1
--   (NOT touched by this migration at all) — proving the two new keys reach every reader purely
--   through the shared app.ci_exclusion_counts_v680 / app.ci_envelope_v680 upgrade.
--
--   MUTATION CHECK (overlapping_campaigns): campaign_send_records_v255 is append-only (no
--   UPDATE/DELETE outside a retention purge), so "changing the 14-day span" cannot mean editing
--   an existing row. Instead, a fresh customer (c_camp_far) receives two distinct campaigns 19
--   days apart (>14) inside an isolated window that contains neither of the other campaign
--   scenarios -- expected overlapping_campaigns=0 for that window, demonstrating the span
--   boundary in the one direction an immutable table allows: a materially different gap over
--   otherwise-identical shapes.
--
--   FUNNEL TYPED VERDICT: a dedicated 5-client population (all mature, all converting exactly
--   once from first to second visit within 60 days, none converting to a third visit) gives
--   stage_1_to_2.pct=100, stage_2_to_3.pct=0 -> bottleneck='second_to_third',
--   bottleneck_evidence_class='DIRECT_FACT' present. An empty window gives mature_first=0 ->
--   evidence.status='insufficient' -> bottleneck=null -> bottleneck_evidence_class ABSENT
--   entirely (not present as null).
--
--   RETENTION WINDOWS TYPED VERDICT: the main window's 5-client cohort produces >=1 cohort cell
--   in the 'cohorts' array; every cell carries evidence_class='DIRECT_FACT'.
--
--   DAYPART TYPED VERDICT: 5 sales on 5 distinct Mondays (same ISO weekday, different calendar
--   weeks) put busiest_weekday and most_valuable_weekday both on Monday (dow=1), the only weekday
--   clearing the evidence floor. busiest_weekday.evidence_class='DIRECT_FACT';
--   most_valuable_weekday.evidence_class='ASSOCIATION' with a non-empty explanatory note. A sixth
--   sale, alone at hour 14 (the only occurrence of that hour in the window), proves the 'hours'
--   bucket is now floor-gated the same way 'weekdays' always was: hour 10 (5 visits, evidence ok)
--   carries a non-null revenue_per_visit_cents; hour 14 (1 visit, evidence insufficient) carries
--   revenue_per_visit_cents=null while visits/revenue_cents stay visible.
--
--   DEMOGRAPHIC COHORT TYPED VERDICT: a cohort query against a taxonomy node with zero matching
--   purchases (denominator=0, confidence.status='insufficient') still carries
--   difference_evidence_class='ASSOCIATION' and a non-empty difference_evidence_note --
--   proving the class is emitted UNCONDITIONALLY, not only when 'difference' resolves.
--
--   VOCABULARY: no payload from any of the four typed-verdict readers contains the string
--   'CAUSAL', anywhere.

\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

do $v693$
declare
  biz uuid := '00000000-0000-4000-8000-000000693001';
  br  uuid := '00000000-0000-4000-8000-000000693002';
  u_sa uuid := '00000000-0000-4000-8000-000000693003';
  node1 text;
  v_err text;

  d0 date := current_date - 300;
  w_from date; w_to date;

  -- main window population
  c_full1 uuid := '00000000-0000-4000-8000-000000693101';
  c_full2 uuid := '00000000-0000-4000-8000-000000693102';
  c_full3 uuid := '00000000-0000-4000-8000-000000693103';
  c_nog1  uuid := '00000000-0000-4000-8000-000000693104';
  c_nog2  uuid := '00000000-0000-4000-8000-000000693105';
  c_synth uuid := '00000000-0000-4000-8000-000000693106';
  c_reversed uuid := '00000000-0000-4000-8000-000000693107';
  s_rev_orig uuid := '00000000-0000-4000-8000-000000693108';
  s_rev_rev  uuid := '00000000-0000-4000-8000-000000693109';

  camp_a uuid := '00000000-0000-4000-8000-000000693110';
  camp_b uuid := '00000000-0000-4000-8000-000000693111';
  c_camp1 uuid := '00000000-0000-4000-8000-000000693112';
  c_camp2 uuid := '00000000-0000-4000-8000-000000693113';
  c_camp_only uuid := '00000000-0000-4000-8000-000000693114';

  -- mutation-check (isolated window, isolated customer)
  wf2_from date; wf2_to date;
  c_camp_far uuid := '00000000-0000-4000-8000-000000693115';
  camp_c uuid := '00000000-0000-4000-8000-000000693116';
  camp_d uuid := '00000000-0000-4000-8000-000000693117';

  -- funnel typed-verdict, named-bottleneck scenario
  w_fun_from date; w_fun_to date;
  c_fun1 uuid := '00000000-0000-4000-8000-000000693201';
  c_fun2 uuid := '00000000-0000-4000-8000-000000693202';
  c_fun3 uuid := '00000000-0000-4000-8000-000000693203';
  c_fun4 uuid := '00000000-0000-4000-8000-000000693204';
  c_fun5 uuid := '00000000-0000-4000-8000-000000693205';

  -- funnel typed-verdict, null-bottleneck (empty) scenario
  w_empty_from date; w_empty_to date;

  -- daypart typed-verdict
  c_daypart uuid := '00000000-0000-4000-8000-000000693301';
  v_monday0 date;
  w_dp_from date; w_dp_to date;

  r_excl jsonb;
  r_funnel_main jsonb;
  r_retention_main jsonb;
  r_demog_main jsonb;
  r_fun_named jsonb;
  r_fun_null jsonb;
  r_retention jsonb;
  r_daypart jsonb;
  r_cohort jsonb;
  r_mutation jsonb;
  cell jsonb;
begin
  ---------------------------------------------------------------------------
  -- platform (super admin) session — see CI-CORPUS-FIXTURE-GUIDE.md
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values (u_sa, 'zz-v693-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v693-sa@example.test')
    on conflict do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v693 exclusions fixture', 'zz-v693-exclusions',
     array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v693 branch', true, true);

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

  select n.node_key into node1 from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 order by n.node_key limit 1;
  if node1 is null then
    insert into _fail values ('PRE-taxonomy', 'no level-2 taxonomy node at version 1');
    return;
  end if;

  ---------------------------------------------------------------------------
  -- MAIN WINDOW fixture
  ---------------------------------------------------------------------------
  w_from := d0; w_to := d0 + 10;

  insert into public.clients (id, business_id, full_name, birth_date, gender) values
    (c_full1, biz, 'ZZ v693 full demo A', '1990-01-01', 'female'),
    (c_full2, biz, 'ZZ v693 full demo B', '1988-06-15', 'male'),
    (c_full3, biz, 'ZZ v693 full demo C', '1995-03-20', 'other'),
    (c_nog1,  biz, 'ZZ v693 no gender A', '1985-01-01', null),
    (c_nog2,  biz, 'ZZ v693 no gender B', '1982-09-09', null),
    (c_reversed, biz, 'ZZ v693 reversed', '1991-01-01', 'female');
  insert into public.clients (id, business_id, full_name, is_synthetic)
  values (c_synth, biz, 'ZZ v693 synthetic', true);
  insert into public.clients (id, business_id, full_name) values
    (c_camp1, biz, 'ZZ v693 camp overlap A'),
    (c_camp2, biz, 'ZZ v693 camp overlap B'),
    (c_camp_only, biz, 'ZZ v693 camp single');

  -- 5 identified qualifying sales: c_full1/2/3 (resolve fully) + c_nog1/2 (age only)
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

  -- 1 synthetic client's sale
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, br, c_synth, 'service', 500,
          ((w_from + 1)::timestamp + time '10:00') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '10:00') at time zone 'Asia/Singapore');

  -- 2 anonymous sales (client_id null)
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (gen_random_uuid(), biz, br, null, 'retail', 200,
     ((w_from + 1)::timestamp + time '11:00') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '11:00') at time zone 'Asia/Singapore'),
    (gen_random_uuid(), biz, br, null, 'retail', 200,
     ((w_from + 1)::timestamp + time '11:10') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '11:10') at time zone 'Asia/Singapore');

  -- 1 reversed pair (2 rows)
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
          s_rev_orig, 'ZZ v693 fixture reversal', u_sa, 'zz-v693-rev-idem-001');
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);

  -- overlapping campaigns: c_camp1 and c_camp2 each get campaign A then campaign B, 5 days apart
  insert into public.campaign_send_records_v255
    (business_id, campaign_kind, campaign_ref_id, send_kind, campaign_label, channel, client_id,
     occurred_at, retention_until)
  values
    (biz, 'promotion', camp_a, 'new', 'ZZ v693 campaign A', 'none', c_camp1,
     ((w_from + 1)::timestamp + time '08:00') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '08:00') at time zone 'Asia/Singapore' + interval '400 days'),
    (biz, 'promotion', camp_b, 'new', 'ZZ v693 campaign B', 'none', c_camp1,
     ((w_from + 6)::timestamp + time '08:00') at time zone 'Asia/Singapore', ((w_from + 6)::timestamp + time '08:00') at time zone 'Asia/Singapore' + interval '400 days'),
    (biz, 'promotion', camp_a, 'new', 'ZZ v693 campaign A', 'none', c_camp2,
     ((w_from + 1)::timestamp + time '08:05') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '08:05') at time zone 'Asia/Singapore' + interval '400 days'),
    (biz, 'promotion', camp_b, 'new', 'ZZ v693 campaign B', 'none', c_camp2,
     ((w_from + 6)::timestamp + time '08:05') at time zone 'Asia/Singapore', ((w_from + 6)::timestamp + time '08:05') at time zone 'Asia/Singapore' + interval '400 days'),
    (biz, 'promotion', camp_a, 'new', 'ZZ v693 campaign A', 'none', c_camp_only,
     ((w_from + 1)::timestamp + time '08:10') at time zone 'Asia/Singapore', ((w_from + 1)::timestamp + time '08:10') at time zone 'Asia/Singapore' + interval '400 days');

  ---------------------------------------------------------------------------
  -- ASSERT: raw exclusion counts, exact
  ---------------------------------------------------------------------------
  r_excl := app.ci_exclusion_counts_v680(biz, null, w_from, w_to, clock_timestamp());

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

  ---------------------------------------------------------------------------
  -- ASSERT: inheritance — three DIFFERENT readers' envelopes carry the exact same 5 keys.
  -- get_ci_demographics_v1 is NOT touched by the v693 migration at all.
  ---------------------------------------------------------------------------
  r_funnel_main := public.get_ci_funnel_conversion_v1(biz, w_from, w_to);
  r_retention_main := public.get_ci_retention_windows_v1(biz, w_from, w_to);
  r_demog_main := public.get_ci_demographics_v1(biz, w_from, w_to);

  if r_funnel_main->'exclusions' is distinct from r_excl then
    insert into _fail values ('INHERIT-funnel', (r_funnel_main->'exclusions')::text);
  end if;
  if r_retention_main->'exclusions' is distinct from r_excl then
    insert into _fail values ('INHERIT-retention', (r_retention_main->'exclusions')::text);
  end if;
  if r_demog_main->'exclusions' is distinct from r_excl then
    insert into _fail values ('INHERIT-demographics', (r_demog_main->'exclusions')::text);
  end if;

  ---------------------------------------------------------------------------
  -- MUTATION CHECK: a >14-day gap (isolated window/customer) -> overlapping_campaigns = 0
  ---------------------------------------------------------------------------
  wf2_from := w_from + 200; wf2_to := wf2_from + 25;
  insert into public.clients (id, business_id, full_name) values (c_camp_far, biz, 'ZZ v693 camp far');
  insert into public.campaign_send_records_v255
    (business_id, campaign_kind, campaign_ref_id, send_kind, campaign_label, channel, client_id,
     occurred_at, retention_until)
  values
    (biz, 'promotion', camp_c, 'new', 'ZZ v693 campaign C', 'none', c_camp_far,
     ((wf2_from + 1)::timestamp + time '08:00') at time zone 'Asia/Singapore', ((wf2_from + 1)::timestamp + time '08:00') at time zone 'Asia/Singapore' + interval '400 days'),
    (biz, 'promotion', camp_d, 'new', 'ZZ v693 campaign D', 'none', c_camp_far,
     ((wf2_from + 20)::timestamp + time '08:00') at time zone 'Asia/Singapore', ((wf2_from + 20)::timestamp + time '08:00') at time zone 'Asia/Singapore' + interval '400 days');

  r_mutation := app.ci_exclusion_counts_v680(biz, null, wf2_from, wf2_to, clock_timestamp());
  if (r_mutation->>'overlapping_campaigns')::int is distinct from 0 then
    insert into _fail values ('MUTATION-overlap',
      'expected 0 once the gap exceeds 14 days, got ' || coalesce(r_mutation->>'overlapping_campaigns','null'));
  end if;

  ---------------------------------------------------------------------------
  -- FUNNEL TYPED VERDICT — named bottleneck (DIRECT_FACT)
  ---------------------------------------------------------------------------
  w_fun_from := d0 - 200; w_fun_to := d0 - 198;

  insert into public.clients (id, business_id, full_name) values
    (c_fun1, biz, 'ZZ v693 funnel A'), (c_fun2, biz, 'ZZ v693 funnel B'),
    (c_fun3, biz, 'ZZ v693 funnel C'), (c_fun4, biz, 'ZZ v693 funnel D'),
    (c_fun5, biz, 'ZZ v693 funnel E');

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, cl, 'service', 300,
         ((w_fun_from + 1)::timestamp + time '09:00') at time zone 'Asia/Singapore', ((w_fun_from + 1)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from unnest(array[c_fun1, c_fun2, c_fun3, c_fun4, c_fun5]) as cl;

  -- second visit 10 days later for all five (100% stage_1_to_2), none convert a third time
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, cl, 'service', 300,
         ((w_fun_from + 11)::timestamp + time '09:00') at time zone 'Asia/Singapore', ((w_fun_from + 11)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from unnest(array[c_fun1, c_fun2, c_fun3, c_fun4, c_fun5]) as cl;

  r_fun_named := public.get_ci_funnel_conversion_v1(biz, w_fun_from, w_fun_to);
  if (r_fun_named->'stage_1_to_2'->>'pct')::numeric is distinct from 100.0 then
    insert into _fail values ('FUN-pct1', coalesce(r_fun_named->'stage_1_to_2'->>'pct','null'));
  end if;
  if (r_fun_named->'stage_2_to_3'->>'pct')::numeric is distinct from 0.0 then
    insert into _fail values ('FUN-pct2', coalesce(r_fun_named->'stage_2_to_3'->>'pct','null'));
  end if;
  if r_fun_named->>'bottleneck' is distinct from 'second_to_third' then
    insert into _fail values ('FUN-bottleneck', coalesce(r_fun_named->>'bottleneck','null'));
  end if;
  if r_fun_named->>'bottleneck_evidence_class' is distinct from 'DIRECT_FACT' then
    insert into _fail values ('FUN-class-named', coalesce(r_fun_named->>'bottleneck_evidence_class','null'));
  end if;

  ---------------------------------------------------------------------------
  -- FUNNEL TYPED VERDICT — null bottleneck: key absent entirely
  ---------------------------------------------------------------------------
  w_empty_from := d0 - 400; w_empty_to := d0 - 399;
  r_fun_null := public.get_ci_funnel_conversion_v1(biz, w_empty_from, w_empty_to);
  if r_fun_null->>'bottleneck' is not null then
    insert into _fail values ('FUN-null-pre', 'expected null bottleneck over an empty window, got '
      || coalesce(r_fun_null->>'bottleneck','null'));
  end if;
  if r_fun_null ? 'bottleneck_evidence_class' then
    insert into _fail values ('FUN-class-null',
      'bottleneck_evidence_class must be ABSENT (not null) when no bottleneck is named: '
      || (r_fun_null->'bottleneck_evidence_class')::text);
  end if;

  ---------------------------------------------------------------------------
  -- RETENTION WINDOWS TYPED VERDICT — every cohort cell carries evidence_class:'DIRECT_FACT'
  ---------------------------------------------------------------------------
  r_retention := public.get_ci_retention_windows_v1(biz, w_from, w_to);
  if jsonb_array_length(r_retention->'cohorts') is distinct from 1
     or jsonb_array_length(r_retention->'cohorts') is null then
    -- not a hard requirement of shape, just record what we saw for context if it's ever 0
    if coalesce(jsonb_array_length(r_retention->'cohorts'), 0) = 0 then
      insert into _fail values ('RET-empty', 'expected at least one cohort cell, got none');
    end if;
  end if;
  for cell in select * from jsonb_array_elements(r_retention->'cohorts') loop
    if cell->>'evidence_class' is distinct from 'DIRECT_FACT' then
      insert into _fail values ('RET-class', coalesce(cell->>'evidence_class','null') || ' in ' || cell::text);
    end if;
  end loop;

  ---------------------------------------------------------------------------
  -- DAYPART TYPED VERDICT — busiest_weekday DIRECT_FACT, most_valuable_weekday ASSOCIATION+note
  ---------------------------------------------------------------------------
  v_monday0 := date_trunc('week', current_date)::date;
  w_dp_from := v_monday0 - 35; w_dp_to := v_monday0;

  insert into public.clients (id, business_id, full_name) values (c_daypart, biz, 'ZZ v693 daypart');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, c_daypart, 'service', 1000,
         ((mon)::timestamp + time '10:00') at time zone 'Asia/Singapore', ((mon)::timestamp + time '10:00') at time zone 'Asia/Singapore'
    from unnest(array[v_monday0, v_monday0 - 7, v_monday0 - 14, v_monday0 - 21, v_monday0 - 28]) as mon;

  -- one single sale at hour 14 -- the ONLY occurrence of that hour anywhere in the window --
  -- to prove the 'hours' bucket is floor-gated exactly like 'weekdays' already is (an
  -- independent refuter found hours computing revenue_per_visit_cents off `visits > 0` alone,
  -- with no app.subgroup_evidence_v1 gate at all).
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, br, c_daypart, 'service', 4000,
          (v_monday0::timestamp + time '14:00') at time zone 'Asia/Singapore',
          (v_monday0::timestamp + time '14:00') at time zone 'Asia/Singapore');

  r_daypart := public.get_ci_daypart_v1(biz, w_dp_from, w_dp_to);
  if (r_daypart->'busiest_weekday'->>'dow')::int is distinct from 1 then
    insert into _fail values ('DP-busiest-dow', coalesce(r_daypart->'busiest_weekday'->>'dow','null'));
  end if;
  if r_daypart->'busiest_weekday'->>'evidence_class' is distinct from 'DIRECT_FACT' then
    insert into _fail values ('DP-busiest-class', coalesce(r_daypart->'busiest_weekday'->>'evidence_class','null'));
  end if;
  if r_daypart->'most_valuable_weekday' is null then
    insert into _fail values ('DP-mv-null', 'expected a most_valuable_weekday, got null');
  else
    if r_daypart->'most_valuable_weekday'->>'evidence_class' is distinct from 'ASSOCIATION' then
      insert into _fail values ('DP-mv-class', coalesce(r_daypart->'most_valuable_weekday'->>'evidence_class','null'));
    end if;
    if coalesce(length(r_daypart->'most_valuable_weekday'->>'note'), 0) = 0 then
      insert into _fail values ('DP-mv-note', 'expected a non-empty note explaining the comparison');
    end if;
  end if;

  -- hours floor gate: hour 10 has 5 visits (evidence ok) -> rate present; hour 14 has 1 visit
  -- (evidence insufficient) -> rate null, counts still present.
  declare
    h10 jsonb; h14 jsonb;
  begin
    select h into h10 from jsonb_array_elements(r_daypart->'hours') h where (h->>'hour')::int = 10;
    select h into h14 from jsonb_array_elements(r_daypart->'hours') h where (h->>'hour')::int = 14;

    if h10 is null then
      insert into _fail values ('DP-hour10-missing', 'no hour-10 bucket in hours array');
    else
      if (h10->>'visits')::int is distinct from 5 then
        insert into _fail values ('DP-hour10-visits', coalesce(h10->>'visits','null'));
      end if;
      if h10->'evidence'->>'status' is distinct from 'ok' then
        insert into _fail values ('DP-hour10-evidence', coalesce(h10->'evidence'->>'status','null'));
      end if;
      if h10->>'revenue_per_visit_cents' is null then
        insert into _fail values ('DP-hour10-rate-null', 'expected a non-null rate at the evidence floor');
      end if;
    end if;

    if h14 is null then
      insert into _fail values ('DP-hour14-missing', 'no hour-14 bucket in hours array');
    else
      if (h14->>'visits')::int is distinct from 1 then
        insert into _fail values ('DP-hour14-visits', coalesce(h14->>'visits','null'));
      end if;
      if h14->'evidence'->>'status' is distinct from 'insufficient' then
        insert into _fail values ('DP-hour14-evidence', coalesce(h14->'evidence'->>'status','null'));
      end if;
      if h14->>'revenue_per_visit_cents' is not null then
        insert into _fail values ('DP-hour14-rate-not-null',
          'a single-visit hour leaked a rate: ' || (h14->>'revenue_per_visit_cents'));
      end if;
      if (h14->>'revenue_cents')::int is distinct from 4000 then
        insert into _fail values ('DP-hour14-revenue', coalesce(h14->>'revenue_cents','null'));
      end if;
    end if;
  end;

  ---------------------------------------------------------------------------
  -- DEMOGRAPHIC COHORT TYPED VERDICT — unconditional difference_evidence_class + note
  ---------------------------------------------------------------------------
  r_cohort := public.get_ci_demographic_cohort_v1(biz, 'female', 0, 99, node1, w_from, w_to);
  if (r_cohort->'confidence'->>'status') is distinct from 'insufficient' then
    insert into _fail values ('COH-pre',
      'expected an insufficient-evidence cohort (no qualifying purchases seeded), got '
      || coalesce(r_cohort->'confidence'->>'status','null'));
  end if;
  if r_cohort->>'difference_evidence_class' is distinct from 'ASSOCIATION' then
    insert into _fail values ('COH-class', coalesce(r_cohort->>'difference_evidence_class','null'));
  end if;
  if coalesce(length(r_cohort->>'difference_evidence_note'), 0) = 0 then
    insert into _fail values ('COH-note', 'expected a non-empty difference_evidence_note');
  end if;

  ---------------------------------------------------------------------------
  -- VOCABULARY — the classification token 'CAUSAL' never appears in any of the four
  -- typed-verdict readers. Case-SENSITIVE on purpose: the frozen vocabulary
  -- (docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md, this migration's header) restricts the
  -- 'evidence_class'/'difference_evidence_class' ENUM VALUE to DIRECT_FACT | ASSOCIATION and
  -- bans the value 'CAUSAL' -- it does not ban the lowercase English word "causal" appearing in
  -- an explanatory note that says a figure is deliberately NOT a causal estimate (see
  -- get_ci_demographic_cohort_v1's difference_evidence_note). A case-insensitive match would
  -- flag that note as a violation for using the word to correctly disclaim causality, which is
  -- the opposite of what this check is for.
  ---------------------------------------------------------------------------
  if r_fun_named::text like '%CAUSAL%' then
    insert into _fail values ('VOCAB-funnel-named', 'CAUSAL found in funnel (named) payload');
  end if;
  if r_fun_null::text like '%CAUSAL%' then
    insert into _fail values ('VOCAB-funnel-null', 'CAUSAL found in funnel (null) payload');
  end if;
  if r_retention::text like '%CAUSAL%' then
    insert into _fail values ('VOCAB-retention', 'CAUSAL found in retention-windows payload');
  end if;
  if r_daypart::text like '%CAUSAL%' then
    insert into _fail values ('VOCAB-daypart', 'CAUSAL found in daypart payload');
  end if;
  if r_cohort::text like '%CAUSAL%' then
    insert into _fail values ('VOCAB-cohort', 'CAUSAL found in demographic-cohort payload');
  end if;

end
$v693$;

select case when count(*) = 0
            then 'PASS — v693 exclusion completeness + typed evidence-class verdicts'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v693: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
