#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
: "${VERIFY_DB_URL:?VERIFY_DB_URL is required}"
: "${VERIFY_TARGET_REF:?VERIFY_TARGET_REF is required}"
: "${VERIFY_RUN_DIR:?VERIFY_RUN_DIR is required}"

PSQL_BIN="${PSQL_BIN:-psql}"
expected="$VERIFY_RUN_DIR/artifacts/source-row-counts.tsv"
actual="$VERIFY_RUN_DIR/target-${VERIFY_TARGET_REF}-row-counts.tsv"

[[ -s "$expected" ]] || { printf 'Expected source row counts are missing.\n' >&2; exit 1; }
PGDATABASE="$VERIFY_DB_URL" PGOPTIONS='-c default_transaction_read_only=on' \
  "$PSQL_BIN" -X --quiet --set ON_ERROR_STOP=1 \
  --file "$SCRIPT_DIR/sql/row-counts.sql" >"$actual"
chmod 600 "$actual"

if ! diff -u "$expected" "$actual"; then
  printf 'Source and target row counts differ.\n' >&2
  exit 1
fi

cron_jobs=$(PGDATABASE="$VERIFY_DB_URL" PGOPTIONS='-c default_transaction_read_only=on' \
  "$PSQL_BIN" -X -A -t --set ON_ERROR_STOP=1 \
  --command "select case when to_regclass('cron.job') is null then 0 else (select count(*) from cron.job) end")
cron_jobs="${cron_jobs//[[:space:]]/}"
[[ "$cron_jobs" == 0 ]] || { printf 'Cron jobs must remain inactive before verification completes.\n' >&2; exit 1; }

printf 'Exact row-count verification passed; cron is inactive.\n'
