-- FRENLY v22b — effective closure of the default-PUBLIC function-privilege recreation vector.
-- Applied migration name: frenly_v22b_global_function_default_privileges
--
-- v22a attempted `alter default privileges for role postgres IN SCHEMA app revoke ...` and was a
-- verified NO-OP: schema-scoped default-privilege entries are additive deltas starting from
-- EMPTY, so an in-schema revoke cannot remove PostgreSQL's built-in "EXECUTE to PUBLIC" grant on
-- newly created functions. The GLOBAL form below is the documented way to change the built-in
-- default: every function subsequently created by `postgres` (the migration-authoring role) in
-- ANY schema is born WITHOUT the implicit PUBLIC EXECUTE grant.
--
-- Effect on schema `app`: new functions are born owner-only — the exact class of regression that
-- created anon/PUBLIC-executable `app.commission_flat_cents` (fixed by v22) cannot recur silently.
-- Effect on schema `public`: unchanged in practice — Supabase's explicit in-schema default
-- entries (anon/authenticated/service_role EXECUTE, visible in pg_default_acl) are additive and
-- continue to apply, so PostgREST-exposed RPCs keep working exactly as before; only the
-- redundant implicit PUBLIC grant disappears. v21's explicit revokes + test suite remain the
-- enforced control for the public-schema API surface.

begin;

alter default privileges for role postgres
  revoke execute on functions from public;

commit;
