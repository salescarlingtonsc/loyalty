#!/bin/sh
set -eu

if [ "${V47_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V47_CONFIRM_DISPOSABLE_DB=YES for a disposable database." >&2
  exit 2
fi
if [ -z "${DATABASE_URL:-}" ] || [ -z "${PGPASSWORD:-}" ]; then
  echo "DATABASE_URL and PGPASSWORD are required." >&2
  exit 2
fi
case "$DATABASE_URL" in postgresql://*|postgres://*) ;; *)
  echo "DATABASE_URL must be a PostgreSQL URL." >&2; exit 2;;
esac
url_authority="${DATABASE_URL#*://}"; url_authority="${url_authority%%/*}"
case "$url_authority" in *@*)
  url_userinfo="${url_authority%@*}"
  case "$url_userinfo" in *:*|*%3[Aa]*)
    echo "DATABASE_URL must not contain password material; use PGPASSWORD." >&2; exit 2;;
  esac;;
esac

export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=10000"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
owner="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
owner_prefix="${owner%%-*}"
fixture_name="V47 booking concurrency"
fixture_slug="v47-booking-concurrency-$owner_prefix"
owner_email="v47-booking-race-$owner_prefix@example.test"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/frenly-v47-booking.XXXXXX")"
holder_pid=""; first_pid=""; second_pid=""; biz=""; result_message=""

cleanup(){
  original_status="$1"
  trap - EXIT HUP INT TERM
  set +e
  for child_pid in "$holder_pid" "$first_pid" "$second_pid"; do
    if [ -n "$child_pid" ]; then kill -TERM "$child_pid" 2>/dev/null || true; fi
  done
  for child_pid in "$holder_pid" "$first_pid" "$second_pid"; do
    if [ -n "$child_pid" ]; then wait "$child_pid" 2>/dev/null || true; fi
  done
  cleanup_status=0
  psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v cleanup_confirm="YES-SCOPED-SYNTHETIC-CLEANUP" \
    -v cleanup_business="$biz" -v cleanup_business_name="$fixture_name" \
    -v cleanup_business_slug="$fixture_slug" \
    -v cleanup_auth_user_1="$owner" -v cleanup_auth_email_1="$owner_email" \
    -v cleanup_auth_user_2="" -v cleanup_auth_email_2="" \
    -f "$script_dir/cleanup_synthetic_fixture.sql" >"$work_dir/cleanup" 2>&1 || cleanup_status=$?
  if [ "$cleanup_status" -ne 0 ]; then
    echo "v47 synthetic fixture cleanup failed; first sanitized lines:" >&2
    sed -n '1,8p' "$work_dir/cleanup" | cut -c1-240 >&2
  fi
  rm -f "$work_dir/holder" "$work_dir/first" "$work_dir/second" \
    "$work_dir/quick-holder" "$work_dir/quick-first" "$work_dir/quick-second" "$work_dir/cleanup"
  rmdir "$work_dir" 2>/dev/null || true
  if [ "$cleanup_status" -ne 0 ]; then exit 1; fi
  if [ "$original_status" -eq 0 ] && [ -n "$result_message" ]; then echo "$result_message"; fi
  exit "$original_status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' HUP INT TERM

fixture_output="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v owner="$owner" -v owner_email="$owner_email" \
  -v fixture_name="$fixture_name" -v fixture_slug="$fixture_slug" <<'SQL'
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000',:'owner','authenticated','authenticated',
  :'owner_email','',now(),now(),now());
set role authenticated;
select set_config('request.jwt.claim.sub',:'owner',false);
select (public.create_business(:'fixture_name',:'fixture_slug','test',
  array['dashboard','clients','services','branches','appointments','sales','loyalty'])::jsonb->>'id')::uuid as biz \gset
reset role;
select id as branch from public.branches where business_id=:'biz' and is_default limit 1 \gset
select id as staff from public.staff where business_id=:'biz' and user_id=:'owner' limit 1 \gset
select (date_trunc('day',clock_timestamp() at time zone 'Asia/Singapore')
  + interval '7 days 10 hours') at time zone 'Asia/Singapore' as starts_at \gset
select extract(dow from (:'starts_at'::timestamptz at time zone 'Asia/Singapore'))::smallint as weekday \gset
insert into public.branch_hours(business_id,branch_id,weekday,opens_at,closes_at)
values(:'biz',:'branch',:'weekday','09:00','18:00');
insert into public.staff_branches(business_id,staff_id,branch_id)
values(:'biz',:'staff',:'branch') on conflict do nothing;
insert into public.staff_hours(business_id,staff_id,weekday,starts_at,ends_at)
values(:'biz',:'staff',:'weekday','09:00','18:00');
insert into public.services(business_id,name,price_cents,duration_min,active)
values(:'biz','V47 race service',5000,60,true) returning id as service \gset
insert into public.staff_services(business_id,staff_id,service_id)
values(:'biz',:'staff',:'service');
insert into public.clients(business_id,full_name,phone)
values(:'biz','V47 race customer','+65 8111 0047') returning id as client \gset
select :'biz',:'branch',:'staff',:'service',:'client',:'starts_at',
       hashtextextended(:'biz'||':v47-booking-race',0),
       hashtextextended(:'biz'||':v47-quick-earn-race',0);
SQL
)"
fixture="$(printf '%s\n' "$fixture_output" | tail -n 1)"
IFS='|' read -r biz branch staff service client starts_at barrier quick_barrier <<EOF
$fixture
EOF

run_booking(){
  worker_name="$1"; idem_key="$2"
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v worker_name="$worker_name" -v barrier="$barrier" -v owner="$owner" \
    -v biz="$biz" -v branch="$branch" -v staff="$staff" -v service="$service" \
    -v client="$client" -v starts_at="$starts_at" -v idem_key="$idem_key" <<'SQL'
set application_name=:'worker_name';
select pg_advisory_lock(:'barrier'::bigint); select pg_advisory_unlock(:'barrier'::bigint);
set role authenticated; select set_config('request.jwt.claim.sub',:'owner',false);
select public.book_appointment_smart_v47(
  :'biz',:'client',:'branch',:'service',:'starts_at',60,:'staff',
  'manual','same-staff race',:'idem_key'
)::text;
SQL
}

holder_name="v47-booking-holder-$owner_prefix"
first_name="v47-booking-first-$owner_prefix"
second_name="v47-booking-second-$owner_prefix"
psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v barrier="$barrier" \
  -v holder_name="$holder_name" >"$work_dir/holder" 2>&1 <<'SQL' &
set application_name=:'holder_name';
select pg_advisory_lock(:'barrier'::bigint); select pg_sleep(3); select pg_advisory_unlock(:'barrier'::bigint);
SQL
holder_pid=$!

attempts=0
while [ "$attempts" -lt 50 ]; do
  holder_ready="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v holder_name="$holder_name" <<'SQL'
select count(*) from pg_stat_activity
 where application_name=:'holder_name' and wait_event='PgSleep';
SQL
)"
  if [ "$holder_ready" = "1" ]; then break; fi
  attempts=$((attempts+1)); sleep 0.1
done
if [ "${holder_ready:-0}" != "1" ]; then echo "v47 concurrency barrier did not start" >&2; exit 1; fi

run_booking "$first_name" "v47-race-first" >"$work_dir/first" 2>&1 & first_pid=$!
run_booking "$second_name" "v47-race-second" >"$work_dir/second" 2>&1 & second_pid=$!
wait "$holder_pid"; holder_pid=""
wait "$first_pid"; first_pid=""
wait "$second_pid"; second_pid=""

combined="$(cat "$work_dir/first" "$work_dir/second")"
booked_count="$(printf '%s\n' "$combined" | grep -c '"status": "booked"' || true)"
conflict_count="$(printf '%s\n' "$combined" | grep -c '"status": "conflict"' || true)"
proof="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v biz="$biz" -v staff="$staff" -v starts_at="$starts_at" <<'SQL'
select
  (select count(*) from public.appointments
    where business_id=:'biz' and staff_id=:'staff' and starts_at=:'starts_at' and status='booked'),
  (select count(*) from app.appointment_booking_operations where business_id=:'biz');
SQL
)"
if [ "$booked_count" -ne 1 ] || [ "$conflict_count" -ne 1 ] || [ "$proof" != "1|1" ]; then
  echo "v47 same-staff race invariant failed: booked=$booked_count conflict=$conflict_count proof=$proof" >&2
  exit 1
fi

run_quick_earn(){
  worker_name="$1"
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v worker_name="$worker_name" -v barrier="$quick_barrier" -v owner="$owner" \
    -v biz="$biz" -v branch="$branch" -v staff="$staff" <<'SQL'
set application_name=:'worker_name';
select pg_advisory_lock(:'barrier'::bigint); select pg_advisory_unlock(:'barrier'::bigint);
set role authenticated; select set_config('request.jwt.claim.sub',:'owner',false);
select public.record_sale_by_phone(
  :'biz','+65 8111 0047',2500,'quick_sale','v47 concurrent Quick earn',:'staff',
  'v47-quick-earn-race',:'branch','paynow'
)::text;
SQL
}

holder_name="v47-quick-holder-$owner_prefix"
first_name="v47-quick-first-$owner_prefix"
second_name="v47-quick-second-$owner_prefix"
psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v barrier="$quick_barrier" \
  -v holder_name="$holder_name" >"$work_dir/quick-holder" 2>&1 <<'SQL' &
set application_name=:'holder_name';
select pg_advisory_lock(:'barrier'::bigint); select pg_sleep(3); select pg_advisory_unlock(:'barrier'::bigint);
SQL
holder_pid=$!

attempts=0
holder_ready=0
while [ "$attempts" -lt 50 ]; do
  holder_ready="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v holder_name="$holder_name" <<'SQL'
select count(*) from pg_stat_activity
 where application_name=:'holder_name' and wait_event='PgSleep';
SQL
)"
  if [ "$holder_ready" = "1" ]; then break; fi
  attempts=$((attempts+1)); sleep 0.1
done
if [ "$holder_ready" != "1" ]; then echo "v47 Quick earn concurrency barrier did not start" >&2; exit 1; fi

run_quick_earn "$first_name" >"$work_dir/quick-first" 2>&1 & first_pid=$!
run_quick_earn "$second_name" >"$work_dir/quick-second" 2>&1 & second_pid=$!
wait "$holder_pid"; holder_pid=""
wait "$first_pid"; first_pid=""
wait "$second_pid"; second_pid=""

quick_combined="$(cat "$work_dir/quick-first" "$work_dir/quick-second")"
quick_ok_count="$(printf '%s\n' "$quick_combined" | grep -c '"status" : "ok"\|"status": "ok"' || true)"
quick_replay_count="$(printf '%s\n' "$quick_combined" | grep -c '"status" : "duplicate_ignored"\|"status": "duplicate_ignored"' || true)"
quick_proof="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v biz="$biz" -v branch="$branch" -v staff="$staff" -v client="$client" <<'SQL'
select
  (select count(*) from public.sales
    where business_id=:'biz' and branch_id=:'branch' and staff_id=:'staff'
      and client_id=:'client' and kind='quick_sale' and amount_cents=2500),
  (select count(*) from public.payments
    where business_id=:'biz' and branch_id=:'branch' and staff_id=:'staff'
      and client_id=:'client' and method='paynow' and kind='payment' and amount_cents=2500),
  (select count(*) from public.financial_operations
    where business_id=:'biz' and operation_type='quick_sale'
      and idempotency_key='v47-quick-earn-race' and status='completed');
SQL
)"
if [ "$quick_ok_count" -ne 1 ] || [ "$quick_replay_count" -ne 1 ] || [ "$quick_proof" != "1|1|1" ]; then
  echo "v47 Quick earn race invariant failed: ok=$quick_ok_count replay=$quick_replay_count proof=$quick_proof" >&2
  exit 1
fi
result_message="v47 concurrency: PASS (booking booked=1 conflict=1 rows=$proof; Quick earn ok=1 replay=1 sale|payment|operation=$quick_proof)"
