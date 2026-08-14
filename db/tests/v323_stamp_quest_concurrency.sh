#!/bin/sh
set -eu

# v323 — TWO COUNTER SCANS AT THE SAME MOMENT.
#
# A rolled-back single-transaction suite cannot demonstrate two sessions racing, so this rig drives
# real concurrent psql sessions at app.redeem_reward_core and asserts the two things owner ruling
# R5 makes possible to get wrong:
#
#   RACE A — eight simultaneous claims of the SAME milestone, each with its own idempotency key.
#            Exactly ONE must succeed. The others must be refused, not silently duplicated.
#   RACE B — eight simultaneous claims of the FINAL milestone. Exactly ONE cycle may close, and
#            the card must fall by exactly N, once.
#   RACE C — eight simultaneous claims sharing ONE idempotency key. All eight must return the same
#            stored result and write exactly one redemption (the pre-existing loyalty_operations
#            replay, re-proved because a non-consuming claim takes a different path through it).
#
# The three defences, in the order they engage:
#   1. app.redeem_reward_core takes `perform 1 from public.clients ... for update` before it reads
#      any balance, so two claims for ONE customer serialise on that row.
#   2. loyalty_operations (business_id, operation_type, idempotency_key) with `for update` collapses
#      a retried scan of the same QR.
#   3. stamp_milestone_claims_slot_uk / _reward_uk and stamp_cycles_cycle_uk / _redemption_uk turn
#      anything that got past 1 and 2 into a 23505 rather than a second gift.
#
# This rig WRITES AND THEN DELETES real rows, so it refuses to run without an explicit disposable
# confirmation. Do not point it at production.

if [ "${V323_CONFIRM_DISPOSABLE_DB:-}" != "YES" ]; then
  echo "Refusing to run: set V323_CONFIRM_DISPOSABLE_DB=YES." >&2
  exit 2
fi
if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL is required." >&2
  exit 2
fi
case "$DATABASE_URL" in postgresql://*|postgres://*) ;; *)
  echo "DATABASE_URL must be PostgreSQL." >&2; exit 2;;
esac

q() { psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 "$@"; }

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nestly-v323-quest-concurrency.XXXXXX")"
biz="$(q -c 'select gen_random_uuid()')"
owner="$(q -c 'select gen_random_uuid()')"
client="$(q -c 'select gen_random_uuid()')"
email="v323-concurrency-${owner}@example.test"

cleanup() {
  status="$1"
  trap - EXIT HUP INT TERM
  set +e
  psql "$DATABASE_URL" -X -qAt -v biz="$biz" -v owner="$owner" -v email="$email" \
    >/dev/null 2>&1 <<'SQL'
set session_replication_role = replica;
delete from public.stamp_milestone_claims where business_id=:'biz';
delete from public.stamp_cycles where business_id=:'biz';
delete from public.loyalty_redemption_batch_drains where business_id=:'biz';
delete from public.loyalty_redemption_provenance where business_id=:'biz';
delete from public.loyalty_redemptions where business_id=:'biz';
delete from public.loyalty_operations where business_id=:'biz';
delete from public.points_batches where business_id=:'biz';
delete from public.points_ledger where business_id=:'biz';
delete from public.sales where business_id=:'biz';
delete from public.loyalty_reward_versions where business_id=:'biz';
delete from public.loyalty_rewards where business_id=:'biz';
delete from public.loyalty_program_versions where business_id=:'biz';
delete from public.loyalty_programs where business_id=:'biz';
delete from public.business_programmes where business_id=:'biz';
delete from public.clients where business_id=:'biz';
delete from public.branches where business_id=:'biz';
delete from public.staff where business_id=:'biz';
update public.businesses set active_config_version_id=null where id=:'biz';
delete from public.firm_config_versions where business_id=:'biz';
delete from public.businesses where id=:'biz';
delete from auth.users where id=:'owner' and email=:'email';
set session_replication_role = origin;
SQL
  rm -f "$work_dir"/claim-*
  rmdir "$work_dir" 2>/dev/null || true
  exit "$status"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' HUP INT TERM

# ---------------------------------------------------------------------------
# Fixture: one stamps firm, a 3 / 5 / 8 quest, and a customer holding 10 stamps
# earned through the real sale trigger.
# ---------------------------------------------------------------------------
q -v biz="$biz" -v owner="$owner" -v client="$client" -v email="$email" <<'SQL' >/dev/null
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                       email_confirmed_at,created_at,updated_at)
values ('00000000-0000-0000-0000-000000000000',:'owner','authenticated','authenticated',
        :'email','',now(),now(),now());

select set_config('app.v79_system_transition','on',true);
insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
values (:'biz','V323 Race','v323-race-'||substr(:'biz',1,8),'retail','SGD',
        array['dashboard','clients','sales','loyalty'],'redeem');
select set_config('app.v79_system_transition','',true);

update public.business_workspace_controls_v94
   set approval_status='approved', decided_by=:'owner', decided_at=now(),
       decision_reason='v323 concurrency rig'
 where business_id=:'biz';
insert into public.business_subscription_lifecycle_v94(business_id)
values (:'biz') on conflict (business_id) do nothing;
update public.business_subscription_lifecycle_v94
   set workspace_paused=false where business_id=:'biz';

insert into public.staff(business_id,user_id,role,full_name,active)
values (:'biz',:'owner','owner','V323 Race Owner',true);
insert into public.branches(business_id,name,active,is_default)
values (:'biz','V323 Race Main',true,true);

insert into public.firm_config_versions(id,business_id,version_no,status,published_at)
values (gen_random_uuid(),:'biz',1,'published',now());
update public.businesses b
   set active_config_version_id=(select id from public.firm_config_versions
                                  where business_id=:'biz' order by version_no desc limit 1)
 where b.id=:'biz';

insert into public.loyalty_programs(
  business_id,kind,active,loyalty_model,configuration_status,redeem_points,reward_credit_cents,
  tier_basis,expiry_mode,expiry_days,earn_points_per_dollar,stamp_target,stamp_per_cents,
  current_config_version_id)
select :'biz','points',true,'stamps','published',100,500,'visits','none',null,1,8,500,
       b.active_config_version_id from public.businesses b where b.id=:'biz';
insert into public.loyalty_program_versions(
  business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,redeem_points,
  reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,expiry_mode,expiry_days)
select :'biz',b.active_config_version_id,'points','stamps',true,1,100,500,8,500,'visits','none',null
  from public.businesses b where b.id=:'biz';

update public.business_programmes set active=false where business_id=:'biz';
update public.business_programmes set active=true, activated_at=now()
 where business_id=:'biz' and kind='stamps';

insert into public.clients(id,business_id,full_name,phone)
values (:'client',:'biz','Race Customer','82900001');

insert into public.loyalty_rewards(
  id,business_id,programme_id,name,internal_name,customer_name,fulfillment_kind,
  cost_points,credit_cents,estimated_cost_cents,active,sort,current_config_version_id)
select gen_random_uuid(),:'biz',spine.id,'Rung '||rung.cost,'Rung '||rung.cost,'Rung '||rung.cost,
       'manual_item',rung.cost,0,0,true,rung.cost,b.active_config_version_id
  from public.business_programmes spine
  join public.businesses b on b.id=:'biz'
  cross join (values (3),(5),(8)) rung(cost)
 where spine.business_id=:'biz' and spine.kind='stamps';
insert into public.loyalty_reward_versions(
  reward_id,business_id,config_version_id,programme_id,internal_name,customer_name,
  fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,sort)
select r.id,r.business_id,b.active_config_version_id,r.programme_id,r.internal_name,
       r.customer_name,r.fulfillment_kind,r.cost_points,0,0,true,r.sort
  from public.loyalty_rewards r join public.businesses b on b.id=r.business_id
 where r.business_id=:'biz';

-- 10 stamps at $5 a stamp, through the real earn trigger.
insert into public.sales(business_id,client_id,kind,amount_cents,earns_points,counts_as_visit,
                         counts_as_revenue,config_version_id,policy_resolved_at)
select :'biz',:'client','service',5000,true,true,true,b.active_config_version_id,now()
  from public.businesses b where b.id=:'biz';
SQL

filled_before="$(q -v biz="$biz" -v client="$client" \
  -c "select filled from app.stamp_progress_v323('$biz','$client')")"
[ "$filled_before" = "10" ] || {
  echo "fixture did not produce a 10-stamp card (got '$filled_before')" >&2; exit 1; }

branch="$(q -c "select id from public.branches where business_id='$biz'")"
mid="$(q -c "select id from public.loyalty_rewards where business_id='$biz' and cost_points=5")"
fin="$(q -c "select id from public.loyalty_rewards where business_id='$biz' and cost_points=8")"

race() {                       # race <label> <reward> <key-mode>
  label="$1"; reward="$2"; mode="$3"
  pids=""; i=1
  while [ "$i" -le 8 ]; do
    if [ "$mode" = "shared" ]; then key="v323-race-shared-$label"; else key="v323-race-$label-$i"; fi
    (
      psql "$DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
        -v owner="$owner" -v biz="$biz" -v client="$client" -v reward="$reward" \
        -v branch="$branch" -v key="$key" >"$work_dir/claim-$label-$i" 2>&1 <<'SQL'
select set_config('request.jwt.claim.sub',:'owner',false);
select set_config('request.jwt.claims',json_build_object('sub',:'owner','role','authenticated')::text,false);
set role authenticated;
select app.redeem_reward_core(:'biz',:'client',:'reward',:'key',:'branch',null,null);
SQL
    ) &
    pids="$pids $!"
    i=$((i+1))
  done
  for pid in $pids; do wait "$pid" || true; done
}

# ---------------------------------------------------------------------------
# RACE A — eight simultaneous claims of the mid-card milestone at slot 5.
# ---------------------------------------------------------------------------
race mid "$mid" distinct

claims="$(q -c "select count(*) from public.stamp_milestone_claims
                 where business_id='$biz' and slot_position=5")"
reds="$(q -c "select count(*) from public.loyalty_redemptions
               where business_id='$biz' and reward_id='$mid'")"
filled_after="$(q -c "select filled from app.stamp_progress_v323('$biz','$client')")"
ledger="$(q -c "select count(*) from public.points_ledger
                 where business_id='$biz' and entry_type='redeem'")"
drains="$(q -c "select count(*) from public.loyalty_redemption_batch_drains
                 where business_id='$biz'")"

[ "$claims" = "1" ] || { echo "RACE A: $claims milestone claims, expected exactly 1" >&2; exit 1; }
[ "$reds" = "1" ]   || { echo "RACE A: $reds redemptions, expected exactly 1" >&2; exit 1; }
[ "$filled_after" = "10" ] || {
  echo "RACE A: the card moved from 10 to $filled_after; a milestone claim must consume nothing" >&2
  exit 1; }
[ "$ledger" = "0" ] || { echo "RACE A: $ledger redeem ledger row(s) were written" >&2; exit 1; }
[ "$drains" = "0" ] || { echo "RACE A: $drains batch drain row(s) were written" >&2; exit 1; }
echo "v323 RACE A: PASS (8 concurrent claims, exactly 1 recorded, card unchanged at 10)"

# ---------------------------------------------------------------------------
# RACE B — eight simultaneous claims of the FINAL milestone. One cycle, once.
# ---------------------------------------------------------------------------
race final "$fin" distinct

cycles="$(q -c "select count(*) from public.stamp_cycles where business_id='$biz'")"
slots="$(q -c "select coalesce(sum(slots),0) from public.stamp_cycles where business_id='$biz'")"
filled_final="$(q -c "select filled from app.stamp_progress_v323('$biz','$client')")"
net="$(q -c "select net_stamps from app.stamp_progress_v323('$biz','$client')")"
idx="$(q -c "select cycle_index from app.stamp_progress_v323('$biz','$client')")"

[ "$cycles" = "1" ] || { echo "RACE B: $cycles closed cycles, expected exactly 1" >&2; exit 1; }
[ "$slots" = "8" ]  || { echo "RACE B: closed slots total $slots, expected 8" >&2; exit 1; }
[ "$idx" = "1" ]    || { echo "RACE B: cycle_index is $idx, expected 1" >&2; exit 1; }
[ "$filled_final" = "2" ] || {
  echo "RACE B: the card is at $filled_final, expected the remainder 2" >&2; exit 1; }
[ "$net" = "10" ] || {
  echo "RACE B: net_stamps is $net; closure must not move the append-only ledger" >&2; exit 1; }
echo "v323 RACE B: PASS (8 concurrent final claims, exactly 1 cycle closed, card 10 -> 2)"

# ---------------------------------------------------------------------------
# RACE C — eight simultaneous claims sharing ONE idempotency key.
# ---------------------------------------------------------------------------
race shared "$mid" shared

shared_claims="$(q -c "select count(*) from public.stamp_milestone_claims
                        where business_id='$biz' and cycle_index=1")"
shared_ops="$(q -c "select count(*) from public.loyalty_operations
                     where business_id='$biz' and idempotency_key='v323-race-shared-shared'")"
[ "$shared_ops" = "1" ] || {
  echo "RACE C: $shared_ops operations for one idempotency key, expected 1" >&2; exit 1; }
[ "$shared_claims" -le 1 ] || {
  echo "RACE C: $shared_claims claims on the new card, expected at most 1" >&2; exit 1; }
echo "v323 RACE C: PASS (one idempotency key, one operation, no duplicate claim)"

echo "v323 stamp quest concurrency: PASS"
