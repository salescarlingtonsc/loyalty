-- V232 — a single abandoned promotion publish must never take the whole REST API down.
--
-- Applied to production live, during the incident, under the name
-- `nestly_v231_promotion_lock_cannot_take_down_the_api`: it was renumbered to v232 here
-- because a concurrent session had already claimed v231 for an unrelated change. The
-- production ledger keeps the name it was applied under; this file is the same change.
--
-- Incident 2026-08-07 (production outage, ~17:27–18:05 UTC):
-- business_finalize_promotion_v15x serialises on a per-business advisory lock taken by
-- app.v104_lock_promotion_business. A PostgREST transaction acquired that lock and then
-- lost its client. Because idle_in_transaction_session_timeout was 0 (PostgreSQL's
-- default, unset on this project) the transaction held the lock indefinitely. Every
-- later promotion call queued behind it and held a pool connection while it waited, so
-- the PostgREST pool drained. Once no connection was free PostgREST could not run its
-- schema-cache query and answered EVERY request on EVERY surface with
-- 503 PGRST002 "Could not query the database for the schema cache" — including business
-- sign-in, which is how the outage was reported ("why my business account not able to
-- log in"). Google sign-in itself never failed: GoTrue is a separate service and its
-- logs show four successful logins during the outage. The app then threw each admitted
-- session away because the follow-up admission RPC 503'd, and surfaced its generic
-- "No business account was found for that Google login" message.
--
-- Two independent guards, either of which alone would have contained it.
begin;

-- (1) Reap abandoned transactions. This is the guard that stops a stuck lock holder from
--     being permanent. PostgREST's transactions are sub-second, so 60s can only ever
--     catch a session whose client is already gone.
alter role authenticator set idle_in_transaction_session_timeout = '60s';

-- (2) Bound the wait itself so callers fail fast with a reason an owner can act on,
--     instead of stacking up and consuming the pool. lock_timeout is attached to the
--     function so it reverts on exit and cannot leak into the caller's transaction; the
--     advisory lock stays transaction-scoped and re-entrant exactly as before, so the
--     success path is byte-for-byte the previous behaviour.
create or replace function app.v104_lock_promotion_business(p_business uuid)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
set lock_timeout to '5s'
as $function$
begin
  perform pg_advisory_xact_lock(
    hashtextextended('nestly.v104.promotion:'||p_business::text,0)
  );
exception when lock_not_available then
  raise exception 'Another promotion change for this business is still saving. Wait a moment and try again.'
    using errcode='55P03';
end
$function$;

commit;
