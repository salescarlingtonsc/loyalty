-- NESTLY v737 -- public.get_customer_intelligence_v83 and public.get_ci_shadow_reconciliation_v685
-- join the synthetic-client exclusion estate (CI-100 checklist checks 1/3/10, continuing
-- nestly_v687/v734). nestly_v734's estate scan reached every dashboard/report reader it found
-- with a live `from public.sales` revenue/visit read, but explicitly did not reach these two --
-- both are re-emitted by nestly_v725 (landed the same day, after v734's own scan), so v734 never
-- saw their current bodies. A refuter's scenario (owner principal, 5 real clients / 50000 cents /
-- 8 visit-days, 1 synthetic client with 3 sales one fully reversed (net 6000), 2 anonymous sales /
-- 10000 cents) found both still broken:
--
--   * public.get_customer_intelligence_v83 reported summary.net_revenue_cents = 56000 (50000 real
--     identified + 6000 synthetic net) instead of 50000, and listed the synthetic client inside
--     customers[]. Root cause: the client_metrics CTE selects `from public.clients client ...`
--     with no is_synthetic filter at all, so the synthetic client's own row (and the revenue/
--     visit/cash figures joined onto it) stays in the roster and gets summed into every summary
--     total built from client_metrics.
--   * public.get_ci_shadow_reconciliation_v685's independent oracle sums `public.sales` directly
--     with no synthetic-client predicate: 66000 (50000 real + 6000 synthetic net + 10000
--     anonymous) against a captured get_revenue_truth_v106 truth of 60000 (50000 identified +
--     10000 anonymous; v106 already excludes the synthetic client via nestly_v687) --
--     overall_status FAIL for any business that ever plants a synthetic client with real sales,
--     which is exactly the shape every other corpus fixture in this estate now carries.
--
-- THE FIX, decision recorded (identified-only vs known revenue). v83's summary was already
-- structurally identified-only: 'net_revenue_cents' derives from the period_revenue CTE, which
-- requires sale.client_id is not null, so an anonymous sale never reaches it; nothing about that
-- shape changes here. The single edit is to client_metrics' own population: add
-- `and client.is_synthetic=false` to the `from public.clients client where ...` clause (the same
-- direct-column authority app.v176_sales_window's first_purchase CTE and app.v177_customers'
-- real_clients CTE already use -- v734's header calls both out as "already correct"). Dropping
-- the synthetic client's row out of client_metrics removes it from customers[] AND from every
-- summary total that sums client_metrics (net_revenue_cents included), in one edit, because those
-- totals are sums over client_metrics rows, not independent re-derivations. The corrected
-- summary.net_revenue_cents (50000) is asserted equal to get_revenue_truth_v106's
-- identified_revenue_minor (50000) in the proof fixture below: v83's summary is identified-only
-- by design and now matches v106's identified figure exactly, the way this migration's own header
-- (and CLAUDE.md's audit discipline) requires stated rather than assumed. v83 carries no "known
-- revenue" (identified+anonymous) field today; if one is ever added it must sum period_sales
-- directly, not client_metrics, since client_metrics is a per-identified-client rollup by
-- construction (it is built by joining FROM public.clients).
--
-- THE FIX, decision recorded (independent-in-implementation, same population by design).
-- get_ci_shadow_reconciliation_v685's oracle stays a hand-written SQL sum against public.sales --
-- it is deliberately NOT rewritten as a call to get_revenue_truth_v106 (nestly_v685's own header:
-- an independent recomputation is the point, or a bug in v106 could never be caught by its own
-- shadow). This migration adds exactly the one predicate that keeps the oracle's POPULATION
-- matching v106's post-v687 population without turning the oracle into a wrapper around v106:
-- `cross join lateral app.analytics_sale_class_v1(s) sc ... and not sc.is_synthetic_client` --
-- the identical shape nestly_v687/v734 already use everywhere else in this estate. Independent
-- implementation, shared population definition by design: the oracle still never calls v106, it
-- just now excludes the same rows v106 excludes, for the same documented reason.
--
-- Both patches are anchored, comment-free replace-equality diffs against the LIVE
-- pg_get_functiondef body -- same discipline as nestly_v668/v687/v714/v724/v734: capture the body
-- before, apply CREATE OR REPLACE, then assert the new body equals old-with-exactly-this-
-- substitution-and-nothing-else, or roll back the whole migration. ACLs are restated as they
-- already are (CREATE OR REPLACE preserves existing grants; v725 last set get_customer_
-- intelligence_v83 to anon+authenticated+service_role and get_ci_shadow_reconciliation_v685 to
-- authenticated+service_role only, anon excluded) -- stated explicitly below per this repo's own
-- convention, not because either grant set is changing.
--
-- PROVEN BY: db/tests/executed/v737_corpus_synthetic_v83_shadow.sql -- one business, the same 5
-- real clients / 50000 cents / 8 visit-days shape v734 uses, plus one synthetic client with 3
-- sales (one fully reversed via a native reversal_of row, unreversed net 6000) and 2 anonymous
-- sales (10000 cents). get_customer_intelligence_v83's summary.net_revenue_cents must equal 50000
-- and customers[] must exclude the synthetic client; get_ci_shadow_reconciliation_v685's captured-
-- vs-independent reconciliation (run as SA-with-Google via app.ci_shadow_capture_v685 then this
-- reader) must report overall_status='PASS' with both metrics equal to the truth (60000/10). Run
-- against the unfixed pre-image, the same fixture proves RED first (56000, synthetic in roster,
-- 66000/12 vs 60000/10, overall_status FAIL) before this migration is applied -- not asserted a
-- second time inside the fixture (which only ever runs post-migration), but reproduced and
-- recorded in the session report that shipped this migration. db/tests/executed/
-- v422_customer_intelligence_scale.sql, v685_corpus_shadow.sql, v723_corpus_reader_contracts.sql,
-- v725_corpus_time_basis_shadow_gate.sql and v734_corpus_synthetic_exclusion.sql are untouched by
-- either edit and stay green.
--
-- ROLLBACK: each function's captured "before" body is available in this migration's own do-block
-- (re-run each CREATE OR REPLACE with the pre-image quoted in that block, or restore from
-- nestly_v725 for get_customer_intelligence_v83/get_ci_shadow_reconciliation_v685).

begin;

create temp table _v737_before(fn text primary key, def text) on commit drop;

do $capture$
begin
  insert into _v737_before(fn, def)
  select 'get_customer_intelligence_v83', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_customer_intelligence_v83'
  union all
  select 'get_ci_shadow_reconciliation_v685', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_ci_shadow_reconciliation_v685';

  if (select count(*) from _v737_before) <> 2 then
    raise exception 'v737: expected exactly 2 captured function bodies, found %',
      (select count(*) from _v737_before);
  end if;
  if exists (
    select 1 from _v737_before where fn = 'get_customer_intelligence_v83' and def ilike '%is_synthetic%'
  ) then
    raise exception 'v737: get_customer_intelligence_v83 already carries a synthetic-client '
      'exclusion -- stop and re-read before shipping';
  end if;
  if exists (
    select 1 from _v737_before
     where fn = 'get_ci_shadow_reconciliation_v685' and def ilike '%is_synthetic_client%'
  ) then
    raise exception 'v737: get_ci_shadow_reconciliation_v685 already carries the exclusion -- '
      'stop and re-read before shipping';
  end if;
end
$capture$;

-- =================================================================================================
-- 1 . public.get_customer_intelligence_v83
-- =================================================================================================
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
  return v_result;
end
$function$;


do $check1$
declare v_before text; v_after text; v_expected text;
  v_old constant text := $lit$    where client.business_id=p_business
      and client.created_at<=v_snapshot_at
      and (p_branch is null or lifetime.client_id is not null)
  ),page as materialized ($lit$;
  v_new constant text := $lit$    where client.business_id=p_business
      and client.created_at<=v_snapshot_at
      and client.is_synthetic=false
      and (p_branch is null or lifetime.client_id is not null)
  ),page as materialized ($lit$;
begin
  select def into v_before from _v737_before where fn = 'get_customer_intelligence_v83';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_customer_intelligence_v83';
  if position(v_old in v_before) = 0 then
    raise exception 'v737/get_customer_intelligence_v83: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v737/get_customer_intelligence_v83: definition moved by more than the '
      'exclusion. %  %', E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check1$;

revoke all on function public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid) from public;
grant execute on function public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid) to anon, authenticated, service_role;

-- =================================================================================================
-- 2 . public.get_ci_shadow_reconciliation_v685
-- =================================================================================================
CREATE OR REPLACE FUNCTION public.get_ci_shadow_reconciliation_v685(p_business uuid, p_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_run app.ci_shadow_runs_v685%rowtype;
  v_captured_revenue_truth jsonb;
  v_captured_known_revenue bigint;
  v_captured_completed_txns bigint;
  v_independent_known_revenue bigint;
  v_independent_completed_txns bigint;
  v_delta_revenue bigint;
  v_delta_txns bigint;
  v_metrics jsonb;
  v_started_at timestamptz := clock_timestamp();
begin
  -- Same refusal convention as every other super-admin-only RPC in this codebase (v66/v79/v86/
  -- v147): anyone who is not a super admin gets 42501, no partial data, no different message.
  -- This reader now ALSO calls the shared Customer Intelligence gate
  -- (app.ci_access_gate_v667), the single authority every other CI reader defers to, instead of
  -- carrying only its own hand-rolled entitlement check in isolation -- one authority, not two.
  -- The shared gate's platform arm (app.v176_can_read_firm_report: super admin OR the firm's
  -- assigned consultant) is DELIBERATELY not sufficient on its own here: this reconciliation
  -- compares a captured shadow-run payload against an independently recomputed oracle -- an
  -- SA-only ops diagnostic auditing the CI pipeline itself, not a firm-facing report -- so the
  -- assigned consultant, who legitimately reads every OTHER CI surface for their firm through
  -- that same platform arm, must still be refused here. app.is_super_admin() is kept as a
  -- second, narrower condition evaluated AFTER the shared gate for exactly that reason: passing
  -- the shared gate is necessary but not sufficient. p_branch is null -- this reader takes no
  -- branch argument; it audits a whole captured business-scoped run, not a branch-scoped one.
  perform app.ci_access_gate_v667(p_business, null);
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode = '42501';
  end if;
  if p_business is null or p_run_id is null then
    raise exception 'p_business and p_run_id are required' using errcode = '22023';
  end if;

  select * into v_run
    from app.ci_shadow_runs_v685
   where id = p_run_id and business_id = p_business;
  if not found then
    raise exception 'unknown shadow run for this business' using errcode = '22023';
  end if;

  v_captured_revenue_truth := v_run.payload->'get_revenue_truth_v106';
  v_captured_known_revenue := (v_captured_revenue_truth->'totals'->>'known_revenue_minor')::bigint;
  v_captured_completed_txns := (v_captured_revenue_truth->'totals'->>'completed_transactions')::bigint;

  -- THE INDEPENDENT ORACLE. Deliberately NOT a call to get_revenue_truth_v106 — restates the
  -- ledger-native half of its rule directly against `sales` (see the migration header for the
  -- documented, non-silent scope limit: no external commerce-event refund-allocation netting).
  -- A sale counts when: it is not itself a reversal, nothing reverses it, it is flagged
  -- counts_as_revenue by the v10 sale-policy trigger, it was recorded at-or-before this run's
  -- as-of time, and it occurred inside [window_from, window_to) in Asia/Singapore — the same
  -- timezone convention app.js's own truthRequest/customerIntelligencePage use for this business.
  select
    coalesce(sum(s.amount_cents), 0)::bigint,
    coalesce(count(*) filter (where s.amount_cents > 0), 0)::bigint
    into v_independent_known_revenue, v_independent_completed_txns
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
   where s.business_id = p_business
     and s.reversal_of is null
     and coalesce(s.counts_as_revenue, false)
     and s.created_at <= (v_run.payload->>'as_of')::timestamptz
     and not sc.is_synthetic_client
     and not exists (select 1 from public.sales r where r.reversal_of = s.id)
     and (s.occurred_at at time zone 'Asia/Singapore')::date >= v_run.window_from
     and (s.occurred_at at time zone 'Asia/Singapore')::date < v_run.window_to;

  v_delta_revenue := coalesce(v_independent_known_revenue, 0) - coalesce(v_captured_known_revenue, 0);
  v_delta_txns := coalesce(v_independent_completed_txns, 0) - coalesce(v_captured_completed_txns, 0);

  v_metrics := jsonb_build_array(
    jsonb_build_object(
      'metric', 'known_revenue_minor',
      'captured', v_captured_known_revenue,
      'independent', v_independent_known_revenue,
      'delta', v_delta_revenue,
      'status', case when v_delta_revenue = 0 then 'PASS' else 'FAIL' end),
    jsonb_build_object(
      'metric', 'completed_transactions',
      'captured', v_captured_completed_txns,
      'independent', v_independent_completed_txns,
      'delta', v_delta_txns,
      'status', case when v_delta_txns = 0 then 'PASS' else 'FAIL' end));

  return jsonb_build_object(
    'run_id', v_run.id,
    'business_id', v_run.business_id,
    'window', v_run.payload->'window',
    'time_basis', 'captured_at',
    'metrics', v_metrics,
    'overall_status', case when v_delta_revenue = 0 and v_delta_txns = 0 then 'PASS' else 'FAIL' end,
    'runtime_ms', extract(epoch from (clock_timestamp() - v_started_at)) * 1000);
end;
$function$;


do $check2$
declare v_before text; v_after text; v_expected text;
  v_old constant text := $lit$    from public.sales s
   where s.business_id = p_business
     and s.reversal_of is null
     and coalesce(s.counts_as_revenue, false)
     and s.created_at <= (v_run.payload->>'as_of')::timestamptz
     and not exists (select 1 from public.sales r where r.reversal_of = s.id)
     and (s.occurred_at at time zone 'Asia/Singapore')::date >= v_run.window_from
     and (s.occurred_at at time zone 'Asia/Singapore')::date < v_run.window_to;$lit$;
  v_new constant text := $lit$    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
   where s.business_id = p_business
     and s.reversal_of is null
     and coalesce(s.counts_as_revenue, false)
     and s.created_at <= (v_run.payload->>'as_of')::timestamptz
     and not sc.is_synthetic_client
     and not exists (select 1 from public.sales r where r.reversal_of = s.id)
     and (s.occurred_at at time zone 'Asia/Singapore')::date >= v_run.window_from
     and (s.occurred_at at time zone 'Asia/Singapore')::date < v_run.window_to;$lit$;
begin
  select def into v_before from _v737_before where fn = 'get_ci_shadow_reconciliation_v685';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_ci_shadow_reconciliation_v685';
  if position(v_old in v_before) = 0 then
    raise exception 'v737/get_ci_shadow_reconciliation_v685: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v737/get_ci_shadow_reconciliation_v685: definition moved by more than the '
      'exclusion. %  %', E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check2$;

revoke all on function public.get_ci_shadow_reconciliation_v685(uuid,uuid) from public, anon;
grant execute on function public.get_ci_shadow_reconciliation_v685(uuid,uuid) to authenticated, service_role;

commit;
