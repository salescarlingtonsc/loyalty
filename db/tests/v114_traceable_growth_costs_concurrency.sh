#!/bin/sh
# True two-session v114 replay harness. Run only against local/disposable data.
# Proves an immutable first receipt, one canonical rule, and changed-payload
# conflict for the same idempotency identity.
set -eu

if [ "${V114_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V114_CONFIRM_DISPOSABLE_DB=YES." >&2
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
case "$DATABASE_URL" in *qadpooereceldfpfxsod*)
  echo "Refusing to run against the protected production project." >&2
  exit 2
esac

export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=15000"
q() { psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 "$@"; }

database_fingerprint="$(q -F '|' -c "
  select current_database(),coalesce(inet_server_addr()::text,'local'),
         inet_server_port()
")"
case "$database_fingerprint" in
  *v114*|*rehearsal*|*test*|*shadow*) ;;
  *)
    case "$DATABASE_URL" in
      postgresql://postgres@127.0.0.1:54322/postgres|\
      postgres://postgres@127.0.0.1:54322/postgres) ;;
      *)
        echo "Refusing database '$database_fingerprint': not demonstrably disposable/local." >&2
        exit 2
        ;;
    esac
    ;;
esac
if [ "$(q -c "
  select count(*) from pg_catalog.pg_class
  where oid='public.growth_cost_rules_v114'::regclass
")" != "1" ]; then
  echo "v114 growth-cost table is not installed." >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nestly-v114-concurrency.XXXXXX")"
super_admin="$(q -c 'select gen_random_uuid()')"
business="$(q -c 'select gen_random_uuid()')"
request_key="$(q -c 'select gen_random_uuid()')"
prefix="${business%%-*}"
super_email="v114-concurrency-sa-$prefix@example.test"
old_flag="$(q -c "
  select enabled::text from app.platform_feature_flags
  where feature_key='economics_driver_policy_v109'
")"

cleanup() {
  status="$1"
  trap - EXIT HUP INT TERM
  set +e
  q -v business="$business" -v super_admin="$super_admin" \
    -v old_flag="$old_flag" <<'SQL' >/dev/null 2>&1
-- Restore shared mutable state first. The v112 receipt and the synthetic
-- business/benefit-registry identity are intentionally permanent evidence in
-- this disposable database: their guards reject deletion by design.
update app.platform_feature_flags
set enabled=:'old_flag'::boolean
where feature_key='economics_driver_policy_v109';
delete from public.growth_cost_rules_v114 where business_id=:'business';
delete from public.audit_log where business_id=:'business';
delete from public.super_admins where user_id=:'super_admin';
delete from auth.users where id=:'super_admin';
SQL
  rm -f "$work_dir"/*
  rmdir "$work_dir" 2>/dev/null || true
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' HUP INT TERM

q -v super_admin="$super_admin" -v business="$business" \
  -v super_email="$super_email" <<'SQL' >/dev/null
insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  created_at,updated_at
) values (
  '00000000-0000-0000-0000-000000000000',:'super_admin',
  'authenticated','authenticated',:'super_email','',now(),now(),now()
);
insert into public.super_admins(user_id,email,note)
values(:'super_admin',:'super_email','v114 two-session fixture');
insert into public.businesses(
  id,name,slug,currency,industry,enabled_modules,is_synthetic
) values(
  :'business','V114 two-session concurrency',
  'v114-concurrency-'||:'business','SGD','facial',
  array['dashboard','reports','pnl'],true
);
update app.platform_feature_flags
set enabled=true
where feature_key='economics_driver_policy_v109';
SQL

normalize() {
  awk '/\{.*\}/ { line=$0 } END { if (line != "") print line }' "$1" > "$2"
}

cat >"$work_dir/first.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$super_admin','role','authenticated')::text,true
);
set local role authenticated;
select public.set_growth_cost_rule_v114(
  '$business',null,'delivery','in_app','fixed_per_event',25,
  'provider_contract','V114-CONCURRENCY',
  '{"fixture":true,"currency":"SGD"}','2026-07-01 00:00+00','$request_key'
);
select pg_sleep(2);
commit;
SQL
cat >"$work_dir/replay.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$super_admin','role','authenticated')::text,true
);
set local role authenticated;
select public.set_growth_cost_rule_v114(
  '$business',null,'delivery','in_app','fixed_per_event',25,
  'provider_contract','V114-CONCURRENCY',
  '{"fixture":true,"currency":"SGD"}','2026-07-01 00:00+00','$request_key'
);
commit;
SQL

q -f "$work_dir/first.sql" >"$work_dir/first.raw" 2>&1 &
first_pid=$!
sleep 0.25
q -f "$work_dir/replay.sql" >"$work_dir/replay.raw" 2>&1
wait "$first_pid"
normalize "$work_dir/first.raw" "$work_dir/first.out"
normalize "$work_dir/replay.raw" "$work_dir/replay.out"
if ! cmp -s "$work_dir/first.out" "$work_dir/replay.out"; then
  echo "Concurrent v114 receipts differ:" >&2
  sed -n '1p' "$work_dir/first.out" >&2
  sed -n '1p' "$work_dir/replay.out" >&2
  exit 1
fi
if ! grep -q '"replayed": false' "$work_dir/first.out"; then
  echo "Concurrent v114 receipt did not preserve the first response." >&2
  exit 1
fi
if [ "$(q -c "
  select count(*) from public.growth_cost_rules_v114
  where business_id='$business' and cost_class='delivery'
    and scope_key='in_app'
")" != "1" ]; then
  echo "Concurrent v114 request created duplicate rules." >&2
  exit 1
fi
if [ "$(q -c "
  select count(*) from public.concurrent_operation_receipts_v112
  where operation='set_growth_cost_rule_v114'
    and scope->>'business_id'='$business'
")" != "1" ]; then
  echo "Concurrent v114 request did not persist exactly one receipt." >&2
  exit 1
fi

cat >"$work_dir/conflict.sql" <<SQL
\set VERBOSITY verbose
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$super_admin','role','authenticated')::text,true
);
set local role authenticated;
select public.set_growth_cost_rule_v114(
  '$business',null,'delivery','in_app','fixed_per_event',26,
  'provider_contract','V114-CONCURRENCY',
  '{"fixture":true,"currency":"SGD"}','2026-07-01 00:00+00','$request_key'
);
commit;
SQL
if q -f "$work_dir/conflict.sql" >"$work_dir/conflict.raw" 2>&1; then
  echo "Changed v114 payload reused an idempotency key without conflict." >&2
  exit 1
fi
if ! grep -q '23505: idempotency key reused with a different request' \
  "$work_dir/conflict.raw"; then
  echo "Changed v114 payload did not fail with the expected 23505 conflict." >&2
  sed -n '1,5p' "$work_dir/conflict.raw" >&2
  exit 1
fi

echo "V114 CONCURRENCY PASS"
