-- Rollback-only acceptance for V188/V189 data repairs.
begin;
do $$
declare v_biz uuid; v_bad integer;
begin
  select id into v_biz from public.businesses where name='Hougang ABC';
  if v_biz is null then raise notice 'target business absent; nothing to assert'; return; end if;

  -- V188: the café menu lives in products, not services.
  select count(*) into v_bad from public.services where business_id=v_biz and active;
  if v_bad > 0 then raise exception 'café still has % active services', v_bad; end if;
  select count(*) into v_bad from public.products where business_id=v_biz and active;
  if v_bad = 0 then raise exception 'menu did not reach the products catalogue'; end if;

  -- Sales history must be untouched: no sale line table references services.id at all.
  if exists (select 1 from information_schema.columns
              where table_schema='public' and column_name='service_id'
                and table_name in ('sale_line_items','sale_lines')) then
    raise exception 'a sale line table now references services; the migration assumption is stale';
  end if;

  -- V189: exactly one active copy of the recommended reward.
  select count(*) into v_bad from public.loyalty_rewards
   where business_id=v_biz and customer_name='A thank-you on your next visits' and active;
  if v_bad <> 1 then raise exception 'expected 1 active recommended reward, found %', v_bad; end if;

  -- and nothing retired had ever been redeemed
  if exists (select 1 from public.loyalty_redemptions lr
              join public.loyalty_rewards r on r.id=lr.reward_id
             where r.business_id=v_biz and not r.active) then
    raise exception 'a retired duplicate had redemptions';
  end if;
end $$;
rollback;
