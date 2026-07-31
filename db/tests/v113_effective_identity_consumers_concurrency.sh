#!/bin/sh
# True two-session v113 identity-correction versus growth-approval harness.
# Run only against a disposable/local database after the canonical chain through
# v113. It proves both commit orderings on the same business-scoped advisory
# boundary:
#   1. correction-first commits; stale source+target growth approval fails.
#   2. growth-first commits; the identity correction that would collapse two
#      live members fails.
set -eu

if [ "${V113_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V113_CONFIRM_DISPOSABLE_DB=YES." >&2
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
  *v113*|*rehearsal*|*test*|*shadow*) ;;
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
  select count(*) from pg_trigger
   where tgname='growth_executions_v113_identity_guard'
     and not tgisinternal
")" != "1" ]; then
  echo "v113 effective-identity growth guard is not installed." >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nestly-v113-cross-flow.XXXXXX")"
growth_flag_before="$(q -c "
  select enabled::text from app.platform_feature_flags
  where feature_key='growth_closed_loop_v108'
")"
cleanup() {
  status="$1"
  set +e
  trap - EXIT HUP INT TERM
  if [ -n "$growth_flag_before" ]; then
    q -v growth_flag_before="$growth_flag_before" <<'SQL' \
      >/dev/null 2>&1 || true
update app.platform_feature_flags
   set enabled=:'growth_flag_before'::boolean
 where feature_key='growth_closed_loop_v108';
SQL
  fi
  rm -f "$work_dir"/*
  rmdir "$work_dir" 2>/dev/null || true
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' HUP INT TERM

ids="$(q -F '|' -c "
  select gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid()
")"
old_ifs="$IFS"
IFS='|'
set -- $ids
IFS="$old_ifs"
owner="$1"
business_a="$2"
branch_a="$3"
source_a="$4"
target_a="$5"
fill_a_1="$6"
fill_a_2="$7"
fill_a_3="$8"
fill_a_4="$9"
shift 9
recommendation_a="$1"
proposal_key_a="$2"
proof_key_a="$3"
correction_key_a="$4"
approval_key_a="$5"
business_b="$6"
branch_b="$7"
source_b="$8"
target_b="$9"
shift 9
fill_b_1="$1"
fill_b_2="$2"
fill_b_3="$3"
fill_b_4="$4"
recommendation_b="$5"
proposal_key_b="$6"
proof_key_b="$7"
correction_key_b="$8"
approval_key_b="$9"

owner_email="v113-cross-flow-$owner@example.test"
slug_a="v113-correction-first-${business_a%%-*}"
slug_b="v113-growth-first-${business_b%%-*}"
shared_email_a="v113-correction-first-${business_a%%-*}@example.test"
shared_email_b="v113-growth-first-${business_b%%-*}@example.test"

setup_values="$(
  q \
    -v owner="$owner" -v owner_email="$owner_email" \
    -v business_a="$business_a" -v branch_a="$branch_a" \
    -v source_a="$source_a" -v target_a="$target_a" \
    -v fill_a_1="$fill_a_1" -v fill_a_2="$fill_a_2" \
    -v fill_a_3="$fill_a_3" -v fill_a_4="$fill_a_4" \
    -v recommendation_a="$recommendation_a" \
    -v proposal_key_a="$proposal_key_a" -v proof_key_a="$proof_key_a" \
    -v business_b="$business_b" -v branch_b="$branch_b" \
    -v source_b="$source_b" -v target_b="$target_b" \
    -v fill_b_1="$fill_b_1" -v fill_b_2="$fill_b_2" \
    -v fill_b_3="$fill_b_3" -v fill_b_4="$fill_b_4" \
    -v recommendation_b="$recommendation_b" \
    -v proposal_key_b="$proposal_key_b" -v proof_key_b="$proof_key_b" \
    -v slug_a="$slug_a" -v slug_b="$slug_b" \
    -v shared_email_a="$shared_email_a" \
    -v shared_email_b="$shared_email_b" <<'SQL'
\o /dev/null
insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  created_at,updated_at
) values(
  '00000000-0000-0000-0000-000000000000',:'owner','authenticated',
  'authenticated',:'owner_email','',now(),now(),now()
);
insert into public.businesses(
  id,name,slug,currency,industry,enabled_modules,is_synthetic
) values
(
  :'business_a','V113 correction-first',:'slug_a','SGD','facial',
  array['dashboard','clients','till','sales','loyalty','retention'],true
),(
  :'business_b','V113 growth-first',:'slug_b','SGD','facial',
  array['dashboard','clients','till','sales','loyalty','retention'],true
);
update public.business_workspace_controls_v94
   set approval_status='approved',
       version=version+1,
       decided_at=statement_timestamp(),
       decision_reason='approved synthetic concurrency fixture',
       updated_at=statement_timestamp()
 where business_id in (:'business_a',:'business_b')
   and approval_status='pending';
insert into public.branches(id,business_id,name,timezone,is_default)
values
  (:'branch_a',:'business_a','Main','Asia/Singapore',true),
  (:'branch_b',:'business_b','Main','Asia/Singapore',true);
insert into public.reporting_contract_versions_v106(
  business_id,branch_id,version_no,effective_from,timezone,currency,
  legacy_assumption,created_by
) values
  (:'business_a',:'branch_a',2,'-infinity','Asia/Singapore','SGD',true,null),
  (:'business_b',:'branch_b',2,'-infinity','Asia/Singapore','SGD',true,null);
insert into public.staff(
  business_id,user_id,role,full_name,email,active
) values
  (:'business_a',:'owner','owner','V113 Owner',:'owner_email',true),
  (:'business_b',:'owner','owner','V113 Owner',:'owner_email',true);
insert into public.growth_policies_v108(
  business_id,minimum_audience,minimum_arm_size,updated_by
) values
  (:'business_a',10,3,:'owner'),
  (:'business_b',10,3,:'owner');
update app.platform_feature_flags
   set enabled=true
 where feature_key='growth_closed_loop_v108';

insert into public.clients(
  id,business_id,full_name,email,marketing_consent,is_synthetic
) values
  (:'source_a',:'business_a','A source',:'shared_email_a',true,true),
  (:'target_a',:'business_a','A target',:'shared_email_a',true,true),
  (:'fill_a_1',:'business_a','A filler 1',null,true,true),
  (:'fill_a_2',:'business_a','A filler 2',null,true,true),
  (:'fill_a_3',:'business_a','A filler 3',null,true,true),
  (:'fill_a_4',:'business_a','A filler 4',null,true,true),
  (:'source_b',:'business_b','B source',:'shared_email_b',true,true),
  (:'target_b',:'business_b','B target',:'shared_email_b',true,true),
  (:'fill_b_1',:'business_b','B filler 1',null,true,true),
  (:'fill_b_2',:'business_b','B filler 2',null,true,true),
  (:'fill_b_3',:'business_b','B filler 3',null,true,true),
  (:'fill_b_4',:'business_b','B filler 4',null,true,true);

select gen_random_uuid() as target_user_a,
       gen_random_uuid() as target_identity_a,
       gen_random_uuid() as target_link_a,
       gen_random_uuid() as target_user_b,
       gen_random_uuid() as target_identity_b,
       gen_random_uuid() as target_link_b
\gset
insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  created_at,updated_at
) values
(
  '00000000-0000-0000-0000-000000000000',:'target_user_a',
  'authenticated','authenticated',:'shared_email_a','',now(),now(),now()
),(
  '00000000-0000-0000-0000-000000000000',:'target_user_b',
  'authenticated','authenticated',:'shared_email_b','',now(),now(),now()
);
insert into public.customer_identities(id,auth_user_id,status,created_via)
values
  (:'target_identity_a',:'target_user_a','active','phone_registration'),
  (:'target_identity_b',:'target_user_b','active','phone_registration');
select set_config('app.customer_link_insert_id',:'target_link_a',false);
insert into public.customer_links(
  id,business_id,identity_id,auth_user_id,client_id,state,
  verification_method,verified_at
) values(
  :'target_link_a',:'business_a',:'target_identity_a',:'target_user_a',
  :'target_a','verified','qr_join',statement_timestamp()
);
select set_config('app.customer_link_insert_id',:'target_link_b',false);
insert into public.customer_links(
  id,business_id,identity_id,auth_user_id,client_id,state,
  verification_method,verified_at
) values(
  :'target_link_b',:'business_b',:'target_identity_b',:'target_user_b',
  :'target_b','verified','qr_join',statement_timestamp()
);
select set_config('app.customer_link_insert_id','',false);

insert into public.growth_recommendations_v108(
  id,business_id,branch_id,recommendation_type,policy_version,
  generated_at,valid_until,observation_start,observation_end,
  comparison_start,comparison_end,finding,supporting_evidence,baseline,
  opportunity,expected_incremental_revenue,expected_incremental_gross_profit,
  confidence,assumptions,recommended_action,recommended_channel,
  recommended_offer,estimated_cost_cents,audience_size,excluded_size,
  success_metric,frequency_cap_days,attribution_window_days,holdout_percent,
  stop_conditions,status,suppression_reasons,data_freshness_at,data_coverage,
  dedupe_key,created_by
) values
(
  :'recommendation_a',:'business_a',:'branch_a',
  'lapsed_high_value_bring_back','bring_back_v1',
  statement_timestamp(),statement_timestamp()+interval '1 day',
  statement_timestamp()-interval '90 days',statement_timestamp(),
  statement_timestamp()-interval '180 days',
  statement_timestamp()-interval '90 days',
  'Correction-first race fixture','[]','{}','{}',
  '{"status":"withheld_uncalibrated"}',null,'{"score_bps":8000}','[]',
  '{"label":"Approve measured bring-back"}','in_app',
  '{"type":"credit_cents","value_cents":300,"currency":"SGD"}',
  1800,6,0,'incremental_completed_purchase_revenue',30,14,20,
  '{"one_active_experiment_per_customer":true}','presented','[]',
  statement_timestamp(),
  jsonb_build_object(
    'identified_revenue_bps',10000,
    'effective_policy',app.growth_v108_effective_parameters(:'business_a')
  ),
  encode(extensions.digest(convert_to(:'recommendation_a','UTF8'),'sha256'),'hex'),
  :'owner'
),(
  :'recommendation_b',:'business_b',:'branch_b',
  'lapsed_high_value_bring_back','bring_back_v1',
  statement_timestamp(),statement_timestamp()+interval '1 day',
  statement_timestamp()-interval '90 days',statement_timestamp(),
  statement_timestamp()-interval '180 days',
  statement_timestamp()-interval '90 days',
  'Growth-first race fixture','[]','{}','{}',
  '{"status":"withheld_uncalibrated"}',null,'{"score_bps":8000}','[]',
  '{"label":"Approve measured bring-back"}','in_app',
  '{"type":"credit_cents","value_cents":300,"currency":"SGD"}',
  1800,6,0,'incremental_completed_purchase_revenue',30,14,20,
  '{"one_active_experiment_per_customer":true}','presented','[]',
  statement_timestamp(),
  jsonb_build_object(
    'identified_revenue_bps',10000,
    'effective_policy',app.growth_v108_effective_parameters(:'business_b')
  ),
  encode(extensions.digest(convert_to(:'recommendation_b','UTF8'),'sha256'),'hex'),
  :'owner'
);
insert into public.growth_recommendation_members_v108(
  recommendation_id,business_id,client_id,eligible,prior_visits,
  average_transaction_cents,historical_revenue_cents,evidence
)
select :'recommendation_a'::uuid,:'business_a'::uuid,
       client_id,true,3,1000,3000,'{}'::jsonb
  from (values
    (:'source_a'::uuid),(:'target_a'::uuid),(:'fill_a_1'::uuid),
    (:'fill_a_2'::uuid),(:'fill_a_3'::uuid),(:'fill_a_4'::uuid)
  ) member(client_id)
union all
select :'recommendation_b'::uuid,:'business_b'::uuid,
       client_id,true,3,1000,3000,'{}'::jsonb
  from (values
    (:'source_b'::uuid),(:'target_b'::uuid),(:'fill_b_1'::uuid),
    (:'fill_b_2'::uuid),(:'fill_b_3'::uuid),(:'fill_b_4'::uuid)
  ) member(client_id);

select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub',:'owner','role','authenticated')::text,
  false
);
select set_config('request.jwt.claim.sub',:'owner',false);
set role authenticated;
select public.propose_customer_identity_correction_v111(
  :'business_a',:'branch_a',:'source_a',:'target_a',
  'Cross-flow correction-first fixture',:'proposal_key_a'
)->>'proposal_id' as proposal_a
\gset
select public.attach_customer_identity_proof_v111(
  :'proposal_a','verified_contact_pair',
  jsonb_build_object('contact_type','email','contact_value',:'shared_email_a'),
  :'proof_key_a'
);
select public.propose_customer_identity_correction_v111(
  :'business_b',:'branch_b',:'source_b',:'target_b',
  'Cross-flow growth-first fixture',:'proposal_key_b'
)->>'proposal_id' as proposal_b
\gset
select public.attach_customer_identity_proof_v111(
  :'proposal_b','verified_contact_pair',
  jsonb_build_object('contact_type','email','contact_value',:'shared_email_b'),
  :'proof_key_b'
);
reset role;
\o
\pset tuples_only on
\pset format unaligned
select :'proposal_a'||'|'||:'proposal_b';
SQL
)"
proposal_a="${setup_values%%|*}"
proposal_b="${setup_values#*|}"
case "$proposal_a:$proposal_b" in
  *[!0-9a-fA-F:-]*|'') echo "Fixture setup returned invalid proposal ids." >&2; exit 1 ;;
esac

# Ordering 1: correction owns the shared business lock first. Growth approval
# waits, then observes the committed effective-identity collapse and fails stale.
(
  q -v owner="$owner" -v proposal="$proposal_a" \
    -v correction_key="$correction_key_a" <<'SQL'
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub',:'owner','role','authenticated')::text,
  true
);
select set_config('request.jwt.claim.sub',:'owner',true);
set local role authenticated;
select public.approve_customer_identity_correction_v111(
  :'proposal',:'correction_key'
);
select pg_sleep(2);
commit;
SQL
) >"$work_dir/correction-first-owner.out" 2>"$work_dir/correction-first-owner.err" &
owner_pid="$!"
sleep 1
set +e
q -v owner="$owner" -v business="$business_a" \
  -v recommendation="$recommendation_a" -v approval_key="$approval_key_a" <<'SQL' \
  >"$work_dir/correction-first-growth.out" 2>"$work_dir/correction-first-growth.err"
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub',:'owner','role','authenticated')::text,
  false
);
select set_config('request.jwt.claim.sub',:'owner',false);
set role authenticated;
select public.approve_growth_recommendation_v108(
  :'business',:'recommendation',300,'simple_saving',:'approval_key'
);
SQL
growth_status="$?"
wait "$owner_pid"
owner_status="$?"
set -e
if [ "$owner_status" -ne 0 ] || [ "$growth_status" -eq 0 ]; then
  echo "correction-first ordering did not serialize fail-closed." >&2
  cat "$work_dir/correction-first-owner.err" >&2 || true
  cat "$work_dir/correction-first-growth.err" >&2 || true
  exit 1
fi
if ! grep -q "recommendation identity snapshot is stale" \
  "$work_dir/correction-first-growth.err"; then
  echo "correction-first growth failure was not the effective-identity guard." >&2
  cat "$work_dir/correction-first-growth.err" >&2
  exit 1
fi

# Ordering 2: growth approval owns the same lock first and commits two distinct
# live members. The correction waits, then fails because it would collapse them.
(
  q -v owner="$owner" -v business="$business_b" \
    -v recommendation="$recommendation_b" -v approval_key="$approval_key_b" <<'SQL'
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub',:'owner','role','authenticated')::text,
  true
);
select set_config('request.jwt.claim.sub',:'owner',true);
set local role authenticated;
select public.approve_growth_recommendation_v108(
  :'business',:'recommendation',300,'simple_saving',:'approval_key'
);
select pg_sleep(2);
commit;
SQL
) >"$work_dir/growth-first-owner.out" 2>"$work_dir/growth-first-owner.err" &
growth_pid="$!"
sleep 1
set +e
q -v owner="$owner" -v proposal="$proposal_b" \
  -v correction_key="$correction_key_b" <<'SQL' \
  >"$work_dir/growth-first-correction.out" 2>"$work_dir/growth-first-correction.err"
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub',:'owner','role','authenticated')::text,
  false
);
select set_config('request.jwt.claim.sub',:'owner',false);
set role authenticated;
select public.approve_customer_identity_correction_v111(
  :'proposal',:'correction_key'
);
SQL
correction_status="$?"
wait "$growth_pid"
growth_owner_status="$?"
set -e
if [ "$growth_owner_status" -ne 0 ] || [ "$correction_status" -eq 0 ]; then
  echo "growth-first ordering did not serialize fail-closed." >&2
  cat "$work_dir/growth-first-owner.err" >&2 || true
  cat "$work_dir/growth-first-correction.err" >&2 || true
  exit 1
fi
if ! grep -q "identity correction would overlap active customer experiments" \
  "$work_dir/growth-first-correction.err"; then
  echo "growth-first correction failure was not the overlap guard." >&2
  cat "$work_dir/growth-first-correction.err" >&2
  exit 1
fi

final_state="$(q -F '|' \
  -v proposal_a="$proposal_a" -v proposal_b="$proposal_b" \
  -v recommendation_a="$recommendation_a" \
  -v recommendation_b="$recommendation_b" <<'SQL'
  select
    (select status from public.customer_identity_proposals_v111
      where id=:'proposal_a'),
    (select status from public.growth_recommendations_v108
      where id=:'recommendation_a'),
    (select status from public.customer_identity_proposals_v111
      where id=:'proposal_b'),
    (select status from public.growth_recommendations_v108
      where id=:'recommendation_b')
SQL
)"
if [ "$final_state" != "approved|presented|proof_attached|executed" ]; then
  echo "unexpected final cross-flow state: $final_state" >&2
  exit 1
fi

echo "v113 correction/growth two-session concurrency evidence passed."
