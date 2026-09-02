-- v722 corpus — shared-envelope freshness (check 97), consultant-brief evidence (check 93), the
-- new platform auth arm on public.platform_customer_account_opens_v175, and an estate-wide
-- signature-drift scan across every public.get_ci_* reader (check 98).
--
-- Reads db/migrations/20260902_nestly_v722_freshness_and_brief_evidence.sql. Runs ABOVE the v422
-- baseline watermark, so it is reported `n/a` in the pre-migration phase and gated on the
-- migrated run.
--
-- TRUTH TABLE (numbers computed before running anything, per CI-CORPUS-FIXTURE-GUIDE):
--   F1  a reader with NO local 'freshness' key (get_ci_demographics_v1), one sale ~1 hour old:
--       freshness.stale=false, data_as_of = that sale's occurred_at, age_hours < 2.
--   F2  same reader, one sale ~100 hours old: freshness.stale=true, age_hours > 48.
--   F3  same reader, ZERO sales at all: freshness.data_as_of is null, freshness.stale=true.
--   F4  two branches on one business, branch A's sale ~1 hour old, branch B's ~100 hours old:
--       p_branch=A -> stale=false; p_branch=B -> stale=true (branch scoping is real, not a
--       business-wide max leaking across branches).
--   F5  get_ci_opportunities_v1 (HAS its own local freshness) under a far-future as_of: still
--       refuses to rank (refusal_reason='stale_evidence', unchanged from v680_corpus E8) and its
--       'freshness' object still carries ITS OWN key 'observed_since_min' and does NOT carry the
--       new 'data_as_of'/'age_hours' keys -- proof the envelope passed it through byte-for-byte
--       rather than overwriting it.
--   F6  F1's payload: top-level 'observed_since' (metric_observed_since_v1) equals
--       freshness.observed_since exactly (both null is an equal pass).
--   K1  platform_get_assigned_firm_report_v94 on a business with ZERO clients: evidence
--       {n:0, floor:5, status:'insufficient'}; kpis.status / cohorts.status /
--       customer_intelligence.status = 'unavailable'; kpis.average_order_cents and
--       customer_intelligence.top_customer_revenue_cents are null; every COUNT
--       (kpis.visits/active_customers/returning_customers/net_revenue_cents, every cohort count,
--       customer_intelligence.total_customers/customers_with_purchase/
--       customers_over_90_days_inactive) is present and 0, never null.
--   K2  same reader on a business with 5 clients, two of whom have one sale each (1000 and 2000
--       cents): evidence {n:5, floor:5, status:'ok'}; every *.status = 'ok';
--       kpis.average_order_cents = 1500 (round(avg(1000,2000))); top_customer_revenue_cents =
--       2000 (max per-client revenue); active_customers = 2.
--   A1  platform_customer_account_opens_v175 as a consultant assigned to the business (no
--       has_perm view_finance, no v89 platform grant, not a super admin) now SUCCEEDS -- refused
--       before v722.
--   A2  the same call as an unrelated stranger (no assignment, no grant, no admin) is still
--       REFUSED, 42501 -- the fix adds one arm, it does not open the gate.
--   R1  every public.get_ci_* reader that takes p_business and does not require a p_run_id
--       (documented exclusion: get_ci_shadow_reconciliation_v685, a super-admin-only independent
--       oracle, not a scoped report reader) is called, with reasonable defaults for every other
--       parameter by name, for an EMPTY business as its owner and again as its assigned
--       consultant. A genuine authorization refusal (42501, insufficient_privilege) is not a
--       signature-drift bug and is tolerated; any OTHER exception -- undefined function, wrong
--       argument types, an unresolved overload -- is a real failure, named. Every call that is
--       NOT refused must return a payload carrying both 'exclusions' and 'freshness'.
--
-- Named for v722: every assertion must FAIL against the pre-v722 engine. One transaction, rolled
-- back. No production access.

\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

do $v722$
declare
  -- F1/F6
  biz_f1 uuid := '00000000-0000-4000-8000-000000722011';
  br_f1  uuid := '00000000-0000-4000-8000-000000722012';
  c_f1   uuid := '00000000-0000-4000-8000-000000722013';
  s_f1   uuid := '00000000-0000-4000-8000-000000722014';
  r_f1   jsonb;

  -- F2/F5
  biz_f2 uuid := '00000000-0000-4000-8000-000000722021';
  br_f2  uuid := '00000000-0000-4000-8000-000000722022';
  c_f2   uuid := '00000000-0000-4000-8000-000000722023';
  s_f2   uuid := '00000000-0000-4000-8000-000000722024';
  r_f2   jsonb;
  r_f5   jsonb;

  -- F3
  biz_f3 uuid := '00000000-0000-4000-8000-000000722031';
  r_f3   jsonb;

  -- F4
  biz_f4  uuid := '00000000-0000-4000-8000-000000722041';
  br_f4a  uuid := '00000000-0000-4000-8000-000000722042';
  br_f4b  uuid := '00000000-0000-4000-8000-000000722043';
  c_f4a   uuid := '00000000-0000-4000-8000-000000722044';
  c_f4b   uuid := '00000000-0000-4000-8000-000000722045';
  s_f4a   uuid := '00000000-0000-4000-8000-000000722046';
  s_f4b   uuid := '00000000-0000-4000-8000-000000722047';
  r_f4a   jsonb;
  r_f4b   jsonb;

  -- K1 (empty, zero clients); K2 (rich)
  biz_k1  uuid := '00000000-0000-4000-8000-000000722051';
  br_k1   uuid := '00000000-0000-4000-8000-000000722052';
  biz_k2  uuid := '00000000-0000-4000-8000-000000722061';
  br_k2   uuid := '00000000-0000-4000-8000-000000722062';
  c_k2a   uuid := '00000000-0000-4000-8000-000000722063';
  c_k2b   uuid := '00000000-0000-4000-8000-000000722064';
  c_k2c   uuid := '00000000-0000-4000-8000-000000722065';
  c_k2d   uuid := '00000000-0000-4000-8000-000000722066';
  c_k2e   uuid := '00000000-0000-4000-8000-000000722067';
  s_k2a   uuid := '00000000-0000-4000-8000-000000722068';
  s_k2b   uuid := '00000000-0000-4000-8000-000000722069';
  r_k1    jsonb;
  r_k2    jsonb;

  -- R1 estate scan: a separate "empty" business (zero sales, zero revenue) that carries exactly
  -- ONE client, purely so public.get_ci_customer_records_v1 -- a drill-down reader whose p_client
  -- argument is a required, business-specific selector, not a nullable filter like a taxonomy
  -- node -- has a real id to be called with. K1 stays a strictly zero-client business so its own
  -- assertions (evidence n=0, every count 0) are not disturbed by this.
  biz_r  uuid := '00000000-0000-4000-8000-000000722071';
  br_r   uuid := '00000000-0000-4000-8000-000000722072';
  c_r    uuid := '00000000-0000-4000-8000-000000722073';
  cons_r_id uuid := '00000000-0000-4000-8000-000000722074';
  co_r_id   uuid := '00000000-0000-4000-8000-000000722075';

  -- actors
  u_sa      uuid := '00000000-0000-4000-8000-000000722101';
  u_owner   uuid := '00000000-0000-4000-8000-000000722102';
  u_cons    uuid := '00000000-0000-4000-8000-000000722103';
  u_stranger uuid := '00000000-0000-4000-8000-000000722104';
  cons_id   uuid := '00000000-0000-4000-8000-000000722105';
  co_id     uuid := '00000000-0000-4000-8000-000000722106';

  d_from date := current_date - 10;
  d_to   date := current_date;
  v_err  text;
  v_payload jsonb;
  v_now timestamptz := clock_timestamp();

  -- R-series
  rec record;
  v_call text;
  v_refused boolean;
begin
  ---------------------------------------------------------------------------
  -- actors
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_sa, 'zz-v722-sa@example.test'), (u_owner, 'zz-v722-owner@example.test'),
    (u_cons, 'zz-v722-cons@example.test'), (u_stranger, 'zz-v722-stranger@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (u_sa, 'zz-v722-sa@example.test') on conflict do nothing;

  -- The F-series only cares about the shared envelope's freshness computation, not entitlement,
  -- so every F-series reader call runs as a real-session super admin (passes every CI reader's
  -- gate via app.v176_can_read_firm_report, incl. the branch-restriction check in F4).
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  if not app.is_super_admin() then
    insert into _fail values ('pre-sa-f', 'fixture super admin session does not resolve is_super_admin(); F-series would be vacuous');
  end if;

  ---------------------------------------------------------------------------
  -- F1/F6 — one sale ~1 hour old, no local freshness key on the reader
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz_f1, 'ZZ v722 F1 firm', 'zz-v722-f1',
     array['dashboard','clients','sales','reports','customerintel']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br_f1, biz_f1, 'ZZ v722 F1 branch', true, true);
  insert into public.clients (id, business_id, full_name) values (c_f1, biz_f1, 'ZZ v722 f1 client');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (s_f1, biz_f1, br_f1, c_f1, 'service', 500, v_now - interval '1 hour', v_now - interval '1 hour');

  r_f1 := public.get_ci_demographics_v1(biz_f1, d_from, d_to, null, v_now);
  if not (r_f1 ? 'freshness') then
    insert into _fail values ('F1-key', 'no freshness key at all');
  else
    if (r_f1->'freshness'->>'stale') is distinct from 'false' then
      insert into _fail values ('F1-stale', coalesce(r_f1->'freshness'->>'stale', 'null'));
    end if;
    if (r_f1->'freshness'->>'data_as_of')::timestamptz is distinct from (v_now - interval '1 hour') then
      insert into _fail values ('F1-data_as_of', coalesce(r_f1->'freshness'->>'data_as_of', 'null'));
    end if;
    if (r_f1->'freshness'->>'age_hours')::numeric >= 2 then
      insert into _fail values ('F1-age_hours', coalesce(r_f1->'freshness'->>'age_hours', 'null'));
    end if;
  end if;
  -- F6 — observed_since forwarding
  if (r_f1->'freshness'->>'observed_since') is distinct from (r_f1->>'observed_since') then
    insert into _fail values ('F6-observed_since',
      format('freshness.observed_since=%s top-level=%s',
        r_f1->'freshness'->>'observed_since', r_f1->>'observed_since'));
  end if;

  ---------------------------------------------------------------------------
  -- F2/F5 — one sale ~100 hours old
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz_f2, 'ZZ v722 F2 firm', 'zz-v722-f2',
     array['dashboard','clients','sales','reports','customerintel']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br_f2, biz_f2, 'ZZ v722 F2 branch', true, true);
  insert into public.clients (id, business_id, full_name) values (c_f2, biz_f2, 'ZZ v722 f2 client');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (s_f2, biz_f2, br_f2, c_f2, 'service', 500, v_now - interval '100 hours', v_now - interval '100 hours');

  r_f2 := public.get_ci_demographics_v1(biz_f2, d_from - 5, d_to, null, v_now);
  if (r_f2->'freshness'->>'stale') is distinct from 'true' then
    insert into _fail values ('F2-stale', coalesce(r_f2->'freshness'->>'stale', 'null'));
  end if;
  if (r_f2->'freshness'->>'age_hours')::numeric <= 48 then
    insert into _fail values ('F2-age_hours', coalesce(r_f2->'freshness'->>'age_hours', 'null'));
  end if;

  -- F5 — get_ci_opportunities_v1 keeps its OWN freshness shape (E8 regression, local check)
  r_f5 := public.get_ci_opportunities_v1(biz_f2, d_from, d_to, null, v_now + interval '500 days');
  if r_f5->>'refusal_reason' is distinct from 'stale_evidence' then
    insert into _fail values ('F5-refusal', coalesce(r_f5->>'refusal_reason', 'null'));
  end if;
  if not (r_f5->'freshness' ? 'observed_since_min') then
    insert into _fail values ('F5-shape-missing', 'opportunities lost its own observed_since_min key');
  end if;
  if (r_f5->'freshness' ? 'data_as_of') or (r_f5->'freshness' ? 'age_hours') then
    insert into _fail values ('F5-shape-overwritten',
      'envelope injected its own keys into a reader that already had freshness: ' || (r_f5->'freshness')::text);
  end if;

  ---------------------------------------------------------------------------
  -- F3 — zero sales at all
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz_f3, 'ZZ v722 F3 firm', 'zz-v722-f3',
     array['dashboard','clients','sales','reports','customerintel']);
  r_f3 := public.get_ci_demographics_v1(biz_f3, d_from, d_to, null, v_now);
  if r_f3->'freshness'->>'data_as_of' is not null then
    insert into _fail values ('F3-data_as_of', r_f3->'freshness'->>'data_as_of');
  end if;
  if (r_f3->'freshness'->>'stale') is distinct from 'true' then
    insert into _fail values ('F3-stale', coalesce(r_f3->'freshness'->>'stale', 'null'));
  end if;

  ---------------------------------------------------------------------------
  -- F4 — branch scoping: branch A fresh, branch B stale, on the SAME business
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz_f4, 'ZZ v722 F4 firm', 'zz-v722-f4',
     array['dashboard','clients','sales','reports','customerintel']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br_f4a, biz_f4, 'ZZ v722 F4 branch A', true, true),
    (br_f4b, biz_f4, 'ZZ v722 F4 branch B', false, true);
  insert into public.clients (id, business_id, full_name) values
    (c_f4a, biz_f4, 'ZZ v722 f4a client'), (c_f4b, biz_f4, 'ZZ v722 f4b client');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (s_f4a, biz_f4, br_f4a, c_f4a, 'service', 500, v_now - interval '1 hour', v_now - interval '1 hour'),
    (s_f4b, biz_f4, br_f4b, c_f4b, 'service', 500, v_now - interval '100 hours', v_now - interval '100 hours');

  r_f4a := public.get_ci_demographics_v1(biz_f4, d_from - 5, d_to, br_f4a, v_now);
  r_f4b := public.get_ci_demographics_v1(biz_f4, d_from - 5, d_to, br_f4b, v_now);
  if (r_f4a->'freshness'->>'stale') is distinct from 'false' then
    insert into _fail values ('F4-branchA-stale', coalesce(r_f4a->'freshness'->>'stale', 'null'));
  end if;
  if (r_f4b->'freshness'->>'stale') is distinct from 'true' then
    insert into _fail values ('F4-branchB-stale', coalesce(r_f4b->'freshness'->>'stale', 'null'));
  end if;

  ---------------------------------------------------------------------------
  -- K1 — platform_get_assigned_firm_report_v94, empty business (this business is reused below
  -- for the R-series estate scan, as both "owner of an empty business" and "assigned consultant")
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz_k1, 'ZZ v722 K1 firm', 'zz-v722-k1',
     array['dashboard','clients','sales','reports','customerintel']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br_k1, biz_k1, 'ZZ v722 K1 branch', true, true);
  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values (biz_k1, u_owner, 'owner', 'ZZ v722 owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz_k1, 'approved', now(), 'v722 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz_k1, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz_k1, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.platform_consultants (id, user_id, display_name, tier, employment_started_on, active)
  values (cons_id, u_cons, 'ZZ v722 consultant', 'senior', current_date - 400, true);
  insert into public.sme_companies (id, legal_name, trading_name)
  values (co_id, 'ZZ v722 co', 'ZZ v722 co');
  insert into public.sme_prospects (company_id, legacy_stage_raw, assigned_consultant_id,
                                    ownership_state, queue_key,
                                    converted_business_id, converted_at, converted_by)
  values (co_id, 'zz-v722-fixture', cons_id, 'owned', null,
          biz_k1, clock_timestamp(), u_sa);

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  if not app.is_super_admin() then
    insert into _fail values ('pre-sa', 'fixture super admin session does not resolve is_super_admin(); K/R would be vacuous');
  end if;

  r_k1 := public.platform_get_assigned_firm_report_v94(biz_k1, null, d_from, d_to);
  if r_k1->'kpis'->'evidence' is distinct from jsonb_build_object('n',0,'floor',5,'status','insufficient') then
    insert into _fail values ('K1-evidence', coalesce((r_k1->'kpis'->'evidence')::text, 'null'));
  end if;
  if r_k1->'kpis'->>'status' is distinct from 'unavailable' then
    insert into _fail values ('K1-kpis-status', coalesce(r_k1->'kpis'->>'status', 'null'));
  end if;
  if r_k1->'cohorts'->>'status' is distinct from 'unavailable' then
    insert into _fail values ('K1-cohorts-status', coalesce(r_k1->'cohorts'->>'status', 'null'));
  end if;
  if r_k1->'customer_intelligence'->>'status' is distinct from 'unavailable' then
    insert into _fail values ('K1-ci-status', coalesce(r_k1->'customer_intelligence'->>'status', 'null'));
  end if;
  if r_k1->'kpis'->'average_order_cents' is distinct from 'null'::jsonb then
    insert into _fail values ('K1-avg-order', coalesce((r_k1->'kpis'->'average_order_cents')::text, 'null'));
  end if;
  if r_k1->'customer_intelligence'->'top_customer_revenue_cents' is distinct from 'null'::jsonb then
    insert into _fail values ('K1-top-customer', coalesce((r_k1->'customer_intelligence'->'top_customer_revenue_cents')::text, 'null'));
  end if;
  -- counts stay: zero, never null
  if (r_k1->'kpis'->>'visits')::bigint is distinct from 0
     or (r_k1->'kpis'->>'active_customers')::bigint is distinct from 0
     or (r_k1->'kpis'->>'returning_customers')::bigint is distinct from 0
     or (r_k1->'kpis'->>'net_revenue_cents')::bigint is distinct from 0 then
    insert into _fail values ('K1-counts-kpis', (r_k1->'kpis')::text);
  end if;
  if (r_k1->'customer_intelligence'->>'total_customers')::bigint is distinct from 0
     or (r_k1->'customer_intelligence'->>'customers_with_purchase')::bigint is distinct from 0
     or (r_k1->'customer_intelligence'->>'customers_over_90_days_inactive')::bigint is distinct from 0 then
    insert into _fail values ('K1-counts-ci', (r_k1->'customer_intelligence')::text);
  end if;
  if exists (
    select 1 from jsonb_each_text(r_k1->'cohorts'->'counts') kv where kv.value::bigint is distinct from 0
  ) then
    insert into _fail values ('K1-counts-cohorts', (r_k1->'cohorts'->'counts')::text);
  end if;

  ---------------------------------------------------------------------------
  -- K2 — same reader, 5 identified customers, two with sales (1000, 2000 cents)
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz_k2, 'ZZ v722 K2 firm', 'zz-v722-k2',
     array['dashboard','clients','sales','reports','customerintel']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br_k2, biz_k2, 'ZZ v722 K2 branch', true, true);
  insert into public.clients (id, business_id, full_name) values
    (c_k2a, biz_k2, 'ZZ v722 k2 a'), (c_k2b, biz_k2, 'ZZ v722 k2 b'),
    (c_k2c, biz_k2, 'ZZ v722 k2 c'), (c_k2d, biz_k2, 'ZZ v722 k2 d'),
    (c_k2e, biz_k2, 'ZZ v722 k2 e');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (s_k2a, biz_k2, br_k2, c_k2a, 'service', 1000, (d_to - 1)::timestamp + time '10:00', v_now),
    (s_k2b, biz_k2, br_k2, c_k2b, 'service', 2000, (d_to - 1)::timestamp + time '11:00', v_now);

  r_k2 := public.platform_get_assigned_firm_report_v94(biz_k2, null, d_from, d_to);
  if r_k2->'kpis'->'evidence' is distinct from jsonb_build_object('n',5,'floor',5,'status','ok') then
    insert into _fail values ('K2-evidence', coalesce((r_k2->'kpis'->'evidence')::text, 'null'));
  end if;
  if r_k2->'kpis'->>'status' is distinct from 'ok'
     or r_k2->'cohorts'->>'status' is distinct from 'ok'
     or r_k2->'customer_intelligence'->>'status' is distinct from 'ok' then
    insert into _fail values ('K2-status',
      format('kpis=%s cohorts=%s ci=%s', r_k2->'kpis'->>'status', r_k2->'cohorts'->>'status',
        r_k2->'customer_intelligence'->>'status'));
  end if;
  if (r_k2->'kpis'->>'average_order_cents')::bigint is distinct from 1500 then
    insert into _fail values ('K2-avg-order', coalesce(r_k2->'kpis'->>'average_order_cents', 'null'));
  end if;
  if (r_k2->'customer_intelligence'->>'top_customer_revenue_cents')::bigint is distinct from 2000 then
    insert into _fail values ('K2-top-customer', coalesce(r_k2->'customer_intelligence'->>'top_customer_revenue_cents', 'null'));
  end if;
  if (r_k2->'kpis'->>'active_customers')::bigint is distinct from 2 then
    insert into _fail values ('K2-active', coalesce(r_k2->'kpis'->>'active_customers', 'null'));
  end if;

  ---------------------------------------------------------------------------
  -- A1 — platform_customer_account_opens_v175 as the assigned consultant (biz_k1): NOW succeeds.
  -- Precondition proves this population genuinely lacked the pre-v722 arms.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_cons, 'role','authenticated')::text, true);
  if app.is_super_admin()
     or app.has_perm(biz_k1, 'view_finance')
     or app.v89_platform_can('reports','r') then
    insert into _fail values ('pre-A1',
      'the consultant fixture already resolves an old arm; A1 would be vacuous');
  end if;
  if not app.platform_firm_report_access_v94(biz_k1) then
    insert into _fail values ('pre-A1b',
      'the consultant fixture does not resolve platform_firm_report_access_v94; A1 would be vacuous');
  end if;
  begin
    v_payload := public.platform_customer_account_opens_v175(biz_k1, d_from, d_to);
    if v_payload is null then
      insert into _fail values ('A1', 'assigned consultant got no payload');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('A1', format('assigned consultant was refused (%s)', v_err));
  end;

  ---------------------------------------------------------------------------
  -- A2 — an unrelated stranger is still refused, 42501.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_stranger, 'role','authenticated')::text, true);
  begin
    perform public.platform_customer_account_opens_v175(biz_k1, d_from, d_to);
    insert into _fail values ('A2', 'an unrelated stranger read the account-opens report');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('A2', format('refused with %s, expected 42501', v_err));
  end;

  ---------------------------------------------------------------------------
  -- R1 setup — biz_r: zero sales, zero revenue, ONE client (see the declare block's comment on
  -- why get_ci_customer_records_v1 needs it), an owner and an assigned consultant.
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz_r, 'ZZ v722 R1 firm', 'zz-v722-r1',
     array['dashboard','clients','sales','reports','customerintel']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br_r, biz_r, 'ZZ v722 R1 branch', true, true);
  insert into public.clients (id, business_id, full_name) values (c_r, biz_r, 'ZZ v722 r1 client');
  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values (biz_r, u_owner, 'owner', 'ZZ v722 R1 owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz_r, 'approved', now(), 'v722 R1 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz_r, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz_r, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';
  -- reuses the SAME consultant (cons_id / u_cons) already created for biz_k1's A-series fixture
  -- above -- one consultant, assigned to two businesses, exactly like a real platform consultant.
  insert into public.sme_companies (id, legal_name, trading_name)
  values (co_r_id, 'ZZ v722 R1 co', 'ZZ v722 R1 co');
  insert into public.sme_prospects (company_id, legacy_stage_raw, assigned_consultant_id,
                                    ownership_state, queue_key,
                                    converted_business_id, converted_at, converted_by)
  values (co_r_id, 'zz-v722-r1-fixture', cons_id, 'owned', null,
          biz_r, clock_timestamp(), u_sa);

  ---------------------------------------------------------------------------
  -- R1 — estate-wide scan: every public.get_ci_* reader that takes p_business and does not
  -- require p_run_id, called for the empty business biz_r as its owner, then as its assigned
  -- consultant. 42501 is tolerated (a real authorization decision); any other exception is a
  -- named failure. A response that is not refused must carry 'exclusions' and 'freshness'.
  ---------------------------------------------------------------------------
  for rec in
    select fn.proname as fname,
      (
        select string_agg(
          format('%s => %s', a.argname,
            case a.argname
              when 'p_business' then format('%L::uuid', biz_r)
              when 'p_branch' then 'null::uuid'
              when 'p_from' then format('%L::date', d_from)
              when 'p_to' then format('%L::date', d_to)
              when 'p_as_of' then format('%L::timestamptz', v_now)
              when 'p_months' then '3'
              when 'p_window_days' then '30'
              when 'p_return_window_days' then '30'
              when 'p_node_key' then quote_literal('barbering')
              when 'p_gender' then quote_literal('female')
              when 'p_age_from' then '18'
              when 'p_age_to' then '99'
              when 'p_client' then format('%L::uuid', c_r)
              when 'p_extended' then 'false'
              when 'p_limit' then '20'
              else 'null'
            end
          ), ', ' order by a.ord)
        from unnest(fn.proargnames) with ordinality as a(argname, ord)
      ) as args
    from pg_proc fn
    where fn.pronamespace = 'public'::regnamespace
      and fn.proname like 'get\_ci\_%' escape '\'
      and fn.proargnames is not null
      and 'p_business' = any(fn.proargnames)
      and not ('p_run_id' = any(fn.proargnames))
  loop
    v_call := format('select public.%I(%s)', rec.fname, rec.args);

    -- owner
    perform set_config('request.jwt.claims',
      json_build_object('sub', u_owner, 'role','authenticated')::text, true);
    v_refused := false;
    begin
      execute v_call into v_payload;
    exception when insufficient_privilege then
      v_refused := true;
    when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('R1-owner-' || rec.fname,
        format('raised %s calling %s', v_err, v_call));
    end;
    if not v_refused then
      if v_payload is null or not (v_payload ? 'exclusions') or not (v_payload ? 'freshness') then
        insert into _fail values ('R1-owner-shape-' || rec.fname,
          format('missing exclusions/freshness: %s', coalesce(v_payload::text, 'null')));
      end if;
    end if;

    -- assigned consultant
    perform set_config('request.jwt.claims',
      json_build_object('sub', u_cons, 'role','authenticated')::text, true);
    v_refused := false;
    begin
      execute v_call into v_payload;
    exception when insufficient_privilege then
      v_refused := true;
    when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('R1-cons-' || rec.fname,
        format('raised %s calling %s', v_err, v_call));
    end;
    if not v_refused then
      if v_payload is null or not (v_payload ? 'exclusions') or not (v_payload ? 'freshness') then
        insert into _fail values ('R1-cons-shape-' || rec.fname,
          format('missing exclusions/freshness: %s', coalesce(v_payload::text, 'null')));
      end if;
    end if;
  end loop;
end;
$v722$;

select case when count(*) = 0 then 'PASS — v722: envelope freshness, brief evidence, v175 platform arm, estate scan'
  else format('FAIL (%s): %s', count(*), string_agg(k || '=' || v, ' | ')) end
from _fail;

rollback;
