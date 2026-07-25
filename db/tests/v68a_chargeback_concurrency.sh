#!/bin/sh
# v68a chargeback / correction concurrency harness: two connections race the value paths.
#   Round A (two chargebacks, DIFFERENT keys): fired together -> exactly ONE chargeback effect, one
#     caller ok + one typed sv_already_charged_back; both lots voided exactly once (never twice).
#   Round A2 (two chargebacks, SAME key): fired together -> one materialises, one replays the cached
#     result; still exactly one chargeback row, one correction per lot, one bad_debt record.
#   Round B (chargeback racing a refund on ONE top-up): one winner, the loser typed, and the lot is
#     never over-voided. Either serialization is legal and the chargeback's reported
#     cash_already_refunded_cents must agree with the movement ledger in BOTH orders. Round B2 pins
#     the OTHER order explicitly (chargeback given a head start) so both branches are exercised on
#     every run, not just whichever one the scheduler happens to pick.
#   Round C (two whole-op refunds, DIFFERENT keys): cumulative cash never exceeds the cash collected
#     and exactly one cap-ledger row materialises (PS-0 §7 case (c-var) / §10.2).
# A real (non-synthetic) business is forced to authority='live' by direct UPDATE (postgres bypasses
# the guard). Run ONLY against a disposable rehearsal cluster (commits are NOT rolled back).
set -eu
if [ "${V68A_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then echo "set V68A_CONFIRM_DISPOSABLE_DB=YES for a disposable DB." >&2; exit 2; fi
if [ -z "${DATABASE_URL:-}" ]; then echo "DATABASE_URL required." >&2; exit 2; fi
if [ -z "${PGPASSWORD:-}" ]; then echo "PGPASSWORD required." >&2; exit 2; fi
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=10000"
q() { psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 "$@"; }

owner="$(q -c 'select gen_random_uuid()')"
slug="v68a-conc-${owner%%-*}"
# All setup in ONE session so the is_local=false JWT persists across statements.
q <<SQL >/dev/null
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','$owner','authenticated','authenticated','$slug@example.test','',now(),now(),now());
select set_config('request.jwt.claim.sub','$owner',false);
select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false);
select public.create_business('V68A concurrency','$slug','test', array['dashboard','clients','sales','loyalty']);
-- force the (real) business live so stored value is spendable (test-only; the guard forbids 'live').
alter table public.sv_authority disable trigger sv_authority_guard;
update public.sv_authority set state='live'
  where business_id=(select id from public.businesses where slug='$slug') and asset='stored_value';
alter table public.sv_authority enable trigger sv_authority_guard;
insert into public.clients(business_id, full_name, phone)
  select id, 'cA', '+6590000901' from public.businesses where slug='$slug';
insert into public.clients(business_id, full_name, phone)
  select id, 'cA2', '+6590000902' from public.businesses where slug='$slug';
insert into public.clients(business_id, full_name, phone)
  select id, 'cB', '+6590000903' from public.businesses where slug='$slug';
insert into public.clients(business_id, full_name, phone)
  select id, 'cC', '+6590000904' from public.businesses where slug='$slug';
insert into public.clients(business_id, full_name, phone)
  select id, 'cB2', '+6590000905' from public.businesses where slug='$slug';
select public.publish_sv_plan_version((select id from public.businesses where slug='$slug'),
  (public.create_sv_plan_draft((select id from public.businesses where slug='$slug'),
     jsonb_build_object('customer_facing_name','Conc','price_cents',10000,'bonus_cents',1200,'customer_terms','1y'),
     gen_random_uuid())->>'draft_id')::uuid, 0, gen_random_uuid(), null);
SQL
biz="$(q -c "select id from public.businesses where slug='$slug'")"
branch="$(q -c "select id from public.branches where business_id='$biz' order by is_default desc nulls last limit 1")"
ver="$(q -c "select id from public.sv_plan_versions where business_id='$biz' order by version_no desc limit 1")"
cA="$(q -c "select id from public.clients where business_id='$biz' and full_name='cA'")"
cA2="$(q -c "select id from public.clients where business_id='$biz' and full_name='cA2'")"
cB="$(q -c "select id from public.clients where business_id='$biz' and full_name='cB'")"
cC="$(q -c "select id from public.clients where business_id='$biz' and full_name='cC'")"
cB2="$(q -c "select id from public.clients where business_id='$biz' and full_name='cB2'")"
for v in "$biz" "$branch" "$ver" "$cA" "$cA2" "$cB" "$cB2" "$cC"; do case "$v" in ????????-????-????-????-????????????) ;; *) echo "setup failed ($v)" >&2; exit 1;; esac; done

jwt="select set_config('request.jwt.claim.sub','$owner',false); select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false);"
sql1() { q -c "$jwt $1" | tail -1; }   # run one authenticated statement, print only the final scalar

mint() {  # $1 = client id -> prints the top-up operation id
  sql1 "select (public.record_sv_topup_sale('$biz'::uuid,'$branch'::uuid,'$1'::uuid,'$ver'::uuid, jsonb_build_object('method','cash','amount_cents',10000,'currency','SGD'), gen_random_uuid()))->>'operation_id';"
}
paidlot() { q -c "select id from public.sv_lots where business_id='$biz' and operation_id='$1' and class='paid'"; }
bonuslot() { q -c "select id from public.sv_lots where business_id='$biz' and operation_id='$1' and class='bonus'"; }
rem() { q -c "select coalesce(sum(cents),0) from public.sv_lot_movements where lot_id='$1'"; }
cbcount() { q -c "select count(*) from public.sv_chargebacks where business_id='$biz' and topup_operation_id='$1'"; }
kindcount() { q -c "select count(*) from public.sv_lot_movements where lot_id='$1' and kind='$2'"; }

opA="$(mint "$cA")"; opA2="$(mint "$cA2")"; opB="$(mint "$cB")"; opB2="$(mint "$cB2")"; opC="$(mint "$cC")"
for v in "$opA" "$opA2" "$opB" "$opB2" "$opC"; do case "$v" in ????????-????-????-????-????????????) ;; *) echo "mint failed ($v)" >&2; exit 1;; esac; done
fail=0

fire() { # $1 = sql expression printing a scalar; writes stdout+stderr to $2; optional $3 = extra delay
  ( q -c "select pg_sleep(greatest(0,$START+${3:-0}-extract(epoch from clock_timestamp())));" >/dev/null 2>&1 || true
    q -c "$jwt $1" >"$2" 2>&1 || echo error >>"$2" ) &
}

# ---------- Round A: two chargebacks of ONE top-up, DIFFERENT keys ----------
cbA="select coalesce((public.sv_chargeback_topup('$biz'::uuid,'$opA'::uuid,'v68a concurrent chargeback', gen_random_uuid()))->>'status','err');"
START="$(q -c 'select extract(epoch from now())+2')"
fire "$cbA" /tmp/v68a_A1.out
fire "$cbA" /tmp/v68a_A2.out
wait
oks="$(cat /tmp/v68a_A1.out /tmp/v68a_A2.out | grep -c '^ok$' || true)"
dupes="$(cat /tmp/v68a_A1.out /tmp/v68a_A2.out | grep -c 'sv_already_charged_back' || true)"
pA="$(paidlot "$opA")"; bA="$(bonuslot "$opA")"
echo "round A: oks=$oks already_charged_back=$dupes chargebacks=$(cbcount "$opA") paid_rem=$(rem "$pA") bonus_rem=$(rem "$bA")"
[ "$(cbcount "$opA")" = "1" ] || { echo "FAIL A: expected exactly one chargeback row" >&2; fail=1; }
[ "$oks" = "1" ] || { echo "FAIL A: expected exactly one ok, got $oks" >&2; fail=1; }
[ "$dupes" = "1" ] || { echo "FAIL A: expected exactly one typed sv_already_charged_back loser, got $dupes" >&2; fail=1; }
[ "$(rem "$pA")" = "0" ] && [ "$(rem "$bA")" = "0" ] || { echo "FAIL A: both lots must be voided to 0" >&2; fail=1; }
[ "$(kindcount "$pA" correction)" = "1" ] || { echo "FAIL A: the paid lot was voided more than once" >&2; fail=1; }
[ "$(kindcount "$bA" correction)" = "1" ] || { echo "FAIL A: the bonus lot was voided more than once" >&2; fail=1; }
[ "$(kindcount "$pA" bad_debt)" = "1" ] || { echo "FAIL A: expected exactly one bad_debt record" >&2; fail=1; }

# ---------- Round A2: two chargebacks of ONE top-up, SAME key ----------
KA2="$(q -c 'select gen_random_uuid()')"
cbA2="select coalesce((public.sv_chargeback_topup('$biz'::uuid,'$opA2'::uuid,'v68a same-key chargeback','$KA2'::uuid))->>'status','err');"
START="$(q -c 'select extract(epoch from now())+2')"
fire "$cbA2" /tmp/v68a_A3.out
fire "$cbA2" /tmp/v68a_A4.out
wait
oks2="$(cat /tmp/v68a_A3.out /tmp/v68a_A4.out | grep -c '^ok$' || true)"
pA2="$(paidlot "$opA2")"; bA2="$(bonuslot "$opA2")"
echo "round A2: oks=$oks2 chargebacks=$(cbcount "$opA2") corrections=$(kindcount "$pA2" correction)/$(kindcount "$bA2" correction) bad_debt=$(kindcount "$pA2" bad_debt)"
[ "$oks2" = "2" ] || { echo "FAIL A2: a same-key replay must also return ok, got $oks2" >&2; fail=1; }
[ "$(cbcount "$opA2")" = "1" ] || { echo "FAIL A2: expected exactly one chargeback row" >&2; fail=1; }
[ "$(kindcount "$pA2" correction)" = "1" ] || { echo "FAIL A2: the same-key replay wrote a second paid void" >&2; fail=1; }
[ "$(kindcount "$bA2" correction)" = "1" ] || { echo "FAIL A2: the same-key replay wrote a second bonus void" >&2; fail=1; }
[ "$(kindcount "$pA2" bad_debt)" = "1" ] || { echo "FAIL A2: the same-key replay wrote a second bad_debt record" >&2; fail=1; }

# ---------- Round B: chargeback racing a refund on ONE top-up ----------
cbB="select coalesce((public.sv_chargeback_topup('$biz'::uuid,'$opB'::uuid,'v68a chargeback vs refund', gen_random_uuid()))->>'status','err');"
rfB="select coalesce((public.refund_sv_operation('$biz'::uuid,'$opB'::uuid, null, gen_random_uuid()))->>'status','err');"
START="$(q -c 'select extract(epoch from now())+2')"
fire "$cbB" /tmp/v68a_B1.out
fire "$rfB" /tmp/v68a_B2.out
wait
pB="$(paidlot "$opB")"; bB="$(bonuslot "$opB")"
refmv="$(kindcount "$pB" refund)"
cbrep="$(q -c "select cash_already_refunded_cents from public.sv_chargebacks where business_id='$biz' and topup_operation_id='$opB'")"
ledger="$(q -c "select coalesce(-sum(cents),0) from public.sv_lot_movements where lot_id='$pB' and kind='refund'")"
capped="$(q -c "select coalesce(max(cumulative_cash_cents),0) from public.sv_topup_cash_refunds where business_id='$biz' and topup_operation_id='$opB'")"
refout="$(cat /tmp/v68a_B2.out)"
echo "round B: chargebacks=$(cbcount "$opB") refund_movements=$refmv cb_reported=$cbrep ledger=$ledger capped=$capped paid_rem=$(rem "$pB") bonus_rem=$(rem "$bB")"
[ "$(cbcount "$opB")" = "1" ] || { echo "FAIL B: expected exactly one chargeback row" >&2; fail=1; }
[ "$cbrep" = "$ledger" ] || { echo "FAIL B: the reported already-refunded cash ($cbrep) disagrees with the ledger ($ledger)" >&2; fail=1; }
[ "$(rem "$pB")" = "0" ] && [ "$(rem "$bB")" = "0" ] || { echo "FAIL B: the lots must end at 0 in either order" >&2; fail=1; }
[ "$(kindcount "$pB" correction)" -le 1 ] || { echo "FAIL B: the paid lot was over-voided" >&2; fail=1; }
[ "$capped" -le 10000 ] || { echo "FAIL B: cumulative cash $capped exceeded the 10000 collected" >&2; fail=1; }
if [ "$refmv" = "0" ]; then
  [ "$cbrep" = "0" ] || { echo "FAIL B: no refund movement but the chargeback reported $cbrep" >&2; fail=1; }
  echo "$refout" | grep -q 'sv_charged_back' || { echo "FAIL B: the losing refund must be typed sv_charged_back, got: $refout" >&2; fail=1; }
elif [ "$refmv" = "1" ]; then
  [ "$cbrep" = "10000" ] || { echo "FAIL B: the refund won, so the chargeback must report 10000 already refunded, got $cbrep" >&2; fail=1; }
  echo "$refout" | grep -q '^ok$' || { echo "FAIL B: the winning refund must report ok, got: $refout" >&2; fail=1; }
else
  echo "FAIL B: expected 0 or 1 refund movement, got $refmv" >&2; fail=1
fi

# ---------- Round B2: the OTHER order, pinned (chargeback gets a head start) ----------
cbB2="select coalesce((public.sv_chargeback_topup('$biz'::uuid,'$opB2'::uuid,'v68a chargeback first', gen_random_uuid()))->>'status','err');"
rfB2="select coalesce((public.refund_sv_operation('$biz'::uuid,'$opB2'::uuid, null, gen_random_uuid()))->>'status','err');"
START="$(q -c 'select extract(epoch from now())+2')"
fire "$cbB2" /tmp/v68a_B3.out
fire "$rfB2" /tmp/v68a_B4.out 0.75
wait
pB2="$(paidlot "$opB2")"; bB2="$(bonuslot "$opB2")"
cbout2="$(cat /tmp/v68a_B3.out)"; refout2="$(cat /tmp/v68a_B4.out)"
echo "round B2: chargebacks=$(cbcount "$opB2") refund_movements=$(kindcount "$pB2" refund) paid_rem=$(rem "$pB2") bonus_rem=$(rem "$bB2")"
[ "$(cbcount "$opB2")" = "1" ] || { echo "FAIL B2: the head-start chargeback must materialise" >&2; fail=1; }
echo "$cbout2" | grep -q '^ok$' || { echo "FAIL B2: the head-start chargeback must report ok, got: $cbout2" >&2; fail=1; }
echo "$refout2" | grep -q 'sv_charged_back' || { echo "FAIL B2: the following refund must be typed sv_charged_back, got: $refout2" >&2; fail=1; }
[ "$(kindcount "$pB2" refund)" = "0" ] || { echo "FAIL B2: the refused refund still moved cash" >&2; fail=1; }
[ "$(kindcount "$pB2" correction)" = "1" ] || { echo "FAIL B2: the paid lot was voided more than once" >&2; fail=1; }
[ "$(rem "$pB2")" = "0" ] && [ "$(rem "$bB2")" = "0" ] || { echo "FAIL B2: both lots must be voided to 0" >&2; fail=1; }
[ "$(q -c "select cash_already_refunded_cents from public.sv_chargebacks where business_id='$biz' and topup_operation_id='$opB2'")" = "0" ] \
  || { echo "FAIL B2: no cash was refunded, so the chargeback must report 0" >&2; fail=1; }

# ---------- Round C: two whole-op refunds, DIFFERENT keys ----------
rfC="select coalesce((public.refund_sv_operation('$biz'::uuid,'$opC'::uuid, null, gen_random_uuid()))->>'status','err');"
START="$(q -c 'select extract(epoch from now())+2')"
fire "$rfC" /tmp/v68a_C1.out
fire "$rfC" /tmp/v68a_C2.out
wait
pC="$(paidlot "$opC")"; bC="$(bonuslot "$opC")"
cashC="$(q -c "select coalesce(-sum(cents),0) from public.sv_lot_movements where lot_id='$pC' and kind='refund'")"
rowsC="$(q -c "select count(*) from public.sv_topup_cash_refunds where business_id='$biz' and topup_operation_id='$opC'")"
capC="$(q -c "select coalesce(max(cumulative_cash_cents),0) from public.sv_topup_cash_refunds where business_id='$biz' and topup_operation_id='$opC'")"
echo "round C: cash_refunded=$cashC cap_rows=$rowsC cumulative=$capC paid_rem=$(rem "$pC") bonus_rem=$(rem "$bC")"
[ "$cashC" = "10000" ] || { echo "FAIL C: cumulative cash must be exactly the 10000 collected, got $cashC" >&2; fail=1; }
[ "$rowsC" = "1" ] || { echo "FAIL C: exactly one cash-bearing refund must materialise, got $rowsC" >&2; fail=1; }
[ "$capC" = "10000" ] || { echo "FAIL C: the cap ledger running total must be 10000, got $capC" >&2; fail=1; }
[ "$(rem "$pC")" = "0" ] && [ "$(rem "$bC")" = "0" ] || { echo "FAIL C: a closed operation must strand no cent" >&2; fail=1; }

# ---------- global invariant sweep ----------
bad="$(q -c "select count(*) from public.sv_lots l where l.business_id='$biz' and (
  (select coalesce(sum(m.cents),0) from public.sv_lot_movements m where m.lot_id=l.id) < 0
  or (select coalesce(sum(m.cents),0) from public.sv_lot_movements m where m.lot_id=l.id) > l.minted_cents)")"
badcap="$(q -c "select count(*) from public.sv_topup_cash_refunds where business_id='$biz' and cumulative_cash_cents > cash_collected_cents")"
badbd="$(q -c "select count(*) from public.sv_lot_movements m join public.sv_lots l on l.id=m.lot_id where l.business_id='$biz' and m.kind='bad_debt' and m.cents <> 0")"
echo "invariants: out_of_range_lots=$bad over_cap_rows=$badcap nonzero_bad_debt=$badbd"
[ "$bad" = "0" ] || { echo "FAIL: a lot went below 0 or above its minted amount" >&2; fail=1; }
[ "$badcap" = "0" ] || { echo "FAIL: a cap row exceeded the cash collected" >&2; fail=1; }
[ "$badbd" = "0" ] || { echo "FAIL: a bad_debt movement carried non-zero cents" >&2; fail=1; }

rm -f /tmp/v68a_A1.out /tmp/v68a_A2.out /tmp/v68a_A3.out /tmp/v68a_A4.out \
      /tmp/v68a_B1.out /tmp/v68a_B2.out /tmp/v68a_B3.out /tmp/v68a_B4.out /tmp/v68a_C1.out /tmp/v68a_C2.out
if [ "$fail" = "0" ]; then
  echo "v68a chargeback/correction concurrency: PASS (one chargeback effect; refund race one-winner + typed loser; cash cap never breached)"
else exit 1; fi
