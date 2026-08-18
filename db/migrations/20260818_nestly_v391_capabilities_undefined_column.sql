-- v391 (P0): the customer wallet was refusing to load for EVERY customer of EVERY business.
--
-- Symptom, reported by the owner from a phone: "Could not load My Peekaa / This business could
-- not be loaded. Reference: 42703". 42703 is Postgres `undefined_column`.
--
-- Cause. public.business_programmes stores its timestamps as `activated_at` / `deactivated_at`.
-- `running_since` / `paused_since` are the names of the JSON KEYS the readers project those two
-- columns onto — they are not columns, and never have been. Every earlier definition of this
-- reader got that right (v310 line 443, v314, v348 line 203 all read
-- `'running_since', spine.activated_at`). v384 rewrote the function and carried the JSON key
-- names into the column positions:
--
--     'running_since', spine.running_since,      -- no such column
--     'paused_since',  spine.paused_since,       -- no such column
--
-- customer_portal_capabilities is one of the two RPCs the wallet page awaits before it can
-- render (the other is customer_get_business_summary), so the failure was total rather than
-- partial: the SELECT raised 42703 on every call, for every customer, on every business page.
-- It could not have been caught by the migration's own tests, because nothing executed the
-- function against a real row — a plpgsql function body is not parsed for column existence
-- until it runs. See db/tests/v391_capabilities_undefined_column.sql, which now does exactly
-- that.
--
-- Fix. The function is restored byte-for-byte from its v384 definition with only those two
-- column references corrected, so nothing else about v384's programme-mode work changes. The
-- `programmes_contract` marker moves v384 -> v391 so a client can tell which shape it received.
--
-- This is additive and reversible: CREATE OR REPLACE of one reader, no schema change, no data
-- touched. Grants are restated exactly as v384 left them.
begin;

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
    'running_since', spine.activated_at,
    'paused_since', spine.deactivated_at,
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
    'programmes_contract', 'v391',
    'programmes', v_programmes
  );
end;
$$;

comment on function public.customer_portal_capabilities(text) is
  'v391: v384 programme capabilities, with running_since/paused_since read from their real '
  'columns (activated_at/deactivated_at). v384 read them as columns that do not exist, which '
  'raised 42703 on every customer wallet load.';

revoke all on function public.customer_portal_capabilities(text) from public, anon;
grant execute on function public.customer_portal_capabilities(text) to authenticated;

commit;
