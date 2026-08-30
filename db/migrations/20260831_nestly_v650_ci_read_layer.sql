-- NESTLY v650 — Phase B/C read layer: the Customer Intelligence sections (CI-1 + C4).
-- Owner directive: all data flows into the Customer Intelligence module. Every RPC here is
-- SQL-computed (never client-side aggregation), rides the A11 exclusion helpers, and returns
-- a coverage object plus observed_since from the A12 watermarks, so the page can keep its
-- standing contract: numbers appear next to their coverage, or the section withholds.
-- Gate: business membership + the reports module (Customer Intelligence follows the reports
-- entitlement — the v523 ruling).
--
-- DESIGN DEVIATION, documented: the approved design widened get_customer_intelligence_v83
-- with p_node_key. That function is the flagship CI reader (forecast + keyset pagination);
-- widening it in place risks the platform's most-audited surface for one filter. The same
-- capability ships instead as the focused get_ci_category_customers_v1 below; v83 is
-- untouched and byte-identical.
begin;

create or replace function app.ci_reports_gate_v650(p_business uuid)
returns void
language plpgsql stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null
     or not (app.is_salon_member(p_business) or app.is_super_admin())
     or not app.can_module(p_business, 'reports') then
    raise exception 'reports access is required' using errcode = '42501';
  end if;
end;
$$;

-- Effective node for a line: the immutable snapshot when present, else a labelled
-- projection through the CURRENT mapping (pre-v649 history, per the approved rule).
create or replace function app.ci_effective_node_v650(p_item public.sale_items)
returns table (node_key text, classification text)
language sql stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select case
      when p_item.canonical_node_key is not null then p_item.canonical_node_key
      when p_item.item_type = 'service' then
        (select m.node_key from public.service_canonical_map m
          where m.business_id = p_item.business_id and m.service_id = p_item.ref_id)
      when p_item.item_type = 'retail' then
        coalesce((select m.node_key from public.product_canonical_map m
                   where m.business_id = p_item.business_id
                     and m.product_id = coalesce(p_item.product_id, p_item.ref_id)),
                 case app.business_pack_v648(p_item.business_id)
                   when 'fnb' then 'packaged_retail' else 'retail_product' end)
      else null end,
    case when p_item.canonical_node_key is not null then 'snapshot' else 'projected' end;
$$;

-- ---------------------------------------------------------------------------
-- C4: category mix. Level-2 rollup with level-3 detail, coverage beside it.
-- ---------------------------------------------------------------------------
create or replace function public.get_ci_category_mix_v1(
  p_business uuid, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_result jsonb;
begin
  perform app.ci_reports_gate_v650(p_business);
  with lines as (
    select si.line_cents, s.client_id, en.node_key as eff_node, en.classification,
           coalesce(n.parent_key, n.node_key) as l2_key,
           case when n.level = 3 then n.node_key end as l3_key
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      cross join lateral app.ci_effective_node_v650(si) en
      left join public.taxonomy_nodes n on n.version_no = 1 and n.node_key = en.node_key
     where si.business_id = p_business
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
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
  return v_result;
end;
$$;
revoke all on function public.get_ci_category_mix_v1(uuid,date,date) from public, anon;
grant execute on function public.get_ci_category_mix_v1(uuid,date,date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- C4: "facial customers" — the category-filtered customer list.
-- p_node_key matches the node and its children ('facial' covers 'facial.%').
-- ---------------------------------------------------------------------------
create or replace function public.get_ci_category_customers_v1(
  p_business uuid, p_node_key text, p_from date, p_to date, p_limit integer default 100)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_rows jsonb;
begin
  perform app.ci_reports_gate_v650(p_business);
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
       and s.client_id is not null
       and not coalesce(c.is_synthetic, false)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and coalesce(s.counts_as_visit, false)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and (en.node_key = p_node_key or en.node_key like p_node_key || '.%')
     group by s.client_id
     limit greatest(1, least(coalesce(p_limit, 100), 500))
    ) t;
  return jsonb_build_object('node_key', p_node_key, 'customers', v_rows,
    'observed_since', app.metric_observed_since_v1('category_snapshots', p_business));
end;
$$;
revoke all on function public.get_ci_category_customers_v1(uuid,text,date,date,integer) from public, anon;
grant execute on function public.get_ci_category_customers_v1(uuid,text,date,date,integer) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- CI-1: where customers come from (A1 capture). The unknown share is always shown.
-- ---------------------------------------------------------------------------
create or replace function public.get_ci_acquisition_v1(p_business uuid, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_rows jsonb;
begin
  perform app.ci_reports_gate_v650(p_business);
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
             and coalesce(s.counts_as_visit, false) and s.reversal_of is null) >= 2)
      ) as rec
      from public.clients c
     where c.business_id = p_business and not coalesce(c.is_synthetic, false)
     group by c.first_acquired_via, c.first_acquired_evidence
    ) t;
  return jsonb_build_object('sources', v_rows,
    'observed_since', app.metric_observed_since_v1('first_acquisition', p_business));
end;
$$;
revoke all on function public.get_ci_acquisition_v1(uuid,date,date) from public, anon;
grant execute on function public.get_ci_acquisition_v1(uuid,date,date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- CI-1: the identity-free join/booking funnel (A14 capture).
-- ---------------------------------------------------------------------------
create or replace function public.get_ci_funnel_v1(p_business uuid, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_rows jsonb;
begin
  perform app.ci_reports_gate_v650(p_business);
  select coalesce(jsonb_object_agg(surface, steps), '{}'::jsonb) into v_rows
    from (
      select f.surface, jsonb_object_agg(f.step, f.hits) as steps
        from (select surface, step, sum(hits) as hits
                from public.public_funnel_counters
               where business_id = p_business and day between p_from and p_to
               group by surface, step) f
       group by f.surface
    ) t;
  return jsonb_build_object('funnel', v_rows,
    'observed_since', app.metric_observed_since_v1('public_funnel_counters', p_business));
end;
$$;
revoke all on function public.get_ci_funnel_v1(uuid,date,date) from public, anon;
grant execute on function public.get_ci_funnel_v1(uuid,date,date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- CI-1: who you may contact (B1 authority), per marketing category.
-- ---------------------------------------------------------------------------
create or replace function public.get_ci_contactability_v1(p_business uuid)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  perform app.ci_reports_gate_v650(p_business);
  return jsonb_build_object(
    'business_offers', app.contactable_counts_v1(p_business, 'business_offers'),
    'rewards_and_points', app.contactable_counts_v1(p_business, 'rewards_and_points'),
    'note', 'A customer counts only with an affirmative recorded consent for the channel; nobody is grandfathered.');
end;
$$;
revoke all on function public.get_ci_contactability_v1(uuid) from public, anon;
grant execute on function public.get_ci_contactability_v1(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- CI-1: customer app engagement — rollups (B3) + the live current month.
-- ---------------------------------------------------------------------------
create or replace function public.get_ci_engagement_v1(p_business uuid, p_months integer default 12)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_hist jsonb; v_current jsonb;
  v_this_month date := date_trunc('month', now() at time zone 'Asia/Singapore')::date;
begin
  perform app.ci_reports_gate_v650(p_business);
  select coalesce(jsonb_agg(jsonb_build_object(
           'month', r.month, 'event_name', r.event_name,
           'events', r.event_count, 'people', r.distinct_actor_count)
           order by r.month, r.event_name), '[]'::jsonb) into v_hist
    from public.engagement_monthly_rollup_v1 r
   where r.business_id = p_business and r.actor_scope = 'customer'
     and r.month >= (v_this_month - make_interval(months => greatest(1, least(coalesce(p_months,12), 36))));
  select coalesce(jsonb_agg(jsonb_build_object(
           'event_name', e.event_name, 'events', e.n, 'people', e.actors)), '[]'::jsonb) into v_current
    from (select event_name, count(*) n, count(distinct actor_user_id) actors
            from public.product_adoption_events_v100
           where business_id = p_business and actor_scope = 'customer'
             and (occurred_at at time zone 'Asia/Singapore')::date >= v_this_month
           group by event_name) e;
  return jsonb_build_object('months', v_hist, 'current_month', v_current,
    'observed_since', app.metric_observed_since_v1('engagement_rollups', p_business));
end;
$$;
revoke all on function public.get_ci_engagement_v1(uuid,integer) from public, anon;
grant execute on function public.get_ci_engagement_v1(uuid,integer) to authenticated, service_role;

commit;
