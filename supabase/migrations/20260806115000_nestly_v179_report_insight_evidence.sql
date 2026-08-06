-- NESTLY v179 - INSIGHT EVIDENCE FOR AI FIRM REPORTS
--
-- Problem: the v176 evidence pack carries period totals (revenue, visits, new
-- customers, account opens) - accurate, but a dashboard already shows those.
-- The facts an owner actually pays for are the ones they cannot see at a
-- glance: whether new customers ever come back, who is slipping away and what
-- a recovered visit is worth, how concentrated revenue is in a few regulars,
-- which weekdays and items carry the shop, and whether the loyalty programme
-- is being redeemed or just accruing liability. All of that is deterministic
-- SQL over data we already hold.
--
-- This migration adds app.v179_business_insights and splices its output into
-- app.v176_evidence_pack as an `insights` key. The AI layer stays unchanged in
-- shape - it simply receives richer, still-strictly-factual evidence.
--
-- Accuracy rules (same as v176): sales are judged by their own v10.1 policy
-- snapshot (counts_as_revenue / counts_as_visit), reversed sales are excluded,
-- synthetic clients are excluded from customer metrics, and customer labels
-- are abbreviated via app.v177_person_label (never contact details).
-- Coverage honesty: item metrics report what share of revenue they explain,
-- so the model can qualify claims instead of overreaching.

begin;

create or replace function app.v179_business_insights(
  p_business uuid,
  p_from date,
  p_to date,
  p_prior_from date,
  p_prior_to date
)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  with bounds as (
    select
      p_from::timestamp at time zone 'Asia/Singapore' as from_ts,
      (p_to + 1)::timestamp at time zone 'Asia/Singapore' as to_ts,
      p_prior_from::timestamp at time zone 'Asia/Singapore' as prior_from_ts,
      (p_prior_to + 1)::timestamp at time zone 'Asia/Singapore' as prior_to_ts,
      (p_to + 1)::timestamp at time zone 'Asia/Singapore' - interval '45 days' as at_risk_before_ts,
      (p_to + 1)::timestamp at time zone 'Asia/Singapore' - interval '180 days' as at_risk_after_ts
  ), lifetime_sales as (
    -- All unreversed visit/revenue-bearing sales for real clients of this firm.
    select sale.id, sale.client_id, sale.amount_cents, sale.occurred_at,
      coalesce(sale.counts_as_revenue, true) as counts_as_revenue,
      coalesce(sale.counts_as_visit, true) as counts_as_visit
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and coalesce(client.is_synthetic, false) = false
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.client_id is not null
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), client_lifetime as (
    select client_id,
      min(occurred_at) filter (where counts_as_visit) as first_visit_at,
      max(occurred_at) filter (where counts_as_visit) as last_visit_at,
      count(*) filter (where counts_as_visit) as lifetime_visits,
      coalesce(sum(amount_cents) filter (where counts_as_revenue), 0) as lifetime_revenue_cents
    from lifetime_sales
    group by client_id
  ), window_sales as (
    select lifetime_sales.*
    from lifetime_sales, bounds
    where occurred_at >= bounds.from_ts and occurred_at < bounds.to_ts
  ), window_clients as (
    select ws.client_id,
      coalesce(sum(ws.amount_cents) filter (where ws.counts_as_revenue), 0) as revenue_cents,
      count(*) filter (where ws.counts_as_visit) as visits,
      bool_and(cl.first_visit_at >= bounds.from_ts) as is_new
    from window_sales ws
    join client_lifetime cl on cl.client_id = ws.client_id
    cross join bounds
    group by ws.client_id
  ), window_revenue as (
    select coalesce(sum(revenue_cents), 0) as total_cents from window_clients
  ), prior_new_clients as (
    -- Clients whose first-ever visit fell in the PRIOR window.
    select cl.client_id
    from client_lifetime cl, bounds
    where cl.first_visit_at >= bounds.prior_from_ts
      and cl.first_visit_at < bounds.prior_to_ts
  ), prior_new_returned as (
    select count(*) as returned
    from prior_new_clients pnc
    where exists(select 1 from window_clients wc
                 where wc.client_id = pnc.client_id and wc.visits > 0)
  ), at_risk as (
    -- Regulars (2+ lifetime visits) whose last visit is 45-180 days old at
    -- period end. Recovery value = one visit each at their own average ticket.
    select cl.client_id,
      cl.lifetime_visits,
      cl.lifetime_revenue_cents,
      case when cl.lifetime_visits > 0
        then (cl.lifetime_revenue_cents / cl.lifetime_visits)::bigint
        else 0 end as avg_ticket_cents
    from client_lifetime cl, bounds
    where cl.lifetime_visits >= 2
      and cl.last_visit_at < bounds.at_risk_before_ts
      and cl.last_visit_at >= bounds.at_risk_after_ts
  ), weekday as (
    select extract(isodow from (occurred_at at time zone 'Asia/Singapore'))::int as isodow,
      coalesce(sum(amount_cents) filter (where counts_as_revenue), 0) as revenue_cents,
      count(*) filter (where counts_as_visit) as visits
    from window_sales
    group by 1
  ), items as (
    select si.description,
      sum(si.qty)::bigint as qty,
      coalesce(sum(si.line_cents), 0)::bigint as revenue_cents
    from public.sale_items si
    join window_sales ws on ws.id = si.sale_id
    where si.business_id = p_business
    group by si.description
  ), points_window as (
    select
      coalesce(sum(points) filter (where entry_type = 'earn'), 0)::bigint as earned,
      coalesce(-sum(points) filter (where entry_type = 'redeem'), 0)::bigint as redeemed
    from public.points_ledger, bounds
    where business_id = p_business
      and created_at >= bounds.from_ts and created_at < bounds.to_ts
  )
  select pg_catalog.jsonb_build_object(
    'contract_version', 'v179',
    'retention', pg_catalog.jsonb_build_object(
      'customers_served', (select count(*) from window_clients where visits > 0),
      'new_customers', (select count(*) from window_clients where is_new and visits > 0),
      'returning_customers', (select count(*) from window_clients where not is_new and visits > 0),
      'repeat_rate_pct', (
        select case when count(*) filter (where visits > 0) = 0 then null
          else round(100.0 * count(*) filter (where not is_new and visits > 0)
                     / count(*) filter (where visits > 0), 1) end
        from window_clients
      ),
      'prior_period_new_customers', (select count(*) from prior_new_clients),
      'prior_new_who_returned_this_period', (select returned from prior_new_returned),
      'prior_new_return_rate_pct', (
        select case when (select count(*) from prior_new_clients) = 0 then null
          else round(100.0 * (select returned from prior_new_returned)
                     / (select count(*) from prior_new_clients), 1) end
      )
    ),
    'at_risk', pg_catalog.jsonb_build_object(
      'definition', 'customers with 2+ lifetime visits whose last visit is 45-180 days before period end',
      'customers', (select count(*) from at_risk),
      'their_lifetime_revenue_cents', (select coalesce(sum(lifetime_revenue_cents), 0) from at_risk),
      'recovery_value_one_visit_each_cents', (select coalesce(sum(avg_ticket_cents), 0) from at_risk)
    ),
    'top_customers', pg_catalog.jsonb_build_object(
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
          'label', app.v177_person_label(client.full_name, wc.client_id),
          'revenue_cents', wc.revenue_cents,
          'visits', wc.visits,
          'is_new_this_period', wc.is_new
        ) order by wc.revenue_cents desc, wc.client_id)
        from (select * from window_clients order by revenue_cents desc limit 5) wc
        join public.clients client on client.id = wc.client_id
        where wc.revenue_cents > 0
      ), '[]'::jsonb),
      'top1_share_pct', (
        select case when wr.total_cents = 0 then null
          else round(100.0 * (select max(revenue_cents) from window_clients) / wr.total_cents, 1) end
        from window_revenue wr
      ),
      'top5_share_pct', (
        select case when wr.total_cents = 0 then null
          else round(100.0 * (
            select coalesce(sum(revenue_cents), 0)
            from (select revenue_cents from window_clients
                  order by revenue_cents desc limit 5) top5
          ) / wr.total_cents, 1) end
        from window_revenue wr
      )
    ),
    'weekday_pattern', pg_catalog.jsonb_build_object(
      'note', 'isodow: 1=Monday .. 7=Sunday, Singapore time',
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
          'isodow', isodow, 'revenue_cents', revenue_cents, 'visits', visits
        ) order by isodow) from weekday
      ), '[]'::jsonb),
      'best_isodow', (select isodow from weekday order by revenue_cents desc, isodow limit 1),
      'quietest_isodow', (select isodow from weekday order by revenue_cents asc, isodow limit 1)
    ),
    'items', pg_catalog.jsonb_build_object(
      'note', 'line-item data may cover only part of revenue; see coverage_pct before generalising',
      'coverage_pct', (
        select case when wr.total_cents = 0 then null
          else round(100.0 * (select coalesce(sum(revenue_cents), 0) from items) / wr.total_cents, 1) end
        from window_revenue wr
      ),
      'top_items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'description', description, 'qty', qty, 'revenue_cents', revenue_cents
        ) order by revenue_cents desc)
        from (select * from items order by revenue_cents desc limit 5) top_items
      ), '[]'::jsonb)
    ),
    'loyalty', pg_catalog.jsonb_build_object(
      'points_earned_this_period', (select earned from points_window),
      'points_redeemed_this_period', (select redeemed from points_window),
      'redemption_rate_pct', (
        select case when earned = 0 then null
          else round(100.0 * redeemed / earned, 1) end from points_window
      ),
      'points_outstanding_total', coalesce((
        select sum(points) from public.points_ledger where business_id = p_business
      ), 0)
    )
  )
$$;
revoke all privileges on function
  app.v179_business_insights(uuid, date, date, date, date)
  from public, anon, authenticated, service_role;

comment on function app.v179_business_insights(uuid, date, date, date, date) is
  'Deterministic owner-grade insight evidence for AI firm reports: retention and new-customer return rates, at-risk regulars with a quantified recovery value, top-customer concentration (labels abbreviated, never contact details), weekday revenue pattern, item mix with coverage honesty, and loyalty points economics. Reversal-aware, policy-snapshot revenue, synthetic clients excluded.';

-- Splice into the evidence pack. Full redefinition of app.v176_evidence_pack
-- (deployed v176 body plus the `insights` key).
create or replace function app.v176_evidence_pack(
  p_business uuid,
  p_period_kind text,
  p_period_start date,
  p_period_end date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_business record;
  v_prior_start date := app.v176_period_prior_start(p_period_kind, p_period_start);
  v_prior_end date := p_period_start - 1;
  v_current jsonb;
  v_prior jsonb;
  v_opens_current jsonb;
  v_opens_prior jsonb;
  v_gated jsonb;
begin
  select business.id, business.name, business.industry, business.is_demo
  into v_business
  from public.businesses business
  where business.id = p_business;
  if not found then
    raise exception 'business_not_found' using errcode = '22023';
  end if;

  v_current := app.v176_sales_window(p_business, p_period_start, p_period_end);
  v_prior := app.v176_sales_window(p_business, v_prior_start, v_prior_end);
  v_opens_current := app.v176_account_opens_window(
    p_business, p_period_start, p_period_end
  );
  v_opens_prior := app.v176_account_opens_window(
    p_business, v_prior_start, v_prior_end
  );
  v_gated := app.v176_gated_evidence(p_business, p_period_start, p_period_end);

  return pg_catalog.jsonb_build_object(
    'contract_version', 'v176',
    'generated_at', now(),
    'timezone', 'Asia/Singapore',
    'currency', 'SGD',
    'scope', pg_catalog.jsonb_build_object(
      'business_id', v_business.id,
      'business_name', v_business.name,
      'industry', v_business.industry,
      'period_kind', p_period_kind,
      'period_start', p_period_start,
      'period_end', p_period_end,
      'prior_period_start', v_prior_start,
      'prior_period_end', v_prior_end
    ),
    'sales', pg_catalog.jsonb_build_object(
      'current', v_current,
      'prior', v_prior,
      'growth', pg_catalog.jsonb_build_object(
        'net_revenue_cents_delta',
          (v_current->>'net_revenue_cents')::bigint
            - (v_prior->>'net_revenue_cents')::bigint,
        'net_revenue_pct',
          case when (v_prior->>'net_revenue_cents')::bigint > 0
            then round(
              ((v_current->>'net_revenue_cents')::numeric
                - (v_prior->>'net_revenue_cents')::numeric)
              * 100 / (v_prior->>'net_revenue_cents')::numeric, 1)
            else null end,
        'revenue_transactions_delta',
          (v_current->>'revenue_transactions')::bigint
            - (v_prior->>'revenue_transactions')::bigint,
        'customers_served_delta',
          (v_current->>'customers_served')::bigint
            - (v_prior->>'customers_served')::bigint,
        'new_customers_delta',
          (v_current->>'new_customers')::bigint
            - (v_prior->>'new_customers')::bigint
      )
    ),
    'insights', app.v179_business_insights(
      p_business, p_period_start, p_period_end, v_prior_start, v_prior_end
    ),
    'account_opens', pg_catalog.jsonb_build_object(
      'current', v_opens_current,
      'prior', v_opens_prior,
      'report', v_gated->'account_opens_report'
    ),
    'consultant_brief', v_gated->'consultant_brief',
    'catalogue_affinity', v_gated->'catalogue_affinity',
    'recommendations', v_gated->'recommendations',
    'evidence_completeness', pg_catalog.jsonb_build_object(
      'gated_rpcs_available',
        coalesce((v_gated->>'available')::boolean, false),
      'gated_rpcs_reason', v_gated->>'reason',
      'synthetic_customers_excluded', true,
      'reversed_sales_excluded', true,
      'revenue_definition',
        'per-sale v10.1 policy snapshot (counts_as_revenue)',
      'insights_version', 'v179'
    )
  );
end
$$;
revoke all privileges on function
  app.v176_evidence_pack(uuid, text, date, date)
  from public, anon, authenticated, service_role;

commit;
