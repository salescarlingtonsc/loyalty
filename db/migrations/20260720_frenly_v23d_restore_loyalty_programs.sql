-- FRENLY v23d — RESTORE the original loyalty_programs schema (regression recovery) + v23 fields.
-- Applied migration name: frenly_v23d_restore_loyalty_programs
--
-- REGRESSION (introduced this session): v23 assumed loyalty_programs was new and used
-- `create table if not exists`, which silently kept the PRE-EXISTING table; a subsequent manual
-- `drop table … cascade` (mistaking it for a partial) destroyed the original schema
-- (id/kind/earn_rate_bps/stamp_target/reward_credit_cents/active/earn_points_per_dollar/
-- redeem_points) and replaced it with v23-only columns. That broke public.redeem_points and any
-- read of the earn config (e.g. the sale auto-earn path). No data was lost (0 program rows in the
-- test tenants). This migration restores the EXACT original columns and re-adds v23's two genuinely
-- new fields (tier_basis, loyalty_model) as additive columns on the same table.
--
-- The v23 loyalty_rewards / loyalty_tiers / loyalty_redemptions tables and the redeem_reward /
-- loyalty_tier_for functions are unaffected and remain in place.

begin;

-- Drop the mangled v23-only table (0 rows; nothing FKs to it — only its own policies drop).
drop table if exists public.loyalty_programs cascade;

-- Restore the original schema (frenly_init + v2_saas), byte-for-byte, so redeem_points and the
-- earn path work exactly as before, PLUS the two additive v23 fields.
create table public.loyalty_programs (
  id                     uuid primary key default gen_random_uuid(),
  business_id            uuid not null unique references public.businesses(id) on delete cascade,
  kind                   text not null default 'points' check (kind in ('points','stamps')),
  earn_rate_bps          integer not null default 500,
  stamp_target           integer,
  reward_credit_cents    integer not null default 0,
  active                 boolean not null default true,
  earn_points_per_dollar numeric not null default 1,
  redeem_points          integer not null default 800,
  -- v23 additive: the points-&-tiers model + how tiers are earned (owner-selectable).
  tier_basis             text not null default 'visits' check (tier_basis in ('visits','spend','points_earned')),
  loyalty_model          text not null default 'points_tiers' check (loyalty_model in ('points_tiers'))
);
comment on column public.loyalty_programs.tier_basis is
  'v23: how tiers are earned — visits (recommended) / spend / points_earned. Owner-selectable.';
comment on column public.loyalty_programs.loyalty_model is
  'v23: the selected loyalty model. points_tiers ships now; a second model slots in as a new value.';

-- RLS: auto-enabled by the ensure_rls event trigger; (re)create member-read / owner-write /
-- super-admin-read, guarded so a re-run can never collide on a duplicate policy name.
alter table public.loyalty_programs enable row level security;
drop policy if exists loyalty_programs_read    on public.loyalty_programs;
drop policy if exists loyalty_programs_write   on public.loyalty_programs;
drop policy if exists loyalty_programs_sa_read on public.loyalty_programs;
drop policy if exists loyalty_programs_all     on public.loyalty_programs;
create policy loyalty_programs_read    on public.loyalty_programs for select using (app.is_salon_member(business_id));
create policy loyalty_programs_write   on public.loyalty_programs for all    using (app.is_salon_owner(business_id)) with check (app.is_salon_owner(business_id));
create policy loyalty_programs_sa_read on public.loyalty_programs for select using (app.is_super_admin());

commit;
