-- nestly_v426 — one canonical tier resolution path: shown tier == applied tier.
--
-- P0-4, confirmed on production 2026-08-22. Five functions each resolved "which tier is this
-- customer in" with their OWN reading of the same three inputs, and the readings disagreed:
--
--   BASIS. app.loyalty_tier_for — the one the money runs through, called by app.on_sale_recorded
--   to multiply the points a sale earns — reads
--       select tier_basis from public.loyalty_programs where business_id = ...
--   with NO `active` filter. Every display-side reader (app.v365_client_tier,
--   app.customer_tier_json_v393, public.customer_get_effective_tier_v143) and the reward gate
--   (app.v176_tier_gate_metric) read the same column `... and active limit 1`. When the programme
--   row is inactive that SELECT INTO returns no row, so the variable is left NULL — the
--   `coalesce(tier_basis,'visits')` inside the query never fires, because there is no row for it
--   to fire on — and the if/elsif chain falls through to the visits branch. Seven of ten live
--   businesses have active = false, so on those tenants the engine and the screen were reading
--   two different bases. Hougang ABC was live-broken by exactly this: tier_basis is
--   'points_earned', the row is inactive, so the customer was SHOWN a visits-basis tier while
--   the engine APPLIED a points-basis one. Yong Xiang, 5 visits and 0 points in the live pot,
--   was shown Platinum (the 5-visit rung, 1.25x) and earned at Gold (1.0x).
--
--   POT SCOPE. app.loyalty_tier_for, app.v176_tier_gate_metric and
--   public.customer_get_effective_tier_v143 scope the points_earned metric to the business's
--   points programme pot (points_ledger.programme_id = the `points` spine row).
--   app.v365_client_tier and app.customer_tier_json_v393 sum `entry_type='earn'` across EVERY
--   pot. On any tenant that has ever had two pots the two numbers differ — Cubbly SPA's Mumu
--   reads 310 unscoped and 300 pot-scoped today.
--
-- OWNER RULING. One resolution path for basis + metric + pot scope + eligibility, used by the
-- customer display, the earn multiplier and the tier gates alike. Where the two disagreed today,
-- DISPLAY MOVES TO MATCH ENFORCEMENT: the engine's reading is the one that has been paying out,
-- so it is the truth of record, and a screen that contradicts it is the thing that is wrong.
-- Concretely that means the canonical basis is read WITHOUT the `active` filter (loyalty_tier_for's
-- reading) and the canonical points metric IS pot-scoped (loyalty_tier_for's reading again).
--
-- WHAT THIS DOES NOT DO. It does not touch app.on_sale_recorded. That trigger calls
-- `app.loyalty_tier_for(new.business_id, new.client_id)` by name, so re-issuing the helper is
-- enough to move the engine onto the canonical path without editing the trigger at all.
-- It does not change any function's return shape: every one of the five is re-issued as a thin
-- delegate over app.tier_resolve_v426 that rebuilds its existing payload key for key, because a
-- frontend and eleven SQL callers read those shapes.
--
-- THE SPINE GATE, and what it costs. public.customer_get_effective_tier_v143 already refuses to
-- resolve a ladder unless app.programme_running_v371(business,'tiers') — the owner's on/off switch
-- (V371). None of the other four honoured it, so a business that had switched Tiers OFF still had
-- tier multipliers applied at earn time, tier discounts applied at checkout (app.ps1c_plan_checkout
-- via app.v365_client_tier) and tier benefits offered at the counter
-- (public.staff_tier_benefits_for_client_v365). The canonical resolver applies the gate once, for
-- everyone. On production today that changes Cubbly SPA, whose Tiers spine row is inactive: its
-- three live tiers all carry points_multiplier = 1.0 and it has no rows in tier_benefits_v365, so
-- nothing about the money moves — but a switched-off ladder now genuinely grants nothing, in every
-- path, which is the whole point of the switch.
--
-- METRIC AGREEMENT, checked not assumed. The visits metric
--   (count(*) from sales where counts_as_visit) and the spend metric
--   (sum(amount_cents)/100.0 where counts_as_revenue) are already textually identical in all five
-- functions, so adopting them is a no-op. Only the points metric and the basis diverged.
--
-- ALSO IN THIS MIGRATION, because they are the same defect wearing a different hat:
--
--   (3) app.c45_base_actionable_wallet_card — the Home wallet card — derived `model` and `unit`
--   from loyalty_programs.loyalty_model, a column the owner's programme switch does not write.
--   Cubbly SPA runs a STAMPS pot with loyalty_model still reading 'points_tiers', so Home said
--   "pts" to a stamps business while the balance underneath it (already correct, via
--   app.live_balance_programme_v381) counted stamps. model and unit now come from the spine, the
--   same authority app.customer_live_loyalty_v384 reads. The vocabulary of both keys is unchanged
--   ('classic' | 'points_tiers' | 'stamps'; 'points' | 'stamps') because the client reads them
--   literally; only the SOURCE moves. next_eligible_reward gains a `unit` key so the caller need
--   not infer which noun to print, and is otherwise untouched — as are `action`, `sort_band`,
--   every other key, and the `enabled` predicate.
--
--   (4) The v354 sync invariant, restated as data: loyalty_programs.loyalty_model / .kind are
--   brought back into agreement with the spine wherever an accruing programme is running. Written
--   generically, not as a two-row hotfix. On production this is exactly two rows — Cubbly SPA
--   (points_tiers/points -> stamps/stamps) and Hougang ABC (classic/points -> points_tiers/points).
--
--   (5) public.customer_get_transaction_history_v167 — a points-to-stamps conversion currently
--   reaches the customer as two anonymous "Points adjustment" lines, one of them for -75,800. The
--   rows are tagged with a machine type so the client can render the pair as ONE event ("75,800
--   points converted to 758 stamps"). Purely additive: no existing key is removed or changed, and
--   the raw rows are still there for a client that does not collapse them.
--
-- ROLLBACK. Every object here is CREATE OR REPLACE over a body captured from production on
-- 2026-08-22; db/tests/executed/v426_tier_resolver.sql carries the pre-image of each one, so the
-- rollback is to replay those five bodies plus the two helpers. The backfill is not reversible
-- from inside the migration — the pre-image of both affected rows is recorded in the test file.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. The canonical resolver. Every tier question in the product is answered from here.
-- ---------------------------------------------------------------------------------------------
create or replace function app.tier_resolve_v426(
  p_business uuid,
  p_client uuid,
  p_as_of timestamptz default statement_timestamp()
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_basis            text;
  v_metric           numeric := 0;
  v_points_programme uuid;
  v_running          boolean;
  v_current          public.loyalty_tiers%rowtype;
  v_next             public.loyalty_tiers%rowtype;
  v_progress         numeric := 0;
  v_ladder           jsonb   := '[]'::jsonb;
begin
  if p_business is null then
    return null;
  end if;

  -- BASIS — read WITHOUT the `active` filter, on purpose. This is app.loyalty_tier_for's
  -- reading, which is the one the earn engine has been paying out on. The coalesce covers both
  -- a NULL column and the no-row case, which is what the old `coalesce(tier_basis,'visits')`
  -- inside the query silently failed to do.
  select lp.tier_basis into v_basis
    from public.loyalty_programs lp
   where lp.business_id = p_business;
  v_basis := coalesce(v_basis, 'visits');

  -- METRIC.
  if v_basis = 'spend' then
    select coalesce(sum(amount_cents), 0) / 100.0 into v_metric
      from public.sales
     where business_id = p_business and client_id = p_client and counts_as_revenue;
  elsif v_basis = 'points_earned' then
    -- Pot scope, copied verbatim from app.loyalty_tier_for / app.v176_tier_gate_metric: the
    -- points spine row, WITHOUT an `active` filter, and an unscoped sum when the business has no
    -- points spine row at all (a tenant that predates the spine must not read as zero).
    select spine.id into v_points_programme
      from public.business_programmes spine
     where spine.business_id = p_business and spine.kind = 'points';
    if v_points_programme is null then
      select coalesce(sum(points), 0) into v_metric
        from public.points_ledger
       where business_id = p_business and client_id = p_client and entry_type = 'earn';
    else
      select coalesce(sum(ledger.points), 0) into v_metric
        from public.points_ledger ledger
       where ledger.business_id = p_business and ledger.client_id = p_client
         and ledger.entry_type = 'earn' and ledger.programme_id = v_points_programme;
    end if;
  else
    select count(*) into v_metric
      from public.sales
     where business_id = p_business and client_id = p_client and counts_as_visit;
  end if;
  v_metric := coalesce(v_metric, 0);

  -- The ladder only exists while the owner's Tiers switch is on. The metric is still reported
  -- when it is off: app.v176_tier_gate_metric answers a reward's min-tier threshold with it, and
  -- that question is about how far the customer has come, not about which rung they stand on.
  v_running := app.programme_running_v371(p_business, 'tiers');

  if v_running then
    select * into v_current
      from public.loyalty_tiers
     where business_id = p_business
       and threshold <= v_metric
       and deleted_at is null and not paused
       and (effective_from is null or effective_from <= p_as_of)
       and (expires_at is null or expires_at > p_as_of)
     order by threshold desc, sort desc, id
     limit 1;

    select * into v_next
      from public.loyalty_tiers
     where business_id = p_business
       and threshold > coalesce(v_current.threshold, -1)
       and deleted_at is null and not paused
       and (effective_from is null or effective_from <= p_as_of)
       and (expires_at is null or expires_at > p_as_of)
     order by threshold, sort, id
     limit 1;

    if v_next.id is not null then
      v_progress := greatest(0, least(100, round(
        (v_metric - coalesce(v_current.threshold, 0)) * 100
        / nullif(v_next.threshold - coalesce(v_current.threshold, 0), 0), 2
      )));
    elsif v_current.id is not null then
      v_progress := 100;
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
      'id',               ladder.id,
      'name',             ladder.name,
      'threshold',        ladder.threshold,
      'sort',             ladder.sort,
      'points_multiplier',ladder.points_multiplier,
      'perk_note',        ladder.perk_note,
      'achieved',         ladder.threshold <= v_metric
    ) order by ladder.threshold, ladder.sort, ladder.id), '[]'::jsonb) into v_ladder
      from public.loyalty_tiers ladder
     where ladder.business_id = p_business
       and ladder.deleted_at is null and not ladder.paused
       and (ladder.effective_from is null or ladder.effective_from <= p_as_of)
       and (ladder.expires_at is null or ladder.expires_at > p_as_of);
  end if;

  return jsonb_build_object(
    'contract',      'v426',
    'basis',         v_basis,
    'metric',        v_metric,
    'tiers_running', v_running,
    'current', case when v_current.id is null then null else jsonb_build_object(
      'id',                v_current.id,
      'name',              v_current.name,
      'threshold',         v_current.threshold,
      'sort',              v_current.sort,
      'points_multiplier', v_current.points_multiplier,
      'perk_note',         v_current.perk_note
    ) end,
    'next', case when v_next.id is null then null else jsonb_build_object(
      'id',                v_next.id,
      'name',              v_next.name,
      'threshold',         v_next.threshold,
      'sort',              v_next.sort,
      'points_multiplier', v_next.points_multiplier,
      'perk_note',         v_next.perk_note,
      'remaining',         greatest(v_next.threshold - v_metric, 0)
    ) end,
    'progress_percent', v_progress,
    'ladder',           v_ladder
  );
end
$function$;

-- Same ACL as every other app.* helper in this family: reachable only from the SECURITY DEFINER
-- functions that own the surface, never directly from a client role.
revoke all on function app.tier_resolve_v426(uuid, uuid, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 2. The five resolvers, re-issued as delegates. Return shapes are unchanged, key for key.
-- ---------------------------------------------------------------------------------------------

-- 2a. The earn multiplier. app.on_sale_recorded does
--     `select * into v_tier from app.loyalty_tier_for(...)` and then reads v_tier.id and
--     v_tier.points_multiplier, so this must keep returning a public.loyalty_tiers rowtype — an
--     all-NULL row when no tier applies, exactly as the `select into` with no match produced.
create or replace function app.loyalty_tier_for(p_business uuid, p_client uuid)
returns public.loyalty_tiers
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_row public.loyalty_tiers%rowtype;
begin
  select * into v_row
    from public.loyalty_tiers
   where id = (app.tier_resolve_v426(p_business, p_client) #>> '{current,id}')::uuid;
  return v_row;
end
$function$;

-- 2b. The checkout / counter reader (app.ps1c_plan_checkout, staff_tier_benefits_for_client_v365,
--     staff_issue_tier_benefit_v365). Kept SECURITY INVOKER exactly as it was.
create or replace function app.v365_client_tier(p_business uuid, p_client uuid)
returns public.loyalty_tiers
language plpgsql
stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_tier public.loyalty_tiers%rowtype;
begin
  select * into v_tier
    from public.loyalty_tiers
   where id = (app.tier_resolve_v426(p_business, p_client) #>> '{current,id}')::uuid;
  return v_tier;
end
$function$;

-- 2c. The customer tier snapshot carried inside app.customer_live_loyalty_v384. Same seven keys,
--     same null-when-there-is-no-ladder behaviour.
create or replace function app.customer_tier_json_v393(p_business_id uuid, p_client_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_resolved jsonb;
  v_current  jsonb;
  v_next     jsonb;
begin
  v_resolved := app.tier_resolve_v426(p_business_id, p_client_id);
  if v_resolved is null then
    return null;
  end if;
  v_current := v_resolved->'current';
  v_next    := v_resolved->'next';

  if (v_current is null or jsonb_typeof(v_current) = 'null')
     and (v_next is null or jsonb_typeof(v_next) = 'null') then
    return null;
  end if;

  return jsonb_build_object(
    'name',              v_current->>'name',
    'threshold',         (v_current->'threshold'),
    'perk_note',         v_current->>'perk_note',
    'points_multiplier', (v_current->'points_multiplier'),
    'basis',             v_resolved->>'basis',
    'metric',            (v_resolved->'metric'),
    'next', case when v_next is null or jsonb_typeof(v_next) = 'null' then null else jsonb_build_object(
      'name',      v_next->>'name',
      'threshold', (v_next->'threshold'),
      'remaining', (v_next->'remaining')
    ) end
  );
end
$function$;

-- 2d. The reward gate metric. Unchanged signature and numeric return; it now reads the canonical
--     basis, which is the whole fix — a reward gated on 12 points_earned was being compared
--     against a visit count on every inactive-programme tenant.
create or replace function app.v176_tier_gate_metric(p_business uuid, p_client uuid)
returns numeric
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  return coalesce((app.tier_resolve_v426(p_business, p_client)->>'metric')::numeric, 0);
end
$function$;

-- 2e. The customer-facing tier screen. Auth, link verification and the module guard are unchanged;
--     only the resolution underneath them moves. The payload is rebuilt key for key, including
--     `current` being JSON null (not false) on every ladder row when there is no current tier.
create or replace function public.customer_get_effective_tier_v143(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_identity uuid;
  v_client uuid;
  v_resolved jsonb;
  v_current jsonb;
  v_next jsonb;
  v_current_id uuid;
  v_basis text;
  v_metric numeric := 0;
  v_progress numeric := 0;
  v_tiers jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode='28000';
  end if;
  v_identity:=app.v31_current_identity();
  select link.client_id into v_client
  from public.customer_links link
  where link.identity_id=v_identity
    and link.auth_user_id=auth.uid()
    and link.business_id=p_business
    and link.state='verified';
  if not found then
    raise exception 'verified customer link required' using errcode='42501';
  end if;
  if not app.business_module_enabled_at_v117(p_business,'loyalty',null)
     or not exists(
       select 1 from public.loyalty_programs
       where business_id=p_business and active
     ) then
    raise exception 'loyalty module is unavailable for this business' using errcode='42501';
  end if;

  /* V426: basis, metric, pot scope, the V371 tiers-running gate, the current/next pair and the
     progress percentage all come from app.tier_resolve_v426 now. What used to live here was a
     fourth private copy of those rules that read the basis with an `active` filter the earn
     engine does not use — so this screen could name a tier the engine would never apply. */
  v_resolved := app.tier_resolve_v426(p_business, v_client);
  v_basis    := v_resolved->>'basis';
  v_metric   := (v_resolved->>'metric')::numeric;
  v_progress := coalesce((v_resolved->>'progress_percent')::numeric, 0);
  v_current  := nullif(v_resolved->'current', 'null'::jsonb);
  v_next     := nullif(v_resolved->'next', 'null'::jsonb);
  v_current_id := (v_current->>'id')::uuid;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',(ladder->>'id')::uuid,
    'label',ladder->>'name',
    'threshold',ladder->'threshold',
    'achieved',(ladder->>'achieved')::boolean,
    'current',(ladder->>'id')::uuid=v_current_id,
    'benefits',coalesce((
      select jsonb_agg(btrim(benefit) order by ordinal)
      from regexp_split_to_table(coalesce(ladder->>'perk_note',''),E'\\r?\\n')
        with ordinality as item(benefit,ordinal)
      where btrim(benefit)<>''
    ),'[]'::jsonb)
  ) order by ordinality),'[]'::jsonb) into v_tiers
  from jsonb_array_elements(coalesce(v_resolved->'ladder','[]'::jsonb))
       with ordinality as rung(ladder,ordinality);

  return jsonb_build_object('tier',jsonb_build_object(
    'points_mode',(select points_mode from public.businesses where id=p_business),
    'label',v_current->>'name',
    'current',case when v_current is null then null else jsonb_build_object(
      'id',(v_current->>'id')::uuid,'label',v_current->>'name','threshold',v_current->'threshold',
      'metric',v_metric,'benefits',coalesce((
        select jsonb_agg(btrim(benefit) order by ordinal)
        from regexp_split_to_table(coalesce(v_current->>'perk_note',''),E'\\r?\\n')
          with ordinality as item(benefit,ordinal)
        where btrim(benefit)<>''
      ),'[]'::jsonb)
    ) end,
    'next',case when v_next is null then null else jsonb_build_object(
      'id',(v_next->>'id')::uuid,'label',v_next->>'name','threshold',v_next->'threshold',
      'benefits',coalesce((
        select jsonb_agg(btrim(benefit) order by ordinal)
        from regexp_split_to_table(coalesce(v_next->>'perk_note',''),E'\\r?\\n')
          with ordinality as item(benefit,ordinal)
        where btrim(benefit)<>''
      ),'[]'::jsonb)
    ) end,
    'tiers',v_tiers,
    'progress_percent',v_progress,'basis',v_basis,'metric',v_metric,
    'tier_fuel','points_programme_earn','balance_scope',app.programme_balance_scope_v312(p_business)
  ));
end
$function$;

revoke all on function public.customer_get_effective_tier_v143(uuid) from public, anon;
grant execute on function public.customer_get_effective_tier_v143(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 3. The Home wallet card: model and unit come from the spine, not from loyalty_programs.
-- ---------------------------------------------------------------------------------------------
create or replace function app.c45_base_actionable_wallet_card(
  p_business_id uuid, p_client_id uuid, p_business_slug text, p_business_name text,
  p_business_industry text, p_business_currency text, p_enabled_modules text[],
  p_as_of timestamp with time zone
)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
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
      end as expiry_mode
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

revoke all on function app.c45_base_actionable_wallet_card(
  uuid, uuid, text, text, text, text, text[], timestamp with time zone
) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 4. Conversion history: one event, not two anonymous adjustments.
-- ---------------------------------------------------------------------------------------------
-- A points-to-stamps conversion writes a PAIR of points_ledger 'adjust' rows per customer at one
-- instant — 'stamp conversion: points spent' against the points pot and 'stamp conversion: stamps
-- issued' against the stamps pot — and one business-level row in
-- public.programme_stamp_conversions_v384 sharing that same created_at. A pot migration writes the
-- same shape with 'programme pot transfer out/in: <programme id>'. Neither carries anything the
-- customer's history could use, so both surfaced as "Points adjustment", one of them for -75,800.
--
-- This tags a ledger row with what it actually is. It returns NULL for every row that is not one
-- of those two families, which is how the caller tells them apart.
create or replace function app.conversion_tag_v426(p_business uuid, p_client uuid, p_ledger uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  with tagged as (
    select
      pl.id,
      pl.created_at,
      case when pl.reference like 'stamp conversion:%' then 'conversion' else 'pot_transfer' end as entry,
      case
        when pl.reference = 'stamp conversion: points spent'    then 'points_spent'
        when pl.reference = 'stamp conversion: stamps issued'   then 'stamps_issued'
        when pl.reference like 'programme pot transfer out%'    then 'transfer_out'
        when pl.reference like 'programme pot transfer in%'     then 'transfer_in'
        else 'other'
      end as role
      from public.points_ledger pl
     where pl.business_id = p_business
       and pl.client_id = p_client
       and pl.id = p_ledger
       and pl.entry_type = 'adjust'
       and (pl.reference like 'stamp conversion:%'
         or pl.reference like 'programme pot transfer out%'
         or pl.reference like 'programme pot transfer in%')
  ), pair as (
    -- THIS customer's two halves of the same conversion, so the client can render one sentence
    -- from either row and drop the other.
    select
      coalesce(sum(sibling.points) filter (
        where sibling.reference = 'stamp conversion: points spent'), 0)::integer as points_delta,
      coalesce(sum(sibling.points) filter (
        where sibling.reference = 'stamp conversion: stamps issued'), 0)::integer as stamps_delta
      from tagged
      join public.points_ledger sibling
        on sibling.business_id = p_business
       and sibling.client_id = p_client
       and sibling.created_at = tagged.created_at
       and sibling.entry_type = 'adjust'
       and sibling.reference like 'stamp conversion:%'
     where tagged.entry = 'conversion'
  ), batch as (
    -- The business-wide run this customer's pair belongs to. Joinable on (business, created_at):
    -- both are written by the same statement, so the timestamps are identical, not merely close.
    select conversion.converted_points, conversion.issued_stamps, conversion.points_per_stamp,
           conversion.leftover_points, conversion.converted_customers, conversion.idempotency_key
      from tagged
      join public.programme_stamp_conversions_v384 conversion
        on conversion.business_id = p_business
       and conversion.created_at = tagged.created_at
     where tagged.entry = 'conversion'
     limit 1
  )
  select jsonb_build_object(
    'entry',                tagged.entry,
    'entry_group',          tagged.entry || ':' || to_char(
                              tagged.created_at at time zone 'UTC',
                              'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'entry_role',           tagged.role,
    'points_delta',         case when tagged.entry = 'conversion' then pair.points_delta end,
    'stamps_delta',         case when tagged.entry = 'conversion' then pair.stamps_delta end,
    'converted_points',     batch.converted_points,
    'issued_stamps',        batch.issued_stamps,
    'points_per_stamp',     batch.points_per_stamp,
    'leftover_points',      batch.leftover_points,
    'converted_customers',  batch.converted_customers,
    'conversion_batch_key', batch.idempotency_key
  )
    from tagged
    left join pair on true
    left join batch on true;
$function$;

revoke all on function app.conversion_tag_v426(uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public.customer_get_transaction_history_v167(
  p_business_slug text,
  p_cursor jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_context record;
  v_result jsonb;
  v_items jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;

  select * into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  v_result := public.customer_get_transaction_history_v81(p_business_slug, p_cursor);

  select coalesce(jsonb_agg(
    (case
      when item->>'source_kind' = 'sale' and package_use.id is not null then
        item || jsonb_build_object(
          'is_package_session', true,
          'package_name', customer_package.plan_name_snapshot,
          'package_purchased_at', customer_package.purchased_at,
          'package_reference', left(customer_package.id::text, 8)
        )
      else item || jsonb_build_object('is_package_session', false)
    end)
    /* V426: additive. Every item gains an `entry` key so the client can switch on it; a
       conversion or pot-transfer row gains the fields needed to render the pair as one event.
       Nothing is removed — the raw ledger lines are still there for a client that does not
       collapse them. */
    || coalesce(conversion.tag, '{"entry": null}'::jsonb)
    order by ordinal
  ), '[]'::jsonb) into v_items
    from jsonb_array_elements(coalesce(v_result->'items', '[]'::jsonb))
         with ordinality listed(item, ordinal)
    left join public.package_session_consumptions package_use
      on listed.item->>'source_kind' = 'sale'
     and package_use.business_id = v_context.business_id
     and package_use.client_id = v_context.client_id
     and package_use.sale_id = nullif(listed.item->>'source_id', '')::uuid
    left join public.client_packages customer_package
      on customer_package.business_id = package_use.business_id
     and customer_package.client_id = package_use.client_id
     and customer_package.id = package_use.client_package_id
    left join lateral (
      select app.conversion_tag_v426(
        v_context.business_id, v_context.client_id,
        case when listed.item->>'source_kind' = 'points_ledger'
          then nullif(listed.item->>'source_id', '')::uuid end
      ) as tag
    ) conversion on true;

  return jsonb_set(v_result, '{items}', v_items, true);
end;
$function$;

revoke all on function public.customer_get_transaction_history_v167(text, jsonb) from public, anon;
grant execute on function public.customer_get_transaction_history_v167(text, jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 5. Backfill: the v354 sync invariant, restated as data.
-- ---------------------------------------------------------------------------------------------
-- public.loyalty_programs.loyalty_model and .kind describe which programme a business runs; the
-- business_programmes spine DECIDES it. Where they disagree, the spine wins — it is what the
-- owner's switch writes, what redeem_reward_core prices against, and what
-- app.live_balance_programme_v381 already counts the balance in.
--
-- Idempotent and guarded: only businesses with an accruing programme actually running are
-- considered (a tenant with points and stamps both off implies no model at all, and guessing one
-- would be worse than leaving the column alone), and only rows that actually differ are written.
-- Re-running this migration writes zero rows.
with spine as (
  select
    programme.business_id,
    bool_or(programme.kind = 'stamps' and programme.active) as stamps_on,
    bool_or(programme.kind = 'points' and programme.active) as points_on,
    bool_or(programme.kind = 'tiers'  and programme.active) as tiers_on
  from public.business_programmes programme
  group by programme.business_id
), intended as (
  select
    spine.business_id,
    case
      when spine.stamps_on then 'stamps'
      when spine.points_on and spine.tiers_on then 'points_tiers'
      when spine.points_on then 'classic'
    end as loyalty_model,
    case when spine.stamps_on then 'stamps' when spine.points_on then 'points' end as kind
  from spine
  where spine.stamps_on or spine.points_on
)
update public.loyalty_programs program
   set loyalty_model = intended.loyalty_model,
       kind          = intended.kind
  from intended
 where intended.business_id = program.business_id
   and (program.loyalty_model is distinct from intended.loyalty_model
     or program.kind          is distinct from intended.kind);

commit;
