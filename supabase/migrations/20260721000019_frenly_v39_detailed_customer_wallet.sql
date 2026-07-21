-- FRENLY v39 - DETAILED CUSTOMER WALLET READ MODEL
--
-- Local review candidate. Every public RPC derives its effective business and
-- client from auth.uid() through the verified v32 link resolver. The browser
-- receives explicit customer-safe projections only; no self-redemption route
-- is introduced by this migration.

begin;

create or replace function public.customer_get_loyalty_details(
  p_business_slug text,
  p_cursor jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record;
  v_program public.loyalty_programs%rowtype;
  v_cursor jsonb := coalesce(p_cursor, '{}'::jsonb);
  v_limit integer := 20;
  v_before_at timestamptz;
  v_before_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if jsonb_typeof(v_cursor) <> 'object' then
    raise exception 'invalid loyalty activity cursor' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(v_cursor) as keys(key) where key not in ('limit','before_at','before_id')) then
    raise exception 'invalid loyalty activity cursor' using errcode = '22023';
  end if;

  begin
    v_limit := least(greatest(coalesce((v_cursor->>'limit')::integer, 20), 1), 50);
    v_before_at := nullif(v_cursor->>'before_at', '')::timestamptz;
    v_before_id := nullif(v_cursor->>'before_id', '')::uuid;
  exception when others then
    raise exception 'invalid loyalty activity cursor' using errcode = '22023';
  end;
  if (v_before_at is null) <> (v_before_id is null) then
    raise exception 'loyalty activity cursor is incomplete' using errcode = '22023';
  end if;

  select * into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  if not ('loyalty' = any(v_context.enabled_modules)) then
    raise exception 'loyalty module is unavailable for this business' using errcode = '42501';
  end if;
  select * into v_program from public.loyalty_programs lp
   where lp.business_id = v_context.business_id and lp.active
   limit 1;
  if not found then
    raise exception 'loyalty module is unavailable for this business' using errcode = '42501';
  end if;

  with activity as (
    select pl.id, pl.created_at as event_at, pl.entry_type as event_type,
           pl.points::integer as points_delta,
           case pl.entry_type
             when 'earn' then 'Points earned'
             when 'expire' then 'Points expired'
             when 'adjust' then 'Balance adjustment'
             else 'Loyalty activity'
           end as title,
           null::text as detail,
           null::text as status,
           null::timestamptz as entitlement_expires_at
      from public.points_ledger pl
     where pl.business_id = v_context.business_id
       and pl.client_id = v_context.client_id
       and pl.entry_type in ('earn','expire','adjust')
    union all
    select lr.id, lr.redeemed_at, 'reward_claimed', -lr.points_spent,
           lr.reward_name, null::text,
           case when rev.id is null then 'claimed' else 'reversed' end,
           lr.entitlement_expires_at
      from public.loyalty_redemptions lr
      left join public.loyalty_redemption_reversals rev
        on rev.business_id = lr.business_id and rev.redemption_id = lr.id
     where lr.business_id = v_context.business_id
       and lr.client_id = v_context.client_id
    union all
    select rg.id, rg.granted_at, 'retention_reward', 0,
           coalesce(nullif(btrim(rg.reward_label), ''), 'Reward granted'),
           null::text, rg.status, null::timestamptz
      from public.reward_grants rg
     where rg.business_id = v_context.business_id
       and rg.client_id = v_context.client_id
  ), eligible as (
    select * from activity
     where v_before_at is null or (event_at, id) < (v_before_at, v_before_id)
     order by event_at desc, id desc
     limit v_limit + 1
  ), visible as (
    select * from eligible order by event_at desc, id desc limit v_limit
  )
  select jsonb_build_object(
    'model', v_program.loyalty_model,
    'unit', case when v_program.loyalty_model = 'stamps' then 'stamps' else 'points' end,
    'balance', coalesce((
      select sum(pl.points)::integer from public.points_ledger pl
       where pl.business_id = v_context.business_id and pl.client_id = v_context.client_id
    ), 0),
    'expiry', jsonb_build_object(
      'expiring_next_30_days', coalesce((
        select sum(pb.remaining)::integer from public.points_batches pb
         where pb.business_id = v_context.business_id and pb.client_id = v_context.client_id
           and pb.remaining > 0 and pb.expires_at > now() and pb.expires_at <= now() + interval '30 days'
      ), 0),
      'next_expiry_at', (
        select min(pb.expires_at) from public.points_batches pb
         where pb.business_id = v_context.business_id and pb.client_id = v_context.client_id
           and pb.remaining > 0 and pb.expires_at > now()
      )
    ),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
      'event_at', event_at, 'event_type', event_type, 'points_delta', points_delta,
      'title', title, 'detail', detail, 'status', status,
      'entitlement_expires_at', entitlement_expires_at
    ) order by event_at desc, id desc) from visible), '[]'::jsonb),
    'next_cursor', case when (select count(*) from eligible) > v_limit then (
      select jsonb_build_object('before_at', event_at, 'before_id', id, 'limit', v_limit)
        from visible order by event_at, id limit 1
    ) else null end
  ) into v_result;

  return v_result;
end;
$$;

create or replace function public.customer_get_reward_catalog(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record;
  v_balance integer;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  if not ('loyalty' = any(v_context.enabled_modules)) or not exists (
    select 1 from public.loyalty_programs lp
     where lp.business_id = v_context.business_id and lp.active
  ) then
    raise exception 'loyalty module is unavailable for this business' using errcode = '42501';
  end if;

  select coalesce(sum(pl.points), 0)::integer into v_balance
    from public.points_ledger pl
   where pl.business_id = v_context.business_id and pl.client_id = v_context.client_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'customer_name', listed.customer_name,
    'description', listed.description,
    'image_ref', listed.image_ref,
    'terms', listed.terms,
    'instructions', listed.instructions,
    'taxonomy_label', listed.taxonomy_label,
    'fulfillment_kind', listed.fulfillment_kind,
    'cost_points', listed.cost_points,
    'claim_available_from', listed.claim_available_from,
    'claim_available_until', listed.claim_available_until,
    'entitlement_expiry_days', listed.entitlement_expiry_days,
    'availability', listed.availability,
    'claim_method', 'counter',
    'eligibility', jsonb_build_object(
      'branches', jsonb_build_object('scope', case when listed.branch_count = 0 then 'all' else 'restricted' end, 'count', listed.branch_count),
      'services', jsonb_build_object('scope', case when listed.service_count = 0 then 'all' else 'restricted' end, 'count', listed.service_count),
      'products', jsonb_build_object('scope', case when listed.product_count = 0 then 'all' else 'restricted' end, 'count', listed.product_count)
    )
  ) order by listed.sort, listed.customer_name), '[]'::jsonb)
  into v_result
  from (
    select rv.customer_name, rv.description, rv.image_ref, rv.terms, rv.instructions,
           rv.taxonomy_label, rv.fulfillment_kind, rv.cost_points, rv.claim_available_from,
           rv.claim_available_until, rv.entitlement_expiry_days, rv.sort,
           (select count(*)::integer from public.loyalty_reward_branches e where e.reward_version_id = rv.id) as branch_count,
           (select count(*)::integer from public.loyalty_reward_services e where e.reward_version_id = rv.id) as service_count,
           (select count(*)::integer from public.loyalty_reward_products e where e.reward_version_id = rv.id) as product_count,
           case
             when rv.claim_available_from is not null and now() < rv.claim_available_from then 'not_started'
             when rv.claim_available_until is not null and now() >= rv.claim_available_until then 'ended'
             when rv.usage_limit is not null and coalesce(usage.used_count, 0) >= rv.usage_limit then 'limit_reached'
             when v_balance < rv.cost_points then 'insufficient_balance'
             else 'available_at_counter'
           end as availability
      from public.businesses b
      join public.loyalty_reward_versions rv
        on rv.business_id = b.id and rv.config_version_id = b.active_config_version_id and rv.active
      left join lateral (
        select count(*)::integer as used_count
          from public.loyalty_redemptions lr
         where lr.business_id = v_context.business_id and lr.client_id = v_context.client_id
           and lr.reward_id = rv.reward_id
      ) usage on true
     where b.id = v_context.business_id
  ) listed;

  return v_result;
end;
$$;

create or replace function public.customer_get_packages(
  p_business_slug text,
  p_cursor jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record;
  v_cursor jsonb := coalesce(p_cursor, '{}'::jsonb);
  v_limit integer := 20;
  v_before_at timestamptz;
  v_before_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if jsonb_typeof(v_cursor) <> 'object' then
    raise exception 'invalid packages cursor' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(v_cursor) as keys(key) where key not in ('limit','before_at','before_id')) then
    raise exception 'invalid packages cursor' using errcode = '22023';
  end if;
  begin
    v_limit := least(greatest(coalesce((v_cursor->>'limit')::integer, 20), 1), 50);
    v_before_at := nullif(v_cursor->>'before_at', '')::timestamptz;
    v_before_id := nullif(v_cursor->>'before_id', '')::uuid;
  exception when others then
    raise exception 'invalid packages cursor' using errcode = '22023';
  end;
  if (v_before_at is null) <> (v_before_id is null) then
    raise exception 'packages cursor is incomplete' using errcode = '22023';
  end if;

  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  if not ('packages' = any(v_context.enabled_modules)) then
    raise exception 'packages module is unavailable for this business' using errcode = '42501';
  end if;

  with packages as (
    select cp.id,
           coalesce(nullif(to_jsonb(cp)->>'purchased_at','')::timestamptz,
                    nullif(to_jsonb(cp)->>'created_at','')::timestamptz,
                    'epoch'::timestamptz) as sort_at,
           nullif(to_jsonb(cp)->>'purchased_at','')::timestamptz as purchased_at,
           nullif(to_jsonb(cp)->>'expires_at','')::timestamptz as expires_at,
           pp.name as plan_name, pp.sessions as sessions_purchased,
           cp.remaining as sessions_remaining, cp.status,
           coalesce((
             select jsonb_agg(jsonb_build_object(
               'used_at', history.created_at,
               'remaining_after', history.remaining_after,
               'status', case when history.reversed then 'reversed' else 'used' end
             ) order by history.created_at desc)
             from (
               select use.created_at, use.remaining_after,
                      exists (select 1 from public.package_session_reversals rev
                               where rev.business_id = use.business_id and rev.consumption_id = use.id) as reversed
                 from public.package_session_consumptions use
                where use.business_id = v_context.business_id
                  and use.client_id = v_context.client_id
                  and use.client_package_id = cp.id
                order by use.created_at desc, use.id desc
                limit 10
             ) history
           ), '[]'::jsonb) as usage_history
      from public.client_packages cp
      join public.package_plans pp
        on pp.id = cp.plan_id and pp.business_id = cp.business_id
     where cp.business_id = v_context.business_id
       and cp.client_id = v_context.client_id
  ), eligible as (
    select * from packages
     where v_before_at is null or (sort_at, id) < (v_before_at, v_before_id)
     order by sort_at desc, id desc limit v_limit + 1
  ), visible as (
    select * from eligible order by sort_at desc, id desc limit v_limit
  )
  select jsonb_build_object(
    'items', coalesce((select jsonb_agg(jsonb_build_object(
      'plan_name', plan_name, 'sessions_purchased', sessions_purchased,
      'sessions_remaining', sessions_remaining, 'status', status,
      'purchased_at', purchased_at, 'expires_at', expires_at,
      'usage_history', usage_history
    ) order by sort_at desc, id desc) from visible), '[]'::jsonb),
    'next_cursor', case when (select count(*) from eligible) > v_limit then (
      select jsonb_build_object('before_at', sort_at, 'before_id', id, 'limit', v_limit)
        from visible order by sort_at, id limit 1
    ) else null end
  ) into v_result;

  return v_result;
end;
$$;

create or replace function public.customer_get_memberships(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  if not ('memberships' = any(v_context.enabled_modules)) then
    raise exception 'memberships module is unavailable for this business' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'plan_name', listed.plan_name,
    'cadence', listed.cadence,
    'status', listed.status,
    'current_period_start', listed.current_period_start,
    'current_period_end', listed.current_period_end
  ) order by listed.current_period_end desc, listed.id desc), '[]'::jsonb)
  into v_result
  from (
    select m.id, mp.name as plan_name, mp.cadence, m.status,
           m.current_period_start, m.current_period_end
      from public.memberships m
      join public.membership_plans mp
        on mp.id = m.plan_id and mp.business_id = m.business_id
     where m.business_id = v_context.business_id
       and m.client_id = v_context.client_id
     order by m.current_period_end desc, m.id desc
     limit 20
  ) listed;

  return v_result;
end;
$$;

create or replace function public.customer_get_appointments_page(
  p_business_slug text,
  p_cursor jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record;
  v_cursor jsonb := coalesce(p_cursor, '{}'::jsonb);
  v_limit integer := 20;
  v_as_of timestamptz := statement_timestamp();
  v_cursor_group integer;
  v_cursor_at timestamptz;
  v_cursor_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if jsonb_typeof(v_cursor) <> 'object' then
    raise exception 'invalid appointments cursor' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(v_cursor) as keys(key)
              where key not in ('limit','as_of','sort_group','starts_at','id')) then
    raise exception 'invalid appointments cursor' using errcode = '22023';
  end if;
  begin
    v_limit := least(greatest(coalesce((v_cursor->>'limit')::integer, 20), 1), 50);
    v_as_of := coalesce(nullif(v_cursor->>'as_of', '')::timestamptz, v_as_of);
    v_cursor_group := nullif(v_cursor->>'sort_group', '')::integer;
    v_cursor_at := nullif(v_cursor->>'starts_at', '')::timestamptz;
    v_cursor_id := nullif(v_cursor->>'id', '')::uuid;
  exception when others then
    raise exception 'invalid appointments cursor' using errcode = '22023';
  end;
  if v_cursor_group is not null and v_cursor_group not in (0,1) then
    raise exception 'invalid appointments cursor' using errcode = '22023';
  end if;
  if num_nonnulls(v_cursor_group,v_cursor_at,v_cursor_id) not in (0,3) then
    raise exception 'appointments cursor is incomplete' using errcode = '22023';
  end if;

  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  if not ('appointments' = any(v_context.enabled_modules)) then
    raise exception 'appointments module is unavailable for this business' using errcode = '42501';
  end if;

  with ordered as (
    select a.id, a.starts_at, a.ends_at, a.status,
           case when a.status = 'booked' and a.starts_at >= v_as_of then 0 else 1 end as sort_group,
           s.name as service_name, br.name as branch_name
      from public.appointments a
      left join public.services s on s.id = a.service_id and s.business_id = a.business_id
      left join public.branches br on br.id = a.branch_id and br.business_id = a.business_id
     where a.business_id = v_context.business_id
       and a.client_id = v_context.client_id
       and a.status in ('booked','completed','cancelled','no_show')
  ), eligible as (
    select * from ordered
     where v_cursor_group is null
        or sort_group > v_cursor_group
        or (
          sort_group = v_cursor_group and (
            (sort_group = 0 and (starts_at,id) > (v_cursor_at,v_cursor_id))
            or (sort_group = 1 and (starts_at,id) < (v_cursor_at,v_cursor_id))
          )
        )
     order by sort_group,
              case when sort_group=0 then starts_at end asc,
              case when sort_group=1 then starts_at end desc,
              case when sort_group=0 then id end asc,
              case when sort_group=1 then id end desc
     limit v_limit + 1
  ), visible as (
    select * from eligible
     order by sort_group,
              case when sort_group=0 then starts_at end asc,
              case when sort_group=1 then starts_at end desc,
              case when sort_group=0 then id end asc,
              case when sort_group=1 then id end desc
     limit v_limit
  )
  select jsonb_build_object(
    'items', coalesce((select jsonb_agg(jsonb_build_object(
      'appointment_id', id, 'starts_at', starts_at, 'ends_at', ends_at,
      'status', status, 'service_name', service_name, 'branch_name', branch_name
    ) order by sort_group,
               case when sort_group=0 then starts_at end asc,
               case when sort_group=1 then starts_at end desc,
               case when sort_group=0 then id end asc,
               case when sort_group=1 then id end desc) from visible), '[]'::jsonb),
    'next_cursor', case when (select count(*) from eligible) > v_limit then (
      select jsonb_build_object(
        'as_of', v_as_of, 'sort_group', sort_group, 'starts_at', starts_at,
        'id', id, 'limit', v_limit
      ) from visible
       order by sort_group,
                case when sort_group=0 then starts_at end asc,
                case when sort_group=1 then starts_at end desc,
                case when sort_group=0 then id end asc,
                case when sort_group=1 then id end desc
       offset v_limit - 1 limit 1
    ) else null end
  ) into v_result;

  return v_result;
end;
$$;

-- Keep the v32 keys for compatibility and add separate read capabilities for
-- the catalog and activity surfaces. Every capability remains both module- and
-- data-aware so the SPA can omit irrelevant empty sections.
create or replace function public.customer_portal_capabilities(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'wallet', 'loyalty' = any(v_context.enabled_modules) and exists (
      select 1 from public.loyalty_programs lp where lp.business_id = v_context.business_id and lp.active
    ),
    'rewards', 'loyalty' = any(v_context.enabled_modules) and exists (
      select 1 from public.loyalty_programs lp
       where lp.business_id = v_context.business_id and lp.active
    ) and exists (
      select 1 from public.loyalty_reward_versions rv
      join public.businesses b on b.id = rv.business_id and b.active_config_version_id = rv.config_version_id
       where rv.business_id = v_context.business_id and rv.active
    ),
    'activity', 'loyalty' = any(v_context.enabled_modules) and exists (
      select 1 from public.loyalty_programs lp
       where lp.business_id = v_context.business_id and lp.active
    ) and (
      exists (select 1 from public.points_ledger x where x.business_id = v_context.business_id and x.client_id = v_context.client_id)
      or exists (select 1 from public.loyalty_redemptions x where x.business_id = v_context.business_id and x.client_id = v_context.client_id)
      or exists (select 1 from public.reward_grants x where x.business_id = v_context.business_id and x.client_id = v_context.client_id)
    ),
    'appointments', 'appointments' = any(v_context.enabled_modules) and exists (
      select 1 from public.appointments x where x.business_id = v_context.business_id and x.client_id = v_context.client_id
    ),
    'booking_request', 'bookings' = any(v_context.enabled_modules) and exists (
      select 1 from public.services x where x.business_id = v_context.business_id and x.active
    ),
    'packages', 'packages' = any(v_context.enabled_modules) and exists (
      select 1 from public.client_packages x where x.business_id = v_context.business_id and x.client_id = v_context.client_id
    ),
    'membership', 'memberships' = any(v_context.enabled_modules) and exists (
      select 1 from public.memberships x where x.business_id = v_context.business_id and x.client_id = v_context.client_id
    )
  );
end;
$$;

revoke all on function public.customer_get_loyalty_details(text,jsonb) from public, anon, authenticated;
revoke all on function public.customer_get_reward_catalog(text) from public, anon, authenticated;
revoke all on function public.customer_get_packages(text,jsonb) from public, anon, authenticated;
revoke all on function public.customer_get_memberships(text) from public, anon, authenticated;
revoke all on function public.customer_get_appointments_page(text,jsonb) from public, anon, authenticated;
revoke all on function public.customer_portal_capabilities(text) from public, anon, authenticated;

grant execute on function public.customer_get_loyalty_details(text,jsonb) to authenticated;
grant execute on function public.customer_get_reward_catalog(text) to authenticated;
grant execute on function public.customer_get_packages(text,jsonb) to authenticated;
grant execute on function public.customer_get_memberships(text) to authenticated;
grant execute on function public.customer_get_appointments_page(text,jsonb) to authenticated;
grant execute on function public.customer_portal_capabilities(text) to authenticated;

commit;
