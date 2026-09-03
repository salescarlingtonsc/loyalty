-- EXECUTED acceptance for nestly_v425 — a referral reward has a TYPE.
--
--   node scripts/db-tests/run.mjs --filter=v425
--   (or:  psql -d <db> -v ON_ERROR_STOP=1 -f db/tests/executed/v425_referral_typed_payout.sql)
--
-- This file runs in BOTH phases of the executed harness and passes in both, because it asserts
-- the BEHAVIOUR ON EACH SIDE rather than only the behaviour it wants. It detects whether v425 is
-- installed and, for every check whose answer v425 deliberately changes, asserts the OLD answer
-- at baseline and the NEW answer after. A baseline run that reports "defect reproduced" is the
-- evidence that the migrated run's PASS is worth anything at all.
--
-- Two synthetic tenants, thrown away with the transaction. They exist because the two accruing
-- programmes are mutually exclusive and the defect only appears when they disagree:
--   ZZ V425 POINTS   points spine ON,  stamps OFF
--   ZZ V425 STAMPS   stamps spine ON,  points OFF, referral_programs.reward_kind = 'points'
--                    — production's Cubbly SPA exactly. app.referral_payout_programme_v322 is
--                    kind-blind, so this firm's "50 points" referral resolved to the STAMP pot
--                    and paid 50 stamps: a unit the customer never earned and the owner never
--                    offered. That is check 03.
--
-- Fixture notes (same gates every owner-write suite here has to satisfy):
--   * an owner write needs staff.access_state='approved' AND an approved
--     business_workspace_controls_v94 row AND an unpaused business_subscription_lifecycle_v94
--     row; a trigger seeds the latter two, hence the upserts.
--   * public.module_registry is seeded on demand: the committed schema snapshot carries the
--     table without its rows, and businesses.enabled_modules is validated against it.
--   * points_ledger is append-guarded, so nothing here writes points directly — every balance in
--     this file arrives through a real sale and the real triggers.
--   * nestly_v565 ("every business born the same") seeds AND PUBLISHES loyalty config version 1
--     at business creation, so businesses.loyalty_programs.current_config_version_id already
--     points at a PUBLISHED version by the time this fixture runs. Calling
--     publish_loyalty_config directly on that id therefore fails with 'only a draft may be
--     published'. Fixed by obtaining a real draft first through public.create_loyalty_config_draft
--     (the flow post-v565 fixtures use, e.g. v433_v436_stamp_lifecycle.sql phase F) and
--     publishing that instead — it clones the live row business_set_earning_rule_v359 just wrote,
--     so publishing it is a no-op re-affirmation of the same values, not a behaviour change.

begin;

create temp table _r(k text, v text) on commit drop;

-- Two REFERENCE tables the committed schema snapshot carries without their rows (it is a
-- schema-only dump). Both are validated against on every business insert / every sale, so a
-- suite that does not seed them cannot create a tenant or record a sale at all. `do nothing`
-- keeps this a no-op on a real database, where the rows already exist with these exact values.
insert into public.module_registry(module_key,label,requires_modules,sort_order) values
  ('dashboard','Dashboard','{}',10),('clients','Customers','{}',30),('sales','Sales','{}',50),
  ('services','Services','{}',60),
  ('loyalty','Loyalty','{clients,sales}',120),('referrals','Referrals','{clients,sales}',140)
on conflict (module_key) do nothing;

insert into public.product_adoption_event_taxonomy_v100
  (event_name,source_authority,actor_scope,business_scope_required,economic_event,description) values
  ('sale.recorded','server','system',true,true,'Canonical non-reversal sale was inserted.'),
  ('sale.reversed','server','system',true,true,'Canonical reversal sale was inserted.'),
  ('loyalty.redemption_completed','server','system',true,true,'Canonical loyalty redemption was inserted.')
on conflict (event_name) do nothing;

do $$
declare
  -- v425 installed? Every dual-mode check below branches on this and on nothing else.
  v425 boolean := exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='app' and p.proname='referral_payout_programme_v425');
  v_pbiz uuid; v_sbiz uuid; v_powner uuid; v_sowner uuid; v_pmgr uuid;
  v_pbr uuid; v_sbr uuid; v_ppot uuid; v_spot uuid;
  v_referrer uuid; v_friend uuid; v_ref uuid; v_row public.referrals%rowtype;
  v_n integer; v_before integer; v_grants_before integer;
  v_pot uuid; v_pts integer; v_msg text; v_state text; v_res jsonb; v_blocked text;
  v_cfg uuid; v_tax uuid; v_prog uuid;
  v_slug text := substr(md5(random()::text),1,8);
begin
  -- ==========================================================================================
  -- FIXTURE
  -- ==========================================================================================
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
          'zz-v425-p-'||v_slug||'@example.test','x',now(),now(),now()) returning id into v_powner;
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
          'zz-v425-s-'||v_slug||'@example.test','x',now(),now(),now()) returning id into v_sowner;
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
          'zz-v425-m-'||v_slug||'@example.test','x',now(),now(),now()) returning id into v_pmgr;

  insert into public.businesses(name,slug,enabled_modules)
  values ('ZZ V425 POINTS','zz-v425-p-'||v_slug,'{dashboard,clients,sales,services,loyalty,referrals}')
  returning id into v_pbiz;
  insert into public.businesses(name,slug,enabled_modules)
  values ('ZZ V425 STAMPS','zz-v425-s-'||v_slug,'{dashboard,clients,sales,services,loyalty,referrals}')
  returning id into v_sbiz;

  insert into public.branches(business_id,name) values (v_pbiz,'Main P') returning id into v_pbr;
  insert into public.branches(business_id,name) values (v_sbiz,'Main S') returning id into v_sbr;

  insert into public.staff(business_id,user_id,role,active,access_state,full_name)
  values (v_pbiz,v_powner,'owner',true,'approved','ZZ P Owner'),
         (v_sbiz,v_sowner,'owner',true,'approved','ZZ S Owner'),
         (v_pbiz,v_pmgr,'manager',true,'approved','ZZ P Manager');

  insert into public.business_workspace_controls_v94(business_id,approval_status,decided_by,decided_at,decision_reason)
  values (v_pbiz,'approved',v_powner,now(),'v425 fixture'),(v_sbiz,'approved',v_sowner,now(),'v425 fixture')
  on conflict (business_id) do update set approval_status='approved',
    decided_by=excluded.decided_by, decided_at=excluded.decided_at, decision_reason=excluded.decision_reason;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (v_pbiz,false),(v_sbiz,false)
  on conflict (business_id) do update set workspace_paused=false;
  /* v620 (nestly_v620_entitlement_authority): business_operational_v620 additionally requires a
     paid (or trialing) subscriptions row, not merely an approved+unpaused workspace. Without this
     both fixtures fail with "owner loyalty configuration access required" under the migrated
     schema — see the same note in v422_baseline_behaviours.sql. */
  insert into public.subscriptions(business_id, status, payment_status, current_period_end)
  values (v_pbiz,'active','paid',now() + interval '30 days'),
         (v_sbiz,'active','paid',now() + interval '30 days')
  on conflict (business_id) do update
    set status = 'active', payment_status = 'paid',
        current_period_end = now() + interval '30 days';

  -- Points firm: a published, running points programme, exactly as a live tenant has one.
  perform set_config('request.jwt.claims', json_build_object('sub',v_powner,'role','authenticated')::text, true);
  perform public.business_set_earning_rule_v359(v_pbiz, 1.0, null, 'none', null);
  perform public.publish_loyalty_config(((public.create_loyalty_config_draft(v_pbiz, null, 'v425 acceptance'))::jsonb ->> 'version_id')::uuid);
  perform public.set_programmes_v314(v_pbiz,'{"points":true}'::jsonb,gen_random_uuid());
  update public.loyalty_programs set active=true where business_id=v_pbiz;

  -- Stamps firm: the stamp card running instead. set_programmes_v314 carries the V354 sync, so
  -- loyalty_programs.loyalty_model follows the spine without being written by hand.
  perform set_config('request.jwt.claims', json_build_object('sub',v_sowner,'role','authenticated')::text, true);
  perform public.business_set_earning_rule_v359(v_sbiz, 1.0, null, 'none', null);
  perform public.publish_loyalty_config(((public.create_loyalty_config_draft(v_sbiz, null, 'v425 acceptance'))::jsonb ->> 'version_id')::uuid);
  perform public.set_programmes_v314(v_sbiz,'{"stamps":true}'::jsonb,gen_random_uuid());
  update public.loyalty_programs set active=true, stamp_per_cents=1000 where business_id=v_sbiz;

  select id into v_ppot from public.business_programmes where business_id=v_pbiz and kind='points';
  select id into v_spot from public.business_programmes where business_id=v_sbiz and kind='stamps';
  insert into _r values('00_fixture',
    case when v_ppot is not null and v_spot is not null
      and (select active from public.business_programmes where id=v_ppot)
      and (select active from public.business_programmes where id=v_spot)
      then 'PASS points firm runs points, stamps firm runs stamps'||(case when v425 then ' [v425 INSTALLED]' else ' [BASELINE]' end)
      else 'FAIL the fixture did not reach a live state' end);

  -- ==========================================================================================
  -- 01-02  THE POINTS FIRM IS UNAFFECTED — the regression guard
  -- ==========================================================================================
  perform set_config('request.jwt.claims', json_build_object('sub',v_powner,'role','authenticated')::text, true);
  perform public.save_referral_program_v421(v_pbiz, true, 'points', 400, null, 0, true, null, null);
  insert into public.clients(business_id,full_name,phone) values (v_pbiz,'ZZ P Referrer','81990101') returning id into v_referrer;
  insert into public.clients(business_id,full_name,phone) values (v_pbiz,'ZZ P Friend','81990102') returning id into v_friend;
  insert into public.referrals(business_id,referrer_client_id,referred_client_id,status)
  values (v_pbiz,v_referrer,v_friend,'pending') returning id into v_ref;
  insert into public.sales(business_id,client_id,kind,amount_cents,branch_id) values (v_pbiz,v_friend,'service',10000,v_pbr);

  insert into _r select '01_points_firm_pays_points_into_the_points_pot',
    case when count(*)=2 and bool_and(programme_id=v_ppot) and bool_and(points=400)
      then 'PASS both sides paid 400 into the points pot (identical before and after v425)'
      else 'FAIL '||count(*)||' rows' end
  from public.points_ledger where business_id=v_pbiz and sale_id is null and reference like 'referral qualified%';
  insert into _r select '02_points_firm_payout_is_exactly_once',
    case when count(*)=2 then 'PASS one payout per side' else 'FAIL '||count(*) end
  from public.points_ledger where business_id=v_pbiz and sale_id is null and reference like 'referral qualified%';

  -- ==========================================================================================
  -- 03-05  THE DEFECT: a points reward at a stamps-only firm
  -- ==========================================================================================
  -- Written with a direct UPDATE because after v425 the saver REFUSES to create this state, and
  -- reproducing the state four live firms are already in is the whole point of the check.
  perform set_config('request.jwt.claims', json_build_object('sub',v_sowner,'role','authenticated')::text, true);
  update public.referral_programs set enabled=true, reward_kind='points', reward_points=50, min_spend_cents=0
   where business_id=v_sbiz;
  if not found then
    insert into public.referral_programs(business_id,enabled,reward_kind,reward_points,min_spend_cents)
    values (v_sbiz,true,'points',50,0);
  end if;

  insert into public.clients(business_id,full_name,phone) values (v_sbiz,'ZZ S Referrer','81990201') returning id into v_referrer;
  insert into public.clients(business_id,full_name,phone) values (v_sbiz,'ZZ S Friend','81990202') returning id into v_friend;
  insert into public.referrals(business_id,referrer_client_id,referred_client_id,status)
  values (v_sbiz,v_referrer,v_friend,'pending') returning id into v_ref;
  select count(*) into v_before from public.points_ledger where business_id=v_sbiz and sale_id is null;
  insert into public.sales(business_id,client_id,kind,amount_cents,branch_id) values (v_sbiz,v_friend,'service',10000,v_sbr);

  select count(*), min(programme_id::text)::uuid, max(points) into v_n, v_pot, v_pts
    from public.points_ledger where business_id=v_sbiz and sale_id is null and reference like 'referral qualified%';
  select * into v_row from public.referrals where id=v_ref;
  v_blocked := to_jsonb(v_row)->>'blocked_reason';

  if v425 then
    insert into _r values('03_points_reward_is_never_paid_as_stamps',
      case when v_n=0 then 'PASS THE FIX: nothing was paid, because the pot the owner named is off'
           else 'FAIL '||v_n||' rows paid into pot '||coalesce(v_pot::text,'?') end);
    insert into _r values('04_the_referral_stays_claimable_and_says_why',
      case when v_row.status='pending' and v_row.qualified_sale_id is null
                and v_blocked='reward_kind_points_requires_active_points_programme'
        then 'PASS pending, unspent, and the Referrals page can show the reason'
        else 'FAIL status='||v_row.status||' reason='||coalesce(v_blocked,'<null>') end);
    insert into _r select '05_no_ledger_row_in_any_unit',
      case when count(*)=v_before then 'PASS' else 'FAIL '||(count(*)-v_before)||' new referral rows' end
    from public.points_ledger where business_id=v_sbiz and sale_id is null;
  else
    insert into _r values('03_points_reward_is_never_paid_as_stamps',
      case when v_n=2 and v_pot=v_spot and v_pts=50
        then 'PASS (DEFECT REPRODUCED at baseline) 50 POINTS were paid as 50 STAMPS'
        else 'FAIL baseline did not reproduce: '||v_n||' rows, pot='||coalesce(v_pot::text,'?') end);
    insert into _r values('04_the_referral_stays_claimable_and_says_why',
      case when v_row.status='rewarded' and v_blocked is null
        then 'PASS (DEFECT REPRODUCED at baseline) marked rewarded, and nothing recorded why'
        else 'FAIL baseline status='||v_row.status end);
    insert into _r select '05_no_ledger_row_in_any_unit',
      case when count(*)>v_before then 'PASS (DEFECT REPRODUCED at baseline) '||(count(*)-v_before)||' rows written'
           else 'FAIL baseline wrote nothing' end
    from public.points_ledger where business_id=v_sbiz and sale_id is null;
  end if;

  -- ==========================================================================================
  -- 06-07  TYPED STAMPS is a thing the owner can actually choose
  -- ==========================================================================================
  perform set_config('request.jwt.claims', json_build_object('sub',v_sowner,'role','authenticated')::text, true);
  begin
    perform public.save_referral_program_v421(v_sbiz, true, 'stamps', 7, null, 0, true, null, null);
    if v425 then
      insert into _r select '06_stamps_is_an_accepted_reward_type',
        case when reward_kind='stamps' and reward_points=7
          then 'PASS saved as stamps, and the amount survived the kind change'
          else 'FAIL '||reward_kind||'/'||reward_points end
      from public.referral_programs where business_id=v_sbiz;
    else
      insert into _r values('06_stamps_is_an_accepted_reward_type','FAIL baseline accepted a kind it does not implement');
    end if;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    insert into _r values('06_stamps_is_an_accepted_reward_type',
      case when not v425 and v_state='22023'
        then 'PASS (BASELINE) stamps was not a reward type yet: '||v_msg
        else 'FAIL '||v_state||' '||v_msg end);
  end;

  if v425 then
    insert into public.clients(business_id,full_name,phone) values (v_sbiz,'ZZ S Referrer 2','81990203') returning id into v_referrer;
    insert into public.clients(business_id,full_name,phone) values (v_sbiz,'ZZ S Friend 2','81990204') returning id into v_friend;
    insert into public.referrals(business_id,referrer_client_id,referred_client_id,status)
    values (v_sbiz,v_referrer,v_friend,'pending') returning id into v_ref;
    insert into public.sales(business_id,client_id,kind,amount_cents,branch_id) values (v_sbiz,v_friend,'service',10000,v_sbr);
    insert into _r select '07_typed_stamps_pays_stamps_into_the_stamp_pot',
      case when count(*)=2 and bool_and(programme_id=v_spot) and bool_and(points=7)
                and count(*) filter (where exists(select 1 from public.points_batches b
                      where b.business_id=v_sbiz and b.sale_id is null and b.expires_at is null))=2
        then 'PASS 7 stamps to each side, in the stamp pot, on batches that do not expire'
        else 'FAIL '||count(*)||' rows' end
    from public.points_ledger where business_id=v_sbiz and sale_id is null
      and reference like 'referral qualified%' and client_id in (v_referrer,v_friend);
  else
    insert into _r values('07_typed_stamps_pays_stamps_into_the_stamp_pot',
      'PASS (BASELINE) not applicable — there was no stamps reward type to pay');
  end if;

  -- ==========================================================================================
  -- 08  A $0 SALE NEVER QUALIFIES A REFERRAL (owner decision D)
  -- ==========================================================================================
  -- A used package session, a completed no-charge appointment and a quick reversal all arrive as
  -- exactly this row, and eleven of production's twelve 'service' sales are one of them.
  perform set_config('request.jwt.claims', json_build_object('sub',v_powner,'role','authenticated')::text, true);
  insert into public.clients(business_id,full_name,phone) values (v_pbiz,'ZZ P Referrer 2','81990103') returning id into v_referrer;
  insert into public.clients(business_id,full_name,phone) values (v_pbiz,'ZZ P Friend 2','81990104') returning id into v_friend;
  insert into public.referrals(business_id,referrer_client_id,referred_client_id,status)
  values (v_pbiz,v_referrer,v_friend,'pending') returning id into v_ref;
  insert into public.sales(business_id,client_id,kind,amount_cents,branch_id,note)
  values (v_pbiz,v_friend,'service',0,v_pbr,'package session used: ZZ');
  select status into v_state from public.referrals where id=v_ref;
  insert into _r values('08_zero_dollar_sale_never_qualifies',
    case when v425 and v_state='pending' then 'PASS a $0 visit is not a qualifying spend'
         when not v425 and v_state='rewarded'
           then 'PASS (DEFECT REPRODUCED at baseline) a $0 visit bought a referral reward'
         else 'FAIL status='||v_state end);
  insert into public.sales(business_id,client_id,kind,amount_cents,branch_id) values (v_pbiz,v_friend,'service',2500,v_pbr);
  insert into _r select '09_a_paying_visit_still_qualifies',
    case when status='rewarded' then 'PASS' else 'FAIL status='||status end
  from public.referrals where id=v_ref;

  -- ==========================================================================================
  -- 10  VOUCHER IS UNTOUCHED
  -- ==========================================================================================
  perform public.save_referral_program_v421(v_pbiz, true, 'voucher', null, 'ZZ Free Coffee', 0, true, null, null);
  insert into public.clients(business_id,full_name,phone) values (v_pbiz,'ZZ P Referrer 3','81990105') returning id into v_referrer;
  insert into public.clients(business_id,full_name,phone) values (v_pbiz,'ZZ P Friend 3','81990106') returning id into v_friend;
  insert into public.referrals(business_id,referrer_client_id,referred_client_id,status)
  values (v_pbiz,v_referrer,v_friend,'pending') returning id into v_ref;
  insert into public.sales(business_id,client_id,kind,amount_cents,branch_id) values (v_pbiz,v_friend,'service',10000,v_pbr);
  insert into _r select '10_voucher_grants_both_sides_unchanged',
    case when count(*)=2 and count(*) filter (where beneficiary='referrer')=1
                          and count(*) filter (where beneficiary='friend')=1
      then 'PASS the v420/v421 gift path is identical before and after v425'
      else 'FAIL '||count(*)||' grants' end
  from public.referral_grants_v420 where referral_id=v_ref;

  -- ==========================================================================================
  -- 11  THE SAVER REFUSES AN UNPAYABLE PROMISE (owner decision B)
  -- ==========================================================================================
  perform set_config('request.jwt.claims', json_build_object('sub',v_sowner,'role','authenticated')::text, true);
  begin
    perform public.save_referral_program_v421(v_sbiz, true, 'points', 50, null, 0, true, null, null);
    insert into _r values('11_saver_refuses_a_type_the_firm_cannot_pay',
      case when v425 then 'FAIL an unpayable configuration was accepted'
           else 'PASS (BASELINE) nothing stopped a firm promising points it cannot pay' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    insert into _r values('11_saver_refuses_a_type_the_firm_cannot_pay',
      case when v425 and v_state='22023'
                and v_msg='referral reward type "points" needs the Point system switched on'
        then 'PASS refused, with copy the screen can show'
        else 'FAIL '||v_state||' '||v_msg end);
  end;

  -- ==========================================================================================
  -- 12  THE REFERRAL PROGRAMME IS OWNER-ONLY
  -- ==========================================================================================
  perform set_config('request.jwt.claims', json_build_object('sub',v_pmgr,'role','authenticated')::text, true);
  begin
    perform public.save_referral_program_v421(v_pbiz, true, 'voucher', null, 'ZZ Manager Gift', 0, true, null, null);
    insert into _r values('12_referral_config_is_owner_only',
      case when v425 then 'FAIL a manager saved the referral programme'
           else 'PASS (BASELINE) a manager could save it — the permission v425 narrows' end);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    insert into _r values('12_referral_config_is_owner_only',
      case when v425 and v_state='42501' then 'PASS '||v_msg else 'FAIL '||v_state||' '||v_msg end);
  end;

  -- ==========================================================================================
  -- 13-14  ONE SWITCH, ONE TRUTH (SA-4), AND THE WARNING THE SCREEN NEEDS
  -- ==========================================================================================
  perform set_config('request.jwt.claims', json_build_object('sub',v_powner,'role','authenticated')::text, true);
  perform public.save_referral_program_v421(v_pbiz, true, 'points', 400, null, 0, true, null, null);
  perform public.set_programmes_v314(v_pbiz,'{"referral":true}'::jsonb,gen_random_uuid());
  v_res := public.set_programmes_v314(v_pbiz,'{"referral":false}'::jsonb,gen_random_uuid());
  insert into _r select '13_referral_switch_moves_the_engine_too',
    case when v425 and not enabled
           then 'PASS referral_programs.enabled followed the spine in the same transaction'
         when not v425 and enabled
           then 'PASS (DEFECT REPRODUCED at baseline) the spine moved and the engine did not'
         else 'FAIL enabled='||enabled end
  from public.referral_programs where business_id=v_pbiz;

  perform public.set_programmes_v314(v_pbiz,'{"referral":true}'::jsonb,gen_random_uuid());
  perform public.save_referral_program_v421(v_pbiz, true, 'points', 400, null, 0, true, null, null);
  v_res := public.set_programmes_v314(v_pbiz,'{"points":false}'::jsonb,gen_random_uuid());
  insert into _r values('14_switch_reports_a_now_unpayable_referral',
    case when v425 and (v_res->>'referral_reward_kind_now_unpayable')::boolean
           then 'PASS turning Points off is allowed AND reported, so the owner can be warned'
         when not v425 and v_res->>'referral_reward_kind_now_unpayable' is null
           then 'PASS (BASELINE) the switch said nothing about the referral it had just broken'
         else 'FAIL flag='||coalesce(v_res->>'referral_reward_kind_now_unpayable','absent') end);

  -- ==========================================================================================
  -- 15  THE LEGACY RETENTION LOOP IS OUT OF THE SALE TRIGGER
  -- ==========================================================================================
  -- A 2-visit / 30-day retention program on the tenant's live config version. Before v425 the
  -- second qualifying visit produced a reward_grants row from inside app.on_sale_recorded; after
  -- it, bringback_campaigns_v361 is the only bring-back engine. The tables and every existing row
  -- are untouched either way.
  -- A published retention version can only be BORN in a draft (trg_guard_retention_program_
  -- version), which is exactly how the one surviving production version came to exist. So the
  -- fixture supersedes the tenant's published config, opens a draft, attaches the programme
  -- there, and publishes it — the same sequence the app performs.
  update public.firm_config_versions set status='superseded', superseded_at=now()
   where business_id=v_pbiz and status='published';
  insert into public.firm_config_versions(business_id,version_no,status,snapshot_hash,created_by)
  values (v_pbiz,(select coalesce(max(version_no),0)+1 from public.firm_config_versions where business_id=v_pbiz),
          'draft',md5('v425 retention fixture'),v_powner)
  returning id into v_cfg;
  select id into v_tax from public.firm_reward_taxonomy
   where business_id=v_pbiz and fulfillment_kind='discount_pct' and active limit 1;
  if v_tax is null then
    insert into public.firm_reward_taxonomy(business_id,label,fulfillment_kind,active,sort)
    values (v_pbiz,'ZZ V425 Discount','discount_pct',true,1) returning id into v_tax;
  end if;
  insert into public.retention_programs(business_id,name,goal_visits,period_days,reward_type,reward_value,reward_taxonomy_id,current_config_version_id)
  values (v_pbiz,'ZZ V425 2-visit',2,30,'discount_pct',10,v_tax,v_cfg) returning id into v_prog;
  insert into public.retention_program_versions(program_id,config_version_id,business_id,name,active,goal_visits,period_days,starts_on,reward_taxonomy_id,fulfillment_kind,discount_percent)
  values (v_prog,v_cfg,v_pbiz,'ZZ V425 2-visit',true,2,30,(current_date - 1),v_tax,'discount_pct',10);
  update public.firm_config_versions set status='published', published_at=now() where id=v_cfg;
  update public.businesses set active_config_version_id=v_cfg where id=v_pbiz;

  insert into public.clients(business_id,full_name,phone) values (v_pbiz,'ZZ P Regular','81990107') returning id into v_friend;
  select count(*) into v_grants_before from public.reward_grants where business_id=v_pbiz;
  insert into public.sales(business_id,client_id,kind,amount_cents,branch_id) values (v_pbiz,v_friend,'service',5000,v_pbr);
  insert into public.sales(business_id,client_id,kind,amount_cents,branch_id) values (v_pbiz,v_friend,'service',5000,v_pbr);
  select count(*) into v_n from public.reward_grants where business_id=v_pbiz;
  insert into _r values('15_sale_trigger_no_longer_grants_retention_rewards',
    case when v425 and v_n=v_grants_before
           then 'PASS the visit-goal loop is out of the trigger; v361 owns bring-back'
         when not v425 and v_n>v_grants_before
           then 'PASS (BASELINE) the loop granted '||(v_n-v_grants_before)||' reward(s) from the sale trigger'
         else 'FAIL grants went '||v_grants_before||' -> '||v_n end);
end $$;

select k as check_name, v as result from _r order by k;

do $$
declare v_fail integer;
begin
  select count(*) into v_fail from _r where v like 'FAIL%';
  if v_fail > 0 then raise exception 'v425: % FAILING CHECK(S) — see the table above', v_fail; end if;
  raise notice 'v425: all checks passed';
end $$;

rollback;
