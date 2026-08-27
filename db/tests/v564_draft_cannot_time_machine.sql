-- Rollback-only acceptance for nestly_v564 — a draft can neither time-machine nor erase.
-- Run: supabase db query --linked -f db/tests/v564_draft_cannot_time_machine.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  shape: all six patched functions carry their v564 anchors — publish refuses a stale
--       draft and validates fixed expiry, publish coalesces the last two nullable stamp columns,
--       both draft creators clone from the LIVE programme row, the seed trigger names all 13
--       typed columns, the stamp editor's gate is spine-keyed, and the branch resolver answers
--       `active` from the spine.
--   02  end to end, rolled back: a business on published v1 opens a draft based on an OLDER
--       version — publish refuses with 23514 'stale_draft: ...' — while a draft based on the
--       live pointer publishes normally (the carve-out that keeps every editor working).
--   03  end to end, rolled back: the live row holds stamp_validity_days=180 and
--       stamp_reward_expiry_days=45; a draft that never mentions either column publishes, and
--       the live row STILL holds 180/45.
--   04  end to end, rolled back: a draft whose effective points expiry is 'fixed' with no day
--       count is refused with the named 23514.
--
-- ROLLBACK: reverting v564 means letting a draft publish over a live pointer it was never based
-- on, letting a NULL clone erase stamp validity and gift expiry, and restoring the draft-model
-- keying in app.stamp_config_edit_commit_v433. Only appropriate if the owner decides a draft
-- SHOULD be able to revert every change made since it was opened — which re-opens the recorded
-- defect (13 open drafts in prod, all behind their tenant's live pointer, one of them carrying
-- an earn rate of 100 against a live rate of 1).

begin;

create temp table _r(check_id text, value text) on commit drop;

do $shape$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.publish_loyalty_config(uuid)'::regprocedure);
  insert into _r values ('01a publish_loyalty_config',
    case when position('stale_draft' in v_def) = 0
      then 'FAIL: publish does not refuse a stale draft'
      when position('v_eff_expiry_mode' in v_def) = 0
      then 'FAIL: the effective points-expiry validation is missing'
      when position('stamp_validity_days=coalesce(v_typed.stamp_validity_days,loyalty_programs.stamp_validity_days)' in v_def) = 0
      then 'FAIL: a NULL clone can still erase stamp_validity_days'
      when position('stamp_reward_expiry_days=coalesce(v_typed.stamp_reward_expiry_days,loyalty_programs.stamp_reward_expiry_days)' in v_def) = 0
      then 'FAIL: a NULL clone can still erase stamp_reward_expiry_days'
      else 'OK' end);

  v_def := pg_get_functiondef('public.create_loyalty_config_draft(uuid,uuid,text)'::regprocedure);
  insert into _r values ('01b create_loyalty_config_draft',
    case when position('left join public.loyalty_programs live' in v_def) = 0
      then 'FAIL: the draft is still cloned from the base version, not from LIVE'
      when position('coalesce(live.stamp_reward_expiry_days,base.stamp_reward_expiry_days)' in v_def) = 0
      then 'FAIL: the clone does not carry all 13 typed columns'
      else 'OK' end);

  v_def := pg_get_functiondef('public.create_grow_config_draft_v138(uuid,uuid,text)'::regprocedure);
  insert into _r values ('01c create_grow_config_draft_v138',
    case when position('left join public.loyalty_programs live' in v_def) = 0
      then 'FAIL: the Grow draft is still cloned from the base version, not from LIVE'
      when position('stamp_validity_days,stamp_reward_expiry_days' in v_def) = 0
      then 'FAIL: the Grow draft insert still names only 11 typed columns'
      else 'OK' end);

  v_def := pg_get_functiondef('app.seed_loyalty_config_version()'::regprocedure);
  insert into _r values ('01d app.seed_loyalty_config_version',
    case when position('new.stamp_reward_expiry_days' in v_def) = 0
      then 'FAIL: version 1 is still seeded without the two stamp-day columns'
      else 'OK' end);

  v_def := pg_get_functiondef('app.stamp_config_edit_commit_v433(uuid,uuid)'::regprocedure);
  insert into _r values ('01e app.stamp_config_edit_commit_v433',
    case when position('or v_spine_stamps then' in v_def) = 0
      then 'FAIL: the editor gate is still keyed on the draft''s loyalty_model alone'
      when position('v_eff_target' in v_def) = 0
      then 'FAIL: the editor still judges the draft''s stamp numbers, not the effective ones'
      else 'OK' end);

  v_def := pg_get_functiondef('app.resolve_loyalty_branch_config(uuid,uuid,uuid)'::regprocedure);
  insert into _r values ('01f app.resolve_loyalty_branch_config',
    case when position('spine.kind in (''points'',''stamps'',''tiers'')' in v_def) = 0
      then 'FAIL: `active` is still answered from the version row''s snapshot flag'
      else 'OK' end);
end
$shape$;

-- 02/03/04 — the owner gate is stubbed IN THIS TRANSACTION ONLY (the v559/v563 suites' pattern).
create or replace function app.c45_owner_loyalty_write(p_business_id uuid)
returns boolean language sql stable as $stub$ select true $stub$;

-- 02 — the time machine, and the carve-out that keeps the editors working.
do $stale$
declare
  v_biz uuid := 'cafe0564-0000-4000-8000-000000000001';
  v_live uuid;
  v_stale uuid := 'cafe0564-0000-4000-8000-000000000002';
  v_fresh uuid := 'cafe0564-0000-4000-8000-000000000003';
  v_earn numeric;
begin
  insert into public.businesses(id, name, slug, industry)
  values (v_biz, 'v564 fixture', 'v564-fixture-rolled-back', 'fnb');
  -- The businesses INSERT seeds the spine and version 1; points on, stamps off, so the v563
  -- stamps guards stay out of this check's way.
  insert into public.business_programmes(business_id, kind, active, sort)
  values (v_biz, 'points', true, 1)
  on conflict (business_id, kind) do update set active = true;
  update public.business_programmes set active=false
   where business_id=v_biz and kind in ('stamps','tiers');
  insert into public.loyalty_programs(business_id, kind, loyalty_model, active,
    earn_points_per_dollar, redeem_points, expiry_mode, configuration_status)
  values (v_biz, 'points', 'classic', true, 1, 100, 'none', 'published')
  on conflict (business_id) do update set kind='points', loyalty_model='classic', active=true,
    earn_points_per_dollar=1, redeem_points=100, expiry_mode='none', configuration_status='published';
  select b.active_config_version_id into v_live from public.businesses b where b.id=v_biz;
  if v_live is null then
    insert into _r values ('02 fixture', 'FAIL: the fixture business has no live version to be behind');
    return;
  end if;

  -- FIRST the carve-out: a draft based on the LIVE pointer (v1) publishes normally, which also
  -- moves the pointer forward and turns v1 into a genuinely OLD version for the refusal below.
  -- (prod carries a real FK on based_on_version_id, so the stale base must be a real row — the
  -- original fixture's invented uuid was refused by the FK before the guard could speak.)
  insert into public.firm_config_versions(id, business_id, version_no, status, based_on_version_id, snapshot_hash)
  values (v_fresh, v_biz,
          (select coalesce(max(version_no),0)+1 from public.firm_config_versions where business_id=v_biz),
          'draft', v_live, md5('v564-fresh'));
  insert into public.loyalty_program_versions(config_version_id, business_id, kind, loyalty_model, active,
    earn_points_per_dollar, redeem_points, reward_credit_cents, tier_basis, expiry_mode)
  values (v_fresh, v_biz, 'points', 'classic', true, 2, 100, 0, 'visits', 'none');
  perform public.publish_loyalty_config(v_fresh);
  select lp.earn_points_per_dollar into v_earn from public.loyalty_programs lp where lp.business_id=v_biz;
  insert into _r values ('02c a draft based on the live pointer still publishes',
    case when v_earn = 2 then 'OK' else 'FAIL: live earn rate is '||coalesce(v_earn::text,'NULL') end);

  -- the stale draft: based on v1, which the publish above just superseded — carrying an earn
  -- rate 50x the live one (the exact shape of the worst open draft in prod).
  insert into public.firm_config_versions(id, business_id, version_no, status, based_on_version_id, snapshot_hash)
  values (v_stale, v_biz,
          (select coalesce(max(version_no),0)+1 from public.firm_config_versions where business_id=v_biz),
          'draft', v_live, md5('v564-stale'));
  insert into public.loyalty_program_versions(config_version_id, business_id, kind, loyalty_model, active,
    earn_points_per_dollar, redeem_points, reward_credit_cents, tier_basis, expiry_mode)
  values (v_stale, v_biz, 'points', 'classic', true, 100, 100, 0, 'visits', 'none');
  begin
    perform public.publish_loyalty_config(v_stale);
    insert into _r values ('02a a stale draft is refused', 'FAIL: publish accepted it');
  exception when sqlstate '23514' then
    insert into _r values ('02a a stale draft is refused',
      case when sqlerrm like 'stale_draft:%' then 'OK' else 'FAIL: wrong 23514 — '||sqlerrm end);
  end;

  select lp.earn_points_per_dollar into v_earn from public.loyalty_programs lp where lp.business_id=v_biz;
  insert into _r values ('02b the live earn rate was not rewritten',
    case when v_earn = 2 then 'OK' else 'FAIL: live earn rate is now '||coalesce(v_earn::text,'NULL') end);

  insert into _r values ('02d ordering note',
    'OK — 02c ran before 02a so v1 is genuinely superseded');
exception when others then
  insert into _r values ('02 stale-draft refusal', 'FAIL: '||sqlerrm);
end
$stale$;

-- 03 — a draft that never mentions a column cannot erase it.
do $erase$
declare
  v_biz uuid := 'cafe0564-0000-4000-8000-000000000011';
  v_live uuid;
  v_ver uuid := 'cafe0564-0000-4000-8000-000000000012';
  v_sv integer; v_sre integer;
begin
  insert into public.businesses(id, name, slug, industry)
  values (v_biz, 'v564 fixture b', 'v564-fixture-b-rolled-back', 'fnb');
  insert into public.business_programmes(business_id, kind, active, sort)
  values (v_biz, 'points', true, 1)
  on conflict (business_id, kind) do update set active = true;
  update public.business_programmes set active=false
   where business_id=v_biz and kind in ('stamps','tiers');
  insert into public.loyalty_programs(business_id, kind, loyalty_model, active,
    earn_points_per_dollar, redeem_points, expiry_mode, stamp_validity_days,
    stamp_reward_expiry_days, configuration_status)
  values (v_biz, 'points', 'classic', true, 1, 100, 'none', 180, 45, 'published')
  on conflict (business_id) do update set kind='points', loyalty_model='classic', active=true,
    earn_points_per_dollar=1, redeem_points=100, expiry_mode='none',
    stamp_validity_days=180, stamp_reward_expiry_days=45, configuration_status='published';
  select b.active_config_version_id into v_live from public.businesses b where b.id=v_biz;

  insert into public.firm_config_versions(id, business_id, version_no, status, based_on_version_id, snapshot_hash)
  values (v_ver, v_biz,
          (select coalesce(max(version_no),0)+1 from public.firm_config_versions where business_id=v_biz),
          'draft', v_live, md5('v564-erase'));
  -- the clone that never mentions the two stamp-day columns
  insert into public.loyalty_program_versions(config_version_id, business_id, kind, loyalty_model, active,
    earn_points_per_dollar, redeem_points, reward_credit_cents, tier_basis, expiry_mode)
  values (v_ver, v_biz, 'points', 'classic', true, 1, 100, 0, 'visits', 'none');

  perform public.publish_loyalty_config(v_ver);
  select lp.stamp_validity_days, lp.stamp_reward_expiry_days into v_sv, v_sre
    from public.loyalty_programs lp where lp.business_id=v_biz;
  insert into _r values ('03 a NULL clone cannot erase stamp validity or gift expiry',
    case when v_sv = 180 and v_sre = 45 then 'OK'
         else 'FAIL: live row now holds '||coalesce(v_sv::text,'NULL')||'/'||coalesce(v_sre::text,'NULL') end);
exception when others then
  insert into _r values ('03 a NULL clone cannot erase stamp validity or gift expiry', 'FAIL: '||sqlerrm);
end
$erase$;

-- 04 — 'fixed' expiry with no number of days is not a configuration.
do $expiry$
declare
  v_biz uuid := 'cafe0564-0000-4000-8000-000000000021';
  v_live uuid;
  v_ver uuid := 'cafe0564-0000-4000-8000-000000000022';
begin
  insert into public.businesses(id, name, slug, industry)
  values (v_biz, 'v564 fixture c', 'v564-fixture-c-rolled-back', 'fnb');
  insert into public.business_programmes(business_id, kind, active, sort)
  values (v_biz, 'points', true, 1)
  on conflict (business_id, kind) do update set active = true;
  update public.business_programmes set active=false
   where business_id=v_biz and kind in ('stamps','tiers');
  insert into public.loyalty_programs(business_id, kind, loyalty_model, active,
    earn_points_per_dollar, redeem_points, expiry_mode, expiry_days, configuration_status)
  values (v_biz, 'points', 'classic', true, 1, 100, 'none', null, 'published')
  on conflict (business_id) do update set kind='points', loyalty_model='classic', active=true,
    earn_points_per_dollar=1, redeem_points=100, expiry_mode='none', expiry_days=null,
    configuration_status='published';
  select b.active_config_version_id into v_live from public.businesses b where b.id=v_biz;

  insert into public.firm_config_versions(id, business_id, version_no, status, based_on_version_id, snapshot_hash)
  values (v_ver, v_biz,
          (select coalesce(max(version_no),0)+1 from public.firm_config_versions where business_id=v_biz),
          'draft', v_live, md5('v564-expiry'));
  insert into public.loyalty_program_versions(config_version_id, business_id, kind, loyalty_model, active,
    earn_points_per_dollar, redeem_points, reward_credit_cents, tier_basis, expiry_mode, expiry_days)
  values (v_ver, v_biz, 'points', 'classic', true, 1, 100, 0, 'visits', 'fixed', null);

  perform public.publish_loyalty_config(v_ver);
  insert into _r values ('04 fixed points expiry with no day count is refused', 'FAIL: publish accepted it');
exception when sqlstate '23514' then
  insert into _r values ('04 fixed points expiry with no day count is refused',
    case when sqlerrm like '%no number of days%' then 'OK' else 'FAIL: wrong 23514 — '||sqlerrm end);
when others then
  insert into _r values ('04 fixed points expiry with no day count is refused', 'FAIL: '||sqlerrm);
end
$expiry$;

select * from _r order by check_id;

rollback;
