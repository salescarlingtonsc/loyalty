#!/bin/sh
# True two-session v111 race harness. Run only against a disposable database.
# It proves both commit orderings for approval versus verified-link creation:
#   1. approval-first: approval commits; the blocked link writer then fails.
#   2. link-first: the verified link commits; the blocked approval then fails.
set -eu

if [ "${V111_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V111_CONFIRM_DISPOSABLE_DB=YES." >&2
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
  *v111*|*rehearsal*|*test*|*shadow*) ;;
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
if [ "$(q -c "select count(*) from pg_trigger where tgname='customer_links_v111_verified_source_guard' and not tgisinternal")" != "1" ]; then
  echo "customer_links_v111_verified_source_guard is not installed." >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nestly-v111-identity-concurrency.XXXXXX")"
cleanup() {
  status="$1"
  trap - EXIT HUP INT TERM
  rm -f "$work_dir"/*
  rmdir "$work_dir" 2>/dev/null || true
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' HUP INT TERM

ids="$(q -F '|' -c "
  select gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
         gen_random_uuid(),gen_random_uuid()
")"
old_ifs="$IFS"
IFS='|'
set -- $ids
IFS="$old_ifs"
owner="$1"
target_user_a="$2"
source_user_a="$3"
target_user_b="$4"
source_user_b="$5"
owner_prefix="${owner%%-*}"
slug_a="v111-approval-first-$owner_prefix"
slug_b="v111-link-first-$owner_prefix"
owner_email="$slug_a-owner@example.test"
target_email_a="$slug_a-target@example.test"
source_email_a="$slug_a-source@example.test"
target_email_b="$slug_b-target@example.test"
source_email_b="$slug_b-source@example.test"

q -v owner="$owner" -v owner_email="$owner_email" \
  -v slug_a="$slug_a" -v slug_b="$slug_b" <<'SQL' >/dev/null
insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  created_at,updated_at
) values(
  '00000000-0000-0000-0000-000000000000',:'owner','authenticated',
  'authenticated',:'owner_email','',now(),now(),now()
);
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub',:'owner','role','authenticated','email',:'owner_email')::text,
  false
);
set role authenticated;
select public.create_business('V111 approval-first race',:'slug_a','facial',null);
select public.create_business('V111 link-first race',:'slug_b','facial',null);
reset role;
SQL

setup_values="$(
  q -v owner="$owner" \
    -v target_user_a="$target_user_a" -v source_user_a="$source_user_a" \
    -v target_user_b="$target_user_b" -v source_user_b="$source_user_b" \
    -v target_email_a="$target_email_a" -v source_email_a="$source_email_a" \
    -v target_email_b="$target_email_b" -v source_email_b="$source_email_b" \
    -v slug_a="$slug_a" -v slug_b="$slug_b" <<'SQL'
\o /dev/null
select id as business_a from public.businesses where slug=:'slug_a'
\gset
select id as business_b from public.businesses where slug=:'slug_b'
\gset
select id as branch_a from public.branches
 where business_id=:'business_a' order by is_default desc,created_at,id limit 1
\gset
select id as branch_b from public.branches
 where business_id=:'business_b' order by is_default desc,created_at,id limit 1
\gset

insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  created_at,updated_at
) values
(
  '00000000-0000-0000-0000-000000000000',:'target_user_a','authenticated',
  'authenticated',:'target_email_a','',now(),now(),now()
),(
  '00000000-0000-0000-0000-000000000000',:'source_user_a','authenticated',
  'authenticated',:'source_email_a','',now(),now(),now()
),(
  '00000000-0000-0000-0000-000000000000',:'target_user_b','authenticated',
  'authenticated',:'target_email_b','',now(),now(),now()
),(
  '00000000-0000-0000-0000-000000000000',:'source_user_b','authenticated',
  'authenticated',:'source_email_b','',now(),now(),now()
);

insert into public.clients(business_id,full_name,email,is_synthetic)
values(:'business_a','Approval-first source',:'source_email_a',true)
returning id as source_a
\gset
insert into public.clients(business_id,full_name,email,is_synthetic)
values(:'business_a','Approval-first target',:'target_email_a',true)
returning id as target_a
\gset
insert into public.clients(business_id,full_name,email,is_synthetic)
values(:'business_b','Link-first source',:'source_email_b',true)
returning id as source_b
\gset
insert into public.clients(business_id,full_name,email,is_synthetic)
values(:'business_b','Link-first target',:'target_email_b',true)
returning id as target_b
\gset

select gen_random_uuid() as target_identity_a,
       gen_random_uuid() as source_identity_a,
       gen_random_uuid() as target_identity_b,
       gen_random_uuid() as source_identity_b,
       gen_random_uuid() as target_link_a,
       gen_random_uuid() as target_link_b,
       gen_random_uuid() as invitation_a,
       gen_random_uuid() as invitation_b
\gset
insert into public.customer_identities(id,auth_user_id,status,created_via)
values
  (:'target_identity_a',:'target_user_a','active','phone_registration'),
  (:'source_identity_a',:'source_user_a','active','phone_registration'),
  (:'target_identity_b',:'target_user_b','active','phone_registration'),
  (:'source_identity_b',:'source_user_b','active','phone_registration');

select set_config('app.customer_link_insert_id',:'target_link_a',false);
insert into public.customer_links(
  id,business_id,identity_id,auth_user_id,client_id,state,
  verification_method,verified_at
) values(
  :'target_link_a',:'business_a',:'target_identity_a',:'target_user_a',
  :'target_a','verified','firm_invitation',statement_timestamp()
);
select set_config('app.customer_link_insert_id',:'target_link_b',false);
insert into public.customer_links(
  id,business_id,identity_id,auth_user_id,client_id,state,
  verification_method,verified_at
) values(
  :'target_link_b',:'business_b',:'target_identity_b',:'target_user_b',
  :'target_b','verified','firm_invitation',statement_timestamp()
);
select set_config('app.customer_link_insert_id','',false);

insert into public.customer_link_invitations(
  id,business_id,client_id,issued_by_auth_user_id,token_hash,
  recipient_email_hash,expires_at
) values
(
  :'invitation_a',:'business_a',:'source_a',:'owner',
  app.v31_sha256_hex('v111-approval-first-'||:'invitation_a'),
  app.v31_sha256_hex('v31.invitation-email:'||lower(:'target_email_a')),
  statement_timestamp()+interval '1 day'
),(
  :'invitation_b',:'business_b',:'source_b',:'owner',
  app.v31_sha256_hex('v111-link-first-'||:'invitation_b'),
  app.v31_sha256_hex('v31.invitation-email:'||lower(:'target_email_b')),
  statement_timestamp()+interval '1 day'
);

select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub',:'owner','role','authenticated')::text,
  false
);
set role authenticated;
select (
  public.propose_customer_identity_correction_v111(
    :'business_a',:'branch_a',:'source_a',:'target_a',
    'approval-first concurrency evidence',gen_random_uuid()
  )->>'proposal_id'
) as proposal_a
\gset
select public.attach_customer_identity_proof_v111(
  :'proposal_a','firm_invitation',
  jsonb_build_object('invitation_id',:'invitation_a'),gen_random_uuid()
);
select (
  public.propose_customer_identity_correction_v111(
    :'business_b',:'branch_b',:'source_b',:'target_b',
    'link-first concurrency evidence',gen_random_uuid()
  )->>'proposal_id'
) as proposal_b
\gset
select public.attach_customer_identity_proof_v111(
  :'proposal_b','firm_invitation',
  jsonb_build_object('invitation_id',:'invitation_b'),gen_random_uuid()
);
reset role;
\o
\echo :business_a|:branch_a|:source_a|:target_a|:source_identity_a|:proposal_a|:business_b|:branch_b|:source_b|:target_b|:source_identity_b|:proposal_b
SQL
)"
old_ifs="$IFS"
IFS='|'
set -- $setup_values
IFS="$old_ifs"
business_a="$1"
branch_a="$2"
source_a="$3"
target_a="$4"
source_identity_a="$5"
proposal_a="$6"
business_b="$7"
branch_b="$8"
source_b="$9"
shift 9
target_b="$1"
source_identity_b="$2"
proposal_b="$3"

source_link_a="$(q -c 'select gen_random_uuid()')"
source_link_b="$(q -c 'select gen_random_uuid()')"
approve_key_a="$(q -c 'select gen_random_uuid()')"
approve_key_b="$(q -c 'select gen_random_uuid()')"

# approval-first: the decision session holds the shared source-client lock,
# then approval commits before the already-waiting verified-link writer resumes.
(
  if q -v owner="$owner" -v business="$business_a" -v source="$source_a" \
       -v proposal="$proposal_a" -v approve_key="$approve_key_a" <<'SQL' \
       >"$work_dir/approval-first-approve.out" 2>&1
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub',:'owner','role','authenticated')::text,
  true
);
set local role authenticated;
select pg_advisory_xact_lock(hashtextextended(
  'v111:client:'||:'business'||':'||:'source',0
));
\echo approval-first-lock-held
select pg_sleep(2);
select public.approve_customer_identity_correction_v111(
  :'proposal',:'approve_key'
);
commit;
SQL
  then echo 0 >"$work_dir/approval-first-approve.status"
  else echo $? >"$work_dir/approval-first-approve.status"
  fi
) &
approval_pid="$!"
until grep -q 'approval-first-lock-held' "$work_dir/approval-first-approve.out" 2>/dev/null; do
  kill -0 "$approval_pid" 2>/dev/null || {
    echo "approval-first decision session exited before acquiring the lock." >&2
    exit 1
  }
done
(
  if q -v business="$business_a" -v source="$source_a" \
       -v identity="$source_identity_a" -v user="$source_user_a" \
       -v link="$source_link_a" <<'SQL' \
       >"$work_dir/approval-first-link.out" 2>&1
begin;
select set_config('app.customer_link_insert_id',:'link',true);
insert into public.customer_links(
  id,business_id,identity_id,auth_user_id,client_id,state,
  verification_method,verified_at
) values(
  :'link',:'business',:'identity',:'user',:'source','verified',
  'firm_invitation',statement_timestamp()
);
commit;
SQL
  then echo 0 >"$work_dir/approval-first-link.status"
  else echo $? >"$work_dir/approval-first-link.status"
  fi
) &
link_pid="$!"
wait "$approval_pid"
wait "$link_pid"

[ "$(cat "$work_dir/approval-first-approve.status")" = "0" ] || {
  echo "approval-first approval did not commit." >&2
  cat "$work_dir/approval-first-approve.out" >&2
  exit 1
}
[ "$(cat "$work_dir/approval-first-link.status")" != "0" ] || {
  echo "approval-first verified-link writer unexpectedly committed." >&2
  exit 1
}
grep -q 'verified link cannot be created for a customer with an active identity correction' \
  "$work_dir/approval-first-link.out" || {
  echo "approval-first link writer failed for the wrong reason." >&2
  cat "$work_dir/approval-first-link.out" >&2
  exit 1
}

# link-first: the writer holds the same lock and commits a verified source link;
# approval resumes afterwards and fails its post-lock source-link proof recheck.
(
  if q -v business="$business_b" -v source="$source_b" \
       -v identity="$source_identity_b" -v user="$source_user_b" \
       -v link="$source_link_b" <<'SQL' \
       >"$work_dir/link-first-link.out" 2>&1
begin;
select pg_advisory_xact_lock(hashtextextended(
  'v111:client:'||:'business'||':'||:'source',0
));
\echo link-first-lock-held
select pg_sleep(2);
select set_config('app.customer_link_insert_id',:'link',true);
insert into public.customer_links(
  id,business_id,identity_id,auth_user_id,client_id,state,
  verification_method,verified_at
) values(
  :'link',:'business',:'identity',:'user',:'source','verified',
  'firm_invitation',statement_timestamp()
);
commit;
SQL
  then echo 0 >"$work_dir/link-first-link.status"
  else echo $? >"$work_dir/link-first-link.status"
  fi
) &
link_first_pid="$!"
until grep -q 'link-first-lock-held' "$work_dir/link-first-link.out" 2>/dev/null; do
  kill -0 "$link_first_pid" 2>/dev/null || {
    echo "link-first writer exited before acquiring the lock." >&2
    exit 1
  }
done
(
  if q -v owner="$owner" -v proposal="$proposal_b" \
       -v approve_key="$approve_key_b" <<'SQL' \
       >"$work_dir/link-first-approve.out" 2>&1
begin;
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub',:'owner','role','authenticated')::text,
  true
);
set local role authenticated;
select public.approve_customer_identity_correction_v111(
  :'proposal',:'approve_key'
);
commit;
SQL
  then echo 0 >"$work_dir/link-first-approve.status"
  else echo $? >"$work_dir/link-first-approve.status"
  fi
) &
approval_first_pid="$!"
wait "$link_first_pid"
wait "$approval_first_pid"

[ "$(cat "$work_dir/link-first-link.status")" = "0" ] || {
  echo "link-first verified-link writer did not commit." >&2
  cat "$work_dir/link-first-link.out" >&2
  exit 1
}
[ "$(cat "$work_dir/link-first-approve.status")" != "0" ] || {
  echo "link-first approval unexpectedly committed." >&2
  exit 1
}
grep -q 'source customer gained a verified identity after proof' \
  "$work_dir/link-first-approve.out" || {
  echo "link-first approval failed for the wrong reason." >&2
  cat "$work_dir/link-first-approve.out" >&2
  exit 1
}

state="$(q -F '|' -v business_a="$business_a" -v source_a="$source_a" \
  -v proposal_a="$proposal_a" -v business_b="$business_b" \
  -v source_b="$source_b" -v proposal_b="$proposal_b" <<'SQL'
select
  (
    select count(*) from public.customer_identity_attribution_events_v111
     where proposal_id=:'proposal_a' and event_type='correction_approved'
  ),
  (
    select count(*) from public.customer_links
     where business_id=:'business_a' and client_id=:'source_a' and state='verified'
  ),
  (
    select count(*) from public.customer_identity_attribution_events_v111
     where proposal_id=:'proposal_b'
  ),
  (
    select count(*) from public.customer_links
     where business_id=:'business_b' and client_id=:'source_b' and state='verified'
  );
SQL
)"
[ "$state" = "1|0|0|1" ] || {
  echo "concurrency postconditions failed: $state" >&2
  exit 1
}

echo "v111 identity concurrency: PASS (approval-first 1|0; link-first 0|1)"
