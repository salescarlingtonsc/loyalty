#!/bin/sh
set -eu

if [ "${V20_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V20_CONFIRM_DISPOSABLE_DB=YES for a disposable/rehearsal database." >&2
  exit 2
fi
if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL is required." >&2
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/frenly-v20-concurrency.XXXXXX")"
trap 'rm -f "$work_dir"/same-a "$work_dir"/same-b "$work_dir"/same-holder "$work_dir"/race-a "$work_dir"/race-b "$work_dir"/race-holder; rmdir "$work_dir"' EXIT

fixture="$({ psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 <<'SQL'
select gen_random_uuid() as actor \gset
insert into auth.users(
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at
) values (
  '00000000-0000-0000-0000-000000000000', :'actor',
  'authenticated', 'authenticated',
  'v20-concurrency-' || substr(:'actor', 1, 8) || '@example.test', '',
  now(), now(), now()
);
insert into public.businesses(name, slug, industry, enabled_modules)
values (
  'V20 concurrency', 'v20-concurrency-' || substr(:'actor', 1, 8),
  'test', array['dashboard','clients','sales']
) returning id as biz \gset
insert into public.branches(business_id, name, is_default, active)
values (:'biz', 'Concurrency main', true, true)
returning id as branch \gset
insert into public.staff(business_id, user_id, role, full_name, active)
values (:'biz', :'actor', 'owner', 'Concurrency owner', true)
returning id as staff \gset
insert into public.staff_branches(business_id, staff_id, branch_id)
values (:'biz', :'staff', :'branch');
insert into public.clients(business_id, full_name)
values (:'biz', 'Same-key client') returning id as client_same \gset
insert into public.clients(business_id, full_name)
values (:'biz', 'Balance-race client') returning id as client_race \gset
insert into public.gift_cards(business_id, code, initial_cents, balance_cents, status)
values (:'biz', 'GC-' || upper(substr(replace(:'client_same','-',''), 1, 8)), 2000, 2000, 'active')
returning code as code_same \gset
insert into public.gift_cards(business_id, code, initial_cents, balance_cents, status)
values (:'biz', 'GC-' || upper(substr(replace(:'client_race','-',''), 1, 8)), 1000, 1000, 'active')
returning code as code_race \gset
set role authenticated;
select set_config('request.jwt.claim.sub', :'actor', false);
select public.redeem_gift_card(:'biz', :'code_same', :'client_same', null);
select public.redeem_gift_card(:'biz', :'code_race', :'client_race', null);
insert into public.sales(business_id, branch_id, client_id, kind, amount_cents, note)
values (:'biz', :'branch', :'client_same', 'service', 1000, 'same-key race')
returning id as sale_same \gset
insert into public.sales(business_id, branch_id, client_id, kind, amount_cents, note)
values (:'biz', :'branch', :'client_race', 'service', 2000, 'balance race')
returning id as sale_race \gset
reset role;
select :'actor', :'biz', :'sale_same', :'sale_race',
       hashtextextended(:'actor' || ':same-barrier', 0),
       hashtextextended(:'actor' || ':race-barrier', 0);
SQL
} | tail -n 1)"

IFS='|' read -r actor biz sale_same sale_race same_barrier race_barrier <<EOF
$fixture
EOF

call_tender() {
  sale="$1"
  amount="$2"
  key="$3"
  barrier="$4"
  app_name="$5"
  psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v actor="$actor" -v biz="$biz" -v sale="$sale" -v amount="$amount" \
    -v key="$key" -v barrier="$barrier" -v app_name="$app_name" <<'SQL'
\set VERBOSITY verbose
set application_name = :'app_name';
select pg_advisory_lock(:'barrier'::bigint);
select pg_advisory_unlock(:'barrier'::bigint);
set role authenticated;
select set_config('request.jwt.claim.sub', :'actor', false);
select public.record_credit_tender(
  :'biz', :'sale', :'amount'::integer, 'two-session concurrency proof', :'key'
)::text;
SQL
}

start_barrier() {
  barrier="$1"
  app_name="$2"
  output="$3"
  psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v barrier="$barrier" -v app_name="$app_name" >"$output" 2>&1 <<'SQL' &
set application_name = :'app_name';
select pg_advisory_lock(:'barrier'::bigint);
select pg_sleep(30);
SQL
  barrier_pid=$!

  attempts=0
  while [ "$attempts" -lt 50 ]; do
    holder_ready="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v app_name="$app_name" <<'SQL'
select coalesce(max(pid), 0) from pg_stat_activity
 where application_name = :'app_name'
   and state = 'active'
   and wait_event = 'PgSleep';
SQL
)"
    if [ "$holder_ready" -gt 0 ]; then
      barrier_backend_pid="$holder_ready"
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  echo "Barrier holder $app_name did not acquire its advisory lock." >&2
  return 1
}

release_after_both_waiting() {
  app_a="$1"
  app_b="$2"
  holder_app="$3"
  holder_backend_pid="$4"
  attempts=0
  while [ "$attempts" -lt 50 ]; do
    waiting="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
      -v app_a="$app_a" -v app_b="$app_b" <<'SQL'
select count(*) from pg_stat_activity
 where application_name in (:'app_a', :'app_b')
   and state = 'active'
   and wait_event_type = 'Lock'
   and wait_event = 'advisory';
SQL
)"
    if [ "$waiting" = "2" ]; then
      holder_still_locked="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
        -v holder_app="$holder_app" -v holder_backend_pid="$holder_backend_pid" <<'SQL'
select count(*) from pg_stat_activity
 where application_name = :'holder_app'
   and pid = :'holder_backend_pid'::integer
   and state = 'active'
   and wait_event = 'PgSleep';
SQL
)"
      if [ "$holder_still_locked" != "1" ]; then
        echo "Barrier holder disappeared before verified release." >&2
        return 1
      fi
      terminated="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
        -v holder_backend_pid="$holder_backend_pid" <<'SQL'
select pg_terminate_backend(:'holder_backend_pid'::integer);
SQL
)"
      if [ "$terminated" != "t" ]; then
        echo "Verified barrier holder could not be released." >&2
        return 1
      fi
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  echo "Both workers did not reach the shared advisory barrier before release." >&2
  return 1
}

same_holder_app="v20-same-holder-$actor"
same_a_app="v20-same-a-$actor"
same_b_app="v20-same-b-$actor"
start_barrier "$same_barrier" "$same_holder_app" "$work_dir/same-holder"
same_holder=$barrier_pid
same_holder_backend=$barrier_backend_pid
call_tender "$sale_same" 500 concurrency-same-key "$same_barrier" "$same_a_app" >"$work_dir/same-a" 2>&1 &
same_a=$!
call_tender "$sale_same" 500 concurrency-same-key "$same_barrier" "$same_b_app" >"$work_dir/same-b" 2>&1 &
same_b=$!
release_after_both_waiting "$same_a_app" "$same_b_app" "$same_holder_app" \
  "$same_holder_backend"
wait "$same_holder" 2>/dev/null || true
wait "$same_a"
wait "$same_b"

same_proof="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 -v biz="$biz" -v sale="$sale_same" <<'SQL'
select
  (select count(*) from public.financial_operations
    where business_id = :'biz' and sale_id = :'sale'
      and operation_type = 'credit_tender' and idempotency_key = 'concurrency-same-key'),
  (select count(*) from public.credit_tenders
    where business_id = :'biz' and sale_id = :'sale'
      and idempotency_key = 'concurrency-same-key'),
  (select count(*) from public.payments
    where business_id = :'biz' and sale_id = :'sale' and method = 'credit'),
  (select count(*) from public.credit_ledger
    where business_id = :'biz' and sale_id = :'sale' and entry_type = 'spend');
SQL
)"
if [ "$same_proof" != "1|1|1|1" ]; then
  echo "Same-key race failed exact-child proof: $same_proof" >&2
  exit 1
fi
if ! grep -q '"replayed": false' "$work_dir/same-a" "$work_dir/same-b" ||
   ! grep -q '"replayed": true' "$work_dir/same-a" "$work_dir/same-b"; then
  echo "Same-key race did not produce one original and one replay." >&2
  exit 1
fi

race_holder_app="v20-race-holder-$actor"
race_a_app="v20-race-a-$actor"
race_b_app="v20-race-b-$actor"
start_barrier "$race_barrier" "$race_holder_app" "$work_dir/race-holder"
race_holder=$barrier_pid
race_holder_backend=$barrier_backend_pid
call_tender "$sale_race" 800 concurrency-balance-a "$race_barrier" "$race_a_app" >"$work_dir/race-a" 2>&1 &
race_a=$!
call_tender "$sale_race" 800 concurrency-balance-b "$race_barrier" "$race_b_app" >"$work_dir/race-b" 2>&1 &
race_b=$!
release_after_both_waiting "$race_a_app" "$race_b_app" "$race_holder_app" \
  "$race_holder_backend"
wait "$race_holder" 2>/dev/null || true
set +e
wait "$race_a"; race_a_status=$?
wait "$race_b"; race_b_status=$?
set -e
if [ "$race_a_status" -eq 0 ] && [ "$race_b_status" -eq 0 ]; then
  echo "Competing tenders both succeeded and overdrew credit." >&2
  exit 1
fi
if [ "$race_a_status" -ne 0 ] && [ "$race_b_status" -ne 0 ]; then
  echo "Competing tenders both failed; expected exactly one success." >&2
  exit 1
fi

if [ "$race_a_status" -ne 0 ]; then
  loser_output="$work_dir/race-a"
else
  loser_output="$work_dir/race-b"
fi
if ! grep -Eq 'ERROR:  +23514: insufficient store credit: 200 available, 800 requested' "$loser_output"; then
  echo "Competing-tender loser did not fail with exact SQLSTATE/message:" >&2
  sed -n '1,20p' "$loser_output" >&2
  exit 1
fi

balance_proof="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 -v biz="$biz" -v sale="$sale_race" <<'SQL'
select
  (select count(*) from public.credit_tenders
    where business_id = :'biz' and sale_id = :'sale'),
  (select coalesce(sum(amount_cents), 0) from public.payments
    where business_id = :'biz' and sale_id = :'sale' and method = 'credit'),
  (select coalesce(sum(cl.amount_cents), 0) from public.credit_ledger cl
    join public.sales s on s.business_id = cl.business_id and s.client_id = cl.client_id
    where s.id = :'sale');
SQL
)"
if [ "$balance_proof" != "1|800|200" ]; then
  echo "Balance race failed serialization proof: $balance_proof" >&2
  exit 1
fi

echo "v20 two-session concurrency checks passed (same-key replay and competing balance race)."
