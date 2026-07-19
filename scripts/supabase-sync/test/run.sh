#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SYNC_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
REPO_ROOT=$(cd -- "$SYNC_DIR/../.." && pwd -P)
FAKES="$SCRIPT_DIR/fakes"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/supabase-sync-test.XXXXXX")
trap 'rm -rf "$WORK"; rm -rf "$REPO_ROOT/.local/supabase-sync/test-sync" "$REPO_ROOT/.local/supabase-sync/test-storage-block"' EXIT

export FAKE_LOG="$WORK/fake.log"
export PSQL_BIN="$FAKES/psql"
export SUPABASE_BIN="$FAKES/supabase"
export DOCKER_BIN="$FAKES/docker"
export OLD_DB_URL='postgresql://postgres.kyzovonwnscrzmkvocid:old-secret@aws-0-ap-south-1.pooler.supabase.com:5432/postgres'
export REHEARSAL_URL='postgresql://postgres.wtegnefsgnyxhflzizcu:new-secret@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres'
export FINAL_URL='postgresql://postgres.gadpooereceldfpfxsod:new-secret@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres'
export SYNC_RUN_ID=test-sync

passes=0
failures=0

pass() {
  printf 'ok - %s\n' "$1"
  passes=$((passes + 1))
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  failures=$((failures + 1))
}

expect_success() {
  local name="$1"
  shift
  if "$@" >"$WORK/out" 2>"$WORK/err"; then pass "$name"; else cat "$WORK/err" >&2; fail "$name"; fi
}

expect_failure() {
  local name="$1"
  shift
  if "$@" >"$WORK/out" 2>"$WORK/err"; then fail "$name"; else pass "$name"; fi
}

expect_success 'shell syntax is valid' bash -n "$SYNC_DIR/sync.sh" "$SYNC_DIR/lib.sh" "$SYNC_DIR/verify-default.sh" "$SYNC_DIR/verify-cutover-gate.sh" "$0" "$FAKES/supabase" "$FAKES/psql" "$FAKES/docker"
expect_success 'prerequisites parse Homebrew psql version suffix' "$SYNC_DIR/sync.sh" prerequisites
export FAKE_PSQL_VERSION_OUTPUT='psql (PostgreSQL) 17.10'
expect_success 'prerequisites parse upstream psql version output' "$SYNC_DIR/sync.sh" prerequisites
unset FAKE_PSQL_VERSION_OUTPUT

export NEW_DB_URL="$REHEARSAL_URL"
expect_success 'dry-run redacts both database URLs' "$SYNC_DIR/sync.sh" dump --dry-run
if grep -q 'old-secret\|new-secret' "$WORK/out" "$WORK/err"; then fail 'dry-run output contains no credentials'; else pass 'dry-run output contains no credentials'; fi

export NEW_DB_URL='postgresql://postgres.notanapprovedproject:secret@pooler.example:5432/postgres'
expect_failure 'unapproved target ref is rejected' "$SYNC_DIR/sync.sh" preflight --dry-run

export NEW_DB_URL='postgresql://postgres:contains-gadpooereceldfpfxsod@db.attacker.example:5432/postgres'
expect_failure 'approved ref embedded only in a password is rejected' "$SYNC_DIR/sync.sh" preflight --dry-run

export NEW_DB_URL='postgresql://postgres:direct-secret@db.wtegnefsgnyxhflzizcu.supabase.co:5432/postgres'
expect_success 'official direct target URL is accepted' "$SYNC_DIR/sync.sh" preflight --dry-run

export NEW_DB_URL="$OLD_DB_URL"
expect_failure 'same source and target are rejected' "$SYNC_DIR/sync.sh" preflight --dry-run

export NEW_DB_URL="$REHEARSAL_URL"
export SYNC_RUN_ID=test-storage-block
export FAKE_SOURCE_STORAGE_OBJECTS=2
export FAKE_SOURCE_AUTH_USERS=7
expect_failure 'preflight blocks when Storage has objects but byte migration is unverified' "$SYNC_DIR/sync.sh" preflight
if grep -Fqx 'auth_user_count=7' "$REPO_ROOT/.local/supabase-sync/test-storage-block/artifacts/source-counts.env" &&
   grep -Fqx 'storage_object_count=2' "$REPO_ROOT/.local/supabase-sync/test-storage-block/artifacts/source-counts.env" &&
   ! grep -Eqi 'email|phone|token|password' "$REPO_ROOT/.local/supabase-sync/test-storage-block/artifacts/source-counts.env"; then
  pass 'preflight records non-PII source Auth and Storage counts'
else
  fail 'preflight records non-PII source Auth and Storage counts'
fi

export SYNC_RUN_ID=test-sync
export FAKE_SOURCE_STORAGE_OBJECTS=2
export FAKE_SOURCE_AUTH_USERS=1
main_attestations="$REPO_ROOT/.local/supabase-sync/test-sync/attestations"
mkdir -p "$main_attestations"
chmod 700 "$REPO_ROOT/.local/supabase-sync/test-sync" "$main_attestations"
printf '%s\n' \
  'kind=storage-byte-migration-v1' \
  'source_ref=kyzovonwnscrzmkvocid' \
  'target_ref=wtegnefsgnyxhflzizcu' \
  'source_storage_object_count=2' \
  'bytes_verified=yes' \
  'evidence_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  >"$main_attestations/storage-bytes-wtegnefsgnyxhflzizcu.verified"
expect_success 'read-only preflight passes against fake databases' "$SYNC_DIR/sync.sh" preflight
expect_success 'dump, inspect, and manifest generation pass' "$SYNC_DIR/sync.sh" dump
if grep -R -q 'old-secret\|new-secret' "$REPO_ROOT/.local/supabase-sync/test-sync/logs"; then
  fail 'persisted diagnostics contain no URL or password credentials'
else
  pass 'persisted diagnostics contain no URL or password credentials'
fi
if grep -q -- '-x storage.buckets_vectors -x storage.vector_indexes' "$FAKE_LOG" &&
   grep -q -- '--schema supabase_migrations' "$FAKE_LOG"; then
  pass 'dump uses Supabase vector exclusions and separate migration history'
else
  fail 'dump uses Supabase vector exclusions and separate migration history'
fi

expect_success 'rehearsal restore succeeds with verified artifacts' "$SYNC_DIR/sync.sh" restore-rehearsal
if grep -q 'activate-cron' "$FAKE_LOG"; then fail 'rehearsal leaves cron inactive'; else pass 'rehearsal leaves cron inactive'; fi
expect_success 'default verification hook passes' "$SYNC_DIR/sync.sh" verify-hook

export NEW_DB_URL="$FINAL_URL"
unset MAINTENANCE_MODE_CONFIRMED CONFIRM_TARGET_REF || true
expect_failure 'final restore requires maintenance confirmation' "$SYNC_DIR/sync.sh" final-restore
export MAINTENANCE_MODE_CONFIRMED=yes
export CONFIRM_TARGET_REF=gadpooereceldfpfxsod
expect_failure 'default row-count verification cannot authorize final cutover' "$SYNC_DIR/sync.sh" final-restore

strict_hook="$WORK/strict-hook.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'mkdir -p "$(dirname "$VERIFY_EVIDENCE_FILE")"' \
  'printf '\''{"ok":true,"launch_blocked":false,"verified_target_ref":"%s","cron_activation_deferred":true,"actual_target_cron_jobs":0,"source_cron_jobs":1,"summary":{"findings":0,"blockers":0,"source_required_paths":28,"target_required_paths":28},"findings":[]}\n'\'' "$VERIFY_TARGET_REF" >"$VERIFY_EVIDENCE_FILE"' \
  'printf "strict-hook\n" >>"$FAKE_LOG"' \
  'exit 0' >"$strict_hook"
chmod 700 "$strict_hook"
export NEW_DB_URL="$REHEARSAL_URL"
expect_success 'non-default strict rehearsal hook creates strict gate' "$SYNC_DIR/sync.sh" verify-hook --verify-hook "$strict_hook"

export NEW_DB_URL="$FINAL_URL"
expect_failure 'missing manual configuration attestation blocks final restore' "$SYNC_DIR/sync.sh" final-restore --verify-hook "$strict_hook"

manifest_hash=$(sha256sum "$REPO_ROOT/.local/supabase-sync/test-sync/manifest.sha256" | awk '{print $1}')
manual_marker="$REPO_ROOT/.local/supabase-sync/test-sync/attestations/manual-config-gadpooereceldfpfxsod.verified"
printf '%s\n' \
  'kind=manual-config-parity-v1' \
  'source_ref=kyzovonwnscrzmkvocid' \
  'target_ref=gadpooereceldfpfxsod' \
  "manifest_sha256=$manifest_hash" \
  'auth_smtp_captcha=verified' \
  'realtime=verified' \
  'extensions=verified' \
  'storage=verified' \
  'edge_functions=verified' \
  'secrets=verified' \
  'verified_by=offline-test' >"$manual_marker"
chmod 600 "$manual_marker"

expect_failure 'final restore blocks nonzero Storage objects without final byte evidence' "$SYNC_DIR/sync.sh" final-restore --verify-hook "$strict_hook"
printf '%s\n' \
  'kind=storage-byte-migration-v1' \
  'source_ref=kyzovonwnscrzmkvocid' \
  'target_ref=gadpooereceldfpfxsod' \
  'source_storage_object_count=2' \
  'bytes_verified=yes' \
  'evidence_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  >"$main_attestations/storage-bytes-gadpooereceldfpfxsod.verified"
chmod 600 "$main_attestations"/*.verified

before_final_lines=$(wc -l <"$FAKE_LOG")
expect_success 'confirmed strict final restore verifies before cron activation' "$SYNC_DIR/sync.sh" final-restore --verify-hook "$strict_hook"
after_final_log="$WORK/after-final.log"
tail -n "+$((before_final_lines + 1))" "$FAKE_LOG" >"$after_final_log"
if grep -q 'strict-hook' "$after_final_log" &&
   grep -q 'cron-enable.sql' "$after_final_log" &&
   [[ $(grep -n 'strict-hook' "$after_final_log" | tail -1 | cut -d: -f1) -lt $(grep -n 'cron-enable.sql' "$after_final_log" | tail -1 | cut -d: -f1) ]]; then
  pass 'cron activation occurs after final verification'
else
  fail 'cron activation occurs after final verification'
fi

printf '%s\n' '-- tampered' >>"$REPO_ROOT/.local/supabase-sync/test-sync/artifacts/schema.sql"
expect_failure 'restore rejects a changed artifact' "$SYNC_DIR/sync.sh" final-restore --verify-hook "$strict_hook"

printf '\n%d passed; %d failed\n' "$passes" "$failures"
((failures == 0))
