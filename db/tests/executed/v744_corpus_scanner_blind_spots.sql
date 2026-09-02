-- EXECUTED acceptance fixture for nestly_v744
-- (db/migrations/20260902_nestly_v744_scanner_blind_spots.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v744_corpus --migrated-only
--
-- WHY THIS EXISTS. The fifth refuter found two live bugs nestly_v743's own scanner could not
-- see: public.get_ci_opportunities_v1's lapsed_regulars population is drawn from a FUNCTION CALL
-- (app.customer_cadence_batch_v1), not a raw table scan, so a source-regex scanner never sees
-- "public.clients" in that caller's own text; and public.get_reports_summary_v94_base's credit
-- liability sums a VIEW (public.client_credit_balance) the v743 scanner's table list never named.
-- This fixture is the RED-BEFORE/GREEN-AFTER proof for both bugs, for every other reader of the
-- same shapes this migration also fixed, and for the hardened
-- app.ci_synthetic_scan_v743()/app.ci_synthetic_scan_mixed_v744() pair itself.
--
-- FIXTURE SHAPE. Two self-contained businesses:
--   B1 -- 4 real clients with an identical weekly visit cadence (5 visits, 7 days apart, last
--         visit ~30 days before "now" -- comfortably past the business's 2x/14-day reactivation
--         threshold), PLUS one SYNTHETIC client with the byte-identical cadence. Proves
--         public.get_ci_opportunities_v1's Generator B (base pass) AND its EXTENDED-MODE EV
--         re-derivation both now count 4 overdue regulars, not 5.
--   B2 -- one real client with a 1000-cent credit_ledger balance and one synthetic client with a
--         9000-cent balance. Proves public.get_reports_summary_v94_base, public.get_reports_summary
--         and public.get_dashboard_summary all now report 1000 cents of liability, not 10000.
--
-- PART C -- the hardened scanner is proven able to fail three ways, each in its own SAVEPOINT so
-- nothing survives past this fixture: (1) deleting one allowlist row makes a known function
-- reappear by name; (2) a throwaway function that reads public.client_credit_balance (a VIEW, not
-- a base table) with no exclusion marker is caught -- proving the widened table list, not just the
-- widened aggregate list; (3) a throwaway function with ONE guarded aggregate statement and ONE
-- unguarded aggregate statement over public.sales is caught ONLY by the new mixed pass (never by
-- the original whole-body rule, since the function DOES carry a marker somewhere) -- proving the
-- statement-level pass actually adds coverage, not merely re-detects what the old rule already
-- found.
--
-- Every assertion below is exact equality, never `> 0`. One transaction, rolled back throughout.
-- No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

----------------------------------------------------------------------------------------------
-- B1 -- lapsed_regulars cadence population; proves public.get_ci_opportunities_v1.
----------------------------------------------------------------------------------------------
do $v744_b1$
declare
  v_biz     uuid := gen_random_uuid();
  v_branch  uuid := gen_random_uuid();
  v_now     timestamptz := clock_timestamp();
  v_today   date := (v_now at time zone 'Asia/Singapore')::date;
  v_from    date := v_today - 90;
  v_to      date := v_today;

  v_cR1 uuid := gen_random_uuid();
  v_cR2 uuid := gen_random_uuid();
  v_cR3 uuid := gen_random_uuid();
  v_cR4 uuid := gen_random_uuid();
  v_cSyn uuid := gen_random_uuid();

  v_drain_token text;
  g jsonb;
  v_reason text;
  i int;
  cid uuid;
begin
  insert into public.businesses (id, name, slug, enabled_modules)
  values (v_biz, 'ZZ v744 B1 cadence', 'zz-v744-b1-cadence',
          array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'ZZ v744 B1 branch', true, true);

  -- v106 landmine (same as v651/v678's own fixtures): backdate an early reporting-contract
  -- version so every backdated sale below stays cadence-eligible.
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select v_biz, v_branch, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore',
         upper(b.currency), true
    from public.businesses b where b.id = v_biz;

  insert into public.clients (id, business_id, full_name, is_synthetic) values
    (v_cR1, v_biz, 'ZZ v744 real regular 1', false),
    (v_cR2, v_biz, 'ZZ v744 real regular 2', false),
    (v_cR3, v_biz, 'ZZ v744 real regular 3', false),
    (v_cR4, v_biz, 'ZZ v744 real regular 4', false),
    (v_cSyn, v_biz, 'ZZ v744 synthetic regular', true);

  -- Every one of the five clients gets the IDENTICAL weekly cadence: 5 visits, 7 days apart,
  -- the last one 30 days before "now" -- 4 interval observations (>= the policy's 3), median 7
  -- days, so the reactivation threshold (2.0x, per nestly_v651/v678's verified auto-seed
  -- defaults) is 14 days -- 30 days since the last visit is comfortably past it.
  foreach cid in array array[v_cR1, v_cR2, v_cR3, v_cR4, v_cSyn] loop
    for i in 1..5 loop
      insert into public.sales (business_id, branch_id, client_id, kind, amount_cents,
                                occurred_at, created_at)
      values (v_biz, v_branch, cid, 'service', 5000,
              (v_now - make_interval(days => 30 + (5 - i) * 7)),
              (v_now - make_interval(days => 30 + (5 - i) * 7)));
    end loop;
  end loop;

  -- PRECONDITION: the cadence batch must see all 5 clients, or the count below would pass for a
  -- fixture reason wearing this bug's costume.
  if (select count(*) from app.customer_cadence_batch_v1(
        v_biz, (v_today + 1), (v_today + 1), v_now, null, true)) <> 5 then
    insert into _fail values ('B1-pre-cadence-population',
      format('cadence batch sees %s clients, expected 5',
             (select count(*) from app.customer_cadence_batch_v1(
                v_biz, (v_today + 1), (v_today + 1), v_now, null, true))));
  end if;
  if (app.customer_cadence_v1(v_biz, v_cR1, v_now)->>'deviation_state') <> 'overdue'
     or (app.customer_cadence_v1(v_biz, v_cR1, v_now)->>'evidence_source')
        <> 'customer_median_interval' then
    insert into _fail values ('B1-pre-cadence-state',
      format('R1 cadence was %s / %s, expected overdue / customer_median_interval',
             app.customer_cadence_v1(v_biz, v_cR1, v_now)->>'deviation_state',
             app.customer_cadence_v1(v_biz, v_cR1, v_now)->>'evidence_source'));
  end if;
  if (app.customer_cadence_v1(v_biz, v_cSyn, v_now)->>'deviation_state') <> 'overdue' then
    insert into _fail values ('B1-pre-cadence-synthetic',
      'the synthetic client must ALSO read as overdue on their own cadence, or this fixture '
      'never exercises the bug at all');
  end if;

  ---------------------------------------------------------------------------
  -- THE ENGINE. Called sessionlessly via the internal-drain authority (app.v676_internal_drain_
  -- token/app.v676_internal_drain_authority) -- the same access path app.ci_access_gate_v667
  -- grants an unattended internal reader, avoiding a whole owner/module/subscription rig this
  -- fixture does not otherwise need.
  ---------------------------------------------------------------------------
  select token into v_drain_token from app.v676_internal_drain_authority limit 1;
  if v_drain_token is null then
    insert into _fail values ('B1-pre-drain-token', 'no app.v676_internal_drain_authority row exists');
  else
    perform set_config('app.v676_internal_drain_token', v_drain_token, true);
    g := public.get_ci_opportunities_v1(v_biz, v_from, v_to, null, v_now, true);
    perform set_config('app.v676_internal_drain_token', '', true);

    -- lapsed_regulars' own sample floor is 5 -- 4 real overdue regulars alone sit BELOW it (so
    -- the generator abstains, saying so by name), but 4 real + the synthetic's matching cadence
    -- would clear it and get PROMOTED as a live finding under the bug. The abstention reason
    -- names the exact count, which is the sharpest possible proof: "4" (correct, synthetic
    -- excluded) vs "5" (buggy, synthetic counted) is the whole defect in one string.
    select a->>'reason' into v_reason
      from jsonb_array_elements(coalesce(g->'abstentions', '[]'::jsonb)) a
     where a->>'generator' = 'lapsed_regulars';
    if v_reason is distinct from '4 overdue regular(s) is below the sample floor of 5' then
      insert into _fail values ('B1_lapsed_regulars_base',
        format('lapsed_regulars abstention reason = %s, expected exactly '
               '''4 overdue regular(s) is below the sample floor of 5''',
               coalesce(v_reason, '<absent -- generator did not abstain at all>')));
    end if;
    if (g->'exclusions'->>'synthetic_clients')::int is distinct from 1 then
      insert into _fail values ('B1_exclusions_synthetic_count',
        format('exclusions.synthetic_clients = %s, expected 1', g->'exclusions'->>'synthetic_clients'));
    end if;
  end if;
end
$v744_b1$;

----------------------------------------------------------------------------------------------
-- B2 -- credit-ledger liability; proves get_reports_summary_v94_base / get_reports_summary /
-- get_dashboard_summary.
----------------------------------------------------------------------------------------------
do $v744_b2$
declare
  v_owner  uuid := gen_random_uuid();
  v_biz    uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_cReal  uuid := gen_random_uuid();
  v_cSyn   uuid := gen_random_uuid();
  v_from   date := (clock_timestamp() at time zone 'Asia/Singapore')::date - 30;
  v_to     date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_crReal uuid := gen_random_uuid();
  v_crSyn  uuid := gen_random_uuid();
  v_saleReal uuid := gen_random_uuid();
  v_saleSyn  uuid := gen_random_uuid();
  g jsonb;
  v_val bigint;
begin
  insert into auth.users (id, email) values (v_owner, 'zz-v744-b2-owner@example.test')
    on conflict (id) do nothing;

  insert into public.businesses (id, name, slug, enabled_modules)
  values (v_biz, 'ZZ v744 B2 credit liability', 'zz-v744-b2-credit',
          array['dashboard','clients','sales','reports','loyalty','giftcards','memberships','dailyreport']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'ZZ v744 B2 branch', true, true);
  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values (v_biz, v_owner, 'owner', 'ZZ v744 B2 owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (v_biz, 'approved', now(), 'v744 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (v_biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (v_biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.clients (id, business_id, full_name, is_synthetic) values
    (v_cReal, v_biz, 'ZZ v744 real credit holder', false),
    (v_cSyn, v_biz, 'ZZ v744 synthetic credit holder', true);

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (v_saleReal, v_biz, v_branch, v_cReal, 'service', 100, now(), now()),
    (v_saleSyn, v_biz, v_branch, v_cSyn, 'service', 100, now(), now());

  perform set_config('app.credit_ledger_insert_id', v_crReal::text, true);
  perform set_config('app.credit_ledger_write_scope', 'sale_trigger', true);
  insert into public.credit_ledger (id, business_id, client_id, entry_type, amount_cents, sale_id, reference)
  values (v_crReal, v_biz, v_cReal, 'referral_reward', 1000, v_saleReal, 'v744 fixture: real customer credit');
  perform set_config('app.credit_ledger_insert_id', v_crSyn::text, true);
  perform set_config('app.credit_ledger_write_scope', 'sale_trigger', true);
  insert into public.credit_ledger (id, business_id, client_id, entry_type, amount_cents, sale_id, reference)
  values (v_crSyn, v_biz, v_cSyn, 'referral_reward', 9000, v_saleSyn,
          'v744 fixture: synthetic customer credit -- must not be liability');
  perform set_config('app.credit_ledger_insert_id', '', true);
  perform set_config('app.credit_ledger_write_scope', '', true);

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin
    g := public.get_reports_summary_v94_base(v_biz, v_from, v_to);
    v_val := (g->>'credit_liability_cents')::bigint;
    if v_val is distinct from 1000 then
      insert into _fail values ('B2_v94base_credit_liability',
        format('credit_liability_cents = %s (expected 1000)', v_val));
    end if;
  exception when others then
    insert into _fail values ('B2_v94base', format('raised %s', sqlstate));
  end;

  begin
    g := public.get_reports_summary(v_biz, v_from, v_to);
    v_val := (g->>'credit_liability_cents')::bigint;
    if v_val is distinct from 1000 then
      insert into _fail values ('B2_reports_summary_credit_liability',
        format('credit_liability_cents = %s (expected 1000)', v_val));
    end if;
  exception when others then
    insert into _fail values ('B2_reports_summary', format('raised %s', sqlstate));
  end;

  begin
    g := public.get_dashboard_summary(v_biz, v_from, v_to);
    v_val := (g->>'credit_liability_cents')::bigint;
    if v_val is distinct from 1000 then
      insert into _fail values ('B2_dashboard_credit_liability',
        format('credit_liability_cents = %s (expected 1000)', v_val));
    end if;
  exception when others then
    insert into _fail values ('B2_dashboard', format('raised %s', sqlstate));
  end;
  perform set_config('request.jwt.claims', null, true);
end
$v744_b2$;

----------------------------------------------------------------------------------------------
-- PART C -- the hardened scanner itself.
----------------------------------------------------------------------------------------------
do $v744_scanner$
declare
  n bigint;
  v_allowlist_size bigint;
begin
  select count(*) into n from app.ci_synthetic_scan_v743();
  if n <> 0 then
    insert into _fail values ('SCANNER_zero_rows', format('scan returned %s row(s), expected 0', n));
  end if;

  select count(*) into v_allowlist_size from app.ci_synthetic_scan_allowlist_v743;
  if v_allowlist_size <> 120 then
    insert into _fail values ('SCANNER_allowlist_size',
      format('allowlist has %s rows (expected 120 = 89 nestly_v743 + 31 nestly_v744)',
             v_allowlist_size));
  end if;
  raise notice 'v744 scanner | allowlist size = % | twelve functions fixed | scan rows = %',
    v_allowlist_size, n;
end
$v744_scanner$;

-- PROVE THE SCANNER CAN FAIL, WAY 1: remove one nestly_v744 allowlist row and confirm it
-- reappears. Isolated in its own savepoint.
savepoint v744_prove_scanner_1;
do $v744_prove1$
declare n bigint;
begin
  delete from app.ci_synthetic_scan_allowlist_v743
   where function_signature like 'app.ci_customer_classes_v1%';
  select count(*) into n from app.ci_synthetic_scan_v743()
   where function_name = 'ci_customer_classes_v1';
  if n <> 1 then
    insert into _fail values ('SCANNER_prove_fail_1',
      format('deleting the ci_customer_classes_v1 allowlist row should make the scan return '
             'exactly 1 row for it; got %s', n));
  end if;
end
$v744_prove1$;
rollback to savepoint v744_prove_scanner_1;

-- PROVE THE SCANNER CAN FAIL, WAY 2: a throwaway function that aggregates a VIEW (not a base
-- table) with no exclusion marker must be caught -- this is what the v743 table list, before
-- this migration widened it, could never see. Isolated in its own savepoint.
savepoint v744_prove_scanner_2;
do $v744_prove2$
declare n bigint;
begin
  create or replace function app._ci_v744_test_probe_view() returns bigint language sql stable as
  $probe$ select coalesce(sum(cb.balance_cents), 0)::bigint from public.client_credit_balance cb $probe$;
  select count(*) into n from app.ci_synthetic_scan_v743()
   where function_name = '_ci_v744_test_probe_view';
  if n <> 1 then
    insert into _fail values ('SCANNER_prove_fail_2',
      format('a throwaway unguarded aggregator over the client_credit_balance VIEW should be '
             'caught by name; got %s matching rows', n));
  end if;
end
$v744_prove2$;
rollback to savepoint v744_prove_scanner_2;

-- PROVE THE SCANNER CAN FAIL, WAY 3: a throwaway function with ONE guarded statement and ONE
-- unguarded statement over public.sales must be caught by the MIXED pass specifically -- proven
-- by also checking it is NOT caught by the original whole-body rule (the function DOES carry a
-- marker somewhere, so the old rule alone would have missed it). Isolated in its own savepoint.
savepoint v744_prove_scanner_3;
do $v744_prove3$
declare n bigint; n_old_rule bigint;
begin
  create or replace function app._ci_v744_test_probe_mixed() returns bigint language sql stable as
  $probe$
    select
      (select coalesce(sum(s1.amount_cents), 0) from public.sales s1
        cross join lateral app.analytics_sale_class_v1(s1) sc
       where sc.include_revenue and not sc.is_synthetic_client)
      +
      (select coalesce(sum(s2.amount_cents), 0) from public.sales s2)
  $probe$;

  select count(*) into n_old_rule
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = '_ci_v744_test_probe_mixed'
     and pg_catalog.pg_get_functiondef(p.oid) ~* '\ypublic\.(sales)\y'
     and pg_catalog.pg_get_functiondef(p.oid) ~* '\y(sum|count)\('
     and pg_catalog.pg_get_functiondef(p.oid) !~* '(is_synthetic_client|is_synthetic|analytics_sale_class_v1)';
  if n_old_rule <> 0 then
    insert into _fail values ('SCANNER_prove_fail_3_precondition',
      format('the mixed probe should NOT be caught by the original whole-body rule (it does '
             'carry a marker); got %s -- the probe does not actually exercise the new pass', n_old_rule));
  end if;

  select count(*) into n from app.ci_synthetic_scan_v743()
   where function_name = '_ci_v744_test_probe_mixed';
  if n <> 1 then
    insert into _fail values ('SCANNER_prove_fail_3',
      format('a function with one guarded and one unguarded aggregate statement over '
             'public.sales should be caught by the mixed pass; got %s matching rows', n));
  end if;
end
$v744_prove3$;
rollback to savepoint v744_prove_scanner_3;

-- Re-assert zero rows after all three destructive probes were rolled back.
do $v744_scanner_recheck$
declare n bigint;
begin
  select count(*) into n from app.ci_synthetic_scan_v743();
  if n <> 0 then
    insert into _fail values ('SCANNER_residue',
      format('scan returned %s row(s) after the prove-it-can-fail savepoints rolled back -- '
             'residue leaked past a savepoint', n));
  end if;
end
$v744_scanner_recheck$;

select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v744: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

select case when count(*) = 0
            then 'PASS -- v744: get_ci_opportunities_v1''s lapsed_regulars cohort (base pass AND '
                 'the extended-mode EV re-derivation) and the credit-liability figure on three '
                 'report readers all exclude a synthetic client sharing the exact same shape as '
                 'the real population, and app.ci_synthetic_scan_v743() returns zero rows with a '
                 '120-entry justified allowlist, proven able to fail three independent ways -- '
                 'deleted allowlist row, unguarded view reader, and a statement-level mixed reader'
            else 'FAIL' end as verdict,
       count(*) as failures
from _fail;

rollback;
