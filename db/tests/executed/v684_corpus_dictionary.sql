-- EXECUTED acceptance fixture for nestly_v684 — the versioned metric dictionary and the
-- disjoint-by-construction customer-classes classifier.
--
-- Named for v684 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md). Proves
-- db/migrations/20260920_nestly_v684_metric_dictionary.sql's three objects:
--   app.ci_metric_dictionary_v1() / public.get_ci_dictionary_v1()   — T1, T2, T3
--   app.ci_customer_classes_v1(p_business, p_client, p_as_of)       — F, G, H, I + mutation-check
--
-- AUTH CONTEXT: a super-admin session, same pattern as db/tests/executed/v673_corpus_funnels.sql
-- — app.ci_access_gate_v667's platform arm admits a super admin outright, so this fixture does
-- not need a fully operational merchant workspace (approval + subscription + staff rows); v667's
-- own corpus already proves that entitlement boundary. The Google-session claims
-- app.is_super_admin() requires since nestly_v625 (amr[0].method='oauth',
-- app_metadata.providers containing 'google') are set alongside the super_admins row, per
-- docs/qa/CI-CORPUS-FIXTURE-GUIDE.md.
--
-- TIME BASE: v_as_of is pinned to local noon on "today" (date_trunc('day', clock_timestamp())
-- + 12h) rather than bare clock_timestamp(), so every day-offset below is an exact integer
-- number of days regardless of the wall-clock instant the harness runs at, and no computed
-- interval crosses a UTC/SGT midnight boundary. Every seeded sale's occurred_at is
-- v_as_of - (N || ' days')::interval for an explicit integer N.
--
-- ============================================================================================
-- TRUTH TABLE — app.ci_customer_classes_v1, business biz1, evaluated at v_as_of
-- ============================================================================================
-- Migration-default cadence policy on a freshly-created business (v107's own seed trigger):
-- fallback_lapse_days=90, customer_interval_min_observations=3, reactivation_multiplier=2.0.
--
--   cl_f (frequent + loyal)
--     8 visits, $50.00 (5000 cents) each, every 10 days, most recent 5 days ago:
--     offsets {5,15,25,35,45,55,65,75} days ago. interval_observations=7 (>=3), median=10d
--     (<=14) -> frequent=true. Cadence: effective_lapse = 10 * 2.0 = 20d; days_since_last=5 < 20
--     -> deviation_state != 'overdue' -> at_risk=false. visits_last_180d=8 (all offsets <180)
--     >=6 -> loyal = true AND NOT false = true. retained: first visit 75d ago, next visit 65d
--     ago (10d after first, <=90d) -> retained=true. lifetime_spend_cents = 8*5000 = 40000.
--     -> frequent=true, loyal=true, retained=true, at_risk=false.
--
--   cl_g (frequent BUT overdue: frequent=true, loyal=false, at_risk=true)
--     6 visits, $30.00 (3000 cents) each, every 7 days, most recent 40 days ago:
--     offsets {40,47,54,61,68,75} days ago. interval_observations=5 (>=3), median=7d (<=14)
--     -> frequent=true. Cadence: effective_lapse = 7 * 2.0 = 14d; days_since_last=40 > 14 ->
--     deviation_state='overdue' -> at_risk=true. loyal = (visits_last_180d=6 >= 6) AND NOT true
--     = false, EXACTLY the case the task calls out: a frequent customer who is overdue is not
--     loyal. retained: first visit 75d ago, next visit 68d ago (7d after, <=90d) -> true.
--     lifetime_spend_cents = 6*3000 = 18000.
--     -> frequent=true, loyal=false, retained=true, at_risk=true.
--
--   cl_h (one huge purchase, 300 days ago: high_ltv=true; at_risk computed, not assumed)
--     ONE visit, $50,000.00 (5000000 cents), 300 days ago. interval_observations=0 (no measured
--     gap: a single visit has no previous_purchase_at pair) -> frequent=false (fails the
--     obs>=3 gate regardless of median, which is null here anyway). visits_last_180d=0 (300>180)
--     -> loyal=false regardless of at_risk. retained: only one visit ever, no later visit
--     within 90d of it -> false.
--
--     AT_RISK — this is the case the task flags for honest, non-assumed reporting. v651's own
--     production semantics do not exempt a zero-observation customer from the CI at_risk
--     policy: interval_observations=0 is still < customer_interval_min_observations(3), so
--     app.customer_cadence_v1 falls back to fallback_lapse_days (90d) exactly as it would for
--     any under-evidenced customer, NOT a special "insufficient, cannot assess" path (that path
--     is reserved for status != 'ready', i.e. ZERO paid visits at all). days_since_last=300 > 90
--     -> deviation_state='overdue' -> at_risk=TRUE for cl_h under this migration's construction.
--     This is DELIBERATE and DOCUMENTED here (see the migration header's "why at_risk needs two
--     entries" note): the v179 AI-report policy would call cl_h not-at-risk (it never clears
--     the "2+ lifetime visits" gate), while the CI policy (this function) calls the same
--     customer overdue against the business-wide 90-day fallback. Both are real; this fixture
--     asserts the CI-policy value (true), not the alternative, because the CI policy is what
--     app.ci_customer_classes_v1 implements. Read the migration header before "fixing" this to
--     false — that would be inventing behaviour the reader does not have.
--     lifetime_spend_cents = 5000000.
--     -> frequent=false, loyal=false, retained=false, at_risk=true.
--
--   cl_i (2 visits 100 days apart: retained=false via the 90-day horizon)
--     first visit 250 days ago, second visit 150 days ago (100 days after the first, > 90d
--     horizon) -> retained=false, exactly the case the task calls out. interval_observations=1
--     (< 3) -> frequent=false regardless of the 100-day median. visits_last_180d=1 (only the
--     150-days-ago visit is within 180d; the 250-days-ago visit is not) -> loyal=false
--     regardless of at_risk. Cadence: obs=1 < 3 -> fallback=90d; days_since_last=150 > 90 ->
--     overdue -> at_risk=true. lifetime_spend_cents = 2*15000 = 30000.
--     -> frequent=false, loyal=false, retained=false, at_risk=true.
--
-- LIFETIME-SPEND POPULATION (identified customers of biz1: cl_f, cl_g, cl_h, cl_i):
--   sorted ascending: cl_g=18000, cl_i=30000, cl_f=40000, cl_h=5000000.
--   percentile_cont(0.8), n=4 -> rank index 0.8*(4-1)=2.4 -> interpolate sorted[2]=40000 and
--   sorted[3]=5000000: 40000 + 0.4*(5000000-40000) = 2024000.
--   -> high_ltv: cl_f (40000 < 2024000) = false; cl_g (18000 < 2024000) = false;
--      cl_h (5000000 >= 2024000) = true; cl_i (30000 < 2024000) = false.
--
-- CONTRADICTION CHECK (universal, all four customers): NOT (at_risk AND loyal).
--   cl_f: loyal=true, at_risk=false  -> holds.
--   cl_g: loyal=false, at_risk=true  -> holds.
--   cl_h: loyal=false, at_risk=true  -> holds.
--   cl_i: loyal=false, at_risk=true  -> holds.
--   This holds by construction (loyal := visits>=6 AND NOT at_risk, using the SAME at_risk
--   value), not by coincidence of these four inputs — the mutation-check below proves the
--   construction is genuinely input-sensitive, not a hardcoded pair.
--
-- MUTATION-CHECK (cl_g): `sales` is append-only (no UPDATE/DELETE — see the immutable guard
-- proven elsewhere in this suite), so the mutation is a further INSERT, not an edit: a 7th
-- sale for cl_g, 3 days ago. This adds one more measured interval (37d, between the new most-
-- recent visit and the former most-recent at 40d ago) to the existing five 7-day gaps:
-- sorted {7,7,7,7,7,37}, n=6, percentile_cont(0.5) still lands on 7 (ranks 3,4 of 6 are both
-- 7) -> median unchanged, interval_observations=6 (>=3) -> frequent stays true. But
-- days_since_last_visit is now 3 (< effective_lapse 7*2.0=14) -> deviation_state != 'overdue'
-- -> at_risk flips to false, and visits_last_180d becomes 7 (>=6) with at_risk now false ->
-- loyal flips to true. A construction that always returned the seeded true/false pair
-- regardless of input would fail this check.
-- ============================================================================================

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v684$
declare
  biz1     uuid := '00000000-0000-4000-8000-000000684001';
  branch1  uuid := '00000000-0000-4000-8000-000000684011';
  u_sa     uuid := '00000000-0000-4000-8000-000000684101';
  cl_f     uuid := '00000000-0000-4000-8000-000000684201';
  cl_g     uuid := '00000000-0000-4000-8000-000000684202';
  cl_h     uuid := '00000000-0000-4000-8000-000000684203';
  cl_i     uuid := '00000000-0000-4000-8000-000000684204';

  v_as_of  timestamptz := date_trunc('day', clock_timestamp()) + interval '12 hours';
  v_err    text;

  v_dict       jsonb;
  v_dict_pub   jsonb;
  v_metrics    jsonb;
  v_keys       text[];
  v_expected_keys text[] := array[
    'revenue','visit','transaction','new','existing_returning','repeat','reactivated',
    'retained','lapsed','at_risk','ltv','atv','identified_coverage','cadence_median',
    'return_probability'
  ];
  v_key text;
  v_entry jsonb;

  g_f jsonb;
  g_g jsonb;
  g_h jsonb;
  g_i jsonb;
  g_g_mut jsonb;
begin
  ---------------------------------------------------------------------------
  -- actors, business, branch (super-admin platform session — v667/v673 pattern)
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values (u_sa, 'zz-v684-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v684-sa@example.test')
    on conflict do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz1, 'ZZ v684 dictionary fixture', 'zz-v684-dictionary',
     array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (branch1, biz1, 'ZZ v684 branch one', true, true);

  -- v106 LANDMINE (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md does not yet list this one; recorded in
  -- db/tests/executed/v651_corpus_cadence.sql): a brand-new branch's first reporting contract
  -- is dated from transaction_timestamp() ("now"), never '-infinity'. app.ci_customer_classes_v1
  -- calls app.customer_cadence_v1 -> app.customer_cadence_batch_v1, whose "eligible" CTE does
  -- `cross join lateral app.v106_reporting_contract(...)` — an INNER join. Every sale in this
  -- fixture is deliberately backdated (real cadence history up to 300 days ago), so without an
  -- early-dated contract row every one of them would silently fail to join and vanish from
  -- eligibility. Add the same explicit early contract version v651's own fixture adds.
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz1, branch1, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore',
         upper(b.currency), true
    from public.businesses b where b.id = biz1;

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  -- PRECONDITION: the fixture's platform session must actually clear the gate, or every
  -- assertion below is vacuous.
  begin
    perform app.ci_access_gate_v667(biz1, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PRE-gate',
      format('fixture super admin cannot pass app.ci_access_gate_v667 (sqlstate %s); every '
             'assertion below would be vacuous', v_err));
  end;

  ---------------------------------------------------------------------------
  -- clients
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name) values
    (cl_f, biz1, 'ZZ v684 frequent+loyal'),
    (cl_g, biz1, 'ZZ v684 frequent-overdue'),
    (cl_h, biz1, 'ZZ v684 one huge purchase'),
    (cl_i, biz1, 'ZZ v684 hundred-day gap');

  ---------------------------------------------------------------------------
  -- sales — cl_f: 8 visits x $50.00, every 10 days, most recent 5 days ago
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, created_at)
  select gen_random_uuid(), biz1, branch1, cl_f, 'service', 5000,
         v_as_of - (o || ' days')::interval, v_as_of - (o || ' days')::interval
    from unnest(array[5,15,25,35,45,55,65,75]) as o;

  ---------------------------------------------------------------------------
  -- sales — cl_g: 6 visits x $30.00, every 7 days, most recent 40 days ago
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, created_at)
  select gen_random_uuid(), biz1, branch1, cl_g, 'service', 3000,
         v_as_of - (o || ' days')::interval, v_as_of - (o || ' days')::interval
    from unnest(array[40,47,54,61,68,75]) as o;

  ---------------------------------------------------------------------------
  -- sales — cl_h: one huge purchase, $50,000.00, 300 days ago
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, created_at)
  values (gen_random_uuid(), biz1, branch1, cl_h, 'service', 5000000,
          v_as_of - interval '300 days', v_as_of - interval '300 days');

  ---------------------------------------------------------------------------
  -- sales — cl_i: 2 visits, $150.00 each, 100 days apart (250d ago, 150d ago)
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, created_at)
  select gen_random_uuid(), biz1, branch1, cl_i, 'service', 15000,
         v_as_of - (o || ' days')::interval, v_as_of - (o || ' days')::interval
    from unnest(array[250,150]) as o;

  ---------------------------------------------------------------------------
  -- T1 — dictionary version string exact
  ---------------------------------------------------------------------------
  v_dict := app.ci_metric_dictionary_v1();
  if (v_dict ->> 'version') is distinct from 'ci_dictionary_v684_1' then
    insert into _fail values ('T1-version',
      format('expected version ci_dictionary_v684_1, got %s', v_dict ->> 'version'));
  end if;

  v_dict_pub := public.get_ci_dictionary_v1();
  if v_dict_pub is distinct from v_dict then
    insert into _fail values ('T1-wrapper',
      'public.get_ci_dictionary_v1() does not match app.ci_metric_dictionary_v1() verbatim');
  end if;

  ---------------------------------------------------------------------------
  -- T2 — every listed metric has a non-empty definition and source_function; key set exact
  ---------------------------------------------------------------------------
  v_metrics := v_dict -> 'metrics';
  select array_agg(k order by k) into v_keys from jsonb_object_keys(v_metrics) as k;

  foreach v_key in array v_expected_keys loop
    if not (v_key = any(v_keys)) then
      insert into _fail values ('T2-missing-key', format('dictionary is missing key %s', v_key));
      continue;
    end if;
    v_entry := v_metrics -> v_key;
    if v_entry -> 'definition' is null
       or btrim(coalesce(v_entry ->> 'definition', '')) = '' then
      insert into _fail values ('T2-definition', format('%s has an empty definition', v_key));
    end if;
    if v_entry -> 'source_function' is null then
      insert into _fail values ('T2-source', format('%s has no source_function', v_key));
    end if;
  end loop;

  -- No key present that wasn't expected either — the key SET matches exactly.
  if (select count(*) from unnest(v_keys) k where not (k = any(v_expected_keys))) > 0 then
    insert into _fail values ('T2-extra-keys',
      format('dictionary has unexpected keys: %s',
        (select string_agg(k, ', ') from unnest(v_keys) k
          where not (k = any(v_expected_keys)))));
  end if;

  ---------------------------------------------------------------------------
  -- T3 — the at_risk-vs-overdue tension entry is present and names both policies
  ---------------------------------------------------------------------------
  v_entry := v_metrics -> 'at_risk';
  if position('v179' in coalesce(v_entry ->> 'definition', '') || coalesce(v_entry ->> 'notes', ''))
       = 0
     or position('651' in coalesce(v_entry ->> 'since_version', '')) = 0 then
    insert into _fail values ('T3-tension',
      'at_risk entry does not name both the v179 AI-report policy and the v651/CI policy');
  end if;
  if v_entry -> 'source_function' is null
     or jsonb_typeof(v_entry -> 'source_function') <> 'array'
     or jsonb_array_length(v_entry -> 'source_function') < 2 then
    insert into _fail values ('T3-two-sources',
      'at_risk source_function must list both competing readers, not one');
  end if;

  ---------------------------------------------------------------------------
  -- F, G, H, I — app.ci_customer_classes_v1
  ---------------------------------------------------------------------------
  g_f := app.ci_customer_classes_v1(biz1, cl_f, v_as_of);
  g_g := app.ci_customer_classes_v1(biz1, cl_g, v_as_of);
  g_h := app.ci_customer_classes_v1(biz1, cl_h, v_as_of);
  g_i := app.ci_customer_classes_v1(biz1, cl_i, v_as_of);

  -- cl_f: frequent=true, loyal=true, retained=true, high_ltv=false, at_risk=false
  if (g_f -> 'classes' ->> 'frequent')::boolean is distinct from true then
    insert into _fail values ('F-frequent', format('got %s', g_f -> 'classes' ->> 'frequent'));
  end if;
  if (g_f -> 'classes' ->> 'loyal')::boolean is distinct from true then
    insert into _fail values ('F-loyal', format('got %s', g_f -> 'classes' ->> 'loyal'));
  end if;
  if (g_f -> 'classes' ->> 'retained')::boolean is distinct from true then
    insert into _fail values ('F-retained', format('got %s', g_f -> 'classes' ->> 'retained'));
  end if;
  if (g_f -> 'classes' ->> 'high_ltv')::boolean is distinct from false then
    insert into _fail values ('F-high_ltv', format('got %s', g_f -> 'classes' ->> 'high_ltv'));
  end if;
  if (g_f -> 'classes' ->> 'at_risk')::boolean is distinct from false then
    insert into _fail values ('F-at_risk', format('got %s', g_f -> 'classes' ->> 'at_risk'));
  end if;

  -- cl_g: frequent=true, loyal=false, retained=true, high_ltv=false, at_risk=true
  if (g_g -> 'classes' ->> 'frequent')::boolean is distinct from true then
    insert into _fail values ('G-frequent', format('got %s', g_g -> 'classes' ->> 'frequent'));
  end if;
  if (g_g -> 'classes' ->> 'loyal')::boolean is distinct from false then
    insert into _fail values ('G-loyal', format('got %s', g_g -> 'classes' ->> 'loyal'));
  end if;
  if (g_g -> 'classes' ->> 'retained')::boolean is distinct from true then
    insert into _fail values ('G-retained', format('got %s', g_g -> 'classes' ->> 'retained'));
  end if;
  if (g_g -> 'classes' ->> 'high_ltv')::boolean is distinct from false then
    insert into _fail values ('G-high_ltv', format('got %s', g_g -> 'classes' ->> 'high_ltv'));
  end if;
  if (g_g -> 'classes' ->> 'at_risk')::boolean is distinct from true then
    insert into _fail values ('G-at_risk', format('got %s', g_g -> 'classes' ->> 'at_risk'));
  end if;

  -- cl_h: frequent=false, loyal=false, retained=false, high_ltv=true, at_risk=true
  -- (see the truth-table note above: obs=0 does NOT make this "insufficient" under v651's own
  -- semantics — a single old purchase is judged against the business fallback, exactly like
  -- any other under-evidenced customer. This is asserted as the construction's ACTUAL output.)
  if (g_h -> 'classes' ->> 'frequent')::boolean is distinct from false then
    insert into _fail values ('H-frequent', format('got %s', g_h -> 'classes' ->> 'frequent'));
  end if;
  if (g_h -> 'classes' ->> 'loyal')::boolean is distinct from false then
    insert into _fail values ('H-loyal', format('got %s', g_h -> 'classes' ->> 'loyal'));
  end if;
  if (g_h -> 'classes' ->> 'retained')::boolean is distinct from false then
    insert into _fail values ('H-retained', format('got %s', g_h -> 'classes' ->> 'retained'));
  end if;
  if (g_h -> 'classes' ->> 'high_ltv')::boolean is distinct from true then
    insert into _fail values ('H-high_ltv', format('got %s', g_h -> 'classes' ->> 'high_ltv'));
  end if;
  if (g_h -> 'classes' ->> 'at_risk')::boolean is distinct from true then
    insert into _fail values ('H-at_risk', format('got %s', g_h -> 'classes' ->> 'at_risk'));
  end if;

  -- cl_i: frequent=false, loyal=false, retained=false, high_ltv=false, at_risk=true
  if (g_i -> 'classes' ->> 'frequent')::boolean is distinct from false then
    insert into _fail values ('I-frequent', format('got %s', g_i -> 'classes' ->> 'frequent'));
  end if;
  if (g_i -> 'classes' ->> 'loyal')::boolean is distinct from false then
    insert into _fail values ('I-loyal', format('got %s', g_i -> 'classes' ->> 'loyal'));
  end if;
  if (g_i -> 'classes' ->> 'retained')::boolean is distinct from false then
    insert into _fail values ('I-retained', format('got %s', g_i -> 'classes' ->> 'retained'));
  end if;
  if (g_i -> 'classes' ->> 'high_ltv')::boolean is distinct from false then
    insert into _fail values ('I-high_ltv', format('got %s', g_i -> 'classes' ->> 'high_ltv'));
  end if;
  if (g_i -> 'classes' ->> 'at_risk')::boolean is distinct from true then
    insert into _fail values ('I-at_risk', format('got %s', g_i -> 'classes' ->> 'at_risk'));
  end if;

  -- exact lifetime_spend_cents inputs (proves the percentile threshold's own inputs, not just
  -- the boolean it produces)
  if ((g_f -> 'inputs' ->> 'lifetime_spend_cents')::bigint) is distinct from 40000 then
    insert into _fail values ('F-ltv-cents',
      format('got %s', g_f -> 'inputs' ->> 'lifetime_spend_cents'));
  end if;
  if ((g_g -> 'inputs' ->> 'lifetime_spend_cents')::bigint) is distinct from 18000 then
    insert into _fail values ('G-ltv-cents',
      format('got %s', g_g -> 'inputs' ->> 'lifetime_spend_cents'));
  end if;
  if ((g_h -> 'inputs' ->> 'lifetime_spend_cents')::bigint) is distinct from 5000000 then
    insert into _fail values ('H-ltv-cents',
      format('got %s', g_h -> 'inputs' ->> 'lifetime_spend_cents'));
  end if;
  if ((g_i -> 'inputs' ->> 'lifetime_spend_cents')::bigint) is distinct from 30000 then
    insert into _fail values ('I-ltv-cents',
      format('got %s', g_i -> 'inputs' ->> 'lifetime_spend_cents'));
  end if;
  if round(((g_f -> 'inputs' ->> 'business_p80_lifetime_spend_cents')::numeric), 0)
       is distinct from 2024000 then
    insert into _fail values ('P80',
      format('got %s', g_f -> 'inputs' ->> 'business_p80_lifetime_spend_cents'));
  end if;

  ---------------------------------------------------------------------------
  -- Universal contradiction check — NOT (at_risk AND loyal) for every seeded customer
  ---------------------------------------------------------------------------
  if exists (
    select 1 from (values
      ((g_f -> 'classes' ->> 'at_risk')::boolean, (g_f -> 'classes' ->> 'loyal')::boolean, 'F'),
      ((g_g -> 'classes' ->> 'at_risk')::boolean, (g_g -> 'classes' ->> 'loyal')::boolean, 'G'),
      ((g_h -> 'classes' ->> 'at_risk')::boolean, (g_h -> 'classes' ->> 'loyal')::boolean, 'H'),
      ((g_i -> 'classes' ->> 'at_risk')::boolean, (g_i -> 'classes' ->> 'loyal')::boolean, 'I')
    ) as t(at_risk, loyal, who)
    where t.at_risk and t.loyal
  ) then
    insert into _fail values ('CONTRADICTION',
      'at least one customer is BOTH at_risk and loyal simultaneously');
  end if;

  ---------------------------------------------------------------------------
  -- MUTATION-CHECK (cl_g): move the most recent sale from 40 days ago to 5 days ago.
  -- Same rhythm (7-day gaps preserved among the earlier five), only "how long since the last
  -- visit" changes. Expect at_risk to flip false and loyal to flip true.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, created_at)
  values (gen_random_uuid(), biz1, branch1, cl_g, 'service', 3000,
          v_as_of - interval '3 days', v_as_of - interval '3 days');

  g_g_mut := app.ci_customer_classes_v1(biz1, cl_g, v_as_of);

  if (g_g_mut -> 'classes' ->> 'at_risk')::boolean is distinct from false then
    insert into _fail values ('MUTATION-at_risk',
      format('expected at_risk to flip to false after moving the last visit closer; got %s',
        g_g_mut -> 'classes' ->> 'at_risk'));
  end if;
  if (g_g_mut -> 'classes' ->> 'loyal')::boolean is distinct from true then
    insert into _fail values ('MUTATION-loyal',
      format('expected loyal to flip to true after moving the last visit closer; got %s',
        g_g_mut -> 'classes' ->> 'loyal'));
  end if;
  if (g_g_mut -> 'classes' ->> 'frequent')::boolean is distinct from true then
    insert into _fail values ('MUTATION-frequent',
      format('frequent should be unaffected by which visit is most recent; got %s',
        g_g_mut -> 'classes' ->> 'frequent'));
  end if;
end
$v684$;

select case when count(*)=0 then 'PASS — dictionary versioned, key set exact, tension '
                                  || 'disclosed, five classes disjoint by construction and '
                                  || 'mutation-sensitive'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v684: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
