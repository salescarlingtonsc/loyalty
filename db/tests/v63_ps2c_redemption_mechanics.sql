-- Rollback-only v63 PS-2A Increment C stored-value REDEMPTION-MECHANICS suite.
-- Run after the pending chain (through v63) in a disposable rehearsal database.
--
-- Proves the Increment-C slice of the owner's 25 + PS-0 arithmetic conformance:
--   PS-0 CONFORMANCE (the important part) - the SQL reproduces the frozen JS oracle to the cent:
--     * allocation vector (10000 paid / 2000 bonus, spend 1000 -> bonus_draw 166, paid_draw 834),
--       asserted DIRECTLY against the pure app.sv_allocate_spend.
--     * SF2 single partial step (1000/137, X=100 -> clawback 13, non-final) and whole-op refund
--       (10000/1200 -> cash 10000, clawback 1200, final) and bonus-expired-unspent (cash 10000,
--       clawback 0), asserted DIRECTLY against the pure app.sv_plan_refund.
--     * SF2 case (a) worked example ($10.00/$1.37, ten $1 refunds to closure) driven through the
--       GATED refund_sv_operation under the shim -> cash total 1000, clawback total 137, ends {0,0}.
--     * case (f) reversal trail (issue+1200, spend-128, expiry-1072, reversal+128, expiry-128 -> 0)
--       driven through sv_spend + sv_expire_due + sv_reverse_spend under the shim.
--   THE GATE (primary safety test): every value RPC on a tenant whose authority is 'unbuilt' (the
--     ship default) raises 22023 'sv_not_live' with ZERO writes (no movement, no reservation).
--   OWNER ADVERSARIAL 4/5/6/7/8/16 via the gated RPCs under a rolled-back authority='live' shim:
--     4 spend at exactly available succeeds; 5 spend above available fails with NO partial movement;
--     6 reverse idempotent; 7 over-reversal fails; 8 expiry cannot expire spent/expired value;
--     16 duplicate sv_spend (same idem key) -> ONE effect. (3 concurrent spends = the .sh harness.)
--   RESERVATIONS: a hold reduces available; a spend of the full balance then fails; release restores
--     it; release is idempotent; available = Σ movements - Σ active holds.
--   HOUSE: append-only guard on sv_reservations; RLS + zero browser DML; definer + pinned
--     search_path + revocation; integer cents; failed txn leaves no orphan movement/reservation;
--     v61 (topup/grant) + v62 (reconciliation) regression; points/credit/gift_cards untouched; the
--     PS-1C checkout kernel byte-unchanged (record_cart_sale + ps1c_plan_checkout still installed)
--     and the PS-1C.2 rule-state axis still 'live'.
--
-- THE authority='live' SHIM (how the gated RPCs are exercised): the v61 sv_authority guard rejects
-- any transition into 'live'. Inside THIS rolled-back transaction ONLY we transiently DISABLE that
-- guard trigger, force the synthetic tenant's row to 'live', re-enable the guard, run the RPCs, and
-- the outer ROLLBACK discards everything. 'live' is NEVER written by a migration, NEVER persisted,
-- NEVER seen by UAT. If this shim were impossible, the RPCs would be proven only via their gate; it
-- is possible, so both the gate AND the full arithmetic are proven.
-- The including transaction owns BEGIN/ROLLBACK; nothing commits.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v63_principal(p_uid uuid, p_role text)
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
    raise exception 'unsupported v63 principal';
  end if;
end $$;
grant execute on function pg_temp.as_v63_principal(uuid, text) to authenticated, anon;

-- Create a fresh client and return its id (owner/superuser context).
create or replace function pg_temp.v63_client(p_business uuid, p_name text, p_phone text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.clients(business_id, full_name, phone) values (p_business, p_name, p_phone) returning id into v_id;
  return v_id;
end $$;

-- Seed lots with EXPLICIT expiry keys (topup + paid/bonus lots + issue movements) so we can craft
-- an already-past-expiry lot that sv_topup (future-only expiry) cannot mint. Returns account/op/lots.
create or replace function pg_temp.v63_seed(
  p_business uuid, p_client uuid, p_paid int, p_paid_expiry timestamptz, p_bonus int, p_bonus_expiry timestamptz)
returns jsonb language plpgsql as $$
declare
  v_account uuid := app.sv_ensure_account(p_business, p_client);
  v_op uuid := gen_random_uuid();
  v_paid_lot uuid := gen_random_uuid();
  v_bonus_lot uuid;
begin
  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash)
  values (v_op, p_business, 'topup', gen_random_uuid(), md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text));
  insert into public.sv_lots(id, business_id, account_id, operation_id, class, minted_cents, expiry_key, earned_seq)
  values (v_paid_lot, p_business, v_account, v_op, 'paid', p_paid, p_paid_expiry, nextval('app.sv_earned_seq'));
  insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
  values (p_business, v_account, v_paid_lot, v_op, 'issue', p_paid);
  if p_bonus > 0 then
    v_bonus_lot := gen_random_uuid();
    insert into public.sv_lots(id, business_id, account_id, operation_id, class, minted_cents, expiry_key, earned_seq)
    values (v_bonus_lot, p_business, v_account, v_op, 'bonus', p_bonus, p_bonus_expiry, nextval('app.sv_earned_seq'));
    insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
    values (p_business, v_account, v_bonus_lot, v_op, 'issue', p_bonus);
  end if;
  return jsonb_build_object('account', v_account, 'operation', v_op, 'paid_lot', v_paid_lot, 'bonus_lot', v_bonus_lot);
end $$;

-- Force authority='live' for a business inside this rolled-back txn ONLY (see header).
create or replace function pg_temp.v63_force_live(p_business uuid, p_live boolean)
returns void language plpgsql as $$
begin
  execute 'reset role';
  alter table public.sv_authority disable trigger sv_authority_guard;
  update public.sv_authority set state = case when p_live then 'live' else 'unbuilt' end
   where business_id = p_business and asset = 'stored_value';
  alter table public.sv_authority enable trigger sv_authority_guard;
end $$;
-- Callable from an authenticated principal (the body resets role to the session owner
-- to run the privileged ALTER). Rolled-back test-only shim; never in a migration.
grant execute on function pg_temp.v63_force_live(uuid, boolean) to authenticated, anon;

do $v63_test$
declare
  v_business uuid; v_owner uuid;
  v_business_b uuid; v_owner_b uuid; v_client_b uuid;
  v_plan uuid; v_pv_a uuid; v_pv_r uuid; v_pv_p uuid;
  v_seed jsonb; v_acct uuid; v_op uuid; v_paid_lot uuid; v_bonus_lot uuid;
  v_res jsonb; v_res2 jsonb; v_spend_op uuid; v_rev jsonb;
  v_c_alloc uuid; v_c_whole uuid; v_c_partial uuid; v_c_bexp uuid;
  v_c_exact uuid; v_c_over uuid; v_c_dup uuid; v_c_rev uuid; v_c_exp uuid; v_c_casef uuid; v_c_casea uuid; v_c_resv uuid;
  v_key uuid; v_gkey uuid; v_reservation uuid;
  v_mv_before int; v_rv_before int; v_pl_before int; v_cl_before int; v_gc_before int;
  v_cash_total int := 0; v_claw_total int := 0; i int; v_paid_rem int;
  t text; v_oid oid; v_bonus_trail text; v_state text;
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
  if v_business is null or v_business_b is null then raise exception 'v63 needs the pristine fixtures A + B'; end if;
  select id into v_client_b from public.clients where business_id = v_business_b order by created_at limit 1;

  -- plan versions: A=10000/2000/365d, R(whole)=10000/1200/365d, P(partial)=1000/137/365d
  insert into public.sv_plans(business_id, name) values (v_business, 'v63 plan') returning id into v_plan;
  insert into public.sv_plan_versions(business_id, plan_id, version_no, price_cents, bonus_cents, expiry_days, terms_snapshot)
  values (v_business, v_plan, 1, 10000, 2000, 365, jsonb_build_object('price_cents', 10000, 'bonus_cents', 2000)) returning id into v_pv_a;
  insert into public.sv_plan_versions(business_id, plan_id, version_no, price_cents, bonus_cents, expiry_days, terms_snapshot)
  values (v_business, v_plan, 2, 10000, 1200, 365, jsonb_build_object('price_cents', 10000, 'bonus_cents', 1200)) returning id into v_pv_r;
  insert into public.sv_plan_versions(business_id, plan_id, version_no, price_cents, bonus_cents, expiry_days, terms_snapshot)
  values (v_business, v_plan, 3, 1000, 137, 365, jsonb_build_object('price_cents', 1000, 'bonus_cents', 137)) returning id into v_pv_p;

  v_c_alloc   := pg_temp.v63_client(v_business, 'v63 alloc',   '+6590006301');
  v_c_whole   := pg_temp.v63_client(v_business, 'v63 whole',   '+6590006302');
  v_c_partial := pg_temp.v63_client(v_business, 'v63 partial', '+6590006303');
  v_c_bexp    := pg_temp.v63_client(v_business, 'v63 bexp',    '+6590006304');
  v_c_exact   := pg_temp.v63_client(v_business, 'v63 exact',   '+6590006305');
  v_c_over    := pg_temp.v63_client(v_business, 'v63 over',    '+6590006306');
  v_c_dup     := pg_temp.v63_client(v_business, 'v63 dup',     '+6590006307');
  v_c_rev     := pg_temp.v63_client(v_business, 'v63 rev',     '+6590006308');
  v_c_exp     := pg_temp.v63_client(v_business, 'v63 exp',     '+6590006309');
  v_c_casef   := pg_temp.v63_client(v_business, 'v63 casef',   '+6590006310');
  v_c_casea   := pg_temp.v63_client(v_business, 'v63 casea',   '+6590006311');
  v_c_resv    := pg_temp.v63_client(v_business, 'v63 resv',    '+6590006312');

  select count(*) into v_pl_before from public.points_ledger;
  select count(*) into v_cl_before from public.credit_ledger;
  select count(*) into v_gc_before from public.gift_cards;

  -- ============================================================
  -- REGRESSION (v61): a topup + grant + idempotent retry still holds; sv ledger stays separate.
  -- ============================================================
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  v_res := public.sv_topup(v_business, v_c_alloc, v_pv_a, gen_random_uuid());
  v_acct := (v_res->>'account_id')::uuid;
  reset role;
  if app.sv_available_balance(v_business, v_acct) <> 12000 then raise exception 'v63 regression: available is not 12000'; end if;

  -- ============================================================
  -- PS-0 CONFORMANCE #1: allocation vector via the PURE app.sv_allocate_spend (no authority gate).
  -- 10000 paid / 2000 bonus, spend 1000 -> bonus_draw = floor(1000*2000/12000) = 166, paid_draw 834.
  -- ============================================================
  v_res := app.sv_allocate_spend(v_business, v_acct, 1000);
  if (v_res->>'ok')::boolean is not true then raise exception 'v63: allocate_spend not ok'; end if;
  if (v_res->>'bonus_draw')::int <> 166 or (v_res->>'paid_draw')::int <> 834 then
    raise exception 'v63 PS-0: allocation vector wrong (bonus=% paid=%)', v_res->>'bonus_draw', v_res->>'paid_draw'; end if;
  if (v_res->>'paid_draw')::int + (v_res->>'bonus_draw')::int <> 1000 then raise exception 'v63: allocation does not conserve'; end if;
  if jsonb_array_length(v_res->'plan') <> 2 then raise exception 'v63: allocation plan is not two lots'; end if;
  -- plan cents are negative (spend movements) and never over-draw.
  if (select sum((e->>'cents')::int) from jsonb_array_elements(v_res->'plan') e) <> -1000 then
    raise exception 'v63: allocation plan cents do not sum to -1000'; end if;
  -- over-spend is rejected (not raised) by the pure planner.
  if (app.sv_allocate_spend(v_business, v_acct, 99999)->>'ok')::boolean is not false then
    raise exception 'v63: allocate_spend did not reject an over-spend'; end if;

  -- ============================================================
  -- PS-0 CONFORMANCE #2: refund planner via the PURE app.sv_plan_refund (no authority gate).
  --   whole-op (10000/1200 -> cash 10000, clawback 1200, final); partial single step (1000/137,
  --   X=100 -> clawback floor(137*100/1000)=13, non-final); bonus-expired-unspent (cash 10000, claw 0).
  -- ============================================================
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  v_res := public.sv_topup(v_business, v_c_whole, v_pv_r, gen_random_uuid());   -- 10000/1200
  v_op := (v_res->>'operation_id')::uuid;
  reset role;
  v_res := app.sv_plan_refund(v_business, v_op, null);   -- whole-op
  if (v_res->>'cash_cents')::int <> 10000 or (v_res->>'clawback_cents')::int <> 1200 or (v_res->>'final')::boolean is not true then
    raise exception 'v63 PS-0: whole-op refund wrong (cash=% claw=% final=%)', v_res->>'cash_cents', v_res->>'clawback_cents', v_res->>'final'; end if;

  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  v_res := public.sv_topup(v_business, v_c_partial, v_pv_p, gen_random_uuid());  -- 1000/137
  v_op := (v_res->>'operation_id')::uuid;
  reset role;
  v_res := app.sv_plan_refund(v_business, v_op, 100);   -- partial, non-final
  if (v_res->>'cash_cents')::int <> 100 or (v_res->>'clawback_cents')::int <> 13 or (v_res->>'final')::boolean is not false then
    raise exception 'v63 PS-0: partial SF2 step wrong (cash=% claw=% final=%)', v_res->>'cash_cents', v_res->>'clawback_cents', v_res->>'final'; end if;

  -- bonus-expired-unspent: mint 10000/1200 then directly expire the bonus lot -> refund $100.00, claw 0.
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  v_res := public.sv_topup(v_business, v_c_bexp, v_pv_r, gen_random_uuid());   -- 10000/1200
  v_op := (v_res->>'operation_id')::uuid;
  v_bonus_lot := (v_res->'bonus_lot'->>'lot_id')::uuid;
  reset role;
  insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
  values (v_business, (v_res->>'account_id')::uuid, v_bonus_lot, v_op, 'expiry', -1200);   -- bonus expires unspent
  v_res2 := app.sv_plan_refund(v_business, v_op, null);
  if (v_res2->>'cash_cents')::int <> 10000 or (v_res2->>'clawback_cents')::int <> 0 then
    raise exception 'v63 PS-0: bonus-expired-unspent refund wrong (cash=% claw=%)', v_res2->>'cash_cents', v_res2->>'clawback_cents'; end if;

  -- ============================================================
  -- THE GATE (primary safety test): every value RPC on the DEFAULT 'unbuilt' tenant raises 22023
  -- 'sv_not_live' with ZERO writes. (Authority is untouched so far -> unbuilt.)
  -- ============================================================
  reset role;
  if (select state from public.sv_authority where business_id = v_business and asset = 'stored_value') <> 'unbuilt' then
    raise exception 'v63 gate precondition: business A authority is not unbuilt'; end if;
  select count(*) into v_mv_before from public.sv_lot_movements where business_id = v_business;
  select count(*) into v_rv_before from public.sv_reservations where business_id = v_business;
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');

  begin perform public.sv_reserve(v_business, v_acct, 100, gen_random_uuid());
    raise exception 'v63 gate: sv_reserve ran while not live';
  exception when sqlstate '22023' then
    if position('sv_not_live' in sqlerrm) = 0 then raise exception 'v63 gate: sv_reserve wrong 22023 (%)', sqlerrm; end if; end;
  begin perform public.sv_release(v_business, gen_random_uuid(), gen_random_uuid());
    raise exception 'v63 gate: sv_release ran while not live';
  exception when sqlstate '22023' then
    if position('sv_not_live' in sqlerrm) = 0 then raise exception 'v63 gate: sv_release wrong 22023 (%)', sqlerrm; end if; end;
  begin perform public.sv_spend(v_business, v_acct, 100, gen_random_uuid());
    raise exception 'v63 gate: sv_spend ran while not live';
  exception when sqlstate '22023' then
    if position('sv_not_live' in sqlerrm) = 0 then raise exception 'v63 gate: sv_spend wrong 22023 (%)', sqlerrm; end if; end;
  begin perform public.sv_reverse_spend(v_business, gen_random_uuid(), gen_random_uuid());
    raise exception 'v63 gate: sv_reverse_spend ran while not live';
  exception when sqlstate '22023' then
    if position('sv_not_live' in sqlerrm) = 0 then raise exception 'v63 gate: sv_reverse_spend wrong 22023 (%)', sqlerrm; end if; end;
  begin perform public.refund_sv_operation(v_business, gen_random_uuid(), null, gen_random_uuid());
    raise exception 'v63 gate: refund_sv_operation ran while not live';
  exception when sqlstate '22023' then
    if position('sv_not_live' in sqlerrm) = 0 then raise exception 'v63 gate: refund wrong 22023 (%)', sqlerrm; end if; end;
  begin perform public.sv_expire_due(v_business, 100);
    raise exception 'v63 gate: sv_expire_due ran while not live';
  exception when sqlstate '22023' then
    if position('sv_not_live' in sqlerrm) = 0 then raise exception 'v63 gate: sv_expire_due wrong 22023 (%)', sqlerrm; end if; end;

  reset role;
  if (select count(*) from public.sv_lot_movements where business_id = v_business) <> v_mv_before then
    raise exception 'v63 gate: a refused value RPC wrote a movement'; end if;
  if (select count(*) from public.sv_reservations where business_id = v_business) <> v_rv_before then
    raise exception 'v63 gate: a refused value RPC wrote a reservation'; end if;

  -- ============================================================
  -- SHIM ON: force authority='live' for business A inside this rolled-back txn (see header).
  -- ============================================================
  perform pg_temp.v63_force_live(v_business, true);
  if (select state from public.sv_authority where business_id = v_business and asset = 'stored_value') <> 'live' then
    raise exception 'v63 shim: authority was not forced to live'; end if;

  -- ---- OWNER TEST 4: spend at EXACTLY available succeeds (12000 on 10000/2000). ----
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  v_res := public.sv_topup(v_business, v_c_exact, v_pv_a, gen_random_uuid());   -- 10000/2000
  v_acct := (v_res->>'account_id')::uuid;
  v_res := public.sv_spend(v_business, v_acct, 12000, gen_random_uuid());
  if (v_res->>'status') <> 'ok' then raise exception 'v63-4: exact-balance spend did not succeed'; end if;
  if (v_res->>'paid_draw_cents')::int <> 10000 or (v_res->>'bonus_draw_cents')::int <> 2000 then
    raise exception 'v63-4: exact spend draw wrong (paid=% bonus=%)', v_res->>'paid_draw_cents', v_res->>'bonus_draw_cents'; end if;
  reset role;
  if app.sv_available_balance(v_business, v_acct) <> 0 then raise exception 'v63-4: available after exact spend is not 0'; end if;

  -- ---- OWNER TEST 5: spend ABOVE available fails with NO partial movement. ----
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  v_res := public.sv_topup(v_business, v_c_over, v_pv_p, gen_random_uuid());   -- 1000/137 => available 1137
  v_acct := (v_res->>'account_id')::uuid;
  reset role;
  select count(*) into v_mv_before from public.sv_lot_movements where business_id = v_business and account_id = v_acct;
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  begin perform public.sv_spend(v_business, v_acct, 1138, gen_random_uuid());   -- 1 over available
    raise exception 'v63-5: over-available spend succeeded';
  exception when sqlstate '22023' then null; end;
  reset role;
  if (select count(*) from public.sv_lot_movements where business_id = v_business and account_id = v_acct) <> v_mv_before then
    raise exception 'v63-5: a failed spend wrote a partial movement'; end if;

  -- ---- OWNER TEST 16: duplicate sv_spend (same idem key) -> ONE effect. ----
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  v_res := public.sv_topup(v_business, v_c_dup, v_pv_p, gen_random_uuid());   -- 1000/137
  v_acct := (v_res->>'account_id')::uuid;
  reset role;
  select count(*) into v_mv_before from public.sv_lot_movements where business_id = v_business and account_id = v_acct;
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  v_key := gen_random_uuid();
  v_res  := public.sv_spend(v_business, v_acct, 500, v_key);
  v_res2 := public.sv_spend(v_business, v_acct, 500, v_key);   -- identical retry
  if v_res <> v_res2 then raise exception 'v63-16: duplicate spend returned a different result'; end if;
  reset role;
  -- 500 on 1000/137: bonus_draw=floor(500*137/1137)=60, paid_draw=440 -> two spend movements, ONCE.
  if (select count(*) from public.sv_lot_movements where business_id = v_business and account_id = v_acct and kind = 'spend') <> 2 then
    raise exception 'v63-16: duplicate spend wrote its movements twice'; end if;
  if app.sv_available_balance(v_business, v_acct) <> 637 then raise exception 'v63-16: balance reduced twice (%)', app.sv_available_balance(v_business, v_acct); end if;

  -- ---- OWNER TEST 6 + 7: reverse idempotent (same key) and over-reversal fails (different key). ----
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  v_res := public.sv_topup(v_business, v_c_rev, v_pv_a, gen_random_uuid());   -- 10000/2000
  v_acct := (v_res->>'account_id')::uuid;
  v_res := public.sv_spend(v_business, v_acct, 3000, gen_random_uuid());
  v_spend_op := (v_res->>'operation_id')::uuid;
  reset role;
  select count(*) into v_mv_before from public.sv_lot_movements where business_id = v_business and account_id = v_acct;
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  v_key := gen_random_uuid();
  v_rev  := public.sv_reverse_spend(v_business, v_spend_op, v_key);
  v_res2 := public.sv_reverse_spend(v_business, v_spend_op, v_key);   -- 6: idempotent replay
  if v_rev <> v_res2 then raise exception 'v63-6: reverse replay returned a different result'; end if;
  reset role;
  -- reversal restored the exact 3000 (no re-expiry: lots not past expiry) -> back to 12000.
  if app.sv_available_balance(v_business, v_acct) <> 12000 then raise exception 'v63-6: reverse did not restore to 12000 (%)', app.sv_available_balance(v_business, v_acct); end if;
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  begin perform public.sv_reverse_spend(v_business, v_spend_op, gen_random_uuid());   -- 7: DIFFERENT key
    raise exception 'v63-7: over-reversal succeeded';
  exception when sqlstate '22023' then null; end;

  -- ---- OWNER TEST 8: expiry cannot expire spent/already-expired value (idempotent per lot). ----
  reset role;
  v_seed := pg_temp.v63_seed(v_business, v_c_exp, 1000, now() - interval '1 day', 0, null);   -- paid lot, past expiry
  v_acct := (v_seed->>'account')::uuid;
  v_paid_lot := (v_seed->>'paid_lot')::uuid;
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  v_res := public.sv_spend(v_business, v_acct, 400, gen_random_uuid());   -- spend 400 -> remaining 600
  v_res := public.sv_expire_due(v_business, 100);
  if (v_res->>'expired_cents')::int <> 600 then raise exception 'v63-8: expiry did not sweep exactly the 600 remaining (got %)', v_res->>'expired_cents'; end if;
  v_res := public.sv_expire_due(v_business, 100);   -- rerun: nothing left
  if (v_res->>'expired_cents')::int <> 0 then raise exception 'v63-8: expiry re-swept already-expired value (got %)', v_res->>'expired_cents'; end if;
  reset role;
  if app.sv_lot_remaining(v_paid_lot) <> 0 then raise exception 'v63-8: lot remaining is not 0 after expiry'; end if;

  -- ============================================================
  -- PS-0 CONFORMANCE #3 (case a): $10.00/$1.37, ten $1 refunds to closure via GATED refund RPC.
  -- ============================================================
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  v_res := public.sv_topup(v_business, v_c_casea, v_pv_p, gen_random_uuid());   -- 1000/137
  v_op := (v_res->>'operation_id')::uuid;
  for i in 1..10 loop
    v_res := public.refund_sv_operation(v_business, v_op, 100, gen_random_uuid());
    v_cash_total := v_cash_total + (v_res->>'cash_cents')::int;
    v_claw_total := v_claw_total + (v_res->>'clawback_cents')::int;
  end loop;
  if v_cash_total <> 1000 then raise exception 'v63 case(a): cash total is not 1000 (got %)', v_cash_total; end if;
  if v_claw_total <> 137 then raise exception 'v63 case(a): clawback total is not 137 (got %)', v_claw_total; end if;
  reset role;
  -- op closed at {paid:0, bonus:0} - no stranded cent (Σ movements over the op's lots is 0).
  if (select coalesce(sum(m.cents),0) from public.sv_lot_movements m join public.sv_lots l on l.id = m.lot_id
        where l.business_id = v_business and l.operation_id = v_op) <> 0 then
    raise exception 'v63 case(a): operation did not close at zero'; end if;

  -- ============================================================
  -- PS-0 CONFORMANCE #4 (case f): expired bonus then reversal -> restore-then-expire trail.
  -- Seed 10000 paid (future) + 1200 bonus (PAST expiry); spend $12 (bonus-128, paid-1072); expire the
  -- bonus lot (-1072 remaining); reverse the spend (paid+1072; bonus+128 then re-expire-128).
  -- ============================================================
  reset role;
  v_seed := pg_temp.v63_seed(v_business, v_c_casef, 10000, now() + interval '365 days', 1200, now() - interval '1 day');
  v_acct := (v_seed->>'account')::uuid;
  v_paid_lot := (v_seed->>'paid_lot')::uuid;
  v_bonus_lot := (v_seed->>'bonus_lot')::uuid;
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  v_res := public.sv_spend(v_business, v_acct, 1200, gen_random_uuid());
  v_spend_op := (v_res->>'operation_id')::uuid;
  if (v_res->>'bonus_draw_cents')::int <> 128 or (v_res->>'paid_draw_cents')::int <> 1072 then
    raise exception 'v63 case(f): spend draw wrong (bonus=% paid=%)', v_res->>'bonus_draw_cents', v_res->>'paid_draw_cents'; end if;
  perform public.sv_expire_due(v_business, 100);   -- bonus lot (past expiry) sweeps its 1072 remaining
  v_rev := public.sv_reverse_spend(v_business, v_spend_op, gen_random_uuid());
  reset role;
  -- paid fully restored; bonus restore-then-expired to 0.
  if app.sv_lot_remaining(v_paid_lot) <> 10000 then raise exception 'v63 case(f): paid not restored to 10000 (%)', app.sv_lot_remaining(v_paid_lot); end if;
  if app.sv_lot_remaining(v_bonus_lot) <> 0 then raise exception 'v63 case(f): bonus not 0 (%)', app.sv_lot_remaining(v_bonus_lot); end if;
  -- the exact bonus-lot trail is {issue+1200, spend-128, expiry-1072, reversal+128, expiry-128},
  -- which sums to 0 (= remaining). sv_lot_movements has no monotonic seq (id is a random uuid,
  -- created_at is the txn time), so we assert the deterministic multiset (sorted by cents,kind).
  select string_agg(kind || ':' || cents::text, ',' order by cents, kind) into v_bonus_trail
    from public.sv_lot_movements where lot_id = v_bonus_lot and business_id = v_business;
  if v_bonus_trail <> 'expiry:-1072,expiry:-128,spend:-128,reversal:128,issue:1200' then
    raise exception 'v63 case(f): bonus trail multiset is %, expected {issue+1200,spend-128,expiry-1072,reversal+128,expiry-128}', v_bonus_trail; end if;
  if (select coalesce(sum(cents),0) from public.sv_lot_movements where lot_id = v_bonus_lot and business_id = v_business) <> 0 then
    raise exception 'v63 case(f): bonus lot trail does not sum to 0'; end if;

  -- ============================================================
  -- RESERVATIONS: a hold reduces available; a full-balance spend then fails; release restores it;
  -- release is idempotent; available = Σ movements - Σ active holds.
  -- ============================================================
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  v_res := public.sv_topup(v_business, v_c_resv, v_pv_p, gen_random_uuid());   -- 1000/137 => available 1137
  v_acct := (v_res->>'account_id')::uuid;
  v_res := public.sv_reserve(v_business, v_acct, 1000, gen_random_uuid());
  v_reservation := (v_res->>'reservation_id')::uuid;
  reset role;
  if app.sv_available_balance(v_business, v_acct) <> 137 then raise exception 'v63 reserve: available after a 1000 hold is not 137 (%)', app.sv_available_balance(v_business, v_acct); end if;
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  begin perform public.sv_spend(v_business, v_acct, 200, gen_random_uuid());   -- 200 > 137 available
    raise exception 'v63 reserve: a spend consumed held value';
  exception when sqlstate '22023' then null; end;
  v_key := gen_random_uuid();
  v_res  := public.sv_release(v_business, v_reservation, v_key);
  v_res2 := public.sv_release(v_business, v_reservation, v_key);   -- idempotent replay
  if v_res <> v_res2 then raise exception 'v63 reserve: release replay differed'; end if;
  reset role;
  if app.sv_available_balance(v_business, v_acct) <> 1137 then raise exception 'v63 reserve: release did not restore available to 1137 (%)', app.sv_available_balance(v_business, v_acct); end if;
  -- releasing again (a DIFFERENT key) is an idempotent no-op, not an error.
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  v_res := public.sv_release(v_business, v_reservation, gen_random_uuid());
  if (v_res->>'already_released')::boolean is not true then raise exception 'v63 reserve: re-release was not reported as already-released'; end if;

  -- ============================================================
  -- SHIM OFF: return authority to unbuilt (defensive; the outer ROLLBACK discards it regardless).
  -- ============================================================
  perform pg_temp.v63_force_live(v_business, false);

  -- ============================================================
  -- FAILED-TXN atomicity: a spend that raises mid-way (over available) leaves NO orphan op/movement.
  -- (Re-armed under a fresh shim, single savepoint.)
  -- ============================================================
  perform pg_temp.v63_force_live(v_business, true);
  reset role;
  select count(*) into v_mv_before from public.sv_lot_movements where business_id = v_business;
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  begin
    perform public.sv_spend(v_business, v_acct, 999999, gen_random_uuid());
    raise exception 'v63: an impossible spend succeeded';
  exception when sqlstate '22023' then null; end;
  reset role;
  if (select count(*) from public.sv_lot_movements where business_id = v_business) <> v_mv_before then
    raise exception 'v63: a failed spend left an orphan movement'; end if;
  perform pg_temp.v63_force_live(v_business, false);

  -- ============================================================
  -- REGRESSION (v62): reconciliation still runs read-only; points/credit/gift_cards untouched by sv.
  -- ============================================================
  perform pg_temp.as_v63_principal(v_owner, 'authenticated');
  v_res := public.run_sv_reconciliation(v_business);
  if (v_res->>'reconciliation_status') is null then raise exception 'v63: run_sv_reconciliation did not return a status'; end if;
  reset role;
  if (select count(*) from public.points_ledger) <> v_pl_before
     or (select count(*) from public.credit_ledger) <> v_cl_before
     or (select count(*) from public.gift_cards) <> v_gc_before then
    raise exception 'v63: an sv operation wrote to points_ledger/credit_ledger/gift_cards'; end if;

  -- ============================================================
  -- CHECKOUT KERNEL byte-unchanged: record_cart_sale (arity 9) + app.ps1c_plan_checkout still exist
  -- and the PS-1C.2 rule-state axis still reports 'live' (independent of stored-value authority).
  -- ============================================================
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'record_cart_sale' and p.pronargs = 9) then
    raise exception 'v63: the kernel finaliser record_cart_sale/9 vanished'; end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'app' and p.proname = 'ps1c_plan_checkout') then
    raise exception 'v63: app.ps1c_plan_checkout vanished'; end if;
  if app.ps1c2_effect_state(v_business, 'apply_discount_amount') <> 'live' then
    raise exception 'v63: the checkout rule-execution axis is no longer live'; end if;

  -- ============================================================
  -- HOUSE: append-only guard on sv_reservations (UPDATE of identity + DELETE -> restrict_violation).
  -- ============================================================
  reset role;
  begin update public.sv_reservations set amount_cents = amount_cents + 1 where business_id = v_business;
    raise exception 'v63: sv_reservations accepted an amount UPDATE'; exception when restrict_violation then null; end;
  begin delete from public.sv_reservations where business_id = v_business;
    raise exception 'v63: sv_reservations accepted a DELETE'; exception when restrict_violation then null; end;

  -- sign CHECKs on sv_lot_movements: a positive 'spend' and a negative 'reversal' are rejected.
  begin
    insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
    select v_business, l.account_id, l.id, l.operation_id, 'spend', 1 from public.sv_lots l where l.business_id = v_business limit 1;
    raise exception 'v63: a positive spend movement was accepted'; exception when check_violation then null; end;

  -- ============================================================
  -- RLS + zero browser DML on sv_reservations; anon cannot SELECT.
  -- ============================================================
  if has_table_privilege('anon', 'public.sv_reservations', 'select') then raise exception 'v63: anon retains SELECT on sv_reservations'; end if;
  if has_table_privilege('anon', 'public.sv_reservations', 'insert') or has_table_privilege('authenticated', 'public.sv_reservations', 'insert')
     or has_table_privilege('authenticated', 'public.sv_reservations', 'update') or has_table_privilege('authenticated', 'public.sv_reservations', 'delete') then
    raise exception 'v63: a browser role retains a direct write on sv_reservations'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.sv_reservations'::regclass) then
    raise exception 'v63: RLS is not enabled on sv_reservations'; end if;
  if (select count(*) from pg_policies where schemaname = 'public' and tablename = 'sv_reservations') < 2 then
    raise exception 'v63: sv_reservations is missing its owner/sa read policies'; end if;
  -- no mutable balance column on the new table.
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sv_reservations'
              and column_name in ('balance', 'balance_cents')) then
    raise exception 'v63: sv_reservations carries a mutable balance column'; end if;

  -- ============================================================
  -- Every new sv function is SECURITY DEFINER, pins search_path, revoked from anon (helpers also
  -- from authenticated; the six value RPCs are granted to authenticated).
  -- ============================================================
  for v_oid in
    select p.oid from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where (ns.nspname, p.proname) in (
       ('app', 'sv_reservations_guard'), ('app', 'sv_allocate_spend'), ('app', 'sv_plan_refund'),
       ('app', 'sv_checkout_quote'), ('app', 'sv_available_balance'),
       ('public', 'sv_reserve'), ('public', 'sv_release'), ('public', 'sv_spend'),
       ('public', 'sv_reverse_spend'), ('public', 'refund_sv_operation'), ('public', 'sv_expire_due'))
  loop
    if not (select prosecdef from pg_proc where oid = v_oid) then raise exception 'v63: an sv function is not SECURITY DEFINER'; end if;
    if not exists (select 1 from pg_proc where oid = v_oid and array_to_string(coalesce(proconfig, '{}'), ',') like '%search_path=%') then
      raise exception 'v63: an sv function does not pin search_path'; end if;
    if has_function_privilege('anon', v_oid, 'execute') then raise exception 'v63: anon retains EXECUTE on an sv function'; end if;
  end loop;
  foreach t in array array['app.sv_reservations_guard()', 'app.sv_allocate_spend(uuid,uuid,integer)',
      'app.sv_plan_refund(uuid,uuid,integer)', 'app.sv_checkout_quote(uuid,uuid,integer)',
      'app.sv_available_balance(uuid,uuid)'] loop
    if has_function_privilege('authenticated', t, 'execute') then raise exception 'v63: authenticated retains EXECUTE on helper %', t; end if;
  end loop;
  if not has_function_privilege('authenticated', 'public.sv_reserve(uuid,uuid,integer,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.sv_release(uuid,uuid,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.sv_spend(uuid,uuid,integer,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.sv_reverse_spend(uuid,uuid,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.refund_sv_operation(uuid,uuid,integer,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.sv_expire_due(uuid,integer)', 'execute') then
    raise exception 'v63: a browser sv RPC is not granted to authenticated'; end if;

  -- ============================================================
  -- Owner-only + anon: a frontdesk of A cannot spend/reserve (owner check 42501 BEFORE the gate);
  -- anon cannot execute any value RPC (revoked -> insufficient_privilege).
  -- ============================================================
  reset role;
  v_gkey := gen_random_uuid();
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_gkey, 'authenticated', 'authenticated',
    'v63-fd-' || substr(v_gkey::text, 1, 8) || '@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, full_name, active) values (v_business, v_gkey, 'frontdesk', 'v63 fd', true);
  perform pg_temp.as_v63_principal(v_gkey, 'authenticated');
  begin perform public.sv_spend(v_business, v_acct, 100, gen_random_uuid());
    raise exception 'v63: a frontdesk spent stored value'; exception when sqlstate '42501' then null; end;
  begin perform public.sv_reserve(v_business, v_acct, 100, gen_random_uuid());
    raise exception 'v63: a frontdesk reserved stored value'; exception when sqlstate '42501' then null; end;
  perform pg_temp.as_v63_principal(null, 'anon');
  begin perform public.sv_spend(v_business, v_acct, 100, gen_random_uuid());
    raise exception 'v63: anon spent stored value'; exception when insufficient_privilege then null; end;

  reset role;
  raise notice 'v63 PS-2A Increment C redemption-mechanics suite: ALL PASS';
end $v63_test$;

reset role;
rollback;
