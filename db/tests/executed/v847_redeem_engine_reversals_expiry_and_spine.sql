-- Rollback-only nestly_v847 acceptance: the redemption engine and the availability core agree
-- about three things they did not agree about before -- a REVERSED claim, a STOPPED programme,
-- and EXPIRED points.
--
-- (A) LATENT, P1 -- a reversed redemption permanently burned a usage-limit slot.
--     app.redeem_reward_core counted prior claims with
--       select count(*) from public.loyalty_redemptions where business_id/client_id/reward_id
--     and app.reward_availability_v432's `used_count` lateral did the same. Neither body
--     contained the string 'loyalty_redemption_reversals'. So a limit-1 gift that was claimed
--     and then REVERSED (points refunded in full by public.reverse_loyalty_redemption) still
--     read `limit_reached` for ever: the customer was refunded and simultaneously locked out of
--     the gift they never received. Latent only because production carries zero reward versions
--     with a usage_limit (measured 2026-09-08), so this suite sets one in its own fixture.
--
-- (B) LIVE, P2 -- a stopped stamps programme still paid out. redeem_reward_core's spine gate
--     read `if v_programme_kind is distinct from 'stamps' and not exists(... spine.active)`,
--     so the stamps kind was exempt and staff_manual_redeem_reward_v404 completed the claim
--     after the owner switched stamps off. nestly_v495 had already withdrawn those gifts from
--     app.reward_availability_v432 and from the customer intent path, and said in its own header
--     "app.redeem_reward_core (the staff-assisted path) is untouched" -- this is that gap.
--     Production carries 22 inactive stamp spines with 5 live gifts on them (2026-09-08).
--     nestly_v478 (an ALREADY-EARNED gift survives its card closing) and nestly_v495 ("nothing
--     is destroyed by a stop ... every gift returns the moment the programme is switched back
--     on") both still hold: assertions 11 and 13 are those two rules, and they pass.
--
-- (C) LIVE, P2 -- expired points were spendable. reward_availability_v432's pot CTE filtered
--     only `pb.remaining > 0`, and redeem_reward_core's pre-flight batch balance, its FEFO drain
--     loop and its post-drain reconcile fence had no expiry filter at all -- while the customer
--     wallet (app.customer_live_loyalty_v384) and the till
--     (public.staff_get_customer_actionable_loyalty_v145) both exclude expired batches with
--     `(expires_at is null or expires_at > <as of>)`. The counter therefore offered and honoured
--     a gift against a wallet reading 0, draining an expired batch.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v847_redeem_engine_reversals_expiry_and_spine.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v847_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v847_out to public;

create or replace function pg_temp.as_v847_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v847_system() to public;

-- The staff principal is the JWT subject, not the database role. Every authorization the
-- redemption engine applies -- app.has_perm, the active staff row, app.can_see_branch -- is
-- derived from auth.uid(), which reads these GUCs. The role is deliberately NOT switched: on
-- production public.redeem_reward_at_context is granted to service_role only (proacl
-- {postgres=X,service_role=X}, read 2026-09-08), so a `set local role authenticated` suite
-- cannot run against prod at all. This file therefore calls app.redeem_reward_core -- the
-- function actually under test, the one public.staff_manual_redeem_reward_v404 calls once per
-- unit -- directly, and runs unchanged in the harness and against production.
create or replace function pg_temp.as_v847_user(p_uid uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','authenticated')::text,true);
end
$$;
grant execute on function pg_temp.as_v847_user(uuid) to public;

-- One append to points_ledger through a route app.loyalty_ledger_write_guard admits from a system
-- principal, plus its matching batch. The batch MUST match the ledger: a pot whose ledger sum and
-- batch remaining disagree is itself a business_pot trigger in app.programme_balance_scope_v312,
-- and every assertion here is written for programme_pot scope.
create or replace function pg_temp.v847_seed_points(
  p_business uuid, p_client uuid, p_programme uuid, p_points integer, p_expires timestamptz
) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid(); v_batch uuid;
begin
  perform app.acquire_loyalty_shared_v480(p_business);
  perform set_config('app.points_ledger_insert_id',v_id::text,true);
  perform set_config('app.points_ledger_write_scope','programme_pot_transfer',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,programme_id)
  values (v_id,p_business,p_client,'adjust',p_points,'v847 seed',null,p_programme);
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
  insert into public.points_batches(business_id,client_id,programme_id,earned,remaining,expires_at)
  values (p_business,p_client,p_programme,p_points,p_points,p_expires)
  returning id into v_batch;
  return v_batch;
end
$$;
grant execute on function pg_temp.v847_seed_points(uuid,uuid,uuid,integer,timestamptz) to public;

-- A whole tenant, ready to trade: approved workspace, paid subscription, owner staff row,
-- default branch, published config version. Same recipe nestly_v815's suite proved on production.
create or replace function pg_temp.v847_seed_firm(
  p_biz uuid, p_owner uuid, p_branch uuid, p_name text, p_kind text, p_stamp_target integer
) returns uuid language plpgsql as $$
declare v_cfg uuid;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v847-owner-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now());

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (p_biz,p_name,'v847-'||substr(p_biz::text,1,8),'fnb','SGD',
          array['dashboard','clients','sales','services','till','loyalty'],'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=p_owner,
         decided_at=clock_timestamp(), decision_reason='v847 rollback fixture',
         updated_at=clock_timestamp()
   where business_id = p_biz;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (p_biz,false)
  on conflict (business_id) do update set workspace_paused=false;
  insert into public.subscriptions(business_id,status,payment_status,current_period_end)
  values (p_biz,'active','paid',now()+interval '30 days')
  on conflict (business_id) do update
    set status='active', payment_status='paid', current_period_end=now()+interval '30 days';
  insert into app.platform_feature_flags(feature_key,enabled)
  values ('customer_wallet',true)
  on conflict (feature_key) do update set enabled = true;

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_biz,p_owner,'owner','V847 Owner',true,'approved');
  insert into public.branches(id,business_id,name,active,is_default)
  values (p_branch,p_biz,'V847 Main',true,true);

  update public.business_programmes set active=(kind = p_kind) where business_id=p_biz;

  insert into public.loyalty_programs(business_id,active,loyalty_model,kind,configuration_status,
                                      stamp_target)
  values (p_biz,true,case when p_kind='stamps' then 'stamps' else 'points_tiers' end,p_kind,
          'published',p_stamp_target)
  on conflict (business_id) do update
    set active=true, loyalty_model=excluded.loyalty_model, kind=excluded.kind,
        configuration_status='published', stamp_target=excluded.stamp_target;

  select id into v_cfg from public.firm_config_versions
   where business_id=p_biz and status='published' order by version_no desc limit 1;
  if v_cfg is null then
    v_cfg := gen_random_uuid();
    insert into public.firm_config_versions(id,business_id,version_no,status,snapshot_hash,published_at)
    select v_cfg,p_biz,coalesce(max(version_no),0)+1,'published',md5('v847-published-'||p_biz::text),now()
      from public.firm_config_versions where business_id=p_biz;
  end if;
  update public.businesses set active_config_version_id=v_cfg where id=p_biz;
  return v_cfg;
end
$$;
grant execute on function pg_temp.v847_seed_firm(uuid,uuid,uuid,text,text,integer) to public;

do $v847_test$
declare
  -- FIRM P: a points firm. (A) usage limits vs reversals, (C) expired points.
  bizp uuid := gen_random_uuid();
  ownerp uuid := gen_random_uuid();
  branchp uuid := gen_random_uuid();
  spine_p uuid; cfgp uuid;
  c_lim uuid := gen_random_uuid();     -- client for the usage-limit story
  c_exp uuid := gen_random_uuid();     -- client whose only points have expired
  gift_lim uuid := gen_random_uuid();  -- 10 points, usage_limit 1
  gift_exp uuid := gen_random_uuid();  -- 10 points, no usage limit
  batch_lim uuid; batch_dead uuid; batch_fresh uuid;

  -- FIRM S: a stamps firm. (B) a stopped programme mints and pays nothing new.
  bizs uuid := gen_random_uuid();
  owners uuid := gen_random_uuid();
  branchs uuid := gen_random_uuid();
  spine_s uuid; cfgs uuid;
  c_st uuid := gen_random_uuid();
  gift_s2 uuid := gen_random_uuid();   -- stamp 2
  gift_s3 uuid := gen_random_uuid();   -- stamp 3
  gift_s5 uuid := gen_random_uuid();   -- stamp 5 == the last slot, closes the card

  v_avail text; v_used integer; v_rem integer; v_scope text; v_wallet integer;
  v_res jsonb; v_red1 uuid; v_red2 uuid; v_err text; v_msg text;
  v_bal integer; v_dead integer; v_fresh integer; v_drains integer; v_n integer;
  v_avail2 text; v_used2 integer; v_err2 text; v_msg2 text;
begin
  perform pg_temp.as_v847_system();

  -- ======================================================================= FIXTURE: points firm
  cfgp := pg_temp.v847_seed_firm(bizp,ownerp,branchp,'V847 Points Firm','points',null);
  select id into spine_p from public.business_programmes where business_id=bizp and kind='points';

  insert into public.clients(id,business_id,full_name,phone)
  values (c_lim,bizp,'V847 Limit Customer','+65 9832 0001'),
         (c_exp,bizp,'V847 Expired Customer','+65 9832 0002');

  batch_lim := pg_temp.v847_seed_points(bizp,c_lim,spine_p,30,now()+interval '365 days');
  -- The only points this customer holds expired YESTERDAY.
  batch_dead := pg_temp.v847_seed_points(bizp,c_exp,spine_p,20,now()-interval '1 day');

  insert into public.loyalty_rewards(id,business_id,name,internal_name,customer_name,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,paused,sort,programme_id)
  values
    (gift_lim,bizp,'V847 One Per Customer','V847 One Per Customer','V847 One Per Customer',
     'manual_item',10,0,0,true,false,1,spine_p),
    (gift_exp,bizp,'V847 Any Number','V847 Any Number','V847 Any Number',
     'manual_item',10,0,0,true,false,2,spine_p);
  insert into public.loyalty_reward_versions(reward_id,business_id,config_version_id,internal_name,
    customer_name,description,fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,
    image_ref,sort,programme_id,usage_limit)
  values
    (gift_lim,bizp,cfgp,'V847 One Per Customer','V847 One Per Customer','limit 1','manual_item',
     10,0,0,null,1,spine_p,1),
    (gift_exp,bizp,cfgp,'V847 Any Number','V847 Any Number','no limit','manual_item',
     10,0,0,null,2,spine_p,null);

  v_scope := app.programme_balance_scope_v312(bizp);
  if v_scope <> 'programme_pot' then
    raise exception 'FIXTURE: the points firm resolves to %, not programme_pot', v_scope;
  end if;

  -- ------------------------------------------------- 1. control: the gift is offered and paid
  select a.availability,a.used_count into v_avail,v_used
    from app.reward_availability_v432(bizp,c_lim) a where a.reward_id=gift_lim;
  perform pg_temp.as_v847_user(ownerp);
  v_err := null; v_msg := null;
  begin
    v_res := app.redeem_reward_core(
               bizp,c_lim,gift_lim,'v847-lim-1-'||replace(gen_random_uuid()::text,'-',''),
               branchp,null,null)::jsonb;
  exception when others then v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v847_system();
  v_red1 := (v_res->>'redemption_id')::uuid;
  select remaining into v_bal from public.points_batches where id=batch_lim;
  if v_avail='available_at_counter' and v_used=0 and v_err is null
     and coalesce(v_res->>'ok','')='true' and v_bal=20 then
    insert into v847_out values (1,'control: a limit-1 gift is offered at used_count 0 and the first claim is paid','PASS');
  else
    insert into v847_out values (1,'control: a limit-1 gift is offered at used_count 0 and the first claim is paid',
      format('FAIL - availability=%s used_count=%s err=%s/%s batch_left=%s (want 20)',
             coalesce(v_avail,'<not listed>'),v_used,coalesce(v_err,'-'),coalesce(v_msg,'-'),v_bal));
  end if;

  -- ------------------------------------------------------------ 2. control: the limit bites
  select a.availability,a.used_count into v_avail,v_used
    from app.reward_availability_v432(bizp,c_lim) a where a.reward_id=gift_lim;
  perform pg_temp.as_v847_user(ownerp);
  v_err := null; v_msg := null;
  begin
    perform app.redeem_reward_core(
              bizp,c_lim,gift_lim,'v847-lim-2-'||replace(gen_random_uuid()::text,'-',''),
              branchp,null,null);
  exception when others then v_err := sqlstate; v_msg := sqlerrm;
  end;
  perform pg_temp.as_v847_system();
  if v_avail='limit_reached' and v_used=1 and v_err='23514'
     and v_msg like '%usage limit reached%' then
    insert into v847_out values (2,'control: a second claim of the same limit-1 gift is refused, and the catalogue says limit_reached','PASS');
  else
    insert into v847_out values (2,'control: a second claim of the same limit-1 gift is refused, and the catalogue says limit_reached',
      format('FAIL - availability=%s used_count=%s err=%s/%s',
             coalesce(v_avail,'<not listed>'),v_used,coalesce(v_err,'-'),coalesce(v_msg,'-')));
  end if;

  -- ------------------------------------------------------- 3. control: the reversal refunds
  perform pg_temp.as_v847_user(ownerp);
  v_err := null; v_msg := null;
  begin
    v_res := public.reverse_loyalty_redemption(
               bizp,v_red1,'v847 acceptance: handed to the wrong customer',
               'v847-rev-1-'||replace(gen_random_uuid()::text,'-',''))::jsonb;
  exception when others then v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v847_system();
  select remaining into v_bal from public.points_batches where id=batch_lim;
  select count(*)::integer into v_n from public.loyalty_redemption_reversals
   where business_id=bizp and redemption_id=v_red1;
  if v_err is null and (v_res->>'restored_points')='10' and v_bal=30 and v_n=1 then
    insert into v847_out values (3,'control: reversing the claim refunds the points in full and records one reversal row','PASS');
  else
    insert into v847_out values (3,'control: reversing the claim refunds the points in full and records one reversal row',
      format('FAIL - err=%s/%s restored=%s batch=%s (want 30) reversal_rows=%s (want 1)',
             coalesce(v_err,'-'),coalesce(v_msg,'-'),coalesce(v_res->>'restored_points','<null>'),
             v_bal,v_n));
  end if;

  -- ----------------------------------- 4. DEFECT A, reader: the reversed claim holds no slot
  select a.availability,a.used_count into v_avail,v_used
    from app.reward_availability_v432(bizp,c_lim) a where a.reward_id=gift_lim;
  if v_avail='available_at_counter' and v_used=0 then
    insert into v847_out values (4,'A/reader: after the reversal the catalogue offers the gift again at used_count 0','PASS');
  else
    insert into v847_out values (4,'A/reader: after the reversal the catalogue offers the gift again at used_count 0',
      format('FAIL - availability=%s used_count=%s; app.reward_availability_v432''s used_count '
             || 'lateral counts loyalty_redemptions without excluding rows that carry a '
             || 'public.loyalty_redemption_reversals row',
             coalesce(v_avail,'<not listed>'),v_used));
  end if;

  -- ---------------------------------- 5. DEFECT A, counter: the refunded customer is not locked out
  perform pg_temp.as_v847_user(ownerp);
  v_err := null; v_msg := null;
  begin
    v_res := app.redeem_reward_core(
               bizp,c_lim,gift_lim,'v847-lim-3-'||replace(gen_random_uuid()::text,'-',''),
               branchp,null,null)::jsonb;
  exception when others then v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v847_system();
  v_red2 := (v_res->>'redemption_id')::uuid;
  select remaining into v_bal from public.points_batches where id=batch_lim;
  if v_err is null and coalesce(v_res->>'ok','')='true' and v_bal=20 then
    insert into v847_out values (5,'A/counter: after the reversal the same gift can be claimed again -- the refund did not burn the slot','PASS');
  else
    insert into v847_out values (5,'A/counter: after the reversal the same gift can be claimed again -- the refund did not burn the slot',
      format('FAIL - err=%s/%s batch=%s (want 20); app.redeem_reward_core counted the reversed '
             || 'claim against usage_limit, so the customer was refunded AND locked out for ever',
             coalesce(v_err,'-'),coalesce(v_msg,'-'),v_bal));
  end if;

  -- ------------------------------------------- 6. sensitivity: a limit is still a limit
  select a.availability,a.used_count into v_avail,v_used
    from app.reward_availability_v432(bizp,c_lim) a where a.reward_id=gift_lim;
  perform pg_temp.as_v847_user(ownerp);
  v_err := null; v_msg := null;
  begin
    perform app.redeem_reward_core(
              bizp,c_lim,gift_lim,'v847-lim-4-'||replace(gen_random_uuid()::text,'-',''),
              branchp,null,null);
  exception when others then v_err := sqlstate; v_msg := sqlerrm;
  end;
  perform pg_temp.as_v847_system();
  if v_avail='limit_reached' and v_used=1 and v_err='23514'
     and v_msg like '%usage limit reached%' then
    insert into v847_out values (6,'A/sensitivity: the un-reversed second claim still fills the slot -- a third is refused and the catalogue says limit_reached','PASS');
  else
    insert into v847_out values (6,'A/sensitivity: the un-reversed second claim still fills the slot -- a third is refused and the catalogue says limit_reached',
      format('FAIL - availability=%s used_count=%s err=%s/%s; the usage limit may have been '
             || 'dropped rather than made reversal-aware',
             coalesce(v_avail,'<not listed>'),v_used,coalesce(v_err,'-'),coalesce(v_msg,'-')));
  end if;

  -- ----------------------------------------- 7. DEFECT C, reader: expired points buy nothing
  v_wallet := (app.customer_live_loyalty_v384(
                 bizp,c_exp,array['dashboard','clients','sales','services','till','loyalty'],now())
               ->>'balance')::integer;
  select a.availability,a.remaining_units into v_avail,v_rem
    from app.reward_availability_v432(bizp,c_exp) a where a.reward_id=gift_exp;
  if v_wallet=0 and v_avail='insufficient_balance' and v_rem=10 then
    insert into v847_out values (7,'C/reader: with only expired points the wallet says 0 and the catalogue agrees -- insufficient_balance','PASS');
  else
    insert into v847_out values (7,'C/reader: with only expired points the wallet says 0 and the catalogue agrees -- insufficient_balance',
      format('FAIL - wallet=%s availability=%s remaining_units=%s; app.reward_availability_v432''s '
             || 'pot CTE filters only pb.remaining > 0 and never asks whether the batch has expired, '
             || 'so it advertised a gift against a wallet reading 0',
             v_wallet,coalesce(v_avail,'<not listed>'),v_rem));
  end if;

  -- --------------------------------------- 8. DEFECT C, counter: expired points are not drained
  perform pg_temp.as_v847_user(ownerp);
  v_err := null; v_msg := null;
  begin
    perform app.redeem_reward_core(
              bizp,c_exp,gift_exp,'v847-exp-1-'||replace(gen_random_uuid()::text,'-',''),
              branchp,null,null);
  exception when others then v_err := sqlstate; v_msg := sqlerrm;
  end;
  perform pg_temp.as_v847_system();
  select remaining into v_dead from public.points_batches where id=batch_dead;
  if v_err is not null and v_msg like '%insufficient proven points%' and v_dead=20 then
    insert into v847_out values (8,'C/counter: a claim funded only by an expired batch is refused and the expired batch is untouched','PASS');
  else
    insert into v847_out values (8,'C/counter: a claim funded only by an expired batch is refused and the expired batch is untouched',
      format('FAIL - err=%s/%s expired_batch=%s (want 20); app.redeem_reward_core''s pre-flight '
             || 'balance and its FEFO drain loop had no expiry filter, so the counter spent points '
             || 'the wallet had already written off',
             coalesce(v_err,'-'),coalesce(v_msg,'-'),v_dead));
  end if;

  -- -------------------------------- 9. C/sensitivity: unexpired points still pay, FEFO intact
  batch_fresh := pg_temp.v847_seed_points(bizp,c_exp,spine_p,10,now()+interval '365 days');
  v_scope := app.programme_balance_scope_v312(bizp);
  if v_scope <> 'programme_pot' then
    raise exception 'FIXTURE: after the fresh batch the points firm resolves to %', v_scope;
  end if;
  select a.availability into v_avail
    from app.reward_availability_v432(bizp,c_exp) a where a.reward_id=gift_exp;
  perform pg_temp.as_v847_user(ownerp);
  v_err := null; v_msg := null;
  begin
    v_res := app.redeem_reward_core(
               bizp,c_exp,gift_exp,'v847-exp-2-'||replace(gen_random_uuid()::text,'-',''),
               branchp,null,null)::jsonb;
  exception when others then v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v847_system();
  select remaining into v_dead  from public.points_batches where id=batch_dead;
  select remaining into v_fresh from public.points_batches where id=batch_fresh;
  select count(*)::integer into v_drains from public.loyalty_redemption_batch_drains
   where redemption_id=(v_res->>'redemption_id')::uuid and points_batch_id=batch_fresh;
  if v_avail='available_at_counter' and v_err is null and coalesce(v_res->>'ok','')='true'
     and v_dead=20 and v_fresh=0 and v_drains=1 then
    insert into v847_out values (9,'C/sensitivity: unexpired points still pay, and FEFO skips the expired batch instead of taking it first','PASS');
  else
    insert into v847_out values (9,'C/sensitivity: unexpired points still pay, and FEFO skips the expired batch instead of taking it first',
      format('FAIL - availability=%s err=%s/%s expired=%s (want 20) fresh=%s (want 0) '
             || 'drains_from_fresh=%s (want 1); the expired batch sorts FIRST under '
             || '"order by expires_at nulls last", so an unfiltered loop takes it before the live one',
             coalesce(v_avail,'<not listed>'),coalesce(v_err,'-'),coalesce(v_msg,'-'),
             v_dead,v_fresh,v_drains));
  end if;

  -- ======================================================================= FIXTURE: stamps firm
  cfgs := pg_temp.v847_seed_firm(bizs,owners,branchs,'V847 Stamp Firm','stamps',5);
  select id into spine_s from public.business_programmes where business_id=bizs and kind='stamps';
  select stamp_target into v_n from public.loyalty_program_versions
   where config_version_id=cfgs and business_id=bizs;
  if v_n is distinct from 5 then
    raise exception 'FIXTURE: the stamps firm''s published version carries stamp_target %', v_n;
  end if;

  insert into public.clients(id,business_id,full_name,phone)
  values (c_st,bizs,'V847 Stamp Customer','+65 9832 0003');
  perform pg_temp.v847_seed_points(bizs,c_st,spine_s,5,null);   -- a full card of 5

  insert into public.loyalty_rewards(id,business_id,name,internal_name,customer_name,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,paused,sort,programme_id)
  values
    (gift_s2,bizs,'V847 Stamp Two','V847 Stamp Two','V847 Stamp Two','manual_item',2,0,0,true,false,1,spine_s),
    (gift_s3,bizs,'V847 Stamp Three','V847 Stamp Three','V847 Stamp Three','manual_item',3,0,0,true,false,2,spine_s),
    (gift_s5,bizs,'V847 Stamp Five','V847 Stamp Five','V847 Stamp Five','manual_item',5,0,0,true,false,3,spine_s);
  insert into public.loyalty_reward_versions(reward_id,business_id,config_version_id,internal_name,
    customer_name,description,fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,
    image_ref,sort,programme_id)
  values
    (gift_s2,bizs,cfgs,'V847 Stamp Two','V847 Stamp Two','slot 2','manual_item',2,0,0,null,1,spine_s),
    (gift_s3,bizs,cfgs,'V847 Stamp Three','V847 Stamp Three','slot 3','manual_item',3,0,0,null,2,spine_s),
    (gift_s5,bizs,cfgs,'V847 Stamp Five','V847 Stamp Five','slot 5 closes the card','manual_item',5,0,0,null,3,spine_s);

  -- ------------------------------- 10. control: a RUNNING stamps programme pays and closes the card
  perform pg_temp.as_v847_user(owners);
  v_err := null; v_msg := null;
  begin
    v_res := app.redeem_reward_core(
               bizs,c_st,gift_s5,'v847-s5-'||replace(gen_random_uuid()::text,'-',''),
               branchs,null,null)::jsonb;
  exception when others then v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v847_system();
  if v_err is null and coalesce(v_res->>'ok','')='true'
     and coalesce(v_res->>'stamp_card_closed','')='true' then
    insert into v847_out values (10,'B/control: a running stamps programme still pays, and the last-slot claim still closes the card','PASS');
  else
    insert into v847_out values (10,'B/control: a running stamps programme still pays, and the last-slot claim still closes the card',
      format('FAIL - err=%s/%s closed=%s',
             coalesce(v_err,'-'),coalesce(v_msg,'-'),coalesce(v_res->>'stamp_card_closed','<null>')));
  end if;

  -- ------------------- 11. nestly_v478 non-regression: an EARNED gift survives the card closing
  perform pg_temp.as_v847_user(owners);
  v_err := null; v_msg := null;
  begin
    v_res := app.redeem_reward_core(
               bizs,c_st,gift_s2,'v847-s2-'||replace(gen_random_uuid()::text,'-',''),
               branchs,null,null)::jsonb;
  exception when others then v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v847_system();
  if v_err is null and coalesce(v_res->>'ok','')='true'
     and coalesce(v_res->>'from_expired_card','')='true' then
    insert into v847_out values (11,'B/nestly_v478: a gift already earned on the closed card is still claimable while the programme runs','PASS');
  else
    insert into v847_out values (11,'B/nestly_v478: a gift already earned on the closed card is still claimable while the programme runs',
      format('FAIL - err=%s/%s from_expired_card=%s; nestly_v478 must not be regressed',
             coalesce(v_err,'-'),coalesce(v_msg,'-'),coalesce(v_res->>'from_expired_card','<null>')));
  end if;

  -- -------------------------------------- 12. DEFECT B: a STOPPED programme pays nothing new
  update public.business_programmes set active=false where id=spine_s;
  select a.availability into v_avail2
    from app.reward_availability_v432(bizs,c_st) a where a.reward_id=gift_s3;
  perform pg_temp.as_v847_user(owners);
  v_err2 := null; v_msg2 := null;
  begin
    perform app.redeem_reward_core(
              bizs,c_st,gift_s3,'v847-s3-off-'||replace(gen_random_uuid()::text,'-',''),
              branchs,null,null);
  exception when others then v_err2 := sqlstate; v_msg2 := sqlerrm;
  end;
  perform pg_temp.as_v847_system();
  if v_avail2 is null and v_err2 is not null and v_msg2 like '%catalog redemption is inactive%' then
    insert into v847_out values (12,'B: with the stamps programme switched off the counter refuses, exactly as the catalogue already does','PASS');
  else
    insert into v847_out values (12,'B: with the stamps programme switched off the counter refuses, exactly as the catalogue already does',
      format('FAIL - catalogue=%s counter_err=%s/%s; app.redeem_reward_core''s spine gate read '
             || '"v_programme_kind is distinct from ''stamps'' and not exists(... spine.active)", '
             || 'so stamps was exempt and a stopped programme still paid out',
             coalesce(v_avail2,'<not listed>'),coalesce(v_err2,'-'),coalesce(v_msg2,'-')));
  end if;

  -- ------------------ 13. nestly_v495 non-regression: a stop destroys nothing; switch it back on
  update public.business_programmes set active=true where id=spine_s;
  perform pg_temp.as_v847_user(owners);
  v_err := null; v_msg := null;
  begin
    v_res := app.redeem_reward_core(
               bizs,c_st,gift_s3,'v847-s3-on-'||replace(gen_random_uuid()::text,'-',''),
               branchs,null,null)::jsonb;
  exception when others then v_err := sqlstate; v_msg := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v847_system();
  if v_err is null and coalesce(v_res->>'ok','')='true'
     and coalesce(v_res->>'from_expired_card','')='true' then
    insert into v847_out values (13,'B/nestly_v495: switching the programme back on returns the gift -- a stop withholds, it does not destroy','PASS');
  else
    insert into v847_out values (13,'B/nestly_v495: switching the programme back on returns the gift -- a stop withholds, it does not destroy',
      format('FAIL - err=%s/%s from_expired_card=%s',
             coalesce(v_err,'-'),coalesce(v_msg,'-'),coalesce(v_res->>'from_expired_card','<null>')));
  end if;
end
$v847_test$;

select seq, step, outcome from v847_out order by seq;

do $v847_gate$
declare v_failed integer;
begin
  select count(*) into v_failed from v847_out where outcome like 'FAIL%';
  if v_failed > 0 then
    raise exception 'nestly_v847 acceptance: % assertion(s) failed', v_failed using errcode = 'XX001';
  end if;
  if (select count(*) from v847_out) <> 13 then
    raise exception 'nestly_v847 acceptance: expected 13 assertions, recorded %',
      (select count(*) from v847_out) using errcode = 'XX001';
  end if;
end
$v847_gate$;

rollback;
