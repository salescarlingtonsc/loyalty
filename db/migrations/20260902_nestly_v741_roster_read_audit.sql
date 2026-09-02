-- NESTLY v741 — public.get_customer_intelligence_v83 stops handing platform principals a full
-- customer roster with no trace.
--
-- CI-100 checklist check 96 (privacy and small-cell protection): "sensitive demographic or
-- customer details remain role-scoped; unsafe small groups are suppressed." v83's `customers[]`
-- array carries every identified customer's full_name/email/phone plus spend — a full roster —
-- to whichever of three populations app.ci_access_gate_v667 admits: the firm's own staff, this
-- firm's assigned platform consultant, or a super admin. nestly_v623 established the precedent
-- that a cross-tenant customer-PII read must leave a trace: platform_list_enterprise_customers_v82
-- writes a PLATFORM_PII_READ_V623 row (actor, business, action, detail with reader scope and row
-- counts) for every call, because before v623 it left none. v83 was never brought into that
-- discipline: a consultant or super admin reading another firm's full roster through it writes
-- nothing at all, while the firm's own owner reading their OWN customers is treated identically
-- — same silence, but here silence is correct for self-service and wrong for a platform read.
--
-- THE FIX. One predicate placed at the single point v83 already computes its result, mirroring
-- v623's shape exactly (same audit_log columns — business_id, actor, action, entity, entity_id,
-- detail; note it is `detail`, not `meta`, per nestly_v454): when the caller is NOT staff of
-- p_business (app.is_salon_member(p_business) false — the only way to reach this point is via
-- ci_access_gate_v667's platform arm, app.v176_can_read_firm_report: a super admin or this firm's
-- assigned consultant), insert one PLATFORM_ROSTER_READ_V741 row recording the reader kind
-- (super_admin vs assigned_consultant, distinguished the same way nestly_v89's v89_platform_role
-- already does), the branch/window scope, and the customers_returned / total_customers counts
-- already sitting in v_result's own pagination block — no re-derivation, no second query. The
-- firm's own staff (owner, manager, any role admitted through the merchant arm) write no row:
-- reading your own customer list is not a platform PII exposure, exactly as v623 audits a broad
-- estate read but not routine one-firm support access on the sibling RPC.
--
-- The roster contents themselves are byte-for-byte unchanged — this adds one INSERT after
-- v_result is already built and validated non-null, immediately before RETURN, and touches
-- nothing that shapes v_result. Every existing v83 fixture (v422_customer_intelligence_scale,
-- v721_corpus_one_ci_gate, v723_corpus_reader_contracts, v725_corpus_time_basis_shadow_gate,
-- v737_corpus_synthetic_v83_shadow, v714_corpus_visit_days_estate) asserts specific payload
-- shapes and stays green because the payload is untouched; none of them assert on audit_log, so
-- none can regress from a write they never inspected.
--
-- Anchored, comment-free replace-equality diff against the LIVE pg_get_functiondef body — same
-- discipline as nestly_v668/v687/v714/v724/v734/v737: capture the body before, apply CREATE OR
-- REPLACE, then assert the new body equals old-with-exactly-this-insertion-and-nothing-else, or
-- roll back the whole migration. ACL is restated as it already is (CREATE OR REPLACE preserves
-- existing grants; nestly_v737 last set this function to anon+authenticated+service_role) —
-- stated explicitly below per this repo's own convention, not because the grant is changing.
--
-- PROVEN BY: db/tests/executed/v741_corpus_roster_read_audit.sql. Owner (staff) reads write no
-- audit row. The assigned consultant reads and writes exactly one PLATFORM_ROSTER_READ_V741 row
-- with reader='assigned_consultant' and the right detail. A super admin (real Google session)
-- reads and writes exactly one row with reader='super_admin'. A stranger with no relationship to
-- the business is refused 42501 by the pre-existing gate and writes no row. The roster payload
-- (customers[] and summary) is asserted byte-identical between the staff read and the consultant
-- read for the same window — this migration changes auditing, not what anyone sees. A mutation
-- that removes the insert, or that fires it for staff, turns the fixture red.
--
-- ROLLBACK: the captured "before" body is available in this migration's own do-block (re-run the
-- CREATE OR REPLACE with the pre-image quoted there, or restore from nestly_v737).

begin;

create temp table _v741_before(fn text primary key, def text) on commit drop;

do $capture$
begin
  insert into _v741_before(fn, def)
  select 'get_customer_intelligence_v83', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_customer_intelligence_v83';

  if (select count(*) from _v741_before) <> 1 then
    raise exception 'v741: expected exactly 1 captured function body, found %',
      (select count(*) from _v741_before);
  end if;
  if exists (
    select 1 from _v741_before where def ilike '%PLATFORM_ROSTER_READ_V741%'
  ) then
    raise exception 'v741: get_customer_intelligence_v83 already carries the roster-read audit '
      'insert -- stop and re-read before shipping';
  end if;
end
$capture$;

CREATE OR REPLACE FUNCTION public.get_customer_intelligence_v83(p_business uuid, p_branch uuid DEFAULT NULL::uuid, p_from date DEFAULT (((now() AT TIME ZONE 'Asia/Singapore'::text))::date - 365), p_to date DEFAULT ((now() AT TIME ZONE 'Asia/Singapore'::text))::date, p_limit integer DEFAULT 250, p_snapshot_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_client uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
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
  perform app.ci_access_gate_v667(p_business, p_branch);
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
  if not (app.v176_can_read_firm_report(p_business) or app.can_see_branch(p_business,p_branch)) then
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
           count(distinct app.ci_visit_day_v699(sale.occurred_at))::integer purchase_day_count,
           min(sale.occurred_at) period_first_purchase_at,
           max(sale.occurred_at) period_last_purchase_at
    from valid_period_purchases sale where sale.client_id is not null
    group by sale.client_id
  ),period_visits as (
    select sale.client_id,count(distinct app.ci_visit_day_v699(sale.occurred_at))::integer visit_count
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
           coalesce(purchase.purchase_day_count,0)>=2 returning_customer,
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
      and client.is_synthetic=false
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
    'time_basis','sale_occurred_at',
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
      'returning_customer','At least two completed unreversed revenue transactions on distinct days (Asia/Singapore) in the selected period; a same-day split bill counts once.',
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
  if not app.is_salon_member(p_business) then
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (
      p_business, auth.uid(), 'PLATFORM_ROSTER_READ_V741', 'clients', null,
      jsonb_build_object(
        'reader', case when app.is_super_admin() then 'super_admin' else 'assigned_consultant' end,
        'branch_id', p_branch, 'from', p_from, 'to', p_to,
        'customers_returned', (v_result->'pagination'->>'returned_customers')::integer,
        'total_customers', (v_result->'pagination'->>'total_customers')::integer,
        'snapshot_at', v_snapshot_at
      )
    );
  end if;
  return v_result;
end
$function$;


do $check$
declare v_before text; v_after text; v_expected text;
  v_old constant text := $lit$  if v_result is null then
    raise exception 'business_not_found' using errcode='22023';
  end if;
  return v_result;
end
$lit$;
  v_new constant text := $lit$  if v_result is null then
    raise exception 'business_not_found' using errcode='22023';
  end if;
  if not app.is_salon_member(p_business) then
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (
      p_business, auth.uid(), 'PLATFORM_ROSTER_READ_V741', 'clients', null,
      jsonb_build_object(
        'reader', case when app.is_super_admin() then 'super_admin' else 'assigned_consultant' end,
        'branch_id', p_branch, 'from', p_from, 'to', p_to,
        'customers_returned', (v_result->'pagination'->>'returned_customers')::integer,
        'total_customers', (v_result->'pagination'->>'total_customers')::integer,
        'snapshot_at', v_snapshot_at
      )
    );
  end if;
  return v_result;
end
$lit$;
begin
  select def into v_before from _v741_before where fn = 'get_customer_intelligence_v83';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_customer_intelligence_v83';
  if position(v_old in v_before) = 0 then
    raise exception 'v741/get_customer_intelligence_v83: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v741/get_customer_intelligence_v83: definition moved by more than the '
      'audit insert. %  %', E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check$;

revoke all on function public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid) from public;
grant execute on function public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid) to anon, authenticated, service_role;

commit;
