-- Rollback-only nestly_v846 acceptance: the customer's QR minter and the counter that scans it
-- read the same catalogue. Four authorities decide whether a gift may be claimed —
-- app.reward_availability_v432 (what the customer is SHOWN),
-- public.customer_create_redemption_intent_v89 (what the QR is MINTED from),
-- public.merchant_scan_redemption_qr_v117 (what the till ACCEPTS),
-- app.redeem_reward_core (what the counter PAYS OUT) — and v846 makes the middle two agree with
-- the outer two on all four points the 2026-09-09 audit measured.
--
-- WHAT THE BUGS WERE, all measured against PRODUCTION inside rolled-back transactions:
--
--   (A) PINNED VERSION. The minter's version selector branched on loyalty_rewards.active:
--         case when v_reward.active then <the firm's ACTIVE version>
--                                   else app.stamp_cycle_version_v416(...) end
--       nestly_v805 (DELETE) clears active, so a withdrawn stamp gift fell to the customer's pin
--       by accident; nestly_v814 (PAUSE) deliberately leaves active = true, so a paused-forward
--       stamp gift read the NEW paused version. app.reward_availability_v432 and
--       app.redeem_reward_core both resolve a stamp reward through app.stamp_cycle_version_v416
--       whatever that flag says. Production, rolled back, 4-of-5-stamp customer pinned to v1,
--       gift paused forward:
--         reward_availability_v432 available_at_counter | redeem_reward_core ok=true slot=3
--         customer_create_redemption_intent_v89 -> 22023 "reward is unavailable"  <-- odd one out
--
--   (D) THE QUOTED VERSION. quoted_points_spent / quoted_config_version_id came from whatever (A)
--       resolved while app.redeem_reward_core charged the pin: gift edited 3 stamps -> 2, intent
--       quoted 2, till printed 2, ledger took 3. Correcting the minter alone was not enough,
--       because public.merchant_scan_redemption_qr_v117 loaded the quoted version with
--       `config_version_id = business.active_config_version_id` and otherwise raised 23514 — so a
--       correctly PINNED quote could not be scanned at all. That defect was ALREADY live through
--       the nestly_v805 withdrawn branch, which already quoted the pin. Production, rolled back:
--         v432 available_at_counter | minter MINTED quoting PINNED v1, points=2
--         merchant_scan_redemption_qr_v117 -> 23514 "catalog redemption terms changed"
--       v846 owns both functions, so both halves land in one transaction.
--
--   (B) POT SCOPE. Two adjacent lines in the minter disagreed with each other:
--         v_balance := app.client_points_balance_v409(...)   -- scope-aware since nestly_v409
--         select sum(remaining) ... where programme_id = v_intent_programme  -- NOT scope-aware
--       nestly_v815 taught app.redeem_reward_core to spend across every pot when
--       app.programme_balance_scope_v312(business) <> 'programme_pot'. Production, rolled back,
--       one pending programme_pot_migrations row, 70 live + 30 retired, 90-point gift:
--         programme_balance_scope_v312 business_pot | client_points_balance_v409 100
--         reward_availability_v432 available_at_counter | redeem_reward_core ok=true spent=90
--         customer_create_redemption_intent_v89 -> 23514 "insufficient points"    <-- odd one out
--
--   (C) EXPIRED POINTS. The minter's batch sum carried no expiry filter while
--       app.customer_live_loyalty_v384 and public.staff_get_customer_actionable_loyalty_v145 both
--       exclude expired batches; the sweep runs once a day, so a batch that expires mid-morning
--       stayed mintable all day. *** The other two thirds of this fix ship in the sibling
--       migration nestly_v847, which puts the same predicate into app.reward_availability_v432
--       and app.redeem_reward_core. This suite asserts only the minter's third, because that is
--       the only third v846 owns; the pair is applied together. ***
--
-- WHAT THIS SUITE PROVES, against two tenants it builds itself:
--   01-03  (B) pot scope: mint, payout, and the sensitivity that the rule was MIRRORED from v815
--          rather than replaced by "always sum every pot"
--   04-05  CONTROL: the non-stamps path is untouched end to end — quoted from the ACTIVE version,
--          scanned to completion by the real till
--   06     GUARD: a non-stamps quote whose version is no longer the active one is STILL refused
--   07-08  (C) an expired batch is not spendable, and the same batch with an hour of life is
--   09-12  (A)/(D) a paused-forward stamp gift: offered, minted from the PIN, scanned, and the
--          ledger records the pinned slot and the pinned configuration version
--   13-14  (D) the price case: gift edited 2 stamps -> 1, the mid-card customer is quoted 2, the
--          till prints 2 and the ledger takes 2
--   15-18  MUTATION CHECKS: each of the three splices is reverted INDIVIDUALLY and the assertions
--          it is supposed to carry are shown to break again. An assertion that survives its own
--          mutation is measuring nothing, and this suite fails if one does.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v846_redemption_intent_agrees_with_the_engine.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole suite.
-- Any row whose outcome starts with FAIL is a failure, and the gate at the end raises on one.
--
-- TIME. now() is fixed for the whole transaction and app.stamp_cycle_version_v416 resolves the pin
-- by `published_at <= the customer's first stamp`. Two versions are published on the stamps
-- tenant, so version 1 is backdated two days and version 2 an hour: otherwise both would carry the
-- same published_at and "the newest version at or before this stamp" would be a coin toss.

begin;

create temp table v846_out(seq integer, step text, outcome text) on commit drop;

do $v846_test$
declare
  -- tenant one: a points firm with a live pot and a retired pot
  p_biz uuid := gen_random_uuid();
  p_owner uuid := gen_random_uuid();
  p_cust uuid := gen_random_uuid();
  p_identity uuid := gen_random_uuid();
  p_c1 uuid := gen_random_uuid();
  p_live uuid; p_retired uuid;
  p_branch uuid := gen_random_uuid();
  p_staff uuid;
  p_gift90 uuid := gen_random_uuid();
  p_gift50 uuid := gen_random_uuid();
  p_link uuid := gen_random_uuid();
  p_s1 uuid := gen_random_uuid();
  p_s2 uuid := gen_random_uuid();
  p_cfg uuid; p_cfg_draft uuid;
  p_migration uuid := gen_random_uuid();
  p_batch_live uuid;
  -- tenant two: a stamps firm with three mid-card customers
  s_biz uuid := gen_random_uuid();
  s_owner uuid := gen_random_uuid();
  s_spine uuid := gen_random_uuid();
  s_branch uuid := gen_random_uuid();
  s_staff uuid;
  s_cust1 uuid := gen_random_uuid(); s_cust2 uuid := gen_random_uuid(); s_cust3 uuid := gen_random_uuid();
  s_id1 uuid := gen_random_uuid();   s_id2 uuid := gen_random_uuid();   s_id3 uuid := gen_random_uuid();
  s_cl1 uuid := gen_random_uuid();   s_cl2 uuid := gen_random_uuid();   s_cl3 uuid := gen_random_uuid();
  s_lk1 uuid := gen_random_uuid();   s_lk2 uuid := gen_random_uuid();   s_lk3 uuid := gen_random_uuid();
  s_sd1 uuid := gen_random_uuid();   s_sd2 uuid := gen_random_uuid();   s_sd3 uuid := gen_random_uuid();
  s_two uuid := gen_random_uuid();
  s_free uuid := gen_random_uuid();
  s_big uuid := gen_random_uuid();
  s_cfg uuid; s_cfg2 uuid;
  v_res jsonb; v_txt text; v_err text; v_msg text; v_intent jsonb; v_iid uuid; v_qr text;
  v_def text; v_new text;
  -- the three splices, restated so each can be reverted on its own
  m_anchor_version constant text :=
$anchor_version$    select reward_version.* into v_reward_version
    from public.loyalty_reward_versions reward_version
    where reward_version.reward_id=p_reward
      and reward_version.business_id=p_business
      and reward_version.config_version_id = case when v_reward.active
            then (select business.active_config_version_id from public.businesses business
                   where business.id=p_business)
            else app.stamp_cycle_version_v416(p_business, v_client, v_reward.programme_id) end
      and reward_version.active;
$anchor_version$;
  m_inject_version constant text :=
$inject_version$    v_stamps_reward := exists (select 1 from public.business_programmes spine
                                where spine.id=v_reward.programme_id
                                  and spine.business_id=p_business and spine.kind='stamps');
    select reward_version.* into v_reward_version
    from public.loyalty_reward_versions reward_version
    where reward_version.reward_id=p_reward
      and reward_version.business_id=p_business
      and reward_version.config_version_id = case when v_stamps_reward
            then app.stamp_cycle_version_v416(p_business, v_client, v_reward.programme_id)
            else (select business.active_config_version_id from public.businesses business
                   where business.id=p_business) end
      and reward_version.active;
$inject_version$;
  m_anchor_balance constant text :=
$anchor_balance$  v_balance := app.client_points_balance_v409(p_business, v_client);
  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0
      and programme_id=v_intent_programme;
$anchor_balance$;
  m_inject_balance constant text :=
$inject_balance$  v_balance := app.client_points_balance_v409(p_business, v_client);
  v_all_pots := app.programme_balance_scope_v312(p_business) <> 'programme_pot';
  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0
      and (expires_at is null or expires_at>now())
      and (v_all_pots or programme_id=v_intent_programme);
$inject_balance$;
  s_anchor_version constant text :=
$scan_version$    select reward_version.*
      into v_reward_version
      from public.loyalty_reward_versions reward_version
      join public.businesses business
        on business.id=reward_version.business_id
     where reward_version.id=v_intent.quoted_reward_version_id
       and reward_version.reward_id=v_intent.reward_id
       and reward_version.business_id=p_business
       and reward_version.config_version_id=business.active_config_version_id
       and reward_version.active
     for share;
$scan_version$;
  s_inject_version constant text :=
$scan_inject$    select exists (select 1 from public.business_programmes spine
                    where spine.id=reward.programme_id and spine.business_id=p_business
                      and spine.kind='stamps'),
           reward.programme_id
      into v_stamps_reward, v_reward_programme
      from public.loyalty_rewards reward
     where reward.id=v_intent.reward_id and reward.business_id=p_business;
    v_stamps_reward := coalesce(v_stamps_reward,false);
    if v_stamps_reward then
      v_pinned_version := app.stamp_cycle_version_v416(p_business, v_intent.client_id,
                                                       v_reward_programme);
    end if;
    select reward_version.*
      into v_reward_version
      from public.loyalty_reward_versions reward_version
      join public.businesses business
        on business.id=reward_version.business_id
     where reward_version.id=v_intent.quoted_reward_version_id
       and reward_version.reward_id=v_intent.reward_id
       and reward_version.business_id=p_business
       and (reward_version.config_version_id=business.active_config_version_id
            or (v_stamps_reward and v_pinned_version is not null
                and reward_version.config_version_id=v_pinned_version))
       and reward_version.active
     for share;
$scan_inject$;
begin
  -- ==========================================================================================
  -- TENANT ONE — a points firm: 70 points in the pot the gift belongs to, 30 in the pot being
  -- migrated away from, a 90-point gift that needs both and a 50-point gift that does not.
  -- ==========================================================================================
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'zz-v846-po-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',p_cust,'authenticated','authenticated',
          'zz-v846-pc-'||substr(p_cust::text,1,8)||'@example.test','',now(),now(),now());
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,enabled_modules,points_mode)
  values (p_biz,'V846 Points Firm','zz-v846p-'||substr(p_biz::text,1,8),array['loyalty'],'redeem');
  perform set_config('app.v79_system_transition','',true);
  select id into p_live    from public.business_programmes where business_id=p_biz and kind='points';
  select id into p_retired from public.business_programmes where business_id=p_biz and kind='stamps';
  update public.business_programmes set active=true  where id=p_live;
  update public.business_programmes set active=false where id=p_retired;
  insert into public.staff(business_id,user_id,role,active,access_state)
  values (p_biz,p_owner,'owner',true,'approved') returning id into p_staff;
  insert into public.branches(id,business_id,name,is_default,active)
  values (p_branch,p_biz,'V846 points main',true,true);
  insert into public.staff_branches(business_id,staff_id,branch_id) values (p_biz,p_staff,p_branch);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_by=p_owner,
         decided_at=clock_timestamp(),decision_reason='v846 acceptance fixture',
         updated_at=clock_timestamp()
   where business_id=p_biz;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (p_biz,false) on conflict (business_id) do update set workspace_paused=false;
  insert into public.subscriptions(business_id) values (p_biz) on conflict do nothing;
  insert into app.platform_feature_flags(feature_key,enabled)
  values ('customer_wallet',true),('customer_claims',true),('customer_qr_redemption',true)
  on conflict (feature_key) do update set enabled=true;
  insert into public.business_customer_capabilities_v89(business_id,redemption_enabled)
  values (p_biz,true) on conflict (business_id) do update set redemption_enabled=true;
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_owner,'role','authenticated')::text,true);
  insert into public.loyalty_programs(business_id,active,loyalty_model,kind,
                                      configuration_status,earn_points_per_dollar)
  values (p_biz,true,'points_tiers','points','published',1)
  on conflict (business_id) do update
    set active=true,loyalty_model='points_tiers',kind='points',configuration_status='published';
  select id into p_cfg from public.firm_config_versions
   where business_id=p_biz and status='published' order by version_no desc limit 1;
  if p_cfg is null then
    raise exception 'FIXTURE BROKEN: the points tenant published no configuration version';
  end if;
  update public.businesses set active_config_version_id=p_cfg where id=p_biz;
  insert into public.clients(id,business_id,full_name,phone)
  values (p_c1,p_biz,'V846 Two Pots','+65 9832 0001');
  insert into public.customer_identities(id,auth_user_id,status) values (p_identity,p_cust,'active');
  perform set_config('app.customer_link_insert_id',p_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                    verification_method,verified_at)
  values (p_link,p_biz,p_identity,p_cust,p_c1,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id','',true);
  insert into public.loyalty_rewards(id,business_id,name,internal_name,customer_name,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,paused,sort,programme_id)
  values (p_gift90,p_biz,'V846 Big 90','V846 Big 90','V846 Big 90','manual_item',90,0,0,true,false,1,p_live),
         (p_gift50,p_biz,'V846 Mid 50','V846 Mid 50','V846 Mid 50','manual_item',50,0,0,true,false,2,p_live);
  insert into public.loyalty_reward_versions(reward_id,business_id,config_version_id,internal_name,
    customer_name,description,fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,sort,
    programme_id)
  values (p_gift90,p_biz,p_cfg,'V846 Big 90','V846 Big 90','crosses the pots','manual_item',90,0,0,1,p_live),
         (p_gift50,p_biz,p_cfg,'V846 Mid 50','V846 Mid 50','fits one pot'    ,'manual_item',50,0,0,2,p_live);
  perform app.acquire_loyalty_shared_v480(p_biz);
  perform set_config('app.points_ledger_insert_id',p_s1::text,true);
  perform set_config('app.points_ledger_write_scope','adjust_points',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,programme_id)
  values (p_s1,p_biz,p_c1,'adjust',70,'v846 live pot',p_owner,p_live);
  perform set_config('app.points_ledger_insert_id',p_s2::text,true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,programme_id)
  values (p_s2,p_biz,p_c1,'adjust',30,'v846 retired pot',p_owner,p_retired);
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
  /* The batch must match the ledger pot for pot: a pot whose ledger sum and batch remaining
     disagree is itself a business_pot trigger in app.programme_balance_scope_v312, which would
     make the programme_pot half of this suite unreachable. */
  insert into public.points_batches(business_id,client_id,programme_id,earned,remaining,expires_at)
  values (p_biz,p_c1,p_live,70,70,now()+interval '90 days') returning id into p_batch_live;
  insert into public.points_batches(business_id,client_id,programme_id,earned,remaining,expires_at)
  values (p_biz,p_c1,p_retired,30,30,now()+interval '10 days');
  insert into public.programme_pot_migrations(id,business_id,from_programme_id,to_programme_id,status)
  values (p_migration,p_biz,p_retired,p_live,'pending');
  if app.programme_balance_scope_v312(p_biz) is distinct from 'business_pot'
     or app.client_points_balance_v409(p_biz,p_c1) is distinct from 100 then
    raise exception 'FIXTURE BROKEN: the points tenant is not in business_pot with a 100 balance';
  end if;
  select ra.availability into v_txt
    from app.reward_availability_v432(p_biz,p_c1) ra where ra.reward_id=p_gift90;
  if coalesce(v_txt,'ABSENT') is distinct from 'available_at_counter' then
    raise exception 'FIXTURE BROKEN: v432 does not offer the cross-pot gift (%)',
      coalesce(v_txt,'ABSENT');
  end if;

  -- ------------------------------------------------------------------ 01  (B) the minter mints
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_cust,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_err := null;
  begin
    perform public.customer_create_redemption_intent_v89(p_biz,p_gift90,gen_random_uuid(),'catalog_reward');
  exception when others then v_err := sqlstate; v_msg := sqlerrm;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_owner,'role','authenticated')::text,true);
  insert into v846_out values (1,'(B) under business_pot the minter mints the cross-pot gift that '
    'the wallet, app.reward_availability_v432 and app.redeem_reward_core all call affordable',
    case when v_err is null then 'PASS'
         else format('FAIL - still refused: %s %s',v_err,v_msg) end);

  -- --------------------------------------------------------------- 02  (B) and the counter pays
  v_res := app.redeem_reward_core(p_biz,p_c1,p_gift90,'v846-acc-core-01',p_branch)::jsonb;
  insert into v846_out values (2,'(B) app.redeem_reward_core drains the same cross-pot gift on '
    'the same fixture - reader agreement is not correctness, the payout is',
    case when coalesce((v_res->>'ok')::boolean,false) and (v_res->>'points_spent')::integer=90
         then 'PASS' else format('FAIL - %s',v_res) end);
  perform public.reverse_loyalty_redemption(p_biz,(v_res->>'redemption_id')::uuid,
    'v846 acceptance: restore the pots before the programme_pot control','v846-acc-rev-01');

  -- --------------------------------------------------------------------- 03  (B) sensitivity
  delete from public.programme_pot_migrations where id = p_migration;
  if app.programme_balance_scope_v312(p_biz) is distinct from 'programme_pot' then
    raise exception 'FIXTURE BROKEN: removing the pot migration did not restore programme_pot';
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_cust,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_err := null;
  begin
    perform public.customer_create_redemption_intent_v89(p_biz,p_gift90,gen_random_uuid(),'catalog_reward');
  exception when others then v_err := sqlstate;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_owner,'role','authenticated')::text,true);
  insert into v846_out values (3,'(B) sensitivity: back in programme_pot the same 90-point gift '
    'is refused again on a 70-point pot - the rule was MIRRORED from nestly_v815, not replaced '
    'by "always sum every pot"',
    case when v_err = '23514' then 'PASS'
         else format('FAIL - expected 23514, got %s',coalesce(v_err,'MINTED')) end);

  -- ----------------------------------------------------- 04/05  CONTROL: the non-stamps path
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_cust,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_err := null; v_intent := null;
  begin
    v_intent := public.customer_create_redemption_intent_v89(p_biz,p_gift50,gen_random_uuid(),'catalog_reward');
  exception when others then v_err := sqlstate; v_msg := sqlerrm;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_owner,'role','authenticated')::text,true);
  v_iid := (v_intent->>'intent_id')::uuid;
  insert into v846_out values (4,'CONTROL: under programme_pot a 50-point gift the 70-point live '
    'pot affords on its own still mints, and it is quoted from the ACTIVE configuration version',
    case when v_err is not null then format('FAIL - the single-pot path now refuses: %s %s',v_err,v_msg)
         when (select i.quoted_config_version_id from public.customer_redemption_intents_v89 i
                where i.id=v_iid) is distinct from p_cfg
           then 'FAIL - a points gift was not quoted from the active version'
         else 'PASS' end);
  v_err := null;
  begin
    v_res := public.merchant_scan_redemption_qr_v117(p_biz,p_branch,v_intent->>'qr_token',gen_random_uuid());
  exception when others then v_err := sqlstate; v_msg := sqlerrm;
  end;
  insert into v846_out values (5,'CONTROL: and the real till completes that ordinary points '
    'redemption, printing 50',
    case when v_err is not null then format('FAIL - the till refused it: %s %s',v_err,v_msg)
         when coalesce(v_res->>'status','') <> 'completed'
           or coalesce((v_res->>'points_spent')::integer,-1) <> 50
           then format('FAIL - %s',v_res)
         else 'PASS' end);
  if v_err is null then
    perform public.reverse_loyalty_redemption(p_biz,(v_res->>'redemption_id')::uuid,
      'v846 acceptance: restore the live pot before the expiry assertions','v846-acc-rev-02');
  end if;

  -- ---------------------------------------------------------------------------- 06  the GUARD
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_cust,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_intent := public.customer_create_redemption_intent_v89(p_biz,p_gift50,gen_random_uuid(),'catalog_reward');
  execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_owner,'role','authenticated')::text,true);
  insert into public.firm_config_versions(business_id,version_no,status,snapshot_hash)
  values (p_biz,9846,'draft',md5('v846-acceptance')) returning id into p_cfg_draft;
  update public.businesses set active_config_version_id=p_cfg_draft where id=p_biz;
  v_err := null;
  begin
    perform public.merchant_scan_redemption_qr_v117(p_biz,p_branch,v_intent->>'qr_token',gen_random_uuid());
  exception when others then v_err := sqlstate;
  end;
  update public.businesses set active_config_version_id=p_cfg where id=p_biz;
  insert into v846_out values (6,'GUARD: a NON-stamps quote whose configuration version is no '
    'longer the active one is still refused with 23514 - the scanner splice widened the accepted '
    'set only for stamps',
    case when v_err = '23514' then 'PASS'
         else format('FAIL - expected 23514, got %s',coalesce(v_err,'ACCEPTED')) end);

  -- ------------------------------------------------------------------------- 07/08  (C) expiry
  update public.points_batches set expires_at=now()-interval '1 hour' where id=p_batch_live;
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_cust,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_err := null;
  begin
    perform public.customer_create_redemption_intent_v89(p_biz,p_gift50,gen_random_uuid(),'catalog_reward');
  exception when others then v_err := sqlstate;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_owner,'role','authenticated')::text,true);
  insert into v846_out values (7,'(C) a points batch that expired an hour ago is no longer '
    'mintable (nestly_v847 carries the same predicate into app.reward_availability_v432 and '
    'app.redeem_reward_core)',
    case when v_err = '23514' then 'PASS'
         else format('FAIL - expected 23514, got %s',coalesce(v_err,'MINTED')) end);
  update public.points_batches set expires_at=now()+interval '1 hour' where id=p_batch_live;
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_cust,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_err := null;
  begin
    perform public.customer_create_redemption_intent_v89(p_biz,p_gift50,gen_random_uuid(),'catalog_reward');
  exception when others then v_err := sqlstate; v_msg := sqlerrm;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_owner,'role','authenticated')::text,true);
  insert into v846_out values (8,'(C) sensitivity: the SAME batch with an hour of life left still '
    'mints - the filter excludes expired points, it does not refuse everything',
    case when v_err is null then 'PASS'
         else format('FAIL - live points refused: %s %s',v_err,v_msg) end);

  -- ==========================================================================================
  -- TENANT TWO — a stamps firm: five-stamp card, gifts at stamps 2, 3 and 5, three customers
  -- four stamps in and pinned to configuration version 1.
  -- ==========================================================================================
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',s_owner,'authenticated','authenticated',
          'zz-v846-so-'||substr(s_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',s_cust1,'authenticated','authenticated',
          'zz-v846-s1-'||substr(s_cust1::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',s_cust2,'authenticated','authenticated',
          'zz-v846-s2-'||substr(s_cust2::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',s_cust3,'authenticated','authenticated',
          'zz-v846-s3-'||substr(s_cust3::text,1,8)||'@example.test','',now(),now(),now());
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,enabled_modules,points_mode)
  values (s_biz,'V846 Stamp Kopi','zz-v846s-'||substr(s_biz::text,1,8),array['loyalty'],'redeem');
  perform set_config('app.v79_system_transition','',true);
  insert into public.business_programmes(id,business_id,kind,active,sort)
  values (s_spine,s_biz,'stamps',true,3)
  on conflict (business_id,kind) do update set active=true
  returning id into s_spine;
  update public.business_programmes set active=true where business_id=s_biz and kind='points';
  insert into public.staff(business_id,user_id,role,active,access_state)
  values (s_biz,s_owner,'owner',true,'approved') returning id into s_staff;
  insert into public.branches(id,business_id,name,is_default,active)
  values (s_branch,s_biz,'V846 stamps main',true,true);
  insert into public.staff_branches(business_id,staff_id,branch_id) values (s_biz,s_staff,s_branch);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_by=s_owner,
         decided_at=clock_timestamp(),decision_reason='v846 acceptance fixture',
         updated_at=clock_timestamp()
   where business_id=s_biz;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (s_biz,false) on conflict (business_id) do update set workspace_paused=false;
  insert into public.subscriptions(business_id) values (s_biz) on conflict do nothing;
  insert into public.business_customer_capabilities_v89(business_id,redemption_enabled)
  values (s_biz,true) on conflict (business_id) do update set redemption_enabled=true;
  perform set_config('request.jwt.claims',
    json_build_object('sub',s_owner,'role','authenticated')::text,true);
  insert into public.loyalty_programs(business_id,active,loyalty_model,kind,configuration_status,
                                      stamp_target,stamp_per_cents)
  values (s_biz,true,'stamps','stamps','published',5,500)
  on conflict (business_id) do update
    set active=true,loyalty_model='stamps',kind='stamps',configuration_status='published',
        stamp_target=5,stamp_per_cents=500;
  select id into s_cfg from public.firm_config_versions
   where business_id=s_biz and status='published' order by version_no desc limit 1;
  if s_cfg is null then
    raise exception 'FIXTURE BROKEN: the stamps tenant published no configuration version';
  end if;
  update public.businesses set active_config_version_id=s_cfg where id=s_biz;
  update public.firm_config_versions set published_at=now()-interval '2 days' where id=s_cfg;
  insert into public.clients(id,business_id,full_name,phone)
  values (s_cl1,s_biz,'V846 Mid Card One','+65 9832 1001'),
         (s_cl2,s_biz,'V846 Mid Card Two','+65 9832 1002'),
         (s_cl3,s_biz,'V846 Mid Card Three','+65 9832 1003');
  insert into public.customer_identities(id,auth_user_id,status)
  values (s_id1,s_cust1,'active'),(s_id2,s_cust2,'active'),(s_id3,s_cust3,'active');
  perform set_config('app.customer_link_insert_id',s_lk1::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                    verification_method,verified_at)
  values (s_lk1,s_biz,s_id1,s_cust1,s_cl1,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id',s_lk2::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                    verification_method,verified_at)
  values (s_lk2,s_biz,s_id2,s_cust2,s_cl2,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id',s_lk3::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                    verification_method,verified_at)
  values (s_lk3,s_biz,s_id3,s_cust3,s_cl3,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id','',true);
  insert into public.loyalty_rewards(id,business_id,name,internal_name,customer_name,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,paused,sort,programme_id)
  values (s_two ,s_biz,'V846 Kaya','V846 Kaya','V846 Kaya','manual_item',2,0,0,true,false,1,s_spine),
         (s_free,s_biz,'V846 Kopi','V846 Kopi','V846 Kopi','manual_item',3,0,0,true,false,2,s_spine),
         (s_big ,s_biz,'V846 Final','V846 Final','V846 Final','manual_item',5,0,0,true,false,3,s_spine);
  /* `paused` is deliberately not listed on the version rows: the nestly_v814 BEFORE INSERT default
     must inherit it from the live row. If that trigger were missing these would arrive NULL and
     the NOT NULL would fail here, in the fixture, rather than silently later. */
  insert into public.loyalty_reward_versions(reward_id,business_id,config_version_id,internal_name,
    customer_name,description,fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,sort,
    programme_id)
  values (s_two ,s_biz,s_cfg,'V846 Kaya','V846 Kaya','stamp 2','manual_item',2,0,0,1,s_spine),
         (s_free,s_biz,s_cfg,'V846 Kopi','V846 Kopi','stamp 3','manual_item',3,0,0,2,s_spine),
         (s_big ,s_biz,s_cfg,'V846 Final','V846 Final','stamp 5','manual_item',5,0,0,3,s_spine);
  /* The EXCLUSIVE fence rather than the shared one every till write takes: this is a single
     transaction and app.acquire_loyalty_exclusive_v480, which publish_loyalty_config takes when
     the pause publishes, refuses to upgrade a fence already held shared. */
  perform app.acquire_loyalty_exclusive_v480(s_biz);
  perform set_config('app.points_ledger_write_scope','adjust_points',true);
  perform set_config('app.points_ledger_insert_id',s_sd1::text,true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,
                                   programme_id,created_at)
  values (s_sd1,s_biz,s_cl1,'adjust',4,'v846 seed stamps 1',s_owner,s_spine,now()-interval '1 day');
  perform set_config('app.points_ledger_insert_id',s_sd2::text,true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,
                                   programme_id,created_at)
  values (s_sd2,s_biz,s_cl2,'adjust',4,'v846 seed stamps 2',s_owner,s_spine,now()-interval '1 day');
  perform set_config('app.points_ledger_insert_id',s_sd3::text,true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,
                                   programme_id,created_at)
  values (s_sd3,s_biz,s_cl3,'adjust',4,'v846 seed stamps 3',s_owner,s_spine,now()-interval '1 day');
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
  insert into public.points_batches(business_id,client_id,programme_id,earned,remaining)
  values (s_biz,s_cl1,s_spine,4,4),(s_biz,s_cl2,s_spine,4,4),(s_biz,s_cl3,s_spine,4,4);
  if app.stamp_cycle_version_v416(s_biz,s_cl1,s_spine) is distinct from s_cfg then
    raise exception 'FIXTURE BROKEN: the stamps customers are not pinned to version 1';
  end if;

  -- The pause the whole (A) scenario turns on: nestly_v814 versions forward and leaves
  -- loyalty_rewards.active = true, which the old selector mistook for "quote the new version".
  v_res := public.business_set_reward_paused_v326(s_biz,s_free,true);
  select active_config_version_id into s_cfg2 from public.businesses where id=s_biz;
  if coalesce(v_res->>'mode','') is distinct from 'version_forward' or s_cfg2 is null or s_cfg2 = s_cfg
     or (select r.active from public.loyalty_rewards r where r.id=s_free) is distinct from true then
    raise exception 'FIXTURE BROKEN: the pause did not version forward with active still true: %',
      v_res;
  end if;
  update public.firm_config_versions set published_at=now()-interval '1 hour' where id=s_cfg2;
  if app.stamp_cycle_version_v416(s_biz,s_cl1,s_spine) is distinct from s_cfg then
    raise exception 'FIXTURE BROKEN: the publish moved the mid-card customers off version 1';
  end if;

  -- ---------------------------------------------------------------- 09  the positive control
  select ra.availability into v_txt
    from app.reward_availability_v432(s_biz,s_cl1) ra where ra.reward_id=s_free;
  insert into v846_out values (9,'FIXTURE: app.reward_availability_v432 still offers the '
    'paused-forward gift to the pinned customer (without this every later assertion is vacuous)',
    case when coalesce(v_txt,'ABSENT') = 'available_at_counter' then 'PASS'
         else format('FAIL - %s',coalesce(v_txt,'ABSENT')) end);

  -- ------------------------------------------------------------------------ 10  (A) the mint
  perform set_config('request.jwt.claims',
    json_build_object('sub',s_cust1,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_err := null; v_intent := null;
  begin
    v_intent := public.customer_create_redemption_intent_v89(s_biz,s_free,gen_random_uuid(),'catalog_reward');
  exception when others then v_err := sqlstate; v_msg := sqlerrm;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub',s_owner,'role','authenticated')::text,true);
  v_iid := (v_intent->>'intent_id')::uuid;
  insert into v846_out values (10,'(A) the minter mints the paused-forward stamp gift, quoting '
    'the version the customer''s OPEN CARD is pinned to, at the pinned 3 stamps',
    case when v_err is not null then format('FAIL - still refused: %s %s',v_err,v_msg)
         when (select i.quoted_config_version_id from public.customer_redemption_intents_v89 i
                where i.id=v_iid) is distinct from s_cfg
           then 'FAIL - quoted a version other than the pin'
         when (select i.quoted_points_spent from public.customer_redemption_intents_v89 i
                where i.id=v_iid) is distinct from 3
           then format('FAIL - quoted %s stamps, expected the pinned 3',
                (select i.quoted_points_spent from public.customer_redemption_intents_v89 i where i.id=v_iid))
         else 'PASS' end);

  -- ------------------------------------------------------------------------ 11  (D) the scan
  v_err := null;
  begin
    v_res := public.merchant_scan_redemption_qr_v117(s_biz,s_branch,v_intent->>'qr_token',gen_random_uuid());
  exception when others then v_err := sqlstate; v_msg := sqlerrm;
  end;
  insert into v846_out values (11,'(D) the counter ACCEPTS that pinned quote, prints 3 and the '
    'engine charges slot 3 - the promise and the payout are the same number',
    case when v_err is not null then format('FAIL - the till refused the pinned quote: %s %s',v_err,v_msg)
         when coalesce(v_res->>'status','') <> 'completed' then format('FAIL - %s',v_res)
         when coalesce((v_res->>'points_spent')::integer,-1) <> 3
           or coalesce((v_res->'result'->>'stamp_slot')::integer,-1) <> 3
           then format('FAIL - printed %s, charged %s',v_res->>'points_spent',
                v_res->'result'->>'stamp_slot')
         else 'PASS' end);

  -- ------------------------------------------------------------------- 12  (D) what was written
  insert into v846_out values (12,'(D) the ledger recorded the claim at slot 3 against the PINNED '
    'configuration version, not the paused one',
    case when exists (select 1 from public.stamp_milestone_claims c
                       where c.business_id=s_biz and c.client_id=s_cl1 and c.reward_id=s_free
                         and c.slot_position=3 and c.config_version_id=s_cfg)
         then 'PASS' else 'FAIL - no claim at slot 3 on the pinned version' end);

  -- ------------------------------------------------------------------- 13/14  (D) the price case
  v_res := public.business_update_reward_v326(s_biz,s_two,'V846 Kaya'::text,1,null::text,0,
             null::text,false,null::timestamptz,false,null::text,null::integer,false,null::integer);
  perform set_config('request.jwt.claims',
    json_build_object('sub',s_cust1,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_err := null; v_intent := null;
  begin
    v_intent := public.customer_create_redemption_intent_v89(s_biz,s_two,gen_random_uuid(),'catalog_reward');
  exception when others then v_err := sqlstate; v_msg := sqlerrm;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub',s_owner,'role','authenticated')::text,true);
  v_iid := (v_intent->>'intent_id')::uuid;
  insert into v846_out values (13,'(D) the stamp-2 gift is edited forward to stamp 1; the mid-card '
    'customer is still quoted the pinned 2',
    case when v_err is not null then format('FAIL - refused: %s %s',v_err,v_msg)
         when (select i.quoted_points_spent from public.customer_redemption_intents_v89 i
                where i.id=v_iid) is distinct from 2
           then format('FAIL - quoted %s, expected 2',
                (select i.quoted_points_spent from public.customer_redemption_intents_v89 i where i.id=v_iid))
         else 'PASS' end);
  v_err := null;
  begin
    v_res := public.merchant_scan_redemption_qr_v117(s_biz,s_branch,v_intent->>'qr_token',gen_random_uuid());
  exception when others then v_err := sqlstate; v_msg := sqlerrm;
  end;
  insert into v846_out values (14,'(D) and the till prints 2 while the ledger takes 2 - before '
    'v846 this pair read "quoted 2, charged 3"',
    case when v_err is not null then format('FAIL - the till refused it: %s %s',v_err,v_msg)
         when coalesce((v_res->>'points_spent')::integer,-1) <> 2
           or coalesce((v_res->'result'->>'stamp_slot')::integer,-1) <> 2
           or not exists (select 1 from public.stamp_milestone_claims c
                           where c.business_id=s_biz and c.client_id=s_cl1 and c.reward_id=s_two
                             and c.slot_position=2)
           then format('FAIL - %s',v_res)
         else 'PASS' end);

  -- ==========================================================================================
  -- MUTATION CHECKS. Each splice is reverted ON ITS OWN and the assertions it is supposed to
  -- carry are shown to break again. An assertion that survives its own mutation measures nothing.
  -- ==========================================================================================

  -- ------------------------------------------- 15  revert ONLY the minter's version selector
  v_def := pg_get_functiondef('public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure);
  v_new := replace(v_def, m_inject_version, m_anchor_version);
  if v_new = v_def then
    raise exception 'MUTATION SETUP BROKEN: the minter does not carry the v846 version splice';
  end if;
  execute v_new;
  perform set_config('request.jwt.claims',
    json_build_object('sub',s_cust2,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_err := null;
  begin
    perform public.customer_create_redemption_intent_v89(s_biz,s_free,gen_random_uuid(),'catalog_reward');
  exception when others then v_err := sqlstate;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub',s_owner,'role','authenticated')::text,true);
  execute v_def;  -- restore
  insert into v846_out values (15,'MUTATION: revert ONLY the minter version splice and assertion '
    '10 breaks again - a second mid-card customer is refused 22023 on the paused-forward gift',
    case when v_err = '22023' then 'PASS'
         else format('FAIL - the assertion survives its own mutation (got %s), so it proves nothing',
              coalesce(v_err,'MINTED')) end);

  -- --------------------------------------------------- 16  revert ONLY the scanner's splice
  perform set_config('request.jwt.claims',
    json_build_object('sub',s_cust3,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_intent := public.customer_create_redemption_intent_v89(s_biz,s_free,gen_random_uuid(),'catalog_reward');
  execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub',s_owner,'role','authenticated')::text,true);
  v_def := pg_get_functiondef('public.merchant_scan_redemption_qr_v117(uuid,uuid,text,uuid)'::regprocedure);
  v_new := replace(v_def, s_inject_version, s_anchor_version);
  if v_new = v_def then
    raise exception 'MUTATION SETUP BROKEN: the scanner does not carry the v846 splice';
  end if;
  execute v_new;
  v_err := null;
  begin
    perform public.merchant_scan_redemption_qr_v117(s_biz,s_branch,v_intent->>'qr_token',gen_random_uuid());
  exception when others then v_err := sqlstate;
  end;
  execute v_def;  -- restore
  insert into v846_out values (16,'MUTATION: revert ONLY the scanner splice and assertion 11 '
    'breaks again - the correctly pinned QR is refused 23514 at the counter',
    case when v_err = '23514' then 'PASS'
         else format('FAIL - the assertion survives its own mutation (got %s), so it proves nothing',
              coalesce(v_err,'SCANNED')) end);

  -- ------------------------------------------ 17/18  revert ONLY the minter's balance splice
  v_def := pg_get_functiondef('public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure);
  v_new := replace(v_def, m_inject_balance, m_anchor_balance);
  if v_new = v_def then
    raise exception 'MUTATION SETUP BROKEN: the minter does not carry the v846 balance splice';
  end if;
  execute v_new;
  insert into public.programme_pot_migrations(id,business_id,from_programme_id,to_programme_id,status)
  values (gen_random_uuid(),p_biz,p_retired,p_live,'pending');
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_cust,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_err := null;
  begin
    perform public.customer_create_redemption_intent_v89(p_biz,p_gift90,gen_random_uuid(),'catalog_reward');
  exception when others then v_err := sqlstate;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_owner,'role','authenticated')::text,true);
  insert into v846_out values (17,'MUTATION: revert ONLY the minter balance splice and assertion 1 '
    'breaks again - under business_pot the cross-pot gift is refused 23514',
    case when v_err = '23514' then 'PASS'
         else format('FAIL - the assertion survives its own mutation (got %s), so it proves nothing',
              coalesce(v_err,'MINTED')) end);
  delete from public.programme_pot_migrations where business_id = p_biz;
  update public.points_batches set expires_at=now()-interval '1 hour' where id=p_batch_live;
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_cust,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_err := null;
  begin
    perform public.customer_create_redemption_intent_v89(p_biz,p_gift50,gen_random_uuid(),'catalog_reward');
  exception when others then v_err := sqlstate;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_owner,'role','authenticated')::text,true);
  execute v_def;  -- restore
  update public.points_batches set expires_at=now()+interval '90 days' where id=p_batch_live;
  insert into v846_out values (18,'MUTATION: the same reversion breaks assertion 7 - the batch '
    'that expired an hour ago becomes spendable again',
    case when v_err is null then 'PASS'
         else format('FAIL - the assertion survives its own mutation (got %s), so it proves nothing',
              v_err) end);
end
$v846_test$;

select seq, step, outcome from v846_out order by seq;

do $v846_gate$
declare v_failed integer;
begin
  select count(*) into v_failed from v846_out where outcome like 'FAIL%';
  if v_failed > 0 then
    raise exception 'nestly_v846 acceptance: % assertion(s) failed', v_failed using errcode = 'XX001';
  end if;
  if (select count(*) from v846_out) <> 18 then
    raise exception 'nestly_v846 acceptance: expected 18 assertions, recorded %',
      (select count(*) from v846_out) using errcode = 'XX001';
  end if;
end
$v846_gate$;

rollback;
