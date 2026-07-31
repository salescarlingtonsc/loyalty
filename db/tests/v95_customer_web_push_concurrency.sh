#!/bin/sh
set -eu

if [ "${V95_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V95_CONFIRM_DISPOSABLE_DB=YES." >&2
  exit 2
fi
if [ -z "${DATABASE_URL:-}" ] || [ -z "${PGPASSWORD:-}" ]; then
  echo "DATABASE_URL and PGPASSWORD are required." >&2
  exit 2
fi
case "$DATABASE_URL" in postgresql://*|postgres://*) ;; *)
  echo "DATABASE_URL must be PostgreSQL." >&2; exit 2;;
esac

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nestly-v95-push-concurrency.XXXXXX")"
customer="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
identity="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
email="v95-concurrency-${customer}@example.test"

cleanup() {
  status="$1"
  trap - EXIT HUP INT TERM
  set +e
  psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v customer="$customer" -v identity="$identity" -v email="$email" <<'SQL' >/dev/null 2>&1
delete from public.customer_push_delivery_results_v95
 where delivery_id in (
   select id from public.customer_push_deliveries_v95 where identity_id=:'identity'
 );
delete from public.customer_push_deliveries_v95 where identity_id=:'identity';
delete from public.customer_push_subscription_operations_v95 where identity_id=:'identity';
delete from public.customer_push_subscriptions_v95 where identity_id=:'identity';
delete from public.customer_identities where id=:'identity' and auth_user_id=:'customer';
delete from auth.users where id=:'customer' and email=:'email';
SQL
  rm -f "$work_dir"/register-*
  rmdir "$work_dir" 2>/dev/null || true
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' HUP INT TERM

psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
  -v customer="$customer" -v identity="$identity" -v email="$email" <<'SQL'
insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
) values(
  '00000000-0000-0000-0000-000000000000',:'customer','authenticated',
  'authenticated',:'email','',now(),now(),now()
);
insert into public.customer_identities(id,auth_user_id,status,created_via)
values(:'identity',:'customer','active','wallet_start');
SQL

pids=""
i=1
while [ "$i" -le 8 ]; do
  endpoint="https://fcm.googleapis.com/wp/v95${i}${customer}"
  key="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
  (
    psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
      -v customer="$customer" -v endpoint="$endpoint" -v key="$key" <<'SQL' \
      >"$work_dir/register-$i" 2>&1
set role authenticated;
select set_config('request.jwt.claim.sub',:'customer',false);
select public.customer_register_push_subscription_v95(
  :'endpoint',repeat('A',87),repeat('B',22),:'key'
);
SQL
  ) &
  pids="$pids $!"
  i=$((i+1))
done

for pid in $pids; do
  wait "$pid"
done

counts="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v identity="$identity" <<'SQL'
select
  count(*) filter(where status='active'),
  count(*) filter(where status='revoked'),
  count(*)
from public.customer_push_subscriptions_v95
where identity_id=:'identity';
SQL
)"
[ "$counts" = "5|3|8" ] || {
  echo "concurrent registration violated the five-device cap" >&2
  exit 1
}

operations="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
  -v identity="$identity" <<'SQL'
select count(*) from public.customer_push_subscription_operations_v95
where identity_id=:'identity';
SQL
)"
[ "$operations" = "8" ] || {
  echo "concurrent registration lost or duplicated operation evidence" >&2
  exit 1
}

echo "v95 concurrent push registration: PASS (8 registrations, exactly 5 active)"
