#!/bin/sh
set -eu

if [ "${V40_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V40_CONFIRM_DISPOSABLE_DB=YES for a disposable database." >&2
  exit 2
fi
if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL is required." >&2
  exit 2
fi
case "$DATABASE_URL" in postgresql://*|postgres://*) ;; *)
  echo "DATABASE_URL must be a PostgreSQL URL." >&2; exit 2;;
esac
url_authority="${DATABASE_URL#*://}"; url_authority="${url_authority%%/*}"
case "$url_authority" in *@*)
  url_userinfo="${url_authority%@*}"
  case "$url_userinfo" in *:*|*%3[Aa]*)
    echo "DATABASE_URL must not contain embedded password material; use PGPASSWORD." >&2; exit 2;;
  esac;;
esac
url_lower="$(printf '%s' "$DATABASE_URL" | tr '[:upper:]' '[:lower:]')"
case "$url_lower" in *\?*pass*=*|*\&*pass*=*)
  echo "DATABASE_URL must not contain password query material; use PGPASSWORD." >&2; exit 2;;
esac
if [ -z "${PGPASSWORD:-}" ]; then
  echo "PGPASSWORD is required with the passwordless DATABASE_URL." >&2; exit 2
fi

export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=10000"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
holder_pid=""; tender_pid=""; reverse_pid=""; biz=""
fixture_users="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -c 'select gen_random_uuid(), gen_random_uuid()')"
IFS='|' read -r owner manager <<EOF
$fixture_users
EOF
case "$owner" in ????????-????-????-????-????????????) ;; *) echo "failed to allocate owner UUID" >&2; exit 1;; esac
case "$manager" in ????????-????-????-????-????????????) ;; *) echo "failed to allocate manager UUID" >&2; exit 1;; esac
owner_prefix="${owner%%-*}"
manager_prefix="${manager%%-*}"
fixture_name="V40 concurrency"
fixture_slug="v40-concurrency-$owner_prefix"
owner_email="v40-race-owner-$owner_prefix@example.test"
manager_email="v40-race-manager-$manager_prefix@example.test"
result_message=""
holder_app="v40-credit-holder-$owner_prefix"
tender_app="v40-credit-tender-$owner_prefix"
reversal_app="v40-credit-reversal-$owner_prefix"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/frenly-v40-concurrency.XXXXXX")"

cleanup(){
  original_status="$1"
  trap - EXIT HUP INT TERM
  set +e
  if [ "$original_status" -ne 0 ]; then
    for child_pid in "$holder_pid" "$tender_pid" "$reverse_pid"; do
      if [ -n "$child_pid" ]; then kill -TERM "$child_pid" 2>/dev/null || true; fi
    done
  fi
  if [ -n "$holder_pid" ]; then wait "$holder_pid" 2>/dev/null; cleanup_holder_status=$?; holder_pid=""; fi
  if [ -n "$tender_pid" ]; then wait "$tender_pid" 2>/dev/null; cleanup_tender_status=$?; tender_pid=""; fi
  if [ -n "$reverse_pid" ]; then wait "$reverse_pid" 2>/dev/null; cleanup_reverse_status=$?; reverse_pid=""; fi
  cleanup_status=0
  psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v cleanup_confirm="YES-SCOPED-SYNTHETIC-CLEANUP" \
    -v cleanup_business="$biz" -v cleanup_business_name="$fixture_name" \
    -v cleanup_business_slug="$fixture_slug" \
    -v cleanup_auth_user_1="$owner" -v cleanup_auth_email_1="$owner_email" \
    -v cleanup_auth_user_2="$manager" -v cleanup_auth_email_2="$manager_email" \
    -f "$script_dir/cleanup_synthetic_fixture.sql" >"$work_dir/cleanup" 2>&1 || cleanup_status=$?
  if [ "$cleanup_status" -ne 0 ]; then
    echo "v40 synthetic fixture cleanup failed (status $cleanup_status); first sanitized lines:" >&2
    sed -n '1,8p' "$work_dir/cleanup" | cut -c1-240 | sed -E \
      -e 's#postgres(ql)?://[^[:space:]]+#<redacted-database-url>#g' \
      -e 's#([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ff][Ii][Ll][Ee])=[^[:space:]]+#\1=<redacted>#g' >&2
  fi
  rm -f "$work_dir/holder" "$work_dir/tender" "$work_dir/reverse" "$work_dir/cleanup"
  rmdir "$work_dir" 2>/dev/null || true
  if [ "$cleanup_status" -ne 0 ]; then
    exit 1
  fi
  if [ "$original_status" -eq 0 ] && [ -n "$result_message" ]; then echo "$result_message"; fi
  exit "$original_status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' HUP INT TERM

fixture_output="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v owner="$owner" -v manager="$manager" -v fixture_name="$fixture_name" \
  -v fixture_slug="$fixture_slug" -v owner_email="$owner_email" \
  -v manager_email="$manager_email" <<'SQL'
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000',:'owner','authenticated','authenticated',
  :'owner_email','',now(),now(),now()),
 ('00000000-0000-0000-0000-000000000000',:'manager','authenticated','authenticated',
  :'manager_email','',now(),now(),now());
set role authenticated;
select set_config('request.jwt.claim.sub',:'owner',false);
select (public.create_business(:'fixture_name',:'fixture_slug',
  'test',array['dashboard','clients','sales','loyalty'])::jsonb->>'id')::uuid as biz \gset
select id as branch from public.branches where business_id=:'biz' and is_default limit 1 \gset
reset role;
insert into public.staff(business_id,user_id,role,full_name,active)
values(:'biz',:'manager','manager','V40 race manager',true);
set role authenticated;
select set_config('request.jwt.claim.sub',:'owner',false);
insert into public.clients(business_id,full_name)
values(:'biz','V40 tender/reversal race') returning id as client \gset
insert into public.services(business_id,name,price_cents,duration_min,active)
values(:'biz','V40 race service',100,15,true) returning id as service \gset
insert into public.service_branches(business_id,service_id,branch_id)
values(:'biz',:'service',:'branch') on conflict do nothing;
insert into public.products(business_id,name,retail_price_cents,active)
values(:'biz','V40 race product',100,true) returning id as product \gset
select (public.create_loyalty_config_draft(:'biz',null,'v40-race')::jsonb->>'version_id')::uuid as draft \gset
select public.save_loyalty_config_draft(:'draft',jsonb_build_object(
  'active',true,'kind','points','loyalty_model','points_tiers',
  'reward',jsonb_build_object('internal_name','V40 race reward','customer_name','V40 race reward',
    'fulfillment_kind','credit','cost_points',20,'credit_cents',100,'estimated_cost_cents',50,'active',true),
  'reward_branch_ids',jsonb_build_array(:'branch'::uuid),
  'reward_service_ids',jsonb_build_array(:'service'::uuid),
  'reward_product_ids',jsonb_build_array(:'product'::uuid)
),null);
reset role;
select reward_id as reward from public.loyalty_reward_versions
 where config_version_id=:'draft' and customer_name='V40 race reward' \gset
set role authenticated;
select set_config('request.jwt.claim.sub',:'owner',false);
select public.publish_loyalty_config(:'draft');
select public.adjust_points(:'biz',:'client',100,'v40 concurrency points');
select (public.redeem_reward_at_context(:'biz',:'client',:'reward','v40-race-redeem',
  :'branch',:'service',:'product')::jsonb->>'redemption_id')::uuid as redemption \gset
insert into public.sales(business_id,branch_id,client_id,kind,amount_cents,note)
values(:'biz',:'branch',:'client','membership',100,'v40 credit tender race') returning id as sale \gset
reset role;
select :'biz',:'client',:'sale',:'redemption',
       hashtextextended(:'client'||':v40-credit-race',0);
SQL
)"
fixture="$(printf '%s\n' "$fixture_output" | tail -n 1)"

IFS='|' read -r fixture_biz client sale redemption barrier <<EOF
$fixture
EOF
for fixture_uuid in "$fixture_biz" "$client" "$sale" "$redemption"; do
  case "$fixture_uuid" in ????????-????-????-????-????????????) ;; *)
    echo "fixture setup returned an invalid UUID" >&2
    exit 1;;
  esac
done
barrier_digits="${barrier#-}"
case "$barrier_digits" in ''|*[!0-9]*) echo "fixture setup returned an invalid barrier" >&2; exit 1;; esac
biz="$fixture_biz"

run_tender(){
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v barrier="$barrier" \
    -v actor="$owner" -v biz="$biz" -v sale="$sale" -v tender_app="$tender_app" <<'SQL'
set application_name=:'tender_app';
set statement_timeout='20s';set lock_timeout='10s';
select pg_advisory_lock(:'barrier'::bigint);select pg_advisory_unlock(:'barrier'::bigint);
set role authenticated;select set_config('request.jwt.claim.sub',:'actor',false);
select public.record_credit_tender(:'biz',:'sale',100,'v40 concurrent tender','v40-race-tender')::text;
SQL
}

run_reversal(){
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v barrier="$barrier" \
    -v actor="$manager" -v biz="$biz" -v redemption="$redemption" \
    -v reversal_app="$reversal_app" <<'SQL'
set application_name=:'reversal_app';
set statement_timeout='20s';set lock_timeout='10s';
select pg_advisory_lock(:'barrier'::bigint);select pg_advisory_unlock(:'barrier'::bigint);
set role authenticated;select set_config('request.jwt.claim.sub',:'actor',false);
select public.reverse_loyalty_redemption(:'biz',:'redemption','v40 concurrent reversal','v40-race-reverse')::text;
SQL
}

psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v barrier="$barrier" -v holder_app="$holder_app" \
  >"$work_dir/holder" 2>&1 <<'SQL' &
set application_name=:'holder_app';
set statement_timeout='15s';
select pg_advisory_lock(:'barrier'::bigint);select pg_sleep(5);select pg_advisory_unlock(:'barrier'::bigint);
SQL
holder_pid=$!

attempts=0
while [ "$attempts" -lt 50 ]; do
  holder_backend="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v holder_app="$holder_app" <<'SQL'
select coalesce(max(pid),0) from pg_stat_activity
 where application_name=:'holder_app' and state='active' and wait_event='PgSleep';
SQL
)"
  if [ "$holder_backend" -gt 0 ]; then break; fi
  attempts=$((attempts+1));sleep 0.1
done
if [ "${holder_backend:-0}" -le 0 ]; then echo "barrier holder did not start" >&2;exit 1;fi

run_tender >"$work_dir/tender" 2>&1 & tender_pid=$!
run_reversal >"$work_dir/reverse" 2>&1 & reverse_pid=$!
attempts=0
while [ "$attempts" -lt 50 ]; do
  waiting="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v tender_app="$tender_app" -v reversal_app="$reversal_app" <<'SQL'
select count(*) from pg_stat_activity where application_name in (:'tender_app',:'reversal_app') and state='active'
 and wait_event_type='Lock' and wait_event='advisory';
SQL
)"
  if [ "$waiting" = "2" ]; then break; fi
  attempts=$((attempts+1));sleep 0.1
done
if [ "${waiting:-0}" != "2" ]; then echo "both workers did not reach barrier" >&2;exit 1;fi
set +e
wait "$holder_pid"; holder_status=$?
holder_pid=""
set -e
if [ "$holder_status" -ne 0 ]; then echo "advisory holder did not self-release cleanly" >&2; exit 1; fi

set +e
wait "$tender_pid"; tender_status=$?
tender_pid=""
wait "$reverse_pid"; reverse_status=$?
reverse_pid=""
set -e
if [ "$tender_status" -eq "$reverse_status" ]; then
  echo "expected exactly one tender/reversal winner; tender=$tender_status reversal=$reverse_status" >&2
  exit 1
fi
if [ "$tender_status" -ne 0 ]; then loser="$work_dir/tender";else loser="$work_dir/reverse";fi
if ! grep -Eqi 'insufficient store credit|reward credit may have been spent' "$loser"; then
  echo "loser did not fail at the serialized balance/provenance check" >&2;sed -n '1,20p' "$loser" >&2;exit 1
fi

proof="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v biz="$biz" -v client="$client" -v sale="$sale" -v redemption="$redemption" <<'SQL'
select
 (select count(*) from public.credit_tenders where business_id=:'biz' and sale_id=:'sale'),
 (select count(*) from public.loyalty_redemption_reversals where business_id=:'biz' and redemption_id=:'redemption'),
 (select coalesce(sum(amount_cents),0) from public.credit_ledger where business_id=:'biz' and client_id=:'client'),
 (select coalesce(sum(points),0) from public.points_ledger where business_id=:'biz' and client_id=:'client'),
 (select coalesce(sum(remaining),0) from public.points_batches where business_id=:'biz' and client_id=:'client');
SQL
)"
IFS='|' read -r tenders reversals credit ledger batches <<EOF
$proof
EOF
if [ $((tenders+reversals)) -ne 1 ] || [ "$credit" -ne 0 ] || [ "$ledger" -ne "$batches" ]; then
  echo "race invariant failed: $proof" >&2;exit 1
fi
result_message="v40 tender-vs-redemption-reversal concurrency: PASS ($proof)"
