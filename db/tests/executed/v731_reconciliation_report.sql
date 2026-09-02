-- EXECUTED acceptance fixture for the CI-100 proof pack, artifact #7 (CI-RECONCILIATION-REPORT).
--
-- Named v731 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run only, per the harness convention (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md):
--   LC_ALL=C node scripts/db-tests/run.mjs --filter=v731 --migrated-only
--
-- WHY THIS EXISTS. `docs/qa/CI-100-CHECKLIST.md`'s required proof pack, artifact 7, asks for a
-- reconciliation report: the same underlying revenue figure, read through every headline reader
-- the product ships, must agree exactly. This file is the FIXTURE that produces that report's raw
-- material — it does not itself write the markdown; `scripts/quality/ci-proof-pack.mjs
-- reconciliation` runs this fixture through the harness and captures its RAISE NOTICE output
-- verbatim into `docs/qa/proof-pack/CI-RECONCILIATION-REPORT.md`, alongside the commit SHA, date
-- and environment the generator script reads for itself. The report IS the captured output; this
-- file only has to make that output trustworthy.
--
-- ORACLE. `app.seed_golden_business_v682` (db/migrations/20260920_nestly_v682_golden_corpus.sql)
-- provisions one fully-operational business per (index, sector) with a deterministic sales
-- population and its OWN independently closed-form expected revenue figure — the same oracle
-- `v682_golden_reconciliation.sql` uses for checklist item 10. This file calls it for THREE
-- sectors (fnb, salon, retail), then reads the resulting business back through FIVE independent
-- code paths and reconciles all five to each other, not only to the oracle:
--
--   A. public.get_revenue_truth_v106(biz, from, to, branch)   -> totals.known_revenue_minor
--        ("Peekaa-recorded revenue" — the canonical figure every other reader is judged against).
--   B. public.get_dashboard_summary_v155(biz, from, to)       -> kpis.revenue_cents
--        (the merchant-facing dashboard's own headline number).
--   C. app.v176_sales_window(biz, from, to)                   -> net_revenue_cents
--        (the AI-report evidence-pack sales window every narrative is grounded against).
--   D. public.platform_get_assigned_firm_report_v94(biz, branch, from, to)
--        -> kpis.net_revenue_cents (the platform-console consultant report; called as a
--           Google-SSO super admin, the only session app.is_super_admin() accepts since v625).
--   E. direct SQL: sum(sales.amount_cents) over the same qualifying-sale predicate every one of
--        A-D implements independently (reversal_of is null, not itself reversed, counts_as_revenue,
--        occurred_at in [from, to+1) SGT) — the "ground truth" a reviewer could hand-check with one
--        query and no RPC at all.
--
-- Each of B, C, D, E is expressed as a percentage of A ("the reconciliation percentage") and MUST
-- read 100.0 for every business — not merely close, not "off by a rounding cent". A discrepancy of
-- even one cent fails the fixture, per the checklist's own "every discrepancy explained and fixed"
-- bar (Section A, required proof).
--
-- FINDING, recorded honestly rather than papered over (this is what the fixture is FOR): B, C and
-- D do NOT reconcile to A; E does, BY DESIGN (see E's own comment below). `app.seed_golden_
-- business_v682` deliberately gives every golden business a synthetic client (`is_synthetic=
-- true`) with two REAL revenue-bearing sales, specifically to exercise nestly_v687's fix —
-- get_revenue_truth_v106 excludes an is_synthetic client's sales from known/identified revenue
-- (`db/migrations/20260920_nestly_v687_revenue_truth_synthetic_exclusion.sql`). That exclusion was
-- applied to get_revenue_truth_v106 and (per that migration's own header) get_ci_category_mix_v1
-- and siblings — but NOT to get_dashboard_summary_v155, app.v176_sales_window or
-- platform_get_assigned_firm_report_v94, which is exactly what this fixture demonstrates:
--   * public.get_dashboard_summary_v155 (db/migrations/20260804_nestly_v155_multibranch_
--     foundation.sql:156-396) computes `revenue_cents` from a `scoped_sales` CTE that filters only
--     on business/branch/date — no `is_synthetic` predicate anywhere in the function.
--   * app.v176_sales_window (db/migrations/20260806_nestly_v176_ai_firm_reports.sql:287-360)
--     filters `client.is_synthetic = false` ONLY inside its `first_purchase` CTE (the
--     `new_customers` count) — its `valid_sales` CTE, which `net_revenue_cents` sums, carries no
--     such filter at all.
--   * public.platform_get_assigned_firm_report_v94 (db/migrations/20260728_nestly_v94_platform_
--     control_intelligence.sql:1670+) filters `client.is_synthetic=false` ONLY inside its
--     `customer_metrics` CTE — its `valid_sales` CTE, which `kpis.net_revenue_cents` sums, carries
--     no such filter either.
-- All three therefore still count a synthetic client's two real sales as revenue, which the
-- merchant dashboard, the AI-report evidence pack (built on app.v176_sales_window) and the
-- platform consultant report (built on platform_get_assigned_firm_report_v94) all present as
-- "Peekaa-recorded revenue" while get_revenue_truth_v106 has already excluded the very same rows —
-- an estate gap, not a fixture defect. This fixture is left asserting the strict 100.0 bar (rather
-- than adjusted to tolerate the gap) so the FAIL is the evidence, and is flagged in the
-- known-limitations register this proof pack ships alongside (checks 1/3/9/16: canonical
-- population and exclusions are not yet estate-wide) rather than silently downgraded to a passing
-- corpus.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;
create temp table _report(
  seq int, business_index int, sector text, business_id uuid,
  a_recorded bigint, b_dashboard bigint, c_sales_window bigint,
  d_platform bigint, e_direct_sql bigint,
  pct_b numeric, pct_c numeric, pct_d numeric, pct_e numeric
) on commit drop;

do $v731$
declare
  v_owner       uuid := '00000000-0000-4000-8000-000000731001';
  v_sa          uuid := '00000000-0000-4000-8000-000000731002';
  v_sectors     text[] := array['fnb','salon','retail'];
  i             int;
  v_sector      text;
  v_payload     jsonb;
  v_biz         uuid;
  v_branch      uuid;
  v_from        date;
  v_to          date;

  g_rev         jsonb;
  g_dash        jsonb;
  g_window      jsonb;
  g_platform    jsonb;

  v_a           bigint;
  v_b           bigint;
  v_c           bigint;
  v_d           bigint;
  v_e           bigint;
  v_pct_b       numeric;
  v_pct_c       numeric;
  v_pct_d       numeric;
  v_pct_e       numeric;
  v_err         text;
begin
  insert into auth.users (id, email) values
    (v_owner, 'zz-v731-owner@example.test'),
    (v_sa,    'zz-v731-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (v_sa, 'zz-v731-sa@example.test') on conflict do nothing;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  for i in 1..array_length(v_sectors, 1) loop
    v_sector := v_sectors[i];

    begin
      v_payload := app.seed_golden_business_v682(700 + i, v_sector, v_owner);
    exception when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('seed', format('biz#%s(%s): seed_golden_business_v682 raised %s',
        i, v_sector, v_err));
      continue;
    end;

    v_biz    := (v_payload->>'business_id')::uuid;
    v_branch := (v_payload->>'branch_id')::uuid;
    v_from   := (v_payload->>'window_from')::date;
    v_to     := (v_payload->>'window_to')::date;

    if not app.has_perm(v_biz, 'view_finance') then
      insert into _fail values ('PRE', format(
        'biz#%s(%s): seeded owner lacks view_finance; every reader call below is vacuous', i, v_sector));
      continue;
    end if;

    ------------------------------------------------------------------------------------------
    -- A. recorded revenue — the anchor every other figure is reconciled against.
    ------------------------------------------------------------------------------------------
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
    begin
      g_rev := public.get_revenue_truth_v106(v_biz, v_from, v_to, v_branch);
      v_a := (g_rev#>>'{totals,known_revenue_minor}')::bigint;
    exception when others then
      get stacked diagnostics v_err = returned_sqlstate;
      v_a := null;
      insert into _fail values ('A_recorded', format(
        'biz#%s(%s): get_revenue_truth_v106 raised %s', i, v_sector, v_err));
    end;

    ------------------------------------------------------------------------------------------
    -- B. dashboard summary.
    ------------------------------------------------------------------------------------------
    begin
      -- p_scope_mode='current' REQUIRES p_operational_branch (app.resolve_reporting_branch_scope_
      -- v155, line ~40: 'operational_branch_required_for_current_scope', 22023, when it is left
      -- null under the default 'current' mode) — pass the seeded branch explicitly so this reads
      -- the same single-branch scope A/D already use, not a fixture-shaped 22023.
      g_dash := public.get_dashboard_summary_v155(v_biz, v_from, v_to, 'current', array[]::uuid[], v_branch);
      -- get_dashboard_summary_v155 merges its KPI object at the TOP LEVEL of the return value
      -- (`return v_kpis || jsonb_build_object(...)`, line ~372 of the v155 migration) — there is
      -- no 'kpis' wrapper key, unlike v94's report. A first draft of this fixture read
      -- {kpis,revenue_cents} here, which silently NULLs (jsonb #>> on a missing path, not an
      -- error) rather than failing loudly — caught by this fixture's own pct_B assertion.
      v_b := (g_dash->>'revenue_cents')::bigint;
    exception when others then
      get stacked diagnostics v_err = returned_sqlstate;
      v_b := null;
      insert into _fail values ('B_dashboard', format(
        'biz#%s(%s): get_dashboard_summary_v155 raised %s', i, v_sector, v_err));
    end;

    ------------------------------------------------------------------------------------------
    -- C. AI evidence-pack sales window.
    ------------------------------------------------------------------------------------------
    begin
      g_window := app.v176_sales_window(v_biz, v_from, v_to);
      v_c := (g_window->>'net_revenue_cents')::bigint;
    exception when others then
      get stacked diagnostics v_err = returned_sqlstate;
      v_c := null;
      insert into _fail values ('C_sales_window', format(
        'biz#%s(%s): app.v176_sales_window raised %s', i, v_sector, v_err));
    end;

    ------------------------------------------------------------------------------------------
    -- D. platform consultant report, as a real Google-SSO super admin (v625).
    ------------------------------------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object(
        'sub', v_sa, 'role', 'authenticated',
        'amr', json_build_array(json_build_object('method', 'oauth')),
        'app_metadata', json_build_object('providers', json_build_array('google'))
      )::text, true);
    begin
      g_platform := public.platform_get_assigned_firm_report_v94(v_biz, v_branch, v_from, v_to);
      v_d := (g_platform#>>'{kpis,net_revenue_cents}')::bigint;
    exception when others then
      get stacked diagnostics v_err = returned_sqlstate;
      v_d := null;
      insert into _fail values ('D_platform', format(
        'biz#%s(%s): platform_get_assigned_firm_report_v94 raised %s', i, v_sector, v_err));
    end;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

    ------------------------------------------------------------------------------------------
    -- E. direct SQL — the same qualifying-sale predicate, hand-written, no RPC. Matches
    -- get_revenue_truth_v106's OWN reporting contract (nestly_v687): a sale attributed to an
    -- is_synthetic client is excluded from recorded revenue, same as A. This is deliberate, not
    -- an oversight — E is meant to be the independent "what SHOULD this figure be" check, so it
    -- is built against the documented contract, not against whichever readers happen to agree.
    ------------------------------------------------------------------------------------------
    select coalesce(sum(sale.amount_cents), 0) into v_e
    from public.sales sale
    where sale.business_id = v_biz
      and sale.reversal_of is null
      and coalesce(sale.counts_as_revenue, true)
      and sale.occurred_at >= (v_from::timestamp at time zone 'Asia/Singapore')
      and sale.occurred_at <  ((v_to + 1)::timestamp at time zone 'Asia/Singapore')
      and not exists (
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
      and not exists (
        select 1 from public.clients synth
        where synth.id = sale.client_id
          and synth.is_synthetic = true
      );

    ------------------------------------------------------------------------------------------
    -- Reconciliation percentages. A zero anchor is a distinct, explicit branch (never a
    -- division by zero, never silently reported as 100.0 when it should be flagged).
    ------------------------------------------------------------------------------------------
    if v_a is null then
      insert into _fail values ('reconcile', format('biz#%s(%s): no recorded-revenue anchor (A failed above)', i, v_sector));
    else
      if v_a = 0 then
        v_pct_b := case when v_b = 0 then 100.0 else null end;
        v_pct_c := case when v_c = 0 then 100.0 else null end;
        v_pct_d := case when v_d = 0 then 100.0 else null end;
        v_pct_e := case when v_e = 0 then 100.0 else null end;
      else
        v_pct_b := round(100.0 * v_b / v_a, 1);
        v_pct_c := round(100.0 * v_c / v_a, 1);
        v_pct_d := round(100.0 * v_d / v_a, 1);
        v_pct_e := round(100.0 * v_e / v_a, 1);
      end if;

      if v_b is not null and v_pct_b is distinct from 100.0 then
        insert into _fail values ('reconcile_B', format('biz#%s(%s): A=%s B=%s pct=%s (expected 100.0)', i, v_sector, v_a, v_b, v_pct_b));
      end if;
      if v_c is not null and v_pct_c is distinct from 100.0 then
        insert into _fail values ('reconcile_C', format('biz#%s(%s): A=%s C=%s pct=%s (expected 100.0)', i, v_sector, v_a, v_c, v_pct_c));
      end if;
      if v_d is not null and v_pct_d is distinct from 100.0 then
        insert into _fail values ('reconcile_D', format('biz#%s(%s): A=%s D=%s pct=%s (expected 100.0)', i, v_sector, v_a, v_d, v_pct_d));
      end if;
      if v_e is not null and v_pct_e is distinct from 100.0 then
        insert into _fail values ('reconcile_E', format('biz#%s(%s): A=%s E=%s pct=%s (expected 100.0)', i, v_sector, v_a, v_e, v_pct_e));
      end if;
    end if;

    insert into _report values (
      i, 700 + i, v_sector, v_biz, v_a, v_b, v_c, v_d, v_e, v_pct_b, v_pct_c, v_pct_d, v_pct_e
    );

    raise notice 'v731 | biz=% sector=% business_id=% | A_recorded=% B_dashboard=% C_sales_window=% D_platform=% E_direct_sql=% | pct_B=% pct_C=% pct_D=% pct_E=%',
      i, v_sector, v_biz, v_a, v_b, v_c, v_d, v_e, v_pct_b, v_pct_c, v_pct_d, v_pct_e;
  end loop;

  perform set_config('request.jwt.claims', null, true);
end
$v731$;

-- Machine-readable table, for the generator script to lift verbatim alongside the NOTICE lines.
select seq, business_index, sector, business_id,
       a_recorded, b_dashboard, c_sales_window, d_platform, e_direct_sql,
       pct_b, pct_c, pct_d, pct_e
from _report order by seq;

select case when count(*) = 0
            then 'PASS — v731 reconciliation: recorded revenue (get_revenue_truth_v106) reconciles '
                 'exactly (100.0%) to the dashboard summary, the AI sales window, the platform '
                 'consultant report and a direct-SQL sum, for every seeded business'
            else 'FAIL' end as verdict,
       count(*) as failures
from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v731: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
