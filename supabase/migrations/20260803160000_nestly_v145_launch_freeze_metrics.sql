-- NESTLY V145 - launch feature-freeze metric truth and bounded reporting
-- Local review candidate. Do not apply without independent acceptance and release approval.

begin;

-- A branch override can intentionally diverge from the firm-level module mode.
-- Metric surfaces must therefore prove that their complete selected scope is readable
-- before a SECURITY DEFINER aggregate bypasses RLS, or before the browser reads an
-- RLS-filtered table. Returning false is deliberate: a partial figure is never a valid
-- substitute for an unavailable complete scope.
create or replace function app.metric_module_scope_available_v145(
  p_business uuid,
  p_branch uuid,
  p_module text)
returns boolean
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null
     or p_module is null
     or not app.can_see_branch(p_business, p_branch) then
    return false;
  end if;
  if p_branch is not null and not exists (
    select 1
    from public.branches branch
    where branch.id = p_branch
      and branch.business_id = p_business
  ) then
    return false;
  end if;
  if app.is_super_admin() then
    return true;
  end if;
  if p_branch is not null then
    -- Inactive branches are historical read scopes: their operational module resolver
    -- correctly disables new work, so metric reads inherit the firm read boundary while
    -- can_see_branch above still enforces the caller's branch visibility.
    if exists (
      select 1 from public.branches branch
       where branch.id = p_branch
         and branch.business_id = p_business
         and not branch.active
    ) then
      return app.can_module_read_at_v94(p_business, null, p_module);
    end if;
    return app.can_module_read_at_v94(p_business, p_branch, p_module);
  end if;
  if not app.can_module_read_at_v94(p_business, null, p_module) then
    return false;
  end if;
  return not exists (
    select 1
    from public.branches branch
    where branch.business_id = p_business
      and (
        not app.can_see_branch(p_business, branch.id)
        or not case when branch.active
          then app.can_module_read_at_v94(p_business, branch.id, p_module)
          else app.can_module_read_at_v94(p_business, null, p_module)
        end
      )
  );
end;
$$;

create or replace function app.require_metric_module_scope_v145(
  p_business uuid,
  p_branch uuid,
  p_module text)
returns void
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if not app.metric_module_scope_available_v145(p_business, p_branch, p_module) then
    raise exception 'complete_metric_scope_required:%', p_module
      using errcode = '42501';
  end if;
end;
$$;

-- SECURITY DEFINER report aggregates sometimes need to prove that an underlying
-- platform source is enabled without granting the caller that source module's raw
-- rows. This keeps a Reports-read-only role useful while still failing closed when
-- Sales is disabled anywhere in the requested scope. Branch visibility remains
-- mandatory and all-business scope is never inferred from one assigned branch.
create or replace function app.platform_metric_source_scope_available_v145(
  p_business uuid,
  p_branch uuid,
  p_module text)
returns boolean
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_active boolean;
  v_mode text;
begin
  if auth.uid() is null
     or p_module is null
     or not app.can_see_branch(p_business, p_branch) then
    return false;
  end if;
  if p_branch is not null then
    select branch.active into v_active
      from public.branches branch
     where branch.id=p_branch and branch.business_id=p_business;
    if not found then return false;end if;
    select resolved.mode into v_mode
      from app.effective_platform_module_mode_v94(
        p_business,case when v_active then p_branch else null end,p_module
      ) resolved;
    return coalesce(v_mode,'disabled')<>'disabled';
  end if;
  select resolved.mode into v_mode
    from app.effective_platform_module_mode_v94(p_business,null,p_module) resolved;
  if coalesce(v_mode,'disabled')='disabled' then return false;end if;
  return not exists (
    select 1
      from public.branches branch
     where branch.business_id=p_business
       and branch.active
       and coalesce((
         select resolved.mode
           from app.effective_platform_module_mode_v94(
             p_business,branch.id,p_module
           ) resolved
       ),'disabled')='disabled'
  );
end;
$$;

-- Existing browser-rendered operational reports still read their detail rows through
-- RLS. This narrow preflight prevents those reads from silently becoming partial when a
-- branch override disables the page or a required source module.
create or replace function public.require_module_scope_v145(
  p_business uuid,
  p_branch uuid,
  p_module text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_dependency text;
  v_permission text;
begin
  if p_module is null or p_module not in (
    'dailyreport', 'staffperf', 'expenses', 'retention', 'appointments', 'clients',
    'reports', 'sales', 'loyalty', 'memberships', 'packages', 'referrals'
  ) then
    raise exception 'unsupported metric module'
      using errcode = '22023';
  end if;
  v_permission := case when p_module in ('staffperf', 'expenses')
    then 'view_finance' else 'view_sales' end;
  if auth.uid() is null or not app.has_perm(p_business, v_permission) then
    raise exception 'metric module permission required:%', p_module
      using errcode = '42501';
  end if;
  perform app.require_metric_module_scope_v145(p_business, p_branch, p_module);
  for v_dependency in
    select dependency
    from public.module_registry registry
    cross join lateral unnest(registry.requires_modules) dependency
    where registry.module_key = p_module
  loop
    perform app.require_metric_module_scope_v145(
      p_business, p_branch, v_dependency
    );
  end loop;
  return jsonb_build_object(
    'status', 'ok',
    'module', p_module,
    'branch_id', p_branch
  );
end;
$$;

revoke all on function app.metric_module_scope_available_v145(uuid, uuid, text)
  from public, anon, authenticated;
revoke all on function app.require_metric_module_scope_v145(uuid, uuid, text)
  from public, anon, authenticated;
revoke all on function app.platform_metric_source_scope_available_v145(uuid, uuid, text)
  from public, anon, authenticated;
revoke all on function public.require_module_scope_v145(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.require_module_scope_v145(uuid, uuid, text)
  to authenticated;

-- Staff performance already reads this finance-authorized projection in complete pages.
-- Expose the immutable revenue-policy snapshot from the same sale row so gift-card
-- issuance and every other non-revenue ledger row remain visible for traceability but
-- can never inflate the attributed revenue column.
create or replace view public.sale_commission
with (security_invoker = on) as
select sale.id as sale_id,
       sale.business_id,
       sale.branch_id,
       sale.staff_id,
       sale.kind,
       sale.occurred_at,
       sale.amount_cents,
       sale.commission_rate_bps as rate_bps,
       case
         when sale.commission_flat_cents is not null then
           case
             when sale.reversal_of is not null and sale.amount_cents < 0 then
               -sale.commission_flat_cents
             else sale.commission_flat_cents
           end
         when sale.reversal_of is not null and sale.amount_cents < 0 then
           -floor(((-sale.amount_cents)::numeric * sale.commission_rate_bps::numeric) / 10000)::integer
         else
           floor((sale.amount_cents::numeric * sale.commission_rate_bps::numeric) / 10000)::integer
       end as commission_cents,
       sale.commission_flat_cents as flat_cents,
       sale.counts_as_revenue
  from public.sales sale
 where app.has_perm(sale.business_id, 'view_finance')
   and app.can_see_branch(sale.business_id, sale.branch_id);

revoke all on public.sale_commission from anon;
grant select on public.sale_commission to authenticated;

-- Keep the existing customer directory and CSV workflow, but make its balance columns
-- agree with Customer 360. Expired batches and disabled/unpublished programmes are not
-- spendable points; signed corrective credit can never become negative spendable credit.
-- One bounded server page carries both profile and balance facts, avoiding browser N+1
-- reads and never replacing unavailable Loyalty authority with plausible zero values.
create or replace function public.staff_list_customers_v129(
  p_business uuid,
  p_search text default null,
  p_inactive_days integer default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_as_of timestamptz := statement_timestamp();
  v_search text := lower(btrim(coalesce(p_search, '')));
  v_phone_search text := regexp_replace(coalesce(p_search, ''), '[^0-9]', '', 'g');
  v_cutoff_date date;
  v_loyalty_available boolean;
  v_program_enabled boolean;
  v_result jsonb;
begin
  if length(v_phone_search) = 10 and left(v_phone_search, 2) = '65' then
    v_phone_search := right(v_phone_search, 8);
  end if;
  if auth.uid() is null or not app.can_module_read(p_business, 'clients') then
    raise exception 'customer read access required' using errcode = '42501';
  end if;
  if p_inactive_days is not null and p_inactive_days not in (30, 60, 90) then
    raise exception 'inactive days must be 30, 60 or 90' using errcode = '22023';
  end if;
  if p_limit < 1 or p_limit > 100 then
    raise exception 'limit must be between 1 and 100' using errcode = '22023';
  end if;
  if p_offset < 0 or p_offset > 100000 then
    raise exception 'offset must be between 0 and 100000' using errcode = '22023';
  end if;

  v_cutoff_date := (v_as_of at time zone 'Asia/Singapore')::date - p_inactive_days;
  v_loyalty_available := app.metric_module_scope_available_v145(
    p_business, null, 'loyalty'
  );
  select exists (
    select 1
      from public.loyalty_programs program
     where program.business_id = p_business
       and coalesce(program.active, false)
       and program.configuration_status = 'published'
  ) into v_program_enabled;

  with visit_facts as materialized (
    select sale.client_id, max(sale.occurred_at) as last_visit_at
      from public.sales sale
     where sale.business_id = p_business
       and sale.client_id is not null
       and sale.counts_as_visit
       and sale.reversal_of is null
       and sale.occurred_at <= v_as_of
       and not exists (
         select 1 from public.sales reversal
          where reversal.business_id = sale.business_id
            and reversal.reversal_of = sale.id
            and reversal.created_at <= v_as_of
       )
     group by sale.client_id
  ), customer_rows as materialized (
    select customer.id, customer.full_name, customer.phone, customer.email,
      customer.birth_date, customer.marketing_consent, customer.created_at,
      visit.last_visit_at,
      case when visit.last_visit_at is null then null
        else ((v_as_of at time zone 'Asia/Singapore')::date -
          (visit.last_visit_at at time zone 'Asia/Singapore')::date)::integer
      end as days_since_last_visit
      from public.clients customer
      left join visit_facts visit on visit.client_id = customer.id
     where customer.business_id = p_business
       and (
         v_search = ''
         or position(v_search in lower(customer.full_name)) > 0
         or (length(v_phone_search) >= 4 and
           position(v_phone_search in coalesce(customer.phone_norm, '')) > 0)
       )
       and (
         p_inactive_days is null
         or visit.last_visit_at is null
         or (visit.last_visit_at at time zone 'Asia/Singapore')::date <= v_cutoff_date
       )
  ), page as materialized (
    select * from customer_rows customer
     order by
       case when p_inactive_days is not null and customer.last_visit_at is null then 0 else 1 end,
       case when p_inactive_days is not null then customer.last_visit_at end asc nulls first,
       case when p_inactive_days is null then customer.created_at end desc,
       customer.full_name, customer.id
     limit p_limit offset p_offset
  ), page_ledger as materialized (
    select ledger.client_id,
           greatest(coalesce(sum(ledger.points), 0), 0)::bigint as units
      from public.points_ledger ledger
      join page customer on customer.id = ledger.client_id
     where ledger.business_id = p_business
     group by ledger.client_id
  ), page_batches as materialized (
    select batch.client_id,
           greatest(coalesce(sum(batch.remaining), 0), 0)::bigint as units
      from public.points_batches batch
      join page customer on customer.id = batch.client_id
     where batch.business_id = p_business
       and batch.remaining > 0
       and (batch.expires_at is null or batch.expires_at > v_as_of)
     group by batch.client_id
  ), page_credit as materialized (
    select ledger.client_id,
           greatest(coalesce(sum(ledger.amount_cents), 0), 0)::bigint as balance_cents
      from public.credit_ledger ledger
      join page customer on customer.id = ledger.client_id
     where ledger.business_id = p_business
     group by ledger.client_id
  ), page_balances as materialized (
    select customer.*,
      case
        when not v_loyalty_available then null::bigint
        when not v_program_enabled then 0::bigint
        else least(coalesce(points.units, 0), coalesce(batches.units, 0))
      end as points,
      case when v_loyalty_available
        then coalesce(credit.balance_cents, 0)
        else null::bigint
      end as balance_cents
      from page customer
      left join page_ledger points on points.client_id = customer.id
      left join page_batches batches on batches.client_id = customer.id
      left join page_credit credit on credit.client_id = customer.id
  )
  select jsonb_build_object(
    'status', 'ok',
    'as_of', v_as_of,
    'inactive_days', p_inactive_days,
    'loyalty_available', v_loyalty_available,
    'loyalty_program_enabled', v_program_enabled,
    'total', (select count(*) from customer_rows),
    'customers', coalesce((select jsonb_agg(jsonb_build_object(
      'id', customer.id,
      'full_name', customer.full_name,
      'phone', customer.phone,
      'email', customer.email,
      'birth_date', customer.birth_date,
      'marketing_consent', customer.marketing_consent,
      'created_at', customer.created_at,
      'last_visit_at', customer.last_visit_at,
      'days_since_last_visit', customer.days_since_last_visit,
      'points', customer.points,
      'balance_cents', customer.balance_cents
    ) order by
      case when p_inactive_days is not null and customer.last_visit_at is null then 0 else 1 end,
      case when p_inactive_days is not null then customer.last_visit_at end asc nulls first,
      case when p_inactive_days is null then customer.created_at end desc,
      customer.full_name, customer.id) from page_balances customer), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.staff_list_customers_v129(uuid, text, integer, integer, integer) is
  'Lists a bounded customer page with valid last-visit facts and V145 actionable/nonnegative loyalty balances; an unavailable complete Loyalty scope returns null balance fields rather than inferred zero.';

revoke all on function public.staff_list_customers_v129(uuid, text, integer, integer, integer)
  from public, anon, authenticated;
grant execute on function public.staff_list_customers_v129(uuid, text, integer, integer, integer)
  to authenticated;

-- Customer 360 used to infer spendable points, expiry and reward readiness from
-- several independently read browser tables. That could advertise an expired or
-- usage-limited reward, expose a negative "spendable" credit, or turn a failed read
-- into a plausible zero. Keep the existing Customer 360 workflow, but project its
-- actionable loyalty facts atomically from the ledgers and currently published
-- configuration. Generic profile context has no service/product selection, so a
-- restricted catalogue reward is intentionally omitted rather than called ready.
create or replace function public.staff_get_customer_actionable_loyalty_v145(
  p_business uuid,
  p_client uuid,
  p_branch uuid default null::uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_as_of timestamptz := statement_timestamp();
  v_result jsonb;
begin
  perform public.require_module_scope_v145(
    p_business, p_branch, 'clients'
  );
  perform public.require_module_scope_v145(
    p_business, p_branch, 'loyalty'
  );
  if not exists (
    select 1
      from public.clients client
     where client.id = p_client
       and client.business_id = p_business
  ) then
    raise exception 'customer not found in business'
      using errcode = '22023';
  end if;

  with program as (
    select
      loyalty.id,
      loyalty.kind,
      loyalty.loyalty_model,
      loyalty.earn_points_per_dollar,
      loyalty.redeem_points,
      loyalty.reward_credit_cents,
      loyalty.stamp_per_cents,
      loyalty.expiry_mode,
      loyalty.configuration_status,
      coalesce(loyalty.active, false)
        and loyalty.configuration_status = 'published' as enabled,
      business.active_config_version_id
    from public.businesses business
    left join public.loyalty_programs loyalty
      on loyalty.business_id = business.id
    where business.id = p_business
  ), ledger_balance as (
    select greatest(coalesce(sum(ledger.points), 0), 0)::integer as units
      from public.points_ledger ledger
     where ledger.business_id = p_business
       and ledger.client_id = p_client
  ), unexpired_batches as (
    select
      batch.id,
      batch.remaining,
      batch.earned_at,
      batch.expires_at,
      sum(batch.remaining) over (
        order by batch.expires_at nulls last, batch.earned_at, batch.id
        rows between unbounded preceding and current row
      )::bigint as cumulative_remaining
      from public.points_batches batch
     where batch.business_id = p_business
       and batch.client_id = p_client
       and batch.remaining > 0
       and (batch.expires_at is null or batch.expires_at > v_as_of)
  ), batch_balance as (
    select coalesce(sum(batch.remaining), 0)::integer as units
      from unexpired_batches batch
  ), loyalty_balance as (
    select case when program.enabled
      then greatest(least(ledger_balance.units, batch_balance.units), 0)
      else 0 end::integer as units
      from program cross join ledger_balance cross join batch_balance
  ), actionable_batches as (
    select
      batch.expires_at,
      least(
        batch.remaining::bigint,
        greatest(
          loyalty_balance.units::bigint
            - (batch.cumulative_remaining - batch.remaining::bigint),
          0
        )
      )::integer as actionable_remaining
      from unexpired_batches batch
      cross join loyalty_balance
     where loyalty_balance.units > 0
       and batch.cumulative_remaining - batch.remaining::bigint
           < loyalty_balance.units::bigint
  ), next_expiry as (
    select batch.expires_at,
           sum(batch.actionable_remaining)::integer as units
      from actionable_batches batch
     where batch.expires_at is not null
       and batch.actionable_remaining > 0
     group by batch.expires_at
     order by batch.expires_at
     limit 1
  ), credit_balance as (
    select greatest(coalesce(sum(ledger.amount_cents), 0), 0)::integer
      as balance_cents
      from public.credit_ledger ledger
     where ledger.business_id = p_business
       and ledger.client_id = p_client
  ), redemption_capability as (
    select (
      program.enabled
      and app.platform_feature_enabled('customer_qr_redemption')
      and coalesce(capability.redemption_enabled, false)
    ) as enabled
    from program
    left join public.business_customer_capabilities_v89 capability
      on capability.business_id = p_business
  ), candidate_rewards as (
    select
      'classic'::text as source,
      null::uuid as reward_id,
      concat(
        'SGD ',
        (program.reward_credit_cents::numeric / 100)::numeric(12,2),
        ' credit'
      )::text as name,
      program.redeem_points::integer as cost_units,
      program.reward_credit_cents::integer as credit_cents,
      'credit'::text as fulfillment_kind,
      0::integer as sort_order,
      greatest(program.redeem_points - loyalty_balance.units, 0)::integer
        as remaining_units,
      (redemption_capability.enabled
        and loyalty_balance.units >= program.redeem_points) as available_now
    from program
    cross join loyalty_balance
    cross join redemption_capability
    where program.enabled
      and program.loyalty_model = 'classic'
      and program.kind = 'points'
      and program.redeem_points > 0
      and program.reward_credit_cents > 0

    union all

    select
      'catalog'::text as source,
      reward_version.reward_id,
      reward_version.customer_name as name,
      reward_version.cost_points::integer as cost_units,
      reward_version.credit_cents::integer,
      reward_version.fulfillment_kind,
      reward_version.sort::integer as sort_order,
      greatest(reward_version.cost_points - loyalty_balance.units, 0)::integer
        as remaining_units,
      (redemption_capability.enabled
        and loyalty_balance.units >= reward_version.cost_points) as available_now
    from program
    cross join loyalty_balance
    cross join redemption_capability
    join public.loyalty_reward_versions reward_version
      on reward_version.business_id = p_business
     and reward_version.config_version_id = program.active_config_version_id
     and reward_version.active
    join public.loyalty_rewards reward
      on reward.id = reward_version.reward_id
     and reward.business_id = reward_version.business_id
     and reward.active
    left join lateral (
      select count(*)::integer as used_count
        from public.loyalty_redemptions redemption
       where redemption.business_id = p_business
         and redemption.client_id = p_client
         and redemption.reward_id = reward_version.reward_id
    ) usage on true
    where program.enabled
      and program.loyalty_model <> 'classic'
      and (reward_version.claim_available_from is null
        or reward_version.claim_available_from <= v_as_of)
      and (reward_version.claim_available_until is null
        or reward_version.claim_available_until > v_as_of)
      and (reward_version.usage_limit is null
        or usage.used_count < reward_version.usage_limit)
      and not exists (
        select 1 from public.loyalty_reward_branches restriction
         where restriction.reward_version_id = reward_version.id
      )
      and not exists (
        select 1 from public.loyalty_reward_services restriction
         where restriction.reward_version_id = reward_version.id
      )
      and not exists (
        select 1 from public.loyalty_reward_products restriction
         where restriction.reward_version_id = reward_version.id
      )
  ), reward_list as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'source', candidate.source,
      'reward_id', candidate.reward_id,
      'name', candidate.name,
      'cost_units', candidate.cost_units,
      'credit_cents', candidate.credit_cents,
      'fulfillment_kind', candidate.fulfillment_kind,
      'remaining_units', candidate.remaining_units,
      'available_now', candidate.available_now
    ) order by candidate.remaining_units, candidate.sort_order,
      lower(candidate.name), candidate.reward_id nulls first), '[]'::jsonb)
      as rewards
      from candidate_rewards candidate
  ), next_reward as (
    select jsonb_build_object(
      'source', candidate.source,
      'reward_id', candidate.reward_id,
      'name', candidate.name,
      'cost_units', candidate.cost_units,
      'credit_cents', candidate.credit_cents,
      'fulfillment_kind', candidate.fulfillment_kind,
      'remaining_units', candidate.remaining_units,
      'available_now', candidate.available_now
    ) as reward
    from candidate_rewards candidate
    order by candidate.remaining_units, candidate.sort_order,
      lower(candidate.name), candidate.reward_id nulls first
    limit 1
  )
  select jsonb_build_object(
    'as_of', v_as_of,
    'program', case when program.id is null then null else jsonb_build_object(
      'id', program.id,
      'active', program.enabled,
      'kind', program.kind,
      'model', program.loyalty_model,
      'unit', case when program.loyalty_model = 'stamps'
        then 'stamps' else 'points' end,
      'earn_points_per_dollar', program.earn_points_per_dollar,
      'stamp_per_cents', program.stamp_per_cents,
      'redeem_points', program.redeem_points,
      'reward_credit_cents', program.reward_credit_cents,
      'expiry_mode', program.expiry_mode,
      'configuration_status', program.configuration_status
    ) end,
    'points_balance', loyalty_balance.units,
    'credit_balance_cents', credit_balance.balance_cents,
    'expiry', case
      when not program.enabled or program.expiry_mode = 'none'
        or next_expiry.expires_at is null then null
      else jsonb_build_object(
        'expires_at', next_expiry.expires_at,
        'units', next_expiry.units
      ) end,
    'redemption_enabled', redemption_capability.enabled,
    'rewards', reward_list.rewards,
    'next_reward', next_reward.reward
  ) into v_result
  from program
  cross join loyalty_balance
  cross join credit_balance
  cross join redemption_capability
  cross join reward_list
  left join next_expiry on true
  left join next_reward on true;

  return v_result;
end;
$$;

revoke all on function public.staff_get_customer_actionable_loyalty_v145(
  uuid, uuid, uuid
) from public, anon, authenticated;
grant execute on function public.staff_get_customer_actionable_loyalty_v145(
  uuid, uuid, uuid
) to authenticated;

-- V49b deliberately exposes only the current business-wide gift-card liability scalar,
-- never card or customer rows. Align its authorization with the branch-effective V94
-- Reports boundary so a branch explicitly enabled over a disabled firm remains usable,
-- while an all-branch request still requires complete Reports coverage.
create or replace function app.reports_gift_card_liability_v49b(
  p_business uuid,
  p_branch uuid default null::uuid
)
returns bigint
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_liability bigint;
begin
  if auth.uid() is null
     or not app.has_perm(p_business, 'view_sales')
     or not app.metric_module_scope_available_v145(p_business, p_branch, 'reports')
     or not app.metric_module_scope_available_v145(p_business, null, 'giftcards') then
    raise exception 'active Reports read authorization is required'
      using errcode = '42501';
  end if;

  -- Gift cards have no branch attribution. The scalar is intentionally business-wide
  -- after complete branch-effective Reports authorization has been proven above.
  select coalesce(sum(card.balance_cents) filter (where card.status = 'active'), 0)::bigint
    into v_liability
    from public.gift_cards card
   where card.business_id = p_business;
  return coalesce(v_liability, 0);
end
$$;

revoke all privileges on function app.reports_gift_card_liability_v49b(uuid,uuid)
  from public, anon, authenticated;
grant execute on function app.reports_gift_card_liability_v49b(uuid,uuid)
  to authenticated;

-- Dashboard contract:
--   * revenue remains an additive signed ledger flow in the selected SG date/branch scope;
--   * a visit is an original counts_as_visit sale with no compensating reversal anywhere;
--   * identified-customer count is derived only from those valid visits;
--   * mixed business-wide/current values are returned with explicit machine-readable scope.
create or replace function public.get_dashboard_summary(
  p_business uuid,
  p_from date,
  p_to date,
  p_branch uuid default null::uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_kpis jsonb;
  v_weekdays jsonb;
  v_revenue_by_day jsonb;
  v_gender jsonb;
  v_age jsonb;
  v_sales_available boolean;
  v_clients_available boolean;
  v_loyalty_available boolean;
  v_credit_liability_available boolean;
begin
  if auth.uid() is null
     or not app.has_perm(p_business, 'view_sales') then
    raise exception 'you do not have permission to view this dashboard'
      using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'a valid report date range is required'
      using errcode = '22007';
  end if;
  if p_to - p_from > 1826 then
    raise exception 'report date range cannot exceed 1827 days'
      using errcode = '22023';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches b
    where b.id = p_branch and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to this business'
      using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'you are not permitted to view this branch scope'
      using errcode = '42501';
  end if;

  v_sales_available := app.metric_module_scope_available_v145(
    p_business, p_branch, 'sales'
  );
  v_clients_available := app.metric_module_scope_available_v145(
    p_business, null, 'clients'
  );
  v_loyalty_available := app.metric_module_scope_available_v145(
    p_business, p_branch, 'loyalty'
  );
  v_credit_liability_available := app.metric_module_scope_available_v145(
    p_business, null, 'sales'
  );
  if not v_sales_available then
    return jsonb_build_object(
      'availability', jsonb_build_object(
        'sales', false,
        'clients', false,
        'loyalty', false,
        'credit_liability', false
      ),
      'scope', jsonb_build_object(
        'timezone', 'Asia/Singapore',
        'from', p_from,
        'to', p_to,
        'branch_id', p_branch,
        'status', 'unavailable_incomplete_sales_scope'
      )
    );
  end if;

  with scoped_sales as (
    select s.*
    from public.sales s
    where s.business_id = p_business
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
  ), valid_visits as (
    select s.*
    from scoped_sales s
    where s.counts_as_visit
      and s.reversal_of is null
      and not exists (
        select 1
        from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  )
  select jsonb_build_object(
    'visits', (select count(*) from valid_visits),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue), 0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null)
  )
  into v_kpis;

  v_kpis := v_kpis || jsonb_build_object(
    'new_customers', case when v_clients_available then (
      select count(*) from public.clients c
      where c.business_id = p_business
        and c.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and c.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    ) else null end,
    'points_issued', case when v_loyalty_available then (
      select coalesce(sum(pl.points), 0)
      from public.points_ledger pl
      left join public.sales ps
        on ps.id = pl.sale_id
       and ps.business_id = pl.business_id
      where pl.business_id = p_business
        and pl.entry_type = 'earn'
        and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
        and (p_branch is null or ps.branch_id = p_branch)
    ) else null end,
    'credit_liability_cents', case when v_credit_liability_available then (
      select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
      from public.client_credit_balance cb
      where cb.business_id = p_business
    ) else null end
  );

  with valid_visits as (
    select s.*
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not exists (
        select 1
        from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  )
  select coalesce(jsonb_agg(coalesce(w.visits, 0) order by d.day_no), '[]'::jsonb)
  into v_weekdays
  from generate_series(1, 7) d(day_no)
  left join (
    select extract(isodow from s.occurred_at at time zone 'Asia/Singapore')::int as day_no,
           count(*) as visits
    from valid_visits s
    group by 1
  ) w using (day_no);

  select coalesce(
    jsonb_agg(jsonb_build_object(
      'day', d.sale_day,
      'amount_cents', coalesce(r.amount_cents, 0)
    ) order by d.sale_day),
    '[]'::jsonb)
  into v_revenue_by_day
  from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d0(day_value)
  cross join lateral (select d0.day_value::date as sale_day) d
  left join (
    select (s.occurred_at at time zone 'Asia/Singapore')::date as sale_day,
           sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
    group by 1
  ) r using (sale_day);

  if v_clients_available then
  select jsonb_build_object(
    'female', count(*) filter (where c.gender = 'female'),
    'male', count(*) filter (where c.gender = 'male'),
    'other', count(*) filter (where c.gender = 'other'),
    'unknown', count(*) filter (where c.gender is null)
  )
  into v_gender
  from public.clients c
  where c.business_id = p_business;

  select jsonb_build_object(
    'under_25', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) < 25),
    'age_25_34', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 25 and 34),
    'age_35_44', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 35 and 44),
    'age_45_54', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 45 and 54),
    'age_55_plus', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) >= 55),
    'unknown', count(*) filter (where c.birth_date is null)
  )
  into v_age
  from public.clients c
  where c.business_id = p_business;
  else
    v_gender := null;
    v_age := null;
  end if;

  return v_kpis || jsonb_build_object(
    'visits_by_weekday', v_weekdays,
    'revenue_by_day', v_revenue_by_day,
    'gender_counts', v_gender,
    'age_counts', v_age,
    'availability', jsonb_build_object(
      'sales', true,
      'clients', v_clients_available,
      'loyalty', v_loyalty_available,
      'credit_liability', v_credit_liability_available
    ),
    'scope', jsonb_build_object(
      'timezone', 'Asia/Singapore',
      'from', p_from,
      'to', p_to,
      'branch_id', p_branch,
      'visits', 'selected_period_and_branch_valid_originals',
      'revenue', 'selected_period_and_branch_signed_ledger',
      'unique_customers', 'selected_period_and_branch_customer_records_with_valid_visits',
      'new_customers', case when v_clients_available then 'business_wide_records_added_in_selected_period' else 'unavailable_without_complete_clients_scope' end,
      'points_issued', case
        when not v_loyalty_available then 'unavailable_without_complete_loyalty_scope'
        when p_branch is null then 'business_wide_gross_earn_in_selected_period'
        else 'selected_branch_sale_linked_gross_earn_in_selected_period'
      end,
      'credit_liability', case when v_credit_liability_available
        then 'business_wide_current_signed_credit_ledger_with_complete_business_sales_read'
        else 'unavailable_without_complete_business_sales_scope' end,
      'age_counts', case when v_clients_available then 'business_wide_current' else 'unavailable_without_complete_clients_scope' end
    )
  );
end;
$$;

-- Reports keeps its existing calculations but exposes their differing scopes explicitly.
create or replace function public.get_reports_summary(
  p_business uuid,
  p_from date,
  p_to date,
  p_branch uuid default null::uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_revenue jsonb;
  v_non_revenue jsonb;
  v_points jsonb;
  v_credit_liability bigint;
  v_gift_card_liability bigint;
  v_active_memberships bigint;
  v_compensating_rows bigint;
  v_reversed_revenue_cents bigint;
  v_net_revenue_cents bigint;
  v_sales_export_available boolean;
  v_clients_export_available boolean;
  v_loyalty_available boolean;
  v_gift_cards_available boolean;
  v_memberships_available boolean;
  v_credit_liability_available boolean;
begin
  if auth.uid() is null
     or not app.has_perm(p_business, 'view_sales') then
    raise exception 'you do not have permission to view reports for this business'
      using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'a valid report date range is required'
      using errcode = '22007';
  end if;
  if p_to - p_from > 1826 then
    raise exception 'report date range cannot exceed 1827 days'
      using errcode = '22023';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches b
    where b.id = p_branch and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to this business'
      using errcode = '42501';
  end if;

  -- Every money/reversal field below is derived from Sales. Reports mode alone is not
  -- sufficient because a branch-level Sales override may intentionally make that
  -- source unreadable. A SECURITY DEFINER aggregate must fail closed for the exact
  -- selected scope rather than return a plausible complete total from hidden rows.
  perform app.require_metric_module_scope_v145(
    p_business, p_branch, 'reports'
  );
  if not app.platform_metric_source_scope_available_v145(
    p_business, p_branch, 'sales'
  ) then
    raise exception 'complete_metric_source_scope_required:sales'
      using errcode = '42501';
  end if;

  v_sales_export_available := app.metric_module_scope_available_v145(
    p_business, p_branch, 'sales'
  );
  v_clients_export_available := app.metric_module_scope_available_v145(
    p_business, p_branch, 'clients'
  );
  v_loyalty_available := app.metric_module_scope_available_v145(
    p_business, null, 'loyalty'
  );
  v_gift_cards_available := app.metric_module_scope_available_v145(
    p_business, null, 'giftcards'
  );
  v_memberships_available := app.metric_module_scope_available_v145(
    p_business, null, 'memberships'
  );
  v_credit_liability_available := app.metric_module_scope_available_v145(
    p_business, null, 'reports'
  ) and app.platform_metric_source_scope_available_v145(
    p_business, null, 'sales'
  );
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'you are not permitted to view this branch scope'
      using errcode = '42501';
  end if;
  -- Preserve the V94 branch-effective Reports boundary. A branch override may
  -- intentionally differ from the firm mode, and an all-branch report must not
  -- consolidate a branch the caller cannot see or where Reports is disabled.
  if p_branch is not null then
    perform app.require_branch_module_v94(p_business, p_branch, 'reports', 'r');
  elsif not app.is_super_admin() then
    if not app.can_module_read_at_v94(p_business, null, 'reports') then
      raise exception 'branch_module_access_required:reports:r'
        using errcode = '42501';
    end if;
    if exists (
      select 1
      from public.branches branch
      where branch.business_id = p_business
        and (
          not app.can_see_branch(p_business, branch.id)
          or not case when branch.active
            then app.can_module_read_at_v94(p_business, branch.id, 'reports')
            else app.can_module_read_at_v94(p_business, null, 'reports')
          end
        )
    ) then
      raise exception 'explicit_branch_required_for_partial_report_scope'
        using errcode = '42501';
    end if;
  end if;

  select coalesce(jsonb_object_agg(x.kind, x.amount_cents), '{}'::jsonb)
  into v_revenue
  from (
    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
    group by s.kind
  ) x;

  select
    count(*) filter (where s.reversal_of is not null),
    coalesce(sum(-s.amount_cents) filter (
      where s.counts_as_revenue
        and s.reversal_of is not null
        and s.amount_cents < 0
    ), 0),
    coalesce(sum(s.amount_cents) filter (where s.counts_as_revenue), 0)
  into v_compensating_rows, v_reversed_revenue_cents, v_net_revenue_cents
  from public.sales s
  where s.business_id = p_business
    and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
    and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    and (p_branch is null or s.branch_id = p_branch);

  select coalesce(jsonb_object_agg(x.kind, x.amount_cents), '{}'::jsonb)
  into v_non_revenue
  from (
    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and not s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
    group by s.kind
  ) x;

  if v_loyalty_available then
    select coalesce(jsonb_object_agg(x.entry_type, x.points), '{}'::jsonb)
    into v_points
    from (
      select pl.entry_type, sum(pl.points) as points
      from public.points_ledger pl
      where pl.business_id = p_business
        and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      group by pl.entry_type
    ) x;
  else
    v_points := null;
  end if;

  if v_credit_liability_available then
    select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
      into v_credit_liability
      from public.client_credit_balance cb
     where cb.business_id = p_business;
  else
    v_credit_liability := null;
  end if;

  if v_gift_cards_available then
    v_gift_card_liability := app.reports_gift_card_liability_v49b(
      p_business, p_branch
    );
  else
    v_gift_card_liability := null;
  end if;

  if v_memberships_available then
    select count(*) filter (where m.status = 'active')
    into v_active_memberships
    from public.memberships m
    where m.business_id = p_business;
  else
    v_active_memberships := null;
  end if;

  return jsonb_build_object(
    'revenue_by_kind', v_revenue,
    'non_revenue_by_kind', v_non_revenue,
    'points_by_type', v_points,
    'credit_liability_cents', v_credit_liability,
    'gift_card_liability_cents', v_gift_card_liability,
    'active_memberships', v_active_memberships,
    'reversal_reconciliation', jsonb_build_object(
      'compensating_rows', v_compensating_rows,
      'reversed_revenue_cents', v_reversed_revenue_cents,
      'net_revenue_cents', v_net_revenue_cents
    ),
    'availability', jsonb_build_object(
      'sales_export', v_sales_export_available,
      'clients_export', v_clients_export_available,
      'loyalty', v_loyalty_available,
      'gift_cards', v_gift_cards_available,
      'memberships', v_memberships_available,
      'credit_liability', v_credit_liability_available
    ),
    'scope', jsonb_build_object(
      'timezone', 'Asia/Singapore',
      'from', p_from,
      'to', p_to,
      'branch_id', p_branch,
      'sales', 'selected_period_and_branch_signed_ledger',
      'points', case when v_loyalty_available
        then 'business_wide_selected_period'
        else 'unavailable_without_complete_loyalty_scope' end,
      'credit_liability', case when v_credit_liability_available
        then 'business_wide_current_with_complete_business_reports_and_sales_source_scope'
        else 'unavailable_without_complete_business_reports_and_sales_source_scope' end,
      'gift_card_liability', case when v_gift_cards_available
        then 'business_wide_current' else 'unavailable_without_complete_giftcards_scope' end,
      'active_memberships', case when v_memberships_available
        then 'business_wide_current'
        else 'unavailable_without_complete_memberships_scope' end
    )
  );
end;
$$;

-- Existing P&L summary now owns its chart aggregates. This removes Data API row-cap
-- truncation and applies one Singapore-time/base-currency formula to KPI, chart and CSV.
create or replace function public.get_revenue_summary(
  p_business uuid,
  p_from date,
  p_to date,
  p_branch uuid default null::uuid)
returns json
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_accrual bigint;
  v_cash bigint;
  v_sv_cash bigint;
  v_expenses bigint;
  v_unpaid bigint;
  v_collected bigint;
  v_from_ts timestamptz;
  v_to_ts timestamptz;
  v_expenses_by_category jsonb;
  v_monthly jsonb;
begin
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'p_from and p_to are required and p_from must be on or before p_to'
      using errcode = '22007';
  end if;
  if p_to - p_from > 1826 then
    raise exception 'report date range cannot exceed 1827 days'
      using errcode = '22023';
  end if;

  if not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to view finance for this business (view_finance)'
      using errcode = '42501';
  end if;

  if p_branch is not null and not exists (
    select 1
      from public.branches b
     where b.id = p_branch
       and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to this business';
  end if;

  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'you are not permitted to view this branch scope for this business (branch_visibility)'
      using errcode = '42501';
  end if;

  perform app.require_metric_module_scope_v145(p_business, p_branch, 'pnl');
  perform app.require_metric_module_scope_v145(p_business, p_branch, 'sales');
  perform app.require_metric_module_scope_v145(p_business, p_branch, 'expenses');

  v_from_ts := p_from::timestamp at time zone 'Asia/Singapore';
  v_to_ts := (p_to + 1)::timestamp at time zone 'Asia/Singapore';

  select coalesce(sum(s.amount_cents), 0)
    into v_accrual
    from public.sales s
   where s.business_id = p_business
     and s.counts_as_revenue
     and s.occurred_at >= v_from_ts
     and s.occurred_at < v_to_ts
     and (p_branch is null or s.branch_id = p_branch);

  select coalesce(sum(p.amount_cents), 0)
    into v_cash
    from public.payments p
    join public.sales s
      on s.business_id = p.business_id
     and s.reversal_of is null
     and (
       s.id = p.sale_id
       or (
         p.sale_id is null
         and p.appointment_id is not null
         and s.appointment_id = p.appointment_id
       )
     )
   where p.business_id = p_business
     and s.counts_as_revenue
     and p.occurred_at >= v_from_ts
     and p.occurred_at < v_to_ts
     and (p_branch is null or p.branch_id = p_branch);

  select coalesce(sum(t.reserved_cents), 0)
    into v_sv_cash
    from public.checkout_sv_tenders t
    join public.sales s
      on s.business_id = t.business_id
     and s.id = t.sale_id
     and s.reversal_of is null
   where t.business_id = p_business
     and t.status = 'consumed'
     and not exists (
       select 1 from public.checkout_sv_tender_reversals rv
        where rv.business_id = t.business_id and rv.tender_id = t.id)
     and s.counts_as_revenue
     and s.occurred_at >= v_from_ts
     and s.occurred_at < v_to_ts
     and (p_branch is null or s.branch_id = p_branch);
  v_cash := v_cash + v_sv_cash;

  select coalesce(sum(p.amount_cents), 0)
    into v_collected
    from public.payments p
   where p.business_id = p_business
     and p.method not in ('credit', 'gift_card')
     and p.occurred_at >= v_from_ts
     and p.occurred_at < v_to_ts
     and (p_branch is null or p.branch_id = p_branch);

  select coalesce(sum(b.balance_cents), 0)
    into v_unpaid
    from public.sale_balance b
   where b.business_id = p_business
     and b.counts_as_revenue
     and b.balance_cents > 0
     and b.occurred_at >= v_from_ts
     and b.occurred_at < v_to_ts
     and (p_branch is null or b.branch_id = p_branch);

  select coalesce(sum(round(e.amount_cents::numeric * e.fx_rate_to_base::numeric)), 0)::bigint
    into v_expenses
    from public.expenses e
   where e.business_id = p_business
     and e.voided_at is null
     and e.occurred_on between p_from and p_to
     and (p_branch is null or e.branch_id = p_branch);

  select coalesce(jsonb_object_agg(x.category, x.amount_cents order by x.category), '{}'::jsonb)
    into v_expenses_by_category
    from (
      select coalesce(nullif(btrim(e.category), ''), 'Uncategorised') as category,
             sum(round(e.amount_cents::numeric * e.fx_rate_to_base::numeric))::bigint as amount_cents
      from public.expenses e
      where e.business_id = p_business
        and e.voided_at is null
        and e.occurred_on between p_from and p_to
        and (p_branch is null or e.branch_id = p_branch)
      group by coalesce(nullif(btrim(e.category), ''), 'Uncategorised')
    ) x;

  with months as (
    select generate_series(
      date_trunc('month', p_from::timestamp),
      date_trunc('month', p_to::timestamp),
      interval '1 month'
    )::date as month_start
  ), revenue as (
    select date_trunc('month', s.occurred_at at time zone 'Asia/Singapore')::date as month_start,
           sum(s.amount_cents)::bigint as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= v_from_ts
      and s.occurred_at < v_to_ts
      and (p_branch is null or s.branch_id = p_branch)
    group by 1
  ), expense as (
    select date_trunc('month', e.occurred_on::timestamp)::date as month_start,
           sum(round(e.amount_cents::numeric * e.fx_rate_to_base::numeric))::bigint as amount_cents
    from public.expenses e
    where e.business_id = p_business
      and e.voided_at is null
      and e.occurred_on between p_from and p_to
      and (p_branch is null or e.branch_id = p_branch)
    group by 1
  )
  select coalesce(jsonb_object_agg(
    to_char(m.month_start, 'YYYY-MM'),
    jsonb_build_object(
      'revenue_accrual_cents', coalesce(r.amount_cents, 0),
      'expenses_cents', coalesce(e.amount_cents, 0)
    ) order by m.month_start
  ), '{}'::jsonb)
  into v_monthly
  from months m
  left join revenue r using (month_start)
  left join expense e using (month_start);

  return json_build_object(
    'from', p_from,
    'to', p_to,
    'branch_id', p_branch,
    'timezone', 'Asia/Singapore',
    'revenue_accrual_cents', v_accrual,
    'revenue_cash_cents', v_cash,
    'cash_collected_cents', v_collected,
    'unpaid_balance_cents', v_unpaid,
    'expenses_cents', v_expenses,
    'expenses_scope', case when p_branch is null
      then 'all_business_expenses'
      else 'selected_branch_expenses_only_business_wide_overhead_excluded'
    end,
    'business_wide_overhead_excluded', p_branch is not null,
    'net_accrual_cents', v_accrual - v_expenses,
    'net_cash_cents', v_cash - v_expenses,
    'expenses_by_category', v_expenses_by_category,
    'monthly', v_monthly
  );
end $$;

-- Complete, read-only redemption history for Customer 360. Reversal-action metadata
-- remains behind the v40 refund permission, but the immutable historical facts must be
-- available to every role that can read the complete Loyalty scope. The browser pages
-- this ordered projection, so no 100-row writer-RPC cap can hide older redemptions.
create or replace function public.list_customer_redemption_history_v145(
  p_business uuid,
  p_client uuid
)
returns table (
  id uuid,
  redeemed_at timestamptz,
  reward_name text,
  points_spent integer,
  credit_cents integer,
  fulfillment_kind text,
  reversal_id uuid,
  reversed_at timestamptz
)
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null
     or not app.has_perm(p_business, 'view_sales')
     or not app.can_module_read(p_business, 'loyalty') then
    raise exception 'active Loyalty read authorization is required'
      using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.clients client
     where client.id = p_client and client.business_id = p_business
  ) then
    raise exception 'customer not found in this business'
      using errcode = '42501';
  end if;

  return query
  select redemption.id,
         redemption.redeemed_at,
         redemption.reward_name,
         redemption.points_spent,
         redemption.credit_cents,
         redemption.fulfillment_kind,
         reversal.id,
         reversal.created_at
    from public.loyalty_redemptions redemption
    left join public.loyalty_redemption_reversals reversal
      on reversal.business_id = redemption.business_id
     and reversal.redemption_id = redemption.id
   where redemption.business_id = p_business
     and redemption.client_id = p_client
   order by redemption.redeemed_at desc, redemption.id desc;
end;
$$;

revoke all on function public.list_customer_redemption_history_v145(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.list_customer_redemption_history_v145(uuid, uuid)
  to authenticated;

-- A page-and-total projection for the existing service-recovery queue. This replaces
-- the misleading bounded queue reader on the Customers page without exposing any new
-- fields or workflow.
create or replace function public.staff_list_visit_feedback_v145(
  p_business uuid,
  p_status text default null,
  p_limit integer default 100,
  p_offset integer default 0,
  p_client uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_status text := nullif(btrim(lower(coalesce(p_status, ''))), '');
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_total bigint;
  v_items jsonb;
begin
  if v_actor is null or not app.can_module_read(p_business, 'clients') then
    raise exception 'active customers-module read authorization is required'
      using errcode = '42501';
  end if;
  select staff.id into v_staff
    from public.staff staff
   where staff.business_id = p_business
     and staff.user_id = v_actor
     and staff.active
   order by case when staff.role = 'owner' then 0 else 1 end,
            staff.created_at, staff.id
   limit 1;
  if not found then
    raise exception 'active staff authorization is required'
      using errcode = '42501';
  end if;
  if v_status is not null
     and v_status not in ('open', 'acknowledged', 'resolved', 'closed') then
    raise exception 'unsupported feedback status filter'
      using errcode = '22023';
  end if;
  if p_client is not null and not exists (
    select 1 from public.clients client
     where client.id = p_client and client.business_id = p_business
  ) then
    raise exception 'customer does not belong to this business'
      using errcode = '42501';
  end if;

  select count(*) into v_total
    from public.visit_feedback feedback
   where feedback.business_id = p_business
     and (v_status is null or feedback.recovery_status = v_status)
     and (p_client is null or feedback.client_id = p_client);

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', page.id,
    'client_id', page.client_id,
    'customer_name', page.full_name,
    'sale_id', page.sale_id,
    'rating', page.rating,
    'comment', page.comment,
    'recovery_status', page.recovery_status,
    'resolved_by', page.resolved_by,
    'resolved_at', page.resolved_at,
    'resolution_note', page.resolution_note,
    'created_at', page.created_at
  ) order by page.created_at desc, page.id desc), '[]'::jsonb)
    into v_items
    from (
      select feedback.id, feedback.client_id, client.full_name, feedback.sale_id,
             feedback.rating, feedback.comment, feedback.recovery_status,
             feedback.resolved_by, feedback.resolved_at, feedback.resolution_note,
             feedback.created_at
        from public.visit_feedback feedback
        left join public.clients client
          on client.id = feedback.client_id
         and client.business_id = feedback.business_id
       where feedback.business_id = p_business
         and (v_status is null or feedback.recovery_status = v_status)
         and (p_client is null or feedback.client_id = p_client)
       order by feedback.created_at desc, feedback.id desc
       limit v_limit offset v_offset
    ) page;

  return jsonb_build_object(
    'status', 'ok',
    'feedback', v_items,
    'total', v_total,
    'limit', v_limit,
    'offset', v_offset
  );
end;
$$;

revoke all on function public.staff_list_visit_feedback_v145(uuid, text, integer, integer, uuid)
  from public, anon, authenticated;
grant execute on function public.staff_list_visit_feedback_v145(uuid, text, integer, integer, uuid)
  to authenticated;

-- Complete paging for the existing gift-card ledger. Codes remain suffix-only, matching
-- the prior projection; this only removes the hidden 100-card ceiling.
create or replace function public.staff_list_gift_cards_v145(
  p_business uuid,
  p_limit integer default 100,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_total bigint;
  v_items jsonb;
begin
  if v_actor is null or not app.can_module_read(p_business, 'giftcards') then
    raise exception 'active giftcards-module read authorization is required'
      using errcode = '42501';
  end if;
  select staff.id into v_staff
    from public.staff staff
   where staff.business_id = p_business
     and staff.user_id = v_actor
     and staff.active
   order by case when staff.role = 'owner' then 0 else 1 end,
            staff.created_at, staff.id
   limit 1;
  if not found then
    raise exception 'active staff authorization is required'
      using errcode = '42501';
  end if;
  select count(*) into v_total
    from public.gift_cards card
   where card.business_id = p_business;
  select coalesce(jsonb_agg(jsonb_build_object(
    'gift_card_id', page.id,
    'code_suffix', right(page.code, 4),
    'initial_cents', page.initial_cents,
    'balance_cents', page.balance_cents,
    'status', page.status,
    'created_at', page.created_at
  ) order by page.created_at desc, page.id), '[]'::jsonb)
    into v_items
    from (
      select card.id, card.code, card.initial_cents, card.balance_cents,
             card.status, card.created_at
        from public.gift_cards card
       where card.business_id = p_business
       order by card.created_at desc, card.id
       limit v_limit offset v_offset
    ) page;
  return jsonb_build_object(
    'status', 'ok', 'cards', v_items, 'total', v_total,
    'limit', v_limit, 'offset', v_offset
  );
end;
$$;

revoke all on function public.staff_list_gift_cards_v145(uuid, integer, integer)
  from public, anon, authenticated;
grant execute on function public.staff_list_gift_cards_v145(uuid, integer, integer)
  to authenticated;

-- Customer 360 already owns the complete immutable sale and redemption history. Its
-- correction controls must cover that same complete history, not only the newest 100
-- rows. Preserve the bounded default for every operational list, but reserve p_limit=0
-- as an explicit unbounded customer-profile read. LIMIT NULL is PostgreSQL's unbounded
-- form; branch visibility and refund_sales authorization remain inside the original RPC.
do $v145_reversal_reader$
declare
  v_definition text;
  v_limit_source constant text :=
    'v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);';
  v_bounded_source constant text := '''bounded'', true,';
  v_more_source constant text := '''may_have_more'', v_sales_total > v_limit,';
begin
  v_definition := pg_get_functiondef(
    'public.staff_get_reversal_workflows(uuid,uuid,integer,text)'::regprocedure
  );
  if strpos(v_definition, v_limit_source) = 0
     or strpos(v_definition, v_bounded_source) = 0
     or strpos(v_definition, v_more_source) = 0 then
    raise exception 'V145 could not verify the V40 reversal reader definition';
  end if;
  v_definition := replace(
    v_definition,
    v_limit_source,
    'v_limit integer := case when p_limit = 0 then null else least(greatest(coalesce(p_limit, 50), 1), 100) end;'
  );
  v_definition := replace(
    v_definition,
    v_bounded_source,
    '''bounded'', v_limit is not null,'
  );
  v_definition := replace(
    v_definition,
    v_more_source,
    '''may_have_more'', case when v_limit is null then false else v_sales_total > v_limit end,'
  );
  execute v_definition;
end;
$v145_reversal_reader$;

-- Program Studio is frozen for launch. Keep the existing published-rule history and
-- safety pauses visible, but remove the unfinished advanced authoring write surface.
create or replace function public.save_program_rule_draft(
  p_config_version uuid,
  p_rule_id uuid,
  p_rule jsonb,
  p_expected_snapshot_hash text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_business uuid;
begin
  select version.business_id into v_business
    from public.firm_config_versions version
   where version.id = p_config_version;
  if v_business is null or not app.is_salon_owner(v_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  raise exception 'advanced rule authoring is unavailable for launch'
    using errcode = '55000';
end;
$$;

create or replace function public.delete_program_rule_draft(
  p_config_version uuid,
  p_rule_id uuid,
  p_expected_snapshot_hash text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_business uuid;
begin
  select version.business_id into v_business
    from public.firm_config_versions version
   where version.id = p_config_version;
  if v_business is null or not app.is_salon_owner(v_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  raise exception 'advanced rule authoring is unavailable for launch'
    using errcode = '55000';
end;
$$;

-- Server-authoritative 30-day baseline retained for historical Studio projections.
-- It uses every valid original sale, not a 1,000-row browser sample.
create or replace function public.get_studio_sales_baseline_v145(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_count bigint; v_average bigint;
begin
  if auth.uid() is null or not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  perform app.require_metric_module_scope_v145(p_business, null, 'sales');
  select count(*), coalesce(round(avg(sale.amount_cents)), 0)::bigint
    into v_count, v_average
    from public.sales sale
   where sale.business_id = p_business
     and sale.reversal_of is null
     and sale.counts_as_revenue
     and sale.occurred_at >= now() - interval '30 days'
     and not exists (
       select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
     );
  return jsonb_build_object(
    'available', true,
    'count30', v_count,
    'avg_bill_cents', coalesce(v_average, 0)
  );
end;
$$;

revoke all on function public.save_program_rule_draft(uuid, uuid, jsonb, text)
  from public, anon, authenticated;
revoke all on function public.delete_program_rule_draft(uuid, uuid, text)
  from public, anon, authenticated;
revoke all on function public.get_studio_sales_baseline_v145(uuid)
  from public, anon, authenticated;
grant execute on function public.save_program_rule_draft(uuid, uuid, jsonb, text)
  to authenticated;
grant execute on function public.delete_program_rule_draft(uuid, uuid, text)
  to authenticated;
grant execute on function public.get_studio_sales_baseline_v145(uuid)
  to authenticated;

-- An incomplete historical Studio rule remains visible for traceability, but cannot
-- run or be resumed during the launch freeze. Existing active incomplete rules receive
-- a reversible emergency pause; no historical rule or fulfilment record is deleted.
create or replace function app.v145_program_rule_activation_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if old.active is false and new.active is true and exists (
    select 1
      from jsonb_array_elements(coalesce(new.then_effects, '[]'::jsonb)) effect
     where app.ps1c2_effect_state(new.business_id, effect->>'effect_type') <> 'live'
  ) then
    raise exception 'incomplete advanced rule cannot be resumed for launch'
      using errcode = '55000';
  end if;
  return new;
end;
$$;

-- Publishing is also an activation boundary. A draft may have been authored before
-- the launch freeze, so an UPDATE-only rule guard is insufficient: promoting that
-- draft would otherwise compile and execute an active rule whose effect is not live.
create or replace function app.v145_config_publish_guard()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.status = 'published'
     and old.status is distinct from 'published'
     and exists (
       select 1
         from public.program_rules rule
         cross join lateral jsonb_array_elements(
           coalesce(rule.then_effects, '[]'::jsonb)
         ) effect
        where rule.config_version_id = new.id
          and rule.business_id = new.business_id
          and rule.active
          and app.ps1c2_effect_state(
            rule.business_id, effect->>'effect_type'
          ) <> 'live'
     ) then
    raise exception 'this draft contains an active advanced action that is unavailable for launch; pause that rule before publishing'
      using errcode = '55000';
  end if;
  return new;
end;
$$;

create or replace function app.v145_program_rule_pause_lift_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if old.lifted_at is null and new.lifted_at is not null and exists (
    select 1
      from public.businesses business
      join public.program_rules rule
        on rule.business_id = business.id
       and rule.config_version_id = business.active_config_version_id
       and rule.active
      cross join lateral jsonb_array_elements(coalesce(rule.then_effects, '[]'::jsonb)) effect
     where business.id = old.business_id
       and rule.rule_id = old.rule_id
       and app.ps1c2_effect_state(rule.business_id, effect->>'effect_type') <> 'live'
  ) then
    raise exception 'incomplete advanced rule pause cannot be lifted for launch'
      using errcode = '55000';
  end if;
  return new;
end;
$$;

revoke all on function app.v145_program_rule_activation_guard()
  from public, anon, authenticated;
revoke all on function app.v145_program_rule_pause_lift_guard()
  from public, anon, authenticated;

drop trigger if exists trg_v145_program_rule_activation_guard on public.program_rules;
create trigger trg_v145_program_rule_activation_guard
before update on public.program_rules
for each row execute function app.v145_program_rule_activation_guard();

drop trigger if exists trg_v145_config_publish_guard on public.firm_config_versions;
create trigger trg_v145_config_publish_guard
before update of status on public.firm_config_versions
for each row execute function app.v145_config_publish_guard();

drop trigger if exists trg_v145_program_rule_pause_lift_guard
  on public.studio_rule_emergency_pauses;
create trigger trg_v145_program_rule_pause_lift_guard
before update on public.studio_rule_emergency_pauses
for each row execute function app.v145_program_rule_pause_lift_guard();

-- Keep the one-time migration reconciliation idempotent and directly testable in a
-- disposable database. It is an internal migration helper only: browser roles receive
-- no EXECUTE privilege. Re-running it may add a missing safety pause, never lift or
-- duplicate an existing one. The nil UUID is a documented system sentinel because this
-- is a migration action, not an action performed by whichever owner happens to sort first.
create or replace function app.reconcile_v145_incomplete_program_rule_pauses()
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_inserted integer;
begin
  with inserted as (
    insert into public.studio_rule_emergency_pauses(
      business_id, rule_id, actor, reason
    )
    select rule.business_id,
           rule.rule_id,
           '00000000-0000-0000-0000-000000000000'::uuid,
           'Launch freeze: advanced rule contains an action that is not fully live.'
      from public.businesses business
      join public.program_rules rule
        on rule.business_id = business.id
       and rule.config_version_id = business.active_config_version_id
       and rule.active
     where exists (
       select 1
         from jsonb_array_elements(coalesce(rule.then_effects, '[]'::jsonb)) effect
        where app.ps1c2_effect_state(rule.business_id, effect->>'effect_type') <> 'live'
     )
    on conflict (business_id, rule_id) where lifted_at is null do nothing
    returning id,business_id,rule_id,actor
  ), audited as (
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    select inserted.business_id,inserted.actor,
           'STUDIO_RULE_EMERGENCY_PAUSE','program_rules',inserted.rule_id,
           jsonb_build_object(
             'rule_id',inserted.rule_id,
             'pause_id',inserted.id,
             'reason','Launch freeze: advanced rule contains an action that is not fully live.',
             'source','v145_launch_reconciliation'
           )
      from inserted
    returning 1
  )
  select count(*)::integer into v_inserted from audited;
  return v_inserted;
end;
$$;

revoke all on function app.reconcile_v145_incomplete_program_rule_pauses()
  from public, anon, authenticated;

select app.reconcile_v145_incomplete_program_rule_pauses();

-- Launch catalogue copy must describe the deterministic promotion wording helper
-- that actually ships. Do not sell or imply a generative-AI capability.
create or replace function public.get_business_billing_v124(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_base jsonb;
  v_current_customer_count integer;
begin
  if auth.uid() is null
     or not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'active owner or super-admin access is required'
      using errcode = '42501';
  end if;
  v_base := public.get_business_billing_v77(p_business);
  select count(*)::integer into v_current_customer_count
    from public.clients client where client.business_id = p_business;
  return v_base || jsonb_build_object(
    'pricing_model', 'v124_customer_capacity',
    'current_customer_count', v_current_customer_count,
    'staff_billing', false,
    'staff_access_note', 'Staff access is included; use individual logins and roles.',
    'terms', (select to_jsonb(terms) from public.billing_subscription_terms_v124 terms
      where terms.business_id = p_business),
    'money_back_window', (select to_jsonb(window_row)
      from public.billing_money_back_windows_v124 window_row
      where window_row.business_id = p_business),
    'plans', coalesce((
      select jsonb_agg(to_jsonb(plan_rows) order by
        case plan_rows.cadence when 'annual' then 0 else 1 end)
      from (
        select cadence, cadence_months, base_amount_cents,
               included_customer_capacity, capacity_block_size,
               capacity_block_amount_cents, compare_at_monthly_cents,
               tax_behavior
          from public.billing_plan_catalog_v124 catalog
         where currency = 'SGD' and active and effective_from <= now()
           and (effective_to is null or effective_to > now())
      ) plan_rows
    ), '[]'::jsonb),
    'included_modules', jsonb_build_array(
      'Customer CRM and QR signup', 'Loyalty points, stamps and rewards',
      'Birthday benefits and referrals', 'Appointments, team schedule and waitlist',
      'Record sale and sales history', 'Packages, memberships and gift cards',
      'Customer wallet, history and redemption', 'Promotions and template-assisted promotion wording',
      'Feedback and Google review handoff', 'Configured notifications',
      'Profitability and operational reports', 'Branches, roles and permissions',
      'English, Simplified Chinese and Malay business UI'
    ),
    'exclusions', jsonb_build_array(
      'Stripe payment processing fees', 'Usage-priced external messaging',
      'Custom integrations', 'Platform-only administration',
      'Disabled or unconfigured modules'
    )
  );
end;
$$;

revoke all on function public.get_business_billing_v124(uuid)
  from public, anon, authenticated;
grant execute on function public.get_business_billing_v124(uuid)
  to authenticated;

create or replace function public.get_self_serve_checkout_v130(
  p_business uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_email text;
  v_is_super_admin boolean := app.is_super_admin();
  v_onboarding public.self_serve_business_onboarding_v130%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated session required' using errcode = '28000';
  end if;
  select lower(email) into v_email from auth.users
   where id = v_actor and coalesce(email_confirmed_at, confirmed_at) is not null;
  if v_email is null then
    raise exception 'confirmed owner email required' using errcode = '42501';
  end if;
  select onboarding.* into v_onboarding
    from public.self_serve_business_onboarding_v130 onboarding
   where (onboarding.owner_user_id = v_actor
          or (v_is_super_admin and p_business is not null))
     and (p_business is null or onboarding.business_id = p_business);
  if p_business is not null and not found and not v_is_super_admin then
    raise exception 'self-service onboarding access required' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'onboarding', case when v_onboarding.business_id is null then null else
      jsonb_build_object(
        'business_id', v_onboarding.business_id,
        'business_slug', v_onboarding.business_slug,
        'business_name', v_onboarding.business_name,
        'owner_name', v_onboarding.owner_name,
        'sector_key', v_onboarding.sector_key,
        'cadence', v_onboarding.selected_cadence,
        'customer_capacity', v_onboarding.selected_customer_capacity,
        'status', v_onboarding.status,
        'checkout_command_id', v_onboarding.checkout_command_id,
        'activated_at', v_onboarding.activated_at,
        'legal_document_version', v_onboarding.legal_document_version,
        'total_cents', app.self_serve_plan_total_v130(
          (select catalog from public.billing_plan_catalog_v124 catalog
            where catalog.id = v_onboarding.billing_catalog_id_v124),
          v_onboarding.selected_customer_capacity
        )
      ) end,
    'plans', coalesce((
      select jsonb_agg(jsonb_build_object(
        'cadence', catalog.cadence,
        'cadence_months', catalog.cadence_months,
        'base_amount_cents', catalog.base_amount_cents,
        'included_customer_capacity', catalog.included_customer_capacity,
        'capacity_block_size', catalog.capacity_block_size,
        'capacity_block_amount_cents', catalog.capacity_block_amount_cents,
        'compare_at_monthly_cents', catalog.compare_at_monthly_cents,
        'tax_behavior', catalog.tax_behavior
      ) order by case catalog.cadence when 'annual' then 0 else 1 end)
      from public.billing_plan_catalog_v124 catalog
      where catalog.currency = 'SGD' and catalog.active
        and catalog.effective_from <= now()
        and (catalog.effective_to is null or catalog.effective_to > now())
    ), '[]'::jsonb),
    'sectors', coalesce((
      select jsonb_agg(jsonb_build_object(
        'sector_key', profile.sector_key, 'label', profile.label
      ) order by profile.label)
      from public.sector_profiles profile
      where profile.active and exists (
        select 1 from public.sector_bundle_versions bundle
         where bundle.sector_key = profile.sector_key
           and bundle.status = 'published'
           and 'loyalty' = any(bundle.modules)
      )
    ), '[]'::jsonb),
    'gst_registered', false,
    'money_back_days', case
      when v_onboarding.business_id is not null
       and v_onboarding.legal_document_version < '2026-08-03' then 30
      else null
    end,
    'refund_policy', case
      when v_onboarding.business_id is not null
       and v_onboarding.legal_document_version < '2026-08-03'
        then 'legacy_30_day_request'
      else 'non_refundable_after_payment'
    end,
    'included_modules', jsonb_build_array(
      'Customer CRM and QR signup', 'Loyalty points, stamps and rewards',
      'Birthday benefits and referrals', 'Appointments, team schedule and waitlist',
      'Record sale and sales history', 'Packages, memberships and gift cards',
      'Customer wallet, history and redemption', 'Promotions and template-assisted promotion wording',
      'Feedback and Google review handoff', 'Configured notifications',
      'Profitability and operational reports', 'Branches, roles and permissions',
      'English, Simplified Chinese and Malay business UI'
    )
  );
end;
$$;

revoke all on function public.get_self_serve_checkout_v130(uuid)
  from public, anon, authenticated;
grant execute on function public.get_self_serve_checkout_v130(uuid)
  to authenticated;

revoke all on function public.get_dashboard_summary(uuid, date, date, uuid)
  from public, anon, authenticated;
revoke all on function public.get_reports_summary(uuid, date, date, uuid)
  from public, anon, authenticated;
revoke all on function public.get_revenue_summary(uuid, date, date, uuid)
  from public, anon, authenticated;
grant execute on function public.get_dashboard_summary(uuid, date, date, uuid)
  to authenticated;
grant execute on function public.get_reports_summary(uuid, date, date, uuid)
  to authenticated;
grant execute on function public.get_revenue_summary(uuid, date, date, uuid)
  to authenticated;

commit;
