-- EXECUTED acceptance fixture for nestly_v685 — CI shadow reconciliation (check 99, machinery
-- half only).
--
-- Named for v685 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- AUTH CONTEXT. app.ci_shadow_capture_v685 calls get_ci_opportunities_v1 / get_revenue_truth_v106
-- / get_ci_funnel_conversion_v1 internally, all of which are gated in a way a super admin session
-- clears outright (app.ci_access_gate_v667 for the first and third, the is_super_admin() arm of
-- get_revenue_truth_v106's own check for the second) — same reasoning as v673/v674/v675's own
-- fixtures for using a platform session rather than building a fully operational merchant
-- workspace this phase is not testing. Per docs/qa/CI-CORPUS-FIXTURE-GUIDE.md, a platform session
-- needs the post-v625 Google-session claims (amr[0].method='oauth', app_metadata.providers
-- containing 'google') in addition to a public.super_admins row.
--
-- TRUTH TABLE (predetermined, asserted with exact equality throughout, never `> 0`):
--   window [v_from, v_to) = a 5-day window with no external commerce-event reconciliation rows
--   in scope, so the independent oracle's ledger-native-only rule and the real
--   get_revenue_truth_v106 agree EXACTLY (see the migration header's documented scope note on
--   why that agreement is not guaranteed in general).
--   sale1 kind='service' amount_cents=10000, sale2 kind='service' amount_cents=5000, both inside
--   the window, both counts_as_revenue=true via the v10 sale-policy default for kind='service'
--   (asserted as a precondition below, not assumed).
--   -> known_revenue_minor = 15000, completed_transactions = 2.
--
-- THREE THINGS PROVEN:
--   A. capture -> reconcile against UNCHANGED data: both metrics PASS, overall_status PASS,
--      and the captured/independent numbers printed alongside each other equal the truth table.
--   B. capture -> mutate the STORED payload's known_revenue_minor -> reconcile again: that one
--      metric is named FAIL with the exact expected delta; completed_transactions, untouched,
--      still PASSes — proving the harness reports PER-METRIC, not an all-or-nothing verdict.
--   C. the same reconciliation call, made by an authenticated user who is NOT a super admin,
--      is refused with sqlstate 42501 — the same refusal convention this migration's header
--      documents matching v66/v79/v86/v147.

\set ON_ERROR_STOP on

begin;
create temp table _fail(k text, v text) on commit drop;

do $v685$
declare
  biz         uuid := '00000000-0000-4000-8000-000000685001';
  u_sa        uuid := '00000000-0000-4000-8000-000000685101';
  u_plain     uuid := '00000000-0000-4000-8000-000000685102';
  sale1       uuid := '00000000-0000-4000-8000-000000685201';
  sale2       uuid := '00000000-0000-4000-8000-000000685202';

  v_today_sgt date := (now() at time zone 'Asia/Singapore')::date;
  v_from      date;
  v_to        date;

  v_run_id       uuid;
  v_recon        jsonb;
  v_recon2       jsonb;
  v_metrics      jsonb;
  v_metric       jsonb;
  v_revenue_status text;
  v_txns_status    text;
  v_err          text;
  v_sqlstate     text;
  v_found        boolean;
  v_counts_as_revenue boolean;
begin
  v_from := v_today_sgt - 10;
  v_to   := v_today_sgt - 5;

  ---------------------------------------------------------------------------
  -- actors, business
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_sa, 'zz-v685-sa@example.test'),
    (u_plain, 'zz-v685-plain@example.test')
  on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v685-sa@example.test')
    on conflict do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v685 shadow fixture', 'zz-v685-shadow', array['dashboard','clients','sales','reports']);

  -- v106 landmine (same one v678/v651's own fixtures document): get_revenue_truth_v106 joins
  -- every sale to app.v106_reporting_contract(business, branch, occurred_at) via an inner
  -- lateral join, so a sale with no matching contract row is silently dropped from the totals
  -- rather than erroring. These fixture sales carry branch_id=null, so the contract row must
  -- too, backdated well before the fixture window.
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, null, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;

  ---------------------------------------------------------------------------
  -- sales — 2 completed sales inside the window, no external reconciliation rows in scope
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (sale1, biz, null, 'service', 10000,
     (v_from + 1)::timestamp at time zone 'Asia/Singapore', (v_from + 1)::timestamp at time zone 'Asia/Singapore'),
    (sale2, biz, null, 'service', 5000,
     (v_from + 2)::timestamp at time zone 'Asia/Singapore', (v_from + 2)::timestamp at time zone 'Asia/Singapore');

  -- PRECONDITION: the v10 sale-policy default trigger must actually have marked both sales
  -- counts_as_revenue, or the 15000/2 truth table below asserts nothing real.
  select bool_and(coalesce(counts_as_revenue, false)) into v_counts_as_revenue
    from public.sales where id in (sale1, sale2);
  if not coalesce(v_counts_as_revenue, false) then
    insert into _fail values ('PRE-policy',
      'the v10 sale-policy trigger did not mark both fixture sales counts_as_revenue=true; '
      'the 15000/2 truth table below would assert nothing real');
  end if;

  ---------------------------------------------------------------------------
  -- A. capture, then reconcile against unchanged data — both metrics PASS
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  -- PRECONDITION: the fixture's platform session must actually be recognised as a super admin,
  -- or the capture/reconcile calls below and the later refusal test both prove nothing.
  if not app.is_super_admin() then
    insert into _fail values ('PRE-super-admin',
      'fixture super-admin session does not pass app.is_super_admin(); every assertion below '
      'would be vacuous');
  end if;

  begin
    v_run_id := app.ci_shadow_capture_v685(biz, v_from, v_to);
  exception when others then
    get stacked diagnostics v_err = message_text;
    insert into _fail values ('A1-capture', format('ci_shadow_capture_v685 raised: %s', v_err));
  end;

  if v_run_id is null then
    insert into _fail values ('A1-capture', 'ci_shadow_capture_v685 returned no run id');
  else
    begin
      v_recon := public.get_ci_shadow_reconciliation_v685(biz, v_run_id);
    exception when others then
      get stacked diagnostics v_err = message_text;
      insert into _fail values ('A2-reconcile',
        format('get_ci_shadow_reconciliation_v685 raised: %s', v_err));
    end;

    if v_recon is not null then
      if v_recon->>'overall_status' is distinct from 'PASS' then
        insert into _fail values ('A3-overall',
          format('expected overall_status PASS on unchanged data, got %s (full: %s)',
                 v_recon->>'overall_status', v_recon::text));
      end if;

      v_metrics := v_recon->'metrics';
      select m into v_metric from jsonb_array_elements(v_metrics) m
        where m->>'metric' = 'known_revenue_minor';
      if v_metric is null then
        insert into _fail values ('A4-revenue-metric', 'known_revenue_minor metric missing');
      else
        if (v_metric->>'captured')::bigint is distinct from 15000 then
          insert into _fail values ('A4-revenue-captured',
            format('expected captured known_revenue_minor 15000, got %s', v_metric->>'captured'));
        end if;
        if (v_metric->>'independent')::bigint is distinct from 15000 then
          insert into _fail values ('A4-revenue-independent',
            format('expected independent known_revenue_minor 15000, got %s', v_metric->>'independent'));
        end if;
        if (v_metric->>'delta')::bigint is distinct from 0 then
          insert into _fail values ('A4-revenue-delta',
            format('expected delta 0 on unchanged data, got %s', v_metric->>'delta'));
        end if;
        if v_metric->>'status' is distinct from 'PASS' then
          insert into _fail values ('A4-revenue-status',
            format('expected PASS, got %s', v_metric->>'status'));
        end if;
      end if;

      select m into v_metric from jsonb_array_elements(v_metrics) m
        where m->>'metric' = 'completed_transactions';
      if v_metric is null then
        insert into _fail values ('A5-txns-metric', 'completed_transactions metric missing');
      else
        if (v_metric->>'captured')::bigint is distinct from 2 then
          insert into _fail values ('A5-txns-captured',
            format('expected captured completed_transactions 2, got %s', v_metric->>'captured'));
        end if;
        if (v_metric->>'independent')::bigint is distinct from 2 then
          insert into _fail values ('A5-txns-independent',
            format('expected independent completed_transactions 2, got %s', v_metric->>'independent'));
        end if;
        if v_metric->>'status' is distinct from 'PASS' then
          insert into _fail values ('A5-txns-status',
            format('expected PASS, got %s', v_metric->>'status'));
        end if;
      end if;
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- B. mutate the STORED captured payload, reconcile again — only the mutated metric FAILs
  ---------------------------------------------------------------------------
  if v_run_id is not null then
    update app.ci_shadow_runs_v685
       set payload = jsonb_set(payload, '{get_revenue_truth_v106,totals,known_revenue_minor}', '99999'::jsonb)
     where id = v_run_id;

    begin
      v_recon2 := public.get_ci_shadow_reconciliation_v685(biz, v_run_id);
    exception when others then
      get stacked diagnostics v_err = message_text;
      insert into _fail values ('B1-reconcile',
        format('get_ci_shadow_reconciliation_v685 raised after mutation: %s', v_err));
    end;

    if v_recon2 is not null then
      if v_recon2->>'overall_status' is distinct from 'FAIL' then
        insert into _fail values ('B2-overall',
          format('expected overall_status FAIL after mutation, got %s', v_recon2->>'overall_status'));
      end if;

      select m into v_metric from jsonb_array_elements(v_recon2->'metrics') m
        where m->>'metric' = 'known_revenue_minor';
      if v_metric is null then
        insert into _fail values ('B3-revenue-metric', 'known_revenue_minor metric missing after mutation');
      else
        if v_metric->>'status' is distinct from 'FAIL' then
          insert into _fail values ('B3-revenue-status',
            format('expected FAIL for the mutated metric, got %s', v_metric->>'status'));
        end if;
        -- independent (15000, unchanged) - captured (99999, the mutated value) = -84999.
        if (v_metric->>'delta')::bigint is distinct from -84999 then
          insert into _fail values ('B3-revenue-delta',
            format('expected delta -84999 (15000 independent - 99999 mutated captured), got %s',
                   v_metric->>'delta'));
        end if;
        if (v_metric->>'independent')::bigint is distinct from 15000 then
          insert into _fail values ('B3-revenue-independent',
            format('the independent oracle must be unaffected by mutating the captured payload; '
                   'expected 15000, got %s', v_metric->>'independent'));
        end if;
      end if;

      -- The untouched metric must still PASS — this is the "PER-METRIC, not all-or-nothing" proof.
      select m into v_metric from jsonb_array_elements(v_recon2->'metrics') m
        where m->>'metric' = 'completed_transactions';
      if v_metric is null then
        insert into _fail values ('B4-txns-metric', 'completed_transactions metric missing after mutation');
      elsif v_metric->>'status' is distinct from 'PASS' then
        insert into _fail values ('B4-txns-status',
          format('the untouched completed_transactions metric must still PASS, got %s',
                 v_metric->>'status'));
      end if;
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- C. a non-super-admin, authenticated caller is refused — sqlstate 42501, no partial data
  ---------------------------------------------------------------------------
  if v_run_id is not null then
    perform set_config('request.jwt.claims', json_build_object(
        'sub', u_plain, 'role', 'authenticated'
      )::text, true);

    -- PRECONDITION: the denial must be earned — u_plain must genuinely not be a super admin,
    -- or the refusal test below proves nothing (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md's own
    -- "assert your preconditions" rule).
    if app.is_super_admin() then
      insert into _fail values ('PRE-plain-not-admin',
        'fixture non-admin session unexpectedly passes app.is_super_admin(); the refusal test '
        'below would prove nothing');
    end if;

    v_sqlstate := null;
    begin
      perform public.get_ci_shadow_reconciliation_v685(biz, v_run_id);
      insert into _fail values ('C1-refusal',
        'get_ci_shadow_reconciliation_v685 must refuse a non-super-admin caller, but it returned '
        'a result instead of raising');
    exception when others then
      get stacked diagnostics v_sqlstate = returned_sqlstate;
    end;
    if v_sqlstate is not null and v_sqlstate is distinct from '42501' then
      insert into _fail values ('C2-sqlstate',
        format('expected sqlstate 42501 for a non-super-admin caller, got %s', v_sqlstate));
    end if;
  end if;
end
$v685$;

select case when count(*)=0 then 'PASS — capture/reconcile agrees on unchanged data, a mutated '
  'metric is named FAIL while the untouched one still PASSes, and a non-super-admin caller is '
  'refused 42501' else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v685: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
