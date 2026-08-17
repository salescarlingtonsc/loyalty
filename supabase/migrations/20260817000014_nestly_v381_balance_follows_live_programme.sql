-- nestly_v381 — a balance is the live programme's pot, never every pot added together.
--
-- Owner, 2026-08-17 (photos 1 and 2): "75877 points (when switched off) — why is it converted to
-- stamps? it is independent. please ensure it does not just change it over."
--
-- The DATA was already right. Cubbly's points pot holds 75877 with the points programme switched
-- OFF, and its live stamps pot holds 0; nothing had been converted. What was wrong was the
-- READING. V312 built app.programme_balance_scope_v312 and taught the customer-facing readers to
-- respect per-programme pots, but the two BUSINESS-facing readers were never converted:
--
--   * staff_get_customer_actionable_loyalty_v145 (the customer profile) summed every
--     points_ledger row for the client, and every unexpired points_batches row, then labelled the
--     total with whichever unit was live — so 75877 points was displayed as "75877 stamps";
--   * staff_list_customers_v155 (the customer directory POINTS column) did the same.
--
-- Both now filter to app.live_balance_programme_v381(business) whenever this tenant's pots are
-- clean enough to read per programme. Tenants whose scope resolves to 'business_pot' — split pots
-- or a pending pot migration — are deliberately left on the old whole-ledger sum, because that is
-- V312's own fallback and reporting a partial pot for them would be a different lie.
--
-- Nothing is written, moved or zeroed: this migration only changes what is READ. A programme that
-- is switched off keeps its balance exactly as it stands, which is what "it is independent" means.
--
-- VERIFIED against production inside a rolled-back transaction on 2026-08-17 — see
-- db/tests/v381_balance_follows_live_programme.sql. A fixture with 500 in a switched-off points
-- pot and 3 in the live stamps pot: the pre-v381 profile reports 503 (the two added together);
-- after, the profile reports 3, the unit reads 'stamps', the directory agrees, and both pots still
-- hold exactly 500 and 3.

begin;


-- ------------------------------------------------------- app.live_balance_programme_v381
create or replace function app.live_balance_programme_v381(p_business uuid)
returns uuid language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $fn$
  -- The accruing programme a balance belongs to. Points and stamps are mutually exclusive (R2),
  -- so at most one is ever active; the order clause only makes the answer deterministic if a
  -- tenant is ever mid-switch. NULL when neither is running, which reads as "no pot is live".
  select bp.id from public.business_programmes bp
   where bp.business_id = p_business and bp.active and bp.kind in ('points','stamps')
   order by case bp.kind when 'stamps' then 0 else 1 end, bp.id
   limit 1
$fn$;
revoke all on function app.live_balance_programme_v381(uuid) from public, anon;
grant execute on function app.live_balance_programme_v381(uuid) to postgres, service_role, authenticated;


-- ------------------------------------------- public.staff_get_customer_actionable_loyalty_v145
CREATE OR REPLACE FUNCTION public.staff_get_customer_actionable_loyalty_v145(p_business uuid, p_client uuid, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_as_of timestamptz := statement_timestamp();
  v_result jsonb;
  -- v381: which pot this balance is, and whether this tenant's pots are safe to read per programme
  v_balance_scope text := app.programme_balance_scope_v312(p_business);
  v_live_programme uuid := app.live_balance_programme_v381(p_business);
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
       -- v381: the balance is the LIVE programme's pot, never every pot added together
       and (v_balance_scope <> 'programme_pot'
            or ledger.programme_id is not distinct from v_live_programme)
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
       and (v_balance_scope <> 'programme_pot'
            or batch.programme_id is not distinct from v_live_programme)
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
     and not reward.paused
    left join lateral (
      select count(*)::integer as used_count
        from public.loyalty_redemptions redemption
       where redemption.business_id = p_business
         and redemption.client_id = p_client
         and redemption.reward_id = reward_version.reward_id
    ) usage on true
    where program.enabled
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
$function$;

revoke all on function public.staff_get_customer_actionable_loyalty_v145(uuid,uuid,uuid) from public, anon;
grant execute on function public.staff_get_customer_actionable_loyalty_v145(uuid,uuid,uuid) to postgres, service_role, authenticated;


-- ------------------------------------------------------------- public.staff_list_customers_v155
CREATE OR REPLACE FUNCTION public.staff_list_customers_v155(p_business uuid, p_search text DEFAULT NULL::text, p_inactive_bucket text DEFAULT NULL::text, p_scope_mode text DEFAULT 'all'::text, p_branch_ids uuid[] DEFAULT ARRAY[]::uuid[], p_operational_branch uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_as_of timestamptz := statement_timestamp();
  v_search text := lower(btrim(coalesce(p_search,'')));
  v_phone_search text := regexp_replace(coalesce(p_search,''),'[^0-9]','','g');
  v_scope_ids uuid[];
  v_scope_label text;
  v_scope_is_whole_business boolean := false;
  v_result jsonb;
  -- v381: same pot rule as the customer profile — one programme's balance, not the sum of all
  v_balance_scope text := app.programme_balance_scope_v312(p_business);
  v_live_programme uuid := app.live_balance_programme_v381(p_business);
begin
  if length(v_phone_search)=10 and left(v_phone_search,2)='65' then
    v_phone_search := right(v_phone_search,8);
  end if;
  if auth.uid() is null or not app.can_module_read(p_business,'clients') then
    raise exception 'customer read access required' using errcode='42501';
  end if;
  if p_inactive_bucket is not null
     and p_inactive_bucket not in ('30_59','60_89','90_plus','never','all_inactive') then
    raise exception 'unsupported_inactivity_bucket' using errcode='22023';
  end if;
  if p_limit < 1 or p_limit > 100 then
    raise exception 'limit must be between 1 and 100' using errcode='22023';
  end if;
  if p_offset < 0 or p_offset > 100000 then
    raise exception 'offset must be between 0 and 100000' using errcode='22023';
  end if;

  select coalesce(array_agg(scope.branch_id order by scope.branch_name),array[]::uuid[])
    into v_scope_ids
  from app.resolve_reporting_branch_scope_v155(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  ) scope;
  v_scope_label := app.reporting_scope_label_v155(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  );
  select not exists(
    select 1
    from public.branches branch
    where branch.business_id = p_business
      and coalesce(branch.active,true)
      and not (branch.id = any(v_scope_ids))
  ) into v_scope_is_whole_business;

  with visit_facts as materialized (
    select sale.client_id,max(sale.occurred_at) as last_visit_at
    from public.sales sale
    where sale.business_id = p_business
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.occurred_at <= v_as_of
      and sale.branch_id = any(v_scope_ids)
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
          and reversal.created_at <= v_as_of
      )
    group by sale.client_id
  ), customer_scope as materialized (
    select distinct sale.client_id
    from public.sales sale
    where sale.business_id = p_business
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.branch_id = any(v_scope_ids)
  ), customer_rows as materialized (
    select customer.id,customer.full_name,customer.phone,
      customer.marketing_consent,customer.created_at,
      visit.last_visit_at,
      case when visit.last_visit_at is null then null
        else ((v_as_of at time zone 'Asia/Singapore')::date-
          (visit.last_visit_at at time zone 'Asia/Singapore')::date)::integer
      end as days_since_last_visit
    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and (
        v_scope_is_whole_business
        or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
      )
      and (
        v_search = ''
        or position(v_search in lower(customer.full_name)) > 0
        or (length(v_phone_search) >= 4 and
          position(v_phone_search in coalesce(customer.phone_norm,'')) > 0)
      )
      and (
        p_inactive_bucket is null
        or (p_inactive_bucket = 'never' and v_scope_is_whole_business
          and visit.last_visit_at is null)
        or (p_inactive_bucket = '30_59' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) between 30 and 59)
        or (p_inactive_bucket = '60_89' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) between 60 and 89)
        or (p_inactive_bucket = '90_plus' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) >= 90)
        or (p_inactive_bucket = 'all_inactive' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) >= 30)
      )
  ), page as materialized (
    select * from customer_rows customer
    order by customer.last_visit_at asc nulls last, customer.full_name, customer.id
    limit p_limit offset p_offset
  ), page_balances as materialized (
    select customer.*,
      coalesce((select sum(ledger.points) from public.points_ledger ledger
        where ledger.business_id = p_business and ledger.client_id = customer.id
          and (v_balance_scope <> 'programme_pot'
               or ledger.programme_id is not distinct from v_live_programme)),0)::bigint as points,
      coalesce((select sum(ledger.amount_cents) from public.credit_ledger ledger
        where ledger.business_id = p_business and ledger.client_id = customer.id),0)::bigint as balance_cents
    from page customer
  )
  select jsonb_build_object(
    'status','ok',
    'as_of',v_as_of,
    'scope',jsonb_build_object(
      'mode',coalesce(p_scope_mode,'all'),
      'label',v_scope_label,
      'branch_ids',to_jsonb(v_scope_ids),
      'definition',case when v_scope_is_whole_business
        then 'Business-wide last valid visit across all included authorised branches.'
        else 'Inactive in this branch scope: last valid visit within that selected scope.'
      end
    ),
    'inactive_bucket',p_inactive_bucket,
    'loyalty_available',app.metric_module_scope_available_v145(p_business,null,'loyalty'),
    'total',(select count(*) from customer_rows),
    'customers',coalesce((select jsonb_agg(jsonb_build_object(
      'id',customer.id,
      'full_name',customer.full_name,
      'phone',customer.phone,
      'marketing_consent',customer.marketing_consent,
      'created_at',customer.created_at,
      'last_visit_at',customer.last_visit_at,
      'days_since_last_visit',customer.days_since_last_visit,
      'points',customer.points,
      'balance_cents',customer.balance_cents
    ) order by customer.last_visit_at asc nulls last,customer.full_name,customer.id)
    from page_balances customer),'[]'::jsonb)
  ) into v_result;

  return v_result;
end
$function$;

revoke all on function public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer) from public, anon;
grant execute on function public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer) to postgres, service_role, authenticated;

commit;
