-- Rollback-only acceptance for v370 — the automatic tier discount, inside the pricing authority.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v370_tier_discount_at_checkout.sql
-- Any outcome starting with FAIL is a failure.

begin;

create temp table _r(check_name text, outcome text) on commit drop;
create temp table _ctx(business uuid, owner_user uuid, branch uuid, client uuid,
                       tier uuid, benefit uuid, product uuid, unit int, kind text) on commit drop;
grant select, insert, update on _r, _ctx to authenticated;

insert into _ctx(business, owner_user)
select b.id, s.user_id from public.businesses b
  join public.staff s on s.business_id=b.id and s.role='owner' and s.user_id is not null
 where b.name ilike '%cubbly%' limit 1;
update _ctx set branch=(select id from public.branches where business_id=(select business from _ctx) and active limit 1);
update _ctx set client=(select id from public.clients where business_id=(select business from _ctx) limit 1);
update _ctx set tier=(select id from public.loyalty_tiers where business_id=(select business from _ctx)
  order by threshold asc limit 1);
/* A priced catalogue line to price. Products first, services second — this tenant sells
   services only, and the planner takes either kind. */
update _ctx set product=(select id from public.products where business_id=(select business from _ctx) and active limit 1);
update _ctx set unit=(select coalesce(retail_price_cents,0) from public.products where id=(select product from _ctx));
update _ctx set kind='product' where product is not null;
update _ctx set product=(select id from public.services where business_id=(select business from _ctx) and active limit 1),
                unit=(select coalesce(price_cents,0) from public.services where business_id=(select business from _ctx) and active limit 1),
                kind='service'
 where product is null or coalesce(unit,0)<=0;

-- A 25% unlimited discount on the LOWEST rung, so any client with a tier qualifies.
with made as (
  insert into public.tier_benefits_v365(business_id,tier_id,label,benefit_kind,discount_percent,limit_count,limit_period,sort)
  values((select business from _ctx),(select tier from _ctx),'25% off','discount_pct',25,null,'month',900)
  returning id)
update _ctx set benefit=(select id from made);

-- ---------------------------------------------------------------------------
-- The planner, called directly.
-- ---------------------------------------------------------------------------
do $$
declare
  v_lines jsonb;
  v_plan jsonb;
  v_plan_walkin jsonb;
  v_config uuid;
  v_eff jsonb;
  v_expected int;
begin
  if (select product from _ctx) is null or coalesce((select unit from _ctx),0) <= 0 then
    insert into _r select 'planner skipped — this tenant has no priced product', 'PASS (not exercised)';
    return;
  end if;
  select active_config_version_id into v_config from public.businesses where id=(select business from _ctx);
  /* The planner's own line contract: catalog_kind + catalog_id + qty, nothing priced by the
     caller (it refuses a client-priced line outright). */
  v_lines := jsonb_build_array(jsonb_build_object(
    'catalog_kind',(select kind from _ctx),'catalog_id',(select product from _ctx),'qty',1));

  v_plan := app.ps1c_plan_checkout((select business from _ctx),(select branch from _ctx),
    (select client from _ctx), v_lines, v_config);
  insert into _r select 'the planner still prices the cart',
    case when v_plan->>'status'='ok' then 'PASS' else 'FAIL ' || coalesce(v_plan->>'status','<null>') end;

  if v_plan->>'status'='ok' then
    v_expected := round((v_plan->>'subtotal_cents')::numeric * 0.25)::int;
    insert into _r select 'a 25% tier discount comes off the bill',
      case when (v_plan->>'discount_total_cents')::int >= v_expected then 'PASS'
           else 'FAIL discount ' || (v_plan->>'discount_total_cents') || ' expected at least ' || v_expected end;
    insert into _r select 'the total is the subtotal minus the discount',
      case when (v_plan->>'total_cents')::int = (v_plan->>'subtotal_cents')::int - (v_plan->>'discount_total_cents')::int
           then 'PASS' else 'FAIL the arithmetic does not close' end;
    select e into v_eff from jsonb_array_elements(v_plan->'applied_effects') e where e->>'source'='tier_benefit';
    insert into _r select 'the effect names the benefit it came from and carries no rule',
      case when v_eff is not null and v_eff->>'rule_id' is null
            and (v_eff->>'tier_benefit_id')::uuid = (select benefit from _ctx)
            and v_eff->>'label' = '25% off'
           then 'PASS' else 'FAIL ' || coalesce(v_eff::text,'<no tier effect>') end;
  end if;

  -- A walk-in has no client and therefore no tier.
  v_plan_walkin := app.ps1c_plan_checkout((select business from _ctx),(select branch from _ctx),
    null, v_lines, v_config);
  insert into _r select 'a walk-in gets no tier discount',
    case when not exists (select 1 from jsonb_array_elements(coalesce(v_plan_walkin->'applied_effects','[]'::jsonb)) e
                           where e->>'source'='tier_benefit')
         then 'PASS' else 'FAIL a customerless sale was discounted' end;

  -- A LIMITED discount must never auto-apply: it has to be counted, which only Give does.
  update public.tier_benefits_v365 set limit_count=1 where id=(select benefit from _ctx);
  v_plan := app.ps1c_plan_checkout((select business from _ctx),(select branch from _ctx),
    (select client from _ctx), v_lines, v_config);
  insert into _r select 'a limited discount is not applied automatically',
    case when not exists (select 1 from jsonb_array_elements(coalesce(v_plan->'applied_effects','[]'::jsonb)) e
                           where e->>'source'='tier_benefit')
         then 'PASS' else 'FAIL a counted benefit was spent silently' end;
  update public.tier_benefits_v365 set limit_count=null where id=(select benefit from _ctx);

  -- The best single percentage, never the sum of two.
  insert into public.tier_benefits_v365(business_id,tier_id,label,benefit_kind,discount_percent,limit_count,limit_period,sort)
  values((select business from _ctx),(select tier from _ctx),'5% off','discount_pct',5,null,'month',901);
  v_plan := app.ps1c_plan_checkout((select business from _ctx),(select branch from _ctx),
    (select client from _ctx), v_lines, v_config);
  insert into _r select 'two discounts on one ladder do not stack — the best one wins',
    case when (select count(*) from jsonb_array_elements(coalesce(v_plan->'applied_effects','[]'::jsonb)) e
                where e->>'source'='tier_benefit') = 1
          and (select (e->>'discount_pct')::numeric from jsonb_array_elements(v_plan->'applied_effects') e
                where e->>'source'='tier_benefit') = 25
         then 'PASS' else 'FAIL more than one, or the wrong one, applied' end;
end $$;

-- ---------------------------------------------------------------------------
-- END TO END, as real staff: price it, sell it, and check what was written.
-- This is the assertion that matters — a planner that discounts but a sale that
-- charges full price would be worse than no discount at all.
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner_user from _ctx),'role','authenticated')::text, true);

do $$
declare
  v_lines jsonb; v_eval jsonb; v_sale json; v_sale_id uuid; v_amount int; v_expected int;
begin
  if (select product from _ctx) is null or coalesce((select unit from _ctx),0) <= 0 then
    insert into _r select 'end to end skipped — no priced catalogue line', 'PASS (not exercised)';
    return;
  end if;
  v_lines := jsonb_build_array(jsonb_build_object(
    'catalog_kind',(select kind from _ctx),'catalog_id',(select product from _ctx),'qty',1));

  v_eval := public.evaluate_checkout((select business from _ctx),(select branch from _ctx),
    (select client from _ctx), v_lines, gen_random_uuid());
  insert into _r select 'evaluate_checkout returns a discounted quote',
    case when v_eval->>'status'='ok' and (v_eval->>'discount_total_cents')::int > 0
         then 'PASS' else 'FAIL ' || coalesce(v_eval::text,'<null>') end;
  if v_eval->>'status' <> 'ok' then return; end if;
  v_expected := (v_eval->>'total_cents')::int;

  v_sale := public.record_cart_sale((select business from _ctx),(select client from _ctx),
    (select branch from _ctx), null, 'cash', gen_random_uuid()::text, v_lines,
    (v_eval->>'evaluation_id')::uuid, true);
  v_sale_id := ((v_sale->'sale')->>'id')::uuid;

  select amount_cents into v_amount from public.sales where id=v_sale_id;
  insert into _r select 'the SALE is recorded at the discounted total, not the list price',
    case when v_amount = v_expected then 'PASS'
         else 'FAIL sale ' || coalesce(v_amount::text,'<null>') || ' vs quote ' || v_expected end;

  insert into _r select 'the discount is on the receipt as its own signed line',
    case when exists (select 1 from public.sale_items
                       where sale_id=v_sale_id and item_type='studio_discount'
                         and description like 'Tier benefit:%' and line_cents < 0)
         then 'PASS' else 'FAIL no tier-benefit line on the sale' end;

  insert into _r select 'no fabricated Studio provenance row was written',
    case when not exists (select 1 from public.checkout_discount_lines
                           where sale_id=v_sale_id and rule_id is null)
         then 'PASS' else 'FAIL a ruleless row reached the Studio registry' end;

  insert into _r select 'the fulfilment registry records the tier discount',
    case when exists (select 1 from public.benefit_fulfilments
                       where detail_ref=v_sale_id and canonical_benefit_key like 'tierdiscount:%')
         then 'PASS' else 'FAIL the discount left no fulfilment record' end;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- Provenance: the finaliser must not write a Studio row for a ruleless effect.
-- ---------------------------------------------------------------------------
insert into _r select 'the finaliser guards the Studio provenance insert',
  case when position('if v_rule is not null then' in pg_get_functiondef(p.oid)) > 0
        and position('Tier benefit: ' in pg_get_functiondef(p.oid)) > 0
       then 'PASS' else 'FAIL record_cart_sale does not special-case a ruleless effect' end
  from pg_proc p
 where p.proname='record_cart_sale'
   and position('checkout_discount_lines' in pg_get_functiondef(p.oid)) > 0;

insert into _r select 'reverse_sale and the discount report were not touched',
  case when (select count(*) from pg_proc where proname in ('reverse_sale','get_checkout_discount_report')
              and position('tier_benefit' in pg_get_functiondef(oid)) > 0) = 0
       then 'PASS' else 'FAIL a reporting path was quietly changed' end;

select check_name, outcome from _r order by check_name;

rollback;
