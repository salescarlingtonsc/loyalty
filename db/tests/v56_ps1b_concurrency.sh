#!/bin/sh
# v56 PS-1B concurrency harness: two connections race the SAME entitlement grant
# and the SAME budget reservation. Exactly one winner (one entitlement, one
# reservation, counter == one grant); the loser is a clean replay/refusal.
# Run ONLY against a disposable rehearsal cluster. Commits are made and NOT rolled
# back, so the database must be throwaway.
set -eu

if [ "${V56_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V56_CONFIRM_DISPOSABLE_DB=YES for a disposable database." >&2
  exit 2
fi
if [ -z "${DATABASE_URL:-}" ]; then echo "DATABASE_URL is required." >&2; exit 2; fi
case "$DATABASE_URL" in postgresql://*|postgres://*) ;; *)
  echo "DATABASE_URL must be a PostgreSQL URL." >&2; exit 2;; esac
url_authority="${DATABASE_URL#*://}"; url_authority="${url_authority%%/*}"
case "$url_authority" in *@*)
  url_userinfo="${url_authority%@*}"
  case "$url_userinfo" in *:*|*%3[Aa]*)
    echo "DATABASE_URL must not contain embedded password material; use PGPASSWORD." >&2; exit 2;;
  esac;; esac
if [ -z "${PGPASSWORD:-}" ]; then echo "PGPASSWORD is required with the passwordless DATABASE_URL." >&2; exit 2; fi

export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=10000"
q() { psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 "$@"; }

owner="$(q -c 'select gen_random_uuid()')"
owner_prefix="${owner%%-*}"
slug="v56-conc-$owner_prefix"

# --- Setup: a disposable business + config + client + a budget-bearing rule id ---
# Session GUCs (is_local=false) persist across the statements of this one psql
# session so the SECURITY DEFINER create_business sees auth.uid()=owner.
q <<SQL >/dev/null
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','$owner','authenticated','authenticated','$slug@example.test','',now(),now(),now());
select set_config('request.jwt.claim.sub','$owner',false);
select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false);
select public.create_business('V56 concurrency','$slug','test', array['dashboard','clients','sales','loyalty']);
insert into public.clients(business_id,full_name,phone)
  select id,'v56 conc','+6590000077' from public.businesses where slug='$slug';
-- create_business does not publish a loyalty config; program_entitlements needs a
-- real (config_version_id, business_id) — publish a minimal one, fixture-style.
select public.publish_loyalty_config(v.draft_id) from (
  select (public.create_loyalty_config_draft(
    (select id from public.businesses where slug='$slug'), null, 'v56-conc')::jsonb->>'version_id')::uuid as draft_id
) v;
SQL
biz="$(q -c "select id from public.businesses where slug='$slug'")"
cfg="$(q -c "select active_config_version_id from public.businesses where id='$biz'")"
client="$(q -c "select id from public.clients where business_id='$biz' order by created_at limit 1")"
case "$biz" in ????????-????-????-????-????????????) ;; *) echo "setup failed (biz=$biz)" >&2; exit 1;; esac
case "$client" in ????????-????-????-????-????????????) ;; *) echo "setup failed (client=$client)" >&2; exit 1;; esac
rule="$(q -c 'select gen_random_uuid()')"
pstart="$(q -c "select date_trunc('month', now())::text")"
pend="$(q -c "select (date_trunc('month', now()) + interval '1 month')::text")"

# --- The raced call: identical keys, cap = exactly one 1500-cent grant ---
call="select outcome from app.ps1b_materialise_entitlement('$biz'::uuid,'$client'::uuid,'$rule'::uuid,'$cfg'::uuid,'race-period','free_item','{}'::jsonb, now(), now()+interval '30 days', 1500, 1500, '$pstart'::timestamptz, '$pend'::timestamptz);"

start_epoch="$(q -c 'select extract(epoch from now())+2')"
worker() {
  q -c "select pg_sleep(greatest(0, $start_epoch - extract(epoch from clock_timestamp())));" >/dev/null 2>&1 || true
  q -c "$call" > "/tmp/v56_race_$1.out" 2>"/tmp/v56_race_$1.err" || echo "worker-$1 error" >"/tmp/v56_race_$1.out"
}
worker A & worker B & wait

echo "worker A: $(cat /tmp/v56_race_A.out 2>/dev/null)"
echo "worker B: $(cat /tmp/v56_race_B.out 2>/dev/null)"

# --- Assertions: exactly one entitlement, one reservation, counter == one grant ---
result="$(q <<SQL
select
  (select count(*) from public.program_entitlements where business_id='$biz' and client_id='$client' and rule_id='$rule')
  || '|' || (select count(*) from public.budget_reservations br join public.budget_periods bp on bp.id=br.budget_period_id where bp.business_id='$biz' and bp.rule_id='$rule')
  || '|' || (select coalesce(committed_cents,-1) from public.budget_periods where business_id='$biz' and rule_id='$rule');
SQL
)"
ent="${result%%|*}"; rest2="${result#*|}"; res="${rest2%%|*}"; committed="${rest2#*|}"
echo "entitlements=$ent reservations=$res committed_cents=$committed"

fail=0
[ "$ent" = "1" ] || { echo "FAIL: expected exactly 1 entitlement, got $ent" >&2; fail=1; }
[ "$res" = "1" ] || { echo "FAIL: expected exactly 1 reservation, got $res" >&2; fail=1; }
[ "$committed" = "1500" ] || { echo "FAIL: expected committed_cents=1500, got $committed" >&2; fail=1; }
# exactly one worker 'materialised', the other 'replayed'
outs="$(cat /tmp/v56_race_A.out /tmp/v56_race_B.out 2>/dev/null | tr '\n' ' ')"
case "$outs" in
  *materialised*replayed*|*replayed*materialised*) : ;;
  *) echo "FAIL: expected one materialised + one replayed, got: $outs" >&2; fail=1;;
esac
rm -f /tmp/v56_race_A.out /tmp/v56_race_A.err /tmp/v56_race_B.out /tmp/v56_race_B.err
if [ "$fail" = "0" ]; then echo "v56 concurrency: PASS (one winner, one clean replay)"; else exit 1; fi
