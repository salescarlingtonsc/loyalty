-- NESTLY v693 -- exclusion completeness (missing_demographics, overlapping_campaigns) and typed
-- evidence-class verdicts on the four CI readers this session owns.
--
-- Reads docs/qa/CI-CORPUS-FIXTURE-GUIDE.md, docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md,
-- db/migrations/20260920_nestly_v680_ci_envelope.sql (app.ci_envelope_v680,
-- app.ci_exclusion_counts_v680, and the re-emitted get_ci_funnel_conversion_v1,
-- get_ci_retention_windows_v1, get_ci_daypart_v1, get_ci_demographic_cohort_v1 bodies -- this
-- migration is an extract-and-diff replace-equality edit of those bodies, per the v668
-- convention, not a rewrite). Proven by
-- db/tests/executed/v693_corpus_exclusions_verdicts.sql.
--
-- Siblings are concurrently re-emitting get_ci_opportunities_v1 (v688),
-- app.customer_cadence_*/app.v179_business_insights (v690), get_ci_category_mix_v1 /
-- get_ci_service_intelligence_v1 / get_ci_discovery_v1 (v691) and get_customer_lifecycle_v107
-- (v692). None of those readers, or any table/function they own, is touched here. This migration
-- only touches the two SHARED authority functions (app.ci_exclusion_counts_v680,
-- app.ci_envelope_v680 -- same signatures, CREATE OR REPLACE, no drop needed) and the four
-- readers this session owns (get_ci_funnel_conversion_v1, get_ci_retention_windows_v1,
-- get_ci_daypart_v1, get_ci_demographic_cohort_v1 -- also same signatures as v680 left them).
--
-- ---------------------------------------------------------------------------------------------
-- 1 . EXCLUSION COMPLETENESS -- two new keys on app.ci_exclusion_counts_v680
-- ---------------------------------------------------------------------------------------------
-- missing_demographics: identified (client_id not null), non-synthetic customers with a
-- QUALIFYING sale in the window -- unreversed, created_at <= p_as_of, and
-- counts_as_revenue OR counts_as_visit, the same "qualifying" shape get_ci_demographics_v1
-- already uses for its own population -- whose app.customer_demographics_core_v674 does not
-- resolve to BOTH a non-null age_band AND a non-null gender (a synthetic client is never
-- "identified" for this purpose and is already counted separately as synthetic_clients).
--
-- overlapping_campaigns: customers who received sends attributed to >= 2 DISTINCT campaigns
-- (distinct (campaign_kind, campaign_ref_id) pairs, per campaign_send_records_v255's own
-- identity -- see its recipient unique index) within any 14-day span, where both sends'
-- occurred_at date falls inside [p_from, p_to]. campaign_send_records_v255 carries no branch_id
-- (marketing sends are not branch-scoped in this schema, unlike sales), so p_branch does not
-- narrow this one key -- a disclosed limitation, the same shape as v680's own package-cohort
-- limitation note. occurred_at doubles as this table's own "recorded at" (it is set at insert
-- time, default now(), and the table is append-only per its immutable-guard trigger), so it is
-- gated on p_as_of directly rather than needing a separate created_at.
--
-- Both new counts default to 0 via the same coalesce(..., 0) pattern as the existing three, so
-- the key is ALWAYS a JSON number, never absent, matching check 16.
--
-- ---------------------------------------------------------------------------------------------
-- 2 . INHERITANCE -- app.ci_envelope_v680 must forward the new keys, not just the original three
-- ---------------------------------------------------------------------------------------------
-- app.ci_envelope_v680's v_excl construction previously whitelisted exactly three keys out of
-- whatever p_exclusions carried -- silently dropping anything else a caller passed in. Every
-- re-emitted CI reader (including ones this migration never touches: get_ci_demographics_v1,
-- get_ci_service_intelligence_v1, get_ci_package_intelligence_v1, get_ci_category_mix_v1,
-- get_ci_category_customers_v1, get_ci_acquisition_v1, get_ci_opportunities_v1 and siblings'
-- future readers) calls `app.ci_exclusion_counts_v680(...)` and passes the result straight into
-- `app.ci_envelope_v680(...)` as p_exclusions -- so extending the whitelist here is the ONLY
-- change needed for every one of those readers to start emitting missing_demographics and
-- overlapping_campaigns too, with no edit to any of their own migration files. This is exactly
-- the mechanism CI-STAT-AUTHORITY-CONTRACT.md's "one authority" discipline is for: a single
-- shared function upgrade propagates to every consumer. Proven directly in the fixture by calling
-- three readers this migration does NOT touch (get_ci_demographics_v1 among them) and asserting
-- the two new keys appear with the exact expected counts.
--
-- ---------------------------------------------------------------------------------------------
-- 3 . TYPED VERDICTS -- vocabulary restricted to DIRECT_FACT | ASSOCIATION, CAUSAL never
-- ---------------------------------------------------------------------------------------------
-- get_ci_funnel_conversion_v1: 'bottleneck_evidence_class':'DIRECT_FACT' is added ONLY when a
-- bottleneck is named (the key is omitted entirely, not emitted as null, when 'bottleneck' is
-- null) -- naming which stage converts worse is a direct read of the two observed stage rates,
-- not a comparison across an external axis.
--
-- get_ci_retention_windows_v1: every cohort cell in the 'cohorts' array gains
-- 'evidence_class':'DIRECT_FACT' -- each cell reports one cohort's own observed return rate at
-- one horizon, a direct fact about that cohort, not a comparison to another cohort.
--
-- get_ci_daypart_v1: 'busiest_weekday' gains 'evidence_class':'DIRECT_FACT' (a direct count of
-- visits landing on that weekday). 'most_valuable_weekday' gains
-- 'evidence_class':'ASSOCIATION' plus a 'note' -- revenue-per-visit is only meaningful as a
-- COMPARISON across the seven weekdays (which one ranks highest), so classing it as a direct
-- fact would overstate what a single weekday's number means in isolation.
--
-- ALSO (found in review, not part of the original four-reader typed-verdict list, but the same
-- reader and the same evidence discipline): the 'hours' bucket computed its
-- revenue_per_visit_cents off `h.visits > 0` alone, with no app.subgroup_evidence_v1 floor gate
-- at all -- unlike the sibling 'weekdays' bucket four lines above it, which has always gated on
-- `evidence->>'status' = 'ok'`. A single sale landing in one hour therefore reported a
-- false-precision "average" of one observation. The 'hours' CTE now carries its own
-- app.subgroup_evidence_v1(visits) per hour, and revenue_per_visit_cents is null below the floor
-- (5) exactly like every other rate in this program; visits and revenue_cents are never
-- suppressed, only the derived rate. Proven by db/tests/executed/v693_corpus_exclusions_verdicts.sql's
-- hour-10 (5 visits, rate present) vs hour-14 (1 visit, rate null) pair.
--
-- get_ci_demographic_cohort_v1: 'difference_evidence_class':'ASSOCIATION' plus a
-- 'difference_evidence_note', added unconditionally (regardless of whether 'difference' itself
-- resolved to a number or was withheld for insufficient evidence) -- cohort membership here
-- (age band x gender x category purchase) is observational, never randomised, so the
-- percentage-point gap against the baseline is an association between group membership and
-- return behaviour, never a causal claim about what produced it.
--
-- All four re-emits are byte-faithful otherwise, with the one disclosed exception above (the
-- 'hours' evidence-floor gate in get_ci_daypart_v1): every other existing key, condition and
-- computation is unchanged from the v680 bodies this extracts from.

begin;

-- ---------------------------------------------------------------------------------------------
-- 0 . app.ci_exclusion_counts_v680 -- add missing_demographics, overlapping_campaigns
-- ---------------------------------------------------------------------------------------------
create or replace function app.ci_exclusion_counts_v680(
  p_business uuid, p_branch uuid, p_from date, p_to date, p_as_of timestamptz)
returns jsonb
language sql
stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select jsonb_build_object(
    'reversed_sales', coalesce((
      select count(*) from public.sales s
       where s.business_id = p_business
         and (p_branch is null or s.branch_id = p_branch)
         and s.created_at <= p_as_of
         and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
         and (s.reversal_of is not null
              or exists (select 1 from public.sales r
                          where r.reversal_of = s.id and r.created_at <= p_as_of))
    ), 0),
    'synthetic_clients', coalesce((
      select count(distinct s.client_id) from public.sales s
      join public.clients c on c.id = s.client_id
       where s.business_id = p_business
         and (p_branch is null or s.branch_id = p_branch)
         and s.created_at <= p_as_of
         and coalesce(c.is_synthetic, false)
         and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
    ), 0),
    'anonymous_sales', coalesce((
      select count(*) from public.sales s
       where s.business_id = p_business
         and (p_branch is null or s.branch_id = p_branch)
         and s.created_at <= p_as_of
         and s.client_id is null
         and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
    ), 0),
    'missing_demographics', coalesce((
      with qual as (
        select distinct s.client_id
          from public.sales s
          join public.clients c on c.id = s.client_id
         where s.business_id = p_business
           and (p_branch is null or s.branch_id = p_branch)
           and s.client_id is not null
           and not coalesce(c.is_synthetic, false)
           and s.created_at <= p_as_of
           and s.reversal_of is null
           and not exists (select 1 from public.sales r
                            where r.reversal_of = s.id and r.created_at <= p_as_of)
           and (coalesce(s.counts_as_revenue, false) or coalesce(s.counts_as_visit, false))
           and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
      )
      select count(*)
        from qual
        cross join lateral (
          select app.customer_demographics_core_v674(p_business, qual.client_id) as dem
        ) d
       where d.dem->>'age_band' is null or d.dem->>'gender' is null
    ), 0),
    'overlapping_campaigns', coalesce((
      select count(distinct a.client_id)
        from public.campaign_send_records_v255 a
        join public.campaign_send_records_v255 b
          on b.business_id = a.business_id
         and b.client_id = a.client_id
         and (b.campaign_kind, b.campaign_ref_id) is distinct from (a.campaign_kind, a.campaign_ref_id)
         and b.id <> a.id
       where a.business_id = p_business
         and a.occurred_at <= p_as_of
         and b.occurred_at <= p_as_of
         and (a.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
         and (b.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
         and abs(extract(epoch from (a.occurred_at - b.occurred_at)) / 86400.0) <= 14
    ), 0)
  );
$$;
revoke all on function app.ci_exclusion_counts_v680(uuid,uuid,date,date,timestamptz)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 0b . app.ci_envelope_v680 -- forward the two new keys instead of dropping them
-- ---------------------------------------------------------------------------------------------
create or replace function app.ci_envelope_v680(
  p_query_version text, p_business uuid, p_branch uuid, p_from date, p_to date,
  p_as_of timestamptz, p_exclusions jsonb, p_payload jsonb)
returns jsonb
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_scope text;
  v_excl jsonb;
  v_trace text;
begin
  -- Deterministic scope fingerprint: business + branch + the requested window. Deliberately NOT
  -- jsonb_build_object(...)::text directly compared for equality anywhere -- it only ever feeds
  -- the trace_id hash, so key order stability (which jsonb_build_object already guarantees: it
  -- preserves argument order) is all that is required.
  v_scope := jsonb_build_object(
    'business_id', p_business, 'branch_id', p_branch, 'from', p_from, 'to', p_to)::text;

  v_excl := jsonb_build_object(
    'reversed_sales', coalesce((p_exclusions->>'reversed_sales')::bigint, 0),
    'synthetic_clients', coalesce((p_exclusions->>'synthetic_clients')::bigint, 0),
    'anonymous_sales', coalesce((p_exclusions->>'anonymous_sales')::bigint, 0),
    'missing_demographics', coalesce((p_exclusions->>'missing_demographics')::bigint, 0),
    'overlapping_campaigns', coalesce((p_exclusions->>'overlapping_campaigns')::bigint, 0));

  v_trace := encode(
    sha256(convert_to(
      coalesce(p_query_version, '') || '|' || v_scope || '|' || p_as_of::text || '|'
        || md5(p_payload::text),
      'utf8')),
    'hex');

  return p_payload || jsonb_build_object(
    'generated_at', clock_timestamp(),
    'as_of', p_as_of,
    'period', jsonb_build_object(
      'from', p_from, 'to', p_to, 'interval', '[from,to]', 'timezone', 'Asia/Singapore'),
    'exclusions', v_excl,
    'trace_id', v_trace);
end;
$$;
revoke all on function app.ci_envelope_v680(text,uuid,uuid,date,date,timestamptz,jsonb,jsonb)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 1 . get_ci_funnel_conversion_v1 -- + bottleneck_evidence_class when named
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_funnel_conversion_v1(
  p_business uuid, p_from date, p_to date, p_window_days integer default 60, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_today date := (p_as_of at time zone 'Asia/Singapore')::date;
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
  v_result jsonb;
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
       and s.created_at <= p_as_of
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
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

  v_result := jsonb_build_object(
    'window_days', p_window_days,
    'time_basis', 'sale_occurred_at',
    'stage_1_to_2', v_stage_1_to_2,
    'stage_2_to_3', v_stage_2_to_3,
    'immature', jsonb_build_object(
      'first_stage', v_immature_first, 'second_stage', v_immature_second),
    'bottleneck', v_bottleneck,
    'evidence', v_evidence,
    'observed_since', app.metric_observed_since_v1('lifecycle_funnel', p_business));

  -- v693: name the evidence class ONLY when a bottleneck was actually named -- omit the key
  -- entirely (not a null value) when 'bottleneck' is null, per the frozen vocabulary contract.
  if v_bottleneck is not null then
    v_result := v_result || jsonb_build_object('bottleneck_evidence_class', 'DIRECT_FACT');
  end if;

  return app.ci_envelope_v680('ci_funnel_conversion_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid,timestamptz) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 2 . get_ci_retention_windows_v1 -- + evidence_class:'DIRECT_FACT' on every cohort cell
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_retention_windows_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_today date := (p_as_of at time zone 'Asia/Singapore')::date;
  v_horizons integer[] := array[30,60,90,180,365];
  v_cohorts jsonb;
  v_immature jsonb;
  v_result jsonb;
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
       and s.created_at <= p_as_of
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
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
           'evidence_class', 'DIRECT_FACT',
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
       and s.created_at <= p_as_of
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
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

  v_result := jsonb_build_object(
    'horizons', to_jsonb(v_horizons),
    'cohorts', v_cohorts,
    'immature_cells', v_immature,
    'time_basis', 'sale_occurred_at',
    'observed_since', app.metric_observed_since_v1('retention_windows', p_business));

  return app.ci_envelope_v680('ci_retention_windows_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 3 . get_ci_daypart_v1 -- + evidence_class on busiest_weekday (DIRECT_FACT) and
--     most_valuable_weekday (ASSOCIATION + note)
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_daypart_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp()
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  with scope as (
    select s.id, s.amount_cents,
           sc.include_revenue, sc.include_visit,
           (s.occurred_at at time zone 'Asia/Singapore') as local_ts
      from public.sales s
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.created_at <= p_as_of
       and not sc.is_synthetic_client
       and (sc.include_revenue or sc.include_visit)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  weekday_occ as (
    select extract(isodow from d)::int as dow, count(*) as occurrences
      from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
     group by 1
  ),
  by_weekday as (
    select extract(isodow from local_ts)::int as dow,
           count(*) filter (where include_visit) as visits,
           coalesce(sum(amount_cents) filter (where include_revenue), 0) as revenue_cents
      from scope
     group by 1
  ),
  weekdays as (
    select g.dow,
           case g.dow when 1 then 'Monday' when 2 then 'Tuesday' when 3 then 'Wednesday'
                      when 4 then 'Thursday' when 5 then 'Friday' when 6 then 'Saturday'
                      else 'Sunday' end as label,
           coalesce(bw.visits, 0) as visits,
           coalesce(bw.revenue_cents, 0) as revenue_cents,
           coalesce(wo.occurrences, 0) as weekday_occurrences
      from generate_series(1, 7) as g(dow)
      left join weekday_occ wo on wo.dow = g.dow
      left join by_weekday bw on bw.dow = g.dow
  ),
  weekday_rows as (
    select w.*,
           app.subgroup_evidence_v1(w.visits::int) as evidence
      from weekdays w
  ),
  weekday_rated as (
    select wr.*,
           case when wr.evidence ->> 'status' = 'ok' and wr.visits > 0
                then round(wr.revenue_cents::numeric / wr.visits) else null end
             as revenue_per_visit_cents,
           case when wr.evidence ->> 'status' = 'ok'
                then app.rate_block_v1(wr.visits, wr.weekday_occurrences)
                else jsonb_build_object('numerator', wr.visits,
                                         'denominator', wr.weekday_occurrences, 'pct', null) end
             as visits_per_occurrence
      from weekday_rows wr
  ),
  by_hour as (
    select extract(hour from local_ts)::int as hr,
           count(*) filter (where include_visit) as visits,
           coalesce(sum(amount_cents) filter (where include_revenue), 0) as revenue_cents
      from scope
     group by 1
  ),
  hours as (
    select g.hr, coalesce(bh.visits, 0) as visits, coalesce(bh.revenue_cents, 0) as revenue_cents,
           app.subgroup_evidence_v1(coalesce(bh.visits, 0)::int) as evidence
      from generate_series(0, 23) as g(hr)
      left join by_hour bh on bh.hr = g.hr
  ),
  busiest as (
    select dow, label, visits from weekday_rated order by visits desc, dow asc limit 1
  ),
  most_valuable as (
    select dow, label, revenue_per_visit_cents from weekday_rated
     where evidence ->> 'status' = 'ok' and revenue_per_visit_cents is not null
     order by revenue_per_visit_cents desc, dow asc limit 1
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                 'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'basis_note',
      'Bucketed on sale_occurred_at -- the till timestamp a sale was RECORDED at -- converted to '
      'Asia/Singapore. This is TILL time, not arrival time or service-start time: neither is '
      'captured anywhere in this schema today, so a customer who waited before being served, or '
      'a booking whose service began well before checkout, is bucketed by when the sale closed, '
      'not by when they walked in.',
    'weekdays', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'dow', wr.dow, 'label', wr.label,
               'visits', wr.visits, 'revenue_cents', wr.revenue_cents,
               'revenue_per_visit_cents', wr.revenue_per_visit_cents,
               'weekday_occurrences', wr.weekday_occurrences,
               'visits_per_occurrence', wr.visits_per_occurrence,
               'evidence', wr.evidence
             ) order by wr.dow), '[]'::jsonb)
        from weekday_rated wr
    ),
    'hours', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'hour', h.hr, 'visits', h.visits, 'revenue_cents', h.revenue_cents,
               'revenue_per_visit_cents',
                 case when h.evidence ->> 'status' = 'ok' and h.visits > 0
                      then round(h.revenue_cents::numeric / h.visits) else null end,
               'evidence', h.evidence
             ) order by h.hr), '[]'::jsonb)
        from hours h
    ),
    'busiest_weekday',
      (select jsonb_build_object('dow', b.dow, 'label', b.label, 'visits', b.visits,
                                  'evidence_class', 'DIRECT_FACT') from busiest b),
    'most_valuable_weekday',
      (select jsonb_build_object('dow', m.dow, 'label', m.label,
                                  'revenue_per_visit_cents', m.revenue_per_visit_cents,
                                  'evidence_class', 'ASSOCIATION',
                                  'note',
                                    'Revenue-per-visit only means something as a COMPARISON '
                                    'across the seven weekdays -- which one ranks highest -- so '
                                    'it is classed as an association between weekday and value, '
                                    'not a directly observed single fact.')
         from most_valuable m),
    'observed_since', app.metric_observed_since_v1('ci_daypart', p_business)
  ) into v_result;

  return app.ci_envelope_v680('ci_daypart_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$function$;
revoke all on function public.get_ci_daypart_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_daypart_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 4 . get_ci_demographic_cohort_v1 -- + difference_evidence_class:'ASSOCIATION' (unconditional)
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_demographic_cohort_v1(
  p_business uuid, p_gender text, p_age_from integer, p_age_to integer,
  p_node_key text, p_from date, p_to date,
  p_return_window_days integer default 60, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_result jsonb;
  v_today date := (p_as_of at time zone 'Asia/Singapore')::date;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);

  if p_gender is null or p_gender not in ('female', 'male', 'other') then
    raise exception 'p_gender must be one of female, male, other (got %)', coalesce(p_gender, '<null>')
      using errcode = '22023';
  end if;
  if p_age_from is null or p_age_to is null or p_age_from < 0 or p_age_to < p_age_from then
    raise exception 'invalid age range % to %', p_age_from, p_age_to using errcode = '22023';
  end if;
  if p_return_window_days is null or p_return_window_days < 1 then
    raise exception 'p_return_window_days must be a positive integer' using errcode = '22023';
  end if;
  if not exists (select 1 from public.taxonomy_nodes n
                  where n.version_no = 1 and n.node_key = p_node_key) then
    raise exception 'unknown taxonomy node %', p_node_key using errcode = '22023';
  end if;

  with qualifying_purchases as (
    select s.client_id, min((s.occurred_at at time zone 'Asia/Singapore')::date) as anchor_date
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      join public.clients c on c.id = s.client_id
      cross join lateral app.ci_effective_node_v650(si) en
     where si.business_id = p_business
       and si.item_type in ('service', 'retail')
       and (p_branch is null or s.branch_id = p_branch)
       and s.client_id is not null
       and not coalesce(c.is_synthetic, false)
       and s.reversal_of is null
       and s.created_at <= p_as_of
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and coalesce(s.counts_as_visit, false)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and (en.node_key = p_node_key or en.node_key like p_node_key || '.%')
     group by s.client_id
  ),
  demog as (
    select qp.client_id, qp.anchor_date,
           case when wl.wbirth is not null or wl.wgender is not null
                then coalesce(wl.wbirth, c.birth_date) else c.birth_date end as eff_birth,
           case when wl.wbirth is not null or wl.wgender is not null
                then nullif(coalesce(wl.wgender, c.gender), 'prefer_not_to_say')
                else nullif(c.gender, 'prefer_not_to_say') end as eff_gender
      from qualifying_purchases qp
      join public.clients c on c.id = qp.client_id
      left join lateral (
        select cp.birth_date as wbirth, cp.gender as wgender
          from public.customer_links cl
          join public.customer_profiles cp on cp.identity_id = cl.identity_id
         where cl.business_id = p_business and cl.client_id = qp.client_id and cl.state = 'verified'
         limit 1
      ) wl on true
  ),
  classified as (
    select d.client_id, d.anchor_date, d.eff_gender,
           (d.eff_birth is not null and d.eff_gender is not null) as resolved,
           case when d.eff_birth is not null
                then extract(year from age(d.anchor_date, d.eff_birth))::int end as age_at_anchor,
           ((v_today - d.anchor_date) >= p_return_window_days) as mature
      from demog d
  ),
  cohort as (
    select cl2.client_id, cl2.anchor_date, cl2.mature
      from classified cl2
     where cl2.eff_gender = p_gender
       and cl2.age_at_anchor is not null
       and cl2.age_at_anchor between p_age_from and p_age_to
  ),
  cohort_eval as (
    select co.client_id, co.mature,
           exists (
             select 1 from public.sales s2
              where s2.business_id = p_business
                and s2.client_id = co.client_id
                and (p_branch is null or s2.branch_id = p_branch)
                and coalesce(s2.counts_as_visit, false)
                and s2.reversal_of is null
                and s2.created_at <= p_as_of
                and not exists (select 1 from public.sales r2
                                 where r2.reversal_of = s2.id and r2.created_at <= p_as_of)
                and (s2.occurred_at at time zone 'Asia/Singapore')::date > co.anchor_date
                and (s2.occurred_at at time zone 'Asia/Singapore')::date
                      <= co.anchor_date + p_return_window_days
           ) as returned
      from cohort co
  ),
  cohort_agg as (
    select count(*) as customers,
           count(*) filter (where mature) as denom,
           count(*) filter (where mature and returned) as numer
      from cohort_eval
  ),
  cohort_observations as (
    select count(*) as obs
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      cross join lateral app.ci_effective_node_v650(si) en
     where si.business_id = p_business
       and si.item_type in ('service', 'retail')
       and (p_branch is null or s.branch_id = p_branch)
       and s.client_id in (select client_id from cohort)
       and s.reversal_of is null
       and s.created_at <= p_as_of
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and coalesce(s.counts_as_visit, false)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and (en.node_key = p_node_key or en.node_key like p_node_key || '.%')
  ),
  baseline_pop as (
    select cl3.client_id, cl3.anchor_date
      from classified cl3
     where cl3.resolved and cl3.mature
  ),
  baseline_eval as (
    select bp.client_id,
           exists (
             select 1 from public.sales s3
              where s3.business_id = p_business
                and s3.client_id = bp.client_id
                and (p_branch is null or s3.branch_id = p_branch)
                and coalesce(s3.counts_as_visit, false)
                and s3.reversal_of is null
                and s3.created_at <= p_as_of
                and not exists (select 1 from public.sales r3
                                 where r3.reversal_of = s3.id and r3.created_at <= p_as_of)
                and (s3.occurred_at at time zone 'Asia/Singapore')::date > bp.anchor_date
                and (s3.occurred_at at time zone 'Asia/Singapore')::date
                      <= bp.anchor_date + p_return_window_days
           ) as returned
      from baseline_pop bp
  ),
  baseline_agg as (
    select count(*) as denom, count(*) filter (where returned) as numer
      from baseline_eval
  ),
  coverage_pop as (
    select count(*) as mature_identified,
           count(*) filter (where resolved) as mature_resolved
      from classified
     where mature
  ),
  final as (
    select ca.customers, ca.denom, ca.numer, co.obs,
           ba.denom as b_denom, ba.numer as b_numer,
           cp.mature_identified, cp.mature_resolved,
           app.subgroup_evidence_v1(ca.denom::int) as confidence
      from cohort_agg ca, cohort_observations co, baseline_agg ba, coverage_pop cp
  )
  select jsonb_build_object(
    'cohort', jsonb_build_object(
      'gender', p_gender, 'age_from', p_age_from, 'age_to', p_age_to,
      'node_key', p_node_key, 'business_id', p_business, 'branch_id', p_branch,
      'sentence', format('%s customers aged %s-%s who made a qualifying purchase in category %s.',
                          initcap(p_gender), p_age_from, p_age_to, p_node_key)),
    'window', jsonb_build_object(
      'return_window_days', p_return_window_days,
      'maturity_rule', 'a cohort member is mature once return_window_days have fully elapsed since their qualifying category purchase: (as_of_date - purchase_date) >= return_window_days'),
    'numerator', f.numer,
    'denominator', f.denom,
    'customers', f.customers,
    'observations', f.obs,
    'baseline', app.rate_block_v1(f.b_numer, f.b_denom),
    'pct', case when f.confidence->>'status' = 'ok' and f.denom > 0
                then round(100.0 * f.numer / f.denom, 1) else null end,
    'difference', case when f.confidence->>'status' = 'ok' and f.denom > 0 and f.b_denom > 0
                  then round(100.0 * f.numer / f.denom - 100.0 * f.b_numer / f.b_denom, 1)
                  else null end,
    'difference_evidence_class', 'ASSOCIATION',
    'difference_evidence_note',
      'Cohort membership (age band x gender x category purchase) is observational, not '
      'randomised, so the percentage-point difference against the baseline is an association '
      'between group membership and return behaviour, not a causal estimate of what produced it.',
    'period', jsonb_build_object('from', p_from, 'to', p_to, 'time_basis', 'sale_occurred_at'),
    'coverage', app.rate_block_v1(f.mature_resolved, f.mature_identified),
    'age_basis', 'purchase_date',
    'confidence', f.confidence,
    'withheld_reason', case when f.confidence->>'status' <> 'ok'
      then format('cohort denominator (%s mature member(s)) is below the sample floor of %s; the return rate and its comparison to baseline are withheld to avoid a false-precision figure for a very small group.', f.denom, f.confidence->>'floor')
      else null end,
    'observed_since', app.metric_observed_since_v1('ci_demographic_cohort', p_business))
    into v_result
    from final f;

  return app.ci_envelope_v680('ci_demographic_cohort_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid,timestamptz)
  from public, anon;
grant execute on function public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid,timestamptz)
  to authenticated, service_role;

commit;
