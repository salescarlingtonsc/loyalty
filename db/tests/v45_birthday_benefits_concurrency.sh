#!/bin/sh
set -eu

# This harness is intentionally NOT run automatically. It only runs against a
# separately authorized disposable PostgreSQL database and creates uniquely
# named synthetic fixtures. It never prints DATABASE_URL or PGPASSWORD.
if [ "${C45_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set C45_CONFIRM_DISPOSABLE_DB=YES for a disposable database." >&2
  exit 2
fi
if [ -z "${DATABASE_URL:-}" ] || [ -z "${PGPASSWORD:-}" ]; then
  echo "DATABASE_URL and PGPASSWORD are required." >&2
  exit 2
fi
case "$DATABASE_URL" in postgresql://*|postgres://*) ;; *) echo "DATABASE_URL must be PostgreSQL." >&2; exit 2;; esac
case "$(printf '%s' "$DATABASE_URL" | tr '[:upper:]' '[:lower:]')" in
  *gadpooereceldfpfxsod*) echo "Refusing C45 runtime against the protected project reference." >&2; exit 2;;
esac

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/frenly-c45-concurrency.XXXXXX")"
owner="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
customer="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
case "$owner" in ????????-????-????-????-????????????) ;; *) echo "fixture owner UUID failed" >&2; exit 1;; esac
case "$customer" in ????????-????-????-????-????????????) ;; *) echo "fixture customer UUID failed" >&2; exit 1;; esac
prefix="${owner%%-*}"
fixture_name="C45 synthetic birthday concurrency ${prefix}"
fixture_slug="c45-birthday-${prefix}"
owner_email="c45-owner-${prefix}@example.test"
customer_email="c45-customer-${prefix}@example.test"
business=""
feature_flag_state="$(psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 -c "select feature_key,enabled from app.platform_feature_flags where feature_key in ('customer_identity','customer_claims','customer_wallet','customer_birthday_benefits') order by feature_key")"
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
  rm -f "$work_dir/fixture" "$work_dir/activation-a" "$work_dir/activation-b" "$work_dir/redeem-a" "$work_dir/redeem-b" "$work_dir/reverse-a" "$work_dir/reverse-b" "$work_dir/expiry-a" "$work_dir/expiry-b" "$work_dir/cleanup"
  rmdir "$work_dir" 2>/dev/null || true
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' HUP INT TERM

psql "$DATABASE_URL" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
  -v owner="$owner" -v customer="$customer" -v fixture_name="$fixture_name" -v fixture_slug="$fixture_slug" \
  -v owner_email="$owner_email" -v customer_email="$customer_email" >"$work_dir/fixture" <<'SQL'
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values ('00000000-0000-0000-0000-000000000000',:'owner','authenticated','authenticated',:'owner_email','',now(),now(),now()),
       ('00000000-0000-0000-0000-000000000000',:'customer','authenticated','authenticated',:'customer_email','',now(),now(),now());
set role authenticated;
select set_config('request.jwt.claim.sub',:'owner',false) \gset
select (public.create_business(:'fixture_name',:'fixture_slug','test',array['dashboard','clients','sales','loyalty'])::jsonb->>'id')::uuid as business \gset
select id as branch from public.branches where business_id=:'business' and is_default limit 1 \gset
select id as owner_staff from public.staff where business_id=:'business' and user_id=:'owner' limit 1 \gset
reset role;
update app.platform_feature_flags set enabled=true where feature_key in ('customer_identity','customer_claims','customer_wallet','customer_birthday_benefits');
insert into public.staff_branches(business_id,staff_id,branch_id) values(:'business',:'owner_staff',:'branch') on conflict do nothing;
insert into public.clients(business_id,full_name) values(:'business','C45 synthetic customer') returning id as client \gset
insert into public.customer_identities(id,auth_user_id,status,created_via) values(gen_random_uuid(),:'customer','active','phone_registration') returning id as identity \gset
select set_config('app.c42_profile_identity',:'identity',true) \gset
insert into public.customer_profiles(identity_id,auth_user_id,full_name,birth_date) values(:'identity',:'customer','C45 synthetic customer',current_date);
insert into public.customer_links(business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
values(:'business',:'identity',:'customer',:'client','verified','phone_claim',now());
set role authenticated;
select set_config('request.jwt.claim.sub',:'owner',false) \gset
select (public.create_loyalty_config_draft(:'business',null,'c45-concurrency')::jsonb->>'version_id')::uuid as draft \gset
-- New businesses start with inactive loyalty. Make the explicitly reviewed
-- fixture config active before publishing so activation joins a live model.
select public.save_loyalty_config_draft(:'draft',jsonb_build_object('active',true)) \gset
select public.get_birthday_program_draft(:'draft')->>'snapshot_hash' as draft_hash \gset
select public.save_birthday_program_draft(:'draft',gen_random_uuid(),jsonb_build_object(
  'active',true,'customer_label','C45 birthday treat','customer_description','Synthetic only','customer_terms','Synthetic only',
  'fulfillment_kind','free_item','manual_item','Synthetic item','window_days_before',0,'window_days_after',0,'sort',0
),:'draft_hash') \gset
select public.publish_loyalty_config(:'draft') \gset
set role authenticated;
select set_config('request.jwt.claim.sub',:'customer',false) \gset
select public.customer_set_birthday_participation(true,gen_random_uuid()) \gset
reset role;
-- A separate synthetic client has a benefit whose exclusive end instant is
-- already reached. It makes the expiry-boundary race executable without
-- changing the live customer's immutable entitlement window.
insert into public.clients(business_id,full_name) values(:'business','C45 synthetic expiry customer') returning id as expiry_client \gset
insert into public.customer_identities(id,auth_user_id,status,created_via) values(gen_random_uuid(),:'owner','active','phone_registration') returning id as expiry_identity \gset
select set_config('app.c42_profile_identity',:'expiry_identity',true) \gset
insert into public.customer_profiles(identity_id,auth_user_id,full_name,birth_date)
values(:'expiry_identity',:'owner','C45 synthetic expiry customer',(timezone('Asia/Singapore',statement_timestamp()))::date);
insert into public.customer_links(business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
values(:'business',:'expiry_identity',:'owner',:'expiry_client','verified','phone_claim',now());
insert into public.customer_birthday_entitlements(
  business_id,client_id,identity_id,config_version_id,birthday_program_version_id,birthday_year,status,valid_from,valid_until,benefit_snapshot
)
select :'business',:'expiry_client',:'expiry_identity',bpv.config_version_id,bpv.id,
       extract(year from timezone('Asia/Singapore',statement_timestamp()))::integer-1,
       'available',statement_timestamp()-interval '2 days',statement_timestamp(),app.c45_benefit_snapshot(bpv)
  from public.birthday_program_versions bpv
  join public.businesses b on b.active_config_version_id=bpv.config_version_id and b.id=bpv.business_id
 where bpv.business_id=:'business' and bpv.active;
select :'business',:'branch',:'client',:'expiry_client';
SQL
IFS='|' read -r business branch client expiry_client < "$work_dir/fixture"
for id in "$business" "$branch" "$client" "$expiry_client"; do case "$id" in ????????-????-????-????-????????????) ;; *) echo "fixture setup failed" >&2; exit 1;; esac; done

# same-key two-session activation: both callers must return a safe success
# payload while the unique business/client/birthday-year rule leaves one promise.
activation_key="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
activate(){
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v customer="$customer" -v slug="$fixture_slug" -v key="$activation_key" <<'SQL'
set role authenticated; select set_config('request.jwt.claim.sub',:'customer',false);
select public.customer_activate_birthday_benefit(:'slug',:'key')::text;
SQL
}
activate >"$work_dir/activation-a" 2>&1 & activation_a=$!
activate >"$work_dir/activation-b" 2>&1 & activation_b=$!
set +e; wait "$activation_a"; activation_status_a=$?; wait "$activation_b"; activation_status_b=$?; set -e
[ "$activation_status_a" -eq 0 ] && [ "$activation_status_b" -eq 0 ] || { echo "same-key activation did not succeed in both sessions" >&2; exit 1; }
cmp -s "$work_dir/activation-a" "$work_dir/activation-b" || { echo "same-key activation responses were not exact replays" >&2; exit 1; }
activation_count="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v business="$business" -v client="$client" -c "select count(*) from public.customer_birthday_entitlements where business_id=:'business' and client_id=:'client'")"
[ "$activation_count" = "1" ] || { echo "same-key two-session activation did not yield exactly one entitlement" >&2; exit 1; }

# different-key loser conflict: two owner counter requests race for one live
# redemption. Exactly one writes a redemption; the loser is rejected, never
# relabelled as a replay of a different idempotency key.
redeem(){
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v owner="$owner" -v business="$business" -v client="$1" -v branch="$branch" -v key="$2" <<'SQL'
set role authenticated; select set_config('request.jwt.claim.sub',:'owner',false);
select public.redeem_customer_birthday_benefit(:'business',:'client',:'branch',:'key')::text;
SQL
}
redeem_key_a="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
redeem_key_b="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
redeem "$client" "$redeem_key_a" >"$work_dir/redeem-a" 2>&1 & redeem_a=$!
redeem "$client" "$redeem_key_b" >"$work_dir/redeem-b" 2>&1 & redeem_b=$!
set +e; wait "$redeem_a"; status_a=$?; wait "$redeem_b"; status_b=$?; set -e
if ! { [ "$status_a" -eq 0 ] && [ "$status_b" -ne 0 ]; } && ! { [ "$status_b" -eq 0 ] && [ "$status_a" -ne 0 ]; }; then
  echo "different-key loser conflict failed: statuses $status_a/$status_b" >&2; exit 1
fi
if [ "$status_a" -ne 0 ]; then loser_log="$work_dir/redeem-a"; else loser_log="$work_dir/redeem-b"; fi
grep -Eqi '40001|birthday redemption conflicts with an existing operation' "$loser_log" || { echo "different-key loser was not an explicit conflict" >&2; exit 1; }
redemption="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v business="$business" -v client="$client" -c "select id from public.customer_birthday_redemptions where business_id=:'business' and client_id=:'client' and operation_kind='redemption' and active")"
case "$redemption" in ????????-????-????-????-????????????) ;; *) echo "winner redemption missing" >&2; exit 1;; esac

# Two owner sessions use the same client-scoped reversal key. They must both
# succeed (one exact replay), append one compensating row, and leave no live
# original redemption. No internal redemption UUID is sent by this workflow.
reversal_key="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
reverse(){
  exec psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v owner="$owner" -v business="$business" -v client="$client" -v key="$reversal_key" <<'SQL'
set role authenticated; select set_config('request.jwt.claim.sub',:'owner',false);
select public.reverse_customer_birthday_benefit_for_client(:'business',:'client','synthetic counter correction',:'key')::text;
SQL
}
reverse >"$work_dir/reverse-a" 2>&1 & reverse_a=$!
reverse >"$work_dir/reverse-b" 2>&1 & reverse_b=$!
set +e; wait "$reverse_a"; reverse_status_a=$?; wait "$reverse_b"; reverse_status_b=$?; set -e
[ "$reverse_status_a" -eq 0 ] && [ "$reverse_status_b" -eq 0 ] || { echo "same-key reversal did not succeed in both sessions" >&2; exit 1; }
reversal_rows="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v redemption="$redemption" -c "select count(*) from public.customer_birthday_redemptions where original_redemption_id=:'redemption' and operation_kind='reversal' and active")"
[ "$reversal_rows" = "1" ] || { echo "same-key reversal did not append exactly one active compensation" >&2; exit 1; }

# The expiry fixture has valid_until exactly at a prior statement timestamp:
# C45's half-open boundary makes it unavailable to both counter sessions. The
# effective expired state is derived from valid_until; neither call persists an
# expiry update before raising, creates a redemption, or turns into a
# different-key conflict.
expiry_key_a="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
expiry_key_b="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')"
redeem "$expiry_client" "$expiry_key_a" >"$work_dir/expiry-a" 2>&1 & expiry_a=$!
redeem "$expiry_client" "$expiry_key_b" >"$work_dir/expiry-b" 2>&1 & expiry_b=$!
set +e; wait "$expiry_a"; expiry_status_a=$?; wait "$expiry_b"; expiry_status_b=$?; set -e
[ "$expiry_status_a" -ne 0 ] && [ "$expiry_status_b" -ne 0 ] || { echo "exclusive expiry-boundary race unexpectedly redeemed" >&2; exit 1; }
expiry_effective="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v business="$business" -v client="$expiry_client" -c "select app.c45_staff_safe_birthday_entitlement(e,statement_timestamp())->>'status' from public.customer_birthday_entitlements e where e.business_id=:'business' and e.client_id=:'client'")"
[ "$expiry_effective" = "expired" ] || { echo "effective expiry projection did not expire the boundary fixture" >&2; exit 1; }
expiry_redemptions="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v business="$business" -v client="$expiry_client" -c "select count(*) from public.customer_birthday_redemptions where business_id=:'business' and client_id=:'client'")"
[ "$expiry_redemptions" = "0" ] || { echo "expiry-boundary fixture created a redemption" >&2; exit 1; }

# No birthday activation, redemption, reversal, or expiry handling may write
# monetary ledgers or mutate a sale.
financial_rows="$(psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -v business="$business" -v client="$client" -c "select (select count(*) from public.credit_ledger where business_id=:'business' and client_id=:'client') + (select count(*) from public.points_ledger where business_id=:'business' and client_id=:'client')")"
[ "$financial_rows" = "0" ] || { echo "birthday benefit touched financial ledgers" >&2; exit 1; }
echo "C45 activation/redeem/reversal/expiry concurrency: PASS (synthetic-fixture-cleanup and feature-flag restoration run on exit)"
