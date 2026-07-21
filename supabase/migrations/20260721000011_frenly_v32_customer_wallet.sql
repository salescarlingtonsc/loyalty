-- FRENLY v32 - CUSTOMER WALLET READ MODEL
--
-- Local review candidate. This migration adds the customer-facing read boundary
-- after v30 identity and v31 verified business links. It does not grant browser
-- access to customer identity, relationship, or client tables.

begin;

-- Operational release gates are private database state, not frontend constants.
-- Only an operator/service-role migration may open these after SMTP, alerting,
-- and support runbooks are accepted.
create table if not exists app.platform_feature_flags (
  feature_key text primary key check (feature_key ~ '^[a-z][a-z0-9_]{2,63}$'),
  enabled boolean not null default false,
  changed_at timestamptz not null default now(),
  changed_by uuid
);
insert into app.platform_feature_flags(feature_key,enabled) values
  ('customer_wallet',false),('customer_actions',false),('customer_notifications',false)
on conflict(feature_key) do nothing;
alter table app.platform_feature_flags enable row level security;
revoke all privileges on table app.platform_feature_flags from public,anon,authenticated;

create or replace function app.platform_feature_enabled(p_feature_key text)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select coalesce((select f.enabled from app.platform_feature_flags f
                    where f.feature_key=$1),false)
$$;
revoke all on function app.platform_feature_enabled(text) from public,anon,authenticated;

-- The one scope resolver used by every public customer read RPC. A business slug
-- is a lookup hint only: the effective business and client come exclusively from
-- auth.uid() -> active customer identity -> verified customer link.
create or replace function app.v32_customer_wallet_context(p_business_slug text default null)
returns table (
  identity_id uuid,
  business_id uuid,
  client_id uuid,
  business_name text,
  business_slug text,
  business_industry text,
  business_currency text,
  enabled_modules text[]
)
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_slug text := nullif(lower(btrim(coalesce(p_business_slug, ''))), '');
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_wallet') then
    raise exception 'customer wallet is not enabled' using errcode = '0A000';
  end if;
  perform 1
    from public.customer_identities ci
   where ci.auth_user_id = v_actor and ci.status = 'active';
  if not found then
    raise exception 'active customer identity required' using errcode = '42501';
  end if;

  return query
    select ci.id, l.business_id, l.client_id, b.name, b.slug, b.industry, b.currency,
           coalesce(b.enabled_modules, '{}'::text[])
      from public.customer_identities ci
      join public.customer_links l
        on l.identity_id = ci.id
       and l.auth_user_id = v_actor
       and l.state = 'verified'
      join public.businesses b on b.id = l.business_id
     where ci.auth_user_id = v_actor
       and ci.status = 'active'
       -- `state` is the customer-link status; only status = 'verified' is live scope.
       and (v_slug is null or b.slug = v_slug)
     order by b.slug, l.id;
end;
$$;

revoke all on function app.v32_customer_wallet_context(text)
  from public, anon, authenticated;

-- Returns a list of separate firm cards. This deliberately has no platform
-- total: money, points, memberships, packages, and appointments stay inside
-- the customer relationship with the firm that owns them.
create or replace function public.customer_get_wallet()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_wallet jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_wallet') then
    raise exception 'customer wallet is not enabled' using errcode = '0A000';
  end if;

  select coalesce(jsonb_agg(card order by business_slug), '[]'::jsonb)
    into v_wallet
    from (
      select
        ctx.business_slug,
        jsonb_build_object(
          'business', jsonb_build_object(
            'slug', ctx.business_slug,
            'name', ctx.business_name,
            'industry', ctx.business_industry,
            'currency', ctx.business_currency
          ),
          'loyalty', jsonb_build_object(
            'enabled', 'loyalty' = any(ctx.enabled_modules) and coalesce(lp.active, false),
            'model', case when 'loyalty' = any(ctx.enabled_modules) and coalesce(lp.active, false)
                          then lp.loyalty_model end,
            'unit', case when 'loyalty' = any(ctx.enabled_modules) and coalesce(lp.active, false)
                           then case when lp.loyalty_model = 'stamps' then 'stamps' else 'points' end end,
            'balance', case when 'loyalty' = any(ctx.enabled_modules) and coalesce(lp.active, false)
                            then coalesce(point_balance.balance, 0) else 0 end,
            'credit_balance_cents', case when 'loyalty' = any(ctx.enabled_modules) and coalesce(lp.active, false)
                                         then coalesce(credit_balance.balance_cents, 0) else 0 end
          ),
          'packages', jsonb_build_object(
            'enabled', 'packages' = any(ctx.enabled_modules),
            'active_count', case when 'packages' = any(ctx.enabled_modules)
                                 then coalesce(package_summary.active_count, 0) else 0 end,
            'sessions_remaining', case when 'packages' = any(ctx.enabled_modules)
                                       then coalesce(package_summary.sessions_remaining, 0) else 0 end
          ),
          'membership', jsonb_build_object(
            'enabled', 'memberships' = any(ctx.enabled_modules),
            'active', case when 'memberships' = any(ctx.enabled_modules)
                           then coalesce(membership_summary.active, false) else false end,
            'current_period_ends_at', case when 'memberships' = any(ctx.enabled_modules)
                                           then membership_summary.current_period_end end
          ),
          'upcoming_appointments', jsonb_build_object(
            'enabled', 'appointments' = any(ctx.enabled_modules),
            'count', case when 'appointments' = any(ctx.enabled_modules)
                          then coalesce(appointment_summary.upcoming_count, 0) else 0 end
          )
        ) as card
      from app.v32_customer_wallet_context(null) ctx
      left join public.loyalty_programs lp
        on lp.business_id = ctx.business_id
      left join lateral (
        select coalesce(sum(pl.points), 0)::integer as balance
          from public.points_ledger pl
         where 'loyalty' = any(ctx.enabled_modules)
           and coalesce(lp.active, false)
           and pl.business_id = ctx.business_id
           and pl.client_id = ctx.client_id
      ) point_balance on true
      left join lateral (
        select coalesce(sum(cl.amount_cents), 0)::integer as balance_cents
          from public.credit_ledger cl
         where 'loyalty' = any(ctx.enabled_modules)
           and coalesce(lp.active, false)
           and cl.business_id = ctx.business_id
           and cl.client_id = ctx.client_id
      ) credit_balance on true
      left join lateral (
        select count(*)::integer as active_count,
               coalesce(sum(cp.remaining), 0)::integer as sessions_remaining
          from public.client_packages cp
         where 'packages' = any(ctx.enabled_modules)
           and cp.business_id = ctx.business_id
           and cp.client_id = ctx.client_id
           and cp.status = 'active'
           and cp.remaining > 0
      ) package_summary on true
      left join lateral (
        select (count(*) > 0) as active, min(m.current_period_end) as current_period_end
          from public.memberships m
         where 'memberships' = any(ctx.enabled_modules)
           and m.business_id = ctx.business_id
           and m.client_id = ctx.client_id
           and m.status in ('active', 'paused', 'cancel_at_period_end')
      ) membership_summary on true
      left join lateral (
        select count(*)::integer as upcoming_count
          from public.appointments a
         where 'appointments' = any(ctx.enabled_modules)
           and a.business_id = ctx.business_id
           and a.client_id = ctx.client_id
           and a.status = 'booked'
           and a.starts_at >= now()
      ) appointment_summary on true
      group by ctx.identity_id, ctx.business_id, ctx.client_id, ctx.business_name,
               ctx.business_slug, ctx.business_industry, ctx.business_currency, ctx.enabled_modules,
               lp.loyalty_model, lp.active, point_balance.balance, credit_balance.balance_cents,
               package_summary.active_count, package_summary.sessions_remaining,
               membership_summary.active, membership_summary.current_period_end,
               appointment_summary.upcoming_count
    ) per_firm;

  return v_wallet;
end;
$$;

-- One firm summary. A missing, unlinked, or unverified relationship deliberately
-- produces the same authorization failure; this RPC never reveals whether a slug exists.
create or replace function public.customer_get_business_summary(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_context record;
  v_summary jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_wallet') then
    raise exception 'customer wallet is not enabled' using errcode = '0A000';
  end if;

  -- The app context resolves auth.uid() through customer_links with link status = 'verified'.
  select identity_id, business_id, client_id, business_name, business_slug,
         business_industry, business_currency, enabled_modules into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'business', jsonb_build_object(
      'slug', v_context.business_slug,
      'name', v_context.business_name,
      'industry', v_context.business_industry,
      'currency', v_context.business_currency
    ),
    'loyalty', jsonb_build_object(
      'enabled', 'loyalty' = any(v_context.enabled_modules) and coalesce(lp.active, false),
      'model', case when 'loyalty' = any(v_context.enabled_modules) and coalesce(lp.active, false)
                    then lp.loyalty_model end,
      'unit', case when 'loyalty' = any(v_context.enabled_modules) and coalesce(lp.active, false)
                     then case when lp.loyalty_model = 'stamps' then 'stamps' else 'points' end end,
      'balance', case when 'loyalty' = any(v_context.enabled_modules) and coalesce(lp.active, false) then coalesce((
        select sum(pl.points)::integer
          from public.points_ledger pl
         where pl.business_id = v_context.business_id
           and pl.client_id = v_context.client_id
      ), 0) else 0 end,
      'credit_balance_cents', case when 'loyalty' = any(v_context.enabled_modules) and coalesce(lp.active, false) then coalesce((
        select sum(cl.amount_cents)::integer
          from public.credit_ledger cl
         where cl.business_id = v_context.business_id
           and cl.client_id = v_context.client_id
      ), 0) else 0 end
    ),
    'packages', jsonb_build_object(
      'enabled', 'packages' = any(v_context.enabled_modules),
      'active_count', case when 'packages' = any(v_context.enabled_modules) then coalesce((
        select count(*)::integer
          from public.client_packages cp
         where cp.business_id = v_context.business_id
           and cp.client_id = v_context.client_id
           and cp.status = 'active'
           and cp.remaining > 0
      ), 0) else 0 end,
      'sessions_remaining', case when 'packages' = any(v_context.enabled_modules) then coalesce((
        select sum(cp.remaining)::integer
          from public.client_packages cp
         where cp.business_id = v_context.business_id
           and cp.client_id = v_context.client_id
           and cp.status = 'active'
           and cp.remaining > 0
      ), 0) else 0 end
    ),
    'membership', jsonb_build_object(
      'enabled', 'memberships' = any(v_context.enabled_modules),
      'active', case when 'memberships' = any(v_context.enabled_modules) then exists (
        select 1 from public.memberships m
         where m.business_id = v_context.business_id
           and m.client_id = v_context.client_id
           and m.status in ('active', 'paused', 'cancel_at_period_end')
      ) else false end,
      'current_period_ends_at', case when 'memberships' = any(v_context.enabled_modules) then (
        select min(m.current_period_end)
          from public.memberships m
         where m.business_id = v_context.business_id
           and m.client_id = v_context.client_id
           and m.status in ('active', 'paused', 'cancel_at_period_end')
      ) end
    ),
    'upcoming_appointments', jsonb_build_object(
      'enabled', 'appointments' = any(v_context.enabled_modules),
      'count', case when 'appointments' = any(v_context.enabled_modules) then (
        select count(*)::integer
          from public.appointments a
         where a.business_id = v_context.business_id
           and a.client_id = v_context.client_id
           and a.status = 'booked'
           and a.starts_at >= now()
      ) else 0 end
    )
  ) into v_summary
    from (select 1) scope
    left join public.loyalty_programs lp
      on lp.business_id = v_context.business_id;

  return coalesce(v_summary, jsonb_build_object(
    'business', jsonb_build_object(
      'slug', v_context.business_slug,
      'name', v_context.business_name,
      'industry', v_context.business_industry,
      'currency', v_context.business_currency
    ),
    'loyalty', jsonb_build_object(
      'enabled', false,
      'model', null,
      'unit', null,
      'balance', 0,
      'credit_balance_cents', 0
    ),
    'packages', jsonb_build_object('enabled', false, 'active_count', 0, 'sessions_remaining', 0),
    'membership', jsonb_build_object('enabled', false, 'active', false, 'current_period_ends_at', null),
    'upcoming_appointments', jsonb_build_object('enabled', false, 'count', 0)
  ));
end;
$$;

-- The customer can inspect a bounded, chronological list of their own upcoming
-- and recent appointments through the explicit allowlist below.
create or replace function public.customer_get_appointments(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_context record;
  v_appointments jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_wallet') then
    raise exception 'customer wallet is not enabled' using errcode = '0A000';
  end if;

  -- The app context resolves auth.uid() through customer_links with link status = 'verified'.
  select identity_id, business_id, client_id, business_name, business_slug,
         business_industry, business_currency, enabled_modules into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  if not ('appointments' = any(v_context.enabled_modules)) then
    raise exception 'appointments module is unavailable for this business' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'appointment_id', listed.id,
      'starts_at', listed.starts_at,
      'ends_at', listed.ends_at,
      'status', listed.status,
      'service_name', listed.service_name,
      'branch_name', listed.branch_name
    ) order by listed.sort_group, listed.starts_at asc, listed.id
  ), '[]'::jsonb)
    into v_appointments
    from (
      select a.id, a.starts_at, a.ends_at, a.status,
             case when a.status = 'booked' and a.starts_at >= now() then 0 else 1 end as sort_group,
             s.name as service_name, br.name as branch_name
        from public.appointments a
        left join public.services s
          on s.id = a.service_id and s.business_id = a.business_id
        left join public.branches br
          on br.id = a.branch_id and br.business_id = a.business_id
       where a.business_id = v_context.business_id
         and a.client_id = v_context.client_id
         and a.status in ('booked', 'completed', 'cancelled', 'no_show')
       order by case when a.status = 'booked' and a.starts_at >= now() then 0 else 1 end,
                a.starts_at asc, a.id
       limit 20
    ) listed;

  return v_appointments;
end;
$$;

-- Capabilities are deliberately data-aware. A verified relationship alone does
-- not expose a dormant module; an enabled module alone does not make an action
-- relevant without supporting customer data or an active service catalog.
create or replace function public.customer_portal_capabilities(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_context record;
  v_capabilities jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_wallet') then
    raise exception 'customer wallet is not enabled' using errcode = '0A000';
  end if;

  -- The app context resolves auth.uid() through customer_links with link status = 'verified'.
  select identity_id, business_id, client_id, business_name, business_slug,
         business_industry, business_currency, enabled_modules into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'wallet',
      'loyalty' = any(v_context.enabled_modules)
      and exists (
        select 1 from public.loyalty_programs lp
         where lp.business_id = v_context.business_id
           and lp.active
      ),
    'appointments',
      'appointments' = any(v_context.enabled_modules)
      and exists (
        select 1 from public.appointments a
         where a.business_id = v_context.business_id
           and a.client_id = v_context.client_id
      ),
    'booking_request',
      'bookings' = any(v_context.enabled_modules)
      and exists (
        select 1 from public.services s
         where s.business_id = v_context.business_id
           and s.active
      ),
    'packages',
      'packages' = any(v_context.enabled_modules)
      and exists (
        select 1 from public.client_packages cp
         where cp.business_id = v_context.business_id
           and cp.client_id = v_context.client_id
           and cp.status = 'active'
           and cp.remaining > 0
      ),
    'membership',
      'memberships' = any(v_context.enabled_modules)
      and exists (
        select 1 from public.memberships m
         where m.business_id = v_context.business_id
           and m.client_id = v_context.client_id
           and m.status in ('active', 'paused', 'cancel_at_period_end')
      )
  ) into v_capabilities;

  return v_capabilities;
end;
$$;

revoke all on function public.customer_get_wallet()
  from public, anon, authenticated;
revoke all on function public.customer_get_business_summary(text)
  from public, anon, authenticated;
revoke all on function public.customer_get_appointments(text)
  from public, anon, authenticated;
revoke all on function public.customer_portal_capabilities(text)
  from public, anon, authenticated;

grant execute on function public.customer_get_wallet() to authenticated;
grant execute on function public.customer_get_business_summary(text) to authenticated;
grant execute on function public.customer_get_appointments(text) to authenticated;
grant execute on function public.customer_portal_capabilities(text) to authenticated;

commit;
