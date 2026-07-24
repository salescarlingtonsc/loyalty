#!/bin/sh
# v66 top-up concurrency harness: two connections race real top-ups.
#   Round A (idempotency): SAME idempotency key, fired together -> exactly ONE operation, ONE pair of
#     lots/movements/payment, both callers return the same result.
#   Round B (capacity): a fresh customer, plan max_balance = one purchase, DISTINCT keys -> exactly ONE
#     winner; the account holds exactly one purchase; never exceeds the cap.
# Shadow_testing + structurally-synthetic business/customer + method='test' (no real value, no cutover).
# Run ONLY against a disposable rehearsal cluster (commits are NOT rolled back).
set -eu
if [ "${V66_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then echo "set V66_CONFIRM_DISPOSABLE_DB=YES for a disposable DB." >&2; exit 2; fi
if [ -z "${DATABASE_URL:-}" ]; then echo "DATABASE_URL required." >&2; exit 2; fi
if [ -z "${PGPASSWORD:-}" ]; then echo "PGPASSWORD required." >&2; exit 2; fi
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=10000"
q() { psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 "$@"; }

owner="$(q -c 'select gen_random_uuid()')"
slug="v66-conc-${owner%%-*}"
# All setup in ONE session so the is_local=false JWT persists across statements.
q <<SQL >/dev/null
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','$owner','authenticated','authenticated','$slug@example.test','',now(),now(),now());
select set_config('request.jwt.claim.sub','$owner',false);
select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false);
select public.create_business('V66 concurrency','$slug','test', array['dashboard','clients','sales','loyalty']);
update public.businesses set is_synthetic = true where slug = '$slug';                       -- postgres bypasses the guard
insert into public.clients(business_id, full_name, phone, is_synthetic)
  select id, 'c idem', '+6590000011', true from public.businesses where slug='$slug';
insert into public.clients(business_id, full_name, phone, is_synthetic)
  select id, 'c cap',  '+6590000012', true from public.businesses where slug='$slug';
select public.set_sv_authority_state((select id from public.businesses where slug='$slug'),'stored_value','shadow_testing','canary');
select public.publish_sv_plan_version((select id from public.businesses where slug='$slug'),
  (public.create_sv_plan_draft((select id from public.businesses where slug='$slug'),
     jsonb_build_object('customer_facing_name','Conc','price_cents',10000,'bonus_cents',0,'customer_terms','1y','max_balance_cents',10000),
     gen_random_uuid())->>'draft_id')::uuid, 0, gen_random_uuid(), null);
SQL
biz="$(q -c "select id from public.businesses where slug='$slug'")"
branch="$(q -c "select id from public.branches where business_id='$biz' order by is_default desc nulls last limit 1")"
ver="$(q -c "select id from public.sv_plan_versions where business_id='$biz' order by version_no desc limit 1")"
c_idem="$(q -c "select id from public.clients where business_id='$biz' and full_name='c idem'")"
c_cap="$(q -c "select id from public.clients where business_id='$biz' and full_name='c cap'")"
for v in "$biz" "$branch" "$ver" "$c_idem" "$c_cap"; do case "$v" in ????????-????-????-????-????????????) ;; *) echo "setup failed ($v)" >&2; exit 1;; esac; done

jwt="select set_config('request.jwt.claim.sub','$owner',false); select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false);"
fire() { # $1 client, $2 key-expr -> prints status (last line)
  q -c "$jwt select (public.record_sv_topup_sale('$biz'::uuid,'$branch'::uuid,'$1'::uuid,'$ver'::uuid, jsonb_build_object('method','test','amount_cents',10000,'currency','SGD'), $2))->>'status';"
}
race() { # $1 client $2 keyexprA $3 keyexprB $4 tag
  local s; s="$(q -c 'select extract(epoch from now())+2')"
  ( q -c "select pg_sleep(greatest(0, $s - extract(epoch from clock_timestamp())));" >/dev/null 2>&1 || true; fire "$1" "$2" >"/tmp/v66_${4}_A.out" 2>&1 || echo error >"/tmp/v66_${4}_A.out" ) &
  ( q -c "select pg_sleep(greatest(0, $s - extract(epoch from clock_timestamp())));" >/dev/null 2>&1 || true; fire "$1" "$3" >"/tmp/v66_${4}_B.out" 2>&1 || echo error >"/tmp/v66_${4}_B.out" ) &
  wait
}

fail=0
# Round A: idempotency (same key)
k="'$(q -c 'select gen_random_uuid()')'::uuid"
race "$c_idem" "$k" "$k" idem
a="$(tail -1 /tmp/v66_idem_A.out)"; b="$(tail -1 /tmp/v66_idem_B.out)"
ops="$(q -c "select count(*) from public.sv_operations o where o.business_id='$biz' and o.operation_type='topup' and exists(select 1 from public.sv_lots l where l.operation_id=o.id and l.account_id in (select id from public.sv_accounts where business_id='$biz' and client_id='$c_idem'))")"
lots="$(q -c "select count(*) from public.sv_lots where account_id in (select id from public.sv_accounts where business_id='$biz' and client_id='$c_idem')")"
pays="$(q -c "select count(*) from public.sv_topup_payments where business_id='$biz' and client_id='$c_idem'")"
echo "idempotency: A=$a B=$b ops=$ops lots=$lots payments=$pays"
[ "$a" = "ok" ] && [ "$b" = "ok" ] || { echo "FAIL idem: both should be ok" >&2; fail=1; }
[ "$ops" = "1" ] && [ "$lots" = "1" ] && [ "$pays" = "1" ] || { echo "FAIL idem: expected 1 op/1 lot/1 payment" >&2; fail=1; }

# Round B: capacity (distinct keys, max_balance = one purchase)
race "$c_cap" "gen_random_uuid()" "gen_random_uuid()" cap
a="$(tail -1 /tmp/v66_cap_A.out)"; b="$(tail -1 /tmp/v66_cap_B.out)"
winners="$(q -c "select count(*) from public.sv_operations o where o.business_id='$biz' and o.operation_type='topup' and exists(select 1 from public.sv_lots l where l.operation_id=o.id and l.account_id in (select id from public.sv_accounts where business_id='$biz' and client_id='$c_cap'))")"
total="$(q -c "select coalesce(sum(cents),0) from public.sv_lot_movements where account_id in (select id from public.sv_accounts where business_id='$biz' and client_id='$c_cap')")"
echo "capacity: A=$a B=$b winners=$winners total=$total"
[ "$winners" = "1" ] || { echo "FAIL cap: expected exactly one winning top-up, got $winners" >&2; fail=1; }
[ "$total" = "10000" ] || { echo "FAIL cap: account must hold exactly one purchase (10000), got $total" >&2; fail=1; }
case "$a|$b" in ok\|*error*|*error*\|ok|ok\|*22023*|*22023*\|ok) : ;; *) echo "note: outcomes A=$a B=$b (one ok, one refused expected)";; esac

rm -f /tmp/v66_idem_A.out /tmp/v66_idem_B.out /tmp/v66_cap_A.out /tmp/v66_cap_B.out
if [ "$fail" = "0" ]; then echo "v66 topup concurrency: PASS (one op under same key; one winner under capacity)"; else exit 1; fi
