-- Rollback-only v656 acceptance suite (owner photo 3, 2026-08-31).
--
-- T1  A discount that names no item still takes its percentage off the WHOLE bill — v370's
--     contract, unchanged, which is what every discount configured before v656 relies on.
-- T2  A discount that names items takes its percentage off THOSE LINES only.
-- T3  A cart containing none of the named items is not discounted at all.
-- T4  A LIMITED discount is still never applied automatically (v370's reasoning: an allowance
--     that is spent must be counted, and the automatic path counts nothing).
-- T5  ...but it applies when the counter chooses it, and is flagged so record_cart_sale spends
--     the allowance in the same transaction that takes the money.
-- T6  A perk whose allowance is gone is REFUSED by the pricing authority, rather than quietly
--     discounting a bill that nothing will be counted against.
-- T7  A scoped discount names its items in its own wording; an unscoped one keeps the short form.
--
-- Run after the complete canonical chain through v656, in a disposable database or as a
-- rolled-back transaction against a prod-shaped instance. Substitute your own business, tier,
-- service and client ids for the literals below.
begin;
-- Fixtures live inside the rolled-back transaction: a Gold-tier discount at Jess Salon, scoped in
-- one case and blanket in the other, and a client who has actually reached Gold.
create temporary table v656_evidence(test text) on commit drop;
do $fx$
declare
  v_biz uuid := '709387ff-5768-4767-9dad-abd665c2bb07';
  v_tier uuid := '53205338-5ccf-4f73-957c-0f19ca1dbcf4';   -- Gold, threshold 1
  v_cut_director uuid := '864f3390-5a42-43ec-85f8-d568eca7c52e';  -- 60.00
  v_cut_junior  uuid := '9d3ef69f-4f3b-4085-bd82-90931559ec92';  -- 15.00
  v_client uuid;
  v_branch uuid;
  v_blanket uuid; v_scoped uuid; v_limited uuid;
  v_plan jsonb; v_eff jsonb; v_amt int; v_tierlabel text;
begin
  select id into v_client from public.clients where business_id=v_biz limit 1;
  select id into v_branch from public.branches where business_id=v_biz and active limit 1;
  if v_client is null or v_branch is null then raise exception 'FIXTURE: need a client and a branch'; end if;

  -- The client must be AT Gold for any of these to be offered. v365_client_tier reads visits;
  -- rather than fake visits, assert we are testing with a client who qualifies.
  if coalesce((app.v365_client_tier(v_biz, v_client)).threshold, -1) < 1 then
    raise exception 'FIXTURE: the sample client has not reached Gold, so nothing below was proved';
  end if;

  -- Clear any live discount benefits so the fixtures are the only candidates.
  update public.tier_benefits_v365 set deleted_at=now(), active=false
   where business_id=v_biz and benefit_kind='discount_pct' and deleted_at is null;

  -- (a) BLANKET, unlimited: the v370 contract, which must not move.
  insert into public.tier_benefits_v365(business_id,tier_id,label,limit_count,limit_period,sort,
    benefit_kind,discount_percent)
  values(v_biz,v_tier,'10% off',null,'month',0,'discount_pct',10) returning id into v_blanket;

  v_plan := app.ps1c_plan_checkout(v_biz, v_branch, v_client,
    jsonb_build_array(
      jsonb_build_object('catalog_kind','service','catalog_id',v_cut_director,'qty',1),
      jsonb_build_object('catalog_kind','service','catalog_id',v_cut_junior,'qty',1)),
    null, null);
  if v_plan->>'status' <> 'ok' then raise exception 'T1 plan failed: %', v_plan; end if;
  select e into v_eff from jsonb_array_elements(v_plan->'applied_effects') e
   where e->>'source'='tier_benefit' limit 1;
  if v_eff is null then raise exception 'T1 the blanket discount did not apply'; end if;
  -- 6000 + 1500 = 7500; 10% of the whole bill = 750
  if (v_eff->>'amount_cents')::int <> 750 then
    raise exception 'T1 blanket discount should be 750 off 7500, got %', v_eff->>'amount_cents'; end if;
  if (v_eff->>'tier_benefit_scoped')::boolean then raise exception 'T1 must not be marked scoped'; end if;
  if (v_eff->>'tier_benefit_limited')::boolean then raise exception 'T1 must not be marked limited'; end if;
  insert into v656_evidence values('T1 ok — a blanket discount still takes 10 percent of the whole bill (750 of 7500)');

  -- (b) SCOPED to the Director cut only.
  insert into public.tier_benefit_scope_v656(business_id,benefit_id,service_id)
  values(v_biz,v_blanket,v_cut_director);
  v_plan := app.ps1c_plan_checkout(v_biz, v_branch, v_client,
    jsonb_build_array(
      jsonb_build_object('catalog_kind','service','catalog_id',v_cut_director,'qty',1),
      jsonb_build_object('catalog_kind','service','catalog_id',v_cut_junior,'qty',1)),
    null, null);
  if v_plan->>'status' <> 'ok' then raise exception 'T2 plan failed: %', v_plan; end if;
  select e into v_eff from jsonb_array_elements(v_plan->'applied_effects') e
   where e->>'source'='tier_benefit' limit 1;
  if v_eff is null then raise exception 'T2 the scoped discount did not apply'; end if;
  -- 10% of the 6000 Director line ONLY = 600, not 750
  if (v_eff->>'amount_cents')::int <> 600 then
    raise exception 'T2 scoped discount should be 600 (10%% of the 6000 line), got %', v_eff->>'amount_cents'; end if;
  if not (v_eff->>'tier_benefit_scoped')::boolean then raise exception 'T2 must be marked scoped'; end if;
  insert into v656_evidence values('T2 ok — a scoped discount takes 10 percent of its own line only (600, not 750)');

  -- (c) A line the discount does not name gets nothing at all.
  v_plan := app.ps1c_plan_checkout(v_biz, v_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',v_cut_junior,'qty',1)),
    null, null);
  select e into v_eff from jsonb_array_elements(v_plan->'applied_effects') e
   where e->>'source'='tier_benefit' limit 1;
  if v_eff is not null then
    raise exception 'T3 a cart with none of the named items must get no discount, got %', v_eff; end if;
  insert into v656_evidence values('T3 ok — a cart without the named item is not discounted');

  -- (d) A LIMITED discount is still never automatic...
  update public.tier_benefits_v365 set deleted_at=now(), active=false where id=v_blanket;
  insert into public.tier_benefits_v365(business_id,tier_id,label,limit_count,limit_period,sort,
    benefit_kind,discount_percent)
  values(v_biz,v_tier,'20% off',1,'month',1,'discount_pct',20) returning id into v_limited;
  v_plan := app.ps1c_plan_checkout(v_biz, v_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',v_cut_director,'qty',1)),
    null, null);
  select e into v_eff from jsonb_array_elements(v_plan->'applied_effects') e
   where e->>'source'='tier_benefit' limit 1;
  if v_eff is not null then raise exception 'T4 a limited discount must never apply automatically'; end if;
  insert into v656_evidence values('T4 ok — a limited discount is still never applied on its own');

  -- ...but it applies when the counter chooses it.
  v_plan := app.ps1c_plan_checkout(v_biz, v_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',v_cut_director,'qty',1)),
    null, v_limited);
  if v_plan->>'status' <> 'ok' then raise exception 'T5 plan failed: %', v_plan; end if;
  select e into v_eff from jsonb_array_elements(v_plan->'applied_effects') e
   where e->>'source'='tier_benefit' limit 1;
  if v_eff is null then raise exception 'T5 the chosen discount did not apply'; end if;
  if (v_eff->>'amount_cents')::int <> 1200 then
    raise exception 'T5 expected 1200 (20%% of 6000), got %', v_eff->>'amount_cents'; end if;
  if not (v_eff->>'tier_benefit_limited')::boolean then
    raise exception 'T5 must be flagged limited so record_cart_sale spends the allowance'; end if;
  insert into v656_evidence values('T5 ok — the chosen limited discount takes 20 percent (1200) and is flagged for counting');

  -- ...and once the allowance is gone the plan refuses rather than discounting for free.
  insert into public.tier_benefit_issues_v365(business_id,benefit_id,client_id,tier_id,label,
    limit_count,limit_period,period_key,branch_id,issued_by,idem_key)
  values(v_biz,v_limited,v_client,v_tier,'20% off',1,'month',
    app.v365_period_key('month',now()),v_branch,null,gen_random_uuid());
  v_plan := app.ps1c_plan_checkout(v_biz, v_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',v_cut_director,'qty',1)),
    null, v_limited);
  if v_plan->>'status' <> 'tier_benefit_used_up' then
    raise exception 'T6 a spent perk must be refused, got %', v_plan->>'status'; end if;
  insert into v656_evidence values('T6 ok — a spent perk is refused instead of discounting for free');

  -- (e) The wording names the items.
  insert into public.tier_benefit_scope_v656(business_id,benefit_id,service_id)
  values(v_biz,v_limited,v_cut_director);
  select app.v656_discount_label(20, app.v656_scope_names(v_limited)) into v_tierlabel;
  if v_tierlabel <> '20% off Hair Cut (Director)' then
    raise exception 'T7 expected "20%% off Hair Cut (Director)", got "%"', v_tierlabel; end if;
  if app.v656_discount_label(10, '{}'::text[]) <> '10% off' then
    raise exception 'T7 an unscoped discount must keep its short wording'; end if;
  insert into v656_evidence values('T7 ok — a scoped discount names its items, an unscoped one does not');
end $fx$;
select (select count(*) from v656_evidence) as assertions_passed,
       (select string_agg(test, ' | ' order by test) from v656_evidence) as evidence,
       case when (select count(*) from v656_evidence)=7 then 'V656_SUITE_PASSED' else 'V656_SUITE_INCOMPLETE' end as verdict;


-- =============================================================================================
-- E2E — THE WHOLE POINT, END TO END: the money and the allowance move together.
-- The seven assertions above prove the pricing arithmetic. These prove the thing the owner
-- actually asked for — that "using" the voucher deducts from the bill — through the real
-- evaluate_checkout -> record_cart_sale path rather than the plan function alone:
--   E2E-1  the same cart without the perk is quoted at full price (6000)
--   E2E-2  with the perk the counter chose, it is quoted at 4800
--   E2E-3  PRICING alone spends nothing — quoting a discount is not using it
--   E2E-5  the finalised SALE is recorded at 4800, not 6000
--   E2E-6  the allowance is spent exactly once, in the same transaction as the sale
--   E2E-7  the receipt carries the -1200 tier benefit line
-- Proven rolled-back against production on 2026-08-31 before v656 was applied.
-- =============================================================================================
do $fx$
declare v_client uuid;
begin
  select id into v_client from public.clients where business_id='709387ff-5768-4767-9dad-abd665c2bb07' limit 1;
  if coalesce((app.v365_client_tier('709387ff-5768-4767-9dad-abd665c2bb07', v_client)).threshold,-1) < 1 then
    raise exception 'E2E fixture: the sample client is below Gold, so nothing below would be proved';
  end if;
end $fx$;
-- The benefit fixture is seeded with RLS out of the way; tier_benefits_v365 is written only by
-- business_set_tier_benefits_v365 (SECURITY DEFINER) in production.
do $fx2$
declare v_perk uuid;
begin
  update public.tier_benefits_v365 set deleted_at=now(), active=false
   where business_id='709387ff-5768-4767-9dad-abd665c2bb07'
     and benefit_kind='discount_pct' and deleted_at is null;
  insert into public.tier_benefits_v365(business_id,tier_id,label,limit_count,limit_period,sort,
    benefit_kind,discount_percent)
  values('709387ff-5768-4767-9dad-abd665c2bb07','53205338-5ccf-4f73-957c-0f19ca1dbcf4',
    '20% off',1,'month',0,'discount_pct',20) returning id into v_perk;
end $fx2$;
set local role authenticated;
set local request.jwt.claims = '{"sub":"b8ba53b5-b20d-4d6d-b6fe-66f014758fab","role":"authenticated"}';
do $e2e$
declare
  v_biz uuid := '709387ff-5768-4767-9dad-abd665c2bb07';
  v_tier uuid := '53205338-5ccf-4f73-957c-0f19ca1dbcf4';
  v_svc uuid := '864f3390-5a42-43ec-85f8-d568eca7c52e';   -- Hair Cut (Director), 60.00
  v_client uuid; v_branch uuid; v_perk uuid;
  v_eval jsonb; v_sale json; v_total int; v_issues int; v_line int;
begin
  select id into v_client from public.clients where business_id=v_biz limit 1;
  select id into v_branch from public.branches where business_id=v_biz and active limit 1;
  -- The tier check itself is app-schema and not granted to `authenticated`; the pricing
  -- authority calls it as definer. Fixture-check it before dropping into the customer role.

  select id into v_perk from public.tier_benefits_v365
   where business_id=v_biz and benefit_kind='discount_pct' and deleted_at is null and active
     and limit_count=1 and discount_percent=20 limit 1;
  if v_perk is null then raise exception 'E2E fixture: the 20%% limited perk was not seeded'; end if;

  -- Price the cart WITHOUT the perk first: the limited discount must not apply on its own.
  v_eval := public.evaluate_checkout(v_biz, v_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',v_svc,'qty',1)),
    gen_random_uuid());
  if (v_eval->>'total_cents')::int <> 6000 then
    raise exception 'E2E-1 expected the undiscounted 6000, got %', v_eval->>'total_cents'; end if;

  -- Now price it WITH the perk the counter chose.
  v_eval := public.evaluate_checkout(v_biz, v_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',v_svc,'qty',1)),
    gen_random_uuid(), v_perk);
  if (v_eval->>'total_cents')::int <> 4800 then
    raise exception 'E2E-2 expected 4800 after 20%% off 6000, got %', v_eval->>'total_cents'; end if;
  raise notice 'E2E-2 ok — evaluate_checkout quotes 4800 instead of 6000';

  select count(*) into v_issues from public.tier_benefit_issues_v365
   where benefit_id=v_perk and client_id=v_client;
  if v_issues <> 0 then raise exception 'E2E-3 pricing must not spend the allowance on its own'; end if;

  -- Finalise. The money and the allowance must move together.
  v_sale := public.record_cart_sale(v_biz, v_client, v_branch, null, 'cash',
    gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',v_svc,'qty',1)),
    (v_eval->>'evaluation_id')::uuid, true, now(), null);
  if v_sale->>'status' not in ('ok','recorded') then
    raise exception 'E2E-4 finalise failed: %', v_sale; end if;

  select amount_cents into v_total from public.sales where id=(v_sale->>'sale_id')::uuid;
  if v_total <> 4800 then
    raise exception 'E2E-5 the SALE must be recorded at the discounted 4800, got %', v_total; end if;
  raise notice 'E2E-5 ok — the sale is recorded at 4800';

  select count(*) into v_issues from public.tier_benefit_issues_v365
   where benefit_id=v_perk and client_id=v_client
     and period_key=to_char(now() at time zone 'Asia/Singapore','YYYY-MM');
  if v_issues <> 1 then
    raise exception 'E2E-6 the allowance must be spent exactly once, got % issue rows', v_issues; end if;
  raise notice 'E2E-6 ok — the allowance was spent exactly once, in the same transaction';

  select line_cents into v_line from public.sale_items
   where sale_id=(v_sale->>'sale_id')::uuid and item_type='studio_discount' limit 1;
  if v_line <> -1200 then
    raise exception 'E2E-7 the receipt must carry a -1200 discount line, got %', v_line; end if;
  raise notice 'E2E-7 ok — the receipt carries the -1200 tier benefit line';
end $e2e$;
select 'V656_E2E_PASSED' as verdict;

rollback;
