#!/bin/sh
# v63 PS-2A Increment C concurrency harness: a REAL two-connection race against the stored-value
# SPEND path (owner adversarial test 3 - concurrent redemptions, no overspend).
#   Seed a disposable tenant + a stored-value account funded to cover EXACTLY ONE spend (5000 paid
#   + 1000 bonus = 6000 available). Force sv_authority='live' (this DB is disposable and dropped, so
#   persisting 'live' here is fine - it NEVER touches UAT). Race two public.sv_spend calls of 6000
#   with DIFFERENT idempotency keys: exactly ONE succeeds, ONE fails (insufficient), no overspend,
#   and Σ movements reconciles to 0 (issue 6000 minus one spend of 6000). One-winner comes from the
#   per-account advisory xact lock + FEFO row locks: the loser re-reads the drained balance and
#   refuses BEFORE writing any movement.
# Run ONLY against a disposable rehearsal cluster. Commits are made and NOT rolled back.
set -eu

if [ "${V63_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V63_CONFIRM_DISPOSABLE_DB=YES for a disposable database." >&2
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
export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=15000"
q() { psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 "$@"; }

owner="$(q -c 'select gen_random_uuid()')"
owner_prefix="${owner%%-*}"
slug="v63-conc-$owner_prefix"

# --- Setup: disposable business + client + stored-value plan version, funded, authority forced live ---
q <<SQL >/dev/null
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','$owner','authenticated','authenticated','$slug@example.test','',now(),now(),now());
select set_config('request.jwt.claim.sub','$owner',false);
select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false);
select public.create_business('V63 concurrency','$slug','test', array['dashboard','clients','sales','loyalty']);
insert into public.clients(business_id,full_name,phone)
  select id,'v63 conc','+6590000063' from public.businesses where slug='$slug';
do \$seed\$
declare v_biz uuid; v_client uuid; v_plan uuid; v_pv uuid; v_res jsonb;
begin
  select id into v_biz from public.businesses where slug='$slug';
  select id into v_client from public.clients where business_id=v_biz order by created_at limit 1;
  insert into public.sv_plans(business_id,name) values (v_biz,'v63 conc plan') returning id into v_plan;
  insert into public.sv_plan_versions(business_id,plan_id,version_no,price_cents,bonus_cents,expiry_days,terms_snapshot)
  values (v_biz,v_plan,1,5000,1000,365, jsonb_build_object('price_cents',5000,'bonus_cents',1000)) returning id into v_pv;
  -- mint 5000 paid + 1000 bonus = 6000 available (covers EXACTLY one 6000 spend).
  perform public.sv_topup(v_biz, v_client, v_pv, gen_random_uuid());
  -- force authority='live' in this DISPOSABLE db (the v61 guard rejects the transition; disable it
  -- transiently). This is legitimate ONLY because the harness refuses to run without
  -- V63_CONFIRM_DISPOSABLE_DB=YES and the cluster is thrown away afterwards.
  alter table public.sv_authority disable trigger sv_authority_guard;
  update public.sv_authority set state='live' where business_id=v_biz and asset='stored_value';
  alter table public.sv_authority enable trigger sv_authority_guard;
end \$seed\$;
SQL

biz="$(q -c "select id from public.businesses where slug='$slug'")"
acct="$(q -c "select a.id from public.sv_accounts a where a.business_id='$biz' order by a.created_at limit 1")"
case "$biz$acct" in *' '*|*'
'*) echo "setup failed (biz=$biz acct=$acct)" >&2; exit 1;; esac
case "$biz" in ????????-????-????-????-????????????) ;; *) echo "setup failed (biz=$biz)" >&2; exit 1;; esac
avail="$(q -c "select app.sv_available_balance('$biz'::uuid,'$acct'::uuid)")"
[ "$avail" = "6000" ] || { echo "setup: available must be 6000, got $avail" >&2; exit 1; }

# worker: spend the full 6000 with a given key; write status/error to a file
spend() { # $1=key $2=outfile
  q <<SQL > "$2" 2>&1 || true
select set_config('request.jwt.claim.sub','$owner',false);
select set_config('request.jwt.claims', json_build_object('sub','$owner','role','authenticated')::text, false);
select pg_sleep(greatest(0, $start_epoch - extract(epoch from clock_timestamp())));
select coalesce((public.sv_spend('$biz'::uuid,'$acct'::uuid,6000,'$1'::uuid))->>'status','err');
SQL
}

fail=0
keyA="$(q -c 'select gen_random_uuid()')"
keyB="$(q -c 'select gen_random_uuid()')"
start_epoch="$(q -c 'select extract(epoch from now())+2')"
spend "$keyA" /tmp/v63_a.out &
spend "$keyB" /tmp/v63_b.out &
wait
echo "spend A: $(cat /tmp/v63_a.out 2>/dev/null | tr '\n' ' ')"
echo "spend B: $(cat /tmp/v63_b.out 2>/dev/null | tr '\n' ' ')"

spends="$(q -c "select count(*) from public.sv_operations where business_id='$biz' and operation_type='spend'")"
movements="$(q -c "select coalesce(sum(cents),0) from public.sv_lot_movements where business_id='$biz' and account_id='$acct'")"
availafter="$(q -c "select app.sv_available_balance('$biz'::uuid,'$acct'::uuid)")"
neg="$(q -c "select count(*) from public.sv_lots l where l.business_id='$biz' and app.sv_lot_remaining(l.id) < 0")"
echo "result: spend_ops=$spends sum_movements=$movements available_after=$availafter negative_lots=$neg"

outs="$(cat /tmp/v63_a.out /tmp/v63_b.out 2>/dev/null | tr '\n' ' ')"
case "$outs" in
  *ok*insufficient*|*insufficient*ok*) : ;;
  *) echo "FAIL: expected one ok + one insufficient, got: $outs" >&2; fail=1;;
esac
[ "$spends" = "1" ]     || { echo "FAIL: expected exactly ONE committed spend operation (got $spends)" >&2; fail=1; }
[ "$movements" = "0" ]  || { echo "FAIL: Σ movements must reconcile to 0 after one full spend (got $movements)" >&2; fail=1; }
[ "$availafter" = "0" ] || { echo "FAIL: available after the winning spend must be 0 (got $availafter)" >&2; fail=1; }
[ "$neg" = "0" ]        || { echo "FAIL: no lot may go negative (overspend), found $neg" >&2; fail=1; }

rm -f /tmp/v63_a.out /tmp/v63_b.out
if [ "$fail" = "0" ]; then
  echo "v63 concurrency: PASS (one-winner sv_spend; no overspend; Σ movements consistent)"
else
  exit 1
fi
