-- NESTLY v669 — Phase D re-assessment, D2 + D3: two misleading-number defects, both
-- confirmed by the 2026-09-01 re-assessment (docs/qa/CI-REASSESSMENT-2026-09-01.md) and held
-- red by deliberately-red assertions in the executed corpus.
--
-- D2 — app.evidence_block_v1 (db/migrations/20260831_nestly_v652_evidence_contract.sql) used an
-- unadjusted normal-approximation (Wald) interval on the difference of two rates. Hand-verified
-- at treated 9/10 (90%) vs comparison 1/10 (10%) — n=10 per arm, which CLEARS the default
-- p_min_arm floor of 10, so the floor does not intervene:
--   p1=0.9, p2=0.1, diff=0.8, se=sqrt(0.9*0.1/10 + 0.1*0.9/10)=sqrt(0.018)=0.1341641
--   lo = 0.8 - 1.96*0.1341641 = 0.5370384 => 53.7pp
--   hi = 0.8 + 1.96*0.1341641 = 1.0629616 => 106.3pp
-- 106.3pp is outside [-100,100], the only range a percentage-point difference between two rates
-- can legally occupy. Held red by db/tests/executed/v652_corpus_statistics.sql assertion S6b.
--
-- Fix: replace the interval arithmetic with Newcombe's hybrid score method — a Wilson score
-- interval computed independently on each arm, then combined into a difference interval. Wilson
-- intervals are bounded to [0,1] on each arm by construction, so the Newcombe combination is
-- bounded to [-1,1] (i.e. [-100,100]pp) by construction; it is the standard textbook method for
-- a confidence interval on the difference of two independent proportions where the Wald interval
-- is known to misbehave (Newcombe 1998, "Interval estimation for the difference between
-- independent proportions"). Nothing else about the contract changes: p_min_arm, the verdict
-- tiers ('strong_pattern'/'early_signal'/'insufficient'), the verdict-spans-zero rule, the
-- verdict ceiling, and every payload key are byte-identical to the v652 version — confirmed by
-- reading every consumer (public.get_recovery_report_v550, the only SQL caller; app/app-business.js
-- and app/app.js's recoveryHeadlineHtmlV652, the only UI consumers) before this migration was
-- written: they read evidence.verdict, evidence.verdict_ceiling, evidence.sample.*,
-- evidence.rates.*, evidence.difference.{absolute_pp,relative,confidence_95_pp}, and
-- evidence.limitations — never evidence.difference.method by value (it is disclosure text, not a
-- branch condition), so renaming that string is safe. Only the 'method' string and the
-- lo/hi arithmetic that produces 'confidence_95_pp' change.
--
-- KNOWN CONSEQUENCE, reported rather than hidden: three OTHER assertions in
-- v652_corpus_statistics.sql (S1b, S3, S4) hardcode hand-computed WALD confidence-interval
-- bounds with a tight (+/-0.1pp) tolerance, as truth-table checks against the old method. A
-- Wilson/Newcombe interval is a different, non-linear computation and does not reproduce those
-- Wald numbers (Newcombe is asymptotically close to Wald only for large n away from 0%/100% —
-- none of S1b, S3, S4 satisfy that). S1b in particular hardcodes an EXACT degenerate [100.0,100.0]
-- point interval for a 5-of-5 vs 0-of-5 split, which a Wilson interval never produces (it has
-- genuine width even at p=1 or p=0, because it does not collapse the variance term to zero the
-- way Wald's p(1-p)/n does). S1b's own comment already anticipated this ("pinned so a future
-- change to the method is visible here") — and it worked: all three went red on this change,
-- exactly as intended. RESOLUTION (corrected header; an earlier draft of this paragraph said
-- the three were left red, which is not what shipped — an independent verification caught the
-- contradiction): the VERIFYING session re-pinned S1b/S3/S4 to Newcombe values it hand-computed
-- independently before comparing with function output (S1b [38.6, 100.0]; S3 [-15.1, 22.7];
-- S4 [10.4, 29.1]; all matched the live function to 0.1pp). A re-pin by the verifier after the
-- tripwire fired is a truth-table update for a deliberate method change, not a weakening; the
-- arithmetic sits beside each assertion in the fixture. S6a (method-string disclosure) and S6b
-- (the specific defect this migration closes) were updated with the fix itself.
--
-- D3 — app.customer_cadence_v1 (db/migrations/20260831_nestly_v651_canonical_cadence.sql line
-- ~170) does `round(coalesce(v_row.median_interval_days, 0)::numeric, 1)`. A customer with
-- exactly one visit has interval_observations = 0 (zero elapsed gaps to measure a median from),
-- so v_row.median_interval_days is genuinely NULL — and the coalesce silently turns that into
-- 0.0, which reads as "this customer visits every 0 days," a fabricated rhythm for a customer
-- whose true rhythm is entirely unknown. The zero-visit case is already handled correctly
-- (returns status='insufficient' with no median field at all); the one-visit case is the only
-- inconsistency. Fix: emit a genuine jsonb null for median_interval_days whenever
-- interval_observations = 0, in every other respect identical. Held red by
-- db/tests/executed/v651_corpus_cadence.sql assertion C6.
--
-- Consumer check for D3: grepped db/, app/, scripts/, docs/ for customer_cadence_v1 and
-- customer_cadence_batch_v1. The only hits outside this migration and its own executed/
-- unexecuted test files are the two doc files that record this exact finding
-- (docs/qa/CI-PROOF-BASELINE-2026-09-01.md, docs/qa/CI-REASSESSMENT-2026-09-01.md). No app/*.js
-- file and no other db/migrations/*.sql file calls either function. The re-assessment's claim
-- that app.customer_cadence_v1 has NO callers yet is confirmed — this fix is consequence-free
-- for any existing caller today; it exists so the first real caller (Customer Intelligence
-- "expected next visit", Phase H "who to contact today") inherits honest output from day one.
begin;

-- ---------------------------------------------------------------------------
-- 1. app.evidence_block_v1 — extract-and-diff from v652. Only the CI arithmetic (now Newcombe
--    hybrid Wilson score) and the 'method' disclosure string change. Every declared parameter,
--    every payload key, the verdict logic, and the ceiling logic are byte-identical to v652.
-- ---------------------------------------------------------------------------
create or replace function app.evidence_block_v1(
  p_population text,
  p_denominator text,
  p_window_from date,
  p_window_to date,
  p_treated_n integer,
  p_treated_events integer,
  p_baseline_n integer,
  p_baseline_events integer,
  p_comparison text,
  p_max_verdict text default 'strong_pattern',
  p_limitations text[] default array[]::text[],
  p_observed_since timestamptz default null,
  p_min_arm integer default 10)
returns jsonb
language plpgsql
immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_p1 numeric; v_p2 numeric; v_diff numeric;
  v_lo numeric; v_hi numeric;
  -- v669: Newcombe hybrid Wilson score interval — per-arm Wilson bounds, then combined.
  v_z constant numeric := 1.96;
  v_z2 constant numeric := v_z * v_z;         -- 3.8416
  v_denom1 numeric; v_denom2 numeric;
  v_centre1 numeric; v_centre2 numeric;
  v_adjsd1 numeric; v_adjsd2 numeric;
  v_l1 numeric; v_u1 numeric; v_l2 numeric; v_u2 numeric;
  v_verdict text;
  v_rank_max integer;
  v_rank integer;
begin
  if p_max_verdict not in ('strong_pattern','early_signal','insufficient') then
    raise exception 'unsupported verdict ceiling %', p_max_verdict using errcode = '22023';
  end if;

  if coalesce(p_treated_n,0) > 0 then v_p1 := p_treated_events::numeric / p_treated_n; end if;
  if coalesce(p_baseline_n,0) > 0 then v_p2 := p_baseline_events::numeric / p_baseline_n; end if;

  if v_p1 is not null and v_p2 is not null then
    v_diff := v_p1 - v_p2;

    -- Wilson score interval, arm 1 (treated).
    v_denom1  := 1 + v_z2 / p_treated_n;
    v_centre1 := v_p1 + v_z2 / (2 * p_treated_n);
    v_adjsd1  := sqrt(v_p1 * (1 - v_p1) / p_treated_n + v_z2 / (4 * p_treated_n::numeric ^ 2));
    v_l1 := (v_centre1 - v_z * v_adjsd1) / v_denom1;
    v_u1 := (v_centre1 + v_z * v_adjsd1) / v_denom1;

    -- Wilson score interval, arm 2 (comparison/baseline).
    v_denom2  := 1 + v_z2 / p_baseline_n;
    v_centre2 := v_p2 + v_z2 / (2 * p_baseline_n);
    v_adjsd2  := sqrt(v_p2 * (1 - v_p2) / p_baseline_n + v_z2 / (4 * p_baseline_n::numeric ^ 2));
    v_l2 := (v_centre2 - v_z * v_adjsd2) / v_denom2;
    v_u2 := (v_centre2 + v_z * v_adjsd2) / v_denom2;

    -- Newcombe (1998) hybrid combination of the two Wilson intervals. Bounded to [-1,1] by
    -- construction because each Wilson bound is bounded to [0,1] by construction.
    v_lo := v_diff - sqrt((v_p1 - v_l1) ^ 2 + (v_u2 - v_p2) ^ 2);
    v_hi := v_diff + sqrt((v_u1 - v_p1) ^ 2 + (v_p2 - v_l2) ^ 2);
  end if;

  -- Verdict, before the ceiling is applied.
  if v_p1 is null or v_p2 is null
     or coalesce(p_treated_n,0) < p_min_arm
     or coalesce(p_baseline_n,0) < p_min_arm then
    v_verdict := 'insufficient';
  elsif v_lo is null or (v_lo <= 0 and v_hi >= 0) then
    -- The interval spans zero: this group cannot be told apart from its comparison.
    v_verdict := 'insufficient';
  else
    v_verdict := 'strong_pattern';
  end if;

  -- Apply the ceiling. A non-randomised comparison can never rise above early_signal.
  v_rank_max := case p_max_verdict when 'strong_pattern' then 3 when 'early_signal' then 2 else 1 end;
  v_rank := case v_verdict when 'strong_pattern' then 3 when 'early_signal' then 2 else 1 end;
  if v_rank > v_rank_max then
    v_verdict := p_max_verdict;
  end if;

  return jsonb_build_object(
    'population', p_population,
    'denominator', p_denominator,
    'window', jsonb_build_object('from', p_window_from, 'to', p_window_to),
    'sample', jsonb_build_object(
      'treated', p_treated_n, 'treated_events', p_treated_events,
      'comparison', p_baseline_n, 'comparison_events', p_baseline_events),
    'comparison', p_comparison,
    'rates', jsonb_build_object(
      'treated_pct', case when v_p1 is null then null else round(v_p1 * 100, 1) end,
      'comparison_pct', case when v_p2 is null then null else round(v_p2 * 100, 1) end),
    'difference', case when v_diff is null then null else jsonb_build_object(
      'absolute_pp', round(v_diff * 100, 1),
      'relative', case when v_p2 > 0 then round(v_p1 / v_p2, 2) else null end,
      'confidence_95_pp', jsonb_build_array(round(v_lo * 100, 1), round(v_hi * 100, 1)),
      'method', 'Newcombe hybrid Wilson score, 95% interval on the difference in rates') end,
    'verdict', v_verdict,
    'verdict_ceiling', p_max_verdict,
    'limitations', to_jsonb(p_limitations),
    'observed_since', p_observed_since);
end;
$$;
-- ACL restated verbatim from the live proacl (unchanged by this migration).
revoke all on function app.evidence_block_v1(text,text,date,date,integer,integer,integer,integer,text,text,text[],timestamptz,integer)
  from public, anon, authenticated;
grant execute on function app.evidence_block_v1(text,text,date,date,integer,integer,integer,integer,text,text,text[],timestamptz,integer)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. app.customer_cadence_v1 — anchored, single-occurrence patch of the live body: the one
--    `round(coalesce(v_row.median_interval_days, 0)::numeric, 1)` expression becomes a genuine
--    jsonb null when interval_observations = 0. Every other branch is untouched.
-- ---------------------------------------------------------------------------
do $patch$
declare
  v_def text;
  v_anchor text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure(
    'app.customer_cadence_v1(uuid,uuid,timestamptz)')) into v_def;
  if v_def is null then raise exception 'v669: app.customer_cadence_v1 not found'; end if;

  v_anchor := '''median_interval_days'', round(coalesce(v_row.median_interval_days, 0)::numeric, 1),';
  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 1 then
    raise exception 'v669: median_interval_days anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  v_def := replace(v_def, v_anchor,
    -- v669 (D3): zero interval observations means zero measured gaps — there is nothing to take
    -- a median OF. A single-visit customer must get an honest null, not a fabricated 0.0 that
    -- reads as "visits every day". Any real median (including a genuine 0-day same-day repeat
    -- visit, which is a measured value, not an absent one) still passes through unchanged.
    '''median_interval_days'', case when coalesce(v_row.interval_observations, 0) = 0 then null
        else round(v_row.median_interval_days::numeric, 1) end,');
  execute v_def;
end;
$patch$;
-- ACL restated verbatim from the live proacl (unchanged by this migration).
revoke all on function app.customer_cadence_v1(uuid,uuid,timestamptz) from public, anon, authenticated;
grant execute on function app.customer_cadence_v1(uuid,uuid,timestamptz) to service_role;

commit;
