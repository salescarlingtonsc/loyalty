-- nestly_v437 — a history row keeps the unit it happened in (owner rule 13, locked 2026-08-22).
--
-- THE DEFECT (2026-08-22 simulation, A9): after a stamps→points switch the customer's Activity
-- relabelled every historical stamp earn as "+3 points" — the row's unit followed the LIVE
-- programme instead of the row's own pot. The ledger knows exactly which pot each row belongs to
-- (points_ledger.programme_id → business_programmes.kind); the history reader just never said.
--
-- THE FIX: customer_get_transaction_history_v81 (the base reader v167 wraps and augments with
-- `||`, so the new key flows through v167 untouched) now emits `loyalty_unit` per item —
-- 'stamps' or 'points', resolved from the row's OWN pot — and the standalone ledger events'
-- descriptions say the right noun ("Stamps earned", not "Points earned"). Additive: no key is
-- removed or renamed, clients that ignore `loyalty_unit` render exactly as before.
--
-- For a sale event the unit is the pot of the sale's earn rows (one active accruing programme
-- writes per sale; if a mixed legacy sale ever existed, the first ledger row's pot wins — the
-- same row the earn total leads with).

begin;

CREATE OR REPLACE FUNCTION public.customer_get_transaction_history_v81(p_business_slug text, p_cursor jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_context record;
  v_cursor jsonb := coalesce(p_cursor, '{}'::jsonb);
  v_limit integer := 20;
  v_before_at timestamptz;
  v_before_order integer;
  v_before_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if jsonb_typeof(v_cursor) <> 'object'
     or exists (
       select 1
         from jsonb_object_keys(v_cursor) as cursor_keys(key)
        where key not in ('limit', 'before_at', 'before_order', 'before_id')
     ) then
    raise exception 'invalid transaction history cursor' using errcode = '22023';
  end if;
  begin
    v_limit := least(greatest(coalesce((v_cursor->>'limit')::integer, 20), 1), 50);
    v_before_at := nullif(v_cursor->>'before_at', '')::timestamptz;
    v_before_order := nullif(v_cursor->>'before_order', '')::integer;
    v_before_id := nullif(v_cursor->>'before_id', '')::uuid;
  exception when others then
    raise exception 'invalid transaction history cursor' using errcode = '22023';
  end;
  if num_nonnulls(v_before_at, v_before_order, v_before_id) not in (0, 3)
     or (v_before_order is not null and v_before_order not in (1, 2)) then
    raise exception 'transaction history cursor is incomplete' using errcode = '22023';
  end if;

  select * into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  with sale_events as (
    select
      sale.id as source_id,
      sale.occurred_at as event_at,
      2 as event_order,
      'sale'::text as source_kind,
      case when sale.reversal_of is null then 'sale' else 'sale_reversal' end
        as event_type,
      case
        when sale.reversal_of is not null then 'reversal'
        when reversal.id is not null then 'reversed'
        else 'completed'
      end as status,
      branch.name as branch_name,
      sale.kind as sale_kind,
      sale.amount_cents::integer as gross_cents,
      case when sale.reversal_of is not null then 0
        else (sale.amount_cents + coalesce(reversal.amount_cents, 0))::integer
      end as net_cents,
      coalesce(points.points_earned, 0)::integer as points_earned,
      coalesce(points.points_redeemed, 0)::integer as points_redeemed,
      coalesce(points.points_removed, 0)::integer as points_removed,
      points.loyalty_unit as loyalty_unit,
      case when sale.reversal_of is not null then sale.reversal_of else reversal.id end
        as related_source_id,
      case sale.kind
        when 'quick_sale' then 'Purchase'
        when 'service' then 'Service purchase'
        when 'retail' then 'Retail purchase'
        when 'membership' then 'Membership purchase'
        else 'Purchase'
      end as description,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'item_id', item.id,
          'item_type', item.item_type,
          'description', item.description,
          'qty', item.qty,
          'unit_cents', item.unit_cents,
          'line_cents', item.line_cents
        ) order by item.created_at, item.id)
          from public.sale_items item
         where item.business_id = sale.business_id
           and item.sale_id = sale.id
      ), '[]'::jsonb) as line_items
      from public.sales sale
      left join public.branches branch
        on branch.business_id = sale.business_id
       and branch.id = sale.branch_id
      left join lateral (
        select reversal_sale.id, reversal_sale.amount_cents
          from public.sales reversal_sale
         where reversal_sale.business_id = sale.business_id
           and reversal_sale.reversal_of = sale.id
         order by reversal_sale.occurred_at desc, reversal_sale.id desc
         limit 1
      ) reversal on true
      left join lateral (
        select
          coalesce(sum(ledger.points) filter (where ledger.points > 0), 0)::integer
            as points_earned,
          abs(coalesce(sum(ledger.points) filter (
            where ledger.points < 0 and ledger.entry_type = 'redeem'
          ), 0))::integer as points_redeemed,
          abs(coalesce(sum(ledger.points) filter (
            where ledger.points < 0 and ledger.entry_type <> 'redeem'
          ), 0))::integer as points_removed,
          /* nestly_v437: the pot these rows actually live in. */
          (array_agg(spine.kind order by ledger.created_at, ledger.id)
             filter (where spine.kind is not null))[1] as loyalty_unit
          from public.points_ledger ledger
          left join public.business_programmes spine
            on spine.id = ledger.programme_id
         where ledger.business_id = sale.business_id
           and ledger.client_id = sale.client_id
           and ledger.sale_id = sale.id
      ) points on true
     where sale.business_id = v_context.business_id
       and sale.client_id = v_context.client_id
  ), standalone_point_events as (
    select
      ledger.id as source_id,
      ledger.created_at as event_at,
      1 as event_order,
      'points_ledger'::text as source_kind,
      'points_' || ledger.entry_type as event_type,
      'completed'::text as status,
      null::text as branch_name,
      null::text as sale_kind,
      null::integer as gross_cents,
      null::integer as net_cents,
      greatest(ledger.points, 0)::integer as points_earned,
      case when ledger.entry_type = 'redeem'
        then greatest(-ledger.points, 0) else 0 end::integer as points_redeemed,
      case when ledger.entry_type <> 'redeem'
        then greatest(-ledger.points, 0) else 0 end::integer as points_removed,
      spine.kind as loyalty_unit,
      null::uuid as related_source_id,
      /* nestly_v437: the noun follows the ROW's pot, not the live programme (owner rule 13). */
      case when spine.kind = 'stamps' then
        case ledger.entry_type
          when 'earn' then 'Stamps earned'
          when 'redeem' then 'Stamps redeemed'
          when 'expire' then 'Stamps expired'
          when 'adjust' then 'Stamps adjustment'
          else 'Loyalty activity'
        end
      else
        case ledger.entry_type
          when 'earn' then 'Points earned'
          when 'redeem' then 'Points redeemed'
          when 'expire' then 'Points expired'
          when 'adjust' then 'Points adjustment'
          else 'Loyalty activity'
        end
      end as description,
      '[]'::jsonb as line_items
      from public.points_ledger ledger
      left join public.business_programmes spine
        on spine.id = ledger.programme_id
     where ledger.business_id = v_context.business_id
       and ledger.client_id = v_context.client_id
       and ledger.sale_id is null
  ), history as (
    select * from sale_events
    union all
    select * from standalone_point_events
  ), eligible as (
    select *
      from history
     where v_before_at is null
        or (event_at, event_order, source_id)
           < (v_before_at, v_before_order, v_before_id)
     order by event_at desc, event_order desc, source_id desc
     limit v_limit + 1
  ), visible as (
    select *
      from eligible
     order by event_at desc, event_order desc, source_id desc
     limit v_limit
  )
  select jsonb_build_object(
    'business', jsonb_build_object(
      'slug', v_context.business_slug,
      'name', v_context.business_name,
      'currency', v_context.business_currency
    ),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'source_kind', source_kind,
        'source_id', source_id,
        'event_at', event_at,
        'event_type', event_type,
        'status', status,
        'branch_name', branch_name,
        'sale_kind', sale_kind,
        'gross_cents', gross_cents,
        'net_cents', net_cents,
        'points_earned', points_earned,
        'points_redeemed', points_redeemed,
        'points_removed', points_removed,
        'loyalty_unit', loyalty_unit,
        'related_source_id', related_source_id,
        'description', description,
        'line_items', line_items
      ) order by event_at desc, event_order desc, source_id desc)
        from visible
    ), '[]'::jsonb),
    'next_cursor', case when (select count(*) from eligible) > v_limit then (
      select jsonb_build_object(
        'before_at', event_at,
        'before_order', event_order,
        'before_id', source_id,
        'limit', v_limit
      )
        from visible
       order by event_at, event_order, source_id
       limit 1
    ) else null end
  ) into v_result;

  return v_result;
end;
$function$;

revoke all on function public.customer_get_transaction_history_v81(text, jsonb) from public, anon;
grant execute on function public.customer_get_transaction_history_v81(text, jsonb) to authenticated, service_role;

-- ============================================================================================
-- §2  THE WALLET CARD'S EXPIRY OBJECT LEARNS ITS RULE (owner rule 15: the points explainer
--     says "Points expire {X} days after you earn them" with the SERVER's number, and the
--     wallet payload carried the mode and the next date but never the rule itself). One added
--     key ('days', only under mode='fixed'); everything else byte-identical to the deployed
--     nestly_v426 body.
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

revoke all on function app.c45_base_actionable_wallet_card(uuid, uuid, text, text, text, text, text[], timestamptz) from public, anon, authenticated;

commit;
