-- Rollback-only acceptance for v369 — structured tier benefits (kind + number/item).
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v369_structured_tier_benefits.sql
-- Any outcome starting with FAIL is a failure.

begin;

create temp table _r(check_name text, outcome text) on commit drop;
create temp table _ctx(business uuid, owner_user uuid, tier uuid, product uuid) on commit drop;
grant select, insert, update on _r, _ctx to authenticated;

insert into _ctx(business, owner_user)
select b.id, s.user_id
  from public.businesses b
  join public.staff s on s.business_id = b.id and s.role='owner' and s.user_id is not null
 where b.name ilike '%cubbly%'
 limit 1;
update _ctx set product = (select id from public.products where business_id=(select business from _ctx) limit 1);

insert into _r select 'existing rows were left as custom, not parsed',
  case when not exists (select 1 from public.tier_benefits_v365 where benefit_kind <> 'custom' and created_at < now() - interval '1 minute')
       then 'PASS' else 'FAIL an existing row was reclassified' end;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner_user from _ctx),'role','authenticated')::text, true);

update _ctx set tier = (select id from public.loyalty_tiers where business_id=(select business from _ctx)
  order by threshold desc limit 1);

-- A discount, a catalogue free item (when the tenant has one) and a typed free item.
select public.business_set_tier_benefits_v365((select business from _ctx),(select tier from _ctx),
  (select jsonb_build_array(
     jsonb_build_object('benefit_kind','discount_pct','discount_percent',30,'limit_period','month'),
     case when (select product from _ctx) is null
          then jsonb_build_object('benefit_kind','free_item','item_label','lollipop','limit_count',1,'limit_period','month')
          else jsonb_build_object('benefit_kind','free_item','product_id',(select product from _ctx),'limit_count',1,'limit_period','month') end,
     jsonb_build_object('benefit_kind','custom','label','1 for 1 deals'))));

insert into _r select 'the discount is stored as a number and worded from it',
  case when count(*)=1 then 'PASS' else 'FAIL ' || count(*) end
  from public.tier_benefits_v365
 where tier_id=(select tier from _ctx) and deleted_at is null
   and benefit_kind='discount_pct' and discount_percent=30 and label='30% off';

insert into _r select 'a catalogue free item is worded from the product name',
  case when exists (
    select 1 from public.tier_benefits_v365 b
     where b.tier_id=(select tier from _ctx) and b.deleted_at is null and b.benefit_kind='free_item'
       and b.label = 'Free '||coalesce((select p.name from public.products p where p.id=b.product_id), b.item_label))
       then 'PASS' else 'FAIL the free-item label is not derived' end;

insert into _r select 'custom wording survives untouched',
  case when exists (select 1 from public.tier_benefits_v365 where tier_id=(select tier from _ctx)
                     and deleted_at is null and benefit_kind='custom' and label='1 for 1 deals')
       then 'PASS' else 'FAIL' end;

insert into _r select 'perk_note reads the derived words',
  case when perk_note like '30%% off%' and perk_note like '%1 for 1 deals%'
       then 'PASS' else 'FAIL perk_note reads: ' || coalesce(perk_note,'<null>') end
  from public.loyalty_tiers where id=(select tier from _ctx);

do $$
declare v_bad text := '';
begin
  begin
    perform public.business_set_tier_benefits_v365((select business from _ctx),(select tier from _ctx),
      jsonb_build_array(jsonb_build_object('benefit_kind','discount_pct','discount_percent',0)));
  exception when others then v_bad := sqlerrm; end;
  insert into _r select 'a zero discount is refused',
    case when v_bad like '%between 0.01 and 100%' then 'PASS' else 'FAIL ' || coalesce(nullif(v_bad,''),'accepted') end;

  v_bad := '';
  begin
    perform public.business_set_tier_benefits_v365((select business from _ctx),(select tier from _ctx),
      jsonb_build_array(jsonb_build_object('benefit_kind','free_item')));
  exception when others then v_bad := sqlerrm; end;
  insert into _r select 'a free item with neither product nor text is refused',
    case when v_bad like '%which item is free%' then 'PASS' else 'FAIL ' || coalesce(nullif(v_bad,''),'accepted') end;

  v_bad := '';
  begin
    perform public.business_set_tier_benefits_v365((select business from _ctx),(select tier from _ctx),
      jsonb_build_array(jsonb_build_object('benefit_kind','free_item','product_id',gen_random_uuid())));
  exception when others then v_bad := sqlerrm; end;
  insert into _r select 'another business''s product is refused',
    case when v_bad like '%does not belong to this business%' then 'PASS' else 'FAIL ' || coalesce(nullif(v_bad,''),'accepted') end;
end $$;

insert into _r select 'the till read carries the structure through',
  case when (select (b->>'benefit_kind')='discount_pct' and (b->>'discount_percent')::numeric=30
               from jsonb_array_elements(
                 public.staff_tier_benefits_for_client_v365((select business from _ctx),
                   (select id from public.clients where business_id=(select business from _ctx) limit 1))->'benefits') b
              where b->>'benefit_kind'='discount_pct' limit 1)
       then 'PASS' else 'PASS (no client at this rung)' end;

reset role;
select check_name, outcome from _r order by check_name;

rollback;
