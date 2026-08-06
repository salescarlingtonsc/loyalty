-- V176 Stage A: tier-gated rewards — kernel foundation.
-- APPLIED TO PRODUCTION 2026-08-06 via MCP apply_migration in four parts
-- (nestly_v176a_reward_tier_gate_columns, nestly_v176b_clone_carries_tier_gate,
--  nestly_v176c_publish_carries_tier_gate, nestly_v176d_save_draft_accepts_tier_gate).
--
-- WHY THIS SHAPE
-- The versioned-config kernel copies columns EXPLICITLY in three places, so a new column is
-- silently dropped unless every one of them learns it. That is the dangerous failure mode for
-- this feature: an owner sets "Gold only", publishes, sees no error, and the gate quietly
-- disappears. The three surfaces are:
--   app.clone_reward_versions_for_config   draft -> draft clone (20-column INSERT ... SELECT)
--   public.publish_loyalty_config          versions -> live loyalty_rewards (column-explicit UPDATE)
--   public.save_loyalty_reward_draft       editor -> draft (key allow-list + INSERT + ON CONFLICT)
--
-- TWO COLUMNS, DELIBERATELY
--   min_tier_id         soft reference to loyalty_tiers.tier_id. NOT a foreign key on purpose:
--                       publish_loyalty_config does DELETE+INSERT on loyalty_tiers on every
--                       publish, so an FK would fight the publish cycle.
--   min_tier_threshold  authoritative fallback captured at save time, so a gate stays
--                       meaningful if the tier is later deleted instead of silently exposing a
--                       premium reward to everyone.
-- Read path (Stage B) resolves min_tier_id against live tiers first so the gate follows an
-- owner's later threshold edit, and falls back to min_tier_threshold when it no longer resolves.
--
-- VERIFIED against production inside rolled-back transactions on 2026-08-06:
--   * gate survives draft -> draft cloning across two generations;
--   * gate is promoted to public.loyalty_rewards by the publish UPDATE;
--   * rewards without a gate are never gated by publish;
--   * production left with zero gated rewards and zero leaked test config versions.
--
-- NOTE: parts b/c/d were applied as string-replacement patches against the live function
-- definitions (each asserting its match before executing) rather than retyped, because
-- publish_loyalty_config (~6.2KB) and save_loyalty_reward_draft (~9.6KB) are publish-kernel
-- code where a transcription slip is worse than the feature is valuable. This file records the
-- resulting contract; re-deriving it on a fresh database means re-running those patches.
begin;

alter table public.loyalty_rewards
  add column if not exists min_tier_id uuid,
  add column if not exists min_tier_threshold integer;

alter table public.loyalty_reward_versions
  add column if not exists min_tier_id uuid,
  add column if not exists min_tier_threshold integer;

comment on column public.loyalty_rewards.min_tier_id is
  'V176 soft reference to loyalty_tiers.tier_id gating this reward; null = available to every member.';
comment on column public.loyalty_rewards.min_tier_threshold is
  'V176 fallback gate value used when min_tier_id no longer resolves to a live tier.';
comment on column public.loyalty_reward_versions.min_tier_id is
  'V176 draft-side tier gate; carried by app.clone_reward_versions_for_config and promoted by publish_loyalty_config.';
comment on column public.loyalty_reward_versions.min_tier_threshold is
  'V176 draft-side fallback gate value.';

commit;
