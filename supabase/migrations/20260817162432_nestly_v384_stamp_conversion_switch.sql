-- nestly_v384_stamp_conversion_switch
--
-- Customer loyalty reads must follow the live programme spine. Points, tiers and stamps are
-- separate business choices; switching to stamps does not silently relabel points as stamps.
-- Owners can explicitly convert old points at an editable "points per stamp" rate.

begin;

create table if not exists public.programme_stamp_conversions_v384 (
  business_id uuid not null references public.businesses(id) on delete restrict,
  idempotency_key uuid not null,
  points_programme_id uuid not null references public.business_programmes(id) on delete restrict,
  stamps_programme_id uuid not null references public.business_programmes(id) on delete restrict,
  points_per_stamp integer not null check (points_per_stamp > 0),
  converted_customers integer not null default 0,
  converted_points integer not null default 0,
  issued_stamps integer not null default 0,
  leftover_points integer not null default 0,
  response jsonb not null,
  created_at timestamptz not null default now(),
  primary key (business_id, idempotency_key)
);

create unique index if not exists programme_stamp_conversions_v384_once
  on public.programme_stamp_conversions_v384 (business_id, points_programme_id, stamps_programme_id);

alter table public.programme_stamp_conversions_v384 enable row level security;
revoke all privileges on table public.programme_stamp_conversions_v384 from public, anon, authenticated;

create or replace function app.customer_live_loyalty_v384(
  p_business_id uuid,
  p_client_id uuid,
  p_enabled_modules text[],
  p_as_of timestamptz default statement_timestamp()
)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  with live as (
    select
      points.id as points_programme_id,
      stamps.id as stamps_programme_id,
      tiers.id as tiers_programme_id,
      coalesce(lp.expiry_mode, 'none') as expiry_mode
    from (select 1) scope
    left join public.loyalty_programs lp on lp.business_id = p_business_id
    left join lateral (
      select spine.id
        from public.business_programmes spine
       where spine.business_id = p_business_id
         and spine.kind = 'points'
         and spine.active
       order by spine.sort, spine.id
       limit 1
    ) points on true
    left join lateral (
      select spine.id
        from public.business_programmes spine
       where spine.business_id = p_business_id
         and spine.kind = 'stamps'
         and spine.active
       order by spine.sort, spine.id
       limit 1
    ) stamps on true
    left join lateral (
      select spine.id
        from public.business_programmes spine
       where spine.business_id = p_business_id
         and spine.kind = 'tiers'
         and spine.active
       order by spine.sort, spine.id
       limit 1
    ) tiers on true
  ), selected as (
    select
      case when stamps_programme_id is not null then stamps_programme_id
           else points_programme_id end as programme_id,
      case when stamps_programme_id is not null then 'stamps'
           when points_programme_id is not null then 'points'
           when tiers_programme_id is not null then 'tiers'
           else null end as unit,
      case when stamps_programme_id is not null then 'stamps'
           when points_programme_id is not null and tiers_programme_id is not null then 'both'
           when points_programme_id is not null then 'redeem'
           when tiers_programme_id is not null then 'tiers'
           else null end as model,
      expiry_mode,
      points_programme_id,
      stamps_programme_id,
      tiers_programme_id
    from live
  ), ledger_balance as (
    select greatest(coalesce(sum(pl.points), 0), 0)::integer as units
      from selected s
      left join public.points_ledger pl
        on pl.business_id = p_business_id
       and pl.client_id = p_client_id
       and pl.programme_id = s.programme_id
  ), batch_balance as (
    select greatest(coalesce(sum(pb.remaining), 0), 0)::integer as units
      from selected s
      left join public.points_batches pb
        on pb.business_id = p_business_id
       and pb.client_id = p_client_id
       and pb.programme_id = s.programme_id
       and pb.remaining > 0
       and (pb.expires_at is null or pb.expires_at > p_as_of)
  ), credit as (
    select greatest(coalesce(sum(cl.amount_cents), 0), 0)::integer as cents
      from selected s
      left join public.credit_ledger cl
        on cl.business_id = p_business_id
       and cl.client_id = p_client_id
       and ('loyalty' = any(p_enabled_modules))
       and (s.programme_id is not null or s.tiers_programme_id is not null)
  )
  select jsonb_build_object(
    'enabled', 'loyalty' = any(p_enabled_modules)
      and (selected.programme_id is not null or selected.tiers_programme_id is not null),
    'model', selected.model,
    'unit', selected.unit,
    'balance', case when selected.programme_id is not null
      then least(ledger_balance.units, batch_balance.units) else 0 end,
    'ledger_balance', case when selected.programme_id is not null then ledger_balance.units else 0 end,
    'batch_balance', case when selected.programme_id is not null then batch_balance.units else 0 end,
    'credit_balance_cents', credit.cents,
    'programme', jsonb_build_object(
      'id', selected.programme_id,
      'kind', selected.unit,
      'active', selected.programme_id is not null or selected.tiers_programme_id is not null,
      'balance_scope', 'programme_pot'
    ),
    'programmes_contract', 'v384'
  )
  from selected cross join ledger_balance cross join batch_balance cross join credit;
$$;

revoke all privileges on function app.customer_live_loyalty_v384(uuid,uuid,text[],timestamptz)
  from public, anon, authenticated;

create or replace function public.business_preview_stamp_conversion_v384(
  p_business uuid,
  p_points_per_stamp integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_points_programme uuid;
  v_stamps_programme uuid;
  v_rate integer := coalesce(p_points_per_stamp, 0);
  v_result jsonb;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_rate <= 0 then
    raise exception 'points per stamp must be greater than zero' using errcode = '22023';
  end if;

  select id into v_points_programme
    from public.business_programmes
   where business_id = p_business and kind = 'points'
   order by sort, id
   limit 1;
  select id into v_stamps_programme
    from public.business_programmes
   where business_id = p_business and kind = 'stamps'
   order by sort, id
   limit 1;
  if v_points_programme is null or v_stamps_programme is null then
    raise exception 'points and stamp programmes are required' using errcode = '23514';
  end if;

  with balances as (
    select coalesce(l.client_id, b.client_id) as client_id,
           greatest(least(coalesce(l.points_balance, 0), coalesce(b.batch_balance, 0)), 0)::integer as spendable_points
      from (
        select client_id, sum(points)::integer as points_balance
          from public.points_ledger
         where business_id = p_business and programme_id = v_points_programme
         group by client_id
      ) l
      full join (
        select client_id, sum(remaining)::integer as batch_balance
          from public.points_batches
         where business_id = p_business
           and programme_id = v_points_programme
           and remaining > 0
         group by client_id
      ) b using (client_id)
  ), converted as (
    select client_id,
           spendable_points,
           (spendable_points / v_rate)::integer as stamps_to_issue,
           ((spendable_points / v_rate) * v_rate)::integer as points_to_convert,
           (spendable_points - ((spendable_points / v_rate) * v_rate))::integer as leftover_points
      from balances
     where spendable_points > 0
  )
  select jsonb_build_object(
    'points_per_stamp', v_rate,
    'customers', coalesce(count(*) filter (where stamps_to_issue > 0), 0),
    'points_convertible', coalesce(sum(points_to_convert), 0),
    'stamps_to_issue', coalesce(sum(stamps_to_issue), 0),
    'leftover_points', coalesce(sum(leftover_points), 0),
    'already_converted', exists (
      select 1 from public.programme_stamp_conversions_v384 done
       where done.business_id = p_business
         and done.points_programme_id = v_points_programme
         and done.stamps_programme_id = v_stamps_programme
    )
  ) into v_result
  from converted;

  return coalesce(v_result, jsonb_build_object(
    'points_per_stamp', v_rate,
    'customers', 0,
    'points_convertible', 0,
    'stamps_to_issue', 0,
    'leftover_points', 0,
    'already_converted', false
  ));
end;
$$;

create or replace function public.business_switch_to_stamps_v384(
  p_business uuid,
  p_convert_existing_points boolean,
  p_points_per_stamp integer,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_points_programme uuid;
  v_stamps_programme uuid;
  v_rate integer := coalesce(p_points_per_stamp, 0);
  v_existing jsonb;
  v_switch jsonb;
  v_row record;
  v_batch record;
  v_left integer;
  v_take integer;
  v_customers integer := 0;
  v_points integer := 0;
  v_stamps integer := 0;
  v_leftover integer := 0;
  v_response jsonb;
begin
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode = '22023';
  end if;
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if coalesce(p_convert_existing_points, false) and v_rate <= 0 then
    raise exception 'points per stamp must be greater than zero' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('v384:stamp-switch:'||p_business::text, 0));

  select response into v_existing
    from public.programme_stamp_conversions_v384
   where business_id = p_business and idempotency_key = p_idempotency_key;
  if found then
    return v_existing;
  end if;

  select id into v_points_programme
    from public.business_programmes
   where business_id = p_business and kind = 'points'
   order by sort, id
   limit 1;
  select id into v_stamps_programme
    from public.business_programmes
   where business_id = p_business and kind = 'stamps'
   order by sort, id
   limit 1;
  if v_points_programme is null or v_stamps_programme is null then
    raise exception 'points and stamp programmes are required' using errcode = '23514';
  end if;

  v_switch := public.set_programmes_v314(
    p_business,
    jsonb_build_object('stamps', true, 'points', false, 'tiers', false),
    p_idempotency_key
  );

  if coalesce(p_convert_existing_points, false) then
    if exists (
      select 1 from public.programme_stamp_conversions_v384 done
       where done.business_id = p_business
         and done.points_programme_id = v_points_programme
         and done.stamps_programme_id = v_stamps_programme
    ) then
      raise exception 'points have already been converted to this stamp card'
        using errcode = '23505';
    end if;

    for v_row in
      with balances as (
        select coalesce(l.client_id, b.client_id) as client_id,
               greatest(least(coalesce(l.points_balance, 0), coalesce(b.batch_balance, 0)), 0)::integer as spendable_points
          from (
            select client_id, sum(points)::integer as points_balance
              from public.points_ledger
             where business_id = p_business and programme_id = v_points_programme
             group by client_id
          ) l
          full join (
            select client_id, sum(remaining)::integer as batch_balance
              from public.points_batches
             where business_id = p_business
               and programme_id = v_points_programme
               and remaining > 0
             group by client_id
          ) b using (client_id)
      )
      select client_id,
             ((spendable_points / v_rate) * v_rate)::integer as points_to_convert,
             (spendable_points / v_rate)::integer as stamps_to_issue,
             (spendable_points - ((spendable_points / v_rate) * v_rate))::integer as leftover_points
        from balances
       where (spendable_points / v_rate)::integer > 0
       order by client_id
    loop
      v_left := v_row.points_to_convert;
      for v_batch in
        select id, remaining
          from public.points_batches
         where business_id = p_business
           and client_id = v_row.client_id
           and programme_id = v_points_programme
           and remaining > 0
         order by expires_at nulls last, earned_at, id
         for update
      loop
        exit when v_left = 0;
        v_take := least(v_batch.remaining, v_left);
        update public.points_batches
           set remaining = remaining - v_take
         where id = v_batch.id;
        v_left := v_left - v_take;
      end loop;
      if v_left <> 0 then
        raise exception 'could not prove points batch conversion for customer %', v_row.client_id
          using errcode = '23514';
      end if;

      perform set_config('app.points_ledger_write_scope', 'programme_pot_transfer', true);
      insert into public.points_ledger(
        id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id
      ) values (
        gen_random_uuid(), p_business, v_row.client_id, 'adjust', -v_row.points_to_convert,
        null, 'stamp conversion: points spent', null, v_points_programme
      );
      insert into public.points_ledger(
        id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id
      ) values (
        gen_random_uuid(), p_business, v_row.client_id, 'adjust', v_row.stamps_to_issue,
        null, 'stamp conversion: stamps issued', null, v_stamps_programme
      );
      perform set_config('app.points_ledger_write_scope', '', true);

      insert into public.points_batches(
        business_id,client_id,earned,remaining,sale_id,earned_at,expires_at,programme_id
      ) values (
        p_business, v_row.client_id, v_row.stamps_to_issue, v_row.stamps_to_issue,
        null, statement_timestamp(), null, v_stamps_programme
      );

      v_customers := v_customers + 1;
      v_points := v_points + v_row.points_to_convert;
      v_stamps := v_stamps + v_row.stamps_to_issue;
      v_leftover := v_leftover + v_row.leftover_points;
    end loop;
  end if;

  v_response := jsonb_build_object(
    'ok', true,
    'converted', coalesce(p_convert_existing_points, false),
    'points_per_stamp', case when coalesce(p_convert_existing_points, false) then v_rate else null end,
    'customers', v_customers,
    'points_converted', v_points,
    'stamps_issued', v_stamps,
    'leftover_points', v_leftover,
    'programmes', v_switch->'programmes'
  );

  if coalesce(p_convert_existing_points, false) then
    insert into public.programme_stamp_conversions_v384(
      business_id,idempotency_key,points_programme_id,stamps_programme_id,
      points_per_stamp,converted_customers,converted_points,issued_stamps,leftover_points,response
    ) values (
      p_business,p_idempotency_key,v_points_programme,v_stamps_programme,
      v_rate,v_customers,v_points,v_stamps,v_leftover,v_response
    );
  end if;

  return v_response;
exception when others then
  perform set_config('app.points_ledger_write_scope', '', true);
  raise;
end;
$$;

revoke all privileges on function public.business_preview_stamp_conversion_v384(uuid,integer)
  from public, anon;
grant execute on function public.business_preview_stamp_conversion_v384(uuid,integer)
  to authenticated;
revoke all privileges on function public.business_switch_to_stamps_v384(uuid,boolean,integer,uuid)
  from public, anon;
grant execute on function public.business_switch_to_stamps_v384(uuid,boolean,integer,uuid)
  to authenticated;

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
          'loyalty', app.customer_live_loyalty_v384(ctx.business_id, ctx.client_id, ctx.enabled_modules, now()),
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
    ) per_firm;

  return v_wallet;
end;
$$;

create or replace function public.customer_get_business_summary(p_business_slug text)
returns jsonb
language plpgsql
stable security definer
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

  select identity_id, business_id, client_id, business_name, business_slug,
         business_industry, business_currency, enabled_modules into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'business', jsonb_build_object(
      'id', v_context.business_id,
      'slug', v_context.business_slug,
      'name', v_context.business_name,
      'industry', v_context.business_industry,
      'currency', v_context.business_currency,
      'logo_url', app.v267_business_logo_url(v_context.business_id),
      'review_url', (select b.review_url from public.businesses b where b.id = v_context.business_id)
    ),
    'loyalty', app.customer_live_loyalty_v384(
      v_context.business_id, v_context.client_id, v_context.enabled_modules, now()
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
  ) into v_summary;

  return v_summary;
end;
$$;

create or replace function public.customer_portal_capabilities(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_context record;
  v_points_active boolean;
  v_stamps_active boolean;
  v_tiers_active boolean;
  v_referral_active boolean;
  v_points_programme uuid;
  v_stamps_programme uuid;
  v_tiers_programme uuid;
  v_wallet boolean;
  v_rewards boolean;
  v_tiers boolean;
  v_points_mode text;
  v_programmes jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode='28000';
  end if;

  select * into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode='42501';
  end if;

  select
    bool_or(kind = 'points' and active),
    bool_or(kind = 'stamps' and active),
    bool_or(kind = 'tiers' and active),
    bool_or(kind = 'referral' and active)
    into v_points_active, v_stamps_active, v_tiers_active, v_referral_active
    from public.business_programmes
   where business_id = v_context.business_id;
  select id into v_points_programme
    from public.business_programmes
   where business_id = v_context.business_id and kind = 'points' and active
   order by sort, id limit 1;
  select id into v_stamps_programme
    from public.business_programmes
   where business_id = v_context.business_id and kind = 'stamps' and active
   order by sort, id limit 1;
  select id into v_tiers_programme
    from public.business_programmes
   where business_id = v_context.business_id and kind = 'tiers' and active
   order by sort, id limit 1;

  v_wallet := 'loyalty'=any(v_context.enabled_modules)
    and (coalesce(v_points_active,false) or coalesce(v_stamps_active,false)
         or coalesce(v_tiers_active,false));
  v_rewards := 'loyalty'=any(v_context.enabled_modules)
    and (coalesce(v_points_active,false) or coalesce(v_stamps_active,false))
    and exists (
      select 1
        from public.loyalty_reward_versions rv
        join public.businesses business
          on business.id = rv.business_id
         and business.active_config_version_id = rv.config_version_id
        join public.business_programmes spine
          on spine.id = rv.programme_id
         and spine.business_id = rv.business_id
         and spine.active
       where rv.business_id = v_context.business_id
         and rv.active
    );
  v_tiers := 'loyalty'=any(v_context.enabled_modules)
    and coalesce(v_tiers_active,false)
    and exists(select 1 from public.loyalty_tiers tier where tier.business_id=v_context.business_id);
  v_points_mode := case
    when coalesce(v_stamps_active,false) then 'stamps'
    when coalesce(v_points_active,false) and coalesce(v_tiers_active,false) then 'both'
    when coalesce(v_points_active,false) then 'redeem'
    when coalesce(v_tiers_active,false) then 'tiers'
    else null end;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', spine.id,
    'kind', spine.kind,
    'active', spine.active,
    'running_since', spine.running_since,
    'paused_since', spine.paused_since,
    'balance_scope', 'programme_pot',
    'customer_visible', case spine.kind
      when 'points' then v_rewards and spine.active
      when 'stamps' then v_rewards and spine.active
      when 'tiers' then v_tiers and spine.active
      when 'referral' then coalesce(v_referral_active,false) and spine.active
      else false end
  ) order by spine.sort, spine.kind), '[]'::jsonb)
  into v_programmes
  from public.business_programmes spine
  where spine.business_id = v_context.business_id;

  return jsonb_build_object(
    'wallet', v_wallet,
    'rewards', v_rewards,
    'tiers', v_tiers,
    'points_mode', v_points_mode,
    'activity',
      v_wallet and (
        exists(select 1 from public.points_ledger ledger
                where ledger.business_id=v_context.business_id
                  and ledger.client_id=v_context.client_id
                  and ledger.programme_id in (v_points_programme, v_stamps_programme))
        or exists(select 1 from public.loyalty_redemptions redemption
                   where redemption.business_id=v_context.business_id
                     and redemption.client_id=v_context.client_id)
        or exists(select 1 from public.reward_grants grant_row
                   where grant_row.business_id=v_context.business_id
                     and grant_row.client_id=v_context.client_id)
      ),
    'appointments',
      'appointments'=any(v_context.enabled_modules)
      and exists(select 1 from public.appointments appointment
                  where appointment.business_id=v_context.business_id
                    and appointment.client_id=v_context.client_id),
    'booking_request',
      'bookings'=any(v_context.enabled_modules)
      and exists(select 1 from public.services service
                  where service.business_id=v_context.business_id
                    and service.active),
    'packages',
      'packages'=any(v_context.enabled_modules)
      and exists(select 1 from public.client_packages customer_package
                  where customer_package.business_id=v_context.business_id
                    and customer_package.client_id=v_context.client_id),
    'membership',
      'memberships'=any(v_context.enabled_modules)
      and exists(select 1 from public.memberships membership
                  where membership.business_id=v_context.business_id
                    and membership.client_id=v_context.client_id),
    'programmes_contract', 'v384',
    'programmes', v_programmes
  );
end;
$$;

do $$
declare
  v_def text;
begin
  select pg_get_functiondef('public.customer_get_reward_catalog(text)'::regprocedure)
    into strict v_def;
  if position('v384_live_customer_programmes_catalog' in v_def) = 0 then
    v_def := replace(v_def,
      'v_stamps_programme uuid;',
      'v_stamps_programme uuid;'||E'\n  v_live_points_programme uuid;');
    v_def := replace(v_def,
      $needle$  select coalesce(sum(pl.points), 0)::integer into v_balance
    from public.points_ledger pl
   where pl.business_id = v_context.business_id and pl.client_id = v_context.client_id;$needle$,
      $needle$  select spine.id into v_live_points_programme
    from public.business_programmes spine
   where spine.business_id = v_context.business_id and spine.kind = 'points' and spine.active
   order by spine.sort, spine.id limit 1;
  select coalesce(sum(pl.points), 0)::integer into v_balance
    from public.points_ledger pl
   where pl.business_id = v_context.business_id and pl.client_id = v_context.client_id
     and pl.programme_id = v_live_points_programme; /* v384_live_customer_programmes_catalog */$needle$);
    v_def := replace(v_def,
      $needle$  select spine.id into v_stamps_programme
    from public.business_programmes spine
   where spine.business_id = v_context.business_id and spine.kind = 'stamps';$needle$,
      $needle$  select spine.id into v_stamps_programme
    from public.business_programmes spine
   where spine.business_id = v_context.business_id and spine.kind = 'stamps' and spine.active
   order by spine.sort, spine.id limit 1;$needle$);
    execute v_def;
  end if;

  select pg_get_functiondef('public.customer_get_business_actions_v89(uuid)'::regprocedure)
    into strict v_def;
  if position('v384_live_customer_programmes_actions' in v_def) = 0 then
    v_def := replace(v_def,
      'v_stamps_programme uuid;v_stamp_filled integer;v_stamp_cycle integer;',
      'v_live_points_programme uuid;v_stamps_programme uuid;v_stamp_filled integer;v_stamp_cycle integer;');
    v_def := replace(v_def,
      $needle$  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger
    where business_id=p_business and client_id=v_client;$needle$,
      $needle$  select spine.id into v_live_points_programme from public.business_programmes spine
    where spine.business_id=p_business and spine.kind='points' and spine.active
    order by spine.sort, spine.id limit 1;
  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger
    where business_id=p_business and client_id=v_client and programme_id=v_live_points_programme;$needle$);
    v_def := replace(v_def,
      $needle$  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0;
  select spine.id into v_stamps_programme from public.business_programmes spine
    where spine.business_id=p_business and spine.kind='stamps';$needle$,
      $needle$  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0
      and programme_id=v_live_points_programme;
  select spine.id into v_stamps_programme from public.business_programmes spine
    where spine.business_id=p_business and spine.kind='stamps' and spine.active
    order by spine.sort, spine.id limit 1; /* v384_live_customer_programmes_actions */$needle$);
    execute v_def;
  end if;

  select pg_get_functiondef('app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamp with time zone)'::regprocedure)
    into strict v_def;
  if position('v384_live_customer_programmes_actionable' in v_def) = 0 then
    v_def := replace(v_def,
      $needle$       and pl.client_id = p_client_id$needle$,
      $needle$       and pl.client_id = p_client_id
       and pl.programme_id is not distinct from app.live_balance_programme_v381(p_business_id) /* v384_live_customer_programmes_actionable */$needle$);
    v_def := replace(v_def,
      $needle$       and pb.remaining > 0
       and (pb.expires_at is null or pb.expires_at > p_as_of)$needle$,
      $needle$       and pb.remaining > 0
       and pb.programme_id is not distinct from app.live_balance_programme_v381(p_business_id)
       and (pb.expires_at is null or pb.expires_at > p_as_of)$needle$);
    execute v_def;
  end if;
end $$;

revoke all on function public.customer_get_wallet() from public, anon;
grant execute on function public.customer_get_wallet() to authenticated;
revoke all on function public.customer_get_business_summary(text) from public, anon;
grant execute on function public.customer_get_business_summary(text) to authenticated, service_role;
revoke all on function public.customer_portal_capabilities(text) from public, anon;
grant execute on function public.customer_portal_capabilities(text) to authenticated;
revoke all on function public.customer_get_reward_catalog(text) from public, anon;
grant execute on function public.customer_get_reward_catalog(text) to authenticated;
revoke all on function public.customer_get_business_actions_v89(uuid) from public, anon;
grant execute on function public.customer_get_business_actions_v89(uuid) to authenticated;

commit;
