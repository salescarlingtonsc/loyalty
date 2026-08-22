-- nestly_v432 — the staff redeem-now list offers exactly what the customer can redeem.
--
-- Owner ruling 2026-08-22: hidden counter-only gifts are not supported. The till's
-- "Rewards this customer can claim" list must derive from the same canonical availability
-- the customer sees — Customer → canonical entitlement/availability → currently redeemable
-- rewards → staff redeem-now — never from the raw catalogue.
--
-- The live defect (Cubbly, stamps engine): staff_get_customer_actionable_loyalty_v145 judged
-- every published gift by `balance >= cost` against the live pot. On a stamps tenant that pot
-- holds STAMPS, so two points-programme gifts whose points spine is switched OFF ("Free Lotion"
-- 10, "moisturizer" 10) were offered as redeemable — 764 stamps >= 10 "points" — while
-- app.redeem_reward_core would have refused both ('catalog redemption is inactive'). The
-- customer's own surfaces excluded them (V372). Staff saw 4 gifts; the customer saw 2.
--
-- Root cause: THREE near-copies of the availability calculation had drifted —
--   staff_get_customer_actionable_loyalty_v145  (no spine gate, no stamp semantics, no tier gate)
--   customer_get_reward_catalog                 (published-version read for stamp gifts, no
--                                                past-card-end check)
--   customer_get_business_actions_v89           (no tier gate, no past-card-end check)
-- while the truth redemption enforces lives in app.redeem_reward_core: spine active, live row
-- active+unpaused, version row from the CYCLE-PINNED config for stamp gifts (v416), claim window,
-- usage limit, tier gate (v176), stamp gift on the card and unclaimed this cycle with enough
-- stamps filled, points gift covered by the programme pot.
--
-- This migration extracts that truth into ONE core — app.reward_availability_v432 — and re-issues
-- all three readers on top of it. No write path changes: redemption, earning, entitlement and
-- ledger semantics are untouched; only what the lists PROMISE moves, and it moves toward what
-- redemption already enforces. Grant-funded rewards (welcome / bring-back / referral / vouchers)
-- are not listed here — staff_get_customer_entitlements_v102 already reads the canonical grant
-- rows with expiry withheld, and the till shows them as their own labelled groups.
--
-- Availability vocabulary (superset of the previous strings; the client's copy map has a safe
-- default for values it does not know):
--   not_started | ended | tier_locked | limit_reached | claimed_this_cycle | not_on_card
--   | insufficient_balance | available_at_counter
-- Two deliberate narrowings, both matching redemption:
--   • a stamp gift priced past the card's end is 'not_on_card', never promised
--     (redeem_reward_core: 'this gift sits past the end of the stamp card');
--   • a reward whose programme link is missing is excluded (redeem_reward_core refuses it with
--     XX001; V372's fail-open display promised a claim the counter would refuse).

begin;

-- ============================================================================================
-- §1  THE ONE AVAILABILITY CALCULATION
-- ============================================================================================
create or replace function app.reward_availability_v432(
  p_business uuid,
  p_client uuid,
  p_as_of timestamptz default now()
) returns table (
  reward_id uuid,
  reward_version_id uuid,
  customer_name text,
  description text,
  image_ref text,
  terms text,
  instructions text,
  taxonomy_label text,
  fulfillment_kind text,
  cost_points integer,
  credit_cents integer,
  claim_available_from timestamptz,
  claim_available_until timestamptz,
  entitlement_expiry_days integer,
  sort integer,
  source text,
  unit text,
  gate_threshold numeric,
  gate_label text,
  tier_met boolean,
  branch_count integer,
  service_count integer,
  product_count integer,
  used_count integer,
  remaining_units integer,
  availability text
)
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  with business as (
    select b.id, b.active_config_version_id
      from public.businesses b
     where b.id = p_business
  ), stamps_spine as (
    select spine.id from public.business_programmes spine
     where spine.business_id = p_business and spine.kind = 'stamps' and spine.active
     order by spine.sort, spine.id limit 1
  ), points_spine as (
    select spine.id from public.business_programmes spine
     where spine.business_id = p_business and spine.kind = 'points' and spine.active
     order by spine.sort, spine.id limit 1
  ), stamp as (
    -- filled / cycle_index / slots exactly as redemption reads them (app.stamp_progress_v323).
    select coalesce(sp.slots, 0) as slots,
           coalesce(sp.filled, 0) as filled,
           coalesce(sp.cycle_index, 0) as cycle_index
      from app.stamp_progress_v323(p_business, p_client) sp
     limit 1
  ), pot as (
    -- The points balance a redemption can actually drain: the live points pot, capped by the
    -- proven batch remainder in the same pot (redeem_reward_core requires both).
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
    -- nestly_v416: a stamp gift is judged against the config the customer's OPEN card was
    -- started under — the same version redeem_reward_core will select.
    select case when exists (select 1 from stamps_spine)
      then app.stamp_cycle_version_v416(p_business, p_client, (select id from stamps_spine))
      end as config_version_id
  )
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
      when (case when shape.is_stamp then coalesce(stamp.filled, 0) else pot.balance end)
           < rv.cost_points
        then 'insufficient_balance'
      else 'available_at_counter'
    end as availability
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
  -- The programme gate redemption enforces: the reward's own spine row must exist and be
  -- active. This also excludes rewards with no programme link — redeem_reward_core refuses
  -- those (XX001), so listing them would promise a claim the counter cannot honour.
  where exists (
    select 1 from public.business_programmes spine
     where spine.id = live.programme_id and spine.active
  )
$$;

-- ============================================================================================
-- §2  CUSTOMER CATALOGUE — same rows, availability from the core
-- ============================================================================================
create or replace function public.customer_get_reward_catalog(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record;
  v_result jsonb;
  v_balance_scope text;
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

  -- nestly_v432: availability is the ONE core calculation the staff redeem-now list and the
  -- customer hero list also read, so the counter and Customer View cannot disagree about what
  -- is redeemable. Restricted rewards stay visible here with their eligibility scope, exactly
  -- as before.
  select coalesce(jsonb_agg(jsonb_build_object(
    'customer_name', core.customer_name,
    'description', core.description,
    'image_ref', core.image_ref,
    'terms', core.terms,
    'instructions', core.instructions,
    'taxonomy_label', core.taxonomy_label,
    'fulfillment_kind', core.fulfillment_kind,
    'cost_points', core.cost_points,
    'claim_available_from', core.claim_available_from,
    'claim_available_until', core.claim_available_until,
    'entitlement_expiry_days', core.entitlement_expiry_days,
    'availability', core.availability,
    'claim_method', 'counter',
    'source', core.source,
    'unit', core.unit,
    'tier_requirement', case when core.gate_threshold is null then null else jsonb_build_object(
      'tier_label', core.gate_label,
      'threshold', core.gate_threshold,
      'met', coalesce(core.tier_met, false)
    ) end,
    'eligibility', jsonb_build_object(
      'branches', jsonb_build_object('scope', case when core.branch_count = 0 then 'all' else 'restricted' end, 'count', core.branch_count),
      'services', jsonb_build_object('scope', case when core.service_count = 0 then 'all' else 'restricted' end, 'count', core.service_count),
      'products', jsonb_build_object('scope', case when core.product_count = 0 then 'all' else 'restricted' end, 'count', core.product_count)
    )
  ) order by core.sort, core.customer_name), '[]'::jsonb)
  into v_result
  from app.reward_availability_v432(v_context.business_id, v_context.client_id, now()) core;

  -- v230/v241: the one owner choice for what points are FOR, so the wallet tells one
  -- story. As an OBJECT: appending to the rewards array made the mode unreadable (v241).
  v_balance_scope := app.programme_balance_scope_v312(v_context.business_id);
  return jsonb_build_object(
    'rewards', coalesce(v_result, '[]'::jsonb),
    'points_mode', (select points_mode from public.businesses where id = v_context.business_id),
    'programmes_contract', 'v310',
    'balance_scope', v_balance_scope,
    'programmes', jsonb_build_array(jsonb_build_object(
      'kind', case when exists (
                     select 1 from public.loyalty_programs programme_v310
                      where programme_v310.business_id = v_context.business_id
                        and programme_v310.loyalty_model = 'stamps')
                   then 'stamps' else 'points' end,
      'balance_scope', v_balance_scope,
      'rewards', coalesce(v_result, '[]'::jsonb))));
end;
$$;

-- ============================================================================================
-- §3  CUSTOMER HOME ACTIONS — same rows, availability from the core
-- ============================================================================================
create or replace function public.customer_get_business_actions_v89(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_identity uuid;v_client uuid;v_result jsonb;
  v_program public.loyalty_programs%rowtype;
begin
  v_identity:=app.v31_current_identity();
  select link.client_id into v_client from public.customer_links link
  where link.identity_id=v_identity and link.auth_user_id=auth.uid()
    and link.business_id=p_business and link.state='verified';
  if not found then raise exception 'verified customer link required' using errcode='42501';end if;
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
    -- nestly_v432: availability from the one core the counter and the catalogue read. This adds
    -- the tier gate and the past-card-end rule this list was missing, and pins stamp gifts to
    -- the customer's open-cycle config exactly as redemption does. Restricted rewards remain
    -- truthfully excluded from this actionable scan list (customer QR redemption carries no
    -- visit context in v89).
    'rewards',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',core.reward_id,'name',core.customer_name,
        'redemption_kind','catalog_reward',
        'cost_points',core.cost_points,
        'source',core.source,
        'unit',core.unit,
        'availability',case
          when not coalesce(capability.redemption_enabled,false)
            or not app.v89_business_module_enabled(p_business,'loyalty')
            then 'disabled'
          else core.availability end
      ) order by core.sort,core.reward_id)
      from app.reward_availability_v432(p_business, v_client, now()) core
      where core.branch_count=0 and core.service_count=0 and core.product_count=0
    ),'[]'::jsonb)
  ) into v_result
  from public.businesses business
  left join public.business_customer_capabilities_v89 capability
    on capability.business_id=business.id
  where business.id=p_business;
  return v_result;
end
$$;

-- ============================================================================================
-- §4  STAFF REDEEM-NOW — offers only what the core says is redeemable, grouped by source
-- ============================================================================================
create or replace function public.staff_get_customer_actionable_loyalty_v145(p_business uuid, p_client uuid, p_branch uuid default null::uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
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
    -- nestly_v432: the rows come from the ONE availability core the customer's own surfaces
    -- read (app.reward_availability_v432), so this list can never offer a gift the counter
    -- would refuse. Only two states are actionable at a till: redeemable now, or genuine
    -- progress toward a gift ("5 more stamps"). Everything else — wrong programme, off the
    -- card, claimed on this card, tier-locked, expired, limit reached — is simply not listed.
    -- Restricted rewards stay excluded as before: v404 manual redemption carries no service
    -- or product context.
    select
      core.source,
      core.availability,
      core.unit,
      core.reward_id,
      core.customer_name as name,
      core.cost_points as cost_units,
      core.credit_cents,
      core.fulfillment_kind,
      core.sort as sort_order,
      core.remaining_units,
      (redemption_capability.enabled
        and core.availability = 'available_at_counter') as available_now
    from app.reward_availability_v432(p_business, p_client, v_as_of) core
    cross join redemption_capability
    where core.branch_count = 0
      and core.service_count = 0
      and core.product_count = 0
      and core.availability in ('available_at_counter', 'insufficient_balance')
  ), reward_list as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'source', candidate.source,
      'availability', candidate.availability,
      'unit', candidate.unit,
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
      'availability', candidate.availability,
      'unit', candidate.unit,
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
$$;

-- ============================================================================================
-- §5  ACLS — restated for every function this migration re-issues (preflight rule)
-- ============================================================================================
revoke all on function app.reward_availability_v432(uuid, uuid, timestamptz)
  from public, anon, authenticated;

revoke all on function public.customer_get_reward_catalog(text) from public, anon;
grant execute on function public.customer_get_reward_catalog(text) to authenticated, service_role;

revoke all on function public.customer_get_business_actions_v89(uuid) from public, anon;
grant execute on function public.customer_get_business_actions_v89(uuid) to authenticated, service_role;

revoke all on function public.staff_get_customer_actionable_loyalty_v145(uuid, uuid, uuid) from public, anon;
grant execute on function public.staff_get_customer_actionable_loyalty_v145(uuid, uuid, uuid) to authenticated, service_role;

commit;
