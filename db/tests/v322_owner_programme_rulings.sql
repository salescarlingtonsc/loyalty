-- Rollback-only v322 acceptance: THE OWNER RULINGS OF 2026-08-14, SERVER HALF.
--
-- v322 does two things and refuses to do a third:
--   R1/R4 — the referral payout stops writing public.credit_ledger and writes ONE points_ledger
--           'earn' row plus its batch, tagged with the referrer's firm's ONE active accruing
--           programme, with sale_id NULL so it cannot collide with the friend's own earn row.
--   R2/R3 — public.set_programmes_v314 refuses any call whose RESULT would leave the stamp card
--           running beside points or tiers. Referral is orthogonal and is never part of it.
--   NOT   — it does not touch the W5 money kernel. The earn loop, the (sale, programme) arbiter,
--           the ledger/batch parity check and the pot migration are asserted UNCHANGED below.
--
-- ZERO LIVE TENANTS EXERCISE THE CHANGED BRANCHES. No firm runs stamps (that is the precondition
-- v322 asserts at apply), and only two referrals have ever qualified. A green run against
-- production therefore proves ABSENCE OF REGRESSION, not presence of correctness — so every
-- tenant shape is CREATED INSIDE THIS TRANSACTION:
--
--   R1 points firm    points=true; referral enabled paying points        (the headline payout)
--   R2 stamps firm    stamps=true; referral enabled                      (universality: pays stamps)
--   R3 dark firm      nothing accruing; referral enabled                 (fail closed, stays pending)
--   R4 guard firm     points=true, used only to drive set_programmes_v314 (R2/R3 exclusivity)
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v322_owner_programme_rulings.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.
--
-- MUTANTS. Stated in the step banners in this repo's house form. Each names the edit to the
-- shipped v322 bytes that turns that step red:
--   M1  compute the exclusivity guard on p_switches alone instead of merging it over the spine
--   M2  include referral in the exclusivity guard
--   M3  place the guard AFTER the flip loop instead of before it
--   M4  give the referral earn row sale_id = new.id
--   M5  resolve the payout pot with app.reward_default_programme_v313 instead of the v322 resolver
--   M6  pay the referral even when the pot is null (or the amount is zero)
--   M7  drop the 'referral_reward_points' shape rule from app.loyalty_ledger_write_guard
--   M8  keep the credit_ledger insert alongside the points one

begin;

create temp table v322_out(seq integer, step text, outcome text) on commit drop;

create or replace function pg_temp.as_v322_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v322_system() to public;

create or replace function pg_temp.as_v322_user(p_uid uuid, p_role text default 'authenticated')
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
grant execute on function pg_temp.as_v322_user(uuid,text) to public;

create or replace function pg_temp.v322_spine(p_business uuid, p_kind text) returns uuid
language sql stable as $$
  select spine.id from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = p_kind
$$;
grant execute on function pg_temp.v322_spine(uuid,text) to public;

create or replace function pg_temp.v322_active(p_business uuid, p_kind text) returns boolean
language sql stable as $$
  select spine.active from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = p_kind
$$;
grant execute on function pg_temp.v322_active(uuid,text) to public;

-- The same tenant builder the v313/v314 suite uses, narrowed to what v322 needs.
create or replace function pg_temp.v322_tenant(
  p_business uuid, p_owner uuid, p_label text, p_model text,
  p_per_dollar numeric, p_stamp_per_cents integer
) returns uuid language plpgsql as $$
declare v_config uuid := gen_random_uuid();
begin
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (p_business, p_label, lower(p_label)||'-'||substr(p_business::text,1,8),
          'retail','SGD',
          array['dashboard','clients','sales','loyalty','referrals'], 'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v322 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;

  insert into public.staff(business_id,user_id,role,full_name,active)
  values (p_business,p_owner,'owner','V322 Owner',true);

  insert into public.firm_config_versions(id,business_id,version_no,status,published_at)
  values (v_config,p_business,1,'published',now());
  update public.businesses set active_config_version_id=v_config where id=p_business;

  -- redeem_points/reward_credit_cents = 100/500 is a deliberate, ugly ratio (5 cents a point):
  -- the backfill and the benefit costing both use it, and a 1:1 ratio would hide an inverted
  -- multiplication in both directions.
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,redeem_points,
    reward_credit_cents,tier_basis,expiry_mode,expiry_days,earn_points_per_dollar,
    stamp_target,stamp_per_cents,current_config_version_id)
  values (p_business,'points',true,p_model,'published',100,500,'visits',
          'none',null,p_per_dollar,10,p_stamp_per_cents,v_config);

  insert into public.loyalty_program_versions(
    business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,
    expiry_mode,expiry_days)
  values (p_business,v_config,'points',p_model,true,p_per_dollar,100,500,10,
          p_stamp_per_cents,'visits','none',null);

  return v_config;
end
$$;
grant execute on function pg_temp.v322_tenant(uuid,uuid,text,text,numeric,integer) to public;

create or replace function pg_temp.v322_sale(
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
grant execute on function pg_temp.v322_sale(uuid,uuid,uuid,integer) to public;

do $v322_test$
declare
  r1 uuid := gen_random_uuid(); r2 uuid := gen_random_uuid();
  r3 uuid := gen_random_uuid(); r4 uuid := gen_random_uuid();
  o1 uuid := gen_random_uuid(); o2 uuid := gen_random_uuid();
  o3 uuid := gen_random_uuid(); o4 uuid := gen_random_uuid();
  c1 uuid := gen_random_uuid(); c2 uuid := gen_random_uuid();
  c3 uuid := gen_random_uuid(); c4 uuid := gen_random_uuid();
  c5 uuid := gen_random_uuid(); c6 uuid := gen_random_uuid();
  c7 uuid := gen_random_uuid(); c8 uuid := gen_random_uuid();
  cfg1 uuid; cfg2 uuid; cfg3 uuid; cfg4 uuid;
  ref1 uuid := gen_random_uuid(); ref2 uuid := gen_random_uuid();
  ref3 uuid := gen_random_uuid(); ref4 uuid := gen_random_uuid();
  v_sale uuid; v_rows integer; v_msg text; v_txt text; v_def text;
  v_points integer; v_prog uuid; v_ok boolean;
begin
  perform pg_temp.as_v322_system();

  cfg1 := pg_temp.v322_tenant(r1,o1,'V322 Points','points_tiers',1,500);
  cfg2 := pg_temp.v322_tenant(r2,o2,'V322 Stamps','stamps',1,500);
  cfg3 := pg_temp.v322_tenant(r3,o3,'V322 Dark','points_tiers',1,500);
  cfg4 := pg_temp.v322_tenant(r4,o4,'V322 Guard','points_tiers',1,500);

  insert into public.clients(id,business_id,full_name,phone) values
    (c1,r1,'R1 Referrer','81000001'),(c2,r1,'R1 Friend','81000002'),
    (c3,r2,'R2 Referrer','81000003'),(c4,r2,'R2 Friend','81000004'),
    (c5,r3,'R3 Referrer','81000005'),(c6,r3,'R3 Friend','81000006'),
    (c7,r1,'R1 Referrer B','81000007'),(c8,r1,'R1 Friend B','81000008');

  -- The four tenants are seeded all-four-false by app.seed_business_programmes_v314, so every
  -- spine row below is set explicitly and each firm's shape is legal under R2 by construction.
  update public.business_programmes set active=true, activated_at=now()
   where business_id in (r1,r3,r4) and kind='points';
  update public.business_programmes set active=true, activated_at=now()
   where business_id=r2 and kind='stamps';
  update public.business_programmes set active=false where business_id=r3 and kind='points';
  update public.business_programmes set active=true, activated_at=now()
   where business_id in (r1,r2,r3) and kind='referral';

  insert into public.referral_programs(business_id,enabled,reward_cents,reward_points,min_spend_cents)
  values (r1,true,0,50,1000),(r2,true,0,3,0),(r3,true,0,50,0);

  insert into public.referrals(id,business_id,referrer_client_id,referred_client_id,status)
  values (ref1,r1,c1,c2,'pending'),(ref2,r2,c3,c4,'pending'),(ref3,r3,c5,c6,'pending'),
         (ref4,r1,c7,c8,'pending');

  -- =========================================================================
  -- STEP 1. The shape of the new columns. reward_points is a NEW column, not a
  --   re-read of reward_cents, and reward_kind can only ever say 'points'
  --   until the deferred voucher payout is built.
  -- =========================================================================
  begin
    insert into v322_out values (1,'referral_programs carries reward_points and a points-only reward_kind',
      case when not exists (select 1 from information_schema.columns
                             where table_schema='public' and table_name='referral_programs'
                               and column_name='reward_points')
             then 'FAIL: referral_programs.reward_points is missing'
           when not exists (select 1 from information_schema.columns
                             where table_schema='public' and table_name='referrals'
                               and column_name='reward_points')
             then 'FAIL: referrals.reward_points is missing'
           when exists (select 1 from public.referral_programs where reward_kind <> 'points')
             then 'FAIL: a referral programme already claims a payout kind that is not built'
           when not exists (select 1 from pg_constraint
                             where conrelid='public.referral_programs'::regclass
                               and conname='referral_programs_reward_kind_check')
             then 'FAIL: reward_kind has no CHECK, so ''voucher'' could be written today'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (1,'referral_programs carries reward_points and a points-only reward_kind','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 2. A voucher row cannot be written, so the deferred half cannot be
  --   reached by accident.
  -- =========================================================================
  begin
    v_ok := false;
    begin
      update public.referral_programs set reward_kind='voucher' where business_id=r1;
      -- 'voucher' IS a legal column value (the shape carries the deferral); what must hold is
      -- that the ENGINE refuses to pay it. Put it back and prove that instead, in step 9.
      v_ok := true;
      update public.referral_programs set reward_kind='points' where business_id=r1;
    exception when others then v_ok := false;
    end;
    begin
      update public.referral_programs set reward_kind='free_coffee' where business_id=r1;
      insert into v322_out values (2,'reward_kind is constrained to the two named payouts',
        'FAIL: an arbitrary reward_kind was accepted');
    exception when check_violation then
      insert into v322_out values (2,'reward_kind is constrained to the two named payouts',
        case when v_ok then 'PASS' else 'FAIL: ''voucher'' is not even storable, so the deferral has no shape' end);
    end;
    update public.referral_programs set reward_kind='points' where business_id=r1;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (2,'reward_kind is constrained to the two named payouts','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 3. THE HEADLINE. A qualifying referral at a points firm pays POINTS to
  --   the REFERRER and writes NO credit. The earn row carries sale_id NULL —
  --   mutant M4 (sale_id := new.id) makes this step abort with 23505 the moment
  --   the friend's own earn row lands in the same programme, which it does
  --   here, deliberately.
  -- =========================================================================
  begin
    v_sale := pg_temp.v322_sale(r1,c2,cfg1,10000);
    select count(*) into v_rows from public.points_ledger l
     where l.business_id=r1 and l.client_id=c1 and l.entry_type='earn' and l.sale_id is null;
    select coalesce(sum(l.points),0) into v_points from public.points_ledger l
     where l.business_id=r1 and l.client_id=c1;
    insert into v322_out values (3,'a qualifying referral pays the referrer POINTS and writes no credit',
      case when v_rows <> 1 then 'FAIL: expected one sale-less earn row for the referrer, found '||v_rows
           when v_points <> 50 then 'FAIL: referrer balance is '||v_points||', expected 50'
           when exists (select 1 from public.credit_ledger cl
                         where cl.business_id=r1 and cl.entry_type='referral_reward')
             then 'FAIL: the referral still minted store credit'
           when not exists (select 1 from public.points_batches b
                             where b.business_id=r1 and b.client_id=c1 and b.remaining=50
                               and b.sale_id is null)
             then 'FAIL: the referrer got a ledger row with no batch behind it — unspendable'
           when (select status from public.referrals where id=ref1) <> 'rewarded'
             then 'FAIL: the referral was not marked rewarded'
           when (select reward_points from public.referrals where id=ref1) <> 50
             then 'FAIL: the referral did not record the points it paid'
           when (select reward_cents from public.referrals where id=ref1) <> 0
             then 'FAIL: the frozen money column was written'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (3,'a qualifying referral pays the referrer POINTS and writes no credit','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 4. The payout lands in a pot the customer can actually spend, and the
  --   FRIEND's own earn is untouched — the W5 arbiter and the ledger/batch
  --   parity check both still hold on the same sale. Mutant M5 (resolve with
  --   app.reward_default_programme_v313) survives here and dies at step 7.
  -- =========================================================================
  begin
    select l.programme_id into v_prog from public.points_ledger l
     where l.business_id=r1 and l.client_id=c1 and l.entry_type='earn' and l.sale_id is null;
    select count(*) into v_rows from public.points_ledger l
     where l.business_id=r1 and l.client_id=c2 and l.entry_type='earn' and l.sale_id=v_sale;
    insert into v322_out values (4,'the referral pot is the firm''s live accruing programme; the friend''s own earn is intact',
      case when v_prog is distinct from pg_temp.v322_spine(r1,'points')
             then 'FAIL: the referral was paid into the wrong programme'
           when not pg_temp.v322_active(r1,'points')
             then 'FAIL: the payout programme is not running'
           when v_rows <> 1 then 'FAIL: the friend''s own earn row is missing or doubled ('||v_rows||')'
           when (select count(*) from public.points_ledger l
                  where l.sale_id=v_sale and l.entry_type='earn')
             <> (select count(*) from public.points_batches b where b.sale_id=v_sale)
             then 'FAIL: the sale''s ledger/batch parity broke'
           when (select count(*) from app.detect_double_earn_v309()) <> 0
             then 'FAIL: the double-earn detector is no longer empty'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (4,'the referral pot is the firm''s live accruing programme; the friend''s own earn is intact','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 5. Once only, ever. The second qualifying sale from the same friend
  --   pays nothing more, because the UPDATE ... WHERE status='pending' guard is
  --   untouched and the payout hangs off its FOUND.
  -- =========================================================================
  begin
    perform pg_temp.v322_sale(r1,c2,cfg1,10000);
    select count(*) into v_rows from public.points_ledger l
     where l.business_id=r1 and l.client_id=c1 and l.entry_type='earn' and l.sale_id is null;
    insert into v322_out values (5,'a referral pays once and only once',
      case when v_rows <> 1 then 'FAIL: the referrer was paid '||v_rows||' times'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (5,'a referral pays once and only once','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 6. The minimum-spend gate is unchanged: a sale below it leaves the
  --   referral pending and pays nothing.
  -- =========================================================================
  begin
    perform pg_temp.v322_sale(r1,c8,cfg1,500);
    insert into v322_out values (6,'a sale below the minimum leaves the referral pending and pays nothing',
      case when (select status from public.referrals where id=ref4) <> 'pending'
             then 'FAIL: an under-spend qualified the referral'
           when exists (select 1 from public.points_ledger l
                         where l.business_id=r1 and l.client_id=c7)
             then 'FAIL: an under-spend paid the referrer'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (6,'a sale below the minimum leaves the referral pending and pays nothing','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 7. UNIVERSALITY (R4). Referral runs at a STAMPS firm, and it pays into
  --   the stamps pot, because that is the only balance that firm's customers
  --   can spend. Mutant M5 (reward_default_programme_v313) still answers
  --   'stamps' here — but it answers 'points' at the dark firm in step 8, which
  --   is what kills it.
  -- =========================================================================
  begin
    perform pg_temp.v322_sale(r2,c4,cfg2,10000);
    select l.programme_id into v_prog from public.points_ledger l
     where l.business_id=r2 and l.client_id=c3 and l.entry_type='earn' and l.sale_id is null;
    insert into v322_out values (7,'referral is universal: at a stamps firm it pays into the stamps pot',
      case when v_prog is null then 'FAIL: a stamps firm''s referral paid nothing'
           when v_prog is distinct from pg_temp.v322_spine(r2,'stamps')
             then 'FAIL: the payout landed in a pot this firm''s customers cannot spend'
           when (select reward_points from public.referrals where id=ref2) <> 3
             then 'FAIL: the stamps referral did not record its payout'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (7,'referral is universal: at a stamps firm it pays into the stamps pot','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 8. FAIL CLOSED. A firm with NOTHING accruing pays nothing and leaves
  --   the referral PENDING, so it pays on the next qualifying visit once the
  --   owner switches a programme on. Mutants M5 and M6 both die here: M5 would
  --   mint points into a switched-off pot nobody can spend, M6 would raise a
  --   NOT NULL violation on points_ledger.programme_id and abort the sale.
  -- =========================================================================
  begin
    perform pg_temp.v322_sale(r3,c6,cfg3,10000);
    insert into v322_out values (8,'a firm with nothing accruing pays no referral and leaves it pending',
      case when (select status from public.referrals where id=ref3) <> 'pending'
             then 'FAIL: the referral was marked rewarded with no pot to pay into'
           when exists (select 1 from public.points_ledger l
                         where l.business_id=r3 and l.client_id=c5)
             then 'FAIL: points were minted into a programme nobody is running'
           when exists (select 1 from public.credit_ledger cl
                         where cl.business_id=r3 and cl.entry_type='referral_reward')
             then 'FAIL: it fell back to store credit'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (8,'a firm with nothing accruing pays no referral and leaves it pending','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 9. A 'voucher' programme pays NOTHING, because the voucher payout is
  --   deferred and the engine will not improvise one. This is the assertion
  --   that makes "deferred" mean deferred rather than "half built".
  -- =========================================================================
  begin
    update public.referral_programs set reward_kind='voucher' where business_id=r3;
    update public.business_programmes set active=true, activated_at=now()
     where business_id=r3 and kind='points';
    perform pg_temp.v322_sale(r3,c6,cfg3,10000);
    insert into v322_out values (9,'a voucher-kind referral pays nothing — the deferred half is unreachable',
      case when (select status from public.referrals where id=ref3) <> 'pending'
             then 'FAIL: a voucher referral qualified with no voucher machinery behind it'
           when exists (select 1 from public.points_ledger l
                         where l.business_id=r3 and l.client_id=c5)
             then 'FAIL: a voucher referral silently paid points instead'
           else 'PASS' end);
    update public.referral_programs set reward_kind='points' where business_id=r3;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (9,'a voucher-kind referral pays nothing — the deferred half is unreachable','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 10. The ledger write guard closed the hole it opened. The new scope
  --   exists AND it refuses the one shape that would collide with the arbiter.
  --   Mutant M7 (drop the shape rule) turns this red.
  -- =========================================================================
  begin
    v_ok := false;
    begin
      perform set_config('app.points_ledger_insert_id', ref1::text, true);
      perform set_config('app.points_ledger_write_scope','referral_reward_points',true);
      insert into public.points_ledger(id,business_id,client_id,entry_type,points,sale_id,
                                       reference,actor,programme_id)
      values (ref1,r1,c1,'earn',5,v_sale,'v322 mutant probe',null,pg_temp.v322_spine(r1,'points'));
    exception when others then v_ok := true;
    end;
    perform set_config('app.points_ledger_insert_id','',true);
    perform set_config('app.points_ledger_write_scope','',true);
    insert into v322_out values (10,'the referral ledger scope refuses a row that carries a sale',
      case when not v_ok
             then 'FAIL: the referral scope accepted a sale_id, which is the 23505 collision it exists to avoid'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (10,'the referral ledger scope refuses a row that carries a sale','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 11. The fulfilment trail survived the move off credit_ledger. The v56
  --   trigger fires on a credit insert that no longer happens, so v322 calls
  --   app.emit_referral_qualified_v322 directly — and the v56 trigger is left
  --   installed so a pre-v322 credit row still emits.
  -- =========================================================================
  begin
    insert into v322_out values (11,'the referral.qualified event and its shadow fulfilment still happen',
      case when not exists (select 1 from public.domain_events e
                             where e.business_id=r1 and e.event_type='referral.qualified'
                               and e.dedupe_key='referral_qualify:'||ref1::text)
             then 'FAIL: no referral.qualified event was emitted'
           when (select e.payload->>'reward_points' from public.domain_events e
                  where e.business_id=r1 and e.dedupe_key='referral_qualify:'||ref1::text) <> '50'
             then 'FAIL: the event does not carry the points that were paid'
           when not exists (select 1 from pg_trigger
                             where tgrelid='public.credit_ledger'::regclass
                               and tgname='trg_ps1b_referral_fulfilment')
             then 'FAIL: the legacy credit-side emitter was dropped, so a rollback would be silent'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (11,'the referral.qualified event and its shadow fulfilment still happen','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 12. R2/R3 — the exclusivity guard refuses a call whose RESULT would
  --   put stamps beside points, and it refuses it BEFORE writing anything.
  --   Mutant M3 (guard after the flip loop) turns the second half of this red:
  --   the spine would already carry stamps=true when the refusal fired.
  -- =========================================================================
  begin
    perform pg_temp.as_v322_user(o4);
    v_ok := false; v_txt := '';
    begin
      perform public.set_programmes_v314(r4, '{"points":true,"stamps":true}'::jsonb, gen_random_uuid());
    exception when others then
      get stacked diagnostics v_txt = message_text; v_ok := true;
    end;
    perform pg_temp.as_v322_system();
    insert into v322_out values (12,'points + stamps in one call is refused, in words, before anything is written',
      case when not v_ok then 'FAIL: the forbidden shape was accepted'
           when position('stamp card runs on its own' in v_txt) = 0
             then 'FAIL: the refusal is not a sentence an owner can act on: '||v_txt
           when pg_temp.v322_active(r4,'stamps')
             then 'FAIL: the spine was written before the refusal'
           when not pg_temp.v322_active(r4,'points')
             then 'FAIL: the refused call moved the points row anyway'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (12,'points + stamps in one call is refused, in words, before anything is written','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 13. THE R6 CASE, AND THE ONE MUTANT THAT ONLY THIS STEP CATCHES. After
  --   R6 the wizard sends a PARTIAL payload — only the programmes the owner is
  --   actually setting up. So {"stamps":true} alone, at a firm already running
  --   points, is the forbidden shape even though the payload names one kind.
  --   Mutant M1 (judge the payload instead of the merged result) passes step 12
  --   and dies here.
  -- =========================================================================
  begin
    perform pg_temp.as_v322_user(o4);
    v_ok := false; v_txt := '';
    begin
      perform public.set_programmes_v314(r4, '{"stamps":true}'::jsonb, gen_random_uuid());
    exception when others then
      get stacked diagnostics v_txt = message_text; v_ok := true;
    end;
    perform pg_temp.as_v322_system();
    insert into v322_out values (13,'a PARTIAL payload is judged on the merged result, not on its own keys',
      case when not v_ok
             then 'FAIL: {stamps:true} was accepted at a firm already running points'
           when position('stamp card runs on its own' in v_txt) = 0
             then 'FAIL: wrong refusal: '||v_txt
           when pg_temp.v322_active(r4,'stamps') then 'FAIL: stamps was switched on anyway'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (13,'a PARTIAL payload is judged on the merged result, not on its own keys','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 14. The legal shapes are all reachable, and moving to stamps in ONE
  --   call (which is what the client now sends) is accepted — including the
  --   pot migration v312 owns, which v322 does not touch.
  -- =========================================================================
  begin
    perform pg_temp.as_v322_user(o4);
    perform public.set_programmes_v314(r4,
      '{"points":true,"tiers":true}'::jsonb, gen_random_uuid());
    perform public.set_programmes_v314(r4,
      '{"stamps":true,"points":false,"tiers":false}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v322_system();
    insert into v322_out values (14,'points+tier is legal, and switching to stamps in one call is accepted',
      case when not pg_temp.v322_active(r4,'stamps') then 'FAIL: the stamps switch did not land'
           when pg_temp.v322_active(r4,'points') or pg_temp.v322_active(r4,'tiers')
             then 'FAIL: the exclusive switch left an accruing sibling on'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (14,'points+tier is legal, and switching to stamps in one call is accepted','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 15. REFERRAL IS ORTHOGONAL (R4). It is never part of the exclusivity,
  --   so it can be switched at a stamps firm and it can ride along with a
  --   points call. Mutant M2 (include referral in the guard) turns this red.
  -- =========================================================================
  begin
    perform pg_temp.as_v322_user(o4);
    perform public.set_programmes_v314(r4, '{"referral":true}'::jsonb, gen_random_uuid());
    v_ok := pg_temp.v322_active(r4,'referral') and pg_temp.v322_active(r4,'stamps');
    perform public.set_programmes_v314(r4,
      '{"points":true,"stamps":false,"referral":true}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v322_system();
    insert into v322_out values (15,'referral is orthogonal: it switches under stamps and under points alike',
      case when not v_ok then 'FAIL: referral could not be switched on at a stamps firm'
           when not pg_temp.v322_active(r4,'referral')
             then 'FAIL: referral did not survive the move back to points'
           when not pg_temp.v322_active(r4,'points') then 'FAIL: the points switch did not land'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (15,'referral is orthogonal: it switches under stamps and under points alike','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 16. R6's other half, at the server: a PARTIAL payload leaves every
  --   kind it does not name exactly as it found it. Unselecting a programme in
  --   the wizard must never be able to switch it off, and this is the property
  --   the client's new scope-only payload relies on.
  -- =========================================================================
  begin
    perform pg_temp.as_v322_user(o4);
    perform public.set_programmes_v314(r4, '{"tiers":true}'::jsonb, gen_random_uuid());
    perform public.set_programmes_v314(r4, '{"tiers":true}'::jsonb, gen_random_uuid());
    perform pg_temp.as_v322_system();
    insert into v322_out values (16,'a partial payload leaves every unnamed programme exactly as it found it',
      case when not pg_temp.v322_active(r4,'points')
             then 'FAIL: a payload that never mentioned points switched it off'
           when not pg_temp.v322_active(r4,'referral')
             then 'FAIL: a payload that never mentioned referral switched it off'
           when not pg_temp.v322_active(r4,'tiers') then 'FAIL: the tiers switch did not land'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (16,'a partial payload leaves every unnamed programme exactly as it found it','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 17. THE NON-GOAL, ASSERTED. v322 must not revert v311/v312. The earn
  --   loop, the (sale, programme) arbiter and the parity check are all still
  --   byte-present in app.on_sale_recorded, and the pot migration is still the
  --   one entry point.
  -- =========================================================================
  begin
    select pg_get_functiondef('app.on_sale_recorded()'::regprocedure) into v_def;
    insert into v322_out values (17,'the W5 money kernel is untouched — this is not a revert of v311/v312',
      case when position('spine.kind in (''points'',''stamps'')' in v_def) = 0
             then 'FAIL: the per-programme earn loop is gone'
           when position('on conflict (sale_id,programme_id) where entry_type=''earn''' in v_def) = 0
             then 'FAIL: the (sale, programme) earn arbiter is gone'
           when position('earn loop left ledger/batch parity broken for sale' in v_def) = 0
             then 'FAIL: the ledger/batch parity check is gone'
           when to_regprocedure('app.enqueue_programme_pot_migration_v312(uuid,uuid,uuid)') is null
             then 'FAIL: the pot migration entry point is gone'
           when position('''referral_reward''' in v_def) <> 0
             then 'FAIL: the credit-paying referral branch is still there (mutant M8)'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (17,'the W5 money kernel is untouched — this is not a revert of v311/v312','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 18. Both standing money detectors are still empty after everything
  --   above, and the new writer's ACL floor holds.
  -- =========================================================================
  begin
    insert into v322_out values (18,'both money detectors are empty and the new writer''s ACL floor holds',
      case when (select count(*) from app.detect_double_earn_v309()) <> 0
             then 'FAIL: detect_double_earn_v309 is not empty'
           when (select count(*) from app.detect_programme_pot_split_v312()) <> 0
             then 'FAIL: detect_programme_pot_split_v312 is not empty'
           when not has_function_privilege('authenticated',
                  'public.save_referral_program_v322(uuid,boolean,integer,integer)','execute')
             then 'FAIL: an owner cannot call the points writer'
           when has_function_privilege('anon',
                  'public.save_referral_program_v322(uuid,boolean,integer,integer)','execute')
             then 'FAIL: anon can call the points writer'
           when has_function_privilege('authenticated','app.referral_payout_programme_v322(uuid)','execute')
             then 'FAIL: the payout resolver is reachable from a browser'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (18,'both money detectors are empty and the new writer''s ACL floor holds','FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 19. The three LIVE referral programmes, reported rather than asserted:
  --   the backfill has already run by the time this suite executes, and what
  --   each real firm now pays belongs in the apply log and in the acceptance
  --   document, business by business.
  -- =========================================================================
  begin
    select string_agg(b.name||' = '||rp.reward_points||' points (was '||rp.reward_cents||' cents)',
                      ' · ' order by b.name)
      into v_txt
      from public.referral_programs rp join public.businesses b on b.id = rp.business_id
     where rp.business_id not in (r1,r2,r3,r4);
    insert into v322_out values (19,'LIVE referral payouts after the backfill (report, never an assertion)',
      'REPORT: '||coalesce(v_txt,'(none)'));
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v322_system();
    insert into v322_out values (19,'LIVE referral payouts after the backfill (report, never an assertion)','FAIL: '||v_msg);
  end;

  perform pg_temp.as_v322_system();
end
$v322_test$;

select seq, step, outcome from v322_out order by seq;

rollback;
