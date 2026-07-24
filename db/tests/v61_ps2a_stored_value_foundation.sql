-- Rollback-only v61 PS-2A Increment A stored-value FOUNDATION suite.
-- Run after the pending chain (through v61) in a disposable rehearsal database.
--
-- Proves the Increment-A-testable subset of the owner's 25 (the foundation has no spend/
-- refund/reserve/expire path, so the spend-side numbered cases are out of scope here):
--   1  identical idempotent sv_topup retry -> ONE op row, ONE pair of lots, ONE pair of mint
--      movements, identical returned result.
--   2  conflicting reuse of the same idempotency key (different plan version) -> 22023, and
--      NO second lot/movement.
--   12 a non-owner (frontdesk) cannot sv_topup / sv_grant (42501); anon cannot (42501).
--   13 anon cannot SELECT any sv table (has_table_privilege false) and cannot call the RPCs.
--   14 cross-tenant: an owner of one business cannot topup into another's client, and cannot
--      read another's account (42501); the actual business-B owner also cannot topup into A.
--   15 a failed transaction (invalid plan version) leaves NO orphan op/lot/movement row.
-- Plus foundation invariants: append-only sv_lot_movements + immutable sv_lots / sv_plan_versions
--   (UPDATE/DELETE -> restrict_violation); no mutable balance column on any sv table; integer
--   units only; derived-balance correctness (10000 paid + 2000 bonus -> total 12000 / paid 10000
--   / bonus 2000); bonus_cents=0 mints exactly ONE lot; RLS on every sv table with owner/sa
--   policies and zero browser INSERT/UPDATE/DELETE; every sv SECURITY DEFINER function pins
--   search_path and is revoked from anon (helpers also from authenticated); sv_authority is
--   'unbuilt' for every business and get_sv_account.spendable is false; the authority guard
--   rejects a direct UPDATE to 'live'; PS-0 mint conformance (exactly two lots, correct
--   classes/cents, independent non-null expiry_keys, monotonic earned_seq); and zero rows
--   written to points_ledger / credit_ledger / sales by any sv function.
-- The including transaction owns BEGIN/ROLLBACK; nothing commits.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v61_principal(p_uid uuid, p_role text)
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
    raise exception 'unsupported v61 principal';
  end if;
end $$;
grant execute on function pg_temp.as_v61_principal(uuid, text) to authenticated, anon;

do $v61_test$
declare
  v_business uuid; v_owner uuid; v_client uuid;
  v_business_b uuid; v_owner_b uuid; v_client_b uuid;
  v_fresh uuid := gen_random_uuid(); v_fresh_staff uuid;
  v_plan uuid; v_pv uuid; v_pv2 uuid; v_pv0 uuid;
  v_key uuid := gen_random_uuid(); v_key0 uuid := gen_random_uuid(); v_gkey uuid := gen_random_uuid();
  v_res1 jsonb; v_res2 jsonb; v_res jsonb; v_acct uuid;
  v_paid_lot uuid; v_bonus_lot uuid; v_paid_seq bigint; v_bonus_seq bigint;
  v_ops_before int; v_lots_before int; v_moves_before int;
  v_pl_before int; v_cl_before int; v_sales_before int;
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
  if v_business is null or v_business_b is null then raise exception 'v61 needs the pristine fixtures A + B'; end if;
  select id into v_client from public.clients where business_id = v_business order by created_at limit 1;
  select id into v_client_b from public.clients where business_id = v_business_b order by created_at limit 1;

  -- Seed a plan + two plan versions (10000/2000/365d and 5000/0) and a bonus-free version.
  insert into public.sv_plans(business_id, name) values (v_business, 'v61 plan') returning id into v_plan;
  insert into public.sv_plan_versions(business_id, plan_id, version_no, price_cents, bonus_cents, expiry_days, terms_snapshot)
  values (v_business, v_plan, 1, 10000, 2000, 365, jsonb_build_object('price_cents', 10000, 'bonus_cents', 2000))
  returning id into v_pv;
  insert into public.sv_plan_versions(business_id, plan_id, version_no, price_cents, bonus_cents, expiry_days, terms_snapshot)
  values (v_business, v_plan, 2, 5000, 0, null, jsonb_build_object('price_cents', 5000, 'bonus_cents', 0))
  returning id into v_pv2;
  insert into public.sv_plan_versions(business_id, plan_id, version_no, price_cents, bonus_cents, expiry_days, terms_snapshot)
  values (v_business, v_plan, 3, 8000, 0, 30, jsonb_build_object('price_cents', 8000, 'bonus_cents', 0))
  returning id into v_pv0;

  -- ---- authority ships 'unbuilt' for EVERY business, and get_sv_account.spendable is false ----
  if exists (select 1 from public.sv_authority where state <> 'unbuilt') then
    raise exception 'v61: an sv_authority row is not unbuilt at ship time'; end if;
  if (select count(*) from public.sv_authority) <> (select count(*) from public.businesses) then
    raise exception 'v61: sv_authority is not seeded 1:1 with businesses'; end if;

  -- Baselines for the "sv functions touch no legacy value spine" assertion.
  select count(*) into v_pl_before from public.points_ledger;
  select count(*) into v_cl_before from public.credit_ledger;
  select count(*) into v_sales_before from public.sales;

  -- ============================================================
  -- 1. Identical idempotent sv_topup retry.
  -- ============================================================
  perform pg_temp.as_v61_principal(v_owner, 'authenticated');
  v_res1 := public.sv_topup(v_business, v_client, v_pv, v_key);
  v_res2 := public.sv_topup(v_business, v_client, v_pv, v_key);   -- identical retry (replay)
  if v_res1 <> v_res2 then raise exception 'v61: idempotent topup retry returned a different result'; end if;
  if (v_res1->>'status') <> 'ok' then raise exception 'v61: topup did not return ok'; end if;
  v_acct := (v_res1->>'account_id')::uuid;
  v_paid_lot := (v_res1->'paid_lot'->>'lot_id')::uuid;
  v_bonus_lot := (v_res1->'bonus_lot'->>'lot_id')::uuid;

  reset role;
  if (select count(*) from public.sv_operations where business_id = v_business and operation_type = 'topup') <> 1 then
    raise exception 'v61: idempotent topup wrote more than one op row'; end if;
  if (select count(*) from public.sv_lots where business_id = v_business and operation_id = (v_res1->>'operation_id')::uuid) <> 2 then
    raise exception 'v61: idempotent topup did not mint exactly two lots'; end if;
  if (select count(*) from public.sv_lot_movements where business_id = v_business and operation_id = (v_res1->>'operation_id')::uuid and kind = 'issue') <> 2 then
    raise exception 'v61: idempotent topup did not write exactly two issue movements'; end if;

  -- ============================================================
  -- PS-0 mint conformance: exactly two lots, correct classes/cents, independent non-null
  -- expiry_keys, monotonic earned_seq.
  -- ============================================================
  if (select minted_cents from public.sv_lots where id = v_paid_lot) <> 10000
     or (select class from public.sv_lots where id = v_paid_lot) <> 'paid' then
    raise exception 'v61: paid lot is not 10000/paid'; end if;
  if (select minted_cents from public.sv_lots where id = v_bonus_lot) <> 2000
     or (select class from public.sv_lots where id = v_bonus_lot) <> 'bonus' then
    raise exception 'v61: bonus lot is not 2000/bonus'; end if;
  select earned_seq into v_paid_seq from public.sv_lots where id = v_paid_lot;
  select earned_seq into v_bonus_seq from public.sv_lots where id = v_bonus_lot;
  if v_bonus_seq <= v_paid_seq then raise exception 'v61: earned_seq is not monotonic across the minted lots'; end if;
  if (select expiry_key from public.sv_lots where id = v_paid_lot) is null
     or (select expiry_key from public.sv_lots where id = v_bonus_lot) is null then
    raise exception 'v61: a 365-day plan minted a null expiry_key'; end if;

  -- ============================================================
  -- Derived-balance correctness (10000 paid + 2000 bonus).
  -- ============================================================
  if app.sv_available_balance(v_business, v_acct) <> 12000 then raise exception 'v61: available balance is not 12000'; end if;
  if app.sv_class_balance(v_business, v_acct, 'paid') <> 10000 then raise exception 'v61: paid class balance is not 10000'; end if;
  if app.sv_class_balance(v_business, v_acct, 'bonus') <> 2000 then raise exception 'v61: bonus class balance is not 2000'; end if;
  if app.sv_lot_remaining(v_paid_lot) <> 10000 then raise exception 'v61: paid lot remaining is not 10000'; end if;
  if app.sv_lot_remaining(v_bonus_lot) <> 2000 then raise exception 'v61: bonus lot remaining is not 2000'; end if;

  -- get_sv_account: spendable false, authority verbatim, balances derived.
  perform pg_temp.as_v61_principal(v_owner, 'authenticated');
  v_res := public.get_sv_account(v_business, v_client);
  if (v_res->>'spendable')::boolean is not false then raise exception 'v61: get_sv_account.spendable is not false'; end if;
  if (v_res->>'authority_state') <> 'unbuilt' then raise exception 'v61: get_sv_account.authority_state is not verbatim unbuilt'; end if;
  if (v_res->'balances'->>'total_cents')::int <> 12000
     or (v_res->'balances'->>'paid_cents')::int <> 10000
     or (v_res->'balances'->>'bonus_cents')::int <> 2000 then
    raise exception 'v61: get_sv_account balances are wrong'; end if;
  if jsonb_array_length(v_res->'lots') <> 2 then raise exception 'v61: get_sv_account did not list two lots'; end if;

  -- ============================================================
  -- 2. Conflicting reuse of the same idempotency key (different plan version) -> 22023, no
  --    second lot/movement.
  -- ============================================================
  reset role;
  select count(*) into v_lots_before from public.sv_lots where business_id = v_business;
  select count(*) into v_moves_before from public.sv_lot_movements where business_id = v_business;
  perform pg_temp.as_v61_principal(v_owner, 'authenticated');
  begin
    perform public.sv_topup(v_business, v_client, v_pv2, v_key);   -- SAME key, different plan version
    raise exception 'v61: a conflicting idempotency key was accepted';
  exception when sqlstate '22023' then null; end;
  reset role;
  if (select count(*) from public.sv_lots where business_id = v_business) <> v_lots_before
     or (select count(*) from public.sv_lot_movements where business_id = v_business) <> v_moves_before then
    raise exception 'v61: a conflicting idempotency key wrote a lot/movement'; end if;

  -- ============================================================
  -- bonus_cents = 0 mints EXACTLY ONE lot + one issue movement (no bonus lot).
  -- ============================================================
  perform pg_temp.as_v61_principal(v_owner, 'authenticated');
  v_res := public.sv_topup(v_business, v_client, v_pv0, v_key0);
  if (v_res->'bonus_lot') <> 'null'::jsonb and v_res->'bonus_lot' is not null then
    raise exception 'v61: a zero-bonus plan still reported a bonus lot: %', v_res->'bonus_lot'; end if;
  reset role;
  if (select count(*) from public.sv_lots where business_id = v_business and operation_id = (v_res->>'operation_id')::uuid) <> 1 then
    raise exception 'v61: a zero-bonus plan minted more than one lot'; end if;
  if (select count(*) from public.sv_lot_movements where business_id = v_business and operation_id = (v_res->>'operation_id')::uuid) <> 1 then
    raise exception 'v61: a zero-bonus plan wrote more than one movement'; end if;

  -- ============================================================
  -- sv_grant: owner-only bonus grant (append-only ledger event with actor + reason).
  -- ============================================================
  perform pg_temp.as_v61_principal(v_owner, 'authenticated');
  v_res := public.sv_grant(v_business, v_client, 750, 'goodwill', v_gkey);
  if (v_res->'bonus_lot'->>'minted_cents')::int <> 750 or (v_res->'bonus_lot'->>'class') <> 'bonus' then
    raise exception 'v61: sv_grant did not mint a 750 bonus lot'; end if;
  -- reason < 3 chars is rejected.
  begin
    perform public.sv_grant(v_business, v_client, 100, 'x', gen_random_uuid());
    raise exception 'v61: sv_grant accepted a too-short reason';
  exception when sqlstate '22023' then null; end;
  reset role;
  if app.sv_class_balance(v_business, v_acct, 'bonus') <> 2750 then raise exception 'v61: grant did not add 750 to the bonus balance'; end if;
  -- the grant is auditable with actor + reason.
  if not exists (select 1 from public.audit_log where business_id = v_business and action = 'SV_GRANT'
                  and actor = v_owner and detail->>'reason' = 'goodwill') then
    raise exception 'v61: SV_GRANT was not audited with actor + reason'; end if;

  -- ============================================================
  -- 15. A failed transaction (invalid plan version) leaves NO orphan op/lot/movement row.
  -- ============================================================
  reset role;
  select count(*) into v_ops_before from public.sv_operations where business_id = v_business;
  select count(*) into v_lots_before from public.sv_lots where business_id = v_business;
  select count(*) into v_moves_before from public.sv_lot_movements where business_id = v_business;
  perform pg_temp.as_v61_principal(v_owner, 'authenticated');
  begin
    perform public.sv_topup(v_business, v_client, gen_random_uuid(), gen_random_uuid());  -- invalid plan version
    raise exception 'v61: an invalid plan version was accepted';
  exception when sqlstate '22023' then null; end;
  reset role;
  if (select count(*) from public.sv_operations where business_id = v_business) <> v_ops_before
     or (select count(*) from public.sv_lots where business_id = v_business) <> v_lots_before
     or (select count(*) from public.sv_lot_movements where business_id = v_business) <> v_moves_before then
    raise exception 'v61: a failed topup left an orphan op/lot/movement row'; end if;

  -- ============================================================
  -- Zero rows written to points_ledger / credit_ledger / sales by any sv function.
  -- ============================================================
  if (select count(*) from public.points_ledger) <> v_pl_before
     or (select count(*) from public.credit_ledger) <> v_cl_before
     or (select count(*) from public.sales) <> v_sales_before then
    raise exception 'v61: an sv function wrote to points_ledger/credit_ledger/sales'; end if;

  -- ============================================================
  -- 12. Non-owner (frontdesk) cannot topup / grant; anon cannot.
  -- ============================================================
  reset role;
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_fresh, 'authenticated', 'authenticated',
    'v61-fd-' || substr(v_fresh::text, 1, 8) || '@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, full_name, active)
  values (v_business, v_fresh, 'frontdesk', 'v61 frontdesk', true) returning id into v_fresh_staff;
  perform pg_temp.as_v61_principal(v_fresh, 'authenticated');
  begin perform public.sv_topup(v_business, v_client, v_pv, gen_random_uuid());
    raise exception 'v61: a non-owner performed a topup'; exception when sqlstate '42501' then null; end;
  begin perform public.sv_grant(v_business, v_client, 100, 'nope', gen_random_uuid());
    raise exception 'v61: a non-owner performed a grant'; exception when sqlstate '42501' then null; end;
  -- but a member CAN read (contract §9: view own-tenant balances).
  v_res := public.get_sv_account(v_business, v_client);
  if (v_res->>'spendable')::boolean is not false then raise exception 'v61: member read reported spendable'; end if;

  perform pg_temp.as_v61_principal(null, 'anon');
  begin perform public.sv_topup(v_business, v_client, v_pv, gen_random_uuid());
    raise exception 'v61: anon performed a topup'; exception when insufficient_privilege then null; end;
  begin perform public.sv_grant(v_business, v_client, 100, 'nope', gen_random_uuid());
    raise exception 'v61: anon performed a grant'; exception when insufficient_privilege then null; end;
  begin perform public.get_sv_account(v_business, v_client);
    raise exception 'v61: anon read an sv account'; exception when insufficient_privilege then null; end;

  -- ============================================================
  -- 14. Cross-tenant isolation.
  -- ============================================================
  perform pg_temp.as_v61_principal(v_owner, 'authenticated');   -- owner A (non-super) attacks business B
  begin perform public.sv_topup(v_business_b, v_client_b, v_pv, gen_random_uuid());
    raise exception 'v61: cross-tenant topup into another business succeeded'; exception when sqlstate '42501' then null; end;
  begin perform public.get_sv_account(v_business_b, v_client_b);
    raise exception 'v61: cross-tenant account read succeeded'; exception when sqlstate '42501' then null; end;
  perform pg_temp.as_v61_principal(v_owner_b, 'authenticated');  -- business-B owner cannot write into A
  begin perform public.sv_topup(v_business, v_client, v_pv, gen_random_uuid());
    raise exception 'v61: business-B owner topped up business A'; exception when sqlstate '42501' then null; end;

  -- ============================================================
  -- 13. Anon cannot SELECT any sv table.
  -- ============================================================
  reset role;
  foreach t in array array['sv_accounts','sv_plans','sv_plan_versions','sv_lots','sv_lot_movements','sv_operations','sv_authority'] loop
    if has_table_privilege('anon', 'public.' || t, 'select') then
      raise exception 'v61: anon retains SELECT on public.%', t; end if;
    -- and zero browser writes for anon + authenticated.
    if has_table_privilege('anon', 'public.' || t, 'insert') or has_table_privilege('anon', 'public.' || t, 'update')
       or has_table_privilege('anon', 'public.' || t, 'delete')
       or has_table_privilege('authenticated', 'public.' || t, 'insert')
       or has_table_privilege('authenticated', 'public.' || t, 'update')
       or has_table_privilege('authenticated', 'public.' || t, 'delete') then
      raise exception 'v61: a browser role retains a direct write on public.%', t; end if;
    -- RLS enabled + at least the owner + sa read policies.
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then
      raise exception 'v61: RLS is not enabled on public.%', t; end if;
    if (select count(*) from pg_policies where schemaname = 'public' and tablename = t) < 2 then
      raise exception 'v61: public.% is missing its owner/sa read policies', t; end if;
  end loop;

  -- ============================================================
  -- No mutable balance column, and integer-only money on every sv table.
  -- ============================================================
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name like 'sv\_%'
                and column_name in ('balance', 'balance_cents')) then
    raise exception 'v61: an sv table carries a mutable balance column'; end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name like 'sv\_%'
                and data_type in ('numeric', 'double precision', 'real')) then
    raise exception 'v61: an sv table carries a non-integer (float/numeric) money column'; end if;

  -- ============================================================
  -- Every sv SECURITY DEFINER function pins search_path + is revoked from anon (helpers also
  -- from authenticated; the three public RPCs are granted to authenticated).
  -- ============================================================
  for v_oid in
    select p.oid from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where (ns.nspname, p.proname) in (
       ('app','sv_immutable_guard'), ('app','sv_authority_guard'), ('app','seed_sv_authority'),
       ('app','trg_seed_sv_authority'), ('app','sv_lot_remaining'), ('app','sv_available_balance'),
       ('app','sv_class_balance'), ('app','sv_ensure_account'),
       ('public','sv_topup'), ('public','sv_grant'), ('public','get_sv_account'))
  loop
    if not (select prosecdef from pg_proc where oid = v_oid) then
      raise exception 'v61: an sv function is not SECURITY DEFINER'; end if;
    if not exists (select 1 from pg_proc where oid = v_oid
                    and array_to_string(coalesce(proconfig, '{}'), ',') like '%search_path=%') then
      raise exception 'v61: an sv function does not pin search_path'; end if;
    if has_function_privilege('anon', v_oid, 'execute') then
      raise exception 'v61: anon retains EXECUTE on an sv function'; end if;
  end loop;
  -- app.* helpers are revoked from authenticated too.
  foreach t in array array['app.sv_immutable_guard()','app.sv_authority_guard()','app.seed_sv_authority(uuid)',
      'app.sv_lot_remaining(uuid)','app.sv_available_balance(uuid,uuid)','app.sv_class_balance(uuid,uuid,text)',
      'app.sv_ensure_account(uuid,uuid)'] loop
    if has_function_privilege('authenticated', t, 'execute') then
      raise exception 'v61: authenticated retains EXECUTE on helper %', t; end if;
  end loop;
  -- the three browser RPCs ARE granted to authenticated.
  if not has_function_privilege('authenticated', 'public.sv_topup(uuid,uuid,uuid,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.sv_grant(uuid,uuid,integer,text,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.get_sv_account(uuid,uuid)', 'execute') then
    raise exception 'v61: a browser sv RPC is not granted to authenticated'; end if;

  -- ============================================================
  -- Append-only / immutable guards: UPDATE + DELETE on sv_lot_movements, sv_lots,
  -- sv_plan_versions all raise restrict_violation.
  -- ============================================================
  reset role;
  begin update public.sv_lot_movements set cents = cents + 1 where lot_id = v_paid_lot;
    raise exception 'v61: sv_lot_movements accepted an UPDATE'; exception when restrict_violation then null; end;
  begin delete from public.sv_lot_movements where lot_id = v_paid_lot;
    raise exception 'v61: sv_lot_movements accepted a DELETE'; exception when restrict_violation then null; end;
  begin update public.sv_lots set minted_cents = minted_cents + 1 where id = v_paid_lot;
    raise exception 'v61: sv_lots accepted an UPDATE'; exception when restrict_violation then null; end;
  begin delete from public.sv_lots where id = v_paid_lot;
    raise exception 'v61: sv_lots accepted a DELETE'; exception when restrict_violation then null; end;
  begin update public.sv_plan_versions set price_cents = price_cents + 1 where id = v_pv;
    raise exception 'v61: sv_plan_versions accepted an UPDATE'; exception when restrict_violation then null; end;
  begin delete from public.sv_plan_versions where id = v_pv;
    raise exception 'v61: sv_plan_versions accepted a DELETE'; exception when restrict_violation then null; end;

  -- ============================================================
  -- The authority guard rejects a direct UPDATE to 'live' (and to 'ready_for_cutover').
  -- ============================================================
  begin update public.sv_authority set state = 'live' where business_id = v_business;
    raise exception 'v61: sv_authority accepted a transition to live'; exception when restrict_violation then null; end;
  begin update public.sv_authority set state = 'ready_for_cutover' where business_id = v_business;
    raise exception 'v61: sv_authority accepted a transition to ready_for_cutover'; exception when restrict_violation then null; end;
  -- a benign transition (unbuilt -> shadow_testing) is allowed by the guard.
  update public.sv_authority set state = 'shadow_testing' where business_id = v_business;
  update public.sv_authority set state = 'unbuilt' where business_id = v_business;

  raise notice 'v61 PS-2A stored-value foundation suite: ALL PASS';
end $v61_test$;

reset role;
rollback;
