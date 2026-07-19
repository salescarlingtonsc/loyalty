#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
CUTOVER_DIR="$REPO_ROOT/db/cutover"

: "${VERIFY_SOURCE_DB_URL:?VERIFY_SOURCE_DB_URL is required}"
: "${VERIFY_DB_URL:?VERIFY_DB_URL is required}"
: "${VERIFY_TARGET_REF:?VERIFY_TARGET_REF is required}"
: "${VERIFY_RUN_DIR:?VERIFY_RUN_DIR is required}"
: "${VERIFY_EVIDENCE_FILE:?VERIFY_EVIDENCE_FILE is required}"

PSQL_BIN="${PSQL_BIN:-psql}"
NODE_BIN="${NODE_BIN:-node}"
SOURCE_REF="kyzovonwnscrzmkvocid"

case "$VERIFY_TARGET_REF" in
  wtegnefsgnyxhflzizcu) target_scope=rehearsal ;;
  gadpooereceldfpfxsod) target_scope=target ;;
  *) printf 'Unsupported strict-verification target ref.\n' >&2; exit 1 ;;
esac

for file in \
  source_inventory.sql source_reconciliation.sql \
  "${target_scope}_inventory.sql" "${target_scope}_reconciliation.sql" \
  compare-cutover-inventories.mjs; do
  [[ -f "$CUTOVER_DIR/$file" && ! -L "$CUTOVER_DIR/$file" ]] || {
    printf 'Required cutover comparator artifact is missing or unsafe: %s\n' "$file" >&2
    exit 1
  }
done
command -v "$PSQL_BIN" >/dev/null 2>&1 || { printf 'psql is required.\n' >&2; exit 1; }
command -v "$NODE_BIN" >/dev/null 2>&1 || { printf 'node is required.\n' >&2; exit 1; }
node_major=$($NODE_BIN --version | sed 's/^v//' | cut -d. -f1)
[[ "$node_major" =~ ^[0-9]+$ && "$node_major" -ge 18 ]] || {
  printf 'Node.js 18 or newer is required.\n' >&2
  exit 1
}

output_dir="$VERIFY_RUN_DIR/cutover-gate/$VERIFY_TARGET_REF"
[[ "$VERIFY_EVIDENCE_FILE" == "$output_dir/comparison.json" ]] || {
  printf 'Verification evidence path does not match the protected run directory.\n' >&2
  exit 1
}
umask 077
mkdir -p "$output_dir"
chmod 700 "$output_dir"

PGDATABASE="$VERIFY_SOURCE_DB_URL" PGOPTIONS='-c default_transaction_read_only=on' \
  "$PSQL_BIN" -X --quiet --set ON_ERROR_STOP=1 \
  --file "$CUTOVER_DIR/source_inventory.sql" >"$output_dir/source-inventory.json"
PGDATABASE="$VERIFY_SOURCE_DB_URL" PGOPTIONS='-c default_transaction_read_only=on' \
  "$PSQL_BIN" -X --quiet --set ON_ERROR_STOP=1 \
  --file "$CUTOVER_DIR/source_reconciliation.sql" >"$output_dir/source-reconciliation.json"
PGDATABASE="$VERIFY_DB_URL" PGOPTIONS='-c default_transaction_read_only=on' \
  "$PSQL_BIN" -X --quiet --set ON_ERROR_STOP=1 \
  --file "$CUTOVER_DIR/${target_scope}_inventory.sql" >"$output_dir/target-inventory.json"
PGDATABASE="$VERIFY_DB_URL" PGOPTIONS='-c default_transaction_read_only=on' \
  "$PSQL_BIN" -X --quiet --set ON_ERROR_STOP=1 \
  --file "$CUTOVER_DIR/${target_scope}_reconciliation.sql" >"$output_dir/target-reconciliation.json"

"$NODE_BIN" "$SCRIPT_DIR/combine-cutover-output.mjs" \
  "$output_dir/source-inventory.json" "$output_dir/source-reconciliation.json" \
  "$output_dir/source-cutover.json" "$SOURCE_REF" source
"$NODE_BIN" "$SCRIPT_DIR/combine-cutover-output.mjs" \
  "$output_dir/target-inventory.json" "$output_dir/target-reconciliation.json" \
  "$output_dir/target-cutover.json" "$VERIFY_TARGET_REF" "$target_scope"
"$NODE_BIN" "$SCRIPT_DIR/prepare-deferred-cron-comparison.mjs" \
  "$output_dir/source-cutover.json" "$output_dir/target-cutover.json" \
  "$output_dir/target-cutover-for-compare.json" "$output_dir/deferred-cron.json" \
  "$VERIFY_TARGET_REF"
"$NODE_BIN" "$CUTOVER_DIR/compare-cutover-inventories.mjs" \
  "$output_dir/source-cutover.json" "$output_dir/target-cutover-for-compare.json" \
  --out "$VERIFY_EVIDENCE_FILE"
"$NODE_BIN" "$SCRIPT_DIR/annotate-cutover-evidence.mjs" \
  "$VERIFY_EVIDENCE_FILE" "$output_dir/deferred-cron.json" "$VERIFY_TARGET_REF"

chmod 600 "$output_dir"/*
printf 'Strict cutover inventory and reconciliation comparison passed for %s.\n' "$VERIFY_TARGET_REF"
