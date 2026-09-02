-- EXECUTED acceptance fixture for nestly_v715 — app.v179_business_insights.weekday_pattern was
-- summing RAW SALE ROWS per isodow while every sibling figure in the SAME payload
-- (top_customers.visits, lifetime_visits, retention.*) counts distinct visit-days (nestly_v699).
--
-- Named for v715 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- Reads db/migrations/20260902_nestly_v715_v179_weekday_visit_days.sql.
--
-- PREDETERMINED TRUTH TABLE (computed before running anything). One business, one default branch
-- (timezone defaults to Asia/Singapore, so app.ci_bucket_tz_v698 resolves 'firm_agreed'/
-- 'Asia/Singapore' — the resolved bucket clock and the SG visit-day clock coincide here on
-- purpose, so this fixture isolates the dedupe bug from nestly_v706's separate branch-clock
-- concern, already proven by db/tests/executed/v706_corpus_branch_clock.sql). Window = a known
-- Monday (v_monday1, computed via date_trunc('week', ...) so it lands on isodow=1 regardless of
-- what day this suite runs) through the following Monday + 0 days (8 calendar days), inclusive.
--
--   Client R: 3 sales on v_monday1 (a split bill, same afternoon) + 1 sale on v_monday1+1
--     (Tuesday) + 1 sale on v_monday1+7 (the FOLLOWING Monday) -> 5 raw sale rows, 3 true
--     visit-days (2 distinct Mondays + 1 Tuesday).
--   Client C: 5 sales on 5 DISTINCT days: v_monday1 (Monday), v_monday1+2 (Wednesday),
--     v_monday1+3 (Thursday), v_monday1+4 (Friday), v_monday1+5 (Saturday) -> 5 raw sale rows,
--     5 true visit-days (one per day, none shared with any other C day).
--
--   weekday_pattern.rows (NEW, visit-day rule): isodow=1 (Monday) visits = 3 (R's 2 Mondays + C's
--     1 Monday); isodow=2 (Tuesday) visits = 1 (R); isodow=3 (Wed) = 1, isodow=4 (Thu) = 1,
--     isodow=5 (Fri) = 1, isodow=6 (Sat) = 1 (all C). SUM ACROSS ALL ROWS = 8.
--   Under the OLD raw-row rule: isodow=1 would sum R's 4 Monday sale rows (3 same-day + 1 on the
--     following Monday) + C's 1 Monday sale row = 5, and the grand total would be 10 (R's 5 raw
--     rows + C's 5 raw rows) — the exact "10 for two clients with 3+1+1 and 5 sales" figure this
--     migration's header cites.
--   top_customers.rows / lifetime_visits: UNCHANGED by this migration (already deduped since
--     nestly_v699) — R.visits = 3, C.visits = 5.
--
-- A mutation that reverts weekday_pattern's dedupe (back to counting raw sale rows) makes the
-- Monday row read 5 and the sum read 10; this fixture turns red on either.

\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

do $v715$
declare
  biz  uuid := '00000000-0000-4000-8000-000000715001';
  br1  uuid := '00000000-0000-4000-8000-000000715011';
  r    uuid := '00000000-0000-4000-8000-000000715101';
  c    uuid := '00000000-0000-4000-8000-000000715102';

  v_monday1 date := (date_trunc('week', current_date - 30))::date;

  v_as_of timestamptz := clock_timestamp();

  p_from date; p_to date; p_prior_from date; p_prior_to date;

  g_v179 jsonb;
  wk_row jsonb;
  top_r jsonb; top_c jsonb;
  v_sum bigint;
  v_err text;
begin
  ---------------------------------------------------------------------------
  -- business/branch — default branch keeps timezone='Asia/Singapore' (column default), so
  -- app.ci_bucket_tz_v698(biz, null) resolves 'firm_agreed'/'Asia/Singapore': the resolved
  -- bucket clock and the SG visit-day clock are the SAME clock in this fixture, on purpose.
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v715 fixture', 'zz-v715-fixture',
          array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (br1, biz, 'ZZ v715 branch', true, true);

  insert into public.clients (id, business_id, full_name) values
    (r, biz, 'ZZ v715 R split-bill-plus-two-mondays'),
    (c, biz, 'ZZ v715 C five-distinct-days');

  ---------------------------------------------------------------------------
  -- R: 3 same-day (Monday) + 1 Tuesday + 1 the FOLLOWING Monday. 5 raw rows, 3 visit-days.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit)
  values
    ('00000000-0000-4000-8000-000000715201', biz, br1, r, 'service', 1000,
     (v_monday1::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000715202', biz, br1, r, 'service', 1500,
     (v_monday1::timestamp + time '11:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000715203', biz, br1, r, 'service', 500,
     (v_monday1::timestamp + time '15:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000715204', biz, br1, r, 'service', 700,
     ((v_monday1 + 1)::timestamp + time '10:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000715205', biz, br1, r, 'service', 900,
     ((v_monday1 + 7)::timestamp + time '10:00') at time zone 'Asia/Singapore', v_as_of, true, true);

  ---------------------------------------------------------------------------
  -- C: 5 sales on 5 distinct days (Mon, Wed, Thu, Fri, Sat of the SAME first week). 5 raw rows,
  -- 5 visit-days, none shared with R's Tuesday or R's second Monday.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit)
  values
    ('00000000-0000-4000-8000-000000715301', biz, br1, c, 'service', 1100,
     (v_monday1::timestamp + time '13:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000715302', biz, br1, c, 'service', 1200,
     ((v_monday1 + 2)::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000715303', biz, br1, c, 'service', 1300,
     ((v_monday1 + 3)::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000715304', biz, br1, c, 'service', 1400,
     ((v_monday1 + 4)::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true),
    ('00000000-0000-4000-8000-000000715305', biz, br1, c, 'service', 1600,
     ((v_monday1 + 5)::timestamp + time '09:00') at time zone 'Asia/Singapore', v_as_of, true, true);

  p_from := v_monday1;
  p_to := v_monday1 + 7;
  p_prior_to := p_from;
  p_prior_from := p_prior_to - 7;

  begin
    g_v179 := app.v179_business_insights(biz, p_from, p_to, p_prior_from, p_prior_to);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('V715-call', format('app.v179_business_insights raised %s', v_err));
    return;
  end;

  ---------------------------------------------------------------------------
  -- weekday_pattern: bucket_timezone/timezone_basis (sanity, nestly_v706), visit_definition
  -- (new, nestly_v715), the Monday row, and the grand total.
  ---------------------------------------------------------------------------
  if (g_v179->'weekday_pattern'->>'bucket_timezone') is distinct from 'Asia/Singapore'
     or (g_v179->'weekday_pattern'->>'timezone_basis') is distinct from 'firm_agreed' then
    insert into _fail values ('WK-bucket-tz', format(
      'expected Asia/Singapore/firm_agreed (single default-tz branch), got %s/%s',
      g_v179->'weekday_pattern'->>'bucket_timezone', g_v179->'weekday_pattern'->>'timezone_basis'));
  end if;

  if (g_v179->'weekday_pattern'->>'visit_definition') is null then
    insert into _fail values ('WK-visit-def', 'weekday_pattern.visit_definition key missing');
  end if;

  select w into wk_row from jsonb_array_elements(g_v179->'weekday_pattern'->'rows') w
   where (w->>'isodow')::int = 1;
  if wk_row is null then
    insert into _fail values ('WK-monday-present', 'no isodow=1 (Monday) row in weekday_pattern.rows');
  else
    if (wk_row->>'visits')::bigint is distinct from 3 then
      insert into _fail values ('WK-monday-visits', format(
        'expected 3 (R''s 2 distinct Mondays + C''s 1 Monday), got %s', wk_row->>'visits'));
    end if;
    -- MUTATION: the OLD raw-row Monday count (R's 4 same-week Monday sale rows + C's 1) must NOT
    -- come back.
    if (wk_row->>'visits')::bigint = 5 then
      insert into _fail values ('WK-monday-mutation',
        'weekday_pattern Monday visits still reads the OLD raw-row count (5), not the new visit-day count (3)');
    end if;
  end if;

  select coalesce(sum((w->>'visits')::bigint), 0) into v_sum
    from jsonb_array_elements(g_v179->'weekday_pattern'->'rows') w;
  if v_sum is distinct from 8 then
    insert into _fail values ('WK-total-visits', format(
      'expected weekday_pattern.rows[].visits to sum to 8 (3 true visit-days for R + 5 for C), got %s',
      v_sum));
  end if;
  -- MUTATION: the OLD raw-row grand total (R's 5 raw rows + C's 5 raw rows) must NOT come back.
  if v_sum = 10 then
    insert into _fail values ('WK-total-mutation',
      'weekday_pattern visits still sum to the OLD raw-row total (10), not the new visit-day total (8)');
  end if;

  ---------------------------------------------------------------------------
  -- top_customers / lifetime_visits: UNCHANGED by this migration — still deduped since
  -- nestly_v699. R=3, C=5. A regression here would mean this migration's edit leaked outside
  -- the weekday CTE.
  ---------------------------------------------------------------------------
  -- top_customers rows do not carry client_id (only a display label + revenue_cents/visits), so
  -- match by revenue_cents instead (R totals 1000+1500+500+700+900=4600; C totals
  -- 1100+1200+1300+1400+1600=6600 — distinct amounts, an unambiguous key for this fixture).
  select x into top_r from jsonb_array_elements(g_v179->'top_customers'->'rows') x
   where (x->>'revenue_cents')::bigint = 4600;
  select x into top_c from jsonb_array_elements(g_v179->'top_customers'->'rows') x
   where (x->>'revenue_cents')::bigint = 6600;

  if top_r is null then
    insert into _fail values ('TOP-r-present', 'R (revenue_cents=4600) absent from top_customers.rows');
  elsif (top_r->>'visits')::bigint is distinct from 3 then
    insert into _fail values ('TOP-r-visits', format('expected R visits=3 (unchanged by this migration), got %s',
      top_r->>'visits'));
  end if;
  if top_c is null then
    insert into _fail values ('TOP-c-present', 'C (revenue_cents=6600) absent from top_customers.rows');
  elsif (top_c->>'visits')::bigint is distinct from 5 then
    insert into _fail values ('TOP-c-visits', format('expected C visits=5 (unchanged by this migration), got %s',
      top_c->>'visits'));
  end if;
end
$v715$;

select case when count(*)=0
            then 'PASS — v715: app.v179_business_insights.weekday_pattern.visits now dedupes by '
                 '(client_id, visit-day) same as every sibling figure in the payload; Monday=3 '
                 '(was 5), total=8 (was 10); top_customers/lifetime_visits unchanged at 3/5'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v715: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
