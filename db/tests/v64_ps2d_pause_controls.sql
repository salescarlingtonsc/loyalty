-- Rollback-only v64 PS-2A Increment D stored-value PAUSE/KILL-CONTROLS + CUTOVER-PREVIEW suite.
-- Run after the pending chain (through v64) in a disposable rehearsal database.
--
-- Proves the Increment-D slice of the owner's adversarial set (9/10/11 + the pause matrix + UI
-- truthfulness) and the house rules:
--   OWNER 9 : an 'earn' (or 'all') pause blocks NEW earns (sv_topup + sv_grant -> 22023 sv_paused)
--             while prior movements/lots stay intact (history preserved). Tested at the ship
--             default authority='unbuilt' (topup/grant work there when unpaused).
--   OWNER 10: a 'redeem' (or 'all') pause blocks sv_spend + sv_reserve (under the force-live shim);
--             AND THE PINNED POLICY (parent §8): an 'earn' pause does NOT block spend - spend
--             still succeeds under an earn-only pause when authority='live'.
--   OWNER 11: lifting one scope restores ONLY that operation family: lift earn -> topup works
--             again while a separately-active redeem pause still blocks spend.
--   MATRIX  : app.sv_pause_active(business, asset, family) - earn matches all|earn; redeem matches
--             all|redeem; all_only matches all ONLY. Plus end-to-end: refund blocked by earn|all,
--             reverse blocked by redeem|all, expire blocked by all ONLY (never earn/redeem).
--   CONTROLS: pause idempotent (replayed); lift-of-none no-op (replayed); one-active-per-scope
--             (partial unique); sv_pauses append-only + write-once (identity UPDATE / DELETE /
--             re-lift -> restrict_violation); NO implicit lift (publishing a loyalty config leaves
--             the sv pause active); owner-only (frontdesk 42501, anon insufficient_privilege);
--             cross-tenant denied (42501).
--   UI READ : get_sv_authority_overview surfaces authority_state + active_pauses + can_cutover
--             HARDCODED false; preview_sv_cutover has ready HARDCODED false with real blockers.
--   HOUSE   : sv_pauses RLS + zero browser DML + no mutable balance column; definer + pinned
--             search_path + revocation on every new function; v61/v62/v63 regression; the PS-1C
--             checkout kernel + the PS-1C.2 rule emergency pause are BYTE-untouched.
--
-- THE authority='live' SHIM: the redeem-family gates sit AFTER the v63 sv_not_live gate (which is
-- unreachable in PS-2A), so proving them requires authority='live'. Inside THIS rolled-back
-- transaction ONLY we transiently DISABLE the v61 sv_authority guard, force the synthetic tenant
-- to 'live', re-enable the guard, run the RPCs, and the outer ROLLBACK discards everything. 'live'
-- is NEVER written by a migration, NEVER persisted, NEVER seen by UAT. The earn-family gates
-- (topup/grant) need NO shim - they are provable at the ship default 'unbuilt'.
-- The including transaction owns BEGIN/ROLLBACK; nothing commits.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v64_principal(p_uid uuid, p_role text)
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
    raise exception 'unsupported v64 principal';
  end if;
end $$;
grant execute on function pg_temp.as_v64_principal(uuid, text) to authenticated, anon;

-- Create a fresh client and return its id (owner/superuser context).
create or replace function pg_temp.v64_client(p_business uuid, p_name text, p_phone text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.clients(business_id, full_name, phone) values (p_business, p_name, p_phone) returning id into v_id;
  return v_id;
end $$;

-- Seed a lot with an EXPLICIT (past) expiry key so sv_expire_due has something to sweep.
create or replace function pg_temp.v64_seed(
  p_business uuid, p_client uuid, p_paid int, p_paid_expiry timestamptz)
returns jsonb language plpgsql as $$
declare
  v_account uuid := app.sv_ensure_account(p_business, p_client);
  v_op uuid := gen_random_uuid();
  v_paid_lot uuid := gen_random_uuid();
begin
  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash)
  values (v_op, p_business, 'topup', gen_random_uuid(), md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text));
  insert into public.sv_lots(id, business_id, account_id, operation_id, class, minted_cents, expiry_key, earned_seq)
  values (v_paid_lot, p_business, v_account, v_op, 'paid', p_paid, p_paid_expiry, nextval('app.sv_earned_seq'));
  insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
  values (p_business, v_account, v_paid_lot, v_op, 'issue', p_paid);
  return jsonb_build_object('account', v_account, 'operation', v_op, 'paid_lot', v_paid_lot);
end $$;

-- Force authority='live' for a business inside this rolled-back txn ONLY (see header).
create or replace function pg_temp.v64_force_live(p_business uuid, p_live boolean)
returns void language plpgsql as $$
begin
  execute 'reset role';
  alter table public.sv_authority disable trigger sv_authority_guard;
  update public.sv_authority set state = case when p_live then 'live' else 'unbuilt' end
   where business_id = p_business and asset = 'stored_value';
  alter table public.sv_authority enable trigger sv_authority_guard;
end $$;
grant execute on function pg_temp.v64_force_live(uuid, boolean) to authenticated, anon;

do $v64_test$
declare
  v_business uuid; v_owner uuid;
  v_business_b uuid; v_owner_b uuid;
  v_pv uuid; v_plan uuid;
  v_c_hist uuid; v_c_grant uuid; v_c_spend uuid; v_c_refund uuid; v_c_rev uuid; v_c_exp uuid;
  v_res jsonb; v_res2 jsonb; v_acct uuid; v_op uuid; v_spend_op uuid; v_seed jsonb;
  v_lots_before int; v_mv_before int; v_pl_before int; v_cl_before int; v_gc_before int;
  v_draft uuid; v_cfg uuid; v_gkey uuid; t text; v_oid oid;
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
  if v_business is null or v_business_b is null then raise exception 'v64 needs the pristine fixtures A + B'; end if;

  insert into public.sv_plans(business_id, name) values (v_business, 'v64 plan') returning id into v_plan;
  insert into public.sv_plan_versions(business_id, plan_id, version_no, price_cents, bonus_cents, expiry_days, terms_snapshot)
  values (v_business, v_plan, 1, 1000, 137, 365, jsonb_build_object('price_cents', 1000, 'bonus_cents', 137)) returning id into v_pv;

  v_c_hist   := pg_temp.v64_client(v_business, 'v64 hist',   '+6590007401');
  v_c_grant  := pg_temp.v64_client(v_business, 'v64 grant',  '+6590007402');
  v_c_spend  := pg_temp.v64_client(v_business, 'v64 spend',  '+6590007403');
  v_c_refund := pg_temp.v64_client(v_business, 'v64 refund', '+6590007404');
  v_c_rev    := pg_temp.v64_client(v_business, 'v64 rev',    '+6590007405');
  v_c_exp    := pg_temp.v64_client(v_business, 'v64 exp',    '+6590007406');

  select count(*) into v_pl_before from public.points_ledger;
  select count(*) into v_cl_before from public.credit_ledger;
  select count(*) into v_gc_before from public.gift_cards;

  -- ============================================================
  -- OWNER 9: an 'earn' pause blocks NEW earns (topup + grant -> 22023 sv_paused); prior lots/
  -- movements survive (history preserved). Proven at the ship default authority='unbuilt'.
  -- ============================================================
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  v_res := public.sv_topup(v_business, v_c_hist, v_pv, gen_random_uuid());   -- funds 1000/137
  v_acct := (v_res->>'account_id')::uuid;
  reset role;
  if app.sv_available_balance(v_business, v_acct) <> 1137 then raise exception 'v64-9: initial topup not 1137'; end if;
  select count(*) into v_lots_before from public.sv_lots where business_id = v_business;
  select count(*) into v_mv_before from public.sv_lot_movements where business_id = v_business;

  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  v_res := public.sv_pause(v_business, 'stored_value', 'earn', 'v64-9 earn pause');
  if (v_res->>'replayed')::boolean is not false then raise exception 'v64-9: first pause reported replayed'; end if;

  begin perform public.sv_topup(v_business, v_c_hist, v_pv, gen_random_uuid());
    raise exception 'v64-9: sv_topup ran under an earn pause';
  exception when sqlstate '22023' then
    if position('sv_paused' in sqlerrm) = 0 then raise exception 'v64-9: topup wrong 22023 (%)', sqlerrm; end if; end;
  begin perform public.sv_grant(v_business, v_c_grant, 500, 'v64-9 grant', gen_random_uuid());
    raise exception 'v64-9: sv_grant ran under an earn pause';
  exception when sqlstate '22023' then
    if position('sv_paused' in sqlerrm) = 0 then raise exception 'v64-9: grant wrong 22023 (%)', sqlerrm; end if; end;

  reset role;
  if (select count(*) from public.sv_lots where business_id = v_business) <> v_lots_before then
    raise exception 'v64-9: a paused earn wrote a lot (history not preserved)'; end if;
  if (select count(*) from public.sv_lot_movements where business_id = v_business) <> v_mv_before then
    raise exception 'v64-9: a paused earn wrote a movement (history not preserved)'; end if;
  if app.sv_available_balance(v_business, v_acct) <> 1137 then raise exception 'v64-9: prior balance changed under pause'; end if;

  -- ============================================================
  -- CONTROLS: pause idempotent (replayed) + lift-of-none no-op + one-active-per-scope (partial unique).
  -- ============================================================
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  v_res := public.sv_pause(v_business, 'stored_value', 'earn', 'v64 second earn pause');   -- same active scope
  if (v_res->>'replayed')::boolean is not true then raise exception 'v64: a repeat pause of an active scope was not replayed'; end if;

  reset role;   -- direct duplicate active earn pause -> partial-unique violation
  begin
    insert into public.sv_pauses(business_id, asset, scope, actor, reason)
    values (v_business, 'stored_value', 'earn', v_owner, 'dup active earn');
    raise exception 'v64: a second ACTIVE earn pause was accepted (partial unique missing)';
  exception when unique_violation then null; end;

  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  v_res := public.sv_lift_pause(v_business, 'stored_value', 'earn', 'v64 lift');
  if (v_res->>'lifted')::boolean is not true then raise exception 'v64: lifting an active earn pause did not report lifted'; end if;
  v_res := public.sv_lift_pause(v_business, 'stored_value', 'earn', 'v64 lift none');   -- nothing active now
  if (v_res->>'lifted')::boolean is not false or (v_res->>'replayed')::boolean is not true then
    raise exception 'v64: lift-of-none was not a replayed no-op'; end if;

  -- topup works again once earn is lifted (proves the lift restored earns).
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  v_res := public.sv_topup(v_business, v_c_hist, v_pv, gen_random_uuid());
  if (v_res->>'status') <> 'ok' then raise exception 'v64: topup did not recover after lifting the earn pause'; end if;

  -- ============================================================
  -- APPEND-ONLY + WRITE-ONCE guard: identity UPDATE / DELETE / re-lift -> restrict_violation.
  -- ============================================================
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  perform public.sv_pause(v_business, 'stored_value', 'earn', 'v64 guard row');
  reset role;
  begin update public.sv_pauses set reason = reason || '!' where business_id = v_business and scope = 'earn' and lifted_at is null;
    raise exception 'v64 guard: sv_pauses accepted an identity UPDATE'; exception when restrict_violation then null; end;
  begin delete from public.sv_pauses where business_id = v_business and scope = 'earn' and lifted_at is null;
    raise exception 'v64 guard: sv_pauses accepted a DELETE'; exception when restrict_violation then null; end;
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  perform public.sv_lift_pause(v_business, 'stored_value', 'earn', 'v64 guard lift');
  reset role;
  begin update public.sv_pauses set lifted_at = now(), lifted_by = gen_random_uuid()
          where business_id = v_business and scope = 'earn' and lifted_at is not null;
    raise exception 'v64 guard: sv_pauses accepted a re-lift of an already-lifted row';
  exception when restrict_violation then null; end;

  -- ============================================================
  -- MATRIX (direct on app.sv_pause_active): earn->{all|earn}, redeem->{all|redeem}, all_only->{all}.
  -- Pause each scope in isolation and assert the three family verdicts.
  -- ============================================================
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  perform public.sv_pause(v_business, 'stored_value', 'earn', 'matrix earn');
  reset role;
  if app.sv_pause_active(v_business, 'stored_value', 'earn')   is not true  then raise exception 'v64 matrix: earn pause did not block earn'; end if;
  if app.sv_pause_active(v_business, 'stored_value', 'redeem') is not false then raise exception 'v64 matrix: earn pause wrongly blocked redeem'; end if;
  if app.sv_pause_active(v_business, 'stored_value', 'all_only') is not false then raise exception 'v64 matrix: earn pause wrongly blocked all_only'; end if;
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  perform public.sv_lift_pause(v_business, 'stored_value', 'earn', 'matrix earn off');
  perform public.sv_pause(v_business, 'stored_value', 'redeem', 'matrix redeem');
  reset role;
  if app.sv_pause_active(v_business, 'stored_value', 'earn')   is not false then raise exception 'v64 matrix: redeem pause wrongly blocked earn'; end if;
  if app.sv_pause_active(v_business, 'stored_value', 'redeem') is not true  then raise exception 'v64 matrix: redeem pause did not block redeem'; end if;
  if app.sv_pause_active(v_business, 'stored_value', 'all_only') is not false then raise exception 'v64 matrix: redeem pause wrongly blocked all_only'; end if;
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  perform public.sv_lift_pause(v_business, 'stored_value', 'redeem', 'matrix redeem off');
  perform public.sv_pause(v_business, 'stored_value', 'all', 'matrix all');
  reset role;
  if app.sv_pause_active(v_business, 'stored_value', 'earn')   is not true then raise exception 'v64 matrix: all pause did not block earn'; end if;
  if app.sv_pause_active(v_business, 'stored_value', 'redeem') is not true then raise exception 'v64 matrix: all pause did not block redeem'; end if;
  if app.sv_pause_active(v_business, 'stored_value', 'all_only') is not true then raise exception 'v64 matrix: all pause did not block all_only'; end if;
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  perform public.sv_lift_pause(v_business, 'stored_value', 'all', 'matrix all off');

  -- ============================================================
  -- OWNER-ONLY + CROSS-TENANT + ANON.
  -- ============================================================
  -- owner of A cannot pause business B (cross-tenant): 42501 before any write.
  begin perform public.sv_pause(v_business_b, 'stored_value', 'all', 'cross tenant');
    raise exception 'v64: owner A paused business B (cross-tenant)'; exception when sqlstate '42501' then null; end;

  reset role;
  v_gkey := gen_random_uuid();
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_gkey, 'authenticated', 'authenticated',
    'v64-fd-' || substr(v_gkey::text, 1, 8) || '@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, full_name, active) values (v_business, v_gkey, 'frontdesk', 'v64 fd', true);
  perform pg_temp.as_v64_principal(v_gkey, 'authenticated');
  begin perform public.sv_pause(v_business, 'stored_value', 'all', 'fd pause');
    raise exception 'v64: a frontdesk paused stored value'; exception when sqlstate '42501' then null; end;
  begin perform public.sv_lift_pause(v_business, 'stored_value', 'all', 'fd lift');
    raise exception 'v64: a frontdesk lifted a pause'; exception when sqlstate '42501' then null; end;
  perform pg_temp.as_v64_principal(null, 'anon');
  begin perform public.sv_pause(v_business, 'stored_value', 'all', 'anon pause');
    raise exception 'v64: anon paused stored value'; exception when insufficient_privilege then null; end;

  -- ============================================================
  -- NO IMPLICIT LIFT: publishing a loyalty config version leaves the sv pause active.
  -- ============================================================
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  perform public.sv_pause(v_business, 'stored_value', 'earn', 'v64 no-implicit-lift');
  v_draft := (public.create_loyalty_config_draft(v_business, null, 'v64-no-implicit-lift')::jsonb->>'version_id')::uuid;
  perform public.save_loyalty_config_draft(v_draft, jsonb_build_object(
    'active', true, 'kind', 'points', 'loyalty_model', 'classic',
    'earn_points_per_dollar', 1, 'redeem_points', 50, 'reward_credit_cents', 500, 'expiry_mode', 'none'), null);
  perform public.publish_loyalty_config(v_draft);
  reset role;
  if app.sv_pause_active(v_business, 'stored_value', 'earn') is not true then
    raise exception 'v64: publishing a loyalty config IMPLICITLY LIFTED the sv earn pause'; end if;
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  perform public.sv_lift_pause(v_business, 'stored_value', 'earn', 'v64 done implicit');

  -- ============================================================
  -- SHIM ON: force authority='live' for the redeem-family gates (see header).
  -- ============================================================
  perform pg_temp.v64_force_live(v_business, true);
  if (select state from public.sv_authority where business_id = v_business and asset = 'stored_value') <> 'live' then
    raise exception 'v64 shim: authority was not forced to live'; end if;

  -- Fund an account for the spend tests (earn is not paused here).
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  v_res := public.sv_topup(v_business, v_c_spend, v_pv, gen_random_uuid());   -- 1000/137 => available 1137
  v_acct := (v_res->>'account_id')::uuid;

  -- ---- OWNER 10: a redeem pause blocks sv_spend + sv_reserve. ----
  perform public.sv_pause(v_business, 'stored_value', 'redeem', 'v64-10 redeem pause');
  begin perform public.sv_spend(v_business, v_acct, 500, gen_random_uuid());
    raise exception 'v64-10: sv_spend ran under a redeem pause';
  exception when sqlstate '22023' then
    if position('sv_paused' in sqlerrm) = 0 then raise exception 'v64-10: spend wrong 22023 (%)', sqlerrm; end if; end;
  begin perform public.sv_reserve(v_business, v_acct, 500, gen_random_uuid());
    raise exception 'v64-10: sv_reserve ran under a redeem pause';
  exception when sqlstate '22023' then
    if position('sv_paused' in sqlerrm) = 0 then raise exception 'v64-10: reserve wrong 22023 (%)', sqlerrm; end if; end;
  perform public.sv_lift_pause(v_business, 'stored_value', 'redeem', 'v64-10 redeem off');

  -- ---- OWNER 10 (pinned policy): an EARN pause does NOT block spend. ----
  perform public.sv_pause(v_business, 'stored_value', 'earn', 'v64-10 earn pause');
  v_res := public.sv_spend(v_business, v_acct, 500, gen_random_uuid());
  if (v_res->>'status') <> 'ok' then raise exception 'v64-10 PINNED: an earn pause blocked spend (contract §8 violated)'; end if;
  reset role;
  if app.sv_available_balance(v_business, v_acct) <> 637 then raise exception 'v64-10: spend under earn pause did not draw (%)', app.sv_available_balance(v_business, v_acct); end if;
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  perform public.sv_lift_pause(v_business, 'stored_value', 'earn', 'v64-10 earn off');

  -- ---- OWNER 11: lifting one scope restores ONLY that family. ----
  perform public.sv_pause(v_business, 'stored_value', 'earn', 'v64-11 earn');
  perform public.sv_pause(v_business, 'stored_value', 'redeem', 'v64-11 redeem');
  begin perform public.sv_topup(v_business, v_c_spend, v_pv, gen_random_uuid());
    raise exception 'v64-11: topup ran while earn was paused';
  exception when sqlstate '22023' then
    if position('sv_paused' in sqlerrm) = 0 then raise exception 'v64-11: topup wrong 22023 (%)', sqlerrm; end if; end;
  begin perform public.sv_spend(v_business, v_acct, 100, gen_random_uuid());
    raise exception 'v64-11: spend ran while redeem was paused';
  exception when sqlstate '22023' then
    if position('sv_paused' in sqlerrm) = 0 then raise exception 'v64-11: spend wrong 22023 (%)', sqlerrm; end if; end;
  perform public.sv_lift_pause(v_business, 'stored_value', 'earn', 'v64-11 lift earn');
  v_res := public.sv_topup(v_business, v_c_spend, v_pv, gen_random_uuid());
  if (v_res->>'status') <> 'ok' then raise exception 'v64-11: lifting earn did not restore topup'; end if;
  begin perform public.sv_spend(v_business, v_acct, 100, gen_random_uuid());
    raise exception 'v64-11: spend ran after only earn was lifted (redeem still paused)';
  exception when sqlstate '22023' then
    if position('sv_paused' in sqlerrm) = 0 then raise exception 'v64-11: spend wrong 22023 (%)', sqlerrm; end if; end;
  perform public.sv_lift_pause(v_business, 'stored_value', 'redeem', 'v64-11 lift redeem');

  -- ---- MATRIX end-to-end: refund blocked by earn (not redeem); reverse blocked by redeem (not earn). ----
  -- refund target op.
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  v_res := public.sv_topup(v_business, v_c_refund, v_pv, gen_random_uuid());
  v_op := (v_res->>'operation_id')::uuid;
  perform public.sv_pause(v_business, 'stored_value', 'earn', 'v64 refund earn');
  begin perform public.refund_sv_operation(v_business, v_op, null, gen_random_uuid());
    raise exception 'v64 matrix: refund ran under an earn pause';
  exception when sqlstate '22023' then
    if position('sv_paused' in sqlerrm) = 0 then raise exception 'v64 matrix: refund wrong 22023 (%)', sqlerrm; end if; end;
  perform public.sv_lift_pause(v_business, 'stored_value', 'earn', 'v64 refund earn off');
  perform public.sv_pause(v_business, 'stored_value', 'redeem', 'v64 refund redeem');
  v_res := public.refund_sv_operation(v_business, v_op, null, gen_random_uuid());   -- redeem pause does NOT block a refund
  if (v_res->>'status') <> 'ok' then raise exception 'v64 matrix: a redeem pause wrongly blocked a refund'; end if;
  perform public.sv_lift_pause(v_business, 'stored_value', 'redeem', 'v64 refund redeem off');

  -- reverse target: a spend op.
  v_res := public.sv_topup(v_business, v_c_rev, v_pv, gen_random_uuid());
  v_acct := (v_res->>'account_id')::uuid;
  v_res := public.sv_spend(v_business, v_acct, 300, gen_random_uuid());
  v_spend_op := (v_res->>'operation_id')::uuid;
  perform public.sv_pause(v_business, 'stored_value', 'redeem', 'v64 reverse redeem');
  begin perform public.sv_reverse_spend(v_business, v_spend_op, gen_random_uuid());
    raise exception 'v64 matrix: reverse ran under a redeem pause';
  exception when sqlstate '22023' then
    if position('sv_paused' in sqlerrm) = 0 then raise exception 'v64 matrix: reverse wrong 22023 (%)', sqlerrm; end if; end;
  perform public.sv_lift_pause(v_business, 'stored_value', 'redeem', 'v64 reverse redeem off');
  perform public.sv_pause(v_business, 'stored_value', 'earn', 'v64 reverse earn');
  v_res := public.sv_reverse_spend(v_business, v_spend_op, gen_random_uuid());   -- earn pause does NOT block a reverse
  if (v_res->>'status') <> 'ok' then raise exception 'v64 matrix: an earn pause wrongly blocked a reverse'; end if;
  perform public.sv_lift_pause(v_business, 'stored_value', 'earn', 'v64 reverse earn off');

  -- ---- MATRIX end-to-end: expire blocked by 'all' ONLY (never earn/redeem). ----
  reset role;
  v_seed := pg_temp.v64_seed(v_business, v_c_exp, 1000, now() - interval '1 day');   -- past-expiry paid lot
  v_acct := (v_seed->>'account')::uuid;
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  perform public.sv_pause(v_business, 'stored_value', 'all', 'v64 expire all');
  begin perform public.sv_expire_due(v_business, 100);
    raise exception 'v64 matrix: expire ran under an all pause';
  exception when sqlstate '22023' then
    if position('sv_paused' in sqlerrm) = 0 then raise exception 'v64 matrix: expire wrong 22023 (%)', sqlerrm; end if; end;
  perform public.sv_lift_pause(v_business, 'stored_value', 'all', 'v64 expire all off');
  -- an earn pause does NOT block the expiry sweep.
  perform public.sv_pause(v_business, 'stored_value', 'earn', 'v64 expire earn');
  v_res := public.sv_expire_due(v_business, 100);
  if (v_res->>'expired_cents')::int <> 1000 then raise exception 'v64 matrix: earn pause wrongly blocked expiry (swept %)', v_res->>'expired_cents'; end if;
  perform public.sv_lift_pause(v_business, 'stored_value', 'earn', 'v64 expire earn off');

  -- ============================================================
  -- SHIM OFF (defensive; the outer ROLLBACK discards it regardless). The UI reads below run at the
  -- REAL PS-2A ship state (unbuilt) so spendable is asserted FALSE - the truthful posture.
  -- ============================================================
  perform pg_temp.v64_force_live(v_business, false);

  -- ============================================================
  -- UI READ (at unbuilt): get_sv_authority_overview (spendable FALSE, can_cutover FALSE,
  -- active_pauses surfaced) + preview_sv_cutover (ready FALSE, real blockers). Owner context.
  -- ============================================================
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  perform public.sv_pause(v_business, 'stored_value', 'redeem', 'v64 overview surface');
  v_res := public.get_sv_authority_overview(v_business);
  if (v_res->>'can_cutover')::boolean is not false then raise exception 'v64 overview: can_cutover is not false'; end if;
  if (v_res->>'authority_state') <> 'unbuilt' then raise exception 'v64 overview: authority_state is not the ship-default unbuilt (%)', v_res->>'authority_state'; end if;
  if (v_res->>'spendable')::boolean is not false then raise exception 'v64 overview: spendable must be FALSE while authority is not live'; end if;
  if jsonb_array_length(v_res->'active_pauses') < 1 then raise exception 'v64 overview: active_pauses did not surface the redeem pause'; end if;
  if not (v_res->'active_pauses' @> jsonb_build_array(jsonb_build_object('scope', 'redeem'))) then
    raise exception 'v64 overview: active_pauses missing the redeem scope'; end if;

  v_res := public.preview_sv_cutover(v_business);
  if (v_res->>'ready')::boolean is not false then raise exception 'v64 preview: ready is not false'; end if;
  if jsonb_array_length(v_res->'blocking_reasons') < 1 then raise exception 'v64 preview: no blocking reasons'; end if;
  if position('future authorized phase' in (v_res->'blocking_reasons')::text) = 0 then
    raise exception 'v64 preview: missing the standing "future authorized phase" blocker'; end if;
  if position('unbuilt' in (v_res->'blocking_reasons')::text) = 0 then
    raise exception 'v64 preview: missing the "authority is unbuilt" blocker'; end if;
  perform public.sv_lift_pause(v_business, 'stored_value', 'redeem', 'v64 overview off');

  -- non-owner cannot read the overview / preview (42501).
  perform pg_temp.as_v64_principal(v_gkey, 'authenticated');   -- frontdesk (not owner, not sa)
  begin perform public.preview_sv_cutover(v_business);
    raise exception 'v64: a frontdesk previewed cutover'; exception when sqlstate '42501' then null; end;

  -- ============================================================
  -- REGRESSION: v62 reconciliation still runs; sv touched no points/credit/gift_cards.
  -- ============================================================
  perform pg_temp.as_v64_principal(v_owner, 'authenticated');
  v_res := public.run_sv_reconciliation(v_business);
  if (v_res->>'reconciliation_status') is null then raise exception 'v64: run_sv_reconciliation returned no status'; end if;
  reset role;
  if (select count(*) from public.points_ledger) <> v_pl_before
     or (select count(*) from public.credit_ledger) <> v_cl_before
     or (select count(*) from public.gift_cards) <> v_gc_before then
    raise exception 'v64: an sv pause/value operation wrote to points_ledger/credit_ledger/gift_cards'; end if;

  -- ============================================================
  -- CHECKOUT KERNEL + PS-1C.2 rule emergency pause: BYTE-untouched surfaces still present.
  -- ============================================================
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'record_cart_sale' and p.pronargs = 9) then
    raise exception 'v64: the kernel finaliser record_cart_sale/9 vanished'; end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'app' and p.proname = 'ps1c_plan_checkout') then
    raise exception 'v64: app.ps1c_plan_checkout vanished'; end if;
  if app.ps1c2_effect_state(v_business, 'apply_discount_amount') <> 'live' then
    raise exception 'v64: the checkout rule-execution axis is no longer live'; end if;
  if to_regclass('public.studio_rule_emergency_pauses') is null then
    raise exception 'v64: the PS-1C.2 rule emergency-pause table vanished'; end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'emergency_pause_studio_rule') then
    raise exception 'v64: emergency_pause_studio_rule vanished'; end if;

  -- ============================================================
  -- HOUSE: sv_pauses RLS + zero browser DML + no mutable balance column.
  -- ============================================================
  if has_table_privilege('anon', 'public.sv_pauses', 'select') then raise exception 'v64: anon retains SELECT on sv_pauses'; end if;
  if has_table_privilege('anon', 'public.sv_pauses', 'insert') or has_table_privilege('authenticated', 'public.sv_pauses', 'insert')
     or has_table_privilege('authenticated', 'public.sv_pauses', 'update') or has_table_privilege('authenticated', 'public.sv_pauses', 'delete') then
    raise exception 'v64: a browser role retains a direct write on sv_pauses'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.sv_pauses'::regclass) then
    raise exception 'v64: RLS is not enabled on sv_pauses'; end if;
  if (select count(*) from pg_policies where schemaname = 'public' and tablename = 'sv_pauses') < 2 then
    raise exception 'v64: sv_pauses is missing its owner/sa read policies'; end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sv_pauses'
              and column_name in ('balance', 'balance_cents')) then
    raise exception 'v64: sv_pauses carries a mutable balance column'; end if;

  -- Every new v64 function is SECURITY DEFINER, pins search_path, revoked from anon (helpers also
  -- from authenticated; the four browser RPCs are granted to authenticated).
  for v_oid in
    select p.oid from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where (ns.nspname, p.proname) in (
       ('app', 'sv_pauses_guard'), ('app', 'sv_pause_active'),
       ('public', 'sv_pause'), ('public', 'sv_lift_pause'),
       ('public', 'get_sv_authority_overview'), ('public', 'preview_sv_cutover'))
  loop
    if not (select prosecdef from pg_proc where oid = v_oid) then raise exception 'v64: an sv function is not SECURITY DEFINER'; end if;
    if not exists (select 1 from pg_proc where oid = v_oid and array_to_string(coalesce(proconfig, '{}'), ',') like '%search_path=%') then
      raise exception 'v64: an sv function does not pin search_path'; end if;
    if has_function_privilege('anon', v_oid, 'execute') then raise exception 'v64: anon retains EXECUTE on an sv function'; end if;
  end loop;
  foreach t in array array['app.sv_pauses_guard()', 'app.sv_pause_active(uuid,text,text)'] loop
    if has_function_privilege('authenticated', t, 'execute') then raise exception 'v64: authenticated retains EXECUTE on helper %', t; end if;
  end loop;
  if not has_function_privilege('authenticated', 'public.sv_pause(uuid,text,text,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.sv_lift_pause(uuid,text,text,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.get_sv_authority_overview(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.preview_sv_cutover(uuid)', 'execute') then
    raise exception 'v64: a browser sv control/read RPC is not granted to authenticated'; end if;

  reset role;
  raise notice 'v64 PS-2A Increment D pause-controls + cutover-preview suite: ALL PASS';
end $v64_test$;

reset role;
rollback;
