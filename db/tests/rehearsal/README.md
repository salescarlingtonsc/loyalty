# Local rehearsal harness — full canonical-chain replay on plain Postgres

This is the exact procedure used on 2026-07-23 to verify v50/v50a/v50b, and repeated through
v100 on 2026-07-29: a fresh replay of the complete canonical migration chain on a scratch
Postgres (no Docker, no Supabase CLI), followed by the final-schema-compatible rolled-back
acceptance suites for the phase under review. It reproduced the production catalog
faithfully enough to surface two live defects (SGT birth-date validation, stale v30
contact-proof constraint), so treat it as the standard pre-review verification for any new
migration. It is also the natural substrate for the P0-FINANCE-REVERSAL-005 /
P0-REPORTING-SCALE-006 rehearsal gates.

## One-time cluster setup (macOS, Homebrew Postgres 17)

```bash
initdb -D "$REHEARSAL_DIR/data" -U postgres -E UTF8 --no-locale -A trust
printf "port = 5499\nlisten_addresses = '127.0.0.1'\nunix_socket_directories = ''\ntimezone = 'UTC'\n" \
  >> "$REHEARSAL_DIR/data/postgresql.conf"
LC_ALL=C pg_ctl -D "$REHEARSAL_DIR/data" -l "$REHEARSAL_DIR/server.log" start
```

Notes: `unix_socket_directories = ''` avoids macOS socket-path length limits (TCP only);
`LC_ALL=C` avoids the macOS "postmaster became multithreaded during startup" locale bug;
`timezone = 'UTC'` matches Supabase — REQUIRED, several defects only reproduce when the
server clock disagrees with SGT (run suites during 00:00–08:00 SGT for the full effect).

## Per-replay procedure

```bash
export PGHOST=127.0.0.1 PGPORT=5499 PGUSER=postgres
createdb frenly_rehearsal
psql -d frenly_rehearsal -v ON_ERROR_STOP=1 -q -f db/tests/rehearsal/bootstrap.sql
psql -d frenly_rehearsal -c "create role authenticator nologin"   # v21 suite asserts it exists

# Apply the canonical chain in manifest order, skipping ONLY the two
# platform-extension statements (both provided by bootstrap.sql stubs):
node -e "const m=require('./supabase/canonical-migration-order.manifest.json'); console.log(m.items.map(i=>i.path).join('\n'))" |
while IFS= read -r f; do
  sed -e 's|^CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";|-- rehearsal: bootstrap stub|' \
      -e 's|^[Cc][Rr][Ee][Aa][Tt][Ee] [Ee][Xx][Tt][Ee][Nn][Ss][Ii][Oo][Nn] [Ii][Ff] [Nn][Oo][Tt] [Ee][Xx][Ii][Ss][Tt][Ss] .\{0,1\}pg_cron.*$|-- rehearsal: bootstrap stub|' \
      "$f" | psql -d frenly_rehearsal -v ON_ERROR_STOP=1 -q || { echo "FAILED: $f"; break; }
done

# Run the phase's final-schema-compatible rolled-back suites explicitly. The
# pending-migration preflight map is the source of truth for which suite belongs
# to each pending migration. Example for v99/v100:
psql -d frenly_rehearsal -v ON_ERROR_STOP=1 -f db/tests/v99_v100_campaign_truth_adoption.sql

# Then run the latest synthetic end-to-end journey against the final schema:
psql -d frenly_rehearsal -v ON_ERROR_STOP=1 -f db/tests/v93_synthetic_e2e_campaign.sql
```

After the selected suites, `select count(*) from public.businesses` and `from auth.users`
must both be 0 — every compatible suite owns its own `begin;`…`rollback;`.

Do **not** treat `for f in db/tests/*.sql` on the final schema as a release gate. Several
historical files are point-in-time migration suites: they deliberately assert function bodies,
permissions, or onboarding defaults that later migrations replace. Replaying those files against
the latest schema creates false failures and previously hid fixture drift such as the v94 approval
gate. If a historical suite must be rerun, replay the canonical chain only through that suite's
declared migration boundary. New release evidence must use a current final-schema-compatible suite
and an explicit mapping in `tests/phase0-foundation/pending-migration-preflight.test.mjs`.

## Documented deviations from production (all platform-provided there)

`bootstrap.sql` supplies minimal local equivalents for: the `anon` / `authenticated` /
`service_role` / `authenticator` roles, the `auth` schema (`users`, `uid()`, `jwt()`,
`role()`), the `extensions` schema (real pgcrypto / uuid-ossp / pg_stat_statements),
a `cron` schema with `schedule()` / `unschedule()` equivalents (stub for pg_cron), a
`vault.secrets` table (stub for supabase_vault), the `storage.buckets` metadata table
used by the private SME document migration, and the `supabase_realtime` publication.
Storage object APIs remain platform-owned and are not emulated. Nothing else in the
chain is altered; the migration manifest determines the current count and order (139 files through
v100 at the 2026-07-29 rehearsal) and every file applies byte-for-byte otherwise.

## What this harness is NOT

It is not production evidence. Launch-gate artifacts must be captured by the named release
owner against the real target per `docs/launch/evidence-plan/`. This harness exists so
defects are found and fixed before that evidence run, not instead of it.
