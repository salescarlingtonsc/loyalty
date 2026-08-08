-- Nestly v256 — remove the v239 guard. Tiers and redeemable points DO coexist.
--
-- This migration is filed retrospectively: it was applied to production on 2026-08-09 as
-- `nestly_v256_tier_may_measure_lifetime_points_while_points_are_spendable` (deploy version
-- 20260808184533) and the file was missed in the same batch. The body below is the exact
-- statement set that was applied; it is idempotent, so replaying the canonical chain is safe.
--
-- What v239 asserted, and why it was wrong.
-- v239 added a pair of triggers refusing any configuration where a business ran points in
-- `points_mode='both'` while its programme measured tiers on `tier_basis='points_earned'`. The
-- reasoning was that spending points to redeem a reward would drop a customer out of a tier they
-- had already earned — a demotion nobody chose.
--
-- The owner's ruling: "tier is based on lifetime spending / lifetime points accumulated - with or
-- without expiry while points is for redemption purpose". That is not merely a preference; it is
-- how the engine already behaves, and v239 was guarding against a bug that does not exist:
--
--   app.customer_get_effective_tier_v143 computes the tier input as
--     select coalesce(sum(points),0) from public.points_ledger
--      where client_id = ... and business_id = ... and entry_type = 'earn'
--
-- `entry_type='earn'` is the whole point. Redemptions are written as a separate entry type, so
-- they are never subtracted from the tier measure. Lifetime earned only ever rises. A customer
-- who earns 5,000 points and spends 4,900 of them keeps the tier that 5,000 bought, and has 100
-- points left to spend. This is the Chagee model the owner asked for, and the engine implemented
-- it correctly before v239 existed.
--
-- So the guard did not protect a real invariant; it blocked a legitimate, already-correct
-- configuration — the exact configuration the owner wants. It is removed rather than relaxed:
-- a narrower version of a rule that should not exist is still a rule that should not exist.
--
-- Nothing replaces it. The two settings are orthogonal by construction: `points_mode` governs
-- what a customer may DO with points (redeem, count toward tiers, or both) and `tier_basis`
-- governs what the tier MEASURES (visits, spend, or lifetime points earned). No combination of
-- the two can lower a tier, because no combination changes the `entry_type='earn'` filter above.
--
-- Reversibility: re-applying v239 would restore the guard, but doing so would once again reject
-- the owner's chosen configuration. Recorded here so the ruling is not re-litigated.

begin;

drop trigger if exists v239_guard_points_mode on public.businesses;
drop trigger if exists v239_guard_tier_basis on public.loyalty_programs;
drop function if exists app.v239_guard_points_and_tier_basis();

commit;
