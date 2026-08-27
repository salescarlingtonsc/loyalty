-- Rollback-only acceptance for nestly_v568 — a stamp card's survivor gifts stay in its own pot.
-- Run: supabase db query --linked -f db/tests/v568_survivor_arm_stays_in_its_pot.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  shape: the survivor arm carries `live.programme_id = sc.programme_id`.
--   02  ESTATE INVARIANT (the one that would have caught this): for every verified customer of
--       every business, app.reward_availability_v432 offers no reward whose own programme spine
--       is inactive. This audits the CORE's answer, not two readers' agreement — the gap that
--       let this defect through (a consistency check cannot see a defect in the shared core).
--   03  end to end, rolled back: a fixture tenant running stamps with a PARKED points gift whose
--       cost is within the card length (the exact KKY shape: 5-point gift, 5-slot card, closed
--       cycle). The survivor arm must offer the stamp gift and NOT the parked points gift.
--
-- ROLLBACK: reverting v568 means dropping that one predicate — which re-opens the recorded case
-- (a points gift advertised as "READY · 5 stamps" that app.redeem_reward_core then refuses).

begin;

create temp table _r(check_id text, value text) on commit drop;

do $shape$
declare v_def text;
begin
  v_def := pg_get_functiondef('app.reward_availability_v432(uuid,uuid,timestamptz)'::regprocedure);
  insert into _r values ('01 the survivor arm is pot-scoped',
    case when position('and live.programme_id = sc.programme_id' in v_def) = 0
      then 'FAIL: the survivor arm can still admit another pot''s rewards'
      when position('and rv.cost_points <= sc.slots' in v_def) = 0
      then 'FAIL: the v478 survivor arm is gone entirely'
      else 'OK' end);
end
$shape$;

do $estate$
declare v_leak integer; v_names text; v_seen integer;
begin
  select count(*), count(*) filter (where true), string_agg(distinct lr.customer_name, ', ')
    into v_seen, v_leak, v_names
    from public.businesses b
    join public.customer_links cl on cl.business_id=b.id and cl.state='verified'
    cross join lateral app.reward_availability_v432(b.id, cl.client_id, now()) core
    join public.loyalty_rewards lr on lr.id=core.reward_id
   where not exists (select 1 from public.business_programmes sp
                      where sp.id=lr.programme_id and sp.active);
  insert into _r values ('02 no offered reward sits on a switched-off programme',
    case when coalesce(v_leak,0)=0 then 'OK'
         else 'FAIL: '||v_leak||' offer(s): '||coalesce(v_names,'?') end);
end
$estate$;

-- 03 — the recorded shape, rebuilt from scratch. Owner gate stubbed IN THIS TRANSACTION ONLY
-- (the v563/v564/v565 suites' pattern).
create or replace function app.c45_owner_loyalty_write(p_business_id uuid)
returns boolean language sql stable as $stub$ select true $stub$;

do $endtoend$
declare
  v_biz uuid := 'cafe0568-0000-4000-8000-000000000001';
  v_client uuid := 'cafe0568-0000-4000-8000-000000000002';
  v_ver uuid;
  v_points uuid; v_stamps uuid;
  v_gift_pts uuid := 'cafe0568-0000-4000-8000-00000000000a';
  v_gift_stp uuid := 'cafe0568-0000-4000-8000-00000000000b';
  v_offered text;
begin
  insert into public.businesses(id, name, slug, industry)
  values (v_biz, 'v568 fixture', 'v568-fixture-rolled-back', 'fnb');
  select b.active_config_version_id into v_ver from public.businesses b where b.id=v_biz;
  select id into v_points from public.business_programmes where business_id=v_biz and kind='points';
  select id into v_stamps from public.business_programmes where business_id=v_biz and kind='stamps';
  -- stamps running, points PARKED — the KKY shape
  update public.business_programmes set active=(kind='stamps') where business_id=v_biz;
  insert into public.loyalty_programs(business_id, kind, loyalty_model, active, earn_points_per_dollar,
    stamp_target, stamp_per_cents, configuration_status)
  values (v_biz, 'stamps', 'stamps', true, 1, 5, 500, 'published')
  on conflict (business_id) do update set kind='stamps', loyalty_model='stamps', active=true,
    stamp_target=5, stamp_per_cents=500, configuration_status='published';
  if v_ver is null then
    select b.active_config_version_id into v_ver from public.businesses b where b.id=v_biz;
  end if;

  insert into public.clients(id, business_id, full_name, phone)
  values (v_client, v_biz, 'v568 fixture client', '80005681');

  -- two gifts, both priced 5: one on the PARKED points pot, one on the LIVE stamp card
  insert into public.loyalty_rewards(id, business_id, programme_id, name, customer_name,
    internal_name, fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active, sort)
  values (v_gift_pts, v_biz, v_points, 'v568 parked points gift', 'v568 parked points gift',
          'v568 parked points gift', 'manual_item', 5, 0, 0, true, 0),
         (v_gift_stp, v_biz, v_stamps, 'v568 stamp gift', 'v568 stamp gift',
          'v568 stamp gift', 'manual_item', 5, 0, 0, true, 1);
  insert into public.loyalty_reward_versions(config_version_id, business_id, reward_id, programme_id,
    active, cost_points, customer_name, internal_name, fulfillment_kind, credit_cents,
    estimated_cost_cents, sort)
  values (v_ver, v_biz, v_gift_pts, v_points, true, 5, 'v568 parked points gift',
          'v568 parked points gift', 'manual_item', 0, 0, 0),
         (v_ver, v_biz, v_gift_stp, v_stamps, true, 5, 'v568 stamp gift',
          'v568 stamp gift', 'manual_item', 0, 0, 1);

  -- a completed 5-slot cycle: the survivor arm's own trigger condition. stamp_cycles is fenced
  -- by app.require_loyalty_shared_v480 — every writer of loyalty VALUE must hold the business's
  -- advisory lock first, which is the fence's whole point. Take it the way the real writers do.
  perform app.acquire_loyalty_shared_v480(v_biz);
  insert into public.stamp_cycles(business_id, client_id, programme_id, cycle_index, slots,
    config_version_id, origin)
  values (v_biz, v_client, v_stamps, 0, 5, v_ver, 'completed');

  select string_agg(coalesce(lr.customer_name,'?'), ', ' order by lr.customer_name)
    into v_offered
    from app.reward_availability_v432(v_biz, v_client, now()) core
    join public.loyalty_rewards lr on lr.id=core.reward_id;

  insert into _r values ('03 the survivor arm offers the card''s own gift only',
    case when v_offered = 'v568 stamp gift' then 'OK'
         when v_offered is null then 'FAIL: nothing offered — the survivor arm is over-filtered'
         else 'FAIL: offered '||v_offered end);
exception when others then
  insert into _r values ('03 the survivor arm offers the card''s own gift only','FAIL: '||sqlerrm);
end
$endtoend$;

select * from _r order by check_id;

rollback;
