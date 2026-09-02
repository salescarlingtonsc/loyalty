-- EXECUTED acceptance fixture for nestly_v682 — the golden reconciliation corpus.
--
-- Named for v682 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- Closes checklist item 10: >=100 populated synthetic businesses across every supported sector,
-- whose headline metrics reconcile EXACTLY to independently calculated expected values. The
-- oracle is app.seed_golden_business_v682 (db/migrations/20260920_nestly_v682_golden_corpus.sql):
-- for each (index, sector) it provisions one fully-operational business plus a deterministic
-- customer/sales population, and returns the expected headline numbers computed by CLOSED-FORM
-- ARITHMETIC on the same (index, sector) inputs -- never by reading back the rows it just wrote.
-- This file's job is only to call the real product RPCs against those rows and diff their output
-- against that independent expectation, one business at a time, counting mismatches per metric.
--
-- READERS UNDER TEST, and why these three (see the migration header "MODULE ENTITLEMENT" for the
-- gating detail):
--   get_revenue_truth_v106(biz, from, to, branch)         -> totals.known_revenue_minor,
--     identified_revenue_minor, anonymous_revenue_minor, completed_transactions,
--     identified_transactions. Called as the business OWNER (nestly_v668 fixed the resolver so a
--     genuinely-entitled owner reaches it; see that migration and v106_corpus_revenue_truth.sql).
--   get_ci_daypart_v1(biz, from, to, branch)               -> sum of weekdays[].visits across all
--     seven days is used as "visits" -- a raw count of qualifying (non-reversed, non-synthetic)
--     sales, independent of get_revenue_truth_v106's own transaction count, so an equal expected
--     value still exercises app.analytics_sale_class_v1's exclusion path rather than reusing
--     get_revenue_truth_v106's.
--   get_customer_lifecycle_v107(biz, from, to, branch)     -> metrics.transacting_identified_
--     customers ("customer_count") and metrics.repeat_purchasers_in_period ("repeat_customers").
--
-- Every reader is queried over the exact [window_from, window_to) the seeder used, so no sale it
-- wrote falls outside the assertion window.
--
-- HONEST LIMITS
--   * Sector coverage is the fixed 8-key list read from public.sector_profiles / nestly_v275
--     ('bar'): fnb, salon, facial, massage, fitness, retail, other, bar. If a ninth sector is
--     added later, this file needs a new entry, same as the seeder migration does.
--   * The reversed-pair and anonymous-sale slices are small by design ((index mod 3) and
--     (index mod 2) respectively) -- they exist to prove the exclusion holds at scale across many
--     businesses, not to dominate the population.
--   * Runtime budget: 60000 ms for the whole 100+-business loop (bulk insert + 3 RPC calls per
--     business, no per-row RPCs) -- a regression tripwire, not a production SLA.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;
create temp table _sector_seen(sector text) on commit drop;

do $v682$
declare
  v_owner       uuid := '00000000-0000-4000-8000-000000682001';
  v_sectors     text[] := array['fnb','salon','facial','massage','fitness','retail','other','bar'];
  v_n_sectors   int := 8;
  v_n_biz       int := 104;   -- >=100, exact multiple of 8 so every sector appears >=13 times
  v_t0          timestamptz;
  v_ms          numeric;
  v_budget_ms   numeric := 60000;

  i             int;
  v_sector      text;
  v_payload     jsonb;
  v_expected    jsonb;
  v_biz         uuid;
  v_branch      uuid;
  v_from        date;
  v_to          date;

  g_rev         jsonb;
  g_day         jsonb;
  g_life        jsonb;
  v_visits_actual bigint;
  v_err         text;

  v_missing_sectors text[];
  v_total_checked   int := 0;
begin
  insert into auth.users (id, email) values (v_owner, 'zz-v682-owner@example.test')
    on conflict (id) do nothing;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  v_t0 := clock_timestamp();

  for i in 1..v_n_biz loop
    v_sector := v_sectors[((i - 1) % v_n_sectors) + 1];
    insert into _sector_seen values (v_sector);

    begin
      v_payload := app.seed_golden_business_v682(i, v_sector, v_owner);
    exception when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('seed', format('biz#%s(%s): seed_golden_business_v682 raised %s',
        i, v_sector, v_err));
      continue;
    end;

    v_biz      := (v_payload->>'business_id')::uuid;
    v_branch   := (v_payload->>'branch_id')::uuid;
    v_from     := (v_payload->>'window_from')::date;
    v_to       := (v_payload->>'window_to')::date;
    v_expected := v_payload->'expected';
    v_total_checked := v_total_checked + 1;

    -- PRECONDITION (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md "the rule that matters most"): the seeded
    -- owner must genuinely hold view_finance, or every reconciliation below is vacuous.
    if not app.has_perm(v_biz, 'view_finance') then
      insert into _fail values ('PRE', format(
        'biz#%s(%s): seeded owner lacks view_finance; every reader call below is vacuous', i, v_sector));
      continue;
    end if;

    ------------------------------------------------------------------------------------------
    -- get_revenue_truth_v106: known/identified/anonymous revenue, completed/identified txns.
    ------------------------------------------------------------------------------------------
    begin
      g_rev := public.get_revenue_truth_v106(v_biz, v_from, v_to, v_branch);
    exception when others then
      get stacked diagnostics v_err = returned_sqlstate;
      g_rev := null;
      insert into _fail values ('known_revenue', format(
        'biz#%s(%s): get_revenue_truth_v106 raised %s', i, v_sector, v_err));
      insert into _fail values ('identified_revenue', format(
        'biz#%s(%s): get_revenue_truth_v106 raised %s', i, v_sector, v_err));
      insert into _fail values ('anonymous_revenue', format(
        'biz#%s(%s): get_revenue_truth_v106 raised %s', i, v_sector, v_err));
      insert into _fail values ('completed_transactions', format(
        'biz#%s(%s): get_revenue_truth_v106 raised %s', i, v_sector, v_err));
      insert into _fail values ('identified_transactions', format(
        'biz#%s(%s): get_revenue_truth_v106 raised %s', i, v_sector, v_err));
    end;

    if g_rev is not null then
      if (g_rev#>>'{totals,known_revenue_minor}')::bigint <> (v_expected->>'known_revenue')::bigint then
        insert into _fail values ('known_revenue', format(
          'biz#%s(%s): expected %s, got %s', i, v_sector,
          v_expected->>'known_revenue', g_rev#>>'{totals,known_revenue_minor}'));
      end if;
      if (g_rev#>>'{totals,identified_revenue_minor}')::bigint <> (v_expected->>'identified_revenue')::bigint then
        insert into _fail values ('identified_revenue', format(
          'biz#%s(%s): expected %s, got %s', i, v_sector,
          v_expected->>'identified_revenue', g_rev#>>'{totals,identified_revenue_minor}'));
      end if;
      if (g_rev#>>'{totals,anonymous_revenue_minor}')::bigint <> (v_expected->>'anonymous_revenue')::bigint then
        insert into _fail values ('anonymous_revenue', format(
          'biz#%s(%s): expected %s, got %s', i, v_sector,
          v_expected->>'anonymous_revenue', g_rev#>>'{totals,anonymous_revenue_minor}'));
      end if;
      if (g_rev#>>'{totals,completed_transactions}')::bigint <> (v_expected->>'completed_transactions')::bigint then
        insert into _fail values ('completed_transactions', format(
          'biz#%s(%s): expected %s, got %s', i, v_sector,
          v_expected->>'completed_transactions', g_rev#>>'{totals,completed_transactions}'));
      end if;
      if (g_rev#>>'{totals,identified_transactions}')::bigint <> (v_expected->>'identified_transactions')::bigint then
        insert into _fail values ('identified_transactions', format(
          'biz#%s(%s): expected %s, got %s', i, v_sector,
          v_expected->>'identified_transactions', g_rev#>>'{totals,identified_transactions}'));
      end if;
    end if;

    ------------------------------------------------------------------------------------------
    -- get_ci_daypart_v1: visits = sum of weekdays[].visits over the whole window.
    ------------------------------------------------------------------------------------------
    begin
      g_day := public.get_ci_daypart_v1(v_biz, v_from, v_to, v_branch);
    exception when others then
      get stacked diagnostics v_err = returned_sqlstate;
      g_day := null;
      insert into _fail values ('visits', format(
        'biz#%s(%s): get_ci_daypart_v1 raised %s', i, v_sector, v_err));
    end;

    if g_day is not null then
      select coalesce(sum((w->>'visits')::bigint), 0) into v_visits_actual
        from jsonb_array_elements(g_day->'weekdays') w;
      if v_visits_actual <> (v_expected->>'visits')::bigint then
        insert into _fail values ('visits', format(
          'biz#%s(%s): expected %s, got %s', i, v_sector, v_expected->>'visits', v_visits_actual));
      end if;
    end if;

    ------------------------------------------------------------------------------------------
    -- get_customer_lifecycle_v107: customer_count, repeat_customers.
    ------------------------------------------------------------------------------------------
    begin
      g_life := public.get_customer_lifecycle_v107(v_biz, v_from, v_to, v_branch);
    exception when others then
      get stacked diagnostics v_err = returned_sqlstate;
      g_life := null;
      insert into _fail values ('customer_count', format(
        'biz#%s(%s): get_customer_lifecycle_v107 raised %s', i, v_sector, v_err));
      insert into _fail values ('repeat_customers', format(
        'biz#%s(%s): get_customer_lifecycle_v107 raised %s', i, v_sector, v_err));
    end;

    if g_life is not null then
      if (g_life#>>'{metrics,transacting_identified_customers}')::bigint
         <> (v_expected->>'customer_count')::bigint then
        insert into _fail values ('customer_count', format(
          'biz#%s(%s): expected %s, got %s', i, v_sector,
          v_expected->>'customer_count', g_life#>>'{metrics,transacting_identified_customers}'));
      end if;
      if (g_life#>>'{metrics,repeat_purchasers_in_period}')::bigint
         <> (v_expected->>'repeat_customers')::bigint then
        insert into _fail values ('repeat_customers', format(
          'biz#%s(%s): expected %s, got %s', i, v_sector,
          v_expected->>'repeat_customers', g_life#>>'{metrics,repeat_purchasers_in_period}'));
      end if;
    end if;
  end loop;

  v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000;
  raise notice 'v682: seeded+reconciled % businesses in % ms', v_total_checked, round(v_ms, 1);
  if v_ms > v_budget_ms then
    insert into _fail values ('timing', format(
      'whole corpus took %s ms, over the %s ms budget', round(v_ms, 1), v_budget_ms));
  end if;

  -- Every supported sector must appear at least once.
  select array(select s from unnest(v_sectors) s
                where not exists (select 1 from _sector_seen ss where ss.sector = s))
    into v_missing_sectors;
  if array_length(v_missing_sectors, 1) > 0 then
    insert into _fail values ('sector_coverage', format('sectors never seeded: %s', v_missing_sectors));
  end if;

  perform set_config('request.jwt.claims', null, true);

  raise notice 'v682: businesses checked=%, sectors seeded=%',
    v_total_checked, (select count(distinct sector) from _sector_seen);
end
$v682$;

-- Per-metric reconciliation rate, for the report (not the pass/fail decision -- that is the
-- stricter 100% below, per the task's own instruction to assert the stricter bar).
select k as metric, count(*) as mismatches from _fail where k not in ('seed','PRE','timing','sector_coverage')
  group by k order by k;

select case when count(*)=0
            then 'PASS — v682 golden corpus: >=100 businesses across every supported sector '
                 'reconcile exactly on known/identified/anonymous revenue, completed/identified '
                 'transactions, visits, customer_count and repeat_customers'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v682: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
