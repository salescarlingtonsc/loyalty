-- nestly_v326a_gift_rpc_anon_revoke
--
-- Security-advisor follow-up to v326. New functions default to PUBLIC EXECUTE in Postgres,
-- which this project's schema-level default-privilege migrations (frenly_v22a/v22b) do not
-- retroactively strip from a role that already held it at the moment the function was created
-- (they only rewrite the ALTER DEFAULT PRIVILEGES for the schema, not existing grants). The three
-- v326 immediate-write RPCs — business_set_reward_paused_v326, business_delete_reward_v326,
-- business_create_reward_v326 — were flagged by get_advisors as anon-executable, unlike every
-- comparable owner-only write in this module (set_programmes_v314, publish_loyalty_config,
-- business_delete_promotion_v183, all anon-revoked already). The internal
-- app.c45_owner_loyalty_write(p_business) check already blocks a real anonymous caller with
-- 42501 — this is defense in depth, matching the standing precedent set by
-- frenly_v23a_redeem_reward_anon_revoke, not a fix for an exploitable hole.
--
-- v326 itself was corrected in the same review pass to carry an explicit
-- `revoke ... from public` immediately after each function it defines (the house convention
-- pending-migration-preflight.test.mjs enforces), which already subsumes these three anon-only
-- revokes. Left in place — a REVOKE that has nothing left to revoke is a no-op, not an error —
-- rather than rewritten, since this file is already applied to production.

begin;

revoke execute on function public.business_set_reward_paused_v326(uuid, uuid, boolean) from anon;
revoke execute on function public.business_delete_reward_v326(uuid, uuid) from anon;
revoke execute on function public.business_create_reward_v326(uuid, uuid, text, integer, integer) from anon;

commit;
