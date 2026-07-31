-- Nestly v113: effective-identity closure for measured growth consumers.
--
-- Historical sales, recommendation, execution, delivery and entitlement rows remain
-- immutable.  Every live consumer resolves those source client ids through the
-- current v111 attribution.  Reversing a correction therefore restores the prior
-- attribution without rewriting evidence.

begin;

do $v113_preflight$
begin
  if to_regprocedure('app.v111_effective_client_id(uuid,uuid)') is null
     or to_regclass('public.customer_identity_current_attribution_v111') is null
     or to_regprocedure('public.refresh_growth_recommendation_v108(uuid,uuid)') is null
     or to_regprocedure(
       'public.get_revenue_driver_decomposition_v109(uuid,date,date,date,date,uuid,timestamp with time zone)'
     ) is null then
    raise exception 'v113 requires the complete v108, v109 and v111 contracts'
      using errcode='55000';
  end if;
end
$v113_preflight$;

create or replace function app.v113_effective_client_id(
  p_business uuid,
  p_client uuid
)
returns uuid
language sql
stable
security definer
returns null on null input
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select app.v111_effective_client_id(p_business,p_client)
$$;

revoke all on function app.v113_effective_client_id(uuid,uuid)
  from public,anon,authenticated;

create or replace function app.v113_customer_effective_client_id(
  p_business uuid,
  p_identity uuid
)
returns uuid
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_count integer;
  v_client uuid;
begin
  select count(*),(array_agg(effective.effective_client_id))[1]
    into v_count,v_client
    from (
      select distinct
        app.v113_effective_client_id(link.business_id,link.client_id)
          as effective_client_id
      from public.customer_links link
      join public.customer_identities identity_row
        on identity_row.id=link.identity_id
       and identity_row.auth_user_id=link.auth_user_id
      where link.business_id=p_business
        and link.identity_id=p_identity
        and link.state='verified'
        and identity_row.status='active'
    ) effective;
  if v_count<>1 then
    raise exception 'one unambiguous active verified customer link is required'
      using errcode='42501';
  end if;
  return v_client;
end
$$;

-- Attribution is written against the immutable experiment-member snapshot while
-- the sale remains linked to its immutable source client.  Matching is current
-- effective identity, so approval and reversal immediately change live results.
create or replace function app.capture_growth_outcome_v108()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_overlap integer;
  v_now timestamptz:=clock_timestamp();
begin
  if new.reversal_of is not null then
    update public.growth_entitlements_v108 entitlement
       set status='reversed',reversed_at=statement_timestamp()
     where entitlement.business_id=new.business_id
       and entitlement.redeemed_sale_id=new.reversal_of
       and entitlement.status='redeemed';
    insert into public.growth_entitlement_events_v108(
      entitlement_id,business_id,event_type,sale_id,idempotency_key,detail
    )
    select entitlement.id,entitlement.business_id,'reversed',new.id,
      extensions.uuid_generate_v5(entitlement.id,new.id::text),
      jsonb_build_object(
        'reversal_sale_id',new.id,'original_sale_id',new.reversal_of
      )
    from public.growth_entitlements_v108 entitlement
    where entitlement.business_id=new.business_id
      and entitlement.redeemed_sale_id=new.reversal_of
      and entitlement.status='reversed'
    on conflict do nothing;
    update public.growth_outcomes_v108
       set revenue_cents=app.v106_sale_residual_minor(new.reversal_of,v_now)
     where business_id=new.business_id and sale_id=new.reversal_of;
    return new;
  end if;
  if new.client_id is null
     or not new.counts_as_visit
     or not new.counts_as_revenue
     or new.created_at>v_now
     or new.occurred_at>v_now
     or app.v106_sale_residual_minor(new.id,v_now)<=0 then
    return new;
  end if;
  -- Count matching immutable member snapshots, not only executions.  An
  -- approved correction can collapse two legacy member rows that were already
  -- present in one running execution.  That state must invalidate causal
  -- measurement without making an ordinary sale fail.
  select count(*) into v_overlap
    from public.growth_execution_members_v108 member
    join public.growth_executions_v108 execution
      on execution.id=member.execution_id
   where member.business_id=new.business_id
     and app.v113_effective_client_id(member.business_id,member.client_id)
         =app.v113_effective_client_id(new.business_id,new.client_id)
     and execution.status='running'
     and (execution.branch_id is null or execution.branch_id=new.branch_id)
     and new.occurred_at>=execution.started_at
     and new.occurred_at<execution.ends_at;
  with matched_member as (
    select execution.id as execution_id,member.id as execution_member_id,
      member.client_id,member.assignment,
      row_number() over (
        partition by execution.id
        order by member.assignment_rank,member.id
      ) as execution_rank
    from public.growth_execution_members_v108 member
    join public.growth_executions_v108 execution
      on execution.id=member.execution_id
    where member.business_id=new.business_id
      and app.v113_effective_client_id(member.business_id,member.client_id)
          =app.v113_effective_client_id(new.business_id,new.client_id)
      and execution.status='running'
      and (execution.branch_id is null or execution.branch_id=new.branch_id)
      and new.occurred_at>=execution.started_at
      and new.occurred_at<execution.ends_at
  )
  insert into public.growth_outcomes_v108(
    execution_id,execution_member_id,business_id,client_id,sale_id,
    assignment,outcome_kind,occurred_at,revenue_cents,overlap_count,
    causal_eligible
  )
  select member.execution_id,member.execution_member_id,new.business_id,
    member.client_id,new.id,member.assignment,'qualifying_purchase',
    new.occurred_at,
    app.v106_sale_residual_minor(new.id,v_now),greatest(v_overlap,1),
    v_overlap=1
  from matched_member member
  where member.execution_rank=1
  -- Either the same member already has its first outcome, or the same sale was
  -- already captured for this execution.  Both are harmless replay states.
  on conflict do nothing;
  return new;
end
$$;

revoke all on function app.capture_growth_outcome_v108()
  from public,anon,authenticated;

create or replace function app.get_growth_execution_result_at_v108(
  p_execution uuid,
  p_as_of timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_execution public.growth_executions_v108%rowtype;
  v_t_members integer:=0;
  v_h_members integer:=0;
  v_t_buyers integer:=0;
  v_h_buyers integer:=0;
  v_t_revenue bigint:=0;
  v_h_revenue bigint:=0;
  v_t_rate numeric:=0;
  v_h_rate numeric:=0;
  v_lift numeric:=0;
  v_se numeric:=0;
  v_aov numeric:=0;
  v_estimate bigint:=0;
  v_low bigint:=0;
  v_high bigint:=0;
  v_overlap integer:=0;
  v_identity_overlap integer:=0;
  v_measurement text;
begin
  if p_as_of is null then
    raise exception 'reporting cutoff is required' using errcode='22004';
  end if;
  select * into v_execution
    from public.growth_executions_v108 execution
   where execution.id=p_execution;
  if not found then raise exception 'execution not found'; end if;
  if auth.uid() is null or (
    not app.is_super_admin()
    and (
      not app.has_perm(v_execution.business_id,'view_finance')
      or not app.can_module_read(v_execution.business_id,'retention')
    )
  ) then
    raise exception 'finance and retention access required' using errcode='42501';
  end if;
  if not app.can_see_branch(v_execution.business_id,v_execution.branch_id) then
    raise exception 'execution branch is outside actor scope' using errcode='42501';
  end if;

  with effective_members as (
    select member.*,
      app.v113_effective_client_id(member.business_id,member.client_id)
        as effective_client_id,
      row_number() over (
        partition by app.v113_effective_client_id(
          member.business_id,member.client_id
        )
        order by member.assignment_rank,member.id
      ) as identity_rank,
      count(*) over (
        partition by app.v113_effective_client_id(
          member.business_id,member.client_id
        )
      ) as identity_count
    from public.growth_execution_members_v108 member
    where member.execution_id=p_execution
  ),
  member_result as (
    select member.assignment,member.client_id,member.effective_client_id,
      member.identity_count,
      exists (
        select 1 from public.sales sale
         where sale.business_id=v_execution.business_id
           and sale.client_id is not null
           and app.v113_effective_client_id(sale.business_id,sale.client_id)
               =member.effective_client_id
           and sale.counts_as_visit
           and sale.counts_as_revenue
           and sale.reversal_of is null
           and sale.created_at<=p_as_of
           and sale.occurred_at<=p_as_of
           and (
             v_execution.branch_id is null
             or sale.branch_id=v_execution.branch_id
           )
           and sale.occurred_at>=v_execution.started_at
           and sale.occurred_at<v_execution.ends_at
           and app.v106_sale_residual_minor(sale.id,p_as_of)>0
      ) as purchased,
      coalesce((
        select sum(app.v106_sale_residual_minor(sale.id,p_as_of))
          from public.sales sale
         where sale.business_id=v_execution.business_id
           and sale.client_id is not null
           and app.v113_effective_client_id(sale.business_id,sale.client_id)
               =member.effective_client_id
           and sale.counts_as_revenue
           and sale.reversal_of is null
           and sale.created_at<=p_as_of
           and sale.occurred_at<=p_as_of
           and (
             v_execution.branch_id is null
             or sale.branch_id=v_execution.branch_id
           )
           and sale.occurred_at>=v_execution.started_at
           and sale.occurred_at<v_execution.ends_at
           and app.v106_sale_residual_minor(sale.id,p_as_of)>0
      ),0)::bigint as revenue_cents
    from effective_members member
    where member.identity_rank=1
  )
  select
    count(*) filter(where assignment='treatment'),
    count(*) filter(where assignment='holdout'),
    count(*) filter(where assignment='treatment' and purchased),
    count(*) filter(where assignment='holdout' and purchased),
    coalesce(sum(revenue_cents) filter(where assignment='treatment'),0),
    coalesce(sum(revenue_cents) filter(where assignment='holdout'),0),
    count(*) filter(where identity_count>1)
  into v_t_members,v_h_members,v_t_buyers,v_h_buyers,
       v_t_revenue,v_h_revenue,v_identity_overlap
  from member_result;

  select count(*) into v_overlap
    from public.growth_outcomes_v108 outcome
    join public.growth_execution_members_v108 member
      on member.id=outcome.execution_member_id
     and member.business_id=outcome.business_id
    join public.sales sale
      on sale.id=outcome.sale_id
     and sale.business_id=outcome.business_id
   where outcome.execution_id=p_execution
     and not outcome.causal_eligible
     and outcome.occurred_at<=p_as_of
     and app.v106_sale_residual_minor(outcome.sale_id,p_as_of)>0
     and sale.client_id is not null
     and app.v113_effective_client_id(sale.business_id,sale.client_id)
         =app.v113_effective_client_id(member.business_id,member.client_id);
  v_t_rate:=case when v_t_members>0
    then v_t_buyers::numeric/v_t_members else 0 end;
  v_h_rate:=case when v_h_members>0
    then v_h_buyers::numeric/v_h_members else 0 end;
  v_lift:=v_t_rate-v_h_rate;
  v_se:=case when v_t_members>0 and v_h_members>0 then sqrt(
    greatest(0,v_t_rate*(1-v_t_rate)/v_t_members)
    +greatest(0,v_h_rate*(1-v_h_rate)/v_h_members)
  ) else 0 end;
  v_aov:=case when v_t_buyers+v_h_buyers>0
    then (v_t_revenue+v_h_revenue)::numeric/(v_t_buyers+v_h_buyers)
    else 0 end;
  v_estimate:=round(v_lift*v_t_members*v_aov);
  v_low:=round((v_lift-1.96*v_se)*v_t_members*v_aov);
  v_high:=round((v_lift+1.96*v_se)*v_t_members*v_aov);
  v_measurement:=case
    when v_identity_overlap>0 then 'invalid_overlap'
    when v_overlap>0 then 'invalid_overlap'
    when v_t_members<v_execution.minimum_arm_size
      or v_h_members<v_execution.minimum_arm_size
      then 'inconclusive_small_sample'
    when p_as_of<v_execution.ends_at then 'provisional'
    else 'final'
  end;
  return jsonb_build_object(
    'execution_id',p_execution,'business_id',v_execution.business_id,
    'as_of',p_as_of,'status',v_execution.status,
    'window',jsonb_build_object(
      'start',v_execution.started_at,'end',v_execution.ends_at
    ),
    'method','randomized_intent_to_treat_holdout',
    'identity_attribution','v111_current_effective_identity',
    'measurement_status',v_measurement,
    'arms',jsonb_build_object(
      'treatment',jsonb_build_object(
        'members',v_t_members,'buyers',v_t_buyers,
        'conversion_rate_bps',round(v_t_rate*10000),
        'associated_revenue_cents',v_t_revenue
      ),
      'holdout',jsonb_build_object(
        'members',v_h_members,'buyers',v_h_buyers,
        'conversion_rate_bps',round(v_h_rate*10000),
        'associated_revenue_cents',v_h_revenue
      )
    ),
    'incremental_conversion_lift_bps',round(v_lift*10000),
    'estimated_incremental_revenue',case
      when v_measurement in ('invalid_overlap','inconclusive_small_sample')
        then null
      else jsonb_build_object(
        'currency',v_execution.currency,'point_estimate_cents',v_estimate,
        'low_cents',least(v_low,v_high),
        'high_cents',greatest(v_low,v_high),
        'confidence_level','approximate_95_percent'
      )
    end,
    'incremental_gross_profit',null,
    'cost',jsonb_build_object(
      'estimated_offer_cost_cents',coalesce((
        select sum(delivery.estimated_cost_cents)
          from public.growth_deliveries_v108 delivery
         where delivery.execution_id=p_execution
           and delivery.delivery_status='delivered'
      ),0),
      'actual_redeemed_cost_cents',coalesce((
        select sum(entitlement.estimated_cost_cents)
          from public.growth_entitlements_v108 entitlement
         where entitlement.execution_id=p_execution
           and entitlement.status='redeemed'
      ),0),
      'reversed_offer_cost_cents',coalesce((
        select sum(entitlement.estimated_cost_cents)
          from public.growth_entitlements_v108 entitlement
         where entitlement.execution_id=p_execution
           and entitlement.status='reversed'
      ),0)
    ),
    'overlap_outcomes',v_overlap,
    'identity_overlap_members',v_identity_overlap,
    'limitations',jsonb_build_array(
      'revenue result is not gross profit',
      'confidence interval uses a transparent normal approximation',
      'small, overlapping or identity-ambiguous experiments are suppressed'
    )
  );
end
$$;

revoke all on function app.get_growth_execution_result_at_v108(uuid,timestamptz)
  from public,anon,authenticated;

create or replace function public.get_revenue_driver_decomposition_v109(
  p_business uuid,
  p_current_from date,
  p_current_to date,
  p_comparison_from date,
  p_comparison_to date,
  p_branch uuid default null,
  p_as_of timestamptz default statement_timestamp()
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  c_total bigint:=0;
  c_identified bigint:=0;
  c_transactions integer:=0;
  c_clients integer:=0;
  c_total_transactions integer:=0;
  c_itemized_transactions integer:=0;
  c_itemized_revenue bigint:=0;
  p_total bigint:=0;
  p_identified bigint:=0;
  p_transactions integer:=0;
  p_clients integer:=0;
  p_total_transactions integer:=0;
  p_itemized_transactions integer:=0;
  p_itemized_revenue bigint:=0;
  c_anonymous bigint:=0;
  p_anonymous bigint:=0;
  c_coverage integer;
  p_coverage integer;
  c_itemized_transaction_coverage integer;
  p_itemized_transaction_coverage integer;
  c_itemized_revenue_coverage integer;
  p_itemized_revenue_coverage integer;
  p_frequency numeric;
  p_aov numeric;
  c_frequency numeric;
  c_aov numeric;
  d_customer bigint;
  d_frequency bigint;
  d_aov bigint;
  d_anonymous bigint;
  d_residual bigint;
  d_total bigint;
  d_sum bigint;
  v_available boolean:=false;
  v_reason text;
  v_currency text;
  v_currency_count integer;
begin
  perform app.v109_require_feature();
  perform app.v109_require_finance_scope(p_business,p_branch);
  if p_current_from is null
     or p_current_to is null
     or p_comparison_from is null
     or p_comparison_to is null
     or p_current_from>=p_current_to
     or p_comparison_from>=p_comparison_to
     or p_as_of is null then
    raise exception 'valid local-date periods and as-of are required'
      using errcode='22023';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches branch
     where branch.id=p_branch and branch.business_id=p_business
  ) then
    raise exception 'branch does not belong to business' using errcode='22023';
  end if;

  select count(distinct contract.currency),min(contract.currency)
    into v_currency_count,v_currency
    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
   where sale.business_id=p_business
     and (p_branch is null or sale.branch_id=p_branch)
     and sale.counts_as_revenue
     and sale.reversal_of is null
     and sale.created_at<=p_as_of
     and (
       (
         (sale.occurred_at at time zone contract.timezone)::date>=p_current_from
         and
         (sale.occurred_at at time zone contract.timezone)::date<p_current_to
       ) or (
         (sale.occurred_at at time zone contract.timezone)::date>=
           p_comparison_from
         and
         (sale.occurred_at at time zone contract.timezone)::date<p_comparison_to
       )
     );
  if v_currency_count>1 then
    raise exception 'cross-currency driver comparisons are not supported'
      using errcode='22023';
  end if;
  if v_currency_count=0 then
    select upper(currency) into strict v_currency
      from public.businesses where id=p_business;
  end if;

  with base as (
    select
      app.v113_effective_client_id(sale.business_id,sale.client_id) as client_id,
      app.v106_sale_residual_minor(
        sale.id,p_current_to,p_as_of
      ) as amount_cents,
      exists (
        select 1
          from public.sale_items item
         where item.business_id=sale.business_id
           and item.sale_id=sale.id
           and item.line_cents>0
      ) as is_itemized
    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.counts_as_revenue
      and sale.reversal_of is null
      and sale.created_at<=p_as_of
      and (sale.occurred_at at time zone contract.timezone)::date>=p_current_from
      and (sale.occurred_at at time zone contract.timezone)::date<p_current_to
      and app.v106_sale_residual_minor(
        sale.id,p_current_to,p_as_of
      )>0
  )
  select coalesce(sum(amount_cents),0),
    coalesce(sum(amount_cents) filter(where client_id is not null),0),
    count(*) filter(where client_id is not null),
    count(distinct client_id) filter(where client_id is not null),
    count(*),
    count(*) filter(where is_itemized),
    coalesce(sum(amount_cents) filter(where is_itemized),0)
  into c_total,c_identified,c_transactions,c_clients,
       c_total_transactions,c_itemized_transactions,c_itemized_revenue
  from base;

  with base as (
    select
      app.v113_effective_client_id(sale.business_id,sale.client_id) as client_id,
      app.v106_sale_residual_minor(
        sale.id,p_comparison_to,p_as_of
      ) as amount_cents,
      exists (
        select 1
          from public.sale_items item
         where item.business_id=sale.business_id
           and item.sale_id=sale.id
           and item.line_cents>0
      ) as is_itemized
    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.counts_as_revenue
      and sale.reversal_of is null
      and sale.created_at<=p_as_of
      and (sale.occurred_at at time zone contract.timezone)::date>=
        p_comparison_from
      and (sale.occurred_at at time zone contract.timezone)::date<
        p_comparison_to
      and app.v106_sale_residual_minor(
        sale.id,p_comparison_to,p_as_of
      )>0
  )
  select coalesce(sum(amount_cents),0),
    coalesce(sum(amount_cents) filter(where client_id is not null),0),
    count(*) filter(where client_id is not null),
    count(distinct client_id) filter(where client_id is not null),
    count(*),
    count(*) filter(where is_itemized),
    coalesce(sum(amount_cents) filter(where is_itemized),0)
  into p_total,p_identified,p_transactions,p_clients,
       p_total_transactions,p_itemized_transactions,p_itemized_revenue
  from base;

  c_anonymous:=c_total-c_identified;
  p_anonymous:=p_total-p_identified;
  c_coverage:=case when c_total=0 then null
    else round(c_identified*10000.0/c_total)::integer end;
  p_coverage:=case when p_total=0 then null
    else round(p_identified*10000.0/p_total)::integer end;
  c_itemized_transaction_coverage:=case when c_total_transactions=0 then null
    else round(c_itemized_transactions*10000.0/c_total_transactions)::integer end;
  p_itemized_transaction_coverage:=case when p_total_transactions=0 then null
    else round(p_itemized_transactions*10000.0/p_total_transactions)::integer end;
  c_itemized_revenue_coverage:=case when c_total=0 then null
    else round(c_itemized_revenue*10000.0/c_total)::integer end;
  p_itemized_revenue_coverage:=case when p_total=0 then null
    else round(p_itemized_revenue*10000.0/p_total)::integer end;
  d_total:=c_total-p_total;
  v_available:=c_clients>0 and p_clients>0
    and c_transactions>0 and p_transactions>0;
  if v_available then
    p_frequency:=p_transactions::numeric/p_clients;
    p_aov:=p_identified::numeric/p_transactions;
    c_frequency:=c_transactions::numeric/c_clients;
    c_aov:=c_identified::numeric/c_transactions;
    d_customer:=round((c_clients-p_clients)*p_frequency*p_aov);
    d_frequency:=round(c_clients*(c_frequency-p_frequency)*p_aov);
    d_aov:=round(c_clients*c_frequency*(c_aov-p_aov));
    d_anonymous:=c_anonymous-p_anonymous;
    d_residual:=d_total-d_customer-d_frequency-d_aov-d_anonymous;
    d_sum:=d_customer+d_frequency+d_aov+d_anonymous+d_residual;
  else
    v_reason:=case
      when p_total=0 then 'comparison_period_has_no_revenue'
      when c_total=0 then 'current_period_has_no_revenue'
      when p_clients=0 or p_transactions=0
        then 'comparison_period_has_no_identified_customer_base'
      else 'current_period_has_no_identified_customer_base'
    end;
  end if;

  return jsonb_build_object(
    'contract_version','revenue_driver_decomposition_v109',
    'business_id',p_business,'as_of',p_as_of,'currency',v_currency,
    'status',case when v_available then 'ready' else 'unavailable' end,
    'unavailable_reason',v_reason,
    'identity_attribution','v111_current_effective_identity',
    'periods',jsonb_build_object(
      'comparison',jsonb_build_object(
        'from',p_comparison_from,'to',p_comparison_to,
        'basis','business_local_date','revenue_cents',p_total,
        'identified_revenue_cents',p_identified,
        'anonymous_revenue_cents',p_anonymous,
        'identified_customers',p_clients,
        'identified_transactions',p_transactions,
        'transactions',p_total_transactions,
        'itemized_transactions',p_itemized_transactions,
        'itemized_revenue_cents',p_itemized_revenue
      ),
      'current',jsonb_build_object(
        'from',p_current_from,'to',p_current_to,
        'basis','business_local_date','revenue_cents',c_total,
        'identified_revenue_cents',c_identified,
        'anonymous_revenue_cents',c_anonymous,
        'identified_customers',c_clients,
        'identified_transactions',c_transactions,
        'transactions',c_total_transactions,
        'itemized_transactions',c_itemized_transactions,
        'itemized_revenue_cents',c_itemized_revenue
      )
    ),
    'coverage',jsonb_build_object(
      'comparison_identified_revenue_bps',p_coverage,
      'current_identified_revenue_bps',c_coverage,
      'comparison_itemized_transaction_bps',p_itemized_transaction_coverage,
      'current_itemized_transaction_bps',c_itemized_transaction_coverage,
      'comparison_itemized_revenue_bps',p_itemized_revenue_coverage,
      'current_itemized_revenue_bps',c_itemized_revenue_coverage,
      'anonymous_revenue_is_separate_driver',true
    ),
    'line_item_analysis',jsonb_build_object(
      'status','coverage_only',
      'price_volume_mix_status','not_claimed',
      'reason',
        'line-level price and mix effects require complete itemization and a versioned taxonomy',
      'causal_claim',false
    ),
    'drivers',case when v_available then jsonb_build_object(
      'identified_customer_count_cents',d_customer,
      'purchase_frequency_cents',d_frequency,
      'average_transaction_value_cents',d_aov,
      'anonymous_revenue_cents',d_anonymous,
      'rounding_residual_cents',d_residual
    ) else 'null'::jsonb end,
    'reconciliation',jsonb_build_object(
      'period_revenue_delta_cents',d_total,
      'sum_driver_contributions_cents',d_sum,
      'rounding_residual_cents',d_residual,
      'reconciles',case when v_available then d_sum=d_total else null end
    ),
    'method',jsonb_build_object(
      'identity',
        'revenue = effective identified customers × purchase frequency × average transaction value + anonymous revenue',
      'identity_resolver','v111_current_effective_identity',
      'order',jsonb_build_array(
        'identified_customer_count','purchase_frequency',
        'average_transaction_value','anonymous_revenue','rounding_residual'
      ),
      'deterministic',true,'causal_claim',false
    )
  );
end
$$;

-- Customer access follows the verified identity's effective client, not the
-- immutable identity/client snapshot stored when the offer was issued.
create or replace function public.customer_get_growth_offers_v108(
  p_business uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_identity uuid;
  v_client uuid;
begin
  select identity_row.id into v_identity
    from public.customer_identities identity_row
   where identity_row.auth_user_id=auth.uid()
     and identity_row.status='active';
  if v_identity is null then
    raise exception 'active customer identity required' using errcode='42501';
  end if;
  v_client:=app.v113_customer_effective_client_id(p_business,v_identity);

  with expired as (
    update public.growth_entitlements_v108 entitlement
       set status='expired'
     where entitlement.business_id=p_business
       and app.v113_effective_client_id(
             entitlement.business_id,entitlement.client_id
           )=v_client
       and entitlement.status='issued'
       and entitlement.expires_at<=statement_timestamp()
    returning entitlement.id,entitlement.business_id,entitlement.expires_at
  )
  insert into public.growth_entitlement_events_v108(
    entitlement_id,business_id,event_type,actor,idempotency_key,detail
  )
  select expired.id,expired.business_id,'expired',auth.uid(),
    extensions.uuid_generate_v5(expired.id,'expired'),
    jsonb_build_object('expired_at',expired.expires_at)
  from expired
  on conflict do nothing;

  return jsonb_build_object(
    'business_id',p_business,
    'identity_attribution','v111_current_effective_identity',
    'offers',coalesce((
      select jsonb_agg(jsonb_build_object(
        'entitlement_id',entitlement.id,
        'label',execution.offer_label,
        'type',entitlement.entitlement_type,
        'value_cents',entitlement.value_cents,
        'currency',execution.currency,
        'governed_copy',execution.governed_copy,
        'status',entitlement.status,
        'issued_at',entitlement.issued_at,
        'expires_at',entitlement.expires_at,
        'redeemed_at',entitlement.redeemed_at
      ) order by entitlement.issued_at desc,entitlement.id desc)
      from public.growth_entitlements_v108 entitlement
      join public.growth_executions_v108 execution
        on execution.id=entitlement.execution_id
      where entitlement.business_id=p_business
        and app.v113_effective_client_id(
              entitlement.business_id,entitlement.client_id
            )=v_client
    ),'[]'::jsonb)
  );
end
$$;

create or replace function public.customer_prepare_growth_offer_qr_v108(
  p_entitlement uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_identity uuid;
  v_client uuid;
  v_entitlement public.growth_entitlements_v108%rowtype;
  v_intent public.growth_redemption_intents_v108%rowtype;
  v_token text;
  v_request_hash text;
  v_now timestamptz:=statement_timestamp();
begin
  select identity_row.id into v_identity
    from public.customer_identities identity_row
   where identity_row.auth_user_id=auth.uid()
     and identity_row.status='active';
  if v_identity is null then
    raise exception 'active customer identity required' using errcode='42501';
  end if;
  select * into v_entitlement
    from public.growth_entitlements_v108 entitlement
   where entitlement.id=p_entitlement
   for update;
  if not found then raise exception 'offer not found'; end if;
  v_client:=app.v113_customer_effective_client_id(
    v_entitlement.business_id,v_identity
  );
  if app.v113_effective_client_id(
       v_entitlement.business_id,v_entitlement.client_id
     )<>v_client then
    raise exception 'offer not found' using errcode='42501';
  end if;
  if v_entitlement.status<>'issued' or v_entitlement.expires_at<=v_now then
    raise exception 'offer is not redeemable' using errcode='42501';
  end if;
  v_request_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'identity_id',v_identity,
    'effective_client_id',v_client,
    'entitlement_id',p_entitlement
  )::text,'UTF8'),'sha256'),'hex');
  v_token:=app.growth_v108_token(
    v_identity,v_entitlement.business_id,v_entitlement.id,p_idempotency_key
  );
  select * into v_intent
    from public.growth_redemption_intents_v108 intent
   where intent.identity_id=v_identity
     and intent.idempotency_key=p_idempotency_key;
  if found then
    if v_intent.request_hash<>v_request_hash then
      raise exception 'idempotency key reused with a different QR request'
        using errcode='23505';
    end if;
    return jsonb_build_object(
      'intent_id',v_intent.id,'token',v_token,
      'expires_at',v_intent.expires_at,'replayed',true
    );
  end if;
  insert into public.growth_redemption_intents_v108(
    entitlement_id,business_id,identity_id,token_hash,idempotency_key,
    request_hash,expires_at
  ) values (
    v_entitlement.id,v_entitlement.business_id,v_identity,
    encode(extensions.digest(convert_to(v_token,'UTF8'),'sha256'),'hex'),
    p_idempotency_key,v_request_hash,
    least(v_now+interval '5 minutes',v_entitlement.expires_at)
  ) returning * into v_intent;
  insert into public.growth_entitlement_events_v108(
    entitlement_id,business_id,event_type,actor,idempotency_key,detail
  ) values (
    v_entitlement.id,v_entitlement.business_id,'qr_prepared',auth.uid(),
    p_idempotency_key,jsonb_build_object(
      'intent_id',v_intent.id,
      'identity_attribution','v111_current_effective_identity'
    )
  );
  return jsonb_build_object(
    'intent_id',v_intent.id,'token',v_token,
    'expires_at',v_intent.expires_at,'replayed',false
  );
end
$$;

create or replace function public.redeem_growth_offer_v108(
  p_business uuid,
  p_token text,
  p_sale uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_intent public.growth_redemption_intents_v108%rowtype;
  v_entitlement public.growth_entitlements_v108%rowtype;
  v_execution public.growth_executions_v108%rowtype;
  v_sale public.sales%rowtype;
  v_existing public.growth_entitlement_events_v108%rowtype;
  v_now timestamptz:=clock_timestamp();
  v_request_hash text;
  v_receipt jsonb;
begin
  if v_actor is null
     or not app.has_perm(p_business,'create_sales')
     or not app.can_module_read(p_business,'retention') then
    raise exception 'sales and retention access required' using errcode='42501';
  end if;
  select * into v_intent
    from public.growth_redemption_intents_v108 intent
   where intent.business_id=p_business
     and intent.token_hash=encode(
       extensions.digest(convert_to(p_token,'UTF8'),'sha256'),'hex'
     )
   for update;
  if not found then raise exception 'invalid offer QR'; end if;
  v_request_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'business_id',p_business,'intent_id',v_intent.id,
    'entitlement_id',v_intent.entitlement_id,'sale_id',p_sale
  )::text,'UTF8'),'sha256'),'hex');
  select * into v_existing
    from public.growth_entitlement_events_v108 event
   where event.business_id=p_business
     and event.actor=v_actor
     and event.event_type='redeemed'
     and event.idempotency_key=p_idempotency_key;
  if found then
    if v_existing.detail->>'request_hash'<>v_request_hash then
      raise exception 'idempotency key reused with a different redemption request'
        using errcode='23505';
    end if;
    return v_existing.detail->'receipt';
  end if;
  if v_intent.status<>'pending' or v_intent.expires_at<=v_now then
    raise exception 'offer QR is no longer valid' using errcode='42501';
  end if;
  select * into v_entitlement
    from public.growth_entitlements_v108 entitlement
   where entitlement.id=v_intent.entitlement_id
     and entitlement.business_id=p_business
   for update;
  if v_entitlement.status<>'issued' or v_entitlement.expires_at<=v_now then
    raise exception 'offer is no longer redeemable' using errcode='42501';
  end if;
  select * into strict v_execution
    from public.growth_executions_v108 execution
   where execution.id=v_entitlement.execution_id
     and execution.business_id=p_business;
  if not app.can_see_branch(v_execution.business_id,v_execution.branch_id) then
    raise exception 'offer branch is outside actor scope' using errcode='42501';
  end if;
  select * into v_sale
    from public.sales sale
   where sale.id=p_sale and sale.business_id=p_business
   for share;
  if not found
     or v_sale.client_id is null
     or app.v113_effective_client_id(v_sale.business_id,v_sale.client_id)
        <>app.v113_effective_client_id(
             v_entitlement.business_id,v_entitlement.client_id
           )
     or not v_sale.counts_as_visit
     or not v_sale.counts_as_revenue
     or v_sale.reversal_of is not null
     or v_sale.amount_cents<=0
     or v_sale.created_at>v_now
     or v_sale.occurred_at>v_now
     or app.v106_sale_residual_minor(v_sale.id,v_now)<=0
     or exists (
       select 1 from public.sales reversal
        where reversal.business_id=v_sale.business_id
          and reversal.reversal_of=v_sale.id
          and reversal.created_at<=v_now
     )
     or v_sale.created_at<greatest(v_entitlement.issued_at,v_execution.started_at)
     or v_sale.occurred_at<greatest(v_entitlement.issued_at,v_execution.started_at)
     or v_sale.occurred_at>=least(v_entitlement.expires_at,v_execution.ends_at)
     or (
       v_execution.branch_id is not null
       and v_sale.branch_id is distinct from v_execution.branch_id
     )
     or not app.can_see_branch(v_sale.business_id,v_sale.branch_id) then
    raise exception 'offer must attach to this customer''s qualifying sale'
      using errcode='22023';
  end if;
  v_receipt:=jsonb_build_object(
    'entitlement_id',v_entitlement.id,'sale_id',p_sale,
    'value_cents',v_entitlement.value_cents,'status','redeemed',
    'identity_attribution','v111_current_effective_identity'
  );
  update public.growth_entitlements_v108
     set status='redeemed',redeemed_at=v_now,redeemed_sale_id=p_sale
   where id=v_entitlement.id;
  update public.growth_redemption_intents_v108
     set status='completed',completed_at=v_now
   where id=v_intent.id;
  insert into public.growth_entitlement_events_v108(
    entitlement_id,business_id,event_type,actor,sale_id,idempotency_key,detail
  ) values (
    v_entitlement.id,p_business,'redeemed',v_actor,p_sale,p_idempotency_key,
    jsonb_build_object(
      'intent_id',v_intent.id,'value_cents',v_entitlement.value_cents,
      'request_hash',v_request_hash,'receipt',v_receipt,
      'identity_attribution','v111_current_effective_identity'
    )
  );
  return v_receipt;
end
$$;


revoke all on function app.v113_customer_effective_client_id(uuid,uuid)
  from public,anon,authenticated;

-- A correction may be approved after a recommendation snapshot was generated.
-- The execution boundary rejects a now-duplicated snapshot and reserves overlap
-- against the effective identity of every running member.
create or replace function app.v113_guard_growth_execution_identity()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_eligible integer;
  v_effective integer;
begin
  select count(*),
         count(distinct app.v113_effective_client_id(member.business_id,member.client_id))
    into v_eligible,v_effective
    from public.growth_recommendation_members_v108 member
   where member.recommendation_id=new.recommendation_id
     and member.business_id=new.business_id
     and member.eligible;
  if v_eligible<>v_effective then
    raise exception 'recommendation identity snapshot is stale; refresh before approval'
      using errcode='55000';
  end if;
  if exists (
    select 1
      from public.growth_recommendation_members_v108 candidate
      join public.growth_execution_members_v108 active_member
        on active_member.business_id=candidate.business_id
       and app.v113_effective_client_id(
             active_member.business_id,active_member.client_id
           )=app.v113_effective_client_id(
             candidate.business_id,candidate.client_id
           )
      join public.growth_executions_v108 active_execution
        on active_execution.id=active_member.execution_id
       and active_execution.business_id=active_member.business_id
     where candidate.recommendation_id=new.recommendation_id
       and candidate.business_id=new.business_id
       and candidate.eligible
       and active_execution.status='running'
       and active_execution.ends_at>statement_timestamp()
  ) then
    raise exception 'recommendation overlaps an active effective-customer experiment'
      using errcode='23P01';
  end if;
  return new;
end
$$;

revoke all on function app.v113_guard_growth_execution_identity()
  from public,anon,authenticated;

drop trigger if exists growth_executions_v113_identity_guard
  on public.growth_executions_v108;
create trigger growth_executions_v113_identity_guard
before insert on public.growth_executions_v108
for each row execute function app.v113_guard_growth_execution_identity();

-- Identity approval and growth approval share this business-scoped lock.  The
-- lock closes the cross-flow race where each approval observes the state before
-- the other commits.  Existing inconsistent snapshots are still handled by the
-- outcome/result fail-closed guards above.
alter function public.approve_customer_identity_correction_v111(uuid,uuid)
  rename to approve_customer_identity_correction_v111_v113_inner;

revoke all on function
  public.approve_customer_identity_correction_v111_v113_inner(uuid,uuid)
  from public,anon,authenticated;

create or replace function public.approve_customer_identity_correction_v111(
  p_proposal uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_proposal public.customer_identity_proposals_v111%rowtype;
  v_active_members integer:=0;
begin
  if v_actor is null then
    raise exception 'authentication required' using errcode='42501';
  end if;
  select * into v_proposal
    from public.customer_identity_proposals_v111 proposal
   where proposal.id=p_proposal;
  if not found then
    raise exception 'identity proposal not found' using errcode='23503';
  end if;
  if not app.v111_can_decide(v_proposal.business_id) then
    raise exception 'owner or global business authority is required to approve'
      using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'growth-v108-membership:'||v_proposal.business_id::text,0
  ));
  if v_proposal.status<>'approved' then
    select count(*) into v_active_members
      from public.growth_execution_members_v108 member
      join public.growth_executions_v108 execution
        on execution.id=member.execution_id
       and execution.business_id=member.business_id
     where member.business_id=v_proposal.business_id
       and execution.status='running'
       and execution.ends_at>statement_timestamp()
       and app.v113_effective_client_id(
             member.business_id,member.client_id
           ) in (
             app.v113_effective_client_id(
               v_proposal.business_id,v_proposal.source_client_id
             ),
             app.v113_effective_client_id(
               v_proposal.business_id,v_proposal.target_client_id
             )
           );
    if v_active_members>1 then
      raise exception
        'identity correction would overlap active customer experiments'
        using errcode='23P01';
    end if;
  end if;
  return public.approve_customer_identity_correction_v111_v113_inner(
    p_proposal,p_idempotency_key
  );
end
$$;

revoke all on function
  public.approve_customer_identity_correction_v111(uuid,uuid)
  from public,anon;
grant execute on function
  public.approve_customer_identity_correction_v111(uuid,uuid)
  to authenticated;

create or replace function app.v113_canonicalize_execution_member()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  new.client_id:=app.v113_effective_client_id(new.business_id,new.client_id);
  return new;
end
$$;

revoke all on function app.v113_canonicalize_execution_member()
  from public,anon,authenticated;

drop trigger if exists growth_execution_members_v113_effective_identity
  on public.growth_execution_members_v108;
create trigger growth_execution_members_v113_effective_identity
before insert on public.growth_execution_members_v108
for each row execute function app.v113_canonicalize_execution_member();

-- Build one cohort row per current effective customer.  Sales keep their source
-- client_id; only the analytical partition is canonical.
create or replace function public.refresh_growth_recommendation_v108(
  p_business uuid,
  p_branch uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_now timestamptz:=statement_timestamp();
  v_policy public.growth_policies_v108%rowtype;
  v_recommendation uuid:=gen_random_uuid();
  v_total_revenue bigint:=0;
  v_identified_revenue bigint:=0;
  v_total_sales integer:=0;
  v_identified_sales integer:=0;
  v_coverage_bps integer:=0;
  v_eligible integer:=0;
  v_excluded integer:=0;
  v_avg_value bigint:=0;
  v_confidence_bps integer:=0;
  v_status text;
  v_suppressions jsonb:='[]'::jsonb;
  v_dedupe text;
  v_existing uuid;
  v_member_fingerprint text;
  v_currency text;
  v_effective_policy jsonb;
  v_candidates jsonb:='[]'::jsonb;
begin
  if v_actor is null or (
    not app.is_super_admin()
    and (
      not app.has_perm(p_business,'view_finance')
      or not app.can_module_read(p_business,'retention')
    )
  ) then
    raise exception 'finance and retention access required' using errcode='42501';
  end if;
  if not app.can_see_branch(p_business,p_branch) then
    raise exception 'branch is outside actor scope' using errcode='42501';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches branch
     where branch.id=p_branch and branch.business_id=p_business
  ) then
    raise exception 'branch does not belong to business' using errcode='22023';
  end if;
  if not app.platform_feature_enabled('growth_closed_loop_v108') then
    raise exception 'growth closed loop is not enabled' using errcode='0A000';
  end if;
  select upper(currency) into strict v_currency
    from public.businesses where id=p_business;

  insert into public.growth_policies_v108(business_id,updated_by)
  values(p_business,v_actor)
  on conflict (business_id) do nothing;
  select * into strict v_policy
    from public.growth_policies_v108 where business_id=p_business;
  v_effective_policy:=app.growth_v108_effective_parameters(p_business);

  select
    coalesce(sum(app.v106_sale_residual_minor(sale.id,v_now))
      filter(where sale.counts_as_revenue),0),
    coalesce(sum(app.v106_sale_residual_minor(sale.id,v_now))
      filter(where sale.counts_as_revenue and sale.client_id is not null),0),
    count(*) filter(where sale.counts_as_revenue),
    count(*) filter(where sale.counts_as_revenue and sale.client_id is not null)
  into v_total_revenue,v_identified_revenue,v_total_sales,v_identified_sales
  from public.sales sale
  where sale.business_id=p_business
    and (p_branch is null or sale.branch_id=p_branch)
    and sale.occurred_at>=v_now-interval '90 days'
    and sale.occurred_at<v_now
    and sale.reversal_of is null
    and not exists (
      select 1 from public.sales reversal
       where reversal.business_id=sale.business_id
         and reversal.reversal_of=sale.id
    );
  v_coverage_bps:=case when v_total_revenue>0
    then least(10000,(v_identified_revenue*10000/v_total_revenue)::integer)
    else 0 end;

  with canonical_sales as (
    select
      app.v113_effective_client_id(sale.business_id,sale.client_id) as client_id,
      sale.occurred_at,
      sale.id,
      app.v106_sale_residual_minor(sale.id,v_now) as amount_cents
    from public.sales sale
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and app.v106_sale_residual_minor(sale.id,v_now)>0
      and sale.occurred_at>=v_now-make_interval(days=>v_policy.observation_days)
      and sale.occurred_at<v_now
      and not exists (
        select 1 from public.sales reversal
         where reversal.business_id=sale.business_id
           and reversal.reversal_of=sale.id
      )
  ),
  visits as (
    select canonical_sales.*,
      extract(epoch from (
        occurred_at-lag(occurred_at) over (
          partition by client_id order by occurred_at,id
        )
      ))/86400.0 as interval_days
    from canonical_sales
  ),
  metrics as (
    select visit.client_id,
      count(*)::integer as prior_visits,
      max(visit.occurred_at) as last_visit_at,
      percentile_cont(0.5) within group(order by visit.interval_days)
        filter(where visit.interval_days is not null) as cadence_days,
      floor(extract(epoch from(v_now-max(visit.occurred_at)))/86400)::integer
        as lapse_days,
      round(avg(visit.amount_cents))::bigint as average_transaction_cents,
      sum(visit.amount_cents)::bigint as historical_revenue_cents
    from visits visit
    group by visit.client_id
  ),
  judged as (
    select metric.*,
      case
        when metric.prior_visits<
          (v_effective_policy#>>'{parameters,minimum_prior_visits}')::integer
          then 'insufficient_history'
        when metric.cadence_days is null then 'insufficient_history'
        when metric.lapse_days<greatest(
          (v_effective_policy#>>'{parameters,minimum_lapse_days}')::integer,
          ceil(metric.cadence_days*
            (v_effective_policy#>>'{parameters,cadence_multiplier}')::numeric
          )::integer
        ) then 'not_lapsed'
        when not exists (
          select 1
            from public.customer_links link
            join public.customer_identities identity_row
              on identity_row.id=link.identity_id
             and identity_row.status='active'
           where link.business_id=p_business
             and app.v113_effective_client_id(link.business_id,link.client_id)
                 =metric.client_id
             and link.state='verified'
        ) then 'no_verified_link'
        when not exists (
          select 1
            from public.customer_notification_preferences preference
            join public.customer_links link
              on link.id=preference.link_id
             and link.business_id=preference.business_id
            join public.customer_identities identity_row
              on identity_row.id=link.identity_id
             and identity_row.status='active'
           where preference.business_id=p_business
             and app.v113_effective_client_id(
                   preference.business_id,preference.client_id
                 )=metric.client_id
             and preference.channel='in_app'
             and preference.topic='marketing'
             and preference.opted_in
             and link.state='verified'
        ) then 'no_marketing_consent'
        when exists (
          select 1 from public.growth_deliveries_v108 delivery
           where delivery.business_id=p_business
             and app.v113_effective_client_id(
                   delivery.business_id,delivery.client_id
                 )=metric.client_id
             and delivery.delivery_status='delivered'
             and delivery.delivered_at>=
               v_now-make_interval(days=>v_policy.frequency_cap_days)
        ) then 'frequency_cap'
        when exists (
          select 1
            from public.growth_execution_members_v108 member
            join public.growth_executions_v108 execution
              on execution.id=member.execution_id
           where member.business_id=p_business
             and app.v113_effective_client_id(
                   member.business_id,member.client_id
                 )=metric.client_id
             and execution.status='running'
             and execution.ends_at>v_now
        ) then 'active_experiment'
        else null
      end as exclusion_reason
    from metrics metric
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'client_id',judged.client_id,
    'prior_visits',judged.prior_visits,
    'last_visit_at',judged.last_visit_at,
    'cadence_days',judged.cadence_days,
    'lapse_days',judged.lapse_days,
    'average_transaction_cents',judged.average_transaction_cents,
    'historical_revenue_cents',judged.historical_revenue_cents,
    'eligible',judged.exclusion_reason is null,
    'exclusion_reason',judged.exclusion_reason
  ) order by judged.client_id),'[]'::jsonb)
  into v_candidates
  from judged;

  select count(*) filter(where eligible),
         count(*) filter(where not eligible),
         coalesce(round(avg(average_transaction_cents)
           filter(where eligible)),0)::bigint
    into v_eligible,v_excluded,v_avg_value
    from jsonb_to_recordset(v_candidates) as candidate(
      client_id uuid,
      prior_visits integer,
      last_visit_at timestamptz,
      cadence_days numeric,
      lapse_days integer,
      average_transaction_cents bigint,
      historical_revenue_cents bigint,
      eligible boolean,
      exclusion_reason text
    );
  v_confidence_bps:=least(9500,
    greatest(0,v_coverage_bps*7/10)+least(2500,v_eligible*100)
  );

  if not v_policy.enabled then
    v_suppressions:=v_suppressions||jsonb_build_array('policy_disabled');
  end if;
  if v_total_sales<50 then
    v_suppressions:=v_suppressions||jsonb_build_array('cold_start_under_50_sales');
  end if;
  if v_coverage_bps<v_policy.minimum_identity_coverage_bps then
    v_suppressions:=v_suppressions||
      jsonb_build_array('identity_coverage_below_threshold');
  end if;
  if v_eligible<
     (v_effective_policy#>>'{parameters,minimum_audience}')::integer then
    v_suppressions:=v_suppressions||jsonb_build_array('audience_below_minimum');
  end if;
  v_suppressions:=v_suppressions||
    coalesce(v_effective_policy->'suppression_reasons','[]'::jsonb);
  if floor(v_eligible*v_policy.holdout_percent/100.0)<v_policy.minimum_arm_size
     or v_eligible-floor(v_eligible*v_policy.holdout_percent/100.0)
        <v_policy.minimum_arm_size then
    v_suppressions:=v_suppressions||
      jsonb_build_array('experiment_arms_too_small');
  end if;
  v_status:=case when jsonb_array_length(v_suppressions)=0
    then 'presented' else 'suppressed' end;

  select encode(extensions.digest(convert_to(
    coalesce(jsonb_agg(jsonb_build_array(
      candidate.client_id,candidate.eligible,candidate.exclusion_reason,
      candidate.prior_visits,candidate.last_visit_at,
      round(candidate.cadence_days,2),candidate.lapse_days,
      candidate.average_transaction_cents,candidate.historical_revenue_cents
    ) order by candidate.client_id)::text,'[]'),'UTF8'
  ),'sha256'),'hex')
  into v_member_fingerprint
  from jsonb_to_recordset(v_candidates) as candidate(
    client_id uuid,
    prior_visits integer,
    last_visit_at timestamptz,
    cadence_days numeric,
    lapse_days integer,
    average_transaction_cents bigint,
    historical_revenue_cents bigint,
    eligible boolean,
    exclusion_reason text
  );

  v_dedupe:=encode(extensions.digest(convert_to(concat_ws(':',
    'v113',p_business,coalesce(p_branch::text,'all'),v_policy.policy_version,
    date_trunc('day',v_now)::text,v_status,v_currency,v_total_sales,
    v_identified_sales,v_total_revenue,v_identified_revenue,v_eligible,
    v_excluded,v_avg_value,v_policy.default_credit_cents,
    v_policy.maximum_credit_cents,v_policy.frequency_cap_days,
    v_policy.attribution_days,v_policy.minimum_arm_size,
    v_policy.holdout_percent,v_member_fingerprint,v_effective_policy::text
  ),'UTF8'),'sha256'),'hex');
  perform pg_advisory_xact_lock(
    hashtextextended('growth-v108-refresh:'||v_dedupe,0)
  );
  select recommendation.id into v_existing
    from public.growth_recommendations_v108 recommendation
   where recommendation.dedupe_key=v_dedupe;
  if found then
    return jsonb_build_object(
      'recommendation_id',v_existing,'status',v_status,
      'eligible',v_eligible,'excluded',v_excluded,
      'coverage_bps',v_coverage_bps,
      'suppression_reasons',v_suppressions,'replayed',true
    );
  end if;

  insert into public.growth_recommendations_v108(
    id,business_id,branch_id,recommendation_type,policy_version,
    generated_at,valid_until,observation_start,observation_end,
    comparison_start,comparison_end,finding,supporting_evidence,baseline,
    opportunity,expected_incremental_revenue,expected_incremental_gross_profit,
    confidence,assumptions,recommended_action,recommended_channel,
    recommended_offer,estimated_cost_cents,audience_size,excluded_size,
    success_metric,frequency_cap_days,attribution_window_days,holdout_percent,
    stop_conditions,status,suppression_reasons,data_freshness_at,data_coverage,
    dedupe_key,created_by
  ) values (
    v_recommendation,p_business,p_branch,'lapsed_high_value_bring_back',
    v_policy.policy_version,v_now,v_now+interval '24 hours',
    v_now-make_interval(days=>v_policy.observation_days),v_now,
    v_now-interval '180 days',v_now-interval '90 days',
    case when v_status='presented'
      then v_eligible||
        ' previously active customers are beyond their observed visit cadence.'
      else 'No reliable bring-back action is available yet.' end,
    jsonb_build_array(
      jsonb_build_object('metric','eligible_customers','value',v_eligible),
      jsonb_build_object(
        'metric','identified_revenue_coverage_bps','value',v_coverage_bps
      ),
      jsonb_build_object(
        'metric','average_historical_transaction_cents','value',v_avg_value
      ),
      jsonb_build_object(
        'metric','effective_policy_lineage','value',v_effective_policy
      ),
      jsonb_build_object(
        'metric','identity_attribution','value','v111_current_effective_identity'
      )
    ),
    jsonb_build_object(
      'total_sales_90d',v_total_sales,
      'identified_sales_90d',v_identified_sales,
      'total_revenue_cents_90d',v_total_revenue,
      'identified_revenue_cents_90d',v_identified_revenue
    ),
    jsonb_build_object(
      'eligible_customers',v_eligible,
      'historical_average_transaction_cents',v_avg_value
    ),
    jsonb_build_object(
      'currency',v_currency,'status','withheld_uncalibrated',
      'kind','incremental_revenue_not_yet_available',
      'reason','no completed calibrated experiment evidence'
    ),
    null,
    jsonb_build_object(
      'score_bps',v_confidence_bps,'score_kind','data_quality_only',
      'level',case
        when v_confidence_bps>=8000 then 'high'
        when v_confidence_bps>=6500 then 'medium'
        else 'low' end,
      'reasons',jsonb_build_array(
        'identity coverage and audience size determine confidence',
        'causal result remains unavailable until a valid holdout completes'
      )
    ),
    jsonb_build_array(
      'future behaviour may differ from historical cadence',
      'expected revenue is a range, not a guarantee',
      'gross profit is unavailable until item cost coverage is complete'
    ),
    jsonb_build_object(
      'label','Approve measured bring-back','channel','in_app',
      'requires_owner_approval',true
    ),
    'in_app',
    jsonb_build_object(
      'type','credit_cents','value_cents',v_policy.default_credit_cents,
      'currency',v_currency,'expires_in_days',7
    ),
    greatest(0,
      (v_eligible-floor(v_eligible*v_policy.holdout_percent/100.0)::integer)
      *v_policy.default_credit_cents
    ),
    v_eligible,v_excluded,'incremental_completed_purchase_revenue',
    v_policy.frequency_cap_days,v_policy.attribution_days,
    v_policy.holdout_percent,
    jsonb_build_object(
      'budget_cap_cents',v_eligible*v_policy.maximum_credit_cents,
      'one_active_experiment_per_customer',true,
      'consent_rechecked_at_execution',true,
      'minimum_arm_size',v_policy.minimum_arm_size,
      'identity_attribution','v111_current_effective_identity'
    ),
    v_status,v_suppressions,v_now,
    jsonb_build_object(
      'identified_revenue_bps',v_coverage_bps,
      'total_sales',v_total_sales,'identified_sales',v_identified_sales,
      'effective_policy',v_effective_policy,
      'identity_attribution','v111_current_effective_identity','as_of',v_now
    ),
    v_dedupe,v_actor
  );

  insert into public.growth_recommendation_members_v108(
    recommendation_id,business_id,client_id,eligible,exclusion_reason,
    prior_visits,last_visit_at,cadence_days,lapse_days,
    average_transaction_cents,historical_revenue_cents,evidence
  )
  select v_recommendation,p_business,candidate.client_id,candidate.eligible,
    candidate.exclusion_reason,candidate.prior_visits,candidate.last_visit_at,
    round(candidate.cadence_days,2),candidate.lapse_days,
    candidate.average_transaction_cents,candidate.historical_revenue_cents,
    jsonb_build_object(
      'prior_visits',candidate.prior_visits,
      'last_visit_at',candidate.last_visit_at,
      'observed_median_cadence_days',round(candidate.cadence_days,2),
      'days_since_last_visit',candidate.lapse_days,
      'historical_average_transaction_cents',
        candidate.average_transaction_cents,
      'identity_attribution','v111_current_effective_identity'
    )
  from jsonb_to_recordset(v_candidates) as candidate(
    client_id uuid,
    prior_visits integer,
    last_visit_at timestamptz,
    cadence_days numeric,
    lapse_days integer,
    average_transaction_cents bigint,
    historical_revenue_cents bigint,
    eligible boolean,
    exclusion_reason text
  );

  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values (
    p_business,v_actor,'REFRESH_GROWTH_RECOMMENDATION_V108',
    'growth_recommendations_v108',v_recommendation,
    jsonb_build_object(
      'status',v_status,'eligible',v_eligible,'excluded',v_excluded,
      'coverage_bps',v_coverage_bps,
      'identity_attribution','v111_current_effective_identity'
    )
  );
  return jsonb_build_object(
    'recommendation_id',v_recommendation,'status',v_status,
    'eligible',v_eligible,'excluded',v_excluded,
    'coverage_bps',v_coverage_bps,
    'suppression_reasons',v_suppressions,'replayed',false
  );
end
$$;

revoke all on function public.refresh_growth_recommendation_v108(uuid,uuid)
  from public,anon;
revoke all on function public.customer_get_growth_offers_v108(uuid)
  from public,anon;
revoke all on function public.customer_prepare_growth_offer_qr_v108(uuid,uuid)
  from public,anon;
revoke all on function public.redeem_growth_offer_v108(uuid,text,uuid,uuid)
  from public,anon;
revoke all on function public.get_revenue_driver_decomposition_v109(
  uuid,date,date,date,date,uuid,timestamptz
) from public,anon;

grant execute on function public.refresh_growth_recommendation_v108(uuid,uuid)
  to authenticated;
grant execute on function public.customer_get_growth_offers_v108(uuid)
  to authenticated;
grant execute on function public.customer_prepare_growth_offer_qr_v108(uuid,uuid)
  to authenticated;
grant execute on function public.redeem_growth_offer_v108(uuid,text,uuid,uuid)
  to authenticated;
grant execute on function public.get_revenue_driver_decomposition_v109(
  uuid,date,date,date,date,uuid,timestamptz
) to authenticated;

comment on function public.get_revenue_driver_decomposition_v109(
  uuid,date,date,date,date,uuid,timestamptz
) is
  'Deterministic non-causal revenue bridge whose customer counts and frequency resolve immutable source client ids through current v111 effective identity.';

commit;
