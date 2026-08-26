-- EXECUTED golden fixture for nestly_v548 — the AI's insight partitions are scope-honest.
--
-- WHY. The insights half of the evidence pack filtered `client_id is not null`, so its
-- weekday/items partitions silently covered fewer sales than the headline (Kaya Toast: 22/659650
-- against a headline of 23/660150 — the gap is one anonymous sale). v548 makes weekday and items
-- read the headline's own population, and makes the per-customer blocks declare
-- `identified_customers_only` plus a top-level `identification` disclosure block.
--
-- THE ORACLE IS INDEPENDENT: every expected value below is hand-computed from the seeded rows
-- (700 + 1100 identified, 500 anonymous ⇒ 2300 total, 78.3% identified share). The function under
-- test is never used to produce its own expectation.
--
--   P1  weekday rows sum EXACTLY to the v176 headline (revenue and visits)
--   P2  the identification block states total, identified, share and anonymous count
--   P3  retention / at_risk / top_customers each declare identified_customers_only
--   P4  an item sold ONLY on an anonymous sale appears in top_items
--   P5  the per-customer blocks did NOT silently absorb the anonymous sale (customers_served = 2)
--
-- Named for v548: P1-P4 must FAIL against the frozen baseline. One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v548$
declare
  b uuid := '00000000-0000-4000-8000-00000000c001';
  c1 uuid := '00000000-0000-4000-8000-00000000c101';
  c2 uuid := '00000000-0000-4000-8000-00000000c102';
  s1 uuid := '00000000-0000-4000-8000-00000000c201';
  s2 uuid := '00000000-0000-4000-8000-00000000c202';
  s3 uuid := '00000000-0000-4000-8000-00000000c203';
  d_from date := current_date - 10; d_to date := current_date;
  hl jsonb; ev jsonb; wk_rev bigint; wk_vis bigint;
begin
  insert into public.businesses (id, name, slug) values (b,'ZZ v548 scope','zz-v548-scope');
  insert into public.clients (id, business_id, full_name) values
    (c1,b,'Fixture Ida'), (c2,b,'Fixture Ines');

  -- two identified sales and ONE anonymous sale, all inside the window
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at) values
    (s1, b, c1,   'quick_sale',  700, (current_date - 5)::timestamp at time zone 'Asia/Singapore'),
    (s2, b, c2,   'quick_sale', 1100, (current_date - 4)::timestamp at time zone 'Asia/Singapore'),
    (s3, b, null, 'quick_sale',  500, (current_date - 3)::timestamp at time zone 'Asia/Singapore');

  insert into public.sale_items (business_id, sale_id, item_type, description, qty, unit_cents, line_cents) values
    (b, s1, 'custom', 'Kopi',              1,  700,  700),
    (b, s2, 'custom', 'Kaya Toast Set',    1, 1100, 1100),
    (b, s3, 'custom', 'ANON ONLY WIDGET',  1,  500,  500);

  hl := app.v176_sales_window(b, d_from, d_to);
  -- sanity on the seed itself: the headline must see all three sales
  if (hl->>'net_revenue_cents')::bigint <> 2300 or (hl->>'visits')::bigint <> 3 then
    insert into _fail values ('seed', format('headline is %s/%s, expected 2300/3',
      hl->>'net_revenue_cents', hl->>'visits'));
  end if;

  ev := app.v179_business_insights(b, d_from, d_to, d_from - 11, d_from - 1);

  -- P1 — the partition sums to the headline, by hand: 700+1100+500 and 3 visit rows
  select coalesce(sum((r->>'revenue_cents')::bigint),0), coalesce(sum((r->>'visits')::bigint),0)
    into wk_rev, wk_vis
    from jsonb_array_elements(ev->'weekday_pattern'->'rows') r;
  if wk_rev <> 2300 or wk_vis <> 3 then
    insert into _fail values ('P1', format('weekday sums %s/%s, headline 2300/3 — the anonymous sale is missing', wk_rev, wk_vis));
  end if;

  -- P2 — the disclosure block, against hand-computed values
  if jsonb_typeof(ev->'identification') is distinct from 'object' then
    insert into _fail values ('P2','the identification block is absent');
  else
    if (ev->'identification'->>'total_revenue_cents')::bigint <> 2300
       or (ev->'identification'->>'identified_revenue_cents')::bigint <> 1800
       or (ev->'identification'->>'identified_revenue_share_pct')::numeric <> 78.3
       or (ev->'identification'->>'anonymous_sales')::bigint <> 1 then
      insert into _fail values ('P2', format('identification says %s, expected 2300/1800/78.3/1',
        ev->'identification'));
    end if;
  end if;

  -- P3 — the per-customer blocks say what they cover
  if (ev->'retention'->>'scope') is distinct from 'identified_customers_only'
     or (ev->'at_risk'->>'scope') is distinct from 'identified_customers_only'
     or (ev->'top_customers'->>'scope') is distinct from 'identified_customers_only' then
    insert into _fail values ('P3', format('scopes: retention=%s at_risk=%s top_customers=%s',
      ev->'retention'->>'scope', ev->'at_risk'->>'scope', ev->'top_customers'->>'scope'));
  end if;

  -- P4 — anonymous line items reach the item mix
  if not exists (
    select 1 from jsonb_array_elements(ev->'items'->'top_items') item
     where item->>'description' = 'ANON ONLY WIDGET'
  ) then
    insert into _fail values ('P4', format('the anonymous-only item is missing from top_items: %s',
      ev->'items'->'top_items'));
  end if;

  -- P5 — no silent grain change the OTHER way: per-customer blocks still identified-only
  if (ev->'retention'->>'customers_served')::bigint <> 2 then
    insert into _fail values ('P5', format('customers_served=%s, expected 2 — the anonymous sale must not become a customer',
      ev->'retention'->>'customers_served'));
  end if;
end
$v548$;

select case when count(*)=0 then 'PASS — the insight partitions are scope-honest'
            else 'FAIL' end as verdict, count(*) as failures from _fail;
select k, v from _fail order by k;

do $verdict$
declare v integer;
begin
  select count(*) into v from _fail;
  if v > 0 then raise exception 'v548: % assertion(s) failed', v; end if;
end
$verdict$;

rollback;
