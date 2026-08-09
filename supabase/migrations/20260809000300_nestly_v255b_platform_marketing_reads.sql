-- NESTLY v255b - SUPER-ADMIN MARKETING AND ENGAGEMENT READS
--
-- The audit found that nothing in the platform console reads the telemetry the
-- product already collects: both v100 and v175 report RPCs are called from
-- nowhere, and marketing visibility is two KPI tiles. These three reads close
-- that, super-admin only.
--
-- Deliberate honesty rules baked into the SQL, not left to the UI:
--   * push_delivered and push_opens are literal JSON null, never 0. The Web
--     Push API returns no delivery receipt and no open callback, so a zero
--     would be a measurement claim we cannot make (audit finding 1.18).
--   * explore demand reports the query SHAPE only - never the typed text -
--     and suppresses any bucket seen fewer than 5 times (audit 5e).
--   * every count is scoped by business and every range is bounded, so a
--     console mistake cannot turn into an unbounded scan.
--
-- Authorization is app.is_super_admin() ONLY. A business owner, a staff member
-- and a platform sales_staff account are all denied; these are cross-tenant
-- reads and no tenant role may hold one.

begin;

create or replace function public.platform_engagement_monthly_v255(
  p_from date,
  p_to date,
  p_businesses uuid[] default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid:=auth.uid();
  v_from timestamptz;
  v_to timestamptz;
  v_rows jsonb;
  v_trend jsonb;
  v_summary jsonb;
  v_total integer:=0;
begin
  if v_actor is null then
    raise exception 'authenticated platform session is required'
      using errcode='28000';
  end if;
  if not app.is_super_admin() then
    raise exception 'platform engagement reporting is super admin only'
      using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_to<p_from then
    raise exception 'report range must be positive' using errcode='22023';
  end if;
  if p_to>p_from+interval '24 months' then
    raise exception 'report range may not exceed 24 months'
      using errcode='22023';
  end if;
  if p_businesses is not null
     and coalesce(array_length(p_businesses,1),0)>100 then
    raise exception 'at most 100 businesses may be requested'
      using errcode='22023';
  end if;
  if p_limit is null or p_limit not between 1 and 1000 then
    raise exception 'row limit must be 1..1000' using errcode='22023';
  end if;

  v_from:=(date_trunc('month',p_from::timestamp) at time zone 'Asia/Singapore');
  v_to:=(
    (date_trunc('month',p_to::timestamp)+interval '1 month')
    at time zone 'Asia/Singapore'
  );

  with sends as(
    select
      record.business_id,
      pg_catalog.to_char(
        date_trunc('month',record.occurred_at at time zone 'Asia/Singapore'),
        'YYYY-MM'
      ) as month,
      count(*)::bigint as sends,
      count(distinct
        record.campaign_kind||':'||record.campaign_ref_id::text
      )::bigint as campaigns
    from public.campaign_send_records_v255 record
    where record.occurred_at>=v_from and record.occurred_at<v_to
      and (p_businesses is null or record.business_id=any(p_businesses))
    group by 1,2
  ),
  pushes as(
    select
      event_row.business_id,
      pg_catalog.to_char(
        date_trunc('month',result.created_at at time zone 'Asia/Singapore'),
        'YYYY-MM'
      ) as month,
      count(*) filter(where result.result='sent')::bigint as push_sent,
      count(*) filter(
        where result.result in ('failed','gone')
      )::bigint as push_failed
    from public.customer_push_delivery_results_v95 result
    join public.customer_push_deliveries_v95 delivery
      on delivery.id=result.delivery_id
    join public.customer_in_app_inbox_events event_row
      on event_row.id=delivery.event_id
    where result.created_at>=v_from and result.created_at<v_to
      and (p_businesses is null or event_row.business_id=any(p_businesses))
    group by 1,2
  ),
  opens as(
    select
      state.business_id,
      pg_catalog.to_char(
        date_trunc('month',state.read_at at time zone 'Asia/Singapore'),
        'YYYY-MM'
      ) as month,
      count(*)::bigint as inbox_opens
    from public.customer_in_app_inbox_state state
    where state.read_at>=v_from and state.read_at<v_to
      and (p_businesses is null or state.business_id=any(p_businesses))
    group by 1,2
  ),
  adoption as(
    select
      event_row.business_id,
      pg_catalog.to_char(
        date_trunc('month',event_row.occurred_at at time zone 'Asia/Singapore'),
        'YYYY-MM'
      ) as month,
      count(distinct event_row.actor_user_id) filter(
        where event_row.actor_scope='merchant'
      )::bigint as merchant_mau,
      count(distinct event_row.session_id)::bigint as sessions
    from public.product_adoption_events_v100 event_row
    where event_row.business_id is not null
      and event_row.occurred_at>=v_from and event_row.occurred_at<v_to
      and (p_businesses is null or event_row.business_id=any(p_businesses))
    group by 1,2
  ),
  merchant_daily as(
    select
      event_row.business_id,
      pg_catalog.to_char(
        date_trunc('month',event_row.occurred_at at time zone 'Asia/Singapore'),
        'YYYY-MM'
      ) as month,
      (event_row.occurred_at at time zone 'Asia/Singapore')::date as open_day,
      count(distinct event_row.actor_user_id)::bigint as actors
    from public.product_adoption_events_v100 event_row
    where event_row.business_id is not null
      and event_row.actor_scope='merchant'
      and event_row.occurred_at>=v_from and event_row.occurred_at<v_to
      and (p_businesses is null or event_row.business_id=any(p_businesses))
    group by 1,2,3
  ),
  merchant_dau as(
    select
      daily.business_id,daily.month,
      round(avg(daily.actors),2) as merchant_dau
    from merchant_daily daily
    group by 1,2
  ),
  customer_opens as(
    select
      open_row.business_id,
      pg_catalog.to_char(
        date_trunc('month',open_row.open_date::timestamp),'YYYY-MM'
      ) as month,
      count(distinct coalesce(
        open_row.auth_user_id,open_row.client_id
      ))::bigint as customer_mau
    from public.customer_account_open_days_v175 open_row
    where open_row.open_date>=(v_from at time zone 'Asia/Singapore')::date
      and open_row.open_date<(v_to at time zone 'Asia/Singapore')::date
      and (p_businesses is null or open_row.business_id=any(p_businesses))
    group by 1,2
  ),
  redemptions as(
    select
      redemption.business_id,
      pg_catalog.to_char(
        date_trunc(
          'month',redemption.redeemed_at at time zone 'Asia/Singapore'
        ),'YYYY-MM'
      ) as month,
      count(*)::bigint as redemptions
    from public.loyalty_redemptions redemption
    where redemption.redeemed_at>=v_from and redemption.redeemed_at<v_to
      and (p_businesses is null or redemption.business_id=any(p_businesses))
    group by 1,2
  ),
  bookings as(
    select
      request.business_id,
      pg_catalog.to_char(
        date_trunc('month',request.created_at at time zone 'Asia/Singapore'),
        'YYYY-MM'
      ) as month,
      count(*)::bigint as bookings
    from public.booking_requests request
    where request.created_at>=v_from and request.created_at<v_to
      and (p_businesses is null or request.business_id=any(p_businesses))
    group by 1,2
  ),
  sale_counts as(
    select
      sale.business_id,
      pg_catalog.to_char(
        date_trunc('month',sale.occurred_at at time zone 'Asia/Singapore'),
        'YYYY-MM'
      ) as month,
      count(*)::bigint as sales_count
    from public.sales sale
    where sale.occurred_at>=v_from and sale.occurred_at<v_to
      and sale.reversal_of is null
      and (p_businesses is null or sale.business_id=any(p_businesses))
    group by 1,2
  ),
  keys as(
    select business_id,month from sends
    union select business_id,month from pushes
    union select business_id,month from opens
    union select business_id,month from adoption
    union select business_id,month from customer_opens
    union select business_id,month from redemptions
    union select business_id,month from bookings
    union select business_id,month from sale_counts
  ),
  rows_out as(
    select
      key.business_id,key.month,
      coalesce(business.name,'Removed business') as business_name,
      (
        select count(*)::bigint
        from public.customer_links link
        where link.business_id=key.business_id
          and link.state='verified'
          and link.created_at
              <((key.month||'-01')::date+interval '1 month')
                at time zone 'Asia/Singapore'
      ) as customers,
      coalesce(sends.campaigns,0) as campaigns,
      coalesce(pushes.push_sent,0) as push_sent,
      coalesce(pushes.push_failed,0) as push_failed,
      coalesce(sends.sends,0) as sends,
      coalesce(opens.inbox_opens,0) as inbox_opens,
      coalesce(merchant_dau.merchant_dau,0) as merchant_dau,
      coalesce(adoption.merchant_mau,0) as merchant_mau,
      coalesce(adoption.sessions,0) as sessions,
      coalesce(customer_opens.customer_mau,0) as customer_mau,
      coalesce(redemptions.redemptions,0) as redemptions,
      coalesce(bookings.bookings,0) as bookings,
      coalesce(sale_counts.sales_count,0) as sales_count
    from keys key
    left join public.businesses business on business.id=key.business_id
    left join sends
      on sends.business_id=key.business_id and sends.month=key.month
    left join pushes
      on pushes.business_id=key.business_id and pushes.month=key.month
    left join opens
      on opens.business_id=key.business_id and opens.month=key.month
    left join adoption
      on adoption.business_id=key.business_id and adoption.month=key.month
    left join merchant_dau
      on merchant_dau.business_id=key.business_id
     and merchant_dau.month=key.month
    left join customer_opens
      on customer_opens.business_id=key.business_id
     and customer_opens.month=key.month
    left join redemptions
      on redemptions.business_id=key.business_id
     and redemptions.month=key.month
    left join bookings
      on bookings.business_id=key.business_id and bookings.month=key.month
    left join sale_counts
      on sale_counts.business_id=key.business_id
     and sale_counts.month=key.month
  ),
  page as(
    select * from rows_out
    order by month desc,business_name,business_id
    limit p_limit
  )
  select
    coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'business_id',page.business_id,'business_name',page.business_name,
          'month',page.month,'customers',page.customers,
          'campaigns',page.campaigns,'push_sent',page.push_sent,
          'push_failed',page.push_failed,'sends',page.sends,
          'inbox_opens',page.inbox_opens,'merchant_dau',page.merchant_dau,
          'merchant_mau',page.merchant_mau,'sessions',page.sessions,
          'customer_mau',page.customer_mau,'redemptions',page.redemptions,
          'bookings',page.bookings,'sales_count',page.sales_count
        )
        order by page.month desc,page.business_name,page.business_id
      ),
      '[]'::jsonb
    ),
    (select count(*)::integer from rows_out)
  into v_rows,v_total
  from page;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'month',trend.month,'businesses',trend.businesses,
        'customers',trend.customers,'campaigns',trend.campaigns,
        'push_sent',trend.push_sent,'sends',trend.sends,
        'inbox_opens',trend.inbox_opens
      )
      order by trend.month desc
    ),
    '[]'::jsonb
  ) into v_trend
  from(
    select
      item->>'month' as month,
      count(*)::bigint as businesses,
      sum((item->>'customers')::bigint) as customers,
      sum((item->>'campaigns')::bigint) as campaigns,
      sum((item->>'push_sent')::bigint) as push_sent,
      sum((item->>'sends')::bigint) as sends,
      sum((item->>'inbox_opens')::bigint) as inbox_opens
    from pg_catalog.jsonb_array_elements(v_rows) as element(item)
    group by 1
  ) trend;

  -- 'customers' is a running total per business-month, so summing every month
  -- would count the same customer once per month. The headline is the newest
  -- month only.
  select pg_catalog.jsonb_build_object(
    'businesses',count(distinct item->>'business_id'),
    'months',count(distinct item->>'month'),
    'customers',coalesce(sum((item->>'customers')::bigint) filter(
      where item->>'month'=(
        select pg_catalog.max(latest->>'month')
        from pg_catalog.jsonb_array_elements(v_rows) as newest(latest)
      )
    ),0),
    'campaigns',coalesce(sum((item->>'campaigns')::bigint),0),
    'push_sent',coalesce(sum((item->>'push_sent')::bigint),0),
    'sends',coalesce(sum((item->>'sends')::bigint),0),
    'inbox_opens',coalesce(sum((item->>'inbox_opens')::bigint),0)
  ) into v_summary
  from pg_catalog.jsonb_array_elements(v_rows) as element(item);

  return pg_catalog.jsonb_build_object(
    'scope',pg_catalog.jsonb_build_object(
      'from',p_from,'to',p_to,'limit',p_limit,
      'business_filter_count',coalesce(array_length(p_businesses,1),0),
      'timezone','Asia/Singapore'
    ),
    'methodology',pg_catalog.jsonb_build_object(
      'customers',
        'Verified customer links that existed at the end of that month.',
      'campaigns',
        'Distinct campaigns with at least one send record in that month.',
      'push_sent',
        'Web push attempts the dispatcher reported as sent in that month.',
      'push_opens',
        'Not tracked. The Web Push API returns no delivery receipt or open callback.',
      'months','Calendar months in Asia/Singapore.'
    ),
    'summary',coalesce(v_summary,'{}'::jsonb),
    'businesses',v_rows,
    'monthly_trend',v_trend,
    'total_count',v_total,
    'has_more',v_total>p_limit,
    'snapshot_at',clock_timestamp()
  );
end
$$;
revoke all privileges on function public.platform_engagement_monthly_v255(
  date,date,uuid[],integer
) from public,anon,authenticated,service_role;
grant execute on function public.platform_engagement_monthly_v255(
  date,date,uuid[],integer
) to authenticated;

create or replace function public.platform_campaign_detail_v255(
  p_business uuid,
  p_from date,
  p_to date,
  p_limit integer default 100,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid:=auth.uid();
  v_from timestamptz;
  v_to timestamptz;
  v_items jsonb;
  v_summary jsonb;
  v_total integer:=0;
begin
  if v_actor is null then
    raise exception 'authenticated platform session is required'
      using errcode='28000';
  end if;
  if not app.is_super_admin() then
    raise exception 'platform campaign reporting is super admin only'
      using errcode='42501';
  end if;
  if p_business is null then
    raise exception 'a business is required' using errcode='22023';
  end if;
  if p_from is null or p_to is null or p_to<p_from then
    raise exception 'report range must be positive' using errcode='22023';
  end if;
  if p_to>p_from+interval '24 months' then
    raise exception 'report range may not exceed 24 months'
      using errcode='22023';
  end if;
  if p_limit is null or p_limit not between 1 and 500 then
    raise exception 'row limit must be 1..500' using errcode='22023';
  end if;
  if p_offset is null or p_offset<0 or p_offset>100000 then
    raise exception 'offset must be 0..100000' using errcode='22023';
  end if;

  v_from:=(p_from::timestamp at time zone 'Asia/Singapore');
  v_to:=((p_to::timestamp+interval '1 day') at time zone 'Asia/Singapore');

  with scoped as(
    select record.*
    from public.campaign_send_records_v255 record
    where record.business_id=p_business
      and record.occurred_at>=v_from and record.occurred_at<v_to
  ),
  push_facts as(
    select
      scoped.campaign_kind,scoped.campaign_ref_id,
      count(*) filter(where result.result='sent')::bigint as push_sent,
      count(*) filter(
        where result.result in ('failed','gone')
      )::bigint as push_failed
    from scoped
    join public.customer_push_deliveries_v95 delivery
      on delivery.event_id=scoped.inbox_event_id
    join public.customer_push_delivery_results_v95 result
      on result.delivery_id=delivery.id
    group by 1,2
  ),
  open_facts as(
    select
      scoped.campaign_kind,scoped.campaign_ref_id,
      count(*) filter(where state.read_at is not null)::bigint as in_app_opens
    from scoped
    join public.customer_in_app_inbox_state state
      on state.event_id=scoped.inbox_event_id
    group by 1,2
  ),
  campaigns as(
    select
      scoped.campaign_kind,scoped.campaign_ref_id,
      max(scoped.campaign_label) as campaign_label,
      min(scoped.occurred_at) as first_sent_at,
      max(scoped.occurred_at) as last_sent_at,
      count(*)::bigint as recipients,
      count(*) filter(where scoped.channel='in_app')::bigint as in_app_sent,
      array_agg(distinct scoped.channel order by scoped.channel)
        as delivery_channels
    from scoped
    group by 1,2
  ),
  page as(
    select
      campaigns.*,
      coalesce(push_facts.push_sent,0) as push_sent,
      coalesce(push_facts.push_failed,0) as push_failed,
      coalesce(open_facts.in_app_opens,0) as in_app_opens
    from campaigns
    left join push_facts
      on push_facts.campaign_kind=campaigns.campaign_kind
     and push_facts.campaign_ref_id=campaigns.campaign_ref_id
    left join open_facts
      on open_facts.campaign_kind=campaigns.campaign_kind
     and open_facts.campaign_ref_id=campaigns.campaign_ref_id
    order by campaigns.first_sent_at desc,campaigns.campaign_label
    offset p_offset
    limit p_limit
  )
  select
    coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'campaign_kind',page.campaign_kind,
          'campaign_ref_id',page.campaign_ref_id,
          'campaign_label',page.campaign_label,
          'delivery_channels',pg_catalog.to_jsonb(page.delivery_channels),
          'first_sent_at',page.first_sent_at,
          'last_sent_at',page.last_sent_at,
          'recipients',page.recipients,
          'in_app_sent',page.in_app_sent,
          'in_app_opens',page.in_app_opens,
          'push_sent',page.push_sent,
          'push_failed',page.push_failed,
          'push_delivered',null::text,
          'push_opens',null::text
        )
        order by page.first_sent_at desc,page.campaign_label
      ),
      '[]'::jsonb
    ),
    (
      select count(distinct
        record.campaign_kind||':'||record.campaign_ref_id::text
      )::integer
      from public.campaign_send_records_v255 record
      where record.business_id=p_business
        and record.occurred_at>=v_from and record.occurred_at<v_to
    )
  into v_items,v_total
  from page;

  select pg_catalog.jsonb_build_object(
    'campaigns',count(*),
    'recipients',coalesce(sum((item->>'recipients')::bigint),0),
    'in_app_sent',coalesce(sum((item->>'in_app_sent')::bigint),0),
    'in_app_opens',coalesce(sum((item->>'in_app_opens')::bigint),0),
    'push_sent',coalesce(sum((item->>'push_sent')::bigint),0),
    'push_failed',coalesce(sum((item->>'push_failed')::bigint),0),
    'push_delivered',null::text,
    'push_opens',null::text
  ) into v_summary
  from pg_catalog.jsonb_array_elements(v_items) as element(item);

  return pg_catalog.jsonb_build_object(
    'scope',pg_catalog.jsonb_build_object(
      'business_id',p_business,'from',p_from,'to',p_to,
      'limit',p_limit,'offset',p_offset,'timezone','Asia/Singapore'
    ),
    'methodology',pg_catalog.jsonb_build_object(
      'delivered',
        'Not tracked. A web push provider returns no delivery confirmation.',
      'push_opens',
        'Not tracked. The Push API exposes no open callback to the server.',
      'in_app_opens',
        'Recipients who opened the in-app notification at least once.',
      'audience_only',
        'A campaign whose only channel is none was frozen as an audience and never delivered.'
    ),
    'summary',coalesce(v_summary,'{}'::jsonb),
    'items',v_items,
    'total_count',v_total,
    'has_more',v_total>p_offset+p_limit,
    'next_offset',p_offset+p_limit,
    'snapshot_at',clock_timestamp()
  );
end
$$;
revoke all privileges on function public.platform_campaign_detail_v255(
  uuid,date,date,integer,integer
) from public,anon,authenticated,service_role;
grant execute on function public.platform_campaign_detail_v255(
  uuid,date,date,integer,integer
) to authenticated;

create or replace function public.platform_explore_demand_v255(
  p_from date,
  p_to date,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid:=auth.uid();
  v_from timestamptz;
  v_to timestamptz;
  v_items jsonb;
  v_total integer:=0;
  v_suppressed integer:=0;
begin
  if v_actor is null then
    raise exception 'authenticated platform session is required'
      using errcode='28000';
  end if;
  if not app.is_super_admin() then
    raise exception 'platform demand reporting is super admin only'
      using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_to<p_from then
    raise exception 'report range must be positive' using errcode='22023';
  end if;
  if p_to>p_from+interval '24 months' then
    raise exception 'report range may not exceed 24 months'
      using errcode='22023';
  end if;
  if p_limit is null or p_limit not between 1 and 200 then
    raise exception 'row limit must be 1..200' using errcode='22023';
  end if;

  v_from:=(p_from::timestamp at time zone 'Asia/Singapore');
  v_to:=((p_to::timestamp+interval '1 day') at time zone 'Asia/Singapore');

  with shapes as(
    select
      nullif(btrim(event_row.event_context->>'query_shape'),'') as query_shape,
      count(*)::bigint as searches,
      count(distinct event_row.actor_user_id)::bigint as customers
    from public.product_adoption_events_v100 event_row
    where event_row.event_name='customer.explore_searched'
      and event_row.occurred_at>=v_from and event_row.occurred_at<v_to
    group by 1
  ),
  visible as(
    select * from shapes
    where shapes.query_shape is not null and shapes.searches>=5
  ),
  page as(
    select * from visible order by searches desc,query_shape limit p_limit
  )
  select
    coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'query_shape',page.query_shape,
          'searches',page.searches,
          'customers',page.customers
        )
        order by page.searches desc,page.query_shape
      ),
      '[]'::jsonb
    ),
    (select count(*)::integer from visible),
    (
      select count(*)::integer from shapes
      where shapes.query_shape is not null and shapes.searches<5
    )
  into v_items,v_total,v_suppressed
  from page;

  return pg_catalog.jsonb_build_object(
    'scope',pg_catalog.jsonb_build_object(
      'from',p_from,'to',p_to,'limit',p_limit,'timezone','Asia/Singapore'
    ),
    'methodology',pg_catalog.jsonb_build_object(
      'shape_only',
        'Only the normalized shape of a search is recorded. Typed text is never stored.',
      'k_anonymity',
        'A shape seen fewer than 5 times in the range is suppressed entirely.'
    ),
    'items',v_items,
    'suppressed_buckets',coalesce(v_suppressed,0),
    'total_count',v_total,
    'has_more',v_total>p_limit,
    'snapshot_at',clock_timestamp()
  );
end
$$;
revoke all privileges on function public.platform_explore_demand_v255(
  date,date,integer
) from public,anon,authenticated,service_role;
grant execute on function public.platform_explore_demand_v255(
  date,date,integer
) to authenticated;

comment on function public.platform_campaign_detail_v255(
  uuid,date,date,integer,integer
) is
  'Per-campaign send history for one business. push_delivered and push_opens are always null because the Web Push API cannot report them; a zero would be a false measurement.';

commit;
