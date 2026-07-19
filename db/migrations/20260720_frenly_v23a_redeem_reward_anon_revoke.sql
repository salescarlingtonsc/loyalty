-- FRENLY v23a — revoke anon EXECUTE from public.redeem_reward (v21-invariant fix for v23).
-- Applied migration name: frenly_v23a_redeem_reward_anon_revoke
--
-- v23 created public.redeem_reward as SECURITY DEFINER. The `public` schema carries Supabase
-- default privileges that grant `anon` EXECUTE on newly created functions, so redeem_reward was
-- born anon-executable — the SAME class as the v13/v22 regression, this time via the public-schema
-- default (v22b only removed the implicit PUBLIC grant, not the explicit anon grant). `revoke all
-- from public` in v23 did not strip the explicit `anon` grant. This restores the v21 invariant:
-- no SECURITY DEFINER function in app/public is executable by anon/PUBLIC. `authenticated` keeps
-- EXECUTE (the frontend calls redeem_reward via PostgREST as a signed-in owner/staff member).
--
-- Lesson: every new SECURITY DEFINER RPC in schema `public` must EXPLICITLY revoke anon; the
-- `app` schema does not have this default, which is why app.loyalty_tier_for was already correct.

begin;
revoke execute on function public.redeem_reward(uuid, uuid, uuid, text) from anon, public;
commit;
