-- Rollback-only acceptance for Nestly v256 — tiers and redeemable points coexist.
-- Run after the canonical chain through v256 in a disposable database:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v256_tier_may_measure_lifetime_points.sql
-- Everything runs inside one transaction and is rolled back; nothing is left behind.
--
-- v256 removed the v239 guard that rejected points_mode='both' alongside
-- tier_basis='points_earned'. Deleting a guard is only safe if the invariant it claimed to
-- protect is genuinely held elsewhere, so this suite tests the INVARIANT, not the absence:
--
--   1. the guard's objects are gone, and the configuration it forbade is now accepted;
--   2. the tier measure is LIFETIME EARNED — spending points never lowers it. This is the
--      property that made the guard unnecessary, and it is the owner's product ruling
--      ("tier is based on lifetime ... points accumulated ... while points is for redemption").
--
-- Two independent code paths compute the tier metric — app.loyalty_tier_for, which resolves a
-- customer's actual tier row, and app.v176_tier_gate_metric, which gates tier-restricted
-- rewards. BOTH are asserted: a regression in either would demote a real customer, and pinning
-- only one would let the other drift.
--
-- Points are earned and spent through the REAL production routes, never by writing
-- points_ledger directly: app.loyalty_ledger_write_guard refuses any insert that does not carry
-- a matching row token and an approved write scope, so a fixture that inserted its own rows
-- would prove nothing about how the engine actually behaves. Earning therefore goes through
-- evaluate_checkout + record_cart_sale, and spending through public.adjust_points.
--
-- Verified against production inside an aborted transaction on 2026-08-09:
--   lifetime earned 400 held while spendable fell to 50; tier Gold and gate metric 400
--   unchanged by the spend.
begin;

create or replace function pg_temp.as_v256_user(
  p_uid uuid,p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,
    true
  );
end
$$;
grant execute on function pg_temp.as_v256_user(uuid,text) to authenticated,anon;

do $v256$
declare
  v_owner uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_branch uuid:=gen_random_uuid();
  v_staff uuid:=gen_random_uuid();
  v_client uuid:=gen_random_uuid();
  v_svc uuid:=gen_random_uuid();
  v_config uuid:=gen_random_uuid();
  v_eval jsonb;
  v_sale json;
  v_tier_earn public.loyalty_tiers%rowtype;
  v_tier_spend public.loyalty_tiers%rowtype;
  v_gate_earn numeric;
  v_gate_spend numeric;
  v_earned bigint;
  v_balance bigint;
begin
  -- 1. The guard's objects must be gone.
  if exists(select 1 from pg_trigger
             where tgname in ('v239_guard_points_mode','v239_guard_tier_basis')) then
    raise exception 'v256: a v239 guard trigger still exists';
  end if;
  if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
             where n.nspname='app' and p.proname='v239_guard_points_and_tier_basis') then
    raise exception 'v256: app.v239_guard_points_and_tier_basis still exists';
  end if;

  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
    'v256-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());

  -- 2. The exact configuration v239 rejected must now be accepted by both writes:
  --    points_mode='both' on the business AND tier_basis='points_earned' on the programme.
  insert into public.businesses(id,name,slug,industry,enabled_modules,points_mode)
  values(v_business,'V256 tier fixture','v256-'||substr(v_business::text,1,8),'retail',
         array['dashboard','clients','loyalty','till','sales','services'],'both');

  -- Every till and loyalty RPC is gated on app.business_workspace_open_v94. Both rows are
  -- created by a trigger on the business insert, so they are UPDATEd, and the controls check
  -- constraint requires a decided_by/decided_at pair alongside 'approved'.
  update public.business_workspace_controls_v94
     set approval_status='approved',decided_by=v_owner,decided_at=now(),
         decision_reason='v256 rollback-only fixture'
   where business_id=v_business;
  update public.business_subscription_lifecycle_v94
     set state='current',workspace_paused=false
   where business_id=v_business;

  insert into public.firm_config_versions(
    id,business_id,version_no,status,source,published_at,created_by,snapshot_hash
  ) values(v_config,v_business,1,'published','v256_seed',now(),v_owner,
           md5('v256-seed-'||v_config::text));
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,expiry_mode
  ) values(v_config,v_business,'points','points_tiers',true,1,100,0,'points_earned','none');
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,
    earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,expiry_mode,
    current_config_version_id
  ) values(v_business,'points',true,'points_tiers','published',1,100,0,'points_earned','none',
           v_config);
  -- Earning resolves the EFFECTIVE config from the business, so a programme row alone earns
  -- nothing. Without this the suite silently measures zero points and proves the wrong thing.
  update public.businesses set active_config_version_id=v_config where id=v_business;

  insert into public.loyalty_tiers(business_id,name,threshold,points_multiplier,sort) values
    (v_business,'Silver',100,1,1),
    (v_business,'Gold',400,1.5,2);

  insert into public.branches(id,business_id,name,active,is_default)
  values(v_branch,v_business,'Primary',true,true);
  insert into public.staff(id,business_id,user_id,role,full_name,active)
  values(v_staff,v_business,v_owner,'owner','V256 owner',true);
  insert into public.clients(id,business_id,full_name,phone)
  values(v_client,v_business,'V256 customer','81860256');
  insert into public.services(id,business_id,name,price_cents,duration_min,active)
  values(v_svc,v_business,'V256 treatment',40000,60,true);

  -- 3. Earn 400 points through a real 400.00 sale, reaching Gold.
  perform pg_temp.as_v256_user(v_owner);
  v_eval:=public.evaluate_checkout(
    v_business,v_branch,v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',v_svc,'qty',1)),
    gen_random_uuid());
  v_sale:=public.record_cart_sale(
    p_business=>v_business,p_client=>v_client,p_branch=>v_branch,p_staff=>v_staff,
    p_method=>'cash',p_idempotency_key=>'v256-earn-'||substr(v_business::text,1,8),
    p_lines=>null,p_evaluation_id=>(v_eval->>'evaluation_id')::uuid,p_paid=>true);
  if (v_sale::jsonb->>'status')<>'ok' then
    raise exception 'v256: the earning sale did not record: %',v_sale;
  end if;

  reset role;
  select coalesce(sum(points),0) into v_earned from public.points_ledger
   where business_id=v_business and client_id=v_client and entry_type='earn';
  if v_earned<>400 then
    raise exception 'v256: fixture earned % points, expected 400',v_earned;
  end if;
  v_tier_earn:=app.loyalty_tier_for(v_business,v_client);
  v_gate_earn:=app.v176_tier_gate_metric(v_business,v_client);
  if v_tier_earn.name is distinct from 'Gold' then
    raise exception 'v256: fixture did not reach Gold on 400 earned points, got %',
      v_tier_earn.name;
  end if;

  -- 4. Spend 350 of those 400 points.
  perform pg_temp.as_v256_user(v_owner);
  perform public.adjust_points(v_business,v_client,-350,'v256 spend on a reward');

  reset role;
  select coalesce(sum(points),0) into v_balance from public.points_ledger
   where business_id=v_business and client_id=v_client;
  if v_balance<>50 then
    raise exception 'v256: spendable balance is %, expected 50',v_balance;
  end if;

  -- THE INVARIANT: 50 points left to spend, and Gold intact.
  v_tier_spend:=app.loyalty_tier_for(v_business,v_client);
  v_gate_spend:=app.v176_tier_gate_metric(v_business,v_client);
  if v_tier_spend.name is distinct from v_tier_earn.name then
    raise exception
      'v256 FAIL: spending points changed the tier (% -> %). The tier must measure LIFETIME earned.',
      v_tier_earn.name,v_tier_spend.name;
  end if;
  if v_gate_spend is distinct from v_gate_earn then
    raise exception 'v256 FAIL: the tier gate metric fell from % to % after a spend',
      v_gate_earn,v_gate_spend;
  end if;
  if (select coalesce(sum(points),0) from public.points_ledger
       where business_id=v_business and client_id=v_client and entry_type='earn')<>v_earned then
    raise exception 'v256 FAIL: spending altered the lifetime-earn total';
  end if;

  raise notice
    'v256 tier/points coexistence suite: ALL PASS (lifetime earned % held, spendable %, tier % held, gate metric %)',
    v_earned,v_balance,v_tier_spend.name,v_gate_spend;
end
$v256$;

rollback;
