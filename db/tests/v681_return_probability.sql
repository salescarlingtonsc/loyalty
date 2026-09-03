-- EXECUTED acceptance fixture for nestly_v681 — the return-probability model and its measured,
-- temporally-held-out calibration/discrimination proof.
--
-- WHY. v681 (db/migrations/20260920_nestly_v681_return_probability.sql) closes checks 49
-- (a return-probability model) and 50 (abstains on sparse history) honestly: the model
-- (app.return_probability_v681) is a transparent memoryless-exponential hazard on the
-- customer's OWN median rhythm (m, k from app.customer_cadence_batch_v1 — the v651 canonical
-- cadence authority), and its accuracy claims are MEASURED by
-- public.evaluate_return_probability_v681 on real, temporally-held-out outcomes, never asserted.
-- Named above the v422 baseline watermark: n/a in the baseline phase, gated on the migrated run
-- (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- ============================================================================================
-- TRUTH TABLE (all offsets are days relative to v_train = midnight SGT, current_date; the
-- horizon is the default 30 days)
-- ============================================================================================
-- Group A — cl_a1..cl_a6: visits at [60,50,40,30,20,10] days before v_train (6 visits -> 5
--   gaps of 10 days each) -> k=5, m=10.0 -> P = 1 - exp(-30/10) = 1 - exp(-3) = 0.9502129...
--   -> probability_pct = 95.0 (round 1dp).
--   OUTCOME: cl_a1..cl_a5 get a real qualifying visit at v_train+15d (inside the 30-day
--   horizon) -> observed=1 (return). cl_a6 gets NO real return (a same-window sale is inserted
--   and then REVERSED — proving a reversed sale does not count as a return) -> observed=0.
--   5 of 6 return within 30 days, exactly as specified.
--
-- Group B — cl_b1..cl_b6: visits at [360,300,240,180,120,60] days before v_train (6 visits ->
--   5 gaps of 60 days each) -> k=5, m=60.0 -> P = 1 - exp(-30/60) = 1 - exp(-0.5) =
--   0.3934693... -> probability_pct = 39.3 (round 1dp).
--   OUTCOME: cl_b1 and cl_b2 get a real qualifying visit at v_train+20d -> observed=1.
--   cl_b3..cl_b6 get none -> observed=0. 2 of 6 return within 30 days, exactly as specified.
--   cl_b1's return sale doubles as the TEMPORAL-LEAK PROBE: its prediction is taken BEFORE that
--   sale exists and again AFTER, both at the same p_as_of = v_train, and must be byte-identical
--   (C-LEAK below) — a visit dated after the cutoff must change the OUTCOME, never the INPUT.
--
-- Group C — cl_c1..cl_c3: exactly ONE visit each, 5 days before v_train -> zero gaps -> k=0 <
--   the floor of 3 -> app.return_probability_v681 returns status='insufficient' -> ABSTAINED.
--   Counted in n_abstained, never scored, never contributes to calibration or discrimination.
--
-- cl_synth — is_synthetic=true, given the IDENTICAL rhythm and return as Group A (so it would
--   silently inflate n_scored to 13 and skew the 90-100 bin to n=7 if the exclusion broke) ->
--   must be invisible to evaluate_return_probability_v681 entirely.
--
-- EXPECTED AGGREGATES (hand-computed, asserted exactly or to the stated tolerance):
--   n_scored = 12 (6 Group A + 6 Group B; Group C excluded as abstained, cl_synth excluded)
--   n_abstained = 3 (Group C)
--   calibration.bins: one bin '90-100' with n=6, observed_rate = 100*5/6 = 83.3;
--                     one bin '30-40'  with n=6, observed_rate = 100*2/6 = 33.3.
--   Brier = mean((p-y)^2) over the 12 scored clients, computed by hand using the UNROUNDED
--     probabilities (p_A=0.950212931632136, p_B=0.393469340287367):
--       group A: 5*(p_A-1)^2 + 1*(p_A-0)^2
--              = 5*0.0024787532... + 1*0.9029046292...  = 0.0123937664 + 0.9029046292 = 0.9152983956
--       group B: 2*(p_B-1)^2 + 4*(p_B-0)^2
--              = 2*0.3677591142... + 4*0.1548182110...  = 0.7355182284 + 0.6192728440 = 1.3547910724
--       Brier  = (0.9152983956 + 1.3547910724) / 12 = 2.2700894680 / 12 = 0.189174... ~ 0.1892
--     (the migration prompt's own worked example, rounding p to 4dp first, gets 0.189194 — the
--     two agree to better than 0.001, which is the asserted tolerance below)
--   AUC (Mann-Whitney U / rank-sum, ties given the average-rank 0.5-credit convention):
--     12 values, 6 tied at p_B (ranks 1..6, avg rank 3.5) and 6 tied at p_A (ranks 7..12, avg
--     rank 9.5). Positives: 2 from group B (rank 3.5 each) + 5 from group A (rank 9.5 each) = 7
--     positives; negatives: 4 from group B + 1 from group A = 5 negatives.
--       sum_ranks_positives = 2*3.5 + 5*9.5 = 7 + 47.5 = 54.5
--       U   = 54.5 - 7*8/2 = 54.5 - 28 = 26.5
--       AUC = U / (n_pos * n_neg) = 26.5 / (7*5) = 26.5/35 = 0.7571428571...
-- ============================================================================================

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v681$
declare
  biz         uuid := '00000000-0000-4000-8000-000000681001';
  branch      uuid := '00000000-0000-4000-8000-000000681011';
  u_sa        uuid := '00000000-0000-4000-8000-000000681901';
  u_stranger  uuid := '00000000-0000-4000-8000-000000681902';

  cl_a1 uuid := '00000000-0000-4000-8000-000000681101';
  cl_a2 uuid := '00000000-0000-4000-8000-000000681102';
  cl_a3 uuid := '00000000-0000-4000-8000-000000681103';
  cl_a4 uuid := '00000000-0000-4000-8000-000000681104';
  cl_a5 uuid := '00000000-0000-4000-8000-000000681105';
  cl_a6 uuid := '00000000-0000-4000-8000-000000681106';
  cl_b1 uuid := '00000000-0000-4000-8000-000000681201';
  cl_b2 uuid := '00000000-0000-4000-8000-000000681202';
  cl_b3 uuid := '00000000-0000-4000-8000-000000681203';
  cl_b4 uuid := '00000000-0000-4000-8000-000000681204';
  cl_b5 uuid := '00000000-0000-4000-8000-000000681205';
  cl_b6 uuid := '00000000-0000-4000-8000-000000681206';
  cl_c1 uuid := '00000000-0000-4000-8000-000000681301';
  cl_c2 uuid := '00000000-0000-4000-8000-000000681302';
  cl_c3 uuid := '00000000-0000-4000-8000-000000681303';
  cl_synth uuid := '00000000-0000-4000-8000-000000681401';

  rev_orig_id uuid := '00000000-0000-4000-8000-000000681501';
  rev_row_id  uuid := '00000000-0000-4000-8000-000000681502';

  v_train timestamptz := (current_date)::timestamp at time zone 'Asia/Singapore';
  g       jsonb;
  g_before jsonb;
  g_after  jsonb;
  ev      jsonb;
  v_err   text;
  v_brier numeric;
  v_auc   numeric;
  v_bin90 jsonb;
  v_bin30 jsonb;
begin
  ---------------------------------------------------------------------------
  -- fixture business + branch (+ the v106 reporting-contract landmine workaround: a fresh
  -- branch's first contract is dated from "now", never '-infinity', so backdated visits would
  -- be silently dropped by app.customer_cadence_batch_v1's inner join unless an explicit early
  -- contract version is added — see db/qa/CI-CORPUS-FIXTURE-GUIDE.md and v651's own fixture).
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v681 return-probability fixture', 'zz-v681-retprob',
          array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (branch, biz, 'ZZ v681 branch', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, branch, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore',
         upper(b.currency), true
    from public.businesses b where b.id = biz;

  insert into auth.users (id, email) values
    (u_sa, 'zz-v681-sa@example.test'),
    (u_stranger, 'zz-v681-stranger@example.test')
  on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v681-sa@example.test')
    on conflict do nothing;

  ---------------------------------------------------------------------------
  -- customers
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name) values
    (cl_a1, biz, 'ZZ v681 A1 (10d rhythm, returns)'),
    (cl_a2, biz, 'ZZ v681 A2 (10d rhythm, returns)'),
    (cl_a3, biz, 'ZZ v681 A3 (10d rhythm, returns)'),
    (cl_a4, biz, 'ZZ v681 A4 (10d rhythm, returns)'),
    (cl_a5, biz, 'ZZ v681 A5 (10d rhythm, returns)'),
    (cl_a6, biz, 'ZZ v681 A6 (10d rhythm, does not return)'),
    (cl_b1, biz, 'ZZ v681 B1 (60d rhythm, returns, leak probe)'),
    (cl_b2, biz, 'ZZ v681 B2 (60d rhythm, returns)'),
    (cl_b3, biz, 'ZZ v681 B3 (60d rhythm, does not return)'),
    (cl_b4, biz, 'ZZ v681 B4 (60d rhythm, does not return)'),
    (cl_b5, biz, 'ZZ v681 B5 (60d rhythm, does not return)'),
    (cl_b6, biz, 'ZZ v681 B6 (60d rhythm, does not return)'),
    (cl_c1, biz, 'ZZ v681 C1 (single visit, abstain)'),
    (cl_c2, biz, 'ZZ v681 C2 (single visit, abstain)'),
    (cl_c3, biz, 'ZZ v681 C3 (single visit, abstain)');
  insert into public.clients (id, business_id, full_name, is_synthetic) values
    (cl_synth, biz, 'ZZ v681 synthetic (must be invisible to evaluate)', true);

  ---------------------------------------------------------------------------
  -- pre-train_until history (created_at pinned to occurred_at — the v651 fixture landmine:
  -- both app.customer_cadence_batch_v1's eligibility filter and the residual check gate on
  -- created_at <= p_as_of, and v_train is midnight SGT TODAY, earlier than "now" on every run)
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, c.id, 'service', 1000,
         v_train - make_interval(days => o), v_train - make_interval(days => o)
    from (values (cl_a1),(cl_a2),(cl_a3),(cl_a4),(cl_a5),(cl_a6)) as c(id)
    cross join unnest(array[60,50,40,30,20,10]) as o;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, c.id, 'service', 1000,
         v_train - make_interval(days => o), v_train - make_interval(days => o)
    from (values (cl_b1),(cl_b2),(cl_b3),(cl_b4),(cl_b5),(cl_b6)) as c(id)
    cross join unnest(array[360,300,240,180,120,60]) as o;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, c.id, 'service', 1000,
         v_train - make_interval(days => 5), v_train - make_interval(days => 5)
    from (values (cl_c1),(cl_c2),(cl_c3)) as c(id);

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl_synth, 'service', 1000,
         v_train - make_interval(days => o), v_train - make_interval(days => o)
    from unnest(array[60,50,40,30,20,10]) as o;

  ---------------------------------------------------------------------------
  -- MODEL — direct per-customer checks (no gate: app.return_probability_v681 is internal,
  -- service_role-only, exactly like app.customer_cadence_v1 — see the fixture guide's note that
  -- the harness's superuser role can call a SECURITY DEFINER function directly regardless of
  -- its grants).
  ---------------------------------------------------------------------------
  g := app.return_probability_v681(biz, cl_a1, v_train);
  if g->>'status' <> 'ready' then
    insert into _fail values ('M1-pre', format('cl_a1 status=%s, expected ready', g->>'status'));
  end if;
  if (g->>'k')::int <> 5 then
    insert into _fail values ('M1', format('cl_a1 k=%s, expected 5', g->>'k'));
  end if;
  if (g->>'median_interval_days')::numeric <> 10.0 then
    insert into _fail values ('M1', format('cl_a1 median_interval_days=%s, expected 10.0', g->>'median_interval_days'));
  end if;
  if (g->>'probability_pct')::numeric <> 95.0 then
    insert into _fail values ('M1',
      format('cl_a1 probability_pct=%s, expected 95.0 (1-exp(-3))', g->>'probability_pct'));
  end if;

  g := app.return_probability_v681(biz, cl_b1, v_train);
  if g->>'status' <> 'ready' then
    insert into _fail values ('M2-pre', format('cl_b1 status=%s, expected ready', g->>'status'));
  end if;
  if (g->>'k')::int <> 5 then
    insert into _fail values ('M2', format('cl_b1 k=%s, expected 5', g->>'k'));
  end if;
  if (g->>'median_interval_days')::numeric <> 60.0 then
    insert into _fail values ('M2', format('cl_b1 median_interval_days=%s, expected 60.0', g->>'median_interval_days'));
  end if;
  if (g->>'probability_pct')::numeric <> 39.3 then
    insert into _fail values ('M2',
      format('cl_b1 probability_pct=%s, expected 39.3 (1-exp(-0.5))', g->>'probability_pct'));
  end if;

  ---------------------------------------------------------------------------
  -- M3 — abstention on sparse history (check 50): k=0 for a single-visit customer must NEVER
  -- produce a probability.
  ---------------------------------------------------------------------------
  g := app.return_probability_v681(biz, cl_c1, v_train);
  if g->>'status' <> 'insufficient' then
    insert into _fail values ('M3', format('cl_c1 (1 visit, k=0) status=%s, expected insufficient', g->>'status'));
  end if;
  if g->'probability' is distinct from 'null'::jsonb then
    insert into _fail values ('M3',
      format('cl_c1 returned a numeric probability (%s) from zero measured intervals — a '
             'fabricated number, not a measured one', g->>'probability'));
  end if;
  if (g->>'k')::int <> 0 then
    insert into _fail values ('M3', format('cl_c1 k=%s, expected 0', g->>'k'));
  end if;

  ---------------------------------------------------------------------------
  -- TEMPORAL-LEAK PROBE. Take cl_b1's prediction BEFORE its own return sale exists, insert that
  -- sale (dated strictly after v_train, inside the horizon), then take the SAME prediction at
  -- the SAME p_as_of again. The two must be byte-identical: a visit recorded after the cutoff
  -- may change the OUTCOME an evaluation later measures, but must never change the INPUT a
  -- prediction anchored at that cutoff sees.
  ---------------------------------------------------------------------------
  g_before := app.return_probability_v681(biz, cl_b1, v_train);

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, branch, cl_b1, 'service', 1000,
          v_train + interval '20 days', v_train + interval '20 days');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, branch, cl_b2, 'service', 1000,
          v_train + interval '20 days', v_train + interval '20 days');

  g_after := app.return_probability_v681(biz, cl_b1, v_train);

  if g_before is distinct from g_after then
    insert into _fail values ('C-LEAK',
      format('cl_b1''s prediction at the SAME p_as_of changed after a later-dated sale was '
             'inserted — before=%s after=%s. The holdout is not real.', g_before, g_after));
  end if;
  if (g_after->>'k')::int <> 5 or (g_after->>'median_interval_days')::numeric <> 60.0 then
    insert into _fail values ('C-LEAK',
      'cl_b1''s post-insert prediction no longer matches the pre-insert k/m — the new sale leaked '
      'into the cadence computation despite being dated after p_train_until');
  end if;

  ---------------------------------------------------------------------------
  -- Group A outcomes: cl_a1..cl_a5 return within the horizon (v_train+15d).
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, c.id, 'service', 1000,
         v_train + interval '15 days', v_train + interval '15 days'
    from (values (cl_a1),(cl_a2),(cl_a3),(cl_a4),(cl_a5)) as c(id);

  -- cl_a6: a sale in the SAME window that is then REVERSED — proves a reversed sale is not a
  -- return. Same two-GUC write-guard token pair the fixture guide documents for reversal rows.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (rev_orig_id, biz, branch, cl_a6, 'service', 1000,
          v_train + interval '12 days', v_train + interval '12 days');
  perform set_config('app.sale_reversal_insert_id', rev_row_id::text, true);
  perform set_config('app.sale_reversal_original_id', rev_orig_id::text, true);
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at,
                            reversal_of, reversal_reason, reversal_actor, reversal_idempotency_key)
  values (rev_row_id, biz, branch, cl_a6, 'service', -1000,
          v_train + interval '12 days' + interval '1 second',
          v_train + interval '12 days' + interval '1 second',
          rev_orig_id, 'ZZ v681 fixture reversal — must not count as a return', u_sa,
          'zz-v681-rev-idem-001');
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);

  -- cl_synth: identical rhythm AND a real return in-window. If exclusion ever broke, this alone
  -- would flip n_scored to 13 and the 90-100 bin to n=7 / a different observed_rate.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, branch, cl_synth, 'service', 1000,
          v_train + interval '15 days', v_train + interval '15 days');

  ---------------------------------------------------------------------------
  -- entitlement preconditions, then the two calls.
  ---------------------------------------------------------------------------
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
             'evaluate_return_probability_v681 assertion below would be vacuous', v_err));
  end;

  ---------------------------------------------------------------------------
  -- ENTITLEMENT — an unentitled caller (no super_admin row, no staff row, no consultant
  -- assignment on this business) must be refused 42501, and the refusal must be earned: assert
  -- first that this session genuinely holds none of the gate's admitting predicates, or the
  -- refusal below proves nothing.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_stranger, 'role', 'authenticated')::text, true);
  if app.v176_can_read_firm_report(biz) then
    insert into _fail values ('E1-pre',
      'fixture stranger unexpectedly holds platform read access to this firm; E1 would be vacuous');
  end if;
  if app.is_salon_member(biz) then
    insert into _fail values ('E1-pre',
      'fixture stranger is unexpectedly a member of this firm; E1 would be vacuous');
  end if;
  begin
    ev := public.evaluate_return_probability_v681(biz, v_train, 30, null);
    insert into _fail values ('E1', 'an unentitled stranger reached evaluate_return_probability_v681');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('E1', format('refused with %s, expected 42501', v_err));
  end;

  ---------------------------------------------------------------------------
  -- THE MEASURED PROOF — entitled super admin.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  begin
    ev := public.evaluate_return_probability_v681(biz, v_train, 30, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('EV-pre', format('entitled super admin was refused (%s)', v_err));
    ev := null;
  end;

  if ev is null then
    insert into _fail values ('EV', 'evaluate_return_probability_v681 returned nothing');
  else
    if (ev->>'n_scored')::int <> 12 then
      insert into _fail values ('EV-n_scored', format('n_scored=%s, expected 12', ev->>'n_scored'));
    end if;
    if (ev->>'n_abstained')::int <> 3 then
      insert into _fail values ('EV-n_abstained', format('n_abstained=%s, expected 3', ev->>'n_abstained'));
    end if;
    if (ev->'evidence'->>'n')::int <> 12 then
      insert into _fail values ('EV-evidence', format('evidence.n=%s, expected 12', ev->'evidence'->>'n'));
    end if;
    -- base rate: 7 of 12 returned (5 from A + 2 from B)
    if (ev->'base_rate'->>'numerator')::int <> 7 then
      insert into _fail values ('EV-base_rate',
        format('base_rate.numerator=%s, expected 7 (5 group-A + 2 group-B returns)', ev->'base_rate'->>'numerator'));
    end if;
    if (ev->'base_rate'->>'denominator')::int <> 12 then
      insert into _fail values ('EV-base_rate',
        format('base_rate.denominator=%s, expected 12', ev->'base_rate'->>'denominator'));
    end if;

    -- reliability bins: exactly one 90-100 bin (n=6, observed 83.3) and one 30-40 bin (n=6, observed 33.3)
    select b into v_bin90 from jsonb_array_elements(ev->'calibration'->'bins') b
     where b->>'bin' = '90-100';
    select b into v_bin30 from jsonb_array_elements(ev->'calibration'->'bins') b
     where b->>'bin' = '30-40';

    if v_bin90 is null then
      insert into _fail values ('EV-bins', 'no 90-100 reliability bin was returned');
    else
      if (v_bin90->>'n')::int <> 6 then
        insert into _fail values ('EV-bins', format('90-100 bin n=%s, expected 6', v_bin90->>'n'));
      end if;
      if (v_bin90->>'observed_rate')::numeric <> 83.3 then
        insert into _fail values ('EV-bins',
          format('90-100 bin observed_rate=%s, expected 83.3 (5/6)', v_bin90->>'observed_rate'));
      end if;
    end if;
    if v_bin30 is null then
      insert into _fail values ('EV-bins', 'no 30-40 reliability bin was returned');
    else
      if (v_bin30->>'n')::int <> 6 then
        insert into _fail values ('EV-bins', format('30-40 bin n=%s, expected 6', v_bin30->>'n'));
      end if;
      if (v_bin30->>'observed_rate')::numeric <> 33.3 then
        insert into _fail values ('EV-bins',
          format('30-40 bin observed_rate=%s, expected 33.3 (2/6)', v_bin30->>'observed_rate'));
      end if;
    end if;
    -- exactly two bins total: proves cl_synth never contributed a 7th member anywhere
    if jsonb_array_length(ev->'calibration'->'bins') <> 2 then
      insert into _fail values ('EV-bins',
        format('calibration.bins has %s entries, expected exactly 2 (90-100 and 30-40)',
               jsonb_array_length(ev->'calibration'->'bins')));
    end if;

    -- Brier, hand-computed above: ~0.1892. Assert within 0.001.
    v_brier := (ev->'calibration'->>'brier')::numeric;
    if v_brier is null or abs(v_brier - 0.1892) > 0.001 then
      insert into _fail values ('EV-brier',
        format('brier=%s, expected ~0.1892 (within 0.001) — see the hand calc in this file''s header',
               v_brier));
    end if;

    -- AUC, hand-computed above: 26.5/35 = 0.7571428571. Assert within 0.001.
    v_auc := (ev->'discrimination'->>'auc')::numeric;
    if v_auc is null or abs(v_auc - 0.7571428571) > 0.001 then
      insert into _fail values ('EV-auc',
        format('auc=%s, expected ~0.7571 (within 0.001) — see the hand calc in this file''s header',
               v_auc));
    end if;

    if ev->>'time_basis' <> 'sale_occurred_at' then
      insert into _fail values ('EV-time_basis', format('time_basis=%s, expected sale_occurred_at', ev->>'time_basis'));
    end if;
  end if;
end
$v681$;

select case when count(*)=0
            then 'PASS — v681 return probability: memoryless-hazard model, k<3 abstention, '
                 'temporal-holdout leak probe, reversal/synthetic exclusion, measured '
                 'calibration (deciles + Brier) and discrimination (rank-sum AUC), entitlement'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v681: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
