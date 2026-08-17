-- nestly_v376 — the customer is never offered store credit either.
--
-- Follow-up to v375, found while verifying it end to end. v375 retired the classic
-- points-for-store-credit model in the business-side reader and made
-- app.redeem_points_v40_internal refuse outright — but customer_get_business_actions_v89 was
-- still building a "Redeem N points" action for a classic tenant, priced in credit. Nine
-- production programmes matched that branch and ONE has customer redemption enabled, so a real
-- customer could still have prepared a redemption QR for something the counter would now refuse.
-- Refusing the write without withdrawing the offer is worse than either alone.
--
-- The action is removed rather than made conditional: there is no state in which points may be
-- exchanged for credit any more, so a condition would only be a place for the offer to come back.
-- Nothing else in the payload changes shape — `enabled` and the catalogue `rewards` array are
-- untouched, and no intent has ever been created against this branch (0 rows).
--
-- VERIFIED against production inside a rolled-back transaction on 2026-08-17 — see
-- db/tests/v376_no_classic_redemption_offer.sql. Three checks, from a fixture in the exact shape
-- of the affected tenant (classic, 150 points, SGD 1.50 credit, redemption enabled): the pre-v376
-- function offers "Redeem 150 points"; the repaired one offers nothing; the redemption block keeps
-- its shape.

begin;


-- ------------------------------------------------- public.customer_get_business_actions_v89
CREATE OR REPLACE FUNCTION public.customer_get_business_actions_v89(p_business uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_identity uuid;v_client uuid;v_result jsonb;
  v_balance integer;v_batch_balance integer;
  v_program public.loyalty_programs%rowtype;
  v_stamps_programme uuid;v_stamp_filled integer;v_stamp_cycle integer;
begin
  v_identity:=app.v31_current_identity();
  select link.client_id into v_client from public.customer_links link
  where link.identity_id=v_identity and link.auth_user_id=auth.uid()
    and link.business_id=p_business and link.state='verified';
  if not found then raise exception 'verified customer link required' using errcode='42501';end if;
  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger
    where business_id=p_business and client_id=v_client;
  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0;
  select spine.id into v_stamps_programme from public.business_programmes spine
    where spine.business_id=p_business and spine.kind='stamps';
  select coalesce(sp.filled,0),coalesce(sp.cycle_index,0)
    into v_stamp_filled,v_stamp_cycle
    from app.stamp_progress_v323(p_business,v_client) sp;
  select * into v_program from public.loyalty_programs program
    where program.business_id=p_business and program.active
    order by program.id limit 1;
  select jsonb_build_object(
    'business',jsonb_build_object('id',business.id,'slug',business.slug,
      'name',business.name,'industry',business.industry,'currency',business.currency),
    'booking',jsonb_build_object('enabled',
      coalesce(capability.booking_enabled,false)
      and app.v89_business_module_enabled(p_business,'bookings') and exists(
        select 1 from public.services service where service.business_id=p_business
          and service.active and service.show_on_booking_page),
      'public_slug',case when coalesce(capability.booking_enabled,false)
        and app.v89_business_module_enabled(p_business,'bookings') and exists(
        select 1 from public.services service where service.business_id=p_business
          and service.active and service.show_on_booking_page)
        then business.slug else null end),
    'redemption',jsonb_build_object(
      'enabled',coalesce(capability.redemption_enabled,false)
        and app.v89_business_module_enabled(p_business,'loyalty')
        and v_program.id is not null,
      -- v376: the points-for-store-credit action is never offered. v375 retired the model and made
      -- app.redeem_points_v40_internal refuse, so leaving this in place would have shown a customer
      -- a redemption their own counter could no longer honour.
      'classic',null::jsonb),
    'appointment_changes',jsonb_build_object(
      'enabled',coalesce(capability.appointment_changes_enabled,false)
        and app.v89_business_module_enabled(p_business,'appointments')),
    'rewards',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',reward.id,'name',coalesce(reward.customer_name,reward.name),
        'redemption_kind','catalog_reward',
        'cost_points',reward_version.cost_points,
        'availability',case
          when not coalesce(capability.redemption_enabled,false)
            or not app.v89_business_module_enabled(p_business,'loyalty')
            then 'disabled'
          when reward_version.claim_available_from is not null
            and reward_version.claim_available_from>now() then 'not_started'
          when reward_version.claim_available_until is not null
            and reward_version.claim_available_until<=now() then 'ended'
          when reward_version.usage_limit is not null and (
            select count(*) from public.loyalty_redemptions redemption
            where redemption.business_id=p_business
              and redemption.client_id=v_client
              and redemption.reward_id=reward.id
          )>=reward_version.usage_limit then 'limit_reached'
          when v_stamps_programme is not null and reward.programme_id=v_stamps_programme
            and exists(select 1 from public.stamp_milestone_claims claim
                        where claim.business_id=p_business and claim.client_id=v_client
                          and claim.programme_id=v_stamps_programme
                          and claim.cycle_index=coalesce(v_stamp_cycle,0)
                          and claim.reward_id=reward.id)
            then 'limit_reached'
          when (case when v_stamps_programme is not null and reward.programme_id=v_stamps_programme
                     then coalesce(v_stamp_filled,0)
                     else least(v_balance,v_batch_balance) end)<reward_version.cost_points
            then 'insufficient_balance'
          else 'available_at_counter' end
      ) order by reward.sort,reward.id)
      from public.loyalty_rewards reward
      join public.loyalty_reward_versions reward_version
        on reward_version.reward_id=reward.id
       and reward_version.business_id=reward.business_id
      where reward.business_id=p_business and reward.active and not reward.paused
        and exists(select 1 from public.business_programmes spine
                    where spine.id=reward.programme_id and spine.active)
        and reward_version.config_version_id=business.active_config_version_id
        and reward_version.active
        -- Customer QR redemption carries no visit context in v89. Restricted
        -- rewards remain visible through the ordinary wallet catalog, but are
        -- truthfully excluded from this actionable scan list.
        and not exists(select 1 from public.loyalty_reward_branches restriction
          where restriction.reward_version_id=reward_version.id)
        and not exists(select 1 from public.loyalty_reward_services restriction
          where restriction.reward_version_id=reward_version.id)
        and not exists(select 1 from public.loyalty_reward_products restriction
          where restriction.reward_version_id=reward_version.id)
    ),'[]'::jsonb)
  ) into v_result
  from public.businesses business
  left join public.business_customer_capabilities_v89 capability
    on capability.business_id=business.id
  where business.id=p_business;
  return v_result;
end
$function$;

-- Grants restated verbatim from production (CREATE OR REPLACE preserves them).
revoke all on function public.customer_get_business_actions_v89(uuid) from public, anon;
grant execute on function public.customer_get_business_actions_v89(uuid) to postgres, service_role, authenticated;

commit;
