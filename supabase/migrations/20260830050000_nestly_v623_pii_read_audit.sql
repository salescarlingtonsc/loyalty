-- NESTLY v623 — cross-tenant customer PII reads are capped, reasoned, and audited.
--
-- platform_list_enterprise_customers_v82 returns every tenant's end-customer name, phone and
-- email, and drives an unbounded CSV export. Before v623 it left no trace: no audit row, no
-- reason, page size up to 500, no distinction between "support looks at one firm" and "someone
-- drains the whole estate". The v177 workspace mirror audits every glance at masked data;
-- the door handing over raw PII audited nothing — that inversion ends here.
--
-- Shape (deny nothing legitimate, record everything):
--   · page size cap drops 500 → 200;
--   · a read scoped to exactly ONE business needs no reason (routine support) but is audited;
--   · any broader read (all firms, a sector, a multi-business filter — i.e. every export)
--     requires a reason of ≥8 characters, recorded in the audit row;
--   · every call writes PLATFORM_PII_READ_V623 with actor, scope, limit, total and returned
--     row counts, and the reason.
--
-- The old 10-parameter overload is DROPPED before the 11-parameter one is created — two
-- overloads with defaulted tails are indistinguishable to PostgREST named-argument calls and
-- would 300 every console request (the PGRST203 class).

begin;

drop function public.platform_list_enterprise_customers_v82(text, uuid[], uuid, date, date, text, integer, timestamp with time zone, timestamp with time zone, uuid);

CREATE OR REPLACE FUNCTION public.platform_list_enterprise_customers_v82(p_sector text DEFAULT NULL::text, p_businesses uuid[] DEFAULT NULL::uuid[], p_branch uuid DEFAULT NULL::uuid, p_from date DEFAULT (((now() AT TIME ZONE 'Asia/Singapore'::text))::date - 365), p_to date DEFAULT ((now() AT TIME ZONE 'Asia/Singapore'::text))::date, p_search text DEFAULT NULL::text, p_limit integer DEFAULT 200, p_snapshot_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_client uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_from_ts timestamptz;
  v_to_ts timestamptz;
  v_snapshot_at timestamptz:=coalesce(p_snapshot_at,clock_timestamp());
  v_search text:=nullif(btrim(p_search),'');
  v_result jsonb;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_from>p_to then
    raise exception 'invalid_report_window' using errcode='22023';
  end if;
  if p_to-p_from>1826 then
    raise exception 'report_window_exceeds_five_years' using errcode='22023';
  end if;
  if p_limit is null or p_limit<1 or p_limit>200 then
    raise exception 'limit_must_be_between_1_and_200' using errcode='22023';
  end if;
  /* v623: a broad (not exactly-one-business) read of customer PII needs a stated reason. */
  if coalesce(cardinality(p_businesses),0)<>1
     and length(coalesce(btrim(p_reason),''))<8 then
    raise exception 'broad customer reads require a reason of at least 8 characters' using errcode='22023';
  end if;
  if coalesce(cardinality(p_businesses),0)>100 then
    raise exception 'business_filter_exceeds_100' using errcode='22023';
  end if;
  if (p_after_created_at is null)<>(p_after_client is null) then
    raise exception 'complete_customer_cursor_required' using errcode='22023';
  end if;
  if p_snapshot_at is not null and p_snapshot_at>clock_timestamp()+interval '1 minute' then
    raise exception 'snapshot_cannot_be_in_the_future' using errcode='22023';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches branch where branch.id=p_branch
  ) then
    raise exception 'branch_not_found' using errcode='22023';
  end if;
  v_from_ts:=p_from::timestamp at time zone 'Asia/Singapore';
  v_to_ts:=(p_to+1)::timestamp at time zone 'Asia/Singapore';

  with selected_businesses as materialized (
    select business.id,business.name,business.industry,business.currency,
      (
        v_search is null
        or business.name ilike '%'||v_search||'%'
        or business.industry ilike '%'||v_search||'%'
        or exists(
          select 1 from public.branches branch
          where branch.business_id=business.id
            and branch.created_at<=v_snapshot_at
            and (p_branch is null or branch.id=p_branch)
            and branch.name ilike '%'||v_search||'%'
        )
      ) search_all
    from public.businesses business
    where business.is_synthetic=false and business.is_demo=false and business.created_at<=v_snapshot_at
      and (nullif(btrim(p_sector),'') is null
           or business.industry=btrim(p_sector))
      and (coalesce(cardinality(p_businesses),0)=0
           or business.id=any(p_businesses))
      and (p_branch is null or exists(
        select 1 from public.branches branch
        where branch.id=p_branch and branch.business_id=business.id
          and branch.created_at<=v_snapshot_at
      ))
  ),
  eligible_clients as materialized (
    select client.*,business.name business_name,business.industry,
           business.currency
    from selected_businesses business
    join public.clients client on client.business_id=business.id
    where client.created_at<=v_snapshot_at
      and (
        business.search_all
        or client.full_name ilike '%'||v_search||'%'
        or coalesce(client.email,'') ilike '%'||v_search||'%'
        or coalesce(client.phone,'') ilike '%'||v_search||'%'
      )
      and (p_branch is null or exists(
        select 1 from public.sales sale
        where sale.business_id=client.business_id and sale.client_id=client.id
          and sale.branch_id=p_branch and sale.created_at<=v_snapshot_at
          and sale.occurred_at<v_to_ts
      ))
  ),
  page as materialized (
    select client.*
    from eligible_clients client
    where p_after_created_at is null
       or (client.created_at,client.id)>(p_after_created_at,p_after_client)
    order by client.created_at,client.id limit p_limit
  ),
  customer_rows as materialized (
    select client.id client_id,client.business_id,client.business_name,
      client.industry,client.currency,client.full_name,client.email,client.phone,
      client.created_at customer_since,
      coalesce(period.net_revenue_cents,0)::bigint net_revenue_cents,
      coalesce(cash.cash_collected_cents,0)::bigint cash_collected_cents,
      coalesce(period.completed_transactions,0)::integer completed_transactions,
      coalesce(period.visit_count,0)::integer visit_count,
      lifetime.first_purchase_at,lifetime.last_purchase_at,
      period.first_purchase_at period_first_purchase_at,
      period.last_purchase_at period_last_purchase_at,
      case when lifetime.last_purchase_at is null then null
        else p_to-(lifetime.last_purchase_at at time zone 'Asia/Singapore')::date
      end days_since_last_purchase,
      coalesce(period.visit_count,0)>=2 returning_customer,
      coalesce(period.branches_visited,0)::integer branches_visited
    from page client
    left join lateral (
      select
        coalesce(sum(sale.amount_cents)
          filter(where sale.counts_as_revenue),0)::bigint net_revenue_cents,
        count(*) filter(
          where sale.reversal_of is null and sale.amount_cents>0
            and sale.counts_as_revenue and not exists(
              select 1 from public.sales reversal
              where reversal.business_id=sale.business_id
                and reversal.reversal_of=sale.id
                and reversal.created_at<=v_snapshot_at
                and reversal.occurred_at<v_to_ts
            )
        )::integer completed_transactions,
        count(*) filter(
          where sale.reversal_of is null and sale.amount_cents>0
            and sale.counts_as_visit and not exists(
              select 1 from public.sales reversal
              where reversal.business_id=sale.business_id
                and reversal.reversal_of=sale.id
                and reversal.created_at<=v_snapshot_at
                and reversal.occurred_at<v_to_ts
            )
        )::integer visit_count,
        min(sale.occurred_at) filter(
          where sale.reversal_of is null and sale.amount_cents>0
            and sale.counts_as_revenue and not exists(
              select 1 from public.sales reversal
              where reversal.business_id=sale.business_id
                and reversal.reversal_of=sale.id
                and reversal.created_at<=v_snapshot_at
                and reversal.occurred_at<v_to_ts
            )
        ) first_purchase_at,
        max(sale.occurred_at) filter(
          where sale.reversal_of is null and sale.amount_cents>0
            and sale.counts_as_revenue and not exists(
              select 1 from public.sales reversal
              where reversal.business_id=sale.business_id
                and reversal.reversal_of=sale.id
                and reversal.created_at<=v_snapshot_at
                and reversal.occurred_at<v_to_ts
            )
        ) last_purchase_at,
        count(distinct sale.branch_id) filter(
          where sale.reversal_of is null and sale.amount_cents>0
            and sale.counts_as_visit
        )::integer branches_visited
      from public.sales sale
      where sale.business_id=client.business_id and sale.client_id=client.id
        and sale.created_at<=v_snapshot_at
        and sale.occurred_at>=v_from_ts and sale.occurred_at<v_to_ts
        and (p_branch is null or sale.branch_id=p_branch)
    ) period on true
    left join lateral (
      select min(sale.occurred_at) first_purchase_at,
             max(sale.occurred_at) last_purchase_at
      from public.sales sale
      where sale.business_id=client.business_id and sale.client_id=client.id
        and sale.created_at<=v_snapshot_at and sale.occurred_at<v_to_ts
        and (p_branch is null or sale.branch_id=p_branch)
        and sale.reversal_of is null and sale.amount_cents>0
        and sale.counts_as_revenue
        and not exists(
          select 1 from public.sales reversal
          where reversal.business_id=sale.business_id
            and reversal.reversal_of=sale.id
            and reversal.created_at<=v_snapshot_at
            and reversal.occurred_at<v_to_ts
        )
    ) lifetime on true
    left join lateral (
      select coalesce(sum(payment.amount_cents)
        filter(where payment.method not in('credit','gift_card')),0)::bigint
        cash_collected_cents
      from public.payments payment
      left join public.sales linked_sale
        on linked_sale.id=payment.sale_id
       and linked_sale.business_id=payment.business_id
      where payment.business_id=client.business_id
        and coalesce(payment.client_id,linked_sale.client_id)=client.id
        and payment.created_at<=v_snapshot_at
        and payment.occurred_at>=v_from_ts and payment.occurred_at<v_to_ts
        and (p_branch is null or payment.branch_id=p_branch)
    ) cash on true
  )
  select jsonb_build_object(
    'snapshot_at',v_snapshot_at,
    'scope',jsonb_build_object(
      'sector',nullif(btrim(p_sector),''),
      'business_ids',coalesce(to_jsonb(p_businesses),'[]'::jsonb),
      'branch_id',p_branch,'from',p_from,'to',p_to,'search',v_search,
      'timezone','Asia/Singapore',
      'search_behavior','firm_or_branch_match_includes_whole_scope_otherwise_matching_customers_only'
    ),
    'customers',coalesce((
      select jsonb_agg(to_jsonb(customer) order by
        customer.customer_since,customer.client_id)
      from customer_rows customer
    ),'[]'::jsonb),
    'pagination',jsonb_build_object(
      'limit',p_limit,'total_customers',(select count(*) from eligible_clients),
      'returned_customers',(select count(*) from customer_rows),
      'has_more',exists(
        select 1 from eligible_clients candidate
        where (candidate.created_at,candidate.id)>(
          (select customer_since from customer_rows
            order by customer_since desc,client_id desc limit 1),
          (select client_id from customer_rows
            order by customer_since desc,client_id desc limit 1)
        )
      ),
      'next_cursor',case when exists(
        select 1 from eligible_clients candidate
        where (candidate.created_at,candidate.id)>(
          (select customer_since from customer_rows
            order by customer_since desc,client_id desc limit 1),
          (select client_id from customer_rows
            order by customer_since desc,client_id desc limit 1)
        )
      ) then (
        select jsonb_build_object(
          'created_at',customer_since,'client_id',client_id)
        from customer_rows
        order by customer_since desc,client_id desc limit 1
      ) else null end
    )
  ) into v_result;
  /* v623: every cross-tenant customer-PII read leaves a trace — who, what scope, how many. */
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (
    case when coalesce(cardinality(p_businesses),0)=1 then p_businesses[1] end,
    auth.uid(), 'PLATFORM_PII_READ_V623', 'clients', null,
    jsonb_build_object(
      'sector', p_sector, 'businesses', p_businesses, 'branch', p_branch,
      'from', p_from, 'to', p_to, 'search_used', v_search is not null,
      'limit', p_limit, 'cursor_page', p_after_client is not null,
      'total_customers', v_result->'pagination'->'total_customers',
      'returned_customers', v_result->'pagination'->'returned_customers',
      'reason', nullif(btrim(coalesce(p_reason,'')),'')
    )
  );
  return v_result;
end
$function$;

revoke all on function public.platform_list_enterprise_customers_v82(text, uuid[], uuid, date, date, text, integer, timestamp with time zone, timestamp with time zone, uuid, text) from public, anon;
grant execute on function public.platform_list_enterprise_customers_v82(text, uuid[], uuid, date, date, text, integer, timestamp with time zone, timestamp with time zone, uuid, text) to authenticated, service_role;

commit;
