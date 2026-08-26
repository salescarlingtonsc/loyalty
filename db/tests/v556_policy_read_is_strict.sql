-- Rollback-only acceptance for nestly_v556 — the evidence layer reads the v10.1 policy
-- snapshot strictly (TRUTH-002).
-- Run: supabase db query --linked -f db/tests/v556_policy_read_is_strict.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- v556 is behaviour-preserving BY DESIGN: sales.counts_as_revenue / counts_as_visit have been
-- NOT NULL since nestly_v10.1, so coalesce(sale.counts_as_*, true) was always dead code. This
-- acceptance proves the premise still holds and that removing the coalesce moved nothing, by
-- independently recomputing the same window from raw public.sales for every live business.
--
--   01  sales.counts_as_revenue and sales.counts_as_visit are NOT NULL in production — the
--       precondition the migration itself required before it would run.
--   02  none of the four evidence functions (app.v176_sales_window, app.v177_sales_window,
--       app.v177_customers, app.v179_business_insights) still contains
--       "coalesce(sale.counts_as_" — the silent-default arm is gone everywhere.
--   03  for every live business, app.v176_sales_window(b, current_date-30, current_date)
--       equals an independent recomputation of net_revenue_cents and visits from raw
--       public.sales — same Asia/Singapore window bounds (from date at SGT midnight, to
--       date+1 at SGT midnight), reversal_of is null, not itself reversed, counts_as_revenue
--       / counts_as_visit read STRICTLY (no coalesce). Equality here proves the strict
--       rewrite is arithmetically identical to what production already returns.
--
-- ROLLBACK: reverting v556 means restoring
--
--     coalesce(sale.counts_as_revenue, true)   /   coalesce(sale.counts_as_visit, true)
--
-- at the eleven sites in app.v176_sales_window, app.v177_sales_window, app.v177_customers and
-- app.v179_business_insights. Only appropriate if sales.counts_as_revenue / counts_as_visit
-- become nullable again (i.e. the v10.1 policy-snapshot invariant is deliberately relaxed) and
-- the owner wants those four functions to silently default a missing snapshot to "counts as
-- both" rather than fail loudly. Until that invariant changes, this migration has zero live
-- effect to roll back — the correct fix for a suspected snapshot-nullability regression is to
-- re-run this suite's check 01, not to restore the coalesce.

begin;

create temp table _r(check_id text, value text) on commit drop;

-- 01 — the precondition the migration itself enforced
do $notnull$
declare
  nullable text;
begin
  select string_agg(column_name, ', ') into nullable
    from information_schema.columns
   where table_schema='public' and table_name='sales'
     and column_name in ('counts_as_revenue','counts_as_visit')
     and is_nullable='YES';

  insert into _r values ('01 sales.counts_as_revenue/counts_as_visit are NOT NULL',
    case when nullable is null then 'PASS'
      else pg_catalog.format('FAIL nullable columns: %s', nullable) end);
end
$notnull$;

-- 02 — no silent default survives in the four evidence functions
do $branch$
declare
  bad text;
begin
  select string_agg(n.nspname||'.'||p.proname, ', ') into bad
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app'
     and p.proname in ('v176_sales_window','v177_sales_window','v177_customers','v179_business_insights')
     and p.prosrc like '%coalesce(sale.counts_as_%';

  insert into _r values ('02 no coalesce(sale.counts_as_*) survives in the four evidence functions',
    case when bad is null then 'PASS'
      else pg_catalog.format('FAIL a silent policy default survives in: %s', bad) end);
end
$branch$;

-- 03 — the strict rewrite moved nothing, verified against every live business
do $recompute$
declare
  r record;
  hl jsonb;
  reported_revenue bigint; reported_visits bigint;
  computed_revenue bigint; computed_visits bigint;
  bad integer := 0; note text := '';
  n_businesses integer := 0;
begin
  for r in select id, name from public.businesses loop
    n_businesses := n_businesses + 1;

    hl := app.v176_sales_window(r.id, current_date - 30, current_date);
    reported_revenue := (hl->>'net_revenue_cents')::bigint;
    reported_visits := (hl->>'visits')::bigint;

    select
      coalesce(sum(sale.amount_cents) filter (where sale.counts_as_revenue), 0),
      count(*) filter (where sale.counts_as_visit)
      into computed_revenue, computed_visits
      from public.sales sale
     where sale.business_id = r.id
       and sale.reversal_of is null
       and sale.occurred_at >= (current_date - 30)::timestamp at time zone 'Asia/Singapore'
       and sale.occurred_at < (current_date + 1)::timestamp at time zone 'Asia/Singapore'
       and not exists (
         select 1 from public.sales reversal
          where reversal.business_id = sale.business_id
            and reversal.reversal_of = sale.id
       );

    if reported_revenue is distinct from computed_revenue
       or reported_visits is distinct from computed_visits then
      bad := bad + 1;
      note := note || pg_catalog.format(
        '[%s(%s): reported %s/%s vs recomputed %s/%s] ',
        r.name, left(r.id::text,8), reported_revenue, reported_visits, computed_revenue, computed_visits);
    end if;
  end loop;

  insert into _r values (
    pg_catalog.format('03 v176_sales_window matches an independent raw-sales recomputation (%s businesses checked)', n_businesses),
    case when bad = 0 then 'PASS' else pg_catalog.format('FAIL %s: %s', bad, note) end);
end
$recompute$;

select check_id, value from _r order by check_id;

rollback;
