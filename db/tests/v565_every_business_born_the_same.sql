-- Rollback-only acceptance for nestly_v565 — every business is born the same: one helper owns the
-- birth of public.loyalty_programs, the platform paths never skip it silently, tiers count as a
-- live programme, and referral cannot be switched on with no reward behind it.
-- Run: supabase db query --linked -f db/tests/v565_every_business_born_the_same.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  shape: app.ensure_loyalty_program_row exists; the three Settings bootstrappers and
--       create_loyalty_config_draft call it instead of inventing their own narrower row; the two
--       platform paths seed loudly; set_programmes_v314 counts tiers and guards referral.
--   02  the stranded-tenant repair, rolled back: a bare business insert reproduces the exact live
--       shape (no loyalty_programs row, active_config_version_id NULL) — one ensure call gives it
--       the FULL onboarding preset plus a published version 1, even while the owner guard refuses,
--       and a second call changes nothing.
--   03  tiers-only truth: a business whose only running programme is Tier membership syncs its
--       loyalty row to active=true, not false (the v514 formula counted points and stamps only).
--   04  referral needs its reward: switching referral ON with no public.referral_programs row is
--       refused with 22023; switching it OFF with no row stays the no-op it always was.
--   06  the same RPCs EXECUTED, not grepped: a Settings-first business is born with the full
--       preset, a NULL parameter still leaves its field alone, and Grow opens on a rowless tenant.
--   05  data: no business anywhere is without its loyalty_programs row.
--
-- ROLLBACK: reverting v565 means restoring each RPC's own narrower bootstrap insert, restoring the
-- silent skip in the two platform paths, dropping the tiers term from the active formula and
-- dropping the referral guard. Only appropriate if the owner decides a tenant SHOULD be able to
-- exist with no loyalty row — which re-opens the recorded defect (two live tenants that could
-- never open Grow, because create_loyalty_config_draft raised 'base configuration not found').

begin;

create temp table _r(check_id text, value text) on commit drop;

do $shape$
declare v_ensure text; v_353 text; v_359 text; v_347 text; v_draft text; v_105 text; v_169 text; v_314 text;
begin
  if to_regprocedure('app.ensure_loyalty_program_row(uuid,text)') is null then
    insert into _r values ('01a the one birth helper exists', 'FAIL: app.ensure_loyalty_program_row is missing');
    return;
  end if;
  v_ensure := pg_get_functiondef('app.ensure_loyalty_program_row(uuid,text)'::regprocedure);
  v_353  := pg_get_functiondef('public.business_set_loyalty_model_v353(uuid,text)'::regprocedure);
  v_359  := pg_get_functiondef('public.business_set_earning_rule_v359(uuid,numeric,integer,text,integer,integer,integer)'::regprocedure);
  v_347  := pg_get_functiondef('public.business_set_tier_basis_v347(uuid,text)'::regprocedure);
  v_draft:= pg_get_functiondef('public.create_loyalty_config_draft(uuid,uuid,text)'::regprocedure);
  v_105  := pg_get_functiondef('public.platform_decide_business_application_v105(uuid,text,text,bigint,uuid)'::regprocedure);
  v_169  := pg_get_functiondef('public.platform_activate_approved_application_v169(uuid,uuid)'::regprocedure);
  v_314  := pg_get_functiondef('public.set_programmes_v314(uuid,jsonb,uuid)'::regprocedure);

  insert into _r values ('01a the one birth helper exists',
    case when position('on conflict(business_id) do nothing' in v_ensure) = 0
      then 'FAIL: the helper is not idempotent'
      when position('p_business,''points'',1,800,2000,false,''classic'',''draft''' in v_ensure) = 0
      then 'FAIL: the helper does not write the full onboarding preset'
      else 'OK' end);

  insert into _r values ('01b no RPC invents its own narrower row',
    case when position('app.ensure_loyalty_program_row(p_business, ''settings_bootstrap'')' in v_353) = 0
      then 'FAIL: business_set_loyalty_model_v353 still bootstraps its own row'
      when position('app.ensure_loyalty_program_row(p_business, ''settings_bootstrap'')' in v_359) = 0
      then 'FAIL: business_set_earning_rule_v359 still bootstraps its own row'
      when position('app.ensure_loyalty_program_row(p_business, ''settings_bootstrap'')' in v_347) = 0
      then 'FAIL: business_set_tier_basis_v347 still bootstraps its own row'
      when position('insert into public.loyalty_programs' in v_353) > 0
        or position('insert into public.loyalty_programs' in v_359) > 0
        or position('insert into public.loyalty_programs' in v_347) > 0
      then 'FAIL: a Settings RPC still carries a loyalty_programs insert of its own'
      else 'OK' end);

  insert into _r values ('01c Grow no longer dead-ends on a missing row',
    case when position('app.ensure_loyalty_program_row(p_business, ''draft_bootstrap'')' in v_draft) = 0
      then 'FAIL: create_loyalty_config_draft still raises without trying to create the row'
      else 'OK' end);

  insert into _r values ('01d the platform paths seed loudly, never silently',
    case when position('loyalty_core.seeded_v565' in v_105) = 0
      then 'FAIL: platform_decide_business_application_v105 can still skip the loyalty row in silence'
      when position('loyalty_core.seeded_v565' in v_169) = 0
      then 'FAIL: platform_activate_approved_application_v169 can still skip the loyalty row in silence'
      when position('if app.c45_owner_loyalty_write(v_business.id) then' in v_105) = 0
        or position('if app.c45_owner_loyalty_write(v_business.id) then' in v_169) = 0
      then 'FAIL: the owner guard was removed rather than made non-silent'
      else 'OK' end);

  insert into _r values ('01e tiers count and referral is guarded',
    case when position('set active = (v_points or v_stamps or v_tiers)' in v_314) = 0
      then 'FAIL: the active formula still ignores tiers'
      when position('into v_points, v_stamps, v_tiers' in v_314) = 0
      then 'FAIL: the tiers spine is not captured alongside points and stamps'
      when position('referral_needs_configuration' in v_314) = 0
      then 'FAIL: referral can still be switched on with no reward'
      when position('The stamp card runs on its own.' in v_314) = 0
      then 'FAIL: the stamps exclusivity guard was disturbed'
      else 'OK' end);
end
$shape$;

-- 02 — the owner gate is stubbed IN THIS TRANSACTION ONLY (the v559/v560/v563 suites' pattern).
create or replace function app.c45_owner_loyalty_write(p_business_id uuid)
returns boolean language sql stable as $stub$ select true $stub$;

do $repair$
declare
  v_biz uuid := 'ca7e0565-0000-4000-8000-000000000001';
  v_row public.loyalty_programs%rowtype;
  v_stranded boolean;
  v_ver_no integer; v_ver_status text; v_active_ver uuid;
  v_before bigint; v_after bigint;
begin
  -- a bare businesses insert IS the stranded shape: the spine rows and the other per-business
  -- seeds fire, but version 1 only appears once a loyalty_programs row exists.
  insert into public.businesses(id, name, slug, industry)
  values (v_biz, 'v565 fixture', 'v565-fixture-rolled-back', 'fnb');
  select not exists(select 1 from public.loyalty_programs lp where lp.business_id=v_biz)
     and (select b.active_config_version_id is null from public.businesses b where b.id=v_biz)
    into v_stranded;
  insert into _r values ('02a a bare business reproduces the stranded shape',
    case when v_stranded then 'OK' else 'FAIL: the fixture is not the shape the two live tenants are in' end);

  -- the guard the two platform paths consult REFUSES, and the row is created anyway.
  create or replace function app.c45_owner_loyalty_write(p_business_id uuid)
  returns boolean language sql stable as $stub$ select false $stub$;
  perform app.ensure_loyalty_program_row(v_biz, 'v565_backfill');
  create or replace function app.c45_owner_loyalty_write(p_business_id uuid)
  returns boolean language sql stable as $stub$ select true $stub$;

  select * into v_row from public.loyalty_programs where business_id=v_biz;
  insert into _r values ('02b the repaired row carries the full onboarding preset',
    case when v_row.business_id is null then 'FAIL: no loyalty row was created'
         when v_row.kind is distinct from 'points' then 'FAIL: kind='||coalesce(v_row.kind,'NULL')
         when v_row.loyalty_model is distinct from 'classic' then 'FAIL: loyalty_model='||coalesce(v_row.loyalty_model,'NULL')
         when v_row.earn_points_per_dollar is distinct from 1 then 'FAIL: earn='||coalesce(v_row.earn_points_per_dollar::text,'NULL')
         when v_row.redeem_points is distinct from 800 then 'FAIL: redeem_points='||coalesce(v_row.redeem_points::text,'NULL')
         when v_row.reward_credit_cents is distinct from 2000 then 'FAIL: reward_credit_cents='||coalesce(v_row.reward_credit_cents::text,'NULL')
         when v_row.recommendation_source is distinct from 'v565_backfill' then 'FAIL: recommendation_source='||coalesce(v_row.recommendation_source,'NULL')
         when v_row.active then 'FAIL: the repair turned loyalty ON -- it must never flip anything on'
         else 'OK' end);

  select fcv.version_no, fcv.status into v_ver_no, v_ver_status
    from public.firm_config_versions fcv where fcv.business_id=v_biz order by fcv.version_no limit 1;
  select b.active_config_version_id into v_active_ver from public.businesses b where b.id=v_biz;
  insert into _r values ('02c version 1 is born live with the row',
    case when v_ver_no is distinct from 1 then 'FAIL: first version_no='||coalesce(v_ver_no::text,'NONE')
         when v_ver_status is distinct from 'published' then 'FAIL: version 1 status='||coalesce(v_ver_status,'NULL')
         when v_active_ver is null then 'FAIL: the business still has no active_config_version_id'
         when not exists(select 1 from public.loyalty_program_versions lpv
                          where lpv.business_id=v_biz and lpv.config_version_id=v_active_ver)
         then 'FAIL: version 1 carries no typed loyalty row, so create_loyalty_config_draft still has no base'
         else 'OK' end);

  select count(*) into v_before from public.loyalty_programs where business_id=v_biz;
  perform app.ensure_loyalty_program_row(v_biz, 'v565_backfill');
  select count(*) into v_after from public.loyalty_programs where business_id=v_biz;
  insert into _r values ('02d a second call is a no-op',
    case when v_before=1 and v_after=1
          and (select count(*) from public.firm_config_versions where business_id=v_biz)=1
         then 'OK' else 'FAIL: the helper is not idempotent' end);
exception when others then
  insert into _r values ('02z stranded-tenant repair', 'FAIL: '||sqlerrm);
end
$repair$;

do $tiers$
declare
  v_biz uuid := 'ca7e0565-0000-4000-8000-000000000002';
  v_active boolean;
begin
  insert into public.businesses(id, name, slug, industry)
  values (v_biz, 'v565 tiers fixture', 'v565-tiers-fixture-rolled-back', 'fnb');
  perform app.ensure_loyalty_program_row(v_biz, 'v565_test');
  update public.business_programmes set active=false
   where business_id=v_biz and kind in ('points','stamps','referral');
  update public.business_programmes set active=true where business_id=v_biz and kind='tiers';

  perform public.set_programmes_v314(v_biz, jsonb_build_object('tiers', true),
                                     'ca7e0565-0000-4000-8000-0000000000a1');
  select lp.active into v_active from public.loyalty_programs lp where lp.business_id=v_biz;
  insert into _r values ('03 a tiers-only business reads as running',
    case when v_active then 'OK'
         else 'FAIL: loyalty_programs.active is false while Tier membership is the running programme' end);
exception when others then
  insert into _r values ('03 a tiers-only business reads as running', 'FAIL: '||sqlerrm);
end
$tiers$;

do $referral$
declare
  v_biz uuid := 'ca7e0565-0000-4000-8000-000000000003';
begin
  insert into public.businesses(id, name, slug, industry)
  values (v_biz, 'v565 referral fixture', 'v565-referral-fixture-rolled-back', 'fnb');
  perform app.ensure_loyalty_program_row(v_biz, 'v565_test');
  delete from public.referral_programs where business_id=v_biz;

  -- OFF with no row must stay the no-op it always was
  begin
    perform public.set_programmes_v314(v_biz, jsonb_build_object('referral', false),
                                       'ca7e0565-0000-4000-8000-0000000000b1');
    insert into _r values ('04a referral OFF with no reward stays a no-op', 'OK');
  exception when others then
    insert into _r values ('04a referral OFF with no reward stays a no-op', 'FAIL: '||sqlerrm);
  end;

  -- ON with no row must be refused, by name
  begin
    perform public.set_programmes_v314(v_biz, jsonb_build_object('referral', true),
                                       'ca7e0565-0000-4000-8000-0000000000b2');
    insert into _r values ('04b referral ON with no reward is refused', 'FAIL: the switch was accepted');
  exception when sqlstate '22023' then
    insert into _r values ('04b referral ON with no reward is refused',
      case when position('referral_needs_configuration' in sqlerrm) > 0 then 'OK'
           else 'FAIL: refused, but not by the named reason: '||sqlerrm end);
  when others then
    insert into _r values ('04b referral ON with no reward is refused', 'FAIL: '||sqlerrm);
  end;
exception when others then
  insert into _r values ('04z referral guard', 'FAIL: '||sqlerrm);
end
$referral$;

-- 06 — the RPCs are EXECUTED, not grepped: a shape check that only reads the source would stay
-- green while the behaviour was dead.
do $settings$
declare
  v_biz uuid := 'ca7e0565-0000-4000-8000-000000000004';
  v_biz2 uuid := 'ca7e0565-0000-4000-8000-000000000005';
  v_row public.loyalty_programs%rowtype;
  v_draft json;
begin
  insert into public.businesses(id, name, slug, industry)
  values (v_biz, 'v565 settings fixture', 'v565-settings-fixture-rolled-back', 'fnb');
  -- the row does NOT exist yet: this is the path that used to invent a narrower one
  perform public.business_set_loyalty_model_v353(v_biz, 'points_tiers');
  perform public.business_set_tier_basis_v347(v_biz, 'spend');
  perform public.business_set_earning_rule_v359(v_biz, 3.5, 250, 'fixed', 30, null, null);
  select * into v_row from public.loyalty_programs where business_id=v_biz;
  insert into _r values ('06a a Settings-first business is born identical to an onboarded one',
    case when v_row.business_id is null then 'FAIL: no loyalty row was created'
         when v_row.redeem_points is distinct from 800 then 'FAIL: redeem_points='||coalesce(v_row.redeem_points::text,'NULL')||' -- the narrow bootstrap is back'
         when v_row.reward_credit_cents is distinct from 2000 then 'FAIL: reward_credit_cents='||coalesce(v_row.reward_credit_cents::text,'NULL')||' -- the narrow bootstrap is back'
         when v_row.loyalty_model is distinct from 'points_tiers' then 'FAIL: v353 did not set the model'
         when v_row.tier_basis is distinct from 'spend' then 'FAIL: v347 did not set the basis'
         when v_row.earn_points_per_dollar is distinct from 3.5 then 'FAIL: v359 did not set the earn rate'
         when v_row.expiry_mode is distinct from 'fixed' or v_row.expiry_days is distinct from 30 then 'FAIL: v359 did not set expiry'
         when v_row.active then 'FAIL: a Settings save turned loyalty ON'
         else 'OK' end);

  -- a NULL parameter still means "leave this field alone"
  perform public.business_set_earning_rule_v359(v_biz, null, null, null, null, null, null);
  select * into v_row from public.loyalty_programs where business_id=v_biz;
  insert into _r values ('06b v359 still leaves NULL parameters alone',
    case when v_row.earn_points_per_dollar = 3.5 and v_row.stamp_per_cents = 250
          and v_row.expiry_mode = 'fixed' and v_row.expiry_days = 30
         then 'OK' else 'FAIL: an all-NULL call overwrote the saved rule' end);

  -- and Grow opens on a business that never had a row
  insert into public.businesses(id, name, slug, industry)
  values (v_biz2, 'v565 grow fixture', 'v565-grow-fixture-rolled-back', 'fnb');
  v_draft := public.create_loyalty_config_draft(v_biz2);
  insert into _r values ('06c Grow opens on a business that never had a loyalty row',
    case when v_draft->>'status' = 'draft'
          and exists(select 1 from public.loyalty_programs where business_id=v_biz2)
         then 'OK' else 'FAIL: no draft, or still no loyalty row' end);
exception when others then
  insert into _r values ('06z the Settings RPCs and Grow, executed', 'FAIL: '||sqlerrm);
end
$settings$;

do $data$
declare v_bad integer;
begin
  select count(*) into v_bad
    from public.businesses b
    left join public.loyalty_programs lp on lp.business_id=b.id
   where lp.business_id is null;
  insert into _r values ('05 every business has its loyalty row',
    case when v_bad=0 then 'OK' else 'FAIL: '||v_bad||' business(es) still stranded' end);
end
$data$;

select * from _r order by check_id;

rollback;
