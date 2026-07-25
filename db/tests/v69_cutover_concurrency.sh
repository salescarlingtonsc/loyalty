#!/bin/sh
# v69 CONTROLLED-CUTOVER concurrency harness: two connections race the go-live.
#
#   Round A  (two cutovers of ONE business, DIFFERENT keys): fired together -> exactly ONE
#     transition. One caller gets ok, the other the typed sv_already_live; exactly one
#     sv_cutover_events row, one 'cutover' sv_operations row and one SV_CUTOVER audit row exist.
#     This is the load-bearing round: a business must go live at most once, ever.
#   Round A2 (two cutovers of ANOTHER business, SAME key): fired together -> both ok (one
#     materialises, the other replays the cached envelope result); still exactly one event/op/audit.
#   Round B  (PS-0 §9 case (b): concurrent spend vs refund on the genuinely live business from
#     Round A). $100 paid + $12 bonus, a $30 spend racing a $100 whole-refund. Either order is
#     legal and the invariant is the same in both: cumulative cash-out <= the 10 000 paid, no lot
#     leaves [0, minted], and the losing operation is a TYPED refusal rather than a partial write.
#     Spend-first leaves paid 7 321 (bonus draw floor(3000*1200/11200)=321, paid draw 2 679) and a
#     follow-up whole refund pays exactly $73.21; refund-first leaves the spend refused.
#
# UNLIKE db/tests/v68b_reversal_concurrency.sh THIS HARNESS NEVER FORCES 'live'. The whole point of
# v69 is that 'live' is reachable only through public.sv_cutover_business, so the businesses here go
# live by actually being designated by a super admin and cut over by their owner.
#
# The harness COMMITS (it needs two connections), so run it ONLY against a disposable rehearsal
# cluster that has been replayed through v69. It revokes each designation when a round is done, so
# the platform-wide "one active designation" singleton index does not block a later round or run.
set -eu
if [ "${V69_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then echo "set V69_CONFIRM_DISPOSABLE_DB=YES for a disposable DB." >&2; exit 2; fi
if [ -z "${DATABASE_URL:-}" ]; then echo "DATABASE_URL required." >&2; exit 2; fi
if [ -z "${PGPASSWORD:-}" ]; then echo "PGPASSWORD required." >&2; exit 2; fi
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=10000"
q() { psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 "$@"; }

sa="$(q -c 'select gen_random_uuid()')"
o1="$(q -c 'select gen_random_uuid()')"
o2="$(q -c 'select gen_random_uuid()')"
tag="${o1%%-*}"
s1="v69-conc-a-$tag"
s2="v69-conc-b-$tag"

# ---------- setup: one super admin (the designator) and two owner-run businesses ----------
q <<SQL >/dev/null
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','$sa','authenticated','authenticated','$s1-sa@example.test','',now(),now(),now()),
      ('00000000-0000-0000-0000-000000000000','$o1','authenticated','authenticated','$s1-owner@example.test','',now(),now(),now()),
      ('00000000-0000-0000-0000-000000000000','$o2','authenticated','authenticated','$s2-owner@example.test','',now(),now(),now());
insert into public.super_admins(user_id,email,note)
values('$sa','$s1-sa@example.test','v69 concurrency harness designator');
select set_config('request.jwt.claim.sub','$o1',false);
select set_config('request.jwt.claims', json_build_object('sub','$o1','role','authenticated')::text, false);
select public.create_business('V69 concurrency A','$s1','test', array['dashboard','clients','sales','loyalty']);
select set_config('request.jwt.claim.sub','$o2',false);
select set_config('request.jwt.claims', json_build_object('sub','$o2','role','authenticated')::text, false);
select public.create_business('V69 concurrency B','$s2','test', array['dashboard','clients','sales','loyalty']);
SQL

b1="$(q -c "select id from public.businesses where slug='$s1'")"
b2="$(q -c "select id from public.businesses where slug='$s2'")"
for v in "$b1" "$b2"; do case "$v" in ????????-????-????-????-????????????) ;; *) echo "setup failed ($v)" >&2; exit 1;; esac; done

# The JWT is established through a DO block so it prints nothing: a raced worker's output file must
# contain the operation's own result (or its error), never the session-setup rows.
jwt() { echo "do \$j\$ begin perform set_config('request.jwt.claim.sub','$1',false); perform set_config('request.jwt.claims', json_build_object('sub','$1','role','authenticated')::text, false); end \$j\$;"; }
jwt_sa="$(jwt "$sa")"; jwt_o1="$(jwt "$o1")"; jwt_o2="$(jwt "$o2")"
fail=0

# Bring a business to the exact pre-cutover state the RPC demands, then designate it.
prepare() { # $1 = business, $2 = owner jwt block
  q >/dev/null <<SQL
$2
select public.set_sv_authority_state('$1','stored_value','shadow_testing','v69 concurrency harness');
select public.run_sv_reconciliation('$1');
SQL
  q >/dev/null <<SQL
$jwt_sa
select public.set_sv_cutover_designation('$1', true, 'v69 concurrency harness pilot designation');
SQL
}
undesignate() { q >/dev/null <<SQL
$jwt_sa
select public.set_sv_cutover_designation('$1', false, 'v69 concurrency harness releases the pilot slot');
SQL
}
state() { q -c "select state from public.sv_authority where business_id='$1' and asset='stored_value'"; }
events() { q -c "select count(*) from public.sv_cutover_events where business_id='$1'"; }
ops() { q -c "select count(*) from public.sv_operations where business_id='$1' and operation_type='cutover'"; }
audits() { q -c "select count(*) from public.audit_log where business_id='$1' and action='SV_CUTOVER'"; }
hash_for() { q -c "$1 select (public.preview_sv_cutover('$2'))->>'evidence_hash';" | tail -1; }
ready_for() { q -c "$1 select (public.preview_sv_cutover('$2'))->>'ready';" | tail -1; }

fire() { # $1 = jwt block, $2 = sql expression printing a scalar, $3 = out file
  ( q -c "select pg_sleep(greatest(0,$START-extract(epoch from clock_timestamp())));" >/dev/null 2>&1 || true
    q -c "$1 $2" >"$3" 2>&1 || echo error >>"$3" ) &
}

# ---------- Round A: two cutovers of ONE business, DIFFERENT keys ----------
prepare "$b1" "$jwt_o1"
[ "$(ready_for "$jwt_o1" "$b1")" = "true" ] || { echo "FAIL A: the preview is not ready before the race: $(ready_for "$jwt_o1" "$b1")" >&2; exit 1; }
h1="$(hash_for "$jwt_o1" "$b1")"
cutA="select coalesce((public.sv_cutover_business('$b1'::uuid,'v69 concurrency round A go-live','$h1', gen_random_uuid()))->>'status','err');"
START="$(q -c 'select extract(epoch from now())+2')"
fire "$jwt_o1" "$cutA" /tmp/v69_A1.out
fire "$jwt_o1" "$cutA" /tmp/v69_A2.out
wait
oksA="$(cat /tmp/v69_A1.out /tmp/v69_A2.out | grep -c '^ok$' || true)"
liveA="$(cat /tmp/v69_A1.out /tmp/v69_A2.out | grep -c 'sv_already_live' || true)"
echo "round A: oks=$oksA already_live=$liveA state=$(state "$b1") events=$(events "$b1") ops=$(ops "$b1") audits=$(audits "$b1")"
[ "$oksA" = "1" ] || { echo "FAIL A: expected exactly one ok, got $oksA" >&2; fail=1; }
[ "$liveA" = "1" ] || { echo "FAIL A: expected exactly one typed sv_already_live loser, got $liveA" >&2; fail=1; }
[ "$(state "$b1")" = "live" ] || { echo "FAIL A: the business is not live" >&2; fail=1; }
[ "$(events "$b1")" = "1" ] || { echo "FAIL A: expected exactly ONE cutover event (one transition)" >&2; fail=1; }
[ "$(ops "$b1")" = "1" ] || { echo "FAIL A: expected exactly one cutover operation" >&2; fail=1; }
[ "$(audits "$b1")" = "1" ] || { echo "FAIL A: expected exactly one SV_CUTOVER audit row" >&2; fail=1; }
undesignate "$b1"

# ---------- Round A2: two cutovers of ANOTHER business, SAME key ----------
prepare "$b2" "$jwt_o2"
h2="$(hash_for "$jwt_o2" "$b2")"
K2="$(q -c 'select gen_random_uuid()')"
cutA2="select coalesce((public.sv_cutover_business('$b2'::uuid,'v69 concurrency round A2 go-live','$h2','$K2'::uuid))->>'status','err');"
START="$(q -c 'select extract(epoch from now())+2')"
fire "$jwt_o2" "$cutA2" /tmp/v69_A3.out
fire "$jwt_o2" "$cutA2" /tmp/v69_A4.out
wait
oksA2="$(cat /tmp/v69_A3.out /tmp/v69_A4.out | grep -c '^ok$' || true)"
echo "round A2: oks=$oksA2 state=$(state "$b2") events=$(events "$b2") ops=$(ops "$b2") audits=$(audits "$b2")"
[ "$oksA2" = "2" ] || { echo "FAIL A2: a same-key replay must also return ok, got $oksA2" >&2; fail=1; }
[ "$(state "$b2")" = "live" ] || { echo "FAIL A2: the business is not live" >&2; fail=1; }
[ "$(events "$b2")" = "1" ] || { echo "FAIL A2: expected exactly ONE cutover event" >&2; fail=1; }
[ "$(ops "$b2")" = "1" ] || { echo "FAIL A2: expected exactly one cutover operation" >&2; fail=1; }
[ "$(audits "$b2")" = "1" ] || { echo "FAIL A2: expected exactly one SV_CUTOVER audit row" >&2; fail=1; }
undesignate "$b2"

# ---------- Round B: PS-0 case (b) - concurrent spend vs refund on the live business ----------
q >/dev/null <<SQL
$jwt_o1
insert into public.clients(business_id, full_name, phone) values ('$b1','caseB','+6592$(printf '%06d' $((RANDOM % 1000000)))');
select public.publish_sv_plan_version('$b1',
  (public.create_sv_plan_draft('$b1',
     jsonb_build_object('customer_facing_name','CaseB','price_cents',10000,'bonus_cents',1200,'customer_terms','1y'),
     gen_random_uuid())->>'draft_id')::uuid, 0, gen_random_uuid(), null);
SQL
cB="$(q -c "select id from public.clients where business_id='$b1' and full_name='caseB'")"
branch="$(q -c "select id from public.branches where business_id='$b1' order by is_default desc nulls last limit 1")"
ver="$(q -c "select id from public.sv_plan_versions where business_id='$b1' order by version_no desc limit 1")"
topop="$(q -c "$jwt_o1 select (public.record_sv_topup_sale('$b1'::uuid,'$branch'::uuid,'$cB'::uuid,'$ver'::uuid, jsonb_build_object('method','cash','amount_cents',10000,'currency','SGD'), gen_random_uuid()))->>'operation_id';" | tail -1)"
acct="$(q -c "select id from public.sv_accounts where business_id='$b1' and client_id='$cB'")"
paidlot="$(q -c "select id from public.sv_lots where business_id='$b1' and operation_id='$topop' and class='paid'")"
case "$topop" in ????????-????-????-????-????????????) ;; *) echo "case (b) mint failed ($topop)" >&2; exit 1;; esac

spendB="select coalesce((public.sv_spend('$b1'::uuid,'$acct'::uuid,3000,gen_random_uuid()))->>'status','err');"
refundB="select coalesce((public.refund_sv_operation('$b1'::uuid,'$topop'::uuid,10000,gen_random_uuid()))->>'status','err');"
START="$(q -c 'select extract(epoch from now())+2')"
fire "$jwt_o1" "$spendB" /tmp/v69_B1.out
fire "$jwt_o1" "$refundB" /tmp/v69_B2.out
wait
spout="$(cat /tmp/v69_B1.out)"; rfout="$(cat /tmp/v69_B2.out)"
rem() { q -c "select coalesce(sum(cents),0) from public.sv_lot_movements where lot_id='$1'"; }
cashout="$(q -c "select coalesce(sum((o.result->>'cash_cents')::int),0) from public.sv_operations o where o.business_id='$b1' and o.operation_type='refund'")"
echo "round B: spend=$spout refund=$rfout paid_rem=$(rem "$paidlot") cash_out=$cashout"
# PS-0 §10 invariant 2: cumulative cash out can never exceed the paid amount, in EITHER order.
[ "$cashout" -le 10000 ] || { echo "FAIL B: cumulative cash-out $cashout exceeded the 10000 paid" >&2; fail=1; }
# A whole refund pays what REMAINS, so the two legal orders are distinguished by the cash figure.
if [ "$cashout" = "7321" ]; then
  # spend-first: bonus draw floor(3000*1200/11200)=321, paid draw 2679 -> the whole refund pays 7321
  echo "$spout" | grep -q '^ok$' || { echo "FAIL B: cash 7321 implies spend-first, but the spend did not succeed: $spout" >&2; fail=1; }
  echo "$rfout" | grep -q '^ok$' || { echo "FAIL B: cash 7321 implies the refund succeeded, got: $rfout" >&2; fail=1; }
  [ "$(rem "$paidlot")" = "0" ] || { echo "FAIL B: spend-first must close the paid lot at 0, got $(rem "$paidlot")" >&2; fail=1; }
  echo "  PS-0 case (b) spend-first: cash \$73.21 exactly"
elif [ "$cashout" = "10000" ]; then
  # refund-first: the whole 10000 is paid out and the spend must be a TYPED refusal, not a partial write
  echo "$rfout" | grep -q '^ok$' || { echo "FAIL B: cash 10000 implies refund-first, but the refund did not succeed: $rfout" >&2; fail=1; }
  echo "$spout" | grep -q '^ok$' && { echo "FAIL B: refund-first must refuse the spend, got: $spout" >&2; fail=1; }
  [ "$(rem "$paidlot")" = "0" ] || { echo "FAIL B: refund-first must close the paid lot at 0, got $(rem "$paidlot")" >&2; fail=1; }
  echo "  PS-0 case (b) refund-first: cash \$100.00 and the spend rejected"
else
  echo "FAIL B: cash-out $cashout is neither the spend-first 7321 nor the refund-first 10000" >&2; fail=1
fi

# ---------- global invariants ----------
bad="$(q -c "select count(*) from public.sv_lots l where l.business_id in ('$b1','$b2') and (
  (select coalesce(sum(m.cents),0) from public.sv_lot_movements m where m.lot_id=l.id) < 0
  or (select coalesce(sum(m.cents),0) from public.sv_lot_movements m where m.lot_id=l.id) > l.minted_cents)")"
dupev="$(q -c "select count(*) from (select business_id from public.sv_cutover_events group by business_id having count(*)>1) t")"
extralive="$(q -c "select count(*) from public.sv_authority a where a.state='live' and a.business_id not in ('$b1','$b2')")"
echo "invariants: out_of_range_lots=$bad businesses_with_two_cutovers=$dupev unrelated_live=$extralive"
[ "$bad" = "0" ] || { echo "FAIL: a lot went below 0 or above its minted amount" >&2; fail=1; }
[ "$dupev" = "0" ] || { echo "FAIL: a business recorded more than one cutover" >&2; fail=1; }
[ "$extralive" = "0" ] || { echo "FAIL: an unrelated business went live" >&2; fail=1; }

rm -f /tmp/v69_A1.out /tmp/v69_A2.out /tmp/v69_A3.out /tmp/v69_A4.out /tmp/v69_B1.out /tmp/v69_B2.out
if [ "$fail" = "0" ]; then
  echo "v69 controlled-cutover concurrency: PASS (two concurrent cutovers -> exactly one transition; same-key replay -> one transition, two oks; PS-0 case (b) invariants hold)"
else exit 1; fi
