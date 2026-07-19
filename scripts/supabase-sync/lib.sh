#!/usr/bin/env bash

SOURCE_REF="kyzovonwnscrzmkvocid"
FINAL_TARGET_REF="gadpooereceldfpfxsod"
REHEARSAL_TARGET_REF="wtegnefsgnyxhflzizcu"
MIN_SUPABASE_VERSION="2.81.3"
MIN_PSQL_MAJOR="17"

SYNC_ROOT="${REPO_ROOT}/.local/supabase-sync"
RUN_DIR="${SYNC_ROOT}/${RUN_ID}"
ARTIFACT_DIR="${RUN_DIR}/artifacts"
LOG_DIR="${RUN_DIR}/logs"
ATTESTATION_DIR="${RUN_DIR}/attestations"
MANIFEST_FILE="${RUN_DIR}/manifest.sha256"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*"
}

redact_text() {
  local value="$1" secret
  if [[ -n "${OLD_DB_URL:-}" ]]; then
    value="${value//${OLD_DB_URL}/<OLD_DB_URL:redacted>}"
    secret=$(password_from_url "$OLD_DB_URL")
    [[ -z "$secret" ]] || value="${value//${secret}/<OLD_DB_PASSWORD:redacted>}"
  fi
  if [[ -n "${NEW_DB_URL:-}" ]]; then
    value="${value//${NEW_DB_URL}/<NEW_DB_URL:redacted>}"
    secret=$(password_from_url "$NEW_DB_URL")
    [[ -z "$secret" ]] || value="${value//${secret}/<NEW_DB_PASSWORD:redacted>}"
  fi
  printf '%s\n' "$value"
}

password_from_url() {
  local authority userinfo
  authority="${1#*://}"
  userinfo="${authority%@*}"
  [[ "$userinfo" == *:* ]] || return 0
  printf '%s\n' "${userinfo#*:}"
}

redact_stream() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    redact_text "$line"
  done
}

validate_run_id() {
  [[ "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] ||
    die "run id must use 1-80 letters, digits, dots, underscores, or hyphens"
  [[ "$RUN_ID" != *..* ]] || die "run id cannot contain '..'"
}

validate_db_urls() {
  [[ -n "${OLD_DB_URL:-}" ]] || die "OLD_DB_URL must be set in the environment"
  [[ -n "${NEW_DB_URL:-}" ]] || die "NEW_DB_URL must be set in the environment"
  [[ "$OLD_DB_URL" =~ ^postgres(ql)?:// ]] || die "OLD_DB_URL must be a PostgreSQL URL"
  [[ "$NEW_DB_URL" =~ ^postgres(ql)?:// ]] || die "NEW_DB_URL must be a PostgreSQL URL"
  local old_ref new_ref
  old_ref=$(project_ref_from_url "$OLD_DB_URL") || die "OLD_DB_URL is not an official Supabase direct or Session Pooler URL"
  new_ref=$(project_ref_from_url "$NEW_DB_URL") || die "NEW_DB_URL is not an official Supabase direct or Session Pooler URL"
  [[ "$old_ref" == "$SOURCE_REF" ]] || die "OLD_DB_URL is not the approved source project"

  case "$new_ref" in
    "$FINAL_TARGET_REF"|"$REHEARSAL_TARGET_REF") TARGET_REF="$new_ref" ;;
    *) die "NEW_DB_URL is not an approved rehearsal or final target" ;;
  esac

  [[ "$OLD_DB_URL" != "$NEW_DB_URL" ]] || die "source and target URLs must differ"
  [[ "$TARGET_REF" != "$SOURCE_REF" ]] || die "source and target project refs must differ"
}

project_ref_from_url() {
  local url="$1" authority userinfo endpoint username hostport host ref
  authority="${url#*://}"
  [[ "$authority" == *@*/* ]] || return 1
  userinfo="${authority%@*}"
  [[ "$userinfo" == *:* ]] || return 1
  endpoint="${authority##*@}"
  username="${userinfo%%:*}"
  hostport="${endpoint%%/*}"
  host="${hostport%%:*}"

  if [[ "$username" =~ ^postgres\.([a-z0-9]{20})$ ]]; then
    ref="${BASH_REMATCH[1]}"
    if [[ "$host" =~ \.pooler\.supabase\.com$ ]]; then
      printf '%s\n' "$ref"
      return 0
    fi
  fi
  if [[ "$username" == postgres ]] &&
     [[ "$host" =~ ^db\.([a-z0-9]{20})\.supabase\.co$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

init_run_dir() {
  validate_run_id
  if [[ "$DRY_RUN" == "yes" ]]; then
    return
  fi
  umask 077
  mkdir -p "$ARTIFACT_DIR" "$LOG_DIR" "$ATTESTATION_DIR"
  chmod 700 "$RUN_DIR" "$ARTIFACT_DIR" "$LOG_DIR" "$ATTESTATION_DIR"
}

version_ge() {
  local left="$1" right="$2" i
  local -a a b
  IFS=. read -r -a a <<<"${left%%-*}"
  IFS=. read -r -a b <<<"${right%%-*}"
  for ((i = 0; i < 3; i++)); do
    ((10#${a[i]:-0} > 10#${b[i]:-0})) && return 0
    ((10#${a[i]:-0} < 10#${b[i]:-0})) && return 1
  done
  return 0
}

psql_client_version() {
  local output version
  output=$($PSQL_BIN --version 2>&1) || die "could not run psql --version"
  version=$(printf '%s\n' "$output" | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+([.][0-9]+)+$/) {
          print $i
          exit
        }
      }
    }
  ')
  [[ "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "could not parse psql version"
  printf '%s\n' "$version"
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

run_logged() {
  local label="$1"
  shift
  local log_file="${LOG_DIR}/${label}.log"
  local status
  if [[ "$DRY_RUN" == "yes" ]]; then
    die "internal error: run_logged called during dry-run"
  fi
  set +e
  "$@" 2>&1 | redact_stream | tee -a "$log_file"
  status=${PIPESTATUS[0]}
  set -e
  ((status == 0)) || die "$label failed; see $log_file"
}

run_psql_logged() {
  local label="$1" url="$2"
  shift 2
  local log_file="${LOG_DIR}/${label}.log"
  local status
  set +e
  PGDATABASE="$url" "$PSQL_BIN" -X "$@" 2>&1 | redact_stream | tee -a "$log_file"
  status=${PIPESTATUS[0]}
  set -e
  ((status == 0)) || die "$label failed; see $log_file"
}

psql_scalar() {
  local url="$1" sql="$2" output status
  set +e
  output=$(PGDATABASE="$url" PGOPTIONS='-c default_transaction_read_only=on' \
    "$PSQL_BIN" -X -A -t --set ON_ERROR_STOP=1 --command "$sql" 2>&1)
  status=$?
  set -e
  if ((status != 0)); then
    redact_text "$output" >&2
    die "read-only database preflight query failed"
  fi
  printf '%s' "$output" | tr -d '[:space:]'
}

generate_manifest() {
  local file relative
  : >"$MANIFEST_FILE"
  while IFS= read -r file; do
    relative="${file#${RUN_DIR}/}"
    printf '%s  %s\n' "$(sha256_file "$file")" "$relative" >>"$MANIFEST_FILE"
  done < <(find "$ARTIFACT_DIR" -type f -print | LC_ALL=C sort)
  chmod 600 "$MANIFEST_FILE"
}

verify_manifest() {
  local expected relative file actual count=0 listed actual_files
  [[ -f "$MANIFEST_FILE" && ! -L "$MANIFEST_FILE" ]] || die "manifest is missing or unsafe"
  while IFS=' ' read -r expected relative; do
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "manifest contains an invalid checksum"
    [[ "$relative" == artifacts/* && "$relative" != *..* ]] || die "manifest contains an unsafe path"
    file="${RUN_DIR}/${relative}"
    [[ -f "$file" && ! -L "$file" ]] || die "manifest artifact is missing or is a symlink: $relative"
    actual=$(sha256_file "$file")
    [[ "$actual" == "$expected" ]] || die "artifact checksum changed: $relative"
    ((count += 1))
  done <"$MANIFEST_FILE"
  ((count >= 7)) || die "manifest does not contain the complete artifact set"

  listed=$(awk '{print $2}' "$MANIFEST_FILE" | LC_ALL=C sort)
  actual_files=$(find "$ARTIFACT_DIR" -type f -print | sed "s#^${RUN_DIR}/##" | LC_ALL=C sort)
  [[ "$listed" == "$actual_files" ]] || die "manifest coverage does not exactly match the artifact directory"
}

manifest_identity() {
  sha256_file "$MANIFEST_FILE"
}

require_marker_for_manifest() {
  local marker="$1" identity
  [[ -f "$marker" ]] || die "required phase marker is missing: ${marker#${RUN_DIR}/}"
  identity=$(manifest_identity)
  [[ "$(<"$marker")" == "$identity" ]] || die "phase marker belongs to a different artifact manifest"
}

write_manifest_marker() {
  local marker="$1"
  manifest_identity >"$marker"
  chmod 600 "$marker"
}

marker_has_line() {
  local marker="$1" line="$2"
  grep -Fqx -- "$line" "$marker"
}

require_storage_byte_marker() {
  local object_count="$1" target_ref="$2"
  ((object_count > 0)) || return 0
  local marker="$ATTESTATION_DIR/storage-bytes-${target_ref}.verified"
  [[ -f "$marker" && ! -L "$marker" ]] ||
    die "source has $object_count Storage objects; verified byte-migration marker is required: ${marker#${REPO_ROOT}/}"
  marker_has_line "$marker" 'kind=storage-byte-migration-v1' || die "storage-byte marker has the wrong kind"
  marker_has_line "$marker" "source_ref=$SOURCE_REF" || die "storage-byte marker source ref does not match"
  marker_has_line "$marker" "target_ref=$target_ref" || die "storage-byte marker target ref does not match"
  marker_has_line "$marker" "source_storage_object_count=$object_count" || die "storage-byte marker object count does not match"
  marker_has_line "$marker" 'bytes_verified=yes' || die "storage-byte marker is not verified"
  grep -Eq '^evidence_sha256=[0-9a-fA-F]{64}$' "$marker" || die "storage-byte marker requires an evidence SHA-256"
}

require_manual_config_marker() {
  local marker="$ATTESTATION_DIR/manual-config-${FINAL_TARGET_REF}.verified"
  [[ -f "$marker" && ! -L "$marker" ]] ||
    die "final restore requires manual configuration parity marker: ${marker#${REPO_ROOT}/}"
  marker_has_line "$marker" 'kind=manual-config-parity-v1' || die "manual-config marker has the wrong kind"
  marker_has_line "$marker" "source_ref=$SOURCE_REF" || die "manual-config marker source ref does not match"
  marker_has_line "$marker" "target_ref=$FINAL_TARGET_REF" || die "manual-config marker target ref does not match"
  marker_has_line "$marker" "manifest_sha256=$(manifest_identity)" || die "manual-config marker belongs to a different manifest"
  local category
  for category in auth_smtp_captcha realtime extensions storage edge_functions secrets; do
    marker_has_line "$marker" "$category=verified" || die "manual-config marker is missing $category=verified"
  done
  grep -Eq '^verified_by=.+$' "$marker" || die "manual-config marker requires verified_by"
}
