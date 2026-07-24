#!/bin/sh
# v67 checkout stored-value tender concurrency harness: two connections race the finaliser.
#   Round A (double-finalise one token): the SAME evaluation token + SAME finalise key, fired
#     together -> exactly ONE sale + ONE stored-value spend (paid draw), one caller ok + one
#     duplicate_ignored; the account balance is drawn exactly once.
#   Round B (two tokens race one balance): a customer whose balance covers ONE checkout; token2's
#     reservation supersedes token1's, then both tokens finalise together -> exactly ONE spend
#     (token2 wins), token1 fails typed stale_evaluation; the balance never over-draws.
# A real (non-synthetic) business is forced to authority='live' by direct UPDATE (postgres bypasses
# the guard). Run ONLY against a disposable rehearsal cluster (commits are NOT rolled back).
set -eu
if [ "${V67_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then echo "set V67_CONFIRM_DISPOSABLE_DB=YES for a disposable DB." >&2; exit 2; fi
if [ -z "${DATABASE_URL:-}" ]; then echo "DATABASE_URL required." >&2; exit 2; fi
if [ -z "${PGPASSWORD:-}" ]; then echo "PGPASSWORD required." >&2; exit 2; fi
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=10000"
q() { psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 "$@"; }

owner="$(q -c 'select gen_random_uuid()')"
slug="v67-conc-${owner%%-*}"
# All setup in ONE session so the is_local=false JWT persists across statements.
q <<SQL >/dev/null
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','$owner','authenticated','authenticated','$slug@example.test','',now(),now(),now());
select set_config('request.jwt.claim.sub','$owner',false);
select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false);
select public.create_business('V67 concurrency','$slug','test', array['dashboard','clients','sales','loyalty']);
-- force the (real) business live so stored value is spendable (test-only; the guard forbids 'live').
alter table public.sv_authority disable trigger sv_authority_guard;
update public.sv_authority set state='live'
  where business_id=(select id from public.businesses where slug='$slug') and asset='stored_value';
alter table public.sv_authority enable trigger sv_authority_guard;
insert into public.clients(business_id, full_name, phone)
  select id, 'cA', '+6590000301' from public.businesses where slug='$slug';
insert into public.clients(business_id, full_name, phone)
  select id, 'cB', '+6590000302' from public.businesses where slug='$slug';
insert into public.services(business_id, name, price_cents, duration_min)
  select id, 'sA', 4000, 30 from public.businesses where slug='$slug';
insert into public.services(business_id, name, price_cents, duration_min)
  select id, 'sB', 6000, 30 from public.businesses where slug='$slug';
select public.publish_sv_plan_version((select id from public.businesses where slug='$slug'),
  (public.create_sv_plan_draft((select id from public.businesses where slug='$slug'),
     jsonb_build_object('customer_facing_name','Conc','price_cents',10000,'bonus_cents',0,'customer_terms','1y'),
     gen_random_uuid())->>'draft_id')::uuid, 0, gen_random_uuid(), null);
SQL
biz="$(q -c "select id from public.businesses where slug='$slug'")"
branch="$(q -c "select id from public.branches where business_id='$biz' order by is_default desc nulls last limit 1")"
ver="$(q -c "select id from public.sv_plan_versions where business_id='$biz' order by version_no desc limit 1")"
cA="$(q -c "select id from public.clients where business_id='$biz' and full_name='cA'")"
cB="$(q -c "select id from public.clients where business_id='$biz' and full_name='cB'")"
sA="$(q -c "select id from public.services where business_id='$biz' and name='sA'")"
sB="$(q -c "select id from public.services where business_id='$biz' and name='sB'")"
for v in "$biz" "$branch" "$ver" "$cA" "$cB" "$sA" "$sB"; do case "$v" in ????????-????-????-????-????????????) ;; *) echo "setup failed ($v)" >&2; exit 1;; esac; done

jwt="select set_config('request.jwt.claim.sub','$owner',false); select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false);"
sql1() { q -c "$jwt $1" | tail -1; }   # run one authenticated statement, print only the final scalar

# mint 10000 into cA and cB
sql1 "select (public.record_sv_topup_sale('$biz'::uuid,'$branch'::uuid,'$cA'::uuid,'$ver'::uuid, jsonb_build_object('method','cash','amount_cents',10000,'currency','SGD'), gen_random_uuid()))->>'status';" >/dev/null
sql1 "select (public.record_sv_topup_sale('$biz'::uuid,'$branch'::uuid,'$cB'::uuid,'$ver'::uuid, jsonb_build_object('method','cash','amount_cents',10000,'currency','SGD'), gen_random_uuid()))->>'status';" >/dev/null

# lines helper
linesA="jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id','$sA'::uuid,'qty',1))"
linesB="jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id','$sB'::uuid,'qty',1))"

# ---------- Round A: double-finalise one token ----------
tokA="$(sql1 "select (public.evaluate_checkout('$biz'::uuid,'$branch'::uuid,'$cA'::uuid, $linesA, gen_random_uuid()))->>'evaluation_id';")"
sql1 "select (public.reserve_checkout_sv_tender('$biz'::uuid,'$tokA'::uuid, 4000, gen_random_uuid()))->>'reserved_cents';" >/dev/null
KA="v67cA-$(q -c 'select substr(md5(random()::text),1,10)')"
fireA() { q -c "$jwt select coalesce((public.record_cart_sale('$biz'::uuid,'$cA'::uuid,'$branch'::uuid,null,'cash','$KA',null,'$tokA'::uuid,true))->>'status','err');" 2>/dev/null || echo error; }

s="$(q -c 'select extract(epoch from now())+2')"
( q -c "select pg_sleep(greatest(0,$s-extract(epoch from clock_timestamp())));" >/dev/null 2>&1 || true; fireA >/tmp/v67_A1.out 2>&1 || echo error >/tmp/v67_A1.out ) &
( q -c "select pg_sleep(greatest(0,$s-extract(epoch from clock_timestamp())));" >/dev/null 2>&1 || true; fireA >/tmp/v67_A2.out 2>&1 || echo error >/tmp/v67_A2.out ) &
wait
a1="$(tail -1 /tmp/v67_A1.out)"; a2="$(tail -1 /tmp/v67_A2.out)"
salesA="$(q -c "select count(*) from public.sales s where s.business_id='$biz' and s.client_id='$cA' and s.kind='quick_sale' and s.reversal_of is null")"
spendA="$(q -c "select count(*) from public.sv_operations o where o.business_id='$biz' and o.operation_type='spend' and (o.result->>'account_id')::uuid=(select id from public.sv_accounts where business_id='$biz' and client_id='$cA')")"
availA="$(q -c "select app.sv_available_balance('$biz','$( q -c "select id from public.sv_accounts where business_id='$biz' and client_id='$cA'" )')" 2>/dev/null || echo NA)"

fail=0
echo "round A: r1=$a1 r2=$a2 sales=$salesA spends=$spendA"
[ "$salesA" = "1" ] || { echo "FAIL A: expected exactly one sale, got $salesA" >&2; fail=1; }
[ "$spendA" = "1" ] || { echo "FAIL A: expected exactly one SV spend, got $spendA" >&2; fail=1; }
case "$a1|$a2" in ok\|duplicate_ignored|duplicate_ignored\|ok) : ;; *) echo "FAIL A: expected one ok + one duplicate_ignored, got $a1|$a2" >&2; fail=1;; esac

# ---------- Round B: two tokens race one balance ----------
tokB1="$(sql1 "select (public.evaluate_checkout('$biz'::uuid,'$branch'::uuid,'$cB'::uuid, $linesB, gen_random_uuid()))->>'evaluation_id';")"
sql1 "select (public.reserve_checkout_sv_tender('$biz'::uuid,'$tokB1'::uuid, 6000, gen_random_uuid()))->>'reserved_cents';" >/dev/null
tokB2="$(sql1 "select (public.evaluate_checkout('$biz'::uuid,'$branch'::uuid,'$cB'::uuid, $linesB, gen_random_uuid()))->>'evaluation_id';")"
sql1 "select (public.reserve_checkout_sv_tender('$biz'::uuid,'$tokB2'::uuid, 6000, gen_random_uuid()))->>'reserved_cents';" >/dev/null   # supersedes tokB1
KB1="v67cB1-$(q -c 'select substr(md5(random()::text),1,10)')"; KB2="v67cB2-$(q -c 'select substr(md5(random()::text),1,10)')"
fireB() { q -c "$jwt select coalesce((public.record_cart_sale('$biz'::uuid,'$cB'::uuid,'$branch'::uuid,null,'cash','$2',null,'$1'::uuid,true))->>'status','err');" 2>&1; }

s="$(q -c 'select extract(epoch from now())+2')"
( q -c "select pg_sleep(greatest(0,$s-extract(epoch from clock_timestamp())));" >/dev/null 2>&1 || true; fireB "$tokB1" "$KB1" >/tmp/v67_B1.out 2>&1 || echo error >>/tmp/v67_B1.out ) &
( q -c "select pg_sleep(greatest(0,$s-extract(epoch from clock_timestamp())));" >/dev/null 2>&1 || true; fireB "$tokB2" "$KB2" >/tmp/v67_B2.out 2>&1 || echo error >>/tmp/v67_B2.out ) &
wait
spendB="$(q -c "select count(*) from public.sv_operations o where o.business_id='$biz' and o.operation_type='spend' and (o.result->>'account_id')::uuid=(select id from public.sv_accounts where business_id='$biz' and client_id='$cB')")"
acctB="$(q -c "select id from public.sv_accounts where business_id='$biz' and client_id='$cB'")"
availB="$(q -c "select app.sv_available_balance('$biz','$acctB')")"
# exactly one finalise prints the scalar 'ok'; the loser raises a typed stale_evaluation error.
oks="$(cat /tmp/v67_B1.out /tmp/v67_B2.out | grep -c '^ok$' || true)"
stales="$(cat /tmp/v67_B1.out /tmp/v67_B2.out | grep -ci 'stale_evaluation' || true)"
echo "round B: oks=$oks stales=$stales spends=$spendB avail=$availB"
[ "$spendB" = "1" ] || { echo "FAIL B: expected exactly one SV spend (one winner), got $spendB" >&2; fail=1; }
[ "$availB" = "4000" ] || { echo "FAIL B: balance must draw exactly one 6000 spend (10000-6000=4000), got $availB" >&2; fail=1; }
[ "$oks" = "1" ] || { echo "FAIL B: expected exactly one ok finalise, got $oks" >&2; fail=1; }
[ "$stales" = "1" ] || { echo "FAIL B: expected exactly one typed stale_evaluation loser, got $stales" >&2; fail=1; }

rm -f /tmp/v67_A1.out /tmp/v67_A2.out /tmp/v67_B1.out /tmp/v67_B2.out
if [ "$fail" = "0" ]; then
  echo "v67 checkout tender concurrency: PASS (double-finalise -> one spend; two tokens -> one winner + one typed stale)"
else exit 1; fi
