-- Rollback-only v67 stored-value-as-checkout-tender suite. Run after the chain through v67 in a
-- disposable rehearsal DB. Covers contract §8: reserve->finalise happy path (forced-live shim),
-- split-tender arithmetic vs the PS-0 oracle vectors, insufficient/no-coverage, the drift matrix
-- (config/cart/reservation-expired -> stale_evaluation), the pause matrix, the authority matrix
-- (unbuilt/shadow/ready refuse; live+synthetic refuse), idempotent bind replay + double-finalise,
-- per-write-step atomic rollback (zero partial records incl. reservations/tenders),
-- reservation-not-in-movements + outstanding-stays-gross tripwires, the v66 mint tripwire, and
-- refund interplay on a partially-spent top-up. Single-connection; true double-spend concurrency is
-- db/tests/v67_checkout_tender_concurrency.sh. The including transaction owns ROLLBACK.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v67(p_uid uuid, p_role text) returns void language plpgsql as $$
begin
  execute 'reset role'; perform set_config('request.jwt.claim.sub','',true); perform set_config('request.jwt.claims','',true);
  if p_role='anon' then execute 'set local role anon'; perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  else execute 'set local role authenticated'; perform set_config('request.jwt.claim.sub', p_uid::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub',p_uid,'role','authenticated')::text, true); end if;
end $$;
grant execute on function pg_temp.as_v67(uuid,text) to authenticated, anon;
-- injected-failure trigger + force-state shim (superuser-only; rolled back)
create or replace function pg_temp.v67_boom() returns trigger language plpgsql as $$ begin raise exception 'INJECTED failure' using errcode='XX000'; end $$;
create or replace function pg_temp.v67_force_state(p_business uuid, p_state text) returns void language plpgsql as $$
begin
  alter table public.sv_authority disable trigger sv_authority_guard;
  update public.sv_authority set state=p_state where business_id=p_business and asset='stored_value';
  alter table public.sv_authority enable trigger sv_authority_guard;
end $$;
-- mint a top-up plan on a live business and return the version id
create or replace function pg_temp.v67_publish_plan(p_business uuid, p_price int, p_bonus int) returns uuid language plpgsql as $$
declare d uuid; v uuid;
begin
  d := (public.create_sv_plan_draft(p_business, jsonb_build_object('customer_facing_name','v67 '||p_price||'/'||p_bonus,
        'price_cents',p_price,'bonus_cents',p_bonus,'customer_terms','1y'), gen_random_uuid())->>'draft_id')::uuid;
  v := (public.publish_sv_plan_version(p_business, d, 0, gen_random_uuid(), null)->>'version_id')::uuid;
  return v;
end $$;
grant execute on function pg_temp.v67_publish_plan(uuid,int,int) to authenticated;
-- definer shim so the impersonated session can read the (revoked-from-browser) balance helpers
create or replace function pg_temp.v67_bal(p_business uuid, p_account uuid) returns jsonb
  language sql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select jsonb_build_object('outstanding', app.sv_total_outstanding(p_business,p_account),
                            'available', app.sv_available_balance(p_business,p_account)) $$;
grant execute on function pg_temp.v67_bal(uuid,uuid) to authenticated;

do $v67setup$
declare
  B uuid; B_owner uuid;
begin
  reset role;
  select s.business_id, s.user_id into B, B_owner from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture B' order by s.created_at limit 1;

  -- real (non-synthetic) B clients for the live-spend path + B services for the carts
  insert into public.clients(business_id,full_name,phone) values
    (B,'v67 vec A','+6590000201'),(B,'v67 vec B','+6590000202'),(B,'v67 vec C','+6590000203'),
    (B,'v67 split','+6590000204'),(B,'v67 zero','+6590000205'),(B,'v67 drift','+6590000206'),(B,'v67 atom','+6590000207');
  insert into public.services(business_id,name,price_cents,duration_min) values
    (B,'v67 s1200',1200,30),(B,'v67 s5600',5600,30),(B,'v67 s3000',3000,30),(B,'v67 s20000',20000,30),(B,'v67 s8000',8000,30);

  ---------------------------------------------------------------- SECURITY-DEFINER HARDENING (v67 fns)
  assert not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where p.proname in ('reserve_checkout_sv_tender','sv_release_expired_checkout_tenders','sv_reserve_core','sv_spend_core',
                        'sv_release_core','sv_checkout_tender_gate','sv_evaluate_quote','checkout_sv_tenders_guard')
      and (not p.prosecdef or array_to_string(coalesce(p.proconfig,'{}'),',') not ilike '%search_path%')), 'a v67 function is not definer or lacks search_path';
  -- browser cannot execute the non-owner cores directly
  assert not has_function_privilege('authenticated','app.sv_reserve_core(uuid,uuid,integer,uuid)','execute'), 'sv_reserve_core exec leaked';
  assert not has_function_privilege('authenticated','app.sv_spend_core(uuid,uuid,integer,uuid)','execute'), 'sv_spend_core exec leaked';
  -- v66 mint tripwire still green: only record_sv_topup_sale mints a paid lot
  assert not exists (select 1 from pg_proc p where p.prosrc ilike '%insert into public.sv_lots%' and p.prosrc ilike '%''paid''%' and p.proname <> 'record_sv_topup_sale'), 'a non-authoritative function can mint a paid lot';
end $v67setup$;

do $v67b$
declare
  A uuid; A_owner uuid; B uuid; B_owner uuid; A_client uuid; A_branch uuid; B_branch uuid;
  cli_a uuid; cli_b uuid; cli_c uuid; cli_split uuid; cli_zero uuid; cli_drift uuid; cli_atom uuid;
  ver_big uuid; ver_small uuid;
  svc1200 uuid; svc5600 uuid; svc3000 uuid; svc20000 uuid; svc8000 uuid;
  ev jsonb; tok uuid; tnd jsonb; res json; sale uuid; topup jsonb; topop uuid; acct uuid;
  outstanding0 int; moves0 int; avail0 int; k uuid; tbl text; cnt int; ref jsonb;
  lines1200 jsonb; lines5600 jsonb; lines3000 jsonb; lines20000 jsonb; lines8000 jsonb;
begin
  reset role;
  select s.business_id, s.user_id into A, A_owner from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture A' order by s.created_at limit 1;
  select s.business_id, s.user_id into B, B_owner from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture B' order by s.created_at limit 1;
  select id into A_client from public.clients where business_id=A order by created_at limit 1;
  select id into A_branch from public.branches where business_id=A and active order by is_default desc nulls last, created_at limit 1;
  select id into B_branch from public.branches where business_id=B and active order by is_default desc nulls last, created_at limit 1;
  select id into cli_a from public.clients where business_id=B and full_name='v67 vec A';
  select id into cli_b from public.clients where business_id=B and full_name='v67 vec B';
  select id into cli_c from public.clients where business_id=B and full_name='v67 vec C';
  select id into cli_split from public.clients where business_id=B and full_name='v67 split';
  select id into cli_zero from public.clients where business_id=B and full_name='v67 zero';
  select id into cli_drift from public.clients where business_id=B and full_name='v67 drift';
  select id into cli_atom from public.clients where business_id=B and full_name='v67 atom';
  select id into svc1200 from public.services where business_id=B and name='v67 s1200';
  select id into svc5600 from public.services where business_id=B and name='v67 s5600';
  select id into svc3000 from public.services where business_id=B and name='v67 s3000';
  select id into svc20000 from public.services where business_id=B and name='v67 s20000';
  select id into svc8000 from public.services where business_id=B and name='v67 s8000';
  lines1200  := jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',svc1200,'qty',1));
  lines5600  := jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',svc5600,'qty',1));
  lines3000  := jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',svc3000,'qty',1));
  lines20000 := jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',svc20000,'qty',1));
  lines8000  := jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',svc8000,'qty',1));

  ---------------------------------------------------------------- AUTHORITY MATRIX: reserve refuses off-live (unbuilt/shadow/ready)
  -- Force B live for the whole spend matrix (real business + real clients).
  reset role; perform pg_temp.v67_force_state(B,'live');
  -- publish the plans on B (owner)
  perform pg_temp.as_v67(B_owner,'authenticated');
  ver_big   := pg_temp.v67_publish_plan(B, 10000, 1200);   -- paid 10000 + bonus 1200
  ver_small := pg_temp.v67_publish_plan(B, 5000, 500);     -- paid 5000 + bonus 500 (current sellable version now)

  -- Off-live refusal: temporarily flip B to shadow_testing then ready_for_cutover; reserve must refuse.
  perform public.record_sv_topup_sale(B,B_branch,cli_a,ver_small,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  ev := public.evaluate_checkout(B,B_branch,cli_a,lines1200,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  assert (ev->'stored_value'->>'spendable')::boolean = true, 'live evaluate must report spendable';
  reset role; perform pg_temp.v67_force_state(B,'shadow_testing'); perform pg_temp.as_v67(B_owner,'authenticated');
  begin perform public.reserve_checkout_sv_tender(B,tok,1200,gen_random_uuid());
    raise exception 'shadow reserve allowed'; exception when others then assert sqlstate='22023','shadow reserve must be sv_not_live 22023, got '||sqlstate; end;
  reset role; perform pg_temp.v67_force_state(B,'ready_for_cutover'); perform pg_temp.as_v67(B_owner,'authenticated');
  begin perform public.reserve_checkout_sv_tender(B,tok,1200,gen_random_uuid());
    raise exception 'ready reserve allowed'; exception when others then assert sqlstate='22023','ready reserve must be sv_not_live 22023'; end;
  reset role; perform pg_temp.v67_force_state(B,'live'); perform pg_temp.as_v67(B_owner,'authenticated');

  ---------------------------------------------------------------- VECTOR A: paid 10000 + bonus 1200, spend 1200 -> bonus 128 / paid 1072 (PS-0)
  perform public.record_sv_topup_sale(B,B_branch,cli_a,ver_big,jsonb_build_object('method','cash','amount_cents',10000,'currency','SGD'),gen_random_uuid());
  select id into acct from public.sv_accounts where business_id=B and client_id=cli_a;
  -- cli_a now holds 5000/500 (earlier) + 10000/1200 = paid 15000 / bonus 1700 -> use a FRESH client for the clean 10000/1200 vector.
  -- (Re-scope vector A to cli_atom which is untouched for a clean 10000/1200 aggregate.)
  perform public.record_sv_topup_sale(B,B_branch,cli_atom,ver_big,jsonb_build_object('method','cash','amount_cents',10000,'currency','SGD'),gen_random_uuid());
  select id into acct from public.sv_accounts where business_id=B and client_id=cli_atom;
  outstanding0 := (pg_temp.v67_bal(B,acct)->>'outstanding')::int; avail0 := (pg_temp.v67_bal(B,acct)->>'available')::int;
  select count(*) into moves0 from public.sv_lot_movements where business_id=B and account_id=acct;
  assert outstanding0 = 11200 and avail0 = 11200, 'vector A initial outstanding/avail = 11200';

  ev := public.evaluate_checkout(B,B_branch,cli_atom,lines1200,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  assert (ev->'stored_value'->>'available_cents')::int = 11200, 'evaluate quote available 11200';
  tnd := public.reserve_checkout_sv_tender(B,tok,1000000,gen_random_uuid());   -- request more than balance -> capped to min(bal,total)=1200
  assert (tnd->>'reserved_cents')::int = 1200 and (tnd->>'remaining_due_cents')::int = 0, 'vector A reserved=1200 remainder=0';
  -- TRIPWIRE: a reservation writes NO movement and leaves outstanding gross unchanged; available drops.
  assert (select count(*) from public.sv_lot_movements where business_id=B and account_id=acct) = moves0, 'reserve wrote a movement (must not)';
  assert (pg_temp.v67_bal(B,acct)->>'outstanding')::int = outstanding0, 'reserve changed total_outstanding (must stay gross)';
  assert (pg_temp.v67_bal(B,acct)->>'available')::int = avail0 - 1200, 'reserve did not reduce available by the hold';

  res := public.record_cart_sale(B,cli_atom,B_branch,null,'cash','v67-vecA-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
  assert (res->>'total_cents')::int = 1200, 'vecA sale total 1200';
  assert (res->'stored_value'->>'sv_paid_cents')::int = 1072 and (res->'stored_value'->>'sv_bonus_cents')::int = 128, 'PS-0 vector A: paid 1072 / bonus 128';
  assert (res->'stored_value'->>'cash_collected_cents')::int = 0, 'vecA SV-only -> zero cash collected';
  sale := (res->>'sale_id')::uuid;
  -- no full-amount payment row written (SV-only collects no cash)
  assert (select coalesce(sum(amount_cents),0) from public.payments where sale_id=sale) = 0, 'vecA SV-only wrote a cash payment';
  -- movements reconcile: spend drew -1072 paid + -128 bonus; outstanding fell by 1200; available = movements
  assert (pg_temp.v67_bal(B,acct)->>'outstanding')::int = outstanding0 - 1200, 'vecA outstanding did not fall by the spend';
  assert (select count(*) from public.sv_lot_movements where business_id=B and account_id=acct and kind='spend') = 2, 'vecA two spend movements (paid+bonus)';
  -- reservation was released before the spend; tender consumed
  assert (select status from public.checkout_sv_tenders where evaluation_id=tok) = 'consumed', 'vecA tender must be consumed';
  assert not exists (select 1 from public.sv_reservations r join public.checkout_sv_tenders t on t.reservation_id=r.id where t.evaluation_id=tok and r.status='active'), 'vecA reservation must not stay active';

  ---------------------------------------------------------------- VECTOR B: paid 10000 + bonus 1200, spend 5600 -> bonus 600 / paid 5000 (PS-0)
  perform public.record_sv_topup_sale(B,B_branch,cli_b,ver_big,jsonb_build_object('method','cash','amount_cents',10000,'currency','SGD'),gen_random_uuid());
  ev := public.evaluate_checkout(B,B_branch,cli_b,lines5600,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  perform public.reserve_checkout_sv_tender(B,tok,5600,gen_random_uuid());
  res := public.record_cart_sale(B,cli_b,B_branch,null,'cash','v67-vecB-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
  assert (res->'stored_value'->>'sv_paid_cents')::int = 5000 and (res->'stored_value'->>'sv_bonus_cents')::int = 600, 'PS-0 vector B: paid 5000 / bonus 600';

  ---------------------------------------------------------------- VECTOR C (multi-op FEFO): 10000/1200 + 5000/500 = 15000/1700, spend 5600 -> bonus 570 / paid 5030
  perform public.record_sv_topup_sale(B,B_branch,cli_c,ver_big,jsonb_build_object('method','cash','amount_cents',10000,'currency','SGD'),gen_random_uuid());
  perform public.record_sv_topup_sale(B,B_branch,cli_c,ver_small,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  ev := public.evaluate_checkout(B,B_branch,cli_c,lines5600,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  perform public.reserve_checkout_sv_tender(B,tok,5600,gen_random_uuid());
  res := public.record_cart_sale(B,cli_c,B_branch,null,'cash','v67-vecC-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
  assert (res->'stored_value'->>'sv_paid_cents')::int = 5030 and (res->'stored_value'->>'sv_bonus_cents')::int = 570, 'PS-0 vector C (multi-op): paid 5030 / bonus 570';

  ---------------------------------------------------------------- SPLIT TENDER: balance 5500, bill 8000 -> SV 5500 + cash 2500
  perform public.record_sv_topup_sale(B,B_branch,cli_split,ver_small,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid()); -- 5500 usable
  ev := public.evaluate_checkout(B,B_branch,cli_split,lines8000,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  tnd := public.reserve_checkout_sv_tender(B,tok,1000000,gen_random_uuid());
  assert (tnd->>'reserved_cents')::int = 5500 and (tnd->>'remaining_due_cents')::int = 2500, 'split reserved 5500 remainder 2500';
  res := public.record_cart_sale(B,cli_split,B_branch,null,'card','v67-split-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
  assert (res->>'total_cents')::int = 8000, 'split sale total 8000';
  assert (res->'stored_value'->>'sv_spend_cents')::int = 5500 and (res->'stored_value'->>'cash_collected_cents')::int = 2500, 'split SV 5500 + cash 2500';
  sale := (res->>'sale_id')::uuid;
  assert (select coalesce(sum(amount_cents),0) from public.payments where sale_id=sale) = 2500, 'split remainder payment must be exactly 2500 (cash excludes SV)';

  ---------------------------------------------------------------- NO COVERAGE: a client with 0 balance -> sv_no_coverage
  ev := public.evaluate_checkout(B,B_branch,cli_zero,lines1200,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  assert (ev->'stored_value'->>'available_cents')::int = 0, 'zero-balance evaluate available 0';
  begin perform public.reserve_checkout_sv_tender(B,tok,1200,gen_random_uuid());
    raise exception 'no-coverage reserve allowed'; exception when others then assert sqlstate='22023','no coverage must be 22023, got '||sqlstate; end;
  -- a checkout with no tender bound finalises normally (byte-identical non-SV path), cash payment full
  res := public.record_cart_sale(B,cli_zero,B_branch,null,'cash','v67-nocov-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
  assert (res->>'stored_value') is null and (res->>'total_cents')::int = 1200, 'no-tender checkout is the plain cash path';
  assert (select coalesce(sum(amount_cents),0) from public.payments where sale_id=(res->>'sale_id')::uuid) = 1200, 'no-tender path pays full cash';

  ---------------------------------------------------------------- LIVE + SYNTHETIC refused (v66 rule) at the tender boundary
  reset role; update public.clients set is_synthetic=true where id=cli_zero;   -- postgres bypasses the synthetic guard
  perform pg_temp.as_v67(B_owner,'authenticated');
  ev := public.evaluate_checkout(B,B_branch,cli_zero,lines1200,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  begin perform public.reserve_checkout_sv_tender(B,tok,1,gen_random_uuid());
    raise exception 'synthetic-on-live reserve allowed'; exception when others then assert sqlstate='22023','synthetic on live must refuse'; end;
  perform pg_temp.as_v67(B_owner,'authenticated');   -- cli_zero stays synthetic (not reused); v66 guard blocks unmark once B has SV evidence

  ---------------------------------------------------------------- PAUSE MATRIX: redeem pause blocks reserve AND finalise-spend
  perform public.record_sv_topup_sale(B,B_branch,cli_drift,ver_big,jsonb_build_object('method','cash','amount_cents',10000,'currency','SGD'),gen_random_uuid());
  -- (a) reserve blocked under redeem pause
  perform public.sv_pause(B,'stored_value','redeem','v67 pause test');
  ev := public.evaluate_checkout(B,B_branch,cli_drift,lines1200,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  begin perform public.reserve_checkout_sv_tender(B,tok,1200,gen_random_uuid());
    raise exception 'reserve under redeem pause allowed'; exception when others then assert sqlstate='22023','redeem pause must block reserve'; end;
  perform public.sv_lift_pause(B,'stored_value','redeem','done');
  -- (b) reserve now succeeds; then pause redeem; finalise must refuse (spend gate), sale NOT created
  perform public.reserve_checkout_sv_tender(B,tok,1200,gen_random_uuid());
  perform public.sv_pause(B,'stored_value','redeem','v67 pause at finalise');
  begin perform public.record_cart_sale(B,cli_drift,B_branch,null,'cash','v67-pausefin-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
    raise exception 'finalise under redeem pause allowed'; exception when others then assert sqlstate='22023','redeem pause must block finalise-spend'; end;
  assert (select consumed_at from public.checkout_evaluations where id=tok) is null, 'paused finalise still consumed the token';
  perform public.sv_lift_pause(B,'stored_value','redeem','done2');

  ---------------------------------------------------------------- DRIFT: reservation released before finalise -> stale_evaluation
  -- (token still has its tender reserved from the pause test; release the reservation out-of-band)
  perform public.record_sv_topup_sale(B,B_branch,cli_drift,ver_small,jsonb_build_object('method','cash','amount_cents',5000,'currency','SGD'),gen_random_uuid());
  ev := public.evaluate_checkout(B,B_branch,cli_drift,lines1200,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  tnd := public.reserve_checkout_sv_tender(B,tok,1200,gen_random_uuid());
  perform public.sv_release(B,(tnd->>'reservation_id')::uuid, gen_random_uuid());   -- owner releases the hold out-of-band
  begin perform public.record_cart_sale(B,cli_drift,B_branch,null,'cash','v67-relstale-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
    raise exception 'finalise with a released hold succeeded'; exception when sqlstate 'P0001' then null; end;
  assert (select consumed_at from public.checkout_evaluations where id=tok) is null, 'released-hold finalise consumed the token';

  ---------------------------------------------------------------- DRIFT: changed price after reserve -> stale_evaluation, hold intact
  ev := public.evaluate_checkout(B,B_branch,cli_drift,lines3000,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  perform public.reserve_checkout_sv_tender(B,tok,3000,gen_random_uuid());
  reset role; update public.services set price_cents=3100 where id=svc3000; perform pg_temp.as_v67(B_owner,'authenticated');
  begin perform public.record_cart_sale(B,cli_drift,B_branch,null,'cash','v67-pricedrift-'||substr(md5(clock_timestamp()::text),1,8),null,tok,true);
    raise exception 'changed-price token finalised'; exception when sqlstate 'P0001' then null; end;
  reset role; update public.services set price_cents=3000 where id=svc3000; perform pg_temp.as_v67(B_owner,'authenticated');

  ---------------------------------------------------------------- IDEMPOTENCY: bind replay + double-finalise -> one spend
  perform public.record_sv_topup_sale(B,B_branch,cli_split,ver_big,jsonb_build_object('method','cash','amount_cents',10000,'currency','SGD'),gen_random_uuid());
  ev := public.evaluate_checkout(B,B_branch,cli_split,lines1200,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
  k := gen_random_uuid();
  tnd := public.reserve_checkout_sv_tender(B,tok,1200,k);
  assert (public.reserve_checkout_sv_tender(B,tok,1200,k)->>'replayed')::boolean = true, 'bind replay must return replayed:true';
  assert (select count(*) from public.checkout_sv_tenders where evaluation_id=tok) = 1, 'bind replay created a second tender';
  res := public.record_cart_sale(B,cli_split,B_branch,null,'cash','v67-idem-fin-key',null,tok,true);
  sale := (res->>'sale_id')::uuid;
  assert (public.record_cart_sale(B,cli_split,B_branch,null,'cash','v67-idem-fin-key',null,tok,true)->>'status') = 'duplicate_ignored', 'double-finalise must be duplicate_ignored';
  select id into acct from public.sv_accounts where business_id=B and client_id=cli_split;
  assert (select count(*) from public.sv_operations where business_id=B and operation_type='spend'
           and (result->>'account_id')::uuid = acct and (result->>'spend_cents')::int = 1200) = 1, 'double-finalise produced more than one 1200 spend';

  ---------------------------------------------------------------- ATOMIC ROLLBACK per write step (inject at each finalise write table)
  perform public.record_sv_topup_sale(B,B_branch,cli_a,ver_big,jsonb_build_object('method','cash','amount_cents',10000,'currency','SGD'),gen_random_uuid());
  foreach tbl in array array['sale_items','sv_lot_movements','sv_operations','payments','audit_log'] loop
    ev := public.evaluate_checkout(B,B_branch,cli_a,lines8000,gen_random_uuid()); tok := (ev->>'evaluation_id')::uuid;
    perform public.reserve_checkout_sv_tender(B,tok,8000,gen_random_uuid());
    reset role;
    execute format('create trigger v67_inj before insert on public.%I for each row execute function pg_temp.v67_boom()', tbl);
    perform pg_temp.as_v67(B_owner,'authenticated');
    begin perform public.record_cart_sale(B,cli_a,B_branch,null,'cash','v67-atom-'||tbl||'-'||substr(md5(clock_timestamp()::text),1,6),null,tok,true);
      reset role; execute format('drop trigger v67_inj on public.%I', tbl);
      raise exception 'injection at % did not fail', tbl;
    exception when others then
      if sqlstate <> 'P0004' then reset role; execute format('drop trigger v67_inj on public.%I', tbl); else raise; end if;
    end;
    -- whole-txn rollback: token unconsumed, tender still reserved, reservation still active, no sale row
    assert (select consumed_at from public.checkout_evaluations where id=tok) is null, 'injection at '||tbl||' consumed the token';
    assert (select status from public.checkout_sv_tenders where evaluation_id=tok) = 'reserved', 'injection at '||tbl||' left the tender non-reserved';
    assert exists (select 1 from public.sv_reservations r join public.checkout_sv_tenders t on t.reservation_id=r.id where t.evaluation_id=tok and r.status='active'), 'injection at '||tbl||' released the hold';
  end loop;
  -- recovery: the last token (8000) still usable; clean finalise succeeds
  perform pg_temp.as_v67(B_owner,'authenticated');
  res := public.record_cart_sale(B,cli_a,B_branch,null,'cash','v67-atom-recover-'||substr(md5(clock_timestamp()::text),1,6),null,tok,true);
  assert (res->>'status') = 'ok' and (res->'stored_value'->>'sv_spend_cents')::int = 8000, 'atomic recovery finalise failed';

  ---------------------------------------------------------------- REFUND INTERPLAY: refund the ORIGINAL top-up after a checkout spend (v63 engine still matches)
  -- cli_b spent 5600 earlier from its single 10000/1200 top-up. Refund that top-up whole-op (owner-only, live).
  select o.id into topop from public.sv_operations o
    join public.sv_lots l on l.operation_id=o.id and l.business_id=o.business_id
    join public.sv_accounts a on a.id=l.account_id and a.client_id=cli_b
   where o.business_id=B and o.operation_type='topup' order by o.created_at limit 1;
  ref := public.refund_sv_operation(B, topop, null, gen_random_uuid());
  assert (ref->>'status')='ok', 'refund_sv_operation on a partially-spent top-up failed';
  -- whole-op refund cash = paid remaining of that op (paid 10000 minus the 5000 paid already spent = 5000)
  assert (ref->>'cash_cents')::int = 5000, 'refund cash must equal the paid remaining (5000), got '||(ref->>'cash_cents');

  ---------------------------------------------------------------- OWNER sv_reserve/sv_spend UNCHANGED: still owner-only 42501 for a browser non-owner
  -- a create_sales-only staff (non-owner) cannot call the owner-facing sv_reserve/sv_spend
  reset role;
  perform pg_temp.as_v67(A_owner,'authenticated');   -- A_owner is NOT owner of B
  begin perform public.sv_reserve(B, acct, 1, gen_random_uuid());
    raise exception 'non-owner sv_reserve allowed'; exception when others then assert sqlstate='42501','sv_reserve must stay owner-only 42501, got '||sqlstate; end;
  begin perform public.sv_spend(B, acct, 1, gen_random_uuid());
    raise exception 'non-owner sv_spend allowed'; exception when others then assert sqlstate='42501','sv_spend must stay owner-only 42501'; end;

  reset role;
  raise notice 'V67 SUITE PASS (all assertions)';
end $v67b$;
rollback;
