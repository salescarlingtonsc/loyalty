#!/bin/sh
# v58 PS-1C concurrency harness: two two-connection races against the checkout kernel.
#   RACE 1 — the SAME evaluation token finalised concurrently with DIFFERENT keys:
#            exactly ONE sale, the token consumed exactly once, the loser gets a clean
#            stale_evaluation (never a double-sell).
#   RACE 2 — two DIFFERENT evaluations racing the LAST budget slot of a cap=one rule:
#            exactly ONE discounted sale + one stale_evaluation (the atomic budget
#            re-check under the sorted period lock catches the loser); committed_cents
#            equals exactly one commitment and Σreservations reconciles.
# Run ONLY against a disposable rehearsal cluster. Commits are made and NOT rolled
# back, so the database must be throwaway.
set -eu

if [ "${V58_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V58_CONFIRM_DISPOSABLE_DB=YES for a disposable database." >&2
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
slug="v58-conc-$owner_prefix"

# --- Setup: disposable business + published discount config + catalog + tokens ---
# Session GUCs (is_local=false) persist across the statements of this one psql
# session so the SECURITY DEFINER RPCs see auth.uid()=owner.
q <<SQL >/dev/null
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','$owner','authenticated','authenticated','$slug@example.test','',now(),now(),now());
select set_config('request.jwt.claim.sub','$owner',false);
select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false);
select public.create_business('V58 concurrency','$slug','test', array['dashboard','clients','sales','loyalty']);
insert into public.clients(business_id,full_name,phone)
  select id,'v58 conc','+6590000088' from public.businesses where slug='$slug';
insert into public.services(business_id,name,price_cents,duration_min)
  select id,'v58 conc 5000',5000,30 from public.businesses where slug='$slug';
insert into public.services(business_id,name,price_cents,duration_min)
  select id,'v58 conc 2000',2000,30 from public.businesses where slug='$slug';
-- Publish a discount config: R_plain (bill 10% at 5000) + R_cap (bill 1000 at 4000, cap 1000).
do \$seed\$
declare v_biz uuid; v_base uuid; v_draft uuid; v_hash text; v_r1 uuid:=gen_random_uuid(); v_r2 uuid:=gen_random_uuid();
begin
  select id, active_config_version_id into v_biz, v_base from public.businesses where slug='$slug';
  v_draft := (public.create_loyalty_config_draft(v_biz, v_base, 'v58-conc-rules')::jsonb->>'version_id')::uuid;
  select snapshot_hash into v_hash from public.firm_config_versions where id=v_draft;
  perform public.save_program_rule_draft(v_draft, v_r1, jsonb_build_object(
    'name','R plain 10pct 5000','when_event','sale.completed','active',true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field','amount_cents','op','eq','value',5000)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type','apply_discount_pct','discount_pct',10))), v_hash);
  select snapshot_hash into v_hash from public.firm_config_versions where id=v_draft;
  perform public.save_program_rule_draft(v_draft, v_r2, jsonb_build_object(
    'name','R cap 1000 at 4000','when_event','sale.completed','active',true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field','amount_cents','op','eq','value',4000)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type','apply_discount_amount','amount_cents',1000)),
    'with_params', jsonb_build_object('budget_cap_cents',1000,'budget_period','monthly')), v_hash);
  perform public.publish_loyalty_config(v_draft);
end \$seed\$;
SQL

biz="$(q -c "select id from public.businesses where slug='$slug'")"
client="$(q -c "select id from public.clients where business_id='$biz' order by created_at limit 1")"
branch="$(q -c "select id from public.branches where business_id='$biz' and active order by is_default desc, created_at limit 1")"
svc5000="$(q -c "select id from public.services where business_id='$biz' and name='v58 conc 5000'")"
svc2000="$(q -c "select id from public.services where business_id='$biz' and name='v58 conc 2000'")"
caprule="$(q -c "select rule_id from public.program_rules pr join public.businesses b on b.active_config_version_id=pr.config_version_id where b.id='$biz' and pr.name='R cap 1000 at 4000'")"
case "$biz" in ????????-????-????-????-????????????) ;; *) echo "setup failed (biz=$biz)" >&2; exit 1;; esac

# helper: mint a token as owner and echo its evaluation_id (last line only —
# the set_config selects also emit rows in -qAt mode)
mint() { # $1 = lines-json
  q <<SQL | tail -n 1
select set_config('request.jwt.claim.sub','$owner',false);
select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false);
select public.evaluate_checkout('$biz'::uuid,'$branch'::uuid,'$client'::uuid, '$1'::jsonb, gen_random_uuid())->>'evaluation_id';
SQL
}

# worker: finalise a given token with a given key; write 'ok'|'stale'|'dup'|'err' to a file
finalise() { # $1=token $2=key $3=outfile
  q <<SQL > "$3" 2>&1 || true
select set_config('request.jwt.claim.sub','$owner',false);
select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false);
select pg_sleep(greatest(0, $start_epoch - extract(epoch from clock_timestamp())));
select coalesce((public.record_cart_sale('$biz'::uuid,'$client'::uuid,'$branch'::uuid,null,'cash','$2', null, '$1'::uuid, true))->>'status','ok');
SQL
}

fail=0

# ================= RACE 1: same token, different keys =================
tok1="$(mint "[{\"catalog_kind\":\"service\",\"catalog_id\":\"$svc5000\",\"qty\":1}]")"
case "$tok1" in ????????-????-????-????-????????????) ;; *) echo "mint race1 failed (tok=$tok1)" >&2; exit 1;; esac
key1a="v58r1a-$owner_prefix"; key1b="v58r1b-$owner_prefix"
start_epoch="$(q -c 'select extract(epoch from now())+2')"
finalise "$tok1" "$key1a" /tmp/v58_r1a.out &
finalise "$tok1" "$key1b" /tmp/v58_r1b.out &
wait
echo "race1 A: $(cat /tmp/v58_r1a.out 2>/dev/null | tr '\n' ' ')"
echo "race1 B: $(cat /tmp/v58_r1b.out 2>/dev/null | tr '\n' ' ')"
sales1="$(q -c "select count(*) from public.sales where id=(select consumed_sale_id from public.checkout_evaluations where id='$tok1')")"
consumed1="$(q -c "select count(*) from public.checkout_evaluations where id='$tok1' and consumed_at is not null")"
dlines1="$(q -c "select count(*) from public.checkout_discount_lines where sale_id=(select consumed_sale_id from public.checkout_evaluations where id='$tok1')")"
echo "race1: consumed_token=$consumed1 sale_exists=$sales1 discount_lines=$dlines1"
[ "$consumed1" = "1" ] || { echo "FAIL race1: token not consumed exactly once" >&2; fail=1; }
[ "$sales1" = "1" ]    || { echo "FAIL race1: expected exactly one kernel sale" >&2; fail=1; }
[ "$dlines1" = "1" ]   || { echo "FAIL race1: expected exactly one discount line" >&2; fail=1; }
outs1="$(cat /tmp/v58_r1a.out /tmp/v58_r1b.out 2>/dev/null | tr '\n' ' ')"
case "$outs1" in
  *ok*stale*|*stale*ok*) : ;;
  *) echo "FAIL race1: expected one ok + one stale_evaluation, got: $outs1" >&2; fail=1;;
esac

# ================= RACE 2: two tokens, last budget slot =================
tok2a="$(mint "[{\"catalog_kind\":\"service\",\"catalog_id\":\"$svc2000\",\"qty\":2}]")"
tok2b="$(mint "[{\"catalog_kind\":\"service\",\"catalog_id\":\"$svc2000\",\"qty\":2}]")"
case "$tok2a$tok2b" in *' '*) echo "mint race2 failed" >&2; exit 1;; esac
# both evaluations must have projected the 1000 discount (committed was 0 at eval time)
d2a="$(q -c "select discount_total_cents from public.checkout_evaluations where id='$tok2a'")"
d2b="$(q -c "select discount_total_cents from public.checkout_evaluations where id='$tok2b'")"
echo "race2 projected discounts: A=$d2a B=$d2b (both must be 1000)"
[ "$d2a" = "1000" ] && [ "$d2b" = "1000" ] || { echo "FAIL race2: both tokens must project the discount" >&2; fail=1; }
start_epoch="$(q -c 'select extract(epoch from now())+2')"
finalise "$tok2a" "v58r2a-$owner_prefix" /tmp/v58_r2a.out &
finalise "$tok2b" "v58r2b-$owner_prefix" /tmp/v58_r2b.out &
wait
echo "race2 A: $(cat /tmp/v58_r2a.out 2>/dev/null | tr '\n' ' ')"
echo "race2 B: $(cat /tmp/v58_r2b.out 2>/dev/null | tr '\n' ' ')"
committed2="$(q -c "select committed_cents from public.budget_periods where business_id='$biz' and rule_id='$caprule'")"
reserved2="$(q -c "select coalesce(sum(amount_cents),0) from public.budget_reservations br join public.budget_periods bp on bp.id=br.budget_period_id where bp.business_id='$biz' and bp.rule_id='$caprule'")"
consumed2="$(q -c "select count(*) from public.checkout_evaluations where id in ('$tok2a','$tok2b') and consumed_at is not null")"
echo "race2: committed=$committed2 reserved=$reserved2 consumed_tokens=$consumed2"
[ "$committed2" = "1000" ] || { echo "FAIL race2: committed_cents must equal exactly one commitment (1000)" >&2; fail=1; }
[ "$reserved2" = "1000" ]  || { echo "FAIL race2: reservations must reconcile to the counter (1000)" >&2; fail=1; }
[ "$consumed2" = "1" ]     || { echo "FAIL race2: exactly one token must be consumed" >&2; fail=1; }
outs2="$(cat /tmp/v58_r2a.out /tmp/v58_r2b.out 2>/dev/null | tr '\n' ' ')"
case "$outs2" in
  *ok*stale*|*stale*ok*) : ;;
  *) echo "FAIL race2: expected one ok + one stale_evaluation, got: $outs2" >&2; fail=1;;
esac

rm -f /tmp/v58_r1a.out /tmp/v58_r1b.out /tmp/v58_r2a.out /tmp/v58_r2b.out
if [ "$fail" = "0" ]; then
  echo "v58 concurrency: PASS (single-use token + atomic budget slot both hold under races)"
else
  exit 1
fi
