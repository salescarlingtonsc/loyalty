-- EXECUTED acceptance fixture for nestly_v737
-- (db/migrations/20260920_nestly_v737_synthetic_excluded_v83_shadow.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v737_corpus --migrated-only
--
-- WHY THIS EXISTS. nestly_v734's estate sweep reached every touched dashboard/report reader but
-- explicitly did NOT touch public.get_customer_intelligence_v83 or
-- public.get_ci_shadow_reconciliation_v685 (those two are re-emitted by nestly_v725, a migration
-- that landed the same day and was not in v734's scan). A refuter's scenario (owner principal, 5
-- real clients / 50000 cents / 8 visit-days, 1 synthetic client with 3 sales one fully reversed
-- (net 6000), 2 anonymous sales / 10000 cents) found both still broken:
--   * get_customer_intelligence_v83 reported summary.net_revenue_cents = 56000 (50000 real +
--     6000 synthetic net) instead of 50000, and listed the synthetic client inside customers[].
--   * get_ci_shadow_reconciliation_v685's independent oracle summed public.sales without any
--     synthetic-client predicate at all: 66000 (50000 real + 6000 synthetic net + 10000
--     anonymous) against the captured get_revenue_truth_v106 truth of 60000 (50000 identified +
--     10000 anonymous, synthetic already excluded there since nestly_v687) -- a false FAIL the
--     auditor would raise for every business that ever plants a synthetic client with real sales.
--
-- THE DECISION THIS FIXTURE DOCUMENTS (identified-only vs known revenue). v83's summary was
-- already structurally identified-only before this fix: 'net_revenue_cents' is built from the
-- period_revenue CTE, which requires sale.client_id is not null -- an anonymous sale never
-- reaches it. nestly_v737 does not change that shape. It only removes the synthetic client's row
-- from the client_metrics population (client.is_synthetic=false), which is sufficient to drop
-- both defects at once: the synthetic row disappears from customers[], and its net_revenue_cents
-- (which was being summed into summary.net_revenue_cents purely because that client's row still
-- existed in client_metrics) disappears with it. The corrected summary.net_revenue_cents (50000)
-- is asserted equal to get_revenue_truth_v106's identified_revenue_minor (50000) below -- v83's
-- summary is identified-only by design and now matches v106's identified figure exactly. v83 has
-- no "known revenue" (identified+anonymous) field to reconcile against v106's known_revenue_minor
-- (60000); if one is ever added, it should sum period_sales directly rather than client_metrics.
--
-- THE SECOND DECISION (independent-in-implementation, same population by design).
-- get_ci_shadow_reconciliation_v685's oracle stays a hand-written SQL sum against public.sales --
-- it is deliberately NOT a call to get_revenue_truth_v106 (see nestly_v685's own header: this is
-- an independent recomputation, not a wrapper, or a bug in v106 could never be caught by its own
-- shadow). nestly_v737 adds exactly the one predicate (`cross join lateral
-- app.analytics_sale_class_v1(s) sc ... and not sc.is_synthetic_client`) that keeps the oracle's
-- POPULATION matching v106's post-v687 population, without making the oracle a wrapper around
-- v106 itself -- same authority (app.analytics_sale_class_v1.is_synthetic_client), same shape
-- nestly_v687/v734 already used everywhere else, independent recomputation preserved.
--
-- TRUTH TABLE (predetermined, asserted with exact equality throughout, never `> 0`):
--   5 real clients, 8 sales, 8 distinct visit-days, totalling exactly 50000 cents (v734's own
--   real-client shape, reused verbatim for continuity with the corpus).
--   1 synthetic client (clients.is_synthetic=true), 3 sales: 4000 (day 8, FULLY REVERSED via a
--   native reversal_of row for -4000) + 3000 (day 9) + 3000 (day 10) -- unreversed net 6000.
--   2 anonymous sales (client_id null), 5000 + 5000 = 10000 cents (days 11-12).
--   -> get_revenue_truth_v106:      known_revenue_minor=60000, identified_revenue_minor=50000,
--                                   anonymous_revenue_minor=10000, completed_transactions=10.
--   -> get_customer_intelligence_v83 (fixed): summary.net_revenue_cents=50000 (== v106 identified),
--                                   customers[] excludes the synthetic client entirely.
--   -> get_ci_shadow_reconciliation_v685 (fixed): independent oracle known_revenue_minor=60000,
--                                   completed_transactions=10 -- equal to the captured truth on
--                                   both metrics -> overall_status='PASS'.
--   -> pre-fix (documented, not re-asserted here -- see the migration's own before/after proof):
--                                   v83 would have reported 56000 and listed the synthetic
--                                   client; the shadow oracle would have reported 66000/12
--                                   against a captured truth of 60000/10 -> overall_status='FAIL'.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v737$
declare
  v_owner   uuid := '00000000-0000-4000-8000-000000737001';
  v_sa      uuid := '00000000-0000-4000-8000-000000737002';
  v_biz     uuid := gen_random_uuid();
  v_branch  uuid := gen_random_uuid();
  v_today   date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_from    date := v_today - 45;
  v_to_incl date := v_today - 30;
  v_to_excl date := v_today - 29;

  v_cA uuid := gen_random_uuid();
  v_cB uuid := gen_random_uuid();
  v_cC uuid := gen_random_uuid();
  v_cD uuid := gen_random_uuid();
  v_cE uuid := gen_random_uuid();
  v_cS uuid := gen_random_uuid();  -- synthetic

  v_sale_syn1 uuid := gen_random_uuid();  -- the 4000-cent synthetic sale that gets reversed
  v_rev_syn1  uuid := gen_random_uuid();  -- its -4000 reversal row

  g          jsonb;
  v_err      text;
  v_val      bigint;
  v_val2     bigint;
  v_run_id   uuid;
  v_metrics  jsonb;
  v_metric   jsonb;
begin
  insert into auth.users (id, email) values
    (v_owner, 'zz-v737-owner@example.test'),
    (v_sa,    'zz-v737-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (v_sa, 'zz-v737-sa@example.test') on conflict do nothing;

  ----------------------------------------------------------------------------------------------
  -- control rows: business, branch, staff, workspace/subscription, reporting contract.
  ----------------------------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, industry, enabled_modules)
  values (v_biz, 'ZZ v737 synthetic v83 shadow', 'zz-v737-synth-v83-shadow', 'fnb',
          array['dashboard','dailyreport','clients','sales','reports','customerintel',
                'loyalty','retention']);

  insert into public.branches (id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'ZZ v737 branch', true, true);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values (v_biz, v_owner, 'owner', 'ZZ v737 owner', true, 'approved');

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (v_biz, 'approved', now(), 'v737 fixture')
  on conflict (business_id) do update
    set approval_status = 'approved', decided_at = now(), decision_reason = 'v737 fixture';

  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (v_biz, 'current', false)
  on conflict (business_id) do update set state = 'current', workspace_paused = false;

  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (v_biz, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update
    set status = 'active', payment_status = 'paid', current_period_end = now() + interval '30 days';

  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  values (v_biz, null,     2, '-infinity', 'Asia/Singapore', 'SGD', true),
         (v_biz, v_branch, 2, '-infinity', 'Asia/Singapore', 'SGD', true)
  on conflict do nothing;

  ----------------------------------------------------------------------------------------------
  -- 5 real clients + 1 synthetic client.
  ----------------------------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name, is_synthetic) values
    (v_cA, v_biz, 'ZZ v737 real A', false),
    (v_cB, v_biz, 'ZZ v737 real B', false),
    (v_cC, v_biz, 'ZZ v737 real C', false),
    (v_cD, v_biz, 'ZZ v737 real D', false),
    (v_cE, v_biz, 'ZZ v737 real E', false),
    (v_cS, v_biz, 'ZZ v737 synthetic', true);

  alter table public.sales disable trigger user;

  -- 5 real clients, 8 sales, 8 distinct visit-days, totalling exactly 50000 cents.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  select gen_random_uuid(), v_biz, v_branch, x.client_id, 'service', x.amount_cents,
         t.v_ts, t.v_ts, true, true, true, t.v_ts, 0, t.v_ts
    from (values
      (v_cA, 0,  5000::bigint),
      (v_cA, 1,  5000::bigint),
      (v_cB, 2, 10000::bigint),
      (v_cB, 3, 10000::bigint),
      (v_cC, 4,  5000::bigint),
      (v_cD, 5,  5000::bigint),
      (v_cE, 6,  5000::bigint),
      (v_cE, 7,  5000::bigint)
    ) as x(client_id, day_offset, amount_cents)
    cross join lateral (
      select ((v_from + x.day_offset)::timestamp + interval '12 hours')
               at time zone 'Asia/Singapore' as v_ts
    ) t;

  -- 1 synthetic client, 3 sales: day 8's 4000-cent sale is fully reversed (net 0), day 9/10 are
  -- untouched (3000 each) -- unreversed synthetic net = 6000.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  values
    (v_sale_syn1, v_biz, v_branch, v_cS, 'service', 4000,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore',
     (v_from + 8)::timestamp at time zone 'Asia/Singapore',
     true, true, true,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore', 0,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  select gen_random_uuid(), v_biz, v_branch, v_cS, 'service', x.amount_cents,
         t.v_ts, t.v_ts, true, true, true, t.v_ts, 0, t.v_ts
    from (values
      (v_cS, 9,  3000::bigint),
      (v_cS, 10, 3000::bigint)
    ) as x(client_id, day_offset, amount_cents)
    cross join lateral (
      select ((v_from + x.day_offset)::timestamp + interval '12 hours')
               at time zone 'Asia/Singapore' as v_ts
    ) t;

  -- the native full reversal of the day-8 synthetic sale (same guard token door
  -- public.reverse_sale() uses -- see db/tests/executed/v106_corpus_revenue_truth.sql's R2).
  perform set_config('app.sale_reversal_insert_id', v_rev_syn1::text, true);
  perform set_config('app.sale_reversal_original_id', v_sale_syn1::text, true);
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at,
    reversal_of, reversal_reason, reversal_actor, reversal_idempotency_key)
  values
    (v_rev_syn1, v_biz, v_branch, v_cS, 'service', -4000,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore',
     (v_from + 8)::timestamp at time zone 'Asia/Singapore',
     true, false, false,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore', 0,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore',
     v_sale_syn1, 'v737 fixture full reversal', v_owner, 'v737-syn1-reversal-1');
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);

  -- 2 anonymous sales, no client_id, 5000 + 5000 = 10000 cents.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  select gen_random_uuid(), v_biz, v_branch, null, 'service', x.amount_cents,
         t.v_ts, t.v_ts, true, true, false, t.v_ts, 0, t.v_ts
    from (values
      (11, 5000::bigint),
      (12, 5000::bigint)
    ) as x(day_offset, amount_cents)
    cross join lateral (
      select ((v_from + x.day_offset)::timestamp + interval '12 hours')
               at time zone 'Asia/Singapore' as v_ts
    ) t;

  alter table public.sales enable trigger user;

  ----------------------------------------------------------------------------------------------
  -- PRECONDITIONS.
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  if not app.is_salon_member(v_biz) then
    insert into _fail values ('pre-owner', 'the owner fixture row is not a salon member');
  end if;
  if not app.can_module(v_biz, 'customerintel') then
    insert into _fail values ('pre-owner-module', 'the owner does not resolve customerintel');
  end if;
  if not app.has_perm(v_biz, 'view_finance') then
    insert into _fail values ('pre-owner-perm', 'the owner does not resolve view_finance');
  end if;
  if app.v106_sale_residual_minor(v_sale_syn1, v_to_excl, clock_timestamp()) <> 0 then
    insert into _fail values ('pre-reversal', format(
      'the day-8 synthetic sale residual was %s, expected exactly 0 -- the reversal fixture '
      'itself is broken and nothing below would prove anything about synthetic exclusion',
      app.v106_sale_residual_minor(v_sale_syn1, v_to_excl, clock_timestamp())));
  end if;

  perform set_config('request.jwt.claims', json_build_object(
      'sub', v_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  if not app.is_super_admin() then
    insert into _fail values ('pre-sa',
      'the Google-session fixture user does not resolve is_super_admin() -- the capture/'
      'reconcile assertions below would be vacuous');
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  ----------------------------------------------------------------------------------------------
  -- A. get_revenue_truth_v106 -- the control (already fixed by nestly_v687, unaffected by
  --    this migration; asserted here as the fixed point every other figure is judged against).
  ----------------------------------------------------------------------------------------------
  begin
    g := public.get_revenue_truth_v106(v_biz, v_from, v_to_excl, v_branch);
    v_val  := (g #>> '{totals,known_revenue_minor}')::bigint;
    v_val2 := (g #>> '{totals,identified_revenue_minor}')::bigint;
    if v_val <> 60000 then
      insert into _fail values ('A_revenue_truth_known',
        format('known_revenue_minor = %s (expected 60000)', v_val));
    end if;
    if v_val2 <> 50000 then
      insert into _fail values ('A_revenue_truth_identified',
        format('identified_revenue_minor = %s (expected 50000)', v_val2));
    end if;
    if (g #>> '{totals,anonymous_revenue_minor}')::bigint <> 10000 then
      insert into _fail values ('A_revenue_truth_anonymous',
        format('anonymous_revenue_minor = %s (expected 10000)',
          g #>> '{totals,anonymous_revenue_minor}'));
    end if;
    if (g #>> '{totals,completed_transactions}')::bigint <> 10 then
      insert into _fail values ('A_revenue_truth_txns',
        format('completed_transactions = %s (expected 10)',
          g #>> '{totals,completed_transactions}'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('A_revenue_truth', format('raised %s', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- B. public.get_customer_intelligence_v83 -- summary.net_revenue_cents must equal v106's
  --    identified figure (50000), and the synthetic client must not appear in customers[].
  ----------------------------------------------------------------------------------------------
  begin
    g := public.get_customer_intelligence_v83(v_biz, v_branch, v_from, v_to_incl);
    v_val := (g #>> '{summary,net_revenue_cents}')::bigint;
    if v_val <> 50000 then
      insert into _fail values ('B1_v83_summary_revenue',
        format('summary.net_revenue_cents = %s (expected 50000, matching v106 identified)', v_val));
    end if;
    if exists (
      select 1 from jsonb_array_elements(g->'customers') row
       where (row->>'client_id')::uuid = v_cS
    ) then
      insert into _fail values ('B2_v83_roster',
        'the synthetic client appears inside customers[]');
    end if;
    if not exists (
      select 1 from jsonb_array_elements(g->'customers') row
       where (row->>'client_id')::uuid = v_cA
    ) then
      insert into _fail values ('B3_v83_roster_real_client_dropped',
        'a real client (A) unexpectedly disappeared from customers[] -- the fix over-reached');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('B_v83', format('raised %s', v_err));
  end;

  ----------------------------------------------------------------------------------------------
  -- C. app.ci_shadow_capture_v685 -> public.get_ci_shadow_reconciliation_v685, run as the
  --    SA-with-Google session (v685's own gate: shared CI gate + is_super_admin()).
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', v_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  begin
    v_run_id := app.ci_shadow_capture_v685(v_biz, v_from, v_to_excl);
  exception when others then
    get stacked diagnostics v_err = message_text;
    insert into _fail values ('C1_capture', format('ci_shadow_capture_v685 raised: %s', v_err));
  end;

  if v_run_id is null then
    insert into _fail values ('C1_capture', 'ci_shadow_capture_v685 returned no run id');
  else
    begin
      g := public.get_ci_shadow_reconciliation_v685(v_biz, v_run_id);
    exception when others then
      get stacked diagnostics v_err = message_text;
      insert into _fail values ('C2_reconcile',
        format('get_ci_shadow_reconciliation_v685 raised: %s', v_err));
    end;

    if g is not null then
      if (g->>'overall_status') <> 'PASS' then
        insert into _fail values ('C3_overall_status',
          format('overall_status = %s (expected PASS); payload = %s',
            g->>'overall_status', g::text));
      end if;
      v_metrics := g->'metrics';
      for v_metric in select * from jsonb_array_elements(v_metrics) loop
        if v_metric->>'metric' = 'known_revenue_minor' then
          if (v_metric->>'captured')::bigint <> 60000 then
            insert into _fail values ('C4_captured_known_revenue',
              format('captured known_revenue_minor = %s (expected 60000)',
                v_metric->>'captured'));
          end if;
          if (v_metric->>'independent')::bigint <> 60000 then
            insert into _fail values ('C5_independent_known_revenue',
              format('independent known_revenue_minor = %s (expected 60000, i.e. the oracle '
                     'still leaks the synthetic client''s net)', v_metric->>'independent'));
          end if;
          if v_metric->>'status' <> 'PASS' then
            insert into _fail values ('C6_known_revenue_status',
              format('known_revenue_minor status = %s (expected PASS)', v_metric->>'status'));
          end if;
        elsif v_metric->>'metric' = 'completed_transactions' then
          if (v_metric->>'captured')::bigint <> 10 then
            insert into _fail values ('C7_captured_txns',
              format('captured completed_transactions = %s (expected 10)',
                v_metric->>'captured'));
          end if;
          if (v_metric->>'independent')::bigint <> 10 then
            insert into _fail values ('C8_independent_txns',
              format('independent completed_transactions = %s (expected 10)',
                v_metric->>'independent'));
          end if;
          if v_metric->>'status' <> 'PASS' then
            insert into _fail values ('C9_txns_status',
              format('completed_transactions status = %s (expected PASS)', v_metric->>'status'));
          end if;
        end if;
      end loop;
    end if;
  end if;

  perform set_config('request.jwt.claims', null, true);

  raise notice 'v737 | business_id=% | real: 50000 cents / 8 visit-days (5 clients) | synthetic: 3 sales, one fully reversed, unreversed net 6000 cents (1 client, excluded) | anonymous: 10000 cents (2 sales) | v106 known=60000 identified=50000 | v83 summary=50000, roster excludes synthetic | shadow oracle=60000/10, overall_status=PASS',
    v_biz;
end
$v737$;

select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v737: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

select case when count(*) = 0
            then 'PASS — v737: get_customer_intelligence_v83 summary.net_revenue_cents=50000 '
                 '(matching get_revenue_truth_v106 identified_revenue_minor), customers[] '
                 'excludes the synthetic client, and get_ci_shadow_reconciliation_v685''s '
                 'independent oracle reconciles exactly to the captured truth (60000/10, '
                 'overall_status=PASS) for a business carrying a synthetic client with real, '
                 'partially-reversed sales'
            else 'FAIL' end as verdict,
       count(*) as failures
from _fail;

rollback;
