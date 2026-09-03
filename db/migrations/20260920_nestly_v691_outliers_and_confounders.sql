-- NESTLY v691 — OUTLIER ANALYSIS (check 66, USED) and CONFOUNDER CHECKS (check 68) for
-- Customer Intelligence.
--
-- Two readers re-emitted, byte-additive only (docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md,
-- docs/qa/CI-CORPUS-FIXTURE-GUIDE.md). Neither public.get_ci_opportunities_v1 (v678/v680) nor
-- the cadence functions (v690) are touched by this migration — they consume the readers below
-- by JSON path access, and an added key never breaks a path read.
--
-- ---------------------------------------------------------------------------------------------
-- 1 · CHECK 66 — OUTLIER ANALYSIS, USED. app.distribution_block_v1 (v672) already exists and is
-- already the frozen authority for "mean cannot hide skew", but before this migration no reader
-- actually EMBEDS it. public.get_ci_category_mix_v1 (v667/v680) and
-- public.get_ci_service_intelligence_v1 (v675/v680) now compute the PER-CUSTOMER (category) /
-- PER-BUYER (service) revenue distribution and embed it verbatim as 'distribution' beside every
-- existing key — nothing renamed, nothing removed, so the v667/v675/v680 fixtures' assertions on
-- 'revenue_cents', 'buyers', 'coverage', etc. see byte-identical values. When
-- distribution.skew_material is true, both readers additionally emit 'skew_note' — a
-- plain-English sentence naming the top1 share, so a caller reading only the headline mean gets
-- the same warning inline. skew_note is null (key present, value null) when skew is not
-- material — "no skew_note" per the acceptance brief means nothing to disclose, not an absent
-- key, matching how 'bottleneck' and other optional fields already behave in this reader family.
--
-- ---------------------------------------------------------------------------------------------
-- 2 · CHECK 68 — CONFOUNDER CHECKS. public.get_ci_discovery_v1 (v686) already runs a BH-controlled
-- candidate/holdout pipeline; this migration adds a STRATIFIED consistency check on top of it,
-- reusing the population CTE the reader already builds (it already carries every classifying
-- field the check needs: dow, age_band, gender, l2_key, acquisition, branch_id).
--
-- For a BH survivor on (dimension D, group G), the check recomputes G-vs-rest-of-D SEPARATELY
-- within every stratum of every OTHER predetermined dimension (weekday, age_gender,
-- category_node, acquisition_source, branch — branch only when the business genuinely has the
-- dimension, same v_use_branch gate the scan itself already applies) whose stratum clears the
-- SAME floor (app.subgroup_evidence_v1's default, 5) on BOTH the group side and the rest side.
-- Ineligible strata (either side below floor, or the row does not classify into that other
-- dimension at all) are silently excluded from the count, exactly as v686's own header already
-- treats an unclassified row for its primary dimensions.
--
-- Every BH survivor carries 'confounders': {strata_checked, strata_consistent, strata_reversed,
-- verdict, note, detail}. verdict is 'reversed' when a STRICT MAJORITY of checked strata flip
-- sign against the train-half finding (Simpson's-paradox shape — the aggregate direction was an
-- artifact of how the group's members are distributed across the confounder, not a real
-- within-stratum effect); 'consistent' when zero strata reverse (including the case where zero
-- strata could be checked at all — there is no evidence of confounding to report); otherwise
-- 'mixed'. Holdout replication (the existing 'replicated' flag) is UNTOUCHED by this — it stays
-- exactly the train-vs-holdout check it always was. A survivor that both replicates AND is
-- confounded (verdict='reversed') is moved OUT of 'discoveries' into a new 'confounded' list,
-- carrying the same strata evidence, rather than silently dropped or silently kept — the false
-- Simpson's-paradox headline is still visible, just correctly labelled. A survivor that does not
-- replicate stays in 'not_replicated' regardless of its confounders verdict (that list already
-- means "did not survive the holdout test"; confounding is a different question and both keys
-- travel together on the same row).
--
-- A fixed 'competing_campaigns' block travels beside the pipeline output: how many
-- public.campaign_send_records_v255 rows touch a client who is anywhere in this call's cohort
-- (either half), inside the requested window — 0 when none, never omitted. This is disclosure,
-- not adjustment (the brief's own words): the engine does not attempt to net out campaign
-- exposure from the return-rate calculation, it just tells the reader how much of it happened
-- alongside the same customers.
begin;

-- ---------------------------------------------------------------------------------------------
-- 0 · Helper: given a discovery-scan dimension name and a population row's raw classifying
--     fields, return that row's group label for the named dimension — the SAME derivation
--     get_ci_discovery_v1's own dim_rows fan-out already uses, factored out so the confounder
--     check can ask "what is this row's value for dimension X" for an ARBITRARY X, including one
--     that is not the row's own candidacy dimension.
-- ---------------------------------------------------------------------------------------------
create or replace function app.discovery_dim_label_v691(
  p_dimension text, p_dow integer, p_age_band text, p_gender text,
  p_l2_key text, p_acquisition text, p_branch_id uuid
) returns text
language sql immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select case p_dimension
    when 'weekday' then
      case p_dow when 1 then 'Monday' when 2 then 'Tuesday' when 3 then 'Wednesday'
                 when 4 then 'Thursday' when 5 then 'Friday' when 6 then 'Saturday'
                 when 7 then 'Sunday' else null end
    when 'age_gender' then
      case when p_age_band is not null and p_gender is not null
           then p_age_band || '_' || p_gender else null end
    when 'category_node' then p_l2_key
    when 'acquisition_source' then p_acquisition
    when 'branch' then p_branch_id::text
    else null
  end;
$$;
revoke all on function app.discovery_dim_label_v691(text,integer,text,text,text,text,uuid)
  from public, anon, authenticated;
grant execute on function app.discovery_dim_label_v691(text,integer,text,text,text,text,uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 1 · get_ci_category_mix_v1 — 'distribution' + 'skew_note' per level-2 category.
-- ---------------------------------------------------------------------------------------------
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
  -- v691: per-customer revenue inside each level-2 category, feeding the shared distribution
  -- authority (app.distribution_block_v1, v672) — the input it was always meant to take.
  l2_customer_rev as (
    select l2_key, client_id, sum(line_cents)::numeric as rev
      from lines where l2_key is not null group by l2_key, client_id
  ),
  l2_dist as (
    select l2_key, app.distribution_block_v1(array_agg(rev)) as dist
      from l2_customer_rev group by l2_key
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
                       from l3 where l3.l2_key = l2.l2_key), '[]'::jsonb),
        'distribution', ld.dist,
        'skew_note', case when coalesce((ld.dist->>'skew_material')::boolean, false)
          then format('top customer carries %s%% of this category; the mean overstates the typical customer',
                       round((ld.dist->>'top1_share_bps')::numeric / 100, 1))
          else null end)
        order by l2.rev desc)
        from l2
        left join l2_dist ld on ld.l2_key = l2.l2_key), '[]'::jsonb),
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

-- ---------------------------------------------------------------------------------------------
-- 2 · get_ci_service_intelligence_v1 — 'distribution' + 'skew_note' per service (per-buyer
--     revenue).
-- ---------------------------------------------------------------------------------------------
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
  -- v691: per-buyer revenue for each service, feeding app.distribution_block_v1 the same way
  -- category_mix now does.
  buyer_revenue as (
    select service_id, client_id, sum(line_cents)::numeric as rev
      from lines
     group by service_id, client_id
  ),
  svc_dist as (
    select service_id, app.distribution_block_v1(array_agg(rev)) as dist
      from buyer_revenue
     group by service_id
  ),
  services_agg as (
    select ps.service_id, svc.name as service_name,
           ps.buyers, ps.orders, ps.revenue_cents,
           coalesce(rc.repeat_buyers, 0) as repeat_buyers,
           coalesce(gc.gateway_count, 0) as gateway_count,
           coalesce(md.n_obs, 0) as median_n_obs,
           md.raw_median,
           app.subgroup_evidence_v1(ps.buyers::int, v_floor) as evidence,
           sd.dist as distribution
      from per_service ps
      join public.services svc on svc.id = ps.service_id and svc.business_id = p_business
      left join repeat_counts rc on rc.service_id = ps.service_id
      left join gateway_counts gc on gc.service_id = ps.service_id
      left join median_days md on md.service_id = ps.service_id
      left join svc_dist sd on sd.service_id = ps.service_id
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
               'evidence', x.evidence,
               'distribution', x.distribution,
               'skew_note', case when coalesce((x.distribution->>'skew_material')::boolean, false)
                 then format('top customer carries %s%% of this category; the mean overstates the typical customer',
                              round((x.distribution->>'top1_share_bps')::numeric / 100, 1))
                 else null end
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

-- ---------------------------------------------------------------------------------------------
-- 3 · get_ci_discovery_v1 — confounder checks (68) + competing-campaigns disclosure.
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
           ((app.sg_today() - ans.anchor_date) >= 30) as mature,
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
  -- v691 (check 68): STRATIFIED CONFOUNDER CHECK. For every BH survivor (dimension D, group G),
  -- recompute G-vs-rest-of-D separately within every stratum of every OTHER predetermined
  -- dimension, using the TRAIN half's own population (the same half candidacy was judged on).
  -- ---------------------------------------------------------------------------------------
  train_pop_raw as (
    select client_id, mature, returned, dow, age_band, gender, l2_key, acquisition, branch_id
      from population where half = 'train'
  ),
  confound_strata as (
    select sv.dimension as focus_dim, sv.group_key as focus_group, sv.diff_pp as focus_diff_pp,
           o.dim_name as other_dim,
           app.discovery_dim_label_v691(
             o.dim_name, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
           ) as stratum_value,
           count(*) filter (
             where t.mature and app.discovery_dim_label_v691(
                     sv.dimension, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
                   ) = sv.group_key
           ) as g_n,
           count(*) filter (
             where t.mature and t.returned and app.discovery_dim_label_v691(
                     sv.dimension, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
                   ) = sv.group_key
           ) as g_numer,
           count(*) filter (
             where t.mature and app.discovery_dim_label_v691(
                     sv.dimension, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
                   ) is not null
               and app.discovery_dim_label_v691(
                     sv.dimension, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
                   ) <> sv.group_key
           ) as rest_n,
           count(*) filter (
             where t.mature and t.returned and app.discovery_dim_label_v691(
                     sv.dimension, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
                   ) is not null
               and app.discovery_dim_label_v691(
                     sv.dimension, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
                   ) <> sv.group_key
           ) as rest_numer
      from survivors sv
      cross join lateral unnest(
        array['weekday','age_gender','category_node','acquisition_source']
        || case when v_use_branch then array['branch'] else array[]::text[] end
      ) as o(dim_name)
      cross join train_pop_raw t
     where o.dim_name <> sv.dimension
       and app.discovery_dim_label_v691(
             o.dim_name, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
           ) is not null
     group by sv.dimension, sv.group_key, sv.diff_pp, o.dim_name,
              app.discovery_dim_label_v691(
                o.dim_name, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
              )
  ),
  confound_eligible as (
    select *,
           (g_n >= v_floor and rest_n >= v_floor) as eligible,
           case when g_n > 0 then g_numer::numeric / g_n else null end as g_rate,
           case when rest_n > 0 then rest_numer::numeric / rest_n else null end as rest_rate
      from confound_strata
  ),
  confound_signs as (
    select *,
           (g_rate - rest_rate) as stratum_diff,
           sign(g_rate - rest_rate) as stratum_sign,
           sign(focus_diff_pp) as focus_sign
      from confound_eligible where eligible
  ),
  confound_agg as (
    select focus_dim, focus_group,
           count(*) as strata_checked,
           count(*) filter (where stratum_sign = focus_sign and stratum_sign <> 0) as strata_consistent,
           count(*) filter (where stratum_sign <> focus_sign and stratum_sign <> 0) as strata_reversed,
           coalesce(jsonb_agg(jsonb_build_object(
             'dimension', other_dim, 'stratum', stratum_value,
             'group_rate_pct', round(g_rate * 100, 1), 'rest_rate_pct', round(rest_rate * 100, 1),
             'diff_pp', round(stratum_diff * 100, 1))
             order by other_dim, stratum_value), '[]'::jsonb) as strata_detail
      from confound_signs
     group by focus_dim, focus_group
  ),
  survivors_with_confound as (
    select sv.*,
           coalesce(ca.strata_checked, 0) as strata_checked,
           coalesce(ca.strata_consistent, 0) as strata_consistent,
           coalesce(ca.strata_reversed, 0) as strata_reversed,
           coalesce(ca.strata_detail, '[]'::jsonb) as strata_detail
      from survivors sv
      left join confound_agg ca on ca.focus_dim = sv.dimension and ca.focus_group = sv.group_key
  ),
  confound_final as (
    select *,
           case when strata_checked = 0 then 'consistent'
                when strata_reversed::numeric / strata_checked > 0.5 then 'reversed'
                when strata_reversed = 0 then 'consistent'
                else 'mixed' end as verdict
      from survivors_with_confound
  ),
  confound_block as (
    select dimension, group_key,
           jsonb_build_object(
             'strata_checked', strata_checked,
             'strata_consistent', strata_consistent,
             'strata_reversed', strata_reversed,
             'verdict', verdict,
             'note', case verdict
               when 'reversed' then format(
                 'sign reverses in %s of %s checked strata (a majority); the aggregate direction '
                 'may be driven by an uneven mix of %s across strata rather than a genuine '
                 'within-stratum effect', strata_reversed, strata_checked, group_key)
               when 'mixed' then format(
                 '%s of %s checked strata reverse sign; interpret the aggregate direction with caution',
                 strata_reversed, strata_checked)
               else case when strata_checked = 0
                 then 'no other dimension had at least the sample floor of customers on both sides to check for confounding'
                 else format('sign holds across all %s checked strata', strata_checked) end
             end,
             'detail', strata_detail
           ) as confounders,
           (verdict = 'reversed') as confounded
      from confound_final
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
    select sv.*, cb.confounders, coalesce(cb.confounded, false) as confounded,
           (h_diff_pp is not null and sign(h_diff_pp) = sign(sv.diff_pp) and sign(sv.diff_pp) <> 0)
             as replicated
      from survivor_verdict sv
      left join confound_block cb on cb.dimension = sv.dimension and cb.group_key = sv.group_key
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
  cohort_clients as (
    select distinct client_id from population
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
           ((app.sg_today() - pa.anchor_date) >= 30) as mature,
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
                 'evidence_class', 'ASSOCIATION',
                 'confounders', sr.confounders)
               order by sr.dimension, sr.group_key)
          from survivor_replicated sr where sr.replicated and not sr.confounded), '[]'::jsonb),

      -- v691: a BH survivor that replicates on holdout but whose train-half sign is a Simpson's-
      -- paradox artifact (majority of checked strata reverse) is disclosed here instead of
      -- 'discoveries' — never silently dropped.
      'confounded', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'dimension', sr.dimension, 'group', sr.group_key,
                 'train', jsonb_build_object('n', sr.n, 'rate', round(100.0*sr.numer/sr.n,1)),
                 'holdout', jsonb_build_object('n', sr.h_n, 'rate',
                              case when sr.h_n > 0 then round(100.0*sr.h_numer/sr.h_n,1) else null end),
                 'diff_pp', sr.diff_pp, 'interval', sr.block->'difference'->'confidence_95_pp',
                 'p_value', sr.p_value, 'bh_rank', sr.p_rank, 'replicated', true,
                 'evidence_class', 'ASSOCIATION',
                 'confounded', true,
                 'confounders', sr.confounders)
               order by sr.dimension, sr.group_key)
          from survivor_replicated sr where sr.replicated and sr.confounded), '[]'::jsonb),

      'not_replicated', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'dimension', sr.dimension, 'group', sr.group_key,
                 'train', jsonb_build_object('n', sr.n, 'rate', round(100.0*sr.numer/sr.n,1)),
                 'holdout', jsonb_build_object('n', sr.h_n, 'rate',
                              case when coalesce(sr.h_n,0) > 0 then round(100.0*sr.h_numer/sr.h_n,1) else null end),
                 'diff_pp', sr.diff_pp, 'interval', sr.block->'difference'->'confidence_95_pp',
                 'p_value', sr.p_value, 'bh_rank', sr.p_rank, 'replicated', false,
                 'evidence_class', 'ASSOCIATION',
                 'confounders', sr.confounders)
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

      -- v691 (68): fixed disclosure of marketing exposure touching this call's cohort. Reported,
      -- not adjusted -- the pipeline above makes no attempt to net campaign contact out of the
      -- return-rate calculation.
      'competing_campaigns', jsonb_build_object(
        'count', coalesce((
          select count(*) from public.campaign_send_records_v255 csr
           where csr.business_id = p_business
             and csr.client_id in (select client_id from cohort_clients)
             and (csr.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
        ), 0),
        'note', 'campaign exposure is reported, not adjusted'),

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
