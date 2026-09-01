-- Baseline role privileges for the executed-SQL harness.
--
-- WHY THIS FILE EXISTS
--   tests/fixtures/db-schema-snapshot.sql is produced by pg_dump with --no-privileges
--   (scripts/db-tests/snapshot-schema.mjs), so the restored baseline has the tables, the
--   policies and the routines but NO table or routine privileges for anon / authenticated /
--   service_role. Production is a Supabase project where those roles hold the standard
--   schema-wide grants, so the harness baseline was not faithful to production.
--
--   That gap was not cosmetic. v599 (browser write boundaries) revokes a specific set of
--   privileges and then asserts the resulting ACL, including that a SELECT which must
--   survive is still present. Against a privilege-less baseline that post-condition can
--   never hold, so v599 raised and the migration chain stopped there — taking EVERY
--   later migration with it. Before this file, no v6xx migration applied in the harness,
--   which silently removed the entire Customer Intelligence layer (v620-v665, including
--   v628-v652) from the only place in this repo that executes real SQL.
--
--   The second-order risk was worse than the missing coverage. A tenant-isolation test run
--   as `authenticated` against a baseline where `authenticated` holds no grants at all
--   passes for the wrong reason: it proves the role cannot read anything anywhere, not that
--   the policy scopes it to its own tenant. Restoring the grants is what makes
--   `set local role authenticated` mean what it says.
--
-- WHAT IT REPRODUCES
--   Supabase's default posture for a project's exposed schema: anon, authenticated and
--   service_role each hold schema-wide privileges on `public`, and service_role holds them
--   on the internal `app` schema too. Migrations then revoke from that baseline — which is
--   the direction the committed migrations are written in. Postgres also grants EXECUTE on
--   functions to PUBLIC by default; the explicit service_role grants below matter because a
--   migration that revokes EXECUTE `from public, anon, authenticated` would otherwise strip
--   service_role's only route to the routine along with it.
--
-- APPLIED BY scripts/db-tests/run.mjs immediately after the snapshot is restored, so it
-- lands after the objects exist and before any pending migration runs.

grant usage on schema public to anon, authenticated, service_role;

/* `authenticated` holds USAGE on `app` in production: frenly_v19_public_gateway_security grants
   `usage on schema app to authenticated, service_role`. That migration is BELOW the v422
   snapshot watermark, so the grant survives only inside the snapshot — and the snapshot strips
   privileges. Nothing replays it, so omitting it here would leave the harness STRICTER than
   production, which is the dangerous direction: an isolation test would pass locally while the
   real database is more permissive than the test believes. Individual app.* routines are still
   governed by their own explicit revokes in the migrations that define them. */
grant usage on schema app to authenticated, service_role;

grant all on all tables    in schema public to anon, authenticated, service_role;
grant all on all sequences in schema public to anon, authenticated, service_role;
grant all on all functions in schema public to anon, authenticated, service_role;

grant all on all tables    in schema app to service_role;
grant all on all sequences in schema app to service_role;
grant all on all functions in schema app to service_role;
