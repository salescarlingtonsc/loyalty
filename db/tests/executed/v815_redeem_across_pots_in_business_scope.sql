-- Rollback-only nestly_v815 acceptance: under business_pot scope the customer may SPEND the
-- whole business pot, and the counter agrees.
--
-- WHAT THE BUG WAS
--   nestly_v813 made the customer's wallet readers scope-aware but deliberately EXEMPTED
--   app.reward_availability_v432, because app.redeem_reward_core drained only the REWARD'S OWN
--   programme's batches and a wider reader would have advertised gifts the counter then refused.
--   The owner has now ruled that under 'business_pot' the whole business pot is spendable, so the
--   reader and the writer move together.
--
--   Measured on production, read-only, inside a rolled-back transaction (2026-09-07), on a firm
--   with a live points pot of 30, a retired pot of 70 and a 50-point gift:
--
--     BEFORE  programme_pot  scope=programme_pot wallet=30  availability(cost 50)=insufficient_balance
--     AFTER   business_pot   scope=business_pot  wallet=100 availability(cost 50)=insufficient_balance
--                                                            remaining_units=20
--
--   One pending row in programme_pot_migrations is the only difference between the two lines. In
--   the AFTER line the wallet tells the customer they hold 100 spendable points while the counter
--   refuses a 50-point gift and asks them for 20 more.
--
-- WHAT THIS SUITE PROVES, against a tenant it builds itself — a LIVE points pot of 70 expiring in
-- 90 days and a RETIRED pot of 30 expiring in 10 days, so the two scopes give different,
-- both-legitimate answers AND the retired pot is the FEFO-oldest:
--    1. programme_pot — the availability core agrees with the wallet on the live pot (70): the
--       90-point gift is refused (20 short) and the 20-point gift is offered.
--    2. programme_pot — redeeming the 20-point gift drains the LIVE batch only. The retired pot is
--       untouched at 30 even though it expires first. This is the byte-for-behaviour assertion:
--       nothing about programme_pot may change.
--    3. programme_pot — reversing it restores the live batch and leaves the retired pot alone.
--    4. business_pot — the availability core now agrees with the wallet on EVERY pot: wallet 100,
--       the 90-point gift is available_at_counter with remaining_units 0. This is the assertion
--       that fails before the migration, at wallet 100 vs insufficient_balance.
--    5. business_pot — redemption drains ACROSS pots, FEFO: the retired pot goes first and in full
--       (30, expiring in 10 days), then 60 from the live pot. One drain row per batch touched.
--    6. business_pot — one provenance row, and every drain row carries it. The evidence shape is
--       unchanged; there are simply more rows when the spend crosses a pot.
--    7. business_pot — the cross-pot redemption is REVERSIBLE and restores BOTH batches. Before
--       this migration public.reverse_loyalty_redemption_v34_base raised 'restored batches span
--       more than one programme or none' and the spend could never be undone.
--    8. Sensitivity control — the fix is not "always sum everything". With the pot migration gone
--       the firm is programme_pot again and the 90-point gift is refused again at 70.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v815_redeem_across_pots_in_business_scope.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v815_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v815_out to public;

create or replace function pg_temp.as_v815_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v815_system() to public;

create or replace function pg_temp.as_v815_user(p_uid uuid, p_role text default 'authenticated')
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
grant execute on function pg_temp.as_v815_user(uuid,text) to public;

-- One append to points_ledger through the single route app.loyalty_ledger_write_guard admits from
-- a system principal, plus its matching batch. The batch MUST match the ledger: a pot whose ledger
-- sum and batch remaining disagree is itself a business_pot trigger in
-- app.programme_balance_scope_v312, which would make the programme_pot half of this suite
-- unreachable.
create or replace function pg_temp.v815_seed_points(
  p_business uuid, p_client uuid, p_programme uuid, p_points integer, p_expires timestamptz
) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid(); v_batch uuid;
begin
  perform app.acquire_loyalty_shared_v480(p_business);
  perform set_config('app.points_ledger_insert_id',v_id::text,true);
  perform set_config('app.points_ledger_write_scope','programme_pot_transfer',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,programme_id)
  values (v_id,p_business,p_client,'adjust',p_points,'v815 seed',null,p_programme);
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
  insert into public.points_batches(business_id,client_id,programme_id,earned,remaining,expires_at)
  values (p_business,p_client,p_programme,p_points,p_points,p_expires)
  returning id into v_batch;
  return v_batch;
end
$$;
grant execute on function pg_temp.v815_seed_points(uuid,uuid,uuid,integer,timestamptz) to public;

do $v815_test$
declare
  biz uuid := gen_random_uuid();
  owner_uid uuid := gen_random_uuid();
  branch uuid := gen_random_uuid();
  cust uuid := gen_random_uuid();
  spine_live uuid;
  spine_retired uuid;
  cfg uuid;
  batch_live uuid;
  batch_retired uuid;
  gift_big uuid := gen_random_uuid();    -- 90 points: unaffordable on the live pot, affordable on the firm's
  gift_small uuid := gen_random_uuid();  -- 20 points: affordable in both scopes
  migration uuid := gen_random_uuid();
  v_slug text;
  v_modules text[];
  v_scope text;
  v_wallet integer;
  v_avail_big text; v_rem_big integer; v_avail_small text;
  v_res jsonb; v_redemption uuid; v_provenance uuid;
  v_live integer; v_retired integer; v_drains integer; v_sum integer;
  v_drain_live integer; v_drain_retired integer; v_carry integer;
  v_err text; v_msg text;
begin
  perform pg_temp.as_v815_system();

  -- ============================================================ FIXTURE: a two-pot points firm
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',owner_uid,'authenticated','authenticated',
          'v815-owner-'||substr(owner_uid::text,1,8)||'@example.test','',now(),now(),now());

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (biz,'V815 Two Pots','v815-'||substr(biz::text,1,8),'fnb','SGD',
          array['dashboard','clients','sales','services','till','loyalty'],'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=owner_uid,
         decided_at=clock_timestamp(), decision_reason='v815 rollback fixture',
         updated_at=clock_timestamp()
   where business_id = biz;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (biz,false)
  on conflict (business_id) do update set workspace_paused=false;
  insert into public.subscriptions(business_id,status,payment_status,current_period_end)
  values (biz,'active','paid',now()+interval '30 days')
  on conflict (business_id) do update
    set status='active', payment_status='paid', current_period_end=now()+interval '30 days';
  insert into app.platform_feature_flags(feature_key,enabled)
  values ('customer_wallet',true)
  on conflict (feature_key) do update set enabled = true;

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (biz,owner_uid,'owner','V815 Owner',true,'approved');
  insert into public.branches(id,business_id,name,active,is_default)
  values (branch,biz,'V815 Main',true,true);

  select id into spine_live from public.business_programmes where business_id=biz and kind='points';
  select id into spine_retired from public.business_programmes where business_id=biz and kind='stamps';
  update public.business_programmes set active=true  where id=spine_live;
  update public.business_programmes set active=false where id=spine_retired;

  insert into public.loyalty_programs(business_id,active,loyalty_model,kind,configuration_status)
  values (biz,true,'points_tiers','points','published')
  on conflict (business_id) do update
    set active=true, loyalty_model='points_tiers', kind='points', configuration_status='published';

  select id into cfg from public.firm_config_versions
   where business_id=biz and status='published' order by version_no desc limit 1;
  if cfg is null then
    cfg := gen_random_uuid();
    insert into public.firm_config_versions(id,business_id,version_no,status,snapshot_hash,published_at)
    select cfg,biz,coalesce(max(version_no),0)+1,'published',md5('v815-published'),now()
      from public.firm_config_versions where business_id=biz;
  end if;
  update public.businesses set active_config_version_id=cfg where id=biz;

  insert into public.clients(id,business_id,full_name,phone)
  values (cust,biz,'V815 Two Pots Customer','+65 9815 0001');

  -- 70 on the live pot expiring in 90 days; 30 on the retired pot expiring in 10 days. The
  -- retired pot is the FEFO-oldest, so "which batches does the drain loop walk" is decidable from
  -- the outcome rather than from reading the code.
  batch_live    := pg_temp.v815_seed_points(biz,cust,spine_live,70,now()+interval '90 days');
  batch_retired := pg_temp.v815_seed_points(biz,cust,spine_retired,30,now()+interval '10 days');

  insert into public.loyalty_rewards(id,business_id,name,internal_name,customer_name,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,paused,sort,programme_id)
  values
    (gift_big,biz,'V815 Big Gift','V815 Big Gift','V815 Big Gift','manual_item',90,0,0,true,false,1,spine_live),
    (gift_small,biz,'V815 Small Gift','V815 Small Gift','V815 Small Gift','manual_item',20,0,0,true,false,2,spine_live);
  insert into public.loyalty_reward_versions(reward_id,business_id,config_version_id,internal_name,
    customer_name,description,fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,
    image_ref,sort,programme_id)
  values
    (gift_big,biz,cfg,'V815 Big Gift','V815 Big Gift','crosses the pots','manual_item',90,0,0,null,1,spine_live),
    (gift_small,biz,cfg,'V815 Small Gift','V815 Small Gift','fits the live pot','manual_item',20,0,0,null,2,spine_live);

  select slug,enabled_modules into v_slug,v_modules from public.businesses where id=biz;

  -- ------------------------------------------------------- 1. programme_pot: reader == wallet
  v_scope := app.programme_balance_scope_v312(biz);
  if v_scope <> 'programme_pot' then
    raise exception 'FIXTURE: the fresh firm resolves to %, not programme_pot', v_scope;
  end if;
  v_wallet := (app.c45_base_actionable_wallet_card(
                 biz,cust,v_slug,'V815 Two Pots','fnb','SGD',v_modules,now())
               ->'loyalty'->>'balance')::integer;
  select a.availability,a.remaining_units into v_avail_big,v_rem_big
    from app.reward_availability_v432(biz,cust) a where a.reward_id=gift_big;
  select a.availability into v_avail_small
    from app.reward_availability_v432(biz,cust) a where a.reward_id=gift_small;
  if v_wallet = 70 and v_avail_big = 'insufficient_balance' and v_rem_big = 20
     and v_avail_small = 'available_at_counter' then
    insert into v815_out values (1,'programme_pot: the counter judges the 90-point gift against the live pot (70), as the wallet does','PASS');
  else
    insert into v815_out values (1,'programme_pot: the counter judges the 90-point gift against the live pot (70), as the wallet does',
      format('FAIL - wallet=%s big=%s remaining_units=%s small=%s',
             v_wallet,coalesce(v_avail_big,'<not listed>'),v_rem_big,coalesce(v_avail_small,'<not listed>')));
  end if;

  -- ------------------------------------------- 2. programme_pot: the retired pot is untouched
  perform pg_temp.as_v815_user(owner_uid);
  v_res := public.redeem_reward_at_context(
             biz,cust,gift_small,'v815-small-'||replace(gen_random_uuid()::text,'-',''),
             branch,null,null)::jsonb;
  perform pg_temp.as_v815_system();
  v_redemption := (v_res->>'redemption_id')::uuid;
  select remaining into v_live    from public.points_batches where id=batch_live;
  select remaining into v_retired from public.points_batches where id=batch_retired;
  select count(*)::integer into v_drains from public.loyalty_redemption_batch_drains
   where redemption_id=v_redemption;
  select coalesce(sum(drained_points),0)::integer into v_drain_live
    from public.loyalty_redemption_batch_drains where redemption_id=v_redemption and points_batch_id=batch_live;
  if coalesce(v_res->>'ok','') = 'true' and v_live = 50 and v_retired = 30
     and v_drains = 1 and v_drain_live = 20 then
    insert into v815_out values (2,'programme_pot: redemption drains the live pot only; the retired pot is untouched even though it expires first','PASS');
  else
    insert into v815_out values (2,'programme_pot: redemption drains the live pot only; the retired pot is untouched even though it expires first',
      format('FAIL - live=%s (want 50) retired=%s (want 30) drain_rows=%s (want 1) drained_from_live=%s (want 20)',
             v_live,v_retired,v_drains,v_drain_live));
  end if;

  -- ------------------------------------------------ 3. programme_pot: the reversal is unchanged
  perform pg_temp.as_v815_user(owner_uid);
  v_res := public.reverse_loyalty_redemption(
             biz,v_redemption,'v815 acceptance: given to the wrong customer',
             'v815-rev-small-'||replace(gen_random_uuid()::text,'-',''))::jsonb;
  perform pg_temp.as_v815_system();
  select remaining into v_live    from public.points_batches where id=batch_live;
  select remaining into v_retired from public.points_batches where id=batch_retired;
  v_scope := app.programme_balance_scope_v312(biz);
  if (v_res->>'restored_points') = '20' and v_live = 70 and v_retired = 30
     and v_scope = 'programme_pot' then
    insert into v815_out values (3,'programme_pot: reversing restores the live pot exactly and leaves the retired pot alone','PASS');
  else
    insert into v815_out values (3,'programme_pot: reversing restores the live pot exactly and leaves the retired pot alone',
      format('FAIL - restored=%s live=%s (want 70) retired=%s (want 30) scope=%s',
             coalesce(v_res->>'restored_points','<null>'),v_live,v_retired,v_scope));
  end if;

  -- ------------------------------------------------------ 4. business_pot: reader == wallet
  -- Put the firm in business_pot the way production does: a pot migration that is pending.
  insert into public.programme_pot_migrations(id,business_id,from_programme_id,to_programme_id,status)
  values (migration,biz,spine_retired,spine_live,'pending');
  v_scope := app.programme_balance_scope_v312(biz);
  if v_scope <> 'business_pot' then
    raise exception 'FIXTURE: with a pending migration the firm resolves to %, not business_pot', v_scope;
  end if;
  v_wallet := (app.c45_base_actionable_wallet_card(
                 biz,cust,v_slug,'V815 Two Pots','fnb','SGD',v_modules,now())
               ->'loyalty'->>'balance')::integer;
  select a.availability,a.remaining_units into v_avail_big,v_rem_big
    from app.reward_availability_v432(biz,cust) a where a.reward_id=gift_big;
  if v_wallet = 100 and v_avail_big = 'available_at_counter' and v_rem_big = 0 then
    insert into v815_out values (4,'business_pot: the counter judges the 90-point gift against every pot (100), as the wallet does','PASS');
  else
    insert into v815_out values (4,'business_pot: the counter judges the 90-point gift against every pot (100), as the wallet does',
      format('FAIL - wallet=%s big=%s remaining_units=%s; the customer holds 100 '
             || '(70 live pot + 30 retired pot) and the wallet already says so',
             v_wallet,coalesce(v_avail_big,'<not listed>'),v_rem_big));
  end if;

  -- --------------------------------------------- 5. business_pot: FEFO across pots, oldest first
  perform pg_temp.as_v815_user(owner_uid);
  v_err := null;
  begin
    v_res := public.redeem_reward_at_context(
               biz,cust,gift_big,'v815-big-'||replace(gen_random_uuid()::text,'-',''),
               branch,null,null)::jsonb;
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v815_system();
  v_redemption := (v_res->>'redemption_id')::uuid;
  select remaining into v_live    from public.points_batches where id=batch_live;
  select remaining into v_retired from public.points_batches where id=batch_retired;
  select count(*)::integer, coalesce(sum(drained_points),0)::integer into v_drains, v_sum
    from public.loyalty_redemption_batch_drains where redemption_id=v_redemption;
  select coalesce(sum(drained_points),0)::integer into v_drain_retired
    from public.loyalty_redemption_batch_drains where redemption_id=v_redemption and points_batch_id=batch_retired;
  select coalesce(sum(drained_points),0)::integer into v_drain_live
    from public.loyalty_redemption_batch_drains where redemption_id=v_redemption and points_batch_id=batch_live;
  if v_err is null and v_drains = 2 and v_sum = 90
     and v_drain_retired = 30 and v_drain_live = 60
     and v_retired = 0 and v_live = 10 then
    insert into v815_out values (5,'business_pot: the drain walks every pot FEFO — the retired pot (expiring first) is emptied before the live one','PASS');
  else
    insert into v815_out values (5,'business_pot: the drain walks every pot FEFO — the retired pot (expiring first) is emptied before the live one',
      format('FAIL - err=%s/%s drain_rows=%s (want 2) drained=%s (want 90) from_retired=%s (want 30) '
             || 'from_live=%s (want 60) retired_left=%s (want 0) live_left=%s (want 10)',
             coalesce(v_err,'-'),coalesce(v_msg,'-'),v_drains,v_sum,v_drain_retired,v_drain_live,
             v_retired,v_live));
  end if;

  -- ----------------------------------------- 6. business_pot: the evidence shape is unchanged
  select id into v_provenance from public.loyalty_redemption_provenance
   where business_id=biz and redemption_id=v_redemption;
  select count(*)::integer into v_carry from public.loyalty_redemption_batch_drains
   where redemption_id=v_redemption and provenance_id=v_provenance;
  select count(*)::integer into v_drains from public.loyalty_redemption_provenance
   where business_id=biz and redemption_id=v_redemption;
  if v_provenance is not null and v_drains = 1 and v_carry = 2
     and (select count(distinct points_batch_id)::integer from public.loyalty_redemption_batch_drains
           where redemption_id=v_redemption) = 2 then
    insert into v815_out values (6,'business_pot: one provenance row, one drain row per batch touched, every drain carrying it','PASS');
  else
    insert into v815_out values (6,'business_pot: one provenance row, one drain row per batch touched, every drain carrying it',
      format('FAIL - provenance=%s provenance_rows=%s drains_carrying_it=%s',
             coalesce(v_provenance::text,'<null>'),v_drains,v_carry));
  end if;

  -- ------------------------------- 7. business_pot: a cross-pot redemption is still reversible
  perform pg_temp.as_v815_user(owner_uid);
  v_err := null;
  begin
    v_res := public.reverse_loyalty_redemption(
               biz,v_redemption,'v815 acceptance: cross-pot reversal must reconstruct the drains',
               'v815-rev-big-'||replace(gen_random_uuid()::text,'-',''))::jsonb;
  exception when others then
    v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v815_system();
  select remaining into v_live    from public.points_batches where id=batch_live;
  select remaining into v_retired from public.points_batches where id=batch_retired;
  select coalesce(sum(points),0)::integer into v_sum from public.points_ledger
   where business_id=biz and client_id=cust;
  if v_err is null and (v_res->>'restored_points') = '90'
     and v_live = 70 and v_retired = 30 and v_sum = 100 then
    insert into v815_out values (7,'business_pot: reversing the cross-pot redemption restores BOTH batches and the whole ledger','PASS');
  else
    insert into v815_out values (7,'business_pot: reversing the cross-pot redemption restores BOTH batches and the whole ledger',
      format('FAIL - err=%s/%s restored=%s live=%s (want 70) retired=%s (want 30) ledger=%s (want 100); '
             || 'before nestly_v815 this raised ''restored batches span more than one programme or none'' '
             || 'and the spend could never be undone',
             coalesce(v_err,'-'),coalesce(v_msg,'-'),coalesce(v_res->>'restored_points','<null>'),
             v_live,v_retired,v_sum));
  end if;

  -- --------------------------------------------------------------- 8. sensitivity control
  delete from public.programme_pot_migrations where id = migration;
  v_scope := app.programme_balance_scope_v312(biz);
  if v_scope <> 'programme_pot' then
    raise exception 'FIXTURE: without the migration the firm resolves to %, not programme_pot', v_scope;
  end if;
  v_wallet := (app.c45_base_actionable_wallet_card(
                 biz,cust,v_slug,'V815 Two Pots','fnb','SGD',v_modules,now())
               ->'loyalty'->>'balance')::integer;
  select a.availability,a.remaining_units into v_avail_big,v_rem_big
    from app.reward_availability_v432(biz,cust) a where a.reward_id=gift_big;
  if v_wallet = 70 and v_avail_big = 'insufficient_balance' and v_rem_big = 20 then
    insert into v815_out values (8,'sensitivity: back in programme_pot scope the counter refuses the 90-point gift again','PASS');
  else
    insert into v815_out values (8,'sensitivity: back in programme_pot scope the counter refuses the 90-point gift again',
      format('FAIL - wallet=%s big=%s remaining_units=%s; the pot rule may have been dropped '
             || 'rather than made scope-aware',
             v_wallet,coalesce(v_avail_big,'<not listed>'),v_rem_big));
  end if;
end
$v815_test$;

select seq, step, outcome from v815_out order by seq;

do $v815_gate$
declare v_failed integer;
begin
  select count(*) into v_failed from v815_out where outcome like 'FAIL%';
  if v_failed > 0 then
    raise exception 'nestly_v815 acceptance: % assertion(s) failed', v_failed using errcode = 'XX001';
  end if;
  if (select count(*) from v815_out) <> 8 then
    raise exception 'nestly_v815 acceptance: expected 8 assertions, recorded %',
      (select count(*) from v815_out) using errcode = 'XX001';
  end if;
end
$v815_gate$;

rollback;
