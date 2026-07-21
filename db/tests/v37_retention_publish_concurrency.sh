#!/bin/sh
set -eu

if [ "${V37_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V37_CONFIRM_DISPOSABLE_DB=YES for a disposable database." >&2
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
holder_pid=""; sale_pid=""; publish_pid=""; biz=""
owner="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
case "$owner" in ????????-????-????-????-????????????) ;; *) echo "failed to allocate fixture UUID" >&2; exit 1;; esac
owner_prefix="${owner%%-*}"
fixture_name="V37 concurrency"
fixture_slug="v37-concurrency-$owner_prefix"
owner_email="v37-race-owner-$owner_prefix@example.test"
result_message=""
holder_app="v37-retention-holder-$owner_prefix"
sale_app="v37-retention-sale-$owner_prefix"
publish_app="v37-retention-publish-$owner_prefix"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/frenly-v37-concurrency.XXXXXX")"

cleanup(){
  original_status="$1"
  trap - EXIT HUP INT TERM
  set +e
  if [ "$original_status" -ne 0 ]; then
    for child_pid in "$holder_pid" "$sale_pid" "$publish_pid"; do
      if [ -n "$child_pid" ]; then kill -TERM "$child_pid" 2>/dev/null || true; fi
    done
  fi
  if [ -n "$holder_pid" ]; then wait "$holder_pid" 2>/dev/null; cleanup_holder_status=$?; holder_pid=""; fi
  if [ -n "$sale_pid" ]; then wait "$sale_pid" 2>/dev/null; cleanup_sale_status=$?; sale_pid=""; fi
  if [ -n "$publish_pid" ]; then wait "$publish_pid" 2>/dev/null; cleanup_publish_status=$?; publish_pid=""; fi
  cleanup_status=0
  psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v cleanup_confirm="YES-SCOPED-SYNTHETIC-CLEANUP" \
    -v cleanup_business="$biz" -v cleanup_business_name="$fixture_name" \
    -v cleanup_business_slug="$fixture_slug" \
    -v cleanup_auth_user_1="$owner" -v cleanup_auth_email_1="$owner_email" \
    -v cleanup_auth_user_2="" -v cleanup_auth_email_2="" \
    -f "$script_dir/cleanup_synthetic_fixture.sql" >"$work_dir/cleanup" 2>&1 || cleanup_status=$?
  if [ "$cleanup_status" -ne 0 ]; then
    echo "v37 synthetic fixture cleanup failed (status $cleanup_status); first sanitized lines:" >&2
    sed -n '1,8p' "$work_dir/cleanup" | cut -c1-240 | sed -E \
      -e 's#postgres(ql)?://[^[:space:]]+#<redacted-database-url>#g' \
      -e 's#([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ff][Ii][Ll][Ee])=[^[:space:]]+#\1=<redacted>#g' >&2
  fi
  rm -f "$work_dir/holder" "$work_dir/sale" "$work_dir/publish" "$work_dir/cleanup"
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
  -v owner="$owner" -v fixture_name="$fixture_name" -v fixture_slug="$fixture_slug" \
  -v owner_email="$owner_email" <<'SQL'
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000',:'owner','authenticated','authenticated',
  :'owner_email','',now(),now(),now());
set role authenticated;
select set_config('request.jwt.claim.sub',:'owner',false);
select (public.create_business(:'fixture_name',:'fixture_slug',
  'test',array['dashboard','clients','sales','loyalty','retention'])::jsonb->>'id')::uuid as biz \gset
select id as branch from public.branches where business_id=:'biz' and is_default limit 1 \gset
select id as owner_staff from public.staff where business_id=:'biz' and user_id=:'owner' limit 1 \gset
insert into public.clients(business_id,full_name) values(:'biz','V37 race client') returning id as client \gset
select id as taxonomy from public.firm_reward_taxonomy
 where business_id=:'biz' and fulfillment_kind='credit' and active order by sort,id limit 1 \gset
select (public.create_loyalty_config_draft(:'biz',null,'v37-race-base')::jsonb->>'version_id')::uuid as base \gset
select snapshot_hash as base_hash from public.firm_config_versions where id=:'base' \gset
select gen_random_uuid() as program_id \gset
select (public.save_retention_program_draft(:'base',:'program_id',jsonb_build_object(
  'name','V37 race reward','active',true,'goal_visits',1,'period_days',30,
  'starts_on',current_date,'reward_taxonomy_id',:'taxonomy'::uuid,'credit_cents',101),:'base_hash')
  ->>'program_id')::uuid as program \gset
select public.publish_loyalty_config(:'base');
select (public.create_loyalty_config_draft(:'biz',:'base','v37-race-next')::jsonb->>'version_id')::uuid as draft \gset
select snapshot_hash as draft_hash from public.firm_config_versions where id=:'draft' \gset
select public.save_retention_program_draft(:'draft',:'program',jsonb_build_object('credit_cents',202),:'draft_hash');
reset role;
select :'biz',:'branch',:'owner_staff',:'client',:'program',:'base',:'draft';
SQL
)"
fixture="$(printf '%s\n' "$fixture_output" | tail -n 1)"

IFS='|' read -r fixture_biz branch owner_staff client program base draft <<EOF
$fixture
EOF
for fixture_uuid in "$fixture_biz" "$branch" "$owner_staff" "$client" "$program" "$base" "$draft"; do
  case "$fixture_uuid" in ????????-????-????-????-????????????) ;; *)
    echo "fixture setup returned an invalid UUID" >&2
    exit 1;;
  esac
done
biz="$fixture_biz"

run_sale(){
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v owner="$owner" -v biz="$biz" -v branch="$branch" -v owner_staff="$owner_staff" \
    -v client="$client" -v sale_app="$sale_app" <<'SQL'
set application_name=:'sale_app';
set statement_timeout='20s'; set lock_timeout='10s';
set role authenticated; select set_config('request.jwt.claim.sub',:'owner',false);
select public.record_quick_sale(:'biz',100,'cash',:'client',:'owner_staff',:'branch',
  'v37 concurrent sale','v37-race-sale',true)::text;
SQL
}

run_publish(){
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v owner="$owner" -v draft="$draft" -v publish_app="$publish_app" <<'SQL'
set application_name=:'publish_app';
set statement_timeout='20s'; set lock_timeout='10s';
set role authenticated; select set_config('request.jwt.claim.sub',:'owner',false);
select public.publish_loyalty_config(:'draft')::text;
SQL
}

psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v biz="$biz" -v holder_app="$holder_app" \
  >"$work_dir/holder" 2>&1 <<'SQL' &
begin; set application_name=:'holder_app'; set statement_timeout='15s';
select id from public.businesses where id=:'biz' for update;
select pg_sleep(5); rollback;
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
  attempts=$((attempts+1)); sleep 0.1
done
if [ "${holder_backend:-0}" -le 0 ]; then echo "business-row holder did not start" >&2; exit 1; fi

run_sale >"$work_dir/sale" 2>&1 & sale_pid=$!
run_publish >"$work_dir/publish" 2>&1 & publish_pid=$!
attempts=0
while [ "$attempts" -lt 50 ]; do
  waiting="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v sale_app="$sale_app" -v publish_app="$publish_app" <<'SQL'
select count(*) from pg_stat_activity where application_name in (:'sale_app',:'publish_app') and state='active'
 and wait_event_type='Lock';
SQL
)"
  if [ "$waiting" = "2" ]; then break; fi
  attempts=$((attempts+1)); sleep 0.1
done
if [ "${waiting:-0}" != "2" ]; then echo "both workers did not block inside on the businesses row" >&2; exit 1; fi
set +e
wait "$holder_pid"; holder_status=$?
holder_pid=""
set -e
if [ "$holder_status" -ne 0 ]; then echo "business-row holder did not self-release cleanly" >&2; exit 1; fi

set +e
wait "$sale_pid"; sale_status=$?
sale_pid=""
wait "$publish_pid"; publish_status=$?
publish_pid=""
set -e
if [ "$sale_status" -ne 0 ]; then echo "concurrent sale worker failed" >&2; exit 1; fi
if [ "$publish_status" -ne 0 ]; then echo "concurrent publish worker failed" >&2; exit 1; fi

proof="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v biz="$biz" -v program="$program" -v base="$base" -v draft="$draft" <<'SQL'
with event as (
  select id,config_version_id from public.sales
   where business_id=:'biz' and note='v37 concurrent sale'
), grant_evidence as (
  select g.config_version_id,g.retention_program_version_id,g.reward_value::integer,
         rv.config_version_id as rule_config,
         coalesce(rv.credit_cents,0) as rule_credit
    from public.reward_grants g
    join public.retention_program_versions rv on rv.id=g.retention_program_version_id
   where g.business_id=:'biz' and g.program_id=:'program'
)
select (select count(*) from event),(select count(*) from grant_evidence),
       (select config_version_id from event),(select config_version_id from grant_evidence),
       (select rule_config from grant_evidence),(select reward_value from grant_evidence),
       (select rule_credit from grant_evidence),
       (select count(*) from public.firm_config_versions where id in(:'base',:'draft') and status in('published','superseded'));
SQL
)"
IFS='|' read -r sales grants sale_config grant_config rule_config grant_value rule_value immutable_versions <<EOF
$proof
EOF
if [ "$sales" -ne 1 ] || [ "$grants" -ne 1 ] \
   || [ "$sale_config" != "$grant_config" ] || [ "$grant_config" != "$rule_config" ] \
   || [ "$grant_value" -ne "$rule_value" ] || [ "$immutable_versions" -ne 2 ]; then
  echo "sale/publish race mixed retention versions: $proof" >&2
  exit 1
fi

# Both racing transactions succeed, while the sale and its grant use exactly one immutable config version.
result_message="v37 retention sale-vs-publish concurrency: PASS ($proof)"
