-- Rollback-only v66 staff-assisted top-up sale suite. Run after the chain through v66 in a disposable
-- rehearsal DB. Covers directive §3 + the mandatory safety contract + the 11 corrections + the reviewer's
-- highest-risk cases (split retirement, per-write-step atomic rollback, authority/version/permission,
-- reference uniqueness, synthetic lifecycle, preview reconciliation). Single-connection; true concurrency
-- (capacity/idempotency/reference races) is db/tests/v66_topup_concurrency.sh. Including txn owns ROLLBACK.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v66(p_uid uuid, p_role text) returns void language plpgsql as $$
begin
  execute 'reset role'; perform set_config('request.jwt.claim.sub','',true); perform set_config('request.jwt.claims','',true);
  if p_role='anon' then execute 'set local role anon'; perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  else execute 'set local role authenticated'; perform set_config('request.jwt.claim.sub', p_uid::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub',p_uid,'role','authenticated')::text, true); end if;
end $$;
grant execute on function pg_temp.as_v66(uuid,text) to authenticated, anon;
-- injected-failure trigger + force-live shim (superuser-only; rolled back)
create or replace function pg_temp.v66_boom() returns trigger language plpgsql as $$ begin raise exception 'INJECTED failure' using errcode='XX000'; end $$;
create or replace function pg_temp.v66_force_state(p_business uuid, p_state text) returns void language plpgsql as $$
begin
  alter table public.sv_authority disable trigger sv_authority_guard;
  update public.sv_authority set state=p_state where business_id=p_business and asset='stored_value';
  alter table public.sv_authority enable trigger sv_authority_guard;
end $$;

do $v66$
declare
  A uuid; A_owner uuid; B uuid; B_owner uuid; A_client uuid; A_client2 uuid; A_branch uuid; B_client uuid; B_branch uuid;
  d uuid; pub jsonb; ver uuid; verB uuid; res jsonb; prev jsonb; k uuid; pay jsonb;
  tbl text; n0 int; cnt int; v_priv_ok boolean; v_plain_uid uuid := gen_random_uuid(); v_topup_uid uuid := gen_random_uuid();
begin
  reset role;
  select s.business_id, s.user_id into A, A_owner from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture A' order by s.created_at limit 1;
  select s.business_id, s.user_id into B, B_owner from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture B' order by s.created_at limit 1;
  select id into A_client from public.clients where business_id=A order by created_at limit 1;
  insert into public.clients(business_id, full_name, phone) values (A,'A synthetic two','+6590000066') returning id into A_client2;
  select id into A_branch from public.branches where business_id=A order by is_default desc nulls last limit 1;
  select id into B_client from public.clients where business_id=B order by created_at limit 1;
  select id into B_branch from public.branches where business_id=B order by is_default desc nulls last limit 1;

  ---------------------------------------------------------------- RETIREMENT (split: 42501 vs 22023 vs privileges)
  perform pg_temp.as_v66(A_owner,'authenticated');
  begin perform public.sv_topup(A, A_client, gen_random_uuid(), gen_random_uuid());
    raise exception 'sv_topup callable by browser'; exception when others then assert sqlstate='42501','browser sv_topup must be 42501, got '||sqlstate; end;
  begin perform public.sv_grant(A, A_client, 100, 'x', gen_random_uuid());
    raise exception 'sv_grant callable by browser'; exception when others then assert sqlstate='42501','browser sv_grant must be 42501, got '||sqlstate; end;
  reset role;  -- privileged role that DOES have execute reaches the stub -> 22023, zero rows
  select count(*) into n0 from public.sv_lots;
  begin perform public.sv_topup(A, A_client, gen_random_uuid(), gen_random_uuid());
    raise exception 'privileged sv_topup did not raise'; exception when others then assert sqlstate='22023','privileged sv_topup stub must be 22023, got '||sqlstate; end;
  begin perform public.sv_grant(A, A_client, 100, 'x', gen_random_uuid());
    raise exception 'privileged sv_grant did not raise'; exception when others then assert sqlstate='22023','privileged sv_grant stub must be 22023, got '||sqlstate; end;
  assert (select count(*) from public.sv_lots) = n0, 'retired stubs created lots';
  -- execute-privilege enumeration: neither anon nor authenticated may execute the retired minters
  assert not has_function_privilege('anon', 'public.sv_topup(uuid,uuid,uuid,uuid)', 'EXECUTE'), 'anon sv_topup';
  assert not has_function_privilege('authenticated', 'public.sv_topup(uuid,uuid,uuid,uuid)', 'EXECUTE'), 'authenticated sv_topup';
  assert not has_function_privilege('authenticated', 'public.sv_grant(uuid,uuid,integer,text,uuid)', 'EXECUTE'), 'authenticated sv_grant';
  -- mint-path tripwire: no function OTHER than record_sv_topup_sale inserts a paid class lot
  assert not exists (select 1 from pg_proc p where p.prosrc ilike '%insert into public.sv_lots%' and p.prosrc ilike '%''paid''%' and p.proname <> 'record_sv_topup_sale'), 'a non-authoritative function can mint a paid lot';

  ---------------------------------------------------------------- SECURITY-DEFINER HARDENING (v66 public+app fns)
  assert not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where p.proname in ('record_sv_topup_sale','preview_sv_topup_sale','get_sellable_sv_topup_plans','set_synthetic_marker',
                        'can_sell_topups','current_sellable_sv_version','sv_total_outstanding','sv_topup_count','sv_topup_projection','sv_has_synthetic_evidence','is_synthetic_guard')
      and (not p.prosecdef or array_to_string(coalesce(p.proconfig,'{}'),',') not ilike '%search_path%')), 'a v66 function is not definer or lacks search_path';

  ---------------------------------------------------------------- publish a plan (10000+1000, terms, max 50000, lifetime cap 2)
  perform pg_temp.as_v66(A_owner,'authenticated');
  res := public.create_sv_plan_draft(A, jsonb_build_object('customer_facing_name','Canary','price_cents',10000,'bonus_cents',1000,
    'customer_terms','1y','max_balance_cents',50000,'purchase_lifetime_cap',2), gen_random_uuid());
  d := (res->>'draft_id')::uuid; pub := public.publish_sv_plan_version(A, d, 0, gen_random_uuid(), null); ver := (pub->>'version_id')::uuid;

  ---------------------------------------------------------------- AUTHORITY MATRIX
  pay := jsonb_build_object('method','test','amount_cents',10000,'currency','SGD');
  -- unbuilt refuses
  begin perform public.record_sv_topup_sale(A,A_branch,A_client,ver,pay,gen_random_uuid());
    raise exception 'unbuilt allowed'; exception when others then assert sqlstate='22023','unbuilt refuse'; end;
  -- mark A + both clients synthetic (super-admin B_owner)
  perform pg_temp.as_v66(B_owner,'authenticated');
  perform public.set_synthetic_marker(A,null,true,'canary business'); perform public.set_synthetic_marker(A,A_client,true,'canary c1'); perform public.set_synthetic_marker(A,A_client2,true,'canary c2');
  perform pg_temp.as_v66(A_owner,'authenticated');
  perform public.set_sv_authority_state(A,'stored_value','shadow_testing','canary');
  -- shadow: real method refused; real (non-synth) customer refused
  begin perform public.record_sv_topup_sale(A,A_branch,A_client,ver,jsonb_build_object('method','cash','amount_cents',10000,'currency','SGD'),gen_random_uuid());
    raise exception 'shadow cash allowed'; exception when others then assert sqlstate='22023','shadow non-test refuse'; end;
  -- shadow + synthetic + test -> mint
  k := gen_random_uuid(); res := public.record_sv_topup_sale(A,A_branch,A_client,ver,pay,k);
  assert res->>'status'='ok' and (res->>'spendable')::boolean=false, 'shadow synthetic mint';
  -- PREVIEW reconciliation (advisory) vs a fresh client to avoid capacity interference
  prev := public.preview_sv_topup_sale(A,A_branch,A_client2,ver,pay);
  assert (prev->>'preview')::boolean and (prev->>'price_cents')::int=10000 and (prev->>'bonus_cents')::int=1000
     and (prev->>'total_usable_cents')::int=11000 and (prev->>'projected_account_total_cents')::int=11000
     and (prev->>'spendable')::boolean=false, 'preview reconciles';
  res := public.record_sv_topup_sale(A,A_branch,A_client2,ver,pay,gen_random_uuid());
  assert (res->>'total_value_issued_cents')::int = (prev->>'total_usable_cents')::int, 'preview total == final';
  assert (res->>'account_total_after_cents')::int = (prev->>'projected_account_total_cents')::int, 'preview projected == final';

  ---------------------------------------------------------------- IDEMPOTENCY replay + conflict
  assert public.record_sv_topup_sale(A,A_branch,A_client,ver,pay,k) = (select result from public.sv_operations where idempotency_key=k and business_id=A), 'replay';
  -- same key, DIFFERENT valid customer -> conflict (not stale replay)
  begin perform public.record_sv_topup_sale(A,A_branch,A_client2,ver,pay,k);
    raise exception 'same-key-diff-customer replayed'; exception when others then assert sqlstate='22023','idempotency conflict on changed customer'; end;

  ---------------------------------------------------------------- CURRENCY
  begin perform public.record_sv_topup_sale(A,A_branch,A_client,ver,jsonb_build_object('method','test','amount_cents',10000,'currency','USD'),gen_random_uuid());
    raise exception 'USD allowed'; exception when others then assert sqlstate='22023','currency mismatch'; end;

  ---------------------------------------------------------------- LIFETIME cap (2): A_client already has 1 (replayed); do a 2nd distinct then 3rd -> cap
  perform public.record_sv_topup_sale(A,A_branch,A_client,ver,pay,gen_random_uuid());  -- A_client 2nd
  begin perform public.record_sv_topup_sale(A,A_branch,A_client,ver,pay,gen_random_uuid());  -- 3rd
    raise exception 'lifetime cap not enforced'; exception when others then assert sqlstate='22023','lifetime cap'; end;

  ---------------------------------------------------------------- MAX-BALANCE includes ALL outstanding (basis). New client, plan max 15000, price+bonus 11000: 1st ok, 2nd (22000) refused.
  perform pg_temp.as_v66(A_owner,'authenticated');
  res := public.create_sv_plan_draft(A, jsonb_build_object('customer_facing_name','Cap','price_cents',10000,'bonus_cents',1000,'customer_terms','1y','max_balance_cents',15000), gen_random_uuid());
  d := (res->>'draft_id')::uuid; ver := (public.publish_sv_plan_version(A, d, 0, gen_random_uuid(), null)->>'version_id')::uuid;
  reset role; insert into public.clients(business_id,full_name,phone,is_synthetic) values (A,'cap client','+6590000055',true) returning id into A_client;
  perform pg_temp.as_v66(A_owner,'authenticated');
  perform public.record_sv_topup_sale(A,A_branch,A_client,ver,pay,gen_random_uuid());  -- 11000 <= 15000 ok
  begin perform public.record_sv_topup_sale(A,A_branch,A_client,ver,pay,gen_random_uuid());  -- 22000 > 15000
    raise exception 'max-balance not enforced'; exception when others then assert sqlstate='22023','max balance'; end;

  ---------------------------------------------------------------- PERMISSION distinction (sell_topups vs generic)
  reset role;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at) values
    ('00000000-0000-0000-0000-000000000000',v_plain_uid,'authenticated','authenticated','plain@t.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_topup_uid,'authenticated','authenticated','topup@t.test','',now(),now(),now());
  insert into public.staff(business_id,user_id,role,full_name,active,module_perms) values
    (A, v_plain_uid, 'staff', 'plain staff', true, '{"sales": true}'::jsonb),      -- generic sales, NO sell_topups
    (A, v_topup_uid, 'staff', 'topup staff', true, '{"sell_topups": true}'::jsonb); -- explicit sell_topups
  perform pg_temp.as_v66(v_plain_uid,'authenticated');
  begin perform public.record_sv_topup_sale(A,A_branch,A_client,ver,pay,gen_random_uuid());
    raise exception 'generic sales staff sold a topup'; exception when others then assert sqlstate='42501','generic sales insufficient'; end;
  -- direct helper (as superuser with each sub set): only owner/manager/sell_topups qualify
  reset role;
  perform set_config('request.jwt.claim.sub', v_plain_uid::text, true); assert not app.can_sell_topups(A), 'generic staff can_sell_topups false';
  perform set_config('request.jwt.claim.sub', v_topup_uid::text, true); assert app.can_sell_topups(A), 'sell_topups staff can_sell_topups true';
  perform set_config('request.jwt.claim.sub', A_owner::text, true); assert app.can_sell_topups(A), 'owner can_sell_topups true';

  ---------------------------------------------------------------- CURRENT SELLABLE VERSION + effective_at
  perform pg_temp.as_v66(A_owner,'authenticated');
  -- publish v1 then v2 of one plan; v1 must be refused as not current
  res := public.create_sv_plan_draft(A, jsonb_build_object('customer_facing_name','Multi','price_cents',5000,'bonus_cents',0,'customer_terms','1y'), gen_random_uuid());
  d := (res->>'draft_id')::uuid; pub := public.publish_sv_plan_version(A, d, 0, gen_random_uuid(), null); ver := (pub->>'version_id')::uuid; -- v1
  res := public.clone_sv_plan_version_to_draft(A, ver, gen_random_uuid());
  d := (res->>'draft_id')::uuid; verB := (public.publish_sv_plan_version(A, d, (res->>'revision')::int, gen_random_uuid(), null)->>'version_id')::uuid; -- v2 current
  begin perform public.record_sv_topup_sale(A,A_branch,A_client,ver,jsonb_build_object('method','test','amount_cents',5000,'currency','SGD'),gen_random_uuid());
    raise exception 'historical version sold'; exception when others then assert sqlstate='22023','not_current_version'; end;

  ---------------------------------------------------------------- ATOMIC ROLLBACK per write step (inject a failure at each table)
  perform pg_temp.as_v66(A_owner,'authenticated');
  res := public.create_sv_plan_draft(A, jsonb_build_object('customer_facing_name','Atom','price_cents',7000,'bonus_cents',700,'customer_terms','1y'), gen_random_uuid());
  d := (res->>'draft_id')::uuid; ver := (public.publish_sv_plan_version(A, d, 0, gen_random_uuid(), null)->>'version_id')::uuid;
  reset role; insert into public.clients(business_id,full_name,phone,is_synthetic) values (A,'atom client','+6590000044',true) returning id into A_client;
  pay := jsonb_build_object('method','test','amount_cents',7000,'currency','SGD');
  foreach tbl in array array['sv_operations','sv_lots','sv_lot_movements','sv_topup_payments','sv_topup_payment_events','audit_log'] loop
    reset role;
    execute format('create trigger v66_inj before insert on public.%I for each row execute function pg_temp.v66_boom()', tbl);
    perform pg_temp.as_v66(A_owner,'authenticated');
    begin perform public.record_sv_topup_sale(A,A_branch,A_client,ver,pay,gen_random_uuid());
      reset role; execute format('drop trigger v66_inj on public.%I', tbl);
      raise exception 'injection at % did not fail', tbl;
    exception when others then
      if sqlstate <> 'P0004' then  -- not our own assert
        reset role; execute format('drop trigger v66_inj on public.%I', tbl);
      else raise; end if;
    end;
    -- zero partial rows for A_client across ALL value/payment tables
    select count(*) into cnt from public.sv_operations o where o.business_id=A and o.actor is not null and exists (select 1 from public.sv_lots l where l.operation_id=o.id and l.account_id in (select id from public.sv_accounts where business_id=A and client_id=A_client));
    assert (select count(*) from public.sv_lots l where l.account_id in (select id from public.sv_accounts where business_id=A and client_id=A_client))=0, 'partial lots after '||tbl;
    assert (select count(*) from public.sv_topup_payments where business_id=A and client_id=A_client)=0, 'partial payment after '||tbl;
    assert (select count(*) from public.sv_topup_payment_events e join public.sv_topup_payments p on p.id=e.payment_id where p.client_id=A_client)=0, 'partial event after '||tbl;
  end loop;
  -- FAILURE RECOVERY: a clean retry after all injections succeeds, exactly one op, capacity intact
  perform pg_temp.as_v66(A_owner,'authenticated');
  res := public.record_sv_topup_sale(A,A_branch,A_client,ver,pay,gen_random_uuid());
  assert res->>'status'='ok', 'recovery retry ok';
  assert (select count(*) from public.sv_lots l where l.account_id in (select id from public.sv_accounts where business_id=A and client_id=A_client))=2, 'recovery minted exactly once';

  ---------------------------------------------------------------- SYNTHETIC LIFECYCLE
  -- owner cannot mark synthetic
  perform pg_temp.as_v66(A_owner,'authenticated');
  begin perform public.set_synthetic_marker(A,null,false,'try'); raise exception 'owner set marker';
    exception when others then assert sqlstate='42501','owner cannot set marker'; end;
  -- SA cannot UNMARK A while synthetic evidence exists
  perform pg_temp.as_v66(B_owner,'authenticated');
  begin perform public.set_synthetic_marker(A,null,false,'unmark'); raise exception 'unmarked with evidence';
    exception when others then assert sqlstate='22023','cannot unmark with evidence'; end;

  ---------------------------------------------------------------- POINTS policy
  perform pg_temp.as_v66(A_owner,'authenticated');
  res := public.create_sv_plan_draft(A, jsonb_build_object('customer_facing_name','Pts','price_cents',5000,'bonus_cents',0,'customer_terms','1y','topup_purchase_earns_points',true), gen_random_uuid());
  d := (res->>'draft_id')::uuid; ver := (public.publish_sv_plan_version(A, d, 0, gen_random_uuid(), null)->>'version_id')::uuid;
  res := public.record_sv_topup_sale(A,A_branch,A_client,ver,jsonb_build_object('method','test','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  assert res->>'status'='policy_not_yet_supported', 'points policy blocks';

  ---------------------------------------------------------------- LIVE path (force-live shim on real business B): real mint + test refused + synthetic refused
  reset role; perform pg_temp.v66_force_state(B, 'live');
  perform pg_temp.as_v66(B_owner,'authenticated');
  res := public.create_sv_plan_draft(B, jsonb_build_object('customer_facing_name','Live','price_cents',8000,'bonus_cents',800,'customer_terms','1y'), gen_random_uuid());
  d := (res->>'draft_id')::uuid; verB := (public.publish_sv_plan_version(B, d, 0, gen_random_uuid(), null)->>'version_id')::uuid;
  -- live: test method refused
  begin perform public.record_sv_topup_sale(B,B_branch,B_client,verB,jsonb_build_object('method','test','amount_cents',8000,'currency','SGD'),gen_random_uuid());
    raise exception 'live test method allowed'; exception when others then assert sqlstate='22023','live test refused'; end;
  -- live real cash mint -> spendable true
  res := public.record_sv_topup_sale(B,B_branch,B_client,verB,jsonb_build_object('method','cash','amount_cents',8000,'currency','SGD'),gen_random_uuid());
  assert res->>'status'='ok' and (res->>'spendable')::boolean=true, 'live cash mint spendable';
  assert (select confirmation_mode from public.sv_topup_payments where operation_id=(res->>'operation_id')::uuid)='cash_received', 'cash_received';
  -- live: a fresh REAL (is_synthetic=false) customer for the non-cash reference + staff-confirmation checks below
  reset role; insert into public.clients(business_id,full_name,phone,is_synthetic) values (B,'synth on live','+6590000033',false) returning id into B_client;
  perform pg_temp.as_v66(B_owner,'authenticated');
  perform pg_temp.as_v66(B_owner,'authenticated');
  -- non-cash requires reference + staff_confirmed
  begin perform public.record_sv_topup_sale(B,B_branch,B_client,verB,jsonb_build_object('method','paynow','amount_cents',8000,'currency','SGD'),gen_random_uuid());
    raise exception 'paynow without reference allowed'; exception when others then assert sqlstate='22023','non-cash needs reference'; end;
  -- non-cash reference uniqueness (sequential): same ref twice -> 2nd refused
  perform public.record_sv_topup_sale(B,B_branch,B_client,verB,jsonb_build_object('method','paynow','amount_cents',8000,'currency','SGD','reference','TXN-1','staff_confirmed',true),gen_random_uuid());
  begin perform public.record_sv_topup_sale(B,B_branch,B_client,verB,jsonb_build_object('method','paynow','amount_cents',8000,'currency','SGD','reference','txn-1','staff_confirmed',true),gen_random_uuid());
    raise exception 'duplicate reference allowed'; exception when others then assert sqlstate='22023','duplicate ref (case-insensitive)'; end;

  reset role;
  raise notice 'V66 SUITE PASS (all assertions)';
end $v66$;
rollback;
