#!/bin/sh
set -eu

# Destructive synthetic stress evidence for a disposable database only. The
# caller must reset the disposable database after this script succeeds.
if [ "${V89_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V89_CONFIRM_DISPOSABLE_DB=YES." >&2
  exit 2
fi
if [ -z "${DATABASE_URL:-}" ] || [ -z "${PGPASSWORD:-}" ]; then
  echo "DATABASE_URL and PGPASSWORD are required." >&2
  exit 2
fi
case "$DATABASE_URL" in
  postgresql://*|postgres://*) ;;
  *) echo "DATABASE_URL must be a PostgreSQL URL." >&2; exit 2 ;;
esac

export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c statement_timeout=60000 -c lock_timeout=30000"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nestly-v89-race.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

owner="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
customer="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
prefix="${owner%%-*}"

fixture="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v owner="$owner" -v customer="$customer" -v prefix="$prefix" <<'SQL'
insert into auth.users(
  instance_id,id,aud,role,email,phone,encrypted_password,email_confirmed_at,
  phone_confirmed_at,created_at,updated_at
) values
  ('00000000-0000-0000-0000-000000000000',:'owner','authenticated',
    'authenticated','v89-race-owner-'||:'prefix'||'@example.test',null,'',
    now(),null,now(),now()),
  ('00000000-0000-0000-0000-000000000000',:'customer','authenticated',
    'authenticated','v89-race-customer-'||:'prefix'||'@example.test',
    '+658'||substr(
      regexp_replace(:'customer','[^0-9]','','g')||'0000000',1,7
    ),'',
    now(),now(),now(),now());
insert into public.businesses(name,slug,industry,join_enabled,enabled_modules)
values(
  'V89 QR concurrency '||:'prefix','v89-qr-race-'||:'prefix','test',true,
  array['dashboard','clients','sales','loyalty','bookings','appointments']
) returning id as business \gset
insert into public.branches(business_id,name,is_default,active)
values(:'business','V89 Race Main',true,true)
returning id as branch \gset
insert into public.businesses(name,slug,industry,join_enabled,enabled_modules)
values(
  'V89 QR foreign tenant '||:'prefix','v89-qr-foreign-'||:'prefix','test',true,
  array['dashboard','clients','sales','loyalty']
) returning id as foreign_business \gset
insert into public.branches(business_id,name,is_default,active)
values(:'foreign_business','V89 Race Foreign',true,true)
returning id as foreign_branch \gset
update public.business_workspace_controls_v94
set approval_status='approved',version=version+1,decided_by=:'owner',
    decided_at=now(),decision_reason='disposable redemption concurrency fixture',
    updated_at=now()
where business_id in(:'business',:'foreign_business');
insert into public.staff(
  business_id,user_id,role,full_name,active,modules,module_perms
) values(
  :'business',:'owner','owner','V89 Race Owner',true,null,null
);
insert into public.business_customer_capabilities_v89(
  business_id,booking_enabled,redemption_enabled,
  appointment_changes_enabled,updated_by
) values(:'business',false,true,false,:'owner');
insert into public.customer_identities(
  auth_user_id,status,created_via
) values(
  :'customer','active','phone_registration'
) returning id as identity \gset
select set_config('app.c42_profile_identity',:'identity',false) \gset
insert into public.customer_profiles(
  identity_id,auth_user_id,full_name,birth_date
) values(
  :'identity',:'customer','V89 Race Customer','1990-01-01'
);
select set_config('app.c42_profile_identity','',false) \gset
select encode(extensions.gen_random_bytes(32),'hex') as join_token \gset
insert into public.business_customer_join_qr_v89(
  business_id,token_hash,expires_at,issued_by
) values(
  :'business',app.v89_sha256(:'join_token'),now()+interval '1 day',:'owner'
);
select :'business',:'branch',:'foreign_branch',:'identity',:'join_token';
SQL
)"
IFS='|' read -r business branch foreign_branch identity join_token <<EOF
$fixture
EOF

claim_once() {
  output="$1"
  psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v customer="$customer" -v token="$join_token" >"$output" 2>&1 <<'SQL'
set role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('sub',:'customer','role','authenticated')::text,
  false
);
select public.customer_join_business_from_qr_v89(
  :'token',gen_random_uuid()
)::text;
SQL
}

i=1
pids=""
while [ "$i" -le 25 ]; do
  claim_once "$work_dir/claim-$i" &
  pids="$pids $!"
  i=$((i+1))
done
claim_failed=0
for pid in $pids; do
  if ! wait "$pid"; then claim_failed=1; fi
done
if [ "$claim_failed" -ne 0 ]; then
  grep -h -E 'ERROR|DETAIL|CONTEXT' "$work_dir"/claim-* >&2 || true
  exit 1
fi

claim_proof="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v business="$business" -v customer="$customer" -v identity="$identity" <<'SQL'
select
  (select count(*) from public.customer_links
    where business_id=:'business' and auth_user_id=:'customer'
      and identity_id=:'identity' and state='verified'),
  (select count(*) from public.clients
    where business_id=:'business'
      and phone_norm=(select app.norm_phone(phone) from auth.users
        where id=:'customer')),
  (select count(*) from public.customer_link_claim_attempts
    where business_id=:'business' and identity_id=:'identity'
      and operation='qr_join');
SQL
)"
[ "$claim_proof" = "1|1|25" ] || {
  echo "25-way QR claim invariant failed (link|client|attempt=$claim_proof)" >&2
  exit 1
}

redemption_fixture="$(psql "$DATABASE_URL" -X -qAt -F '|' \
  -v ON_ERROR_STOP=1 -v business="$business" -v owner="$owner" \
  -v customer="$customer" <<'SQL'
select client_id as client from public.customer_links
 where business_id=:'business' and auth_user_id=:'customer'
   and state='verified' \gset
select gen_random_uuid() as config,gen_random_uuid() as reward,
  gen_random_uuid() as reward_version \gset
insert into public.firm_config_versions(
  id,business_id,version_no,status,source,snapshot_hash,created_by
) values(
  :'config',:'business',1,'draft','manual',md5('v89-race-config'),:'owner'
);
select set_config(
  'request.jwt.claims',
  json_build_object('sub',:'owner','role','authenticated')::text,
  false
) \gset
insert into public.loyalty_program_versions(
  config_version_id,business_id,kind,loyalty_model,active,
  earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,
  expiry_mode
) values(
  :'config',:'business','points','points_tiers',true,1,40,0,
  'points_earned','none'
);
insert into public.loyalty_rewards(
  id,business_id,name,cost_points,credit_cents,active,internal_name,
  customer_name,fulfillment_kind,estimated_cost_cents
) values(
  :'reward',:'business','V89 Race Reward',40,0,true,'V89 Race Reward',
  'V89 Race Reward','manual_item',0
);
insert into public.loyalty_reward_versions(
  id,reward_id,business_id,config_version_id,internal_name,customer_name,
  fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active
) values(
  :'reward_version',:'reward',:'business',:'config','V89 Race Reward',
  'V89 Race Reward','manual_item',40,0,0,true
);
select set_config('request.jwt.claims','',false) \gset
update public.firm_config_versions
   set status='published',published_at=now()
 where id=:'config';
insert into public.loyalty_programs(
  business_id,kind,active,loyalty_model,configuration_status,
  current_config_version_id
) values(
  :'business','points',true,'points_tiers','published',:'config'
) on conflict(business_id) do update set
  active=true,loyalty_model='points_tiers',configuration_status='published',
  current_config_version_id=excluded.current_config_version_id;
select set_config('app.v79_system_transition','on',false) \gset
update public.businesses set active_config_version_id=:'config'
 where id=:'business';
select set_config('app.v79_system_transition','',false) \gset
set role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('sub',:'owner','role','authenticated')::text,
  false
) \gset
select public.adjust_points(
  :'business',:'client',100,'v89 concurrency funding'
) as funded_result \gset
reset role;
set role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('sub',:'customer','role','authenticated')::text,
  false
) \gset
select public.customer_create_redemption_intent_v89(
  :'business',:'reward',gen_random_uuid()
)->>'qr_token' as qr_token \gset
reset role;
select :'client',:'reward',:'qr_token';
SQL
)"
IFS='|' read -r client reward qr_token <<EOF
$redemption_fixture
EOF

if psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
  -v owner="$owner" -v business="$business" -v branch="$foreign_branch" \
  -v token="$qr_token" >"$work_dir/cross-tenant-branch" 2>&1 <<'SQL'
set role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('sub',:'owner','role','authenticated')::text,
  false
);
select public.merchant_scan_redemption_qr_v117(
  :'business',:'branch',:'token',gen_random_uuid()
)::text;
SQL
then
  echo "cross-tenant branch was allowed to scan a redemption" >&2
  exit 1
fi

cross_tenant_proof="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v business="$business" -v client="$client" -v token="$qr_token" <<'SQL'
select
  (select status from public.customer_redemption_intents_v89
    where business_id=:'business' and token_hash=app.v89_sha256(:'token')),
  (select count(*) from public.loyalty_redemptions
    where business_id=:'business' and client_id=:'client'),
  (select coalesce(sum(points),0) from public.points_ledger
    where business_id=:'business' and client_id=:'client');
SQL
)"
[ "$cross_tenant_proof" = "pending|0|100" ] || {
  echo "cross-tenant branch denial changed redemption state or balance ($cross_tenant_proof)" >&2
  exit 1
}

scan_once() {
  output="$1"
  psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v owner="$owner" -v business="$business" -v branch="$branch" \
    -v token="$qr_token" \
    >"$output" 2>&1 <<'SQL'
set role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('sub',:'owner','role','authenticated')::text,
  false
);
select public.merchant_scan_redemption_qr_v117(
  :'business',:'branch',:'token',gen_random_uuid()
)::text;
SQL
}

i=1
scan_failed=0
while [ "$i" -le 100 ]; do
  pids=""
  batch_size=0
  while [ "$batch_size" -lt 20 ] && [ "$i" -le 100 ]; do
    scan_once "$work_dir/scan-$i" &
    pids="$pids $!"
    i=$((i+1))
    batch_size=$((batch_size+1))
  done
  for pid in $pids; do
    if ! wait "$pid"; then scan_failed=1; fi
  done
done
if [ "$scan_failed" -ne 0 ]; then
  grep -h -E 'ERROR|DETAIL|CONTEXT|psql:' "$work_dir"/scan-* >&2 || true
  exit 1
fi

scan_proof="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v business="$business" -v client="$client" <<'SQL'
select
  (select count(*) from public.loyalty_redemptions
    where business_id=:'business' and client_id=:'client'),
  (select coalesce(sum(points),0) from public.points_ledger
    where business_id=:'business' and client_id=:'client'),
  (select count(*) from public.customer_redemption_intents_v89
    where business_id=:'business' and client_id=:'client'
      and status='completed'),
  (select count(*) from public.customer_redemption_events_v89
    where business_id=:'business' and event_type='scan_completed');
SQL
)"
[ "$scan_proof" = "1|60|1|1" ] || {
  echo "100-way scan invariant failed (redemption|points|intent|completion=$scan_proof)" >&2
  exit 1
}

cancel_race_fixture="$(psql "$DATABASE_URL" -X -qAt -F '|' \
  -v ON_ERROR_STOP=1 -v business="$business" -v customer="$customer" \
  -v reward="$reward" <<'SQL'
set role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('sub',:'customer','role','authenticated')::text,
  false
) \gset
select result->>'intent_id',result->>'qr_token'
from (
  select public.customer_create_redemption_intent_v89(
    :'business',:'reward',gen_random_uuid()
  ) result
) created;
SQL
)"
IFS='|' read -r cancel_race_intent cancel_race_token <<EOF
$cancel_race_fixture
EOF

cancel_race_once() {
  psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v customer="$customer" -v intent="$cancel_race_intent" \
    >"$work_dir/cancel-race" 2>&1 <<'SQL'
set role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('sub',:'customer','role','authenticated')::text,
  false
);
select public.customer_cancel_redemption_intent_v89(
  :'intent',gen_random_uuid()
)::text;
SQL
}

scan_race_once() {
  psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
    -v owner="$owner" -v business="$business" -v branch="$branch" \
    -v token="$cancel_race_token" \
    >"$work_dir/scan-race" 2>&1 <<'SQL'
set role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('sub',:'owner','role','authenticated')::text,
  false
);
select public.merchant_scan_redemption_qr_v117(
  :'business',:'branch',:'token',gen_random_uuid()
)::text;
SQL
}

cancel_race_once & cancel_pid=$!
scan_race_once & scan_pid=$!
race_successes=0
if wait "$cancel_pid"; then race_successes=$((race_successes+1)); fi
if wait "$scan_pid"; then race_successes=$((race_successes+1)); fi
[ "$race_successes" -eq 1 ] || {
  echo "cancel-vs-scan race expected exactly one successful writer, got $race_successes" >&2
  cat "$work_dir/cancel-race" "$work_dir/scan-race" >&2
  exit 1
}

race_proof="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v intent="$cancel_race_intent" -v business="$business" -v client="$client" <<'SQL'
select
  (select status from public.customer_redemption_intents_v89 where id=:'intent'),
  (select count(*) from public.loyalty_redemptions
    where business_id=:'business' and client_id=:'client'),
  (select coalesce(sum(points),0) from public.points_ledger
    where business_id=:'business' and client_id=:'client'),
  (select count(*) from public.customer_redemption_events_v89
    where intent_id=:'intent' and event_type in('intent_cancelled','scan_completed'));
SQL
)"
case "$race_proof" in
  cancelled\|1\|60\|1|completed\|2\|20\|1) ;;
  *)
    echo "cancel-vs-scan invariant failed (status|redemptions|points|terminal-events=$race_proof)" >&2
    exit 1
    ;;
esac

echo "v89 QR claims (25), redemption scans (100), and cancel-vs-scan race: PASS; reset disposable DB."
