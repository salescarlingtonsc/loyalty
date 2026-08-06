-- V176 Stage B: tier-gated rewards — read path and enforcement.
-- APPLIED TO PRODUCTION 2026-08-06 via MCP apply_migration in four parts
-- (nestly_v176e_tier_gate_resolver, nestly_v176f_redeem_enforces_tier_gate,
--  nestly_v176g_catalog_shows_tier_gate, nestly_v176h_draft_reader_returns_tier_gate).
--
-- Stage A gave the gate somewhere to live. On its own that is inert: nothing read it. Stage B
-- makes it bite, in the order that matters.
--
-- ENFORCEMENT FIRST, DISPLAY SECOND
-- Hiding or greying a reward in the customer app is not a gate — the redemption RPC is the
-- only thing standing between a Basic member and a Diamond perk. app.redeem_reward_core now
-- refuses a gate it has not met, checked BEFORE the points balance so the member is told the
-- real reason ("higher membership tier") rather than a misleading "not enough points".
--
-- ONE RESOLVER, TWO CALLERS
-- app.v176_reward_gate_threshold and app.v176_tier_gate_metric are shared by the guard and the
-- catalog, so the badge a member sees can never disagree with what the counter will allow.
-- Resolution order is deliberate:
--   1. min_tier_id still resolves to a live tier -> use that tier's CURRENT threshold, so the
--      gate follows an owner who later edits the tier;
--   2. otherwise fall back to the stored min_tier_threshold, so DELETING a tier tightens the
--      gate to its last known value instead of silently opening a premium reward to everyone;
--   3. neither set -> no gate.
-- The member's metric uses the same basis as the tier ladder (visits / spend / points earned),
-- matching customer_get_effective_tier_v143.
--
-- LOCKED, NOT HIDDEN
-- customer_get_reward_catalog returns availability 'tier_locked' plus a tier_requirement object
-- carrying the tier NAME. A hidden reward teaches the member nothing; "Reach Gold to unlock" is
-- the entire reason a tier ladder changes behaviour. customerRewardCanRedeem already pins the
-- redeem button to 'available_at_counter', so a locked card offers no action without a change.
--
-- get_loyalty_reward_draft returns the gate so the owner editor can read back what it saved;
-- without it the picker silently reset to "Everyone" on every reopen. The draft payload already
-- carried 'tiers', so the picker's options needed no new plumbing, and save_loyalty_config_draft
-- passes the reward envelope to save_loyalty_reward_draft wholesale, so the Stage A allow-list
-- already accepts both keys.
--
-- VERIFIED against production inside a rolled-back transaction on 2026-08-06, using two real
-- members of the same business under one gate (Gold, threshold 3000) — 45 points vs 77,286:
--   A1 live tier threshold is preferred over the stored fallback;
--   A2 an unresolvable tier falls back to the stored threshold (gate does not open);
--   A3 an ungated reward reports no gate;
--   A4 the below-tier member sees availability=tier_locked with the tier name, met=false;
--   A5 redemption for that member is REFUSED with "higher membership tier";
--   A6 the above-tier member sees the same reward unlocked, met=true;
--   A7 redemption for that member is not blocked by the gate;
--   A8 clearing the gate restores the reward for everyone, with no stray tier_requirement.
-- Production left with zero gated rewards and zero redemptions written.
--
-- NOTE: redeem_reward_core, get_loyalty_reward_draft and (in Stage A) publish_loyalty_config /
-- save_loyalty_reward_draft were patched by asserted string replacement against their live
-- definitions rather than retyped. Each patch asserts its anchor exists and re-reads the result
-- to prove the change landed. These are ledger-writing and publish-kernel functions where a
-- transcription slip is worse than the feature is valuable. This file records the resulting
-- contract; re-deriving it on a fresh database means re-running those patches.
begin;

-- The member's position on the tier ladder, in the ladder's own units.
create or replace function app.v176_tier_gate_metric(p_business uuid, p_client uuid)
returns numeric
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_basis text;
  v_metric numeric := 0;
begin
  select coalesce(tier_basis,'visits') into v_basis
    from public.loyalty_programs
   where business_id = p_business and active
   limit 1;

  if v_basis = 'spend' then
    select coalesce(sum(amount_cents),0)/100.0 into v_metric
      from public.sales
     where business_id = p_business and client_id = p_client and counts_as_revenue;
  elsif v_basis = 'points_earned' then
    select coalesce(sum(points),0) into v_metric
      from public.points_ledger
     where business_id = p_business and client_id = p_client and entry_type = 'earn';
  else
    select count(*) into v_metric
      from public.sales
     where business_id = p_business and client_id = p_client and counts_as_visit;
  end if;
  return coalesce(v_metric,0);
end $$;

-- The effective gate for a reward version, or null when ungated. Deleting a tier must never
-- open a gate, so the stored threshold is the floor, not a hint.
create or replace function app.v176_reward_gate_threshold(
  p_business uuid, p_min_tier_id uuid, p_min_tier_threshold integer
)
returns integer
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_live integer;
begin
  if p_min_tier_id is null and p_min_tier_threshold is null then
    return null;
  end if;
  if p_min_tier_id is not null then
    select threshold into v_live
      from public.loyalty_tiers
     where business_id = p_business and id = p_min_tier_id
     limit 1;
    if v_live is not null then
      return v_live;
    end if;
  end if;
  return p_min_tier_threshold;
end $$;

create or replace function app.v176_reward_gate_label(p_business uuid, p_min_tier_id uuid)
returns text
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select t.name from public.loyalty_tiers t
   where t.business_id = p_business and t.id = p_min_tier_id
   limit 1;
$$;

revoke all on function app.v176_tier_gate_metric(uuid,uuid) from public, anon;
revoke all on function app.v176_reward_gate_threshold(uuid,uuid,integer) from public, anon;
revoke all on function app.v176_reward_gate_label(uuid,uuid) from public, anon;

-- Enforcement: refuse a gated reward the member has not unlocked. Checked before the balance
-- test so the refusal names the real reason.
do $$
declare
  v_def text;
  v_anchor text := '  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger where business_id=p_business and client_id=p_client;';
  v_guard text := '  if app.v176_reward_gate_threshold(p_business, v_version.min_tier_id, v_version.min_tier_threshold) is not null'
    || ' and app.v176_tier_gate_metric(p_business, p_client) < app.v176_reward_gate_threshold(p_business, v_version.min_tier_id, v_version.min_tier_threshold) then'
    || E'\n    raise exception ''reward requires a higher membership tier'' using errcode=''check_violation'';'
    || E'\n  end if;\n';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='redeem_reward_core';
  if v_def is null then raise exception 'app.redeem_reward_core not found'; end if;
  if v_def like '%v176_reward_gate_threshold%' then return; end if;
  if position(v_anchor in v_def) = 0 then
    raise exception 'balance-check anchor not found in redeem_reward_core; refusing to patch blind';
  end if;
  execute replace(v_def, v_anchor, v_guard || v_anchor);
end $$;

do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='redeem_reward_core';
  if v_def !~ 'reward requires a higher membership tier' then
    raise exception 'tier gate guard did not land in redeem_reward_core';
  end if;
  if position('reward requires a higher membership tier' in v_def)
     > position('insufficient proven points' in v_def) then
    raise exception 'tier gate must be checked before the balance check';
  end if;
end $$;

-- Owner editor must be able to read back the gate it saved.
do $$
declare
  v_def text;
  v_anchor text := '''usage_limit'', rv.usage_limit,';
  v_add text := '''min_tier_id'', rv.min_tier_id,' || E'\n        ''min_tier_threshold'', rv.min_tier_threshold,' || E'\n        ';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='get_loyalty_reward_draft';
  if v_def is null then raise exception 'public.get_loyalty_reward_draft not found'; end if;
  if v_def like '%min_tier_id%' then return; end if;
  if position(v_anchor in v_def) = 0 then
    raise exception 'usage_limit anchor not found; refusing to patch blind';
  end if;
  execute replace(v_def, v_anchor, v_add || v_anchor);
end $$;

-- Customer catalog: locked, not hidden. Full definition rather than a patch, because the whole
-- availability CASE changes shape here.
create or replace function public.customer_get_reward_catalog(p_business_slug text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_context record;
  v_balance integer;
  v_metric numeric;
  v_result jsonb;
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
             when v_balance < rv.cost_points then 'insufficient_balance'
             else 'available_at_counter'
           end as availability
      from public.businesses b
      join public.loyalty_reward_versions rv
        on rv.business_id = b.id and rv.config_version_id = b.active_config_version_id and rv.active
      left join lateral (
        select count(*)::integer as used_count
          from public.loyalty_redemptions lr
         where lr.business_id = v_context.business_id and lr.client_id = v_context.client_id
           and lr.reward_id = rv.reward_id
      ) usage on true
     where b.id = v_context.business_id
  ) listed;

  return v_result;
end;
$function$;

revoke all on function public.customer_get_reward_catalog(text) from public, anon;
grant execute on function public.customer_get_reward_catalog(text) to authenticated;

commit;
