-- NESTLY v651 — Phase D, D1: one canonical customer-cadence computation.
-- The Phase 1 audit found the same "median inter-purchase interval x multiplier, trusted only
-- above a minimum-observations gate" idea implemented THREE times independently — v107
-- (customer lifecycle), v108 (growth audience) and the v109 sector policy — with no shared
-- function, so a change to one silently fails to reach the others.
--
-- What is consolidated here is the COMPUTATION, not the POLICY. The policy difference is
-- legitimate and stays explicit: v107 answers "is this customer lapsed for lifecycle
-- reporting" from customer_lifecycle_policies_v107 (fallback 90d, min 3 observations,
-- multiplier 2.0), while v108/v109 answer "should we contact them" from the per-sector
-- lapse_detection policy. Both now ask the SAME function for the underlying rhythm.
--
--   app.customer_cadence_batch_v1 — the canonical median-interval computation, extracted
--     VERBATIM from v107's interval_evidence CTE (same paid-visit definition: counts_as_visit,
--     not reversed, v106 residual > 0, v111 effective client id, per-outlet timezone from the
--     v106 reporting contract). v107 is then re-pointed at it, and the rollback suite proves
--     the swap is output-identical for every real customer in production before it is trusted.
--   app.customer_cadence_v1 — the per-customer answer new consumers ask (Customer
--     Intelligence "expected next visit", Phase H's "who to contact today", and v108/v109 when
--     their flags flip): median, observations, expected-next-visit window, deviation state and
--     the evidence source behind the answer.
--
-- No behaviour changes in this migration. It removes a duplicate and names an authority.
begin;

-- ---------------------------------------------------------------------------
-- 1. The canonical batch computation (v107's CTE, extracted).
-- ---------------------------------------------------------------------------
create or replace function app.customer_cadence_batch_v1(
  p_business uuid,
  p_before date,                 -- intervals whose later visit falls before this business date
  p_residual_to date,            -- the v106 residual horizon (v107 passes p_to)
  p_as_of timestamptz,
  p_branch uuid default null,
  p_business_wide boolean default true)
returns table (
  client_id uuid,
  interval_observations integer,
  median_interval_days numeric,
  last_visit_at timestamptz,
  paid_visits integer)
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  with eligible as materialized (
    select s.id,
           app.v111_effective_client_id(s.business_id, s.client_id) as client_id,
           s.branch_id, s.occurred_at, s.created_at,
           s.amount_cents, c.timezone,
           app.v106_sale_residual_minor(s.id, p_residual_to, p_as_of) as residual_minor
      from public.sales s
      cross join lateral app.v106_reporting_contract(
        s.business_id, s.branch_id, s.occurred_at
      ) c
     where s.business_id = p_business
       and s.reversal_of is null
       and s.counts_as_visit
       and s.created_at <= p_as_of
       and (
         p_business_wide
         or (p_branch is not null and s.branch_id = p_branch)
       )
  ), sequenced as (
    select e.*,
           lag(e.occurred_at) over (
             partition by e.client_id order by e.occurred_at, e.id
           ) as previous_purchase_at
      from eligible e
     where e.residual_minor > 0
  )
  select client_id,
         count(*) filter (where previous_purchase_at is not null)::integer
           as interval_observations,
         percentile_cont(0.5) within group (
           order by extract(epoch from (occurred_at - previous_purchase_at)) / 86400.0
         ) filter (where previous_purchase_at is not null)
           as median_interval_days,
         max(occurred_at) as last_visit_at,
         count(*)::integer as paid_visits
    from sequenced
   where client_id is not null
     and (occurred_at at time zone timezone)::date < p_before
   group by client_id;
$$;
revoke all on function app.customer_cadence_batch_v1(uuid,date,date,timestamptz,uuid,boolean)
  from public, anon, authenticated;
grant execute on function app.customer_cadence_batch_v1(uuid,date,date,timestamptz,uuid,boolean)
  to service_role;

-- ---------------------------------------------------------------------------
-- 2. The per-customer answer, policy-resolved. Evidence source is always named:
--    'customer_median_interval' when the customer's own rhythm clears the
--    minimum-observations gate, 'business_fallback' otherwise, 'none' when the
--    customer has no paid visit at all.
-- ---------------------------------------------------------------------------
create or replace function app.customer_cadence_v1(
  p_business uuid, p_client uuid, p_as_of timestamptz default now())
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_policy public.customer_lifecycle_policies_v107%rowtype;
  v_row record;
  v_effective_lapse numeric;
  v_source text;
  v_days_since numeric;
  v_expected_from timestamptz;
  v_expected_to timestamptz;
  v_state text;
begin
  select * into v_policy
    from public.customer_lifecycle_policies_v107 p
   where p.business_id = p_business and p.effective_from <= p_as_of
   order by p.effective_from desc, p.version_no desc limit 1;
  if not found then
    return jsonb_build_object('status','no_policy');
  end if;

  select * into v_row
    from app.customer_cadence_batch_v1(
      p_business,
      ((p_as_of at time zone 'Asia/Singapore')::date + 1),
      ((p_as_of at time zone 'Asia/Singapore')::date + 1),
      p_as_of, null, true) b
   where b.client_id = app.v111_effective_client_id(p_business, p_client);

  if not found or v_row.last_visit_at is null then
    return jsonb_build_object(
      'status','insufficient',
      'evidence_source','none',
      'interval_observations', 0,
      'reason','no paid visit on record');
  end if;

  v_days_since := extract(epoch from (p_as_of - v_row.last_visit_at)) / 86400.0;

  if v_row.interval_observations >= v_policy.customer_interval_min_observations
     and v_row.median_interval_days is not null then
    v_source := 'customer_median_interval';
    v_effective_lapse := greatest(1, v_row.median_interval_days * v_policy.reactivation_multiplier);
    -- The customer's own window: their median, with a symmetric tolerance of half
    -- the multiplier's headroom. Deliberately a RANGE, never a single date.
    v_expected_from := v_row.last_visit_at
      + make_interval(secs => v_row.median_interval_days * 86400.0 * 0.75);
    v_expected_to := v_row.last_visit_at
      + make_interval(secs => v_row.median_interval_days * 86400.0 * 1.25);
  else
    v_source := 'business_fallback';
    v_effective_lapse := greatest(1, v_policy.fallback_lapse_days);
    v_expected_from := null;
    v_expected_to := null;
  end if;

  v_state := case
    when v_days_since > v_effective_lapse then 'overdue'
    when v_expected_to is not null and p_as_of > v_expected_to then 'late'
    when v_expected_from is not null and p_as_of >= v_expected_from then 'due'
    else 'within_cycle' end;

  return jsonb_build_object(
    'status','ready',
    'evidence_source', v_source,
    'interval_observations', v_row.interval_observations,
    'paid_visits', v_row.paid_visits,
    'median_interval_days', round(coalesce(v_row.median_interval_days, 0)::numeric, 1),
    'last_visit_at', v_row.last_visit_at,
    'days_since_last_visit', round(v_days_since, 1),
    'effective_lapse_days', round(v_effective_lapse, 1),
    'expected_next_from', v_expected_from,
    'expected_next_to', v_expected_to,
    'deviation_state', v_state,
    'policy', jsonb_build_object(
      'min_observations', v_policy.customer_interval_min_observations,
      'multiplier', v_policy.reactivation_multiplier,
      'fallback_lapse_days', v_policy.fallback_lapse_days));
end;
$$;
revoke all on function app.customer_cadence_v1(uuid,uuid,timestamptz) from public, anon, authenticated;
grant execute on function app.customer_cadence_v1(uuid,uuid,timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Re-point v107 at the canonical computation. Anchored, single-occurrence
--    patch of the live body; the rollback suite proves output equality for
--    every real customer before this is trusted.
-- ---------------------------------------------------------------------------
do $patch$
declare
  v_def text;
  v_anchor text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_customer_lifecycle_v107(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then raise exception 'v651: get_customer_lifecycle_v107 not found'; end if;

  v_anchor := '), interval_evidence as (
    select client_id,
           count(*) filter (where previous_purchase_at is not null)::integer
             as interval_observations,
           percentile_cont(0.5) within group (
             order by extract(epoch from (occurred_at - previous_purchase_at)) / 86400.0
           ) filter (where previous_purchase_at is not null)
             as median_interval_days
      from sequenced
     where client_id is not null
       and (occurred_at at time zone timezone)::date < p_from
     group by client_id
  ),';
  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 1 then
    raise exception 'v651: interval_evidence anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  v_def := replace(v_def, v_anchor, '), interval_evidence as (
    -- v651: the canonical cadence computation (extracted verbatim from this CTE).
    select b.client_id, b.interval_observations, b.median_interval_days
      from app.customer_cadence_batch_v1(
        p_business, p_from, p_to, p_as_of, p_branch, v_business_wide_identity) b
  ),');
  execute v_def;
end;
$patch$;

-- ACL restated verbatim from the live proacl.
revoke all on function public.get_customer_lifecycle_v107(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_customer_lifecycle_v107(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

commit;
