-- NESTLY v83 - CUSTOMER INTELLIGENCE, COMPLETE-WEEK FORECASTS AND STABLE EXPORTS
--
-- Period revenue/returning metrics remain inside p_from..p_to. Inactivity and
-- last-purchase facts are lifetime-as-of p_to. Interactive pages use a stable
-- generated-at cutoff plus an immutable (customer_since, client_id) keyset.
-- CSV export materialises a short-lived server snapshot so later writes cannot
-- create omissions, duplicates or mixed-cutoff rows while the file is fetched.

begin;

create table public.customer_intelligence_exports_v83 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id uuid,
  requested_by uuid not null references auth.users(id) on delete cascade,
  from_date date not null,
  to_date date not null,
  snapshot_at timestamptz not null,
  expires_at timestamptz not null,
  scope jsonb not null,
  methodology jsonb not null,
  data_quality jsonb not null,
  summary jsonb not null,
  forecast jsonb not null,
  total_customers integer not null check (total_customers >= 0),
  created_at timestamptz not null default now(),
  constraint customer_intelligence_exports_v83_window_check
    check (from_date <= to_date and expires_at > snapshot_at),
  constraint customer_intelligence_exports_v83_branch_fk
    foreign key (branch_id,business_id)
    references public.branches(id,business_id) on delete cascade
);

create table public.customer_intelligence_export_rows_v83 (
  export_id uuid not null
    references public.customer_intelligence_exports_v83(id) on delete cascade,
  ordinal integer not null check (ordinal > 0),
  client_id uuid not null,
  payload jsonb not null,
  primary key(export_id,ordinal),
  unique(export_id,client_id)
);
create index customer_intelligence_exports_v83_expiry_idx
  on public.customer_intelligence_exports_v83(expires_at);

alter table public.customer_intelligence_exports_v83 enable row level security;
alter table public.customer_intelligence_export_rows_v83 enable row level security;
revoke all on table public.customer_intelligence_exports_v83
  from public,anon,authenticated;
revoke all on table public.customer_intelligence_export_rows_v83
  from public,anon,authenticated;

create or replace function public.get_customer_intelligence_v83(
  p_business uuid,
  p_branch uuid default null,
  p_from date default (((now() at time zone 'Asia/Singapore')::date) - 365),
  p_to date default ((now() at time zone 'Asia/Singapore')::date),
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
  v_snapshot_at timestamptz := coalesce(p_snapshot_at,clock_timestamp());
  v_forecast_end_date date;
  v_forecast_start_date date;
  v_result jsonb;
  v_history_days integer := 0;
  v_active_weeks integer := 0;
  v_completed_transactions integer := 0;
  v_cash_observation_weeks integer := 0;
  v_forecast_eligible boolean;
  v_unmet jsonb := '[]'::jsonb;
  v_weekly_average numeric := 0;
  v_weekly_lower numeric := 0;
  v_weekly_upper numeric := 0;
  v_forecast jsonb;
begin
  if p_business is null then
    raise exception 'business_required' using errcode='22023';
  end if;
  if not app.has_perm(p_business,'view_finance') then
    raise exception 'view_finance_required' using errcode='42501';
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
  if (p_after_created_at is null)<>(p_after_client is null) then
    raise exception 'complete_customer_cursor_required' using errcode='22023';
  end if;
  if p_snapshot_at is not null and p_snapshot_at>clock_timestamp()+interval '1 minute' then
    raise exception 'snapshot_cannot_be_in_the_future' using errcode='22023';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches branch
    where branch.id=p_branch and branch.business_id=p_business
  ) then
    raise exception 'branch_not_in_business' using errcode='22023';
  end if;
  if not app.can_see_branch(p_business,p_branch) then
    raise exception 'branch_visibility_required' using errcode='42501';
  end if;

  v_from_ts:=p_from::timestamp at time zone 'Asia/Singapore';
  v_to_ts:=(p_to+1)::timestamp at time zone 'Asia/Singapore';
  -- Sunday is a complete Singapore ISO week; every other p_to excludes its
  -- partial week and anchors on that week's Monday.
  v_forecast_end_date:=case
    when extract(isodow from p_to)::integer=7 then p_to+1
    else p_to-(extract(isodow from p_to)::integer-1)
  end;
  v_forecast_start_date:=v_forecast_end_date-91;

  select coalesce(
    (v_forecast_end_date-1)
      - min((sale.occurred_at at time zone 'Asia/Singapore')::date),0
  )::integer
  into v_history_days
  from public.sales sale
  where sale.business_id=p_business
    and sale.created_at<=v_snapshot_at
    and sale.reversal_of is null
    and sale.amount_cents>0
    and sale.counts_as_revenue
    and sale.occurred_at
      < v_forecast_end_date::timestamp at time zone 'Asia/Singapore'
    and (p_branch is null or sale.branch_id=p_branch)
    and not exists(
      select 1 from public.sales reversal
      where reversal.business_id=sale.business_id
        and reversal.reversal_of=sale.id
        and reversal.created_at<=v_snapshot_at
        and reversal.occurred_at
          < v_forecast_end_date::timestamp at time zone 'Asia/Singapore'
    );

  select count(distinct date_trunc(
           'week',sale.occurred_at at time zone 'Asia/Singapore'
         ))::integer,
         count(*)::integer
  into v_active_weeks,v_completed_transactions
  from public.sales sale
  where sale.business_id=p_business
    and sale.created_at<=v_snapshot_at
    and sale.reversal_of is null
    and sale.amount_cents>0
    and sale.counts_as_revenue
    and sale.occurred_at
      >= v_forecast_start_date::timestamp at time zone 'Asia/Singapore'
    and sale.occurred_at
      < v_forecast_end_date::timestamp at time zone 'Asia/Singapore'
    and (p_branch is null or sale.branch_id=p_branch)
    and not exists(
      select 1 from public.sales reversal
      where reversal.business_id=sale.business_id
        and reversal.reversal_of=sale.id
        and reversal.created_at<=v_snapshot_at
        and reversal.occurred_at
          < v_forecast_end_date::timestamp at time zone 'Asia/Singapore'
    );

  with week_series as (
    select week_start::date
    from generate_series(
      v_forecast_start_date,
      v_forecast_end_date-7,
      interval '1 week'
    ) week_start
  ),weekly as (
    select week.week_start,
           coalesce(sum(payment.amount_cents) filter(
             where payment.method not in ('credit','gift_card')
           ),0)::numeric cash_cents,
           count(payment.id) filter(
             where payment.method not in ('credit','gift_card')
           )::integer payment_count
    from week_series week
    left join public.payments payment
      on payment.business_id=p_business
     and payment.created_at<=v_snapshot_at
     and payment.occurred_at
       >= week.week_start::timestamp at time zone 'Asia/Singapore'
     and payment.occurred_at
       < (week.week_start+7)::timestamp at time zone 'Asia/Singapore'
     and (p_branch is null or payment.branch_id=p_branch)
    group by week.week_start
  )
  select coalesce(avg(cash_cents),0),
         coalesce(percentile_cont(0.20) within group(order by cash_cents),0),
         coalesce(percentile_cont(0.80) within group(order by cash_cents),0),
         count(*) filter(where payment_count>0)::integer
  into v_weekly_average,v_weekly_lower,v_weekly_upper,v_cash_observation_weeks
  from weekly;

  if v_history_days<90 then
    v_unmet:=v_unmet||jsonb_build_array(jsonb_build_object(
      'key','history_days','actual',v_history_days,'required',90
    ));
  end if;
  if v_active_weeks<12 then
    v_unmet:=v_unmet||jsonb_build_array(jsonb_build_object(
      'key','active_weeks','actual',v_active_weeks,'required',12
    ));
  end if;
  if v_completed_transactions<30 then
    v_unmet:=v_unmet||jsonb_build_array(jsonb_build_object(
      'key','completed_transactions','actual',v_completed_transactions,'required',30
    ));
  end if;
  if v_cash_observation_weeks<8 then
    v_unmet:=v_unmet||jsonb_build_array(jsonb_build_object(
      'key','cash_observation_weeks','actual',v_cash_observation_weeks,'required',8
    ));
  end if;
  v_forecast_eligible:=jsonb_array_length(v_unmet)=0;

  if v_forecast_eligible then
    select jsonb_build_object(
      'status','available',
      'method','trailing_13_complete_singapore_calendar_weeks_p20_mean_p80',
      'data_valid_through',p_to,
      'observation_start',v_forecast_start_date,
      'observation_end_exclusive',v_forecast_end_date,
      'complete_weeks',13,
      'partial_report_end_week_excluded',
        extract(isodow from p_to)::integer<>7,
      'weekly_average_cents',round(v_weekly_average)::bigint,
      'weekly_lower_cents',round(v_weekly_lower)::bigint,
      'weekly_upper_cents',round(v_weekly_upper)::bigint,
      'next_90_days',jsonb_build_object(
        'lower_cents',greatest(0,round(v_weekly_lower*90/7))::bigint,
        'expected_cents',greatest(0,round(v_weekly_average*90/7))::bigint,
        'upper_cents',greatest(0,round(v_weekly_upper*90/7))::bigint
      ),
      'months',(
        select jsonb_agg(jsonb_build_object(
          'month_index',month_index,
          'from',month_start,
          'to',month_end,
          'lower_cents',greatest(0,round(
            v_weekly_lower*((month_end-month_start)+1)/7
          ))::bigint,
          'expected_cents',greatest(0,round(
            v_weekly_average*((month_end-month_start)+1)/7
          ))::bigint,
          'upper_cents',greatest(0,round(
            v_weekly_upper*((month_end-month_start)+1)/7
          ))::bigint
        ) order by month_index)
        from (
          select month_index,
                 (p_to+1+make_interval(months=>month_index-1))::date month_start,
                 (p_to+make_interval(months=>month_index))::date month_end
          from generate_series(1,3) month_index
        ) windows
      ),
      'caution','Observed 20th percentile, mean and 80th percentile from 13 complete Singapore calendar weeks; this operating range is not a guarantee.'
    ) into v_forecast;
  else
    v_forecast:=jsonb_build_object(
      'status','insufficient_data',
      'data_valid_through',p_to,
      'observation_start',v_forecast_start_date,
      'observation_end_exclusive',v_forecast_end_date,
      'unmet_thresholds',v_unmet,
      'required_thresholds',jsonb_build_object(
        'history_days',90,'active_weeks',12,
        'completed_transactions',30,'cash_observation_weeks',8
      ),
      'message','A 3-month cash-collection range appears only after enough complete-week evidence exists.'
    );
  end if;

  with period_sales as materialized (
    select sale.*
    from public.sales sale
    where sale.business_id=p_business
      and sale.created_at<=v_snapshot_at
      and sale.occurred_at>=v_from_ts and sale.occurred_at<v_to_ts
      and (p_branch is null or sale.branch_id=p_branch)
  ),valid_period_purchases as materialized (
    select sale.*
    from period_sales sale
    where sale.reversal_of is null and sale.amount_cents>0
      and sale.counts_as_revenue
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id
          and reversal.created_at<=v_snapshot_at
          and reversal.occurred_at<v_to_ts
      )
  ),valid_period_visits as materialized (
    select sale.*
    from period_sales sale
    where sale.reversal_of is null and sale.amount_cents>0
      and sale.counts_as_visit
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id
          and reversal.created_at<=v_snapshot_at
          and reversal.occurred_at<v_to_ts
      )
  ),valid_lifetime_purchases as materialized (
    select sale.*
    from public.sales sale
    where sale.business_id=p_business
      and sale.created_at<=v_snapshot_at
      and sale.occurred_at<v_to_ts
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
  ),period_revenue as (
    select sale.client_id,
           coalesce(sum(sale.amount_cents) filter(
             where sale.counts_as_revenue
           ),0)::bigint net_revenue_cents
    from period_sales sale where sale.client_id is not null
    group by sale.client_id
  ),period_purchases as (
    select sale.client_id,count(*)::integer purchase_count,
           min(sale.occurred_at) period_first_purchase_at,
           max(sale.occurred_at) period_last_purchase_at
    from valid_period_purchases sale where sale.client_id is not null
    group by sale.client_id
  ),period_visits as (
    select sale.client_id,count(*)::integer visit_count
    from valid_period_visits sale where sale.client_id is not null
    group by sale.client_id
  ),period_cash as (
    select coalesce(payment.client_id,sale.client_id) client_id,
           coalesce(sum(payment.amount_cents) filter(
             where payment.method not in ('credit','gift_card')
           ),0)::bigint cash_collected_cents
    from public.payments payment
    left join public.sales sale
      on sale.id=payment.sale_id and sale.business_id=payment.business_id
    where payment.business_id=p_business
      and payment.created_at<=v_snapshot_at
      and payment.occurred_at>=v_from_ts and payment.occurred_at<v_to_ts
      and (p_branch is null or payment.branch_id=p_branch)
      and coalesce(payment.client_id,sale.client_id) is not null
    group by coalesce(payment.client_id,sale.client_id)
  ),lifetime as (
    select sale.client_id,count(*)::integer lifetime_purchase_count,
           min(sale.occurred_at) first_purchase_at,
           max(sale.occurred_at) last_purchase_at,
           count(distinct sale.branch_id)::integer branches_visited,
           case when count(*)<2 then null else round(
             extract(epoch from(max(sale.occurred_at)-min(sale.occurred_at)))
             /86400/(count(*)-1),1
           ) end average_days_between_purchases
    from valid_lifetime_purchases sale where sale.client_id is not null
    group by sale.client_id
  ),client_metrics as materialized (
    select client.id client_id,client.full_name,client.email,client.phone,
           client.created_at customer_since,
           coalesce(revenue.net_revenue_cents,0)::bigint net_revenue_cents,
           coalesce(cash.cash_collected_cents,0)::bigint cash_collected_cents,
           coalesce(purchase.purchase_count,0)::integer purchase_count,
           coalesce(visit.visit_count,0)::integer visit_count,
           purchase.period_first_purchase_at,purchase.period_last_purchase_at,
           lifetime.first_purchase_at,lifetime.last_purchase_at,
           case when lifetime.last_purchase_at is null then null
             else p_to-(lifetime.last_purchase_at at time zone 'Asia/Singapore')::date
           end days_since_last_purchase,
           coalesce(lifetime.branches_visited,0)::integer branches_visited,
           coalesce(lifetime.lifetime_purchase_count,0)::integer lifetime_purchase_count,
           coalesce(purchase.purchase_count,0)>=2 returning_customer,
           case when coalesce(purchase.purchase_count,0)=0 then 0 else round(
             coalesce(revenue.net_revenue_cents,0)::numeric/purchase.purchase_count
           )::bigint end average_revenue_per_purchase_cents,
           lifetime.average_days_between_purchases
    from public.clients client
    left join period_revenue revenue on revenue.client_id=client.id
    left join period_purchases purchase on purchase.client_id=client.id
    left join period_visits visit on visit.client_id=client.id
    left join period_cash cash on cash.client_id=client.id
    left join lifetime on lifetime.client_id=client.id
    where client.business_id=p_business
      and client.created_at<=v_snapshot_at
      and (p_branch is null or lifetime.client_id is not null)
  ),page as materialized (
    select * from client_metrics customer
    where p_after_created_at is null
       or (customer.customer_since,customer.client_id)
          >(p_after_created_at,p_after_client)
    order by customer_since,client_id
    limit p_limit
  ),last_page as (
    select customer_since,client_id
    from page order by customer_since desc,client_id desc limit 1
  ),page_state as (
    select exists(
      select 1 from client_metrics customer,last_page last
      where (customer.customer_since,customer.client_id)
            >(last.customer_since,last.client_id)
    ) has_more
  )
  select jsonb_build_object(
    'generated_at',v_snapshot_at,
    'snapshot_at',v_snapshot_at,
    'scope',jsonb_build_object(
      'business_id',p_business,'business_name',business.name,
      'currency',business.currency,'branch_id',p_branch,'branch_name',branch.name,
      'from',p_from,'to',p_to,'timezone','Asia/Singapore'
    ),
    'methodology',jsonb_build_object(
      'period_metrics','Revenue, cash, active and returning metrics use p_from through p_to.',
      'lifetime_inactivity','Last purchase and inactivity use all valid purchases through p_to.',
      'revenue','Net immutable sales ledger events at the generated-at cutoff.',
      'cash_collected','External payment ledger less refunds; credit and gift-card tenders excluded.',
      'forecast','Thirteen complete Singapore calendar weeks; partial report-end week excluded; p20/mean/p80 range.',
      'returning_customer','At least two completed unreversed revenue transactions in the selected period.',
      'returning_rate_denominator','Active customers with at least one completed period purchase.',
      'pagination','Immutable customer_since/client_id keyset at one generated-at cutoff.'
    ),
    'data_quality',jsonb_build_object(
      'forecast_eligible',v_forecast_eligible,'history_days',v_history_days,
      'active_weeks',v_active_weeks,
      'completed_transactions',v_completed_transactions,
      'cash_observation_weeks',v_cash_observation_weeks,
      'required_thresholds',jsonb_build_object(
        'history_days',90,'active_weeks',12,
        'completed_transactions',30,'cash_observation_weeks',8
      ),'unmet_thresholds',v_unmet
    ),
    'summary',jsonb_build_object(
      'known_customers',(select count(*) from client_metrics),
      'active_customers',(select count(*) from client_metrics where purchase_count>0),
      'returning_customers',(select count(*) from client_metrics where returning_customer),
      'returning_rate_pct',(
        select case when count(*) filter(where purchase_count>0)=0 then 0
          else round(100.0*count(*) filter(where returning_customer)
            /count(*) filter(where purchase_count>0),1) end
        from client_metrics
      ),
      'net_revenue_cents',(select coalesce(sum(net_revenue_cents),0) from client_metrics),
      'cash_collected_cents',(select coalesce(sum(cash_collected_cents),0) from client_metrics),
      'average_revenue_per_active_customer_cents',(
        select case when count(*) filter(where purchase_count>0)=0 then 0
          else round(sum(net_revenue_cents)::numeric
            /count(*) filter(where purchase_count>0))::bigint end
        from client_metrics
      ),
      'average_purchase_frequency_days',(
        select round(avg(average_days_between_purchases),1)
        from client_metrics where average_days_between_purchases is not null
      ),
      'customers_over_90_days_inactive',(
        select count(*) from client_metrics where days_since_last_purchase>90
      )
    ),
    'forecast',v_forecast,
    'customers',coalesce((
      select jsonb_agg(to_jsonb(customer) order by customer_since,client_id)
      from page customer
    ),'[]'::jsonb),
    'pagination',jsonb_build_object(
      'limit',p_limit,'total_customers',(select count(*) from client_metrics),
      'returned_customers',(select count(*) from page),
      'has_more',coalesce((select has_more from page_state),false),
      'next_cursor',case
        when coalesce((select has_more from page_state),false) then (
          select jsonb_build_object(
            'customer_since',customer_since,'client_id',client_id
          ) from last_page
        ) else null end
    )
  ) into v_result
  from public.businesses business
  left join public.branches branch
    on branch.id=p_branch and branch.business_id=business.id
  where business.id=p_business;

  if v_result is null then
    raise exception 'business_not_found' using errcode='22023';
  end if;
  return v_result;
end
$$;

create or replace function public.create_customer_intelligence_export_v83(
  p_business uuid,
  p_branch uuid default null,
  p_from date default (((now() at time zone 'Asia/Singapore')::date)-365),
  p_to date default ((now() at time zone 'Asia/Singapore')::date)
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_export uuid:=gen_random_uuid();
  v_snapshot timestamptz:=clock_timestamp();
  v_expires timestamptz:=v_snapshot+interval '24 hours';
  v_page jsonb;
  v_cursor jsonb;
  v_customer jsonb;
  v_ordinal integer:=0;
begin
  if v_actor is null then
    raise exception 'authenticated_user_required' using errcode='42501';
  end if;
  if not app.has_perm(p_business,'view_finance') then
    raise exception 'view_finance_required' using errcode='42501';
  end if;
  delete from public.customer_intelligence_exports_v83
  where requested_by=v_actor and expires_at<=clock_timestamp();

  v_page:=public.get_customer_intelligence_v83(
    p_business,p_branch,p_from,p_to,500,v_snapshot,null,null
  );
  insert into public.customer_intelligence_exports_v83(
    id,business_id,branch_id,requested_by,from_date,to_date,snapshot_at,
    expires_at,scope,methodology,data_quality,summary,forecast,total_customers
  ) values (
    v_export,p_business,p_branch,v_actor,p_from,p_to,v_snapshot,v_expires,
    v_page->'scope',v_page->'methodology',v_page->'data_quality',
    v_page->'summary',v_page->'forecast',
    coalesce((v_page#>>'{pagination,total_customers}')::integer,0)
  );

  loop
    for v_customer in select value from jsonb_array_elements(v_page->'customers')
    loop
      v_ordinal:=v_ordinal+1;
      insert into public.customer_intelligence_export_rows_v83(
        export_id,ordinal,client_id,payload
      ) values (
        v_export,v_ordinal,(v_customer->>'client_id')::uuid,v_customer
      );
    end loop;
    v_cursor:=v_page#>'{pagination,next_cursor}';
    exit when v_cursor is null or v_cursor='null'::jsonb;
    v_page:=public.get_customer_intelligence_v83(
      p_business,p_branch,p_from,p_to,500,v_snapshot,
      (v_cursor->>'customer_since')::timestamptz,
      (v_cursor->>'client_id')::uuid
    );
  end loop;

  return jsonb_build_object(
    'export_id',v_export,'snapshot_at',v_snapshot,'expires_at',v_expires,
    'total_customers',v_ordinal
  );
end
$$;

create or replace function public.get_customer_intelligence_export_page_v83(
  p_export uuid,
  p_after_ordinal integer default 0,
  p_limit integer default 500
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_export public.customer_intelligence_exports_v83%rowtype;
  v_result jsonb;
begin
  if p_after_ordinal is null or p_after_ordinal<0 then
    raise exception 'after_ordinal_must_be_nonnegative' using errcode='22023';
  end if;
  if p_limit is null or p_limit<1 or p_limit>500 then
    raise exception 'limit_must_be_between_1_and_500' using errcode='22023';
  end if;
  select * into v_export
  from public.customer_intelligence_exports_v83 export
  where export.id=p_export and export.requested_by=v_actor;
  if not found then
    raise exception 'export_not_found' using errcode='22023';
  end if;
  if v_export.expires_at<=clock_timestamp() then
    raise exception 'export_expired' using errcode='22023';
  end if;
  if not app.has_perm(v_export.business_id,'view_finance')
     or not app.can_see_branch(v_export.business_id,v_export.branch_id) then
    raise exception 'export_scope_no_longer_permitted' using errcode='42501';
  end if;

  with page as materialized (
    select row.ordinal,row.payload
    from public.customer_intelligence_export_rows_v83 row
    where row.export_id=p_export and row.ordinal>p_after_ordinal
    order by row.ordinal limit p_limit
  )
  select jsonb_build_object(
    'export_id',v_export.id,'snapshot_at',v_export.snapshot_at,
    'expires_at',v_export.expires_at,'scope',v_export.scope,
    'methodology',v_export.methodology,'data_quality',v_export.data_quality,
    'summary',v_export.summary,'forecast',v_export.forecast,
    'customers',coalesce((
      select jsonb_agg(payload order by ordinal) from page
    ),'[]'::jsonb),
    'pagination',jsonb_build_object(
      'limit',p_limit,'total_customers',v_export.total_customers,
      'returned_customers',(select count(*) from page),
      'has_more',coalesce((select max(ordinal) from page),p_after_ordinal)
        <v_export.total_customers,
      'next_ordinal',case
        when coalesce((select max(ordinal) from page),p_after_ordinal)
          <v_export.total_customers
        then (select max(ordinal) from page) else null end
    )
  ) into v_result;
  return v_result;
end
$$;

revoke all on function public.get_customer_intelligence_v83(
  uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid
) from public,anon,authenticated;
revoke all on function public.create_customer_intelligence_export_v83(
  uuid,uuid,date,date
) from public,anon,authenticated;
revoke all on function public.get_customer_intelligence_export_page_v83(
  uuid,integer,integer
) from public,anon,authenticated;
grant execute on function public.get_customer_intelligence_v83(
  uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid
) to authenticated;
grant execute on function public.create_customer_intelligence_export_v83(
  uuid,uuid,date,date
) to authenticated;
grant execute on function public.get_customer_intelligence_export_page_v83(
  uuid,integer,integer
) to authenticated;

comment on function public.get_customer_intelligence_v83(
  uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid
) is
  'Customer intelligence with period metrics, lifetime inactivity, complete-week forecast and snapshot keyset pagination.';
comment on function public.create_customer_intelligence_export_v83(
  uuid,uuid,date,date
) is
  'Materialises a 24-hour customer-intelligence export at one immutable generated-at cutoff.';

commit;
