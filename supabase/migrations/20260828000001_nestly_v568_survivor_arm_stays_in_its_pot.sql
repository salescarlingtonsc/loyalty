-- nestly_v568 -- a stamp card's survivor gifts stay in the stamp card's own pot.
--
-- THE DEFECT (owner, KKY demo screenshot 01:53 2026-08-28): the customer hero showed
-- "READY - 5 stamps - Nata de coco - Redeem now" while the business editor's stamp 5 holds
-- "Free upsize". Nata de coco is a 5-POINT gift on the points programme the owner switched OFF.
--
-- MECHANISM: app.reward_availability_v432 has two arms. Arm 0 (the live card) derives whether a
-- reward is a stamp reward from the reward's OWN programme_id and reports that programme's
-- active flag, so a parked pot's gifts are correctly filtered by the outer `where
-- rows.programme_active`. Arm 1 -- the nestly_v478 "survivor" arm that keeps an earned gift
-- claimable after its cycle closes -- joins reward versions to the closed cycle by
-- config_version_id and `rv.cost_points <= sc.slots` ONLY. Any active reward version in that
-- config version whose cost is within the card length is admitted, whatever pot it belongs to,
-- and arm 1 hardcodes source='stamp_card', unit='stamps' and the STAMPS spine's active flag --
-- so the outer filter cannot catch it. A points gift priced at 5 on a 5-slot card therefore
-- surfaced as a stamp gift the customer was invited to redeem, and app.redeem_reward_core then
-- refused it ('catalog redemption is inactive', because its own programme is off).
--
-- Blast radius, measured before the fix: ONE tenant, ONE reward, 6 rows (KKY demo / Nata de coco
-- across three closed cycles). No cross-pot payout was possible -- the redemption core's own
-- programme gate always refused it -- so this misled customers and wasted counter time; no
-- balance or ledger was ever wrong.
--
-- THE FIX: one predicate. The survivor arm requires the reward to belong to the very programme
-- whose cycle it is surviving (`live.programme_id = sc.programme_id`, and sc.programme_id is
-- already joined to the stamps spine). Arm 0 is untouched -- it never had the bug.
--
-- ROLLBACK: db/tests/v568_survivor_arm_stays_in_its_pot.sql

begin;

do $pre$
begin
  if position('and live.programme_id = sc.programme_id' in pg_get_functiondef('app.reward_availability_v432(uuid,uuid,timestamptz)'::regprocedure)) > 0 then
    raise exception 'v568: the survivor arm already carries its pot predicate';
  end if;
  if position('and rv.cost_points <= sc.slots' in pg_get_functiondef('app.reward_availability_v432(uuid,uuid,timestamptz)'::regprocedure)) = 0 then
    raise exception 'v568: expected the v478 survivor arm to patch -- re-derive from the live definition';
  end if;
end
$pre$;

CREATE OR REPLACE FUNCTION app.reward_availability_v432(p_business uuid, p_client uuid, p_as_of timestamp with time zone DEFAULT now())
 RETURNS TABLE(reward_id uuid, reward_version_id uuid, customer_name text, description text, image_ref text, terms text, instructions text, taxonomy_label text, fulfillment_kind text, cost_points integer, credit_cents integer, claim_available_from timestamp with time zone, claim_available_until timestamp with time zone, entitlement_expiry_days integer, sort integer, source text, unit text, gate_threshold numeric, gate_label text, tier_met boolean, branch_count integer, service_count integer, product_count integer, used_count integer, remaining_units integer, reward_expires_at timestamp with time zone, availability text, quantity integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
  with business as (
    select b.id, b.active_config_version_id
      from public.businesses b
     where b.id = p_business
  ), stamps_spine as (
    select spine.id, spine.active from public.business_programmes spine
     where spine.business_id = p_business and spine.kind = 'stamps'
     order by spine.sort, spine.id limit 1
  ), points_spine as (
    select spine.id from public.business_programmes spine
     where spine.business_id = p_business and spine.kind = 'points' and spine.active
     order by spine.sort, spine.id limit 1
  ), stamp as (
    select coalesce(sp.slots, 0) as slots,
           coalesce(sp.filled, 0) as filled,
           coalesce(sp.cycle_index, 0) as cycle_index
      from app.stamp_progress_v323(p_business, p_client) sp
     limit 1
  ), pot as (
    select least(
      (select coalesce(sum(pl.points), 0)::integer
         from public.points_ledger pl
        where pl.business_id = p_business and pl.client_id = p_client
          and pl.programme_id = (select id from points_spine)),
      (select coalesce(sum(pb.remaining), 0)::integer
         from public.points_batches pb
        where pb.business_id = p_business and pb.client_id = p_client
          and pb.remaining > 0
          and pb.programme_id = (select id from points_spine))
    ) as balance
  ), metric as (
    select app.v176_tier_gate_metric(p_business, p_client) as value
  ), stamp_version as (
    select case when exists (select 1 from stamps_spine)
      then app.stamp_cycle_version_v416(p_business, p_client, (select id from stamps_spine))
      end as config_version_id
  )
  select ranked.reward_id, ranked.reward_version_id, ranked.customer_name, ranked.description,
         ranked.image_ref, ranked.terms, ranked.instructions, ranked.taxonomy_label,
         ranked.fulfillment_kind, ranked.cost_points, ranked.credit_cents,
         ranked.claim_available_from, ranked.claim_available_until, ranked.entitlement_expiry_days,
         ranked.sort, ranked.source, ranked.unit, ranked.gate_threshold, ranked.gate_label,
         ranked.tier_met, ranked.branch_count, ranked.service_count, ranked.product_count,
         ranked.used_count, ranked.remaining_units, ranked.reward_expires_at,
         ranked.availability, ranked.quantity
  from (
    select rows.*, row_number() over (
      partition by rows.reward_id
      order by (rows.availability = 'available_at_counter') desc, rows.arm
    ) as rn,
      sum(case when rows.availability = 'available_at_counter' then 1 else 0 end)
        over (partition by rows.reward_id)::integer as quantity
    from (
      select
        live.id as reward_id,
        rv.id as reward_version_id,
        rv.customer_name,
        rv.description,
        rv.image_ref,
        rv.terms,
        rv.instructions,
        rv.taxonomy_label,
        rv.fulfillment_kind,
        rv.cost_points::integer,
        rv.credit_cents::integer,
        rv.claim_available_from,
        rv.claim_available_until,
        rv.entitlement_expiry_days,
        rv.sort::integer,
        case when shape.is_stamp then 'stamp_card' else 'points' end as source,
        case when shape.is_stamp then 'stamps' else 'points' end as unit,
        gate.threshold as gate_threshold,
        gate.label as gate_label,
        case when gate.threshold is null then null
             else metric.value >= gate.threshold end as tier_met,
        scope.branch_count,
        scope.service_count,
        scope.product_count,
        usage.used_count,
        greatest(rv.cost_points - (case when shape.is_stamp
          then coalesce(stamp.filled, 0) else pot.balance end), 0)::integer as remaining_units,
        expiry.expires_at as reward_expires_at,
        case
          when rv.claim_available_from is not null and rv.claim_available_from > p_as_of
            then 'not_started'
          when rv.claim_available_until is not null and rv.claim_available_until <= p_as_of
            then 'ended'
          when gate.threshold is not null and metric.value < gate.threshold
            then 'tier_locked'
          when rv.usage_limit is not null and usage.used_count >= rv.usage_limit
            then 'limit_reached'
          when shape.is_stamp
            and (coalesce(stamp.slots, 0) <= 0 or rv.cost_points > coalesce(stamp.slots, 0))
            then 'not_on_card'
          when shape.is_stamp and claimed.this_cycle
            then 'claimed_this_cycle'
          when shape.is_stamp and (expiry.recorded
               or (expiry.expires_at is not null and expiry.expires_at <= p_as_of))
            then 'reward_expired'
          when (case when shape.is_stamp then coalesce(stamp.filled, 0) else pot.balance end)
               < rv.cost_points
            then 'insufficient_balance'
          else 'available_at_counter'
        end as availability,
        exists (
          select 1 from public.business_programmes sp2
           where sp2.id = live.programme_id and sp2.active
        ) as programme_active,
        0 as arm
      from business
      join public.loyalty_rewards live
        on live.business_id = business.id
       and live.active
       and not live.paused
      cross join lateral (
        select coalesce(live.programme_id = (select id from stamps_spine), false) as is_stamp
      ) shape
      join public.loyalty_reward_versions rv
        on rv.reward_id = live.id
       and rv.business_id = live.business_id
       and rv.active
       and rv.config_version_id = case when shape.is_stamp
         then coalesce((select sv.config_version_id from stamp_version sv),
                       business.active_config_version_id)
         else business.active_config_version_id end
      left join stamp on true
      cross join pot
      cross join metric
      cross join lateral (
        select app.v176_reward_gate_threshold(p_business, rv.min_tier_id, rv.min_tier_threshold)
                 as threshold,
               app.v176_reward_gate_label(p_business, rv.min_tier_id) as label
      ) gate
      cross join lateral (
        select (select count(*)::integer from public.loyalty_reward_branches e
                 where e.reward_version_id = rv.id) as branch_count,
               (select count(*)::integer from public.loyalty_reward_services e
                 where e.reward_version_id = rv.id) as service_count,
               (select count(*)::integer from public.loyalty_reward_products e
                 where e.reward_version_id = rv.id) as product_count
      ) scope
      cross join lateral (
        select count(*)::integer as used_count
          from public.loyalty_redemptions lr
         where lr.business_id = p_business and lr.client_id = p_client
           and lr.reward_id = live.id
      ) usage
      cross join lateral (
        select exists (
          select 1 from public.stamp_milestone_claims claim
           where claim.business_id = p_business
             and claim.client_id = p_client
             and claim.programme_id = live.programme_id
             and claim.cycle_index = coalesce(stamp.cycle_index, 0)
             and claim.reward_id = live.id
        ) as this_cycle
      ) claimed
      cross join lateral (
        select case when shape.is_stamp then (
                 select x.expires_at
                   from app.stamp_reward_expiry_v464(p_business, p_client, live.programme_id,
                          coalesce(stamp.cycle_index, 0), rv.cost_points) x) end as expires_at,
               case when shape.is_stamp then exists (
                 select 1 from public.stamp_reward_expiries_v464 e
                  where e.business_id = p_business and e.client_id = p_client
                    and e.programme_id = live.programme_id
                    and e.cycle_index = coalesce(stamp.cycle_index, 0)
                    and e.reward_id = live.id) else false end as recorded
      ) expiry
      where live.programme_id is not null
        and exists (select 1 from public.business_programmes sp3
                     where sp3.id = live.programme_id)

      union all

      select
        live.id,
        rv.id,
        rv.customer_name,
        rv.description,
        rv.image_ref,
        rv.terms,
        rv.instructions,
        rv.taxonomy_label,
        rv.fulfillment_kind,
        rv.cost_points::integer,
        rv.credit_cents::integer,
        rv.claim_available_from,
        rv.claim_available_until,
        rv.entitlement_expiry_days,
        rv.sort::integer,
        'stamp_card' as source,
        'stamps' as unit,
        gate.threshold,
        gate.label,
        case when gate.threshold is null then null
             else metric.value >= gate.threshold end,
        scope.branch_count,
        scope.service_count,
        scope.product_count,
        usage.used_count,
        0 as remaining_units,
        expiry.expires_at as reward_expires_at,
        case
          when rv.claim_available_from is not null and rv.claim_available_from > p_as_of
            then 'not_started'
          when rv.claim_available_until is not null and rv.claim_available_until <= p_as_of
            then 'ended'
          when gate.threshold is not null and metric.value < gate.threshold
            then 'tier_locked'
          when rv.usage_limit is not null and usage.used_count >= rv.usage_limit
            then 'limit_reached'
          when expiry.recorded
               or (expiry.expires_at is not null and expiry.expires_at <= p_as_of)
            then 'reward_expired'
          else 'available_at_counter'
        end as availability,
        coalesce((select ss.active from stamps_spine ss), false) as programme_active,
        1 as arm
      from public.stamp_cycles sc
      join stamps_spine on stamps_spine.id = sc.programme_id
      join public.loyalty_reward_versions rv
        on rv.business_id = p_business
       and rv.config_version_id = sc.config_version_id
       and rv.active
       and rv.cost_points <= sc.slots
      join public.loyalty_rewards live
        on live.id = rv.reward_id
       and live.business_id = p_business
       and live.active
       and not live.paused
       -- nestly_v568: the survivor arm must stay in its own pot. It joins reward VERSIONS by the
       -- closed cycle's config version and `cost_points <= sc.slots` alone, which says nothing
       -- about WHICH programme the reward belongs to -- so a POINTS gift whose cost happened to be
       -- <= the stamp card's length was admitted as a stamp-card survivor, dressed in this arm's
       -- hardcoded source='stamp_card' / unit='stamps', and passed the outer programme_active
       -- filter because this arm reports the STAMPS spine's flag rather than the reward's own.
       -- Recorded case (KKY demo, 2026-08-28): a 5-POINT gift on a switched-off points programme
       -- was offered as "READY - 5 stamps - Nata de coco" beside the real stamp gift, while
       -- app.redeem_reward_core refused it ('catalog redemption is inactive') -- an advertised
       -- gift the counter would not honour, which is the one thing this file exists to prevent.
       -- Arm 0 never had the bug: it derives `shape.is_stamp` from the reward's own programme_id
       -- and reports that programme's active flag. This is the same predicate, stated for arm 1.
       and live.programme_id = sc.programme_id
      cross join metric
      cross join lateral (
        select app.v176_reward_gate_threshold(p_business, rv.min_tier_id, rv.min_tier_threshold)
                 as threshold,
               app.v176_reward_gate_label(p_business, rv.min_tier_id) as label
      ) gate
      cross join lateral (
        select (select count(*)::integer from public.loyalty_reward_branches e
                 where e.reward_version_id = rv.id) as branch_count,
               (select count(*)::integer from public.loyalty_reward_services e
                 where e.reward_version_id = rv.id) as service_count,
               (select count(*)::integer from public.loyalty_reward_products e
                 where e.reward_version_id = rv.id) as product_count
      ) scope
      cross join lateral (
        select count(*)::integer as used_count
          from public.loyalty_redemptions lr
         where lr.business_id = p_business and lr.client_id = p_client
           and lr.reward_id = live.id
      ) usage
      cross join lateral (
        select (select x.expires_at
                  from app.stamp_reward_expiry_v464(p_business, p_client, sc.programme_id,
                         sc.cycle_index, rv.cost_points) x) as expires_at,
               exists (select 1 from public.stamp_reward_expiries_v464 e
                        where e.business_id = p_business and e.client_id = p_client
                          and e.programme_id = sc.programme_id
                          and e.cycle_index = sc.cycle_index
                          and e.reward_id = rv.reward_id) as recorded
      ) expiry
      where sc.business_id = p_business
        and sc.client_id = p_client
        and sc.origin in ('expired','claimed','completed')
        and not exists (
          select 1 from public.stamp_milestone_claims claim
           where claim.business_id = p_business
             and claim.client_id = p_client
             and claim.programme_id = sc.programme_id
             and claim.cycle_index = sc.cycle_index
             and claim.reward_id = rv.reward_id
        )
    ) rows
    where rows.programme_active
       -- v495: the rescue for a stopped programme's open card is withdrawn; the intent path refuses those gifts, and a listed reward the counter refuses is worse than none
  ) ranked
  where ranked.rn = 1
$function$;

-- ACL restated verbatim from the live proacl (app-internal helper; no anon/authenticated grant).
revoke all on function app.reward_availability_v432(uuid,uuid,timestamptz) from public, anon, authenticated, service_role;

commit;
