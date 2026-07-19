#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
DRY_RUN=no
RUN_ID="${SYNC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
VERIFY_HOOK="${VERIFY_HOOK:-$SCRIPT_DIR/verify-default.sh}"
PHASE=""
TARGET_REF=""
PSQL_BIN="${PSQL_BIN:-psql}"
SUPABASE_BIN="${SUPABASE_BIN:-supabase}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
NODE_BIN="${NODE_BIN:-node}"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  unset PGDATABASE PGPASSWORD OLD_DB_URL NEW_DB_URL VERIFY_DB_URL || true
}
trap cleanup EXIT HUP INT TERM

usage() {
  cat <<'EOF'
Usage: scripts/supabase-sync/sync.sh <phase> [options]

Phases:
  prerequisites       Check local CLI, Docker, and PostgreSQL client versions.
  preflight           Read-only source inventory and empty-target checks.
  dump                Create roles/schema/data/history/cron artifacts and manifest.
  inspect             Verify artifacts, checksums, exclusions, and cron suppression.
  restore-rehearsal   Restore only to wtegnefsgnyxhflzizcu; cron remains inactive.
  verify-hook         Verify the rehearsal using the configured executable hook.
  final-restore       Restore final target, verify, then activate source cron jobs.

Options:
  --run-id ID         Reuse a run directory across phases.
  --verify-hook PATH  Executable verification hook; receives secrets by environment.
  --dry-run           Print redacted commands without executing or writing files.
  --help              Show this help.

Database URLs are accepted only through OLD_DB_URL and NEW_DB_URL.
EOF
}

parse_args() {
  (($# >= 1)) || { usage >&2; exit 2; }
  PHASE="$1"
  shift
  while (($#)); do
    case "$1" in
      --run-id)
        (($# >= 2)) || die "--run-id requires a value"
        RUN_ID="$2"
        shift 2
        ;;
      --verify-hook)
        (($# >= 2)) || die "--verify-hook requires a path"
        VERIFY_HOOK="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=yes
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *) die "unknown option: $1" ;;
    esac
  done
  case "$PHASE" in
    prerequisites|preflight|dump|inspect|restore-rehearsal|verify-hook|final-restore) ;;
    *) die "unknown phase: $PHASE" ;;
  esac
}

phase_prerequisites() {
  if [[ "$DRY_RUN" == "yes" ]]; then
    note '[dry-run] command -v supabase psql docker and SHA-256 utility'
    note '[dry-run] supabase --version (must be >= 2.81.3)'
    note '[dry-run] psql --version (major must be >= 17)'
    note '[dry-run] docker info'
    return
  fi

  command -v "$SUPABASE_BIN" >/dev/null 2>&1 || die "Supabase CLI is required"
  command -v "$PSQL_BIN" >/dev/null 2>&1 || die "psql is required"
  command -v "$DOCKER_BIN" >/dev/null 2>&1 || die "Docker is required by supabase db dump"
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || die "SHA-256 utility is required"

  local supabase_version psql_version psql_major
  supabase_version=$($SUPABASE_BIN --version | awk 'NR==1 {sub(/^v/, "", $1); print $1}')
  version_ge "$supabase_version" "$MIN_SUPABASE_VERSION" ||
    die "Supabase CLI $supabase_version is older than required $MIN_SUPABASE_VERSION"
  psql_version=$(psql_client_version)
  psql_major="${psql_version%%.*}"
  [[ "$psql_major" =~ ^[0-9]+$ ]] || die "could not parse psql version"
  ((psql_major >= MIN_PSQL_MAJOR)) || die "psql major $psql_major is older than required $MIN_PSQL_MAJOR"
  "$DOCKER_BIN" info >/dev/null 2>&1 || die "Docker daemon is not available"
  note "Prerequisites passed: Supabase CLI $supabase_version, psql $psql_version, Docker available."
}

dry_run_db_context() {
  validate_db_urls
  note "[dry-run] source ref: $SOURCE_REF"
  note "[dry-run] target ref: $TARGET_REF"
  note "[dry-run] run directory: .local/supabase-sync/$RUN_ID"
}

assert_target_empty() {
  local public_relations auth_users migration_rows cron_jobs
  public_relations=$(psql_scalar "$NEW_DB_URL" "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p','v','m','S','f')")
  auth_users=$(psql_scalar "$NEW_DB_URL" "select count(*) from auth.users")
  migration_rows=$(psql_scalar "$NEW_DB_URL" "select case when to_regclass('supabase_migrations.schema_migrations') is null then 0 else (select count(*) from supabase_migrations.schema_migrations) end")
  cron_jobs=$(psql_scalar "$NEW_DB_URL" "select case when to_regclass('cron.job') is null then 0 else (select count(*) from cron.job) end")
  [[ "$public_relations" == 0 && "$auth_users" == 0 && "$migration_rows" == 0 && "$cron_jobs" == 0 ]] ||
    die "target is not empty (public relations=$public_relations, auth users=$auth_users, migrations=$migration_rows, cron jobs=$cron_jobs)"
}

record_source_counts() {
  local auth_user_count storage_object_count
  auth_user_count=$(psql_scalar "$OLD_DB_URL" 'select count(*) from auth.users')
  storage_object_count=$(psql_scalar "$OLD_DB_URL" 'select count(*) from storage.objects')
  [[ "$auth_user_count" =~ ^[0-9]+$ && "$storage_object_count" =~ ^[0-9]+$ ]] ||
    die "source count inventory returned non-numeric data"
  printf 'kind=source-count-inventory-v1\nsource_ref=%s\ntarget_ref=%s\nauth_user_count=%s\nstorage_object_count=%s\n' \
    "$SOURCE_REF" "$TARGET_REF" "$auth_user_count" "$storage_object_count" >"$ARTIFACT_DIR/source-counts.env"
  chmod 600 "$ARTIFACT_DIR/source-counts.env"
  SOURCE_AUTH_USER_COUNT="$auth_user_count"
  SOURCE_STORAGE_OBJECT_COUNT="$storage_object_count"
}

load_source_counts() {
  local file="$ARTIFACT_DIR/source-counts.env"
  [[ -f "$file" && ! -L "$file" ]] || die "source count inventory is missing"
  SOURCE_AUTH_USER_COUNT=$(awk -F= '$1 == "auth_user_count" { print $2 }' "$file")
  SOURCE_STORAGE_OBJECT_COUNT=$(awk -F= '$1 == "storage_object_count" { print $2 }' "$file")
  [[ "$SOURCE_AUTH_USER_COUNT" =~ ^[0-9]+$ && "$SOURCE_STORAGE_OBJECT_COUNT" =~ ^[0-9]+$ ]] ||
    die "source count inventory is invalid"
}

assert_source_counts_unchanged() {
  load_source_counts
  local current_auth current_storage
  current_auth=$(psql_scalar "$OLD_DB_URL" 'select count(*) from auth.users')
  current_storage=$(psql_scalar "$OLD_DB_URL" 'select count(*) from storage.objects')
  [[ "$current_auth" == "$SOURCE_AUTH_USER_COUNT" ]] || die "source auth user count changed after dump"
  [[ "$current_storage" == "$SOURCE_STORAGE_OBJECT_COUNT" ]] || die "source Storage object count changed after dump"
}

assert_source_cron_unchanged() {
  local current_dir="$RUN_DIR/current-source"
  mkdir -p "$current_dir"
  chmod 700 "$current_dir"
  PGDATABASE="$OLD_DB_URL" PGOPTIONS='-c default_transaction_read_only=on' \
    "$PSQL_BIN" -X --quiet --set ON_ERROR_STOP=1 \
    --file "$SCRIPT_DIR/sql/cron-inventory.sql" >"$current_dir/cron-inventory.tsv"
  printf '%s\n' '-- Generated from source cron.job. Run only after target verification succeeds.' >"$current_dir/cron-enable.sql"
  PGDATABASE="$OLD_DB_URL" PGOPTIONS='-c default_transaction_read_only=on' \
    "$PSQL_BIN" -X --quiet --set ON_ERROR_STOP=1 \
    --file "$SCRIPT_DIR/sql/cron-enable.sql" >>"$current_dir/cron-enable.sql"
  chmod 600 "$current_dir"/*
  cmp -s "$ARTIFACT_DIR/cron-inventory.tsv" "$current_dir/cron-inventory.tsv" ||
    die "source cron inventory changed after dump"
  cmp -s "$ARTIFACT_DIR/cron-enable.sql" "$current_dir/cron-enable.sql" ||
    die "source cron activation plan changed after dump"
}

canonical_hook_path() {
  local path="$1" directory
  directory=$(cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$directory" "$(basename -- "$path")"
}

is_default_verify_hook() {
  local hook default
  hook=$(canonical_hook_path "$VERIFY_HOOK") || return 1
  default=$(canonical_hook_path "$SCRIPT_DIR/verify-default.sh") || return 1
  [[ "$hook" == "$default" ]]
}

phase_preflight() {
  validate_db_urls
  if [[ "$DRY_RUN" == "yes" ]]; then
    dry_run_db_context
    note '[dry-run] PGDATABASE=<OLD_DB_URL:redacted> psql -X --file inventory.sql (read-only)'
    note '[dry-run] PGDATABASE=<NEW_DB_URL:redacted> psql -X --file inventory.sql (read-only)'
    note '[dry-run] target emptiness checks: public relations, auth users, migration history, cron jobs'
    return
  fi
  init_run_dir
  phase_prerequisites

  local old_server new_server old_major new_major
  old_server=$(psql_scalar "$OLD_DB_URL" 'show server_version_num')
  new_server=$(psql_scalar "$NEW_DB_URL" 'show server_version_num')
  old_major=$((old_server / 10000))
  new_major=$((new_server / 10000))
  ((old_major == new_major)) || die "source PostgreSQL $old_major and target PostgreSQL $new_major are incompatible for this harness"
  local local_psql_major
  local_psql_major=$(psql_client_version)
  local_psql_major="${local_psql_major%%.*}"
  ((local_psql_major >= old_major)) || die "psql major must be at least the database server major $old_major"

  record_source_counts
  require_storage_byte_marker "$SOURCE_STORAGE_OBJECT_COUNT" "$TARGET_REF"
  assert_target_empty

  PGDATABASE="$OLD_DB_URL" PGOPTIONS='-c default_transaction_read_only=on' \
    "$PSQL_BIN" -X --quiet --set ON_ERROR_STOP=1 --file "$SCRIPT_DIR/sql/inventory.sql" >"$ARTIFACT_DIR/source-inventory.txt"
  PGDATABASE="$NEW_DB_URL" PGOPTIONS='-c default_transaction_read_only=on' \
    "$PSQL_BIN" -X --quiet --set ON_ERROR_STOP=1 --file "$SCRIPT_DIR/sql/inventory.sql" >"$ARTIFACT_DIR/target-preflight-inventory.txt"
  printf 'source=%s\ntarget=%s\npostgres_major=%s\n' "$SOURCE_REF" "$TARGET_REF" "$old_major" >"$RUN_DIR/preflight.ok"
  chmod 600 "$RUN_DIR/preflight.ok" "$ARTIFACT_DIR"/*.txt
  note "Read-only preflight passed for $SOURCE_REF -> $TARGET_REF."
}

supabase_dump() {
  local label="$1" output="$2"
  shift 2
  run_logged "$label" "$SUPABASE_BIN" db dump --db-url "$OLD_DB_URL" -f "$output" "$@"
}

phase_dump() {
  validate_db_urls
  if [[ "$DRY_RUN" == "yes" ]]; then
    dry_run_db_context
    note '[dry-run] supabase db dump --db-url <OLD_DB_URL:redacted> -f roles.sql --role-only'
    note '[dry-run] supabase db dump --db-url <OLD_DB_URL:redacted> -f schema.sql'
    note '[dry-run] supabase db dump --db-url <OLD_DB_URL:redacted> -f data.sql --use-copy --data-only -x storage.buckets_vectors -x storage.vector_indexes'
    note '[dry-run] supabase db dump --db-url <OLD_DB_URL:redacted> -f history_schema.sql --schema supabase_migrations'
    note '[dry-run] supabase db dump --db-url <OLD_DB_URL:redacted> -f history_data.sql --use-copy --data-only --schema supabase_migrations'
    note '[dry-run] read-only cron inventory/export and exact source row counts; generate SHA-256 manifest'
    return
  fi
  init_run_dir
  [[ -f "$RUN_DIR/preflight.ok" ]] || die "run preflight with this run id before dump"
  grep -qx "source=$SOURCE_REF" "$RUN_DIR/preflight.ok" || die "preflight source does not match"
  grep -qx "target=$TARGET_REF" "$RUN_DIR/preflight.ok" || die "preflight target does not match"

  supabase_dump dump-roles "$ARTIFACT_DIR/roles.sql" --role-only
  supabase_dump dump-schema "$ARTIFACT_DIR/schema.sql"
  supabase_dump dump-data "$ARTIFACT_DIR/data.sql" --use-copy --data-only -x storage.buckets_vectors -x storage.vector_indexes
  supabase_dump dump-history-schema "$ARTIFACT_DIR/history_schema.sql" --schema supabase_migrations
  supabase_dump dump-history-data "$ARTIFACT_DIR/history_data.sql" --use-copy --data-only --schema supabase_migrations

  PGDATABASE="$OLD_DB_URL" PGOPTIONS='-c default_transaction_read_only=on' \
    "$PSQL_BIN" -X --quiet --set ON_ERROR_STOP=1 --file "$SCRIPT_DIR/sql/cron-inventory.sql" >"$ARTIFACT_DIR/cron-inventory.tsv"
  printf '%s\n' '-- Generated from source cron.job. Run only after target verification succeeds.' >"$ARTIFACT_DIR/cron-enable.sql"
  PGDATABASE="$OLD_DB_URL" PGOPTIONS='-c default_transaction_read_only=on' \
    "$PSQL_BIN" -X --quiet --set ON_ERROR_STOP=1 --file "$SCRIPT_DIR/sql/cron-enable.sql" >>"$ARTIFACT_DIR/cron-enable.sql"
  PGDATABASE="$OLD_DB_URL" PGOPTIONS='-c default_transaction_read_only=on' \
    "$PSQL_BIN" -X --quiet --set ON_ERROR_STOP=1 --file "$SCRIPT_DIR/sql/row-counts.sql" >"$ARTIFACT_DIR/source-row-counts.tsv"
  chmod 600 "$ARTIFACT_DIR"/*

  generate_manifest
  phase_inspect
  note "Dump completed under .local/supabase-sync/$RUN_ID; credentials were not stored in artifacts."
}

phase_inspect() {
  init_run_dir
  if [[ "$DRY_RUN" == "yes" ]]; then
    note "[dry-run] verify SHA-256 manifest under .local/supabase-sync/$RUN_ID"
    note '[dry-run] reject missing/symlinked/changed artifacts, embedded cron activation, and unsafe database-level SQL'
    return
  fi
  local required
  for required in roles.sql schema.sql data.sql history_schema.sql history_data.sql cron-inventory.tsv cron-enable.sql source-row-counts.tsv source-counts.env; do
    [[ -s "$ARTIFACT_DIR/$required" ]] || die "required artifact is missing or empty: $required"
    [[ ! -L "$ARTIFACT_DIR/$required" ]] || die "artifact cannot be a symlink: $required"
  done
  verify_manifest

  if grep -Eiq '(^|[^[:alnum:]_])cron\.(job|job_run_details|schedule|schedule_in_database|alter_job)([^[:alnum:]_]|$)' \
    "$ARTIFACT_DIR/roles.sql" "$ARTIFACT_DIR/schema.sql" "$ARTIFACT_DIR/data.sql" \
    "$ARTIFACT_DIR/history_schema.sql" "$ARTIFACT_DIR/history_data.sql"; then
    die "base restore artifacts contain cron activation; cron must remain separated"
  fi
  if grep -Eiq '(^|[[:space:];])(CREATE|DROP)[[:space:]]+DATABASE|\\connect|default_transaction_read_only' \
    "$ARTIFACT_DIR"/*.sql; then
    die "artifacts contain forbidden database-level or connection-changing SQL"
  fi
  if grep -Evq '^(--.*|[[:space:]]*|SELECT cron\.(schedule|alter_job)\(.*\);)$' "$ARTIFACT_DIR/cron-enable.sql"; then
    die "cron activation artifact contains an unexpected statement"
  fi
  write_manifest_marker "$RUN_DIR/inspected.ok"
  note "Artifact inspection and checksum verification passed."
}

restore_base() {
  local label="$1"
  run_psql_logged "$label" "$NEW_DB_URL" \
    --single-transaction \
    --variable ON_ERROR_STOP=1 \
    --file "$ARTIFACT_DIR/roles.sql" \
    --file "$ARTIFACT_DIR/schema.sql" \
    --command 'SET session_replication_role = replica' \
    --file "$ARTIFACT_DIR/data.sql" \
    --command 'SET session_replication_role = origin' \
    --file "$ARTIFACT_DIR/history_schema.sql" \
    --file "$ARTIFACT_DIR/history_data.sql"
}

run_verify_hook() {
  [[ -x "$VERIFY_HOOK" && ! -L "$VERIFY_HOOK" ]] || die "verification hook must be an executable, non-symlink file"
  local status
  set +e
  VERIFY_DB_URL="$NEW_DB_URL" \
  VERIFY_SOURCE_DB_URL="$OLD_DB_URL" \
  VERIFY_TARGET_REF="$TARGET_REF" \
  VERIFY_RUN_DIR="$RUN_DIR" \
  VERIFY_SOURCE_REF="$SOURCE_REF" \
  VERIFY_EVIDENCE_FILE="$RUN_DIR/cutover-gate/$TARGET_REF/comparison.json" \
    "$VERIFY_HOOK" 2>&1 | redact_stream | tee -a "$LOG_DIR/verify-${TARGET_REF}.log"
  status=${PIPESTATUS[0]}
  set -e
  ((status == 0)) || die "verification hook failed; cron remains inactive"
}

validate_strict_evidence() {
  local evidence="$RUN_DIR/cutover-gate/$TARGET_REF/comparison.json"
  [[ -f "$evidence" && ! -L "$evidence" ]] || die "strict hook did not produce cutover comparator evidence"
  command -v "$NODE_BIN" >/dev/null 2>&1 || die "node is required to validate strict cutover evidence"
  "$NODE_BIN" "$SCRIPT_DIR/validate-cutover-evidence.mjs" "$evidence" "$TARGET_REF" ||
    die "strict cutover evidence is invalid or launch-blocking"
}

phase_restore_rehearsal() {
  validate_db_urls
  [[ "$TARGET_REF" == "$REHEARSAL_TARGET_REF" ]] || die "restore-rehearsal only permits $REHEARSAL_TARGET_REF"
  if [[ "$DRY_RUN" == "yes" ]]; then
    dry_run_db_context
    note '[dry-run] verify manifest and inspected marker'
    note '[dry-run] PGDATABASE=<NEW_DB_URL:redacted> psql --single-transaction --variable ON_ERROR_STOP=1 roles/schema/replica/data/origin/history'
    note '[dry-run] cron-enable.sql is not executed during rehearsal'
    return
  fi
  init_run_dir
  verify_manifest
  require_marker_for_manifest "$RUN_DIR/inspected.ok"
  assert_target_empty
  restore_base restore-rehearsal
  write_manifest_marker "$RUN_DIR/restored-${REHEARSAL_TARGET_REF}.ok"
  note "Rehearsal restore completed with cron inactive. Run verify-hook next."
}

phase_verify_hook() {
  validate_db_urls
  [[ "$TARGET_REF" == "$REHEARSAL_TARGET_REF" ]] || die "standalone verify-hook is for the rehearsal target"
  if [[ "$DRY_RUN" == "yes" ]]; then
    dry_run_db_context
    note '[dry-run] VERIFY_DB_URL=<NEW_DB_URL:redacted> VERIFY_TARGET_REF=<rehearsal> <verification-hook>'
    return
  fi
  init_run_dir
  verify_manifest
  require_marker_for_manifest "$RUN_DIR/restored-${REHEARSAL_TARGET_REF}.ok"
  run_verify_hook
  if is_default_verify_hook; then
    write_manifest_marker "$RUN_DIR/verified-row-count-${REHEARSAL_TARGET_REF}.ok"
    note "Row-count verification passed for rehearsal; this does not authorize final cutover."
  else
    validate_strict_evidence
    write_manifest_marker "$RUN_DIR/verified-strict-${REHEARSAL_TARGET_REF}.ok"
    note "Strict rehearsal verification passed for the exact artifact manifest."
  fi
}

phase_final_restore() {
  validate_db_urls
  [[ "$TARGET_REF" == "$FINAL_TARGET_REF" ]] || die "final-restore only permits $FINAL_TARGET_REF"
  if [[ "$DRY_RUN" == "yes" ]]; then
    dry_run_db_context
    note "[dry-run] require MAINTENANCE_MODE_CONFIRMED=yes and CONFIRM_TARGET_REF=$FINAL_TARGET_REF"
    note '[dry-run] require strict exact-manifest rehearsal verification and manual-config parity markers'
    note '[dry-run] if source storage.objects > 0, require a verified Storage-byte migration marker'
    note '[dry-run] PGDATABASE=<NEW_DB_URL:redacted> psql --single-transaction --variable ON_ERROR_STOP=1 roles/schema/replica/data/origin/history'
    note '[dry-run] run verification hook; only on success execute cron-enable.sql in a separate transaction'
    return
  fi
  [[ "${MAINTENANCE_MODE_CONFIRMED:-}" == yes ]] || die "final restore requires MAINTENANCE_MODE_CONFIRMED=yes"
  [[ "${CONFIRM_TARGET_REF:-}" == "$FINAL_TARGET_REF" ]] || die "final restore requires CONFIRM_TARGET_REF=$FINAL_TARGET_REF"
  init_run_dir
  verify_manifest
  require_marker_for_manifest "$RUN_DIR/inspected.ok"
  is_default_verify_hook && die "default row-count verification cannot authorize final restore; use a non-default strict hook"
  require_marker_for_manifest "$RUN_DIR/verified-strict-${REHEARSAL_TARGET_REF}.ok"
  require_manual_config_marker
  assert_source_counts_unchanged
  assert_source_cron_unchanged
  require_storage_byte_marker "$SOURCE_STORAGE_OBJECT_COUNT" "$FINAL_TARGET_REF"
  assert_target_empty
  restore_base restore-final
  run_verify_hook
  validate_strict_evidence
  write_manifest_marker "$RUN_DIR/verified-${FINAL_TARGET_REF}.ok"
  run_psql_logged activate-cron "$NEW_DB_URL" \
    --single-transaction --variable ON_ERROR_STOP=1 --file "$ARTIFACT_DIR/cron-enable.sql"
  write_manifest_marker "$RUN_DIR/final-restore-complete.ok"
  note "Final restore, verification, and post-verification cron activation completed."
}

parse_args "$@"
validate_run_id

case "$PHASE" in
  prerequisites) phase_prerequisites ;;
  preflight) phase_preflight ;;
  dump) phase_dump ;;
  inspect) phase_inspect ;;
  restore-rehearsal) phase_restore_rehearsal ;;
  verify-hook) phase_verify_hook ;;
  final-restore) phase_final_restore ;;
esac
