-- Rollback-only v68a stored-value CHARGEBACK / BAD DEBT / CORRECTION / REFUND-CAP suite.
-- Run after the pending chain (through v68a) in a disposable rehearsal database.
--
-- Oracle: docs/design/ps0/STORED_VALUE_CONTRACT.md - §4 (refund model), §5 (the seven rounding
-- requirements), §6 (expiry independence, restore-then-expire, chargeback + bad debt, corrections),
-- §9 (frozen cents vectors + lettered cases), §10 (invariants). Every number below is asserted
-- CENTS-EXACT against that document; nothing is re-derived here.
--
-- What this proves (contract docs/design/ps2/PS2_LIVE_V68A_CHARGEBACK_CORRECTION_CONTRACT.md §8):
--   * CATALOG TRUTH: 'correction' and 'bad_debt' had NO writer before v68a, and the pre-v68a
--     movement writers still write neither.
--   * PS-0 case (e): $100 paid + $12 bonus, $80 spend -> void paid 2857 + bonus 343, bad debt 7143 -
--     through the PURE planner AND through the gated RPC; movements still sum to derived remaining.
--   * PS-0 case (f): the exact bonus trail issue +1200, spend -128, expiry -1072, reversal +128,
--     expiry -128 -> 0, plus expiry independence (a bonus expiry never touches a paid lot).
--   * Prior-refund-then-chargeback (§3 pinned default): void only what remains, report
--     cash_already_refunded_cents separately, net nothing.
--   * Correction: reason mandatory, both directions, over-void / over-mint / expired-lot /
--     charged-back refusals, single-lot scope, not a mint.
--   * Cash-refund cap: typed refusal AND the structural table CHECK; unused_only + no_refund plan
--     variants on and off; no-arbitrage adversarial case (PS-0 §7 case (b) cents).
--   * Envelope: idempotent replay (zero new movements) + changed-request same-key typed conflict.
--   * Gate matrices: authority, pause family mapping, synthetic-on-live, owner-only, anon.
--   * Per-write-step atomic rollback injection: zero partial records at every write table.
--   * The v67 §11a/§11b reversal refusals STILL REFUSE (v68a must not weaken them), and an
--     SV-tendered sale already delivered STANDS through a chargeback of its funding top-up.
--   * v66 mint tripwire green; sv_total_outstanding + reservation invariants intact.
--
-- THE authority='live' SHIM: the v61 sv_authority guard rejects any transition into 'live'. Inside
-- THIS rolled-back transaction ONLY the guard trigger is transiently disabled, the tenant forced to
-- 'live', the guard re-enabled, the RPCs run, and the outer ROLLBACK discards everything. 'live' is
-- NEVER written by a migration and NEVER persisted.
-- The including transaction owns BEGIN/ROLLBACK; nothing commits.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v68a(p_uid uuid, p_role text) returns void language plpgsql as $$
begin
  execute 'reset role'; perform set_config('request.jwt.claim.sub','',true); perform set_config('request.jwt.claims','',true);
  if p_role='anon' then execute 'set local role anon'; perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  else execute 'set local role authenticated'; perform set_config('request.jwt.claim.sub', p_uid::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub',p_uid,'role','authenticated')::text, true); end if;
end $$;
grant execute on function pg_temp.as_v68a(uuid,text) to authenticated, anon;

create or replace function pg_temp.v68a_boom() returns trigger language plpgsql as $$
begin raise exception 'INJECTED failure' using errcode='XX000'; end $$;

create or replace function pg_temp.v68a_force_state(p_business uuid, p_state text) returns void language plpgsql as $$
begin
  execute 'reset role';
  alter table public.sv_authority disable trigger sv_authority_guard;
  update public.sv_authority set state=p_state where business_id=p_business and asset='stored_value';
  alter table public.sv_authority enable trigger sv_authority_guard;
end $$;
grant execute on function pg_temp.v68a_force_state(uuid,text) to authenticated, anon;

-- publish one plan (its own sv_plans row, so the published version is that plan's current sellable)
create or replace function pg_temp.v68a_plan(p_business uuid, p_cfg jsonb) returns uuid language plpgsql as $$
declare d uuid;
begin
  d := (public.create_sv_plan_draft(p_business, p_cfg, gen_random_uuid())->>'draft_id')::uuid;
  return (public.publish_sv_plan_version(p_business, d, 0, gen_random_uuid(), null)->>'version_id')::uuid;
end $$;
grant execute on function pg_temp.v68a_plan(uuid,jsonb) to authenticated;

-- Seed lots with EXPLICIT expiry keys (the mint path can only set future expiry), mirroring the v63
-- fixture helper. Used for the expiry matrix only. No payment evidence row by design.
create or replace function pg_temp.v68a_seed(
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

-- definer shims so an impersonated (browser-role) session can still read the revoked app.* helpers
create or replace function pg_temp.v68a_bal(p_business uuid, p_account uuid) returns jsonb
  language sql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select jsonb_build_object('outstanding', app.sv_total_outstanding(p_business,p_account),
                            'available', app.sv_available_balance(p_business,p_account)) $$;
grant execute on function pg_temp.v68a_bal(uuid,uuid) to authenticated;
create or replace function pg_temp.v68a_cbplan(p_business uuid, p_op uuid) returns jsonb
  language sql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select app.sv_chargeback_plan(p_business, p_op) $$;
grant execute on function pg_temp.v68a_cbplan(uuid,uuid) to authenticated;
create or replace function pg_temp.v68a_rem(p_lot uuid) returns integer
  language sql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select app.sv_lot_remaining(p_lot) $$;
grant execute on function pg_temp.v68a_rem(uuid) to authenticated;

-- ============================================================================================
-- STATIC CATALOG TRUTH (no fixture needed): hardening, ACLs, and the "no prior writer" claim.
-- ============================================================================================
do $v68a_catalog$
declare v_names text;
begin
  reset role;

  -- every v68a function is SECURITY DEFINER with a pinned search_path
  assert not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where p.proname in ('sv_chargeback_topup','sv_correct_lot','sv_chargeback_plan','sv_cash_collected_cents',
                         'sv_cash_refunded_cents','sv_operation_net_spent','sv_operation_refund_policy')
       and (not p.prosecdef or array_to_string(coalesce(p.proconfig,'{}'),',') not ilike '%search_path%')),
    'a v68a function is not SECURITY DEFINER or lacks a pinned search_path';

  -- browser roles cannot execute the internal app.* helpers
  assert not has_function_privilege('authenticated','app.sv_chargeback_plan(uuid,uuid)','execute'), 'sv_chargeback_plan exec leaked';
  assert not has_function_privilege('authenticated','app.sv_cash_collected_cents(uuid,uuid)','execute'), 'sv_cash_collected_cents exec leaked';
  assert not has_function_privilege('authenticated','app.sv_cash_refunded_cents(uuid,uuid)','execute'), 'sv_cash_refunded_cents exec leaked';
  assert not has_function_privilege('authenticated','app.sv_operation_net_spent(uuid,uuid)','execute'), 'sv_operation_net_spent exec leaked';
  assert not has_function_privilege('authenticated','app.sv_operation_refund_policy(uuid,uuid)','execute'), 'sv_operation_refund_policy exec leaked';
  -- the two new owner RPCs are granted to authenticated and closed to anon
  assert has_function_privilege('authenticated','public.sv_chargeback_topup(uuid,uuid,text,uuid)','execute'), 'sv_chargeback_topup must be callable by authenticated';
  assert has_function_privilege('authenticated','public.sv_correct_lot(uuid,uuid,integer,text,uuid)','execute'), 'sv_correct_lot must be callable by authenticated';
  assert not has_function_privilege('anon','public.sv_chargeback_topup(uuid,uuid,text,uuid)','execute'), 'sv_chargeback_topup leaked to anon';
  assert not has_function_privilege('anon','public.sv_correct_lot(uuid,uuid,integer,text,uuid)','execute'), 'sv_correct_lot leaked to anon';
  assert not has_function_privilege('anon','public.refund_sv_operation(uuid,uuid,integer,uuid)','execute'), 'refund_sv_operation leaked to anon';
  assert has_function_privilege('authenticated','public.refund_sv_operation(uuid,uuid,integer,uuid)','execute'),
    'refund_sv_operation lost the owner-RPC grant it has held since v63';

  -- new tables: RLS on, browser DML revoked, SELECT granted
  assert (select relrowsecurity from pg_class where oid='public.sv_chargebacks'::regclass), 'sv_chargebacks RLS off';
  assert (select relrowsecurity from pg_class where oid='public.sv_topup_cash_refunds'::regclass), 'sv_topup_cash_refunds RLS off';
  assert not has_table_privilege('authenticated','public.sv_chargebacks','insert')
     and not has_table_privilege('authenticated','public.sv_chargebacks','update')
     and not has_table_privilege('authenticated','public.sv_chargebacks','delete'), 'sv_chargebacks browser DML leaked';
  assert not has_table_privilege('authenticated','public.sv_topup_cash_refunds','insert')
     and not has_table_privilege('authenticated','public.sv_topup_cash_refunds','update')
     and not has_table_privilege('authenticated','public.sv_topup_cash_refunds','delete'), 'sv_topup_cash_refunds browser DML leaked';
  assert has_table_privilege('authenticated','public.sv_chargebacks','select'), 'sv_chargebacks owner read missing';
  assert not has_table_privilege('anon','public.sv_chargebacks','select'), 'sv_chargebacks leaked to anon';
  assert not has_table_privilege('anon','public.sv_topup_cash_refunds','select'), 'sv_topup_cash_refunds leaked to anon';

  -- the operation_type vocabulary widened, and only by the two intended values
  assert (select pg_get_constraintdef(c.oid) like '%chargeback%'
            from pg_constraint c where c.conrelid='public.sv_operations'::regclass and c.contype='c'
             and pg_get_constraintdef(c.oid) like '%operation_type%'), 'sv_operations does not accept chargeback ops';
  assert (select pg_get_constraintdef(c.oid) like '%correction%'
            from pg_constraint c where c.conrelid='public.sv_operations'::regclass and c.contype='c'
             and pg_get_constraintdef(c.oid) like '%operation_type%'), 'sv_operations does not accept correction ops';

  -- CATALOG TRUTH: v68a is the FIRST writer of 'correction'/'bad_debt'. Every pre-v68a function that
  -- writes sv_lot_movements still writes neither kind.
  select string_agg(p.proname, ', ' order by p.proname) into v_names
    from pg_proc p
   where p.proname in ('sv_spend_core','record_sv_topup_sale','refund_sv_operation','sv_expire_due','sv_reverse_spend')
     and (p.prosrc ~ '''correction''' or p.prosrc ~ '''bad_debt''');
  assert v_names is null, 'a pre-v68a movement writer now writes correction/bad_debt: '||coalesce(v_names,'');
  -- ...and NO function outside the v68a chargeback pair carries the 'bad_debt' literal at all
  select string_agg(n.nspname||'.'||p.proname, ', ' order by n.nspname||'.'||p.proname) into v_names
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname in ('public','app') and p.prosrc ~ '''bad_debt'''
     and p.proname not in ('sv_chargeback_plan','sv_chargeback_topup');
  assert v_names is null, 'unexpected bad_debt writers: '||coalesce(v_names,'');
  assert (select p.prosrc ~ '''bad_debt''' from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='app' and p.proname='sv_chargeback_plan'),
    'v68a must be the first writer of the bad_debt movement kind';
  -- ...and likewise for 'correction' outside the v68a chargeback/correction trio
  select string_agg(n.nspname||'.'||p.proname, ', ' order by n.nspname||'.'||p.proname) into v_names
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname in ('public','app') and p.prosrc ~ '''correction'''
     and p.proname not in ('sv_chargeback_plan','sv_chargeback_topup','sv_correct_lot');
  assert v_names is null, 'unexpected correction writers: '||coalesce(v_names,'');

  -- v67 refusals present and unweakened
  assert position('sv_tendered_sale_unsupported' in
    pg_get_functiondef('public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)'::regprocedure)) > 0,
    'the v67 §11a sale-leg refusal is gone';
  assert position('sv_tendered_spend_unsupported' in
    pg_get_functiondef('public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure)) > 0,
    'the v67 §11b settlement-leg refusal is gone';

  -- v66 mint tripwire: still exactly one paid-lot minter in the shipped schemas (this suite's own
  -- rolled-back pg_temp seeding helper is deliberately outside the scope, as it is in v63's).
  select string_agg(n.nspname||'.'||p.proname, ', ' order by n.nspname||'.'||p.proname) into v_names
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname in ('public','app')
     and p.prosrc ilike '%insert into public.sv_lots%' and p.prosrc ilike '%''paid''%'
     and p.proname <> 'record_sv_topup_sale';
  assert v_names is null, 'a non-authoritative function can mint a paid lot: '||coalesce(v_names,'');
end $v68a_catalog$;

-- ============================================================================================
-- BEHAVIOUR
-- ============================================================================================
do $v68a$
declare
  B uuid; B_owner uuid; B_branch uuid; A uuid; A_owner uuid;
  ver_e uuid; ver_f uuid; ver_arb uuid; ver_cap uuid; ver_unused uuid; ver_norefund uuid; ver_gate uuid;
  cli_e uuid; cli_del uuid; cli_pr uuid; cli_arb uuid; cli_cap uuid; cli_un1 uuid; cli_un2 uuid;
  cli_nr uuid; cli_corr uuid; cli_exp uuid; cli_gate uuid; cli_atom uuid; cli_syn uuid;
  svc5000 uuid; lines5000 jsonb;
  topup jsonb; op_e uuid; op_del uuid; op_pr uuid; op_arb uuid; op_cap uuid; op_un1 uuid; op_un2 uuid;
  op_nr uuid; op_corr uuid; op_gate uuid; op_atom uuid; op_syn uuid; syn_lot uuid;
  acct uuid; acct_e uuid; acct_corr uuid; acct_exp uuid; acct_atom uuid;
  paid_lot uuid; bonus_lot uuid; corr_paid uuid; corr_bonus uuid;
  spend jsonb; spend_op uuid; plan jsonb; cb jsonb; cb2 jsonb; ref jsonb; corr jsonb;
  seed jsonb; k uuid; trail text; tbl text; cnt jsonb; cnt0 jsonb;
  ev jsonb; tok uuid; res json; sale_sv uuid; sb record; settle_spend uuid;
  n int; m int; frontdesk uuid; injected boolean;
begin
  reset role;
  select s.business_id, s.user_id into A, A_owner from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture A' order by s.created_at limit 1;
  select s.business_id, s.user_id into B, B_owner from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture B' order by s.created_at limit 1;
  select id into B_branch from public.branches where business_id=B and active order by is_default desc nulls last, created_at limit 1;

  insert into public.clients(business_id,full_name,phone) values
    (B,'v68a e','+6590000801'),(B,'v68a delivered','+6590000802'),(B,'v68a priorrefund','+6590000803'),
    (B,'v68a arb','+6590000804'),(B,'v68a cap','+6590000805'),(B,'v68a un1','+6590000806'),
    (B,'v68a un2','+6590000807'),(B,'v68a nr','+6590000808'),(B,'v68a corr','+6590000809'),
    (B,'v68a exp','+6590000810'),(B,'v68a gate','+6590000811'),(B,'v68a atom','+6590000812'),
    (B,'v68a syn','+6590000813');
  insert into public.services(business_id,name,price_cents,duration_min) values (B,'v68a s5000',5000,30);
  select id into svc5000 from public.services where business_id=B and name='v68a s5000';
  lines5000 := jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',svc5000,'qty',1));
  select id into cli_e    from public.clients where business_id=B and full_name='v68a e';
  select id into cli_del  from public.clients where business_id=B and full_name='v68a delivered';
  select id into cli_pr   from public.clients where business_id=B and full_name='v68a priorrefund';
  select id into cli_arb  from public.clients where business_id=B and full_name='v68a arb';
  select id into cli_cap  from public.clients where business_id=B and full_name='v68a cap';
  select id into cli_un1  from public.clients where business_id=B and full_name='v68a un1';
  select id into cli_un2  from public.clients where business_id=B and full_name='v68a un2';
  select id into cli_nr   from public.clients where business_id=B and full_name='v68a nr';
  select id into cli_corr from public.clients where business_id=B and full_name='v68a corr';
  select id into cli_exp  from public.clients where business_id=B and full_name='v68a exp';
  select id into cli_gate from public.clients where business_id=B and full_name='v68a gate';
  select id into cli_atom from public.clients where business_id=B and full_name='v68a atom';
  select id into cli_syn  from public.clients where business_id=B and full_name='v68a syn';

  ---------------------------------------------------------------- AUTHORITY MATRIX (before forcing live)
  perform pg_temp.as_v68a(B_owner,'authenticated');
  begin perform public.sv_chargeback_topup(B, gen_random_uuid(), 'unbuilt probe', gen_random_uuid());
    raise exception 'chargeback ran while authority is unbuilt' using errcode='XX000';
  exception when others then
    assert sqlstate='22023', 'unbuilt chargeback must be 22023, got '||sqlstate;
    assert position('sv_not_live' in sqlerrm)=1, 'unbuilt chargeback must be typed sv_not_live, got: '||sqlerrm; end;
  begin perform public.sv_correct_lot(B, gen_random_uuid(), 100, 'unbuilt probe', gen_random_uuid());
    raise exception 'correction ran while authority is unbuilt' using errcode='XX000';
  exception when others then
    assert sqlstate='22023', 'unbuilt correction must be 22023, got '||sqlstate;
    assert position('sv_not_live' in sqlerrm)=1, 'unbuilt correction must be typed sv_not_live'; end;

  reset role; perform pg_temp.v68a_force_state(B,'live'); perform pg_temp.as_v68a(B_owner,'authenticated');
  ver_e        := pg_temp.v68a_plan(B, jsonb_build_object('customer_facing_name','v68a e','price_cents',10000,'bonus_cents',1200,'customer_terms','1y'));
  ver_f        := pg_temp.v68a_plan(B, jsonb_build_object('customer_facing_name','v68a f','price_cents',10000,'bonus_cents',1200,'customer_terms','1y'));
  ver_arb      := pg_temp.v68a_plan(B, jsonb_build_object('customer_facing_name','v68a arb','price_cents',10000,'bonus_cents',1200,'customer_terms','1y'));
  ver_cap      := pg_temp.v68a_plan(B, jsonb_build_object('customer_facing_name','v68a cap','price_cents',10000,'bonus_cents',0,'customer_terms','1y'));
  ver_unused   := pg_temp.v68a_plan(B, jsonb_build_object('customer_facing_name','v68a unused','price_cents',5000,'bonus_cents',500,'refund_policy','unused_only','customer_terms','1y'));
  ver_norefund := pg_temp.v68a_plan(B, jsonb_build_object('customer_facing_name','v68a norefund','price_cents',4000,'bonus_cents',0,'refund_policy','no_refund','customer_terms','1y'));
  ver_gate     := pg_temp.v68a_plan(B, jsonb_build_object('customer_facing_name','v68a gate','price_cents',5000,'bonus_cents',500,'customer_terms','1y'));

  ---------------------------------------------------------------- PS-0 CASE (e): $100 + $12 bonus, $80 spend
  topup := public.record_sv_topup_sale(B,B_branch,cli_e,ver_e,jsonb_build_object('method','cash','amount_cents',10000,'currency','SGD'),gen_random_uuid());
  op_e := (topup->>'operation_id')::uuid; acct_e := (topup->>'account_id')::uuid;
  paid_lot := (topup->'paid_lot'->>'lot_id')::uuid; bonus_lot := (topup->'bonus_lot'->>'lot_id')::uuid;
  assert (pg_temp.v68a_bal(B,acct_e)->>'outstanding')::int = 11200, 'case (e) mint must be 11200 usable';

  spend := public.sv_spend(B, acct_e, 8000, gen_random_uuid());
  spend_op := (spend->>'operation_id')::uuid;
  -- PS-0 §3: bonus_draw = floor(8000*1200/11200) = 857; paid_draw = 7143.
  assert (spend->>'bonus_draw_cents')::int = 857, 'case (e) bonus_draw must be 857, got '||(spend->>'bonus_draw_cents');
  assert (spend->>'paid_draw_cents')::int = 7143, 'case (e) paid_draw must be 7143, got '||(spend->>'paid_draw_cents');
  assert pg_temp.v68a_rem(paid_lot) = 2857 and pg_temp.v68a_rem(bonus_lot) = 343, 'case (e) remaining must be paid 2857 / bonus 343';

  -- (1) the PURE planner reproduces the oracle with NO gate and NO DML
  plan := pg_temp.v68a_cbplan(B, op_e);
  assert (plan->>'ok')::boolean, 'chargeback planner failed: '||coalesce(plan->>'reason','');
  assert (plan->>'void_paid_cents')::int = 2857, 'PS-0 case (e) void paid must be 2857, got '||(plan->>'void_paid_cents');
  assert (plan->>'void_bonus_cents')::int = 343, 'PS-0 case (e) void bonus must be 343, got '||(plan->>'void_bonus_cents');
  assert (plan->>'bad_debt_cents')::int = 7143, 'PS-0 case (e) bad debt must be 7143, got '||(plan->>'bad_debt_cents');
  assert (plan->>'cash_already_refunded_cents')::int = 0, 'case (e) has no prior cash refund';
  select count(*) into n from public.sv_lot_movements where business_id=B and account_id=acct_e;

  -- (2) the gated RPC writes the same numbers
  k := gen_random_uuid();
  cb := public.sv_chargeback_topup(B, op_e, 'bank reversed the funding', k);
  assert (cb->>'status')='ok', 'chargeback did not return ok';
  assert (cb->>'void_paid_cents')::int = 2857 and (cb->>'void_bonus_cents')::int = 343
     and (cb->>'bad_debt_cents')::int = 7143, 'PS-0 case (e) RPC cents: '||cb::text;
  assert (cb->>'voided_total_cents')::int = 3200, 'case (e) voided total must be 2857+343';
  assert (cb->>'cash_collected_cents')::int = 10000 and (cb->>'cash_basis')='payment_evidence', 'case (e) collected cash evidence';
  assert (cb->>'cash_already_refunded_cents')::int = 0, 'case (e) cash_already_refunded must be 0';
  assert (cb->>'bad_debt_accounting_classification')='not_classified_owner_and_accountant_review_required',
    'the chargeback must classify nothing (⚖️ owner + accountant)';
  assert (cb->>'sales_delivered_stand')::boolean, 'delivered sales must be reported as standing';

  -- (3) both lots are voided to zero and movements still sum to derived remaining
  assert pg_temp.v68a_rem(paid_lot) = 0 and pg_temp.v68a_rem(bonus_lot) = 0, 'chargeback must void both lots to 0';
  assert (pg_temp.v68a_bal(B,acct_e)->>'outstanding')::int = 0, 'case (e) outstanding must be 0 after the chargeback';
  assert (select coalesce(sum(cents),0) from public.sv_lot_movements where lot_id=paid_lot) = pg_temp.v68a_rem(paid_lot),
    'PS-0 §10.1 broken on the paid lot after a chargeback';
  assert (select coalesce(sum(cents),0) from public.sv_lot_movements where lot_id=bonus_lot) = pg_temp.v68a_rem(bonus_lot),
    'PS-0 §10.1 broken on the bonus lot after a chargeback';
  -- the bad-debt record carries cents=0 so it can never double-subtract the already-voided value
  assert (select count(*) from public.sv_lot_movements where lot_id=paid_lot and kind='bad_debt') = 1,
    'exactly one bad_debt movement per chargeback, on the paid lot';
  assert (select cents from public.sv_lot_movements where lot_id=paid_lot and kind='bad_debt') = 0,
    'the bad_debt movement must carry cents=0 (PS-0 §2 footnote)';
  assert (select count(*) from public.sv_lot_movements where lot_id=bonus_lot and kind='bad_debt') = 0,
    'bad debt is recorded on the paid lot only';
  assert (select cents from public.sv_lot_movements where lot_id=paid_lot and kind='correction') = -2857, 'paid void movement must be -2857';
  assert (select cents from public.sv_lot_movements where lot_id=bonus_lot and kind='correction') = -343, 'bonus void movement must be -343';
  -- the loss figure lives on the record, not on the ledger cache
  assert (select bad_debt_cents from public.sv_chargebacks where business_id=B and topup_operation_id=op_e) = 7143,
    'sv_chargebacks.bad_debt_cents must carry the 7143 figure';
  assert (select count(*) from public.sv_topup_payment_events e join public.sv_topup_payments p on p.id=e.payment_id
           where p.operation_id=op_e and e.event_type='chargeback') = 1, 'one append-only chargeback payment event';
  -- the payment itself stays immutable (v66) - refused for the browser role by ACL, and refused for
  -- a privileged writer by the v61 immutability trigger
  begin update public.sv_topup_payments set amount_cents=1 where operation_id=op_e;
    raise exception 'the browser role mutated a top-up payment' using errcode='XX000';
  exception when others then assert sqlstate='42501','a browser payment UPDATE must be 42501, got '||sqlstate; end;
  reset role;
  begin update public.sv_topup_payments set amount_cents=1 where operation_id=op_e;
    raise exception 'the top-up payment was mutated' using errcode='XX000';
  exception when others then assert sqlstate='23001','sv_topup_payments must stay immutable, got '||sqlstate; end;
  perform pg_temp.as_v68a(B_owner,'authenticated');

  -- (4) idempotent replay: same key -> byte-equal result, ZERO new movements
  select count(*) into n from public.sv_lot_movements where business_id=B and account_id=acct_e;
  cb2 := public.sv_chargeback_topup(B, op_e, 'bank reversed the funding', k);
  assert cb2 = cb, 'a replayed chargeback must return the byte-equal cached result';
  assert (select count(*) from public.sv_lot_movements where business_id=B and account_id=acct_e) = n,
    'a replayed chargeback wrote new movements';
  -- changed request under the SAME key -> typed conflict
  begin perform public.sv_chargeback_topup(B, op_e, 'a different reason entirely', k);
    raise exception 'a changed chargeback request reused its key' using errcode='XX000';
  exception when others then
    assert sqlstate='22023','changed-request same-key must be 22023, got '||sqlstate;
    assert position('idempotency key conflicts' in sqlerrm) > 0, 'expected the typed idempotency conflict, got: '||sqlerrm; end;
  -- a SECOND chargeback of the same top-up under a NEW key is refused
  begin perform public.sv_chargeback_topup(B, op_e, 'second attempt', gen_random_uuid());
    raise exception 'a top-up was charged back twice' using errcode='XX000';
  exception when others then
    assert sqlstate='22023','double chargeback must be 22023, got '||sqlstate;
    assert position('sv_already_charged_back' in sqlerrm)=1, 'expected sv_already_charged_back, got: '||sqlerrm; end;
  -- and a refund of a charged-back top-up is typed-refused (this is what makes the race deterministic)
  begin perform public.refund_sv_operation(B, op_e, null, gen_random_uuid());
    raise exception 'a charged-back top-up was refunded' using errcode='XX000';
  exception when others then
    assert sqlstate='22023','refund-after-chargeback must be 22023, got '||sqlstate;
    assert position('sv_charged_back' in sqlerrm)=1, 'expected sv_charged_back, got: '||sqlerrm; end;

  ---------------------------------------------------------------- SALES ALREADY DELIVERED STAND
  -- Fund a customer, settle a real checkout with stored value (v67 tender), then charge back the
  -- FUNDING top-up. The sale must stay exactly as it was: no reversal, no goods clawed back, and the
  -- v67 §11a/§11b refusals must still refuse.
  topup := public.record_sv_topup_sale(B,B_branch,cli_del,ver_gate,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  op_del := (topup->>'operation_id')::uuid;
  ev := public.evaluate_checkout(B,B_branch,cli_del,lines5000,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  perform public.reserve_checkout_sv_tender(B,tok,5000,gen_random_uuid());
  res := public.record_cart_sale(B,cli_del,B_branch,null,'cash','v68a-del-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
  sale_sv := (res->>'sale_id')::uuid;
  select spend_operation_id into settle_spend from public.checkout_sv_tenders where business_id=B and sale_id=sale_sv;
  select balance_cents, paid_cents, sv_settled_cents, payment_status into sb from public.sale_balance where sale_id=sale_sv and business_id=B;
  assert sb.balance_cents=0 and sb.sv_settled_cents=5000 and sb.payment_status='paid', 'the sv-settled sale must start fully settled';
  select count(*) into n from public.sales where business_id=B;
  select count(*) into m from public.sale_reversal_audits where business_id=B;
  cb := public.sv_chargeback_topup(B, op_del, 'funding reversed after delivery', gen_random_uuid());
  -- PS-0 §3 proportional draw on 5000 paid + 500 bonus: bonus floor(5000*500/5500)=454, paid 4546,
  -- so the settled sale consumed 4546 of PAID value as goods and left paid 454 / bonus 46.
  assert (cb->>'bad_debt_cents')::int = 4546, 'delivered-goods bad debt must be the 4546 paid draw, got '||(cb->>'bad_debt_cents');
  assert (cb->>'void_paid_cents')::int = 454 and (cb->>'void_bonus_cents')::int = 46,
    'the chargeback must void exactly the unspent remainder (454 paid / 46 bonus), got '||cb::text;
  assert (select count(*) from public.sales where business_id=B) = n, 'the chargeback created or removed a sale';
  assert (select count(*) from public.sale_reversal_audits where business_id=B) = m, 'the chargeback reversed a sale';
  select balance_cents, paid_cents, sv_settled_cents, payment_status into sb from public.sale_balance where sale_id=sale_sv and business_id=B;
  assert sb.balance_cents=0 and sb.sv_settled_cents=5000 and sb.payment_status='paid', 'the delivered sale must STAND after a chargeback';
  -- v67 §11a still refuses the sale leg
  begin perform public.reverse_sale(B, sale_sv, 'v68a probe: sv-tendered sale', 'v68a-rev-'||substr(md5(clock_timestamp()::text),1,8));
    raise exception 'v68a weakened the §11a sale-leg refusal' using errcode='XX000';
  exception when others then
    assert sqlstate='P0001','§11a refusal must stay P0001, got '||sqlstate;
    assert position('sv_tendered_sale_unsupported:' in sqlerrm)=1, '§11a must stay typed, got: '||sqlerrm; end;
  -- v67 §11b still refuses the settlement leg
  begin perform public.sv_reverse_spend(B, settle_spend, gen_random_uuid());
    raise exception 'v68a weakened the §11b settlement-leg refusal' using errcode='XX000';
  exception when others then
    assert sqlstate='22023','§11b refusal must stay 22023, got '||sqlstate;
    assert position('sv_tendered_spend_unsupported:' in sqlerrm)=1, '§11b must stay typed, got: '||sqlerrm; end;

  ---------------------------------------------------------------- §3 PRIOR REFUND THEN CHARGEBACK (pinned default)
  topup := public.record_sv_topup_sale(B,B_branch,cli_pr,ver_e,jsonb_build_object('method','cash','amount_cents',10000,'currency','SGD'),gen_random_uuid());
  op_pr := (topup->>'operation_id')::uuid;
  paid_lot := (topup->'paid_lot'->>'lot_id')::uuid; bonus_lot := (topup->'bonus_lot'->>'lot_id')::uuid;
  -- PS-0 §4 partial: X=3000 of 10000 paid -> clawback = floor(1200*3000/10000) = 360 (non-final)
  ref := public.refund_sv_operation(B, op_pr, 3000, gen_random_uuid());
  assert (ref->>'cash_cents')::int = 3000 and (ref->>'clawback_cents')::int = 360 and not (ref->>'final')::boolean,
    'PS-0 §4 partial refund must be cash 3000 / clawback 360 / non-final, got '||ref::text;
  assert (ref->>'cash_refunded_cumulative_cents')::int = 3000, 'cumulative cash after the first partial must be 3000';
  assert pg_temp.v68a_rem(paid_lot) = 7000 and pg_temp.v68a_rem(bonus_lot) = 840, 'after the partial: paid 7000 / bonus 840';
  cb := public.sv_chargeback_topup(B, op_pr, 'funding reversed after a partial refund', gen_random_uuid());
  assert (cb->>'void_paid_cents')::int = 7000 and (cb->>'void_bonus_cents')::int = 840,
    'the chargeback must void ONLY what remains (7000 / 840), got '||cb::text;
  assert (cb->>'bad_debt_cents')::int = 0, 'nothing was delivered as goods, so bad debt must be 0';
  assert (cb->>'cash_already_refunded_cents')::int = 3000,
    'the double-loss figure must be surfaced as 3000, got '||(cb->>'cash_already_refunded_cents');
  -- and it is NOT netted into anything else
  assert (cb->>'voided_total_cents')::int = 7840, 'cash_already_refunded must not be netted into the void';
  assert (select cash_already_refunded_cents from public.sv_chargebacks where business_id=B and topup_operation_id=op_pr) = 3000,
    'sv_chargebacks must record the already-refunded cash separately';
  assert exists (select 1 from public.audit_log where business_id=B and action='SV_CHARGEBACK'
                  and (detail->>'cash_already_refunded_cents')::int = 3000),
    'audit_log must carry the already-refunded cash figure';
  assert pg_temp.v68a_rem(paid_lot) = 0 and pg_temp.v68a_rem(bonus_lot) = 0, 'the charged-back lots must be zero';

  ---------------------------------------------------------------- NO-ARBITRAGE (PS-0 §7 case (b) cents)
  topup := public.record_sv_topup_sale(B,B_branch,cli_arb,ver_arb,jsonb_build_object('method','cash','amount_cents',10000,'currency','SGD'),gen_random_uuid());
  op_arb := (topup->>'operation_id')::uuid; acct := (topup->>'account_id')::uuid;
  paid_lot := (topup->'paid_lot'->>'lot_id')::uuid; bonus_lot := (topup->'bonus_lot'->>'lot_id')::uuid;
  -- proportional draw: spend 3000 -> bonus floor(3000*1200/11200)=321, paid 2679
  spend := public.sv_spend(B, acct, 3000, gen_random_uuid());
  assert (spend->>'bonus_draw_cents')::int = 321 and (spend->>'paid_draw_cents')::int = 2679,
    'PS-0 case (b) draw must be bonus 321 / paid 2679, got '||spend::text;
  ref := public.refund_sv_operation(B, op_arb, null, gen_random_uuid());
  assert (ref->>'cash_cents')::int = 7321, 'PS-0 case (b) cash-out must be 7321, got '||(ref->>'cash_cents');
  assert (ref->>'clawback_cents')::int = 879 and (ref->>'final')::boolean,
    'the FINAL refund must claw the ENTIRE 879 bonus remaining (PS-0 §5 requirement 2)';
  assert pg_temp.v68a_rem(paid_lot) = 0, 'paid must close at 0';
  assert pg_temp.v68a_rem(bonus_lot) = 0, 'no stranded bonus cent (PS-0 §10.3)';
  assert (ref->>'cash_refunded_cumulative_cents')::int = 7321, 'cumulative cash must be 7321';
  assert (ref->>'cash_collected_cents')::int = 10000, 'cash collected must be the 10000 actually taken';
  assert (ref->>'cash_refunded_cumulative_cents')::int <= (ref->>'cash_collected_cents')::int,
    'the customer received more cash than they paid (arbitrage)';
  assert (select cumulative_cash_cents from public.sv_topup_cash_refunds where topup_operation_id=op_arb) = 7321,
    'the structural cap ledger must record the 7321 running total';
  -- DEFAULT-OFF CONTROL: this plan never set refund_policy, so it resolves to the product default and
  -- the stricter unused-only variant did NOT apply.
  assert (ref->>'refund_policy')='proportional', 'the stricter refund variants must default OFF, got '||(ref->>'refund_policy');

  ---------------------------------------------------------------- CASH-REFUND CAP (typed + structural)
  topup := public.record_sv_topup_sale(B,B_branch,cli_cap,ver_cap,jsonb_build_object('method','cash','amount_cents',10000,'currency','SGD'),gen_random_uuid());
  op_cap := (topup->>'operation_id')::uuid; paid_lot := (topup->'paid_lot'->>'lot_id')::uuid;
  ref := public.refund_sv_operation(B, op_cap, null, gen_random_uuid());
  assert (ref->>'cash_cents')::int = 10000 and (ref->>'cash_refunded_cumulative_cents')::int = 10000, 'whole refund must return the full 10000';
  -- an owner correction puts 5000 back on the (now empty) paid lot - legal, since 5000 <= minted 10000
  corr := public.sv_correct_lot(B, paid_lot, 5000, 'goodwill restore after the refund', gen_random_uuid());
  assert (corr->>'remaining_after_cents')::int = 5000, 'the positive correction must restore 5000';
  -- ...but refunding it as CASH would take cumulative cash to 15000 on a 10000 collection -> refused
  begin perform public.refund_sv_operation(B, op_cap, null, gen_random_uuid());
    raise exception 'cumulative cash exceeded the cash collected' using errcode='XX000';
  exception when others then
    assert sqlstate='22023','the cash cap must be a typed 22023, got '||sqlstate;
    assert position('sv_cash_refund_cap' in sqlerrm)=1, 'expected sv_cash_refund_cap, got: '||sqlerrm; end;
  assert pg_temp.v68a_rem(paid_lot) = 5000, 'the refused refund moved value';
  assert (select count(*) from public.sv_topup_cash_refunds where topup_operation_id=op_cap) = 1,
    'the refused refund wrote a cap-ledger row';
  -- STRUCTURAL: even a direct write cannot record cash beyond the collection
  reset role;
  begin
    insert into public.sv_topup_cash_refunds(business_id,account_id,topup_operation_id,refund_operation_id,paid_lot_id,
      cash_cents,cumulative_cash_cents,cash_collected_cents,cash_basis)
    select business_id,account_id,topup_operation_id,refund_operation_id,paid_lot_id,1,cash_collected_cents+1,cash_collected_cents,cash_basis
      from public.sv_topup_cash_refunds where topup_operation_id=op_cap;
    raise exception 'the cash-refund cap CHECK did not fire' using errcode='XX000';
  exception when others then assert sqlstate='23514','the cap must be a CHECK violation, got '||sqlstate; end;
  begin
    insert into public.sv_topup_cash_refunds(business_id,account_id,topup_operation_id,refund_operation_id,paid_lot_id,
      cash_cents,cumulative_cash_cents,cash_collected_cents,cash_basis)
    select business_id,account_id,topup_operation_id,refund_operation_id,paid_lot_id,cash_cents,cumulative_cash_cents,cash_collected_cents,cash_basis
      from public.sv_topup_cash_refunds where topup_operation_id=op_cap;
    raise exception 'a duplicate running total was accepted' using errcode='XX000';
  exception when others then assert sqlstate='23505','a duplicate running total must be a unique violation, got '||sqlstate; end;
  begin update public.sv_topup_cash_refunds set cash_cents=1 where topup_operation_id=op_cap;
    raise exception 'the cap ledger was mutated' using errcode='XX000';
  exception when others then assert sqlstate='23001','the cap ledger must be append-only, got '||sqlstate; end;
  perform pg_temp.as_v68a(B_owner,'authenticated');

  ---------------------------------------------------------------- UNUSED-ONLY + NO-REFUND PLAN VARIANTS
  topup := public.record_sv_topup_sale(B,B_branch,cli_un1,ver_unused,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  op_un1 := (topup->>'operation_id')::uuid;
  ref := public.refund_sv_operation(B, op_un1, null, gen_random_uuid());   -- wholly unspent -> permitted
  assert (ref->>'refund_policy')='unused_only' and (ref->>'cash_cents')::int = 5000,
    'an unused_only refund of a wholly-unspent top-up must return the full 5000, got '||ref::text;
  topup := public.record_sv_topup_sale(B,B_branch,cli_un2,ver_unused,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  op_un2 := (topup->>'operation_id')::uuid; acct := (topup->>'account_id')::uuid;
  perform public.sv_spend(B, acct, 100, gen_random_uuid());
  begin perform public.refund_sv_operation(B, op_un2, null, gen_random_uuid());
    raise exception 'unused_only permitted a refund of a partly-spent top-up' using errcode='XX000';
  exception when others then
    assert sqlstate='22023','the unused_only refusal must be 22023, got '||sqlstate;
    assert position('sv_refund_unused_only' in sqlerrm)=1, 'expected sv_refund_unused_only, got: '||sqlerrm; end;
  topup := public.record_sv_topup_sale(B,B_branch,cli_nr,ver_norefund,jsonb_build_object('method','cash','amount_cents',4000,'currency','SGD'),gen_random_uuid());
  op_nr := (topup->>'operation_id')::uuid;
  begin perform public.refund_sv_operation(B, op_nr, null, gen_random_uuid());
    raise exception 'a no_refund plan version was refunded' using errcode='XX000';
  exception when others then
    assert sqlstate='22023','the no_refund refusal must be 22023, got '||sqlstate;
    assert position('sv_refund_not_permitted' in sqlerrm)=1, 'expected sv_refund_not_permitted, got: '||sqlerrm; end;
  assert (select count(*) from public.sv_topup_cash_refunds where topup_operation_id=op_nr) = 0,
    'a refused no_refund attempt wrote a cap-ledger row';

  ---------------------------------------------------------------- CORRECTION (contract §4)
  topup := public.record_sv_topup_sale(B,B_branch,cli_corr,ver_gate,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  op_corr := (topup->>'operation_id')::uuid; acct_corr := (topup->>'account_id')::uuid;
  corr_paid := (topup->'paid_lot'->>'lot_id')::uuid; corr_bonus := (topup->'bonus_lot'->>'lot_id')::uuid;

  -- reason mandatory (null / empty / whitespace / too short) -> typed 22023
  foreach trail in array array[null, '', '   ', 'ab'] loop
    begin perform public.sv_correct_lot(B, corr_paid, -100, trail, gen_random_uuid());
      raise exception 'a correction was accepted without a reason' using errcode='XX000';
    exception when others then
      assert sqlstate='22023','a missing reason must be 22023, got '||sqlstate;
      assert position('requires a reason of at least 3 characters' in sqlerrm) > 0, 'expected the typed reason refusal, got: '||sqlerrm; end;
  end loop;
  -- zero / null cents refused
  begin perform public.sv_correct_lot(B, corr_paid, 0, 'zero probe', gen_random_uuid());
    raise exception 'a zero-cent correction was accepted' using errcode='XX000';
  exception when others then assert sqlstate='22023','a zero correction must be 22023, got '||sqlstate; end;
  begin perform public.sv_correct_lot(B, corr_paid, null, 'null probe', gen_random_uuid());
    raise exception 'a null-cent correction was accepted' using errcode='XX000';
  exception when others then assert sqlstate='22023','a null correction must be 22023, got '||sqlstate; end;

  -- BOTH DIRECTIONS on a live lot, and ONLY the target lot moves
  select count(*) into m from public.sv_lot_movements where lot_id=corr_bonus;
  corr := public.sv_correct_lot(B, corr_paid, -1500, 'till overcount on the funding day', gen_random_uuid());
  assert (corr->>'direction')='decrease' and (corr->>'remaining_after_cents')::int = 3500 and not (corr->>'is_mint')::boolean,
    'the negative correction must take 5000 -> 3500 without minting, got '||corr::text;
  assert pg_temp.v68a_rem(corr_paid) = 3500, 'the negative correction did not apply';
  corr := public.sv_correct_lot(B, corr_paid, 500, 'partial reinstatement after review', gen_random_uuid());
  assert (corr->>'direction')='increase' and (corr->>'remaining_after_cents')::int = 4000, 'the positive correction must take 3500 -> 4000';
  assert (select count(*) from public.sv_lot_movements where lot_id=corr_bonus) = m, 'a correction touched another lot';
  assert (select count(*) from public.sv_lot_movements where lot_id=corr_paid and kind='correction') = 2, 'exactly two correction movements on the target lot';
  assert (select coalesce(sum(cents),0) from public.sv_lot_movements where lot_id=corr_paid) = pg_temp.v68a_rem(corr_paid),
    'PS-0 §10.1 broken after a correction';
  assert exists (select 1 from public.audit_log where business_id=B and action='SV_CORRECT_LOT'
                  and (detail->>'reason')='till overcount on the funding day'), 'the correction must be audited with its reason';

  -- may never drive remaining below 0 nor above minted_cents
  begin perform public.sv_correct_lot(B, corr_paid, -4001, 'over-void probe', gen_random_uuid());
    raise exception 'a correction drove remaining below zero' using errcode='XX000';
  exception when others then
    assert sqlstate='22023','over-void must be 22023, got '||sqlstate;
    assert position('sv_correction_below_zero' in sqlerrm)=1, 'expected sv_correction_below_zero, got: '||sqlerrm; end;
  begin perform public.sv_correct_lot(B, corr_paid, 1001, 'over-mint probe', gen_random_uuid());
    raise exception 'a correction drove remaining above minted' using errcode='XX000';
  exception when others then
    assert sqlstate='22023','over-mint must be 22023, got '||sqlstate;
    assert position('sv_correction_above_mint' in sqlerrm)=1, 'expected sv_correction_above_mint, got: '||sqlerrm; end;
  -- the exact boundary IS allowed (remaining == minted)
  corr := public.sv_correct_lot(B, corr_paid, 1000, 'restore to the minted amount', gen_random_uuid());
  assert (corr->>'remaining_after_cents')::int = 5000, 'a correction to exactly minted_cents must be allowed';

  -- not a mint: no lot row is ever created
  select count(*) into n from public.sv_lots where business_id=B;
  perform public.sv_correct_lot(B, corr_paid, -1, 'single cent probe', gen_random_uuid());
  assert (select count(*) from public.sv_lots where business_id=B) = n, 'a correction created a lot (mint)';

  -- idempotent replay + changed-request same-key conflict
  k := gen_random_uuid();
  corr := public.sv_correct_lot(B, corr_paid, -100, 'idempotency probe', k);
  select count(*) into n from public.sv_lot_movements where lot_id=corr_paid;
  assert public.sv_correct_lot(B, corr_paid, -100, 'idempotency probe', k) = corr, 'a replayed correction must return the cached result';
  assert (select count(*) from public.sv_lot_movements where lot_id=corr_paid) = n, 'a replayed correction wrote a movement';
  begin perform public.sv_correct_lot(B, corr_paid, -200, 'idempotency probe', k);
    raise exception 'a changed correction reused its key' using errcode='XX000';
  exception when others then
    assert sqlstate='22023','changed-request same-key must be 22023, got '||sqlstate;
    assert position('idempotency key conflicts' in sqlerrm) > 0, 'expected the typed idempotency conflict, got: '||sqlerrm; end;

  -- a charged-back operation's lots are frozen
  begin perform public.sv_correct_lot(B, (select id from public.sv_lots where operation_id=op_e and class='paid'), 100, 'post-chargeback probe', gen_random_uuid());
    raise exception 'a charged-back lot was corrected' using errcode='XX000';
  exception when others then
    assert sqlstate='22023','a charged-back correction must be 22023, got '||sqlstate;
    assert position('sv_charged_back' in sqlerrm)=1, 'expected sv_charged_back, got: '||sqlerrm; end;

  -- a lot in ANOTHER business is invisible
  begin perform public.sv_correct_lot(A, corr_paid, -100, 'cross-tenant probe', gen_random_uuid());
    raise exception 'a cross-tenant correction was accepted' using errcode='XX000';
  exception when others then assert sqlstate in ('22023','42501'), 'a cross-tenant correction must be refused, got '||sqlstate; end;

  ---------------------------------------------------------------- EXPIRY MATRIX (PS-0 §6, case (f))
  reset role;
  seed := pg_temp.v68a_seed(B, cli_exp, 10000, now() + interval '365 days', 1200, now() - interval '1 day');
  acct_exp := (seed->>'account')::uuid; paid_lot := (seed->>'paid_lot')::uuid; bonus_lot := (seed->>'bonus_lot')::uuid;
  perform pg_temp.as_v68a(B_owner,'authenticated');
  -- spend 1200 -> PS-0: bonus floor(1200*1200/11200)=128, paid 1072
  spend := public.sv_spend(B, acct_exp, 1200, gen_random_uuid()); spend_op := (spend->>'operation_id')::uuid;
  assert (spend->>'bonus_draw_cents')::int = 128 and (spend->>'paid_draw_cents')::int = 1072,
    'case (f) draw must be bonus 128 / paid 1072, got '||spend::text;
  -- EXPIRY INDEPENDENCE: the sweep expires ONLY the past-expiry bonus lot; the paid lot is untouched
  select count(*) into m from public.sv_lot_movements where lot_id=paid_lot;
  perform public.sv_expire_due(B, 1000);
  assert (select count(*) from public.sv_lot_movements where lot_id=paid_lot) = m,
    'a bonus expiry touched the paid lot (PS-0 §6 expiry independence)';
  assert pg_temp.v68a_rem(bonus_lot) = 0 and pg_temp.v68a_rem(paid_lot) = 8928, 'after the bonus expiry: bonus 0 / paid 8928';
  -- RESTORE-THEN-EXPIRE: the reversal restores +128 and immediately re-expires -128; paid restores fully
  perform public.sv_reverse_spend(B, spend_op, gen_random_uuid());
  assert pg_temp.v68a_rem(paid_lot) = 10000, 'the paid lot must be restored to 10000';
  assert pg_temp.v68a_rem(bonus_lot) = 0, 'an expired lot must never be silently resurrected';
  -- PS-0 case (f) trail, asserted twice. (1) as a canonically-ordered MULTISET (every row in the
  -- suite shares one transaction timestamp, so created_at cannot order them) - the same form the
  -- v63 suite pins; (2) in physical append order via ctid, which additionally proves the
  -- restore-then-expire SEQUENCE (+reversal immediately followed by -expiry).
  select string_agg(kind||':'||cents::text, ',' order by cents, kind) into trail
    from public.sv_lot_movements where lot_id=bonus_lot;
  assert trail = 'expiry:-1072,expiry:-128,spend:-128,reversal:128,issue:1200',
    'PS-0 case (f) bonus trail multiset must be {issue+1200,spend-128,expiry-1072,reversal+128,expiry-128}, got: '||trail;
  select string_agg(m.kind||' '||m.cents, ', ' order by m.ctid) into trail
    from public.sv_lot_movements m where m.lot_id=bonus_lot;
  assert trail = 'issue 1200, spend -128, expiry -1072, reversal 128, expiry -128',
    'PS-0 case (f) bonus trail order must be exact, got: '||trail;
  assert (select coalesce(sum(cents),0) from public.sv_lot_movements where lot_id=bonus_lot) = 0, 'the case (f) bonus trail must sum to 0';
  -- the restore-then-expire pair belongs to ONE reverse operation and BOTH legs are recorded
  assert (select count(*) from public.sv_lot_movements m
           where m.lot_id=bonus_lot and m.operation_id=(select id from public.sv_operations
             where business_id=B and operation_type='reverse' and (result->>'spend_operation_id')=spend_op::text)) = 2,
    'restore-then-expire must record BOTH legs under the reverse operation';
  -- a positive correction onto the expired lot is refused (pinned default, see the migration header)
  begin perform public.sv_correct_lot(B, bonus_lot, 100, 'expired restore probe', gen_random_uuid());
    raise exception 'a positive correction resurrected an expired lot' using errcode='XX000';
  exception when others then
    assert sqlstate='22023','the expired-lot refusal must be 22023, got '||sqlstate;
    assert position('sv_correct_expired_lot' in sqlerrm)=1, 'expected sv_correct_expired_lot, got: '||sqlerrm; end;
  -- a NEGATIVE correction on a live lot with a past-expiry sibling still works (independence again)
  corr := public.sv_correct_lot(B, paid_lot, -1000, 'independent negative correction', gen_random_uuid());
  assert (corr->>'remaining_after_cents')::int = 9000, 'the negative correction on the live paid lot must apply';
  assert pg_temp.v68a_rem(bonus_lot) = 0, 'the paid-lot correction touched the bonus lot';
  -- a chargeback needs recorded payment evidence; this seeded operation has none
  begin perform public.sv_chargeback_topup(B, (seed->>'operation')::uuid, 'no evidence probe', gen_random_uuid());
    raise exception 'a chargeback ran without payment evidence' using errcode='XX000';
  exception when others then
    assert sqlstate='22023','the missing-evidence refusal must be 22023, got '||sqlstate;
    assert position('sv_no_payment_evidence' in sqlerrm)=1, 'expected sv_no_payment_evidence, got: '||sqlerrm; end;

  ---------------------------------------------------------------- GATE MATRICES
  topup := public.record_sv_topup_sale(B,B_branch,cli_gate,ver_gate,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  op_gate := (topup->>'operation_id')::uuid; paid_lot := (topup->'paid_lot'->>'lot_id')::uuid;

  -- PAUSE FAMILY MAPPING: chargeback + correction are REDEEM-family; an 'earn' pause does NOT block
  -- them, a 'redeem' pause does, and 'all' does.
  perform public.sv_pause(B,'stored_value','earn','v68a earn pause probe');
  corr := public.sv_correct_lot(B, paid_lot, -1, 'earn pause must not block a correction', gen_random_uuid());
  assert (corr->>'status')='ok', 'an earn pause wrongly blocked a correction';
  perform public.sv_lift_pause(B,'stored_value','earn','done');
  perform public.sv_pause(B,'stored_value','redeem','v68a redeem pause probe');
  begin perform public.sv_correct_lot(B, paid_lot, -1, 'redeem pause probe', gen_random_uuid());
    raise exception 'a redeem pause did not block a correction' using errcode='XX000';
  exception when others then
    assert sqlstate='22023','the pause refusal must be 22023, got '||sqlstate;
    assert position('sv_paused' in sqlerrm)=1, 'expected sv_paused, got: '||sqlerrm; end;
  begin perform public.sv_chargeback_topup(B, op_gate, 'redeem pause probe', gen_random_uuid());
    raise exception 'a redeem pause did not block a chargeback' using errcode='XX000';
  exception when others then assert sqlstate='22023' and position('sv_paused' in sqlerrm)=1, 'chargeback must be sv_paused under a redeem pause'; end;
  perform public.sv_lift_pause(B,'stored_value','redeem','done');
  perform public.sv_pause(B,'stored_value','all','v68a all pause probe');
  begin perform public.sv_chargeback_topup(B, op_gate, 'all pause probe', gen_random_uuid());
    raise exception 'an all pause did not block a chargeback' using errcode='XX000';
  exception when others then assert sqlstate='22023' and position('sv_paused' in sqlerrm)=1, 'chargeback must be sv_paused under an all pause'; end;
  perform public.sv_lift_pause(B,'stored_value','all','done');

  -- AUTHORITY MATRIX: shadow_testing / ready_for_cutover / paused all refuse
  foreach trail in array array['shadow_testing','ready_for_cutover','paused'] loop
    reset role; perform pg_temp.v68a_force_state(B,trail); perform pg_temp.as_v68a(B_owner,'authenticated');
    begin perform public.sv_chargeback_topup(B, op_gate, 'authority probe', gen_random_uuid());
      raise exception 'a chargeback ran while authority is %', trail using errcode='XX000';
    exception when others then assert sqlstate='22023' and position('sv_not_live' in sqlerrm)=1, 'chargeback must be sv_not_live in '||trail; end;
    begin perform public.sv_correct_lot(B, paid_lot, -1, 'authority probe', gen_random_uuid());
      raise exception 'a correction ran while authority is %', trail using errcode='XX000';
    exception when others then assert sqlstate='22023' and position('sv_not_live' in sqlerrm)=1, 'correction must be sv_not_live in '||trail; end;
  end loop;
  reset role; perform pg_temp.v68a_force_state(B,'live'); perform pg_temp.as_v68a(B_owner,'authenticated');

  -- CURRENCY: the recorded funding currency must still match the business currency
  reset role; update public.businesses set currency='USD' where id=B; perform pg_temp.as_v68a(B_owner,'authenticated');
  begin perform public.sv_chargeback_topup(B, op_gate, 'currency probe', gen_random_uuid());
    raise exception 'a chargeback ran with a mismatched currency' using errcode='XX000';
  exception when others then
    assert sqlstate='22023','the currency refusal must be 22023, got '||sqlstate;
    assert position('currency_mismatch' in sqlerrm)=1, 'expected currency_mismatch, got: '||sqlerrm; end;
  reset role; update public.businesses set currency='SGD' where id=B; perform pg_temp.as_v68a(B_owner,'authenticated');

  -- SYNTHETIC-ON-LIVE (v66): a synthetic customer cannot transact on a live business. The marker is
  -- set on a DEDICATED customer that nothing else uses and is never cleared - the v66 guard refuses
  -- true->false while stored-value evidence remains, which is itself the behaviour we want to keep.
  topup := public.record_sv_topup_sale(B,B_branch,cli_syn,ver_gate,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  op_syn := (topup->>'operation_id')::uuid; syn_lot := (topup->'paid_lot'->>'lot_id')::uuid;
  reset role; update public.clients set is_synthetic=true where id=cli_syn; perform pg_temp.as_v68a(B_owner,'authenticated');
  begin perform public.sv_chargeback_topup(B, op_syn, 'synthetic probe', gen_random_uuid());
    raise exception 'a synthetic customer transacted on a live business' using errcode='XX000';
  exception when others then assert sqlstate='22023' and position('synthetic' in sqlerrm) > 0, 'expected the synthetic refusal, got: '||sqlerrm; end;
  begin perform public.sv_correct_lot(B, syn_lot, -1, 'synthetic probe', gen_random_uuid());
    raise exception 'a synthetic customer was corrected on a live business' using errcode='XX000';
  exception when others then assert sqlstate='22023' and position('synthetic' in sqlerrm) > 0, 'expected the synthetic refusal for correction'; end;

  -- OWNER-ONLY + ANON
  reset role;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
          'v68a-frontdesk-'||substr(md5(clock_timestamp()::text),1,10)||'@example.test','',now(),now(),now())
  returning id into frontdesk;
  insert into public.staff(business_id,user_id,full_name,role,active) values (B,frontdesk,'v68a frontdesk','frontdesk',true);
  perform pg_temp.as_v68a(frontdesk,'authenticated');
  begin perform public.sv_chargeback_topup(B, op_gate, 'frontdesk probe', gen_random_uuid());
    raise exception 'a frontdesk charged back a top-up' using errcode='XX000';
  exception when others then assert sqlstate='42501','a non-owner chargeback must be 42501, got '||sqlstate; end;
  begin perform public.sv_correct_lot(B, paid_lot, -1, 'frontdesk probe', gen_random_uuid());
    raise exception 'a frontdesk corrected a lot' using errcode='XX000';
  exception when others then assert sqlstate='42501','a non-owner correction must be 42501, got '||sqlstate; end;
  perform pg_temp.as_v68a(null,'anon');
  begin perform public.sv_chargeback_topup(B, op_gate, 'anon probe', gen_random_uuid());
    raise exception 'anon charged back a top-up' using errcode='XX000';
  exception when insufficient_privilege then null; end;
  begin perform public.sv_correct_lot(B, paid_lot, -1, 'anon probe', gen_random_uuid());
    raise exception 'anon corrected a lot' using errcode='XX000';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_v68a(B_owner,'authenticated');

  ---------------------------------------------------------------- ATOMIC ROLLBACK per write step
  topup := public.record_sv_topup_sale(B,B_branch,cli_atom,ver_gate,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  op_atom := (topup->>'operation_id')::uuid; acct_atom := (topup->>'account_id')::uuid;
  paid_lot := (topup->'paid_lot'->>'lot_id')::uuid;
  cnt0 := jsonb_build_object(
    'ops',        (select count(*) from public.sv_operations       where business_id=B),
    'movements',  (select count(*) from public.sv_lot_movements    where business_id=B),
    'chargebacks',(select count(*) from public.sv_chargebacks      where business_id=B),
    'cash_caps',  (select count(*) from public.sv_topup_cash_refunds where business_id=B),
    'pay_events', (select count(*) from public.sv_topup_payment_events where business_id=B),
    'audits',     (select count(*) from public.audit_log           where business_id=B));
  foreach tbl in array array['sv_operations','sv_lot_movements','sv_chargebacks','sv_topup_payment_events','audit_log'] loop
    reset role;
    execute format('create trigger v68a_inj before insert on public.%I for each row execute function pg_temp.v68a_boom()', tbl);
    perform pg_temp.as_v68a(B_owner,'authenticated');
    injected := false;
    begin
      perform public.sv_chargeback_topup(B, op_atom, 'injection at '||tbl, gen_random_uuid());
    exception when others then
      injected := (sqlstate = 'XX000' and position('INJECTED failure' in sqlerrm) > 0);
    end;
    reset role; execute format('drop trigger v68a_inj on public.%I', tbl);
    assert injected, 'chargeback injection at '||tbl||' did not fail with the injected error';
    cnt := jsonb_build_object(
      'ops',        (select count(*) from public.sv_operations       where business_id=B),
      'movements',  (select count(*) from public.sv_lot_movements    where business_id=B),
      'chargebacks',(select count(*) from public.sv_chargebacks      where business_id=B),
      'cash_caps',  (select count(*) from public.sv_topup_cash_refunds where business_id=B),
      'pay_events', (select count(*) from public.sv_topup_payment_events where business_id=B),
      'audits',     (select count(*) from public.audit_log           where business_id=B));
    assert cnt = cnt0, 'chargeback injection at '||tbl||' left partial records: '||cnt0::text||' -> '||cnt::text;
  end loop;
  foreach tbl in array array['sv_operations','sv_lot_movements','audit_log'] loop
    reset role;
    execute format('create trigger v68a_inj before insert on public.%I for each row execute function pg_temp.v68a_boom()', tbl);
    perform pg_temp.as_v68a(B_owner,'authenticated');
    injected := false;
    begin
      perform public.sv_correct_lot(B, paid_lot, -1, 'injection at '||tbl, gen_random_uuid());
    exception when others then
      injected := (sqlstate = 'XX000' and position('INJECTED failure' in sqlerrm) > 0);
    end;
    reset role; execute format('drop trigger v68a_inj on public.%I', tbl);
    assert injected, 'correction injection at '||tbl||' did not fail with the injected error';
    cnt := jsonb_build_object(
      'ops',        (select count(*) from public.sv_operations       where business_id=B),
      'movements',  (select count(*) from public.sv_lot_movements    where business_id=B),
      'chargebacks',(select count(*) from public.sv_chargebacks      where business_id=B),
      'cash_caps',  (select count(*) from public.sv_topup_cash_refunds where business_id=B),
      'pay_events', (select count(*) from public.sv_topup_payment_events where business_id=B),
      'audits',     (select count(*) from public.audit_log           where business_id=B));
    assert cnt = cnt0, 'correction injection at '||tbl||' left partial records: '||cnt0::text||' -> '||cnt::text;
  end loop;
  perform pg_temp.as_v68a(B_owner,'authenticated');

  ---------------------------------------------------------------- GLOBAL INVARIANTS (PS-0 §10)
  reset role;
  assert not exists (
    select 1 from public.sv_lots l
     where l.business_id = B
       and app.sv_lot_remaining(l.id) is distinct from
           (select coalesce(sum(m.cents),0)::integer from public.sv_lot_movements m where m.lot_id = l.id)),
    'PS-0 §10.1 conservation broken on some lot of B';
  assert not exists (
    select 1 from public.sv_lots l where l.business_id = B and app.sv_lot_remaining(l.id) < 0),
    'a lot went negative';
  assert not exists (
    select 1 from public.sv_lots l where l.business_id = B and app.sv_lot_remaining(l.id) > l.minted_cents),
    'a lot exceeded its minted amount';
  assert not exists (
    select 1 from public.sv_topup_cash_refunds r where r.cumulative_cash_cents > r.cash_collected_cents),
    'PS-0 §10.2 broken: cumulative cash exceeded the cash collected';
  -- cumulative cash in the cap ledger agrees with the movement authority
  assert not exists (
    select 1 from (select topup_operation_id, max(cumulative_cash_cents) as capped
                     from public.sv_topup_cash_refunds where business_id=B group by topup_operation_id) t
     where t.capped is distinct from app.sv_cash_refunded_cents(B, t.topup_operation_id)),
    'the cap ledger drifted from the movement authority';
  -- reservations still never write movements and outstanding stays gross
  assert not exists (
    select 1 from public.sv_lot_movements m join public.sv_reservations r on r.operation_id = m.operation_id),
    'a reservation wrote a stored-value movement';
  -- bad_debt is always zero-cents, so it can never disturb the conservation invariant
  assert not exists (select 1 from public.sv_lot_movements where kind='bad_debt' and cents <> 0),
    'a bad_debt movement carried non-zero cents';
  -- exactly one bad_debt movement per chargeback, on that chargeback's paid lot
  assert (select count(*) from public.sv_lot_movements where kind='bad_debt' and business_id=B)
       = (select count(*) from public.sv_chargebacks where business_id=B),
    'bad_debt movements and chargebacks are not 1:1';
  assert not exists (
    select 1 from public.sv_lot_movements m join public.sv_chargebacks c on c.operation_id = m.operation_id
     where m.kind='bad_debt' and m.lot_id is distinct from c.paid_lot_id),
    'a bad_debt movement was written on a lot other than the chargeback paid lot';

  raise notice 'V68A SUITE PASS (all assertions)';
end $v68a$;
rollback;
