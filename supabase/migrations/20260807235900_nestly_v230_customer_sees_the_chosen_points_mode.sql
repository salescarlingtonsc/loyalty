-- Nestly v230 — the customer surface reflects the points mode the firm actually chose.
--
-- Owner, looking at Cubbly's programme page: "instead of showing different points to redeem
-- rewards - it should show the relevant selected model. in this case selected tier - it should
-- reflect the different tiers and its benefits."
--
-- v229 gave a firm ONE use for points (businesses.points_mode = 'redeem' | 'tiers') and refuses
-- redemption server-side in tiers mode. Cubbly is on 'tiers'. The customer surface never learned
-- about that choice, so it was still printing a point-priced reward catalogue with "Show QR at
-- counter" buttons — an offer the server would now reject with
-- "points here count toward membership tiers and cannot be redeemed". Offering a customer an
-- action that cannot succeed is worse than showing nothing.
--
-- customer_portal_capabilities is where the customer surface already asks what a business can do,
-- so the choice is answered there rather than in a new round trip:
--   * 'rewards' is false in tiers mode. The capability now agrees with the redemption gate, so a
--     stale wallet cannot render a redeem button the intent RPC will refuse.
--   * 'tiers' is new: true when this firm's points buy membership AND it has published tiers to
--     climb. A 'redeem' firm gets false, so the customer is never shown a tier ladder for a
--     programme that does not run tiers.
--   * 'points_mode' is new: the choice itself, so the surface can say WHY a section is absent
--     rather than silently dropping it.
--
-- Additive only: every key the surface reads today is unchanged in shape and meaning, apart from
-- 'rewards', whose new false case is exactly the case where redemption is already impossible.

begin;

create or replace function public.customer_portal_capabilities(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_context record;
  v_points_mode text;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required'
      using errcode='28000';
  end if;

  select *
    into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required'
      using errcode='42501';
  end if;

  select business.points_mode
    into v_points_mode
    from public.businesses business
   where business.id=v_context.business_id;

  return jsonb_build_object(
    'wallet',
      'loyalty'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.loyalty_programs program
         where program.business_id=v_context.business_id
           and program.active
      ),
    -- v230: points that buy tier membership are not spendable. The capability says so, so the
    -- customer is never offered a redemption the v229 gate would refuse.
    'rewards',
      'loyalty'=any(v_context.enabled_modules)
      and coalesce(v_points_mode,'redeem') <> 'tiers'
      and exists(
        select 1
          from public.loyalty_programs program
         where program.business_id=v_context.business_id
           and program.active
           and (
             (
               program.loyalty_model='classic'
               and program.kind='points'
               and program.redeem_points>0
               and program.reward_credit_cents>0
             )
             or exists(
               select 1
                 from public.loyalty_reward_versions reward_version
                 join public.businesses business
                   on business.id=reward_version.business_id
                  and business.active_config_version_id=
                    reward_version.config_version_id
                where reward_version.business_id=v_context.business_id
                  and reward_version.active
             )
           )
      ),
    -- v230: the tier ladder belongs to a firm whose points are FOR membership, and only once it
    -- has tiers to climb. A firm that has not chosen yet keeps today's behaviour: tiers show if
    -- they exist, because nothing has been put away.
    'tiers',
      'loyalty'=any(v_context.enabled_modules)
      and coalesce(v_points_mode,'tiers') = 'tiers'
      and exists(
        select 1
          from public.loyalty_programs program
         where program.business_id=v_context.business_id
           and program.active
      )
      and exists(
        select 1
          from public.loyalty_tiers tier
         where tier.business_id=v_context.business_id
      ),
    'points_mode', v_points_mode,
    'activity',
      'loyalty'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.loyalty_programs program
         where program.business_id=v_context.business_id
           and program.active
      )
      and (
        exists(
          select 1
            from public.points_ledger ledger
           where ledger.business_id=v_context.business_id
             and ledger.client_id=v_context.client_id
        )
        or exists(
          select 1
            from public.loyalty_redemptions redemption
           where redemption.business_id=v_context.business_id
             and redemption.client_id=v_context.client_id
        )
        or exists(
          select 1
            from public.reward_grants grant_row
           where grant_row.business_id=v_context.business_id
             and grant_row.client_id=v_context.client_id
        )
      ),
    'appointments',
      'appointments'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.appointments appointment
         where appointment.business_id=v_context.business_id
           and appointment.client_id=v_context.client_id
      ),
    'booking_request',
      'bookings'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.services service
         where service.business_id=v_context.business_id
           and service.active
      ),
    'packages',
      'packages'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.client_packages customer_package
         where customer_package.business_id=v_context.business_id
           and customer_package.client_id=v_context.client_id
      ),
    'membership',
      'memberships'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.memberships membership
         where membership.business_id=v_context.business_id
           and membership.client_id=v_context.client_id
      )
  );
end
$function$;

comment on function public.customer_portal_capabilities(text) is
  'v230: adds points_mode and tiers, and turns rewards off in tiers mode so the customer surface '
  'never offers a redemption the v229 gate refuses. Every other key is unchanged.';

-- create-or-replace preserves grants, but a shipped SECURITY DEFINER function states its own
-- access so the guarantee travels with the file rather than with the database's history.
revoke all on function public.customer_portal_capabilities(text) from public, anon;
grant execute on function public.customer_portal_capabilities(text) to authenticated;

commit;
