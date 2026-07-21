-- FRENLY C44 — actionable customer wallet read contract.
--
-- Forward-only and read-only. This does not change the established v32/v39
-- readers or any redemption rule. It adds a separate, conservative customer
-- projection: a unit is actionable only when both the ledger and an unexpired
-- remaining batch can prove it. The two browser RPCs derive all scope from
-- auth.uid() through the verified v32 customer-link context; callers never
-- provide a customer, identity, client, business, or configuration UUID.

begin;

insert into app.platform_feature_flags(feature_key, enabled)
values ('customer_actionable_wallet', false)
on conflict (feature_key) do nothing;

-- These predicates are the hot paths for a bounded customer card projection.
-- They retain the unwrapped expiry timestamp so `expires_at > p_as_of` remains
-- index-supported and never silently treats an overdue batch as actionable.
create index if not exists c44_points_batches_actionable_idx
  on public.points_batches (business_id, client_id, expires_at, earned_at, id)
  include (remaining)
  where remaining > 0;
create index if not exists c44_client_packages_actionable_idx
  on public.client_packages (business_id, client_id, status)
  include (remaining);
create index if not exists c44_reward_versions_actionable_idx
  on public.loyalty_reward_versions (business_id, config_version_id, sort, customer_name)
  include (cost_points, claim_available_from, claim_available_until, usage_limit)
  where active;

-- The private helper has an explicit JSON allowlist. It is not browser
-- executable: public readers pass only values resolved from the verified link
-- context and a single statement timestamp.
create or replace function app.c44_actionable_wallet_card(
  p_business_id uuid,
  p_client_id uuid,
  p_business_slug text,
  p_business_name text,
  p_business_industry text,
  p_business_currency text,
  p_enabled_modules text[],
  p_as_of timestamptz
)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  with program as (
    select
      'loyalty' = any(p_enabled_modules) and coalesce(lp.active, false) as enabled,
      case when 'loyalty' = any(p_enabled_modules) and coalesce(lp.active, false)
        then case when lp.loyalty_model = 'stamps' then 'stamps' else 'points' end
      end as unit,
      case when 'loyalty' = any(p_enabled_modules) and coalesce(lp.active, false)
        then lp.loyalty_model
      end as model,
      case when 'loyalty' = any(p_enabled_modules) and coalesce(lp.active, false)
        then coalesce(lp.expiry_mode, 'none')
        else 'none'
      end as expiry_mode
    from (select 1) scope
    left join public.loyalty_programs lp on lp.business_id = p_business_id
  ), ledger_balance as (
    select greatest(coalesce(sum(pl.points), 0), 0)::integer as units
      from public.points_ledger pl
     where pl.business_id = p_business_id
       and pl.client_id = p_client_id
  -- A ledger balance can lag or lead batch rows during a repair or reversal.
  -- The customer projection therefore allocates only the proven balance over
  -- unexpired batches in the same FEFO order used for redemption. Expiry
  -- bands and next_expiry_at are derived from that capped allocation, never
  -- from raw batches that the customer cannot currently spend.
  ), unexpired_batches as (
    select
      pb.id,
      pb.remaining,
      pb.earned_at,
      pb.expires_at,
      sum(pb.remaining) over (
        order by pb.expires_at nulls last, pb.earned_at, pb.id
        rows between unbounded preceding and current row
      )::bigint as cumulative_remaining
      from public.points_batches pb
     where pb.business_id = p_business_id
       and pb.client_id = p_client_id
       and pb.remaining > 0
       and (pb.expires_at is null or pb.expires_at > p_as_of)
  ), batch_balance as (
    select coalesce(sum(remaining), 0)::integer as unexpired_units
      from unexpired_batches
  ), loyalty_balance as (
    select
      program.enabled,
      program.model,
      program.unit,
      program.expiry_mode,
      case when program.enabled
        then greatest(least(ledger_balance.units, batch_balance.unexpired_units), 0)
        else 0 end as balance
      from program cross join ledger_balance cross join batch_balance
  ), actionable_batches as (
    select
      ub.expires_at,
      least(
        ub.remaining::bigint,
        greatest(
          loyalty_balance.balance::bigint
            - (ub.cumulative_remaining - ub.remaining::bigint),
          0
        )
      )::integer as actionable_remaining
      from unexpired_batches ub
      cross join loyalty_balance
     where loyalty_balance.enabled
       and loyalty_balance.balance > 0
       and ub.cumulative_remaining - ub.remaining::bigint < loyalty_balance.balance::bigint
  ), expiry_balance as (
    select
      coalesce(sum(actionable_remaining) filter (
        where expires_at > p_as_of
          and expires_at <= p_as_of + interval '7 days'
      ), 0)::integer as expiring_7_units,
      coalesce(sum(actionable_remaining) filter (
        where expires_at > p_as_of
          and expires_at <= p_as_of + interval '30 days'
      ), 0)::integer as expiring_30_units,
      min(expires_at) filter (
        where actionable_remaining > 0
          and expires_at > p_as_of
          and expires_at <= p_as_of + interval '30 days'
      ) as next_expiry_at
      from actionable_batches
  ), loyalty as (
    select
      loyalty_balance.enabled,
      loyalty_balance.model,
      loyalty_balance.unit,
      loyalty_balance.expiry_mode,
      loyalty_balance.balance,
      case when loyalty_balance.enabled and loyalty_balance.expiry_mode <> 'none'
        then expiry_balance.expiring_7_units else 0 end as expiring_7_units,
      case when loyalty_balance.enabled and loyalty_balance.expiry_mode <> 'none'
        then expiry_balance.expiring_30_units else 0 end as expiring_units,
      case when loyalty_balance.enabled and loyalty_balance.expiry_mode <> 'none'
             and expiry_balance.expiring_30_units > 0
        then expiry_balance.next_expiry_at else null end as next_expiry_at
      from loyalty_balance cross join expiry_balance
  ), credit as (
    select greatest(coalesce(sum(cl.amount_cents), 0), 0)::integer as balance_cents
      from public.credit_ledger cl
     where cl.business_id = p_business_id
       and cl.client_id = p_client_id
  ), packages as (
    select coalesce(sum(cp.remaining), 0)::integer as sessions_remaining
      from public.client_packages cp
     where cp.business_id = p_business_id
       and cp.client_id = p_client_id
       and cp.status = 'active'
       and cp.remaining > 0
  ), reward_candidate as (
    select
      rv.customer_name as name,
      rv.cost_points::integer as cost_units,
      greatest(rv.cost_points - loyalty.balance, 0)::integer as remaining_units,
      loyalty.balance >= rv.cost_points as available_now
      from public.businesses b
      join public.loyalty_reward_versions rv
        on rv.business_id = b.id
       and rv.config_version_id = b.active_config_version_id
       and rv.active
      cross join loyalty
      left join lateral (
        select count(*)::integer as used_count
          from public.loyalty_redemptions lr
         where lr.business_id = p_business_id
           and lr.client_id = p_client_id
           and lr.reward_id = rv.reward_id
      ) usage on true
     where b.id = p_business_id
       and loyalty.enabled
       and (rv.claim_available_from is null or rv.claim_available_from <= p_as_of)
       and (rv.claim_available_until is null or rv.claim_available_until > p_as_of)
       and (rv.usage_limit is null or usage.used_count < rv.usage_limit)
     order by greatest(rv.cost_points - loyalty.balance, 0), rv.sort,
              lower(rv.customer_name), rv.reward_id
     limit 1
  ), retention_windows as (
    select
      rv.program_id,
      rv.goal_visits,
      rv.sort,
      rv.name,
      rv.customer_description,
      rv.starts_on::timestamptz
        + make_interval(days => (
          floor(extract(epoch from (p_as_of - rv.starts_on::timestamptz))
            / (rv.period_days * 86400))::integer * rv.period_days
        )) as period_start,
      rv.starts_on::timestamptz
        + make_interval(days => (
          (floor(extract(epoch from (p_as_of - rv.starts_on::timestamptz))
            / (rv.period_days * 86400))::integer + 1) * rv.period_days
        )) as period_end
      from public.businesses b
      join public.retention_program_versions rv
        on rv.business_id = b.id
       and rv.config_version_id = b.active_config_version_id
       and rv.active
     where b.id = p_business_id
       and p_as_of >= rv.starts_on::timestamptz
  ), visit_candidate as (
    select
      w.program_id,
      w.period_end,
      w.goal_visits,
      w.customer_description,
      greatest(w.goal_visits - count(s.id)::integer, 0)::integer as visits_remaining
      from retention_windows w
      left join public.sales s
        on s.business_id = p_business_id
       and s.client_id = p_client_id
       and s.counts_as_visit
       and s.reversal_of is null
       and s.occurred_at >= w.period_start
       and s.occurred_at < w.period_end
       and not exists (
         select 1 from public.sales reversal
          where reversal.business_id = s.business_id and reversal.reversal_of = s.id
       )
     group by w.program_id, w.goal_visits, w.period_end, w.sort, w.name, w.customer_description
     order by greatest(w.goal_visits - count(s.id)::integer, 0),
              w.period_end, w.sort, lower(w.name), w.program_id
     limit 1
  ), action as (
    select
      case
        when loyalty.expiring_7_units > 0 then 'expiring_within_7_days'
        when coalesce(reward_candidate.available_now, false) then 'reward_available'
        when loyalty.expiring_units > 0 then 'expiring_within_30_days'
        when visit_candidate.visits_remaining = 1 then 'one_qualifying_visit_remaining'
        when reward_candidate.name is not null then 'reward_progress'
        else 'none'
      end as reason,
      case
        when loyalty.expiring_7_units > 0 then loyalty.next_expiry_at
        when loyalty.expiring_units > 0 then loyalty.next_expiry_at
        when visit_candidate.visits_remaining = 1 then visit_candidate.period_end
        else null
      end as deadline_at,
      case
        when loyalty.expiring_7_units > 0 then 1
        when coalesce(reward_candidate.available_now, false) then 2
        when loyalty.expiring_units > 0 then 3
        when visit_candidate.visits_remaining = 1 then 4
        when reward_candidate.name is not null then 5
        else 6
      end as sort_band,
      case when reward_candidate.name is not null
        then reward_candidate.remaining_units else 0 end as sort_units
      from loyalty
      left join reward_candidate on true
      left join visit_candidate on true
  )
  select jsonb_build_object(
    'business', jsonb_build_object(
      'slug', p_business_slug,
      'name', p_business_name,
      'industry', p_business_industry,
      'currency', p_business_currency
    ),
    'loyalty', jsonb_build_object(
      'enabled', loyalty.enabled,
      'model', loyalty.model,
      'unit', loyalty.unit,
      'balance', loyalty.balance
    ),
    'credit', jsonb_build_object(
      'balance_cents', credit.balance_cents
    ),
    'packages', jsonb_build_object(
      'sessions_remaining', case when 'packages' = any(p_enabled_modules)
        then packages.sessions_remaining else 0 end
    ),
    'expiry', jsonb_build_object(
      'mode', loyalty.expiry_mode,
      'expiring_within_7_days', loyalty.expiring_7_units,
      'expiring_units', loyalty.expiring_units,
      'next_expiry_at', loyalty.next_expiry_at
    ),
    'next_eligible_reward', case when reward_candidate.name is null then null else
      jsonb_build_object(
        'name', reward_candidate.name,
        'cost_units', reward_candidate.cost_units,
        'remaining_units', reward_candidate.remaining_units,
        'available_now', reward_candidate.available_now
      ) end,
    'visits_remaining', visit_candidate.visits_remaining,
    'visit_progress', case when visit_candidate.visits_remaining is null then null else
      jsonb_build_object(
        'remaining', visit_candidate.visits_remaining,
        'goal_visits', visit_candidate.goal_visits,
        'period_ends_at', visit_candidate.period_end,
        'customer_description', visit_candidate.customer_description
      ) end,
    'action', jsonb_build_object(
      'reason', action.reason,
      'deadline_at', action.deadline_at,
      'sort_band', action.sort_band,
      'sort_units', action.sort_units
    )
  )
    from loyalty
    cross join credit
    cross join packages
    left join reward_candidate on true
    left join visit_candidate on true
    cross join action;
$$;

create or replace function public.get_customer_feature_capabilities()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null then
    raise exception 'authenticated session required' using errcode = '28000';
  end if;
  return jsonb_build_object(
    'customer_identity', app.platform_feature_enabled('customer_identity'),
    'customer_claims', app.platform_feature_enabled('customer_claims'),
    'customer_wallet', app.platform_feature_enabled('customer_wallet'),
    'customer_actions', app.platform_feature_enabled('customer_actions'),
    'customer_notifications', app.platform_feature_enabled('customer_notifications'),
    'customer_email_otp', app.platform_feature_enabled('customer_email_otp'),
    'customer_phone_otp', app.platform_feature_enabled('customer_phone_otp'),
    'customer_whatsapp_otp', app.platform_feature_enabled('customer_whatsapp_otp'),
    'customer_phone_registration', app.platform_feature_enabled('customer_phone_registration'),
    'customer_phone_claims', app.platform_feature_enabled('customer_phone_claims'),
    'customer_actionable_wallet', app.platform_feature_enabled('customer_actionable_wallet')
  );
end;
$$;

create or replace function public.customer_get_actionable_wallet()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_as_of timestamptz := statement_timestamp();
  v_cards jsonb;
  v_truncated boolean := false;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_actionable_wallet') then
    raise exception 'actionable customer wallet is not enabled' using errcode = '0A000';
  end if;

  -- Rank every eligible linked business after its customer-safe action is
  -- computed. Never alphabetically pre-limit the source context: a lexical
  -- tail must not hide an expiring or immediately redeemable programme.
  select coalesce(jsonb_agg(card order by
    (card#>>'{action,sort_band}')::integer,
    nullif(card#>>'{action,deadline_at}', '')::timestamptz nulls last,
    (card#>>'{action,sort_units}')::integer,
    lower(card#>>'{business,name}'),
    card#>>'{business,slug}'
  ) filter (where action_rank <= 100), '[]'::jsonb),
  coalesce(bool_or(action_rank > 100), false)
    into v_cards, v_truncated
    from (
      select action_cards.card, row_number() over (order by
        (action_cards.card#>>'{action,sort_band}')::integer,
        nullif(action_cards.card#>>'{action,deadline_at}', '')::timestamptz nulls last,
        (action_cards.card#>>'{action,sort_units}')::integer,
        lower(action_cards.card#>>'{business,name}'),
        action_cards.card#>>'{business,slug}'
      ) as action_rank
        from (
          select app.c44_actionable_wallet_card(
            context.business_id, context.client_id, context.business_slug,
            context.business_name, context.business_industry, context.business_currency,
            context.enabled_modules, v_as_of
          ) as card
            from app.v32_customer_wallet_context(null) context
        ) action_cards
    ) ranked
   where action_rank <= 101;

  return jsonb_build_object('as_of', v_as_of, 'cards', v_cards, 'truncated', v_truncated);
end;
$$;

create or replace function public.customer_get_actionable_business(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_as_of timestamptz := statement_timestamp();
  v_context record;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if p_business_slug is null or length(btrim(p_business_slug)) not between 2 and 160 then
    raise exception 'invalid business link' using errcode = '22023';
  end if;
  if not app.platform_feature_enabled('customer_actionable_wallet') then
    raise exception 'actionable customer wallet is not enabled' using errcode = '0A000';
  end if;

  select * into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'as_of', v_as_of,
    'card', app.c44_actionable_wallet_card(
      v_context.business_id, v_context.client_id, v_context.business_slug,
      v_context.business_name, v_context.business_industry, v_context.business_currency,
      v_context.enabled_modules, v_as_of
    )
  );
end;
$$;

revoke all on function app.c44_actionable_wallet_card(uuid, uuid, text, text, text, text, text[], timestamptz)
  from public, anon, authenticated;
revoke all on function public.get_customer_feature_capabilities()
  from public, anon;
grant execute on function public.get_customer_feature_capabilities() to authenticated;
revoke all on function public.customer_get_actionable_wallet()
  from public, anon, authenticated;
revoke all on function public.customer_get_actionable_business(text)
  from public, anon, authenticated;
grant execute on function public.customer_get_actionable_wallet() to authenticated;
grant execute on function public.customer_get_actionable_business(text) to authenticated;

commit;
