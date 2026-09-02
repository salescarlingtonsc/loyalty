-- NESTLY v681 — return-probability model with a measured, temporally-held-out proof.
--
-- Closes acceptance checks 49 (a return-probability model) and 50 (it abstains on sparse
-- history) honestly: the model is a transparent, documented formula (no ML, nothing that can't
-- be hand-checked), and its calibration + discrimination are MEASURED against real held-out
-- outcomes rather than asserted. Proof: db/tests/executed/v681_corpus_calibration.sql.
--
-- MODEL. app.return_probability_v681(p_business, p_client, p_as_of) — memoryless-exponential
-- hazard on the customer's OWN rhythm:
--
--   m = median inter-visit interval in days, k = number of measured intervals (gaps, not
--       visits), both computed AS OF p_as_of by app.customer_cadence_batch_v1 (the v651
--       canonical cadence authority) — only visits with occurred_at date < as_of_date+1 and
--       created_at <= p_as_of are ever seen, so the model can never be handed information from
--       after p_as_of.
--   P(return within H days of p_as_of) = 1 - exp(-H / m)              [H = 30 by default]
--
-- This is the textbook CDF of an exponential distribution with mean m, i.e. "if this customer's
-- gaps between visits behave like a Poisson process with rate 1/m, what's the chance the next
-- gap is <= H days". It deliberately does NOT use days-already-elapsed-since-last-visit (d) as
-- a covariate: the exponential distribution is memoryless BY CONSTRUCTION, so
-- P(return within the next H days | already d days since last visit) is identical to
-- P(return within the first H days) for every d under this model — folding d in would not
-- change the number, only manufacture the appearance of using it. The payload's own 'method'
-- string states this so nobody mistakes the omission for a bug. (The migration prompt offered a
-- discrete geometric-on-intervals variant as an alternative; the continuous exponential is
-- chosen because m is itself measured on a continuous day scale via percentile_cont, so no
-- artificial discretisation of partial days is needed.)
--
-- ABSTENTION (check 50). k < 3 (the same customer_interval_min_observations=3 default v651's own
-- policy seeds, and the same floor the v651 fixture already proves) returns
-- status='insufficient', probability=null, and a reason — never a fabricated number from a
-- rhythm the customer hasn't shown three times over. This is deliberately a HARD gate
-- independent of any business's own lifecycle policy row (unlike app.customer_cadence_v1, which
-- resolves against customer_lifecycle_policies_v107 and can vary per business) — a probability
-- claim is a stronger statement than a lapse classification, so it earns the stricter, fixed
-- floor rather than inheriting a policy value that could be configured down.
--
-- EVALUATION (check 49's "measured, not asserted" half).
-- public.evaluate_return_probability_v681(p_business, p_train_until, p_horizon_days default 30,
-- p_branch default null) — gated by app.ci_access_gate_v667 (frozen CI entitlement authority,
-- db/migrations/20260901_nestly_v667_ci_access_boundaries.sql).
--
--   TEMPORAL HOLDOUT. Every prediction is made AS OF p_train_until (via
--   app.customer_cadence_batch_v1's own p_as_of gate — created_at <= p_train_until AND the
--   visit's own occurred_at date < p_train_until's date + 1). The OBSERVED outcome for each
--   scored client is whether a qualifying visit (counts_as_visit, not reversed, non-synthetic
--   client) occurred_at STRICTLY AFTER p_train_until and within p_horizon_days of it — a
--   completely separate query over public.sales that never touches the prediction inputs. A
--   defensive, EXECUTABLE assertion re-checks the population's own last_visit_at against
--   p_train_until before any prediction is made, and raises if the two ever disagree, rather
--   than trusting the batch function's internal filters blindly.
--
--   Population: every non-synthetic client with >=1 qualifying visit on or before p_train_until
--   (i.e. every row app.customer_cadence_batch_v1 returns for the business/branch as of that
--   date). A client with k>=3 is SCORED; a client with k<3 is ABSTAINED (n_abstained) — counted,
--   never silently dropped, per check 50. A client with zero qualifying visits at all never
--   enters the batch function's output and is outside this evaluation's population entirely
--   (there is nothing — not even an abstained prediction — to hold out for them).
--
--   calibration.bins — reliability deciles of predicted probability (bin edges at every 10
--   percentage points, {bin,n,mean_predicted,observed_rate}), calibration.brier — the mean
--   squared error of predicted probability vs the {0,1} observed outcome, over EXACTLY the
--   scored population (never the abstained one — there is no prediction to score there).
--   discrimination.auc — the Mann-Whitney U / rank-sum AUC (ties given the standard 0.5-credit
--   average rank), computed over the same scored population; null if either outcome class is
--   empty (an AUC needs both a positive and a negative to rank against).
--   evidence — app.subgroup_evidence_v1(n_scored); base_rate — app.rate_block_v1 of the observed
--   positive count over n_scored (the CI-B statistical authority, frozen in
--   docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md, embedded rather than reimplemented).
--
-- JUDGEMENT CALLS, recorded rather than buried:
--   - The abstention floor here (k<3, hardcoded) does NOT delegate to
--     customer_lifecycle_policies_v107 the way app.customer_cadence_v1 does. A probability
--     claim is a stronger, more quotable number than a lapse-state label; letting a business
--     configure the floor down would let a probability be manufactured from thinner evidence
--     than the rest of the platform trusts anywhere else. Recorded as a deliberate divergence,
--     not an oversight.
--   - The evaluation's outcome window ("did they return") is NOT branch-filtered even when
--     p_branch narrows the PREDICTION population to that branch's first-time-at-that-branch
--     customers — a customer's return to ANY branch of the firm still counts as "they came
--     back". p_branch narrows who is being asked about, not what counts as an answer.
--   - A client scored at p_train_until who happens to also appear as a candidate for a LATER
--     evaluation window is not deduplicated across separate calls — each call is a fresh,
--     independent backtest at its own train_until, exactly as a walk-forward validation should
--     behave; there is no cross-call state here to leak from one window to the next.
begin;

-- ---------------------------------------------------------------------------
-- 1 · The model itself. Internal, service_role only — matches app.customer_cadence_v1's own
--     grant shape exactly (no direct entitlement gate inside; callers gate at the public layer).
-- ---------------------------------------------------------------------------
create or replace function app.return_probability_v681(
  p_business uuid, p_client uuid, p_as_of timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_client  uuid := app.v111_effective_client_id(p_business, p_client);
  v_row     record;
  v_p       numeric;
  v_horizon constant integer := 30;
  v_floor   constant integer := 3;
begin
  select * into v_row
    from app.customer_cadence_batch_v1(
      p_business,
      ((p_as_of at time zone 'Asia/Singapore')::date + 1),
      ((p_as_of at time zone 'Asia/Singapore')::date + 1),
      p_as_of, null, true) b
   where b.client_id = v_client;

  if not found or v_row.last_visit_at is null then
    return jsonb_build_object(
      'status', 'insufficient',
      'probability', null,
      'k', 0,
      'horizon_days', v_horizon,
      'as_of', p_as_of,
      'reason', 'no qualifying visit on record as of this date');
  end if;

  if coalesce(v_row.interval_observations, 0) < v_floor or v_row.median_interval_days is null then
    return jsonb_build_object(
      'status', 'insufficient',
      'probability', null,
      'k', coalesce(v_row.interval_observations, 0),
      'horizon_days', v_horizon,
      'as_of', p_as_of,
      'reason', format(
        'fewer than %s measured intervals (k=%s); not enough of this customer''s own rhythm to '
        'project a probability from — the same floor app.customer_cadence_v1 trusts as '
        '''customer_median_interval'' evidence',
        v_floor, coalesce(v_row.interval_observations, 0)));
  end if;

  v_p := 1 - exp((- v_horizon::numeric / v_row.median_interval_days));

  return jsonb_build_object(
    'status', 'ready',
    'probability', round(v_p, 4),
    'probability_pct', round(v_p * 100, 1),
    'k', v_row.interval_observations,
    'median_interval_days', round(v_row.median_interval_days::numeric, 1),
    'last_visit_at', v_row.last_visit_at,
    'horizon_days', v_horizon,
    'as_of', p_as_of,
    'method', 'memoryless exponential hazard: P(return within 30 days) = 1 - exp(-30 / m), where '
      'm is this customer''s own median inter-visit interval in days (app.customer_cadence_batch_v1, '
      'the v651 canonical cadence authority). Days already elapsed since the last visit are '
      'deliberately NOT used as a covariate: the exponential distribution is memoryless by '
      'construction, so this 30-day forward probability is identical regardless of how long the '
      'customer has already been away — using elapsed time would not change the number under '
      'this model, only the appearance of accounting for it. This is a documented property of '
      'the chosen method, not an omission.');
end;
$$;
revoke all on function app.return_probability_v681(uuid,uuid,timestamptz) from public, anon, authenticated;
grant execute on function app.return_probability_v681(uuid,uuid,timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- 2 · The measured, temporally-held-out proof. Gated, set-based, embeds the frozen v672
--     statistical authority.
-- ---------------------------------------------------------------------------
create or replace function public.evaluate_return_probability_v681(
  p_business uuid, p_train_until timestamptz, p_horizon_days integer default 30,
  p_branch uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_business_wide boolean := (p_branch is null);
  v_n_scored     integer;
  v_n_abstained  integer;
  v_n_pos        integer;
  v_brier        numeric;
  v_auc          numeric;
  v_bins         jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);

  -- TEMPORAL-LEAK ASSERTION, executed, not merely claimed: the population as-of p_train_until
  -- must never contain a client whose OWN last known visit is after the cutoff. This is already
  -- structurally guaranteed by app.customer_cadence_batch_v1's own filters (created_at <=
  -- p_train_until AND the visit's own date < p_train_until's date + 1) — this re-checks the
  -- OUTPUT independently rather than trusting that guarantee blindly.
  if exists (
    select 1
      from app.customer_cadence_batch_v1(
        p_business,
        ((p_train_until at time zone 'Asia/Singapore')::date + 1),
        ((p_train_until at time zone 'Asia/Singapore')::date + 1),
        p_train_until, p_branch, v_business_wide) b
     where b.last_visit_at > p_train_until
  ) then
    raise exception 'return-probability temporal leak: a scored client''s last known visit falls '
      'after p_train_until (%); the holdout is not real', p_train_until
      using errcode = 'XX000';
  end if;

  with pop as materialized (
    select b.client_id, b.interval_observations, b.median_interval_days, b.last_visit_at
      from app.customer_cadence_batch_v1(
        p_business,
        ((p_train_until at time zone 'Asia/Singapore')::date + 1),
        ((p_train_until at time zone 'Asia/Singapore')::date + 1),
        p_train_until, p_branch, v_business_wide) b
      join public.clients c on c.id = b.client_id
     where not coalesce(c.is_synthetic, false)
  ),
  scored as materialized (
    select client_id,
           interval_observations as k,
           median_interval_days as m,
           case when interval_observations >= 3 and median_interval_days is not null
                then 1 - exp((- p_horizon_days::numeric / median_interval_days))
                else null end as prob
      from pop
  ),
  -- Observed outcome: a qualifying, non-reversed, non-synthetic visit strictly after the cutoff
  -- and within the horizon. Deliberately NOT branch-filtered — a return to any branch of the
  -- firm still counts as "they came back" (see the migration header's judgement-call note).
  outcomes as materialized (
    select distinct app.v111_effective_client_id(p_business, s.client_id) as client_id
      from public.sales s
      join public.clients c on c.id = app.v111_effective_client_id(p_business, s.client_id)
     where s.business_id = p_business
       and coalesce(s.counts_as_visit, false)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and not coalesce(c.is_synthetic, false)
       and s.occurred_at > p_train_until
       and s.occurred_at <= p_train_until + make_interval(days => p_horizon_days)
  ),
  joined as materialized (
    select sc.client_id, sc.prob,
           case when o.client_id is not null then 1 else 0 end as y
      from scored sc
      left join outcomes o on o.client_id = sc.client_id
     where sc.prob is not null
  ),
  ranked as materialized (
    select prob, y, row_number() over (order by prob) as rn from joined
  ),
  avgranked as materialized (
    select prob, y, avg(rn) over (partition by prob) as rank_avg from ranked
  ),
  auc_agg as materialized (
    select sum(rank_avg) filter (where y = 1) as sum_pos,
           count(*) filter (where y = 1) as n_pos,
           count(*) filter (where y = 0) as n_neg
      from avgranked
  ),
  binned as materialized (
    select least(90, floor(prob * 10) * 10) as bin_lo, prob, y from joined
  ),
  bins_agg as materialized (
    select bin_lo, count(*) as n, avg(prob) as mean_p, sum(y) as pos
      from binned
     group by bin_lo
  )
  select
    (select count(*) from joined),
    (select count(*) from scored where prob is null),
    (select count(*) filter (where y = 1) from joined),
    (select round(avg(power(prob - y, 2)), 6) from joined),
    (select case when n_pos > 0 and n_neg > 0
                 then round((sum_pos - n_pos * (n_pos + 1) / 2.0) / (n_pos * n_neg), 6)
                 else null end
       from auc_agg),
    (select coalesce(jsonb_agg(jsonb_build_object(
              'bin', format('%s-%s', bin_lo::int, bin_lo::int + 10),
              'n', n,
              'mean_predicted', round(mean_p * 100, 1),
              'observed_rate', round(100.0 * pos / n, 1)
            ) order by bin_lo), '[]'::jsonb)
       from bins_agg)
    into v_n_scored, v_n_abstained, v_n_pos, v_brier, v_auc, v_bins;

  return jsonb_build_object(
    'n_scored', v_n_scored,
    'n_abstained', v_n_abstained,
    'train_until', p_train_until,
    'horizon_days', p_horizon_days,
    'time_basis', 'sale_occurred_at',
    'calibration', jsonb_build_object('bins', v_bins, 'brier', v_brier),
    'discrimination', jsonb_build_object('auc', v_auc),
    'evidence', app.subgroup_evidence_v1(v_n_scored),
    'base_rate', app.rate_block_v1(v_n_pos, v_n_scored),
    'observed_since', app.metric_observed_since_v1('return_probability_v681', p_business),
    'method', 'per-customer P(return within horizon_days) = 1 - exp(-horizon_days / m); m = the '
      'customer''s own median inter-visit interval (app.customer_cadence_batch_v1, as of '
      'train_until); abstain when fewer than 3 measured intervals. Outcome = any qualifying, '
      'non-reversed visit strictly after train_until and within horizon_days of it.');
end;
$$;
revoke all on function public.evaluate_return_probability_v681(uuid,timestamptz,integer,uuid) from public, anon;
grant execute on function public.evaluate_return_probability_v681(uuid,timestamptz,integer,uuid)
  to authenticated, service_role;

commit;
