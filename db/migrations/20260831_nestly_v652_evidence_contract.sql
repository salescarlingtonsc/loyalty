-- NESTLY v652 — Phase D, D2/D3: the shared evidence contract, and the Recovered Revenue
-- report retrofitted onto it.
--
-- The blueprint named v550 as the one place the product currently overstates its evidence:
-- it leads with a confident "Recovered revenue (estimated)" dollar figure computed against a
-- baseline of customers who were never contacted at all. That baseline is NOT a holdout — it
-- is whoever the campaign missed — so the comparison is selection-biased by construction, and
-- the figure carried no interval, no verdict, and only a n<10 flag.
--
-- This migration does NOT change the arithmetic anyone has been reading. It adds the evidence
-- block beside it, so the number can be read for what it is:
--   * a normal-approximation 95% interval on the difference in return rates,
--   * a verdict that is STRUCTURALLY CAPPED at 'early_signal' — no non-randomised comparison
--     in this product may ever report 'strong_pattern', however large the sample,
--   * 'insufficient' whenever an arm is under 10 or the interval spans zero (i.e. the treated
--     group cannot be distinguished from the comparison group at all),
--   * the named limitations, in plain English, that a reader needs in order to quote it.
-- Real causal claims wait for the v99/v108 holdout machinery, exactly as designed.
--
-- app.evidence_block_v1 is the reusable contract every future comparative claim must use.
begin;

-- ---------------------------------------------------------------------------
-- 1. The shared evidence block.
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
  v_p1 numeric; v_p2 numeric; v_se numeric; v_diff numeric;
  v_lo numeric; v_hi numeric;
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
    v_se := sqrt(v_p1 * (1 - v_p1) / p_treated_n + v_p2 * (1 - v_p2) / p_baseline_n);
    v_lo := v_diff - 1.96 * v_se;
    v_hi := v_diff + 1.96 * v_se;
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
      'method', 'normal approximation, 95% interval on the difference in rates') end,
    'verdict', v_verdict,
    'verdict_ceiling', p_max_verdict,
    'limitations', to_jsonb(p_limitations),
    'observed_since', p_observed_since);
end;
$$;
revoke all on function app.evidence_block_v1(text,text,date,date,integer,integer,integer,integer,text,text,text[],timestamptz,integer)
  from public, anon, authenticated;
grant execute on function app.evidence_block_v1(text,text,date,date,integer,integer,integer,integer,text,text,text[],timestamptz,integer)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. v550 re-emitted byte-faithfully, with the evidence block added at the end.
--    Every pre-existing key keeps its exact meaning and value.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_recovery_report_v550(p_business uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_now timestamptz := now();
  v_attr constant integer := 30;   -- attribution window, days
  v_lapse constant integer := 14;  -- minimum absence for an intervention to count
  v_from_ts timestamptz;
  v_to_ts timestamptz;
  v_result jsonb;
begin
  perform public.require_module_scope_v145(p_business, null, 'reports');
  perform public.require_module_scope_v145(p_business, null, 'clients');
  perform public.require_module_scope_v145(p_business, null, 'sales');
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'invalid report window' using errcode = '22023';
  end if;
  v_from_ts := p_from::timestamp at time zone 'Asia/Singapore';
  v_to_ts := p_to::timestamp at time zone 'Asia/Singapore';

  with visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at < v_now
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
  real_clients as (
    select c.id from public.clients c
    where c.business_id = p_business and coalesce(c.is_synthetic, false) = false
  ),
  interventions_raw as (
    select g.client_id, g.granted_at as at, 'voucher'::text as kind
    from public.bringback_grants_v361 g
    where g.business_id = p_business
      and g.granted_at >= v_from_ts and g.granted_at < v_to_ts
    union all
    select o.client_id, o.occurred_at, 'message'::text
    from public.attention_outreach_v550 o
    where o.business_id = p_business
      and o.occurred_at >= v_from_ts and o.occurred_at < v_to_ts
  ),
  -- One intervention per client per window: the first. Repeat contact never
  -- multiplies credit.
  interventions as (
    select distinct on (i.client_id) i.client_id, i.at, i.kind
    from interventions_raw i
    join real_clients rc on rc.id = i.client_id
    order by i.client_id, i.at, i.kind
  ),
  judged as (
    select i.client_id, i.at, i.kind,
      (select max(v.occurred_at) from visits v
        where v.client_id = i.client_id and v.occurred_at < i.at) as last_visit_before,
      (select count(*) from visits v
        where v.client_id = i.client_id and v.occurred_at < i.at) as prior_visits
    from interventions i
  ),
  eligible as (
    select j.*,
      exists (
        select 1 from visits v
        where v.client_id = j.client_id
          and v.occurred_at > j.at
          and v.occurred_at <= j.at + make_interval(days => v_attr)
      ) as returned,
      coalesce((
        select sum(v.amount_cents) from visits v
        where v.client_id = j.client_id
          and v.occurred_at > j.at
          and v.occurred_at <= j.at + make_interval(days => v_attr)
      ), 0)::bigint as window_cents
    from judged j
    where j.prior_visits >= 1
      and j.last_visit_before is not null
      and j.last_visit_before <= j.at - make_interval(days => v_lapse)
  ),
  excluded as (
    select count(*)::integer as n from judged j
    where not (j.prior_visits >= 1
      and j.last_visit_before is not null
      and j.last_visit_before <= j.at - make_interval(days => v_lapse))
  ),
  -- What would have happened anyway: clients lapsed at the window start with no
  -- intervention in the window, measured over the same 30-day horizon.
  baseline_cohort as (
    select v.client_id,
      max(v.occurred_at) filter (where v.occurred_at < v_from_ts) as last_before
    from visits v
    join real_clients rc on rc.id = v.client_id
    where not exists (select 1 from interventions i where i.client_id = v.client_id)
    group by v.client_id
    having max(v.occurred_at) filter (where v.occurred_at < v_from_ts)
             <= v_from_ts - make_interval(days => v_lapse)
  ),
  baseline as (
    select count(*)::integer as cohort,
      count(*) filter (where exists (
        select 1 from visits v2
        where v2.client_id = b.client_id
          and v2.occurred_at >= v_from_ts
          and v2.occurred_at < v_from_ts + make_interval(days => v_attr)
      ))::integer as returned
    from baseline_cohort b
  ),
  redeemed as (
    select count(*)::integer as n,
      coalesce(sum(app.v106_sale_residual_minor(g.redeemed_sale_id, v_now)), 0)::bigint as cents
    from public.bringback_grants_v361 g
    join real_clients rc on rc.id = g.client_id
    where g.business_id = p_business and g.status = 'redeemed'
      and g.granted_at >= v_from_ts and g.granted_at < v_to_ts
  ),
  monthly as (
    select to_char(e.at at time zone 'Asia/Singapore', 'YYYY-MM') as month,
      count(*)::integer as interventions,
      count(*) filter (where e.returned)::integer as returned,
      coalesce(sum(e.window_cents) filter (where e.returned), 0)::bigint as gross_cents
    from eligible e
    group by 1
  ),
  totals as (
    select
      (select count(*) from eligible)::integer as treated,
      (select count(*) filter (where kind = 'voucher') from eligible)::integer as vouchers,
      (select count(*) filter (where kind = 'message') from eligible)::integer as messages,
      (select count(*) filter (where returned) from eligible)::integer as returned,
      (select coalesce(sum(window_cents) filter (where returned), 0) from eligible)::bigint as gross_cents
  )
  select jsonb_build_object(
    'window', jsonb_build_object(
      'from', p_from, 'to_exclusive', p_to,
      'attribution_days', v_attr, 'min_absence_days', v_lapse),
    'interventions', jsonb_build_object(
      'treated', t.treated, 'vouchers', t.vouchers, 'messages', t.messages,
      'excluded_not_lapsed', (select n from excluded)),
    'returned', jsonb_build_object(
      'count', t.returned,
      'rate_pct', case when t.treated > 0
        then round(t.returned * 100.0 / t.treated, 1) else null end),
    'recovered', jsonb_build_object(
      'gross_cents', t.gross_cents,
      'redeemed_vouchers', (select n from redeemed),
      'redeemed_voucher_cents', (select cents from redeemed)),
    'baseline', jsonb_build_object(
      'cohort', b.cohort, 'returned', b.returned,
      'rate_pct', case when b.cohort > 0
        then round(b.returned * 100.0 / b.cohort, 1) else null end),
    'net', jsonb_build_object(
      'cents', case
        when t.treated = 0 or t.returned = 0 then 0
        when b.cohort = 0 then t.gross_cents
        else greatest(0, round(t.gross_cents
          * (1 - (b.returned::numeric / b.cohort)
               / (t.returned::numeric / t.treated))))::bigint end,
      'method', 'gross scaled by (1 - baseline_rate / treated_rate), floored at zero'),
    'low_confidence', (t.treated < 10 or b.cohort < 10),
    'monthly', (select coalesce(jsonb_agg(jsonb_build_object(
        'month', m.month, 'interventions', m.interventions,
        'returned', m.returned, 'gross_cents', m.gross_cents)
      order by m.month), '[]'::jsonb) from monthly m),
    -- v652: the evidence this report stands on, stated rather than implied. The
    -- comparison group is NOT a holdout, so the verdict is capped at early_signal
    -- however large the sample gets; a real causal claim needs v99/v108.
    'evidence', app.evidence_block_v1(
      p_population    => 'Customers contacted after at least ' || v_lapse || ' days away',
      p_denominator   => 'Contacted customers who were lapsed at the time of contact',
      p_window_from   => p_from,
      p_window_to     => p_to,
      p_treated_n     => t.treated,
      p_treated_events=> t.returned,
      p_baseline_n    => b.cohort,
      p_baseline_events=> b.returned,
      p_comparison    => 'Similarly lapsed customers who happened to receive no contact in this window',
      p_max_verdict   => 'early_signal',
      p_limitations   => array[
        'The comparison group was not randomly assigned — it is whoever was not contacted, so the two groups may differ in ways this report cannot see.',
        'Revenue is credited to any paying visit within ' || v_attr || ' days of contact, whether or not the offer was redeemed.',
        'Net revenue is floored at zero, so this figure can never show a campaign performing worse than the comparison group.'],
      p_observed_since=> null))
  into v_result
  from totals t, baseline b;

  return v_result;
end;
$function$;

-- ACL restated verbatim from the live proacl.
revoke all on function public.get_recovery_report_v550(uuid,date,date) from public, anon;
grant execute on function public.get_recovery_report_v550(uuid,date,date) to authenticated, service_role;

commit;
