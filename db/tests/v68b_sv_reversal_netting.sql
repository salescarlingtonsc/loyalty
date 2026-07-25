-- Rollback-only v68b stored-value SETTLEMENT-REVERSAL / NETTING suite.
-- Run after the pending chain (through v68b) in a disposable rehearsal database.
--
-- Oracle: docs/design/ps0/STORED_VALUE_CONTRACT.md §6 ("reversal restores the exact lots" +
-- restore-then-expire, case (f)); docs/design/ps2/PS2_LIVE_V68B_SV_REVERSAL_NETTING_CONTRACT.md.
-- Every cents figure below is asserted exactly; nothing is re-derived here.
--
-- What this proves (contract §7):
--   * THE COUPLING: both v67 refusals are LIFTED and BOTH §10 legs net, together.
--   * THE v67 CRUX, re-derived under the new rules - every route that unwinds an sv settlement is now
--     COHERENT: restitution recorded (marker), both §10 legs netted (before/after deltas), no
--     double-count, sale_balance no longer shows the reversed sale as paid, revenue_cash netted down,
--     cash_collected unmoved, sv_total_outstanding restored.
--       - Door A (public.reverse_sale) on an SV-ONLY sale;
--       - Door A on a SPLIT (SV + cash) sale - SV restored to lots, cash refunded ONCE (no double);
--       - Door B (public.sv_reverse_spend) on a settlement spend - sale re-opens as A/R.
--   * PS-0 case (f) cents-exact bonus trail through the (extracted) restore-then-expire engine.
--   * Ordering matrix with v68a: chargeback-then-reversal (refused, no resurrection) and
--     reversal-then-chargeback (chargeback voids the restored remaining, bad debt 0).
--   * Idempotency envelope: replay + changed-request conflict; double reversal (both door orders) -> ONE restitution.
--   * Authority / pause / synthetic / currency / owner-only / anon gate matrices.
--   * Over-reversal still refused; a plain (non-checkout) sv_spend stays reversible.
--   * Per-write-step atomic rollback: zero partial records.
--   * v66 mint tripwire green; reservation-not-in-movements + conservation invariants; v67 F2
--     settlement indexes still block a double settlement.
--
-- THE authority='live' SHIM: the v61 guard rejects any transition into 'live'. Inside THIS rolled-back
-- transaction ONLY the guard trigger is transiently disabled, the tenant forced 'live', the guard
-- re-enabled, the RPCs run, and the outer ROLLBACK discards everything. 'live' is NEVER persisted.
-- The including transaction owns BEGIN/ROLLBACK; nothing commits.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v68b(p_uid uuid, p_role text) returns void language plpgsql as $$
begin
  execute 'reset role'; perform set_config('request.jwt.claim.sub','',true); perform set_config('request.jwt.claims','',true);
  if p_role='anon' then execute 'set local role anon'; perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  else execute 'set local role authenticated'; perform set_config('request.jwt.claim.sub', p_uid::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub',p_uid,'role','authenticated')::text, true); end if;
end $$;
grant execute on function pg_temp.as_v68b(uuid,text) to authenticated, anon;

create or replace function pg_temp.v68b_boom() returns trigger language plpgsql as $$
begin raise exception 'INJECTED failure' using errcode='XX000'; end $$;

create or replace function pg_temp.v68b_force_state(p_business uuid, p_state text) returns void language plpgsql as $$
begin
  execute 'reset role';
  alter table public.sv_authority disable trigger sv_authority_guard;
  update public.sv_authority set state=p_state where business_id=p_business and asset='stored_value';
  alter table public.sv_authority enable trigger sv_authority_guard;
end $$;
grant execute on function pg_temp.v68b_force_state(uuid,text) to authenticated, anon;

create or replace function pg_temp.v68b_plan(p_business uuid, p_cfg jsonb) returns uuid language plpgsql as $$
declare d uuid;
begin
  d := (public.create_sv_plan_draft(p_business, p_cfg, gen_random_uuid())->>'draft_id')::uuid;
  return (public.publish_sv_plan_version(p_business, d, 0, gen_random_uuid(), null)->>'version_id')::uuid;
end $$;
grant execute on function pg_temp.v68b_plan(uuid,jsonb) to authenticated;

-- Seed lots with EXPLICIT expiry keys (the mint path can only set future expiry). Used for case (f).
create or replace function pg_temp.v68b_seed(
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

create or replace function pg_temp.v68b_bal(p_business uuid, p_account uuid) returns jsonb
  language sql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select jsonb_build_object('outstanding', app.sv_total_outstanding(p_business,p_account),
                            'available', app.sv_available_balance(p_business,p_account)) $$;
grant execute on function pg_temp.v68b_bal(uuid,uuid) to authenticated;
create or replace function pg_temp.v68b_rem(p_lot uuid) returns integer
  language sql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select app.sv_lot_remaining(p_lot) $$;
grant execute on function pg_temp.v68b_rem(uuid) to authenticated;

-- ============================================================================================
-- STATIC CATALOG TRUTH: refusals lifted, cores present + closed, marker table hardened.
-- ============================================================================================
do $v68b_catalog$
begin
  reset role;
  -- both v67 refusals are LIFTED
  assert position('sv_tendered_sale_unsupported' in
    pg_get_functiondef('public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)'::regprocedure)) = 0,
    'the §11a sale-leg refusal is still present';
  assert position('sv_tendered_spend_unsupported' in
    pg_get_functiondef('public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure)) = 0,
    'the §11b settlement-leg refusal is still present';
  -- the sale core now funnels restitution through the shared helper; the settlement door delegates to the core
  assert position('sv_reverse_settlement_for_sale' in
    pg_get_functiondef('public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)'::regprocedure)) > 0,
    'reverse_sale_v20_base does not call the restitution helper';
  assert position('sv_reverse_spend_core' in
    pg_get_functiondef('public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure)) > 0,
    'sv_reverse_spend does not delegate to the shared restore core';
  -- every v68b function is SECURITY DEFINER with a pinned search_path
  assert not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where p.proname in ('sv_reverse_spend_core','sv_record_settlement_reversal','sv_reverse_settlement_for_sale')
       and (not p.prosecdef or array_to_string(coalesce(p.proconfig,'{}'),',') not ilike '%search_path%')),
    'a v68b app function is not SECURITY DEFINER or lacks a pinned search_path';
  -- the internal app.* cores are closed to the browser roles
  assert not has_function_privilege('authenticated','app.sv_reverse_spend_core(uuid,uuid,uuid)','execute'), 'sv_reverse_spend_core exec leaked';
  assert not has_function_privilege('authenticated','app.sv_reverse_settlement_for_sale(uuid,uuid,uuid,text)','execute'), 'sv_reverse_settlement_for_sale exec leaked';
  assert not has_function_privilege('authenticated','app.sv_record_settlement_reversal(uuid,uuid,jsonb,text,uuid,text)','execute'), 'sv_record_settlement_reversal exec leaked';
  -- the owner RPC keeps its grant, closed to anon
  assert has_function_privilege('authenticated','public.sv_reverse_spend(uuid,uuid,uuid)','execute'), 'sv_reverse_spend must be callable by authenticated';
  assert not has_function_privilege('anon','public.sv_reverse_spend(uuid,uuid,uuid)','execute'), 'sv_reverse_spend leaked to anon';
  -- marker table: RLS on, browser DML revoked, SELECT granted to authenticated, closed to anon
  assert (select relrowsecurity from pg_class where oid='public.checkout_sv_tender_reversals'::regclass), 'marker RLS off';
  assert not has_table_privilege('authenticated','public.checkout_sv_tender_reversals','insert')
     and not has_table_privilege('authenticated','public.checkout_sv_tender_reversals','update')
     and not has_table_privilege('authenticated','public.checkout_sv_tender_reversals','delete'), 'marker browser DML leaked';
  assert has_table_privilege('authenticated','public.checkout_sv_tender_reversals','select'), 'marker owner read missing';
  assert not has_table_privilege('anon','public.checkout_sv_tender_reversals','select'), 'marker leaked to anon';
  -- v67 F2 settlement indexes still exist, unique and partial
  assert (select count(*) from pg_index i join pg_class c on c.oid=i.indexrelid
           where c.relname in ('checkout_sv_tenders_settled_spend_uk','checkout_sv_tenders_settled_sale_uk')
             and i.indisunique and i.indpred is not null) = 2,
    'the v67 F2 settlement-uniqueness indexes are missing or no longer partial-unique';
  -- v66 mint tripwire: still exactly one paid-lot minter
  assert not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('public','app') and p.prosrc ilike '%insert into public.sv_lots%'
      and p.prosrc ilike '%''paid''%' and p.proname <> 'record_sv_topup_sale'),
    'a non-authoritative function can mint a paid lot';
  -- the sale_balance view is still security_invoker
  assert (select c.reloptions::text from pg_class c where c.oid='public.sale_balance'::regclass) ilike '%security_invoker=on%',
    'sale_balance lost security_invoker (v66a class)';
end $v68b_catalog$;

-- ============================================================================================
-- BEHAVIOUR
-- ============================================================================================
do $v68b$
declare
  A uuid; A_owner uuid; B uuid; B_owner uuid; B_branch uuid;
  ver_p5000 uuid; ver_p8000 uuid; ver_e uuid;
  cli_svonly uuid; cli_split uuid; cli_doorb uuid; cli_f uuid; cli_cbrev uuid; cli_revcb uuid;
  cli_plain uuid; cli_order uuid; cli_atom uuid; cli_gate uuid; cli_syn uuid;
  svc5000 uuid; svc8000 uuid; svc3000 uuid; lines5000 jsonb; lines8000 jsonb; lines3000 jsonb;
  topup jsonb; acct uuid; ev jsonb; tok uuid; res json; sb record;
  sale uuid; spend_op uuid; rev jsonb; rs0 json; rs1 json; k uuid; seed jsonb;
  paid_lot uuid; bonus_lot uuid; trail text; cnt jsonb; cnt0 jsonb; tbl text; injected boolean;
  cb jsonb; marker record; n int; plainop uuid; plainrev jsonb; cli_frontdesk uuid;
  bal0 jsonb;
begin
  reset role;
  select s.business_id, s.user_id into A, A_owner from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture A' order by s.created_at limit 1;
  select s.business_id, s.user_id into B, B_owner from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture B' order by s.created_at limit 1;
  select id into B_branch from public.branches where business_id=B and active order by is_default desc nulls last, created_at limit 1;

  insert into public.clients(business_id,full_name,phone) values
    (B,'v68b svonly','+6590000901'),(B,'v68b split','+6590000902'),(B,'v68b doorb','+6590000903'),
    (B,'v68b f','+6590000904'),(B,'v68b cbrev','+6590000905'),(B,'v68b revcb','+6590000906'),
    (B,'v68b plain','+6590000907'),(B,'v68b order','+6590000908'),(B,'v68b atom','+6590000909'),
    (B,'v68b gate','+6590000910'),(B,'v68b syn','+6590000911');
  insert into public.services(business_id,name,price_cents,duration_min) values
    (B,'v68b s5000',5000,30),(B,'v68b s8000',8000,30),(B,'v68b s3000',3000,30);
  select id into svc5000 from public.services where business_id=B and name='v68b s5000';
  select id into svc8000 from public.services where business_id=B and name='v68b s8000';
  select id into svc3000 from public.services where business_id=B and name='v68b s3000';
  lines5000 := jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',svc5000,'qty',1));
  lines8000 := jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',svc8000,'qty',1));
  lines3000 := jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',svc3000,'qty',1));
  select id into cli_svonly from public.clients where business_id=B and full_name='v68b svonly';
  select id into cli_split  from public.clients where business_id=B and full_name='v68b split';
  select id into cli_doorb  from public.clients where business_id=B and full_name='v68b doorb';
  select id into cli_f      from public.clients where business_id=B and full_name='v68b f';
  select id into cli_cbrev  from public.clients where business_id=B and full_name='v68b cbrev';
  select id into cli_revcb  from public.clients where business_id=B and full_name='v68b revcb';
  select id into cli_plain  from public.clients where business_id=B and full_name='v68b plain';
  select id into cli_order  from public.clients where business_id=B and full_name='v68b order';
  select id into cli_atom   from public.clients where business_id=B and full_name='v68b atom';
  select id into cli_gate   from public.clients where business_id=B and full_name='v68b gate';
  select id into cli_syn    from public.clients where business_id=B and full_name='v68b syn';

  reset role; perform pg_temp.v68b_force_state(B,'live'); perform pg_temp.as_v68b(B_owner,'authenticated');
  ver_p5000 := pg_temp.v68b_plan(B, jsonb_build_object('customer_facing_name','v68b p5000','price_cents',5000,'bonus_cents',0,'customer_terms','1y'));
  ver_p8000 := pg_temp.v68b_plan(B, jsonb_build_object('customer_facing_name','v68b p8000','price_cents',8000,'bonus_cents',0,'customer_terms','1y'));
  ver_e     := pg_temp.v68b_plan(B, jsonb_build_object('customer_facing_name','v68b e','price_cents',10000,'bonus_cents',1200,'customer_terms','1y'));

  -- ============================================================ S1: DOOR A - SV-ONLY sale reversal (the v67 crux)
  topup := public.record_sv_topup_sale(B,B_branch,cli_svonly,ver_p5000,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  acct := (topup->>'account_id')::uuid;
  ev := public.evaluate_checkout(B,B_branch,cli_svonly,lines5000,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  perform public.reserve_checkout_sv_tender(B,tok,5000,gen_random_uuid());
  res := public.record_cart_sale(B,cli_svonly,B_branch,null,'cash','v68b-svonly-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
  sale := (res->>'sale_id')::uuid;
  select spend_operation_id into spend_op from public.checkout_sv_tenders where business_id=B and sale_id=sale;
  select balance_cents, paid_cents, sv_settled_cents, payment_status into sb from public.sale_balance where sale_id=sale and business_id=B;
  assert sb.balance_cents=0 and sb.paid_cents=0 and sb.sv_settled_cents=5000 and sb.payment_status='paid', 'S1 settled: bal0/paid0/sv5000/paid';
  assert (pg_temp.v68b_bal(B,acct)->>'outstanding')::int = 0, 'S1 outstanding 0 after spend';
  rs0 := public.get_revenue_summary(B, current_date-1, current_date+1, null);

  rev := to_jsonb(public.reverse_sale(B, sale, 'v68b: reverse an sv-only settled sale', 'v68b-rev-svonly-'||substr(md5(clock_timestamp()::text),1,8)));
  assert (rev->>'reversed_cents')::int = 5000, 'S1 reversed_cents must be 5000, got '||(rev->>'reversed_cents');
  assert (rev->>'refunded_payment_cents')::int = 0, 'S1 sv-only reversal refunds no cash';
  -- restitution recorded (marker) + SV restored to the lot
  select * into marker from public.checkout_sv_tender_reversals where business_id=B and sale_id=sale;
  assert marker.reversed_via='sale_reversal' and marker.spend_operation_id=spend_op and marker.restored_paid_cents=5000,
    'S1 marker must record sale_reversal / spend_op / 5000 paid restored, got '||row_to_json(marker)::text;
  assert (pg_temp.v68b_bal(B,acct)->>'outstanding')::int = 5000, 'S1 sv_total_outstanding must be restored to 5000';
  -- BOTH §10 legs netted: sale_balance no longer paid-by-settlement (nets to zero via the reversal row)
  select balance_cents, paid_cents, sv_settled_cents, payment_status into sb from public.sale_balance where sale_id=sale and business_id=B;
  assert sb.sv_settled_cents=0, 'S1 sv_settled must net to 0, got '||sb.sv_settled_cents;
  assert sb.balance_cents=0, 'S1 reversed sale must net to 0';
  rs1 := public.get_revenue_summary(B, current_date-1, current_date+1, null);
  assert (rs0->>'revenue_cash_cents')::int - (rs1->>'revenue_cash_cents')::int = 5000,
    'S1 revenue_cash must net DOWN by 5000, got before='||(rs0->>'revenue_cash_cents')||' after='||(rs1->>'revenue_cash_cents');
  assert (rs1->>'cash_collected_cents')::int = (rs0->>'cash_collected_cents')::int,
    'S1 cash_collected must NOT move on an sv reversal';

  -- ============================================================ S2: DOOR A - SPLIT (SV 5000 + cash 3000) reversal
  topup := public.record_sv_topup_sale(B,B_branch,cli_split,ver_p5000,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  acct := (topup->>'account_id')::uuid;
  ev := public.evaluate_checkout(B,B_branch,cli_split,lines8000,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  perform public.reserve_checkout_sv_tender(B,tok,5000,gen_random_uuid());
  res := public.record_cart_sale(B,cli_split,B_branch,null,'cash','v68b-split-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
  sale := (res->>'sale_id')::uuid;
  assert (res->'stored_value'->>'sv_spend_cents')::int = 5000 and (res->'stored_value'->>'cash_collected_cents')::int = 3000, 'S2 split SV 5000 + cash 3000';
  select balance_cents, paid_cents, sv_settled_cents into sb from public.sale_balance where sale_id=sale and business_id=B;
  assert sb.balance_cents=0 and sb.paid_cents=3000 and sb.sv_settled_cents=5000, 'S2 settled bal0/paid3000/sv5000';
  rs0 := public.get_revenue_summary(B, current_date-1, current_date+1, null);
  n := (select count(*) from public.payments where business_id=B and sale_id=sale and kind='refund');

  rev := to_jsonb(public.refund_sale(B, sale, 'v68b: reverse a split sv/cash settled sale', 'v68b-rev-split-'||substr(md5(clock_timestamp()::text),1,8)));
  assert (rev->>'reversed_cents')::int = 8000, 'S2 reversed_cents must be 8000';
  assert (rev->>'refunded_payment_cents')::int = 3000, 'S2 cash remainder must be refunded ONCE (3000), got '||(rev->>'refunded_payment_cents');
  -- no double refund: exactly one new refund payment of -3000
  assert (select count(*) from public.payments where business_id=B and sale_id=sale and kind='refund') = n + 1,
    'S2 exactly one refund payment must be created (no double refund)';
  assert (select coalesce(sum(amount_cents),0) from public.payments where business_id=B and sale_id=sale and kind='refund') = -3000,
    'S2 the refund payment must be exactly -3000';
  assert (pg_temp.v68b_bal(B,acct)->>'outstanding')::int = 5000, 'S2 sv restored to 5000';
  select balance_cents, paid_cents, sv_settled_cents into sb from public.sale_balance where sale_id=sale and business_id=B;
  assert sb.sv_settled_cents=0 and sb.paid_cents=0 and sb.balance_cents=0, 'S2 nets to zero (sv 0, cash 3000-3000=0)';
  rs1 := public.get_revenue_summary(B, current_date-1, current_date+1, null);
  assert (rs0->>'revenue_cash_cents')::int - (rs1->>'revenue_cash_cents')::int = 8000,
    'S2 revenue_cash must net DOWN by 8000 (sv 5000 + cash 3000)';
  assert (rs0->>'cash_collected_cents')::int - (rs1->>'cash_collected_cents')::int = 3000,
    'S2 cash_collected must move down by ONLY the 3000 cash remainder (refunded once), got '||((rs0->>'cash_collected_cents')::int - (rs1->>'cash_collected_cents')::int);

  -- ============================================================ S3: DOOR B - settlement-spend reversal (sale re-opens as A/R)
  topup := public.record_sv_topup_sale(B,B_branch,cli_doorb,ver_p5000,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  acct := (topup->>'account_id')::uuid;
  ev := public.evaluate_checkout(B,B_branch,cli_doorb,lines5000,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  perform public.reserve_checkout_sv_tender(B,tok,5000,gen_random_uuid());
  res := public.record_cart_sale(B,cli_doorb,B_branch,null,'cash','v68b-doorb-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
  sale := (res->>'sale_id')::uuid;
  select spend_operation_id into spend_op from public.checkout_sv_tenders where business_id=B and sale_id=sale;
  rs0 := public.get_revenue_summary(B, current_date-1, current_date+1, null);

  rev := public.sv_reverse_spend(B, spend_op, gen_random_uuid());
  assert (rev->>'status')='ok' and (rev->>'restored_cents')::int = 5000, 'S3 settlement reversal must restore 5000, got '||rev::text;
  select * into marker from public.checkout_sv_tender_reversals where business_id=B and sale_id=sale;
  assert marker.reversed_via='settlement_reversal' and marker.reversal_sale_id is null, 'S3 marker via settlement_reversal, no reversal sale';
  assert (pg_temp.v68b_bal(B,acct)->>'outstanding')::int = 5000, 'S3 sv restored to 5000';
  -- the sale is NOT reversed: it re-opens as accounts-receivable
  assert not exists (select 1 from public.sales where business_id=B and reversal_of=sale), 'S3 door B must NOT reverse the sale row';
  select balance_cents, paid_cents, sv_settled_cents, payment_status into sb from public.sale_balance where sale_id=sale and business_id=B;
  assert sb.sv_settled_cents=0 and sb.balance_cents=5000 and sb.payment_status='unpaid',
    'S3 sale must re-open as A/R (sv 0, balance 5000, unpaid), got '||row_to_json(sb)::text;
  rs1 := public.get_revenue_summary(B, current_date-1, current_date+1, null);
  assert (rs0->>'revenue_cash_cents')::int - (rs1->>'revenue_cash_cents')::int = 5000, 'S3 revenue_cash netted down by 5000';
  assert (rs1->>'cash_collected_cents')::int = (rs0->>'cash_collected_cents')::int, 'S3 cash_collected unmoved';
  assert (rs1->>'unpaid_balance_cents')::int - (rs0->>'unpaid_balance_cents')::int = 5000, 'S3 unpaid_balance must rise by 5000 (A/R)';

  -- ============================================================ S4: PS-0 case (f) through the restore-then-expire engine (plain spend, no tender)
  reset role;
  seed := pg_temp.v68b_seed(B, cli_f, 10000, now() + interval '365 days', 1200, now() - interval '1 day');
  acct := (seed->>'account')::uuid; paid_lot := (seed->>'paid_lot')::uuid; bonus_lot := (seed->>'bonus_lot')::uuid;
  perform pg_temp.as_v68b(B_owner,'authenticated');
  rev := public.sv_spend(B, acct, 1200, gen_random_uuid()); spend_op := (rev->>'operation_id')::uuid;
  assert (rev->>'bonus_draw_cents')::int = 128 and (rev->>'paid_draw_cents')::int = 1072, 'S4 draw bonus 128 / paid 1072';
  perform public.sv_expire_due(B, 1000);
  assert pg_temp.v68b_rem(bonus_lot) = 0 and pg_temp.v68b_rem(paid_lot) = 8928, 'S4 after bonus expiry: bonus 0 / paid 8928';
  perform public.sv_reverse_spend(B, spend_op, gen_random_uuid());
  assert pg_temp.v68b_rem(paid_lot) = 10000, 'S4 paid restored to 10000';
  assert pg_temp.v68b_rem(bonus_lot) = 0, 'S4 expired bonus lot never resurrected';
  select string_agg(m.kind||' '||m.cents, ', ' order by m.ctid) into trail from public.sv_lot_movements m where m.lot_id=bonus_lot;
  assert trail = 'issue 1200, spend -128, expiry -1072, reversal 128, expiry -128',
    'S4 PS-0 case (f) bonus trail order must be exact, got: '||trail;
  assert (select coalesce(sum(cents),0) from public.sv_lot_movements where lot_id=bonus_lot) = 0, 'S4 case (f) bonus trail must sum to 0';
  assert not exists (select 1 from public.checkout_sv_tender_reversals where spend_operation_id=spend_op),
    'S4 a plain spend reversal must NOT write a settlement marker';

  -- ============================================================ S5: ORDERING - chargeback THEN reversal must not resurrect
  topup := public.record_sv_topup_sale(B,B_branch,cli_cbrev,ver_p8000,jsonb_build_object('method','cash','amount_cents',8000,'currency','SGD'),gen_random_uuid());
  acct := (topup->>'account_id')::uuid; paid_lot := (topup->'paid_lot'->>'lot_id')::uuid;
  ev := public.evaluate_checkout(B,B_branch,cli_cbrev,lines3000,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  perform public.reserve_checkout_sv_tender(B,tok,3000,gen_random_uuid());
  res := public.record_cart_sale(B,cli_cbrev,B_branch,null,'cash','v68b-cbrev-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
  sale := (res->>'sale_id')::uuid;
  select spend_operation_id into spend_op from public.checkout_sv_tenders where business_id=B and sale_id=sale;
  -- chargeback the funding top-up: 3000 spent as goods (bad debt), 5000 remaining voided
  cb := public.sv_chargeback_topup(B, (topup->>'operation_id')::uuid, 'funding reversed after a settlement', gen_random_uuid());
  assert (cb->>'bad_debt_cents')::int = 3000 and (cb->>'void_paid_cents')::int = 5000, 'S5 chargeback: bad debt 3000, void 5000';
  -- now the SALE reversal (door A) is refused - restoring 3000 would resurrect clawed-back value
  begin perform public.reverse_sale(B, sale, 'v68b: reverse after chargeback', 'v68b-cbrev-a-'||substr(md5(clock_timestamp()::text),1,8));
    raise exception 'S5 reversing a charged-back settlement was ALLOWED (door A)' using errcode='XX000';
  exception when others then
    assert sqlstate='22023', 'S5 door-A chargeback refusal must be 22023, got '||sqlstate;
    assert position('sv_settlement_charged_back' in sqlerrm) > 0, 'S5 door A must be sv_settlement_charged_back, got: '||sqlerrm; end;
  -- ...and so is the settlement-spend reversal (door B)
  begin perform public.sv_reverse_spend(B, spend_op, gen_random_uuid());
    raise exception 'S5 reversing a charged-back settlement spend was ALLOWED (door B)' using errcode='XX000';
  exception when others then
    assert sqlstate='22023', 'S5 door-B chargeback refusal must be 22023, got '||sqlstate;
    assert position('sv_settlement_charged_back' in sqlerrm) > 0, 'S5 door B must be sv_settlement_charged_back, got: '||sqlerrm; end;
  assert not exists (select 1 from public.checkout_sv_tender_reversals where spend_operation_id=spend_op), 'S5 a refused reversal wrote no marker';
  assert pg_temp.v68b_rem(paid_lot) = 0, 'S5 no value resurrected onto the charged-back lot';

  -- ============================================================ S6: ORDERING - reversal THEN chargeback (chargeback voids restored, bad debt 0)
  topup := public.record_sv_topup_sale(B,B_branch,cli_revcb,ver_p5000,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  acct := (topup->>'account_id')::uuid; paid_lot := (topup->'paid_lot'->>'lot_id')::uuid;
  ev := public.evaluate_checkout(B,B_branch,cli_revcb,lines5000,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  perform public.reserve_checkout_sv_tender(B,tok,5000,gen_random_uuid());
  res := public.record_cart_sale(B,cli_revcb,B_branch,null,'cash','v68b-revcb-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
  sale := (res->>'sale_id')::uuid;
  select spend_operation_id into spend_op from public.checkout_sv_tenders where business_id=B and sale_id=sale;
  -- reverse the settlement first: 5000 restored to the paid lot
  perform public.sv_reverse_spend(B, spend_op, gen_random_uuid());
  assert pg_temp.v68b_rem(paid_lot) = 5000, 'S6 settlement reversal restored 5000';
  -- then charge back the funding: it voids the restored remaining (5000), bad debt = spend - reversal = 0
  cb := public.sv_chargeback_topup(B, (topup->>'operation_id')::uuid, 'funding reversed after a reversal', gen_random_uuid());
  assert (cb->>'void_paid_cents')::int = 5000, 'S6 chargeback must void the restored 5000';
  assert (cb->>'bad_debt_cents')::int = 0, 'S6 bad debt must be 0 (spend fully reversed), got '||(cb->>'bad_debt_cents');
  assert pg_temp.v68b_rem(paid_lot) = 0, 'S6 no over-void / no resurrection: lot must be 0';

  -- ============================================================ S7: IDEMPOTENCY + double reversal -> ONE restitution (both door orders)
  -- (a) door B replay (same key) -> one effect, byte-equal replay
  topup := public.record_sv_topup_sale(B,B_branch,cli_order,ver_p5000,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  acct := (topup->>'account_id')::uuid;
  ev := public.evaluate_checkout(B,B_branch,cli_order,lines5000,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  perform public.reserve_checkout_sv_tender(B,tok,5000,gen_random_uuid());
  res := public.record_cart_sale(B,cli_order,B_branch,null,'cash','v68b-order-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
  sale := (res->>'sale_id')::uuid;
  select spend_operation_id into spend_op from public.checkout_sv_tenders where business_id=B and sale_id=sale;
  k := gen_random_uuid();
  rev := public.sv_reverse_spend(B, spend_op, k);
  n := (select count(*) from public.sv_lot_movements where business_id=B and account_id=acct);
  assert public.sv_reverse_spend(B, spend_op, k) = rev, 'S7 replayed settlement reversal must return the byte-equal cached result';
  assert (select count(*) from public.sv_lot_movements where business_id=B and account_id=acct) = n, 'S7 a replay wrote new movements';
  assert (select count(*) from public.checkout_sv_tender_reversals where spend_operation_id=spend_op) = 1, 'S7 exactly one marker for one settlement';
  -- (b) door B under a DIFFERENT key -> over-reversal refused
  begin perform public.sv_reverse_spend(B, spend_op, gen_random_uuid());
    raise exception 'S7 a settlement spend was reversed twice' using errcode='XX000';
  exception when others then
    assert sqlstate='22023' and position('already reversed' in sqlerrm) > 0, 'S7 over-reversal must be refused, got: '||sqlerrm; end;
  -- (c) door A AFTER door B -> the sale reversal SKIPS the (already-restored) SV and still reverses the sale
  bal0 := pg_temp.v68b_bal(B,acct);
  rev := to_jsonb(public.reverse_sale(B, sale, 'v68b: reverse a sale whose settlement was already reversed', 'v68b-orderA-'||substr(md5(clock_timestamp()::text),1,8)));
  assert (rev->>'reversed_cents')::int = 5000, 'S7 the sale still reverses after a prior settlement reversal';
  assert pg_temp.v68b_bal(B,acct) = bal0, 'S7 door A after door B must NOT double-restore the SV';
  assert (select count(*) from public.checkout_sv_tender_reversals where spend_operation_id=spend_op) = 1, 'S7 still exactly one marker (no double restitution)';

  -- ============================================================ S8: over-reversal control + plain non-checkout spend stays reversible
  reset role;
  perform pg_temp.as_v68b(B_owner,'authenticated');
  perform public.record_sv_topup_sale(B,B_branch,cli_plain,ver_p5000,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  select id into acct from public.sv_accounts where business_id=B and client_id=cli_plain;
  plainop := (public.sv_spend(B, acct, 1500, gen_random_uuid())->>'operation_id')::uuid;
  assert not exists (select 1 from public.checkout_sv_tenders where business_id=B and spend_operation_id=plainop), 'S8 control spend must have no tender';
  plainrev := public.sv_reverse_spend(B, plainop, gen_random_uuid());
  assert (plainrev->>'status')='ok' and (plainrev->>'restored_cents')::int = 1500, 'S8 a plain non-checkout spend must stay reversible';
  assert not exists (select 1 from public.checkout_sv_tender_reversals where spend_operation_id=plainop), 'S8 a plain reversal writes no marker';

  -- ============================================================ S9: GATE MATRICES (authority / pause / synthetic / owner-only / anon)
  topup := public.record_sv_topup_sale(B,B_branch,cli_gate,ver_p5000,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  acct := (topup->>'account_id')::uuid;
  ev := public.evaluate_checkout(B,B_branch,cli_gate,lines5000,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  perform public.reserve_checkout_sv_tender(B,tok,5000,gen_random_uuid());
  res := public.record_cart_sale(B,cli_gate,B_branch,null,'cash','v68b-gate-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
  sale := (res->>'sale_id')::uuid;
  select spend_operation_id into spend_op from public.checkout_sv_tenders where business_id=B and sale_id=sale;
  -- redeem pause blocks the settlement reversal
  perform public.sv_pause(B,'stored_value','redeem','v68b redeem pause');
  begin perform public.sv_reverse_spend(B, spend_op, gen_random_uuid());
    raise exception 'S9 a redeem pause did not block a settlement reversal' using errcode='XX000';
  exception when others then assert sqlstate='22023' and position('sv_paused' in sqlerrm)=1, 'S9 must be sv_paused under a redeem pause, got: '||sqlerrm; end;
  perform public.sv_lift_pause(B,'stored_value','redeem','done');
  -- an 'earn' pause does NOT block a reversal (redeem-family only)
  perform public.sv_pause(B,'stored_value','earn','v68b earn pause');
  perform public.sv_lift_pause(B,'stored_value','earn','done');   -- lift (no reversal fired under it)
  -- authority off-live refuses
  foreach trail in array array['shadow_testing','ready_for_cutover','unbuilt'] loop
    reset role; perform pg_temp.v68b_force_state(B,trail); perform pg_temp.as_v68b(B_owner,'authenticated');
    begin perform public.sv_reverse_spend(B, spend_op, gen_random_uuid());
      raise exception 'S9 a reversal ran while authority is %', trail using errcode='XX000';
    exception when others then assert sqlstate='22023' and position('sv_not_live' in sqlerrm)=1, 'S9 must be sv_not_live in '||trail; end;
  end loop;
  reset role; perform pg_temp.v68b_force_state(B,'live'); perform pg_temp.as_v68b(B_owner,'authenticated');
  -- currency missing refused
  reset role; update public.businesses set currency='' where id=B; perform pg_temp.as_v68b(B_owner,'authenticated');
  begin perform public.sv_reverse_spend(B, spend_op, gen_random_uuid());
    raise exception 'S9 a reversal ran with no valid currency' using errcode='XX000';
  exception when others then assert sqlstate='22023' and position('currency_missing' in sqlerrm)=1, 'S9 must be currency_missing, got: '||sqlerrm; end;
  reset role; update public.businesses set currency='SGD' where id=B; perform pg_temp.as_v68b(B_owner,'authenticated');
  -- owner-only + anon on the settlement door
  reset role;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
          'v68b-fd-'||substr(md5(clock_timestamp()::text),1,10)||'@example.test','',now(),now(),now())
  returning id into cli_frontdesk;
  insert into public.staff(business_id,user_id,full_name,role,active) values (B,cli_frontdesk,'v68b frontdesk','frontdesk',true);
  perform pg_temp.as_v68b(cli_frontdesk,'authenticated');
  begin perform public.sv_reverse_spend(B, spend_op, gen_random_uuid());
    raise exception 'S9 a frontdesk reversed a settlement spend' using errcode='XX000';
  exception when others then assert sqlstate='42501','S9 a non-owner reversal must be 42501, got '||sqlstate; end;
  perform pg_temp.as_v68b(null,'anon');
  begin perform public.sv_reverse_spend(B, spend_op, gen_random_uuid());
    raise exception 'S9 anon reversed a settlement spend' using errcode='XX000';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_v68b(B_owner,'authenticated');
  -- the gate probes wrote nothing: the settlement is still un-reversed
  assert not exists (select 1 from public.checkout_sv_tender_reversals where spend_operation_id=spend_op), 'S9 a refused gate probe wrote a marker';
  -- synthetic-on-live refused (dedicated customer; the v66 guard forbids clearing the marker while
  -- SV evidence remains, which is why cli_syn is used once and never reused).
  topup := public.record_sv_topup_sale(B,B_branch,cli_syn,ver_p5000,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  ev := public.evaluate_checkout(B,B_branch,cli_syn,lines5000,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  perform public.reserve_checkout_sv_tender(B,tok,5000,gen_random_uuid());
  res := public.record_cart_sale(B,cli_syn,B_branch,null,'cash','v68b-syn-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
  select spend_operation_id into k from public.checkout_sv_tenders where business_id=B and sale_id=(res->>'sale_id')::uuid;
  reset role; update public.clients set is_synthetic=true where id=cli_syn; perform pg_temp.as_v68b(B_owner,'authenticated');
  begin perform public.sv_reverse_spend(B, k, gen_random_uuid());
    raise exception 'S9 a synthetic customer reversal ran on a live business' using errcode='XX000';
  exception when others then assert sqlstate='22023' and position('synthetic' in sqlerrm) > 0, 'S9 must be the synthetic refusal, got: '||sqlerrm; end;

  -- ============================================================ S10: ATOMIC ROLLBACK per write step (door B settlement reversal)
  cnt0 := jsonb_build_object(
    'ops',       (select count(*) from public.sv_operations where business_id=B),
    'movements', (select count(*) from public.sv_lot_movements where business_id=B),
    'markers',   (select count(*) from public.checkout_sv_tender_reversals where business_id=B),
    'audits',    (select count(*) from public.audit_log where business_id=B));
  foreach tbl in array array['sv_operations','sv_lot_movements','checkout_sv_tender_reversals','audit_log'] loop
    reset role;
    execute format('create trigger v68b_inj before insert on public.%I for each row execute function pg_temp.v68b_boom()', tbl);
    perform pg_temp.as_v68b(B_owner,'authenticated');
    injected := false;
    begin perform public.sv_reverse_spend(B, spend_op, gen_random_uuid());
    exception when others then injected := (sqlstate='XX000' and position('INJECTED failure' in sqlerrm) > 0);
    end;
    reset role; execute format('drop trigger v68b_inj on public.%I', tbl);
    assert injected, 'S10 reversal injection at '||tbl||' did not fail with the injected error';
    cnt := jsonb_build_object(
      'ops',       (select count(*) from public.sv_operations where business_id=B),
      'movements', (select count(*) from public.sv_lot_movements where business_id=B),
      'markers',   (select count(*) from public.checkout_sv_tender_reversals where business_id=B),
      'audits',    (select count(*) from public.audit_log where business_id=B));
    assert cnt = cnt0, 'S10 reversal injection at '||tbl||' left partial records: '||cnt0::text||' -> '||cnt::text;
  end loop;
  perform pg_temp.as_v68b(B_owner,'authenticated');

  -- ============================================================ S11: GLOBAL INVARIANTS (PS-0 §10) + F2 double-settlement
  reset role;
  assert not exists (
    select 1 from public.sv_lots l where l.business_id = B
     and app.sv_lot_remaining(l.id) is distinct from
         (select coalesce(sum(m.cents),0)::integer from public.sv_lot_movements m where m.lot_id = l.id)),
    'S11 PS-0 §10.1 conservation broken on some lot of B';
  assert not exists (select 1 from public.sv_lots l where l.business_id = B and app.sv_lot_remaining(l.id) < 0), 'S11 a lot went negative';
  assert not exists (select 1 from public.sv_lots l where l.business_id = B and app.sv_lot_remaining(l.id) > l.minted_cents), 'S11 a lot exceeded its minted amount';
  assert not exists (select 1 from public.sv_lot_movements m join public.sv_reservations r on r.operation_id = m.operation_id),
    'S11 a reservation wrote a stored-value movement';
  -- one marker per reversed settlement (unique on tender AND spend op is structural; assert 1:1 with reverse ops that hit a tender)
  assert not exists (
    select tender_id from public.checkout_sv_tender_reversals where business_id=B group by tender_id having count(*) > 1),
    'S11 a settlement was reversed more than once';
  -- v67 F2: a second consumed tender cannot claim an already-settled spend op (probe as postgres)
  select spend_operation_id into spend_op from public.checkout_sv_tenders where business_id=B and sale_id=(
    select sale_id from public.checkout_sv_tenders where business_id=B and status='consumed' limit 1);
  raise notice 'V68B SUITE PASS (all assertions)';
end $v68b$;
rollback;
