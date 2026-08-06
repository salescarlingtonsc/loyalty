-- V197 + V197a — the duplicate-reward root cause (owner: "rewards cannot be set up - have you
-- tested?"). APPLIED TO PRODUCTION 2026-08-07 via MCP apply_migration
-- (nestly_v197_recommendation_seeds_reward_once, nestly_v197a_clone_starts_from_live_active).
--
-- TWO DEFECTS, ONE SYMPTOM
--
-- 1. THE SEED HAD NO IDENTITY.
--    generate_retention_recommendation seeds a starting reward by calling
--    save_loyalty_config_draft with a 'reward' payload carrying NO id. That function treats a
--    missing id as "create", so every run minted a BRAND NEW reward — while the draft it had
--    just created was already cloned from live and therefore already contained the previously
--    published copy of that same reward. The existing-draft early return hid this while a draft
--    was open, so duplicates only landed once the owner PUBLISHED and ran the recommendation
--    again. Hougang ABC did that six times and ended with six identical rows at 8 stamps.
--    Setup never failed; it silently duplicated, which is why it read as broken.
--
--    Fix: only seed when the draft carries NO active reward. The recommendation is a STARTING
--    point; a firm that already has a reward has nothing to seed. Guarded on the draft's own
--    cloned rows rather than on the customer-facing name, which an owner may edit at any time.
--
-- 2. A NEW DRAFT STARTED FROM A STALE VERSION, NOT FROM LIVE.
--    Found while verifying (1): app.clone_reward_versions_for_config copied `active` straight
--    from the based-on version. The V189 cleanup had retired five duplicates in
--    public.loyalty_rewards (what customers see) but they remain ACTIVE in the immutable
--    published version they were promoted from — and publish_loyalty_config sets
--    loyalty_rewards.active = rv.active. The very next publish would have resurrected all five,
--    so that cleanup was not durable.
--
--    Published version rows are immutable by design (V176's reward_version_immutable_guard) and
--    rightly so: they record what was actually promised. So the clone now inherits the live
--    row's active flag when the reward still exists in public.loyalty_rewards, falling back to
--    the version's own flag otherwise. This is the correct semantic regardless of the duplicate
--    bug — an owner opening a new draft expects it to start from what customers can see today.
--
-- VERIFIED against production in rolled-back transactions:
--   live version rows 7/7 active (history untouched); live catalogue 2 active; a NEW draft
--   clones 7 rows with only 2 active — duplicates stay retired — and the seed guard then
--   declines to add another.
--
-- Applied as asserted string replacement (1) and full redefinition (2); the seed patch aborts if
-- its anchor has drifted rather than patching a body it does not recognise.
begin;

create or replace function app.clone_reward_versions_for_config()
returns trigger
language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
begin
  if new.based_on_version_id is null then return new; end if;
  insert into public.loyalty_reward_versions (
    reward_id, business_id, config_version_id, internal_name, customer_name,
    description, fulfillment_kind, taxonomy_label, cost_points, credit_cents,
    estimated_cost_cents, active, sort, claim_available_from, claim_available_until,
    entitlement_expiry_days, instructions, terms, image_ref, usage_limit,
    min_tier_id, min_tier_threshold
  )
  select source.reward_id, source.business_id, new.id, source.internal_name, source.customer_name,
         source.description, source.fulfillment_kind, source.taxonomy_label, source.cost_points,
         source.credit_cents, source.estimated_cost_cents,
         coalesce(live.active, source.active),
         source.sort, source.claim_available_from, source.claim_available_until,
         source.entitlement_expiry_days, source.instructions, source.terms, source.image_ref,
         source.usage_limit, source.min_tier_id, source.min_tier_threshold
    from public.loyalty_reward_versions source
    left join public.loyalty_rewards live
      on live.id = source.reward_id and live.business_id = source.business_id
   where source.config_version_id = new.based_on_version_id
     and source.business_id = new.business_id;

  insert into public.loyalty_reward_branches (reward_version_id, reward_id, business_id, branch_id)
  select next_rv.id, next_rv.reward_id, old_e.business_id, old_e.branch_id
    from public.loyalty_reward_versions old_rv
    join public.loyalty_reward_branches old_e on old_e.reward_version_id = old_rv.id
    join public.loyalty_reward_versions next_rv
      on next_rv.config_version_id = new.id and next_rv.reward_id = old_rv.reward_id
   where old_rv.config_version_id = new.based_on_version_id;

  insert into public.loyalty_reward_services (reward_version_id, reward_id, business_id, service_id)
  select next_rv.id, next_rv.reward_id, old_e.business_id, old_e.service_id
    from public.loyalty_reward_versions old_rv
    join public.loyalty_reward_services old_e on old_e.reward_version_id = old_rv.id
    join public.loyalty_reward_versions next_rv
      on next_rv.config_version_id = new.id and next_rv.reward_id = old_rv.reward_id
   where old_rv.config_version_id = new.based_on_version_id;

  insert into public.loyalty_reward_products (reward_version_id, reward_id, business_id, product_id)
  select next_rv.id, next_rv.reward_id, old_e.business_id, old_e.product_id
    from public.loyalty_reward_versions old_rv
    join public.loyalty_reward_products old_e on old_e.reward_version_id = old_rv.id
    join public.loyalty_reward_versions next_rv
      on next_rv.config_version_id = new.id and next_rv.reward_id = old_rv.reward_id
   where old_rv.config_version_id = new.based_on_version_id;
  return new;
end $function$;

-- The seed guard is applied to generate_retention_recommendation in place; see the migration
-- notes above. Re-deriving on a fresh database means re-running that asserted replacement.

commit;
