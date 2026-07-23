-- Rollback-only v57 PS-1B.1 catalog-pricing-fails-closed suite.
-- Run after the full chain (through v57) in a disposable rehearsal database.
-- Proves: app.ps1b_catalog_price returns a TYPED result and NEVER a silent 0, and
-- the non-checkout executor consumes it so a pricing failure produces a logged,
-- evidence-backed 'failed' outcome (NO entitlement / fulfilment / reservation /
-- $0 promise) while healthy siblings still fulfil at the TRUE price.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v57_principal(p_uid uuid, p_role text)
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
  if p_role='anon' then
    execute 'set local role anon';
    perform set_config('request.jwt.claims',json_build_object('role','anon')::text,true);
  elsif p_role='authenticated' and p_uid is not null then
    execute 'set local role authenticated';
    perform set_config('request.jwt.claim.sub',p_uid::text,true);
    perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role','authenticated')::text,true);
  else
    raise exception 'unsupported v57 principal';
  end if;
end $$;
grant execute on function pg_temp.as_v57_principal(uuid,text) to authenticated, anon;

do $v57_test$
declare
  v_business uuid; v_owner uuid; v_owner_staff uuid; v_client uuid; v_branch uuid;
  v_biz_b uuid; v_base uuid; v_service uuid; v_product uuid;
  v_draft uuid; v_hash text; v_res jsonb; v_price jsonb;
  v_ruleX uuid; v_ruleY uuid; v_ruleZ uuid; v_evt uuid; v_n integer;
begin
  reset role;
  select s.business_id,s.user_id,s.id into v_business,v_owner,v_owner_staff
    from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture A'
   order by s.created_at limit 1;
  select b.id into v_biz_b from public.businesses b where b.name='Pristine chain fixture B' limit 1;
  if v_business is null or v_biz_b is null then raise exception 'v57 needs both fixture businesses'; end if;
  select id into v_client from public.clients where business_id=v_business order by created_at limit 1;
  select id into v_branch from public.branches where business_id=v_business and active order by is_default desc, created_at limit 1;
  select active_config_version_id into v_base from public.businesses where id=v_business;
  insert into public.services(business_id,name,price_cents,duration_min) values(v_business,'v57 free service',1500,30) returning id into v_service;
  insert into public.products(business_id,name,retail_price_cents) values(v_business,'v57 free product',2500) returning id into v_product;

  -- ================================================================
  -- Pure pricing contract (a-g). Driven as postgres: app.* is browser-revoked.
  -- ================================================================
  -- (a) valid service price -> ok + exact price_cents.
  v_price := app.ps1b_catalog_price(v_business,'service',v_service);
  if v_price->>'status'<>'ok' or (v_price->>'price_cents')::int<>1500 then
    raise exception 'a: service price not ok/1500: %', v_price; end if;

  -- (b) valid product retail price -> ok + exact retail_price_cents.
  v_price := app.ps1b_catalog_price(v_business,'product',v_product);
  if v_price->>'status'<>'ok' or (v_price->>'price_cents')::int<>2500 then
    raise exception 'b: product price not ok/2500: %', v_price; end if;

  -- (c) wrong business (real service id, business B's id) -> not_found, no leak.
  v_price := app.ps1b_catalog_price(v_biz_b,'service',v_service);
  if v_price->>'status'<>'not_found' then
    raise exception 'c: cross-tenant service leaked (expected not_found): %', v_price; end if;

  -- (d) missing catalog row -> not_found.
  v_price := app.ps1b_catalog_price(v_business,'service',gen_random_uuid());
  if v_price->>'status'<>'not_found' then
    raise exception 'd: missing catalog row not not_found: %', v_price; end if;

  -- (e) null reference -> not_applicable, price_cents null (never a meaningful 0).
  v_price := app.ps1b_catalog_price(v_business,'service',null);
  if v_price->>'status'<>'not_applicable' or v_price->>'price_cents' is not null then
    raise exception 'e: null ref not not_applicable/null-price: %', v_price; end if;

  -- (f) unsupported kind -> invalid_kind.
  v_price := app.ps1b_catalog_price(v_business,'bundle',v_service);
  if v_price->>'status'<>'invalid_kind' then
    raise exception 'f: bundle kind not invalid_kind: %', v_price; end if;

  -- (g) simulated renamed price column -> error (sqlstate) + structured audit row.
  select count(*) into v_n from public.audit_log where business_id=v_business and action='PS1B_PRICING_ERROR';
  alter table public.products rename column retail_price_cents to retail_price_cents_broken;
  v_price := app.ps1b_catalog_price(v_business,'product',v_product);
  alter table public.products rename column retail_price_cents_broken to retail_price_cents;
  if v_price->>'status'<>'error' then
    raise exception 'g: renamed price column did not fail closed (expected error): %', v_price; end if;
  if coalesce(v_price->>'reason','') !~ '^[0-9A-Za-z]{5}$' then
    raise exception 'g: error reason does not carry a sqlstate: %', v_price; end if;
  if (select count(*) from public.audit_log
        where business_id=v_business and action='PS1B_PRICING_ERROR'
          and entity='ps1b_catalog_price' and entity_id=v_product)<1 then
    raise exception 'g: no PS1B_PRICING_ERROR audit evidence row was written'; end if;
  -- the audit detail carries the sqlstate + inputs, NEVER raw SQL / secrets.
  if not exists(select 1 from public.audit_log
        where business_id=v_business and action='PS1B_PRICING_ERROR' and entity_id=v_product
          and detail ? 'sqlstate' and detail->>'kind'='product' and (detail->>'catalog_id')::uuid=v_product) then
    raise exception 'g: audit detail is not the structured pricing-error evidence'; end if;

  -- ================================================================
  -- End-to-end (h) + executor isolation (i). ONE published config, TWO firing rule
  -- families plus a poison rule, ONE sale, ONE executor sweep under a broken column.
  -- ================================================================
  perform pg_temp.as_v57_principal(v_owner,'authenticated');
  v_draft := (public.create_loyalty_config_draft(v_business,v_base,'v57_rules')::jsonb->>'version_id')::uuid;
  select snapshot_hash into v_hash from public.firm_config_versions where id=v_draft;
  v_ruleX := gen_random_uuid(); v_ruleY := gen_random_uuid(); v_ruleZ := gen_random_uuid();

  -- Rule X: grant_free_item on a real PRODUCT (broken by the column rename at run
  -- time -> priced 'error') + send_notification (must still process - isolation).
  v_res := public.save_program_rule_draft(v_draft, v_ruleX, jsonb_build_object(
    'name','X product free item','when_event','sale.completed','active',true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field','amount_cents','op','gte','value',100)),
    'then_effects', jsonb_build_array(
       jsonb_build_object('effect_type','grant_free_item','catalog_kind','product','catalog_id',v_product),
       jsonb_build_object('effect_type','send_notification','note','thanks')),
    'with_params', jsonb_build_object('budget_period','monthly','entitlement_expiry_days',30)), v_hash);
  v_hash := v_res->>'snapshot_hash';

  -- Rule Y: healthy grant_free_item on the real 1500-cent SERVICE, capped so a
  -- budget reservation is materialised.
  v_res := public.save_program_rule_draft(v_draft, v_ruleY, jsonb_build_object(
    'name','Y service free item','when_event','sale.completed','active',true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field','amount_cents','op','gte','value',100)),
    'then_effects', jsonb_build_array(
       jsonb_build_object('effect_type','grant_free_item','catalog_kind','service','catalog_id',v_service)),
    'with_params', jsonb_build_object('budget_cap_cents',5000,'budget_period','monthly','entitlement_expiry_days',30)), v_hash);
  v_hash := v_res->>'snapshot_hash';

  -- Rule Z: grant_free_item on the real service but with a MALFORMED amount_cents.
  -- Passes PS-1A validation (grant_free_item never parses amount_cents), then raises
  -- inside the executor -> the per-effect subtransaction fails CLOSED.
  v_res := public.save_program_rule_draft(v_draft, v_ruleZ, jsonb_build_object(
    'name','Z malformed effect','when_event','sale.completed','active',true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field','amount_cents','op','gte','value',100)),
    'then_effects', jsonb_build_array(
       jsonb_build_object('effect_type','grant_free_item','catalog_kind','service','catalog_id',v_service,'amount_cents','not-a-number')),
    'with_params', jsonb_build_object('budget_period','monthly','entitlement_expiry_days',30)), v_hash);
  v_hash := v_res->>'snapshot_hash';

  perform public.publish_loyalty_config(v_draft);
  if (select count(*) from public.program_rules_compiled where config_version_id=v_draft and when_event='sale.completed' and rule_id in (v_ruleX,v_ruleY,v_ruleZ))<>3 then
    raise exception 'setup: the three rules did not compile into the executor surface'; end if;

  -- One sale -> one sale.completed event.
  perform public.record_quick_sale(v_business,5000,'cash',v_client,v_owner_staff,v_branch,'v57 e2e','v57-e2e-'||substr(md5(clock_timestamp()::text),1,10),true);
  reset role;
  select event_id into v_evt from public.domain_events
   where business_id=v_business and event_type='sale.completed' and subject_client_id=v_client
   order by recorded_at desc limit 1;
  if v_evt is null then raise exception 'setup: sale.completed event was not produced'; end if;

  -- Sweep with products.retail_price_cents renamed away, so rule X's product price
  -- errors while rule Y's service price is untouched (one statement per branch).
  alter table public.products rename column retail_price_cents to retail_price_cents_broken;
  perform app.run_studio_executor(500);
  alter table public.products rename column retail_price_cents_broken to retail_price_cents;

  -- (h) Rule X priced 'error' -> failed, structured reason, and ZERO promise rows.
  if not exists(select 1 from public.rule_effect_log
        where event_id=v_evt and rule_id=v_ruleX and effect_type='grant_free_item'
          and outcome='failed' and failure_reason is not null) then
    raise exception 'h: rule X grant_free_item did not fail closed'; end if;
  if exists(select 1 from public.program_entitlements where business_id=v_business and rule_id=v_ruleX) then
    raise exception 'h: rule X produced a program_entitlement despite a pricing failure'; end if;
  if exists(select 1 from public.benefit_fulfilments where business_id=v_business and canonical_benefit_key like 'recurring:'||v_ruleX::text||':%') then
    raise exception 'h: rule X produced a benefit_fulfilment despite a pricing failure'; end if;
  if exists(select 1 from public.budget_periods where business_id=v_business and rule_id=v_ruleX) then
    raise exception 'h: rule X produced a budget_period despite a pricing failure'; end if;

  -- (h) Rule X's send_notification effect still processed (sibling isolation).
  if not exists(select 1 from public.event_outbox where event_id=v_evt and consumer='comms') then
    raise exception 'h: rule X send_notification did not enqueue an outbox row (isolation broken)'; end if;
  if not exists(select 1 from public.rule_effect_log
        where event_id=v_evt and rule_id=v_ruleX and effect_type='send_notification' and outcome='notified') then
    raise exception 'h: rule X send_notification effect was not processed'; end if;

  -- (h) Rule Y healthy -> exactly one entitlement + one 1500-cent fulfilment + one
  --     reservation reconciling to the TRUE catalog price (never a silent 0).
  if (select count(*) from public.program_entitlements where business_id=v_business and rule_id=v_ruleY)<>1 then
    raise exception 'h: rule Y did not produce exactly one entitlement'; end if;
  if (select count(*) from public.benefit_fulfilments
        where business_id=v_business and canonical_benefit_key like 'recurring:'||v_ruleY::text||':%'
          and face_value_cents=1500)<>1 then
    raise exception 'h: rule Y did not produce exactly one 1500-cent fulfilment'; end if;
  if (select coalesce(sum(br.amount_cents),0) from public.budget_reservations br
        join public.budget_periods bp on bp.id=br.budget_period_id
       where bp.business_id=v_business and bp.rule_id=v_ruleY)<>1500 then
    raise exception 'h: rule Y reservation does not reconcile to the 1500-cent face'; end if;
  if not exists(select 1 from public.rule_effect_log where event_id=v_evt and rule_id=v_ruleY and outcome='fulfilled') then
    raise exception 'h: rule Y did not log a fulfilled effect'; end if;

  -- (h) No silent-zero anywhere: NO fulfilment in the business carries face 0.
  if exists(select 1 from public.benefit_fulfilments where business_id=v_business and face_value_cents=0) then
    raise exception 'h: a zero-face fulfilment exists (silent-zero regression)'; end if;

  -- (i) Executor subtransaction isolation: rule Z's malformed effect fails CLOSED,
  --     produces NO promise, yet the event still received its execution marker so a
  --     poisoned rule cannot wedge the sweep.
  if not exists(select 1 from public.rule_effect_log
        where event_id=v_evt and rule_id=v_ruleZ and outcome='failed' and failure_reason is not null) then
    raise exception 'i: rule Z malformed effect did not fail closed'; end if;
  if exists(select 1 from public.program_entitlements where business_id=v_business and rule_id=v_ruleZ)
     or exists(select 1 from public.benefit_fulfilments where business_id=v_business and canonical_benefit_key like 'recurring:'||v_ruleZ::text||':%') then
    raise exception 'i: rule Z produced a promise despite failing'; end if;
  if not exists(select 1 from public.domain_event_execution where event_id=v_evt) then
    raise exception 'i: a poisoned rule wedged the event execution marker'; end if;

  raise notice 'v57 PS-1B.1 catalog-pricing-fails-closed suite: ALL PASS';
end $v57_test$;

reset role;
rollback;
