#!/usr/bin/env bash
set -euo pipefail

# Executed two-session proof for v480. DATABASE_URL must target a disposable
# migrated database; this script creates no durable fixture rows.
: "${DATABASE_URL:?set DATABASE_URL to a disposable migrated database}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/peekaa-v480-concurrency.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

q(){ psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -Atq "$@"; }
biz_a="$(q -c 'select gen_random_uuid()')"
biz_b="$(q -c 'select gen_random_uuid()')"
now_ms(){ node -e 'process.stdout.write(String(Date.now()))'; }
wait_lock(){
  local business="$1" mode="$2"
  for _ in {1..100}; do
    test "$(q -c "with k as (select app.loyalty_fence_key_v480('$business') value) select count(*) from pg_locks l,k where l.locktype='advisory' and l.granted and l.mode='$mode' and l.objsubid=1 and l.classid=(((k.value>>32)&4294967295)::bigint)::oid and l.objid=((k.value&4294967295)::bigint)::oid")" != "0" && return 0
    sleep 0.02
  done
  echo "v480 holder did not acquire $mode" >&2
  return 1
}

# Exclusive conversion lock blocks a same-tenant shared writer.
(
  q -c "begin; select app.acquire_loyalty_exclusive_v480('$biz_a'); select 'READY'; select pg_sleep(2); commit"
) >"$work_dir/exclusive.out" &
holder=$!
wait_lock "$biz_a" ExclusiveLock

start="$(now_ms)"
q -c "begin; select app.acquire_loyalty_shared_v480('$biz_b'); commit" >/dev/null
different_ms=$(( $(now_ms)-start ))
if (( different_ms >= 1000 )); then
  echo "different-business writer contended for ${different_ms}ms" >&2
  exit 1
fi

start="$(now_ms)"
q -c "begin; select app.acquire_loyalty_shared_v480('$biz_a'); commit" >/dev/null
same_ms=$(( $(now_ms)-start ))
wait "$holder"
if (( same_ms < 1400 )); then
  echo "same-business writer bypassed exclusive fence (${same_ms}ms)" >&2
  exit 1
fi

# Shared writer lock blocks a same-tenant exclusive conversion.
(
  q -c "begin; select app.acquire_loyalty_shared_v480('$biz_a'); select 'READY'; select pg_sleep(2); commit"
) >"$work_dir/shared.out" &
holder=$!
wait_lock "$biz_a" ShareLock
start="$(now_ms)"
q -c "begin; select app.acquire_loyalty_exclusive_v480('$biz_a'); commit" >/dev/null
exclusive_ms=$(( $(now_ms)-start ))
wait "$holder"
if (( exclusive_ms < 1400 )); then
  echo "same-business conversion bypassed shared writer (${exclusive_ms}ms)" >&2
  exit 1
fi

# A transaction never waits on its own unsupported shared→exclusive upgrade.
upgrade_state="$(q -c "do \$\$ begin perform app.acquire_loyalty_shared_v480('$biz_a'); begin perform app.acquire_loyalty_exclusive_v480('$biz_a'); raise exception 'upgrade accepted'; exception when deadlock_detected then if position('unsafe loyalty fence upgrade' in sqlerrm)=0 then raise; end if; end; end \$\$; select 'PASS'")"
test "$upgrade_state" = "PASS"

# Diagnostic settings cannot manufacture proof: pg_locks is authoritative.
spoof="$(q -c "begin; select set_config('app.loyalty_fence_mode_v480','exclusive',true); select coalesce(app.loyalty_fence_mode_v480('$biz_a'),'NONE'); rollback")"
test "$(printf '%s\n' "$spoof" | tail -1)" = "NONE"

echo "v480 concurrency: PASS (exclusive→shared ${same_ms}ms; shared→exclusive ${exclusive_ms}ms; different tenant ${different_ms}ms)"

# ---------------------------------------------------------------------------
# Actual writer surface.  Every pair below invokes the production RPC/function,
# not the lock helper, in both orderings against one synthetic tenant.
# ---------------------------------------------------------------------------
owner="$(q -c 'select gen_random_uuid()')"
business="$(q -c 'select gen_random_uuid()')"
branch="$(q -c 'select gen_random_uuid()')"
staff="$(q -c 'select gen_random_uuid()')"
sale_client="$(q -c 'select gen_random_uuid()')"
adjust_client="$(q -c 'select gen_random_uuid()')"
redeem_client="$(q -c 'select gen_random_uuid()')"
reverse_client="$(q -c 'select gen_random_uuid()')"
restore_client="$(q -c 'select gen_random_uuid()')"
final_client="$(q -c 'select gen_random_uuid()')"
idem_client="$(q -c 'select gen_random_uuid()')"
reward="$(q -c 'select gen_random_uuid()')"
reward_version="$(q -c 'select gen_random_uuid()')"
slug="v480-race-$(printf '%s' "$business" | cut -c1-8)"
claims="{\"sub\":\"$owner\",\"role\":\"authenticated\"}"

q -c "
begin;
insert into public.module_registry(module_key,label,requires_modules,sort_order) values
 ('dashboard','Dashboard','{}',10),('clients','Customers','{}',30),('sales','Sales','{}',50),
 ('till','Till','{sales}',55),('services','Services','{}',60),('loyalty','Loyalty','{clients,sales}',120),
 ('referrals','Referrals','{clients,sales}',140)
on conflict(module_key) do nothing;
insert into public.product_adoption_event_taxonomy_v100
 (event_name,source_authority,actor_scope,business_scope_required,economic_event,description) values
 ('sale.recorded','server','system',true,true,'sale'),
 ('sale.reversed','server','system',true,true,'reversal'),
 ('loyalty.redemption_completed','server','system',true,true,'redemption')
on conflict(event_name) do nothing;
insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values('$owner','00000000-0000-0000-0000-000000000000','authenticated','authenticated',
       '$slug@example.test','x',now(),now(),now());
insert into public.businesses(id,name,slug,enabled_modules)
values('$business','V480 actual writer race','$slug','{dashboard,clients,sales,till,services,loyalty,referrals}');
insert into public.branches(id,business_id,name) values('$branch','$business','Main');
insert into public.staff(id,business_id,user_id,role,active,access_state,full_name)
values('$staff','$business','$owner','owner',true,'approved','V480 owner');
insert into public.business_workspace_controls_v94(business_id,approval_status,decided_by,decided_at,decision_reason)
values('$business','approved','$owner',now(),'v480 concurrency')
on conflict(business_id) do update set approval_status='approved',decided_by=excluded.decided_by,
 decided_at=excluded.decided_at,decision_reason=excluded.decision_reason;
insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
values('$business',false) on conflict(business_id) do update set workspace_paused=false;
insert into public.subscriptions(business_id,status,payment_status,current_period_end)
values('$business','active','paid',now() + interval '30 days')
on conflict(business_id) do update
 set status='active',payment_status='paid',current_period_end=now() + interval '30 days';
select set_config('request.jwt.claims','$claims',true);
select public.business_set_earning_rule_v359('$business',1.0,null,'none',null);
-- v507/v565 (born live): a fresh business's first config version is seeded already
-- 'published' by app.seed_loyalty_config_version, and business_set_earning_rule_v359
-- edits that live version in place for a points-only business (no stamps split), so
-- there is no draft left for an unconditional publish_loyalty_config call to publish.
-- Guard rather than assume: only publish if the version genuinely is still a draft.
select case when (select status from public.firm_config_versions
                    where id=(select current_config_version_id from public.loyalty_programs where business_id='$business')) = 'draft'
  then (select public.publish_loyalty_config((select current_config_version_id from public.loyalty_programs where business_id='$business'))::text)
  else null end;
select public.set_programmes_v314('$business','{\"points\":true}'::jsonb,gen_random_uuid());
insert into public.clients(id,business_id,full_name) values
 ('$sale_client','$business','sale writer'),('$adjust_client','$business','adjust writer'),
 ('$redeem_client','$business','redeem writer'),('$reverse_client','$business','reverse writer'),
 ('$restore_client','$business','restore writer'),('$final_client','$business','final balance'),
 ('$idem_client','$business','idempotent adjust');
insert into public.loyalty_rewards(id,business_id,name,internal_name,customer_name,fulfillment_kind,
 estimated_cost_cents,cost_points,credit_cents,active,programme_id,current_config_version_id)
select '$reward','$business','Race reward','Race reward','Race reward','manual_item',500,50,0,true,
       bp.id,lp.current_config_version_id
 from public.business_programmes bp join public.loyalty_programs lp on lp.business_id=bp.business_id
 where bp.business_id='$business' and bp.kind='points' limit 1;
insert into public.loyalty_reward_versions(id,config_version_id,business_id,reward_id,internal_name,
 customer_name,fulfillment_kind,estimated_cost_cents,cost_points,credit_cents,active,programme_id)
select '$reward_version',current_config_version_id,'$business','$reward','Race reward','Race reward',
       'manual_item',500,50,0,true,programme_id from public.loyalty_rewards where id='$reward';
update app.loyalty_integrity_control_v480 set conversions_enabled=true where singleton;
commit;"

seed_sale(){
  local client="$1" key="$2"
  q -c "begin; select set_config('request.jwt.claims','$claims',true);
    select public.record_quick_sale('$business',10000,'cash','$client','$staff','$branch','v480 race seed','$key',true);
    commit" | tail -1
}
seed_sale "$adjust_client" "race-seed-adjust" >/dev/null
seed_sale "$redeem_client" "race-seed-redeem" >/dev/null
reverse_sale="$(seed_sale "$reverse_client" "race-seed-reverse" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>process.stdout.write(JSON.parse(s).sale.id))")"
seed_sale "$restore_client" "race-seed-restore" >/dev/null
restore_redemption="$(q -c "begin; select set_config('request.jwt.claims','$claims',true);
 select public.redeem_reward_at_context('$business','$restore_client','$reward','race-seed-restoration','$branch',null,null);
 commit" | tail -1 | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>process.stdout.write(JSON.parse(s).redemption_id))")"

actual_conversion="select public.business_switch_to_stamps_v384('$business',true,100,gen_random_uuid())"
run_pair(){
  local label="$1" writer_sql="$2" holder started elapsed
  (
    q -c "begin; select set_config('request.jwt.claims','$claims',true); $writer_sql; select pg_sleep(0.8); rollback"
  ) >"$work_dir/${label}-writer-first.out" 2>&1 &
  holder=$!
  wait_lock "$business" ShareLock
  started="$(now_ms)"
  q -c "begin; select set_config('request.jwt.claims','$claims',true); $actual_conversion; rollback" >/dev/null
  elapsed=$(( $(now_ms)-started ))
  wait "$holder"
  if (( elapsed < 550 )); then echo "$label writer did not block conversion (${elapsed}ms)" >&2; exit 1; fi

  (
    q -c "begin; select set_config('request.jwt.claims','$claims',true); $actual_conversion; select pg_sleep(0.8); rollback"
  ) >"$work_dir/${label}-conversion-first.out" 2>&1 &
  holder=$!
  wait_lock "$business" ExclusiveLock
  started="$(now_ms)"
  q -c "begin; select set_config('request.jwt.claims','$claims',true); $writer_sql; rollback" >/dev/null
  elapsed=$(( $(now_ms)-started ))
  wait "$holder"
  if (( elapsed < 550 )); then echo "$label conversion did not block writer (${elapsed}ms)" >&2; exit 1; fi
  printf '  actual %-28s PASS\n' "$label"
}

run_pair "sale" "select public.record_quick_sale('$business',1000,'cash','$sale_client','$staff','$branch','race sale','race-sale-'||gen_random_uuid(),true)"
run_pair "positive-adjustment" "select public.adjust_points_v480('$business','$adjust_client',1,'race positive',gen_random_uuid())"
run_pair "negative-adjustment" "select public.adjust_points_v480('$business','$adjust_client',-1,'race negative',gen_random_uuid())"
run_pair "redemption" "select public.redeem_reward_at_context('$business','$redeem_client','$reward','race-redeem-'||gen_random_uuid(),'$branch',null,null)"
run_pair "sale-reversal" "select public.reverse_sale('$business','$reverse_sale','race reversal reason','race-reverse-'||gen_random_uuid(),'race','none')"
run_pair "redemption-restoration" "select public.reverse_loyalty_redemption('$business','$restore_redemption','race restoration reason','race-restore-'||gen_random_uuid())"

# Two redemptions contend for the final 50 proven points. Exactly one commits.
q -c "begin; select set_config('request.jwt.claims','$claims',true);
 select public.adjust_points_v480('$business','$final_client',50,'final balance seed',gen_random_uuid()); commit" >/dev/null
set +e
(q -c "begin; select set_config('request.jwt.claims','$claims',true); select public.redeem_reward_at_context('$business','$final_client','$reward','final-race-a','$branch',null,null); commit" >"$work_dir/final-a.out" 2>&1) & p1=$!
(q -c "begin; select set_config('request.jwt.claims','$claims',true); select public.redeem_reward_at_context('$business','$final_client','$reward','final-race-b','$branch',null,null); commit" >"$work_dir/final-b.out" 2>&1) & p2=$!
wait "$p1"; s1=$?; wait "$p2"; s2=$?
set -e
if ! (( (s1==0 && s2!=0) || (s1!=0 && s2==0) )); then
  echo "final-balance redemptions did not produce exactly one success ($s1/$s2)" >&2; exit 1
fi
final_reconcile="$(q -c "select
 (select coalesce(sum(points),0) from public.points_ledger where business_id='$business' and client_id='$final_client'),
 (select coalesce(sum(remaining),0) from public.points_batches where business_id='$business' and client_id='$final_client'),
 (select count(*) from public.loyalty_redemptions where business_id='$business' and client_id='$final_client'),
 (select count(*) from public.loyalty_redemption_provenance where business_id='$business' and client_id='$final_client'),
 (select coalesce(sum(d.drained_points),0) from public.loyalty_redemption_batch_drains d where d.business_id='$business' and d.client_id='$final_client'),
 (select count(*) from public.loyalty_operations where business_id='$business' and client_id='$final_client' and status='completed')")"
if [[ "$final_reconcile" != "0|0|1|1|50|1" ]]; then echo "final-balance reconciliation failed: $final_reconcile" >&2; exit 1; fi
echo "  concurrent final-balance redemption PASS"

# Two transactions reuse the same adjustment key. Both return, one effect lands.
adjust_key="$(q -c 'select gen_random_uuid()')"
(q -c "begin; select set_config('request.jwt.claims','$claims',true); select public.adjust_points_v480('$business','$idem_client',10,'same retry','$adjust_key'); commit" >"$work_dir/idem-a.out" 2>&1) & p1=$!
(q -c "begin; select set_config('request.jwt.claims','$claims',true); select public.adjust_points_v480('$business','$idem_client',10,'same retry','$adjust_key'); commit" >"$work_dir/idem-b.out" 2>&1) & p2=$!
wait "$p1"; wait "$p2"
idem_reconcile="$(q -c "select
 (select coalesce(sum(points),0) from public.points_ledger where business_id='$business' and client_id='$idem_client'),
 (select coalesce(sum(remaining),0) from public.points_batches where business_id='$business' and client_id='$idem_client'),
 (select count(*) from app.loyalty_adjustment_operations_v480 where business_id='$business' and idempotency_key='$adjust_key' and status='completed')")"
if [[ "$idem_reconcile" != "10|10|1" ]]; then echo "adjustment retry reconciliation failed: $idem_reconcile" >&2; exit 1; fi
if q -c "begin; select set_config('request.jwt.claims','$claims',true); select public.adjust_points_v480('$business','$idem_client',11,'same retry','$adjust_key'); commit" >/dev/null 2>&1; then
  echo "changed adjustment payload reused a key" >&2; exit 1
fi
echo "  concurrent same-key adjustment PASS"

# A qualifying referral reversal races an actual reward redemption against the
# referrer's exact source batch. Whichever locks the customer first wins; the
# loser must fail without a partial benefit or partial reversal.
race_referrer="$(q -c 'select gen_random_uuid()')"
race_friend="$(q -c 'select gen_random_uuid()')"
race_referral="$(q -c 'select gen_random_uuid()')"
q -c "begin; select set_config('request.jwt.claims','$claims',true);
 -- v565: set_programmes_v314 now refuses to switch referral ON with no public.referral_programs
 -- row behind it ('referral_needs_configuration'). save_referral_program_v421 must run first to
 -- create that row; the Point programme it references was already switched on above.
 select public.save_referral_program_v421('$business',true,'points',100,null,0,true,100,null);
 select public.set_programmes_v314('$business','{\"referral\":true}'::jsonb,gen_random_uuid());
 insert into public.clients(id,business_id,full_name) values
  ('$race_referrer','$business','race referrer'),('$race_friend','$business','race friend');
 insert into public.referrals(id,business_id,referrer_client_id,referred_client_id,status)
 values('$race_referral','$business','$race_referrer','$race_friend','pending'); commit" >/dev/null
race_sale="$(seed_sale "$race_friend" "race-referral-sale" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>process.stdout.write(JSON.parse(s).sale.id))")"
set +e
(q -c "begin; select set_config('request.jwt.claims','$claims',true); select public.redeem_reward_at_context('$business','$race_referrer','$reward','referral-redeem-race','$branch',null,null); commit" >"$work_dir/referral-redeem.out" 2>&1) & p1=$!
(q -c "begin; select set_config('request.jwt.claims','$claims',true); select public.reverse_sale('$business','$race_sale','referral concurrency reversal','referral-reversal-race','race','none'); commit" >"$work_dir/referral-reverse.out" 2>&1) & p2=$!
wait "$p1"; s1=$?; wait "$p2"; s2=$?
set -e
if ! (( (s1==0 && s2!=0) || (s1!=0 && s2==0) )); then
  echo "referral redemption/reversal did not serialize to one winner ($s1/$s2)" >&2; exit 1
fi
referral_reconcile="$(q -c "select
 (select count(*) from public.loyalty_redemptions where business_id='$business' and client_id='$race_referrer'),
 (select count(*) from public.sales where business_id='$business' and reversal_of='$race_sale'),
 (select coalesce(sum(points),0) from public.points_ledger where business_id='$business' and client_id in ('$race_referrer','$race_friend')),
 (select coalesce(sum(remaining),0) from public.points_batches where business_id='$business' and client_id in ('$race_referrer','$race_friend')),
 (select count(*) from app.referral_value_provenance_v480 where referral_id='$race_referral' and ledger_id is not null and batch_id is not null)")"
case "$referral_reconcile" in
  "1|0|250|250|2"|"0|1|0|0|2") ;;
  *) echo "referral redemption/reversal reconciliation failed: $referral_reconcile" >&2; exit 1 ;;
esac
echo "  concurrent referral redemption/reversal PASS ($referral_reconcile)"

# A queued exclusive transition must not be starved by a new burst of SHARED writers.
(
  q -c "begin; select set_config('request.jwt.claims','$claims',true); select public.adjust_points_v480('$business','$adjust_client',1,'burst holder',gen_random_uuid()); select pg_sleep(0.8); rollback"
) >"$work_dir/burst-holder.out" 2>&1 & initial=$!
wait_lock "$business" ShareLock
(
  q -c "begin; select set_config('request.jwt.claims','$claims',true); $actual_conversion; select pg_sleep(0.5); rollback"
) >"$work_dir/burst-exclusive.out" 2>&1 & queued=$!
sleep 0.1
burst_started="$(now_ms)"
burst_pids=()
for n in {1..8}; do
  (q -c "begin; select set_config('request.jwt.claims','$claims',true); select public.adjust_points_v480('$business','$adjust_client',1,'burst $n',gen_random_uuid()); rollback" >/dev/null) &
  burst_pids+=("$!")
done
wait "$initial"; wait "$queued"
for pid in "${burst_pids[@]}"; do wait "$pid"; done
burst_ms=$(( $(now_ms)-burst_started ))
if (( burst_ms < 900 )); then echo "shared burst bypassed queued exclusive transition (${burst_ms}ms)" >&2; exit 1; fi
echo "  queued exclusive under shared burst PASS (${burst_ms}ms)"

# Conversion is disabled again even in this disposable database.
q -c "update app.loyalty_integrity_control_v480 set conversions_enabled=false where singleton" >/dev/null
echo "v480 actual-writer concurrency: PASS"
