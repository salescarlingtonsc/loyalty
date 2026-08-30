-- Rollback-only v657 acceptance suite (owner ruling 2026-08-31).
--
-- A tier discount is one of exactly two shapes, and this proves both plus the boundaries:
--   T1  WHOLE BILL, uncapped -- v370/v656 behaviour, unmoved.
--   T2  WHOLE BILL with a money ceiling -- the owner's "10% off, capped at $20".
--   T3  ONE ITEM -- the crux. Two eligible lines are on the bill (60.00 and 30.00) and the
--       discount takes 10%% of the DEARER one only (600), where v656 would have taken 10%% of both
--       (900). This is the owner's ruling: "only allow for 1 item (even though selected multiple)",
--       landing on the highest-priced eligible item.
--   T4  A bill carrying none of the eligible items is not discounted at all.
--   T5  A perk chosen by hand with nothing eligible on the bill is REFUSED with a typed status,
--       so the till can say why rather than quoting a discount that never arrives.
--   T6  The wording states the shape and any ceiling.
--
-- Run after the complete canonical chain through v657, in a disposable database or as a
-- rolled-back transaction against a prod-shaped instance. Substitute your own business, tier,
-- service and client ids for the literals below.
begin;
create temporary table v657_evidence(test text) on commit drop;
do $fx$
declare
  v_biz uuid := '709387ff-5768-4767-9dad-abd665c2bb07';
  v_tier uuid := '53205338-5ccf-4f73-957c-0f19ca1dbcf4';   -- Gold, threshold 1
  v_dir uuid := '864f3390-5a42-43ec-85f8-d568eca7c52e';    -- Hair Cut (Director)  60.00
  v_jun uuid := '9d3ef69f-4f3b-4085-bd82-90931559ec92';    -- Hair Cut (Junior)    15.00
  v_sen uuid := 'a70e0c6a-a7fd-457a-a6d8-a50821e5616d';    -- Hair Cut (Senior)    30.00
  v_client uuid; v_branch uuid; v_perk uuid; v_plan jsonb; v_eff jsonb;
  v_cart jsonb;
begin
  select id into v_client from public.clients where business_id=v_biz limit 1;
  select id into v_branch from public.branches where business_id=v_biz and active limit 1;
  if coalesce((app.v365_client_tier(v_biz, v_client)).threshold,-1) < 1 then
    raise exception 'FIXTURE: the sample client has not reached Gold, so nothing below is proved'; end if;

  v_cart := jsonb_build_array(
    jsonb_build_object('catalog_kind','service','catalog_id',v_dir,'qty',1),
    jsonb_build_object('catalog_kind','service','catalog_id',v_sen,'qty',1),
    jsonb_build_object('catalog_kind','service','catalog_id',v_jun,'qty',1));  -- 60 + 30 + 15 = 105

  update public.tier_benefits_v365 set deleted_at=now(), active=false
   where business_id=v_biz and benefit_kind='discount_pct' and deleted_at is null;

  -- ---- (1) WHOLE BILL, uncapped: v370's contract, which must not move. ----
  insert into public.tier_benefits_v365(business_id,tier_id,label,limit_count,limit_period,sort,
    benefit_kind,discount_percent,discount_scope)
  values(v_biz,v_tier,'10% off',null,'month',0,'discount_pct',10,'bill') returning id into v_perk;
  v_plan := app.ps1c_plan_checkout(v_biz,v_branch,v_client,v_cart,null,null);
  select e into v_eff from jsonb_array_elements(v_plan->'applied_effects') e where e->>'source'='tier_benefit';
  if (v_eff->>'amount_cents')::int <> 1050 then
    raise exception 'T1 expected 1050 (10 percent of 10500), got %', v_eff->>'amount_cents'; end if;
  if v_eff->>'tier_benefit_mode' <> 'bill' then raise exception 'T1 mode must be bill'; end if;
  insert into v657_evidence values('T1 ok - a whole-bill discount still takes 10 percent of the whole bill (1050 of 10500)');

  -- ---- (2) WHOLE BILL with a money cap. ----
  update public.tier_benefits_v365 set max_discount_cents=500 where id=v_perk;
  v_plan := app.ps1c_plan_checkout(v_biz,v_branch,v_client,v_cart,null,null);
  select e into v_eff from jsonb_array_elements(v_plan->'applied_effects') e where e->>'source'='tier_benefit';
  if (v_eff->>'amount_cents')::int <> 500 then
    raise exception 'T2 the cap must hold the discount at 500, got %', v_eff->>'amount_cents'; end if;
  if not (v_eff->>'tier_benefit_capped')::boolean then raise exception 'T2 must be flagged capped'; end if;
  insert into v657_evidence values('T2 ok - a capped whole-bill discount stops at its ceiling (500, not 1050)');

  -- ---- (3) ONE ITEM: the highest-priced ELIGIBLE line, not every eligible line. ----
  update public.tier_benefits_v365 set discount_scope='item', max_discount_cents=null where id=v_perk;
  insert into public.tier_benefit_scope_v656(business_id,benefit_id,service_id)
  values(v_biz,v_perk,v_dir),(v_biz,v_perk,v_sen);   -- Director 60 AND Senior 30 are eligible
  v_plan := app.ps1c_plan_checkout(v_biz,v_branch,v_client,v_cart,null,null);
  select e into v_eff from jsonb_array_elements(v_plan->'applied_effects') e where e->>'source'='tier_benefit';
  -- v656 would have taken 10% of 60+30 = 900. The owner's rule is ONE item: 10% of the dearest, 600.
  if (v_eff->>'amount_cents')::int <> 600 then
    raise exception 'T3 expected 600 (10 percent of the dearest eligible line, 6000), got %', v_eff->>'amount_cents'; end if;
  if v_eff->>'tier_benefit_mode' <> 'item' then raise exception 'T3 mode must be item'; end if;
  if v_eff->>'tier_benefit_item' <> 'Hair Cut (Director)' then
    raise exception 'T3 must name the line it landed on, got %', v_eff->>'tier_benefit_item'; end if;
  insert into v657_evidence values('T3 ok - one item only: 600 off the dearest eligible line, not 900 off both');

  -- ---- (4) Nothing eligible on the bill -> nothing comes off. ----
  v_plan := app.ps1c_plan_checkout(v_biz,v_branch,v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',v_jun,'qty',1)),null,null);
  select e into v_eff from jsonb_array_elements(v_plan->'applied_effects') e where e->>'source'='tier_benefit';
  if v_eff is not null then raise exception 'T4 a bill with no eligible item must not be discounted'; end if;
  insert into v657_evidence values('T4 ok - a bill carrying none of the eligible items is not discounted');

  -- ---- (5) A hand-applied item perk with nothing eligible is REFUSED, with a reason. ----
  update public.tier_benefits_v365 set limit_count=1 where id=v_perk;
  v_plan := app.ps1c_plan_checkout(v_biz,v_branch,v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',v_jun,'qty',1)),null,v_perk);
  if v_plan->>'status' <> 'tier_benefit_no_eligible_item' then
    raise exception 'T5 expected tier_benefit_no_eligible_item, got %', v_plan->>'status'; end if;
  insert into v657_evidence values('T5 ok - a perk chosen by hand with nothing eligible is refused, not silently ignored');

  -- ---- (6) The wording. ----
  if app.v657_discount_label(10,'bill',null) <> '10% off' then raise exception 'T6a'; end if;
  if app.v657_discount_label(10,'bill',2000) <> '10% off, up to 20.00' then
    raise exception 'T6b got "%"', app.v657_discount_label(10,'bill',2000); end if;
  if app.v657_discount_label(10,'item',null) <> '10% off one item' then
    raise exception 'T6c got "%"', app.v657_discount_label(10,'item',null); end if;
  insert into v657_evidence values('T6 ok - the wording states the shape and any ceiling');
end $fx$;
select (select count(*) from v657_evidence) as assertions_passed,
       (select string_agg(test, ' | ' order by test) from v657_evidence) as evidence,
       case when (select count(*) from v657_evidence)=6 then 'V657_SUITE_PASSED' else 'V657_SUITE_INCOMPLETE' end as verdict;

rollback;
