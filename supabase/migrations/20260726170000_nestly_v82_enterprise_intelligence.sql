-- NESTLY v82 - ENTERPRISE HIERARCHY AND SNAPSHOT REPORTING
--
-- Super-admin-only read contracts. Firm and customer collections use a server
-- generated snapshot plus immutable keysets. Search has one meaning everywhere:
-- a firm/branch match includes its whole scoped population; otherwise only
-- matching customers and their transactions are included. Money is never added
-- across currencies.

begin;

create or replace function public.platform_get_enterprise_hierarchy_v82(
  p_sector text default null,
  p_businesses uuid[] default null,
  p_branch uuid default null,
  p_from date default (((now() at time zone 'Asia/Singapore')::date) - 365),
  p_to date default ((now() at time zone 'Asia/Singapore')::date),
  p_search text default null,
  p_limit integer default 100,
  p_snapshot_at timestamptz default null,
  p_after_created_at timestamptz default null,
  p_after_business uuid default null
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
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
  if p_limit is null or p_limit<1 or p_limit>500 then
    raise exception 'limit_must_be_between_1_and_500' using errcode='22023';
  end if;
  if coalesce(cardinality(p_businesses),0)>100 then
    raise exception 'business_filter_exceeds_100' using errcode='22023';
  end if;
  if (p_after_created_at is null)<>(p_after_business is null) then
    raise exception 'complete_firm_cursor_required' using errcode='22023';
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

  with eligible_businesses as materialized (
    select business.id,business.name,business.slug,business.industry,
           business.currency,business.created_at,
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
    where business.created_at<=v_snapshot_at
      and (nullif(btrim(p_sector),'') is null
           or business.industry=btrim(p_sector))
      and (coalesce(cardinality(p_businesses),0)=0
           or business.id=any(p_businesses))
      and (p_branch is null or exists(
        select 1 from public.branches branch
        where branch.id=p_branch and branch.business_id=business.id
          and branch.created_at<=v_snapshot_at
      ))
      and (
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
        or exists(
          select 1 from public.clients client
          where client.business_id=business.id
            and client.created_at<=v_snapshot_at
            and (
              client.full_name ilike '%'||v_search||'%'
              or coalesce(client.email,'') ilike '%'||v_search||'%'
              or coalesce(client.phone,'') ilike '%'||v_search||'%'
            )
            and (p_branch is null or exists(
              select 1 from public.sales sale
              where sale.business_id=business.id and sale.client_id=client.id
                and sale.branch_id=p_branch and sale.created_at<=v_snapshot_at
                and sale.occurred_at<v_to_ts
            ))
        )
      )
  ),
  searched_businesses as materialized (
    select business.*
    from eligible_businesses business
    where business.search_all or exists(
      select 1 from public.clients client
      where client.business_id=business.id
        and client.created_at<=v_snapshot_at
        and (
          client.full_name ilike '%'||v_search||'%'
          or coalesce(client.email,'') ilike '%'||v_search||'%'
          or coalesce(client.phone,'') ilike '%'||v_search||'%'
        )
        and (p_branch is null or exists(
          select 1 from public.sales sale
          where sale.business_id=business.id and sale.client_id=client.id
            and sale.branch_id=p_branch and sale.created_at<=v_snapshot_at
            and sale.occurred_at<v_to_ts
        ))
    )
  ),
  page as materialized (
    select business.*
    from searched_businesses business
    where p_after_created_at is null
       or (business.created_at,business.id)>(p_after_created_at,p_after_business)
    order by business.created_at,business.id
    limit p_limit
  ),
  rows as materialized (
    select business.*,
      (
        select count(*)::integer from public.branches branch
        where branch.business_id=business.id
          and branch.created_at<=v_snapshot_at
          and (p_branch is null or branch.id=p_branch)
      ) branch_count,
      (
        select count(*)::integer from public.staff staff
        where staff.business_id=business.id and staff.active
          and staff.created_at<=v_snapshot_at
      ) staff_count,
      (
        select count(*)::integer from public.clients client
        where client.business_id=business.id
          and client.created_at<=v_snapshot_at
          and (
            business.search_all
            or client.full_name ilike '%'||v_search||'%'
            or coalesce(client.email,'') ilike '%'||v_search||'%'
            or coalesce(client.phone,'') ilike '%'||v_search||'%'
          )
          and (p_branch is null or exists(
            select 1 from public.sales sale
            where sale.business_id=business.id and sale.client_id=client.id
              and sale.branch_id=p_branch and sale.created_at<=v_snapshot_at
              and sale.occurred_at<v_to_ts
          ))
      ) customer_count
    from page business
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
    'firms',coalesce((
      select jsonb_agg(jsonb_build_object(
        'business_id',business.id,'name',business.name,'slug',business.slug,
        'industry',business.industry,'currency',business.currency,
        'created_at',business.created_at,'branch_count',business.branch_count,
        'staff_count',business.staff_count,'customer_count',business.customer_count,
        'summary',jsonb_build_object(
          'net_revenue_cents',(
            select coalesce(sum(sale.amount_cents)
              filter(where sale.counts_as_revenue),0)
            from public.sales sale
            where sale.business_id=business.id
              and sale.created_at<=v_snapshot_at
              and sale.occurred_at>=v_from_ts and sale.occurred_at<v_to_ts
              and (p_branch is null or sale.branch_id=p_branch)
              and (
                business.search_all
                or sale.client_id in(
                  select client.id from public.clients client
                  where client.business_id=business.id
                    and client.created_at<=v_snapshot_at
                    and (
                      client.full_name ilike '%'||v_search||'%'
                      or coalesce(client.email,'') ilike '%'||v_search||'%'
                      or coalesce(client.phone,'') ilike '%'||v_search||'%'
                    )
                )
              )
          ),
          'cash_collected_cents',(
            select coalesce(sum(payment.amount_cents)
              filter(where payment.method not in('credit','gift_card')),0)
            from public.payments payment
            left join public.sales linked_sale
              on linked_sale.id=payment.sale_id
             and linked_sale.business_id=payment.business_id
            where payment.business_id=business.id
              and payment.created_at<=v_snapshot_at
              and payment.occurred_at>=v_from_ts and payment.occurred_at<v_to_ts
              and (p_branch is null or payment.branch_id=p_branch)
              and (
                business.search_all
                or coalesce(payment.client_id,linked_sale.client_id) in(
                  select client.id from public.clients client
                  where client.business_id=business.id
                    and client.created_at<=v_snapshot_at
                    and (
                      client.full_name ilike '%'||v_search||'%'
                      or coalesce(client.email,'') ilike '%'||v_search||'%'
                      or coalesce(client.phone,'') ilike '%'||v_search||'%'
                    )
                )
              )
          ),
          'completed_transactions',(
            select count(*) from public.sales sale
            where sale.business_id=business.id
              and sale.created_at<=v_snapshot_at
              and sale.occurred_at>=v_from_ts and sale.occurred_at<v_to_ts
              and (p_branch is null or sale.branch_id=p_branch)
              and sale.reversal_of is null and sale.amount_cents>0
              and sale.counts_as_revenue
              and (
                business.search_all
                or sale.client_id in(
                  select client.id from public.clients client
                  where client.business_id=business.id
                    and client.created_at<=v_snapshot_at
                    and (
                      client.full_name ilike '%'||v_search||'%'
                      or coalesce(client.email,'') ilike '%'||v_search||'%'
                      or coalesce(client.phone,'') ilike '%'||v_search||'%'
                    )
                )
              )
              and not exists(
                select 1 from public.sales reversal
                where reversal.business_id=sale.business_id
                  and reversal.reversal_of=sale.id
                  and reversal.created_at<=v_snapshot_at
                  and reversal.occurred_at<v_to_ts
              )
          ),
          'returning_customers',(
            select count(*) from (
              select sale.client_id
              from public.sales sale
              where sale.business_id=business.id
                and sale.client_id is not null
                and sale.created_at<=v_snapshot_at
                and sale.occurred_at>=v_from_ts and sale.occurred_at<v_to_ts
                and (p_branch is null or sale.branch_id=p_branch)
                and sale.reversal_of is null and sale.amount_cents>0
                and sale.counts_as_visit
                and (
                  business.search_all
                  or sale.client_id in(
                    select client.id from public.clients client
                    where client.business_id=business.id
                      and client.created_at<=v_snapshot_at
                      and (
                        client.full_name ilike '%'||v_search||'%'
                        or coalesce(client.email,'') ilike '%'||v_search||'%'
                        or coalesce(client.phone,'') ilike '%'||v_search||'%'
                      )
                  )
                )
                and not exists(
                  select 1 from public.sales reversal
                  where reversal.business_id=sale.business_id
                    and reversal.reversal_of=sale.id
                    and reversal.created_at<=v_snapshot_at
                    and reversal.occurred_at<v_to_ts
                )
              group by sale.client_id having count(*)>=2
            ) returning_set
          )
        ),
        'branches',coalesce((
          select jsonb_agg(jsonb_build_object(
            'branch_id',branch.id,'name',branch.name,'address',branch.address,
            'phone',branch.phone,'email',branch.email,'active',branch.active,
            'is_default',branch.is_default,'created_at',branch.created_at,
            'customer_count',(
              select count(distinct sale.client_id)
              from public.sales sale
              where sale.business_id=business.id and sale.branch_id=branch.id
                and sale.client_id is not null and sale.created_at<=v_snapshot_at
                and sale.occurred_at<v_to_ts
                and (
                  business.search_all
                  or sale.client_id in(
                    select client.id from public.clients client
                    where client.business_id=business.id
                      and client.created_at<=v_snapshot_at
                      and (
                        client.full_name ilike '%'||v_search||'%'
                        or coalesce(client.email,'') ilike '%'||v_search||'%'
                        or coalesce(client.phone,'') ilike '%'||v_search||'%'
                      )
                  )
                )
            ),
            'staff_count',(
              select count(distinct staff.id)
              from public.staff_branches staff_branch
              join public.staff staff
                on staff.id=staff_branch.staff_id
               and staff.business_id=staff_branch.business_id
              where staff_branch.business_id=business.id
                and staff_branch.branch_id=branch.id
                and staff.active
                and staff.created_at<=v_snapshot_at
            ),
            'net_revenue_cents',(
              select coalesce(sum(sale.amount_cents)
                filter(where sale.counts_as_revenue),0)
              from public.sales sale
              where sale.business_id=business.id and sale.branch_id=branch.id
                and sale.created_at<=v_snapshot_at
                and sale.occurred_at>=v_from_ts and sale.occurred_at<v_to_ts
                and (
                  business.search_all
                  or sale.client_id in(
                    select client.id from public.clients client
                    where client.business_id=business.id
                      and client.created_at<=v_snapshot_at
                      and (
                        client.full_name ilike '%'||v_search||'%'
                        or coalesce(client.email,'') ilike '%'||v_search||'%'
                        or coalesce(client.phone,'') ilike '%'||v_search||'%'
                      )
                  )
                )
            ),
            'completed_transactions',(
              select count(*) from public.sales sale
              where sale.business_id=business.id and sale.branch_id=branch.id
                and sale.created_at<=v_snapshot_at
                and sale.occurred_at>=v_from_ts and sale.occurred_at<v_to_ts
                and sale.reversal_of is null and sale.amount_cents>0
                and sale.counts_as_revenue
                and (
                  business.search_all
                  or sale.client_id in(
                    select client.id from public.clients client
                    where client.business_id=business.id
                      and client.created_at<=v_snapshot_at
                      and (
                        client.full_name ilike '%'||v_search||'%'
                        or coalesce(client.email,'') ilike '%'||v_search||'%'
                        or coalesce(client.phone,'') ilike '%'||v_search||'%'
                      )
                  )
                )
                and not exists(
                  select 1 from public.sales reversal
                  where reversal.business_id=sale.business_id
                    and reversal.reversal_of=sale.id
                    and reversal.created_at<=v_snapshot_at
                    and reversal.occurred_at<v_to_ts
                )
            )
          ) order by branch.is_default desc,branch.name,branch.id)
          from public.branches branch
          where branch.business_id=business.id
            and branch.created_at<=v_snapshot_at
            and (p_branch is null or branch.id=p_branch)
        ),'[]'::jsonb)
      ) order by business.created_at,business.id)
      from rows business
    ),'[]'::jsonb),
    'pagination',jsonb_build_object(
      'limit',p_limit,'total_firms',(select count(*) from searched_businesses),
      'returned_firms',(select count(*) from rows),
      'has_more',exists(
        select 1 from searched_businesses candidate
        where (candidate.created_at,candidate.id)>(
          (select created_at from rows order by created_at desc,id desc limit 1),
          (select id from rows order by created_at desc,id desc limit 1)
        )
      ),
      'next_cursor',case when exists(
        select 1 from searched_businesses candidate
        where (candidate.created_at,candidate.id)>(
          (select created_at from rows order by created_at desc,id desc limit 1),
          (select id from rows order by created_at desc,id desc limit 1)
        )
      ) then (
        select jsonb_build_object('created_at',created_at,'business_id',id)
        from rows order by created_at desc,id desc limit 1
      ) else null end
    )
  ) into v_result;
  return v_result;
end
$$;

create or replace function public.platform_list_enterprise_customers_v82(
  p_sector text default null,
  p_businesses uuid[] default null,
  p_branch uuid default null,
  p_from date default (((now() at time zone 'Asia/Singapore')::date) - 365),
  p_to date default ((now() at time zone 'Asia/Singapore')::date),
  p_search text default null,
  p_limit integer default 250,
  p_snapshot_at timestamptz default null,
  p_after_created_at timestamptz default null,
  p_after_client uuid default null
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
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
  if p_limit is null or p_limit<1 or p_limit>500 then
    raise exception 'limit_must_be_between_1_and_500' using errcode='22023';
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
    where business.created_at<=v_snapshot_at
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
  return v_result;
end
$$;

create or replace function public.platform_generate_improvement_report_v82(
  p_sector text default null,
  p_businesses uuid[] default null,
  p_branch uuid default null,
  p_from date default (((now() at time zone 'Asia/Singapore')::date) - 365),
  p_to date default ((now() at time zone 'Asia/Singapore')::date),
  p_search text default null,
  p_snapshot_at timestamptz default null
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_from_ts timestamptz;
  v_to_ts timestamptz;
  v_midpoint timestamptz;
  v_snapshot_at timestamptz:=coalesce(p_snapshot_at,clock_timestamp());
  v_search text:=nullif(btrim(p_search),'');
  v_result jsonb;
  v_insights jsonb:='[]'::jsonb;
  v_completed integer;
  v_active integer;
  v_returning integer;
  v_rate numeric;
  v_lapsed integer;
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
  if coalesce(cardinality(p_businesses),0)>100 then
    raise exception 'business_filter_exceeds_100' using errcode='22023';
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
  v_midpoint:=v_from_ts+((v_to_ts-v_from_ts)/2);

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
    where business.created_at<=v_snapshot_at
      and (nullif(btrim(p_sector),'') is null
           or business.industry=btrim(p_sector))
      and (coalesce(cardinality(p_businesses),0)=0
           or business.id=any(p_businesses))
      and (p_branch is null or exists(
        select 1 from public.branches branch
        where branch.id=p_branch and branch.business_id=business.id
          and branch.created_at<=v_snapshot_at
      ))
      and (
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
        or exists(
          select 1 from public.clients client
          where client.business_id=business.id
            and client.created_at<=v_snapshot_at
            and (
              client.full_name ilike '%'||v_search||'%'
              or coalesce(client.email,'') ilike '%'||v_search||'%'
              or coalesce(client.phone,'') ilike '%'||v_search||'%'
            )
            and (p_branch is null or exists(
              select 1 from public.sales sale
              where sale.business_id=business.id and sale.client_id=client.id
                and sale.branch_id=p_branch and sale.created_at<=v_snapshot_at
                and sale.occurred_at<v_to_ts
            ))
        )
      )
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
  sales_scope as materialized (
    select sale.*,business.currency
    from public.sales sale
    join selected_businesses business on business.id=sale.business_id
    where sale.created_at<=v_snapshot_at
      and sale.occurred_at>=v_from_ts and sale.occurred_at<v_to_ts
      and (p_branch is null or sale.branch_id=p_branch)
      and (
        business.search_all
        or sale.client_id in(
          select client.id from eligible_clients client
          where client.business_id=sale.business_id
        )
      )
  ),
  completed_sales as materialized (
    select sale.* from sales_scope sale
    where sale.reversal_of is null and sale.amount_cents>0
      and sale.counts_as_revenue and not exists(
        select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id
          and reversal.created_at<=v_snapshot_at
          and reversal.occurred_at<v_to_ts
      )
  ),
  visit_sales as materialized (
    select sale.* from sales_scope sale
    where sale.reversal_of is null and sale.amount_cents>0
      and sale.counts_as_visit and not exists(
        select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id
          and reversal.created_at<=v_snapshot_at
          and reversal.occurred_at<v_to_ts
      )
  ),
  payment_scope as materialized (
    select payment.*,business.currency,
           coalesce(payment.client_id,linked_sale.client_id) resolved_client_id
    from public.payments payment
    join selected_businesses business on business.id=payment.business_id
    left join public.sales linked_sale
      on linked_sale.id=payment.sale_id
     and linked_sale.business_id=payment.business_id
    where payment.created_at<=v_snapshot_at
      and payment.occurred_at>=v_from_ts and payment.occurred_at<v_to_ts
      and (p_branch is null or payment.branch_id=p_branch)
      and (
        business.search_all
        or coalesce(payment.client_id,linked_sale.client_id) in(
          select client.id from eligible_clients client
          where client.business_id=payment.business_id
        )
      )
  ),
  period_customers as materialized (
    select client.id client_id,client.business_id,client.business_name,
      client.industry,client.currency,client.full_name,client.email,client.phone,
      client.created_at customer_since,
      coalesce(sum(sale.amount_cents)
        filter(where sale.counts_as_revenue),0)::bigint net_revenue_cents,
      count(*) filter(
        where sale.id is not null and sale.reversal_of is null
          and sale.amount_cents>0 and sale.counts_as_revenue
          and not exists(
            select 1 from public.sales reversal
            where reversal.business_id=sale.business_id
              and reversal.reversal_of=sale.id
              and reversal.created_at<=v_snapshot_at
              and reversal.occurred_at<v_to_ts
          )
      )::integer completed_transactions,
      count(*) filter(
        where sale.id is not null and sale.reversal_of is null
          and sale.amount_cents>0 and sale.counts_as_visit
          and not exists(
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
      ) period_first_purchase_at,
      max(sale.occurred_at) filter(
        where sale.reversal_of is null and sale.amount_cents>0
          and sale.counts_as_revenue and not exists(
            select 1 from public.sales reversal
            where reversal.business_id=sale.business_id
              and reversal.reversal_of=sale.id
              and reversal.created_at<=v_snapshot_at
              and reversal.occurred_at<v_to_ts
          )
      ) period_last_purchase_at
    from eligible_clients client
    left join sales_scope sale
      on sale.business_id=client.business_id and sale.client_id=client.id
    group by client.id,client.business_id,client.business_name,client.industry,
             client.currency,client.full_name,client.email,client.phone,
             client.created_at
  ),
  customer_metrics as materialized (
    select customer.*,
      coalesce((
        select sum(payment.amount_cents)
          filter(where payment.method not in('credit','gift_card'))
        from payment_scope payment
        where payment.business_id=customer.business_id
          and payment.resolved_client_id=customer.client_id
      ),0)::bigint cash_collected_cents,
      lifetime.first_purchase_at,lifetime.last_purchase_at,
      case when lifetime.last_purchase_at is null then null
        else p_to-(lifetime.last_purchase_at at time zone 'Asia/Singapore')::date
      end days_since_last_purchase
    from period_customers customer
    left join lateral(
      select min(sale.occurred_at) first_purchase_at,
             max(sale.occurred_at) last_purchase_at
      from public.sales sale
      where sale.business_id=customer.business_id
        and sale.client_id=customer.client_id
        and sale.created_at<=v_snapshot_at and sale.occurred_at<v_to_ts
        and (p_branch is null or sale.branch_id=p_branch)
        and sale.reversal_of is null and sale.amount_cents>0
        and sale.counts_as_revenue and not exists(
          select 1 from public.sales reversal
          where reversal.business_id=sale.business_id
            and reversal.reversal_of=sale.id
            and reversal.created_at<=v_snapshot_at
            and reversal.occurred_at<v_to_ts
        )
    ) lifetime on true
  ),
  currency_metrics as materialized (
    select business.currency,
      coalesce((
        select sum(sale.amount_cents)
          filter(where sale.counts_as_revenue)
        from sales_scope sale where sale.currency=business.currency
      ),0)::bigint net_revenue_cents,
      coalesce((
        select sum(payment.amount_cents)
          filter(where payment.method not in('credit','gift_card'))
        from payment_scope payment where payment.currency=business.currency
      ),0)::bigint cash_collected_cents,
      (select count(*) from completed_sales sale
        where sale.currency=business.currency)::integer completed_transactions,
      (select count(*) from customer_metrics customer
        where customer.currency=business.currency
          and customer.visit_count>0)::integer active_customers,
      (select count(*) from customer_metrics customer
        where customer.currency=business.currency
          and customer.visit_count>=2)::integer returning_customers,
      (select count(*) from customer_metrics customer
        where customer.currency=business.currency
          and customer.days_since_last_purchase>90)::integer lapsed_customers,
      coalesce((
        select sum(sale.amount_cents)
          filter(where sale.counts_as_revenue and sale.occurred_at<v_midpoint)
        from sales_scope sale where sale.currency=business.currency
      ),0)::bigint previous_half_revenue_cents,
      coalesce((
        select sum(sale.amount_cents)
          filter(where sale.counts_as_revenue and sale.occurred_at>=v_midpoint)
        from sales_scope sale where sale.currency=business.currency
      ),0)::bigint current_half_revenue_cents
    from (select distinct currency from selected_businesses) business
  ),
  business_metrics as materialized (
    select business.id business_id,business.name,business.industry,
      business.currency,
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
      (select count(*) from customer_metrics customer
        where customer.business_id=business.id
          and customer.visit_count>0)::integer active_customers,
      (select count(*) from customer_metrics customer
        where customer.business_id=business.id
          and customer.visit_count>=2)::integer returning_customers
    from selected_businesses business
    left join sales_scope sale on sale.business_id=business.id
    group by business.id,business.name,business.industry,business.currency
  ),
  branch_metrics as materialized (
    select branch.id branch_id,branch.business_id,business.name business_name,
      business.currency,branch.name,branch.active,
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
      count(distinct sale.client_id) filter(
        where sale.reversal_of is null and sale.amount_cents>0
          and sale.counts_as_visit
          and not exists(
            select 1 from public.sales reversal
            where reversal.business_id=sale.business_id
              and reversal.reversal_of=sale.id
              and reversal.created_at<=v_snapshot_at
              and reversal.occurred_at<v_to_ts
          )
      )::integer active_customers
    from selected_businesses business
    join public.branches branch on branch.business_id=business.id
      and branch.created_at<=v_snapshot_at
    left join sales_scope sale
      on sale.business_id=branch.business_id and sale.branch_id=branch.id
    where p_branch is null or branch.id=p_branch
    group by branch.id,branch.business_id,business.name,business.currency,
             branch.name,branch.active
  ),
  month_series as (
    select month_start::date from generate_series(
      date_trunc('month',v_from_ts at time zone 'Asia/Singapore')::date,
      date_trunc('month',(v_to_ts-interval '1 millisecond')
        at time zone 'Asia/Singapore')::date,
      interval '1 month'
    ) month_start
  ),
  monthly as materialized (
    select month.month_start,currency.currency,
      coalesce(sum(sale.amount_cents)
        filter(where sale.counts_as_revenue),0)::bigint net_revenue_cents,
      count(*) filter(
        where sale.reversal_of is null and sale.amount_cents>0
          and sale.counts_as_revenue
          and not exists(
            select 1 from public.sales reversal
            where reversal.business_id=sale.business_id
              and reversal.reversal_of=sale.id
              and reversal.created_at<=v_snapshot_at
              and reversal.occurred_at<v_to_ts
          )
      )::integer transactions,
      count(distinct sale.client_id)
        filter(where sale.client_id is not null
          and sale.reversal_of is null and sale.amount_cents>0
          and sale.counts_as_visit
          and not exists(
            select 1 from public.sales reversal
            where reversal.business_id=sale.business_id
              and reversal.reversal_of=sale.id
              and reversal.created_at<=v_snapshot_at
              and reversal.occurred_at<v_to_ts
          ))::integer active_customers
    from month_series month
    cross join (select distinct currency from selected_businesses) currency
    left join sales_scope sale on sale.currency=currency.currency
      and (sale.occurred_at at time zone 'Asia/Singapore')::date
        >=month.month_start
      and (sale.occurred_at at time zone 'Asia/Singapore')::date
        <(month.month_start+interval '1 month')::date
    group by month.month_start,currency.currency
  )
  select jsonb_build_object(
    'generated_at',v_snapshot_at,'snapshot_at',v_snapshot_at,
    'methodology',jsonb_build_object(
      'timezone','Asia/Singapore',
      'revenue','net immutable sales-ledger events in the selected period',
      'cash','payment ledger including refunds, excluding credit and gift-card tenders',
      'returning_customer','at least two unreversed visit-counting sales in the selected period',
      'returning_rate_denominator','customers with at least one visit in the selected period',
      'lapsed_customer','lifetime last unreversed revenue purchase as of report end is more than 90 days old',
      'search','firm or branch match includes its whole scope; otherwise only matching customers and their transactions',
      'currency','money aggregates are calculated independently by currency'
    ),
    'scope',jsonb_build_object(
      'sector',nullif(btrim(p_sector),''),
      'business_ids',coalesce(to_jsonb(p_businesses),'[]'::jsonb),
      'branch_id',p_branch,'from',p_from,'to',p_to,'search',v_search,
      'days',(p_to-p_from)+1,'firm_count',(select count(*) from selected_businesses),
      'branch_count',(select count(*) from branch_metrics),
      'customer_count',(select count(*) from customer_metrics)
    ),
    'summary',jsonb_build_object(
      'currency_mode',case when (select count(*) from currency_metrics)<=1
        then 'single' else 'multiple' end,
      'currency',case when (select count(*) from currency_metrics)=1
        then (select currency from currency_metrics limit 1) else null end,
      'net_revenue_cents',case when (select count(*) from currency_metrics)=1
        then (select net_revenue_cents from currency_metrics limit 1) else null end,
      'cash_collected_cents',case when (select count(*) from currency_metrics)=1
        then (select cash_collected_cents from currency_metrics limit 1) else null end,
      'completed_transactions',(select count(*) from completed_sales),
      'active_customers',(select count(*) from customer_metrics where visit_count>0),
      'returning_customers',(select count(*) from customer_metrics where visit_count>=2),
      'returning_rate_pct',case
        when (select count(*) from customer_metrics where visit_count>0)=0 then 0
        else round(100.0*(select count(*) from customer_metrics where visit_count>=2)
          /(select count(*) from customer_metrics where visit_count>0),1) end,
      'lapsed_customers',(select count(*) from customer_metrics
        where days_since_last_purchase>90)
    ),
    'summary_by_currency',coalesce((
      select jsonb_agg(to_jsonb(metric)||jsonb_build_object(
        'returning_rate_pct',case when metric.active_customers=0 then 0
          else round(100.0*metric.returning_customers/metric.active_customers,1) end,
        'average_revenue_per_active_customer_cents',
          case when metric.active_customers=0 then 0
          else round(metric.net_revenue_cents::numeric/metric.active_customers)::bigint end
      ) order by metric.currency)
      from currency_metrics metric
    ),'[]'::jsonb),
    'businesses',coalesce((
      select jsonb_agg(to_jsonb(metric)
        order by metric.currency,metric.net_revenue_cents desc,metric.name)
      from business_metrics metric
    ),'[]'::jsonb),
    'branches',coalesce((
      select jsonb_agg(to_jsonb(metric)
        order by metric.currency,metric.net_revenue_cents desc,
                 metric.business_name,metric.name)
      from branch_metrics metric
    ),'[]'::jsonb),
    'monthly_trend',coalesce((
      select jsonb_agg(to_jsonb(metric)
        order by metric.month_start,metric.currency)
      from monthly metric
    ),'[]'::jsonb),
    'customer_total',(select count(*) from customer_metrics)
  ) into v_result;

  v_completed:=coalesce((v_result#>>'{summary,completed_transactions}')::integer,0);
  v_active:=coalesce((v_result#>>'{summary,active_customers}')::integer,0);
  v_returning:=coalesce((v_result#>>'{summary,returning_customers}')::integer,0);
  v_rate:=coalesce((v_result#>>'{summary,returning_rate_pct}')::numeric,0);
  v_lapsed:=coalesce((v_result#>>'{summary,lapsed_customers}')::integer,0);
  if v_completed<30 then
    v_insights:=v_insights||jsonb_build_array(jsonb_build_object(
      'key','data_foundation','priority','foundation',
      'title','Build a larger transaction baseline',
      'evidence',jsonb_build_object('completed_transactions',v_completed,'target',30),
      'recommendation','Wait for at least 30 completed transactions in this exact scope before treating movement as a durable trend.'
    ));
  end if;
  if v_active>=5 and v_rate<30 then
    v_insights:=v_insights||jsonb_build_array(jsonb_build_object(
      'key','repeat_visit_gap','priority','high',
      'title','Strengthen the second-visit journey',
      'evidence',jsonb_build_object('active_customers',v_active,
        'returning_customers',v_returning,'returning_rate_pct',v_rate),
      'recommendation','Give first-time customers one clear next-visit action and measure conversion to a second completed visit.'
    ));
  end if;
  if v_lapsed>0 then
    v_insights:=v_insights||jsonb_build_array(jsonb_build_object(
      'key','lapsed_customers','priority','medium',
      'title','Create a lapsed-customer recovery queue',
      'evidence',jsonb_build_object('customers_over_90_days',v_lapsed),
      'recommendation','Prioritise customers whose lifetime last completed purchase is over 90 days old.'
    ));
  end if;
  if exists(
    select 1 from jsonb_to_recordset(v_result->'summary_by_currency')
      as currency(currency text,previous_half_revenue_cents bigint,
        current_half_revenue_cents bigint)
    where currency.previous_half_revenue_cents>0
      and currency.current_half_revenue_cents<currency.previous_half_revenue_cents
  ) then
    v_insights:=v_insights||jsonb_build_array(jsonb_build_object(
      'key','revenue_momentum_by_currency','priority','high',
      'title','Investigate recent revenue slowdowns',
      'evidence',jsonb_build_object(
        'currencies',(
          select jsonb_agg(to_jsonb(currency))
          from jsonb_to_recordset(v_result->'summary_by_currency')
            as currency(currency text,previous_half_revenue_cents bigint,
              current_half_revenue_cents bigint)
          where currency.previous_half_revenue_cents>0
            and currency.current_half_revenue_cents
              <currency.previous_half_revenue_cents
        )
      ),
      'recommendation','Compare branch and customer movement inside each currency; never combine unlike currencies.'
    ));
  end if;
  if jsonb_array_length(v_insights)=0 then
    v_insights:=jsonb_build_array(jsonb_build_object(
      'key','maintain_and_test','priority','monitor',
      'title','Maintain the baseline and test one improvement',
      'evidence',jsonb_build_object('completed_transactions',v_completed,
        'returning_rate_pct',v_rate),
      'recommendation','Keep this exact scope and date window as the baseline, then measure one controlled retention change.'
    ));
  end if;
  return v_result||jsonb_build_object('insights',v_insights);
end
$$;

revoke all on function public.platform_get_enterprise_hierarchy_v82(
  text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid
) from public,anon,authenticated;
revoke all on function public.platform_list_enterprise_customers_v82(
  text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid
) from public,anon,authenticated;
revoke all on function public.platform_generate_improvement_report_v82(
  text,uuid[],uuid,date,date,text,timestamptz
) from public,anon,authenticated;

grant execute on function public.platform_get_enterprise_hierarchy_v82(
  text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid
) to authenticated;
grant execute on function public.platform_list_enterprise_customers_v82(
  text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid
) to authenticated;
grant execute on function public.platform_generate_improvement_report_v82(
  text,uuid[],uuid,date,date,text,timestamptz
) to authenticated;

comment on function public.platform_get_enterprise_hierarchy_v82(
  text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid
) is 'Snapshot-keyset super-admin firm hierarchy; customer detail is paged separately.';
comment on function public.platform_list_enterprise_customers_v82(
  text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid
) is 'Snapshot-keyset super-admin customer detail for complete firm/branch/report exports.';
comment on function public.platform_generate_improvement_report_v82(
  text,uuid[],uuid,date,date,text,timestamptz
) is 'Snapshot super-admin improvement report with exact search semantics and currency-isolated money.';

commit;
