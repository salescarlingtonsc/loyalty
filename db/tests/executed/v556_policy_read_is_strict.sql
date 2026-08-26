-- EXECUTED golden fixture for nestly_v556 — the evidence layer reads the policy snapshot
-- strictly (TRUTH-002).
--
-- v556 is behaviour-preserving BY DESIGN (the snapshot columns are NOT NULL, so the removed
-- coalesce(..., true) arm was dead). The assertions therefore pin three things:
--
--   S1  the premise holds: counts_as_revenue / counts_as_visit are NOT NULL columns
--   S2  no silent default survives in the four evidence functions (this is the one textual
--       check, and the reason the fixture fails on baseline)
--   S3  the arithmetic did not move: the v176 headline over a seeded business equals the
--       hand-computed figures (2300 revenue / 3 visits) after the strict rewrite
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v556$
declare
  b uuid := '00000000-0000-4000-8000-0000000a6001';
  c1 uuid := '00000000-0000-4000-8000-0000000a6101';
  hl jsonb; bad text;
begin
  -- S1
  if exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='sales'
       and column_name in ('counts_as_revenue','counts_as_visit') and is_nullable='YES'
  ) then
    insert into _fail values ('S1','the policy snapshot columns are nullable — strict reads are no longer safe');
  end if;

  -- S2
  select string_agg(n.nspname||'.'||p.proname, ', ') into bad
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app'
     and p.proname in ('v176_sales_window','v177_sales_window','v177_customers','v179_business_insights')
     and p.prosrc like '%coalesce(sale.counts_as_%';
  if bad is not null then
    insert into _fail values ('S2', format('a silent policy default survives in: %s', bad));
  end if;

  -- S3
  insert into public.businesses (id, name, slug) values (b,'ZZ v556 strict','zz-v556-strict');
  insert into public.clients (id, business_id, full_name) values (c1,b,'Fixture Sam');
  insert into public.sales (business_id, client_id, kind, amount_cents, occurred_at) values
    (b, c1,   'quick_sale',  700, (current_date - 5)::timestamp at time zone 'Asia/Singapore'),
    (b, c1,   'quick_sale', 1100, (current_date - 4)::timestamp at time zone 'Asia/Singapore'),
    (b, null, 'quick_sale',  500, (current_date - 3)::timestamp at time zone 'Asia/Singapore');
  hl := app.v176_sales_window(b, current_date - 10, current_date);
  if (hl->>'net_revenue_cents')::bigint is distinct from 2300
     or (hl->>'visits')::bigint is distinct from 3 then
    insert into _fail values ('S3', format('headline %s/%s, hand-computed 2300/3 — the strict rewrite moved a number',
      hl->>'net_revenue_cents', hl->>'visits'));
  end if;
end
$v556$;

select case when count(*)=0 then 'PASS — the policy snapshot is read strictly and nothing moved'
            else 'FAIL' end as verdict, count(*) as failures from _fail;
select k, v from _fail order by k;

do $verdict$
declare v integer;
begin
  select count(*) into v from _fail;
  if v > 0 then raise exception 'v556: % assertion(s) failed', v; end if;
end
$verdict$;

rollback;
