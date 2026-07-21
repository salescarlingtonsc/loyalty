#!/bin/sh
set -eu

# Intentionally NOT run automatically. This creates a uniquely named,
# self-contained C46 fixture only on an explicitly confirmed disposable
# database. It never prints DATABASE_URL, PGPASSWORD, or any query output that
# could contain a connection secret.
if [ "${C46_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set C46_CONFIRM_DISPOSABLE_DB=YES for a disposable database." >&2
  exit 2
fi
if [ -z "${DATABASE_URL:-}" ] || [ -z "${PGPASSWORD:-}" ]; then
  echo "DATABASE_URL and PGPASSWORD are required." >&2
  exit 2
fi
case "$DATABASE_URL" in postgresql://*|postgres://*) ;; *) echo "DATABASE_URL must be PostgreSQL." >&2; exit 2;; esac
case "$(printf '%s' "$DATABASE_URL" | tr '[:upper:]' '[:lower:]')" in
  *gadpooereceldfpfxsod*) echo "Refusing C46 runtime against the protected project reference." >&2; exit 2;;
esac

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/frenly-c46-concurrency.XXXXXX")"
owner="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
customer="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
for value in "$owner" "$customer"; do
  case "$value" in ????????-????-????-????-????????????) ;; *) echo "synthetic auth UUID setup failed" >&2; exit 1;; esac
done
prefix="${owner%%-*}"
fixture_name="C46 synthetic inbox concurrency ${prefix}"
fixture_slug="c46-inbox-${prefix}"
owner_email="c46-owner-${prefix}@example.test"
customer_email="c46-customer-${prefix}@example.test"
business=""
feature_flag_state="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 -c "select feature_key,enabled from app.platform_feature_flags where feature_key in ('customer_in_app_inbox','customer_actionable_wallet','customer_wallet','customer_birthday_benefits') order by feature_key")"

restore_feature_flags(){
  [ -n "$feature_flag_state" ] || return 0
  while IFS='|' read -r feature_key feature_enabled; do
    [ -n "$feature_key" ] || continue
    psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v feature_key="$feature_key" -v feature_enabled="$feature_enabled" \
      -c "update app.platform_feature_flags set enabled=:'feature_enabled'::boolean where feature_key=:'feature_key'" >/dev/null 2>&1 || return 1
  done <<EOF
$feature_flag_state
EOF
}

cleanup(){
  status="$1"; trap - EXIT HUP INT TERM; set +e
  if [ -n "$business" ]; then
    psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
      -v cleanup_confirm="YES-SCOPED-SYNTHETIC-CLEANUP" \
      -v cleanup_business="$business" -v cleanup_business_name="$fixture_name" -v cleanup_business_slug="$fixture_slug" \
      -v cleanup_auth_user_1="$owner" -v cleanup_auth_email_1="$owner_email" \
      -v cleanup_auth_user_2="$customer" -v cleanup_auth_email_2="$customer_email" \
      -f "$script_dir/cleanup_synthetic_fixture.sql" >"$work_dir/cleanup" 2>&1 || status=1
  fi
  restore_feature_flags || status=1
  rm -f "$work_dir/fixture" "$work_dir/sync-same-a" "$work_dir/sync-same-b" \
    "$work_dir/sync-different-a" "$work_dir/sync-different-b" "$work_dir/state-same-a" "$work_dir/state-same-b" \
    "$work_dir/state-different-a" "$work_dir/state-different-b" "$work_dir/race-first" \
    "$work_dir/race-second" "$work_dir/cleanup"
  rmdir "$work_dir" 2>/dev/null || true
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' HUP INT TERM

# This fixture has no C44 source: the C46 booking candidate below is sufficient
# to exercise deterministic sync/event dedupe without editing any live record.
psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v owner="$owner" -v customer="$customer" -v fixture_name="$fixture_name" -v fixture_slug="$fixture_slug" \
  -v owner_email="$owner_email" -v customer_email="$customer_email" >"$work_dir/fixture" <<'SQL'
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values ('00000000-0000-0000-0000-000000000000',:'owner','authenticated','authenticated',:'owner_email','',now(),now(),now()),
       ('00000000-0000-0000-0000-000000000000',:'customer','authenticated','authenticated',:'customer_email','',now(),now(),now());
set role authenticated;
select set_config('request.jwt.claim.sub',:'owner',false) \gset
select (public.create_business(:'fixture_name',:'fixture_slug','test',array['dashboard','clients','sales','loyalty','appointments'])::jsonb->>'id')::uuid as business \gset
select id as owner_staff from public.staff where business_id=:'business' and user_id=:'owner' limit 1 \gset
reset role;
update app.platform_feature_flags set enabled=true where feature_key in ('customer_in_app_inbox','customer_actionable_wallet','customer_wallet','customer_birthday_benefits');
insert into public.clients(business_id,full_name) values(:'business','C46 synthetic customer') returning id as client \gset
insert into public.customer_identities(id,auth_user_id,status,created_via)
values(gen_random_uuid(),:'customer','active','phone_registration') returning id as identity \gset
select set_config('app.c42_profile_identity',:'identity',true) \gset
insert into public.customer_profiles(identity_id,auth_user_id,full_name,birth_date)
values(:'identity',:'customer','C46 synthetic customer',(timezone('Asia/Singapore',statement_timestamp()))::date);
insert into public.customer_links(business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
values(:'business',:'identity',:'customer',:'client','verified','phone_claim',now()) returning id as link \gset
insert into public.appointments(business_id,client_id,staff_id,starts_at,ends_at,status)
values(:'business',:'client',:'owner_staff',now()+interval '2 days',now()+interval '2 days 1 hour','booked') returning id as appointment \gset
insert into public.customer_appointment_action_requests(
  business_id,identity_id,auth_user_id,link_id,client_id,appointment_id,action,proposed_at,note,status,idempotency_key,request_hash
) values (
  :'business',:'identity',:'customer',:'link',:'client',:'appointment','cancel',null,null,'pending',
  'c46-concurrency-booking-source',app.v33_sha256_hex('c46-concurrency-booking-source')
);
-- A current, activated C45 promise is deliberately retained after withdrawal.
-- The later two-session participation-vs-sync assertions prove C46 does not
-- treat that still-visible entitlement as consent to create/retain an inbox event.
set role authenticated;
select set_config('request.jwt.claim.sub',:'owner',false) \gset
select (public.create_loyalty_config_draft(:'business',null,'c46-concurrency-birthday')::jsonb->>'version_id')::uuid as birthday_draft \gset
select public.save_loyalty_config_draft(:'birthday_draft',jsonb_build_object('active',true)) \gset
select snapshot_hash as birthday_draft_hash from public.firm_config_versions where id=:'birthday_draft' \gset
select public.save_birthday_program_draft(:'birthday_draft',gen_random_uuid(),jsonb_build_object(
  'active',true,'customer_label','C46 concurrency birthday','customer_description','Synthetic only','customer_terms','Synthetic only',
  'fulfillment_kind','free_item','manual_item','Synthetic birthday item','window_days_before',0,'window_days_after',0,'sort',0
),:'birthday_draft_hash') \gset
select public.publish_loyalty_config(:'birthday_draft') \gset
set role authenticated;
select set_config('request.jwt.claim.sub',:'customer',false) \gset
select public.customer_set_birthday_participation(true,gen_random_uuid()) \gset
select public.customer_activate_birthday_benefit(:'fixture_slug',gen_random_uuid()) \gset
select public.customer_set_birthday_participation(false,gen_random_uuid()) \gset
select public.customer_set_in_app_inbox_preferences(
  :'fixture_slug','booking_updates',true,'Asia/Singapore','22:00'::time,'08:00'::time,gen_random_uuid()
) \gset
select public.customer_set_in_app_inbox_preferences(
  :'fixture_slug','birthday_benefit',true,null,null,null,gen_random_uuid()
) \gset
reset role;
select :'business',:'fixture_slug';
SQL
IFS='|' read -r business fixture_slug < "$work_dir/fixture"
case "$business" in ????????-????-????-????-????????????) ;; *) echo "self-created C46 business fixture failed" >&2; exit 1;; esac
case "$fixture_slug" in c46-inbox-*) ;; *) echo "self-created C46 slug fixture failed" >&2; exit 1;; esac

sync(){
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v customer="$customer" -v slug="$fixture_slug" -v key="$1" <<'SQL'
set role authenticated;
select set_config('request.jwt.claim.sub',:'customer',false);
select public.customer_sync_in_app_inbox(:'slug',:'key')::text;
SQL
}

add_booking_source(){
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v business="$business" -v customer="$customer" -v source_key="$1" <<'SQL'
insert into public.customer_appointment_action_requests(
  business_id,identity_id,auth_user_id,link_id,client_id,appointment_id,action,proposed_at,note,status,idempotency_key,request_hash
)
select cl.business_id,cl.identity_id,cl.auth_user_id,cl.id,cl.client_id,a.id,'cancel',null,null,'pending',
       :'source_key',app.v33_sha256_hex(:'source_key')
  from public.customer_links cl
  join public.appointments a on a.business_id=cl.business_id and a.client_id=cl.client_id
 where cl.business_id=:'business' and cl.auth_user_id=:'customer' and cl.state='verified'
 order by a.starts_at,a.id limit 1;
SQL
}

set_booking_preference(){
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v customer="$customer" -v slug="$fixture_slug" -v opted="$1" -v key="$2" <<'SQL'
set role authenticated;
select set_config('request.jwt.claim.sub',:'customer',false) \gset
select public.customer_set_in_app_inbox_preferences(
  :'slug','booking_updates',:'opted'::boolean,'Asia/Singapore','22:00'::time,'08:00'::time,:'key'
)::text;
SQL
}

set_birthday_participation(){
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v customer="$customer" -v opted="$1" -v key="$2" <<'SQL'
set role authenticated;
select set_config('request.jwt.claim.sub',:'customer',false) \gset
select public.customer_set_birthday_participation(:'opted'::boolean,:'key')::text;
SQL
}

# Each contender takes the same identity row as the fixture owner, then changes
# to the authenticated caller before invoking its public RPC. The browser role
# never receives raw-table access; it merely inherits this transaction's lock,
# and the public RPC rechecks the same row under its own RLS-safe context. The
# marker lets the second session start only after the first holds the row;
# pg_sleep is a bounded local test barrier, never an application mechanism.
wait_for_identity_lock(){
  lock_file="$1"; attempts=0
  while ! grep -q 'C46_IDENTITY_LOCK_HELD' "$lock_file" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 100 ] || { echo "identity-lock test barrier timed out" >&2; exit 1; }
    sleep 0.05
  done
}

preference_with_identity_lock(){
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v customer="$customer" -v slug="$fixture_slug" -v opted="$1" -v key="$2" <<'SQL'
begin;
select 1 from public.customer_identities where auth_user_id=:'customer' and status='active' for update;
select 'C46_IDENTITY_LOCK_HELD';
select pg_sleep(0.25);
set local role authenticated;
select set_config('request.jwt.claim.sub',:'customer',true) \gset
select public.customer_set_in_app_inbox_preferences(
  :'slug','booking_updates',:'opted'::boolean,'Asia/Singapore','22:00'::time,'08:00'::time,:'key'
)::text;
commit;
SQL
}

sync_with_identity_lock(){
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v customer="$customer" -v slug="$fixture_slug" -v key="$1" <<'SQL'
begin;
select 1 from public.customer_identities where auth_user_id=:'customer' and status='active' for update;
select 'C46_IDENTITY_LOCK_HELD';
select pg_sleep(0.25);
set local role authenticated;
select set_config('request.jwt.claim.sub',:'customer',true) \gset
select public.customer_sync_in_app_inbox(:'slug',:'key')::text;
commit;
SQL
}

participation_with_identity_lock(){
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v customer="$customer" -v opted="$1" -v key="$2" <<'SQL'
begin;
select 1 from public.customer_identities where auth_user_id=:'customer' and status='active' for update;
select 'C46_IDENTITY_LOCK_HELD';
select pg_sleep(0.25);
set local role authenticated;
select set_config('request.jwt.claim.sub',:'customer',true) \gset
select public.customer_set_birthday_participation(:'opted'::boolean,:'key')::text;
commit;
SQL
}

# Same-key two-session sync: both callers succeed with the exact replay and one
# immutable sync operation/event fact. The source event is not browser input.
sync_key="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
sync "$sync_key" >"$work_dir/sync-same-a" 2>&1 & sync_same_a=$!
sync "$sync_key" >"$work_dir/sync-same-b" 2>&1 & sync_same_b=$!
set +e; wait "$sync_same_a"; sync_same_status_a=$?; wait "$sync_same_b"; sync_same_status_b=$?; set -e
[ "$sync_same_status_a" -eq 0 ] && [ "$sync_same_status_b" -eq 0 ] || { echo "same-key two-session sync did not succeed" >&2; exit 1; }
cmp -s "$work_dir/sync-same-a" "$work_dir/sync-same-b" || { echo "same-key sync responses were not exact replays" >&2; exit 1; }
sync_same_rows="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v customer="$customer" -v key="$sync_key" -c "select count(*) from public.customer_in_app_inbox_sync_operations where auth_user_id=:'customer' and idempotency_key=:'key'")"
event_rows="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v business="$business" -v customer="$customer" -c "select count(*) from public.customer_in_app_inbox_events where business_id=:'business' and auth_user_id=:'customer'")"
[ "$sync_same_rows" = "1" ] && [ "$event_rows" = "1" ] || { echo "same-key sync did not retain one operation and one event" >&2; exit 1; }

# Different sync keys are distinct operation evidence, but converge on the
# same immutable event fact through the source/dedupe uniqueness constraint.
sync_key_a="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
sync_key_b="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
sync "$sync_key_a" >"$work_dir/sync-different-a" 2>&1 & sync_different_a=$!
sync "$sync_key_b" >"$work_dir/sync-different-b" 2>&1 & sync_different_b=$!
set +e; wait "$sync_different_a"; sync_different_status_a=$?; wait "$sync_different_b"; sync_different_status_b=$?; set -e
[ "$sync_different_status_a" -eq 0 ] && [ "$sync_different_status_b" -eq 0 ] || { echo "different-key two-session sync did not succeed" >&2; exit 1; }
sync_different_rows="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v customer="$customer" -v key_a="$sync_key_a" -v key_b="$sync_key_b" -c "select count(*) from public.customer_in_app_inbox_sync_operations where auth_user_id=:'customer' and idempotency_key in (:'key_a',:'key_b')")"
event_rows="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v business="$business" -v customer="$customer" -c "select count(*) from public.customer_in_app_inbox_events where business_id=:'business' and auth_user_id=:'customer'")"
[ "$sync_different_rows" = "2" ] && [ "$event_rows" = "1" ] || { echo "different-key sync did not converge on one immutable event" >&2; exit 1; }

event="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v business="$business" -v customer="$customer" -c "select id from public.customer_in_app_inbox_events where business_id=:'business' and auth_user_id=:'customer' order by created_at,id limit 1")"
case "$event" in ????????-????-????-????-????????????) ;; *) echo "C46 sync event fixture missing" >&2; exit 1;; esac

state(){
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v customer="$customer" -v slug="$fixture_slug" -v event="$event" -v operation="$1" -v key="$2" <<'SQL'
set role authenticated;
select set_config('request.jwt.claim.sub',:'customer',false);
select public.customer_set_in_app_inbox_state(:'slug',:'event',:'operation',:'key')::text;
SQL
}

# Same-key state mutation is a replay, not a second mutable-state operation.
state_key="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
state read "$state_key" >"$work_dir/state-same-a" 2>&1 & state_same_a=$!
state read "$state_key" >"$work_dir/state-same-b" 2>&1 & state_same_b=$!
set +e; wait "$state_same_a"; state_same_status_a=$?; wait "$state_same_b"; state_same_status_b=$?; set -e
[ "$state_same_status_a" -eq 0 ] && [ "$state_same_status_b" -eq 0 ] || { echo "same-key two-session state operation did not succeed" >&2; exit 1; }
cmp -s "$work_dir/state-same-a" "$work_dir/state-same-b" || { echo "same-key two-session state responses were not exact replays" >&2; exit 1; }
state_same_rows="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v event="$event" -v key="$state_key" -c "select count(*) from public.customer_in_app_inbox_state_operations where event_id=:'event' and idempotency_key=:'key'")"
[ "$state_same_rows" = "1" ] || { echo "same-key state operation did not retain exactly one evidence row" >&2; exit 1; }

# Different keys preserve two distinct operation facts while the guarded state
# row serializes safely; the final state is intentionally order-independent.
state_key_a="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
state_key_b="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
state unread "$state_key_a" >"$work_dir/state-different-a" 2>&1 & state_different_a=$!
state dismiss "$state_key_b" >"$work_dir/state-different-b" 2>&1 & state_different_b=$!
set +e; wait "$state_different_a"; state_different_status_a=$?; wait "$state_different_b"; state_different_status_b=$?; set -e
[ "$state_different_status_a" -eq 0 ] && [ "$state_different_status_b" -eq 0 ] || { echo "different-key two-session state operations did not succeed" >&2; exit 1; }
state_different_rows="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v event="$event" -v key_a="$state_key_a" -v key_b="$state_key_b" -c "select count(*) from public.customer_in_app_inbox_state_operations where event_id=:'event' and idempotency_key in (:'key_a',:'key_b')")"
[ "$state_different_rows" = "2" ] || { echo "different-key state operations did not retain separate evidence" >&2; exit 1; }
terminal_state="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v event="$event" -c "select case when dismissed_at is not null then 'dismissed' else 'not-dismissed' end from public.customer_in_app_inbox_state where event_id=:'event'")"
[ "$terminal_state" = "dismissed" ] || { echo "unread-vs-dismiss race resurrected a dismissed inbox event" >&2; exit 1; }
unread_after_dismiss="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v customer="$customer" -v slug="$fixture_slug" <<'SQL'
set role authenticated;
select set_config('request.jwt.claim.sub',:'customer',false) \gset
select public.customer_get_in_app_inbox_count(:'slug')->>'unread_count';
SQL
)"
[ "$unread_after_dismiss" = "0" ] || { echo "dismissed event remained in the unread count" >&2; exit 1; }
listed_after_dismiss="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v customer="$customer" -v slug="$fixture_slug" -v event="$event" <<'SQL'
set role authenticated;
select set_config('request.jwt.claim.sub',:'customer',false) \gset
select count(*) from jsonb_array_elements(public.customer_list_in_app_inbox(:'slug',jsonb_build_object('limit',50,'filter','all'))->'items') x where x->>'event_id'=:'event';
SQL
)"
[ "$listed_after_dismiss" = "0" ] || { echo "dismissed event remained in the all-items list" >&2; exit 1; }

# Consent linearization: both C46 preference changes and C45 participation
# changes lock the active identity row before the C46 sync can read source or
# consent. Exercise both serial orders with two sessions. An opt-out first
# leaves a newly pending source without an event; a sync first may create its
# fact before the later opt-out (C46 preference history is deliberately kept).
pref_race_source_a="c46-pref-off-first-$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
add_booking_source "$pref_race_source_a"
booking_before="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v business="$business" -v customer="$customer" -c "select count(*) from public.customer_in_app_inbox_events where business_id=:'business' and auth_user_id=:'customer' and topic='booking_updates'")"
pref_off_first_key="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
pref_off_first_sync_key="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
preference_with_identity_lock false "$pref_off_first_key" >"$work_dir/race-first" 2>&1 & race_first=$!
wait_for_identity_lock "$work_dir/race-first"
sync "$pref_off_first_sync_key" >"$work_dir/race-second" 2>&1 & race_second=$!
set +e; wait "$race_first"; race_first_status=$?; wait "$race_second"; race_second_status=$?; set -e
[ "$race_first_status" -eq 0 ] && [ "$race_second_status" -eq 0 ] || { echo "opt-out-first preference-vs-sync race failed" >&2; exit 1; }
booking_after="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v business="$business" -v customer="$customer" -c "select count(*) from public.customer_in_app_inbox_events where business_id=:'business' and auth_user_id=:'customer' and topic='booking_updates'")"
[ "$booking_after" = "$booking_before" ] || { echo "opt-out-first preference race created a new booking inbox event" >&2; exit 1; }

# Opposite order: while booking consent is true, sync obtains the identity
# lock first. It may create facts for both pending race sources; the waiting
# opt-out then wins only for later syncs, never retroactively mutating history.
set_booking_preference true "$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')" >/dev/null
pref_race_source_b="c46-sync-first-$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
add_booking_source "$pref_race_source_b"
booking_before="$booking_after"
sync_first_key="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
pref_off_second_key="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
sync_with_identity_lock "$sync_first_key" >"$work_dir/race-first" 2>&1 & race_first=$!
wait_for_identity_lock "$work_dir/race-first"
preference_with_identity_lock false "$pref_off_second_key" >"$work_dir/race-second" 2>&1 & race_second=$!
set +e; wait "$race_first"; race_first_status=$?; wait "$race_second"; race_second_status=$?; set -e
[ "$race_first_status" -eq 0 ] && [ "$race_second_status" -eq 0 ] || { echo "sync-first preference-vs-opt-out race failed" >&2; exit 1; }
booking_after="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v business="$business" -v customer="$customer" -c "select count(*) from public.customer_in_app_inbox_events where business_id=:'business' and auth_user_id=:'customer' and topic='booking_updates'")"
[ "$booking_after" -eq $((booking_before + 2)) ] || { echo "sync-first preference race did not create exactly the two pending booking facts before opt-out" >&2; exit 1; }

# The C45 entitlement is still available after participation withdrawal. C46
# must nevertheless use the same shared lock and withhold birthday events when
# withdrawal is first, then resolve the prior event after a sync-first race.
set_birthday_participation true "$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')" >/dev/null
birthday_before="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v business="$business" -v customer="$customer" -c "select count(*) from public.customer_in_app_inbox_events where business_id=:'business' and auth_user_id=:'customer' and topic='birthday_benefit'")"
birthday_off_first_key="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
birthday_off_first_sync_key="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
participation_with_identity_lock false "$birthday_off_first_key" >"$work_dir/race-first" 2>&1 & race_first=$!
wait_for_identity_lock "$work_dir/race-first"
sync "$birthday_off_first_sync_key" >"$work_dir/race-second" 2>&1 & race_second=$!
set +e; wait "$race_first"; race_first_status=$?; wait "$race_second"; race_second_status=$?; set -e
[ "$race_first_status" -eq 0 ] && [ "$race_second_status" -eq 0 ] || { echo "participation-withdraw-first vs sync race failed" >&2; exit 1; }
birthday_after="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v business="$business" -v customer="$customer" -c "select count(*) from public.customer_in_app_inbox_events where business_id=:'business' and auth_user_id=:'customer' and topic='birthday_benefit'")"
[ "$birthday_after" = "$birthday_before" ] || { echo "withdraw-first participation race created a new birthday inbox event" >&2; exit 1; }

set_birthday_participation true "$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')" >/dev/null
birthday_sync_first_key="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
birthday_off_second_key="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
sync_with_identity_lock "$birthday_sync_first_key" >"$work_dir/race-first" 2>&1 & race_first=$!
wait_for_identity_lock "$work_dir/race-first"
participation_with_identity_lock false "$birthday_off_second_key" >"$work_dir/race-second" 2>&1 & race_second=$!
set +e; wait "$race_first"; race_first_status=$?; wait "$race_second"; race_second_status=$?; set -e
[ "$race_first_status" -eq 0 ] && [ "$race_second_status" -eq 0 ] || { echo "sync-first participation-withdraw race failed" >&2; exit 1; }
birthday_event="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v business="$business" -v customer="$customer" -c "select id from public.customer_in_app_inbox_events where business_id=:'business' and auth_user_id=:'customer' and topic='birthday_benefit' order by created_at desc,id desc limit 1")"
case "$birthday_event" in ????????-????-????-????-????????????) ;; *) echo "sync-first participation race did not create a birthday inbox event" >&2; exit 1;; esac
sync "$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')" >/dev/null
birthday_resolved="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v event="$birthday_event" -c "select count(*) from public.customer_in_app_inbox_resolutions where event_id=:'event'")"
[ "$birthday_resolved" = "1" ] || { echo "post-withdraw revalidation did not resolve the C46 birthday event" >&2; exit 1; }

outbox_rows="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v business="$business" -c "select count(*) from public.customer_notification_outbox where business_id=:'business'")"
[ "$outbox_rows" = "0" ] || { echo "C46 concurrency harness observed a legacy outbox/provider write" >&2; exit 1; }
echo "C46 sync/state concurrency: PASS (self-created synthetic fixture cleanup and feature-flag restoration run on exit)"
