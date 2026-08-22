-- Rollback-only acceptance for nestly_v465 — Home's ready count comes from the one availability core.
--   supabase db query --linked -f db/tests/v465_home_ready_count.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Every check EXECUTES the functions. No check reads a function's source text to decide whether the
-- behaviour is right; §12 reads source only to prove a SECOND definition of "ready" was not written,
-- which is a structural claim and cannot be executed.
--
-- The fixture is production tenant qa-kaya-toast (a stamps merchant: Steven Lim holds a 15-slot card
-- with claimable gifts at slots 4 and 6). Every row this suite inserts is rolled back. The expected
-- values are computed from the tenant's own state rather than hardcoded, so the suite keeps meaning
-- something as that tenant changes; the fixture rows it adds are asserted as DELTAS.
--
--   01  fixture shape: a stamps tenant, a verified customer, redemption switched on
--   02  NEGATIVE CONTROL: the DEPLOYED wallet card carries no ready count at all — the defect
--       (v457 had to delete the number because the server never sent one). Runs before the
--       migration's bodies are installed, so it fails loudly if v465 is already applied.
--   03  the count equals the v432 core's own verdict, filtered exactly as customer_get_business_actions_v89 does
--   04  a ZERO-COST gift counts as ready (v399: cost 0 is always redeemable, not "not a reward")
--   05  a TIER-GATED gift is not counted while the gate is unmet, and is counted once it is met
--   06  a programme pause: the count follows the core (v435 Rule 7 keeps stamp survivors
--       claimable); pausing the gifts themselves does empty it
--   07  customer redemption switched off ⇒ 0, even though the core still returns claimable rows
--   08  a RESTRICTED gift (branch-scoped) is excluded, exactly as v89 excludes it
--   09  HOME == BUSINESS PAGE: the count equals what customer_get_business_actions_v89 reports to
--       the real authenticated customer. This is owner ruling R1's invariant.
--   10  the card carries the same number the function returns, and the two new keys only
--   11  choose_one follows v428's slot rule: two claimable gifts on ONE stamp slot, not two prices
--   12  no second definition of "ready" was written

begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v465_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v465_user(uuid) to public;

-- ---------------------------------------------------------------------------------------------
-- 01  fixture shape, read from production rather than assumed
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  c uuid := '9acc0c04-14be-40b8-9473-b40ae5f95b40';
  v_spine uuid; v_redeem boolean; v_verified boolean; v_core integer;
begin
  select id into v_spine from public.business_programmes
   where business_id = b and kind = 'stamps' and active order by sort, id limit 1;
  select coalesce(redemption_enabled, false) into v_redeem
    from public.business_customer_capabilities_v89 where business_id = b;
  select exists (select 1 from public.customer_links link
                  where link.client_id = c and link.business_id = b and link.state = 'verified')
    into v_verified;
  select count(*)::integer into v_core
    from app.reward_availability_v432(b, c, now()) core
   where core.availability = 'available_at_counter';
  insert into _r values('01_fixture',
    case when v_spine is not null and v_redeem and v_verified and v_core > 0
      then 'PASS stamps spine, verified link, redemption on, ' || v_core || ' claimable gift(s)'
      else 'FAIL spine=' || coalesce(v_spine::text,'null') || ' redeem=' || v_redeem
           || ' verified=' || v_verified || ' claimable=' || v_core end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 02  NEGATIVE CONTROL — the deployed card, before this migration replaces it
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_card jsonb;
begin
  select app.c45_base_actionable_wallet_card(
    '38b30e6d-de73-4c2b-a2ca-19b08950896c'::uuid,
    '9acc0c04-14be-40b8-9473-b40ae5f95b40'::uuid,
    'qa-kaya-toast', 'QA Kaya Toast', 'cafe', 'SGD',
    (select enabled_modules from public.businesses where id = '38b30e6d-de73-4c2b-a2ca-19b08950896c'),
    now()) into v_card;
  insert into _r values('02_negative_control_deployed_card_has_no_count',
    case when not (v_card ? 'ready_count')
      then 'PASS the deployed card sends no ready count — the defect v465 fixes'
      else 'FAIL the deployed card already carries ready_count=' || (v_card->>'ready_count')
           || '; v465 is applied, so this control proves nothing — re-point it' end);
  insert into _r values('02_negative_control_deployed_card_still_has_next_eligible',
    case when v_card ? 'next_eligible_reward'
      then 'PASS the ONE reward object Home used to guess from is present'
      else 'FAIL next_eligible_reward is missing; the fixture is not the shape v465 was written against' end);
end $$;

-- =============================================================================================
-- INSTALL — the migration's own bodies, verbatim, inside this transaction
-- =============================================================================================

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

-- ---------------------------------------------------------------------------------------------
-- 03  the count IS the core's verdict, filtered exactly as v89 filters it
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  c uuid := '9acc0c04-14be-40b8-9473-b40ae5f95b40';
  v_expected integer; v_actual integer;
begin
  select count(*)::integer into v_expected
    from app.reward_availability_v432(b, c, now()) core
   where core.branch_count = 0 and core.service_count = 0 and core.product_count = 0
     and core.availability = 'available_at_counter';
  v_actual := (app.customer_ready_reward_count_v465(b, c, now())->>'count')::integer;
  insert into _r values('03_count_equals_the_core',
    case when v_actual = v_expected and v_expected > 0
      then 'PASS ' || v_actual || ' = the core''s own claimable count'
      else 'FAIL count=' || v_actual || ' core=' || v_expected end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 04  the CHEAPEST possible gift is ready, and it moves the count by exactly one.
--     The brief asked for a zero-cost fixture. There is no such row to build: both
--     public.loyalty_rewards and public.loyalty_reward_versions carry CHECK (cost_points > 0), so a
--     catalogue reward costing nothing cannot exist in this database at all — v399's client-side
--     "zero-cost rewards were dropped" rule is unreachable for catalogue rewards, and a free
--     welcome gift is a GRANT (v215/v427), which is not what this count counts. The constraint is
--     asserted here so a future migration relaxing it re-opens the question loudly, and the
--     always-affordable case is covered by the cheapest gift the schema allows.
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  c uuid := '9acc0c04-14be-40b8-9473-b40ae5f95b40';
  v_spine uuid; v_pin uuid; v_before integer; v_after integer; v_reward uuid; v_guard boolean;
begin
  select count(*) = 2 into v_guard from pg_constraint
   where conname in ('loyalty_rewards_cost_points_check', 'loyalty_reward_versions_cost_points_check')
     and pg_get_constraintdef(oid) = 'CHECK ((cost_points > 0))';
  insert into _r values('04a_zero_cost_catalogue_reward_cannot_exist',
    case when v_guard
      then 'PASS both reward tables enforce cost_points > 0, so there is no zero-cost row to count'
      else 'FAIL the cost_points > 0 constraint changed — build a real zero-cost fixture here now' end);

  select id into v_spine from public.business_programmes
   where business_id = b and kind = 'stamps' and active order by sort, id limit 1;
  v_pin := app.stamp_cycle_version_v416(b, c, v_spine);
  v_before := (app.customer_ready_reward_count_v465(b, c, now())->>'count')::integer;
  insert into public.loyalty_rewards(business_id, name, internal_name, customer_name, cost_points,
      credit_cents, estimated_cost_cents, fulfillment_kind, programme_id, active, paused, sort)
    values(b, 'v465 cheapest gift', 'v465 cheapest gift', 'v465 cheapest gift', 1,
      0, 0, 'manual_item', v_spine, true, false, 900)
    returning id into v_reward;
  insert into public.loyalty_reward_versions(reward_id, business_id, config_version_id, internal_name,
      customer_name, fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active, sort,
      programme_id)
    values(v_reward, b, v_pin, 'v465 cheapest gift', 'v465 cheapest gift', 'manual_item', 1, 0, 0, true, 900,
      v_spine);
  v_after := (app.customer_ready_reward_count_v465(b, c, now())->>'count')::integer;
  insert into _r values('04b_an_affordable_gift_moves_the_count_by_one',
    case when v_after = v_before + 1
      then 'PASS ' || v_before || ' -> ' || v_after
      else 'FAIL ' || v_before || ' -> ' || v_after || '; an affordable gift was dropped' end);
  -- Teardown: a published version row is immutable (reward_version_immutable_guard), so the
  -- fixture is retired the way the product retires a gift — on the LIVE row, which the core reads.
  update public.loyalty_rewards set active = false where id = v_reward;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 05  a tier-gated gift: not counted while the gate is unmet, counted when it is met.
--     Two separate gifts rather than one gift edited: a published version row is immutable
--     (reward_version_immutable_guard), which is exactly why v423 made an edit publish a NEW
--     version. Retiring each fixture on its LIVE row is how the product retires a gift.
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  c uuid := '9acc0c04-14be-40b8-9473-b40ae5f95b40';
  v_spine uuid; v_pin uuid; v_metric numeric; v_base integer; v_locked integer; v_open integer;
  v_high uuid; v_low uuid;
begin
  select id into v_spine from public.business_programmes
   where business_id = b and kind = 'stamps' and active order by sort, id limit 1;
  v_pin := app.stamp_cycle_version_v416(b, c, v_spine);
  v_metric := app.v176_tier_gate_metric(b, c);
  v_base := (app.customer_ready_reward_count_v465(b, c, now())->>'count')::integer;

  insert into public.loyalty_rewards(business_id, name, internal_name, customer_name, cost_points,
      credit_cents, estimated_cost_cents, fulfillment_kind, programme_id, active, paused, sort,
      min_tier_threshold)
    values(b, 'v465 tier locked', 'v465 tier locked', 'v465 tier locked', 1, 0, 0, 'manual_item',
      v_spine, true, false, 901, (v_metric + 1000)::integer)
    returning id into v_high;
  insert into public.loyalty_reward_versions(reward_id, business_id, config_version_id, internal_name,
      customer_name, fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active, sort,
      programme_id, min_tier_threshold)
    values(v_high, b, v_pin, 'v465 tier locked', 'v465 tier locked', 'manual_item', 1, 0, 0, true, 901,
      v_spine, (v_metric + 1000)::integer);
  v_locked := (app.customer_ready_reward_count_v465(b, c, now())->>'count')::integer;
  update public.loyalty_rewards set active = false where id = v_high;

  insert into public.loyalty_rewards(business_id, name, internal_name, customer_name, cost_points,
      credit_cents, estimated_cost_cents, fulfillment_kind, programme_id, active, paused, sort,
      min_tier_threshold)
    values(b, 'v465 tier met', 'v465 tier met', 'v465 tier met', 1, 0, 0, 'manual_item',
      v_spine, true, false, 901, greatest(v_metric - 1, 0)::integer)
    returning id into v_low;
  insert into public.loyalty_reward_versions(reward_id, business_id, config_version_id, internal_name,
      customer_name, fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active, sort,
      programme_id, min_tier_threshold)
    values(v_low, b, v_pin, 'v465 tier met', 'v465 tier met', 'manual_item', 1, 0, 0, true, 901,
      v_spine, greatest(v_metric - 1, 0)::integer);
  v_open := (app.customer_ready_reward_count_v465(b, c, now())->>'count')::integer;
  update public.loyalty_rewards set active = false where id = v_low;

  insert into _r values('05_tier_gate_is_honoured',
    case when v_locked = v_base and v_open = v_base + 1
      then 'PASS a gate above the customer''s ' || v_metric || ' adds nothing (' || v_locked
           || '); a gate below it adds one (' || v_open || ')'
      else 'FAIL base=' || v_base || ' locked=' || v_locked || ' met=' || v_open
           || ' metric=' || v_metric end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 06  a programme pause: the count FOLLOWS THE CORE, it does not invent a rule of its own.
--     Deliberately NOT asserting "pause ⇒ 0". nestly_v435's Rule 7 (protected, owner-ruled with the
--     stamp lifecycle wave) is that a stopped STAMP programme still lists what the customer can
--     genuinely claim right now — the survivors of a card that has been closed. Any count that went
--     to zero here would be a SECOND opinion about readiness, which is exactly what R1 forbids. What
--     must hold is that the count equals the core across the pause, and that the owner's own pause
--     control on a gift does remove it.
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  c uuid := '9acc0c04-14be-40b8-9473-b40ae5f95b40';
  v_core integer; v_count integer; v_paused integer;
begin
  update public.business_programmes set active = false where business_id = b;
  select count(*)::integer into v_core
    from app.reward_availability_v432(b, c, now()) core
   where core.branch_count = 0 and core.service_count = 0 and core.product_count = 0
     and core.availability = 'available_at_counter';
  v_count := (app.customer_ready_reward_count_v465(b, c, now())->>'count')::integer;
  insert into _r values('06a_pause_the_count_still_equals_the_core',
    case when v_count = v_core
      then 'PASS both say ' || v_count || ' with every spine switched off (v435 Rule 7 survivors)'
      else 'FAIL count=' || v_count || ' core=' || v_core end);

  update public.loyalty_rewards set paused = true where business_id = b and active;
  v_paused := (app.customer_ready_reward_count_v465(b, c, now())->>'count')::integer;
  insert into _r values('06b_pausing_every_gift_empties_the_count',
    case when v_core > 0 and v_paused = 0
      then 'PASS ' || v_core || ' -> 0 once the owner pauses the gifts themselves'
      else 'FAIL core=' || v_core || ' after pausing every gift=' || v_paused end);

  update public.loyalty_rewards set paused = false where business_id = b and active;
  update public.business_programmes set active = true where business_id = b and kind = 'stamps';
end $$;

-- ---------------------------------------------------------------------------------------------
-- 07  redemption switched off ⇒ 0, while the core still returns claimable rows
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  c uuid := '9acc0c04-14be-40b8-9473-b40ae5f95b40';
  v_core integer; v_count integer;
begin
  update public.business_customer_capabilities_v89 set redemption_enabled = false where business_id = b;
  select count(*)::integer into v_core
    from app.reward_availability_v432(b, c, now()) core
   where core.branch_count = 0 and core.service_count = 0 and core.product_count = 0
     and core.availability = 'available_at_counter';
  v_count := (app.customer_ready_reward_count_v465(b, c, now())->>'count')::integer;
  insert into _r values('07_redemption_gate',
    case when v_core > 0 and v_count = 0
      then 'PASS the counter cannot honour a customer redemption, so the count is 0 (core still sees '
           || v_core || ')'
      else 'FAIL core=' || v_core || ' count=' || v_count end);
  update public.business_customer_capabilities_v89 set redemption_enabled = true where business_id = b;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 08  a branch-restricted gift is excluded, exactly as customer_get_business_actions_v89 excludes it
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  c uuid := '9acc0c04-14be-40b8-9473-b40ae5f95b40';
  v_spine uuid; v_pin uuid; v_branch uuid; v_before integer; v_after integer;
  v_reward uuid; v_version uuid; v_core_sees integer;
begin
  select id into v_spine from public.business_programmes
   where business_id = b and kind = 'stamps' and active order by sort, id limit 1;
  v_pin := app.stamp_cycle_version_v416(b, c, v_spine);
  select id into v_branch from public.branches where business_id = b order by created_at, id limit 1;
  v_before := (app.customer_ready_reward_count_v465(b, c, now())->>'count')::integer;
  insert into public.loyalty_rewards(business_id, name, internal_name, customer_name, cost_points,
      credit_cents, estimated_cost_cents, fulfillment_kind, programme_id, active, paused, sort)
    values(b, 'v465 branch only', 'v465 branch only', 'v465 branch only', 1, 0, 0, 'manual_item', v_spine,
      true, false, 902)
    returning id into v_reward;
  insert into public.loyalty_reward_versions(reward_id, business_id, config_version_id, internal_name,
      customer_name, fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active, sort,
      programme_id)
    values(v_reward, b, v_pin, 'v465 branch only', 'v465 branch only', 'manual_item', 1, 0, 0, true, 902,
      v_spine)
    returning id into v_version;
  insert into public.loyalty_reward_branches(reward_version_id, reward_id, business_id, branch_id)
    values(v_version, v_reward, b, v_branch);
  select count(*)::integer into v_core_sees
    from app.reward_availability_v432(b, c, now()) core
   where core.reward_id = v_reward and core.availability = 'available_at_counter';
  v_after := (app.customer_ready_reward_count_v465(b, c, now())->>'count')::integer;
  insert into _r values('08_restricted_gift_excluded',
    case when v_core_sees = 1 and v_after = v_before
      then 'PASS the core marks it claimable, and the count leaves it out exactly as v89 does'
      else 'FAIL core_sees=' || v_core_sees || ' before=' || v_before || ' after=' || v_after end);
  -- Teardown: a published version row is immutable (reward_version_immutable_guard), so the
  -- fixture is retired the way the product retires a gift — on the LIVE row, which the core reads.
  update public.loyalty_rewards set active = false where id = v_reward;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 09  OWNER RULING R1's INVARIANT — Home's number is the business page's number
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  c uuid := '9acc0c04-14be-40b8-9473-b40ae5f95b40';
  u uuid := '253de8ef-b08c-40fa-b435-5723a6123a9d';
  v_page integer; v_home integer;
begin
  v_home := (app.customer_ready_reward_count_v465(b, c, now())->>'count')::integer;
  perform pg_temp.as_v465_user(u);
  -- Exactly what the business page counts: customerRewardCanRedeem over the v89 reward list —
  -- redemption enabled, availability available_at_counter, and a reward id to redeem against.
  select count(*)::integer into v_page
    from jsonb_array_elements(
      coalesce(public.customer_get_business_actions_v89(b)->'rewards', '[]'::jsonb)) reward
   where reward->>'availability' = 'available_at_counter'
     and nullif(reward->>'id', '') is not null;
  execute 'reset role';
  insert into _r values('09_home_agrees_with_the_business_page',
    case when v_home = v_page and v_page > 0
      then 'PASS both surfaces say ' || v_home
      else 'FAIL home=' || v_home || ' business page=' || v_page end);
exception when others then
  execute 'reset role';
  insert into _r values('09_home_agrees_with_the_business_page', 'FAIL ' || sqlstate || ' ' || sqlerrm);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 10  the card carries the same number, and gains nothing else
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  c uuid := '9acc0c04-14be-40b8-9473-b40ae5f95b40';
  v_card jsonb; v_expected integer; v_added text[];
begin
  select app.c45_base_actionable_wallet_card(b, c, 'qa-kaya-toast', 'QA Kaya Toast', 'cafe', 'SGD',
    (select enabled_modules from public.businesses where id = b), now()) into v_card;
  v_expected := (app.customer_ready_reward_count_v465(b, c, now())->>'count')::integer;
  select array_agg(key order by key) into v_added
    from jsonb_object_keys(v_card) key
   where key not in ('business','loyalty','credit','packages','expiry','next_eligible_reward',
     'visits_remaining','visit_progress','action');
  insert into _r values('10_card_carries_the_count',
    case when (v_card->>'ready_count')::integer = v_expected
      then 'PASS the card says ' || (v_card->>'ready_count')
      else 'FAIL card=' || coalesce(v_card->>'ready_count','<absent>') || ' function=' || v_expected end);
  insert into _r values('10_card_change_is_additive',
    case when v_added = array['ready_choose_one','ready_count']
      then 'PASS exactly two new keys, every pre-v465 key untouched'
      else 'FAIL new keys are ' || coalesce(array_to_string(v_added, ','), '<none>') end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 11  choose_one follows v428's SLOT rule, not "two gifts that cost the same"
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  c uuid := '9acc0c04-14be-40b8-9473-b40ae5f95b40';
  v_spine uuid; v_pin uuid; v_slot integer; v_reward uuid;
  v_before boolean; v_after boolean;
begin
  select id into v_spine from public.business_programmes
   where business_id = b and kind = 'stamps' and active order by sort, id limit 1;
  v_pin := app.stamp_cycle_version_v416(b, c, v_spine);
  v_before := (app.customer_ready_reward_count_v465(b, c, now())->>'choose_one')::boolean;
  -- the slot of a gift that is ALREADY claimable, so the twin is claimable too
  select core.cost_points into v_slot
    from app.reward_availability_v432(b, c, now()) core
   where core.availability = 'available_at_counter' and core.unit = 'stamps' and core.cost_points > 0
   order by core.cost_points limit 1;
  insert into public.loyalty_rewards(business_id, name, internal_name, customer_name, cost_points,
      credit_cents, estimated_cost_cents, fulfillment_kind, programme_id, active, paused, sort)
    values(b, 'v465 same slot twin', 'v465 same slot twin', 'v465 same slot twin', v_slot, 0, 0,
      'manual_item', v_spine, true, false, 903)
    returning id into v_reward;
  insert into public.loyalty_reward_versions(reward_id, business_id, config_version_id, internal_name,
      customer_name, fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active, sort,
      programme_id)
    values(v_reward, b, v_pin, 'v465 same slot twin', 'v465 same slot twin', 'manual_item', v_slot, 0, 0,
      true, 903, v_spine);
  v_after := (app.customer_ready_reward_count_v465(b, c, now())->>'choose_one')::boolean;
  insert into _r values('11_choose_one_follows_the_slot_rule',
    case when v_before = false and v_after = true
      then 'PASS one gift per slot: false -> true when a twin lands on slot ' || v_slot
      else 'FAIL before=' || v_before || ' after=' || v_after || ' slot=' || v_slot end);
  -- Teardown: a published version row is immutable (reward_version_immutable_guard), so the
  -- fixture is retired the way the product retires a gift — on the LIVE row, which the core reads.
  update public.loyalty_rewards set active = false where id = v_reward;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 12  no second definition of "ready" — structural, so it is read rather than executed
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_def text;
  v_borrowed text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'customer_ready_reward_count_v465';
  insert into _r values('12_counts_through_the_one_core',
    case when position('reward_availability_v432' in coalesce(v_def, '')) > 0
      then 'PASS the count reads app.reward_availability_v432'
      else 'FAIL the count does not go through the v432 core' end);
  -- It must not compute a balance, a stamp position or a tier metric of its own: those are the
  -- three things the three drifted copies v432 replaced each got wrong.
  select string_agg(token, ', ') into v_borrowed
    from unnest(array['points_ledger','points_batches','stamp_progress_v323','v176_tier_gate_metric',
      'stamp_milestone_claims','loyalty_reward_versions']) token
   where position(token in coalesce(v_def, '')) > 0;
  insert into _r values('12_no_second_availability_calculation',
    case when v_borrowed is null
      then 'PASS the count computes no balance, slot or tier of its own'
      else 'FAIL it reaches for ' || v_borrowed || ' — that is a second definition of "ready"' end);
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'c45_base_actionable_wallet_card';
  insert into _r values('12_card_calls_the_count_once',
    case when (length(v_def) - length(replace(v_def, 'customer_ready_reward_count_v465', ''))) /
              length('customer_ready_reward_count_v465') = 1
      then 'PASS one call per card, materialised — the core cannot be re-evaluated per key'
      else 'FAIL the card calls the count more than once; the v233 re-evaluation trap' end);
end $$;

select k, v from _r order by k;

rollback;
