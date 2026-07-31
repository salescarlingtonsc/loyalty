#!/bin/sh
# True two-session V120 block-vs-block and block-vs-appointment races.
# Run only against a disposable database with the canonical chain through V120.
set -eu

if [ "${V120_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V120_CONFIRM_DISPOSABLE_DB=YES." >&2
  exit 2
fi
if [ -z "${DATABASE_URL:-}" ] || [ -z "${PGPASSWORD:-}" ]; then
  echo "DATABASE_URL and PGPASSWORD are required." >&2
  exit 2
fi
case "$DATABASE_URL" in postgresql://*|postgres://*) ;; *)
  echo "DATABASE_URL must be PostgreSQL." >&2
  exit 2
esac
url_authority="${DATABASE_URL#*://}"
url_authority="${url_authority%%/*}"
case "$url_authority" in *@*)
  url_userinfo="${url_authority%@*}"
  case "$url_userinfo" in *:*|*%3[Aa]*)
    echo "DATABASE_URL must not contain embedded password material; use PGPASSWORD." >&2
    exit 2
  esac
esac
case "$DATABASE_URL" in
  *gadpooereceldfpfxsod*)
    echo "Refusing to run against the protected production project." >&2
    exit 2
    ;;
esac

export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=15000"
q() { psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 "$@"; }

database_fingerprint="$(q -F '|' -c "
  select current_database(),coalesce(inet_server_addr()::text,'local'),
         inet_server_port()
")"
case "$database_fingerprint" in
  *v120_concurrency*) ;;
  *)
    echo "Refusing database '$database_fingerprint': its name must contain v120_concurrency." >&2
    echo "Create a dedicated disposable clone and drop that whole database after the run." >&2
    exit 2
    ;;
esac

if [ "$(q -c "
  select count(*) from pg_catalog.pg_class
  where oid='public.staff_blocked_times'::regclass
")" != "1" ]; then
  echo "V120 staff blocked-time table is not installed." >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nestly-v120-concurrency.XXXXXX")"
owner="$(q -c 'select gen_random_uuid()')"
business="$(q -c 'select gen_random_uuid()')"
staff="$(q -c 'select gen_random_uuid()')"
branch_a="$(q -c 'select gen_random_uuid()')"
branch_b="$(q -c 'select gen_random_uuid()')"
service="$(q -c 'select gen_random_uuid()')"
client="$(q -c 'select gen_random_uuid()')"
prefix="${business%%-*}"
owner_email="v120-concurrency-owner-$prefix@example.test"

cleanup() {
  status="$1"
  trap - EXIT HUP INT TERM
  set +e
  rm -f "$work_dir"/*
  rmdir "$work_dir" 2>/dev/null || true
  if [ "$status" -ne 0 ]; then
    echo "V120 fixture rows remain in dedicated database '$database_fingerprint'." >&2
    echo "Drop the whole database; immutable evidence guards intentionally prevent row cleanup." >&2
  fi
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' HUP INT TERM

q -v owner="$owner" -v business="$business" -v staff="$staff" \
  -v branch_a="$branch_a" -v branch_b="$branch_b" \
  -v service="$service" -v client="$client" \
  -v owner_email="$owner_email" <<'SQL' >/dev/null
insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  created_at,updated_at
) values (
  '00000000-0000-0000-0000-000000000000',:'owner',
  'authenticated','authenticated',:'owner_email','',now(),now(),now()
);
insert into public.businesses(
  id,name,slug,industry,enabled_modules,created_at
) values (
  :'business','Glow Atelier V120 concurrency',
  'glow-v120-concurrency-'||replace(:'business','-',''),'spa',
  array['dashboard','clients','services','branches','appointments'],'2000-01-01'
);
update public.business_workspace_controls_v94
   set approval_status='approved',version=version+1,
       decided_at=statement_timestamp(),
       decision_reason='approved synthetic V120 concurrency fixture',
       updated_at=statement_timestamp()
 where business_id=:'business' and approval_status='pending';
insert into public.staff(
  id,business_id,user_id,role,full_name,active,modules,module_perms
) values (
  :'staff',:'business',:'owner','owner','Chen Wei',true,null,null
);
insert into public.branches(
  id,business_id,name,timezone,active,is_default
) values
  (:'branch_a',:'business','Orchard','Asia/Singapore',true,true),
  (:'branch_b',:'business','Tampines','Asia/Singapore',true,false);
insert into public.staff_branches(business_id,staff_id,branch_id)
values
  (:'business',:'staff',:'branch_a'),
  (:'business',:'staff',:'branch_b');
insert into public.branch_hours(
  business_id,branch_id,weekday,opens_at,closes_at
) values
  (:'business',:'branch_a',5,'09:00','18:00'),
  (:'business',:'branch_b',5,'09:00','18:00');
insert into public.staff_hours(
  business_id,staff_id,weekday,starts_at,ends_at
) values (:'business',:'staff',5,'09:00','18:00');
insert into public.services(
  id,business_id,name,variant_label,price_cents,duration_min,active,
  buffer_before_min,buffer_after_min
) values (
  :'service',:'business','Spa Ritual','60 min',6000,60,true,0,0
);
insert into public.staff_services(business_id,staff_id,service_id)
values(:'business',:'staff',:'service');
insert into public.clients(id,business_id,full_name,phone)
values(:'client',:'business','Mei Lin','+6581864567');
SQL

wait_for_sleeper() {
  app_name="$1"
  attempts=0
  while [ "$(q -c "
    select count(*) from pg_stat_activity
     where application_name='$app_name' and wait_event='PgSleep'
  ")" != "1" ]; do
    attempts=$((attempts+1))
    if [ "$attempts" -ge 50 ]; then
      echo "Timed out waiting for $app_name to hold the transaction." >&2
      return 1
    fi
    sleep 0.1
  done
}

write_block_session() {
  output="$1"
  error="$2"
  app_name="$3"
  branch="$4"
  starts="$5"
  ends="$6"
  reason="$7"
  request_key="$8"
  sleep_seconds="$9"
  (
    PGAPPNAME="$app_name" q >"$output" 2>"$error" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$owner','role','authenticated')::text,true
);
set local role authenticated;
select public.create_staff_blocked_time_v120(
  '$business','$branch','$staff','$starts','$ends','$reason','$request_key'
);
select pg_sleep($sleep_seconds);
commit;
SQL
  ) &
  BLOCK_SESSION_PID=$!
}

# Different keys and branches for the same staff overlap. The first transaction
# retains the staff-calendar lock; the second waits, then rejects after commit.
write_block_session \
  "$work_dir/block-first.out" "$work_dir/block-first.err" \
  "v120-block-first-$prefix" "$branch_a" \
  "2026-07-31 10:00+08" "2026-07-31 11:00+08" \
  "Supplier briefing" "block-race-first-$prefix" 2
first_pid="$BLOCK_SESSION_PID"
wait_for_sleeper "v120-block-first-$prefix"

set +e
PGAPPNAME="v120-block-second-$prefix" q \
  >"$work_dir/block-second.out" 2>"$work_dir/block-second.err" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$owner','role','authenticated')::text,true
);
set local role authenticated;
select public.create_staff_blocked_time_v120(
  '$business','$branch_b','$staff',
  '2026-07-31 10:30+08','2026-07-31 11:30+08',
  'Cross-branch overlap','block-race-second-$prefix'
);
commit;
SQL
second_status=$?
set -e
wait "$first_pid"

if [ "$second_status" -eq 0 ] \
   || ! grep -q '"status": "created"' "$work_dir/block-first.out" \
   || ! grep -q 'this time is already blocked' "$work_dir/block-second.err"; then
  echo "V120 block-vs-block race did not serialize to one winner." >&2
  exit 1
fi

# A direct appointment insert races a block writer. It waits on the same
# staff-calendar lock and is rejected by the final trigger after the block wins.
write_block_session \
  "$work_dir/appointment-first.out" "$work_dir/appointment-first.err" \
  "v120-appointment-first-$prefix" "$branch_a" \
  "2026-07-31 14:00+08" "2026-07-31 15:00+08" \
  "Supplier training" "appointment-race-first-$prefix" 2
appointment_first_pid="$BLOCK_SESSION_PID"
wait_for_sleeper "v120-appointment-first-$prefix"

set +e
PGAPPNAME="v120-appointment-second-$prefix" q \
  >"$work_dir/appointment-second.out" 2>"$work_dir/appointment-second.err" <<SQL
insert into public.appointments(
  business_id,client_id,branch_id,service_id,staff_id,
  starts_at,ends_at,status
) values (
  '$business','$client','$branch_b','$service','$staff',
  '2026-07-31 14:15+08','2026-07-31 15:15+08','booked'
);
SQL
appointment_status=$?
set -e
wait "$appointment_first_pid"

if [ "$appointment_status" -eq 0 ] \
   || ! grep -q '"status": "created"' "$work_dir/appointment-first.out" \
   || ! grep -q 'staff is not available for this appointment' \
        "$work_dir/appointment-second.err"; then
  echo "V120 block-vs-appointment race did not serialize to the block winner." >&2
  exit 1
fi

# Reverse the ordering. A privileged direct appointment insert obtains the
# trigger's staff-calendar lock first. The overlapping block RPC waits, then
# rejects the committed appointment instead of creating a conflicting block.
(
  PGAPPNAME="v120-reverse-appointment-first-$prefix" q \
    >"$work_dir/reverse-appointment-first.out" \
    2>"$work_dir/reverse-appointment-first.err" <<SQL
begin;
insert into public.appointments(
  business_id,client_id,branch_id,service_id,staff_id,
  starts_at,ends_at,status
) values (
  '$business','$client','$branch_b','$service','$staff',
  '2026-07-31 16:00+08','2026-07-31 17:00+08','booked'
);
select pg_sleep(2);
commit;
SQL
) &
reverse_appointment_pid=$!
wait_for_sleeper "v120-reverse-appointment-first-$prefix"

set +e
PGAPPNAME="v120-reverse-block-second-$prefix" q \
  >"$work_dir/reverse-block-second.out" \
  2>"$work_dir/reverse-block-second.err" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$owner','role','authenticated')::text,true
);
set local role authenticated;
select public.create_staff_blocked_time_v120(
  '$business','$branch_a','$staff',
  '2026-07-31 16:15+08','2026-07-31 16:45+08',
  'Late supplier briefing','reverse-block-second-$prefix'
);
commit;
SQL
reverse_block_status=$?
set -e
wait "$reverse_appointment_pid"

if [ "$reverse_block_status" -eq 0 ] \
   || ! grep -q 'an appointment or its buffer already uses this time' \
        "$work_dir/reverse-block-second.err"; then
  echo "V120 appointment-vs-block reverse race did not serialize to the appointment winner." >&2
  exit 1
fi

postconditions="$(q -F '|' -c "
  select
    (select count(*) from public.staff_blocked_times
      where business_id='$business'),
    (select count(*) from public.appointments
      where business_id='$business'),
    (select count(*) from app.staff_blocked_time_operations_v120
      where business_id='$business' and operation_type='create'),
    (select count(*) from public.audit_log
      where business_id='$business' and action='STAFF_TIME_BLOCK')
")"
if [ "$postconditions" != "2|1|2|2" ]; then
  echo "V120 concurrency postconditions failed: $postconditions" >&2
  exit 1
fi

echo "V120 two-session concurrency: PASS (blocks 2, appointments 1, receipts 2, audits 2; both writer orderings)"
echo "Fixture rows intentionally remain. Drop the entire dedicated v120_concurrency database now."
