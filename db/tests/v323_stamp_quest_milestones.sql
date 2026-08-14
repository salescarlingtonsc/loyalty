-- Rollback-only v323 acceptance: THE STAMP CARD IS A QUEST, AND CLAIMING A MILESTONE
-- DOES NOT RESET PROGRESS TOWARD THE NEXT ONE (owner ruling R5, the half v322 reported blocked).
--
-- WHAT v323 CLAIMS, AND THEREFORE WHAT THIS SUITE MUST PROVE:
--   1. A milestone claim is NON-CONSUMING. No points_ledger row, no points_batches update, no
--      loyalty_redemption_batch_drains row. `filled` is exactly what it was before the claim.
--   2. It is still a first-class redemption: one loyalty_redemptions row (points_spent = 0,
--      consumes_balance = false) and one provenance row (points_ledger_id NULL), so the gift stays
--      in Customer 360, in usage_limit enforcement and on the QR path.
--   3. It is recorded once per (client, quest cycle, milestone), twice over: one unique on the
--      SLOT (the product rule) and one on the REWARD (the idempotency key).
--   4. Claiming the FINAL milestone CLOSES the cycle. That is the only moment the quest's stamps
--      are consumed, it happens exactly once, and the card restarts from the remainder.
--   5. A POINTS reward is byte-identical afterwards: FEFO drain, negative ledger row,
--      consumes_balance = true, points_spent = cost_points.
--   6. The money kernel is stronger, not weaker: a points reward is STRUCTURALLY unable to record
--      a free claim (cell 16), and a non-consuming row is structurally unable to claim it spent.
--   7. The W5 earn loop, its (sale, programme) arbiter, the in-trigger parity assertion and both
--      standing detectors are untouched.
--
-- ZERO LIVE TENANTS EXERCISE ANY OF THIS. Production runs no stamps programme, holds no active
-- stamps reward and has stamp_target NULL on every row. A green run against production therefore
-- proves ABSENCE OF REGRESSION, not presence of correctness — so every tenant shape is CREATED
-- INSIDE THIS TRANSACTION:
--
--   S  stamps firm    stamps spine on, stamp_target 8, milestones at 3 / 5 / 8   (the quest)
--   P  points firm    points spine on, one 300-point gift, a real FEFO pot        (the control)
--   N  stamps firm    stamps spine on, stamp_target NULL                          (unconfigured)
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v323_stamp_quest_milestones.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.
--
-- The two-session concurrency proof is NOT here — a single transaction cannot demonstrate two
-- sessions racing. It lives in db/tests/v323_stamp_quest_concurrency.sh. Cell 22 proves the
-- backstop the race falls onto.
--
-- MUTANT MATRIX. Every mutant is an edit to the shipped v323 bytes, and every one of them turns a
-- NAMED cell red. Verified by applying each mutant to the migration and re-running this file.
--   M1  drop the `if v_consumes` wrapper, so a stamp claim drains FEFO      -> cells 3, 4, 5, 14
--   M2  invert the v_programme_kind test (points goes non-consuming)        -> cells 14, 15
--   M3  drop stamp_milestone_claims_slot_uk                                 -> cells 6, 7
--   M4  drop stamp_milestone_claims_reward_uk                               -> cell 8
--   M5  drop cycle_index from both claim uniques                            -> cell 12
--   M6  write the cycle row for every claim, not only the final one         -> cells 4, 9
--   M7  store the CURRENT stamp_target on the cycle row at read time
--       instead of the N in force at closure                                -> cell 13
--   M8  drop the greatest(...,0) clamp from app.stamp_progress_v323         -> cell 21
--   M9  drop loyalty_redemptions_consumption_shape_check                    -> cell 16
--   M10 drop loyalty_redemption_provenance_consumption_shape_check          -> cell 17
--   M11 drop the two append-only triggers on the quest tables               -> cell 18
--   M12 add a write policy to either quest table                            -> cell 19
--   M13 drop the "gift at the last stamp" publish refusal                   -> cell 20
--   M14 drop the already-claimed check from the QR intent minter            -> cell 11
--   M15 let a milestone priced past stamp_target be claimed                 -> cell 10

begin;

create temp table v323_out(seq integer, step text, outcome text) on commit drop;

create or replace function pg_temp.as_v323_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v323_system() to public;

create or replace function pg_temp.as_v323_user(p_uid uuid, p_role text default 'authenticated')
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
grant execute on function pg_temp.as_v323_user(uuid,text) to public;

create or replace function pg_temp.v323_spine(p_business uuid, p_kind text) returns uuid
language sql stable as $$
  select spine.id from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = p_kind
$$;
grant execute on function pg_temp.v323_spine(uuid,text) to public;

-- The projection, read back through the shipped function so the suite never
-- re-implements the arithmetic it is testing.
create or replace function pg_temp.v323_filled(p_business uuid, p_client uuid) returns integer
language sql stable as $$
  select sp.filled from app.stamp_progress_v323(p_business,p_client) sp
$$;
grant execute on function pg_temp.v323_filled(uuid,uuid) to public;

create or replace function pg_temp.v323_cycle(p_business uuid, p_client uuid) returns integer
language sql stable as $$
  select sp.cycle_index from app.stamp_progress_v323(p_business,p_client) sp
$$;
grant execute on function pg_temp.v323_cycle(uuid,uuid) to public;

create or replace function pg_temp.v323_net(p_business uuid, p_client uuid) returns integer
language sql stable as $$
  select sp.net_stamps from app.stamp_progress_v323(p_business,p_client) sp
$$;
grant execute on function pg_temp.v323_net(uuid,uuid) to public;

create or replace function pg_temp.v323_ready(p_business uuid, p_client uuid) returns boolean
language sql stable as $$
  select sp.ready from app.stamp_progress_v323(p_business,p_client) sp
$$;
grant execute on function pg_temp.v323_ready(uuid,uuid) to public;

-- The whole tenant, in the v313/v314/v322 shape, plus the two things a CLAIM
-- needs that a referral test did not: a real branch (the v94 redemption branch
-- trigger refuses a redemption whose eligibility snapshot names none) and a
-- catalogue.
create or replace function pg_temp.v323_tenant(
  p_business uuid, p_owner uuid, p_label text,
  p_spine_kind text, p_per_dollar numeric, p_stamp_per_cents integer, p_stamp_target integer
) returns uuid language plpgsql as $$
declare v_config uuid := gen_random_uuid();
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v323-owner-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (p_business, p_label, lower(p_label)||'-'||substr(p_business::text,1,8),
          'retail','SGD', array['dashboard','clients','sales','loyalty'], 'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v323 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;

  insert into public.staff(business_id,user_id,role,full_name,active)
  values (p_business,p_owner,'owner','V323 Owner',true);

  insert into public.branches(business_id,name,active,is_default)
  values (p_business,'V323 Main',true,true);

  insert into public.firm_config_versions(id,business_id,version_no,status,published_at)
  values (v_config,p_business,1,'published',now());
  update public.businesses set active_config_version_id=v_config where id=p_business;

  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,redeem_points,
    reward_credit_cents,tier_basis,expiry_mode,expiry_days,earn_points_per_dollar,
    stamp_target,stamp_per_cents,current_config_version_id)
  values (p_business,'points',true,case when p_spine_kind='stamps' then 'stamps' else 'points_tiers' end,
          'published',100,500,'visits','none',null,p_per_dollar,
          p_stamp_target,p_stamp_per_cents,v_config);

  insert into public.loyalty_program_versions(
    business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,
    expiry_mode,expiry_days)
  values (p_business,v_config,'points',
          case when p_spine_kind='stamps' then 'stamps' else 'points_tiers' end,
          true,p_per_dollar,100,500,p_stamp_target,p_stamp_per_cents,'visits','none',null);

  -- Exactly one accruing programme, so this firm is legal under the R2
  -- exclusivity v322 installed at public.set_programmes_v314.
  update public.business_programmes set active=false where business_id=p_business;
  update public.business_programmes set active=true, activated_at=now()
   where business_id=p_business and kind=p_spine_kind;

  return v_config;
end
$$;
grant execute on function pg_temp.v323_tenant(uuid,uuid,text,text,numeric,integer,integer) to public;

-- A milestone (or an ordinary gift) — an ordinary catalogue reward whose
-- cost_points IS its position on the card, priced in the named programme. This
-- is R5's shipped authoring shape, not a test-only construct.
create or replace function pg_temp.v323_reward(
  p_business uuid, p_config uuid, p_programme uuid, p_name text, p_cost integer
) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into public.loyalty_rewards(
    id,business_id,programme_id,name,internal_name,customer_name,fulfillment_kind,
    cost_points,credit_cents,estimated_cost_cents,active,sort,current_config_version_id)
  values (v_id,p_business,p_programme,p_name,p_name,p_name,'manual_item',
          p_cost,0,0,true,p_cost,p_config);
  insert into public.loyalty_reward_versions(
    reward_id,business_id,config_version_id,programme_id,internal_name,customer_name,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,sort)
  values (v_id,p_business,p_config,p_programme,p_name,p_name,
          'manual_item',p_cost,0,0,true,p_cost);
  return v_id;
end
$$;
grant execute on function pg_temp.v323_reward(uuid,uuid,uuid,text,integer) to public;

create or replace function pg_temp.v323_sale(
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
grant execute on function pg_temp.v323_sale(uuid,uuid,uuid,integer) to public;

do $v323_test$
declare
  bS uuid := gen_random_uuid(); bP uuid := gen_random_uuid(); bN uuid := gen_random_uuid();
  oS uuid := gen_random_uuid(); oP uuid := gen_random_uuid(); oN uuid := gen_random_uuid();
  cS uuid := gen_random_uuid(); cS2 uuid := gen_random_uuid();
  cP uuid := gen_random_uuid(); cN uuid := gen_random_uuid();
  cfgS uuid; cfgP uuid; cfgN uuid;
  brS uuid; brP uuid; brN uuid;
  spineS uuid; spineP uuid; spineN uuid;
  m3 uuid; m5 uuid; m8 uuid; m3b uuid; past uuid; giftP uuid; mN uuid;
  custUser uuid := gen_random_uuid(); custIdent uuid := gen_random_uuid();
  v_draft uuid;
  v_msg text; v_code text; v_rows integer; v_int integer; v_json jsonb;
  v_filled integer; v_net integer; v_cycle integer; v_before integer;
  v_led integer; v_bat integer; v_drain integer; v_red uuid;
begin
  perform pg_temp.as_v323_system();

  cfgS := pg_temp.v323_tenant(bS,oS,'V323 Quest','stamps',1,500,8);
  cfgP := pg_temp.v323_tenant(bP,oP,'V323 Points','points',1,500,null);
  cfgN := pg_temp.v323_tenant(bN,oN,'V323 Unset','stamps',1,500,null);
  select id into brS from public.branches where business_id=bS;
  select id into brP from public.branches where business_id=bP;
  select id into brN from public.branches where business_id=bN;
  spineS := pg_temp.v323_spine(bS,'stamps');
  spineP := pg_temp.v323_spine(bP,'points');
  spineN := pg_temp.v323_spine(bN,'stamps');

  insert into public.clients(id,business_id,full_name,phone) values
    (cS,bS,'Quest Customer','82000001'),(cS2,bS,'Quest Customer B','82000002'),
    (cP,bP,'Points Customer','82000003'),(cN,bN,'Unset Customer','82000004');

  -- THE QUEST: 3 -> 5 -> 8, exactly the owner's own example, and stamp_target
  -- (8) is the last rung, which is what the v322 wizard derives.
  m3 := pg_temp.v323_reward(bS,cfgS,spineS,'Free drink',3);
  m5 := pg_temp.v323_reward(bS,cfgS,spineS,'A pastry',5);
  m8 := pg_temp.v323_reward(bS,cfgS,spineS,'Free haircut',8);
  m3b:= pg_temp.v323_reward(bS,cfgS,spineS,'Free drink (swapped)',3);
  past:= pg_temp.v323_reward(bS,cfgS,spineS,'Past the end',9);
  giftP := pg_temp.v323_reward(bP,cfgP,spineP,'300pt gift',300);
  mN := pg_temp.v323_reward(bN,cfgN,spineN,'Unset gift',4);

  -- Six stamps at $5 a stamp, earned through the REAL earn path, so the W5 loop
  -- and its ledger/batch parity assertion are exercised rather than bypassed.
  perform pg_temp.v323_sale(bS,cS,cfgS,3000);
  -- 400 points for the control firm, enough for the 300-point gift with change.
  perform pg_temp.v323_sale(bP,cP,cfgP,40000);
  perform pg_temp.v323_sale(bN,cN,cfgN,3000);

  -- =========================================================================
  -- CELL 1. app.stamp_progress_v323 returns ZERO ROWS at a firm with no stamps
  --   spine. Every caller checks `if not found`; a reader that invented a row
  --   here would give a points firm a phantom card.
  -- =========================================================================
  begin
    select count(*) into v_rows from app.stamp_progress_v323(bP,cP);
    insert into v323_out values (1,'the projection returns zero rows at a firm with no stamp card',
      case when v_rows <> 0 then 'FAIL: got '||v_rows||' row(s) for a points-only firm'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (1,'the projection returns zero rows at a firm with no stamp card','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 2. The opening projection. Six stamps earned, nothing closed.
  -- =========================================================================
  begin
    insert into v323_out values (2,'a fresh card projects filled=6 of 8, cycle 0, nothing closed',
      case when pg_temp.v323_filled(bS,cS) <> 6
             then 'FAIL: filled is '||coalesce(pg_temp.v323_filled(bS,cS)::text,'null')||', expected 6'
           when pg_temp.v323_net(bS,cS) <> 6 then 'FAIL: net_stamps is not 6'
           when pg_temp.v323_cycle(bS,cS) <> 0 then 'FAIL: cycle_index is not 0'
           when pg_temp.v323_ready(bS,cS) then 'FAIL: a 6/8 card reports ready'
           when (select sp.slots from app.stamp_progress_v323(bS,cS) sp) <> 8
             then 'FAIL: slots is not the authored stamp_target'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (2,'a fresh card projects filled=6 of 8, cycle 0, nothing closed','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 3. THE RULING ITSELF. Claim the 3-stamp milestone with six stamps on
  --   the card. Nothing is consumed: the ledger gains no row, no batch loses a
  --   point, and `filled` is STILL 6 — so the 5-stamp milestone did not move.
  --   Mutant M1 (remove the `if v_consumes` wrapper) turns this red.
  -- =========================================================================
  begin
    v_before := pg_temp.v323_filled(bS,cS);
    select count(*) into v_led from public.points_ledger l
     where l.business_id=bS and l.client_id=cS;
    select coalesce(sum(b.remaining),0) into v_bat from public.points_batches b
     where b.business_id=bS and b.client_id=cS;
    perform pg_temp.as_v323_user(oS);
    perform app.redeem_reward_core(bS,cS,m3,'v323-claim-slot3',brS,null,null);
    perform pg_temp.as_v323_system();
    select count(*) into v_rows from public.points_ledger l
     where l.business_id=bS and l.client_id=cS;
    select coalesce(sum(b.remaining),0) into v_int from public.points_batches b
     where b.business_id=bS and b.client_id=cS;
    insert into v323_out values (3,'claiming the 3-stamp milestone consumes NOTHING and leaves the card at 6',
      case when v_rows <> v_led
             then 'FAIL: the ledger gained '||(v_rows-v_led)||' row(s); a milestone claim must write none'
           when v_int <> v_bat
             then 'FAIL: batch remaining moved from '||v_bat||' to '||v_int||'; FEFO drained a stamp card'
           when pg_temp.v323_filled(bS,cS) <> v_before
             then 'FAIL: filled moved from '||v_before||' to '||pg_temp.v323_filled(bS,cS)
           when (5 - pg_temp.v323_filled(bS,cS)) <> (5 - v_before)
             then 'FAIL: the distance to the 5-stamp milestone changed'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (3,'claiming the 3-stamp milestone consumes NOTHING and leaves the card at 6','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 4. …and it is still a FIRST-CLASS REDEMPTION. One loyalty_redemptions
  --   row with points_spent = 0 / consumes_balance = false, one provenance row
  --   with points_ledger_id NULL, one claim row that is not final, ZERO cycle
  --   rows and ZERO batch drains. This is what keeps the gift in Customer 360,
  --   in usage_limit enforcement and on the QR path.
  --   Mutants M1 and M6 both turn this red.
  -- =========================================================================
  begin
    select r.id into v_red from public.loyalty_redemptions r
     where r.business_id=bS and r.client_id=cS and r.reward_id=m3;
    select count(*) into v_drain from public.loyalty_redemption_batch_drains d
     where d.business_id=bS and d.redemption_id=v_red;
    insert into v323_out values (4,'the claim is recorded as a redemption that took nothing',
      case when v_red is null then 'FAIL: no loyalty_redemptions row was written'
           when (select points_spent from public.loyalty_redemptions where id=v_red) <> 0
             then 'FAIL: points_spent is not 0'
           when (select consumes_balance from public.loyalty_redemptions where id=v_red) is not false
             then 'FAIL: consumes_balance is not false'
           when not exists (select 1 from public.loyalty_redemption_provenance p
                             where p.redemption_id=v_red and p.points_ledger_id is null
                               and p.consumes_balance is false)
             then 'FAIL: the provenance row is missing or still names a ledger row'
           when v_drain <> 0 then 'FAIL: '||v_drain||' batch drain row(s) were written'
           when not exists (select 1 from public.stamp_milestone_claims c
                             where c.redemption_id=v_red and c.slot_position=3
                               and c.cycle_index=0 and c.is_final is false)
             then 'FAIL: the milestone claim row is missing or misshapen'
           when (select count(*) from public.stamp_cycles sc
                  where sc.business_id=bS and sc.client_id=cS) <> 0
             then 'FAIL: a non-final claim closed a cycle'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (4,'the claim is recorded as a redemption that took nothing','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 5. The result envelope tells the counter the truth.
  -- =========================================================================
  begin
    perform pg_temp.as_v323_user(oS);
    v_json := (select o.result from public.loyalty_operations o
                where o.business_id=bS and o.idempotency_key='v323-claim-slot3');
    perform pg_temp.as_v323_system();
    insert into v323_out values (5,'the claim result reports points_spent 0 and the quest facts',
      case when v_json is null then 'FAIL: no completed operation result was stored'
           when (v_json->>'points_spent') <> '0' then 'FAIL: points_spent is '||(v_json->>'points_spent')
           when (v_json->>'consumes_balance') <> 'false' then 'FAIL: consumes_balance is not false'
           when (v_json->>'stamp_slot') <> '3' then 'FAIL: stamp_slot is not 3'
           when (v_json->>'stamp_cycle_index') <> '0' then 'FAIL: stamp_cycle_index is not 0'
           when (v_json->>'stamp_card_closed') <> 'false' then 'FAIL: a mid-card claim reported a closed card'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (5,'the claim result reports points_spent 0 and the quest facts','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 6. The same milestone cannot be claimed twice on one card.
  --   Mutant M3 (drop the slot unique) turns this red.
  -- =========================================================================
  begin
    perform pg_temp.as_v323_user(oS);
    begin
      perform app.redeem_reward_core(bS,cS,m3,'v323-claim-slot3-again',brS,null,null);
      perform pg_temp.as_v323_system();
      insert into v323_out values (6,'a milestone cannot be claimed twice on one card',
        'FAIL: the second claim succeeded');
    exception when others then
      get stacked diagnostics v_msg = message_text, v_code = returned_sqlstate;
      perform pg_temp.as_v323_system();
      insert into v323_out values (6,'a milestone cannot be claimed twice on one card',
        case when v_code = '23505'
              and v_msg = 'this stamp gift has already been claimed on this card' then 'PASS'
             else 'FAIL: refused with '||v_code||' / '||v_msg end);
    end;
  end;

  -- =========================================================================
  -- CELL 7. A DIFFERENT gift authored at the SAME slot is also blocked — the
  --   product rule is one gift per milestone per card, not one per reward.
  --   Mutant M3 turns this red (the reward unique alone would let it through).
  -- =========================================================================
  begin
    perform pg_temp.as_v323_user(oS);
    begin
      perform app.redeem_reward_core(bS,cS,m3b,'v323-claim-slot3-swap',brS,null,null);
      perform pg_temp.as_v323_system();
      insert into v323_out values (7,'a swapped gift at the same slot is one milestone, not two',
        'FAIL: a second gift at slot 3 was claimable on the same card');
    exception when others then
      get stacked diagnostics v_msg = message_text, v_code = returned_sqlstate;
      perform pg_temp.as_v323_system();
      insert into v323_out values (7,'a swapped gift at the same slot is one milestone, not two',
        case when v_code='23505' then 'PASS' else 'FAIL: refused with '||v_code||' / '||v_msg end);
    end;
  end;

  -- =========================================================================
  -- CELL 8. Moving the SAME gift to another slot mid-cycle does not make it
  --   claimable again. Mutant M4 (drop the reward unique) turns this red.
  -- =========================================================================
  begin
    -- Slot 4, not 9: the move must be to a rung the customer CAN afford, or the
    -- 'not enough stamps yet' refusal would fire first and this cell would pass
    -- without ever reaching the unique it exists to prove.
    update public.loyalty_reward_versions set cost_points=4 where reward_id=m3 and business_id=bS;
    update public.loyalty_rewards set cost_points=4 where id=m3;
    perform pg_temp.as_v323_user(oS);
    begin
      perform app.redeem_reward_core(bS,cS,m3,'v323-claim-slot3-moved',brS,null,null);
      perform pg_temp.as_v323_system();
      insert into v323_out values (8,'moving a claimed gift to a new slot does not re-open it this card',
        'FAIL: the same gift was claimed twice on one card');
    exception when others then
      get stacked diagnostics v_msg = message_text, v_code = returned_sqlstate;
      perform pg_temp.as_v323_system();
      insert into v323_out values (8,'moving a claimed gift to a new slot does not re-open it this card',
        -- 23505 is the intended refusal. A 'not enough stamps yet' check_violation would mean the
        -- move, not the unique, did the work, which is not the guarantee being claimed here.
        case when v_code='23505' then 'PASS' else 'FAIL: refused with '||v_code||' / '||v_msg end);
    end;
    update public.loyalty_reward_versions set cost_points=3 where reward_id=m3 and business_id=bS;
    update public.loyalty_rewards set cost_points=3 where id=m3;
  end;

  -- =========================================================================
  -- CELL 9. A second, non-final milestone. Still nothing consumed.
  -- =========================================================================
  begin
    v_before := pg_temp.v323_filled(bS,cS);
    perform pg_temp.as_v323_user(oS);
    perform app.redeem_reward_core(bS,cS,m5,'v323-claim-slot5',brS,null,null);
    perform pg_temp.as_v323_system();
    insert into v323_out values (9,'a second milestone claim also consumes nothing and closes nothing',
      case when pg_temp.v323_filled(bS,cS) <> v_before
             then 'FAIL: filled moved from '||v_before||' to '||pg_temp.v323_filled(bS,cS)
           when (select count(*) from public.stamp_cycles where business_id=bS and client_id=cS) <> 0
             then 'FAIL: a mid-card claim closed a cycle'
           when (select count(*) from public.stamp_milestone_claims
                  where business_id=bS and client_id=cS and cycle_index=0) <> 2
             then 'FAIL: expected exactly two claims on this card'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (9,'a second milestone claim also consumes nothing and closes nothing','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 10. A gift priced past the end of the card is refused at the claim,
  --   defensively, even though publish now refuses to create one.
  --   Mutant M15 turns this red.
  -- =========================================================================
  begin
    perform pg_temp.as_v323_user(oS);
    begin
      perform app.redeem_reward_core(bS,cS,past,'v323-claim-past-end',brS,null,null);
      perform pg_temp.as_v323_system();
      insert into v323_out values (10,'a gift past the last stamp cannot be claimed',
        'FAIL: a gift at slot 9 was claimed on an 8-stamp card');
    exception when others then
      get stacked diagnostics v_msg = message_text, v_code = returned_sqlstate;
      perform pg_temp.as_v323_system();
      insert into v323_out values (10,'a gift past the last stamp cannot be claimed',
        case when v_msg = 'this gift sits past the end of the stamp card' then 'PASS'
             else 'FAIL: refused with '||v_code||' / '||v_msg end);
    end;
  end;

  -- =========================================================================
  -- CELL 11. Not enough stamps yet, and an unconfigured card. Two refusals
  --   that must not be confused with each other.
  -- =========================================================================
  begin
    perform pg_temp.as_v323_user(oS);
    v_code := null;
    begin
      perform app.redeem_reward_core(bS,cS2,m5,'v323-claim-no-stamps',brS,null,null);
    exception when others then
      get stacked diagnostics v_msg = message_text;
      v_code := v_msg;
    end;
    perform pg_temp.as_v323_user(oN);
    v_msg := null;
    begin
      perform app.redeem_reward_core(bN,cN,mN,'v323-claim-unset-card',brN,null,null);
    exception when others then
      get stacked diagnostics v_msg = message_text;
    end;
    perform pg_temp.as_v323_system();
    insert into v323_out values (11,'an empty card and an unconfigured card refuse differently',
      case when v_code is distinct from 'not enough stamps yet'
             then 'FAIL: a customer with no stamps got '||coalesce(v_code,'no refusal at all')
           when v_msg is distinct from 'this stamp card has no length set'
             then 'FAIL: a card with no length got '||coalesce(v_msg,'no refusal at all')
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (11,'an empty card and an unconfigured card refuse differently','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 12. THE CLOSURE. Four more stamps take the card to 10. Claiming the
  --   FINAL milestone (slot 8 = stamp_target) closes cycle 0: ONE stamp_cycles
  --   row with slots = 8, cycle_index 0 -> 1, filled 10 -> 2 (the remainder
  --   carries), and net_stamps UNCHANGED at 10 — the ledger never moved.
  --   Then slot 3 is claimable AGAIN on the new card.
  --   Mutant M5 (uniques without cycle_index) turns the second half red.
  -- =========================================================================
  begin
    perform pg_temp.v323_sale(bS,cS,cfgS,2000);
    v_net := pg_temp.v323_net(bS,cS);
    perform pg_temp.as_v323_user(oS);
    perform app.redeem_reward_core(bS,cS,m8,'v323-claim-final',brS,null,null);
    perform pg_temp.as_v323_system();
    v_filled := pg_temp.v323_filled(bS,cS);
    v_cycle  := pg_temp.v323_cycle(bS,cS);
    select count(*) into v_rows from public.stamp_cycles where business_id=bS and client_id=cS;
    insert into v323_out values (12,'the final milestone closes the cycle and the card restarts from the remainder',
      case when v_net <> 10 then 'FAIL: the card should hold 10 stamps before the final claim, holds '||v_net
           when v_rows <> 1 then 'FAIL: expected exactly one closed cycle, found '||v_rows
           when (select slots from public.stamp_cycles where business_id=bS and client_id=cS) <> 8
             then 'FAIL: the closed cycle did not record the 8 slots in force'
           when v_cycle <> 1 then 'FAIL: cycle_index is '||v_cycle||', expected 1'
           when v_filled <> 2 then 'FAIL: filled is '||v_filled||', expected the remainder 2'
           when pg_temp.v323_net(bS,cS) <> 10
             then 'FAIL: net_stamps changed at closure; the ledger must not move'
           when exists (select 1 from public.points_ledger l
                         where l.business_id=bS and l.client_id=cS and l.entry_type='redeem')
             then 'FAIL: closure wrote a redeem ledger row'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (12,'the final milestone closes the cycle and the card restarts from the remainder','FAIL: '||v_msg);
  end;

  begin
    -- Two more stamps so the new card can reach slot 3, then claim it again.
    perform pg_temp.v323_sale(bS,cS,cfgS,1000);
    perform pg_temp.as_v323_user(oS);
    perform app.redeem_reward_core(bS,cS,m3,'v323-claim-slot3-cycle1',brS,null,null);
    perform pg_temp.as_v323_system();
    insert into v323_out values (13,'a milestone is claimable again on the NEXT card',
      case when (select count(*) from public.stamp_milestone_claims
                  where business_id=bS and client_id=cS and reward_id=m3) <> 2
             then 'FAIL: the milestone was not claimable on the new card'
           when (select count(*) from public.stamp_milestone_claims
                  where business_id=bS and client_id=cS and cycle_index=1) <> 1
             then 'FAIL: the new claim did not land in cycle 1'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (13,'a milestone is claimable again on the NEXT card','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 14. Editing the card's length moves only the CURRENT card. A closed
  --   cycle keeps the N it was closed with, so a customer never loses a card
  --   they already completed. Mutant M7 turns this red.
  -- =========================================================================
  begin
    v_before := pg_temp.v323_filled(bS,cS);           -- 4 on the new card
    update public.loyalty_programs set stamp_target=10 where business_id=bS;
    v_int := case when pg_temp.v323_ready(bS,cS) then 1 else 0 end;
    update public.loyalty_programs set stamp_target=3 where business_id=bS;
    insert into v323_out values (14,'editing the card length moves only the current card',
      case when (select slots from public.stamp_cycles where business_id=bS and client_id=cS) <> 8
             then 'FAIL: the closed cycle''s slots followed the edit'
           when v_int <> 0 then 'FAIL: a '||v_before||'/10 card reported ready'
           when not pg_temp.v323_ready(bS,cS)
             then 'FAIL: lowering the target to 3 did not make a '||v_before||'-stamp card ready'
           when (select greatest(sp.filled-sp.slots,0) from app.stamp_progress_v323(bS,cS) sp)
                <> (v_before-3)
             then 'FAIL: the carried figure is wrong after lowering the target'
           when pg_temp.v323_cycle(bS,cS) <> 1
             then 'FAIL: editing the target moved a historical cycle boundary'
           else 'PASS' end);
    update public.loyalty_programs set stamp_target=8 where business_id=bS;
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    update public.loyalty_programs set stamp_target=8 where business_id=bS;
    insert into v323_out values (14,'editing the card length moves only the current card','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 15. THE CONTROL. A POINTS reward is byte-identical after v323: it
  --   still drains FEFO, still writes the negative ledger row, and records
  --   consumes_balance = true with points_spent = cost_points.
  --   Mutant M2 (invert the kind test) turns this red.
  -- =========================================================================
  begin
    select coalesce(sum(b.remaining),0) into v_bat from public.points_batches b
     where b.business_id=bP and b.client_id=cP;
    perform pg_temp.as_v323_user(oP);
    perform app.redeem_reward_core(bP,cP,giftP,'v323-points-claim',brP,null,null);
    perform pg_temp.as_v323_system();
    select r.id into v_red from public.loyalty_redemptions r
     where r.business_id=bP and r.client_id=cP and r.reward_id=giftP;
    select coalesce(sum(b.remaining),0) into v_int from public.points_batches b
     where b.business_id=bP and b.client_id=cP;
    select count(*) into v_drain from public.loyalty_redemption_batch_drains d
     where d.redemption_id=v_red;
    insert into v323_out values (15,'a POINTS reward still drains FEFO and records a consuming redemption',
      case when v_red is null then 'FAIL: no redemption row'
           when (select points_spent from public.loyalty_redemptions where id=v_red) <> 300
             then 'FAIL: points_spent is not the reward cost'
           when (select consumes_balance from public.loyalty_redemptions where id=v_red) is not true
             then 'FAIL: consumes_balance is not true for a points reward'
           when v_int <> v_bat - 300
             then 'FAIL: batch remaining went '||v_bat||' -> '||v_int||', expected a 300 drain'
           when v_drain < 1 then 'FAIL: no batch drain evidence was written'
           when not exists (select 1 from public.points_ledger l
                             where l.business_id=bP and l.client_id=cP
                               and l.entry_type='redeem' and l.points = -300
                               and l.programme_id = spineP)
             then 'FAIL: the negative ledger row is missing or untagged'
           when not exists (select 1 from public.loyalty_redemption_provenance p
                             where p.redemption_id=v_red and p.points_ledger_id is not null
                               and p.consumes_balance is true)
             then 'FAIL: the provenance row lost its ledger id'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (15,'a POINTS reward still drains FEFO and records a consuming redemption','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 16. THE PAIRED GUARD, THE POINTS DIRECTION. An ordinary points reward
  --   is STRUCTURALLY unable to record a free claim: consumes_balance = true
  --   with points_spent = 0 is a check_violation. This is the cell that shows
  --   the relaxation from (> 0) to (>= 0) made the invariant stronger, not
  --   weaker. Mutant M9 turns it red.
  -- =========================================================================
  begin
    begin
      insert into public.loyalty_redemptions(
        business_id,client_id,reward_id,reward_name,points_spent,credit_cents,
        consumes_balance,config_version_id)
      values (bP,cP,giftP,'illegal free claim',0,0,true,cfgP);
      insert into v323_out values (16,'a consuming redemption cannot record a zero spend',
        'FAIL: points_spent 0 with consumes_balance true was accepted');
    exception when check_violation then
      insert into v323_out values (16,'a consuming redemption cannot record a zero spend','PASS');
    end;
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (16,'a consuming redemption cannot record a zero spend','FAIL: '||v_msg);
  end;

  begin
    begin
      insert into public.loyalty_redemptions(
        business_id,client_id,reward_id,reward_name,points_spent,credit_cents,
        consumes_balance,config_version_id)
      values (bP,cP,giftP,'illegal paid free claim',300,0,false,cfgP);
      insert into v323_out values (17,'a non-consuming redemption cannot claim it spent anything',
        'FAIL: points_spent 300 with consumes_balance false was accepted');
    exception when check_violation then
      insert into v323_out values (17,'a non-consuming redemption cannot claim it spent anything','PASS');
    end;
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (17,'a non-consuming redemption cannot claim it spent anything','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 18. The provenance half of the same guard. Mutant M10 turns it red.
  -- =========================================================================
  begin
    begin
      insert into public.loyalty_redemption_provenance(
        business_id,client_id,operation_id,redemption_id,points_ledger_id,
        config_version_id,consumes_balance)
      select bP,cP,gen_random_uuid(),v_red,null,cfgP,true;
      insert into v323_out values (18,'a consuming provenance row cannot omit its ledger id',
        'FAIL: consumes_balance true with a null points_ledger_id was accepted');
    exception when check_violation then
      insert into v323_out values (18,'a consuming provenance row cannot omit its ledger id','PASS');
    when others then
      get stacked diagnostics v_msg = message_text, v_code = returned_sqlstate;
      -- Any refusal short of the shape CHECK (an FK, the operation unique) would
      -- leave the guarantee unproven, so it is reported rather than accepted.
      insert into v323_out values (18,'a consuming provenance row cannot omit its ledger id',
        'FAIL: refused by '||v_code||' / '||v_msg||' rather than the shape CHECK');
    end;
  end;

  -- =========================================================================
  -- CELL 19. Both quest tables are append-only. Mutant M11 turns it red.
  -- =========================================================================
  begin
    v_code := null; v_msg := null;
    begin
      update public.stamp_cycles set slots=99 where business_id=bS;
    exception when others then get stacked diagnostics v_code = returned_sqlstate;
    end;
    begin
      delete from public.stamp_milestone_claims where business_id=bS;
    exception when others then get stacked diagnostics v_msg = returned_sqlstate;
    end;
    insert into v323_out values (19,'the quest tables are append-only',
      case when v_code is distinct from '23001'   -- restrict_violation
             then 'FAIL: updating a closed cycle was refused with '||coalesce(v_code,'nothing')
           when v_msg is distinct from '23001'
             then 'FAIL: deleting a claim was refused with '||coalesce(v_msg,'nothing')
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (19,'the quest tables are append-only','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 20. Tenant isolation and the no-write rule, tested AS THE REAL ROLE.
  --   Mutant M12 turns it red.
  -- =========================================================================
  begin
    perform pg_temp.as_v323_user(oP);              -- a member of the POINTS firm
    select count(*) into v_rows from public.stamp_cycles where business_id=bS;
    v_code := null;
    begin
      insert into public.stamp_cycles(business_id,programme_id,client_id,cycle_index,slots,origin)
      values (bP,spineP,cP,0,8,'migration');
      v_code := 'accepted';
    exception when others then get stacked diagnostics v_code = returned_sqlstate;
    end;
    perform pg_temp.as_v323_system();
    insert into v323_out values (20,'as authenticated, another firm''s cycles are invisible and nobody may insert',
      case when v_rows <> 0 then 'FAIL: firm P read '||v_rows||' of firm S''s closed cycles'
           when v_code = 'accepted' then 'FAIL: an authenticated role inserted a stamp cycle'
           when v_code is distinct from '42501'
             then 'FAIL: the insert was refused with '||coalesce(v_code,'nothing')||', expected 42501'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (20,'as authenticated, another firm''s cycles are invisible and nobody may insert','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 21. The clamp, exercised for real rather than asserted vacuously. When
  --   the stamps pot is MIGRATED AWAY, public.set_programmes_v314 writes an
  --   offsetting transfer on the FROM programme: net_stamps falls to zero (or
  --   below) while stamp_cycles still holds the closed cards, so net - closed
  --   goes NEGATIVE. The shape is reproduced here on a customer whose closed
  --   cycles exceed their lifetime stamps, which is the same arithmetic.
  --   filled must clamp to 0, never go negative. Mutant M8 turns it red.
  -- =========================================================================
  begin
    insert into public.stamp_cycles(business_id,programme_id,client_id,cycle_index,slots,origin)
    values (bS,spineS,cS2,0,8,'migration');
    insert into public.programme_pot_migrations(business_id,from_programme_id,to_programme_id,status)
    values (bS,spineS,pg_temp.v323_spine(bS,'points'),'pending');
    insert into v323_out values (21,'a card whose closed cycles exceed its stamps clamps at zero and says so',
      case when (select sp.net_stamps - sp.closed_slots from app.stamp_progress_v323(bS,cS2) sp) >= 0
             then 'FAIL: the fixture did not produce the negative shape this cell exists to clamp'
           when pg_temp.v323_filled(bS,cS2) <> 0
             then 'FAIL: filled is '||pg_temp.v323_filled(bS,cS2)||', expected the clamped 0'
           when not (select sp.pot_migrated from app.stamp_progress_v323(bS,cS) sp)
             then 'FAIL: pot_migrated is not reported'
           else 'PASS' end);
    -- Neither fixture row is cleaned up: stamp_cycles is append-only by design
    -- and the whole transaction rolls back, so deleting them would only be
    -- theatre — and on the cycle row it would fail.
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (21,'a card whose closed cycles exceed its stamps clamps at zero and says so','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 22. THE CONCURRENCY BACKSTOP. Two sessions cannot race here, but the
  --   thing they would race onto can be proved: the slot unique. This is the
  --   third of the three defences named in the migration header; the first two
  --   (the client row lock, the operation idempotency) are exercised by the
  --   two-session rig in db/tests/v323_stamp_quest_concurrency.sh.
  -- =========================================================================
  begin
    v_code := null;
    begin
      insert into public.stamp_milestone_claims(
        business_id,programme_id,client_id,cycle_index,slot_position,reward_id,
        reward_version_id,redemption_id,config_version_id,is_final)
      select c.business_id,c.programme_id,c.client_id,c.cycle_index,c.slot_position,
             c.reward_id,c.reward_version_id,c.redemption_id,c.config_version_id,c.is_final
        from public.stamp_milestone_claims c
       where c.business_id=bS and c.cycle_index=0 and c.slot_position=3;
      v_code := 'accepted';
    exception when unique_violation then v_code := 'blocked';
    when others then get stacked diagnostics v_code = returned_sqlstate;
    end;
    insert into v323_out values (22,'the claim uniques are the backstop a race falls onto',
      case when v_code <> 'blocked'
             then 'FAIL: a duplicate (client, cycle, slot) claim was '||v_code
           else 'PASS' end);
  end;

  -- =========================================================================
  -- CELL 23. Publish refuses a live stamp card that can never reset.
  --   Mutant M13 turns it red.
  -- =========================================================================
  begin
    -- A draft whose card is 12 stamps long while the ladder still stops at 8.
    -- Under closure-at-claim that card fills to 12/12, says Ready for ever and
    -- can never reset, which is why publish refuses it rather than warns.
    v_draft := gen_random_uuid();
    insert into public.firm_config_versions(id,business_id,version_no,status)
    values (v_draft,bS,2,'draft');
    insert into public.loyalty_program_versions(
      business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
      redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,
      expiry_mode,expiry_days)
    values (bS,v_draft,'points','stamps',true,1,100,500,12,500,'visits','none',null);
    insert into public.loyalty_reward_versions(
      reward_id,business_id,config_version_id,programme_id,internal_name,customer_name,
      fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,sort)
    select rv.reward_id,bS,v_draft,rv.programme_id,rv.internal_name,rv.customer_name,
           rv.fulfillment_kind,rv.cost_points,rv.credit_cents,rv.estimated_cost_cents,true,rv.sort
      from public.loyalty_reward_versions rv
     where rv.business_id=bS and rv.config_version_id=cfgS and rv.reward_id in (m3,m5,m8);
    perform pg_temp.as_v323_user(oS);
    v_msg := null;
    begin
      perform public.publish_loyalty_config(v_draft);
      v_msg := 'published';
    exception when others then
      get stacked diagnostics v_msg = message_text;
    end;
    perform pg_temp.as_v323_system();
    insert into v323_out values (23,'publish refuses a live stamp card with no gift at the last stamp',
      case when v_msg = 'published'
             then 'FAIL: a card that can never reset was published'
           when v_msg <> 'a live stamp card needs a gift at the last stamp'
             then 'FAIL: refused with '||v_msg
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (23,'publish refuses a live stamp card with no gift at the last stamp','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 24. THE CUSTOMER'S READ. filled/total against the CURRENT cycle, which
  --   milestones are claimed on this card, which is next and how far — and NOT
  --   ONE POINTS FIGURE anywhere in the payload.
  -- =========================================================================
  begin
    -- The two probe gifts leave the ladder before the customer sees it: the
    -- swapped slot-3 duplicate (cell 7) and the past-the-end gift (cell 10)
    -- exist only to prove refusals, and a live quest would not carry them.
    update public.loyalty_reward_versions set active=false
     where business_id=bS and reward_id in (m3b,past);
    update public.loyalty_rewards set active=false where id in (m3b,past);

    insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                           email_confirmed_at,created_at,updated_at)
    values ('00000000-0000-0000-0000-000000000000',custUser,'authenticated','authenticated',
            'v323-customer-'||substr(custUser::text,1,8)||'@example.test','',now(),now(),now());
    insert into public.customer_identities(id,auth_user_id,status)
    values (custIdent,custUser,'active');
    insert into public.customer_links(business_id,identity_id,auth_user_id,client_id,state,
                                      verification_method,verified_at)
    values (bS,custIdent,custUser,cS,'verified','otp',now());

    perform pg_temp.as_v323_user(custUser);
    v_json := public.customer_get_stamp_card_v323(
      (select slug from public.businesses where id=bS));
    perform pg_temp.as_v323_system();
    insert into v323_out values (24,'the customer card shows the CURRENT cycle, in stamps only',
      case when v_json is null then 'FAIL: the reader returned nothing'
           when (v_json->>'enabled') <> 'true' then 'FAIL: the card is not enabled'
           when (v_json->>'unit') <> 'stamps' then 'FAIL: the card does not speak in stamps'
           when v_json ? 'balance' or v_json ? 'points' or v_json ? 'points_mode'
             then 'FAIL: the stamp card carries a points figure'
           when (v_json->>'slots') <> '8' then 'FAIL: slots is '||(v_json->>'slots')
           when (v_json->>'cycle_index') <> '1' then 'FAIL: the card is not on the second cycle'
           when (v_json->>'filled')::integer <> pg_temp.v323_filled(bS,cS)
             then 'FAIL: filled disagrees with the projection'
           when (v_json->>'lifetime')::integer <> pg_temp.v323_net(bS,cS)
             then 'FAIL: lifetime disagrees with the ledger'
           when jsonb_array_length(v_json->'milestones') < 3
             then 'FAIL: the ladder is missing rungs'
           when not exists (select 1 from jsonb_array_elements(v_json->'milestones') as rung(value)
                             where (rung.value->>'slot')='3'
                               and (rung.value->>'claimed_this_cycle')='true'
                               and (rung.value->>'availability')='claimed_this_cycle')
             then 'FAIL: the milestone claimed on THIS card is not marked claimed'
           when not exists (select 1 from jsonb_array_elements(v_json->'milestones') as rung(value)
                             where (rung.value->>'slot')='5'
                               and (rung.value->>'claimed_this_cycle')='false')
             then 'FAIL: a milestone claimed on the PREVIOUS card is still marked claimed'
           when (v_json->'next_milestone'->>'slot') <> '5'
             then 'FAIL: next_milestone is '||coalesce(v_json->'next_milestone'->>'slot','null')||', expected 5'
           when (v_json->'next_milestone'->>'stamps_to_go')::integer
                <> greatest(5 - pg_temp.v323_filled(bS,cS),0)
             then 'FAIL: stamps_to_go is wrong'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (24,'the customer card shows the CURRENT cycle, in stamps only','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 25. The reader answers exactly {"enabled": false} for a firm with no
  --   stamp card, so the client removes the slot rather than rendering an
  --   empty one or a retry affordance.
  -- =========================================================================
  begin
    insert into public.customer_links(business_id,identity_id,auth_user_id,client_id,state,
                                      verification_method,verified_at)
    values (bP,custIdent,custUser,cP,'verified','otp',now());
    perform pg_temp.as_v323_user(custUser);
    v_json := public.customer_get_stamp_card_v323(
      (select slug from public.businesses where id=bP));
    perform pg_temp.as_v323_system();
    insert into v323_out values (25,'a firm with no stamp card answers exactly {"enabled": false}',
      case when v_json is distinct from jsonb_build_object('enabled',false)
             then 'FAIL: the reader leaked '||v_json::text
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (25,'a firm with no stamp card answers exactly {"enabled": false}','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 26. THE HARD CONSTRAINT. After everything above — ten stamps earned,
  --   five claims, one closed cycle and a points redemption — the W5 kernel is
  --   exactly as it was: both standing detectors empty, and the stamps firm is
  --   still on a per-programme pot rather than having fallen back to a
  --   business-wide one.
  -- =========================================================================
  begin
    select count(*) into v_rows from app.detect_double_earn_v309();
    select count(*) into v_int  from app.detect_programme_pot_split_v312();
    insert into v323_out values (26,'the W5 earn kernel, arbiter and detectors are undisturbed',
      case when v_rows <> 0 then 'FAIL: detect_double_earn_v309 reports '||v_rows||' row(s)'
           when v_int <> 0 then 'FAIL: detect_programme_pot_split_v312 reports '||v_int||' row(s)'
           when app.programme_balance_scope_v312(bS) <> 'programme_pot'
             then 'FAIL: the stamps firm fell back to '||app.programme_balance_scope_v312(bS)
           when (select count(*) from public.points_batches b
                  where b.business_id=bS and b.client_id=cS)
                <> (select count(*) from public.points_ledger l
                     where l.business_id=bS and l.client_id=cS and l.entry_type='earn')
             then 'FAIL: the stamps pot lost its ledger/batch parity'
           when exists (select 1 from public.points_batches b
                         where b.business_id=bS and b.client_id=cS and b.remaining <> b.earned)
             then 'FAIL: a stamp batch was drained; stamps batches are written and never drained'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (26,'the W5 earn kernel, arbiter and detectors are undisturbed','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- CELL 27. Shape and floor: the two tables, their guards, the reader ACLs and
  --   the relaxed-but-paired constraints, asserted as the migration promised.
  -- =========================================================================
  begin
    insert into v323_out values (27,'the v323 schema, guards and ACL floor are in their contracted shape',
      case when not exists (select 1 from pg_constraint
                             where conrelid='public.loyalty_redemptions'::regclass
                               and conname='loyalty_redemptions_points_spent_check'
                               and pg_get_constraintdef(oid)='CHECK ((points_spent >= 0))')
             then 'FAIL: points_spent was not relaxed to >= 0'
           when exists (select 1 from pg_attribute
                         where attrelid='public.loyalty_redemption_provenance'::regclass
                           and attname='points_ledger_id' and attnotnull)
             then 'FAIL: points_ledger_id is still NOT NULL'
           when not exists (select 1 from pg_constraint
                             where conrelid='public.business_programmes'::regclass
                               and conname='business_programmes_id_business_uk')
             then 'FAIL: the spine composite unique is missing'
           when (select count(*) from pg_policies where schemaname='public'
                  and tablename in ('stamp_cycles','stamp_milestone_claims')) <> 4
             then 'FAIL: the quest tables do not carry exactly four read policies'
           when exists (select 1 from pg_policies where schemaname='public'
                         and tablename in ('stamp_cycles','stamp_milestone_claims')
                         and cmd <> 'SELECT')
             then 'FAIL: a write policy exists on a quest table'
           when has_function_privilege('authenticated','app.stamp_progress_v323(uuid,uuid)','execute')
             then 'FAIL: the internal projection is browser-reachable'
           when has_function_privilege('anon','public.customer_get_stamp_card_v323(text)','execute')
             then 'FAIL: the customer card is anon-reachable'
           when not has_function_privilege('authenticated','public.customer_get_stamp_card_v323(text)','execute')
             then 'FAIL: a verified customer cannot call their own card'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v323_system();
    insert into v323_out values (27,'the v323 schema, guards and ACL floor are in their contracted shape','FAIL: '||v_msg);
  end;

  perform pg_temp.as_v323_system();
end
$v323_test$;

select seq, step, outcome from v323_out order by seq;
select count(*) filter (where outcome not like 'PASS%') as failures,
       count(*) as cells
  from v323_out;

rollback;
