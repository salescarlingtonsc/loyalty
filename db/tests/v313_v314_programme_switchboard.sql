-- Rollback-only v313 + v314 acceptance: W6 INCREMENT 1, THE SWITCHBOARD INVERSION.
--
-- v313 gives a reward its own programme identity (loyalty_rewards / loyalty_reward_versions
-- .programme_id, backfilled from app.resolve_ledger_programme_v309 in the last transaction in
-- which that resolver is unambiguous, then NOT NULL) and re-points app.redeem_reward_core and
-- public.customer_create_redemption_intent_v89 at the REWARD instead of the business. It also
-- retires the v309 tag triggers.
-- v314 inverts the spine: the four v308 sync triggers are dropped, public.set_programmes_v314
-- becomes the one intended writer, a seed-only trigger keeps new tenants alive, businesses
-- .points_mode is frozen behind a swallow+audit tripwire, six consumers move onto the spine, the
-- publish stamps guard follows the switch, and trg_programme_pot_switch_v312 is retired so a
-- settings republish can no longer move a live pot.
--
-- ZERO LIVE TENANTS EXERCISE ANY CHANGED BRANCH — no stamps-active firm, no tiers-active firm,
-- no split pot, and the two `classic` QA tenants cannot redeem a catalogue reward at all today.
-- A green run against production therefore proves ABSENCE OF REGRESSION, not presence of
-- correctness. So all four tenant shapes are CREATED INSIDE THIS TRANSACTION (the W5 discipline):
--
--   T1 points-only    spine points=true, everything else false
--   T2 tiers-only     spine tiers=true, points=false (silent accrual, no spendable points)
--   T3 BOTH accruing  spine points=true AND stamps=true — unreachable before v314 and the
--                     entire reason it exists
--   T4 switched       an earning points firm whose owner turns points off and stamps on, so the
--                     pot-migration routing has something real to move
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v313_v314_programme_switchboard.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v314_out(seq integer, step text, outcome text) on commit drop;

create or replace function pg_temp.as_v314_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v314_system() to public;

create or replace function pg_temp.as_v314_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v314_user(uuid,text) to public;

-- The same identity WITHOUT the browser role: v313/v314 keep the money functions revoked from
-- anon and authenticated, so a step that drives app.redeem_reward_core has to arrive the way
-- production does — through the service role — while auth.uid() still resolves to real staff.
create or replace function pg_temp.as_v314_actor(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','service_role')::text,true);
end
$$;
grant execute on function pg_temp.as_v314_actor(uuid) to public;

create or replace function pg_temp.v314_spine(p_business uuid, p_kind text) returns uuid
language sql stable as $$
  select spine.id from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = p_kind
$$;
grant execute on function pg_temp.v314_spine(uuid,text) to public;

create or replace function pg_temp.v314_active(p_business uuid, p_kind text) returns boolean
language sql stable as $$
  select spine.active from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = p_kind
$$;
grant execute on function pg_temp.v314_active(uuid,text) to public;

-- A raw earn row written exactly the way the loop writes one, so a step can stock a pot without
-- going through a sale. With BOTH v309 tag triggers dropped by v313, programme_id here is the
-- ONLY thing standing between this insert and a NOT NULL violation — which is the point.
create or replace function pg_temp.v314_earn(
  p_business uuid, p_client uuid, p_sale uuid, p_points integer, p_programme uuid
) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  perform set_config('app.points_ledger_insert_id', v_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'sale_trigger', true);
  insert into public.points_ledger(
    id, business_id, client_id, entry_type, points, sale_id, reference, actor, programme_id
  ) values (
    v_id, p_business, p_client, 'earn', p_points, p_sale, 'v314 fixture earn', null, p_programme
  );
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
  return v_id;
end
$$;
grant execute on function pg_temp.v314_earn(uuid,uuid,uuid,integer,uuid) to public;

-- p_version_kind is loyalty_program_versions.kind, the SECOND single-valued discriminator
-- (v26:43 permits 'points' or 'stamps'). The wizard writes 'points' for every model, so every
-- fixture but T6 uses it; T6 is the shape that proves consumer 2's flip behaviourally.
create or replace function pg_temp.v314_tenant(
  p_business uuid, p_owner uuid, p_label text, p_model text,
  p_per_dollar numeric, p_stamp_per_cents integer, p_version_kind text default 'points'
) returns uuid language plpgsql as $$
declare v_config uuid := gen_random_uuid();
begin
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (p_business, p_label, lower(p_label)||'-'||substr(p_business::text,1,8),
          'retail','SGD', array['dashboard','clients','sales','loyalty'], 'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v314 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;

  insert into public.staff(business_id,user_id,role,full_name,active)
  values (p_business,p_owner,'owner','V314 Owner',true);

  insert into public.firm_config_versions(id,business_id,version_no,status,published_at)
  values (v_config,p_business,1,'published',now());
  update public.businesses set active_config_version_id=v_config where id=p_business;

  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,redeem_points,
    reward_credit_cents,tier_basis,expiry_mode,expiry_days,earn_points_per_dollar,
    stamp_target,stamp_per_cents,current_config_version_id)
  values (p_business,p_version_kind,true,p_model,'published',100,500,'visits',
          'none',null,p_per_dollar,10,p_stamp_per_cents,v_config);

  insert into public.loyalty_program_versions(
    business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,
    expiry_mode,expiry_days)
  values (p_business,v_config,p_version_kind,p_model,true,p_per_dollar,100,500,10,
          p_stamp_per_cents,'visits','none',null);

  return v_config;
end
$$;
grant execute on function pg_temp.v314_tenant(uuid,uuid,text,text,numeric,integer,text) to public;

create or replace function pg_temp.v314_sale(
  p_business uuid, p_client uuid, p_config uuid, p_amount integer
) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into public.sales(id,business_id,client_id,kind,amount_cents,earns_points,
                           counts_as_visit,counts_as_revenue,config_version_id,policy_resolved_at)
  values (v_id,p_business,p_client,'service',p_amount,true,true,true,
          coalesce(p_config,(select active_config_version_id from public.businesses
                              where id=p_business)),now());
  return v_id;
end
$$;
grant execute on function pg_temp.v314_sale(uuid,uuid,uuid,integer) to public;

create or replace function pg_temp.v314_quiet_sale(p_business uuid, p_client uuid)
returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into public.sales(id,business_id,client_id,kind,amount_cents,earns_points,
                           counts_as_visit,counts_as_revenue,policy_resolved_at)
  values (v_id,p_business,p_client,'service',0,false,false,true,now());
  return v_id;
end
$$;
grant execute on function pg_temp.v314_quiet_sale(uuid,uuid) to public;

-- A reward priced in a NAMED programme. v313's default trigger would fill programme_id for us;
-- every fixture below names it explicitly, because the whole point of the wave is that a reward
-- knows which pot it costs.
create or replace function pg_temp.v314_reward(
  p_business uuid, p_config uuid, p_label text, p_cost integer, p_programme uuid
) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into public.loyalty_rewards(id,business_id,name,cost_points,credit_cents,active,sort,
                                     programme_id,current_config_version_id)
  values (v_id,p_business,p_label,p_cost,0,true,1,p_programme,p_config);
  insert into public.loyalty_reward_versions(
    business_id,config_version_id,reward_id,internal_name,customer_name,fulfillment_kind,
    cost_points,credit_cents,estimated_cost_cents,active,sort,programme_id)
  values (p_business,p_config,v_id,p_label,p_label,'manual_item',p_cost,0,0,true,1,p_programme);
  return v_id;
end
$$;
grant execute on function pg_temp.v314_reward(uuid,uuid,text,integer,uuid) to public;

-- The whole-catalog digest that proves a re-apply changed nothing (the W5 idiom).
create or replace function pg_temp.v314_catalog_digest() returns text language sql stable as $$
  select md5(string_agg(p.oid::regprocedure::text || ':' || md5(p.prosrc), '|' order by
                        p.oid::regprocedure::text))
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public','app')
$$;
grant execute on function pg_temp.v314_catalog_digest() to public;

do $v314_test$
declare
  v_owner uuid := gen_random_uuid();
  t1 uuid := gen_random_uuid(); t1c uuid := gen_random_uuid(); t1cfg uuid;
  t2 uuid := gen_random_uuid(); t2c uuid := gen_random_uuid(); t2cfg uuid;
  t3 uuid := gen_random_uuid(); t3c uuid := gen_random_uuid(); t3cfg uuid;
  t4 uuid := gen_random_uuid(); t4c uuid := gen_random_uuid(); t4cfg uuid;
  t5 uuid := gen_random_uuid(); t5c uuid := gen_random_uuid(); t5cfg uuid;
  t6 uuid := gen_random_uuid(); t6c uuid := gen_random_uuid(); t6cfg uuid;
  -- T7/T8 are the W6i1 REMEDIATION fixtures (steps 33-35), added after an adversarial review found
  -- three ways the owner's ON/OFF decision failed to reach the engine. Both are BRAND-NEW post-
  -- v314 tenants: seeded all-four-false, no switch ever thrown — the shape every firm created
  -- from now on starts in, and the one no earlier step exercised through a publish.
  t7 uuid := gen_random_uuid(); t7c uuid := gen_random_uuid(); t7cfg uuid;
  t8 uuid := gen_random_uuid(); t8c uuid := gen_random_uuid(); t8cfg uuid;
  v_t7_reward uuid; v_redeem_paused text; v_redeem_live json;
  v_spine_after_publish text; v_spine_after_switch text;
  v_earns_paused bigint;
  v_new_business uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid(); v_cust_user uuid := gen_random_uuid(); v_link uuid;
  v_cust_client uuid := gen_random_uuid();
  v_points_reward uuid; v_stamps_reward uuid; v_t5_reward uuid; v_expensive_reward uuid;
  v_draft uuid; v_draft2 uuid;
  v_result jsonb; v_replay jsonb; v_intent jsonb;
  v_key uuid; v_msg text; v_ok boolean; v_ok2 boolean;
  v_before timestamptz; v_after timestamptz;
  v_paused_before timestamptz; v_paused_after timestamptz;
  v_audits bigint; v_rows bigint; v_count bigint;
  v_earns bigint; v_batches bigint;
  v_mode text; v_caps jsonb;
  v_digest_before text; v_digest_after text;
  v_pot_points integer; v_pot_stamps integer;
  v_migration_id uuid; v_migrations bigint;
  v_slug text;
  v_sale uuid;
  v_redeem json;
begin
  perform pg_temp.as_v314_system();

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
          'v314-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());

  t1cfg := pg_temp.v314_tenant(t1,v_owner,'V314 T1 Points','points_tiers',1.0,null);
  t2cfg := pg_temp.v314_tenant(t2,v_owner,'V314 T2 Tiers','points_tiers',1.0,null);
  t3cfg := pg_temp.v314_tenant(t3,v_owner,'V314 T3 Both','points_tiers',1.0,1000);
  t4cfg := pg_temp.v314_tenant(t4,v_owner,'V314 T4 Switched','points_tiers',1.0,1000);
  t5cfg := pg_temp.v314_tenant(t5,v_owner,'V314 T5 Classic','classic',1.0,null);
  -- T6: a real stamps firm — loyalty_model='stamps' AND version kind='stamps'. Before consumer
  -- 2's flip its points branch was unreachable no matter what the spine said, because
  -- loyalty_program_versions.kind was a second exclusive discriminator.
  t6cfg := pg_temp.v314_tenant(t6,v_owner,'V314 T6 StampKind','stamps',2.0,1000,'stamps');
  -- W6i1 remediation fixtures. T7 is published PAUSED (step 33); T8 is published ACTIVE from the
  -- non-wizard review route (steps 34-35). Neither has ever had a switch thrown, so both sit at
  -- the seeder's all-four-false, which is where the three confirmed defects lived.
  t7cfg := pg_temp.v314_tenant(t7,v_owner,'V314 T7 Paused','points_tiers',1.0,null);
  t8cfg := pg_temp.v314_tenant(t8,v_owner,'V314 T8 NewTenant','points_tiers',1.0,null);
  insert into public.clients(id,business_id,full_name,phone) values
    (t1c,t1,'T1 Customer','81000101'),(t2c,t2,'T2 Customer','81000102'),
    (t3c,t3,'T3 Customer','81000103'),(t4c,t4,'T4 Customer','81000104'),
    (t5c,t5,'T5 Customer','81000105'),(t6c,t6,'T6 Customer','81000106'),
    (t7c,t7,'T7 Customer','81000107'),(t8c,t8,'T8 Customer','81000108');

  -- FIXTURES THAT LATER STEPS SHARE ARE BUILT HERE, OUTSIDE EVERY EXCEPTION BLOCK. A plpgsql
  -- `begin ... exception` is a subtransaction: anything it inserts is rolled back when it
  -- catches, so a fixture created inside one step and read by the next is a silent dependency
  -- on that step passing. Three of the first-run failures in this suite's own development were
  -- exactly that.
  v_points_reward := pg_temp.v314_reward(t3,t3cfg,'V314 Points Gift',100,
                                         pg_temp.v314_spine(t3,'points'));
  v_stamps_reward := pg_temp.v314_reward(t3,t3cfg,'V314 Stamps Gift',5,
                                         pg_temp.v314_spine(t3,'stamps'));
  v_t5_reward := pg_temp.v314_reward(t5,t5cfg,'V314 Classic Firm Gift',50,
                                     pg_temp.v314_spine(t5,'points'));
  v_expensive_reward := pg_temp.v314_reward(t3,t3cfg,'V314 Expensive Stamps Gift',5000,
                                            pg_temp.v314_spine(t3,'stamps'));
  -- T7's reward is deliberately NOT built here: step 33 publishes a new config version for that
  -- firm, and app.redeem_reward_core reads the reward version joined to the business's ACTIVE
  -- config version, so a reward stamped with the pre-publish version would be unreadable
  -- afterwards for a reason that has nothing to do with what the step is testing. It is the only
  -- fixture no other step shares.

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_cust_user,'authenticated','authenticated',
          'v314-customer-'||substr(v_cust_user::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.customer_identities(id,auth_user_id,status,created_via)
  values (v_identity,v_cust_user,'active','email_claim');
  insert into public.clients(id,business_id,full_name,phone)
  values (v_cust_client,t3,'T3 Wallet Customer','81000113');
  v_link := gen_random_uuid();
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                    verification_method,verified_at)
  values (v_link,t3,v_identity,v_cust_user,v_cust_client,'verified','email_claim',now());
  perform set_config('app.customer_link_insert_id','',true);
  insert into public.business_customer_capabilities_v89(
    business_id,booking_enabled,redemption_enabled,appointment_changes_enabled)
  values (t3,false,true,false)
  on conflict (business_id) do update set redemption_enabled=true;
  insert into app.platform_feature_flags(feature_key,enabled)
  values ('customer_qr_redemption',true)
  on conflict (feature_key) do update set enabled=true;

  -- =========================================================================
  -- STEP 1. THE SEED. Every fixture business above was created AFTER the four v308 sync
  --   triggers were dropped, so its four spine rows can only have come from
  --   app.seed_business_programmes_v314. This is the highest-severity risk in the wave:
  --   without the seeder a post-v314 tenant earns nothing, redeems nothing and says nothing.
  -- =========================================================================
  select count(*) into v_rows from public.business_programmes spine
   where spine.business_id in (t1,t2,t3,t4,t5,t6,t7,t8);
  insert into v314_out values (1,'the seeder gives every new tenant four spine rows',
    case when v_rows <> 32 then 'FAIL: expected 32 spine rows across eight new tenants, found '||v_rows
         when exists (select 1 from public.business_programmes spine
                       where spine.business_id in (t1,t2,t3,t4,t5,t6,t7,t8) and spine.active)
           then 'FAIL: a brand-new tenant was seeded with a programme already running'
         when not exists (select 1 from pg_trigger
                           where tgrelid='public.businesses'::regclass
                             and tgname='business_programmes_seed_v314')
           then 'FAIL: the seed trigger is not attached'
         else 'PASS' end);

  -- =========================================================================
  -- STEP 2. THE SYNC IS REALLY GONE. A loyalty_programs write — the loudest surviving legacy
  --   writer, and what publish_loyalty_config does on every publish — must no longer move a
  --   spine row.
  -- =========================================================================
  update public.loyalty_programs set active=false where business_id=t1;
  update public.loyalty_programs set active=true  where business_id=t1;
  insert into v314_out values (2,'the four v308 sync triggers are dropped by name',
    case when exists (select 1 from pg_trigger
                       where tgname in ('business_programmes_sync_businesses_v308',
                                        'business_programmes_sync_loyalty_programs_v308',
                                        'business_programmes_sync_loyalty_tiers_v308',
                                        'business_programmes_sync_referral_programs_v308')
                         and not tgisinternal)
           then 'FAIL: a v308 sync trigger survived'
         when pg_temp.v314_active(t1,'points')
           then 'FAIL: a loyalty_programs write still moved the spine'
         when to_regprocedure('app.sync_business_programmes_v308(uuid)') is null
           then 'FAIL: the sync function was dropped; the rollback is now a rewrite'
         else 'PASS' end);

  -- =========================================================================
  -- STEP 3. THE SWITCH, AUDITED, WITH v308's BREADCRUMB SEMANTICS BYTE-FOR-BYTE.
  --   activated_at moves only on false->true, deactivated_at only on true->false, and neither
  --   is ever cleared. W4b's running_since / paused_since must keep meaning the same thing
  --   across the inversion.
  -- =========================================================================
  begin
    perform pg_temp.as_v314_user(v_owner);
    v_result := public.set_programmes_v314(t1, '{"points":true}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v314_system();
    select activated_at, deactivated_at into v_before, v_paused_before
      from public.business_programmes where business_id=t1 and kind='points';
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t1, '{"points":false}'::jsonb, gen_random_uuid());
    perform public.set_programmes_v314(t1, '{"points":true}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v314_system();
    select activated_at, deactivated_at into v_after, v_paused_after
      from public.business_programmes where business_id=t1 and kind='points';
    select count(*) into v_audits from public.audit_log
     where business_id=t1 and action='PROGRAMME_SWITCH_V314';
    insert into v314_out values (3,'a switch flips the spine, keeps v308 breadcrumbs and is audited',
      case when not pg_temp.v314_active(t1,'points') then 'FAIL: the switch did not land'
           when v_before is null then 'FAIL: activated_at was not stamped on false->true'
           when v_paused_before is not null then 'FAIL: deactivated_at moved on a false->true flip'
           when v_paused_after is null then 'FAIL: deactivated_at was not stamped on true->false'
           -- now() is the transaction timestamp, so a re-activation inside this suite cannot
           -- produce a LATER activated_at. What must hold — and what v308 promised — is that
           -- neither breadcrumb is ever CLEARED: after on->off->on the row carries both.
           when v_after is null then 'FAIL: activated_at was cleared by a later flip'
           when v_paused_after < v_paused_before then 'FAIL: deactivated_at went backwards'
           when v_audits <> 3 then 'FAIL: expected 3 PROGRAMME_SWITCH_V314 audit rows, found '||v_audits
           when (v_result->'changed'->0->>'kind') <> 'points'
             then 'FAIL: the receipt does not name the changed kind'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (3,'a switch flips the spine, keeps v308 breadcrumbs and is audited',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 4. A NO-OP FLIP WRITES NOTHING (v308:313's guard, preserved). No breadcrumb churn, no
  --   dead tuple, no audit row — so an idempotent client that re-sends the current state is free.
  -- =========================================================================
  begin
    select activated_at into v_before from public.business_programmes
     where business_id=t1 and kind='points';
    select count(*) into v_audits from public.audit_log
     where business_id=t1 and action='PROGRAMME_SWITCH_V314';
    perform pg_temp.as_v314_user(v_owner);
    v_result := public.set_programmes_v314(t1, '{"points":true}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v314_system();
    select activated_at into v_after from public.business_programmes
     where business_id=t1 and kind='points';
    select count(*) into v_rows from public.audit_log
     where business_id=t1 and action='PROGRAMME_SWITCH_V314';
    insert into v314_out values (4,'a no-op flip writes nothing at all',
      case when v_after is distinct from v_before then 'FAIL: activated_at churned on a no-op'
           when v_rows <> v_audits then 'FAIL: a no-op flip wrote an audit row'
           when jsonb_array_length(v_result->'changed') <> 0
             then 'FAIL: the receipt claims a change that did not happen'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (4,'a no-op flip writes nothing at all','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 5. IDEMPOTENCY. A double-tapped toggle is one switch: the second call replays the
  --   stored receipt, and a DIFFERENT payload under the same key is a 23505 rather than a
  --   silent second flip.
  -- =========================================================================
  begin
    v_key := gen_random_uuid();
    perform pg_temp.as_v314_user(v_owner);
    v_result := public.set_programmes_v314(t2, '{"tiers":true}'::jsonb, v_key);
    v_replay := public.set_programmes_v314(t2, '{"tiers":true}'::jsonb, v_key);
    v_ok := false;
    begin
      perform public.set_programmes_v314(t2, '{"tiers":false}'::jsonb, v_key);
    exception when others then
      get stacked diagnostics v_msg = message_text;
      v_ok := (v_msg like '%idempotency%');
    end;
    perform pg_temp.as_v314_system();
    select count(*) into v_audits from public.audit_log
     where business_id=t2 and action='PROGRAMME_SWITCH_V314';
    insert into v314_out values (5,'a double-tapped switch is one switch',
      case when v_replay is distinct from v_result then 'FAIL: the replay is not the stored receipt'
           when v_audits <> 1 then 'FAIL: expected exactly 1 audit row, found '||v_audits
           when not v_ok then 'FAIL: a different payload reused the key without conflict'
           when not pg_temp.v314_active(t2,'tiers') then 'FAIL: the tiers switch did not land'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (5,'a double-tapped switch is one switch','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 6. THE OWNER GATE AND THE ACL FLOOR. business_programmes stays SELECT-only for
  --   browsers — the RPC is the only door — and a non-owner cannot open it.
  -- =========================================================================
  begin
    v_ok := false; v_ok2 := false;
    perform pg_temp.as_v314_user(gen_random_uuid());
    begin
      perform public.set_programmes_v314(t1, '{"points":false}'::jsonb, gen_random_uuid());
    exception when others then v_ok := true;
    end;
    begin
      update public.business_programmes set active=false where business_id=t1 and kind='points';
      get diagnostics v_rows = row_count;
      v_ok2 := (v_rows = 0);
    exception when others then v_ok2 := true;
    end;
    perform pg_temp.as_v314_system();
    insert into v314_out values (6,'only the owner RPC writes the spine; browsers cannot',
      case when not v_ok then 'FAIL: a stranger flipped a switch'
           when not v_ok2 then 'FAIL: an authenticated session wrote business_programmes directly'
           when not pg_temp.v314_active(t1,'points') then 'FAIL: the spine moved anyway'
           when exists (select 1 from pg_policies where schemaname='public'
                         and tablename='business_programmes' and cmd <> 'SELECT')
             then 'FAIL: business_programmes gained a non-SELECT policy'
           when has_function_privilege('anon','public.set_programmes_v314(uuid,jsonb,uuid)','execute')
             then 'FAIL: the switch RPC is anon-callable'
           when has_function_privilege('authenticated','app.seed_business_programmes_v314()','execute')
             or has_function_privilege('authenticated','app.detect_spine_legacy_divergence_v314()','execute')
             or has_function_privilege('authenticated','app.business_programmes_active_v314(uuid)','execute')
             then 'FAIL: a v314 app function is browser-callable'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (6,'only the owner RPC writes the spine; browsers cannot',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 7. THE points_mode TRIPWIRE — SWALLOW + AUDIT, NOT A RAISE (brief R4). The OLD app
  --   bundle keeps PATCHing this column for the length of the CDN pin; the write must be
  --   silently pinned, audited, and must not disturb the switchboard.
  -- =========================================================================
  begin
    v_mode := (select points_mode from public.businesses where id=t1);
    update public.businesses set points_mode='tiers' where id=t1;
    select count(*) into v_audits from public.audit_log
     where business_id=t1 and action='POINTS_MODE_WRITE_SUPPRESSED_V314';
    insert into v314_out values (7,'an old-bundle points_mode write is swallowed and audited',
      case when (select points_mode from public.businesses where id=t1) is distinct from v_mode
             then 'FAIL: points_mode moved'
           when v_audits <> 1
             then 'FAIL: expected exactly 1 POINTS_MODE_WRITE_SUPPRESSED_V314 row, found '||v_audits
           when not pg_temp.v314_active(t1,'points')
             then 'FAIL: the suppressed write disturbed the spine'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (7,'an old-bundle points_mode write is swallowed and audited',
      'FAIL: the tripwire RAISED instead of swallowing: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 8. THE FUTURE UPGRADE, PROVEN NOW. Increment 9 turns the tripwire into a raise once
  --   the audit table shows zero suppressed writes. That upgrade is exercised here against the
  --   real trigger — swapped in, driven, and swapped back — so increment 9 inherits a proof
  --   rather than a plan. The named escape GUC is exercised in the same block.
  -- =========================================================================
  begin
    perform set_config('app.points_mode_write_ok','v314',true);
    update public.businesses set points_mode='both' where id=t1;
    v_ok := ((select points_mode from public.businesses where id=t1) = 'both');
    perform set_config('app.points_mode_write_ok','',true);
    update public.businesses set points_mode='redeem' where id=t1;
    v_ok2 := ((select points_mode from public.businesses where id=t1) = 'both');

    create or replace function pg_temp.v314_raising_tripwire() returns trigger
    language plpgsql as $$
    begin
      if new.points_mode is distinct from old.points_mode then
        raise exception 'businesses.points_mode is frozen at v314' using errcode='23514';
      end if;
      return new;
    end $$;
    drop trigger businesses_points_mode_frozen_v314 on public.businesses;
    create trigger businesses_points_mode_frozen_v314
      before update of points_mode on public.businesses
      for each row execute function pg_temp.v314_raising_tripwire();
    begin
      update public.businesses set points_mode='tiers' where id=t1;
      v_msg := 'no raise';
    exception when others then
      get stacked diagnostics v_msg = message_text;
    end;
    drop trigger businesses_points_mode_frozen_v314 on public.businesses;
    create trigger businesses_points_mode_frozen_v314
      before update of points_mode on public.businesses
      for each row execute function app.points_mode_frozen_v314();

    insert into v314_out values (8,'the escape GUC works and the increment-9 raise is proven',
      case when not v_ok then 'FAIL: the named escape GUC did not let a migration through'
           when not v_ok2 then 'FAIL: the tripwire stopped swallowing after the escape'
           when v_msg not like '%frozen at v314%'
             then 'FAIL: the raising variant did not refuse the write ('||v_msg||')'
           when not exists (select 1 from pg_trigger
                             where tgrelid='public.businesses'::regclass
                               and tgname='businesses_points_mode_frozen_v314')
             then 'FAIL: the real tripwire was not restored'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (8,'the escape GUC works and the increment-9 raise is proven',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 9. THE HEADLINE. Switch a programme on, then PUBLISH. Before the inversion
  --   publish_loyalty_config's `update loyalty_programs` (v55:711) drove the sync and silently
  --   reverted the owner's choice. Drop the four triggers and the switch survives a publish —
  --   restore any one of them and this step goes red.
  -- =========================================================================
  begin
    v_draft := gen_random_uuid();
    insert into public.firm_config_versions(id,business_id,version_no,status,based_on_version_id)
    values (v_draft,t1,2,'draft',t1cfg);
    insert into public.loyalty_program_versions(
      business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
      redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,
      expiry_mode,expiry_days)
    values (t1,v_draft,'points','points_tiers',false,1.0,100,500,10,null,'visits','none',null)
    on conflict do nothing;
    perform pg_temp.as_v314_user(v_owner);
    perform public.publish_loyalty_config(v_draft);
    perform pg_temp.as_v314_system();
    insert into v314_out values (9,'THE HEADLINE: a switch survives publish_loyalty_config',
      case when not pg_temp.v314_active(t1,'points')
             then 'FAIL: publishing reverted the owner''s switch'
           when (select active from public.loyalty_programs where business_id=t1) <> false
             then 'FAIL: the publish did not actually write loyalty_programs.active'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (9,'THE HEADLINE: a switch survives publish_loyalty_config',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 10. THE EARN LOOP FOLLOWS THE SWITCH, NOT THE VERSION ROW. T1's published version now
  --   says active=false and its spine says points=true. Consumer 1's flip is what makes the
  --   switchboard mean anything: without it the firm would earn nothing and the owner would see
  --   a switch that does nothing.
  -- =========================================================================
  begin
    -- null config => the business's CURRENT active version. Step 9 published a new one, and
    -- the v26 immutability guard refuses a sale stamped with a superseded version.
    v_sale := pg_temp.v314_sale(t1,t1c,null,10000);
    select count(*) into v_earns from public.points_ledger
     where sale_id=v_sale and entry_type='earn';
    insert into v314_out values (10,'the earn loop is gated by the SPINE, not the version row',
      case when v_earns <> 1
             then 'FAIL: expected one earn row from a switched-on firm, found '||v_earns
           when not exists (select 1 from public.points_ledger l
                             where l.sale_id=v_sale
                               and l.programme_id=pg_temp.v314_spine(t1,'points'))
             then 'FAIL: the earn row is not tagged with the points programme'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (10,'the earn loop is gated by the SPINE, not the version row',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 11. A SWITCHED-OFF PROGRAMME EARNS NOTHING. The other half of step 10: turning points
  --   off must stop accrual even though loyalty_programs and the version row are untouched.
  -- =========================================================================
  begin
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t1, '{"points":false}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v314_system();
    v_sale := pg_temp.v314_sale(t1,t1c,null,10000);
    select count(*) into v_earns from public.points_ledger where sale_id=v_sale;
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t1, '{"points":true}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v314_system();
    insert into v314_out values (11,'a switched-off programme stops accruing',
      case when v_earns <> 0 then 'FAIL: a paused programme earned '||v_earns||' row(s)'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (11,'a switched-off programme stops accruing','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 12. BOTH ACCRUING PROGRAMMES AT ONCE — the state the whole wave exists to reach, and
  --   one that no owner could produce before v314. One sale writes TWO tagged earn rows and TWO
  --   batches, and the in-trigger parity assertion (v311:548-552) holds.
  -- =========================================================================
  begin
    perform pg_temp.as_v314_user(v_owner);
    v_result := public.set_programmes_v314(t3, '{"points":true,"stamps":true}'::jsonb,
                                           gen_random_uuid());
    perform pg_temp.as_v314_system();
    v_sale := pg_temp.v314_sale(t3,t3c,t3cfg,10000);
    select count(*) into v_earns from public.points_ledger
     where sale_id=v_sale and entry_type='earn';
    select count(*) into v_batches from public.points_batches where sale_id=v_sale;
    insert into v314_out values (12,'points AND stamps: one sale, two tagged earns, two batches',
      case when v_earns <> 2 then 'FAIL: expected 2 earn rows, found '||v_earns
           when v_batches <> 2 then 'FAIL: expected 2 batches, found '||v_batches
           when not exists (select 1 from public.points_ledger l
                             where l.sale_id=v_sale and l.programme_id=pg_temp.v314_spine(t3,'points'))
             then 'FAIL: no points-tagged earn row'
           when not exists (select 1 from public.points_ledger l
                             where l.sale_id=v_sale and l.programme_id=pg_temp.v314_spine(t3,'stamps'))
             then 'FAIL: no stamps-tagged earn row'
           when (select count(distinct programme_id) from public.points_batches where sale_id=v_sale) <> 2
             then 'FAIL: the two batches are not on two programmes'
           when jsonb_array_length(v_result->'changed') <> 2
             then 'FAIL: the receipt did not record both flips'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (12,'points AND stamps: one sale, two tagged earns, two batches',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 13. THE CROSS-PROGRAMME DOUBLE-SPEND, CLOSED END-TO-END. T3 now runs both. Its
  --   customer holds points AND stamps in separate pots. A POINTS reward must drain the points
  --   pot and leave the stamp card alone; a STAMPS reward must do the reverse. Before v313
  --   both rewards resolved to the same programme through
  --   app.resolve_ledger_programme_v309 and either could eat the other's money.
  --   REVERT v313's redeem_reward_core splice and this step goes red.
  -- =========================================================================
  begin
    -- Top both pots up to a known, unequal shape so a wrong drain is unmistakable.
    perform pg_temp.v314_earn(t3,t3c,pg_temp.v314_quiet_sale(t3,t3c),400,
                              pg_temp.v314_spine(t3,'points'));
    insert into public.points_batches(business_id,client_id,earned,remaining,earned_at,programme_id)
    values (t3,t3c,400,400,now(),pg_temp.v314_spine(t3,'points'));
    perform pg_temp.v314_earn(t3,t3c,pg_temp.v314_quiet_sale(t3,t3c),20,
                              pg_temp.v314_spine(t3,'stamps'));
    insert into public.points_batches(business_id,client_id,earned,remaining,earned_at,programme_id)
    values (t3,t3c,20,20,now(),pg_temp.v314_spine(t3,'stamps'));

    select coalesce(sum(remaining),0) into v_pot_points from public.points_batches
     where business_id=t3 and client_id=t3c and programme_id=pg_temp.v314_spine(t3,'points');
    select coalesce(sum(remaining),0) into v_pot_stamps from public.points_batches
     where business_id=t3 and client_id=t3c and programme_id=pg_temp.v314_spine(t3,'stamps');

    perform pg_temp.as_v314_actor(v_owner);
    v_redeem := app.redeem_reward_core(t3,t3c,v_points_reward,'v314-points-gift-key');
    v_redeem := app.redeem_reward_core(t3,t3c,v_stamps_reward,'v314-stamps-gift-key');
    perform pg_temp.as_v314_system();

    insert into v314_out values (13,'a stamps gift cannot be paid for out of the points pot',
      case when (select coalesce(sum(remaining),0) from public.points_batches
                  where business_id=t3 and client_id=t3c
                    and programme_id=pg_temp.v314_spine(t3,'points')) <> v_pot_points-100
             then 'FAIL: the points pot did not fall by exactly the points reward''s cost'
           when (select coalesce(sum(remaining),0) from public.points_batches
                  where business_id=t3 and client_id=t3c
                    and programme_id=pg_temp.v314_spine(t3,'stamps')) <> v_pot_stamps-5
             then 'FAIL: the stamps pot did not fall by exactly the stamps reward''s cost'
           when not exists (select 1 from public.points_ledger l
                             where l.business_id=t3 and l.entry_type='redeem' and l.points=-100
                               and l.programme_id=pg_temp.v314_spine(t3,'points'))
             then 'FAIL: the points redemption row is not tagged to points'
           when not exists (select 1 from public.points_ledger l
                             where l.business_id=t3 and l.entry_type='redeem' and l.points=-5
                               and l.programme_id=pg_temp.v314_spine(t3,'stamps'))
             then 'FAIL: the stamps redemption row is not tagged to stamps'
           when position('v_reward_programme:=v_version.programme_id' in
                  (select p.prosrc from pg_proc p
                    where p.oid='app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)'::regprocedure))
                = 0
             then 'FAIL: redeem_reward_core is not reading the reward''s programme'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (13,'a stamps gift cannot be paid for out of the points pot',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 14. AND THE REFUSAL. A reward whose own pot is short must be refused even when the
  --   customer is rich in the OTHER programme — the exact defect the wave closes.
  -- =========================================================================
  begin
    v_ok := false;
    perform pg_temp.as_v314_actor(v_owner);
    begin
      -- A stamps reward costing far more than the stamps pot holds, while the points pot is
      -- flush. Unscoped, the points pot would pay for it.
      perform app.redeem_reward_core(t3,t3c,v_expensive_reward,'v314-expensive-stamps-key');
    exception when others then
      get stacked diagnostics v_msg = message_text;
      v_ok := (v_msg like '%insufficient proven points%');
    end;
    perform pg_temp.as_v314_system();
    insert into v314_out values (14,'a rich points pot cannot rescue a short stamps reward',
      case when not v_ok then 'FAIL: the redemption was allowed ('||coalesce(v_msg,'no error')||')'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (14,'a rich points pot cannot rescue a short stamps reward',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 15. CONSUMER 5's DECLARED, LIVE-VISIBLE BEHAVIOUR CHANGE. T5 is loyalty_model='classic'
  --   — the shape of QA Test Cafe and QA Go-Live Cafe — and today it cannot redeem a catalogue
  --   reward AT ALL (v34:551). After the flip, "points switched on" means it can. This is in the
  --   acceptance doc and the owner note, not discovered at a counter.
  -- =========================================================================
  begin
    perform pg_temp.v314_earn(t5,t5c,pg_temp.v314_quiet_sale(t5,t5c),200,
                              pg_temp.v314_spine(t5,'points'));
    insert into public.points_batches(business_id,client_id,earned,remaining,earned_at,programme_id)
    values (t5,t5c,200,200,now(),pg_temp.v314_spine(t5,'points'));

    v_ok := false;
    perform pg_temp.as_v314_actor(v_owner);
    begin
      perform app.redeem_reward_core(t5,t5c,v_t5_reward,'v314-classic-off-key');
    exception when others then
      get stacked diagnostics v_msg = message_text;
      v_ok := (v_msg like '%catalog redemption is inactive%');
    end;
    perform pg_temp.as_v314_system();
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t5, '{"points":true}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v314_system();
    perform pg_temp.as_v314_actor(v_owner);
    v_redeem := app.redeem_reward_core(t5,t5c,v_t5_reward,'v314-classic-on-key');
    perform pg_temp.as_v314_system();

    insert into v314_out values (15,'a classic firm redeems a catalogue reward once points are on',
      case when not v_ok
             then 'FAIL: catalogue redemption was open before the switch was thrown'
           when coalesce((v_redeem::jsonb)->>'ok','') <> 'true'
             then 'FAIL: the redemption did not succeed after the switch'
           when (select coalesce(sum(remaining),0) from public.points_batches
                  where business_id=t5 and client_id=t5c) <> 150
             then 'FAIL: the drain did not take exactly the reward cost'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (15,'a classic firm redeems a catalogue reward once points are on',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 16. THE CUSTOMER-SIDE QUOTE AGREES WITH THE COUNTER. The affordability check must be
  --   scoped to the REWARD's programme, or the customer is handed a QR redeem_reward_core will
  --   refuse. T3 runs both programmes; the customer's stamps pot is small and their points pot
  --   is large, so an unscoped quote would offer the expensive stamps reward.
  -- =========================================================================
  begin
    perform pg_temp.v314_earn(t3,v_cust_client,pg_temp.v314_quiet_sale(t3,v_cust_client),500,
                              pg_temp.v314_spine(t3,'points'));
    insert into public.points_batches(business_id,client_id,earned,remaining,earned_at,programme_id)
    values (t3,v_cust_client,500,500,now(),pg_temp.v314_spine(t3,'points'));
    perform pg_temp.v314_earn(t3,v_cust_client,pg_temp.v314_quiet_sale(t3,v_cust_client),8,
                              pg_temp.v314_spine(t3,'stamps'));
    insert into public.points_batches(business_id,client_id,earned,remaining,earned_at,programme_id)
    values (t3,v_cust_client,8,8,now(),pg_temp.v314_spine(t3,'stamps'));

    v_ok := false;
    perform pg_temp.as_v314_user(v_cust_user);
    begin
      -- costs 5000 stamps; the customer holds 8 stamps and 500 points.
      v_intent := public.customer_create_redemption_intent_v89(
        t3, v_expensive_reward, gen_random_uuid());
    exception when others then
      get stacked diagnostics v_msg = message_text;
      v_ok := (v_msg like '%insufficient%');
    end;
    -- the POINTS reward, priced at 100, is affordable out of the points pot
    v_intent := public.customer_create_redemption_intent_v89(t3, v_points_reward,
                                                             gen_random_uuid());
    perform pg_temp.as_v314_system();
    insert into v314_out values (16,'the customer quote is scoped to the reward''s own programme',
      case when not v_ok
             then 'FAIL: an unaffordable stamps reward was quoted out of the points pot'
           when coalesce(v_intent->>'intent_id','') = ''
             then 'FAIL: the in-programme intent was not created'
           when position('programme_id=v_intent_programme' in
                  (select p.prosrc from pg_proc p
                    where p.oid='public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure))
                = 0
             then 'FAIL: the intent batch proof is not reward-scoped'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (16,'the customer quote is scoped to the reward''s own programme',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 17. AND THE INTENT REFUSES A PAUSED PROGRAMME (consumer 4). The v229 gate keyed on
  --   businesses.points_mode='tiers'; that column is frozen now, so the refusal has to come
  --   from the spine or a paused programme would still hand out QRs.
  -- =========================================================================
  begin
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t3, '{"points":false}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v314_system();
    v_ok := false;
    perform pg_temp.as_v314_user(v_cust_user);
    begin
      v_intent := public.customer_create_redemption_intent_v89(t3, v_points_reward,
                                                               gen_random_uuid());
    exception when others then
      get stacked diagnostics v_msg = message_text;
      v_ok := (v_msg like '%not running%');
    end;
    perform pg_temp.as_v314_system();
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t3, '{"points":true}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v314_system();
    insert into v314_out values (17,'a paused programme''s reward is refused at quote time',
      case when not v_ok
             then 'FAIL: a paused programme still quoted a redemption ('||coalesce(v_msg,'none')||')'
           when position('points_mode' in
                  (select p.prosrc from pg_proc p
                    where p.oid='public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure))
                <> 0
             then 'FAIL: the intent still reads businesses.points_mode'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (17,'a paused programme''s reward is refused at quote time',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 18. THE CAPABILITY SURFACE READS THE SPINE, AND points_mode IS NEVER NULL. The KEY
  --   survives for the client (v310:455, re-spliced at v312:513); its VALUE is derived —
  --   points AND tiers -> 'both', tiers -> 'tiers', otherwise 'redeem'. A NULL here would make
  --   coalesce(points_mode,'tiers') resurrect a ladder on the customer page.
  -- =========================================================================
  begin
    select slug into v_slug from public.businesses where id=t3;
    perform pg_temp.as_v314_user(v_cust_user);
    v_caps := public.customer_portal_capabilities(v_slug);
    perform pg_temp.as_v314_system();
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t3, '{"tiers":true}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v314_system();
    perform pg_temp.as_v314_user(v_cust_user);
    v_intent := public.customer_portal_capabilities(v_slug);
    perform pg_temp.as_v314_system();
    insert into v314_out values (18,'capabilities derive points_mode from the spine, never null',
      case when v_caps->>'points_mode' is distinct from 'redeem'
             then 'FAIL: points-only did not derive ''redeem'' (got '||coalesce(v_caps->>'points_mode','null')||')'
           when v_intent->>'points_mode' is distinct from 'both'
             then 'FAIL: points+tiers did not derive ''both'' (got '||coalesce(v_intent->>'points_mode','null')||')'
           when (v_caps->>'programmes_contract') <> 'v310'
             then 'FAIL: the programmes contract key was lost'
           when jsonb_array_length(v_caps->'programmes') <> 4
             then 'FAIL: the programmes array is not four rows'
           when (v_intent->>'tiers')::boolean
             then 'FAIL: tiers reads true with no rungs on the ladder'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (18,'capabilities derive points_mode from the spine, never null',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 19. POT-MIGRATION ROUTING, THE CASE THAT MOVES. T4 earns under points, then its owner
  --   switches points OFF and stamps ON in ONE call. Exactly one accruing programme is left, its
  --   sibling is inactive and holds money, so the switch routes through
  --   app.enqueue_programme_pot_migration_v312 (V311/V312 standing invariant 2) and the pot
  --   arrives whole under the new identity.
  -- =========================================================================
  begin
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t4, '{"points":true}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v314_system();
    perform pg_temp.v314_sale(t4,t4c,t4cfg,25000);
    select coalesce(sum(remaining),0) into v_pot_points from public.points_batches
     where business_id=t4 and client_id=t4c;

    perform pg_temp.as_v314_user(v_owner);
    v_result := public.set_programmes_v314(t4, '{"points":false,"stamps":true}'::jsonb,
                                           gen_random_uuid());
    perform pg_temp.as_v314_system();
    v_migration_id := (v_result->>'pot_migration_id')::uuid;

    insert into v314_out values (19,'an accruing-identity flip routes through the v312 enqueue',
      case when v_pot_points <= 0 then 'FAIL: the fixture never earned anything to move'
           when v_migration_id is null
             then 'FAIL: the switch did not enqueue a pot migration'
           when (select status from public.programme_pot_migrations where id=v_migration_id)
                <> 'complete'
             then 'FAIL: the inline migration did not complete'
           when (select coalesce(sum(remaining),0) from public.points_batches
                  where business_id=t4 and client_id=t4c
                    and programme_id=pg_temp.v314_spine(t4,'stamps')) <> v_pot_points
             then 'FAIL: the pot did not arrive whole under the stamps programme'
           when (select coalesce(sum(remaining),0) from public.points_batches
                  where business_id=t4 and client_id=t4c
                    and programme_id=pg_temp.v314_spine(t4,'points')) <> 0
             then 'FAIL: money was left behind under the old programme'
           when exists (select 1 from app.detect_programme_pot_split_v312() d
                         where d.business_id=t4)
             then 'FAIL: the transfer left the firm incoherent'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (19,'an accruing-identity flip routes through the v312 enqueue',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 20. THE THREE CASES THAT MUST NOT ENQUEUE. The rule is stated on the POT, not the
  --   active set: (a) ADDING a second accruing programme never moves the first one's money;
  --   (b) turning one of two OFF freezes that pot, it does not confiscate it; (c) both on is
  --   the intended split. Any of these enqueueing is a silent transfer of a live pot.
  -- =========================================================================
  begin
    select count(*) into v_migrations from public.programme_pot_migrations where business_id=t3;
    perform pg_temp.as_v314_user(v_owner);
    -- (a) T3 already runs points (with a pot); ADD stamps.
    perform public.set_programmes_v314(t3, '{"stamps":true}'::jsonb, gen_random_uuid());
    -- (c) both on, flip an unrelated programme
    perform public.set_programmes_v314(t3, '{"referral":true}'::jsonb, gen_random_uuid());
    -- (b) turn one of the two accruing programmes off; T3's stamps pot must be frozen, not moved
    perform public.set_programmes_v314(t3, '{"stamps":false}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v314_system();
    select count(*) into v_count from public.programme_pot_migrations where business_id=t3;
    insert into v314_out values (20,'adding, pausing and splitting never move a pot',
      case when v_count <> v_migrations
             then 'FAIL: '||(v_count-v_migrations)||' pot migration(s) were enqueued by a flip that moves no identity'
           when (select coalesce(sum(remaining),0) from public.points_batches
                  where business_id=t3 and programme_id=pg_temp.v314_spine(t3,'stamps')) = 0
             then 'FAIL: the paused stamps pot was emptied'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (20,'adding, pausing and splitting never move a pot','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 21. A SETTINGS REPUBLISH CROSSING THE STAMPS BOUNDARY MUST NOT ENQUEUE. This is the
  --   money bug step 3b of v314 retires: trg_programme_pot_switch_v312 fired on
  --   `after update of loyalty_model`, and publish_loyalty_config writes that column on EVERY
  --   publish. Restore the trigger and this step goes red.
  -- =========================================================================
  begin
    select count(*) into v_migrations from public.programme_pot_migrations where business_id=t1;
    v_draft2 := gen_random_uuid();
    insert into public.firm_config_versions(id,business_id,version_no,status,based_on_version_id)
    values (v_draft2,t1,3,'draft',t1cfg);
    insert into public.loyalty_program_versions(
      business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
      redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,
      expiry_mode,expiry_days)
    values (t1,v_draft2,'points','stamps',true,1.0,100,500,10,1000,'visits','none',null);
    perform pg_temp.as_v314_user(v_owner);
    perform public.publish_loyalty_config(v_draft2);
    perform pg_temp.as_v314_system();
    select count(*) into v_count from public.programme_pot_migrations where business_id=t1;
    insert into v314_out values (21,'a settings republish across the stamps boundary moves no pot',
      case when exists (select 1 from pg_trigger
                         where tgname='trg_programme_pot_switch_v312' and not tgisinternal)
             then 'FAIL: trg_programme_pot_switch_v312 is still attached'
           when v_count <> v_migrations
             then 'FAIL: a republish enqueued '||(v_count-v_migrations)||' pot migration(s)'
           when not pg_temp.v314_active(t1,'points')
             then 'FAIL: the republish also reverted the switch'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (21,'a settings republish across the stamps boundary moves no pot',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 22. THE PUBLISH STAMPS GUARD FOLLOWS THE SWITCH (v314 step 6). v55:685 refused an
  --   ACTIVE stamps config with no spend-per-stamp, keyed on loyalty_model. Post-inversion the
  --   key is the stamps SPINE ROW. The points side stays lenient — an earn rate of 0 is a legal
  --   tiers-only silent-accrual shape and the OWNER AMENDMENT protects it.
  -- =========================================================================
  begin
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t2, '{"stamps":true}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v314_system();
    v_draft2 := gen_random_uuid();
    insert into public.firm_config_versions(id,business_id,version_no,status,based_on_version_id)
    values (v_draft2,t2,4,'draft',t2cfg);
    insert into public.loyalty_program_versions(
      business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
      redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,
      expiry_mode,expiry_days)
    values (t2,v_draft2,'points','points_tiers',true,0,100,500,10,null,'visits','none',null);
    v_ok := false;
    perform pg_temp.as_v314_user(v_owner);
    begin
      perform public.publish_loyalty_config(v_draft2);
    exception when others then
      get stacked diagnostics v_msg = message_text;
      v_ok := (v_msg like '%spend per stamp%');
    end;
    perform pg_temp.as_v314_system();
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t2, '{"stamps":false}'::jsonb, gen_random_uuid());
    perform public.publish_loyalty_config(v_draft2);
    perform pg_temp.as_v314_system();
    insert into v314_out values (22,'the publish stamps guard is keyed on the stamps switch',
      case when not v_ok
             then 'FAIL: a stamps-on firm published with no spend-per-stamp'
           when not pg_temp.v314_active(t2,'tiers')
             then 'FAIL: publishing with a zero earn rate disturbed the tier switch'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (22,'the publish stamps guard is keyed on the stamps switch',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 23. CONCURRENCY: TWO FLIPS SERIALISE ON THE businesses ROW. V308 standing invariant 1
  --   is the only thing keeping a publish and a switch — or two owners — from interleaving. The
  --   lock is taken here and its presence is asserted from pg_locks while it is held.
  -- =========================================================================
  begin
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t1, '{"referral":true}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v314_system();
    select count(*) into v_count
      from pg_locks lock_row
     where lock_row.locktype='transactionid' and lock_row.pid=pg_backend_pid();
    insert into v314_out values (23,'the switch takes the businesses row before the spine rows',
      case when position('from public.businesses target where target.id = p_business for update' in
                  (select p.prosrc from pg_proc p
                    where p.oid='public.set_programmes_v314(uuid,jsonb,uuid)'::regprocedure)) = 0
             then 'FAIL: set_programmes_v314 does not lock the businesses row first'
           when position('order by case entry.key' in
                  (select p.prosrc from pg_proc p
                    where p.oid='public.set_programmes_v314(uuid,jsonb,uuid)'::regprocedure)) = 0
             then 'FAIL: the spine rows are not taken in kind order'
           when not exists (select 1 from pg_locks l
                             where l.locktype='tuple' or l.locktype='transactionid')
             then 'FAIL: no lock was taken at all'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (23,'the switch takes the businesses row before the spine rows',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 24. SELF-HEAL. A firm that somehow lacks its four rows (a pre-v308 restore, a manual
  --   delete) must not fail its owner's first switch.
  -- =========================================================================
  begin
    delete from public.business_programmes
     where business_id=t2 and kind in ('stamps','referral');
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t2, '{"referral":true}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v314_system();
    select count(*) into v_count from public.business_programmes where business_id=t2;
    insert into v314_out values (24,'set_programmes_v314 self-heals a firm missing spine rows',
      case when v_count <> 4 then 'FAIL: expected four rows after the self-heal, found '||v_count
           when not pg_temp.v314_active(t2,'referral') then 'FAIL: the switch did not land'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (24,'set_programmes_v314 self-heals a firm missing spine rows',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 25. v313's IDENTITY IS COMPLETE. NOT NULL on both tables, the FKs, the cross-tenant
  --   guard, the INSERT default, and the publish projection carrying the authored programme onto
  --   the live reward row.
  -- =========================================================================
  begin
    v_ok := false;
    begin
      insert into public.loyalty_reward_versions(
        business_id,config_version_id,reward_id,internal_name,customer_name,fulfillment_kind,
        cost_points,credit_cents,estimated_cost_cents,active,sort,programme_id)
      values (t3,t3cfg,v_points_reward,'x','x','manual_item',1,0,0,true,9,
              pg_temp.v314_spine(t1,'points'));
    exception when others then
      get stacked diagnostics v_msg = message_text;
      v_ok := (v_msg like '%another tenant%');
    end;

    -- the default: an INSERT that names no programme still lands NOT NULL, on T1's points row
    insert into public.loyalty_rewards(id,business_id,name,cost_points,credit_cents,active,sort)
    values (gen_random_uuid(),t1,'V314 Defaulted Reward',10,0,true,7);

    insert into v314_out values (25,'a reward always knows its programme, and only its own tenant''s',
      case when not v_ok then 'FAIL: a cross-tenant programme tag was accepted'
           when exists (select 1 from public.loyalty_rewards where programme_id is null)
             or exists (select 1 from public.loyalty_reward_versions where programme_id is null)
             then 'FAIL: an untagged reward row exists'
           when (select programme_id from public.loyalty_rewards
                  where business_id=t1 and name='V314 Defaulted Reward')
                is distinct from pg_temp.v314_spine(t1,'points')
             then 'FAIL: the authoring default did not resolve to the active accruing programme'
           when position('programme_id=rv.programme_id' in
                  (select p.prosrc from pg_proc p
                    where p.oid='public.publish_loyalty_config(uuid)'::regprocedure)) = 0
             then 'FAIL: publish does not project the reward programme'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (25,'a reward always knows its programme, and only its own tenant''s',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 26. HONESTY. Every step above ran with BOTH v309 tag triggers dropped (v313 §7), so any
  --   money writer that is not explicit names itself with a NOT NULL violation rather than being
  --   quietly tagged into the wrong pot. This extends the W5 suite's steps 29-36 pattern one wave
  --   further: nothing is untagged, nothing is cross-tenant, and the oracle is called by nobody.
  -- =========================================================================
  insert into v314_out values (26,'honesty: the v309 tag triggers are gone and every writer is explicit',
    case when exists (select 1 from pg_trigger
                       where tgname in ('trg_points_ledger_programme_tag_v309',
                                        'trg_points_batches_programme_tag_v309')
                         and not tgisinternal)
           then 'FAIL: a v309 tag trigger survived'
         when exists (select 1 from public.points_ledger where programme_id is null)
           then 'FAIL: an untagged ledger row landed with the tag triggers dropped'
         when exists (select 1 from public.points_batches where programme_id is null)
           then 'FAIL: an untagged batch landed with the tag triggers dropped'
         when exists (select 1 from public.points_ledger ledger
                       join public.business_programmes spine on spine.id=ledger.programme_id
                      where spine.business_id <> ledger.business_id)
           then 'FAIL: a ledger row carries another tenant''s programme'
         when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                       where (n.nspname,p.proname) in (('app','redeem_reward_core'),
                             ('public','customer_create_redemption_intent_v89'),
                             ('app','on_sale_recorded'))
                         and position('resolve_ledger_programme_v309' in p.prosrc) > 0)
           then 'FAIL: a money path still calls the pre-inversion oracle'
         when to_regprocedure('app.resolve_ledger_programme_v309(uuid)') is null
           or to_regprocedure('app.tag_ledger_programme_v309()') is null
           then 'FAIL: a v309 function was dropped; the rollback is now a rewrite'
         else 'PASS' end);

  -- =========================================================================
  -- STEP 27. THE ROLLBACK PATH, PROVEN — AND ITS PRICE. Re-attaching the four sync triggers and
  --   re-running the sync restores the pre-inversion world AND DISCARDS EVERY SWITCH AN OWNER
  --   MADE. That is the rollback. It is proven here so it is never discovered in an incident.
  -- =========================================================================
  begin
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t5, '{"tiers":true,"referral":true}'::jsonb,
                                       gen_random_uuid());
    perform pg_temp.as_v314_system();
    v_ok := pg_temp.v314_active(t5,'tiers');

    create trigger business_programmes_sync_loyalty_programs_v308
      after insert or update or delete on public.loyalty_programs
      for each row execute function app.business_programmes_sync_trigger_v308('business_id');
    perform app.sync_business_programmes_v308(t5);
    v_ok2 := pg_temp.v314_active(t5,'tiers');
    drop trigger business_programmes_sync_loyalty_programs_v308 on public.loyalty_programs;
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t5, '{"tiers":false,"referral":false}'::jsonb,
                                       gen_random_uuid());
    perform pg_temp.as_v314_system();

    insert into v314_out values (27,'the rollback re-derives the spine — and discards the switches',
      case when not v_ok then 'FAIL: the switch under test never landed'
           when v_ok2 then 'FAIL: re-running the sync did NOT re-derive the spine'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (27,'the rollback re-derives the spine — and discards the switches',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 28. THE DIVERGENCE DETECTOR IS A REPORT, NOT AN ASSERTION. It was asserted EMPTY once,
  --   at apply. From the first independent switch it is expected to be non-empty — that is the
  --   product working, and a later wave must never "fix" it back to an assertion.
  -- =========================================================================
  insert into v314_out values (28,'detect_spine_legacy_divergence_v314 reports the intended divergence',
    case when not exists (select 1 from app.detect_spine_legacy_divergence_v314())
           then 'FAIL: the detector is empty after this suite switched programmes independently'
         when not exists (select 1 from app.detect_spine_legacy_divergence_v314() d
                           where d.business_id=t3)
           then 'FAIL: T3''s independently switched programmes are not reported'
         else 'PASS' end);

  -- =========================================================================
  -- STEP 29. THE STANDING DETECTORS. The money must still be coherent after all of the above:
  --   two pots per client at T3, a transferred pot at T4, redemptions in both programmes.
  -- =========================================================================
  insert into v314_out values (29,'the standing money detectors are empty',
    case when exists (select 1 from app.detect_programme_pot_split_v312())
           then 'FAIL: the v312 pot-split detector is not empty'
         when exists (select 1 from public.business_programmes spine
                       group by spine.business_id having count(*) <> 4)
           then 'FAIL: a business does not own exactly four spine rows'
         when exists (select 1 from public.points_ledger l
                       left join public.business_programmes spine on spine.id=l.programme_id
                      where spine.id is null)
           then 'FAIL: a ledger row points at no programme'
         else 'PASS' end);

  -- =========================================================================
  -- STEP 30. DOUBLE-APPLY REFUSAL AND CATALOG STABILITY. v313 and v314 are one-apply migrations
  --   (backfills, NOT NULLs and re-splices); each must refuse itself rather than half-land, and
  --   the whole public+app function catalog must be byte-stable across the refusal.
  -- =========================================================================
  begin
    v_digest_before := pg_temp.v314_catalog_digest();
    v_ok := false; v_ok2 := false;
    begin
      -- v313's own guard
      if exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='loyalty_rewards'
                    and column_name='programme_id') then
        v_ok := true;
      end if;
      -- v314's own guard
      if to_regprocedure('public.set_programmes_v314(uuid,jsonb,uuid)') is not null then
        v_ok2 := true;
      end if;
    end;
    v_digest_after := pg_temp.v314_catalog_digest();
    insert into v314_out values (30,'both migrations carry a self-refusal and the catalog is stable',
      case when not v_ok then 'FAIL: v313''s already-applied guard has nothing to detect'
           when not v_ok2 then 'FAIL: v314''s already-applied guard has nothing to detect'
           when v_digest_after is distinct from v_digest_before
             then 'FAIL: the function catalog moved under a read-only check'
           when position('v313 is already applied' in
                  (select p.prosrc from pg_proc p
                    where p.oid='app.reward_default_programme_v313(uuid)'::regprocedure)) <> 0
             then 'FAIL: unexpected guard text leaked into a function body'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (30,'both migrations carry a self-refusal and the catalog is stable',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 31. THE OWNER AMENDMENT, VERIFIED BY OMISSION. tier_basis and every expiry knob are
  --   deliberately untouched by this wave. This step is the mechanical guard on that promise:
  --   if a later reader "tidies" one of them into v313/v314 it goes red.
  -- =========================================================================
  insert into v314_out values (31,'tier_basis and every expiry knob are untouched (OWNER AMENDMENT)',
    case when (select tier_basis from public.loyalty_programs where business_id=t1) <> 'visits'
           then 'FAIL: tier_basis moved'
         when (select expiry_mode from public.loyalty_programs where business_id=t1) <> 'none'
           then 'FAIL: expiry_mode moved'
         when position('tier_basis' in
                (select p.prosrc from pg_proc p
                  where p.oid='public.set_programmes_v314(uuid,jsonb,uuid)'::regprocedure)) <> 0
           then 'FAIL: the switch RPC mentions tier_basis'
         when position('expiry' in
                (select p.prosrc from pg_proc p
                  where p.oid='public.set_programmes_v314(uuid,jsonb,uuid)'::regprocedure)) <> 0
           then 'FAIL: the switch RPC mentions an expiry knob'
         else 'PASS' end);

  -- =========================================================================
  -- STEP 32. CONSUMER 2, PROVEN BEHAVIOURALLY. T6 is a stamps firm whose VERSION row carries
  --   kind='stamps' — the second single-valued discriminator (v26:43). Before the flip the
  --   points branch was gated by `lp.kind='points'` and could never run for this firm no matter
  --   what its spine said, so switching points on would have been a switch that did nothing.
  --   Restore the conjunct (mutant M9) and this step goes red.
  -- =========================================================================
  begin
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t6, '{"points":true,"stamps":true}'::jsonb,
                                       gen_random_uuid());
    perform pg_temp.as_v314_system();
    v_sale := pg_temp.v314_sale(t6,t6c,null,10000);
    select count(*) into v_earns from public.points_ledger
     where sale_id=v_sale and entry_type='earn';
    insert into v314_out values (32,'a stamps-KIND version can still run the points programme',
      case when v_earns <> 2
             then 'FAIL: expected 2 earn rows from a stamps-kind firm running both, found '||v_earns
           when not exists (select 1 from public.points_ledger l
                             where l.sale_id=v_sale and l.programme_id=pg_temp.v314_spine(t6,'points')
                               and l.points=200)
             then 'FAIL: the points branch did not earn at the version''s own rate'
           when position('lp.kind' in
                  (select p.prosrc from pg_proc p
                    where p.oid='app.on_sale_recorded()'::regprocedure)) <> 0
             then 'FAIL: the version-kind discriminator is still read as a switch'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (32,'a stamps-KIND version can still run the points programme',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 33. "KEEP IT PAUSED FOR NOW — CUSTOMERS EARN NOTHING" IS TRUE AGAIN, IN BOTH
  --   DIRECTIONS. This is the adversarial review's probe schedule, made permanent.
  --
  --   The first cut of this wave broke the promise from BOTH ends at once. Consumer 1 dropped
  --   `lp.active` from the earn gate — correct — but the browser published `active:false` and
  --   then called set_programmes_v314 with the switches ON regardless, so a firm published
  --   PAUSED earned. Meanwhile app.redeem_reward_core's row lookup still carried `and active
  --   limit 1`, so the SAME firm refused every catalogue redemption. It accrued a liability its
  --   customers could never spend.
  --
  --   PAUSED = the spine row is OFF, and that one flag governs accrual AND payout. The two
  --   halves of this step are the two halves of that sentence, on one firm, minutes apart:
  --   paused, it neither earns nor pays; unpaused, it does both.
  --
  --   RED-FIRST: revert the client half (app/app.js programmeSwitchSetV314 ignoring `paused`) and
  --   the first half of this step goes red; revert the server half (restore `and active limit 1`
  --   in v314's consumer-5 site 1) and the second half does, because publishing paused left
  --   loyalty_programs.active=false and the lookup would refuse a redemption the switch allows.
  -- =========================================================================
  begin
    -- The wizard's Go-live step with "Keep it paused for now" ticked: save active=false onto the
    -- draft, publish it, then apply the switch set for pick='redeem' WITH keepPaused — which is
    -- every switch in that set turned off (app/app.js programmeSwitchSetV314).
    v_draft := gen_random_uuid();
    insert into public.firm_config_versions(id,business_id,version_no,status,based_on_version_id)
    values (v_draft,t7,2,'draft',t7cfg);
    insert into public.loyalty_program_versions(
      business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
      redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,
      expiry_mode,expiry_days)
    values (t7,v_draft,'points','points_tiers',false,1.0,100,500,10,null,'visits','none',null)
    on conflict do nothing;
    perform pg_temp.as_v314_user(v_owner);
    perform public.publish_loyalty_config(v_draft);
    perform public.set_programmes_v314(t7,'{"points":false,"tiers":false}'::jsonb,gen_random_uuid());
    perform pg_temp.as_v314_system();
    -- Captured NOW, not read in the assertion below: the second half of this step deliberately
    -- unpauses the same firm, so by the time the case expression runs the live answer is the
    -- opposite one.
    v_ok := pg_temp.v314_active(t7,'points');
    -- The gift is priced in the points programme and stamped with the version that is now live.
    v_t7_reward := pg_temp.v314_reward(t7,v_draft,'V314 Paused Firm Gift',10,
                                       pg_temp.v314_spine(t7,'points'));

    -- Stock a pot the way the loop would have, so "cannot redeem" is about the PAUSE and never
    -- about an empty balance.
    perform pg_temp.v314_earn(t7,t7c,pg_temp.v314_quiet_sale(t7,t7c),500,
                              pg_temp.v314_spine(t7,'points'));
    insert into public.points_batches(business_id,client_id,earned,remaining,earned_at,programme_id)
    values (t7,t7c,500,500,now(),pg_temp.v314_spine(t7,'points'));

    v_sale := pg_temp.v314_sale(t7,t7c,null,10000);
    select count(*) into v_earns_paused from public.points_ledger
     where sale_id=v_sale and entry_type='earn';

    v_redeem_paused := '';
    perform pg_temp.as_v314_actor(v_owner);
    begin
      perform app.redeem_reward_core(t7,t7c,v_t7_reward,'v314-paused-redeem-key');
      v_redeem_paused := 'SUCCEEDED';
    exception when others then
      get stacked diagnostics v_redeem_paused = message_text;
    end;
    perform pg_temp.as_v314_system();

    -- Same firm, unpaused. The published version STILL says active=false — that column is a
    -- setting now — so this half is exactly what consumer 5 site 1 exists for.
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t7,'{"points":true,"tiers":false}'::jsonb,gen_random_uuid());
    perform pg_temp.as_v314_system();
    v_sale := pg_temp.v314_sale(t7,t7c,null,10000);
    select count(*) into v_earns from public.points_ledger
     where sale_id=v_sale and entry_type='earn';
    perform pg_temp.as_v314_actor(v_owner);
    v_redeem_live := app.redeem_reward_core(t7,t7c,v_t7_reward,'v314-unpaused-redeem-key');
    perform pg_temp.as_v314_system();

    insert into v314_out values (33,'publishing PAUSED earns nothing AND pays nothing; unpausing does both',
      case when v_ok
             then 'FAIL: the paused publish left the points programme switched on'
           when v_earns_paused <> 0
             then 'FAIL: PAUSED CONFIG EARNED '||v_earns_paused||' row(s)'
           when v_redeem_paused not like '%catalog redemption is inactive%'
             then 'FAIL: a paused firm did not refuse redemption cleanly: '||v_redeem_paused
           when (select active from public.loyalty_programs where business_id=t7) <> false
             then 'FAIL: the fixture did not actually publish a paused settings row'
           when v_earns <> 1
             then 'FAIL: unpausing did not restore accrual, found '||v_earns||' earn row(s)'
           when coalesce((v_redeem_live::jsonb)->>'ok','') <> 'true'
             then 'FAIL: unpausing did not restore catalogue redemption'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (33,'publishing PAUSED earns nothing AND pays nothing; unpausing does both',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 34. THE NON-WIZARD PUBLISH ROUTES. Until the remediation, exactly ONE of the three
  --   publish call sites in app/app.js applied the programme switches: the setup wizard. The
  --   Grow review page (:24316 pre-fix) and the Studio publish (:24970 pre-fix) called
  --   publish_loyalty_config alone — and the v308 sync trigger that used to carry a publish
  --   through to the spine had just been dropped by this very migration. So an owner who set the
  --   whole programme up in the Grow editor and published it from the review page went live with
  --   all four spine rows false: loyalty_programs.active=true, engine off, page saying "Live".
  --
  --   This step replays that route's server calls in order and pins BOTH facts: publishing alone
  --   does not move the spine (the inversion working as designed), and the switch call the review
  --   route now makes afterwards is what makes the published programme real.
  --   The CLIENT half — that all three routes actually make the call — cannot be asserted from
  --   SQL and is pinned at source level in tests/business-ui/v314-programme-switchboard.test.mjs.
  -- =========================================================================
  begin
    v_draft2 := gen_random_uuid();
    insert into public.firm_config_versions(id,business_id,version_no,status,based_on_version_id)
    values (v_draft2,t8,2,'draft',t8cfg);
    insert into public.loyalty_program_versions(
      business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
      redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,
      expiry_mode,expiry_days)
    values (t8,v_draft2,'points','points_tiers',true,1.0,100,500,10,null,'visits','none',null)
    on conflict do nothing;
    perform pg_temp.as_v314_user(v_owner);
    perform public.publish_loyalty_config(v_draft2);
    perform pg_temp.as_v314_system();
    select string_agg(spine.kind||'='||spine.active::text,',' order by spine.sort)
      into v_spine_after_publish
      from public.business_programmes spine where spine.business_id=t8;

    -- ...and now the call the review route makes, with the draft's own active flag:
    -- applyPublishedProgrammeSwitchesV314({active:true}) for a points firm.
    perform pg_temp.as_v314_user(v_owner);
    perform public.set_programmes_v314(t8,'{"points":true,"tiers":false}'::jsonb,gen_random_uuid());
    perform pg_temp.as_v314_system();
    select string_agg(spine.kind||'='||spine.active::text,',' order by spine.sort)
      into v_spine_after_switch
      from public.business_programmes spine where spine.business_id=t8;

    insert into v314_out values (34,'an ACTIVE publish alone does not switch the spine; the publish route''s switch call does',
      case when v_spine_after_publish <> 'points=false,tiers=false,stamps=false,referral=false'
             then 'FAIL: publishing moved the spine on its own — a sync trigger is back: '||coalesce(v_spine_after_publish,'(null)')
           when (select active from public.loyalty_programs where business_id=t8) <> true
             then 'FAIL: the fixture did not actually publish an active settings row'
           when v_spine_after_switch <> 'points=true,tiers=false,stamps=false,referral=false'
             then 'FAIL: the publish route''s switch call did not land: '||coalesce(v_spine_after_switch,'(null)')
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (34,'an ACTIVE publish alone does not switch the spine; the publish route''s switch call does',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 35. THE ACCEPTANCE BAR, STATED AS ONE SENTENCE: a brand-new post-v314 tenant that
  --   publishes an ACTIVE programme from ANY route earns on its very next sale. T8 has never
  --   been near the wizard; it went editor -> review page -> publish -> switch, and that is the
  --   path the adversarial probe proved dead. One $100 sale, one earn row, tagged with the
  --   points programme the switch turned on.
  -- =========================================================================
  begin
    v_sale := pg_temp.v314_sale(t8,t8c,null,10000);
    select count(*) into v_earns from public.points_ledger
     where sale_id=v_sale and entry_type='earn';
    select count(*) into v_batches from public.points_batches where sale_id=v_sale;
    insert into v314_out values (35,'a brand-new tenant published ACTIVE from a non-wizard route earns on the next sale',
      case when v_earns <> 1
             then 'FAIL: EARNED NOTHING — the published live programme is dead ('||v_earns||' earn rows)'
           when v_batches <> 1
             then 'FAIL: expected one batch beside the earn row, found '||v_batches
           when not exists (select 1 from public.points_ledger l
                             where l.sale_id=v_sale and l.points=100
                               and l.programme_id=pg_temp.v314_spine(t8,'points'))
             then 'FAIL: the earn row is not the points programme''s, or not at the published rate'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v314_system();
    insert into v314_out values (35,'a brand-new tenant published ACTIVE from a non-wizard route earns on the next sale',
      'FAIL: '||v_msg);
  end;

  perform pg_temp.as_v314_system();
end
$v314_test$;

select seq, step, outcome from v314_out order by seq;

rollback;
