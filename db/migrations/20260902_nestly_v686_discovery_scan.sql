-- NESTLY v686 — Customer Intelligence DISCOVERY: a generic, honest pattern scan.
--
-- Closes checklist items 26 (holdout validation), 27 (predetermined dimensions x metrics,
-- disclosed), 28 (deterioration), 67 (seasonality disclosure), 69 (false discovery control),
-- 70 (missingness sensitivity). Every prior CI-A/CI-B reader answers a question a human
-- picked in advance ("do referral customers return more?"). This one is different on
-- purpose: it scans a fixed set of SEGMENT DIMENSIONS against ONE metric for relationships
-- NOBODY hand-authored, and it is honest about the scanning itself — how many comparisons it
-- ran, how many of those were even worth reporting, and how many survived actually looking
-- again on data it had not yet seen. A discovery engine that does not disclose its own
-- multiple-comparisons problem is not a discovery engine, it is a coincidence generator with
-- a headline font.
--
-- Frozen inputs reused, not reinvented (docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md):
--   app.ci_access_gate_v667            same entitlement boundary as every other CI reader.
--   app.subgroup_evidence_v1           the ONE floor (default 5), no per-reader override.
--   app.evidence_block_v1 (v669)       Newcombe hybrid Wilson interval on a rate difference —
--                                      reused here for THREE separate comparisons: group-vs-
--                                      rest (candidacy), and group's-own train-vs-holdout
--                                      (deterioration). Same function, same guarantees.
--   app.customer_demographics_core_v674  age_band/gender, TODAY basis (see judgement call 2).
--   app.ci_effective_node_v650          the category node for a sale line (level-2 rollup).
--   app.analytics_sale_class_v1 (v628)  the one exclusion authority for revenue/visit/reversal/
--                                      synthetic-client population rules.
--
-- ---------------------------------------------------------------------------------------------
-- THE METRIC. One metric, many segments — keeps the maths honest (the brief's own words). For
-- each customer, in each half of the period (see SPLIT below), find their EARLIEST qualifying
-- (counts_as_visit) purchase inside that half — their "anchor". The metric is binary per
-- customer: did they make ANY further qualifying purchase within 30 days after the anchor
-- ("returned"). A customer only enters a half's denominator once they are MATURE for that half
-- (current_date - anchor >= 30) — an immature anchor has no decidable outcome yet, so it is
-- excluded rather than silently coded as "did not return" (the same maturity discipline v674's
-- cohort reader uses).
--
-- ---------------------------------------------------------------------------------------------
-- THE SPLIT (26). The requested period is divided in half BY TIME: TRAIN is the first half,
-- HOLDOUT is the second. Integer day-count division floors, so an odd-length period gives
-- HOLDOUT the extra day. A window that cannot produce two non-empty halves (fewer than 2 days)
-- is refused (22023) rather than silently degenerating to a one-sided scan.
--
-- ---------------------------------------------------------------------------------------------
-- THE FIVE SEGMENT DIMENSIONS (27), each partitioning the SAME per-half customer population:
--   weekday              ISO day-of-week (1-7) of the anchor purchase.
--   age_band x gender    via app.customer_demographics_core_v674 — ONE combined group key
--                        ('<age_band>_<gender>'), not two separate dimensions, because the
--                        acceptance brief itself names it as one dimension ("age_band x
--                        gender"), not a cross-product scanned as two.
--   category_node        the level-2 taxonomy node of the anchor sale's (highest-value) line,
--                        via app.ci_effective_node_v650 + taxonomy_nodes.parent_key rollup.
--   acquisition_source    clients.first_acquired_via — a static client attribute, not window-
--                        dependent, read directly (no per-half computation needed).
--   branch                ONLY when p_branch is null AND the business genuinely has more than
--                        one ACTIVE branch. A single-branch firm has no branch dimension to
--                        scan (same "has no dimension" discipline v667/v675 already apply to
--                        p_branch itself) — silently adding a one-value "dimension" would
--                        report a comparison that could not possibly exist. When p_branch IS
--                        given, every population is already scoped to that one branch, so the
--                        dimension is dropped for the same reason.
-- A row missing a dimension's classifying value (unclassified category, unresolved age/gender)
-- is simply excluded from THAT dimension's population — it still counts in every other
-- dimension it does classify into. No "unclassified" bucket is invented for a discovery scan;
-- that disclosure belongs to the readers that already carry it (v667, v674).
--
-- ---------------------------------------------------------------------------------------------
-- CANDIDATES (step 3-4) AND FALSE DISCOVERY CONTROL (69). For every (dimension, group) cell
-- whose TRAIN n clears app.subgroup_evidence_v1's floor, the group's TRAIN rate is compared
-- against the TRAIN rate of every OTHER group in the same dimension pooled together (one
-- hypothesis per examined cell) via app.evidence_block_v1. A cell becomes a CANDIDATE only if
-- BOTH hold: |diff| >= 10pp (materiality) AND the Newcombe interval on that difference excludes
-- zero (i.e. is not consistent with "no difference"). Every candidate then gets a classical
-- two-proportion z-test p-value (app.two_prop_p_value_v686, formula documented on the function
-- itself) purely for Benjamini-Hochberg bookkeeping — the accept/reject decision for CANDIDACY
-- itself already came from the interval, not from this p-value; the p-value exists so false-
-- discovery control has something to rank on. Candidates are sorted by p ascending, and the
-- standard BH step-up rule finds the LARGEST rank k such that p_(k) <= (k/m)*0.10 (m =
-- candidate count, q = 0.10); every candidate at rank <= k survives. hypotheses_examined,
-- candidates_pre_bh, survivors_post_bh and q are all disclosed in the payload — the whole
-- point of check 69 is that a reader of N "findings" can see the comparisons behind them.
--
-- ---------------------------------------------------------------------------------------------
-- HOLDOUT VALIDATION (26) turns a BH-surviving candidate into a 'discovery' only if its
-- direction (sign of group-minus-rest) REPLICATES on the HOLDOUT half's own population for the
-- same group (holdout group n must also clear the floor). Same sign -> discovery
-- (evidence_class 'ASSOCIATION' — this engine finds correlations on later data, never causes).
-- Different sign, or holdout too thin to judge -> 'not_replicated', listed in full, never
-- hidden. This is the check that catches a train-only fluke red-handed.
--
-- ---------------------------------------------------------------------------------------------
-- DETERIORATION (28) is a SEPARATE computation from the candidate/BH pipeline on purpose: a
-- segment's own rate can collapse from one half to the next without ever having been a
-- "candidate" against its dimension's rest (facial-category customers can be unremarkable next
-- to nail customers in TRAIN and still crash in HOLDOUT). For every (dimension, group) cell
-- whose n clears the floor in BOTH halves, app.evidence_block_v1 compares the SAME group's
-- train rate against its own holdout rate; 'deteriorating' when holdout is lower by >= 10pp AND
-- the Newcombe interval on that change excludes zero.
--
-- ---------------------------------------------------------------------------------------------
-- SEASONALITY (67): the same overall (non-segmented) metric computed for the calendar window
-- exactly one year earlier, when data reaches that far back — gated on
-- app.metric_observed_since_v1 AND an actual non-empty prior-year cohort, so "available" means
-- both "the metric existed then" and "there is something to show", not one alone. When either
-- fails, the payload says so plainly rather than omitting the key.
--
-- MISSINGNESS SENSITIVITY (70): the headline return rate (the same overall metric, over the
-- WHOLE requested period, not split by half) travels with a bracket under the two extreme
-- assumptions a business owner cannot rule out about its own anonymous (no client_id) qualifying
-- sales: what the rate would be if EVERY anonymous sale represented a customer who returned, and
-- what it would be if NONE did. This is exactly the "how much could the number I can't see move
-- the number I can see" disclosure — anonymous_sales and identified_sales travel beside the
-- bracket so a reader can judge how wide a gap that really is for this business.
--
-- ---------------------------------------------------------------------------------------------
-- JUDGEMENT CALLS, made explicit rather than silent.
-- 1. ONE FLOOR, THE DEFAULT (5), NO OVERRIDE — the v675 house rule (reversed there after a
--    fixture-tuned floor was caught and rejected on review) applies here without exception.
-- 2. AGE BASIS = TODAY, not purchase-date. Unlike v674's flagship cohort reader (which needs a
--    raw birth date to answer a caller-chosen age RANGE and so reimplements the precedence
--    inline), this engine only needs each customer's CURRENT classification to form a group
--    label — exactly what app.customer_demographics_core_v674 already returns, gate-free. Using
--    the core instead of reinventing a purchase-date variant keeps one authority for "what is
--    this customer's age_band/gender", at the cost of an anchor from three years ago being
--    grouped by an age band the customer has since aged out of. Recorded, not hidden.
-- 3. "RETURN" is ANY qualifying visit after the anchor, any category/branch — the same general
--    retention reading v674's flagship reader adopts (design decision 5 there), not a narrower
--    "did they rebuy the same thing" question.
-- 4. category_node classification for an anchor with multiple sale lines picks the HIGHEST-
--    line_cents item's node — a single deterministic tie-break, documented rather than assuming
--    one line item per anchor sale.
-- 5. The candidate/BH pipeline and the deterioration pipeline are independent by design (see
--    above) — the SAME cell can legitimately appear in 'not_replicated' (its train-vs-rest
--    story didn't hold up) AND in 'deteriorating' (its own train-vs-holdout rate genuinely
--    fell); these are different questions and neither implies the other.
begin;

-- ---------------------------------------------------------------------------------------------
-- 0 · Statistics helpers: erf approximation -> two-tailed normal p-value -> two-proportion
--     z-test p-value. Pure functions, no table access, so they stay trivially provable.
-- ---------------------------------------------------------------------------------------------
create or replace function app.erf_v686(p_x numeric)
returns numeric
language sql immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  -- Abramowitz & Stegun 7.1.26 rational approximation of erf(x), |error| <= 1.5e-7.
  -- erf(x) = sign(x) * (1 - (a1*t + a2*t^2 + a3*t^3 + a4*t^4 + a5*t^5) * exp(-x^2)),
  -- t = 1 / (1 + p*|x|), p = 0.3275911,
  -- a1=0.254829592 a2=-0.284496736 a3=1.421413741 a4=-1.453152027 a5=1.061405429 (Horner form).
  with x as (select abs(p_x)::numeric as ax, sign(p_x)::numeric as sgn),
  t as (select 1.0 / (1.0 + 0.3275911 * ax) as tt, ax, sgn from x)
  select sgn * (1 - (
      tt * (0.254829592 + tt * (-0.284496736 + tt * (1.421413741
             + tt * (-1.453152027 + tt * 1.061405429))))
    ) * exp(-(ax * ax)))
  from t;
$$;
revoke all on function app.erf_v686(numeric) from public, anon, authenticated;
grant execute on function app.erf_v686(numeric) to authenticated, service_role;

create or replace function app.normal_two_tailed_p_v686(p_z numeric)
returns numeric
language sql immutable
set search_path to 'pg_catalog', 'app', 'pg_temp'
as $$
  -- Phi(z) = 0.5*(1 + erf(z/sqrt(2))); two-tailed p = 2*(1 - Phi(|z|)), clamped to [0,1]
  -- against floating-point overshoot at the extremes.
  select least(1.0::numeric, greatest(0.0::numeric,
    2 * (1 - (0.5 * (1 + app.erf_v686(abs(p_z) / sqrt(2::numeric)))))
  ));
$$;
revoke all on function app.normal_two_tailed_p_v686(numeric) from public, anon, authenticated;
grant execute on function app.normal_two_tailed_p_v686(numeric) to authenticated, service_role;

create or replace function app.two_prop_p_value_v686(p_x1 bigint, p_n1 bigint, p_x2 bigint, p_n2 bigint)
returns numeric
language sql immutable
set search_path to 'pg_catalog', 'app', 'pg_temp'
as $$
  -- Classical (unpooled-arm, pooled-variance) two-proportion z-test, two-tailed:
  --   p1=x1/n1, p2=x2/n2, pooled=(x1+x2)/(n1+n2)
  --   se = sqrt(pooled*(1-pooled)*(1/n1+1/n2)),  z = (p1-p2)/se,  p = 2*(1-Phi(|z|))
  -- se=0 (both arms at the same all-0 or all-1 extreme) means p1=p2 exactly -> p=1; any other
  -- se=0 case cannot arise (it would require n1 or n2 = 0, which callers must not pass).
  with parts as (
    select p_x1::numeric / p_n1 as p1, p_x2::numeric / p_n2 as p2,
           (p_x1 + p_x2)::numeric / (p_n1 + p_n2) as pooled
  ),
  se as (
    select p1, p2, sqrt(pooled * (1 - pooled) * (1.0 / p_n1 + 1.0 / p_n2)) as s from parts
  )
  select case when s = 0 then (case when p1 = p2 then 1.0::numeric else 0.0::numeric end)
              else app.normal_two_tailed_p_v686((p1 - p2) / s)
         end
  from se;
$$;
revoke all on function app.two_prop_p_value_v686(bigint,bigint,bigint,bigint) from public, anon, authenticated;
grant execute on function app.two_prop_p_value_v686(bigint,bigint,bigint,bigint) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 1 · The discovery engine itself.
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_discovery_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_result jsonb;
  v_train_to date;
  v_holdout_from date;
  v_floor constant integer := 5;   -- app.subgroup_evidence_v1's own default; never overridden.
  v_q constant numeric := 0.10;
  v_use_branch boolean;
  v_prior_from date;
  v_prior_to date;
  v_prior_available boolean;
  v_prior_pct numeric;
  v_current_pct numeric;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  v_train_to := p_from + ((p_to - p_from) / 2);
  v_holdout_from := v_train_to + 1;
  if v_holdout_from > p_to then
    raise exception 'window too short to split into train and holdout halves'
      using errcode = '22023';
  end if;

  select count(*) > 1 into v_use_branch
    from public.branches br where br.business_id = p_business and br.active;
  v_use_branch := coalesce(v_use_branch, false) and p_branch is null;

  v_prior_from := (p_from - interval '1 year')::date;
  v_prior_to := (p_to - interval '1 year')::date;

  with

  -- ---------------------------------------------------------------------------------------
  -- Per-half anchor population: one row per (half, client) with everything a dimension needs.
  -- ---------------------------------------------------------------------------------------
  halves as (
    select 'train'::text as half, p_from as h_from, v_train_to as h_to
    union all
    select 'holdout', v_holdout_from, p_to
  ),
  anchors as (
    select h.half, s.client_id,
           min((s.occurred_at at time zone 'Asia/Singapore')::date) as anchor_date
      from halves h
      join public.sales s on s.business_id = p_business
      cross join lateral app.analytics_sale_class_v1(s) sc
     where (p_branch is null or s.branch_id = p_branch)
       and sc.include_visit
       and not sc.is_synthetic_client
       and s.client_id is not null
       and (s.occurred_at at time zone 'Asia/Singapore')::date between h.h_from and h.h_to
     group by h.half, s.client_id
  ),
  anchor_sale as (
    -- the specific sale row for that anchor date (min id breaks a same-day tie deterministically).
    select a.half, a.client_id, a.anchor_date,
           (select s.id from public.sales s
              cross join lateral app.analytics_sale_class_v1(s) sc
             where s.business_id = p_business and s.client_id = a.client_id
               and (p_branch is null or s.branch_id = p_branch)
               and sc.include_visit and not sc.is_synthetic_client
               and (s.occurred_at at time zone 'Asia/Singapore')::date = a.anchor_date
             order by s.id asc limit 1) as anchor_sale_id
      from anchors a
  ),
  population as (
    select ans.half, ans.client_id, ans.anchor_date, s.branch_id,
           extract(isodow from ans.anchor_date)::int as dow,
           c.first_acquired_via as acquisition,
           dem->>'age_band' as age_band,
           dem->>'gender' as gender,
           coalesce(tn.parent_key, tn.node_key) as l2_key,
           ((current_date - ans.anchor_date) >= 30) as mature,
           exists (
             select 1 from public.sales s2
             cross join lateral app.analytics_sale_class_v1(s2) sc2
            where s2.business_id = p_business and s2.client_id = ans.client_id
              and (p_branch is null or s2.branch_id = p_branch)
              and sc2.include_visit and not sc2.is_synthetic_client
              and (s2.occurred_at at time zone 'Asia/Singapore')::date > ans.anchor_date
              and (s2.occurred_at at time zone 'Asia/Singapore')::date <= ans.anchor_date + 30
           ) as returned
      from anchor_sale ans
      join public.sales s on s.id = ans.anchor_sale_id
      join public.clients c on c.id = ans.client_id
      cross join lateral (select app.customer_demographics_core_v674(p_business, ans.client_id) as dem) d
      left join lateral (
        select en.node_key
          from public.sale_items si
          cross join lateral app.ci_effective_node_v650(si) en
         where si.sale_id = ans.anchor_sale_id
         order by si.line_cents desc limit 1
      ) cat on true
      left join public.taxonomy_nodes tn on tn.version_no = 1 and tn.node_key = cat.node_key
  ),

  -- ---------------------------------------------------------------------------------------
  -- Fan each population row out to every dimension it classifies into.
  -- ---------------------------------------------------------------------------------------
  dim_rows as (
    select half, 'weekday'::text as dimension,
           case dow when 1 then 'Monday' when 2 then 'Tuesday' when 3 then 'Wednesday'
                    when 4 then 'Thursday' when 5 then 'Friday' when 6 then 'Saturday'
                    else 'Sunday' end as group_key,
           mature, returned
      from population
    union all
    select half, 'age_gender', age_band || '_' || gender, mature, returned
      from population where age_band is not null and gender is not null
    union all
    select half, 'category_node', l2_key, mature, returned
      from population where l2_key is not null
    union all
    select half, 'acquisition_source', acquisition, mature, returned
      from population where acquisition is not null
    union all
    select half, 'branch', branch_id::text, mature, returned
      from population where v_use_branch and branch_id is not null
  ),
  cells as (
    select half, dimension, group_key,
           count(*) filter (where mature) as n,
           count(*) filter (where mature and returned) as numer
      from dim_rows
     group by half, dimension, group_key
  ),
  train_cells as (select * from cells where half = 'train'),
  holdout_cells as (select * from cells where half = 'holdout'),
  train_totals as (
    select dimension, sum(n) as total_n, sum(numer) as total_numer
      from train_cells group by dimension
  ),
  holdout_totals as (
    select dimension, sum(n) as total_n, sum(numer) as total_numer
      from holdout_cells group by dimension
  ),

  -- ---------------------------------------------------------------------------------------
  -- Step 3-4: examined hypotheses, candidates, BH.
  -- ---------------------------------------------------------------------------------------
  examined as (
    select tc.dimension, tc.group_key, tc.n, tc.numer,
           (tt.total_n - tc.n)::bigint as rest_n, (tt.total_numer - tc.numer)::bigint as rest_numer
      from train_cells tc
      join train_totals tt on tt.dimension = tc.dimension
     where tc.n >= v_floor
       and (tt.total_n - tc.n) > 0
  ),
  evid as (
    select e.*,
           app.evidence_block_v1(
             'discovery_group', 'discovery_rest', p_from, v_train_to,
             e.n::integer, e.numer::integer, e.rest_n::integer, e.rest_numer::integer,
             'group vs all other groups in the same dimension (train half)',
             'strong_pattern', array[]::text[], null, 1) as block,
           app.two_prop_p_value_v686(e.numer, e.n, e.rest_numer, e.rest_n) as p_value
      from examined e
  ),
  scored as (
    select *,
           (block->'difference'->>'absolute_pp')::numeric as diff_pp,
           (block->'difference'->'confidence_95_pp'->>0)::numeric as ci_lo,
           (block->'difference'->'confidence_95_pp'->>1)::numeric as ci_hi
      from evid
  ),
  candidates as (
    select * from scored
     where abs(diff_pp) >= 10
       and not (ci_lo <= 0 and ci_hi >= 0)
  ),
  ranked as (
    select *, row_number() over (order by p_value asc, dimension, group_key) as p_rank,
           count(*) over () as m
      from candidates
  ),
  bh as (
    select *, (p_value <= (p_rank::numeric / m) * v_q) as clears_own_rank
      from ranked
  ),
  bh_cutoff as (
    select coalesce(max(p_rank) filter (where clears_own_rank), 0) as k from bh
  ),
  survivors as (
    select bh.* from bh, bh_cutoff where bh.p_rank <= bh_cutoff.k
  ),

  -- ---------------------------------------------------------------------------------------
  -- Step 5: holdout replication for each BH survivor.
  -- ---------------------------------------------------------------------------------------
  survivor_eval as (
    select sv.*,
           hc.n as h_n, hc.numer as h_numer,
           ht.total_n as h_total_n, ht.total_numer as h_total_numer
      from survivors sv
      left join holdout_cells hc on hc.dimension = sv.dimension and hc.group_key = sv.group_key
      left join holdout_totals ht on ht.dimension = sv.dimension
  ),
  survivor_final as (
    select *,
           (h_total_n - coalesce(h_n, 0)) as h_rest_n,
           (h_total_numer - coalesce(h_numer, 0)) as h_rest_numer
      from survivor_eval
  ),
  survivor_verdict as (
    select *,
           case when h_n is not null and h_n >= v_floor and h_rest_n > 0
                then round(100.0 * h_numer / h_n - 100.0 * h_rest_numer / h_rest_n, 1)
                else null end as h_diff_pp
      from survivor_final
  ),
  survivor_replicated as (
    select *,
           (h_diff_pp is not null and sign(h_diff_pp) = sign(diff_pp) and sign(diff_pp) <> 0)
             as replicated
      from survivor_verdict
  ),

  -- ---------------------------------------------------------------------------------------
  -- Step 6: deterioration -- independent of the candidate/BH pipeline (see header).
  -- ---------------------------------------------------------------------------------------
  both_floor as (
    select tc.dimension, tc.group_key,
           tc.n as train_n, tc.numer as train_numer,
           hcell.n as holdout_n, hcell.numer as holdout_numer
      from train_cells tc
      join holdout_cells hcell on hcell.dimension = tc.dimension and hcell.group_key = tc.group_key
     where tc.n >= v_floor and hcell.n >= v_floor
  ),
  det_evid as (
    select bf.*,
           app.evidence_block_v1(
             'discovery_group_train', 'discovery_group_holdout', p_from, p_to,
             bf.train_n::integer, bf.train_numer::integer,
             bf.holdout_n::integer, bf.holdout_numer::integer,
             'same group, train half vs holdout half', 'strong_pattern', array[]::text[], null, 1
           ) as block
      from both_floor bf
  ),
  det_scored as (
    select *,
           round(100.0 * train_numer / train_n, 1) as train_pct,
           round(100.0 * holdout_numer / holdout_n, 1) as holdout_pct,
           (block->'difference'->'confidence_95_pp'->>0)::numeric as ci_lo,
           (block->'difference'->'confidence_95_pp'->>1)::numeric as ci_hi
      from det_evid
  ),
  deteriorating_rows as (
    select * from det_scored
     where (train_pct - holdout_pct) >= 10
       and not (ci_lo <= 0 and ci_hi >= 0)
  ),

  -- ---------------------------------------------------------------------------------------
  -- Missingness (headline = whole period, not split by half) and prior-year seasonality.
  -- ---------------------------------------------------------------------------------------
  headline as (
    select count(*) filter (where mature) as n, count(*) filter (where mature and returned) as numer
      from population
  ),
  anon_sales as (
    select count(*) as n
      from public.sales s
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and sc.include_visit and not sc.is_synthetic_client
       and s.client_id is null
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  ident_sales as (
    select count(*) as n
      from public.sales s
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and sc.include_visit and not sc.is_synthetic_client
       and s.client_id is not null
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  prior_anchors as (
    select s.client_id, min((s.occurred_at at time zone 'Asia/Singapore')::date) as anchor_date
      from public.sales s
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and sc.include_visit and not sc.is_synthetic_client
       and s.client_id is not null
       and (s.occurred_at at time zone 'Asia/Singapore')::date between v_prior_from and v_prior_to
     group by s.client_id
  ),
  prior_pop as (
    select pa.client_id, pa.anchor_date,
           ((current_date - pa.anchor_date) >= 30) as mature,
           exists (
             select 1 from public.sales s2
             cross join lateral app.analytics_sale_class_v1(s2) sc2
            where s2.business_id = p_business and s2.client_id = pa.client_id
              and (p_branch is null or s2.branch_id = p_branch)
              and sc2.include_visit and not sc2.is_synthetic_client
              and (s2.occurred_at at time zone 'Asia/Singapore')::date > pa.anchor_date
              and (s2.occurred_at at time zone 'Asia/Singapore')::date <= pa.anchor_date + 30
           ) as returned
      from prior_anchors pa
  ),
  prior_agg as (
    select count(*) filter (where mature) as n, count(*) filter (where mature and returned) as numer
      from prior_pop
  )

  select
    jsonb_build_object(
      'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                   'from', p_from, 'to', p_to),
      'period', jsonb_build_object('from', p_from, 'to', p_to),
      'train', jsonb_build_object('from', p_from, 'to', v_train_to),
      'holdout', jsonb_build_object('from', v_holdout_from, 'to', p_to),
      'metric', 'return_within_30_days_rate_per_first_purchase_in_window',
      'segment_dimensions',
        (select jsonb_agg(d) from unnest(
           array['weekday','age_gender','category_node','acquisition_source']
           || case when v_use_branch then array['branch'] else array[]::text[] end) d),

      'discoveries', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'dimension', sr.dimension, 'group', sr.group_key,
                 'train', jsonb_build_object('n', sr.n, 'rate', round(100.0*sr.numer/sr.n,1)),
                 'holdout', jsonb_build_object('n', sr.h_n, 'rate',
                              case when sr.h_n > 0 then round(100.0*sr.h_numer/sr.h_n,1) else null end),
                 'diff_pp', sr.diff_pp, 'interval', sr.block->'difference'->'confidence_95_pp',
                 'p_value', sr.p_value, 'bh_rank', sr.p_rank, 'replicated', true,
                 'evidence_class', 'ASSOCIATION')
               order by sr.dimension, sr.group_key)
          from survivor_replicated sr where sr.replicated), '[]'::jsonb),

      'not_replicated', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'dimension', sr.dimension, 'group', sr.group_key,
                 'train', jsonb_build_object('n', sr.n, 'rate', round(100.0*sr.numer/sr.n,1)),
                 'holdout', jsonb_build_object('n', sr.h_n, 'rate',
                              case when coalesce(sr.h_n,0) > 0 then round(100.0*sr.h_numer/sr.h_n,1) else null end),
                 'diff_pp', sr.diff_pp, 'interval', sr.block->'difference'->'confidence_95_pp',
                 'p_value', sr.p_value, 'bh_rank', sr.p_rank, 'replicated', false,
                 'evidence_class', 'ASSOCIATION')
               order by sr.dimension, sr.group_key)
          from survivor_replicated sr where not sr.replicated), '[]'::jsonb),

      'deteriorating', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'dimension', dr.dimension, 'group', dr.group_key,
                 'train', jsonb_build_object('n', dr.train_n, 'rate', dr.train_pct),
                 'holdout', jsonb_build_object('n', dr.holdout_n, 'rate', dr.holdout_pct),
                 'diff_pp', round(dr.train_pct - dr.holdout_pct, 1),
                 'interval', dr.block->'difference'->'confidence_95_pp')
               order by dr.dimension, dr.group_key)
          from deteriorating_rows dr), '[]'::jsonb),

      'false_discovery_control', jsonb_build_object(
        'hypotheses_examined', (select count(*) from examined),
        'candidates_pre_bh', (select count(*) from candidates),
        'survivors_post_bh', (select count(*) from survivors),
        'q', v_q,
        'method', 'two-proportion z-test p-value per candidate (group vs rest, train half); '
          'Benjamini-Hochberg step-up at q=0.10 over the candidate p-values only'),
      'comparisons', app.comparisons_note_v1(
        (select count(*) from examined)::integer,
        (select count(*) from survivor_replicated where replicated)::integer),

      'seasonality', jsonb_build_object(
        'method', 'same_period_prior_year',
        'available',
          (select (app.metric_observed_since_v1('ci_discovery', p_business) <= v_prior_from::timestamptz)
                  and coalesce((select n from prior_agg), 0) > 0),
        'prior_period', jsonb_build_object('from', v_prior_from, 'to', v_prior_to),
        'current_pct', (select case when h.n > 0 then round(100.0*h.numer/h.n,1) else null end from headline h),
        'prior_year_pct', (
          select case
            when (app.metric_observed_since_v1('ci_discovery', p_business) <= v_prior_from::timestamptz)
                 and coalesce(pa.n,0) > 0 and pa.n > 0
            then round(100.0*pa.numer/pa.n, 1) else null end
          from prior_agg pa),
        'note', 'Compares the same metric for the identical calendar window one year earlier; '
          'unavailable when the metric was not yet observed that far back or no qualifying '
          'customers exist in that prior window.'),

      'missingness', jsonb_build_object(
        'anonymous_sales', (select n from anon_sales),
        'identified_sales', (select n from ident_sales),
        'headline', jsonb_build_object(
          'numerator', (select numer from headline), 'denominator', (select n from headline)),
        'bounds', jsonb_build_object(
          'metric_if_anonymous_all_returned',
            (select case when (h.n + a.n) > 0
                          then round(100.0*(h.numer + a.n)/(h.n + a.n), 1) else null end
               from headline h, anon_sales a),
          'metric_if_anonymous_none_returned',
            (select case when (h.n + a.n) > 0
                          then round(100.0*h.numer/(h.n + a.n), 1) else null end
               from headline h, anon_sales a)),
        'note', 'Anonymous (no client_id) qualifying sales cannot be scored as returned or not; '
          'the bracket shows the headline rate under the two extreme assumptions about them.'),

      'time_basis', 'sale_occurred_at',
      'limitation', 'segments are predefined dimensions; discoveries are associations validated '
        'on later data, not causes',
      'observed_since', app.metric_observed_since_v1('ci_discovery', p_business)
    )
  into v_result;

  return v_result;
end;
$function$;
revoke all on function public.get_ci_discovery_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_discovery_v1(uuid,date,date,uuid) to authenticated, service_role;

commit;
