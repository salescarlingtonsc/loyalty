-- nestly_v372 — a gift is only offered while its own programme is running.
--
-- V371 stopped a switched-off programme from being reported as enabled, and stopped a PAUSED gift
-- from being offered. It missed the case in between: a gift that is live and unpaused, but belongs
-- to a programme the owner has switched off.
--
-- A reward carries `programme_id` and is priced in that programme's unit. Cubbly is the live case:
-- stamps off, points on, and "Free Massage Oil" priced at 2 STAMPS still in the customer's reward
-- catalogue — and reported by the wallet as `available_now: true`, because the wallet compares its
-- cost against whichever unit is live (a 50-POINT balance). The customer is promised a reward they
-- cannot earn towards, in a unit the business is not running, and the claim is refused if attempted.
--
-- Both customer-facing readers now drop a reward whose own programme is switched off, using the
-- same live-row lookup that already carries the pause check, so there is one condition per reader
-- rather than two that can drift. A reward with no programme is deliberately left alone — failing
-- open never hides a real gift because a link is missing (all 20 production rewards do have one).
--
-- Verified rolled back against production first; see db/tests/v372_gift_follows_its_programme.sql.

begin;


-- ---------------------------------------------------------------- app.c45_base_actionable_wallet_card
CREATE OR REPLACE FUNCTION app.c45_base_actionable_wallet_card(p_business_id uuid, p_client_id uuid, p_business_slug text, p_business_name text, p_business_industry text, p_business_currency text, p_enabled_modules text[], p_as_of timestamp with time zone)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
  with program as (
    select
      'loyalty' = any(p_enabled_modules) and (coalesce(lp.active, false) and engine.running) as enabled,
      case when 'loyalty' = any(p_enabled_modules) and (coalesce(lp.active, false) and engine.running)
        then case when lp.loyalty_model = 'stamps' then 'stamps' else 'points' end
      end as unit,
      case when 'loyalty' = any(p_enabled_modules) and (coalesce(lp.active, false) and engine.running)
        then lp.loyalty_model
      end as model,
      case when 'loyalty' = any(p_enabled_modules) and (coalesce(lp.active, false) and engine.running)
        then coalesce(lp.expiry_mode, 'none')
        else 'none'
      end as expiry_mode
    from (select 1) scope
    left join public.loyalty_programs lp on lp.business_id = p_business_id
    -- V371: `lp.active` alone is not "is this programme running". The owner's on/off control
    -- (set_programmes_v314) moves the business_programmes spine and never touches lp.active, so a
    -- switched-off programme kept answering enabled=true here while the business page said "not
    -- running". The spine is the authority; app.programme_running_v371 is the single reader of it.
    cross join lateral (
      select app.programme_running_v371(p_business_id, 'points')
          or app.programme_running_v371(p_business_id, 'stamps') as running
    ) engine
  ), ledger_balance as (
    select greatest(coalesce(sum(pl.points), 0), 0)::integer as units
      from public.points_ledger pl
     where pl.business_id = p_business_id
       and pl.client_id = p_client_id
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
      'expiring_within_7_days', loyalty.expiring_7_units,
      'expiring_units', loyalty.expiring_units,
      'next_expiry_at', loyalty.next_expiry_at
    ),
    'next_eligible_reward', case when reward_candidate.name is null then null else
      jsonb_build_object(
        'name', reward_candidate.name,
        'cost_units', reward_candidate.cost_units,
        'remaining_units', reward_candidate.remaining_units,
        'available_now', reward_candidate.available_now
      ) end,
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
    cross join action;
$function$;

-- ---------------------------------------------------------------- public.customer_get_reward_catalog
CREATE OR REPLACE FUNCTION public.customer_get_reward_catalog(p_business_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_context record;
  v_balance integer;
  v_metric numeric;
  v_result jsonb;
  v_balance_scope text;
  v_stamps_programme uuid;
  v_stamp_filled integer;
  v_stamp_cycle integer;
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

  select coalesce(sum(pl.points), 0)::integer into v_balance
    from public.points_ledger pl
   where pl.business_id = v_context.business_id and pl.client_id = v_context.client_id;

  v_metric := app.v176_tier_gate_metric(v_context.business_id, v_context.client_id);

  select spine.id into v_stamps_programme
    from public.business_programmes spine
   where spine.business_id = v_context.business_id and spine.kind = 'stamps';
  select coalesce(sp.filled, 0), coalesce(sp.cycle_index, 0)
    into v_stamp_filled, v_stamp_cycle
    from app.stamp_progress_v323(v_context.business_id, v_context.client_id) sp;

  select coalesce(jsonb_agg(jsonb_build_object(
    'customer_name', listed.customer_name,
    'description', listed.description,
    'image_ref', listed.image_ref,
    'terms', listed.terms,
    'instructions', listed.instructions,
    'taxonomy_label', listed.taxonomy_label,
    'fulfillment_kind', listed.fulfillment_kind,
    'cost_points', listed.cost_points,
    'claim_available_from', listed.claim_available_from,
    'claim_available_until', listed.claim_available_until,
    'entitlement_expiry_days', listed.entitlement_expiry_days,
    'availability', listed.availability,
    'claim_method', 'counter',
    'tier_requirement', case when listed.gate_threshold is null then null else jsonb_build_object(
      'tier_label', listed.gate_label,
      'threshold', listed.gate_threshold,
      'met', v_metric >= listed.gate_threshold
    ) end,
    'eligibility', jsonb_build_object(
      'branches', jsonb_build_object('scope', case when listed.branch_count = 0 then 'all' else 'restricted' end, 'count', listed.branch_count),
      'services', jsonb_build_object('scope', case when listed.service_count = 0 then 'all' else 'restricted' end, 'count', listed.service_count),
      'products', jsonb_build_object('scope', case when listed.product_count = 0 then 'all' else 'restricted' end, 'count', listed.product_count)
    )
  ) order by listed.sort, listed.customer_name), '[]'::jsonb)
  into v_result
  from (
    select rv.customer_name, rv.description, rv.image_ref, rv.terms, rv.instructions,
           rv.taxonomy_label, rv.fulfillment_kind, rv.cost_points, rv.claim_available_from,
           rv.claim_available_until, rv.entitlement_expiry_days, rv.sort,
           app.v176_reward_gate_threshold(v_context.business_id, rv.min_tier_id, rv.min_tier_threshold) as gate_threshold,
           app.v176_reward_gate_label(v_context.business_id, rv.min_tier_id) as gate_label,
           (select count(*)::integer from public.loyalty_reward_branches e where e.reward_version_id = rv.id) as branch_count,
           (select count(*)::integer from public.loyalty_reward_services e where e.reward_version_id = rv.id) as service_count,
           (select count(*)::integer from public.loyalty_reward_products e where e.reward_version_id = rv.id) as product_count,
           case
             when rv.claim_available_from is not null and now() < rv.claim_available_from then 'not_started'
             when rv.claim_available_until is not null and now() >= rv.claim_available_until then 'ended'
             when app.v176_reward_gate_threshold(v_context.business_id, rv.min_tier_id, rv.min_tier_threshold) is not null
              and v_metric < app.v176_reward_gate_threshold(v_context.business_id, rv.min_tier_id, rv.min_tier_threshold) then 'tier_locked'
             when rv.usage_limit is not null and coalesce(usage.used_count, 0) >= rv.usage_limit then 'limit_reached'
             when v_stamps_programme is not null and rv.programme_id = v_stamps_programme
              and exists (select 1 from public.stamp_milestone_claims claim
                           where claim.business_id = v_context.business_id
                             and claim.client_id = v_context.client_id
                             and claim.programme_id = v_stamps_programme
                             and claim.cycle_index = coalesce(v_stamp_cycle, 0)
                             and claim.reward_id = rv.reward_id) then 'limit_reached'
             when (case when v_stamps_programme is not null and rv.programme_id = v_stamps_programme
                        then coalesce(v_stamp_filled, 0) else v_balance end) < rv.cost_points then 'insufficient_balance'
             else 'available_at_counter'
           end as availability
      from public.businesses b
      join public.loyalty_reward_versions rv
        on rv.business_id = b.id and rv.config_version_id = b.active_config_version_id and rv.active
       -- V371: see app.c45_base_actionable_wallet_card. `paused` is on the live row and the
       -- customer reads the published snapshot, so a switched-off gift stayed in the catalogue.
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
      left join lateral (
        select count(*)::integer as used_count
          from public.loyalty_redemptions lr
         where lr.business_id = v_context.business_id and lr.client_id = v_context.client_id
           and lr.reward_id = rv.reward_id
      ) usage on true
     where b.id = v_context.business_id
  ) listed;

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
$function$;

-- Restate the ACLs captured from production before the replace (a replace re-grants PUBLIC).
revoke all on function app.c45_base_actionable_wallet_card(uuid, uuid, text, text, text, text, text[], timestamptz) from public;
grant execute on function app.c45_base_actionable_wallet_card(uuid, uuid, text, text, text, text, text[], timestamptz) to postgres;

revoke all on function public.customer_get_reward_catalog(text) from public;
grant execute on function public.customer_get_reward_catalog(text) to postgres, service_role, authenticated;

commit;
