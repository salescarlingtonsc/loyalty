#!/bin/sh
# v68b SV settlement-reversal concurrency harness: two connections race the reversal paths.
#   Round A  (two settlement reversals of ONE settlement, DIFFERENT keys): fired together -> exactly
#     ONE restitution (one marker, one reverse op, value restored ONCE), one caller ok + one typed
#     over-reversal loser.
#   Round A2 (two settlement reversals, SAME key): fired together -> both ok (one materialises, one
#     replays the cached result); still exactly one marker + one reverse op + one restitution.
#   Round B  (a settlement reversal racing a chargeback of its funding top-up): one winner, the loser
#     typed, NO over-void and NO resurrection. Either order is legal - reversal-first leaves the
#     chargeback voiding the restored value with bad_debt 0; chargeback-first leaves the reversal typed
#     sv_settlement_charged_back. The paid lot ends at 0 in BOTH orders.
#   Round C  (a settlement reversal racing an expiry sweep on a case-(f)-shaped account): the two
#     serialize on the per-account advisory lock and the derived balance is ORDER-INDEPENDENT (paid
#     restored to mint, the past-expiry bonus ends at 0), and conservation holds.
# A real (non-synthetic) business is forced to authority='live' by direct UPDATE (postgres bypasses
# the guard). Run ONLY against a disposable rehearsal cluster (commits are NOT rolled back).
set -eu
if [ "${V68B_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then echo "set V68B_CONFIRM_DISPOSABLE_DB=YES for a disposable DB." >&2; exit 2; fi
if [ -z "${DATABASE_URL:-}" ]; then echo "DATABASE_URL required." >&2; exit 2; fi
if [ -z "${PGPASSWORD:-}" ]; then echo "PGPASSWORD required." >&2; exit 2; fi
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=10000"
q() { psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 "$@"; }

owner="$(q -c 'select gen_random_uuid()')"
slug="v68b-conc-${owner%%-*}"
q <<SQL >/dev/null
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','$owner','authenticated','authenticated','$slug@example.test','',now(),now(),now());
select set_config('request.jwt.claim.sub','$owner',false);
select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false);
select public.create_business('V68B concurrency','$slug','test', array['dashboard','clients','sales','loyalty']);
alter table public.sv_authority disable trigger sv_authority_guard;
update public.sv_authority set state='live'
  where business_id=(select id from public.businesses where slug='$slug') and asset='stored_value';
alter table public.sv_authority enable trigger sv_authority_guard;
insert into public.services(business_id,name,price_cents,duration_min)
  select id,'svc5000',5000,30 from public.businesses where slug='$slug';
insert into public.clients(business_id, full_name, phone)
  select id, v.n, v.p from public.businesses, (values('cA','+6590000901'),('cA2','+6590000902'),('cB','+6590000903'),('cBc','+6590000904'),('cF','+6590000905')) v(n,p)
   where slug='$slug';
select public.publish_sv_plan_version((select id from public.businesses where slug='$slug'),
  (public.create_sv_plan_draft((select id from public.businesses where slug='$slug'),
     jsonb_build_object('customer_facing_name','Conc','price_cents',5000,'bonus_cents',0,'customer_terms','1y'),
     gen_random_uuid())->>'draft_id')::uuid, 0, gen_random_uuid(), null);
SQL
biz="$(q -c "select id from public.businesses where slug='$slug'")"
branch="$(q -c "select id from public.branches where business_id='$biz' order by is_default desc nulls last limit 1")"
ver="$(q -c "select id from public.sv_plan_versions where business_id='$biz' order by version_no desc limit 1")"
svc="$(q -c "select id from public.services where business_id='$biz' and name='svc5000'")"
cA="$(q -c "select id from public.clients where business_id='$biz' and full_name='cA'")"
cA2="$(q -c "select id from public.clients where business_id='$biz' and full_name='cA2'")"
cB="$(q -c "select id from public.clients where business_id='$biz' and full_name='cB'")"
cBc="$(q -c "select id from public.clients where business_id='$biz' and full_name='cBc'")"
cF="$(q -c "select id from public.clients where business_id='$biz' and full_name='cF'")"
for v in "$biz" "$branch" "$ver" "$svc" "$cA" "$cA2" "$cB" "$cBc" "$cF"; do case "$v" in ????????-????-????-????-????????????) ;; *) echo "setup failed ($v)" >&2; exit 1;; esac; done

jwt="select set_config('request.jwt.claim.sub','$owner',false); select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false);"
fail=0

acct() { q -c "select id from public.sv_accounts where business_id='$biz' and client_id='$1'"; }
rem() { q -c "select coalesce(sum(cents),0) from public.sv_lot_movements where lot_id='$1'"; }
paidlot() { q -c "select id from public.sv_lots where business_id='$biz' and operation_id='$1' and class='paid'"; }
outstanding() { q -c "select app.sv_total_outstanding('$biz'::uuid,'$1'::uuid)"; }
markers() { q -c "select count(*) from public.checkout_sv_tender_reversals where business_id='$biz' and spend_operation_id='$1'"; }
revops() { q -c "select count(*) from public.sv_operations where business_id='$biz' and operation_type='reverse' and (result->>'spend_operation_id')='$1'"; }

# Mint a 5000 top-up and settle a 5000 SV-only checkout; prints the settlement spend_operation_id.
settle() { # $1 = client
  q >/dev/null <<SQL
$jwt
do \$s\$
declare v_tok uuid;
begin
  perform public.record_sv_topup_sale('$biz','$branch','$1','$ver',jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  v_tok := (public.evaluate_checkout('$biz','$branch','$1',jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id','$svc','qty',1)),gen_random_uuid())->>'evaluation_id')::uuid;
  perform public.reserve_checkout_sv_tender('$biz',v_tok,5000,gen_random_uuid());
  perform public.record_cart_sale('$biz','$1','$branch',null,'cash','conc-'||substr(md5(random()::text),1,12),null,v_tok,true);
end \$s\$;
SQL
  q -c "select spend_operation_id from public.checkout_sv_tenders where business_id='$biz' and status='consumed' and account_id=(select id from public.sv_accounts where business_id='$biz' and client_id='$1')"
}
topop() { q -c "select o.id from public.sv_operations o join public.sv_lots l on l.operation_id=o.id and l.business_id=o.business_id where o.business_id='$biz' and o.operation_type='topup' and l.account_id=(select id from public.sv_accounts where business_id='$biz' and client_id='$1') order by o.created_at limit 1"; }

fire() { # $1 = sql expression printing a scalar; $2 = out file; optional $3 = extra delay
  ( q -c "select pg_sleep(greatest(0,$START+${3:-0}-extract(epoch from clock_timestamp())));" >/dev/null 2>&1 || true
    q -c "$jwt $1" >"$2" 2>&1 || echo error >>"$2" ) &
}

# ---------- Round A: two settlement reversals of ONE settlement, DIFFERENT keys ----------
spA="$(settle "$cA")"; aA="$(acct "$cA")"
case "$spA" in ????????-????-????-????-????????????) ;; *) echo "settle A failed ($spA)" >&2; exit 1;; esac
revA="select coalesce((public.sv_reverse_spend('$biz'::uuid,'$spA'::uuid, gen_random_uuid()))->>'status','err');"
START="$(q -c 'select extract(epoch from now())+2')"
fire "$revA" /tmp/v68b_A1.out
fire "$revA" /tmp/v68b_A2.out
wait
oksA="$(cat /tmp/v68b_A1.out /tmp/v68b_A2.out | grep -c '^ok$' || true)"
overA="$(cat /tmp/v68b_A1.out /tmp/v68b_A2.out | grep -c 'already reversed' || true)"
echo "round A: oks=$oksA over_reversal=$overA markers=$(markers "$spA") revops=$(revops "$spA") outstanding=$(outstanding "$aA")"
[ "$oksA" = "1" ] || { echo "FAIL A: expected exactly one ok, got $oksA" >&2; fail=1; }
[ "$overA" = "1" ] || { echo "FAIL A: expected exactly one over-reversal loser, got $overA" >&2; fail=1; }
[ "$(markers "$spA")" = "1" ] || { echo "FAIL A: expected exactly one settlement-reversal marker" >&2; fail=1; }
[ "$(revops "$spA")" = "1" ] || { echo "FAIL A: expected exactly one reverse operation (one restitution)" >&2; fail=1; }
[ "$(outstanding "$aA")" = "5000" ] || { echo "FAIL A: value must be restored exactly once (outstanding 5000), got $(outstanding "$aA")" >&2; fail=1; }

# ---------- Round A2: two settlement reversals, SAME key ----------
spA2="$(settle "$cA2")"; aA2="$(acct "$cA2")"
KA2="$(q -c 'select gen_random_uuid()')"
revA2="select coalesce((public.sv_reverse_spend('$biz'::uuid,'$spA2'::uuid,'$KA2'::uuid))->>'status','err');"
START="$(q -c 'select extract(epoch from now())+2')"
fire "$revA2" /tmp/v68b_A3.out
fire "$revA2" /tmp/v68b_A4.out
wait
oksA2="$(cat /tmp/v68b_A3.out /tmp/v68b_A4.out | grep -c '^ok$' || true)"
echo "round A2: oks=$oksA2 markers=$(markers "$spA2") revops=$(revops "$spA2") outstanding=$(outstanding "$aA2")"
[ "$oksA2" = "2" ] || { echo "FAIL A2: a same-key replay must also return ok, got $oksA2" >&2; fail=1; }
[ "$(markers "$spA2")" = "1" ] || { echo "FAIL A2: expected exactly one marker" >&2; fail=1; }
[ "$(revops "$spA2")" = "1" ] || { echo "FAIL A2: expected exactly one reverse operation" >&2; fail=1; }
[ "$(outstanding "$aA2")" = "5000" ] || { echo "FAIL A2: value must be restored exactly once, got $(outstanding "$aA2")" >&2; fail=1; }

# ---------- Round B: a settlement reversal racing a chargeback of its funding top-up ----------
spB="$(settle "$cBc")"; aB="$(acct "$cBc")"; opB="$(topop "$cBc")"; pB="$(paidlot "$opB")"
revB="select coalesce((public.sv_reverse_spend('$biz'::uuid,'$spB'::uuid, gen_random_uuid()))->>'status','err');"
cbB="select coalesce((public.sv_chargeback_topup('$biz'::uuid,'$opB'::uuid,'v68b reversal vs chargeback', gen_random_uuid()))->>'status','err');"
START="$(q -c 'select extract(epoch from now())+2')"
fire "$revB" /tmp/v68b_B1.out
fire "$cbB" /tmp/v68b_B2.out
wait
revout="$(cat /tmp/v68b_B1.out)"; cbout="$(cat /tmp/v68b_B2.out)"
cbcount="$(q -c "select count(*) from public.sv_chargebacks where business_id='$biz' and topup_operation_id='$opB'")"
mk="$(markers "$spB")"
baddebt="$(q -c "select coalesce(max(bad_debt_cents),0) from public.sv_chargebacks where business_id='$biz' and topup_operation_id='$opB'")"
corr="$(q -c "select count(*) from public.sv_lot_movements where lot_id='$pB' and kind='correction'")"
echo "round B: rev=$revout cb=$cbout chargebacks=$cbcount markers=$mk bad_debt=$baddebt corrections=$corr paid_rem=$(rem "$pB")"
[ "$cbcount" = "1" ] || { echo "FAIL B: exactly one chargeback row expected, got $cbcount" >&2; fail=1; }
[ "$corr" -le 1 ] || { echo "FAIL B: the paid lot was over-voided ($corr corrections)" >&2; fail=1; }
[ "$(rem "$pB")" = "0" ] || { echo "FAIL B: the paid lot must end at 0 in either order (no resurrection), got $(rem "$pB")" >&2; fail=1; }
if [ "$mk" = "1" ]; then
  # reversal won: the 5000 was restored, then the chargeback voided it -> bad debt 0
  echo "$revout" | grep -q '^ok$' || { echo "FAIL B: marker present but reversal not ok: $revout" >&2; fail=1; }
  [ "$baddebt" = "0" ] || { echo "FAIL B: reversal-first -> chargeback bad_debt must be 0, got $baddebt" >&2; fail=1; }
elif [ "$mk" = "0" ]; then
  # chargeback won: the reversal is refused with the chargeback-specific error, 5000 booked as bad debt
  echo "$revout" | grep -q 'sv_settlement_charged_back' || { echo "FAIL B: chargeback-first -> reversal must be typed sv_settlement_charged_back, got: $revout" >&2; fail=1; }
  [ "$baddebt" = "5000" ] || { echo "FAIL B: chargeback-first -> bad_debt must be the 5000 spent as goods, got $baddebt" >&2; fail=1; }
else
  echo "FAIL B: expected 0 or 1 marker, got $mk" >&2; fail=1
fi

# ---------- Round C: a settlement reversal racing an expiry sweep (case-(f)-shaped account) ----------
# Seed directly (postgres bypasses RLS): paid 10000 (future expiry), bonus 1200 (PAST expiry).
aF="$(q -c "select app.sv_ensure_account('$biz'::uuid,'$cF'::uuid)")"
opF="$(q -c 'select gen_random_uuid()')"
pF="$(q -c 'select gen_random_uuid()')"
bF="$(q -c 'select gen_random_uuid()')"
q >/dev/null <<SQL
insert into public.sv_operations(id,business_id,operation_type,idempotency_key,request_hash)
values('$opF','$biz','topup',gen_random_uuid(), md5(gen_random_uuid()::text)||md5(gen_random_uuid()::text));
insert into public.sv_lots(id,business_id,account_id,operation_id,class,minted_cents,expiry_key,earned_seq)
values('$pF','$biz','$aF','$opF','paid',10000, now()+interval '365 days', nextval('app.sv_earned_seq'));
insert into public.sv_lot_movements(business_id,account_id,lot_id,operation_id,kind,cents) values('$biz','$aF','$pF','$opF','issue',10000);
insert into public.sv_lots(id,business_id,account_id,operation_id,class,minted_cents,expiry_key,earned_seq)
values('$bF','$biz','$aF','$opF','bonus',1200, now()-interval '1 day', nextval('app.sv_earned_seq'));
insert into public.sv_lot_movements(business_id,account_id,lot_id,operation_id,kind,cents) values('$biz','$aF','$bF','$opF','issue',1200);
SQL
# spend 1200 (bonus 128, paid 1072) as the owner
spF="$(q -c "$jwt select (public.sv_spend('$biz'::uuid,'$aF'::uuid,1200,gen_random_uuid()))->>'operation_id';" | tail -1)"
case "$spF" in ????????-????-????-????-????????????) ;; *) echo "spend F failed ($spF)" >&2; exit 1;; esac
revC="select coalesce((public.sv_reverse_spend('$biz'::uuid,'$spF'::uuid, gen_random_uuid()))->>'status','err');"
expC="select coalesce((public.sv_expire_due('$biz'::uuid, 1000))->>'status','err');"
START="$(q -c 'select extract(epoch from now())+2')"
fire "$revC" /tmp/v68b_C1.out
fire "$expC" /tmp/v68b_C2.out
wait
echo "round C: rev=$(cat /tmp/v68b_C1.out) expire=$(cat /tmp/v68b_C2.out) paid_rem=$(rem "$pF") bonus_rem=$(rem "$bF")"
[ "$(rem "$pF")" = "10000" ] || { echo "FAIL C: paid must be restored to 10000 in either order, got $(rem "$pF")" >&2; fail=1; }
[ "$(rem "$bF")" = "0" ] || { echo "FAIL C: the past-expiry bonus must end at 0 in either order, got $(rem "$bF")" >&2; fail=1; }

# ---------- global invariant sweep ----------
bad="$(q -c "select count(*) from public.sv_lots l where l.business_id='$biz' and (
  (select coalesce(sum(m.cents),0) from public.sv_lot_movements m where m.lot_id=l.id) < 0
  or (select coalesce(sum(m.cents),0) from public.sv_lot_movements m where m.lot_id=l.id) > l.minted_cents)")"
dupmk="$(q -c "select count(*) from (select tender_id from public.checkout_sv_tender_reversals where business_id='$biz' group by tender_id having count(*)>1) t")"
resmv="$(q -c "select count(*) from public.sv_lot_movements m join public.sv_reservations r on r.operation_id=m.operation_id where m.business_id='$biz'")"
echo "invariants: out_of_range_lots=$bad duplicate_markers=$dupmk reservation_movements=$resmv"
[ "$bad" = "0" ] || { echo "FAIL: a lot went below 0 or above its minted amount" >&2; fail=1; }
[ "$dupmk" = "0" ] || { echo "FAIL: a settlement was reversed more than once" >&2; fail=1; }
[ "$resmv" = "0" ] || { echo "FAIL: a reservation wrote a stored-value movement" >&2; fail=1; }

rm -f /tmp/v68b_A1.out /tmp/v68b_A2.out /tmp/v68b_A3.out /tmp/v68b_A4.out \
      /tmp/v68b_B1.out /tmp/v68b_B2.out /tmp/v68b_C1.out /tmp/v68b_C2.out
if [ "$fail" = "0" ]; then
  echo "v68b settlement-reversal concurrency: PASS (double reversal -> one restitution; reversal vs chargeback one-winner + no resurrection; reversal vs expiry order-independent)"
else exit 1; fi
