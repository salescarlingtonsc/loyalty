-- nestly_v556 — the evidence layer reads the policy snapshot strictly (TRUTH-002).
--
-- Eleven sites across app.v176_sales_window, app.v177_sales_window, app.v177_customers and
-- app.v179_business_insights read the v10.1 policy snapshot as
--
--     coalesce(sale.counts_as_revenue, true)   /   coalesce(sale.counts_as_visit, true)
--
-- sales.counts_as_revenue / counts_as_visit have been NOT NULL since nestly_v10.1 stamped the
-- policy at INSERT, so the fallback arm is dead today — this migration changes NO number. What
-- it removes is the failure mode: if those columns ever became nullable again, a sale with no
-- policy snapshot would silently count as revenue AND as a visit in the AI evidence and the
-- superadmin mirror, the one layer where a made-up default is least visible. Strict reads make
-- that regression fail loudly (a NULL boolean filters out and the partition-vs-headline
-- acceptance suites catch the drift) instead of inventing an answer.
--
-- A precondition guards the premise: if the columns are nullable when this runs, the migration
-- refuses, because then the coalesce is load-bearing and removing it is a behaviour change
-- someone must decide about.
--
-- ROLLBACK: db/tests/v556_policy_read_is_strict.sql

begin;

do $pre$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='sales'
       and column_name in ('counts_as_revenue','counts_as_visit')
       and is_nullable='YES'
  ) then
    raise exception 'v556: the policy snapshot columns are NULLABLE — the coalesce is load-bearing and must not be removed';
  end if;
end
$pre$;

do $patch$
declare r record; d text; n text; v_total integer := 0;
begin
  for r in
    select p.oid, ns.nspname, p.proname
      from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
     where ns.nspname='app'
       and p.proname in ('v176_sales_window','v177_sales_window','v177_customers','v179_business_insights')
  loop
    d := pg_get_functiondef(r.oid);
    n := regexp_replace(d, 'coalesce\(sale\.counts_as_(revenue|visit), true\)', 'sale.counts_as_\1', 'g');
    if n = d then
      raise notice 'v556: %.% already strict', r.nspname, r.proname;
      continue;
    end if;
    execute n;
    v_total := v_total + (length(d) - length(n)) / length('coalesce(, true)');
    raise notice 'v556: %.% reads the snapshot strictly', r.nspname, r.proname;
  end loop;
  if v_total not in (0, 11) then
    raise exception 'v556: expected 11 sites in one pass (or 0 on rerun), changed %', v_total;
  end if;
end
$patch$;

do $verify$
declare bad text;
begin
  select string_agg(n.nspname||'.'||p.proname, ', ') into bad
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app'
     and p.proname in ('v176_sales_window','v177_sales_window','v177_customers','v179_business_insights')
     and p.prosrc like '%coalesce(sale.counts_as_%';
  if bad is not null then
    raise exception 'v556: a silent policy default survives in: %', bad;
  end if;
end
$verify$;

commit;
