#!/bin/sh
set -eu

if [ "${V73_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V73_CONFIRM_DISPOSABLE_DB=YES for a disposable database." >&2
  exit 2
fi
if [ -z "${DATABASE_URL:-}" ] || [ -z "${PGPASSWORD:-}" ]; then
  echo "DATABASE_URL and PGPASSWORD are required." >&2
  exit 2
fi
case "$DATABASE_URL" in postgresql://*|postgres://*) ;; *)
  echo "DATABASE_URL must be a PostgreSQL URL." >&2; exit 2;;
esac

export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=10000"
owner="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
prefix="${owner%%-*}"
fixture_name="V73 booking lifecycle concurrency"
fixture_slug="v73-booking-race-$prefix"
owner_email="v73-booking-race-$prefix@example.test"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/frenly-v73-booking.XXXXXX")"
first_pid=""; second_pid=""; holder_pid=""; business=""

cleanup() {
  status="$1"
  trap - EXIT HUP INT TERM
  set +e
  for pid in "$first_pid" "$second_pid" "$holder_pid"; do
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "$first_pid" "$second_pid" "$holder_pid"; do
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  done
  if [ -n "$business" ]; then
    psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
      -v business="$business" -v owner="$owner" <<'SQL' >/dev/null 2>&1 || true
delete from public.businesses where id=:'business';
delete from auth.users where id=:'owner';
SQL
  fi
  rm -rf "$work_dir"
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' HUP INT TERM

fixture="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v owner="$owner" -v owner_email="$owner_email" \
  -v fixture_name="$fixture_name" -v fixture_slug="$fixture_slug" <<'SQL'
insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,
  email_confirmed_at,created_at,updated_at
) values (
  '00000000-0000-0000-0000-000000000000',:'owner',
  'authenticated','authenticated',:'owner_email','',now(),now(),now()
);
insert into public.businesses(name,slug,industry,enabled_modules)
values (
  :'fixture_name',:'fixture_slug','test',
  array['bookings','appointments','clients','services','branches']
) returning id \gset
insert into public.staff(
  business_id,user_id,role,full_name,active,modules,module_perms
) values (
  :'id',:'owner','owner','V73 Race Owner',true,null,null
) returning id as staff \gset
insert into public.branches(business_id,name,active,is_default)
values (:'id','V73 Race Branch',true,true) returning id as branch \gset
select (
  date_trunc('day',clock_timestamp() at time zone 'Asia/Singapore')
  + interval '7 days 10 hours'
) at time zone 'Asia/Singapore' as starts \gset
select extract(dow from :'starts'::timestamptz at time zone 'Asia/Singapore')::smallint
  as weekday \gset
insert into public.branch_hours(business_id,branch_id,weekday,opens_at,closes_at)
values(:'id',:'branch',:'weekday','09:00','18:00');
insert into public.staff_branches(business_id,staff_id,branch_id)
values(:'id',:'staff',:'branch');
insert into public.staff_hours(business_id,staff_id,weekday,starts_at,ends_at)
values(:'id',:'staff',:'weekday','09:00','18:00');
insert into public.services(business_id,name,price_cents,duration_min,active)
values(:'id','V73 Race Service',2500,30,true) returning id as service \gset
insert into public.staff_services(business_id,staff_id,service_id)
values(:'id',:'staff',:'service');
insert into public.booking_requests(
  business_id,name,phone,service_id,party_size,preferred_at,status
) values (
  :'id','V73 same confirm','+6581000073',:'service',1,:'starts','new'
) returning id as same_request \gset
insert into public.booking_requests(
  business_id,name,phone,service_id,party_size,preferred_at,status
) values (
  :'id','V73 confirm decline','+6582000073',:'service',1,
  :'starts'::timestamptz+interval '1 hour','new'
) returning id as opposite_request \gset
select :'id',:'branch',:'same_request',:'opposite_request',
       hashtextextended(:'id'||':v73-race',0);
SQL
)"
IFS='|' read -r business branch same_request opposite_request barrier <<EOF
$fixture
EOF

run_decision() {
  request="$1"; decision="$2"; output="$3"
  psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v barrier="$barrier" -v owner="$owner" -v business="$business" \
    -v branch="$branch" -v request="$request" -v decision="$decision" >"$output" 2>&1 <<'SQL'
select pg_advisory_lock(:'barrier'::bigint);
select pg_advisory_unlock(:'barrier'::bigint);
set role authenticated;
select set_config('request.jwt.claim.sub',:'owner',false);
select public.staff_decide_booking_request_v73(
  :'business',:'request',:'decision',:'branch'
)::text;
SQL
}

# Release two confirm sessions together. The request lock must produce one
# applied transition and one replay, with one appointment and one v73 audit.
psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v barrier="$barrier" \
  >"$work_dir/barrier" 2>&1 <<'SQL' &
select pg_advisory_lock(:'barrier'::bigint);
select pg_sleep(2);
select pg_advisory_unlock(:'barrier'::bigint);
SQL
holder_pid=$!
run_decision "$same_request" confirm "$work_dir/same-a" & first_pid=$!
run_decision "$same_request" confirm "$work_dir/same-b" & second_pid=$!
wait "$holder_pid"; holder_pid=""
wait "$first_pid"; first_pid=""
wait "$second_pid"; second_pid=""

same_output="$(cat "$work_dir/same-a" "$work_dir/same-b")"
[ "$(printf '%s\n' "$same_output" | grep -c '\"outcome\": \"applied\"' || true)" -eq 1 ]
[ "$(printf '%s\n' "$same_output" | grep -c '\"outcome\": \"replayed\"' || true)" -eq 1 ]
same_proof="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v business="$business" -v request="$same_request" <<'SQL'
select
  (select count(*) from public.booking_requests request
    join public.appointments appointment on appointment.id=request.appointment_id
   where request.business_id=:'business' and request.id=:'request'),
  (select count(*) from public.audit_log
   where business_id=:'business' and entity_id=:'request'
     and action='BOOKING_REQUEST_DECISION_V73');
SQL
)"
[ "$same_proof" = "1|1" ] || {
  echo "same-confirm invariant failed (appointment_count|audit_count=$same_proof)" >&2
  exit 1
}

# Force confirm to apply while holding the request lock, then let decline observe
# the terminal state. This proves opposite decisions cannot flip the winner.
psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
  -v owner="$owner" -v business="$business" -v branch="$branch" \
  -v request="$opposite_request" >"$work_dir/opposite-confirm" 2>&1 <<'SQL' &
begin;
set role authenticated;
select set_config('request.jwt.claim.sub',:'owner',false);
select public.staff_decide_booking_request_v73(
  :'business',:'request','confirm',:'branch'
)::text;
select pg_sleep(3);
commit;
SQL
first_pid=$!

attempt=0
while [ "$attempt" -lt 50 ]; do
  if grep -q '\"outcome\": \"applied\"' "$work_dir/opposite-confirm" 2>/dev/null; then break; fi
  attempt=$((attempt+1))
  sleep 0.1
done
run_decision "$opposite_request" decline "$work_dir/opposite-decline" &
second_pid=$!
wait "$first_pid"; first_pid=""
wait "$second_pid"; second_pid=""

grep -q '\"outcome\": \"applied\"' "$work_dir/opposite-confirm"
grep -q '\"outcome\": \"terminal_conflict\"' "$work_dir/opposite-decline"
opposite_proof="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v business="$business" -v request="$opposite_request" <<'SQL'
select
  (select status from public.booking_requests
   where business_id=:'business' and id=:'request'),
  (select count(*) from public.booking_requests request
    join public.appointments appointment on appointment.id=request.appointment_id
   where request.business_id=:'business' and request.id=:'request'),
  (select count(*) from public.audit_log
   where business_id=:'business' and entity_id=:'request'
     and action='BOOKING_REQUEST_DECISION_V73');
SQL
)"
[ "$opposite_proof" = "confirmed|1|1" ] || {
  echo "confirm/decline invariant failed (status|appointment_count|audit_count=$opposite_proof)" >&2
  exit 1
}

echo "v73 two-session lifecycle concurrency: PASS"
