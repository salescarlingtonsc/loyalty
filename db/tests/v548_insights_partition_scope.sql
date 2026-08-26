-- Rollback-only acceptance for nestly_v548 — the AI evidence pack's partitions cover what the
-- headline covers, or say they don't.
-- Run: supabase db query --linked -f db/tests/v548_insights_partition_scope.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- v548 gave app.v179_business_insights a new `window_all_sales` CTE carrying app.v176_sales_window's
-- own filters verbatim (no client filter, no synthetic-client exclusion), and rebuilt weekday_pattern
-- and items on top of it so both partitions sum to the headline by construction. It also added a
-- top-level `identification` disclosure block (total vs identified revenue, the identified share,
-- and the anonymous sale count) and stamped `scope: 'identified_customers_only'` on the three
-- per-customer blocks (retention, at_risk, top_customers), which cannot include anonymous sales.
--
--   01  weekday_pattern rows sum EXACTLY to the v176 headline (revenue and visits), per business
--   02  the identification block's arithmetic is correct against an INDEPENDENT count of raw sales
--   03  retention / at_risk / top_customers each declare scope = identified_customers_only
--   04  items.coverage_pct is null or <= 100.0 (the old identified-only denominator could exceed it)
--
-- ROLLBACK OF THE MIGRATION ITSELF: v179_business_insights was patched by text substitution from
-- its live body; the replaced fragments (the `weekday` CTE's old `from window_sales`, the items
-- CTE's old `join window_sales`, and the old identified-only coverage_pct denominator) are quoted
-- verbatim in the migration file. To revert, restore those fragments. Reverting restores partitions
-- that silently exclude anonymous sales and is only appropriate if the scope-honest shape is itself
-- found faulty. The edge function's system prompt (supabase/functions/ai-firm-reports/index.ts)
-- ships alongside and tells the model to read the `identification` block before generalising from
-- the customer sections; reverting the SQL without reverting that prompt leaves the model told to
-- read a field that no longer exists.

begin;

create temp table _r(check_id text, value text) on commit drop;

-- 01 — weekday_pattern must sum to the v176 headline, per business with any sales
do $probe$
declare
  b record; ev jsonb; hl jsonb;
  wk_rev bigint; wk_vis bigint; hl_rev bigint; hl_vis bigint;
  bad integer := 0; note text := '';
begin
  for b in
    select bs.id, bs.name from public.businesses bs
     where exists (select 1 from public.sales s where s.business_id = bs.id)
     order by bs.name
  loop
    hl := app.v176_sales_window(b.id, (current_date - 30), current_date);
    ev := app.v179_business_insights(b.id, (current_date - 30), current_date,
                                     (current_date - 60), (current_date - 31));

    hl_rev := (hl->>'net_revenue_cents')::bigint;
    hl_vis := (hl->>'visits')::bigint;

    select coalesce(sum((r->>'revenue_cents')::bigint), 0), coalesce(sum((r->>'visits')::bigint), 0)
      into wk_rev, wk_vis
      from jsonb_array_elements(ev->'weekday_pattern'->'rows') r;

    if wk_rev is distinct from hl_rev or wk_vis is distinct from hl_vis then
      bad := bad + 1;
      note := note || format('[%s weekday=%s/%s headline=%s/%s] ',
        b.name, wk_rev, wk_vis, hl_rev, hl_vis);
    end if;
  end loop;

  insert into _r values ('01 weekday_pattern sums to headline',
    case when bad = 0 then 'PASS' else format('FAIL %s business(es): %s', bad, note) end);
end
$probe$;

-- 02 — identification block arithmetic, against an INDEPENDENT count of raw public.sales rows.
--      The window replicates app.v176_sales_window's own bounds: p_from to p_to+1, Asia/Singapore,
--      not reversed, no reversal_of. This does NOT call v179 to produce its own expectation.
do $ident$
declare
  b record; ev jsonb;
  total_cents bigint; identified_cents bigint; share_pct numeric; anon_count bigint;
  exp_anon bigint; exp_share numeric;
  bad integer := 0; note text := '';
begin
  for b in
    select bs.id, bs.name from public.businesses bs
     where exists (select 1 from public.sales s where s.business_id = bs.id)
     order by bs.name
  loop
    ev := app.v179_business_insights(b.id, (current_date - 30), current_date,
                                     (current_date - 60), (current_date - 31))->'identification';

    total_cents := (ev->>'total_revenue_cents')::bigint;
    identified_cents := (ev->>'identified_revenue_cents')::bigint;
    share_pct := (ev->>'identified_revenue_share_pct')::numeric;
    anon_count := (ev->>'anonymous_sales')::bigint;

    -- independent anonymous-sale count, replicating v176's window bounds verbatim
    select count(*) into exp_anon
      from public.sales sale
     where sale.business_id = b.id
       and sale.client_id is null
       and sale.reversal_of is null
       and sale.occurred_at >= (current_date - 30)::timestamp at time zone 'Asia/Singapore'
       and sale.occurred_at <  (current_date + 1)::timestamp at time zone 'Asia/Singapore'
       and not exists(
         select 1 from public.sales reversal
          where reversal.business_id = sale.business_id
            and reversal.reversal_of = sale.id
       );

    if total_cents is distinct from
       (app.v176_sales_window(b.id, (current_date - 30), current_date)->>'net_revenue_cents')::bigint then
      bad := bad + 1;
      note := note || format('[%s total_revenue_cents=%s does not match headline] ', b.name, total_cents);
    end if;

    if identified_cents > total_cents then
      bad := bad + 1;
      note := note || format('[%s identified=%s exceeds total=%s] ', b.name, identified_cents, total_cents);
    end if;

    if anon_count is distinct from exp_anon then
      bad := bad + 1;
      note := note || format('[%s anonymous_sales=%s independently counted=%s] ', b.name, anon_count, exp_anon);
    end if;

    exp_share := case when total_cents = 0 then null
                       else round(100.0 * identified_cents / total_cents, 1) end;
    if share_pct is distinct from exp_share then
      bad := bad + 1;
      note := note || format('[%s share_pct=%s expected=%s] ', b.name, share_pct, exp_share);
    end if;
  end loop;

  insert into _r values ('02 identification block arithmetic',
    case when bad = 0 then 'PASS' else format('FAIL %s problem(s): %s', bad, note) end);
end
$ident$;

-- 03 — the three per-customer blocks must all declare identified_customers_only
do $scope$
declare b record; ev jsonb; bad integer := 0; note text := '';
begin
  for b in
    select bs.id, bs.name from public.businesses bs
     where exists (select 1 from public.sales s where s.business_id = bs.id)
     order by bs.name
  loop
    ev := app.v179_business_insights(b.id, (current_date - 30), current_date,
                                     (current_date - 60), (current_date - 31));
    if (ev->'retention'->>'scope') is distinct from 'identified_customers_only'
       or (ev->'at_risk'->>'scope') is distinct from 'identified_customers_only'
       or (ev->'top_customers'->>'scope') is distinct from 'identified_customers_only' then
      bad := bad + 1;
      note := note || format('[%s retention=%s at_risk=%s top_customers=%s] ', b.name,
        ev->'retention'->>'scope', ev->'at_risk'->>'scope', ev->'top_customers'->>'scope');
    end if;
  end loop;
  insert into _r values ('03 per-customer blocks declare their scope',
    case when bad = 0 then 'PASS' else format('FAIL %s: %s', bad, note) end);
end
$scope$;

-- 04 — items.coverage_pct must be null, or <= 100.0 (the identified-only denominator used to be
--      able to exceed 100% once anonymous line items were counted in the numerator)
do $cov$
declare b record; ev jsonb; cov numeric; bad integer := 0; note text := '';
begin
  for b in
    select bs.id, bs.name from public.businesses bs
     where exists (select 1 from public.sales s where s.business_id = bs.id)
     order by bs.name
  loop
    ev := app.v179_business_insights(b.id, (current_date - 30), current_date,
                                     (current_date - 60), (current_date - 31))->'items';
    cov := (ev->>'coverage_pct')::numeric;
    if cov is not null and cov > 100.0 then
      bad := bad + 1;
      note := note || format('[%s coverage_pct=%s] ', b.name, cov);
    end if;
  end loop;
  insert into _r values ('04 items coverage_pct <= 100',
    case when bad = 0 then 'PASS' else format('FAIL %s: %s', bad, note) end);
end
$cov$;

select check_id, value from _r order by check_id;

rollback;
