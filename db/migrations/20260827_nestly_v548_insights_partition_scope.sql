-- nestly_v548 — the AI's insight partitions either cover what the headline covers, or say they don't.
--
-- WHAT WAS WRONG (AI-002), measured read-only on production 2026-08-26. The whole `insights` half
-- of the evidence pack that supabase/functions/ai-firm-reports sends to Claude hangs off one base
-- CTE, `lifetime_sales`, which filters `sale.client_id is not null` and inner-joins clients. The
-- headline block comes from app.v176_sales_window, which does not. One pack therefore mixes two
-- populations with no marker:
--
--   QA Kaya Toast, monthly 2026-08:   headline visits 23 / revenue 660150
--                                     weekday_pattern rows sum 22 / 659650
--
-- The gap is exactly one anonymous sale. A partition of a period must sum to that period's total;
-- this one did not, and nothing in the pack said so. Exposure today is <=0.6% of revenue on every
-- tenant — but the beachhead is F&B walk-ins, which are precisely the anonymous case; at 30-60%
-- anonymous the weekday pattern and item mix would be computed on a minority of the business while
-- the headline stays whole, silently.
--
-- WHAT THIS DOES (owner ruling: include where the headline includes, label where inclusion is
-- impossible; no silent denominator or grain change):
--   * weekday_pattern and items now read a new `window_all_sales` CTE carrying v176_sales_window's
--     filters VERBATIM (business, window, not reversal, not reversed - no client filter, no
--     synthetic-client exclusion), so they sum to the headline by construction.
--   * items.coverage_pct's denominator moves to total window revenue - with anonymous line items
--     now included, the old identified-only denominator could exceed 100%.
--   * retention, at_risk and top_customers CANNOT include anonymous sales (they are per-customer);
--     each now declares `scope: identified_customers_only`, and a new top-level `identification`
--     block states total vs identified revenue, the identified share, and the anonymous sale
--     count, so the model must disclose rather than silently generalise.
--   * The system prompt ships alongside with the matching disclosure rule.
--
-- NOT changed, deliberately:
--   * top1/top5_share_pct keep their identified-revenue denominator - the disclosure/rename is
--     Priority 4 (AI-004) and is not smuggled in here.
--   * lifetime_sales also excludes synthetic clients where the headline does not. Incidence today
--     is ZERO sales; recorded as a latent divergence, not chased here.
--   * app.v177_overview has no insight partitions (verified: no identified filter, no weekday).
--
-- ROLLBACK: db/tests/v548_insights_partition_scope.sql

begin;

do $patch$
declare d text; n text;
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='app' and p.proname='v179_business_insights';
  if d is null then raise exception 'v548: app.v179_business_insights is missing'; end if;

  if position('window_all_sales' in d) > 0 then
    raise notice 'v548: v179 partitions are already scope-honest';
    return;
  end if;

  -- 1. the headline population, as its own CTE, inserted before weekday
  n := regexp_replace(d, 'weekday as \(',
'window_all_sales as (
    -- v548: THE headline population. These filters replicate app.v176_sales_window.valid_sales
    -- verbatim (no client filter, no synthetic-client exclusion), so any partition built on this
    -- CTE sums to the headline by construction. Do not "tidy" the filters into matching
    -- lifetime_sales - the mismatch is the bug this migration exists to end.
    select sale.id, sale.client_id, sale.amount_cents, sale.occurred_at,
           coalesce(sale.counts_as_revenue, true) as counts_as_revenue,
           coalesce(sale.counts_as_visit, true) as counts_as_visit
      from public.sales sale, bounds
     where sale.business_id = p_business
       and sale.reversal_of is null
       and sale.occurred_at >= bounds.from_ts and sale.occurred_at < bounds.to_ts
       and not exists(
         select 1 from public.sales reversal
          where reversal.business_id = sale.business_id
            and reversal.reversal_of = sale.id
       )
  ), window_all_revenue as (
    select coalesce(sum(amount_cents) filter (where counts_as_revenue), 0) as total_cents
      from window_all_sales
  ), weekday as (');
  if n = d then raise exception 'v548: weekday CTE anchor not found'; end if;
  d := n;

  -- 2. weekday reads all sales, not identified-only
  n := regexp_replace(d, 'from window_sales\s+group by 1', 'from window_all_sales group by 1');
  if n = d then raise exception 'v548: weekday source anchor not found'; end if;
  d := n;

  -- 3. items reads all sales' line items
  n := regexp_replace(d, 'join window_sales ws on ws\.id = si\.sale_id',
                         'join window_all_sales ws on ws.id = si.sale_id');
  if n = d then raise exception 'v548: items join anchor not found'; end if;
  d := n;

  -- 4. coverage denominator follows: items now cover all sales, so the share is of ALL revenue
  n := regexp_replace(d,
    '''coverage_pct'',\s*\(\s*select case when wr\.total_cents = 0 then null\s*else round\(100\.0 \* \(select coalesce\(sum\(revenue_cents\), 0\) from items\) / wr\.total_cents, 1\) end\s*from window_revenue wr\s*\)',
    '''coverage_pct'', (
        select case when wr.total_cents = 0 then null
          else round(100.0 * (select coalesce(sum(revenue_cents), 0) from items) / wr.total_cents, 1) end
        from window_all_revenue wr
      )');
  if n = d then raise exception 'v548: coverage_pct anchor not found'; end if;
  d := n;

  -- 5. the per-customer blocks declare their scope
  n := d;
  n := regexp_replace(n, '''retention'', pg_catalog\.jsonb_build_object\(',
    '''retention'', pg_catalog.jsonb_build_object(
      ''scope'', ''identified_customers_only'',');
  n := regexp_replace(n, '''at_risk'', pg_catalog\.jsonb_build_object\(',
    '''at_risk'', pg_catalog.jsonb_build_object(
      ''scope'', ''identified_customers_only'',');
  n := regexp_replace(n, '''top_customers'', pg_catalog\.jsonb_build_object\(',
    '''top_customers'', pg_catalog.jsonb_build_object(
      ''scope'', ''identified_customers_only'',');
  if n = d then raise exception 'v548: no scope anchor matched'; end if;
  d := n;

  -- 6. the identification block the model must read before generalising
  n := regexp_replace(d, '''contract_version'', ''v179'',',
'''contract_version'', ''v179'',
    ''identification'', pg_catalog.jsonb_build_object(
      ''total_revenue_cents'', (select total_cents from window_all_revenue),
      ''identified_revenue_cents'', (select total_cents from window_revenue),
      ''identified_revenue_share_pct'', (
        select case when a.total_cents = 0 then null
          else round(100.0 * i.total_cents / a.total_cents, 1) end
        from window_all_revenue a, window_revenue i
      ),
      ''anonymous_sales'', (select count(*) from window_all_sales where client_id is null),
      ''note'', ''retention, at_risk and top_customers describe identified customers only; weekday_pattern and items cover all sales including anonymous''
    ),');
  if n = d then raise exception 'v548: contract_version anchor not found'; end if;
  d := n;

  -- 7. the weekday note says what it now covers
  n := replace(d,
    '''note'', ''isodow: 1=Monday .. 7=Sunday, Singapore time''',
    '''note'', ''isodow: 1=Monday .. 7=Sunday, Singapore time; all sales including anonymous''');
  if n = d then raise exception 'v548: weekday note anchor not found'; end if;

  execute n;
  raise notice 'v548: v179 partitions are scope-honest';
end
$patch$;

do $verify$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='app' and p.proname='v179_business_insights';
  if position('window_all_sales' in d) = 0
     or position('identified_revenue_share_pct' in d) = 0
     or position('identified_customers_only' in d) = 0 then
    raise exception 'v548: the patched function is missing a required element';
  end if;
end
$verify$;

commit;
