-- Rollback-only acceptance for nestly_v563 — a stamps tenant can never publish without a card
-- length, and a stale clone inherits the live stamp numbers instead of erasing them.
-- Run: supabase db query --linked -f db/tests/v563_stamps_publish_needs_length.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  shape: the stamps validations are keyed on the spine as well as the draft's model, the
--       effective config resolver (v_eff_target) exists, and the live-row copy coalesces the
--       stamp numbers.
--   02  data: no tenant running stamps holds a live stamp_target of NULL/0 while its live
--       version carries an active stamp gift — the state the backfill closed.
--   03  end to end, rolled back: a stamps tenant with live target 5 publishes a stale 'classic'
--       clone (NULL stamp fields, gift at 5) — publish succeeds and the live target is STILL 5;
--       then the same publish with the live target stripped refuses with the named 23514.
--
-- ROLLBACK: reverting v563 means re-keying the validations on v_typed.loyalty_model alone and
-- restoring the raw v_typed stamp copies. Only appropriate if the owner decides a draft's stale
-- model flag SHOULD be able to skip the stamp guards — which re-opens the recorded defect
-- (KKY demo: 18 collected stamps, a reward the server could never mint).

begin;

create temp table _r(check_id text, value text) on commit drop;

do $shape$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.publish_loyalty_config(uuid)'::regprocedure);
  insert into _r values ('01 function shape',
    case when position('v_eff_target' in v_def) = 0
      then 'FAIL: the effective stamp-config resolver is missing'
      when position('or v_spine_stamps) and coalesce(v_eff_per_cents' in v_def) = 0
      then 'FAIL: the per-stamp guard is not keyed on the spine'
      when position('stamp_target=coalesce(v_typed.stamp_target,loyalty_programs.stamp_target)' in v_def) = 0
      then 'FAIL: the live-row copy can still erase stamp_target with a stale clone''s NULL'
      else 'OK' end);
end
$shape$;

do $data$
declare v_bad integer;
begin
  select count(*) into v_bad
    from public.businesses b
    join public.business_programmes spine
      on spine.business_id=b.id and spine.kind='stamps' and spine.active
    join public.loyalty_programs lp on lp.business_id=b.id
   where coalesce(lp.stamp_target,0)<=0
     and exists (select 1 from public.loyalty_reward_versions rv
                  join public.business_programmes sp on sp.id=rv.programme_id and sp.kind='stamps'
                 where rv.business_id=b.id and rv.config_version_id=b.active_config_version_id
                   and rv.active);
  insert into _r values ('02 no live stamps tenant is missing its card length',
    case when v_bad=0 then 'OK' else 'FAIL: '||v_bad||' tenant(s)' end);
end
$data$;

-- 03 — the owner gate is stubbed IN THIS TRANSACTION ONLY (the v559/v560 suites' pattern).
create or replace function app.c45_owner_loyalty_write(p_business_id uuid)
returns boolean language sql stable as $stub$ select true $stub$;

do $endtoend$
declare
  v_biz uuid := 'cafe0563-0000-4000-8000-000000000001';
  v_ver uuid := 'cafe0563-0000-4000-8000-000000000002';
  v_stamp_spine uuid;
  v_target integer;
begin
  insert into public.businesses(id, name, slug, industry)
  values (v_biz, 'v563 fixture', 'v563-fixture-rolled-back', 'fnb');
  insert into public.business_programmes(business_id, kind, active, sort)
  values (v_biz, 'stamps', true, 3)
  on conflict (business_id, kind) do update set active = true;
  update public.business_programmes set active=false
   where business_id=v_biz and kind in ('points','tiers');
  select id into v_stamp_spine from public.business_programmes
   where business_id=v_biz and kind='stamps';
  insert into public.loyalty_programs(business_id, kind, loyalty_model, active, earn_points_per_dollar,
    stamp_target, stamp_per_cents, configuration_status)
  values (v_biz, 'stamps', 'stamps', true, 1, 5, 500, 'published')
  on conflict (business_id) do update set kind='stamps', loyalty_model='stamps', active=true,
    stamp_target=5, stamp_per_cents=500, configuration_status='published';
  insert into public.firm_config_versions(id, business_id, version_no, status, snapshot_hash)
  values (v_ver, v_biz,
          (select coalesce(max(version_no),0)+1 from public.firm_config_versions where business_id=v_biz),
          'draft', md5('v563-fixture'));
  -- the stale clone: classic, no stamp fields
  insert into public.loyalty_program_versions(config_version_id, business_id, kind, loyalty_model, active,
    earn_points_per_dollar, redeem_points, reward_credit_cents, tier_basis, expiry_mode)
  values (v_ver, v_biz, 'points', 'classic', false, 1, 100, 500, 'visits', 'none');
  insert into public.loyalty_rewards(id, business_id, programme_id, name, customer_name, internal_name,
    fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active, sort)
  values ('cafe0563-0000-4000-8000-000000000003', v_biz, v_stamp_spine, 'v563 gift', 'v563 gift', 'v563 gift',
    'manual_item', 5, 0, 0, true, 0);
  insert into public.loyalty_reward_versions(config_version_id, business_id, reward_id, programme_id,
    active, cost_points, customer_name, internal_name, fulfillment_kind, credit_cents, estimated_cost_cents, sort)
  values (v_ver, v_biz, 'cafe0563-0000-4000-8000-000000000003', v_stamp_spine, true, 5, 'v563 gift', 'v563 gift', 'manual_item', 0, 0, 0);

  perform public.publish_loyalty_config(v_ver);
  select lp.stamp_target into v_target from public.loyalty_programs lp where lp.business_id=v_biz;
  insert into _r values ('03a a stale clone inherits the live card length',
    case when v_target = 5 then 'OK'
         else 'FAIL: live stamp_target became '||coalesce(v_target::text,'NULL') end);
exception when others then
  insert into _r values ('03a a stale clone inherits the live card length', 'FAIL: '||sqlerrm);
end
$endtoend$;

do $refusal$
declare
  v_biz uuid := 'cafe0563-0000-4000-8000-000000000011';
  v_ver uuid := 'cafe0563-0000-4000-8000-000000000012';
begin
  insert into public.businesses(id, name, slug, industry)
  values (v_biz, 'v563 fixture b', 'v563-fixture-b-rolled-back', 'fnb');
  insert into public.business_programmes(business_id, kind, active, sort)
  values (v_biz, 'stamps', true, 3)
  on conflict (business_id, kind) do update set active = true;
  update public.business_programmes set active=false
   where business_id=v_biz and kind in ('points','tiers');
  insert into public.loyalty_programs(business_id, kind, loyalty_model, active, earn_points_per_dollar,
    stamp_per_cents, configuration_status)
  values (v_biz, 'stamps', 'stamps', true, 1, 500, 'published')
  on conflict (business_id) do update set kind='stamps', loyalty_model='stamps', active=true,
    stamp_target=null, stamp_per_cents=500, configuration_status='published';
  insert into public.firm_config_versions(id, business_id, version_no, status, snapshot_hash)
  values (v_ver, v_biz,
          (select coalesce(max(version_no),0)+1 from public.firm_config_versions where business_id=v_biz),
          'draft', md5('v563-fixture-b'));
  insert into public.loyalty_program_versions(config_version_id, business_id, kind, loyalty_model, active,
    earn_points_per_dollar, redeem_points, reward_credit_cents, tier_basis, expiry_mode)
  values (v_ver, v_biz, 'points', 'classic', false, 1, 100, 500, 'visits', 'none');
  perform public.publish_loyalty_config(v_ver);
  insert into _r values ('03b a stamps tenant with no length anywhere is refused',
    'FAIL: publish accepted it');
exception when sqlstate '23514' then
  insert into _r values ('03b a stamps tenant with no length anywhere is refused', 'OK');
when others then
  insert into _r values ('03b a stamps tenant with no length anywhere is refused', 'FAIL: '||sqlerrm);
end
$refusal$;

select * from _r order by check_id;

rollback;
