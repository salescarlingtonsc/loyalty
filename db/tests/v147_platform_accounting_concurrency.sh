#!/usr/bin/env bash
set -euo pipefail

: "${V147_TEST_DATABASE_URL:?Set V147_TEST_DATABASE_URL to a disposable V147 PostgreSQL database}"

database_name="$(psql "$V147_TEST_DATABASE_URL" -Atc 'select current_database()')"
case "$database_name" in
  v147_*) ;;
  *) printf 'Refusing concurrency writes outside a v147_* disposable database: %s\n' "$database_name" >&2; exit 2 ;;
esac

run_dir="$(mktemp -d /tmp/v147-accounting-concurrency.XXXXXX)"
trap 'rm -rf -- "$run_dir"' EXIT

actor='14700000-0000-4000-8000-000000009999'
invoice_id="$(psql "$V147_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -At <<'SQL' | tail -1
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','14700000-0000-4000-8000-000000009999','authenticated','authenticated','v147-concurrency@example.test','',now(),now(),now());
insert into public.super_admins(user_id,email,note)
values('14700000-0000-4000-8000-000000009999','v147-concurrency@example.test','disposable two-session fixture');
set role authenticated;
select set_config('request.jwt.claim.sub','14700000-0000-4000-8000-000000009999',false);
select set_config('request.jwt.claims','{"sub":"14700000-0000-4000-8000-000000009999","role":"authenticated"}',false);
select public.platform_set_accounting_policy_v147('2026-01-01','Peekaa Concurrency Pte. Ltd.','202600009C','9 Synthetic Street, Singapore','not_registered',null,0,12,31,'CON','Synthetic concurrency evidence','14700000-0000-4000-8000-000000009900');
select public.platform_create_invoice_v147('2026-08-04','2026-08-18','NON-SUBSCRIPTION-CONCURRENCY-20260804','{"legal_name":"Concurrent Customer Pte. Ltd.","registration_number":"202688889K","address":"8 Synthetic Road, Singapore"}','[{"description":"Concurrent service","quantity":1,"unit_amount_cents":25000}]',0,'14700000-0000-4000-8000-000000009901')#>>'{document,id}';
SQL
)"

receipt_sql() {
  local reference="$1" operation_key="$2" application_name="$3" hold_seconds="$4"
  printf '%s' "begin; set local application_name='$application_name'; set local role authenticated; select set_config('request.jwt.claim.sub','$actor',true); select set_config('request.jwt.claims','{\"sub\":\"$actor\",\"role\":\"authenticated\"}',true); select public.platform_record_invoice_receipt_v147('$invoice_id','2026-08-05',20000,'$reference','$operation_key'); select pg_sleep($hold_seconds); commit;"
}

set +e
(psql "$V147_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -c "$(receipt_sql CONCURRENT-ONE 14700000-0000-4000-8000-000000009902 v147-receipt-one 2)" >"$run_dir/one.log" 2>&1; printf '%s' "$?" >"$run_dir/one.status") &
first_pid=$!
for _ in {1..40}; do
  [[ "$(psql "$V147_TEST_DATABASE_URL" -Atc "select count(*) from pg_stat_activity where application_name='v147-receipt-one' and wait_event='PgSleep'")" == '1' ]] && break
  sleep 0.05
done
[[ "$(psql "$V147_TEST_DATABASE_URL" -Atc "select count(*) from pg_stat_activity where application_name='v147-receipt-one' and wait_event='PgSleep'")" == '1' ]] || { printf 'First receipt never reached the deliberate post-lock hold\n' >&2; exit 1; }
(psql "$V147_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -c "$(receipt_sql CONCURRENT-TWO 14700000-0000-4000-8000-000000009903 v147-receipt-two 0)" >"$run_dir/two.log" 2>&1; printf '%s' "$?" >"$run_dir/two.status") &
second_pid=$!
for _ in {1..40}; do
  [[ "$(psql "$V147_TEST_DATABASE_URL" -Atc "select count(*) from pg_stat_activity where application_name='v147-receipt-two' and wait_event_type='Lock'")" == '1' ]] && break
  sleep 0.05
done
[[ "$(psql "$V147_TEST_DATABASE_URL" -Atc "select count(*) from pg_stat_activity where application_name='v147-receipt-two' and wait_event_type='Lock'")" == '1' ]] || { printf 'Second receipt did not block on the held invoice-chain lock\n' >&2; exit 1; }
wait "$first_pid"
wait "$second_pid"
set -e

first_status="$(<"$run_dir/one.status")"
second_status="$(<"$run_dir/two.status")"
if ! { [[ "$first_status" == '0' && "$second_status" != '0' ]] || [[ "$first_status" != '0' && "$second_status" == '0' ]]; }; then
  printf 'Expected one success and one PostgreSQL rejection, got %s %s\n' "$first_status" "$second_status" >&2
  exit 1
fi
grep -q 'payment exceeds the invoice balance or is invalid' "$run_dir/one.log" "$run_dir/two.log"

receipt_truth="$(psql "$V147_TEST_DATABASE_URL" -Atc "select count(*)||':'||coalesce(sum(total_cents),0) from public.platform_financial_documents_v147 where original_document='$invoice_id' and document_type='receipt'")"
[[ "$receipt_truth" == '1:20000' ]] || { printf 'Concurrent receipt truth was %s, expected 1:20000\n' "$receipt_truth" >&2; exit 1; }
printf 'V147 two-session receipt serialization passed: %s\n' "$receipt_truth"
