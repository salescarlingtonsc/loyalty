-- nestly_v410 — one finalize function per name (P0: no promotion could be saved at all).
--
-- SYMPTOM (owner, 2026-08-21): pressing "Update published offer" showed "Offer was not published."
-- and the generic "Something went wrong on our side." No promotion could be published or updated.
--
-- CAUSE, proved against production by calling the RPC and reading the error:
--   PGRST203 — "Could not choose the best candidate function between:
--     public.business_finalize_promotion_v155(... p_expected_content_version => bigint ...)
--     public.business_finalize_promotion_v155(... p_expected_content_version => integer ...)"
--
-- The three expected-version parameters were declared `bigint` from v104 through v280. v378 (v155)
-- and v379 (v154) re-declared them as `integer`. `create or replace function` keys on the ARGUMENT
-- TYPES, so changing a parameter's type does not replace a function — it creates a second one.
-- Both names ended up with twin overloads differing only in integer-vs-bigint, and PostgREST
-- cannot choose between them for a JSON number: every finalize call fails before it reaches the
-- database. v380 saw half of this and moved the breaker onto the bigint overload, but leaving both
-- in place is precisely what makes the call ambiguous, so the breaker was never reached either.
--
-- FIX: drop the accidental `integer` twins. `bigint` is the canonical, original declaration and is
-- the one v380's circuit breaker lives on, so dropping the twin restores a single candidate and
-- leaves the surviving function byte-for-byte as v380 shipped it. Nothing else changes: no table,
-- no policy, no grant, no success path.
--
-- REVERSIBLE: the dropped bodies are the ones in
--   db/migrations/20260817_nestly_v378_promotion_finalize_breaker.sql        (v155, integer)
--   db/migrations/20260817_nestly_v379_promotion_finalize_breaker_v154.sql  (v154, integer)
-- Re-running those two files recreates them exactly — but doing so would restore the outage.
--
-- VERIFY AFTER APPLYING (unauthenticated is fine — the point is which error comes back):
--   POST /rest/v1/rpc/business_finalize_promotion_v155 with the 26 named arguments.
--   BEFORE: {"code":"PGRST203", ...}
--   AFTER : an auth/permission refusal, which is the correct answer for an anonymous caller and
--           proves the name resolves to exactly one function again.

begin;

drop function if exists public.business_finalize_promotion_v155(
  uuid, uuid, text, uuid[], uuid, text, text, text, text,
  timestamp with time zone, timestamp with time zone,
  integer, text, text, text, text, boolean, text, text,
  integer, integer, text,
  integer, integer, integer, uuid);

drop function if exists public.business_finalize_promotion_v154(
  uuid, uuid, text, uuid[], uuid, text, text, text, text,
  timestamp with time zone, timestamp with time zone,
  integer, text, text, text, text, boolean, text, text,
  integer, integer, text,
  integer, integer, integer, uuid);

commit;
