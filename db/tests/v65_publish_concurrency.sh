#!/bin/sh
# v65 publish-race harness: two connections publish the SAME draft with DISTINCT
# idempotency keys, fired simultaneously. The draft-row FOR UPDATE + the
# unique(source_draft_id) index must yield EXACTLY ONE immutable version (version_no=1),
# the draft ending 'published', one worker doing the real publish (replayed=false) and
# the other a clean draft-status replay (replayed=true) - never two versions, never a
# raw 23505 to a caller. Config-only: zero sv_lot_movements, authority untouched.
# Run ONLY against a disposable rehearsal cluster (commits are NOT rolled back).
set -eu

if [ "${V65_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V65_CONFIRM_DISPOSABLE_DB=YES for a disposable database." >&2; exit 2; fi
if [ -z "${DATABASE_URL:-}" ]; then echo "DATABASE_URL is required." >&2; exit 2; fi
if [ -z "${PGPASSWORD:-}" ]; then echo "PGPASSWORD is required." >&2; exit 2; fi
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=10000"
q() { psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 "$@"; }

owner="$(q -c 'select gen_random_uuid()')"
slug="v65-conc-${owner%%-*}"

q <<SQL >/dev/null
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','$owner','authenticated','authenticated','$slug@example.test','',now(),now(),now());
select set_config('request.jwt.claim.sub','$owner',false);
select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false);
select public.create_business('V65 concurrency','$slug','test', array['dashboard','clients','sales','loyalty']);
SQL
biz="$(q -c "select id from public.businesses where slug='$slug'")"
case "$biz" in ????????-????-????-????-????????????) ;; *) echo "setup failed (biz=$biz)" >&2; exit 1;; esac

# Create ONE publishable draft (price>0, name, terms, discount below hard limit) as the owner.
draft="$(q <<SQL
select set_config('request.jwt.claim.sub','$owner',false);
select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false);
select (public.create_sv_plan_draft('$biz'::uuid, jsonb_build_object(
  'customer_facing_name','Race pack','price_cents',10000,'bonus_cents',1000,
  'customer_terms','Valid 1 year. No cash out.'), gen_random_uuid()))->>'draft_id';
SQL
)"
draft="$(printf '%s\n' "$draft" | tail -1)"
case "$draft" in ????????-????-????-????-????????????) ;; *) echo "setup failed (draft=$draft)" >&2; exit 1;; esac

# The raced call: SAME draft, expected_revision 0, DISTINCT key per worker (gen_random_uuid()).
call="select set_config('request.jwt.claim.sub','$owner',false); \
select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false); \
select (public.publish_sv_plan_version('$biz'::uuid,'$draft'::uuid,0,gen_random_uuid(),null))->>'replayed';"

start_epoch="$(q -c 'select extract(epoch from now())+2')"
worker() {
  q -c "select pg_sleep(greatest(0, $start_epoch - extract(epoch from clock_timestamp())));" >/dev/null 2>&1 || true
  q -c "$call" > "/tmp/v65_race_$1.out" 2>"/tmp/v65_race_$1.err" || echo "worker-$1 error" >"/tmp/v65_race_$1.out"
}
worker A & worker B & wait
a_out="$(tail -1 /tmp/v65_race_A.out 2>/dev/null)"; b_out="$(tail -1 /tmp/v65_race_B.out 2>/dev/null)"
echo "worker A replayed=$a_out"; echo "worker B replayed=$b_out"

plan="$(q -c "select plan_id from public.sv_plan_drafts where id='$draft'")"
result="$(q <<SQL
select (select count(*) from public.sv_plan_versions where plan_id='$plan' and business_id='$biz')
  || '|' || (select count(*) from public.sv_plan_versions where source_draft_id='$draft')
  || '|' || (select status from public.sv_plan_drafts where id='$draft')
  || '|' || (select count(*) from public.sv_lot_movements where business_id='$biz')
  || '|' || (select coalesce(state,'none') from public.sv_authority where business_id='$biz' and asset='stored_value');
SQL
)"
vers="${result%%|*}"; r1="${result#*|}"; from_draft="${r1%%|*}"; r2="${r1#*|}"; st="${r2%%|*}"; r3="${r2#*|}"; moves="${r3%%|*}"; auth="${r3#*|}"
echo "versions=$vers from_this_draft=$from_draft draft_status=$st sv_movements=$moves authority=$auth"

fail=0
[ "$vers" = "1" ] || { echo "FAIL: expected exactly 1 version, got $vers" >&2; fail=1; }
[ "$from_draft" = "1" ] || { echo "FAIL: expected exactly 1 version from this draft, got $from_draft" >&2; fail=1; }
[ "$st" = "published" ] || { echo "FAIL: expected draft published, got $st" >&2; fail=1; }
[ "$moves" = "0" ] || { echo "FAIL: publish must write no sv movements, got $moves" >&2; fail=1; }
[ "$auth" = "unbuilt" ] || { echo "FAIL: authority must stay unbuilt, got $auth" >&2; fail=1; }
case "$a_out|$b_out" in
  false\|true|true\|false) : ;;
  *) echo "FAIL: expected one real publish (false) + one replay (true), got $a_out|$b_out" >&2; fail=1;;
esac
rm -f /tmp/v65_race_A.out /tmp/v65_race_A.err /tmp/v65_race_B.out /tmp/v65_race_B.err
if [ "$fail" = "0" ]; then echo "v65 publish concurrency: PASS (one version, one clean replay, zero value moved)"; else exit 1; fi
