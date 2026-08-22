-- nestly_v465 — Home says how many rewards are ready, and says it from the server.
--
-- Owner ruling 2026-08-23 (R1): "add a server-side per-business ready-count inside the wallet RPC
-- Home already calls (no new round trip). MUST reuse the canonical availability logic (v432
-- one-availability-core) — no second definition of 'ready'. Home greeting + per-business cards
-- show the real number; greeting agrees with the sum of the cards; nav badge stays removed."
--
-- WHAT WAS WRONG. public.customer_get_actionable_wallet() builds one card per verified
-- relationship through app.c44_actionable_wallet_card -> app.c45_base_actionable_wallet_card. That
-- card carries `next_eligible_reward` — ONE reward object — and no count of any kind. So every
-- "1 reward ready" Home printed was a literal invented in the browser, and the greeting was the
-- SUM of those literals: LIVE it read "2 rewards ready" while one of the two businesses alone had
-- two. nestly_v457 removed the quantity rather than keep guessing, which was right but left Home
-- unable to say a number at all. This migration gives it one to say.
--
-- WHERE THE NUMBER COMES FROM. app.reward_availability_v432 — the ONE availability calculation
-- nestly_v432 extracted after three near-copies drifted apart. The customer's own business page
-- gets its count from public.customer_get_business_actions_v89, which is that core filtered to
-- unrestricted rewards; the till gets its list from staff_get_customer_actionable_loyalty_v145,
-- the same core. The count added here is that identical filter, so Home, the business page and the
-- counter answer one question one way. No second definition of "ready" is written anywhere.
--
-- THE EXACT PREDICATE, and why each clause is there:
--   availability = 'available_at_counter'            the core's own verdict (spine active, live row
--                                                    active+unpaused, cycle-pinned version, claim
--                                                    window, usage limit, tier gate, stamp slot on
--                                                    the card and unclaimed this cycle, balance)
--   branch_count = service_count = product_count = 0 restricted rewards need a visit context the
--                                                    customer QR path does not carry; v89 excludes
--                                                    them, so a count that included them would
--                                                    promise more than the page below it lists
--   redemption gate                                  v89 rewrites every availability to 'disabled'
--                                                    when the business cannot honour a customer
--                                                    redemption, and the client's
--                                                    customerRewardCanRedeem then counts zero. The
--                                                    same three conditions gate the count here.
--
-- `ready_choose_one` mirrors nestly_v428: several gifts authored on ONE stamp slot are all
-- claimable, but public.stamp_milestone_claims allows exactly one per slot per cycle, so the
-- business page says "Choose 1 reward" rather than counting them. Home cannot derive that — its
-- card carries no per-reward costs — so the server states it, and the two surfaces keep agreeing.
--
-- ADDITIVE ONLY. Two new keys on the card. No existing key changes, no write path is touched, no
-- ordering changes, and `next_eligible_reward` keeps its own (older, narrower) progress rules
-- untouched — rewriting it is not this ruling. Where the two disagree, ready_count is the one the
-- client is instructed to believe.
--
-- COST, measured on production gadpooereceldfpfxsod 2026-08-23 before writing this:
--   app.c45_base_actionable_wallet_card, qa-kaya-toast/Steven Lim   25.4 ms
--   the added count for the SAME pair                               ~6 ms warm (40 ms on the first
--                                                                   call, which is plan/JIT, not work)
--   all SEVEN businesses of the busiest real wallet identity        43.6 ms total, 6.1 ms per card,
--                                                                   4436 buffers, zero disk reads
-- The current wallet RPC costs ~271 ms (v233). An indexed parallel count was therefore NOT written:
-- it would have bought ~40 ms at the price of the second definition of "ready" this ruling forbids.
-- Businesses whose customer redemption is switched off skip the core entirely (the gate is a single
-- capability lookup), which is four of those seven.

begin;

-- ============================================================================================
-- §1  THE COUNT — one call into the one core
-- ============================================================================================
create or replace function app.customer_ready_reward_count_v465(
  p_business uuid,
  p_client uuid,
  p_as_of timestamptz
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_redemption_enabled boolean;
  v_count integer := 0;
  v_choose_one boolean := false;
begin
  -- The same three conditions public.customer_get_business_actions_v89 uses to decide
  -- redemption.enabled. When they do not hold, that reader labels every reward 'disabled' and the
  -- client counts zero — so the count is zero here too, and the core is never called.
  select coalesce(capability.redemption_enabled, false)
           and app.v89_business_module_enabled(p_business, 'loyalty')
           and exists (
             select 1 from public.loyalty_programs program
              where program.business_id = p_business and program.active
           )
    into v_redemption_enabled
    from (select 1) scope
    left join public.business_customer_capabilities_v89 capability
      on capability.business_id = p_business;

  if not coalesce(v_redemption_enabled, false) then
    return jsonb_build_object('count', 0, 'choose_one', false);
  end if;

  with claimable as materialized (
    -- AS MATERIALIZED: read twice below, and the core is the expensive part of this function.
    select core.cost_points, core.unit
      from app.reward_availability_v432(p_business, p_client, p_as_of) core
     where core.branch_count = 0
       and core.service_count = 0
       and core.product_count = 0
       and core.availability = 'available_at_counter'
  ), shared_slots as (
    -- nestly_v428's rule, in SQL: two or more claimable STAMP gifts priced at the same slot.
    -- A zero-cost gift has no slot, exactly as the client's customerStampChooseOneSlotV428 skips
    -- one; points gifts sharing a price are genuinely independent and are not folded.
    select 1
      from claimable
     where claimable.unit = 'stamps'
       and claimable.cost_points > 0
     group by claimable.cost_points
    having count(*) > 1
  )
  select (select count(*)::integer from claimable),
         exists (select 1 from shared_slots)
    into v_count, v_choose_one;

  return jsonb_build_object('count', coalesce(v_count, 0), 'choose_one', coalesce(v_choose_one, false));
end;
$$;

comment on function app.customer_ready_reward_count_v465(uuid, uuid, timestamptz) is
  'nestly_v465: how many catalogue rewards this customer can claim at this business RIGHT NOW, '
  'counted through app.reward_availability_v432 with exactly the filter and redemption gate '
  'public.customer_get_business_actions_v89 applies, so the wallet Home card and the customer''s '
  'own business page can never print two different numbers. Returns {count, choose_one}.';

-- ============================================================================================
-- §2  THE CARD — two additive keys, one call, materialised so the core runs once
-- ============================================================================================
CREATE OR REPLACE FUNCTION app.c45_base_actionable_wallet_card(p_business_id uuid, p_client_id uuid, p_business_slug text, p_business_name text, p_business_industry text, p_business_currency text, p_enabled_modules text[], p_as_of timestamp with time zone)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
  -- V426: `model` and `unit` used to read public.loyalty_programs.loyalty_model — a column the
  -- owner's programme switch (set_programmes_v314) never writes. Cubbly SPA runs a stamps pot
  -- with loyalty_model still saying 'points_tiers', so this card said "pts" over a stamps
  -- balance. The spine is the authority for WHICH programme is running, exactly as
  -- app.customer_live_loyalty_v384 reads it; the vocabulary of both keys is deliberately
  -- unchanged because the client compares them literally.
  with spine as (
    select
      app.programme_running_v371(p_business_id, 'points') as points_running,
      app.programme_running_v371(p_business_id, 'stamps') as stamps_running,
      app.programme_running_v371(p_business_id, 'tiers')  as tiers_running
  ), program as (
    select
      'loyalty' = any(p_enabled_modules) and (coalesce(lp.active, false) and engine.running) as enabled,
      case when 'loyalty' = any(p_enabled_modules) and (coalesce(lp.active, false) and engine.running)
        then case when spine.stamps_running then 'stamps' else 'points' end
      end as unit,
      case when 'loyalty' = any(p_enabled_modules) and (coalesce(lp.active, false) and engine.running)
        then case
          when spine.stamps_running then 'stamps'
          when spine.points_running and spine.tiers_running then 'points_tiers'
          else 'classic'
        end
      end as model,
      case when 'loyalty' = any(p_enabled_modules) and (coalesce(lp.active, false) and engine.running)
        then coalesce(lp.expiry_mode, 'none')
        else 'none'
      end as expiry_mode,
      /* nestly_v437: the rule itself, for the customer explainer. */
      case when 'loyalty' = any(p_enabled_modules) and (coalesce(lp.active, false) and engine.running)
             and coalesce(lp.expiry_mode, 'none') = 'fixed'
        then lp.expiry_days
      end as expiry_days
    from (select 1) scope
    left join public.loyalty_programs lp on lp.business_id = p_business_id
    cross join spine
    -- V371: `lp.active` alone is not "is this programme running". The owner's on/off control
    -- (set_programmes_v314) moves the business_programmes spine and never touches lp.active, so a
    -- switched-off programme kept answering enabled=true here while the business page said "not
    -- running". The spine is the authority; app.programme_running_v371 is the single reader of it.
    cross join lateral (
      select spine.points_running or spine.stamps_running as running
    ) engine
  ), ledger_balance as (
    select greatest(coalesce(sum(pl.points), 0), 0)::integer as units
      from public.points_ledger pl
     where pl.business_id = p_business_id
       and pl.client_id = p_client_id
       and pl.programme_id is not distinct from app.live_balance_programme_v381(p_business_id) /* v384_live_customer_programmes_actionable */
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
       and pb.programme_id is not distinct from app.live_balance_programme_v381(p_business_id)
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
      program.expiry_days,
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
      loyalty_balance.expiry_days,
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
       -- V371: a gift the owner paused stays in the published version snapshot, so the wallet
       -- advertised it as `available_now` while redeem_reward_core refused the claim. The pause
       -- lives on the live row; honour it here so the promise matches what can actually be given.
       and not exists (
         select 1 from public.loyalty_rewards live_reward
          where live_reward.id = rv.reward_id
            and live_reward.business_id = rv.business_id
            and (
              live_reward.paused
              -- V372: a gift belongs to ONE programme and is priced in that programme's unit, so it
              -- must not be offered while that programme is switched off. Cubbly was the live case:
              -- stamps off and points on, with a 2-STAMP gift still catalogued and reported
              -- `available_now` against a 50-POINT balance — two different units, for a programme
              -- that is not running. A reward with no programme is left alone: fail open, never
              -- hide a gift because a link is missing.
              or exists (
                select 1 from public.business_programmes spine
                 where spine.id = live_reward.programme_id
                   and not spine.active
              )
            )
       )
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
      join public.retention_programs prog
        on prog.id = rv.program_id
       and prog.business_id = rv.business_id
       and prog.deleted_at is null
       -- V371: same class as the paused gift above — the live row could be switched off while its
       -- published version stayed active, leaving the visit goal on the customer's card.
       and prog.active
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
  ), ready as materialized (
    /* nestly_v465 (owner ruling R1). AS MATERIALIZED on purpose: the payload is read twice in the
       projection below, and an inlined CTE would run the whole availability core twice per card
       (the v233 lesson -- a flattened LATERAL made this very function run ten times per row). */
    select app.customer_ready_reward_count_v465(p_business_id, p_client_id, p_as_of) as payload
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
      'days', loyalty.expiry_days,
      'expiring_within_7_days', loyalty.expiring_7_units,
      'expiring_units', loyalty.expiring_units,
      'next_expiry_at', loyalty.next_expiry_at
    ),
    'next_eligible_reward', case when reward_candidate.name is null then null else
      jsonb_build_object(
        'name', reward_candidate.name,
        'cost_units', reward_candidate.cost_units,
        'remaining_units', reward_candidate.remaining_units,
        'available_now', reward_candidate.available_now,
        -- V426: the price is denominated in the running programme's unit. The client used to
        -- infer the noun from a stale column and printed "pts" over a stamp card.
        'unit', loyalty.unit
      ) end,
    /* nestly_v465 (owner ruling R1): the per-business READY COUNT Home was missing. v457 had to
       delete the number entirely, because the only reward this card carries is next_eligible_reward
       -- ONE object -- so every "1 reward ready" on Home was a browser-invented literal, and the
       greeting was the sum of those literals. The count is produced HERE, inside the card the
       wallet RPC already builds, so Home costs no extra round trip; and it is counted THROUGH
       app.reward_availability_v432 -- the one availability core the counter, the customer
       catalogue and the business page all read (v432) -- so Home and the business page cannot
       disagree about the same customer. next_eligible_reward is deliberately left alone: it is a
       PROGRESS candidate with its own (older, narrower) rules, and rewriting it is not this
       ruling. Where the two disagree, ready_count is the one the client must believe. */
    'ready_count', (ready.payload->>'count')::integer,
    /* nestly_v428 lives on the business page: several gifts on ONE stamp slot are claimable but
       only one may be taken, so that surface says "Choose 1 reward" instead of counting them.
       Home has to be able to say the same sentence about the same fixture, and it cannot derive
       this -- the card carries no per-reward costs. */
    'ready_choose_one', (ready.payload->>'choose_one')::boolean,
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
    cross join ready
    cross join action;
$function$
;

comment on function app.c45_base_actionable_wallet_card(uuid, uuid, text, text, text, text, text[], timestamptz) is
  'nestly_v465: adds ready_count and ready_choose_one, counted through the v432 availability core '
  'inside the card the wallet RPC already builds (no extra round trip). Every other key, the '
  'ordering inputs and next_eligible_reward are byte-identical to the deployed v437 body.';

-- ============================================================================================
-- §3  ACLS — restated for every function this migration creates or replaces (preflight rule)
--
-- Both live in the app schema and are reached only through SECURITY DEFINER callers. Production
-- proacl for app.c45_base_actionable_wallet_card is {postgres=X/postgres} — no role grant is
-- invented here that the function did not already have.
-- ============================================================================================
revoke all on function app.customer_ready_reward_count_v465(uuid, uuid, timestamptz)
  from public, anon, authenticated;

revoke all on function app.c45_base_actionable_wallet_card(uuid, uuid, text, text, text, text, text[], timestamptz)
  from public, anon, authenticated;

commit;
