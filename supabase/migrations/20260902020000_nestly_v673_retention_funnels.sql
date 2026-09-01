-- NESTLY v673 — lifecycle funnel + fixed-window retention (Customer Intelligence, phase CI-A).
--
-- Closes acceptance checks 41-44 (docs/qa/CI-ACCEPTANCE-VERDICT-2026-09-02.md, phase CI-A row:
-- "Retention funnels (1st->2nd->3rd, maturity-adjusted fixed windows)"). Two new readers, both
-- following the conventions frozen for every CI-A/CI-B reader:
--   - app.ci_access_gate_v667(p_business, p_branch) first
--     (db/migrations/20260901_nestly_v667_ci_access_boundaries.sql)
--   - the CI-B statistical authority embedded, not reimplemented: app.subgroup_evidence_v1,
--     app.rate_block_v1 (db/migrations/20260902_nestly_v672_statistical_authority.sql, contract
--     frozen in docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md)
--   - "time_basis":"sale_occurred_at", Asia/Singapore date bucketing, app.metric_observed_since_v1
--   - reversed sales out, synthetic clients out, counts_as_visit respected — via the same
--     three-part sale filter every other v650/v667 reader uses (reversal_of is null; no row
--     reverses it; the client is not synthetic)
-- Proof: db/tests/executed/v673_corpus_funnels.sql. No v106 reporting-contract join is used —
-- both readers filter public.sales directly, per this phase's own instruction that the
-- reporting-contract machinery is unnecessary here and raw sales filters are sufficient.
--
-- POPULATION (both readers). A client's "first visit" is the earliest sale that is
-- counts_as_visit=true, is not itself a reversal row (reversal_of is null), and was not itself
-- later reversed (no sales row exists with reversal_of = this sale's id) — exactly the
-- three-part filter every other v650/v667 CI reader already applies, with the client-level
-- is_synthetic exclusion added on top. A JUDGEMENT CALL worth recording: this means a reversed
-- FIRST visit is not special-cased anywhere. The reversed sale never enters the "first visit"
-- candidate set at all, so the client's counted first visit is transparently whichever real,
-- unreversed sale comes next — the correction falls out of the ordinary exclusion filter, not
-- from bespoke reversal-aware logic. The corpus fixture proves both halves: the reversed sale
-- creates no phantom population entry at its own (wrong) date, and the corrected date is what
-- the population actually uses.
--
-- get_ci_funnel_conversion_v1(p_business, p_from, p_to, p_window_days default 60, p_branch
-- default null) — 1st->2nd->3rd visit conversion, maturity-gated.
--   Population: non-synthetic clients whose first visit falls in [p_from,p_to] (bucketed
--   Asia/Singapore); if p_branch is given, the first visit itself must be on that branch (a
--   client whose first visit was elsewhere is not "this branch's" first-time customer, even if
--   they later visited the given branch).
--
--   MATURITY. A first visit only enters the 1st->2nd calculation once its p_window_days has
--   fully elapsed (first_visit_date + p_window_days <= today, SGT) — otherwise it is still "in
--   flight" and is reported under immature.first_stage: counted, never silently dropped, never
--   used to compute a rate. The 2nd->3rd stage applies the identical rule to the second visit
--   (immature.second_stage). JUDGEMENT CALL: maturity gates ENTRY to a stage, not merely
--   non-conversion — a customer who happens to convert to a second visit quickly, before their
--   own first-stage window has fully elapsed, is still classified immature and excluded from
--   stage_1_to_2 entirely, exactly like a customer who has not converted yet. This also makes
--   stage_2_to_3's mature population a subset of stage_1_to_2's mature population by
--   construction: second_visit_date >= first_visit_date, so second_visit_date + window >=
--   first_visit_date + window, so second-stage maturity always implies first-stage maturity.
--
--   evidence is app.subgroup_evidence_v1 applied to the MATURE 1st->2nd population (the actual
--   denominator of stage_1_to_2, not the full population including immature members) — evidence
--   about a rate should be sized by the population that rate was computed over.
--
--   bottleneck names whichever stage has the strictly LOWER conversion pct
--   ('first_to_second' / 'second_to_third'), and is null when: either pct is null (a zero
--   denominator), OR evidence.status = 'insufficient' (no diagnosis from thin data, per phase
--   CI-A's own rule — the counts and rates themselves are never withheld, only the diagnosis),
--   OR the two pcts are exactly equal (JUDGEMENT CALL: a tie has no unambiguously weaker stage).
--
-- get_ci_retention_windows_v1(p_business, p_from, p_to, p_branch default null) — fixed-horizon
-- (30/60/90/180/365-day) cohort retention.
--   Cohorts are calendar MONTHS of first visit, restricted to first visits in [p_from,p_to] (and
--   to p_branch's first-time customers, if given), same population rule as the funnel reader.
--
--   CENSORING. A (cohort, horizon) CELL — not any individual customer's own first-visit date —
--   is what gets matured or censored: it is reported only once the horizon has fully elapsed for
--   the LAST DAY of the cohort's calendar month (cohort_month_last_day + horizon <= today, SGT),
--   so every member of a cohort has had the same full observation window regardless of which day
--   in the month they actually first visited. A cell that has not cleared that bar is named
--   explicitly in immature_cells ({'month','horizon'}) and omitted from that cohort's 'windows'
--   map — visible censoring, per check 44, not silent absence. This month-end rule is
--   deliberately more conservative than gating on each customer's own date: a customer near the
--   start of a 31-day month can make a cell wait up to 30 extra days before it is allowed to
--   report at all. The corpus fixture seeds a cohort in exactly that ambiguous band on purpose
--   and computes the expected outcome from the same month-end formula, rather than picking a
--   date that dodges the boundary.
--
--   A reported cell's rate_block denominator is the cohort's full size (cohort_n); the numerator
--   is customers with ANY qualifying visit strictly after their own first visit and within the
--   horizon of it. evidence is per-cohort, sized by cohort_n.
--
-- Both functions are security definer, granted authenticated + service_role only, revoked from
-- public/anon, matching v667's style exactly.

begin;

create or replace function public.get_ci_funnel_conversion_v1(
  p_business uuid, p_from date, p_to date, p_window_days integer default 60, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_mature_first integer;
  v_immature_first integer;
  v_converted_second_mature integer;
  v_mature_second integer;
  v_immature_second integer;
  v_converted_third integer;
  v_stage_1_to_2 jsonb;
  v_stage_2_to_3 jsonb;
  v_evidence jsonb;
  v_bottleneck text;
  v_pct1 numeric;
  v_pct2 numeric;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);

  with eligible_sales as (
    select s.id, s.client_id, s.branch_id,
           (s.occurred_at at time zone 'Asia/Singapore')::date as visit_date
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and coalesce(s.counts_as_visit, false)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and not coalesce(c.is_synthetic, false)
  ),
  first_visit as (
    select client_id, min(visit_date) as first_visit_date
      from eligible_sales
     group by client_id
  ),
  first_visit_branch as (
    select distinct on (es.client_id) es.client_id, es.branch_id
      from eligible_sales es
      join first_visit fv
        on fv.client_id = es.client_id and fv.first_visit_date = es.visit_date
     order by es.client_id, es.id
  ),
  population as (
    select fv.client_id, fv.first_visit_date, fvb.branch_id as first_branch
      from first_visit fv
      join first_visit_branch fvb on fvb.client_id = fv.client_id
     where fv.first_visit_date between p_from and p_to
       and (p_branch is null or fvb.branch_id = p_branch)
  ),
  second_visit as (
    select p.client_id, p.first_visit_date, min(es.visit_date) as second_visit_date
      from population p
      join eligible_sales es
        on es.client_id = p.client_id and es.visit_date > p.first_visit_date
     group by p.client_id, p.first_visit_date
  ),
  converted_second as (
    select client_id, first_visit_date, second_visit_date
      from second_visit
     where second_visit_date <= first_visit_date + p_window_days
  ),
  third_visit as (
    select cs.client_id, cs.second_visit_date, min(es.visit_date) as third_visit_date
      from converted_second cs
      join eligible_sales es
        on es.client_id = cs.client_id and es.visit_date > cs.second_visit_date
     group by cs.client_id, cs.second_visit_date
  ),
  converted_third as (
    select client_id
      from third_visit
     where third_visit_date <= second_visit_date + p_window_days
  )
  select
      count(*) filter (where p.first_visit_date + p_window_days <= v_today),
      count(*) filter (where p.first_visit_date + p_window_days > v_today),
      count(*) filter (where p.first_visit_date + p_window_days <= v_today
                        and cs.client_id is not null),
      count(*) filter (where cs.client_id is not null
                        and cs.second_visit_date + p_window_days <= v_today),
      count(*) filter (where cs.client_id is not null
                        and cs.second_visit_date + p_window_days > v_today),
      count(*) filter (where cs.client_id is not null
                        and cs.second_visit_date + p_window_days <= v_today
                        and ct.client_id is not null)
    into v_mature_first, v_immature_first, v_converted_second_mature,
         v_mature_second, v_immature_second, v_converted_third
    from population p
    left join converted_second cs on cs.client_id = p.client_id
    left join converted_third ct on ct.client_id = cs.client_id;

  v_evidence := app.subgroup_evidence_v1(v_mature_first);
  v_stage_1_to_2 := app.rate_block_v1(v_converted_second_mature, v_mature_first);
  v_stage_2_to_3 := app.rate_block_v1(v_converted_third, v_mature_second);

  v_pct1 := (v_stage_1_to_2->>'pct')::numeric;
  v_pct2 := (v_stage_2_to_3->>'pct')::numeric;

  if v_evidence->>'status' = 'insufficient' or v_pct1 is null or v_pct2 is null then
    v_bottleneck := null;
  elsif v_pct1 < v_pct2 then
    v_bottleneck := 'first_to_second';
  elsif v_pct2 < v_pct1 then
    v_bottleneck := 'second_to_third';
  else
    v_bottleneck := null;
  end if;

  return jsonb_build_object(
    'window_days', p_window_days,
    'time_basis', 'sale_occurred_at',
    'stage_1_to_2', v_stage_1_to_2,
    'stage_2_to_3', v_stage_2_to_3,
    'immature', jsonb_build_object(
      'first_stage', v_immature_first, 'second_stage', v_immature_second),
    'bottleneck', v_bottleneck,
    'evidence', v_evidence,
    'observed_since', app.metric_observed_since_v1('lifecycle_funnel', p_business));
end;
$$;
revoke all on function public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid) from public, anon;
grant execute on function public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid) to authenticated, service_role;

create or replace function public.get_ci_retention_windows_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_horizons integer[] := array[30,60,90,180,365];
  v_cohorts jsonb;
  v_immature jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);

  with eligible_sales as (
    select s.id, s.client_id, s.branch_id,
           (s.occurred_at at time zone 'Asia/Singapore')::date as visit_date
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and coalesce(s.counts_as_visit, false)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and not coalesce(c.is_synthetic, false)
  ),
  first_visit as (
    select client_id, min(visit_date) as first_visit_date
      from eligible_sales
     group by client_id
  ),
  first_visit_branch as (
    select distinct on (es.client_id) es.client_id, es.branch_id
      from eligible_sales es
      join first_visit fv
        on fv.client_id = es.client_id and fv.first_visit_date = es.visit_date
     order by es.client_id, es.id
  ),
  population as (
    select fv.client_id, fv.first_visit_date,
           date_trunc('month', fv.first_visit_date)::date as cohort_month
      from first_visit fv
      join first_visit_branch fvb on fvb.client_id = fv.client_id
     where fv.first_visit_date between p_from and p_to
       and (p_branch is null or fvb.branch_id = p_branch)
  ),
  cohort_sizes as (
    select cohort_month, count(*) as n
      from population
     group by cohort_month
  ),
  cohort_bounds as (
    select cohort_month, (cohort_month + interval '1 month - 1 day')::date as month_last_day
      from cohort_sizes
  ),
  cells as (
    select cs.cohort_month, cs.n, h.horizon,
           (cmb.month_last_day + h.horizon) <= v_today as is_mature,
           (select count(distinct p2.client_id)
              from population p2
              join eligible_sales es2 on es2.client_id = p2.client_id
             where p2.cohort_month = cs.cohort_month
               and es2.visit_date > p2.first_visit_date
               and es2.visit_date <= p2.first_visit_date + h.horizon) as returned_n
      from cohort_sizes cs
      join cohort_bounds cmb on cmb.cohort_month = cs.cohort_month
      cross join unnest(v_horizons) as h(horizon)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'month', to_char(x.cohort_month, 'YYYY-MM'),
           'n', x.n,
           'evidence', app.subgroup_evidence_v1(x.n::int),
           'windows', x.windows)
         order by x.cohort_month), '[]'::jsonb)
    into v_cohorts
    from (
      select cohort_month, n,
             coalesce(jsonb_object_agg(horizon::text, app.rate_block_v1(returned_n, n))
                      filter (where is_mature), '{}'::jsonb) as windows
        from cells
       group by cohort_month, n
    ) x;

  with eligible_sales as (
    select s.id, s.client_id, s.branch_id,
           (s.occurred_at at time zone 'Asia/Singapore')::date as visit_date
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and coalesce(s.counts_as_visit, false)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and not coalesce(c.is_synthetic, false)
  ),
  first_visit as (
    select client_id, min(visit_date) as first_visit_date
      from eligible_sales
     group by client_id
  ),
  first_visit_branch as (
    select distinct on (es.client_id) es.client_id, es.branch_id
      from eligible_sales es
      join first_visit fv
        on fv.client_id = es.client_id and fv.first_visit_date = es.visit_date
     order by es.client_id, es.id
  ),
  population as (
    select fv.client_id, fv.first_visit_date,
           date_trunc('month', fv.first_visit_date)::date as cohort_month
      from first_visit fv
      join first_visit_branch fvb on fvb.client_id = fv.client_id
     where fv.first_visit_date between p_from and p_to
       and (p_branch is null or fvb.branch_id = p_branch)
  ),
  cohort_sizes as (
    select cohort_month, count(*) as n
      from population
     group by cohort_month
  ),
  cohort_bounds as (
    select cohort_month, (cohort_month + interval '1 month - 1 day')::date as month_last_day
      from cohort_sizes
  ),
  cells as (
    select cs.cohort_month, h.horizon,
           (cmb.month_last_day + h.horizon) <= v_today as is_mature
      from cohort_sizes cs
      join cohort_bounds cmb on cmb.cohort_month = cs.cohort_month
      cross join unnest(v_horizons) as h(horizon)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'month', to_char(cohort_month, 'YYYY-MM'), 'horizon', horizon)
         order by cohort_month, horizon), '[]'::jsonb)
    into v_immature
    from cells
   where not is_mature;

  return jsonb_build_object(
    'horizons', to_jsonb(v_horizons),
    'cohorts', v_cohorts,
    'immature_cells', v_immature,
    'time_basis', 'sale_occurred_at',
    'observed_since', app.metric_observed_since_v1('retention_windows', p_business));
end;
$$;
revoke all on function public.get_ci_retention_windows_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_retention_windows_v1(uuid,date,date,uuid) to authenticated, service_role;

commit;
