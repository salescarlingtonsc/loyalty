-- Rollback-only acceptance for nestly_v559 — publishing a draft may never switch the live
-- loyalty programme off.
-- Run: supabase db query --linked -f db/tests/v559_publish_never_flips_loyalty_off.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  public.publish_loyalty_config no longer contains the draft copy
--       (active=v_typed.active) and does contain the v559 sync + its audit action name.
--   02  no tenant is diverged: for every public.loyalty_programs row, active equals the spine
--       truth (an active business_programmes row of kind points|stamps exists) — the state the
--       v559 backfill established and the patched publish preserves.
--   03  end to end, on this database, rolled back: a fixture business with spine points ON,
--       live active=true, and a DRAFT whose typed row says active=false is published (the
--       owner-gate is stubbed inside this transaction only) — the live row must still read
--       active=true afterwards, and audit_log must carry loyalty_active.draft_flag_ignored
--       for the fixture business.
--
-- ROLLBACK: reverting v559 means restoring `active=v_typed.active` in the publish update and
-- deleting the sync block. Only appropriate if the owner decides the draft's flag SHOULD govern
-- the live switch again — which re-opens the recorded defect (KKY demo 2026-08-27: a birthday
-- publish silently switching points off while the spine kept earning).

begin;

create temp table _r(check_id text, value text) on commit drop;

-- 01 — function shape
do $shape$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.publish_loyalty_config(uuid)'::regprocedure);
  insert into _r values ('01 publish no longer obeys the draft flag',
    case when position('active=v_typed.active' in v_def) > 0
      then 'FAIL: the draft copy is back'
      when position('loyalty_active.draft_flag_ignored' in v_def) = 0
      then 'FAIL: the v559 audit action is missing'
      when position('active=(v_spine_points or v_spine_stamps)' in v_def) = 0
      then 'FAIL: the spine-truth write is missing'
      else 'OK' end);
end
$shape$;

-- 02 — no diverged tenant
do $sync$
declare v_bad integer;
begin
  select count(*) into v_bad
    from public.loyalty_programs lp
   where lp.active is distinct from exists(
           select 1 from public.business_programmes bp
            where bp.business_id = lp.business_id and bp.active
              and bp.kind in ('points','stamps'));
  insert into _r values ('02 every tenant lp.active == spine truth',
    case when v_bad = 0 then 'OK' else 'FAIL: '||v_bad||' diverged tenant(s)' end);
end
$sync$;

-- 03 — end to end on a rolled-back fixture; the owner gate is stubbed IN THIS TRANSACTION ONLY
create or replace function app.c45_owner_loyalty_write(p_business_id uuid)
returns boolean language sql stable as $stub$ select true $stub$;

do $endtoend$
declare
  v_biz uuid := 'cafe0559-0000-4000-8000-000000000001';
  v_ver uuid := 'cafe0559-0000-4000-8000-000000000002';
  v_active boolean;
  v_audited boolean;
begin
  insert into public.businesses(id, name, slug, industry)
  values (v_biz, 'v559 fixture', 'v559-fixture-rolled-back', 'fnb');
  -- the businesses insert auto-seeds spine rows (and may auto-seed loyalty_programs); shape
  -- them rather than insert beside them.
  insert into public.business_programmes(business_id, kind, active, sort)
  values (v_biz, 'points', true, 1)
  on conflict (business_id, kind) do update set active = true;
  -- configuration_status must be 'published' for an active row (the v507 check constraint).
  insert into public.loyalty_programs(business_id, kind, loyalty_model, active, earn_points_per_dollar, configuration_status)
  values (v_biz, 'points', 'classic', true, 1, 'published')
  on conflict (business_id) do update set kind='points', loyalty_model='classic', active=true,
    earn_points_per_dollar=1, configuration_status='published';
  insert into public.firm_config_versions(id, business_id, version_no, status, snapshot_hash)
  values (v_ver, v_biz,
          (select coalesce(max(version_no),0)+1 from public.firm_config_versions where business_id = v_biz),
          'draft', md5('v559-fixture'));
  insert into public.loyalty_program_versions(config_version_id, business_id, kind, loyalty_model, active,
    earn_points_per_dollar, redeem_points, reward_credit_cents, tier_basis, expiry_mode)
  values (v_ver, v_biz, 'points', 'classic', false, 1, 100, 500, 'visits', 'none');

  perform public.publish_loyalty_config(v_ver);

  select lp.active into v_active from public.loyalty_programs lp where lp.business_id = v_biz;
  select exists(select 1 from public.audit_log a
                 where a.business_id = v_biz
                   and a.action = 'loyalty_active.draft_flag_ignored') into v_audited;
  insert into _r values ('03 publishing an active=false draft leaves a live programme on',
    case when v_active is true and v_audited then 'OK'
         when v_active is not true then 'FAIL: live active became '||coalesce(v_active::text,'null')
         else 'FAIL: draft_flag_ignored audit row missing' end);
exception when others then
  insert into _r values ('03 publishing an active=false draft leaves a live programme on',
    'FAIL: '||sqlerrm);
end
$endtoend$;

select * from _r order by check_id;

rollback;
