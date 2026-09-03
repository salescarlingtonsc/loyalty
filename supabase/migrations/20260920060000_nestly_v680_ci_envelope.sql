-- NESTLY v680 — one shared CI envelope: generated_at/as_of/period/exclusions/trace_id, and an
-- immutable-snapshot as_of gate, on every Customer Intelligence reader.
--
-- Closes acceptance checks 1 (envelope shape), 9 (immutable snapshot), 13 (period/timezone
-- discipline), 16 (exclusion counts travel with every payload) and 20 (a deterministic trace_id)
-- of the rescoped Customer Intelligence program. Proven by
-- db/tests/executed/v680_corpus_envelope.sql.
--
-- ---------------------------------------------------------------------------------------------
-- THE ENVELOPE (app.ci_envelope_v680) — modelled on nestly_v106's own as_of/period/timezone
-- contract (db/migrations/20260729_nestly_v106_revenue_truth_foundation.sql:918-1145), which
-- already proved this exact shape in production: a p_as_of timestamptz defaulting to
-- clock_timestamp(), a 'period' block naming its own interval convention, and every population
-- query gated by `created_at <= p_as_of`. v106's own interval is half-open ([from,to)) because
-- its dates are business-local buckets; every CI reader in this program uses INCLUSIVE dates
-- ([p_from, p_to] via `between`), so the envelope's period.interval is '[from,to]' to describe
-- what the readers actually do rather than copying v106's convention wholesale.
--
-- app.ci_envelope_v680(p_query_version, p_business, p_branch, p_from, p_to, p_as_of,
--                       p_exclusions, p_payload) MERGES five keys into a reader's own payload,
-- verbatim, never replacing anything the reader already emitted:
--   generated_at   clock_timestamp() — when this call actually ran (differs from as_of by design
--                  when a caller pins an old as_of; see the fixture's E2/E3 blocks).
--   as_of          the snapshot boundary the reader honoured, echoed back so a caller never has
--                  to guess whether their as_of took effect.
--   period         {from, to, interval:'[from,to]', timezone:'Asia/Singapore'} — every CI-A/B/C
--                  reader already bucket dates in Asia/Singapore (frozen in
--                  docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md point 2); this just says so in
--                  the envelope instead of leaving it implicit in each reader's own scope object.
--   exclusions     {reversed_sales, synthetic_clients, anonymous_sales} — three counts that are
--                  ALWAYS present as numbers (defaulting a caller's missing key to 0), never
--                  omitted, so a consumer can always answer "how much was excluded" without
--                  parsing a reader-specific shape.
--   trace_id       a deterministic hex digest of (query_version, scope, as_of, the payload's own
--                  content) — sha256, not pgcrypto's digest(), because Postgres 13+ ships
--                  sha256(bytea) in core and this repo's target engine (17) has it, so no
--                  extension dependency is added for one hash. Identical inputs against
--                  unchanged data produce an identical trace_id (check 20); a fresh as_of over
--                  grown data changes it, because the scope string embeds p_as_of AND the
--                  payload's own md5 changes when the population changes.
--
-- app.ci_exclusion_counts_v680 computes the three exclusion counts once, cheaply, over
-- public.sales/public.clients for a (business, branch, window, as_of) — "whatever the reader
-- can count cheaply" per the CI-CORPUS-FIXTURE-GUIDE, not a bespoke recomputation of each
-- reader's own population. It is deliberately reused by every re-emitted reader below rather
-- than each reader growing its own slightly-different exclusion query — one authority for what
-- "excluded" means, the same discipline v672 already established for evidence/rate/distribution.
--
-- ---------------------------------------------------------------------------------------------
-- THE AS_OF GATE (check 9) — applied to every re-emitted reader below
-- ---------------------------------------------------------------------------------------------
-- Every reader gains a trailing `p_as_of timestamptz default clock_timestamp()`. Existing 3/4/5-
-- arg callers keep working unchanged (a new trailing default never breaks a shorter call), but
-- CREATE OR REPLACE cannot add a parameter to an existing signature — Postgres treats a
-- different parameter LIST as a different function — so each one is `drop function if exists`
-- on its exact pre-v680 signature first, exactly as v667 did when it added p_branch. Every
-- reader that reads public.sales (directly or through public.sale_items) adds
-- `s.created_at <= p_as_of` to its population filter, and — where the reader already excludes a
-- sale for being reversed via a `not exists (select 1 from public.sales r where
-- r.reversal_of = s.id)` correlated subquery — adds `and r.created_at <= p_as_of` to that
-- subquery too: a reversal recorded AFTER the pinned as_of had not happened yet as of that
-- snapshot, so the original sale must still count as unreversed at that snapshot, not be
-- silently corrected by a future event. get_ci_acquisition_v1's population is public.clients
-- directly, so it gates on `c.created_at <= p_as_of` instead.
--
-- Every "as of today" calculation (maturity windows, package expiry) is re-anchored on
-- `(p_as_of at time zone 'Asia/Singapore')::date` instead of `now()`/`current_date`, so a
-- snapshot taken with an old p_as_of reproduces byte-identically no matter when it is actually
-- run — the whole point of an immutable snapshot is that "today" is a parameter, not the wall
-- clock. The one deliberate exception: app.customer_demographics_core_v674's age-band
-- classification stays anchored on `current_date` (v638's own frozen contract: "classified as of
-- TODAY", unchanged since 2026-08-30) — re-anchoring THAT on p_as_of would be a divergence from
-- the authority this reader is required to call verbatim, not a fix.
--
-- RECORDED LIMITATION, not fixed: public.client_packages carries no created_at column (verified
-- against tests/fixtures/db-schema-snapshot.sql — only `purchased_at`, which is a business fact,
-- not a recorded-at audit column). get_ci_package_intelligence_v1's COHORT (which package
-- purchases fall in the window) therefore cannot be gated on when the purchase ROW was recorded,
-- only on when the window itself is defined — a purchase inserted after p_as_of but backdated to
-- an in-window purchased_at would still appear. Everything downstream of the cohort that DOES
-- carry a created_at — package_session_consumptions (usage events) and the outside-spend sales
-- lookup — is gated on p_as_of as usual. This is a real, disclosed gap in the immutable-snapshot
-- guarantee for this one reader, not silently patched over by adding a column this migration has
-- no mandate to add.
--
-- ---------------------------------------------------------------------------------------------
-- get_ci_opportunities_v1 (v678) additionally gains 'freshness' and a stale-evidence refusal
-- ---------------------------------------------------------------------------------------------
-- 'freshness': {observed_since_min, generated_at, stale, period_far_from_as_of}. observed_since_min
-- is the earliest 'observed_since' emitted by the six re-emitted sub-readers this engine actually
-- consumes and that carry the field (funnel, daypart, service intelligence, package intelligence,
-- category mix, demographics — get_ci_contactability_v1 has no observed_since and is not part of
-- this calculation, since it was not in this migration's re-emit scope and consent has no
-- watermark).
--
-- JUDGEMENT CALL, recorded rather than hidden. The spec for this check names two signals:
-- observed_since_min more than 400 days before p_as_of, OR the requested period ending more than
-- 90 days before p_as_of. Both are computed and both are disclosed (period_far_from_as_of is its
-- own field), but only the FIRST drives 'stale' and the refusal. The second signal, read
-- literally, would also fire on every ordinary call this engine already needs to make: the
-- funnel and retention-window readers it consumes REQUIRE an old, matured window by design (a
-- cohort's rate only reports once its own maturity window has fully elapsed), and
-- db/tests/executed/v678_corpus_consultant_spine.sql's own truth table already proves a 111-day
-- window ending ~100 days before "now" is the NORMAL way to call this engine on an actively-
-- observed business — that is a deliberately mature analytical window, not stale evidence, and
-- refusing to rank on it would break every legitimate matured-cohort call this engine was built
-- to serve. What genuinely signals stale evidence is observed_since_min: how long ago the
-- business or its metrics were last established or watermarked, independent of which window a
-- caller chose to look at. When 'stale' (observed_since_min-driven) is true, the engine REFUSES
-- to rank: 'ranked' is forced to a single do_nothing entry (the existing twelve-key contract,
-- unchanged) and a top-level 'refusal_reason':'stale_evidence' is set so a caller can distinguish
-- "nothing cleared the evidence floor" (refusal_reason null, rank_class do_nothing) from "the
-- engine refused to look at all" (refusal_reason 'stale_evidence') without parsing the
-- do_nothing entry's prose.

begin;

-- ---------------------------------------------------------------------------------------------
-- 0 · The envelope itself
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
    ), 0)
  );
$$;
revoke all on function app.ci_exclusion_counts_v680(uuid,uuid,date,date,timestamptz)
  from public, anon, authenticated;

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
  -- jsonb_build_object(...)::text directly compared for equality anywhere — it only ever feeds
  -- the trace_id hash, so key order stability (which jsonb_build_object already guarantees: it
  -- preserves argument order) is all that is required.
  v_scope := jsonb_build_object(
    'business_id', p_business, 'branch_id', p_branch, 'from', p_from, 'to', p_to)::text;

  v_excl := jsonb_build_object(
    'reversed_sales', coalesce((p_exclusions->>'reversed_sales')::bigint, 0),
    'synthetic_clients', coalesce((p_exclusions->>'synthetic_clients')::bigint, 0),
    'anonymous_sales', coalesce((p_exclusions->>'anonymous_sales')::bigint, 0));

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
-- 1 · v673 — get_ci_funnel_conversion_v1 / get_ci_retention_windows_v1
-- ---------------------------------------------------------------------------------------------
drop function if exists public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid);
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

  return app.ci_envelope_v680('ci_funnel_conversion_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_funnel_conversion_v1(uuid,date,date,integer,uuid,timestamptz) to authenticated, service_role;

drop function if exists public.get_ci_retention_windows_v1(uuid,date,date,uuid);
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
-- 2 · v674 — get_ci_demographics_v1 / get_ci_demographic_cohort_v1
-- ---------------------------------------------------------------------------------------------
drop function if exists public.get_ci_demographics_v1(uuid,date,date,uuid);
create or replace function public.get_ci_demographics_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);

  with qualifying as (
    select s.client_id, s.amount_cents,
           coalesce(s.counts_as_revenue, false) as is_revenue,
           coalesce(s.counts_as_visit, false) as is_visit
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.client_id is not null
       and not coalesce(c.is_synthetic, false)
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and s.created_at <= p_as_of
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and (coalesce(s.counts_as_revenue, false) or coalesce(s.counts_as_visit, false))
  ),
  client_agg as (
    select q.client_id,
           coalesce(sum(q.amount_cents) filter (where q.is_revenue), 0) as revenue_cents,
           count(*) filter (where q.is_revenue) as revenue_txns,
           count(*) filter (where q.is_visit) as visits
      from qualifying q
     group by q.client_id
  ),
  classified as (
    select ca.client_id, ca.revenue_cents, ca.revenue_txns, ca.visits,
           d.dem->>'age_band' as age_band,
           d.dem->>'gender' as gender
      from client_agg ca
      cross join lateral (
        select app.customer_demographics_core_v674(p_business, ca.client_id) as dem
      ) d
  ),
  cells as (
    select age_band, gender,
           count(*) as customers,
           sum(revenue_cents)::bigint as revenue_cents,
           sum(visits)::bigint as visits,
           sum(revenue_txns)::bigint as revenue_txns
      from classified
     where age_band is not null and gender is not null
     group by age_band, gender
  ),
  unclass as (
    select count(*) as customers, coalesce(sum(revenue_cents), 0)::bigint as revenue_cents
      from classified
     where age_band is null or gender is null
  ),
  totals as (
    select count(*) as active_customers,
           coalesce(sum(revenue_cents), 0)::bigint as active_revenue_cents,
           count(*) filter (where age_band is not null and gender is not null) as resolved_customers,
           coalesce(sum(revenue_cents) filter (where age_band is not null and gender is not null), 0)::bigint
             as resolved_revenue_cents
      from classified
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                 'from', p_from, 'to', p_to),
    'cells', coalesce((
      select jsonb_agg(jsonb_build_object(
               'age_band', cl.age_band,
               'gender', cl.gender,
               'customers', cl.customers,
               'revenue_cents', cl.revenue_cents,
               'visits', cl.visits,
               'atv_cents', case
                 when app.subgroup_evidence_v1(cl.customers::int)->>'status' = 'ok'
                      and cl.revenue_txns > 0
                 then round(cl.revenue_cents::numeric / cl.revenue_txns)::bigint
                 else null end,
               'evidence', app.subgroup_evidence_v1(cl.customers::int))
             order by cl.age_band, cl.gender)
        from cells cl), '[]'::jsonb),
    'unclassified', jsonb_build_object('customers', u.customers, 'revenue_cents', u.revenue_cents),
    'coverage', jsonb_build_object(
      'demographics', app.rate_block_v1(t.resolved_customers, t.active_customers),
      'revenue', app.rate_block_v1(t.resolved_revenue_cents, t.active_revenue_cents)),
    'time_basis', 'sale_occurred_at',
    'observed_since', app.metric_observed_since_v1('ci_demographics', p_business))
    into v_result
    from unclass u, totals t;

  return app.ci_envelope_v680('ci_demographics_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_demographics_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_demographics_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

drop function if exists public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid);
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

-- ---------------------------------------------------------------------------------------------
-- 3 · v675 — get_ci_daypart_v1 / get_ci_service_intelligence_v1 / get_ci_package_intelligence_v1
-- ---------------------------------------------------------------------------------------------
drop function if exists public.get_ci_daypart_v1(uuid,date,date,uuid);
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
    select g.hr, coalesce(bh.visits, 0) as visits, coalesce(bh.revenue_cents, 0) as revenue_cents
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
                 case when h.visits > 0
                      then round(h.revenue_cents::numeric / h.visits) else null end
             ) order by h.hr), '[]'::jsonb)
        from hours h
    ),
    'busiest_weekday',
      (select jsonb_build_object('dow', b.dow, 'label', b.label, 'visits', b.visits) from busiest b),
    'most_valuable_weekday',
      (select jsonb_build_object('dow', m.dow, 'label', m.label,
                                  'revenue_per_visit_cents', m.revenue_per_visit_cents)
         from most_valuable m),
    'observed_since', app.metric_observed_since_v1('ci_daypart', p_business)
  ) into v_result;

  return app.ci_envelope_v680('ci_daypart_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$function$;
revoke all on function public.get_ci_daypart_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_daypart_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

drop function if exists public.get_ci_service_intelligence_v1(uuid,date,date,uuid);
create or replace function public.get_ci_service_intelligence_v1(
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
  v_floor constant integer := 5;
  v_limit constant integer := 20;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  with lines as (
    select si.sale_id, si.ref_id as service_id, si.line_cents, s.client_id, s.occurred_at
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      cross join lateral app.analytics_sale_class_v1(s) sc
     where si.business_id = p_business
       and si.item_type = 'service'
       and si.ref_id is not null
       and (p_branch is null or s.branch_id = p_branch)
       and s.created_at <= p_as_of
       and sc.include_revenue
       and not sc.is_synthetic_client
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  first_ever_sale as (
    select distinct on (s.client_id) s.client_id, s.id as sale_id
      from public.sales s
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and s.created_at <= p_as_of
       and sc.include_revenue
       and not sc.is_synthetic_client
       and s.client_id is not null
     order by s.client_id, s.occurred_at asc, s.id asc
  ),
  gateway_clients as (
    select distinct l.service_id, l.client_id
      from lines l
      join first_ever_sale fes on fes.client_id = l.client_id
      join public.sale_items gi
        on gi.sale_id = fes.sale_id and gi.business_id = p_business
       and gi.item_type = 'service' and gi.ref_id = l.service_id
  ),
  per_service as (
    select service_id,
           count(distinct client_id) as buyers,
           count(distinct sale_id) as orders,
           coalesce(sum(line_cents), 0) as revenue_cents
      from lines
     group by service_id
  ),
  buyer_orders as (
    select service_id, client_id, count(distinct sale_id) as n
      from lines
     group by service_id, client_id
  ),
  repeat_counts as (
    select service_id, count(*) as repeat_buyers
      from buyer_orders
     where n >= 2
     group by service_id
  ),
  gateway_counts as (
    select service_id, count(distinct client_id) as gateway_count
      from gateway_clients
     group by service_id
  ),
  last_purchase as (
    select service_id, client_id, max(occurred_at) as last_at
      from lines
     group by service_id, client_id
  ),
  next_purchase as (
    select lp.service_id, lp.client_id,
           extract(epoch from (np.next_at - lp.last_at)) / 86400.0 as days_to_next
      from last_purchase lp
      cross join lateral (
        select min(s2.occurred_at) as next_at
          from public.sales s2
          cross join lateral app.analytics_sale_class_v1(s2) sc2
         where s2.business_id = p_business
           and s2.client_id = lp.client_id
           and s2.created_at <= p_as_of
           and sc2.include_revenue
           and not sc2.is_synthetic_client
           and s2.occurred_at > lp.last_at
      ) np
     where np.next_at is not null
  ),
  median_days as (
    select service_id, count(*) as n_obs,
           percentile_cont(0.5) within group (order by days_to_next) as raw_median
      from next_purchase
     group by service_id
  ),
  services_agg as (
    select ps.service_id, svc.name as service_name,
           ps.buyers, ps.orders, ps.revenue_cents,
           coalesce(rc.repeat_buyers, 0) as repeat_buyers,
           coalesce(gc.gateway_count, 0) as gateway_count,
           coalesce(md.n_obs, 0) as median_n_obs,
           md.raw_median,
           app.subgroup_evidence_v1(ps.buyers::int, v_floor) as evidence
      from per_service ps
      join public.services svc on svc.id = ps.service_id and svc.business_id = p_business
      left join repeat_counts rc on rc.service_id = ps.service_id
      left join gateway_counts gc on gc.service_id = ps.service_id
      left join median_days md on md.service_id = ps.service_id
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                 'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'basis_note', 'Buyers/orders/revenue are window+branch scoped; gateway status and the next-'
      'purchase gap look at each client''s full lifetime history with this business, not just '
      'this window (see the migration header, judgement call 3).',
    'services', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'service_id', x.service_id, 'service_name', x.service_name,
               'buyers', x.buyers, 'orders', x.orders, 'revenue_cents', x.revenue_cents,
               'repeat_buyers', x.repeat_buyers,
               'repeat_rate',
                 case when x.evidence ->> 'status' = 'ok'
                      then app.rate_block_v1(x.repeat_buyers, x.buyers)
                      else jsonb_build_object('numerator', x.repeat_buyers,
                                               'denominator', x.buyers, 'pct', null) end,
               'gateway_count', x.gateway_count,
               'median_days_to_next_purchase',
                 case when x.evidence ->> 'status' = 'ok' and x.median_n_obs >= 3
                      then round(x.raw_median::numeric, 1) else null end,
               'evidence', x.evidence
             ) order by x.revenue_cents desc, x.service_id), '[]'::jsonb)
        from (select * from services_agg order by revenue_cents desc, service_id limit v_limit) x
    ),
    'truncated', (select count(*) from services_agg) > v_limit,
    'observed_since', app.metric_observed_since_v1('ci_service_intelligence', p_business)
  ) into v_result;

  return app.ci_envelope_v680('ci_service_intelligence_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$function$;
revoke all on function public.get_ci_service_intelligence_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_service_intelligence_v1(uuid,date,date,uuid,timestamptz)
  to authenticated, service_role;

drop function if exists public.get_ci_package_intelligence_v1(uuid,date,date,uuid);
create or replace function public.get_ci_package_intelligence_v1(
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
  -- client_packages carries no branch_id and no sale_id (v675's own finding). It also carries no
  -- created_at (verified against tests/fixtures/db-schema-snapshot.sql), so the window COHORT
  -- itself cannot be gated on when the purchase row was recorded -- only what usage/spend
  -- happened by p_as_of downstream of it. Recorded above in this migration's header, not fixed.
  perform app.ci_no_branch_dimension_v667(p_branch, 'package intelligence');
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  with cohort as (
    select cp.id as client_package_id, cp.plan_id, cp.client_id, cp.remaining, cp.status,
           cp.sessions_snapshot, cp.purchased_at, cp.expires_at
      from public.client_packages cp
      join public.clients c on c.id = cp.client_id and c.business_id = p_business
     where cp.business_id = p_business
       and not coalesce(c.is_synthetic, false)
       and (cp.purchased_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  usage_events as (
    select psc.client_package_id, psc.created_at,
           row_number() over (partition by psc.client_package_id order by psc.created_at) as rn
      from public.package_session_consumptions psc
      join cohort ch on ch.client_package_id = psc.client_package_id
     where psc.business_id = p_business
       and psc.created_at <= p_as_of
  ),
  gaps as (
    select ch.plan_id,
           extract(epoch from (cur.created_at - prev.created_at)) / 86400.0 as gap_days
      from usage_events cur
      join usage_events prev
        on prev.client_package_id = cur.client_package_id and prev.rn = cur.rn - 1
      join cohort ch on ch.client_package_id = cur.client_package_id
  ),
  gap_stats as (
    select plan_id, percentile_cont(0.5) within group (order by gap_days) as raw_median
      from gaps
     group by plan_id
  ),
  event_counts as (
    select ch.plan_id, count(ue.rn) as n_events
      from cohort ch
      left join usage_events ue on ue.client_package_id = ch.client_package_id
     group by ch.plan_id
  ),
  repurchase as (
    select distinct ch.plan_id, ch.client_id
      from cohort ch
     where exists (
       select 1 from public.client_packages older
        where older.business_id = p_business
          and older.plan_id = ch.plan_id
          and older.client_id = ch.client_id
          and older.id <> ch.client_package_id
          and older.purchased_at < ch.purchased_at
          and (older.status = 'used_up'
               or (older.expires_at is not null and older.expires_at < ch.purchased_at))
     )
  ),
  repurchase_counts as (
    select plan_id, count(*) as repurchase_count from repurchase group by plan_id
  ),
  outside_spend as (
    select ch.plan_id, coalesce(sum(s.amount_cents), 0) as spend_cents
      from cohort ch
      join public.sales s on s.business_id = p_business and s.client_id = ch.client_id
      cross join lateral app.analytics_sale_class_v1(s) sc
     where sc.include_revenue
       and not sc.is_synthetic_client
       and s.created_at <= p_as_of
       and s.kind <> 'package'
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
     group by ch.plan_id
  ),
  per_plan as (
    select ch.plan_id,
           count(*) as sold_count,
           sum(ch.sessions_snapshot) as sessions_included,
           sum(ch.sessions_snapshot - ch.remaining) as sessions_used,
           count(*) filter (
             where ch.remaining > 0 and ch.expires_at is not null and ch.expires_at < p_as_of
           ) as expired_or_lapsed_with_unused
      from cohort ch
     group by ch.plan_id
  ),
  plans as (
    select pp.id as plan_id, pp.name as plan_name,
           pl.sold_count, pl.sessions_included, pl.sessions_used,
           pl.expired_or_lapsed_with_unused,
           coalesce(rp.repurchase_count, 0) as repurchase_count,
           coalesce(os.spend_cents, 0) as outside_spend_cents,
           coalesce(ec.n_events, 0) as n_events,
           gs.raw_median,
           app.subgroup_evidence_v1(pl.sold_count::int) as evidence
      from public.package_plans pp
      join per_plan pl on pl.plan_id = pp.id
      left join repurchase_counts rp on rp.plan_id = pp.id
      left join outside_spend os on os.plan_id = pp.id
      left join event_counts ec on ec.plan_id = pp.id
      left join gap_stats gs on gs.plan_id = pp.id
     where pp.business_id = p_business
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', null,
                                 'from', p_from, 'to', p_to),
    'time_basis', 'client_packages.purchased_at',
    'basis_note', 'One row per plan with at least one purchase inside the window. Utilisation, '
      'expiry state and repurchase history are read from each window holder''s CURRENT row, not '
      're-filtered to session-use events inside the window (see the migration header, judgement '
      'call 4).',
    'plans', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'plan_id', p.plan_id, 'plan_name', p.plan_name,
               'sold_count', p.sold_count,
               'sessions_included', p.sessions_included,
               'sessions_used', p.sessions_used,
               'utilisation',
                 case when p.evidence ->> 'status' = 'ok'
                      then app.rate_block_v1(p.sessions_used, p.sessions_included)
                      else jsonb_build_object('numerator', p.sessions_used,
                                               'denominator', p.sessions_included, 'pct', null) end,
               'median_days_between_sessions',
                 case when p.evidence ->> 'status' = 'ok' and p.n_events >= 3
                      then round(p.raw_median::numeric, 1) else null end,
               'expired_or_lapsed_with_unused', p.expired_or_lapsed_with_unused,
               'repurchase_count', p.repurchase_count,
               'outside_spend_cents', p.outside_spend_cents,
               'evidence', p.evidence
             ) order by p.sold_count desc, p.plan_id), '[]'::jsonb)
        from plans p
    ),
    'observed_since', app.metric_observed_since_v1('ci_package_intelligence', p_business)
  ) into v_result;

  return app.ci_envelope_v680('ci_package_intelligence_v1', p_business, null, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, null, p_from, p_to, p_as_of), v_result);
end;
$function$;
revoke all on function public.get_ci_package_intelligence_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_package_intelligence_v1(uuid,date,date,uuid,timestamptz)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 4 · v667 — get_ci_category_mix_v1 / get_ci_category_customers_v1 / get_ci_acquisition_v1
-- ---------------------------------------------------------------------------------------------
drop function if exists public.get_ci_category_mix_v1(uuid,date,date,uuid);
create or replace function public.get_ci_category_mix_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  with lines as (
    select si.line_cents, s.client_id, en.node_key as eff_node, en.classification,
           coalesce(n.parent_key, n.node_key) as l2_key,
           case when n.level = 3 then n.node_key end as l3_key
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      cross join lateral app.ci_effective_node_v650(si) en
      left join public.taxonomy_nodes n on n.version_no = 1 and n.node_key = en.node_key
     where si.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.created_at <= p_as_of
       and s.reversal_of is null
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and coalesce(s.counts_as_revenue, false)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and si.item_type in ('service','retail')
       and si.line_cents > 0
       and not coalesce((select c.is_synthetic from public.clients c where c.id = s.client_id), false)
  ),
  totals as (
    select coalesce(sum(line_cents),0) as total_rev,
           coalesce(sum(line_cents) filter (where eff_node is not null),0) as classified_rev,
           coalesce(sum(line_cents) filter (where eff_node is not null and classification='projected'),0) as projected_rev
      from lines
  ),
  l3 as (
    select l2_key, l3_key, sum(line_cents) as rev
      from lines where l3_key is not null group by l2_key, l3_key
  ),
  l2 as (
    select l.l2_key,
           max(n2.label) as label,
           sum(l.line_cents) as rev,
           count(*) as line_count,
           count(distinct l.client_id) as customer_count,
           case when sum(l.line_cents) > 0
             then (10000.0 * coalesce(sum(l.line_cents) filter (where l.classification='projected'),0) / sum(l.line_cents))::int
             else 0 end as projected_share_bps
      from lines l
      left join public.taxonomy_nodes n2 on n2.version_no = 1 and n2.node_key = l.l2_key
     where l.l2_key is not null
     group by l.l2_key
  )
  select jsonb_build_object(
    'status', case when t.total_rev = 0 then 'empty' else 'ready' end,
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'node_key', l2.l2_key, 'label', l2.label,
        'revenue_cents', l2.rev, 'line_count', l2.line_count,
        'customer_count', l2.customer_count,
        'projected_share_bps', l2.projected_share_bps,
        'children', coalesce((select jsonb_agg(jsonb_build_object(
                       'node_key', l3.l3_key, 'revenue_cents', l3.rev) order by l3.rev desc)
                       from l3 where l3.l2_key = l2.l2_key), '[]'::jsonb))
        order by l2.rev desc)
        from l2), '[]'::jsonb),
    'coverage', jsonb_build_object(
      'stampable_revenue_cents', t.total_rev,
      'classified_pct_bps', case when t.total_rev > 0
        then (10000.0 * t.classified_rev / t.total_rev)::int else null end,
      'projected_share_bps', case when t.classified_rev > 0
        then (10000.0 * t.projected_rev / t.classified_rev)::int else null end),
    'observed_since', app.metric_observed_since_v1('category_snapshots', p_business))
    into v_result
    from totals t;

  return app.ci_envelope_v680('ci_category_mix_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_category_mix_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_category_mix_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

drop function if exists public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid);
create or replace function public.get_ci_category_customers_v1(
  p_business uuid, p_node_key text, p_from date, p_to date,
  p_limit integer default 100, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_rows jsonb;
  v_count integer;
  v_floor constant integer := 5;
  v_env jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if not exists (select 1 from public.taxonomy_nodes n
                  where n.version_no = 1 and n.node_key = p_node_key) then
    raise exception 'unknown taxonomy node %', p_node_key using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(rec order by (rec->>'revenue_cents')::bigint desc), '[]'::jsonb)
    into v_rows
    from (
      select jsonb_build_object(
        'client_id', s.client_id,
        'full_name', max(c.full_name),
        'visits', count(distinct s.id),
        'revenue_cents', sum(si.line_cents),
        'last_visit', max((s.occurred_at at time zone 'Asia/Singapore')::date)
      ) as rec
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      join public.clients c on c.id = s.client_id
      cross join lateral app.ci_effective_node_v650(si) en
     where si.business_id = p_business
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
     limit greatest(1, least(coalesce(p_limit, 100), 500))
    ) t;

  v_count := jsonb_array_length(v_rows);
  v_env := app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of);

  if v_count > 0 and v_count < v_floor then
    return app.ci_envelope_v680('ci_category_customers_v1', p_business, p_branch, p_from, p_to,
      p_as_of, v_env, jsonb_build_object(
      'node_key', p_node_key,
      'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                  'from', p_from, 'to', p_to),
      'customers', '[]'::jsonb,
      'suppressed', jsonb_build_object(
        'reason', 'below_small_cell_floor',
        'floor', v_floor,
        'cohort_size', v_count,
        'note', 'Naming a cohort this small would identify its members.'),
      'observed_since', app.metric_observed_since_v1('category_snapshots', p_business)));
  end if;

  return app.ci_envelope_v680('ci_category_customers_v1', p_business, p_branch, p_from, p_to,
    p_as_of, v_env, jsonb_build_object(
    'node_key', p_node_key,
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'customers', v_rows,
    'suppressed', null,
    'observed_since', app.metric_observed_since_v1('category_snapshots', p_business)));
end;
$$;
revoke all on function public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz) to authenticated, service_role;

drop function if exists public.get_ci_acquisition_v1(uuid,date,date,uuid);
create or replace function public.get_ci_acquisition_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_rows jsonb; v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_no_branch_dimension_v667(p_branch, 'acquisition');
  select coalesce(jsonb_agg(rec order by (rec->>'customers')::int desc), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
        'via', c.first_acquired_via,
        'evidence', c.first_acquired_evidence,
        'customers', count(*),
        'new_in_period', count(*) filter (
          where (c.created_at at time zone 'Asia/Singapore')::date between p_from and p_to),
        'repeat_customers', count(*) filter (where (
          select count(*) from public.sales s
           where s.business_id = p_business and s.client_id = c.id
             and coalesce(s.counts_as_visit, false) and s.reversal_of is null
             and s.created_at <= p_as_of) >= 2)
      ) as rec
      from public.clients c
     where c.business_id = p_business and not coalesce(c.is_synthetic, false)
       and c.created_at <= p_as_of
     group by c.first_acquired_via, c.first_acquired_evidence
    ) t;
  v_result := jsonb_build_object('sources', v_rows,
    'observed_since', app.metric_observed_since_v1('first_acquisition', p_business));

  return app.ci_envelope_v680('ci_acquisition_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_acquisition_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_acquisition_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 5 · v678 — get_ci_opportunities_v1: p_as_of threaded to every sub-reader it consumes, plus a
--     'freshness' block and a stale-evidence refusal
-- ---------------------------------------------------------------------------------------------
drop function if exists public.get_ci_opportunities_v1(uuid,date,date,uuid);
create or replace function public.get_ci_opportunities_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  c_funnel_window   constant integer := 60;
  c_gap_pp          constant numeric := 15.0;
  c_util_pct        constant numeric := 50.0;
  c_conc_bps        constant integer := 6000;
  c_daypart_ratio   constant numeric := 2.0;
  c_gateway_min     constant integer := 5;
  c_reach_pct       constant numeric := 50.0;
  c_classified_bps  constant integer := 9000;
  c_demog_pct       constant numeric := 50.0;
  c_stale_days      constant integer := 400;
  c_stale_period_days constant integer := 90;

  v_funnel      jsonb;
  v_daypart     jsonb;
  v_svc         jsonb;
  v_pkg         jsonb;
  v_catmix      jsonb;
  v_contact     jsonb;
  v_demog       jsonb;

  v_cands       jsonb := '[]'::jsonb;
  v_abst        jsonb := '[]'::jsonb;
  v_ranked      jsonb;
  v_examined    integer := 0;
  v_promoted    integer := 0;

  v_f_d1        bigint;
  v_f_d2        bigint;
  v_f_p1        numeric;
  v_f_p2        numeric;
  v_f_stage     text;
  v_f_conf      jsonb;

  v_conf        jsonb;
  v_hi          jsonb;
  v_lo          jsonb;
  v_busiest     jsonb;
  v_valuable    jsonb;
  v_top         jsonb;
  v_classified  bigint;
  v_share_bps   integer;

  v_lapsed_n    integer;
  v_lapsed_sum  bigint;

  v_plan        record;
  v_service     record;
  v_n_entities  integer;
  v_unused      bigint;
  v_unit        bigint;

  v_bo          jsonb;
  v_customers   bigint;
  v_best        bigint;
  v_best_ch     text;

  v_classified_bps integer;
  v_demog_pct   numeric;
  v_identified  bigint;

  v_obs_min     timestamptz;
  v_stale       boolean;
  v_period_far  boolean;
  v_refusal     text;
  v_result      jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  -- =============================================================================================
  -- GENERATOR A · retention funnel — a named bottleneck with a material gap between the stages
  -- =============================================================================================
  v_examined := v_examined + 1;
  v_funnel := public.get_ci_funnel_conversion_v1(p_business, p_from, p_to, c_funnel_window, p_branch, p_as_of);
  v_f_d1 := (v_funnel->'stage_1_to_2'->>'denominator')::bigint;
  v_f_d2 := (v_funnel->'stage_2_to_3'->>'denominator')::bigint;
  v_f_p1 := (v_funnel->'stage_1_to_2'->>'pct')::numeric;
  v_f_p2 := (v_funnel->'stage_2_to_3'->>'pct')::numeric;
  v_f_stage := v_funnel->>'bottleneck';
  v_f_conf := app.subgroup_evidence_v1(least(coalesce(v_f_d1, 0), coalesce(v_f_d2, 0))::int);

  if v_f_stage is null or v_f_p1 is null or v_f_p2 is null then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'funnel_bottleneck',
      'reason', 'no bottleneck is nameable: a stage rate is null or the two stages are tied'));
  elsif v_f_conf->>'status' <> 'ok' then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'funnel_bottleneck',
      'reason', format('smallest stage denominator (%s) is below the sample floor of %s',
                        v_f_conf->>'n', v_f_conf->>'floor')));
  elsif abs(v_f_p1 - v_f_p2) < c_gap_pp then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'funnel_bottleneck',
      'reason', format('the stages differ by %s points, below the %s-point materiality bar',
                        round(abs(v_f_p1 - v_f_p2), 1), c_gap_pp)));
  else
    v_cands := v_cands || jsonb_build_array(jsonb_build_object(
      'id', 'funnel_bottleneck',
      'domain', 'retention_funnel',
      'pattern', format(
        'Of %s customers whose first visit matured, %s%% came back for a second within %s days, '
        'and %s%% of those went on to a third; the %s step is the weaker of the two by %s points.',
        v_f_d1, v_f_p1, c_funnel_window, v_f_p2, replace(v_f_stage, '_', '-'),
        round(abs(v_f_p1 - v_f_p2), 1)),
      'comparison', jsonb_build_object(
        'kind', 'cross_segment',
        'detail', format('first-to-second conversion (%s%%, n=%s) against second-to-third '
                          '(%s%%, n=%s), both on the same %s-day maturity rule',
                          v_f_p1, v_f_d1, v_f_p2, v_f_d2, c_funnel_window)),
      'impact', jsonb_build_object(
        'cents', null,
        'reason', 'no incremental model: converting a funnel gap into cents requires an assumed '
                  'uplift, which would be a forecast rather than a measurement'),
      'action', jsonb_build_object(
        'who', 'the owner, with the staff who serve the visit before the drop',
        'what', format('Fix the %s drop-off — rework what happens at the end of that visit '
                        '(rebook on the spot, name the next appointment, hand over the follow-up '
                        'offer) rather than adding another campaign upstream of it.',
                        replace(v_f_stage, '_', '-')),
        'when', 'within the next full ' || c_funnel_window || '-day cycle, so the change is measurable',
        'channel', 'in_person_at_checkout'),
      'evidence', jsonb_build_object(
        'source_rpc', 'public.get_ci_funnel_conversion_v1',
        'refs', jsonb_build_object(
          'stage_1_to_2', v_funnel->'stage_1_to_2',
          'stage_2_to_3', v_funnel->'stage_2_to_3',
          'bottleneck', v_f_stage,
          'immature', v_funnel->'immature',
          'window_days', v_funnel->'window_days',
          'reader_evidence', v_funnel->'evidence')),
      'evidence_class', 'DIRECT_FACT',
      'confidence', v_f_conf,
      'limitation',
        'Both rates are measured on customers who have already had a full window, so a recent '
        'change in how the firm operates is not visible here yet, and the two stages are not the '
        'same people — the second-to-third denominator is a self-selected subset of the first.',
      'rank_class', 'unquantified'));
  end if;

  -- =============================================================================================
  -- GENERATOR B · lapsed regulars — customers overdue against their OWN median rhythm
  -- =============================================================================================
  v_examined := v_examined + 1;
  if p_branch is not null then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'lapsed_regulars',
      'reason', 'no branch dimension: app.customer_cadence_v1 resolves the v107 lifecycle policy '
                'firm-wide and emits deviation_state only for a firm-wide computation'));
  else
    with overdue as materialized (
      select b.client_id
        from app.customer_cadence_batch_v1(
               p_business,
               ((p_as_of at time zone 'Asia/Singapore')::date + 1),
               ((p_as_of at time zone 'Asia/Singapore')::date + 1),
               p_as_of, null, true) b
        cross join lateral (
          select app.customer_cadence_v1(p_business, b.client_id) as cad
        ) c
       where c.cad->>'deviation_state' = 'overdue'
         and c.cad->>'evidence_source' = 'customer_median_interval'
    ),
    tickets as (
      select o.client_id,
             round(sum(s.amount_cents)::numeric / count(*)) as avg_ticket
        from overdue o
        join public.sales s
          on s.business_id = p_business
         and app.v111_effective_client_id(s.business_id, s.client_id) = o.client_id
        cross join lateral app.analytics_sale_class_v1(s) sc
       where sc.include_revenue
         and not sc.is_synthetic_client
         and s.created_at <= p_as_of
       group by o.client_id
    )
    select count(*)::int, coalesce(sum(coalesce(t.avg_ticket, 0)), 0)::bigint
      into v_lapsed_n, v_lapsed_sum
      from overdue o
      left join tickets t on t.client_id = o.client_id;

    v_conf := app.subgroup_evidence_v1(coalesce(v_lapsed_n, 0));
    if coalesce(v_lapsed_n, 0) = 0 then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'lapsed_regulars',
        'reason', 'no customer is overdue against a rhythm of their own: every overdue customer '
                  'is judged on the business fallback, which says nothing about that person'));
    elsif v_conf->>'status' <> 'ok' then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'lapsed_regulars',
        'reason', format('%s overdue regular(s) is below the sample floor of %s',
                          v_conf->>'n', v_conf->>'floor')));
    else
      v_cands := v_cands || jsonb_build_array(jsonb_build_object(
        'id', 'lapsed_regulars',
        'domain', 'cadence',
        'pattern', format(
          '%s customers with an established visit rhythm are now overdue against their OWN median '
          'interval; one return visit each at their own historical average ticket is worth %s cents.',
          v_lapsed_n, v_lapsed_sum),
        'comparison', jsonb_build_object(
          'kind', 'baseline',
          'detail', 'each customer is compared against their own median inter-visit interval '
                    '(app.customer_cadence_v1, evidence_source=customer_median_interval), never '
                    'against a firm-wide days-since-last-visit cut-off'),
        'impact', jsonb_build_object(
          'cents', v_lapsed_sum,
          'method', 'sum over the overdue regulars of round(that customer''s lifetime '
                    'revenue-qualifying sale total / their count of such sales) — one visit each, '
                    'at their own average ticket. No response rate, no uplift, no discounting.'),
        'action', jsonb_build_object(
          'who', 'front desk',
          'what', 'Contact these customers individually, referencing what they last had and when, '
                  'before offering anything — the list is small enough to work by hand and a '
                  'discount is not what a customer with a broken rhythm is missing.',
          'when', 'this week',
          'channel', 'whatsapp_or_call_where_consent_exists'),
        'evidence', jsonb_build_object(
          'source_rpc', 'app.customer_cadence_batch_v1 + app.customer_cadence_v1',
          'refs', jsonb_build_object(
            'overdue_regulars', v_lapsed_n,
            'recoverable_cents', v_lapsed_sum,
            'deviation_state', 'overdue',
            'evidence_source', 'customer_median_interval')),
        'evidence_class', 'ASSOCIATION',
        'confidence', v_conf,
        'limitation',
          'An overdue customer is not a lost customer: some would have returned unprompted, so '
          'the figure is the value at stake, not the value a campaign would add.',
        'rank_class', 'quantified'));
    end if;
  end if;

  -- =============================================================================================
  -- GENERATOR C · dead-vs-gold weekday — the busiest day is not the valuable one
  -- =============================================================================================
  v_examined := v_examined + 1;
  v_daypart := public.get_ci_daypart_v1(p_business, p_from, p_to, p_branch, p_as_of);
  v_busiest := v_daypart->'busiest_weekday';
  v_valuable := v_daypart->'most_valuable_weekday';

  select w into v_hi
    from jsonb_array_elements(coalesce(v_daypart->'weekdays', '[]'::jsonb)) w
   where w->'evidence'->>'status' = 'ok'
     and w->>'revenue_per_visit_cents' is not null
     and (w->>'revenue_per_visit_cents')::numeric > 0
   order by (w->>'revenue_per_visit_cents')::numeric desc, (w->>'dow')::int
   limit 1;
  select w into v_lo
    from jsonb_array_elements(coalesce(v_daypart->'weekdays', '[]'::jsonb)) w
   where w->'evidence'->>'status' = 'ok'
     and w->>'revenue_per_visit_cents' is not null
     and (w->>'revenue_per_visit_cents')::numeric > 0
   order by (w->>'revenue_per_visit_cents')::numeric asc, (w->>'dow')::int
   limit 1;

  if v_busiest is null or v_valuable is null or v_valuable->>'dow' is null then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'daypart_shift',
      'reason', 'no weekday clears the evidence floor, so no weekday may be called most valuable'));
  elsif (v_busiest->>'dow')::int = (v_valuable->>'dow')::int then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'daypart_shift',
      'reason', format('the busiest and most valuable weekday are the same day (%s); there is no '
                        'capacity to shift', v_busiest->>'label')));
  elsif v_hi is null or v_lo is null
        or (v_hi->>'dow')::int = (v_lo->>'dow')::int
        or (v_hi->>'revenue_per_visit_cents')::numeric
             < c_daypart_ratio * (v_lo->>'revenue_per_visit_cents')::numeric then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'daypart_shift',
      'reason', format('no pair of evidence-backed weekdays differs by %sx in revenue per visit',
                        c_daypart_ratio)));
  else
    v_conf := app.subgroup_evidence_v1(least((v_hi->>'visits')::int, (v_lo->>'visits')::int));
    if v_conf->>'status' <> 'ok' then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'daypart_shift',
        'reason', 'the thinner of the two compared weekdays is below the sample floor'));
    else
      v_cands := v_cands || jsonb_build_array(jsonb_build_object(
        'id', 'daypart_shift',
        'domain', 'daypart',
        'pattern', format(
          '%s takes %s cents per visit against %s''s %s — %sx — while %s is the busiest day by '
          'volume (%s visits).',
          v_hi->>'label', v_hi->>'revenue_per_visit_cents', v_lo->>'label',
          v_lo->>'revenue_per_visit_cents',
          round((v_hi->>'revenue_per_visit_cents')::numeric
                 / nullif((v_lo->>'revenue_per_visit_cents')::numeric, 0), 1),
          v_busiest->>'label', v_busiest->>'visits'),
        'comparison', jsonb_build_object(
          'kind', 'cross_segment',
          'detail', format('%s (n=%s visits) against %s (n=%s visits), both above the sample floor, '
                            'each measured over the same number of weekday occurrences in the window',
                            v_hi->>'label', v_hi->>'visits', v_lo->>'label', v_lo->>'visits')),
        'impact', jsonb_build_object(
          'cents', null,
          'reason', 'no incremental model: moving capacity between weekdays has no measured '
                    'counterfactual here, and assuming the gold day''s per-visit value would '
                    'survive extra volume is exactly the assumption that must not be smuggled in'),
        'action', jsonb_build_object(
          'who', 'the owner, with whoever writes the rota',
          'what', format('Shift capacity and promotion toward %s — staff it first, book the '
                          'higher-value work into it, and stop spending promotion on %s, which is '
                          'already full of low-value visits.',
                          v_valuable->>'label', v_busiest->>'label'),
          'when', 'next rota cycle',
          'channel', 'rota_and_promotions'),
        'evidence', jsonb_build_object(
          'source_rpc', 'public.get_ci_daypart_v1',
          'refs', jsonb_build_object(
            'gold_weekday', v_hi,
            'dead_weekday', v_lo,
            'busiest_weekday', v_busiest,
            'most_valuable_weekday', v_valuable,
            'time_basis', v_daypart->'time_basis')),
        'evidence_class', 'ASSOCIATION',
        'confidence', v_conf,
        'limitation',
          'Revenue per visit is a mix effect as much as a day effect: the valuable day may simply '
          'be when the expensive service is offered, and the till timestamp is not arrival time.',
        'rank_class', 'unquantified'));
    end if;
  end if;

  -- =============================================================================================
  -- GENERATOR D · category concentration — diversification risk
  -- =============================================================================================
  v_examined := v_examined + 1;
  v_catmix := public.get_ci_category_mix_v1(p_business, p_from, p_to, p_branch, p_as_of);
  select coalesce(sum((c->>'revenue_cents')::bigint), 0) into v_classified
    from jsonb_array_elements(coalesce(v_catmix->'categories', '[]'::jsonb)) c;
  select c into v_top
    from jsonb_array_elements(coalesce(v_catmix->'categories', '[]'::jsonb)) c
   order by (c->>'revenue_cents')::bigint desc, c->>'node_key'
   limit 1;

  if v_top is null or coalesce(v_classified, 0) <= 0 then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'category_concentration',
      'reason', 'no classified revenue in the window, so no share can be computed'));
  else
    v_share_bps := (10000.0 * (v_top->>'revenue_cents')::bigint / v_classified)::int;
    v_conf := app.subgroup_evidence_v1((v_top->>'customer_count')::int);
    if v_share_bps < c_conc_bps then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'category_concentration',
        'reason', format('the largest category holds %s bps of classified revenue, below the %s '
                          'bps concentration bar', v_share_bps, c_conc_bps)));
    elsif v_conf->>'status' <> 'ok' then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'category_concentration',
        'reason', format('the largest category has %s customer(s), below the sample floor of %s',
                          v_conf->>'n', v_conf->>'floor')));
    else
      v_cands := v_cands || jsonb_build_array(jsonb_build_object(
        'id', 'category_concentration',
        'domain', 'category_mix',
        'pattern', format(
          '%s cents of %s cents of classified revenue — %s%% — comes from a single category (%s), '
          'bought by %s customers.',
          v_top->>'revenue_cents', v_classified, round(v_share_bps / 100.0, 1),
          coalesce(v_top->>'label', v_top->>'node_key'), v_top->>'customer_count'),
        'comparison', jsonb_build_object(
          'kind', 'threshold',
          'detail', format('largest level-2 category share of CLASSIFIED revenue (%s bps) against '
                            'the %s bps concentration bar; unclassified revenue is deliberately '
                            'outside the denominator', v_share_bps, c_conc_bps)),
        'impact', jsonb_build_object(
          'cents', null,
          'reason', 'concentration is an exposure profile, not a cash figure; the amount at risk '
                    'is the category revenue already stated, and how much of it would actually '
                    'move is unmeasurable from this data'),
        'action', jsonb_build_object(
          'who', 'the owner',
          'what', format('Treat %s as a single point of failure: know what a price, staffing or '
                          'demand change there does to the month, and pick ONE adjacent category '
                          'to grow deliberately rather than diversifying everywhere at once.',
                          coalesce(v_top->>'label', v_top->>'node_key')),
          'when', 'this quarter',
          'channel', 'planning'),
        'evidence', jsonb_build_object(
          'source_rpc', 'public.get_ci_category_mix_v1',
          'refs', jsonb_build_object(
            'top_category', v_top,
            'classified_revenue_cents', v_classified,
            'top_share_bps', v_share_bps,
            'coverage', v_catmix->'coverage')),
        'evidence_class', 'DIRECT_FACT',
        'confidence', v_conf,
        'limitation',
          'A concentrated mix is not automatically a fault — a specialist earns its living that '
          'way — and this share is computed only over revenue that was classified at all.',
        'rank_class', 'unquantified'));
    end if;
  end if;

  -- =============================================================================================
  -- GENERATOR E · package leakage — prepaid sessions nobody is using (one candidate per plan)
  -- =============================================================================================
  if p_branch is not null then
    v_examined := v_examined + 1;
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'package_leakage',
      'reason', 'no branch dimension: client_packages carries no branch column (v675), so a '
                'branch-scoped utilisation figure cannot be produced honestly'));
  else
    v_pkg := public.get_ci_package_intelligence_v1(p_business, p_from, p_to, null, p_as_of);
    v_n_entities := coalesce(jsonb_array_length(v_pkg->'plans'), 0);
    v_examined := v_examined + greatest(1, v_n_entities);
    if v_n_entities = 0 then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'package_leakage',
        'reason', 'no package plan had a purchase inside the window'));
    end if;
    for v_plan in
      select e.value as p from jsonb_array_elements(coalesce(v_pkg->'plans', '[]'::jsonb)) e
    loop
      if v_plan.p->'evidence'->>'status' <> 'ok' then
        v_abst := v_abst || jsonb_build_array(jsonb_build_object(
          'generator', 'package_leakage:' || (v_plan.p->>'plan_id'),
          'reason', format('%s package(s) sold in the window is below the sample floor of %s',
                            v_plan.p->'evidence'->>'n', v_plan.p->'evidence'->>'floor')));
      elsif v_plan.p->'utilisation'->>'pct' is null
            or (v_plan.p->'utilisation'->>'pct')::numeric >= c_util_pct then
        v_abst := v_abst || jsonb_build_array(jsonb_build_object(
          'generator', 'package_leakage:' || (v_plan.p->>'plan_id'),
          'reason', format('utilisation is %s%%, at or above the %s%% leakage bar',
                            coalesce(v_plan.p->'utilisation'->>'pct', 'null'), c_util_pct)));
      else
        v_unused := (v_plan.p->>'sessions_included')::bigint
                     - (v_plan.p->>'sessions_used')::bigint;
        select round(pp.price_cents::numeric / nullif(pp.sessions, 0))::bigint into v_unit
          from public.package_plans pp
         where pp.id = (v_plan.p->>'plan_id')::uuid and pp.business_id = p_business;
        if v_unit is null or v_unused <= 0 then
          v_abst := v_abst || jsonb_build_array(jsonb_build_object(
            'generator', 'package_leakage:' || (v_plan.p->>'plan_id'),
            'reason', 'no unused sessions, or the plan carries no per-session price to value them'));
        else
          v_cands := v_cands || jsonb_build_array(jsonb_build_object(
            'id', 'package_leakage:' || (v_plan.p->>'plan_id'),
            'domain', 'packages',
            'pattern', format(
              '%s of %s sessions sold on "%s" are still unused (%s%% utilisation across %s '
              'packages), worth %s cents of prepaid service at %s cents a session.',
              v_unused, v_plan.p->>'sessions_included', v_plan.p->>'plan_name',
              v_plan.p->'utilisation'->>'pct', v_plan.p->>'sold_count',
              v_unused * v_unit, v_unit),
            'comparison', jsonb_build_object(
              'kind', 'threshold',
              'detail', format('plan utilisation %s%% against the %s%% bar, on %s packages sold '
                                'inside the window', v_plan.p->'utilisation'->>'pct', c_util_pct,
                                v_plan.p->>'sold_count')),
            'impact', jsonb_build_object(
              'cents', v_unused * v_unit,
              'method', format('(sessions_included %s - sessions_used %s) x round(plan price / '
                                'plan sessions) = %s x %s. The session count comes from '
                                'get_ci_package_intelligence_v1; the per-session unit from '
                                'public.package_plans, which the payload does not carry.',
                                v_plan.p->>'sessions_included', v_plan.p->>'sessions_used',
                                v_unused, v_unit)),
            'action', jsonb_build_object(
              'who', 'front desk',
              'what', format('Book the unused "%s" sessions out: call every holder with sessions '
                              'left and put a date in the diary on the call, rather than waiting '
                              'for them to come back on their own.', v_plan.p->>'plan_name'),
              'when', 'this month',
              'channel', 'call_or_whatsapp_where_consent_exists'),
            'evidence', jsonb_build_object(
              'source_rpc', 'public.get_ci_package_intelligence_v1 + public.package_plans',
              'refs', jsonb_build_object(
                'plan_id', v_plan.p->'plan_id',
                'plan_name', v_plan.p->'plan_name',
                'sold_count', v_plan.p->'sold_count',
                'sessions_included', v_plan.p->'sessions_included',
                'sessions_used', v_plan.p->'sessions_used',
                'utilisation', v_plan.p->'utilisation',
                'expired_or_lapsed_with_unused', v_plan.p->'expired_or_lapsed_with_unused',
                'unused_sessions', v_unused,
                'per_session_cents', v_unit)),
            'evidence_class', 'DIRECT_FACT',
            'confidence', v_plan.p->'evidence',
            'limitation',
              'This is prepaid service at risk of lapsing, not new revenue: the money was already '
              'recognised when the package was sold, and a holder who bought at an older price is '
              'valued here at the plan''s current list price.',
            'rank_class', 'quantified'));
        end if;
      end if;
    end loop;
  end if;

  -- =============================================================================================
  -- GENERATOR F · gateway services whose buyers do not come back (one candidate per service)
  -- =============================================================================================
  v_svc := public.get_ci_service_intelligence_v1(p_business, p_from, p_to, p_branch, p_as_of);
  v_n_entities := coalesce(jsonb_array_length(v_svc->'services'), 0);
  v_examined := v_examined + greatest(1, v_n_entities);
  if v_f_p1 is null or v_f_conf->>'status' <> 'ok' then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'gateway_followthrough',
      'reason', 'the firm''s own first-to-second funnel rate is unavailable or below the sample '
                'floor, so there is no baseline to judge a service against'));
  elsif v_n_entities = 0 then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'gateway_followthrough',
      'reason', 'no service was bought inside the window'));
  else
    for v_service in
      select e.value as s from jsonb_array_elements(coalesce(v_svc->'services', '[]'::jsonb)) e
    loop
      if (v_service.s->>'gateway_count')::int < c_gateway_min then
        v_abst := v_abst || jsonb_build_array(jsonb_build_object(
          'generator', 'gateway_followthrough:' || (v_service.s->>'service_id'),
          'reason', format('%s first-ever buyers is below the %s needed to call it a gateway',
                            v_service.s->>'gateway_count', c_gateway_min)));
      elsif v_service.s->'evidence'->>'status' <> 'ok'
            or v_service.s->'repeat_rate'->>'pct' is null then
        v_abst := v_abst || jsonb_build_array(jsonb_build_object(
          'generator', 'gateway_followthrough:' || (v_service.s->>'service_id'),
          'reason', 'the service''s buyer count is below the sample floor, so its repeat rate is '
                    'withheld and cannot be compared'));
      elsif v_f_p1 - (v_service.s->'repeat_rate'->>'pct')::numeric < c_gap_pp then
        v_abst := v_abst || jsonb_build_array(jsonb_build_object(
          'generator', 'gateway_followthrough:' || (v_service.s->>'service_id'),
          'reason', format('repeat rate %s%% trails the firm''s %s%% by less than %s points',
                            v_service.s->'repeat_rate'->>'pct', v_f_p1, c_gap_pp)));
      else
        v_conf := app.subgroup_evidence_v1(
                    least((v_service.s->>'buyers')::int, coalesce(v_f_d1, 0)::int));
        if v_conf->>'status' <> 'ok' then
          v_abst := v_abst || jsonb_build_array(jsonb_build_object(
            'generator', 'gateway_followthrough:' || (v_service.s->>'service_id'),
            'reason', 'the smaller of the service''s buyers and the funnel denominator is below '
                      'the sample floor'));
        else
          v_cands := v_cands || jsonb_build_array(jsonb_build_object(
            'id', 'gateway_followthrough:' || (v_service.s->>'service_id'),
            'domain', 'service_intelligence',
            'pattern', format(
              '"%s" is how %s customers first arrived, but only %s%% of its %s buyers bought it '
              'again, against a firm-wide first-to-second rate of %s%% — %s points behind.',
              v_service.s->>'service_name', v_service.s->>'gateway_count',
              v_service.s->'repeat_rate'->>'pct', v_service.s->>'buyers', v_f_p1,
              round(v_f_p1 - (v_service.s->'repeat_rate'->>'pct')::numeric, 1)),
            'comparison', jsonb_build_object(
              'kind', 'baseline',
              'detail', format('this service''s repeat rate (%s of %s buyers) against the firm''s '
                                'own first-to-second conversion (%s%%, n=%s) as the baseline',
                                v_service.s->'repeat_rate'->>'numerator',
                                v_service.s->'repeat_rate'->>'denominator', v_f_p1, v_f_d1)),
            'impact', jsonb_build_object(
              'cents', null,
              'reason', 'no incremental model: the gap says the first experience under-converts, '
                        'not how much revenue a better one would add'),
            'action', jsonb_build_object(
              'who', 'the owner, with the staff who deliver this service',
              'what', format('Fix the first-visit experience for "%s": watch the appointment end '
                              'to end, decide what the next step should be for someone who has '
                              'only ever had this one thing, and make offering it part of the '
                              'service rather than an afterthought.', v_service.s->>'service_name'),
              'when', 'within the month',
              'channel', 'in_person_at_the_appointment'),
            'evidence', jsonb_build_object(
              'source_rpc', 'public.get_ci_service_intelligence_v1 + '
                            'public.get_ci_funnel_conversion_v1',
              'refs', jsonb_build_object(
                'service_id', v_service.s->'service_id',
                'service_name', v_service.s->'service_name',
                'buyers', v_service.s->'buyers',
                'orders', v_service.s->'orders',
                'revenue_cents', v_service.s->'revenue_cents',
                'gateway_count', v_service.s->'gateway_count',
                'repeat_rate', v_service.s->'repeat_rate',
                'firm_stage_1_to_2', v_funnel->'stage_1_to_2')),
            'evidence_class', 'ASSOCIATION',
            'confidence', v_conf,
            'limitation',
              'Whoever chooses this service is not a random draw from the firm''s first-timers, so '
              'the gap may be who they are rather than what happened to them.',
            'rank_class', 'unquantified'));
        end if;
      end if;
    end loop;
  end if;

  -- =============================================================================================
  -- GENERATOR G · contactability — most customers cannot legally be reached at all
  -- =============================================================================================
  v_examined := v_examined + 1;
  if p_branch is not null then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'contactability_gap',
      'reason', 'no branch dimension: consent is recorded per business, not per branch'));
  else
    v_contact := public.get_ci_contactability_v1(p_business, null);
    v_bo := v_contact->'business_offers';
    v_customers := (v_bo->>'customers')::bigint;
    select e.key, e.value::bigint into v_best_ch, v_best
      from jsonb_each_text(coalesce(v_bo->'allowed_by_channel', '{}'::jsonb)) e
     order by e.value::bigint desc, e.key
     limit 1;
    v_conf := app.subgroup_evidence_v1(coalesce(v_customers, 0)::int);
    if coalesce(v_customers, 0) = 0 or v_conf->>'status' <> 'ok' then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'contactability_gap',
        'reason', format('%s identified customer(s) is below the sample floor of %s',
                          v_conf->>'n', v_conf->>'floor')));
    elsif 100.0 * coalesce(v_best, 0) / v_customers >= c_reach_pct then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'contactability_gap',
        'reason', format('the best channel reaches %s%% of customers, at or above the %s%% bar',
                          round(100.0 * coalesce(v_best, 0) / v_customers, 1), c_reach_pct)));
    else
      v_cands := v_cands || jsonb_build_array(jsonb_build_object(
        'id', 'contactability_gap',
        'domain', 'contactability',
        'pattern', format(
          'Only %s of %s customers (%s%%) can lawfully be sent a business offer on the best '
          'available channel (%s); the rest have no affirmative consent on record.',
          coalesce(v_best, 0), v_customers,
          round(100.0 * coalesce(v_best, 0) / v_customers, 1), v_best_ch),
        'comparison', jsonb_build_object(
          'kind', 'threshold',
          'detail', format('best single-channel reachable share (%s of %s) against the %s%% bar; '
                            'the best channel is used because per-channel counts cannot be unioned '
                            'from the reader''s payload, which makes this an under-statement of '
                            'reach, never an over-statement',
                            coalesce(v_best, 0), v_customers, c_reach_pct)),
        'impact', jsonb_build_object(
          'cents', null,
          'reason', 'no incremental model: the value of being able to contact someone depends on '
                    'what would be said to them, which does not exist yet'),
        'action', jsonb_build_object(
          'who', 'front desk',
          'what', 'Ask for consent at checkout, in person, with the notice shown — one question '
                  'at the point of payment, recorded per channel. Do not bulk-import or assume '
                  'existing customers are opted in.',
          'when', 'starting immediately, reviewed in 30 days',
          'channel', 'in_person_at_checkout'),
        'evidence', jsonb_build_object(
          'source_rpc', 'public.get_ci_contactability_v1',
          'refs', jsonb_build_object(
            'business_offers', v_bo,
            'best_channel', v_best_ch,
            'best_channel_allowed', coalesce(v_best, 0),
            'note', v_contact->'note')),
        'evidence_class', 'DIRECT_FACT',
        'confidence', v_conf,
        'limitation',
          'A customer unreachable for marketing is still reachable for a booking they asked for; '
          'this counts consent for proactive offers only, and a customer with two channels is '
          'counted once per channel, so the true reachable union is somewhere between the best '
          'channel and their sum.',
        'rank_class', 'unquantified'));
    end if;
  end if;

  -- =============================================================================================
  -- GENERATOR H · data quality (check 30) — a FOUNDATION candidate, ranked above business advice
  -- =============================================================================================
  v_examined := v_examined + 1;
  v_demog := public.get_ci_demographics_v1(p_business, p_from, p_to, p_branch, p_as_of);
  v_classified_bps := (v_catmix->'coverage'->>'classified_pct_bps')::int;
  v_demog_pct := (v_demog->'coverage'->'demographics'->>'pct')::numeric;
  v_identified := (v_demog->'coverage'->'demographics'->>'denominator')::bigint;
  v_conf := app.subgroup_evidence_v1(coalesce(v_identified, 0)::int);

  if v_conf->>'status' <> 'ok' then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'data_quality_coverage',
      'reason', format('%s identified customer(s) is below the sample floor of %s, so a coverage '
                        'complaint would itself rest on nothing',
                        v_conf->>'n', v_conf->>'floor')));
  elsif not ((v_classified_bps is not null and v_classified_bps < c_classified_bps)
             or (v_demog_pct is not null and v_demog_pct < c_demog_pct)) then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'data_quality_coverage',
      'reason', format('coverage is adequate: %s bps of revenue classified, %s%% of customers '
                        'demographically resolved', coalesce(v_classified_bps::text, 'null'),
                        coalesce(v_demog_pct::text, 'null'))));
  else
    v_cands := v_cands || jsonb_build_array(jsonb_build_object(
      'id', 'data_quality_coverage',
      'domain', 'data_quality',
      'pattern', format(
        'Only %s%% of revenue is classified to a category and only %s%% of %s active customers '
        'have a resolved age and gender — every category, cohort and mix finding below is drawn '
        'from that fraction.',
        case when v_classified_bps is null then 'an unknown share of'
             else round(v_classified_bps / 100.0, 1)::text end,
        coalesce(v_demog_pct::text, 'an unknown share of'), v_identified),
      'comparison', jsonb_build_object(
        'kind', 'threshold',
        'detail', format('classified revenue coverage %s bps against %s bps, and demographic '
                          'coverage %s%% against %s%%',
                          coalesce(v_classified_bps::text, 'null'), c_classified_bps,
                          coalesce(v_demog_pct::text, 'null'), c_demog_pct)),
      'impact', jsonb_build_object(
        'cents', null,
        'reason', 'a coverage defect has no revenue figure of its own; what it does is put an '
                  'error bar on every figure above it'),
      'action', jsonb_build_object(
        'who', 'the owner, once, then front desk on an ongoing basis',
        'what', 'Map every service and product to a category in Settings, and capture date of '
                'birth and gender at the point a customer is created rather than retrospectively. '
                'Do this BEFORE acting on any category or cohort finding in this list.',
        'when', 'before the next review',
        'channel', 'settings_and_checkout'),
      'evidence', jsonb_build_object(
        'source_rpc', 'public.get_ci_category_mix_v1 + public.get_ci_demographics_v1',
        'refs', jsonb_build_object(
          'category_coverage', v_catmix->'coverage',
          'demographic_coverage', v_demog->'coverage'->'demographics',
          'unclassified_customers', v_demog->'unclassified',
          'classified_bar_bps', c_classified_bps,
          'demographic_bar_pct', c_demog_pct)),
      'evidence_class', 'DIRECT_FACT',
      'confidence', v_conf,
      'limitation',
        'Coverage is not accuracy: fully classified revenue can still be classified wrongly, and '
        'this says nothing about whether the mapped categories are the right ones.',
      'rank_class', 'foundation'));
  end if;

  -- =============================================================================================
  -- THE FLOOR SWEEP · a tripwire, not a crutch.
  -- =============================================================================================
  v_abst := v_abst || coalesce((
    select jsonb_agg(jsonb_build_object(
             'generator', c->>'id', 'reason', 'below_evidence_floor'))
      from jsonb_array_elements(v_cands) c
     where c->'confidence'->>'status' is distinct from 'ok'), '[]'::jsonb);

  select coalesce(jsonb_agg(x.c || jsonb_build_object('rank', x.rn) order by x.rn), '[]'::jsonb)
    into v_ranked
    from (
      select c,
             row_number() over (
               order by case c->>'rank_class'
                          when 'foundation' then 0
                          when 'quantified' then 1
                          else 2 end,
                        coalesce((c->'impact'->>'cents')::bigint, 0) desc,
                        c->>'domain', c->>'id') as rn
        from jsonb_array_elements(v_cands) c
       where c->'confidence'->>'status' = 'ok'
    ) x;

  v_promoted := coalesce(jsonb_array_length(v_ranked), 0);

  -- =============================================================================================
  -- THE DO-NOTHING OUTCOME · a ranked result in its own right (check 72)
  -- =============================================================================================
  if v_promoted = 0 then
    v_ranked := jsonb_build_array(jsonb_build_object(
      'id', 'do_nothing',
      'domain', 'none',
      'pattern', 'No opportunity clears the evidence bar',
      'comparison', jsonb_build_object(
        'kind', 'threshold',
        'detail', format('all %s candidate evaluation(s) were made and every one abstained; the '
                          'reasons are listed under "abstentions"', v_examined)),
      'impact', jsonb_build_object(
        'cents', null,
        'reason', 'nothing is being recommended, so there is nothing to value'),
      'action', jsonb_build_object(
        'who', 'the consultant',
        'what', 'Take no action from this analysis. If a recommendation is wanted, the constraint '
                'is evidence, not effort: read the abstention reasons and fix whichever one is '
                'cheapest to clear (usually volume, coverage, or consent capture).',
        'when', 'revisit at the next review',
        'channel', 'none'),
      'evidence', jsonb_build_object(
        'source_rpc', 'public.get_ci_funnel_conversion_v1, public.get_ci_daypart_v1, '
                      'public.get_ci_category_mix_v1, public.get_ci_service_intelligence_v1, '
                      'public.get_ci_package_intelligence_v1, public.get_ci_contactability_v1, '
                      'public.get_ci_demographics_v1, app.customer_cadence_v1',
        'refs', jsonb_build_object(
          'candidates_examined', v_examined,
          'candidates_promoted', 0,
          'abstentions', v_abst)),
      'evidence_class', 'DIRECT_FACT',
      'confidence', app.subgroup_evidence_v1(0),
      'limitation',
        '"No opportunity" is a statement about what this period''s data can support, not a finding '
        'that the business has none — a thin window and a healthy business look identical here.',
      'rank_class', 'do_nothing',
      'rank', 1));
  end if;

  -- =============================================================================================
  -- FRESHNESS (check 97) — observed_since_min across the six re-emitted sub-readers this engine
  -- consumes and that carry the field, and a stale-evidence refusal that overrides ranking.
  -- =============================================================================================
  select min(x) into v_obs_min
    from (values
      ((v_funnel->>'observed_since')::timestamptz),
      ((v_daypart->>'observed_since')::timestamptz),
      ((v_svc->>'observed_since')::timestamptz),
      ((v_pkg->>'observed_since')::timestamptz),
      ((v_catmix->>'observed_since')::timestamptz),
      ((v_demog->>'observed_since')::timestamptz)
    ) as t(x)
   where x is not null;

  -- JUDGEMENT CALL, recorded rather than hidden: the period-ends->90-days-before-as_of signal is
  -- surfaced for disclosure (v_period_far) but does NOT by itself force the refusal. The funnel
  -- and retention-window readers this engine consumes REQUIRE an old, matured window by design
  -- (a first-visit cohort only reports once its own maturity window has fully elapsed), and
  -- db/tests/executed/v678_corpus_consultant_spine.sql's own truth table already proves a
  -- 111-day window ending ~100 days before "now" is the NORMAL, intended way to call this engine
  -- -- that is a deliberately mature analytical window on an actively-observed business, not
  -- stale evidence. Gating refusal on it would make every legitimate matured-cohort call refuse
  -- to rank. What genuinely signals stale evidence is observed_since_min itself: how long ago the
  -- underlying business/metrics were last established or watermarked, regardless of which window
  -- a caller chose to look at. 'stale' therefore keys off observed_since_min alone;
  -- 'period_far_from_as_of' remains in the payload so a caller can still see the second signal.
  v_period_far := p_to < (p_as_of at time zone 'Asia/Singapore')::date - c_stale_period_days;
  v_stale := v_obs_min is not null and p_as_of - v_obs_min > make_interval(days => c_stale_days);

  if v_stale then
    v_refusal := 'stale_evidence';
    v_ranked := jsonb_build_array(jsonb_build_object(
      'id', 'do_nothing',
      'domain', 'none',
      'pattern', 'No opportunity is ranked: the evidence behind this analysis is stale.',
      'comparison', jsonb_build_object(
        'kind', 'threshold',
        'detail', format(
          'observed_since_min=%s, as_of=%s — stale when as_of is more than %s days past '
          'observed_since_min (period_far_from_as_of=%s is disclosed but does not itself refuse)',
          v_obs_min, p_as_of, c_stale_days, v_period_far)),
      'impact', jsonb_build_object(
        'cents', null,
        'reason', 'ranking is refused on stale evidence, so there is nothing to value'),
      'action', jsonb_build_object(
        'who', 'the consultant',
        'what', 'Refresh the underlying data (or request a more recent period) before ranking — '
                'acting on this analysis without doing so risks acting on facts that are no '
                'longer true.',
        'when', 'before the next review',
        'channel', 'none'),
      'evidence', jsonb_build_object(
        'source_rpc', 'public.get_ci_opportunities_v1',
        'refs', jsonb_build_object(
          'observed_since_min', v_obs_min, 'as_of', p_as_of, 'period_to', p_to,
          'period_far_from_as_of', v_period_far, 'stale_days_bar', c_stale_days)),
      'evidence_class', 'DIRECT_FACT',
      'confidence', app.subgroup_evidence_v1(0),
      'limitation',
        'Staleness is a statement about data freshness, not about whether opportunities exist.',
      'rank_class', 'do_nothing',
      'rank', 1));
    v_promoted := 0;
  else
    v_refusal := null;
  end if;

  v_result := jsonb_build_object(
    'contract', 'ci_opportunities_v1',
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                 'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'ranked', v_ranked,
    'abstentions', v_abst,
    'comparisons', app.comparisons_note_v1(v_examined, v_promoted),
    'freshness', jsonb_build_object(
      'observed_since_min', v_obs_min,
      'generated_at', clock_timestamp(),
      'stale', v_stale,
      'period_far_from_as_of', v_period_far),
    'refusal_reason', v_refusal,
    'observed_since', app.metric_observed_since_v1('ci_opportunities', p_business));

  return app.ci_envelope_v680('ci_opportunities_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$function$;

revoke all on function public.get_ci_opportunities_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_opportunities_v1(uuid,date,date,uuid,timestamptz)
  to authenticated, service_role;

commit;
