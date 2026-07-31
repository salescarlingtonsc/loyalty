#!/bin/sh
# True two-session v112 race harness. Run only against local/disposable data.
# It proves exact concurrent request replay and canonical-record serialization
# for v106 source ingestion, v108 dismissal, and v109 cost-rule writes.
set -eu

if [ "${V112_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V112_CONFIRM_DISPOSABLE_DB=YES." >&2
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
# Supabase's local `postgres` login is intentionally NOSUPERUSER, so the
# SUSET deadlock_timeout cannot be overridden by this harness. Keep every
# session bounded explicitly and require the server's deadlock detector to be
# no slower than five seconds (the local image defaults to one second).
export PGOPTIONS="-c statement_timeout=15000 -c lock_timeout=5000"
q() { psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 "$@"; }

database_fingerprint="$(q -F '|' -c "
  select current_database(),coalesce(inet_server_addr()::text,'local'),
         inet_server_port()
")"
deadlock_timeout_ms="$(q -c "
  select setting::numeric
  from pg_catalog.pg_settings
  where name='deadlock_timeout' and unit='ms'
")"
if [ -z "$deadlock_timeout_ms" ] \
  || [ "$deadlock_timeout_ms" -le 0 ] \
  || [ "$deadlock_timeout_ms" -gt 5000 ]; then
  echo "Refusing to run without a bounded server deadlock timeout (<= 5s)." >&2
  exit 2
fi
case "$database_fingerprint" in
  *v112*|*rehearsal*|*test*|*shadow*) ;;
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
  where oid='public.concurrent_operation_receipts_v112'::regclass
")" != "1" ]; then
  echo "v112 receipt table is not installed." >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nestly-v112-concurrency.XXXXXX")"
harness_lock_dir="${TMPDIR:-/tmp}/nestly-v112-concurrency.lock"
held_dispatch_restore="$work_dir/restore-held-dispatches.sql"
business=""
dispatch=""
growth_flag_before=""
economics_flag_before=""

lock_wait=0
while ! mkdir "$harness_lock_dir" 2>/dev/null; do
  lock_wait=$((lock_wait + 1))
  if [ "$lock_wait" -ge 30 ]; then
    echo "Another v112 concurrency harness still owns the local test lock." >&2
    rm -f "$work_dir"/*
    rmdir "$work_dir" 2>/dev/null || true
    exit 2
  fi
  sleep 1
done
printf '%s\n' "$$" >"$harness_lock_dir/pid"

cleanup() {
  status="$1"
  set +e
  trap - EXIT HUP INT TERM
  # Receipts are deliberately immutable evidence and therefore cannot be
  # deleted by a cleanup path. Ensure this run leaves no claimable mutable
  # dispatch behind, then restore every pre-existing due row held aside.
  if [ -n "$business" ] && [ -n "$dispatch" ]; then
    q -c "
      select set_config('app.growth_delivery_v110_transition','on',true);
      update public.growth_delivery_dispatches_v110
      set scheduled_for=statement_timestamp()+interval '100 years',
          next_attempt_at=statement_timestamp()+interval '100 years',
          updated_at=statement_timestamp()
      where id='$dispatch'
        and lifecycle_status in ('queued','scheduled');
    " >/dev/null 2>&1 || true
  fi
  if [ -s "$held_dispatch_restore" ]; then
    q -f "$held_dispatch_restore" >/dev/null 2>&1 || true
  fi
  if [ -n "$growth_flag_before" ] && [ -n "$economics_flag_before" ]; then
    q -v growth_flag_before="$growth_flag_before" \
      -v economics_flag_before="$economics_flag_before" <<'SQL' \
      >/dev/null 2>&1 || true
update app.platform_feature_flags
   set enabled=case feature_key
     when 'growth_closed_loop_v108' then :'growth_flag_before'::boolean
     when 'economics_driver_policy_v109' then :'economics_flag_before'::boolean
     else enabled
   end
 where feature_key in (
   'growth_closed_loop_v108','economics_driver_policy_v109'
 );
SQL
  fi
  if [ "$status" -ne 0 ]; then
    echo "V112 harness failed; recent session evidence follows." >&2
    for evidence_file in "$work_dir"/*.raw; do
      [ -f "$evidence_file" ] || continue
      echo "--- $(basename "$evidence_file")" >&2
      tail -n 20 "$evidence_file" >&2 || true
    done
  fi
  rm -f "$work_dir"/*
  rmdir "$work_dir" 2>/dev/null || true
  rm -f "$harness_lock_dir/pid"
  rmdir "$harness_lock_dir" 2>/dev/null || true
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' HUP INT TERM

# The service claim contract is intentionally a global queue. Hold aside any
# pre-existing due work so LIMIT 1 races can only select this harness's target,
# while writing exact restoration statements for the exit trap.
q -c "
  select format(
    'select set_config(''app.growth_delivery_v110_transition'',''on'',true);'
    || ' update public.growth_delivery_dispatches_v110'
    || ' set scheduled_for=%L::timestamptz,next_attempt_at=%L::timestamptz,'
    || ' updated_at=%L::timestamptz'
    || ' where id=%L::uuid and lifecycle_status in (''queued'',''scheduled'');',
    scheduled_for,next_attempt_at,updated_at,id
  )
  from public.growth_delivery_dispatches_v110
  where lifecycle_status in ('queued','scheduled')
    and scheduled_for <= statement_timestamp()
    and next_attempt_at <= statement_timestamp()
" >"$held_dispatch_restore"
q -c "
  select set_config('app.growth_delivery_v110_transition','on',true);
  update public.growth_delivery_dispatches_v110
  set next_attempt_at=statement_timestamp()+interval '100 years',
      updated_at=statement_timestamp()
  where lifecycle_status in ('queued','scheduled')
    and scheduled_for <= statement_timestamp()
    and next_attempt_at <= statement_timestamp();
" >/dev/null

growth_flag_before="$(q -c "
  select enabled::text from app.platform_feature_flags
  where feature_key='growth_closed_loop_v108'
")"
economics_flag_before="$(q -c "
  select enabled::text from app.platform_feature_flags
  where feature_key='economics_driver_policy_v109'
")"

ids="$(q -F '|' -c "
  select gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid(),gen_random_uuid()
")"
old_ifs="$IFS"
IFS='|'
set -- $ids
IFS="$old_ifs"
super_admin="$1"
owner="$2"
owner_staff="$3"
business="$4"
branch="$5"
recommendation="$6"
customer_user="${7}"
identity="${8}"
client="${9}"
link="${10}"
delivery_recommendation="${11}"
recommendation_member="${12}"
execution="${13}"
execution_member="${14}"
delivery="${15}"
prefix="${business%%-*}"
super_email="v112-concurrency-sa-$prefix@example.test"
owner_email="v112-concurrency-owner-$prefix@example.test"
customer_email="v112-concurrency-customer-$prefix@example.test"
source_system="v112.concurrency.$prefix"

q -v super_admin="$super_admin" -v owner="$owner" \
  -v owner_staff="$owner_staff" -v business="$business" \
  -v branch="$branch" -v recommendation="$recommendation" \
  -v customer_user="$customer_user" -v identity="$identity" \
  -v client="$client" -v link="$link" \
  -v delivery_recommendation="$delivery_recommendation" \
  -v recommendation_member="$recommendation_member" \
  -v execution="$execution" -v execution_member="$execution_member" \
  -v delivery="$delivery" -v super_email="$super_email" \
  -v owner_email="$owner_email" -v customer_email="$customer_email" \
  <<'SQL' >/dev/null
begin;
insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  created_at,updated_at
) values
(
  '00000000-0000-0000-0000-000000000000',:'super_admin','authenticated',
  'authenticated',:'super_email','',now(),now(),now()
),(
  '00000000-0000-0000-0000-000000000000',:'owner','authenticated',
  'authenticated',:'owner_email','',now(),now(),now()
),(
  '00000000-0000-0000-0000-000000000000',:'customer_user',
  'authenticated','authenticated',:'customer_email','',now(),now(),now()
);
insert into public.super_admins(user_id,email,note)
values(:'super_admin',:'super_email','v112 two-session fixture');
insert into public.businesses(
  id,name,slug,currency,industry,enabled_modules,is_synthetic
) values(
  :'business','V112 two-session concurrency',
  'v112-concurrency-'||:'business','SGD','facial',
  array['dashboard','clients','sales','reports','pnl','retention'],true
);
update public.business_workspace_controls_v94
   set approval_status='approved',
       version=version+1,
       decided_at=statement_timestamp(),
       decision_reason='approved synthetic concurrency fixture',
       updated_at=statement_timestamp()
 where business_id=:'business'
   and approval_status='pending';
insert into public.branches(id,business_id,name,timezone,is_default)
values(:'branch',:'business','V112 Singapore','Asia/Singapore',true);
insert into public.staff(
  id,business_id,user_id,role,full_name,email,active
) values(
  :'owner_staff',:'business',:'owner','owner','V112 Owner',:'owner_email',true
);
update app.platform_feature_flags
set enabled=true
where feature_key in (
  'growth_closed_loop_v108','economics_driver_policy_v109'
);
insert into public.growth_recommendations_v108(
  id,business_id,branch_id,recommendation_type,policy_version,
  generated_at,valid_until,observation_start,observation_end,
  comparison_start,comparison_end,finding,supporting_evidence,
  baseline,opportunity,expected_incremental_revenue,
  expected_incremental_gross_profit,confidence,assumptions,
  recommended_action,recommended_channel,recommended_offer,
  estimated_cost_cents,audience_size,excluded_size,
  frequency_cap_days,approval_required,success_metric,
  attribution_window_days,holdout_percent,stop_conditions,status,
  suppression_reasons,data_freshness_at,data_coverage,dedupe_key,created_by
) values(
  :'recommendation',:'business',:'branch',
  'lapsed_high_value_bring_back','bring_back_v1',
  statement_timestamp(),statement_timestamp()+interval '1 day',
  statement_timestamp()-interval '180 days',statement_timestamp(),
  statement_timestamp()-interval '360 days',
  statement_timestamp()-interval '180 days',
  'V112 concurrent dismissal evidence','[]','{}','{}','{}',null,
  '{}','[]','{}','in_app','{}',300,10,0,30,true,
  'incremental_completed_purchase_revenue',14,20,'{}','presented','[]',
  statement_timestamp(),'{}',
  encode(
    extensions.digest(
      convert_to(gen_random_uuid()::text,'UTF8'),'sha256'
    ),
    'hex'
  ),
  :'owner'
);
insert into public.clients(
  id,business_id,full_name,email,marketing_consent,is_synthetic
) values(
  :'client',:'business','V112 Callback Customer',:'customer_email',true,true
);
insert into public.customer_identities(
  id,auth_user_id,status,created_via
) values(
  :'identity',:'customer_user','active','phone_registration'
);
select set_config('app.customer_link_insert_id', :'link', true);
insert into public.customer_links(
  id,business_id,identity_id,auth_user_id,client_id,state,
  verification_method,verified_at
) values(
  :'link',:'business',:'identity',:'customer_user',:'client','verified',
  'qr_join',statement_timestamp()-interval '30 days'
);
select set_config('app.customer_link_insert_id', '', true);
insert into public.customer_notification_preferences(
  business_id,identity_id,auth_user_id,link_id,client_id,
  channel,topic,opted_in,consent_at
) values(
  :'business',:'identity',:'customer_user',:'link',:'client',
  'in_app','marketing',true,statement_timestamp()-interval '30 days'
);
insert into public.growth_recommendations_v108(
  id,business_id,branch_id,recommendation_type,policy_version,
  generated_at,valid_until,observation_start,observation_end,
  comparison_start,comparison_end,finding,supporting_evidence,
  baseline,opportunity,expected_incremental_revenue,
  expected_incremental_gross_profit,confidence,assumptions,
  recommended_action,recommended_channel,recommended_offer,
  estimated_cost_cents,audience_size,excluded_size,
  frequency_cap_days,approval_required,success_metric,
  attribution_window_days,holdout_percent,stop_conditions,status,
  suppression_reasons,data_freshness_at,data_coverage,dedupe_key,created_by
) values(
  :'delivery_recommendation',:'business',:'branch',
  'lapsed_high_value_bring_back','bring_back_v1',
  statement_timestamp(),statement_timestamp()+interval '1 day',
  statement_timestamp()-interval '180 days',statement_timestamp(),
  statement_timestamp()-interval '360 days',
  statement_timestamp()-interval '180 days',
  'V112 callback evidence','[]','{}','{}','{}',null,
  '{}','[]','{}','in_app','{}',300,10,0,30,true,
  'incremental_completed_purchase_revenue',14,20,'{}','executed','[]',
  statement_timestamp(),'{}',
  encode(
    extensions.digest(
      convert_to(gen_random_uuid()::text,'UTF8'),'sha256'
    ),
    'hex'
  ),
  :'owner'
);
insert into public.growth_recommendation_members_v108(
  id,recommendation_id,business_id,client_id,eligible,
  prior_visits,last_visit_at,cadence_days,lapse_days,
  average_transaction_cents,historical_revenue_cents,evidence
) values(
  :'recommendation_member',:'delivery_recommendation',:'business',:'client',
  true,3,statement_timestamp()-interval '60 days',14,60,3000,9000,'{}'
);
insert into public.growth_executions_v108(
  id,recommendation_id,business_id,branch_id,
  channel,offer_type,offer_value_cents,offer_label,currency,
  offer_timezone,offer_expires_at,
  governed_copy_schema,governed_copy_version,governed_copy,
  budget_cap_cents,holdout_percent,attribution_window_days,
  minimum_arm_size,status,approved_by,approved_at,
  started_at,ends_at,idempotency_key,request_hash
) values(
  :'execution',:'delivery_recommendation',:'business',:'branch',
  'in_app','credit_cents',300,'member_thank_you','SGD',
  'Asia/Singapore',statement_timestamp()+interval '7 days',
  'nestly.growth_offer_copy',1,
  jsonb_build_object(
    'schema','nestly.growth_offer_copy','version',1,
    'title','A thank-you reward is ready',
    'body','Enjoy SGD 3.00 off before the offer expires.',
    'cta_label','Redeem now',
    'cta_destination','customer_growth_offer_qr',
    'eligibility',jsonb_build_object(
      'business_id',:'business','branch_id',:'branch'
    ),
    'conditions',jsonb_build_object(
      'expires_at',statement_timestamp()+interval '7 days',
      'timezone','Asia/Singapore'
    ),
    'locked_facts',jsonb_build_object(
      'template_id','member_thank_you','offer_value_cents',300,
      'currency','SGD',
      'expires_at',statement_timestamp()+interval '7 days',
      'timezone','Asia/Singapore'
    )
  ),
  10000,20,14,3,'running',:'owner',statement_timestamp(),
  statement_timestamp(),statement_timestamp()+interval '14 days',
  gen_random_uuid(),
  encode(
    extensions.digest(
      convert_to(gen_random_uuid()::text,'UTF8'),'sha256'
    ),
    'hex'
  )
);
insert into public.growth_execution_members_v108(
  id,execution_id,business_id,recommendation_member_id,client_id,
  assignment,assignment_rank,assignment_score
) values(
  :'execution_member',:'execution',:'business',:'recommendation_member',
  :'client','treatment',1,
  encode(
    extensions.digest(
      convert_to(:'execution'||':'||:'client','UTF8'),'sha256'
    ),
    'hex'
  )
);
insert into public.growth_deliveries_v108(
  id,execution_id,execution_member_id,business_id,client_id,
  identity_id,link_id,assignment,channel,delivery_status,
  title,body,estimated_cost_cents,delivered_at
) values(
  :'delivery',:'execution',:'execution_member',:'business',:'client',
  :'identity',:'link','treatment','in_app','delivered',
  'intercepted by v110','intercepted by v110',300,statement_timestamp()
);
commit;
SQL

normalize() {
  # set_config emits the JWT claims as JSON before the RPC receipt. Select the
  # final JSON line so the comparison proves byte-identical RPC responses.
  awk '/\{.*\}/ { line=$0 } END { if (line != "") print line }' "$1" > "$2"
}
assert_equal_files() {
  if ! cmp -s "$1" "$2"; then
    echo "Concurrent receipts differ:" >&2
    sed -n '1p' "$1" >&2
    sed -n '1p' "$2" >&2
    exit 1
  fi
}

event_time="$(q -c "select clock_timestamp()+interval '1 second'")"

# Same v106 request in two overlapping transactions: the second waits and
# returns the byte-identical first receipt.
same_request_key="v112-same-$prefix"
cat >"$work_dir/v106-same-a.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$super_admin','role','authenticated')::text,true
);
set local role authenticated;
select public.ingest_external_commerce_event_v106(
  '$business','$branch','transaction_completed','$source_system',
  'source-same','$same_request_key','$event_time','SGD',1200,
  '{"fixture":"same"}'
);
select pg_sleep(2);
commit;
SQL
cat >"$work_dir/v106-same-b.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$super_admin','role','authenticated')::text,true
);
set local role authenticated;
select public.ingest_external_commerce_event_v106(
  '$business','$branch','transaction_completed','$source_system',
  'source-same','$same_request_key','$event_time','SGD',1200,
  '{"fixture":"same"}'
);
commit;
SQL
q -f "$work_dir/v106-same-a.sql" >"$work_dir/v106-same-a.raw" 2>&1 &
pid_a=$!
sleep 0.25
q -f "$work_dir/v106-same-b.sql" >"$work_dir/v106-same-b.raw" 2>&1
wait "$pid_a"
normalize "$work_dir/v106-same-a.raw" "$work_dir/v106-same-a.out"
normalize "$work_dir/v106-same-b.raw" "$work_dir/v106-same-b.out"
assert_equal_files "$work_dir/v106-same-a.out" "$work_dir/v106-same-b.out"
if ! grep -q '"status": "accepted"' "$work_dir/v106-same-a.out"; then
  echo "Concurrent v106 same-request result was not accepted." >&2
  exit 1
fi

# Different request keys for one canonical source serialize on the source lock.
cat >"$work_dir/v106-source-a.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$super_admin','role','authenticated')::text,true
);
set local role authenticated;
select public.ingest_external_commerce_event_v106(
  '$business','$branch','transaction_completed','$source_system',
  'source-shared','source-key-a-$prefix','$event_time','SGD',1300,
  '{"fixture":"source-shared"}'
);
select pg_sleep(2);
commit;
SQL
cat >"$work_dir/v106-source-b.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$super_admin','role','authenticated')::text,true
);
set local role authenticated;
select public.ingest_external_commerce_event_v106(
  '$business','$branch','transaction_completed','$source_system',
  'source-shared','source-key-b-$prefix','$event_time','SGD',1300,
  '{"fixture":"source-shared"}'
);
commit;
SQL
q -f "$work_dir/v106-source-a.sql" >"$work_dir/v106-source-a.raw" 2>&1 &
pid_a=$!
sleep 0.25
q -f "$work_dir/v106-source-b.sql" >"$work_dir/v106-source-b.raw" 2>&1
wait "$pid_a"
normalize "$work_dir/v106-source-a.raw" "$work_dir/v106-source-a.out"
normalize "$work_dir/v106-source-b.raw" "$work_dir/v106-source-b.out"
if ! grep -q '"status": "accepted"' "$work_dir/v106-source-a.out" \
   || ! grep -q '"status": "replayed"' "$work_dir/v106-source-b.out"; then
  echo "Concurrent v106 canonical-source replay did not serialize." >&2
  exit 1
fi
if [ "$(q -c "
  select count(*) from public.commerce_events_v106
  where business_id='$business'
    and source_system='$source_system'
    and source_event_id='source-shared'
")" != "1" ]; then
  echo "Concurrent v106 canonical source created duplicate events." >&2
  exit 1
fi

# Same v108 dismissal request in two sessions: one decision and exact receipt.
dismiss_key="$(q -c 'select gen_random_uuid()')"
cat >"$work_dir/v108-a.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$owner','role','authenticated')::text,true
);
set local role authenticated;
select public.dismiss_growth_recommendation_v108(
  '$business','$recommendation','not this month','$dismiss_key'
);
select pg_sleep(2);
commit;
SQL
cat >"$work_dir/v108-b.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$owner','role','authenticated')::text,true
);
set local role authenticated;
select public.dismiss_growth_recommendation_v108(
  '$business','$recommendation','not this month','$dismiss_key'
);
commit;
SQL
q -f "$work_dir/v108-a.sql" >"$work_dir/v108-a.raw" 2>&1 &
pid_a=$!
sleep 0.25
q -f "$work_dir/v108-b.sql" >"$work_dir/v108-b.raw" 2>&1
wait "$pid_a"
normalize "$work_dir/v108-a.raw" "$work_dir/v108-a.out"
normalize "$work_dir/v108-b.raw" "$work_dir/v108-b.out"
assert_equal_files "$work_dir/v108-a.out" "$work_dir/v108-b.out"
if [ "$(q -c "
  select count(*) from public.growth_recommendation_decisions_v108
  where recommendation_id='$recommendation'
")" != "1" ]; then
  echo "Concurrent v108 dismissal created duplicate decisions." >&2
  exit 1
fi

# Same v109 cost-rule request in two sessions: one version and exact receipt.
cost_key="$(q -c 'select gen_random_uuid()')"
cat >"$work_dir/v109-a.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$owner','role','authenticated')::text,true
);
set local role authenticated;
select public.set_effective_cost_rule_v109(
  '$business','$branch','sale_kind','quick_sale','revenue_bps',4000,
  'supplier_invoice','INV-V112-CONCURRENCY',
  '{"fixture":true,"currency":"SGD"}','2026-07-01 00:00+00','$cost_key'
);
select pg_sleep(2);
commit;
SQL
cat >"$work_dir/v109-b.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$owner','role','authenticated')::text,true
);
set local role authenticated;
select public.set_effective_cost_rule_v109(
  '$business','$branch','sale_kind','quick_sale','revenue_bps',4000,
  'supplier_invoice','INV-V112-CONCURRENCY',
  '{"fixture":true,"currency":"SGD"}','2026-07-01 00:00+00','$cost_key'
);
commit;
SQL
q -f "$work_dir/v109-a.sql" >"$work_dir/v109-a.raw" 2>&1 &
pid_a=$!
sleep 0.25
q -f "$work_dir/v109-b.sql" >"$work_dir/v109-b.raw" 2>&1
wait "$pid_a"
normalize "$work_dir/v109-a.raw" "$work_dir/v109-a.out"
normalize "$work_dir/v109-b.raw" "$work_dir/v109-b.out"
assert_equal_files "$work_dir/v109-a.out" "$work_dir/v109-b.out"
if [ "$(q -c "
  select count(*) from public.economic_cost_rules_v109
  where business_id='$business' and branch_id='$branch'
    and scope_kind='sale_kind' and scope_key='quick_sale'
")" != "1" ]; then
  echo "Concurrent v109 request created duplicate cost versions." >&2
  exit 1
fi

# Same v110 claim request in two sessions: the second waits for the immutable
# first batch receipt, even though the claimed row has already moved to
# delivering. Changed limit/worker payloads conflict on the same key.
dispatch="$(q -c "
  select id from public.growth_delivery_dispatches_v110
  where delivery_id='$delivery'
")"
claim_key="$(q -c 'select gen_random_uuid()')"
cat >"$work_dir/v110-claim-a.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('role','service_role')::text,true
);
set local role service_role;
select public.service_claim_growth_deliveries_v110(
  100,'v112-concurrency-worker','$claim_key'
);
select pg_sleep(2);
commit;
SQL
cat >"$work_dir/v110-claim-b.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('role','service_role')::text,true
);
set local role service_role;
select public.service_claim_growth_deliveries_v110(
  100,'v112-concurrency-worker','$claim_key'
);
commit;
SQL
q -f "$work_dir/v110-claim-a.sql" >"$work_dir/v110-claim-a.raw" 2>&1 &
pid_a=$!
sleep 0.25
q -f "$work_dir/v110-claim-b.sql" >"$work_dir/v110-claim-b.raw" 2>&1
wait "$pid_a"
normalize "$work_dir/v110-claim-a.raw" "$work_dir/v110-claim-a.out"
normalize "$work_dir/v110-claim-b.raw" "$work_dir/v110-claim-b.out"
assert_equal_files "$work_dir/v110-claim-a.out" "$work_dir/v110-claim-b.out"
if ! grep -q "\"dispatch_id\": \"$dispatch\"" \
  "$work_dir/v110-claim-a.out"; then
  echo "Concurrent v110 claim did not return the seeded dispatch." >&2
  exit 1
fi
if [ "$(q -c "
  select lifecycle_status from public.growth_delivery_dispatches_v110
  where id='$dispatch'
")" != "delivering" ]; then
  echo "V112 callback dispatch was not claimed for delivery." >&2
  exit 1
fi
if q <<SQL >/dev/null 2>&1
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('role','service_role')::text,true
);
set local role service_role;
select public.service_claim_growth_deliveries_v110(
  99,'v112-concurrency-worker','$claim_key'
);
commit;
SQL
then
  echo "V112 claim accepted a changed limit for the same request key." >&2
  exit 1
fi
if q <<SQL >/dev/null 2>&1
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('role','service_role')::text,true
);
set local role service_role;
select public.service_claim_growth_deliveries_v110(
  100,'v112-concurrency-worker-changed','$claim_key'
);
commit;
SQL
then
  echo "V112 claim accepted a changed worker for the same request key." >&2
  exit 1
fi

# Same v110 provider callback in two sessions: the outer callback and its
# transition both serialize on the dispatch identity and replay one receipt.
callback_key="$(q -c 'select gen_random_uuid()')"
cat >"$work_dir/v110-a.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('role','service_role')::text,true
);
set local role service_role;
select public.service_complete_growth_delivery_v110(
  '$dispatch',null,false,'provider_timeout','$callback_key'
);
select pg_sleep(2);
commit;
SQL
cat >"$work_dir/v110-b.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('role','service_role')::text,true
);
set local role service_role;
select public.service_complete_growth_delivery_v110(
  '$dispatch',null,false,'provider_timeout','$callback_key'
);
commit;
SQL
q -f "$work_dir/v110-a.sql" >"$work_dir/v110-a.raw" 2>&1 &
pid_a=$!
sleep 0.25
q -f "$work_dir/v110-b.sql" >"$work_dir/v110-b.raw" 2>&1
wait "$pid_a"
normalize "$work_dir/v110-a.raw" "$work_dir/v110-a.out"
normalize "$work_dir/v110-b.raw" "$work_dir/v110-b.out"
assert_equal_files "$work_dir/v110-a.out" "$work_dir/v110-b.out"
if [ "$(q -c "
  select count(*) from public.growth_delivery_state_events_v110
  where dispatch_id='$dispatch' and idempotency_key='$callback_key'
")" != "1" ]; then
  echo "Concurrent v110 callback created duplicate state events." >&2
  exit 1
fi

# Cross-path lock-order proof. Each pair deliberately overlaps two sessions on
# the same dispatch. The first session holds the canonical dispatch advisory
# lock while the second enters the competing public RPC. Before this fix, the
# callback-first cases deadlocked when claim/retry/cancel took the row first.
reset_dispatch() {
  reset_state="$1"
  case "$reset_state" in queued|failed|delivering) ;; *)
    echo "Unsupported v112 race reset state: $reset_state" >&2
    exit 2
  esac
  if [ -n "$dispatch" ]; then
    q -c "
      select set_config('app.growth_delivery_v110_transition','on',true);
      update public.growth_delivery_dispatches_v110
      set next_attempt_at=statement_timestamp()+interval '100 years',
          updated_at=statement_timestamp()
      where id='$dispatch'
        and lifecycle_status in ('queued','scheduled');
    " >/dev/null
  fi
  fresh_ids="$(q -F '|' -c "
    select gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
           gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
           gen_random_uuid()
  ")"
  old_ifs="$IFS"
  IFS='|'
  set -- $fresh_ids
  IFS="$old_ifs"
  customer_user="$1"
  identity="$2"
  client="$3"
  link="$4"
  recommendation_member="$5"
  execution_member="$6"
  delivery="$7"
  fresh_email="v112-race-${client%%-*}@example.test"
  q -v customer_user="$customer_user" -v identity="$identity" \
    -v client="$client" -v link="$link" \
    -v recommendation_member="$recommendation_member" \
    -v execution_member="$execution_member" -v delivery="$delivery" \
    -v execution="$execution" -v recommendation="$delivery_recommendation" \
    -v business="$business" -v fresh_email="$fresh_email" \
    <<'SQL' >/dev/null
begin;
insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  created_at,updated_at
) values(
  '00000000-0000-0000-0000-000000000000',:'customer_user',
  'authenticated','authenticated',:'fresh_email','',now(),now(),now()
);
insert into public.clients(
  id,business_id,full_name,email,marketing_consent,is_synthetic
) values(
  :'client',:'business','V112 Race Customer',:'fresh_email',true,true
);
insert into public.customer_identities(id,auth_user_id,status,created_via)
values(:'identity',:'customer_user','active','phone_registration');
select set_config('app.customer_link_insert_id', :'link', true);
insert into public.customer_links(
  id,business_id,identity_id,auth_user_id,client_id,state,
  verification_method,verified_at
) values(
  :'link',:'business',:'identity',:'customer_user',:'client','verified',
  'qr_join',statement_timestamp()-interval '30 days'
);
select set_config('app.customer_link_insert_id', '', true);
insert into public.customer_notification_preferences(
  business_id,identity_id,auth_user_id,link_id,client_id,
  channel,topic,opted_in,consent_at
) values(
  :'business',:'identity',:'customer_user',:'link',:'client',
  'in_app','marketing',true,statement_timestamp()-interval '30 days'
);
insert into public.growth_recommendation_members_v108(
  id,recommendation_id,business_id,client_id,eligible,
  prior_visits,last_visit_at,cadence_days,lapse_days,
  average_transaction_cents,historical_revenue_cents,evidence
) values(
  :'recommendation_member',:'recommendation',:'business',:'client',
  true,3,statement_timestamp()-interval '60 days',14,60,3000,9000,'{}'
);
insert into public.growth_execution_members_v108(
  id,execution_id,business_id,recommendation_member_id,client_id,
  assignment,assignment_rank,assignment_score
) values(
  :'execution_member',:'execution',:'business',:'recommendation_member',
  :'client','treatment',1,
  encode(
    extensions.digest(
      convert_to(:'execution'||':'||:'client','UTF8'),'sha256'
    ),
    'hex'
  )
);
insert into public.growth_deliveries_v108(
  id,execution_id,execution_member_id,business_id,client_id,
  identity_id,link_id,assignment,channel,delivery_status,
  title,body,estimated_cost_cents,delivered_at
) values(
  :'delivery',:'execution',:'execution_member',:'business',:'client',
  :'identity',:'link','treatment','in_app','delivered',
  'intercepted by v110','intercepted by v110',300,statement_timestamp()
);
commit;
SQL
  dispatch="$(q -c "
    select id from public.growth_delivery_dispatches_v110
    where delivery_id='$delivery'
  ")"
  q -c "
    update public.growth_executions_v108
    set status='running',
        started_at=least(started_at,statement_timestamp()-interval '1 day'),
        offer_expires_at=greatest(
          offer_expires_at,statement_timestamp()+interval '7 days'
        ),
        ends_at=greatest(ends_at,statement_timestamp()+interval '14 days'),
        governed_copy=jsonb_set(
          jsonb_set(
            governed_copy,
            '{conditions,expires_at}',
            to_jsonb(greatest(
              offer_expires_at,statement_timestamp()+interval '7 days'
            ))
          ),
          '{locked_facts,expires_at}',
          to_jsonb(greatest(
            offer_expires_at,statement_timestamp()+interval '7 days'
          ))
        )
    where id='$execution';
  " >/dev/null
  case "$reset_state" in
    queued) ;;
    delivering)
      q -c "
        select app.v110_transition_delivery(
          '$dispatch','delivering','race_fixture_claim',null,
          gen_random_uuid(),
          jsonb_build_object('worker_id','v112-race-fixture')
        )
      " >/dev/null
      ;;
    failed)
      q -c "
        select app.v110_transition_delivery(
          '$dispatch','delivering','race_fixture_claim',null,
          gen_random_uuid(),
          jsonb_build_object('worker_id','v112-race-fixture')
        );
        select app.v110_transition_delivery(
          '$dispatch','failed','race_fixture',null,
          gen_random_uuid(),'{}'::jsonb
        )
      " >/dev/null
      ;;
  esac
}
dump_cross_state() {
  q -c "
    select jsonb_build_object(
      'dispatch',to_jsonb(dispatch),
      'delivery',to_jsonb(delivery),
      'execution',to_jsonb(execution),
      'events',coalesce((
        select jsonb_agg(to_jsonb(event) order by event.created_at,event.id)
        from public.growth_delivery_state_events_v110 event
        where event.dispatch_id=dispatch.id
      ),'[]'::jsonb),
      'receipts',coalesce((
        select jsonb_agg(to_jsonb(receipt) order by receipt.created_at)
        from public.concurrent_operation_receipts_v112 receipt
        where receipt.scope->>'dispatch_id'=dispatch.id::text
           or receipt.receipt::text like '%'||dispatch.id::text||'%'
      ),'[]'::jsonb)
    )
    from public.growth_delivery_dispatches_v110 dispatch
    join public.growth_deliveries_v108 delivery
      on delivery.id=dispatch.delivery_id
    join public.growth_executions_v108 execution
      on execution.id=dispatch.execution_id
    where dispatch.id='$dispatch'
  " >&2 || true
}
assert_dispatch_status() {
  if [ "$(q -c "
    select lifecycle_status from public.growth_delivery_dispatches_v110
    where id='$dispatch'
  ")" != "$1" ]; then
    echo "V112 cross-path race ended in the wrong state; expected $1." >&2
    dump_cross_state
    exit 1
  fi
}
assert_event_count() {
  if [ "$(q -c "
    select count(*) from public.growth_delivery_state_events_v110
    where dispatch_id='$dispatch' and idempotency_key='$1'::uuid
  ")" != "$2" ]; then
    echo "V112 cross-path event count drifted for request $1." >&2
    dump_cross_state
    exit 1
  fi
}
assert_receipt_identity() {
  if [ "$(q -c "
    select count(*) from public.concurrent_operation_receipts_v112
    where request_identity='$1'
  ")" != "$2" ]; then
    echo "V112 cross-path receipt count drifted for identity $1." >&2
    dump_cross_state
    exit 1
  fi
}

# callback starts first, claim starts second. Callback is expected to reject
# queued -> failed after it proves it can reach the row without deadlocking;
# claim then owns the only committed mutation and exact receipt.
reset_dispatch queued
race_callback_key="$(q -c 'select gen_random_uuid()')"
race_claim_key="$(q -c 'select gen_random_uuid()')"
cat >"$work_dir/v110-callback-claim-callback-first-a.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('role','service_role')::text,true
);
set local role service_role;
select pg_advisory_xact_lock(
  hashtextextended('v112-v110-dispatch:$dispatch',112)
);
select pg_sleep(0.75);
do \$race\$
begin
  perform public.service_complete_growth_delivery_v110(
    '$dispatch',null,false,'callback_first_claim','$race_callback_key'
  );
  raise exception 'queued callback unexpectedly succeeded';
exception when invalid_parameter_value then null;
end
\$race\$;
commit;
SQL
cat >"$work_dir/v110-callback-claim-callback-first-b.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('role','service_role')::text,true
);
set local role service_role;
select public.service_claim_growth_deliveries_v110(
  1,'v112-cross-claim','$race_claim_key'
);
commit;
SQL
q -f "$work_dir/v110-callback-claim-callback-first-a.sql" \
  >"$work_dir/v110-callback-claim-callback-first-a.raw" 2>&1 &
pid_a=$!
sleep 0.15
q -f "$work_dir/v110-callback-claim-callback-first-b.sql" \
  >"$work_dir/v110-callback-claim-callback-first-b.raw" 2>&1
wait "$pid_a"
assert_dispatch_status delivering
if ! grep -q "\"dispatch_id\": \"$dispatch\"" \
  "$work_dir/v110-callback-claim-callback-first-b.raw"; then
  echo "V112 callback-first/claim-second did not claim the dispatch." >&2
  exit 1
fi
if [ "$(q -c "
  select count(*) from public.concurrent_operation_receipts_v112
  where request_identity=app.v112_hash(jsonb_build_object(
    'operation','service_claim_growth_deliveries_v110',
    'idempotency_key','$race_claim_key'::uuid
  ))
")" != "1" ] || [ "$(q -c "
  select count(*) from public.concurrent_operation_receipts_v112
  where request_identity=app.v112_hash(jsonb_build_object(
    'operation','service_complete_growth_delivery_v110',
    'dispatch_id','$dispatch'::uuid,
    'idempotency_key','$race_callback_key'::uuid
  ))
")" != "0" ]; then
  echo "V112 callback-first/claim-second receipt evidence drifted." >&2
  exit 1
fi
claim_event_key="$(q -c "
  select extensions.uuid_generate_v5(
    '$race_claim_key'::uuid,'$dispatch:claim'
  )
")"
assert_event_count "$claim_event_key" 1
assert_event_count "$race_callback_key" 0

# claim starts first, callback starts second. Callback observes the committed
# delivering state, records the provider failure, and both receipts survive.
reset_dispatch queued
race_callback_key="$(q -c 'select gen_random_uuid()')"
race_claim_key="$(q -c 'select gen_random_uuid()')"
cat >"$work_dir/v110-callback-claim-claim-first-a.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('role','service_role')::text,true
);
set local role service_role;
select pg_advisory_xact_lock(
  hashtextextended('v112-v110-dispatch:$dispatch',112)
);
select public.service_claim_growth_deliveries_v110(
  1,'v112-cross-claim-first','$race_claim_key'
);
select pg_sleep(0.75);
commit;
SQL
cat >"$work_dir/v110-callback-claim-claim-first-b.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('role','service_role')::text,true
);
set local role service_role;
select public.service_complete_growth_delivery_v110(
  '$dispatch',null,false,'claim_first_callback','$race_callback_key'
);
commit;
SQL
q -f "$work_dir/v110-callback-claim-claim-first-a.sql" \
  >"$work_dir/v110-callback-claim-claim-first-a.raw" 2>&1 &
pid_a=$!
sleep 0.15
q -f "$work_dir/v110-callback-claim-claim-first-b.sql" \
  >"$work_dir/v110-callback-claim-claim-first-b.raw" 2>&1
wait "$pid_a"
assert_dispatch_status failed
for request_identity in \
  "$(q -c "select app.v112_hash(jsonb_build_object(
    'operation','service_claim_growth_deliveries_v110',
    'idempotency_key','$race_claim_key'::uuid
  ))")" \
  "$(q -c "select app.v112_hash(jsonb_build_object(
    'operation','service_complete_growth_delivery_v110',
    'dispatch_id','$dispatch'::uuid,
    'idempotency_key','$race_callback_key'::uuid
  ))")"
do
  if [ "$(q -c "
    select count(*) from public.concurrent_operation_receipts_v112
    where request_identity='$request_identity'
  ")" != "1" ]; then
    echo "V112 claim-first/callback-second receipt evidence is incomplete." >&2
    exit 1
  fi
done
claim_event_key="$(q -c "
  select extensions.uuid_generate_v5(
    '$race_claim_key'::uuid,'$dispatch:claim'
  )
")"
assert_event_count "$claim_event_key" 1
assert_event_count "$race_callback_key" 1

# callback first / retry second: the provider failure is valid from delivering;
# retry then observes failed and queues it with the deterministic backoff.
reset_dispatch delivering
race_callback_key="$(q -c 'select gen_random_uuid()')"
race_retry_key="$(q -c 'select gen_random_uuid()')"
cat >"$work_dir/v110-callback-retry-callback-first-a.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('role','service_role')::text,true
);
set local role service_role;
select pg_advisory_xact_lock(
  hashtextextended('v112-v110-dispatch:$dispatch',112)
);
select pg_sleep(0.75);
select public.service_complete_growth_delivery_v110(
  '$dispatch',null,false,'callback_first_retry','$race_callback_key'
);
commit;
SQL
cat >"$work_dir/v110-callback-retry-callback-first-b.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$owner','role','authenticated')::text,true
);
set local role authenticated;
select public.retry_growth_delivery_v110(
  '$business','$dispatch','$race_retry_key'
);
commit;
SQL
q -f "$work_dir/v110-callback-retry-callback-first-a.sql" \
  >"$work_dir/v110-callback-retry-callback-first-a.raw" 2>&1 &
pid_a=$!
sleep 0.15
if ! q -f "$work_dir/v110-callback-retry-callback-first-b.sql" \
  >"$work_dir/v110-callback-retry-callback-first-b.raw" 2>&1; then
  echo "V112 callback-first/retry-second foreground session failed." >&2
  tail -n 20 "$work_dir/v110-callback-retry-callback-first-b.raw" >&2
  exit 1
fi
wait "$pid_a"
assert_dispatch_status queued
callback_identity="$(q -c "select app.v112_hash(jsonb_build_object(
  'operation','service_complete_growth_delivery_v110',
  'dispatch_id','$dispatch'::uuid,
  'idempotency_key','$race_callback_key'::uuid
))")"
retry_identity="$(q -c "select app.v112_hash(jsonb_build_object(
  'operation','retry_growth_delivery_v110',
  'business_id','$business'::uuid,
  'dispatch_id','$dispatch'::uuid,
  'actor','$owner'::uuid,
  'idempotency_key','$race_retry_key'::uuid
))")"
assert_receipt_identity "$callback_identity" 1
assert_receipt_identity "$retry_identity" 1
assert_event_count "$race_callback_key" 1
assert_event_count "$race_retry_key" 1

# retry first / callback second: callback reaches the now-queued row without a
# deadlock, rejects queued -> failed, and leaves the retry receipt/state exact.
reset_dispatch failed
race_callback_key="$(q -c 'select gen_random_uuid()')"
race_retry_key="$(q -c 'select gen_random_uuid()')"
cat >"$work_dir/v110-callback-retry-retry-first-a.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$owner','role','authenticated')::text,true
);
set local role authenticated;
select pg_advisory_xact_lock(
  hashtextextended('v112-v110-dispatch:$dispatch',112)
);
select public.retry_growth_delivery_v110(
  '$business','$dispatch','$race_retry_key'
);
select pg_sleep(0.75);
commit;
SQL
cat >"$work_dir/v110-callback-retry-retry-first-b.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('role','service_role')::text,true
);
set local role service_role;
do \$race\$
begin
  perform public.service_complete_growth_delivery_v110(
    '$dispatch',null,false,'retry_first_callback','$race_callback_key'
  );
  raise exception 'queued callback unexpectedly succeeded';
exception when invalid_parameter_value then null;
end
\$race\$;
commit;
SQL
q -f "$work_dir/v110-callback-retry-retry-first-a.sql" \
  >"$work_dir/v110-callback-retry-retry-first-a.raw" 2>&1 &
pid_a=$!
sleep 0.15
q -f "$work_dir/v110-callback-retry-retry-first-b.sql" \
  >"$work_dir/v110-callback-retry-retry-first-b.raw" 2>&1
wait "$pid_a"
assert_dispatch_status queued
if [ "$(q -c "
  select count(*) from public.concurrent_operation_receipts_v112
  where request_identity=app.v112_hash(jsonb_build_object(
    'operation','service_complete_growth_delivery_v110',
    'dispatch_id','$dispatch'::uuid,
    'idempotency_key','$race_callback_key'::uuid
  ))
")" != "0" ]; then
  echo "V112 retry-first invalid callback persisted a receipt." >&2
  exit 1
fi
retry_identity="$(q -c "select app.v112_hash(jsonb_build_object(
  'operation','retry_growth_delivery_v110',
  'business_id','$business'::uuid,
  'dispatch_id','$dispatch'::uuid,
  'actor','$owner'::uuid,
  'idempotency_key','$race_retry_key'::uuid
))")"
assert_receipt_identity "$retry_identity" 1
assert_event_count "$race_retry_key" 1
assert_event_count "$race_callback_key" 0

# callback first / cancel second: the provider failure is valid from delivering
# and serializes before one owner cancellation event.
reset_dispatch delivering
race_callback_key="$(q -c 'select gen_random_uuid()')"
race_cancel_key="$(q -c 'select gen_random_uuid()')"
cat >"$work_dir/v110-callback-cancel-callback-first-a.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('role','service_role')::text,true
);
set local role service_role;
select pg_advisory_xact_lock(
  hashtextextended('v112-v110-dispatch:$dispatch',112)
);
select pg_sleep(0.75);
select public.service_complete_growth_delivery_v110(
  '$dispatch',null,false,'callback_first_cancel','$race_callback_key'
);
commit;
SQL
cat >"$work_dir/v110-callback-cancel-callback-first-b.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$owner','role','authenticated')::text,true
);
set local role authenticated;
select public.cancel_growth_delivery_v110(
  '$business','$dispatch','callback first race','$race_cancel_key'
);
commit;
SQL
q -f "$work_dir/v110-callback-cancel-callback-first-a.sql" \
  >"$work_dir/v110-callback-cancel-callback-first-a.raw" 2>&1 &
pid_a=$!
sleep 0.15
q -f "$work_dir/v110-callback-cancel-callback-first-b.sql" \
  >"$work_dir/v110-callback-cancel-callback-first-b.raw" 2>&1
wait "$pid_a"
assert_dispatch_status cancelled
callback_identity="$(q -c "select app.v112_hash(jsonb_build_object(
  'operation','service_complete_growth_delivery_v110',
  'dispatch_id','$dispatch'::uuid,
  'idempotency_key','$race_callback_key'::uuid
))")"
cancel_identity="$(q -c "select app.v112_hash(jsonb_build_object(
  'operation','cancel_growth_delivery_v110',
  'business_id','$business'::uuid,
  'dispatch_id','$dispatch'::uuid,
  'actor','$owner'::uuid,
  'idempotency_key','$race_cancel_key'::uuid
))")"
assert_receipt_identity "$callback_identity" 1
assert_receipt_identity "$cancel_identity" 1
assert_event_count "$race_callback_key" 1
assert_event_count "$race_cancel_key" 1

# cancel first / callback second: callback reaches cancelled after waiting,
# rejects the invalid transition, and cannot create a receipt or extra event.
reset_dispatch failed
race_callback_key="$(q -c 'select gen_random_uuid()')"
race_cancel_key="$(q -c 'select gen_random_uuid()')"
cat >"$work_dir/v110-callback-cancel-cancel-first-a.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$owner','role','authenticated')::text,true
);
set local role authenticated;
select pg_advisory_xact_lock(
  hashtextextended('v112-v110-dispatch:$dispatch',112)
);
select public.cancel_growth_delivery_v110(
  '$business','$dispatch','cancel first race','$race_cancel_key'
);
select pg_sleep(0.75);
commit;
SQL
cat >"$work_dir/v110-callback-cancel-cancel-first-b.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('role','service_role')::text,true
);
set local role service_role;
do \$race\$
begin
  perform public.service_complete_growth_delivery_v110(
    '$dispatch',null,false,'cancel_first_callback','$race_callback_key'
  );
  raise exception 'cancelled callback unexpectedly succeeded';
exception when invalid_parameter_value then null;
end
\$race\$;
commit;
SQL
q -f "$work_dir/v110-callback-cancel-cancel-first-a.sql" \
  >"$work_dir/v110-callback-cancel-cancel-first-a.raw" 2>&1 &
pid_a=$!
sleep 0.15
q -f "$work_dir/v110-callback-cancel-cancel-first-b.sql" \
  >"$work_dir/v110-callback-cancel-cancel-first-b.raw" 2>&1
wait "$pid_a"
assert_dispatch_status cancelled
if [ "$(q -c "
  select count(*) from public.concurrent_operation_receipts_v112
  where request_identity=app.v112_hash(jsonb_build_object(
    'operation','service_complete_growth_delivery_v110',
    'dispatch_id','$dispatch'::uuid,
    'idempotency_key','$race_callback_key'::uuid
  ))
")" != "0" ]; then
  echo "V112 cancel-first invalid callback persisted a receipt." >&2
  exit 1
fi
cancel_identity="$(q -c "select app.v112_hash(jsonb_build_object(
  'operation','cancel_growth_delivery_v110',
  'business_id','$business'::uuid,
  'dispatch_id','$dispatch'::uuid,
  'actor','$owner'::uuid,
  'idempotency_key','$race_cancel_key'::uuid
))")"
assert_receipt_identity "$cancel_identity" 1
assert_event_count "$race_cancel_key" 1
assert_event_count "$race_callback_key" 0

# A successful provider callback arriving after execution expiry must still
# durably record delivery, but must not mint an already-expired entitlement.
# Starting the late callback first recreates the historical callback-advisory
# versus cancel-row inversion while also proving the liveness fix.
reset_dispatch delivering
q -c "
  update public.growth_executions_v108
  set status='running',
      started_at=statement_timestamp()-interval '3 days',
      offer_expires_at=statement_timestamp()-interval '1 day',
      ends_at=statement_timestamp()-interval '1 second',
      governed_copy=jsonb_set(
        jsonb_set(
          governed_copy,
          '{conditions,expires_at}',
          to_jsonb(statement_timestamp()-interval '1 day')
        ),
        '{locked_facts,expires_at}',
        to_jsonb(statement_timestamp()-interval '1 day')
      )
  where id=(
    select execution_id from public.growth_delivery_dispatches_v110
    where id='$dispatch'
  )
" >/dev/null
race_callback_key="$(q -c 'select gen_random_uuid()')"
race_cancel_key="$(q -c 'select gen_random_uuid()')"
cat >"$work_dir/v110-late-callback-cancel-a.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('role','service_role')::text,true
);
set local role service_role;
select pg_advisory_xact_lock(
  hashtextextended('v112-v110-dispatch:$dispatch',112)
);
select pg_sleep(0.75);
select public.service_complete_growth_delivery_v110(
  '$dispatch','provider-late-concurrency-v112',true,null,'$race_callback_key'
);
commit;
SQL
cat >"$work_dir/v110-late-callback-cancel-b.sql" <<SQL
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub','$owner','role','authenticated')::text,true
);
set local role authenticated;
do \$race\$
begin
  perform public.cancel_growth_delivery_v110(
    '$business','$dispatch','late callback race','$race_cancel_key'
  );
  raise exception 'delivered dispatch cancellation unexpectedly succeeded';
exception when invalid_parameter_value then null;
end
\$race\$;
commit;
SQL
q -f "$work_dir/v110-late-callback-cancel-a.sql" \
  >"$work_dir/v110-late-callback-cancel-a.raw" 2>&1 &
pid_a=$!
sleep 0.15
q -f "$work_dir/v110-late-callback-cancel-b.sql" \
  >"$work_dir/v110-late-callback-cancel-b.raw" 2>&1
wait "$pid_a"
assert_dispatch_status delivered
if ! grep -q '"entitlement_suppressed": true' \
  "$work_dir/v110-late-callback-cancel-a.raw" \
  || ! grep -q '"suppression_reason": "execution_expired"' \
  "$work_dir/v110-late-callback-cancel-a.raw"; then
  echo "V112 late callback did not return the suppression contract." >&2
  exit 1
fi
if [ "$(q -c "
  select count(*)
  from public.growth_entitlements_v108 entitlement
  join public.growth_delivery_dispatches_v110 dispatch
    on dispatch.delivery_id=entitlement.delivery_id
  where dispatch.id='$dispatch'
")" != "0" ]; then
  echo "V112 late callback minted an expired entitlement." >&2
  exit 1
fi
callback_identity="$(q -c "select app.v112_hash(jsonb_build_object(
  'operation','service_complete_growth_delivery_v110',
  'dispatch_id','$dispatch'::uuid,
  'idempotency_key','$race_callback_key'::uuid
))")"
cancel_identity="$(q -c "select app.v112_hash(jsonb_build_object(
  'operation','cancel_growth_delivery_v110',
  'business_id','$business'::uuid,
  'dispatch_id','$dispatch'::uuid,
  'actor','$owner'::uuid,
  'idempotency_key','$race_cancel_key'::uuid
))")"
assert_receipt_identity "$callback_identity" 1
assert_receipt_identity "$cancel_identity" 0
assert_event_count "$race_callback_key" 1
assert_event_count "$race_cancel_key" 0
if [ "$(q -c "
  select count(*) from public.growth_delivery_state_events_v110
  where dispatch_id='$dispatch'
    and idempotency_key='$race_callback_key'
    and reason_code='execution_expired'
    and detail->>'suppression_reason'='execution_expired'
    and (detail->>'entitlement_suppressed')::boolean
")" != "1" ]; then
  echo "V112 late callback suppression audit is incomplete." >&2
  exit 1
fi

if [ "$(q -c "
  select count(*) from public.concurrent_operation_receipts_v112
  where scope->>'business_id'='$business'
")" -lt 5 ] || [ "$(q -c "
  select count(*) from public.concurrent_operation_receipts_v112
  where scope->>'dispatch_id'='$dispatch'
")" -lt 2 ] || [ "$(q -c "
  select count(*) from public.concurrent_operation_receipts_v112
  where operation='service_claim_growth_deliveries_v110'
    and scope->>'idempotency_key'='$claim_key'
")" != "1" ]; then
  echo "Concurrent v112 receipt evidence is incomplete." >&2
  exit 1
fi

echo "V112 CONCURRENCY PASS"
