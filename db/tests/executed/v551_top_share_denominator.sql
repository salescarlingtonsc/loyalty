-- EXECUTED golden fixture for nestly_v551 — the top-customer shares name their denominator.
--
-- WHY. top1_share_pct / top5_share_pct divided by IDENTIFIED revenue without saying so (Kaya
-- Toast: 84.0 = 554150/659650 identified, vs 83.9 of total). v551 renames both to
-- *_of_identified_revenue_pct (expressions untouched) and adds *_of_total_revenue_pct twins over
-- the headline population.
--
-- THE ORACLE IS INDEPENDENT: seeded 700 + 1100 identified and 500 anonymous. Hand-computed:
--   identified revenue 1800, total 2300, top1 = 1100.
--   top1/identified = 61.1   top1/total = 47.8
--   top5/identified = 100.0  top5/total = 78.3
--
--   T1  the old undisclosed names are gone from the payload
--   T2  the renamed identified-denominator fields carry the OLD values exactly (rename-only)
--   T3  the new total-denominator fields match hand-computed values
--   T4  a business with zero revenue yields nulls, not division errors
--
-- Named for v551: T1-T3 must FAIL against the frozen baseline. One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v551$
declare
  b uuid := '00000000-0000-4000-8000-00000000d001';
  b0 uuid := '00000000-0000-4000-8000-00000000d002';
  c1 uuid := '00000000-0000-4000-8000-00000000d101';
  c2 uuid := '00000000-0000-4000-8000-00000000d102';
  d_from date := current_date - 10; d_to date := current_date;
  ev jsonb; tc jsonb;
begin
  insert into public.businesses (id, name, slug) values
    (b,'ZZ v551 shares','zz-v551-shares'), (b0,'ZZ v551 empty','zz-v551-empty');
  insert into public.clients (id, business_id, full_name) values
    (c1,b,'Fixture Tia'), (c2,b,'Fixture Tom');
  insert into public.sales (business_id, client_id, kind, amount_cents, occurred_at) values
    (b, c1,   'quick_sale',  700, (current_date - 5)::timestamp at time zone 'Asia/Singapore'),
    (b, c2,   'quick_sale', 1100, (current_date - 4)::timestamp at time zone 'Asia/Singapore'),
    (b, null, 'quick_sale',  500, (current_date - 3)::timestamp at time zone 'Asia/Singapore');

  ev := app.v179_business_insights(b, d_from, d_to, d_from - 11, d_from - 1);
  tc := ev->'top_customers';

  -- T1
  if tc ? 'top1_share_pct' or tc ? 'top5_share_pct' then
    insert into _fail values ('T1', format('undisclosed-denominator fields survive: %s',
      (select string_agg(k,',') from jsonb_object_keys(tc) k)));
  end if;

  -- T2 — rename only: 1100/1800 and 1800/1800, to one decimal
  if (tc->>'top1_share_of_identified_revenue_pct')::numeric is distinct from 61.1
     or (tc->>'top5_share_of_identified_revenue_pct')::numeric is distinct from 100.0 then
    insert into _fail values ('T2', format('identified shares %s/%s, expected 61.1/100.0',
      tc->>'top1_share_of_identified_revenue_pct', tc->>'top5_share_of_identified_revenue_pct'));
  end if;

  -- T3 — 1100/2300 and 1800/2300
  if (tc->>'top1_share_of_total_revenue_pct')::numeric is distinct from 47.8
     or (tc->>'top5_share_of_total_revenue_pct')::numeric is distinct from 78.3 then
    insert into _fail values ('T3', format('total shares %s/%s, expected 47.8/78.3',
      tc->>'top1_share_of_total_revenue_pct', tc->>'top5_share_of_total_revenue_pct'));
  end if;

  -- T4 — empty business: nulls, no error
  ev := app.v179_business_insights(b0, d_from, d_to, d_from - 11, d_from - 1);
  tc := ev->'top_customers';
  if (tc->>'top1_share_of_total_revenue_pct') is not null
     or (tc->>'top1_share_of_identified_revenue_pct') is not null then
    insert into _fail values ('T4', format('zero-revenue business states a share: %s', tc));
  end if;
end
$v551$;

select case when count(*)=0 then 'PASS — the top-customer shares name their denominator'
            else 'FAIL' end as verdict, count(*) as failures from _fail;
select k, v from _fail order by k;

do $verdict$
declare v integer;
begin
  select count(*) into v from _fail;
  if v > 0 then raise exception 'v551: % assertion(s) failed', v; end if;
end
$verdict$;

rollback;
