-- NESTLY v116 — CLASSIC REWARD PROJECTION
--
-- A classic points programme defines its redeemable reward directly on
-- loyalty_programs. It does not require a versioned catalogue reward row.
-- Keep the customer capability projection aligned with the actionable v89
-- business contract so the customer portal does not hide a valid classic
-- redemption.

begin;

create or replace function public.customer_portal_capabilities(
  p_business_slug text
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_context record;
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

  return jsonb_build_object(
    'wallet',
      'loyalty'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.loyalty_programs program
         where program.business_id=v_context.business_id
           and program.active
      ),
    'rewards',
      'loyalty'=any(v_context.enabled_modules)
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
$$;

comment on function public.customer_portal_capabilities(text)
  is 'v116 linked-customer surface capabilities; classic rewards are projected from the active programme without requiring catalogue rows.';

revoke all on function public.customer_portal_capabilities(text)
  from public,anon,authenticated;
grant execute on function public.customer_portal_capabilities(text)
  to authenticated;

commit;
