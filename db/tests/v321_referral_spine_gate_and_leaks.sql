-- Rollback-only v321 acceptance: THE REFERRAL GATE MOVES ONTO THE PROGRAMME SPINE (SA-4), plus
-- the four proven referral money leaks.
--
-- v321 makes public.business_programmes(kind='referral').active the payout gate, turns
-- public.referral_programs.enabled into a PROJECTION with exactly one intended writer
-- (public.set_programmes_v314) and a structural guard that makes drift impossible, stops a $0
-- sale qualifying a paid referral, makes a reversal TERMINAL instead of re-arming, and clamps
-- the reversal clawback to what the referrer can actually give back.
--
-- ZERO LIVE TENANTS EXERCISE ALMOST ANY CHANGED BRANCH. Measured against production on
-- 2026-08-14: 0 pending referrals, 0 qualified, 2 rewarded, 5 sale reversals of which 0 touched
-- a referral, 2 referral_reward credit rows, 0 welcome offers. A green run against production
-- therefore proves ABSENCE OF REGRESSION, not presence of correctness. So every tenant shape is
-- CONSTRUCTED INSIDE THIS TRANSACTION (the W5/v314 discipline):
--
--   R1 gate-off-desynced   spine referral OFF while the legacy column says true — the shape the
--                          projection trigger normally forbids, built here with the trigger
--                          disabled, because it is the ONLY way to prove the engine reads the
--                          SPINE rather than riding on a column that happens to agree
--   R2 gate-on-desynced    the mirror image: spine ON, legacy column false
--   R3 zero-floor firm     min_spend_cents = 0 and a pending referral — QA Test Cafe's live shape
--   R4 on-without-reward   spine ON, reward_cents = 0 (reachable for the first time after v321)
--   R5 reversal tenants    a referrer with a full balance, a partly spent one, and a drained one
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v321_referral_spine_gate_and_leaks.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.
--
-- THE MUTANT MATRIX (steps 26-40) is red-first: each mutation is applied to the LIVE CATALOGUE
-- inside this same transaction, so it measures the SHIPPED BYTES and not a copy of them, and
-- each must turn a NAMED probe red. A mutant that survives is a test that proves nothing.

begin;

create temp table v319_out(seq integer, step text, outcome text) on commit drop;

create or replace function pg_temp.as_v319_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v319_system() to public;

create or replace function pg_temp.as_v319_user(p_uid uuid, p_role text default 'authenticated')
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
grant execute on function pg_temp.as_v319_user(uuid,text) to public;

-- The same identity WITHOUT the browser role: reverse_sale_v20_base and set_programmes_v314 are
-- revoked from anon/authenticated for some paths, so a step that drives them arrives the way
-- production does — through the service role — while auth.uid() still resolves to real staff.
create or replace function pg_temp.as_v319_actor(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','service_role')::text,true);
end
$$;
grant execute on function pg_temp.as_v319_actor(uuid) to public;

create or replace function pg_temp.v319_spine_active(p_business uuid, p_kind text)
returns boolean language sql stable as $$
  select spine.active from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = p_kind
$$;
grant execute on function pg_temp.v319_spine_active(uuid,text) to public;

-- A tenant with the referral module on and a published loyalty config, so a sale carries a
-- config version and the policy snapshot resolves exactly as it does in production.
create or replace function pg_temp.v319_tenant(
  p_business uuid, p_owner uuid, p_label text
) returns uuid language plpgsql as $$
declare v_config uuid := gen_random_uuid();
begin
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (p_business, p_label, lower(replace(p_label,' ','-'))||'-'||substr(p_business::text,1,8),
          'retail','SGD',
          array['dashboard','clients','sales','loyalty','referrals'], 'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v321 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;

  insert into public.staff(business_id,user_id,role,full_name,active)
  values (p_business,p_owner,'owner','V319 Owner',true);

  insert into public.firm_config_versions(id,business_id,version_no,status,published_at)
  values (v_config,p_business,1,'published',now());
  update public.businesses set active_config_version_id=v_config where id=p_business;

  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,redeem_points,
    reward_credit_cents,tier_basis,expiry_mode,expiry_days,earn_points_per_dollar,
    stamp_target,stamp_per_cents,current_config_version_id)
  values (p_business,'points',true,'points_tiers','published',100,500,'visits',
          'none',null,1.0,10,null,v_config);
  insert into public.loyalty_program_versions(
    business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,
    expiry_mode,expiry_days)
  values (p_business,v_config,'points','points_tiers',true,1.0,100,500,10,null,'visits','none',null);
  return v_config;
end
$$;
grant execute on function pg_temp.v319_tenant(uuid,uuid,text) to public;

-- Referral terms, written straight to the table so a fixture can build a shape the RPC would
-- refuse. Every projection-sensitive step below goes through the real RPC or the real switch.
create or replace function pg_temp.v319_terms(
  p_business uuid, p_reward integer, p_min integer
) returns void language plpgsql as $$
begin
  insert into public.referral_programs(business_id, enabled, reward_cents, min_spend_cents)
  values (p_business, false, p_reward, p_min)
  on conflict (business_id) do update
     set reward_cents = excluded.reward_cents, min_spend_cents = excluded.min_spend_cents;
end
$$;
grant execute on function pg_temp.v319_terms(uuid,integer,integer) to public;

-- Flip a programme through the ONE door, the way an owner does.
create or replace function pg_temp.v319_switch(p_business uuid, p_kind text, p_active boolean)
returns jsonb language plpgsql as $$
begin
  return public.set_programmes_v314(p_business, jsonb_build_object(p_kind, p_active), gen_random_uuid());
end
$$;
grant execute on function pg_temp.v319_switch(uuid,text,boolean) to public;

create or replace function pg_temp.v319_sale(
  p_business uuid, p_client uuid, p_amount integer
) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into public.sales(id,business_id,client_id,kind,amount_cents,earns_points,
                           counts_as_visit,counts_as_revenue,config_version_id,policy_resolved_at)
  values (v_id,p_business,p_client,'service',p_amount,true,true,true,
          (select active_config_version_id from public.businesses where id=p_business),now());
  return v_id;
end
$$;
grant execute on function pg_temp.v319_sale(uuid,uuid,integer) to public;

-- Drain a client's credit balance without a payments row. redemption_reversal is the one guard
-- scope that takes a negative manual_adjust with no sale and no payment.
create or replace function pg_temp.v319_spend(
  p_business uuid, p_client uuid, p_cents integer
) returns void language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  perform set_config('app.credit_ledger_insert_id',v_id::text,true);
  perform set_config('app.credit_ledger_write_scope','redemption_reversal',true);
  insert into public.credit_ledger(id,business_id,client_id,entry_type,amount_cents,reference,actor)
  values (v_id,p_business,p_client,'manual_adjust',-p_cents,'v321 fixture spend',auth.uid());
  perform set_config('app.credit_ledger_insert_id','',true);
  perform set_config('app.credit_ledger_write_scope','',true);
end
$$;
grant execute on function pg_temp.v319_spend(uuid,uuid,integer) to public;

create or replace function pg_temp.v319_balance(p_business uuid, p_client uuid)
returns integer language sql stable as $$
  select coalesce(sum(amount_cents),0)::integer from public.credit_ledger
   where business_id = p_business and client_id = p_client
$$;
grant execute on function pg_temp.v319_balance(uuid,uuid) to public;

create or replace function pg_temp.v319_referral_credits(p_business uuid, p_sale uuid)
returns bigint language sql stable as $$
  select count(*) from public.credit_ledger
   where business_id = p_business and sale_id = p_sale and entry_type = 'referral_reward'
$$;
grant execute on function pg_temp.v319_referral_credits(uuid,uuid) to public;

create or replace function pg_temp.v319_catalog_digest() returns text language sql stable as $$
  select md5(string_agg(p.oid::regprocedure::text || ':' || md5(p.prosrc), '|' order by
                        p.oid::regprocedure::text))
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public','app')
$$;
grant execute on function pg_temp.v319_catalog_digest() to public;

-- ===========================================================================================
-- THE PROBES. Each builds its own tenant, so a mutant can never contaminate the next probe, and
-- each returns 'PASS' under the shipped bytes. The mutant matrix asserts they stop saying PASS.
-- ===========================================================================================
create or replace function pg_temp.v319_probe(p_cell integer, p_owner uuid) returns text
language plpgsql as $$
declare
  b uuid := gen_random_uuid(); c1 uuid := gen_random_uuid(); c2 uuid := gen_random_uuid();
  v_sale uuid; v_res jsonb; v_n bigint; v_bal integer; v_ref uuid;
  v_before timestamptz; v_after timestamptz; v_audits bigint; v_msg text;
  v_enabled boolean; v_reward integer;
begin
  perform pg_temp.v319_tenant(b, p_owner, 'V319 Probe '||p_cell);
  insert into public.clients(id,business_id,full_name,phone)
  values (c1,b,'Probe Referrer','8100'||lpad(p_cell::text,4,'0')),
         (c2,b,'Probe Friend','8101'||lpad(p_cell::text,4,'0'));

  if p_cell in (1,2,3,4) then
    perform pg_temp.v319_terms(b, case when p_cell = 4 then 0 else 1000 end, 0);
    insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
    values (b, c1, c2, 'pending');
  end if;

  -- ---- 1. The engine reads the SPINE, not the column: spine OFF, column forced TRUE.
  if p_cell = 1 then
    alter table public.referral_programs disable trigger trg_referral_programs_projection_v321;
    update public.referral_programs set enabled = true where business_id = b;
    alter table public.referral_programs enable trigger trg_referral_programs_projection_v321;
    v_sale := pg_temp.v319_sale(b, c2, 10000);
    if pg_temp.v319_referral_credits(b, v_sale) <> 0 then return 'PAID_WITH_SPINE_OFF'; end if;
    if not exists (select 1 from public.referrals where business_id=b and status='pending') then
      return 'REFERRAL_CONSUMED_WITH_SPINE_OFF';
    end if;
    return 'PASS';
  end if;

  -- ---- 2. The mirror image: spine ON, column forced FALSE. The engine must still pay.
  if p_cell = 2 then
    perform pg_temp.v319_switch(b, 'referral', true);
    perform pg_temp.v319_terms(b, 1000, 0);
    alter table public.referral_programs disable trigger trg_referral_programs_projection_v321;
    update public.referral_programs set enabled = false where business_id = b;
    alter table public.referral_programs enable trigger trg_referral_programs_projection_v321;
    v_sale := pg_temp.v319_sale(b, c2, 10000);
    if pg_temp.v319_referral_credits(b, v_sale) <> 1 then return 'DID_NOT_PAY_WITH_SPINE_ON'; end if;
    if pg_temp.v319_balance(b, c1) <> 1000 then return 'WRONG_AMOUNT_'||pg_temp.v319_balance(b,c1); end if;
    return 'PASS';
  end if;

  -- ---- 3. L1: a $0 sale at a zero-floor firm must not pay, and must not consume the referral.
  if p_cell = 3 then
    perform pg_temp.v319_switch(b, 'referral', true);
    v_sale := pg_temp.v319_sale(b, c2, 0);
    if pg_temp.v319_referral_credits(b, v_sale) <> 0 then return 'PAID_ON_A_ZERO_DOLLAR_SALE'; end if;
    if not exists (select 1 from public.referrals where business_id=b and status='pending') then
      return 'ZERO_SALE_CONSUMED_THE_REFERRAL';
    end if;
    -- and a $1 sale at the SAME firm still pays: the predicate is >0, not "welcome offers only"
    v_sale := pg_temp.v319_sale(b, c2, 100);
    if pg_temp.v319_referral_credits(b, v_sale) <> 1 then return 'A_ONE_DOLLAR_SALE_DID_NOT_PAY'; end if;
    return 'PASS';
  end if;

  -- ---- 4. Spine ON with reward_cents = 0: the sale must SUCCEED, pay nothing, and leave the
  --         referral pending so it qualifies once a reward is configured.
  if p_cell = 4 then
    perform pg_temp.v319_switch(b, 'referral', true);
    begin
      v_sale := pg_temp.v319_sale(b, c2, 10000);
    exception when others then
      get stacked diagnostics v_msg = message_text;
      return 'SALE_INSERT_FAILED (till outage shape): '||v_msg;
    end;
    if pg_temp.v319_referral_credits(b, v_sale) <> 0 then return 'PAID_A_ZERO_REWARD'; end if;
    if not exists (select 1 from public.referrals where business_id=b and status='pending') then
      return 'ZERO_REWARD_CONSUMED_THE_REFERRAL';
    end if;
    -- configure a reward; the NEXT qualifying sale pays
    perform pg_temp.v319_terms(b, 1000, 0);
    v_sale := pg_temp.v319_sale(b, c2, 10000);
    if pg_temp.v319_referral_credits(b, v_sale) <> 1 then return 'DID_NOT_PAY_AFTER_A_REWARD_WAS_SET'; end if;
    return 'PASS';
  end if;

  -- ---- 5. L2: a reversal is terminal and preserves what was paid.
  if p_cell = 5 then
    perform pg_temp.v319_switch(b, 'referral', true);
    perform pg_temp.v319_terms(b, 1000, 0);
    insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
    values (b, c1, c2, 'pending') returning id into v_ref;
    v_sale := pg_temp.v319_sale(b, c2, 10000);
    perform public.reverse_sale_v20_base(b, v_sale, 'v321 probe reversal of a qualified sale',
                                         'v319probe'||substr(v_sale::text,1,12), null, 'none');
    if not exists (select 1 from public.referrals where id = v_ref and status = 'reversed'
                     and reversed_at is not null and reversed_sale_id is not null) then
      return 'NOT_TERMINAL: '||(select status from public.referrals where id = v_ref);
    end if;
    if not exists (select 1 from public.referrals where id = v_ref
                     and reward_cents = 1000 and qualified_sale_id = v_sale) then
      return 'REVERSAL_DESTROYED_THE_RECORD_OF_WHAT_WAS_PAID';
    end if;
    -- the next qualifying sale must NOT pay again
    v_sale := pg_temp.v319_sale(b, c2, 10000);
    if pg_temp.v319_referral_credits(b, v_sale) <> 0 then return 'PAID_A_SECOND_TIME_AFTER_REVERSAL'; end if;
    return 'PASS';
  end if;

  -- ---- 6. L3 partial: the referrer spent $6 of a $10 reward. Clawback is $4, the balance lands
  --         at 0 and NOT at -$6, and the shortfall is audited.
  if p_cell = 6 then
    perform pg_temp.v319_switch(b, 'referral', true);
    perform pg_temp.v319_terms(b, 1000, 0);
    insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
    values (b, c1, c2, 'pending') returning id into v_ref;
    v_sale := pg_temp.v319_sale(b, c2, 10000);
    perform pg_temp.v319_spend(b, c1, 600);
    perform public.reverse_sale_v20_base(b, v_sale, 'v321 probe partial recovery reversal',
                                         'v319part'||substr(v_sale::text,1,12), null, 'none');
    v_bal := pg_temp.v319_balance(b, c1);
    if v_bal <> 0 then return 'BALANCE_LANDED_AT_'||v_bal||'_NOT_ZERO'; end if;
    select count(*) into v_n from public.audit_log
     where business_id = b and action = 'REFERRAL_CLAWBACK_SHORTFALL_V321'
       and (detail->>'shortfall_cents')::int = 600;
    if v_n <> 1 then return 'SHORTFALL_AUDIT_ROWS_'||v_n; end if;
    return 'PASS';
  end if;

  -- ---- 7. L3 zero: the referrer spent everything. NO ledger row at all (a 0-amount row is a
  --         write-guard check_violation), one shortfall audit, and the reversal SUCCEEDS.
  if p_cell = 7 then
    perform pg_temp.v319_switch(b, 'referral', true);
    perform pg_temp.v319_terms(b, 1000, 0);
    insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
    values (b, c1, c2, 'pending') returning id into v_ref;
    v_sale := pg_temp.v319_sale(b, c2, 10000);
    perform pg_temp.v319_spend(b, c1, 1000);
    begin
      perform public.reverse_sale_v20_base(b, v_sale, 'v321 probe zero recovery reversal',
                                           'v319zero'||substr(v_sale::text,1,12), null, 'none');
    exception when others then
      get stacked diagnostics v_msg = message_text;
      return 'REVERSAL_FAILED: '||v_msg;
    end;
    select count(*) into v_n from public.credit_ledger
     where business_id = b and client_id = c1 and entry_type = 'manual_adjust'
       and reference like 'sale reversal: referral reward clawback%';
    if v_n <> 0 then return 'WROTE_A_CLAWBACK_ROW_WITH_NOTHING_TO_RECOVER'; end if;
    select count(*) into v_n from public.audit_log
     where business_id = b and action = 'REFERRAL_CLAWBACK_SHORTFALL_V321'
       and (detail->>'shortfall_cents')::int = 1000;
    if v_n <> 1 then return 'SHORTFALL_AUDIT_ROWS_'||v_n; end if;
    if not exists (select 1 from public.sale_reversal_audits
                    where business_id = b and original_sale_id = v_sale and referral_reversed) then
      return 'AUDIT_DID_NOT_RECORD_referral_reversed';
    end if;
    return 'PASS';
  end if;

  -- ---- 8. RULING R-A: save_referral_program cannot move the switch, and says so in the audit.
  if p_cell = 8 then
    perform pg_temp.as_v319_user(p_owner);
    v_res := public.save_referral_program(b, true, 1500, 2000);
    perform pg_temp.as_v319_actor(p_owner);
    if coalesce(pg_temp.v319_spine_active(b,'referral'), false) then
      return 'A_TERMS_RPC_MOVED_THE_SPINE';
    end if;
    if (v_res->>'enabled')::boolean then return 'ENVELOPE_REPORTED_AN_OPTIMISTIC_ENABLED'; end if;
    select enabled, reward_cents into v_enabled, v_reward
      from public.referral_programs where business_id = b;
    if v_enabled then return 'PROJECTION_DRIFTED_ON_THE_TERMS_PATH'; end if;
    if v_reward <> 1500 then return 'TERMS_WERE_NOT_SAVED'; end if;
    select count(*) into v_n from public.audit_log
     where business_id = b and action = 'REFERRAL_ENABLED_WRITE_SUPPRESSED_V321';
    if v_n < 1 then return 'THE_SUPPRESSED_SWITCH_WAS_NOT_AUDITED'; end if;
    return 'PASS';
  end if;

  -- ---- 9. The switch SEEDS a referral_programs row at reward_cents = 0 — never the column
  --         default of 1000. Never invent a payout.
  if p_cell = 9 then
    if exists (select 1 from public.referral_programs where business_id = b) then
      return 'FIXTURE_ALREADY_HAD_A_ROW';
    end if;
    perform pg_temp.v319_switch(b, 'referral', true);
    select enabled, reward_cents into v_enabled, v_reward
      from public.referral_programs where business_id = b;
    if v_enabled is null then return 'THE_SWITCH_SEEDED_NO_ROW'; end if;
    if not v_enabled then return 'THE_SEEDED_ROW_DID_NOT_FOLLOW_THE_SWITCH'; end if;
    if v_reward <> 0 then return 'THE_SEED_INVENTED_A_PAYOUT_OF_'||v_reward; end if;
    -- and switching OFF projects false without touching the terms
    perform pg_temp.v319_terms(b, 700, 300);
    perform pg_temp.v319_switch(b, 'referral', false);
    select enabled, reward_cents into v_enabled, v_reward
      from public.referral_programs where business_id = b;
    if v_enabled then return 'OFF_DID_NOT_PROJECT'; end if;
    if v_reward <> 700 then return 'OFF_CLOBBERED_THE_TERMS'; end if;
    return 'PASS';
  end if;

  -- ---- 10. A no-op flip writes NOTHING: no breadcrumb churn, no audit row, no projection write.
  if p_cell = 10 then
    perform pg_temp.v319_switch(b, 'referral', true);
    select count(*) into v_audits from public.audit_log
     where business_id = b and action = 'PROGRAMME_SWITCH_V314';
    select activated_at into v_before from public.business_programmes
     where business_id = b and kind = 'referral';
    perform pg_temp.v319_switch(b, 'referral', true);       -- same value again
    select activated_at into v_after from public.business_programmes
     where business_id = b and kind = 'referral';
    select count(*) into v_n from public.audit_log
     where business_id = b and action = 'PROGRAMME_SWITCH_V314';
    if v_n <> v_audits then return 'A_NO_OP_FLIP_WROTE_'||(v_n - v_audits)||'_AUDIT_ROWS'; end if;
    if v_after is distinct from v_before then return 'A_NO_OP_FLIP_CHURNED_THE_BREADCRUMB'; end if;
    return 'PASS';
  end if;

  -- ---- 11. Breadcrumbs are v314's semantics exactly: NEITHER is ever cleared.
  if p_cell = 11 then
    perform pg_temp.v319_switch(b, 'referral', true);
    perform pg_temp.v319_switch(b, 'referral', false);
    select deactivated_at into v_before from public.business_programmes
     where business_id = b and kind = 'referral';
    if v_before is null then return 'DEACTIVATED_AT_WAS_NOT_STAMPED'; end if;
    perform pg_temp.v319_switch(b, 'referral', true);       -- re-activate
    select deactivated_at into v_after from public.business_programmes
     where business_id = b and kind = 'referral';
    if v_after is distinct from v_before then return 'RE_ACTIVATION_CLEARED_DEACTIVATED_AT'; end if;
    if (select activated_at from public.business_programmes
         where business_id = b and kind = 'referral') is null then
      return 'ACTIVATED_AT_WAS_LOST';
    end if;
    return 'PASS';
  end if;

  -- ---- 12. A MANAGER keeps the ability to save referral TERMS. That boundary is unchanged, and
  --          narrowing it silently would be a permission regression nobody asked for.
  if p_cell = 12 then
    declare v_mgr uuid := gen_random_uuid();
    begin
      insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                             email_confirmed_at,created_at,updated_at)
      values ('00000000-0000-0000-0000-000000000000',v_mgr,'authenticated','authenticated',
              'v321-mgr-'||substr(v_mgr::text,1,8)||'@example.test','',now(),now(),now());
      insert into public.staff(business_id,user_id,role,full_name,active)
      values (b,v_mgr,'manager','V319 Manager',true);
      perform pg_temp.as_v319_user(v_mgr);
      v_res := public.save_referral_program(b, false, 2500, 100);
      perform pg_temp.as_v319_actor(p_owner);
      if (v_res->>'reward_cents')::int <> 2500 then return 'A_MANAGER_COULD_NOT_SAVE_TERMS'; end if;
      return 'PASS';
    exception when others then
      get stacked diagnostics v_msg = message_text;
      perform pg_temp.as_v319_actor(p_owner);
      return 'A_MANAGER_WAS_REFUSED: '||v_msg;
    end;
  end if;

  -- ---- 13. THE PROJECTION CANNOT DRIFT. A rogue direct write is forced back onto the spine.
  if p_cell = 13 then
    perform pg_temp.v319_terms(b, 1000, 0);                  -- spine still OFF
    update public.referral_programs set enabled = true where business_id = b;
    select enabled into v_enabled from public.referral_programs where business_id = b;
    if v_enabled then return 'DRIFT: A_DIRECT_UPDATE_MOVED_THE_PROJECTION'; end if;
    select count(*) into v_n from public.audit_log
     where business_id = b and action = 'REFERRAL_ENABLED_WRITE_SUPPRESSED_V321'
       and detail->>'source' = 'referral_programs_projection_v321';
    if v_n <> 1 then return 'THE_CORRECTION_WAS_NOT_AUDITED ('||v_n||')'; end if;
    return 'PASS';
  end if;

  return 'UNKNOWN_PROBE';
end
$$;
grant execute on function pg_temp.v319_probe(integer,uuid) to public;

-- The mutant driver: mutate the LIVE catalogue, run the named probe, restore. Returns the
-- probe's verdict under the mutation. A mutant is LETHAL when that verdict is not 'PASS'.
create or replace function pg_temp.v319_mutant(
  p_signature text, p_old text, p_new text, p_probe integer, p_owner uuid
) returns text language plpgsql as $$
declare v_def text; v_o integer; v_verdict text; v_msg text;
begin
  select pg_get_functiondef(to_regprocedure(p_signature)) into strict v_def;
  v_o := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  if v_o <> 1 then
    return 'MUTANT_NEEDLE_MATCHED_'||v_o||'_TIMES (the shipped bytes are not what this test thinks)';
  end if;
  execute replace(v_def, p_old, p_new);
  begin
    v_verdict := pg_temp.v319_probe(p_probe, p_owner);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    v_verdict := 'RAISED: '||v_msg;
  end;
  execute v_def;                                             -- restore the shipped bytes
  return v_verdict;
end
$$;
grant execute on function pg_temp.v319_mutant(text,text,text,integer,uuid) to public;

do $v319_test$
declare
  v_owner uuid := gen_random_uuid();
  v_stranger uuid := gen_random_uuid();
  v_msg text; v_n bigint; v_verdict text; v_row record;
  v_digest_before text; v_digest_after text;
  b uuid; c1 uuid; c2 uuid; v_sale uuid; v_res jsonb; v_replay jsonb;
  v_def text;
begin
  perform pg_temp.as_v319_system();

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
          'v321-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_stranger,'authenticated','authenticated',
          'v321-stranger-'||substr(v_stranger::text,1,8)||'@example.test','',now(),now(),now());

  v_digest_before := pg_temp.v319_catalog_digest();
  perform pg_temp.as_v319_actor(v_owner);

  -- =========================================================================
  -- STEPS 1-13. The behaviour of the shipped bytes, one probe each.
  -- =========================================================================
  for v_row in
    select * from (values
      (1, 1,  'L4: spine OFF pays nothing even when the legacy column says true (the gate MOVED)'),
      (2, 2,  'L4: spine ON pays even when the legacy column says false (the gate is the SPINE)'),
      (3, 3,  'L1: a $0 sale never qualifies a paid referral; a $1 sale at the same firm does'),
      (4, 4,  'spine ON with reward_cents=0 captures, pays nothing, and does not break the till'),
      (5, 5,  'L2: a reversal is TERMINAL, preserves what was paid, and cannot pay twice'),
      (6, 6,  'L3: a partly spent reward claws back what is there; the balance lands at 0, not negative'),
      (7, 7,  'L3: a fully spent reward writes NO ledger row, audits the shortfall, and the reversal succeeds'),
      (8, 8,  'R-A: save_referral_program cannot move the switch, and audits the attempt'),
      (9, 9,  'the switch seeds referral_programs at reward_cents=0 and never clobbers terms'),
      (10,10, 'a no-op referral flip writes nothing at all'),
      (11,11, 'breadcrumbs are v314 semantics: neither activated_at nor deactivated_at is ever cleared'),
      (12,12, 'a MANAGER can still save referral terms (no silent permission regression)'),
      (13,13, 'the projection cannot drift: a rogue direct write is forced back and audited')
    ) t(seq, probe, label)
    order by seq
  loop
    begin
      v_verdict := pg_temp.v319_probe(v_row.probe, v_owner);
      insert into v319_out values (v_row.seq, v_row.label,
        case when v_verdict = 'PASS' then 'PASS' else 'FAIL: '||v_verdict end);
    exception when others then
      get stacked diagnostics v_msg = message_text;
      perform pg_temp.as_v319_actor(v_owner);
      insert into v319_out values (v_row.seq, v_row.label, 'FAIL: '||v_msg);
    end;
  end loop;

  -- =========================================================================
  -- STEP 14. The live QA Test Cafe shape, end to end: a welcome-offer redemption inserts a $0
  --   sale of kind service/retail, both of which app.sale_policy_defaults() counts as a visit.
  --   Before v321 that paid the referrer real store credit. This is the leak as it is REACHABLE
  --   TODAY at dcaaf5d6, reproduced rather than argued about.
  -- =========================================================================
  begin
    b := gen_random_uuid(); c1 := gen_random_uuid(); c2 := gen_random_uuid();
    perform pg_temp.v319_tenant(b, v_owner, 'V319 Welcome Offer');
    insert into public.clients(id,business_id,full_name,phone)
    values (c1,b,'WO Referrer','81009001'),(c2,b,'WO Friend','81009002');
    perform pg_temp.v319_switch(b, 'referral', true);
    perform pg_temp.v319_terms(b, 1000, 0);
    insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
    values (b, c1, c2, 'pending');
    -- the welcome-offer redemption's own sale shape, verbatim from the live body
    v_sale := gen_random_uuid();
    insert into public.sales(id, business_id, client_id, kind, amount_cents, note,
                             config_version_id, policy_resolved_at)
    values (v_sale, b, c2, 'service', 0, 'welcome offer redeemed: v321 fixture',
            (select active_config_version_id from public.businesses where id=b), now());
    insert into v319_out values (14,
      'the LIVE QA Test Cafe shape: a $0 welcome-offer redemption pays the referrer nothing',
      case when not exists (select 1 from public.sales s where s.id = v_sale and s.counts_as_visit)
             then 'FAIL: the fixture sale did not count as a visit, so it proves nothing'
           when pg_temp.v319_referral_credits(b, v_sale) <> 0
             then 'FAIL: a $0 welcome-offer redemption paid a referral reward'
           when not exists (select 1 from public.referrals where business_id=b and status='pending')
             then 'FAIL: the $0 sale consumed the referral'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v319_actor(v_owner);
    insert into v319_out values (14, 'the LIVE QA Test Cafe shape: a $0 welcome-offer redemption pays the referrer nothing',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 15. L3 full recovery: an untouched balance gives the whole reward back, with NO
  --   shortfall audit — the clamp must not fire when there is nothing to clamp.
  -- =========================================================================
  begin
    b := gen_random_uuid(); c1 := gen_random_uuid(); c2 := gen_random_uuid();
    perform pg_temp.v319_tenant(b, v_owner, 'V319 Full Recovery');
    insert into public.clients(id,business_id,full_name,phone)
    values (c1,b,'FR Referrer','81009101'),(c2,b,'FR Friend','81009102');
    perform pg_temp.v319_switch(b, 'referral', true);
    perform pg_temp.v319_terms(b, 1000, 0);
    insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
    values (b, c1, c2, 'pending');
    v_sale := pg_temp.v319_sale(b, c2, 10000);
    perform public.reverse_sale_v20_base(b, v_sale, 'v321 full recovery reversal test',
                                         'v319full'||substr(v_sale::text,1,12), null, 'none');
    insert into v319_out values (15,
      'L3: an untouched referrer balance gives the WHOLE reward back and writes no shortfall audit',
      case when pg_temp.v319_balance(b, c1) <> 0
             then 'FAIL: balance landed at '||pg_temp.v319_balance(b, c1)||' not 0'
           when (select count(*) from public.audit_log where business_id=b
                  and action='REFERRAL_CLAWBACK_SHORTFALL_V321') <> 0
             then 'FAIL: a shortfall was audited on a full recovery'
           when not exists (select 1 from public.credit_ledger where business_id=b and client_id=c1
                             and entry_type='manual_adjust' and amount_cents = -1000)
             then 'FAIL: the full clawback row is missing or the wrong amount'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v319_actor(v_owner);
    insert into v319_out values (15, 'L3: an untouched referrer balance gives the WHOLE reward back and writes no shortfall audit',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 16. Reversal idempotency survives the splice: the same key replays the stored result and
  --   writes no second clawback.
  -- =========================================================================
  begin
    b := gen_random_uuid(); c1 := gen_random_uuid(); c2 := gen_random_uuid();
    perform pg_temp.v319_tenant(b, v_owner, 'V319 Replay');
    insert into public.clients(id,business_id,full_name,phone)
    values (c1,b,'RP Referrer','81009201'),(c2,b,'RP Friend','81009202');
    perform pg_temp.v319_switch(b, 'referral', true);
    perform pg_temp.v319_terms(b, 1000, 0);
    insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
    values (b, c1, c2, 'pending');
    v_sale := pg_temp.v319_sale(b, c2, 10000);
    v_res := public.reverse_sale_v20_base(b, v_sale, 'v321 replay idempotency reversal',
                                          'v319rep'||substr(v_sale::text,1,13), null, 'none');
    v_replay := public.reverse_sale_v20_base(b, v_sale, 'v321 replay idempotency reversal',
                                             'v319rep'||substr(v_sale::text,1,13), null, 'none');
    select count(*) into v_n from public.credit_ledger
     where business_id = b and client_id = c1 and entry_type = 'manual_adjust';
    insert into v319_out values (16,
      'reversal idempotency: the same key replays and writes no second clawback',
      case when v_n <> 1 then 'FAIL: '||v_n||' clawback rows after a replay'
           when (v_replay->>'reversal_sale_id') is distinct from (v_res->>'reversal_sale_id')
             then 'FAIL: the replay minted a second reversal sale'
           when pg_temp.v319_balance(b, c1) <> 0
             then 'FAIL: the replay moved the balance to '||pg_temp.v319_balance(b, c1)
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v319_actor(v_owner);
    insert into v319_out values (16, 'reversal idempotency: the same key replays and writes no second clawback',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 17. staff_rearm_referral_v321: the escape hatch, and its three refusals.
  -- =========================================================================
  begin
    b := gen_random_uuid(); c1 := gen_random_uuid(); c2 := gen_random_uuid();
    perform pg_temp.v319_tenant(b, v_owner, 'V319 Rearm');
    insert into public.clients(id,business_id,full_name,phone)
    values (c1,b,'RA Referrer','81009301'),(c2,b,'RA Friend','81009302');
    perform pg_temp.v319_switch(b, 'referral', true);
    perform pg_temp.v319_terms(b, 1000, 0);
    insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
    values (b, c1, c2, 'pending');
    v_sale := pg_temp.v319_sale(b, c2, 10000);
    perform public.reverse_sale_v20_base(b, v_sale, 'v321 re-arm fixture reversal',
                                         'v319arm'||substr(v_sale::text,1,13), null, 'none');
    v_msg := 'PASS';

    perform pg_temp.as_v319_user(v_owner);
    begin
      perform public.staff_rearm_referral_v321(b,
        (select id from public.referrals where business_id=b), 'too short');
      v_msg := 'FAIL: a sub-10-character reason was accepted';
    exception when others then
      if sqlstate <> '22023' then v_msg := 'FAIL: wrong errcode for a short reason: '||sqlstate; end if;
    end;

    perform pg_temp.as_v319_user(v_stranger);
    begin
      perform public.staff_rearm_referral_v321(b,
        (select id from public.referrals where business_id=b), 'a stranger should never re-arm this');
      v_msg := 'FAIL: a caller with no refund_sales permission re-armed a referral';
    exception when others then
      if sqlstate <> '42501' then v_msg := 'FAIL: wrong errcode for a stranger: '||sqlstate; end if;
    end;

    perform pg_temp.as_v319_user(v_owner);
    perform public.staff_rearm_referral_v321(b,
      (select id from public.referrals where business_id=b), 'the refund was keyed to the wrong sale');
    if not exists (select 1 from public.referrals where business_id=b and status='pending'
                     and reversed_at is null and reversed_sale_id is null
                     and qualified_sale_id is null and reward_cents = 0) then
      v_msg := 'FAIL: the re-arm did not fully reset the referral into the pool';
    end if;
    if not exists (select 1 from public.audit_log where business_id=b
                     and action='REFERRAL_REARMED_V321'
                     and (detail->>'previous_reward_cents')::int = 1000) then
      v_msg := 'FAIL: the re-arm was not audited with what had been paid';
    end if;
    begin
      perform public.staff_rearm_referral_v321(b,
        (select id from public.referrals where business_id=b), 'this one is already pending again');
      v_msg := 'FAIL: a non-reversed referral was re-armed';
    exception when others then
      if sqlstate <> '22023' then v_msg := 'FAIL: wrong errcode for a non-reversed referral: '||sqlstate; end if;
    end;
    perform pg_temp.as_v319_actor(v_owner);
    insert into v319_out values (17,
      'staff_rearm_referral_v321 resets a reversed referral, audits it, and refuses three bad calls', v_msg);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v319_actor(v_owner);
    insert into v319_out values (17, 'staff_rearm_referral_v321 resets a reversed referral, audits it, and refuses three bad calls',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 18. The owner gate on the SWITCH is unchanged: a manager cannot flip a programme, and a
  --   stranger cannot touch the terms. R-A's whole point is that this boundary did not move.
  -- =========================================================================
  begin
    b := gen_random_uuid();
    perform pg_temp.v319_tenant(b, v_owner, 'V319 Gates');
    v_msg := 'PASS';
    perform pg_temp.as_v319_user(v_stranger);
    begin
      perform public.set_programmes_v314(b, '{"referral":true}'::jsonb, gen_random_uuid());
      v_msg := 'FAIL: a stranger flipped a programme switch';
    exception when others then
      if sqlstate <> '42501' then v_msg := 'FAIL: wrong errcode for a stranger switch: '||sqlstate; end if;
    end;
    begin
      perform public.save_referral_program(b, false, 100, 0);
      v_msg := 'FAIL: a stranger saved referral terms';
    exception when others then
      if sqlstate <> '42501' then v_msg := 'FAIL: wrong errcode for a stranger save: '||sqlstate; end if;
    end;
    perform pg_temp.as_v319_actor(v_owner);
    insert into v319_out values (18,
      'the owner gate on the switch and the module gate on the terms are both unchanged', v_msg);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v319_actor(v_owner);
    insert into v319_out values (18, 'the owner gate on the switch and the module gate on the terms are both unchanged',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 19. THE ACL FLOOR. authenticated may not write business_programmes or referral_programs
  --   directly. If it could, the projection guard would be one UPDATE away from irrelevant.
  -- =========================================================================
  begin
    v_msg := 'PASS';
    perform pg_temp.as_v319_user(v_owner);
    begin
      update public.business_programmes set active = true where kind = 'referral';
      v_msg := 'FAIL: authenticated updated business_programmes directly';
    exception when others then null; end;
    begin
      update public.referral_programs set enabled = true;
      v_msg := 'FAIL: authenticated updated referral_programs directly';
    exception when others then null; end;
    perform pg_temp.as_v319_actor(v_owner);
    insert into v319_out values (19,
      'the ACL floor holds: authenticated cannot write the spine or the projection directly', v_msg);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v319_actor(v_owner);
    insert into v319_out values (19, 'the ACL floor holds: authenticated cannot write the spine or the projection directly',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 20. POT ROUTING IS UNCHANGED. A referral flip is not an accruing-identity change and
  --   must never enqueue a pot migration (V311/V312 standing invariant 2).
  -- =========================================================================
  begin
    b := gen_random_uuid();
    perform pg_temp.v319_tenant(b, v_owner, 'V319 Pot');
    select count(*) into v_n from public.programme_pot_migrations where business_id = b;
    v_res := pg_temp.v319_switch(b, 'referral', true);
    insert into v319_out values (20,
      'a referral flip never routes a pot, and the switch envelope keeps its shape',
      case when (select count(*) from public.programme_pot_migrations where business_id=b) <> v_n
             then 'FAIL: a referral flip enqueued a pot migration'
           when v_res->>'pot_migration_id' is not null
             then 'FAIL: the envelope reported a pot migration for a referral flip'
           when v_res->'programmes' is null or jsonb_array_length(v_res->'programmes') <> 4
             then 'FAIL: the switch envelope no longer carries four programmes'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v319_actor(v_owner);
    insert into v319_out values (20, 'a referral flip never routes a pot, and the switch envelope keeps its shape',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 21. app.business_programmes_v307's referral limb now AGREES WITH THE SPINE BY
  --   CONSTRUCTION — a strictly stronger property than it holds for points/tiers/stamps, gained
  --   without touching v307 at all.
  -- =========================================================================
  begin
    b := gen_random_uuid();
    perform pg_temp.v319_tenant(b, v_owner, 'V319 V307');
    v_msg := 'PASS';
    perform pg_temp.v319_switch(b, 'referral', true);
    if not (select model.running from app.business_programmes_v307(b) model where model.kind='referral') then
      v_msg := 'FAIL: v307 says referral is off while the spine says on';
    end if;
    perform pg_temp.v319_switch(b, 'referral', false);
    if (select model.running from app.business_programmes_v307(b) model where model.kind='referral') then
      v_msg := 'FAIL: v307 says referral is on while the spine says off';
    end if;
    if exists (select 1 from app.detect_spine_legacy_divergence_v314() d
                where d.business_id = b and d.kind = 'referral') then
      v_msg := 'FAIL: referral can still diverge from the spine';
    end if;
    insert into v319_out values (21,
      'v307''s referral limb can no longer diverge from the spine (v307 itself untouched)', v_msg);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.as_v319_actor(v_owner);
    insert into v319_out values (21, 'v307''s referral limb can no longer diverge from the spine (v307 itself untouched)',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 22. RULING R-H. The spine/legacy divergence detector is a REPORT. It is non-empty in
  --   production (Cubbly / tiers, a real owner switch) and this suite must NEVER assert it empty.
  --   What it DOES assert is the narrower, earned claim: no REFERRAL row in it.
  -- =========================================================================
  begin
    select count(*) into v_n from app.detect_spine_legacy_divergence_v314();
    for v_row in select * from app.detect_spine_legacy_divergence_v314() loop
      raise notice 'v321 suite REPORT (ruling R-H, never an assertion): % / % spine=% legacy=%',
        v_row.business_name, v_row.kind, v_row.spine_active, v_row.legacy_running;
    end loop;
    insert into v319_out values (22,
      'the spine/legacy divergence detector is REPORTED ('||v_n||' row(s)), never asserted; zero of them referral',
      case when exists (select 1 from app.detect_spine_legacy_divergence_v314() where kind='referral')
             then 'FAIL: referral appears in the divergence detector after the projection'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into v319_out values (22, 'the spine/legacy divergence detector is REPORTED, never asserted; zero of them referral',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 23. The gate detector's assertion limbs are empty across the whole estate, fixtures
  --   included; the two standing money detectors are empty; every business holds four spine rows.
  -- =========================================================================
  begin
    insert into v319_out values (23,
      'gate assertion limbs empty, pot-split and double-earn empty, four spine rows everywhere',
      case when (select count(*) from app.detect_referral_gate_desync_v321()
                  where reason in ('spine_vs_enabled','spine_on_without_row')) <> 0
             then 'FAIL: the referral gate detector reports an assertion row'
           when (select count(*) from app.detect_programme_pot_split_v312()) <> 0
             then 'FAIL: the pot-split detector is not empty'
           when (select count(*) from app.detect_double_earn_v309()) <> 0
             then 'FAIL: the double-earn detector is not empty'
           when exists (select 1 from public.businesses b
                         where (select count(*) from public.business_programmes s
                                 where s.business_id=b.id) <> 4)
             then 'FAIL: a business does not hold exactly four spine rows'
           else 'PASS' end);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into v319_out values (23, 'gate assertion limbs empty, pot-split and double-earn empty, four spine rows everywhere',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 24. RULING R-A, ASSERTED AS AN ABSENCE, and the one-writer property, asserted at the
  --   bytes. This is the step that fails if someone later "helpfully" adds the shared helper.
  -- =========================================================================
  begin
    v_msg := 'PASS';
    if to_regprocedure('app.set_programme_active_v321(uuid,text,boolean,text)') is not null then
      v_msg := 'FAIL: a second spine writer (app.set_programme_active_v321) exists';
    end if;
    select pg_get_functiondef('public.save_referral_program(uuid,boolean,integer,integer)'::regprocedure)
      into v_def;
    if position('update public.business_programmes' in v_def) > 0
       or position('insert into public.business_programmes' in v_def) > 0 then
      v_msg := 'FAIL: save_referral_program writes the spine';
    end if;
    if position('enabled = excluded.enabled' in v_def) > 0 then
      v_msg := 'FAIL: save_referral_program still projects enabled in its DO UPDATE list';
    end if;
    select count(*) into v_n from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname in ('public','app')
       and position('update public.business_programmes' in p.prosrc) > 0;
    if v_n <> 1 then
      v_msg := 'FAIL: '||v_n||' functions update business_programmes (expected exactly 1: set_programmes_v314)';
    end if;
    insert into v319_out values (24,
      'R-A: set_programmes_v314 is still the ONE writer of the spine, and no helper exists', v_msg);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into v319_out values (24, 'R-A: set_programmes_v314 is still the ONE writer of the spine, and no helper exists',
      'FAIL: '||v_msg);
  end;

  -- =========================================================================
  -- STEP 25. The catalogue is byte-stable across this whole read-only-ish suite: the mutant
  --   driver restored every body it touched. Recorded here BEFORE the mutants run, and again at
  --   step 41 after them.
  -- =========================================================================
  v_digest_after := pg_temp.v319_catalog_digest();
  insert into v319_out values (25, 'the function catalogue is byte-identical to the suite''s start',
    case when v_digest_after is distinct from v_digest_before
           then 'FAIL: a step mutated the catalogue and did not restore it'
         else 'PASS' end);

  -- =========================================================================
  -- STEPS 26-40. THE RED-FIRST MUTANT MATRIX. Each mutation is applied to the LIVE CATALOGUE, so
  --   it measures the shipped bytes. Each must turn its NAMED probe red.
  -- =========================================================================
  for v_row in
    select * from (values
      (26,'M1','app.on_sale_recorded()',
          $m$from public.referral_programs where business_id=new.business_id limit 1;$m$,
          $m$from public.referral_programs where business_id=new.business_id and enabled limit 1;$m$,
          2, 'restoring `and enabled` on the lookup must break cell 2 (spine ON, column false)'),
      (27,'M2','app.on_sale_recorded()',
          $m$ and exists(select 1 from public.business_programmes spine where spine.business_id=new.business_id and spine.kind='referral' and spine.active)$m$,
          $m$$m$,
          1, 'dropping the spine conjunct must break cell 1 (spine OFF, column true)'),
      (28,'M3','app.on_sale_recorded()',
          $m$ and new.amount_cents>0$m$, $m$$m$,
          3, 'dropping `new.amount_cents>0` must break cell 3 (the $0 leak reopens)'),
      (29,'M4','app.on_sale_recorded()',
          $m$coalesce(refprog.reward_cents,0)>0 and $m$, $m$$m$,
          4, 'dropping the zero-reward guard must break cell 4 — and the SALE INSERT must fail'),
      (30,'M5','public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)',
          $m$       set status = 'reversed',$m$, $m$       set status = 'pending',$m$,
          5, 'reverting the reversal to pending must break cell 5 (the referral pays twice)'),
      (31,'M6','public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)',
          $m$      -v_referral_clawback_cents,
      'sale reversal: referral reward clawback for sale ' || o.id,$m$,
          $m$      -v_referral.reward_cents,
      'sale reversal: referral reward clawback for sale ' || o.id,$m$,
          6, 'removing the clamp must break cell 6 (the balance goes negative)'),
      (32,'M7','public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)',
          $m$    if v_referral_clawback_cents > 0 then$m$,
          $m$    if v_referral_clawback_cents >= 0 then$m$,
          7, 'clamping to zero and still inserting must break cell 7 (write-guard check_violation)'),
      (33,'M8','public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)',
          $m$    if v_referral_shortfall_cents > 0 then$m$,
          $m$    if false then$m$,
          6, 'dropping the shortfall audit must break cell 6'),
      (34,'M9','public.save_referral_program(uuid,boolean,integer,integer)',
          $m$  if p_enabled is distinct from v_spine then$m$,
          $m$  if false then$m$,
          8, 'dropping the suppression audit must break cell 8 (the attempt goes unrecorded)'),
      (35,'M10','public.set_programmes_v314(uuid,jsonb,uuid)',
          $m$      if v_kind = 'referral' then$m$, $m$      if false then$m$,
          9, 'removing the projection write must break cell 9 (the switch seeds no row)'),
      (36,'M11','public.set_programmes_v314(uuid,jsonb,uuid)',
          $m$        values (p_business, v_want, 0, 0)$m$,
          $m$        values (p_business, v_want, 1000, 0)$m$,
          9, 'seeding the column default must break cell 9 (a toggle commits the firm to $10)'),
      (37,'M12','public.set_programmes_v314(uuid,jsonb,uuid)',
          $m$    if v_before is distinct from v_want then$m$, $m$    if true then$m$,
          10, 'removing the no-op guard must break cell 10 (breadcrumb and audit churn)'),
      (38,'M13','public.set_programmes_v314(uuid,jsonb,uuid)',
          $m$             deactivated_at = case when spine.active and not v_want then now()
                                   else spine.deactivated_at end$m$,
          $m$             deactivated_at = case when spine.active and not v_want then now()
                                   else null end$m$,
          11, 'letting a re-activation clear deactivated_at must break cell 11'),
      (39,'M14','public.save_referral_program(uuid,boolean,integer,integer)',
          $m$app.can_module_write(p_business, 'referrals')$m$,
          $m$app.c45_owner_loyalty_write(p_business)$m$,
          12, 'narrowing the terms gate to owner-only must break cell 12 (manager regression)'),
      (40,'M15','','','', 13,
          'dropping the projection trigger must break cell 13 (drift becomes possible again)')
    ) t(seq, tag, signature, old_text, new_text, probe, label)
    order by seq
  loop
    begin
      if v_row.tag = 'M15' then
        -- the one mutant that is a trigger, not a body
        alter table public.referral_programs disable trigger trg_referral_programs_projection_v321;
        begin
          v_verdict := pg_temp.v319_probe(v_row.probe, v_owner);
        exception when others then
          get stacked diagnostics v_msg = message_text; v_verdict := 'RAISED: '||v_msg;
        end;
        alter table public.referral_programs enable trigger trg_referral_programs_projection_v321;
      else
        v_verdict := pg_temp.v319_mutant(v_row.signature, v_row.old_text, v_row.new_text,
                                         v_row.probe, v_owner);
      end if;
      insert into v319_out values (v_row.seq, v_row.tag||': '||v_row.label,
        case when v_verdict like 'MUTANT_NEEDLE_MATCHED%' then 'FAIL: '||v_verdict
             when v_verdict = 'PASS'
               then 'FAIL: MUTANT SURVIVED — probe '||v_row.probe||' still passes without the fix'
             else 'PASS (lethal: '||left(v_verdict, 110)||')' end);
    exception when others then
      get stacked diagnostics v_msg = message_text;
      perform pg_temp.as_v319_actor(v_owner);
      insert into v319_out values (v_row.seq, v_row.tag||': '||v_row.label, 'FAIL: '||v_msg);
    end;
  end loop;

  -- =========================================================================
  -- STEP 41. Every mutant restored the bytes it borrowed. If this is red, no mutant result above
  --   can be trusted and neither can anything measured after them.
  -- =========================================================================
  insert into v319_out values (41, 'every mutant restored the live catalogue byte-for-byte',
    case when pg_temp.v319_catalog_digest() is distinct from v_digest_before
           then 'FAIL: the catalogue did not return to its pre-suite bytes'
         else 'PASS' end);

  -- =========================================================================
  -- STEP 42. Double-apply refusal: the migration must refuse to run twice rather than half-apply.
  -- =========================================================================
  insert into v319_out values (42, 'v321 is one-apply: the reversed_at column is its self-refusal marker',
    case when not exists (select 1 from information_schema.columns
                           where table_schema='public' and table_name='referrals'
                             and column_name='reversed_at')
           then 'FAIL: the self-refusal marker is absent, so a re-apply would proceed'
         else 'PASS' end);

  perform pg_temp.as_v319_system();
end
$v319_test$;

select seq, step, outcome from v319_out order by seq;
select case when exists (select 1 from v319_out where outcome like 'FAIL%')
            then 'V319 SUITE RED' else 'V319 SUITE GREEN' end as verdict,
       count(*) filter (where outcome like 'FAIL%') as failures,
       count(*) as cells
  from v319_out;

rollback;
