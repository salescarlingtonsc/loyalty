# Supabase Project Sync CLI Runbook

This harness performs a one-way database migration from `kyzovonwnscrzmkvocid` to either the rehearsal branch `wtegnefsgnyxhflzizcu` or the final Singapore project `gadpooereceldfpfxsod`. It follows Supabase's official [Backup and Restore using the CLI](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore) procedure.

It does not migrate project-level configuration, Storage object bytes, Edge Functions, API keys, Auth provider/SMTP settings, Realtime publication settings, or Vault encryption root keys. Review Supabase's current guide before every migration. Paid projects with physical backups may be better served by Supabase's Restore to another project feature.

## Safety Model

- Database URLs are read only from `OLD_DB_URL` and `NEW_DB_URL`; URL arguments are rejected because they persist in shell history.
- Diagnostics redact complete URL values. Never enable shell tracing with `set -x`.
- Only the fixed source ref and two fixed target refs are accepted. Source and target cannot be equal.
- Artifacts live under `.local/supabase-sync/<run-id>/`, mode `0700`, and are gitignored.
- Roles, schema, data, and `supabase_migrations` schema/data are separate artifacts.
- Data dumps exclude `storage.buckets_vectors` and `storage.vector_indexes` as Supabase recommends.
- Every artifact is SHA-256 checksummed. Inspection and both restores reject changed files or symlinks.
- Base restores use one `psql` transaction, `ON_ERROR_STOP=1`, and `session_replication_role=replica` for data.
- Cron definitions are source-derived into a separate artifact. Rehearsal never executes it. Final activation occurs only after the final verification hook passes.
- Preflight records only aggregate Auth-user and Storage-object counts. It fails closed when Storage contains objects unless separately verified byte-copy evidence exists.
- The default row-count hook is a smoke check only and cannot authorize final cutover or cron activation.
- Final restore requires strict inventory/reconciliation evidence, a manual configuration attestation, `MAINTENANCE_MODE_CONFIRMED=yes`, and the literal final ref in `CONFIRM_TARGET_REF`.

The Supabase CLI currently requires the database URL in its `--db-url` child-process argument. Supplying it to this harness through the environment avoids shell-history exposure, but privileged users on the migration host may still inspect child-process arguments. Run from a dedicated, trusted workstation with no untrusted local users.

## Prerequisites

- Bash 3.2 or newer.
- Supabase CLI `2.81.3` or newer.
- Docker with a running daemon; `supabase db dump` uses Docker.
- PostgreSQL 17 `psql`, at least as new as both database servers.
- Node.js 18 or newer for strict cutover evidence generation and validation.
- Direct or Session Pooler URLs on port 5432. Do not use transaction pooling on port 6543.
- Source and target database passwords stored in a password manager.
- Enough local encrypted disk space for the dumps and logs.
- A tested maintenance window that stops all application and operator writes to the source.

The harness does not place the source in maintenance mode. `MAINTENANCE_MODE_CONFIRMED=yes` is an operator attestation, not an automated write lock.

## Commands

Set URLs without putting their values in command history. One safe interactive pattern is:

```bash
read -rsp 'Source database URL: ' OLD_DB_URL; echo
read -rsp 'Target database URL: ' NEW_DB_URL; echo
export OLD_DB_URL NEW_DB_URL
```

Choose a run ID and retain it through all phases:

```bash
export SYNC_RUN_ID="sg-cutover-$(date -u +%Y%m%dT%H%M%SZ)"
scripts/supabase-sync/sync.sh prerequisites
scripts/supabase-sync/sync.sh preflight
scripts/supabase-sync/sync.sh dump
scripts/supabase-sync/sync.sh inspect
```

First set `NEW_DB_URL` to the rehearsal branch and restore:

```bash
scripts/supabase-sync/sync.sh restore-rehearsal
scripts/supabase-sync/sync.sh verify-hook
```

The default hook compares table row counts only. It is useful for early rehearsal diagnosis but is explicitly insufficient for final cutover.

Run the strict hook after rehearsal restore. It executes the read-only wrappers in `db/cutover`, combines their inventory and reconciliation output, and requires the comparator to return no findings:

```bash
scripts/supabase-sync/sync.sh verify-hook \
  --verify-hook scripts/supabase-sync/verify-cutover-gate.sh
```

The strict hook receives source and target URLs through its environment and writes only aggregate/fingerprinted evidence under `.local/supabase-sync/<run-id>/cutover-gate/`. It checks schema, migrations, RLS, grants, functions, Auth/Storage counts, tenant aggregates, financial ledgers, liabilities, cron and Realtime. Because cron must remain inactive until verification passes, the hook proves the target cron catalog is empty, compares all other state using the cutover comparator, and records the source cron definitions as a deferred activation plan. Final restore separately proves that this manifest-protected plan has not changed since dump. The harness requires `ok=true`, zero findings, zero blockers and explicit deferred-cron evidence before issuing a strict marker or activating cron. A successful hook exit code alone is insufficient. This still does not prove that Storage object bytes or Dashboard configuration were copied.

### Storage byte gate

If preflight reports a nonzero `storage_object_count`, copy and independently verify every object byte before proceeding. Object-copy tooling is intentionally out of scope. Create this marker for the exact destination only after external evidence passes:

```text
.local/supabase-sync/<run-id>/attestations/storage-bytes-<target-ref>.verified

kind=storage-byte-migration-v1
source_ref=kyzovonwnscrzmkvocid
target_ref=<target-ref>
source_storage_object_count=<exact-preflight-count>
bytes_verified=yes
evidence_sha256=<sha256-of-external-verification-report>
```

Rehearsal and final targets need separate markers. The harness rechecks source counts before final restore and fails if they changed after the dump.

### Manual configuration gate

Before final restore, create `.local/supabase-sync/<run-id>/attestations/manual-config-gadpooereceldfpfxsod.verified` after completing the Dashboard parity review. Its manifest hash is the SHA-256 of `manifest.sha256`:

```text
kind=manual-config-parity-v1
source_ref=kyzovonwnscrzmkvocid
target_ref=gadpooereceldfpfxsod
manifest_sha256=<sha256-of-manifest.sha256>
auth_smtp_captcha=verified
realtime=verified
extensions=verified
storage=verified
edge_functions=verified
secrets=verified
verified_by=<responsible-person>
```

For final cutover, stop all writes, create a fresh dump/run, repeat and verify the rehearsal, set `NEW_DB_URL` to the final project, and then run:

```bash
export MAINTENANCE_MODE_CONFIRMED=yes
export CONFIRM_TARGET_REF=gadpooereceldfpfxsod
scripts/supabase-sync/sync.sh final-restore \
  --verify-hook scripts/supabase-sync/verify-cutover-gate.sh
```

The final phase rejects the default row-count hook, requires strict rehearsal evidence and the manual configuration marker, rechecks source counts and target emptiness, restores the exact manifest, runs the strict comparator against the final target, and only then activates captured cron jobs. A restore error rolls back the entire base restore transaction. A later verification error leaves the restored target populated but keeps cron inactive; inspect it and recreate the target before attempting a clean rerun.

Preview any phase without filesystem or database writes:

```bash
scripts/supabase-sync/sync.sh final-restore --dry-run
```

## Required Manual Parity Checks

Before application cutover, compare source and target Dashboard settings:

- Auth site URL, redirect allowlist, email confirmation, password policy, CAPTCHA, SMTP, OAuth and other providers.
- API publishable key replacement in the application and removal of the old project origin after cutover.
- Enabled extensions and their versions, Database Webhooks, Realtime publications and replica identity.
- Storage buckets, object bytes, policies, size/type restrictions and custom domains.
- Edge Functions, secrets, schedules, logs and external webhooks.
- Network restrictions, SSL enforcement, PITR/backups, compute sizing and connection pooling.
- Vault or column-encryption keys. Manual logical restore does not copy the source encryption root key.

Validate owner, employee, anonymous and cross-tenant access; login and password reset; customer join; booking; sale/points/credit/referral flows; report totals; exports; and each scheduled job. Keep the old project read-only and available until the rollback window closes.

## Rollback

Before application cutover, rollback is simply to leave production traffic on the old project and discard/recreate the target. After application writes reach the new project, do not point traffic back without reconciling those writes; doing so creates split-brain data loss. The old project should remain read-only, and rollback must follow an approved data reconciliation plan.

## Local Tests

The tests use fake `supabase`, `psql`, and `docker` executables and make no network connections:

```bash
bash scripts/supabase-sync/test/run.sh
bash -n scripts/supabase-sync/*.sh scripts/supabase-sync/test/run.sh scripts/supabase-sync/test/fakes/*
```
