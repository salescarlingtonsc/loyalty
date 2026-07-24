-- Rollback-only v62 PS-2A Increment B shadow-operations + reconciliation suite.
-- Run after the pending chain (through v62) in a disposable rehearsal database.
--
-- Proves the Increment-B slice of the owner's 25 plus the contract invariants:
--   17 Shadow operation never changes the legacy authoritative balance: a run_sv_reconciliation
--      leaves gift_cards / sv_lot_movements / points_ledger / credit_ledger byte-identical
--      (md5 equal) - reconciliation reads the legacy analog READ-ONLY and moves no value.
--   18 A shadow mismatch is recorded and visible: a gift card with a positive balance and no
--      studio account produces a missing_in_studio discrepancy that get_sv_reconciliation
--      surfaces, and the authority is driven to reconciliation_blocked.
--   19 A shadow-only effect never reports live: authority shadow_testing -> get_sv_account
--      spendable=false, shadow_testing=true, disclaimer set.
--   20 A mixed-authority program never displays a bare live: the PS-1C.2 rule-state path is
--      UNTOUCHED (a published apply_discount_amount checkout rule still reports 'live' via
--      app.ps1c2_rule_state) while stored-value authority is a SEPARATE axis that reads
--      shadow_testing, never live.
-- Plus: set_sv_authority_state rejects live/ready_for_cutover (22023) and is owner-only
--   (frontdesk/anon denied); the blocked-lock (reconciliation_blocked -> only shadow_testing);
--   invalid (negative/NULL) balances classified invalid_legacy_balance and NOT repaired;
--   duplicate code classified duplicate_legacy_event; rerun determinism (same discrepancy
--   content); a shadow-eval write leaves sv_lot_movements unchanged; cross-tenant isolation on
--   run + read; append-only guards + RLS + zero browser DML on the 3 new tables; definer +
--   pinned search_path + revocation on the new functions; and a compact v61 regression
--   (topup/grant/idempotency) with gift_cards/points/credit still legacy-authoritative.
-- The including transaction owns BEGIN/ROLLBACK; nothing commits.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v62_principal(p_uid uuid, p_role text)
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  if p_role = 'anon' then
    execute 'set local role anon';
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  elsif p_role = 'authenticated' and p_uid is not null then
    execute 'set local role authenticated';
    perform set_config('request.jwt.claim.sub', p_uid::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  else
    raise exception 'unsupported v62 principal';
  end if;
end $$;
grant execute on function pg_temp.as_v62_principal(uuid, text) to authenticated, anon;

do $v62_test$
declare
  v_business uuid; v_owner uuid; v_client uuid;
  v_business_b uuid; v_owner_b uuid; v_client_b uuid;
  v_owner_c uuid := gen_random_uuid(); v_business_c uuid;
  v_fd uuid := gen_random_uuid(); v_fd_staff uuid;
  v_plan uuid; v_pv uuid; v_key uuid := gen_random_uuid(); v_gkey uuid := gen_random_uuid();
  v_res jsonb; v_res2 jsonb; v_acct uuid;
  v_gc_a uuid; v_legacy_ref text; v_cat text;
  v_run1 uuid; v_run2 uuid;
  v_md5_gc text; v_md5_mv text; v_md5_pl text; v_md5_cl text;
  v_md5_gc2 text; v_md5_mv2 text; v_md5_pl2 text; v_md5_cl2 text;
  v_mv_before int; v_se_before int;
  v_pl_before int; v_cl_before int;
  v_cfg uuid; v_base uuid; v_hash text; v_rule uuid := gen_random_uuid(); v_rule_pk uuid;
  v_set1 text; v_set2 text;
  v_conname text; v_bal int;
  t text; v_oid oid;
begin
  -- ---- 0. Fixtures ----
  reset role;
  select s.business_id, s.user_id into v_business, v_owner
    from public.staff s join public.businesses b on b.id = s.business_id
   where s.role = 'owner' and s.active and s.user_id is not null and b.name = 'Pristine chain fixture A'
   order by s.created_at limit 1;
  select s.business_id, s.user_id into v_business_b, v_owner_b
    from public.staff s join public.businesses b on b.id = s.business_id
   where s.role = 'owner' and s.active and s.user_id is not null and b.name = 'Pristine chain fixture B'
   order by s.created_at limit 1;
  if v_business is null or v_business_b is null then raise exception 'v62 needs the pristine fixtures A + B'; end if;
  select id into v_client from public.clients where business_id = v_business order by created_at limit 1;
  select id into v_client_b from public.clients where business_id = v_business_b order by created_at limit 1;

  -- A fresh NON-super owner (business C) for a clean cross-tenant test - the fixture makes
  -- owner_b a super admin, so it cannot prove reconciliation READ isolation.
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner_c, 'authenticated', 'authenticated',
    'v62-c-' || substr(v_owner_c::text, 1, 8) || '@example.test', '', now(), now(), now());
  perform pg_temp.as_v62_principal(v_owner_c, 'authenticated');
  -- 'loyalty' module is REQUIRED: create_business seeds a draft loyalty config whose write
  -- guard (app.c45_owner_loyalty_write) demands the module — matches the fixture's own tenants.
  v_business_c := (public.create_business('v62 tenant C', 'v62c-' || replace(v_owner_c::text, '-', ''),
    'test', array['dashboard', 'clients', 'sales', 'loyalty'])::jsonb->>'id')::uuid;

  -- A frontdesk of A for the non-owner permission checks.
  reset role;
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_fd, 'authenticated', 'authenticated',
    'v62-fd-' || substr(v_fd::text, 1, 8) || '@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, full_name, active)
  values (v_business, v_fd, 'frontdesk', 'v62 frontdesk', true) returning id into v_fd_staff;

  -- ============================================================
  -- REGRESSION (v61): a compact topup + grant + idempotent retry still holds, and the sv
  -- ledger is separate - gift_cards / points_ledger / credit_ledger stay legacy-authoritative.
  -- ============================================================
  reset role;
  insert into public.sv_plans(business_id, name) values (v_business, 'v62 plan') returning id into v_plan;
  insert into public.sv_plan_versions(business_id, plan_id, version_no, price_cents, bonus_cents, expiry_days, terms_snapshot)
  values (v_business, v_plan, 1, 10000, 2000, 365, jsonb_build_object('price_cents', 10000, 'bonus_cents', 2000))
  returning id into v_pv;
  select count(*) into v_pl_before from public.points_ledger;
  select count(*) into v_cl_before from public.credit_ledger;

  perform pg_temp.as_v62_principal(v_owner, 'authenticated');
  v_res := public.sv_topup(v_business, v_client, v_pv, v_key);
  v_res2 := public.sv_topup(v_business, v_client, v_pv, v_key);        -- idempotent retry
  if v_res <> v_res2 then raise exception 'v62 regression: idempotent topup retry differed'; end if;
  v_acct := (v_res->>'account_id')::uuid;
  perform public.sv_grant(v_business, v_client, 750, 'goodwill', v_gkey);
  reset role;
  if app.sv_available_balance(v_business, v_acct) <> 12750 then raise exception 'v62 regression: available balance is not 12750'; end if;
  if app.sv_class_balance(v_business, v_acct, 'paid') <> 10000 then raise exception 'v62 regression: paid balance is not 10000'; end if;
  if (select count(*) from public.sv_operations where business_id = v_business and operation_type = 'topup') <> 1 then
    raise exception 'v62 regression: idempotent topup wrote more than one op row'; end if;
  if (select count(*) from public.points_ledger) <> v_pl_before
     or (select count(*) from public.credit_ledger) <> v_cl_before then
    raise exception 'v62 regression: an sv operation wrote to points_ledger/credit_ledger'; end if;

  -- ============================================================
  -- A shadow-eval write leaves sv_lot_movements unchanged (writes ZERO value rows).
  -- ============================================================
  reset role;
  select count(*) into v_mv_before from public.sv_lot_movements where business_id = v_business;
  select count(*) into v_se_before from public.sv_shadow_evaluations where business_id = v_business;
  perform app.sv_write_shadow_evaluation(v_business, null, 'stored_value', 'topup',
    jsonb_build_array(jsonb_build_object('class', 'paid', 'kind', 'issue', 'cents', 1234)),
    1234, 'legacy:giftcard:manual', 'manual shadow probe');
  if (select count(*) from public.sv_lot_movements where business_id = v_business) <> v_mv_before then
    raise exception 'v62: a shadow evaluation changed the sv_lot_movements count'; end if;
  if (select count(*) from public.sv_shadow_evaluations where business_id = v_business) <> v_se_before + 1 then
    raise exception 'v62: a shadow evaluation did not append exactly one shadow row'; end if;

  -- ============================================================
  -- 19. Authority shadow_testing -> get_sv_account spendable=false, shadow_testing=true,
  --     disclaimer set (business B).
  -- ============================================================
  perform pg_temp.as_v62_principal(v_owner_b, 'authenticated');
  v_res := public.set_sv_authority_state(v_business_b, 'stored_value', 'shadow_testing', 'begin shadow testing');
  if (v_res->>'state') <> 'shadow_testing' then raise exception 'v62-19: set_sv_authority_state did not report shadow_testing'; end if;
  v_res := public.get_sv_account(v_business_b, v_client_b);
  if (v_res->>'spendable')::boolean is not false then raise exception 'v62-19: shadow account reported spendable'; end if;
  if (v_res->>'shadow_testing')::boolean is not true then raise exception 'v62-19: shadow_testing flag is not true'; end if;
  if (v_res->>'authority_state') <> 'shadow_testing' then raise exception 'v62-19: authority_state is not verbatim shadow_testing'; end if;
  if (v_res->>'disclaimer') is null then raise exception 'v62-19: a non-live account has no disclaimer'; end if;

  -- ============================================================
  -- 20. Rule-state axis untouched vs. the SEPARATE stored-value authority axis (business A).
  --     A published apply_discount_amount checkout rule -> 'live' via ps1c2_rule_state, while
  --     sv authority reads shadow_testing (never live) on the SAME business.
  -- ============================================================
  reset role;
  -- precondition: the checkout family is 'studio' so an apply_discount_amount effect is live.
  if (select cutover_status from public.benefit_registry where business_id = v_business and source_engine = 'checkout') <> 'studio' then
    raise exception 'v62-20 precondition: checkout registry is not studio for fixture A'; end if;

  perform pg_temp.as_v62_principal(v_owner, 'authenticated');
  v_res := public.set_sv_authority_state(v_business, 'stored_value', 'shadow_testing', 'shadow testing A');
  reset role;
  -- The rule-EXECUTION axis (checkout family) reports 'live' directly from the registry,
  -- entirely independent of the stored-value authority axis. Proven via app.ps1c2_effect_state
  -- (the exact per-effect server truth that ps1c2_rule_state aggregates) WITHOUT re-publishing a
  -- rule here — v60's suite already proves the full publish -> aggregate-'live' path, and this
  -- avoids re-cloning the loyalty config deep inside a long test txn (fragile, unrelated to the
  -- axis-independence property under test).
  if app.ps1c2_effect_state(v_business, 'apply_discount_amount') <> 'live' then
    raise exception 'v62-20: the checkout rule-execution axis is not live (got %)',
      app.ps1c2_effect_state(v_business, 'apply_discount_amount'); end if;
  -- ... while the SEPARATE stored-value authority axis reads shadow_testing, never live.
  perform pg_temp.as_v62_principal(v_owner, 'authenticated');
  v_res := public.get_sv_account(v_business, v_client);
  if (v_res->>'authority_state') <> 'shadow_testing' or (v_res->>'spendable')::boolean is not false then
    raise exception 'v62-20: the stored-value authority axis is not a separate shadow_testing (non-live) axis'; end if;

  -- ============================================================
  -- 17 + 18. Seed a positive gift card on A (no studio account for it), reconcile, and prove
  --          (17) the legacy value spine is byte-identical and (18) a missing_in_studio
  --          discrepancy is recorded, surfaced, and forces reconciliation_blocked.
  -- ============================================================
  reset role;
  insert into public.gift_cards(business_id, code, initial_cents, balance_cents, status)
  values (v_business, 'v62-A-GC1', 5000, 5000, 'active');
  select id into v_gc_a from public.gift_cards where business_id = v_business and code = 'v62-A-GC1';
  v_legacy_ref := 'legacy:giftcard:' || v_gc_a::text;

  -- capture the value-spine md5 BEFORE the run (business-scoped, deterministic order).
  select md5(coalesce(string_agg(g::text, '|' order by g.id), '')) into v_md5_gc from public.gift_cards g where g.business_id = v_business;
  select md5(coalesce(string_agg(m::text, '|' order by m.id), '')) into v_md5_mv from public.sv_lot_movements m where m.business_id = v_business;
  select md5(coalesce(string_agg(p::text, '|' order by p.id), '')) into v_md5_pl from public.points_ledger p where p.business_id = v_business;
  select md5(coalesce(string_agg(c::text, '|' order by c.id), '')) into v_md5_cl from public.credit_ledger c where c.business_id = v_business;

  perform pg_temp.as_v62_principal(v_owner, 'authenticated');
  v_res := public.run_sv_reconciliation(v_business);
  v_run1 := (v_res->>'run_id')::uuid;
  if (v_res->>'reconciliation_status') <> 'blocked' then raise exception 'v62-18: reconciliation status is not blocked'; end if;
  if (v_res->>'authority_state') <> 'reconciliation_blocked' then raise exception 'v62-18: authority was not driven to reconciliation_blocked'; end if;

  -- 17: value spine byte-identical (reconciliation read gift_cards read-only, moved no value).
  reset role;
  select md5(coalesce(string_agg(g::text, '|' order by g.id), '')) into v_md5_gc2 from public.gift_cards g where g.business_id = v_business;
  select md5(coalesce(string_agg(m::text, '|' order by m.id), '')) into v_md5_mv2 from public.sv_lot_movements m where m.business_id = v_business;
  select md5(coalesce(string_agg(p::text, '|' order by p.id), '')) into v_md5_pl2 from public.points_ledger p where p.business_id = v_business;
  select md5(coalesce(string_agg(c::text, '|' order by c.id), '')) into v_md5_cl2 from public.credit_ledger c where c.business_id = v_business;
  if v_md5_gc <> v_md5_gc2 then raise exception 'v62-17: reconciliation mutated gift_cards (not read-only)'; end if;
  if v_md5_mv <> v_md5_mv2 then raise exception 'v62-17: reconciliation moved stored value (sv_lot_movements changed)'; end if;
  if v_md5_pl <> v_md5_pl2 then raise exception 'v62-17: reconciliation wrote points_ledger'; end if;
  if v_md5_cl <> v_md5_cl2 then raise exception 'v62-17: reconciliation wrote credit_ledger'; end if;

  -- 18: the discrepancy exists and is classified missing_in_studio.
  select category into v_cat from public.sv_reconciliation_discrepancies
   where business_id = v_business and run_id = v_run1 and legacy_ref = v_legacy_ref;
  if v_cat is distinct from 'missing_in_studio' then raise exception 'v62-18: the positive orphan gift card is not missing_in_studio (got %)', v_cat; end if;

  -- 18: get_sv_reconciliation surfaces it (never hidden) and reports blocked + the authority.
  perform pg_temp.as_v62_principal(v_owner, 'authenticated');
  v_res := public.get_sv_reconciliation(v_business);
  if (v_res->>'authority_state') <> 'reconciliation_blocked' then raise exception 'v62-18: get_sv_reconciliation authority_state not blocked'; end if;
  if (v_res->'latest_snapshot'->>'status') <> 'blocked' then raise exception 'v62-18: latest snapshot status is not blocked'; end if;
  if not exists (select 1 from jsonb_array_elements(v_res->'discrepancies') d
                  where d->>'legacy_ref' = v_legacy_ref and d->>'category' = 'missing_in_studio') then
    raise exception 'v62-18: get_sv_reconciliation did not surface the missing_in_studio discrepancy'; end if;

  -- ============================================================
  -- Rerun determinism: a second run appends a NEW snapshot but the discrepancy CONTENT is
  -- stable (deterministic legacy_ref).
  -- ============================================================
  perform pg_temp.as_v62_principal(v_owner, 'authenticated');
  v_res := public.run_sv_reconciliation(v_business);
  v_run2 := (v_res->>'run_id')::uuid;
  reset role;
  if v_run1 = v_run2 then raise exception 'v62: a rerun reused the same run_id'; end if;
  select array_to_string(array_agg(category || ':' || legacy_ref order by category, legacy_ref), ',') into v_set1
    from public.sv_reconciliation_discrepancies where business_id = v_business and run_id = v_run1;
  select array_to_string(array_agg(category || ':' || legacy_ref order by category, legacy_ref), ',') into v_set2
    from public.sv_reconciliation_discrepancies where business_id = v_business and run_id = v_run2;
  if v_set1 is distinct from v_set2 then raise exception 'v62: rerun discrepancy content is not deterministic (% vs %)', v_set1, v_set2; end if;

  -- ============================================================
  -- set_sv_authority_state rejects the cutover states (22023) and the blocked-lock holds.
  -- ============================================================
  perform pg_temp.as_v62_principal(v_owner, 'authenticated');
  begin perform public.set_sv_authority_state(v_business, 'stored_value', 'live', 'nope');
    raise exception 'v62: set_sv_authority_state accepted live'; exception when sqlstate '22023' then null; end;
  begin perform public.set_sv_authority_state(v_business, 'stored_value', 'ready_for_cutover', 'nope');
    raise exception 'v62: set_sv_authority_state accepted ready_for_cutover'; exception when sqlstate '22023' then null; end;
  -- A is reconciliation_blocked; blocked -> unbuilt is refused, blocked -> shadow_testing is allowed.
  begin perform public.set_sv_authority_state(v_business, 'stored_value', 'unbuilt', 'revert');
    raise exception 'v62: blocked -> unbuilt was allowed'; exception when sqlstate '22023' then null; end;
  v_res := public.set_sv_authority_state(v_business, 'stored_value', 'shadow_testing', 'remediate discrepancies');
  if (v_res->>'state') <> 'shadow_testing' then raise exception 'v62: blocked -> shadow_testing was not allowed'; end if;

  -- ============================================================
  -- Owner-only: a frontdesk of A and anon cannot set/run/read.
  -- ============================================================
  perform pg_temp.as_v62_principal(v_fd, 'authenticated');
  begin perform public.set_sv_authority_state(v_business, 'stored_value', 'shadow_testing', 'nope');
    raise exception 'v62: a frontdesk set authority'; exception when sqlstate '42501' then null; end;
  begin perform public.run_sv_reconciliation(v_business);
    raise exception 'v62: a frontdesk ran reconciliation'; exception when sqlstate '42501' then null; end;
  begin perform public.get_sv_reconciliation(v_business);
    raise exception 'v62: a frontdesk read reconciliation'; exception when sqlstate '42501' then null; end;

  perform pg_temp.as_v62_principal(null, 'anon');
  begin perform public.set_sv_authority_state(v_business, 'stored_value', 'shadow_testing', 'nope');
    raise exception 'v62: anon set authority'; exception when insufficient_privilege then null; end;
  begin perform public.run_sv_reconciliation(v_business);
    raise exception 'v62: anon ran reconciliation'; exception when insufficient_privilege then null; end;
  begin perform public.get_sv_reconciliation(v_business);
    raise exception 'v62: anon read reconciliation'; exception when insufficient_privilege then null; end;

  -- ============================================================
  -- Cross-tenant: a fresh NON-super owner (C) cannot run or read A's reconciliation.
  -- ============================================================
  perform pg_temp.as_v62_principal(v_owner_c, 'authenticated');
  begin perform public.run_sv_reconciliation(v_business);
    raise exception 'v62: cross-tenant reconciliation run succeeded'; exception when sqlstate '42501' then null; end;
  begin perform public.get_sv_reconciliation(v_business);
    raise exception 'v62: cross-tenant reconciliation read succeeded'; exception when sqlstate '42501' then null; end;
  begin perform public.set_sv_authority_state(v_business, 'stored_value', 'shadow_testing', 'attack');
    raise exception 'v62: cross-tenant authority write succeeded'; exception when sqlstate '42501' then null; end;

  -- ============================================================
  -- Malformed legacy rows are CLASSIFIED, never repaired. Current gift_cards constraints make
  -- negative/NULL balances and duplicate codes uninsertable through normal paths, so the test
  -- temporarily relaxes them (rolled back) to inject the adversarial legacy rows into business B.
  -- ============================================================
  reset role;
  alter table public.gift_cards alter column balance_cents drop not null;
  for v_conname in
    select conname from pg_constraint
     where conrelid = 'public.gift_cards'::regclass and contype = 'c'
       and pg_get_constraintdef(oid) ilike '%balance_cents%'
  loop execute 'alter table public.gift_cards drop constraint ' || quote_ident(v_conname); end loop;
  for v_conname in
    select conname from pg_constraint
     where conrelid = 'public.gift_cards'::regclass and contype = 'u'
       and pg_get_constraintdef(oid) = 'UNIQUE (code)'
  loop execute 'alter table public.gift_cards drop constraint ' || quote_ident(v_conname); end loop;

  insert into public.gift_cards(business_id, code, initial_cents, balance_cents, status) values
    (v_business_b, 'v62-B-NEG',  1000, -100, 'active'),   -- negative -> invalid_legacy_balance
    (v_business_b, 'v62-B-NULL', 1000, null, 'active'),   -- NULL     -> invalid_legacy_balance
    (v_business_b, 'v62-B-DUP',  1000, 1000, 'active'),   -- duplicate code -> duplicate_legacy_event
    (v_business_b, 'v62-B-DUP',  1000, 1000, 'active');

  perform pg_temp.as_v62_principal(v_owner_b, 'authenticated');
  v_res := public.run_sv_reconciliation(v_business_b);
  v_run1 := (v_res->>'run_id')::uuid;
  reset role;
  -- negative + NULL are classified invalid_legacy_balance (2 rows), never repaired.
  if (select count(*) from public.sv_reconciliation_discrepancies
       where business_id = v_business_b and run_id = v_run1 and category = 'invalid_legacy_balance') <> 2 then
    raise exception 'v62: negative/NULL balances were not both classified invalid_legacy_balance'; end if;
  -- the duplicate code yields duplicate_legacy_event for both rows.
  if (select count(*) from public.sv_reconciliation_discrepancies
       where business_id = v_business_b and run_id = v_run1 and category = 'duplicate_legacy_event') <> 2 then
    raise exception 'v62: the duplicate code was not classified duplicate_legacy_event on both rows'; end if;
  -- NOTHING was repaired: the malformed legacy balances are exactly as inserted.
  select balance_cents into v_bal from public.gift_cards where business_id = v_business_b and code = 'v62-B-NEG';
  if v_bal is distinct from -100 then raise exception 'v62: reconciliation repaired a negative legacy balance'; end if;
  if (select balance_cents from public.gift_cards where business_id = v_business_b and code = 'v62-B-NULL') is not null then
    raise exception 'v62: reconciliation repaired a NULL legacy balance'; end if;

  -- ============================================================
  -- Append-only guards on the 3 new tables (UPDATE + DELETE -> restrict_violation).
  -- ============================================================
  reset role;
  begin update public.sv_shadow_evaluations set note = 'x' where business_id = v_business;
    raise exception 'v62: sv_shadow_evaluations accepted an UPDATE'; exception when restrict_violation then null; end;
  begin delete from public.sv_shadow_evaluations where business_id = v_business;
    raise exception 'v62: sv_shadow_evaluations accepted a DELETE'; exception when restrict_violation then null; end;
  begin update public.sv_reconciliation_snapshots set status = 'clean' where business_id = v_business;
    raise exception 'v62: sv_reconciliation_snapshots accepted an UPDATE'; exception when restrict_violation then null; end;
  begin delete from public.sv_reconciliation_snapshots where business_id = v_business;
    raise exception 'v62: sv_reconciliation_snapshots accepted a DELETE'; exception when restrict_violation then null; end;
  begin update public.sv_reconciliation_discrepancies set category = 'amount_mismatch' where business_id = v_business;
    raise exception 'v62: sv_reconciliation_discrepancies accepted an UPDATE'; exception when restrict_violation then null; end;
  begin delete from public.sv_reconciliation_discrepancies where business_id = v_business;
    raise exception 'v62: sv_reconciliation_discrepancies accepted a DELETE'; exception when restrict_violation then null; end;

  -- ============================================================
  -- RLS + zero browser DML on the 3 new tables; anon cannot SELECT.
  -- ============================================================
  foreach t in array array['sv_shadow_evaluations', 'sv_reconciliation_snapshots', 'sv_reconciliation_discrepancies'] loop
    if has_table_privilege('anon', 'public.' || t, 'select') then
      raise exception 'v62: anon retains SELECT on public.%', t; end if;
    if has_table_privilege('anon', 'public.' || t, 'insert') or has_table_privilege('anon', 'public.' || t, 'update')
       or has_table_privilege('anon', 'public.' || t, 'delete')
       or has_table_privilege('authenticated', 'public.' || t, 'insert')
       or has_table_privilege('authenticated', 'public.' || t, 'update')
       or has_table_privilege('authenticated', 'public.' || t, 'delete') then
      raise exception 'v62: a browser role retains a direct write on public.%', t; end if;
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then
      raise exception 'v62: RLS is not enabled on public.%', t; end if;
    if (select count(*) from pg_policies where schemaname = 'public' and tablename = t) < 2 then
      raise exception 'v62: public.% is missing its owner/sa read policies', t; end if;
  end loop;

  -- ============================================================
  -- Every new sv function is SECURITY DEFINER, pins search_path, and is revoked from anon
  -- (the app.* helpers also from authenticated; the public RPCs are granted to authenticated).
  -- ============================================================
  for v_oid in
    select p.oid from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where (ns.nspname, p.proname) in (
       ('app', 'sv_apply_authority_state'), ('app', 'sv_write_shadow_evaluation'),
       ('public', 'set_sv_authority_state'), ('public', 'run_sv_reconciliation'),
       ('public', 'get_sv_reconciliation'), ('public', 'get_sv_account'))
  loop
    if not (select prosecdef from pg_proc where oid = v_oid) then
      raise exception 'v62: a new sv function is not SECURITY DEFINER'; end if;
    if not exists (select 1 from pg_proc where oid = v_oid
                    and array_to_string(coalesce(proconfig, '{}'), ',') like '%search_path=%') then
      raise exception 'v62: a new sv function does not pin search_path'; end if;
    if has_function_privilege('anon', v_oid, 'execute') then
      raise exception 'v62: anon retains EXECUTE on a new sv function'; end if;
  end loop;
  foreach t in array array['app.sv_apply_authority_state(uuid,text,text,text,uuid)',
      'app.sv_write_shadow_evaluation(uuid,uuid,text,text,jsonb,integer,text,text)'] loop
    if has_function_privilege('authenticated', t, 'execute') then
      raise exception 'v62: authenticated retains EXECUTE on internal helper %', t; end if;
  end loop;
  if not has_function_privilege('authenticated', 'public.set_sv_authority_state(uuid,text,text,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.run_sv_reconciliation(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.get_sv_reconciliation(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.get_sv_account(uuid,uuid)', 'execute') then
    raise exception 'v62: a browser sv RPC is not granted to authenticated'; end if;

  raise notice 'v62 PS-2A Increment B shadow + reconciliation suite: ALL PASS';
end $v62_test$;

reset role;
rollback;
