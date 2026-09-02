-- EXECUTED acceptance fixture for nestly_v696 — spine typed verdicts (check 17, spine half).
--
-- Above the v422 watermark: reported n/a in the BASELINE phase, gated on the MIGRATED run
-- (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- Proves, against public.get_ci_opportunities_v1 (db/migrations/20260902_nestly_v696_spine_typed_
-- verdicts.sql, itself re-emitting db/migrations/20260920_nestly_v688_consultant_spine_v2.sql
-- unchanged apart from three additive substitutions):
--   B1 — every ranked candidate, in BOTH p_extended modes, carries evidence_class in
--        {DIRECT_FACT, ASSOCIATION}, never CAUSAL, and the string 'CAUSAL' does not appear
--        anywhere in either payload's text at all (not just outside the twelve-key contract).
--   B2 — the payload carries a top-level verdict_policy key stating exactly that invariant, in
--        both modes.
--   B3 — app.ci_verdict_class_v696 is EXHAUSTIVE over every generator name
--        public.get_ci_opportunities_v1's LIVE body actually emits — enumerated here by
--        regexp-scanning that body's own pg_get_functiondef text, not by trusting a hand-written
--        list — and an unmapped name raises rather than silently returning something.
--   B4 — for every candidate this fixture's own business actually produces, the mapping function's
--        answer for that candidate's generator agrees with the evidence_class the spine actually
--        shipped for it.
--   B5 — impact.impact_class is 'expected_value' when a real modelled figure exists
--        (package_leakage:plan_big, extended mode only), 'scenario' when only a scenario cents
--        figure exists (package_leakage:plan_big, base mode), and 'none' when neither does
--        (gateway_followthrough, contactability_gap, data_quality_coverage, strength — no
--        candidate in this business's ranked set has a modelled figure it does not also carry a
--        scenario one for, so the fixture pins 'none' against the population that actually has
--        no cents figure at all, and leaves the reverse case — 'expected_value' present but
--        'scenario' absent — undemonstrated here as no generator in this engine produces it).
--
-- =================================================================================================
-- SEEDING — reused from db/tests/executed/v688_corpus_spine_v2.sql's BIZ1 (that file's own hand
-- truth table has the full derivation), trimmed smaller: PLAN_SMALL/K1..K5 dropped (this fixture
-- has no need of check 65's materiality-gate mutation, already proven there), BIZ2/BIZ3/BIZ4
-- dropped entirely (this fixture has no need of the funnel-wording or discovery/EV-formula checks,
-- already proven there). What is kept is exactly enough to get ONE DIRECT_FACT quantified
-- candidate with a real expected_value (package_leakage:plan_big), ONE ASSOCIATION candidate
-- (gateway_followthrough:svc_gw), and two more DIRECT_FACT candidates with no cents figure at all
-- (contactability_gap, data_quality_coverage) — i.e. both evidence classes present, and both
-- impact_class states ('scenario'/'expected_value' vs 'none') present, from a single business.
--
-- WINDOW. p_from = p_to = d1 (one day). p_as_of = d1 + 150 days.
-- FUNNEL. F1..F20 first visit at d1 on svc_gw (making it a gateway service). ALL 20 return at
--   d1+10 (100%). 18 of 20 return at d1+20 (90%). Gap 10.0pp < 15pp bar -> funnel_bottleneck
--   abstains 'below_materiality' (evidence ok, n=20) — not asserted here, v688's own fixture already
--   covers it; kept only because the funnel population is what gives svc_gw its firm-wide
--   first-to-second baseline (100%), which is what makes gateway_followthrough:svc_gw fire (its
--   window-scoped repeat rate is 0%, a 100pp gap against that baseline).
-- H1 rhythm (5 visits, 10-day gaps, BEFORE d1) exists solely to give H1 a resolvable
--   app.return_probability_v681, purely for package_leakage:plan_big's expected_value below.
-- PACKAGES. PLAN_BIG: price 20000 / 10 sessions -> 2000/session. H1..H5 each buy one on d1, none
--   ever use a session (remaining=10 each). Utilisation 0.0% < 50% bar -> fires.
--     scenario_cents = 50 unused * 2000 = 100000.
--     expected_value.cents = round(H1's 10*2000*0.950212932) = 19004; H2..H5 abstain (no other
--     sale ever, so app.return_probability_v681 has no qualifying visit) -> inputs.abstained = 4.
--   (These are the exact figures v688's own fixture asserts for the same population — reused, not
--   re-derived, since the population is byte-identical.)
-- CONTACTABILITY. Zero consents are ever recorded for anyone in this business, so the best channel
--   reaches 0 of the >=20 identified customers — contactability_gap fires, unquantified (no cents).
-- DATA QUALITY. svc_gw is never mapped to a taxonomy node, so classified revenue coverage is 0 bps
--   — data_quality_coverage fires, foundation (no cents).
--
-- =================================================================================================
-- LANDMINES HANDLED (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md; not re-discovered here)
-- =================================================================================================
--  * created_at pinned to occurred_at/purchased_at on every backdated row.
--  * counts_as_revenue / counts_as_visit are NEVER passed on insert.
--  * the operational recipe (workspace controls + subscription lifecycle + subscriptions +
--    reporting_contract_versions_v106 backdated) is required, or every gate refuses for a billing
--    reason and the whole fixture passes vacuously.
--  * a fresh business gets a customer_lifecycle_policies_v107 row automatically (trigger-seeded);
--    this fixture keeps the default (min_observations=3), never touches it.
--  * the platform session needs Google-SSO-shaped claims (amr + app_metadata.providers), not just a
--    super_admins row (nestly_v625).
--  * a bare `c` shared between a query alias and a plpgsql variable raises "ambiguous" — every loop
--    alias below is named distinctly from any declared variable.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000696ee1', 'zz-v696-owner1@example.test'),
  ('00000000-0000-4000-8000-000000696eee', 'zz-v696-sa@example.test')
  on conflict (id) do nothing;
insert into public.super_admins (user_id, email) values
  ('00000000-0000-4000-8000-000000696eee', 'zz-v696-sa@example.test')
  on conflict do nothing;

select set_config('request.jwt.claims', json_build_object(
    'sub', '00000000-0000-4000-8000-000000696eee', 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google'))
  )::text, true);

-- =================================================================================================
-- SCENARIO business (trimmed BIZ1)
-- =================================================================================================
do $v696a$
declare
  biz      uuid := '00000000-0000-4000-8000-000000696001';
  br       uuid := '00000000-0000-4000-8000-000000696011';
  u_owner  uuid := '00000000-0000-4000-8000-000000696ee1';
  svc_gw   uuid := '00000000-0000-4000-8000-0000006960a1';
  plan_big uuid := '00000000-0000-4000-8000-0000006960b1';

  d1       date := current_date - 200;
  as_of    timestamptz := ((d1 + 150)::timestamp + time '12:00') at time zone 'Asia/Singapore';

  g        jsonb;   -- extended payload
  g0       jsonb;   -- non-extended payload
  cand     jsonb;   -- NB: distinct from any query alias (plpgsql.variable_conflict is 'error')
  row_c    jsonb;
  v_txt    text;
  v_class  jsonb;
  v_def    text;
  v_names  text[];
  v_name   text;
  v_ok     boolean;
begin
  ---------------------------------------------------------------------------
  -- operational recipe
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v696 biz', 'zz-v696-biz',
     array['dashboard','clients','sales','reports','packages']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v696 biz main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz, u_owner, 'owner', 'ZZ v696 owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v696 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_gw, biz, 'ZZ v696 gateway service', 1000, 30);
  insert into public.package_plans (id, business_id, name, price_cents, sessions, active) values
    (plan_big, biz, 'ZZ v696 plan big (10 sessions)', 20000, 10, true);

  ---------------------------------------------------------------------------
  -- clients
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000696' || lpad((100+s)::text,3,'0'))::uuid,
         biz, 'ZZ v696 funnel ' || s from generate_series(1,20) s;
  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000696' || lpad((300+s)::text,3,'0'))::uuid,
         biz, 'ZZ v696 plan-big holder ' || s from generate_series(1,5) s;   -- H1..H5

  ---------------------------------------------------------------------------
  -- FUNNEL: F1..F20 first visit at d1, ALL return at d1+10, 18 of 20 return at d1+20.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000696' || lpad((500+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000696' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 1000,
         (d1::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (d1::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,20) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000696' || lpad((500+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 1000, 1000 from generate_series(1,20) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000696' || lpad((520+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000696' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 1000,
         ((d1+10)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1+10)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,20) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000696' || lpad((520+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 1000, 1000 from generate_series(1,20) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000696' || lpad((540+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000696' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 1000,
         ((d1+20)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1+20)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,18) s;   -- only 18 of 20
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000696' || lpad((540+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 1000, 1000 from generate_series(1,18) s;

  ---------------------------------------------------------------------------
  -- H1 rhythm: 5 visits, 10-day gaps, BEFORE d1 — resolvable return_probability_v681 for the
  -- package-leakage EV below only.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000696' || lpad((630+s)::text,3,'0'))::uuid,
         biz, br, '00000000-0000-4000-8000-000000696301'::uuid, 'service', 3000,
         ((d1 - (60 - s*10))::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1 - (60 - s*10))::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000696' || lpad((630+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 3000, 3000 from generate_series(1,5) s;

  ---------------------------------------------------------------------------
  -- PACKAGES, purchased on d1. H1..H5 buy plan_big.
  ---------------------------------------------------------------------------
  insert into public.client_packages
    (id, business_id, plan_id, client_id, sessions_snapshot, remaining, status, purchased_at,
     plan_name_snapshot, plan_version_snapshot, price_cents_snapshot)
  select gen_random_uuid(), biz, plan_big,
         ('00000000-0000-4000-8000-000000696' || lpad((300+s)::text,3,'0'))::uuid,
         10, 10, 'active', (d1::timestamp + time '10:00') at time zone 'Asia/Singapore',
         'ZZ v696 plan big (10 sessions)', 1, 20000
    from generate_series(1,5) s;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000696' || lpad((650+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000696' || lpad((300+s)::text,3,'0'))::uuid,
         'package', 20000,
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore',
         (d1::timestamp + time '10:00') at time zone 'Asia/Singapore'
    from generate_series(1,5) s;

  ---------------------------------------------------------------------------
  -- PRECONDITIONS
  ---------------------------------------------------------------------------
  if (select coalesce(bool_and(s.counts_as_revenue) and bool_and(s.counts_as_visit), false)
        from public.sales s where s.business_id = biz and s.kind = 'service') is not true then
    insert into _fail values ('PRE-policy', 'a service sale did not resolve counts_as_revenue/visit true');
  end if;

  ---------------------------------------------------------------------------
  -- THE CALLS
  ---------------------------------------------------------------------------
  g  := public.get_ci_opportunities_v1(biz, d1, d1, null, as_of, true);
  g0 := public.get_ci_opportunities_v1(biz, d1, d1, null, as_of, false);

  -- pre: assert the population this fixture intends actually promoted (the rule that matters most).
  if not exists (select 1 from jsonb_array_elements(g->'ranked') c
                  where c->>'id' = 'package_leakage:' || plan_big::text) then
    insert into _fail values ('PRE-population', 'package_leakage:plan_big was not promoted — the '
      'downstream evidence_class/impact_class assertions on it would rest on nothing');
  end if;
  if not exists (select 1 from jsonb_array_elements(g->'ranked') c
                  where c->>'id' = 'gateway_followthrough:' || svc_gw::text) then
    insert into _fail values ('PRE-population', 'gateway_followthrough:svc_gw was not promoted — the '
      'only ASSOCIATION candidate this fixture relies on is missing');
  end if;
  if not exists (select 1 from jsonb_array_elements(g->'ranked') c where c->>'id' = 'contactability_gap')
  then
    insert into _fail values ('PRE-population', 'contactability_gap was not promoted');
  end if;
  if not exists (select 1 from jsonb_array_elements(g->'ranked') c
                  where c->>'id' = 'data_quality_coverage') then
    insert into _fail values ('PRE-population', 'data_quality_coverage was not promoted');
  end if;

  -- =================================================================================================
  -- B1 · no CAUSAL, anywhere — structurally (per candidate) and textually (the whole payload).
  -- =================================================================================================
  for row_c in select c from jsonb_array_elements(g->'ranked') c
               union all
               select c from jsonb_array_elements(g0->'ranked') c
  loop
    if row_c->>'evidence_class' = 'CAUSAL' then
      insert into _fail values ('B1-causal', format('candidate %s claims CAUSAL', row_c->>'id'));
    end if;
    if row_c->>'evidence_class' not in ('DIRECT_FACT','ASSOCIATION') then
      insert into _fail values ('B1-class', format('candidate %s has evidence_class %s',
        row_c->>'id', row_c->>'evidence_class'));
    end if;
  end loop;
  if g::text ~ 'CAUSAL' then
    insert into _fail values ('B1-text-extended', 'the literal string CAUSAL appears in the '
      'extended payload text');
  end if;
  if g0::text ~ 'CAUSAL' then
    insert into _fail values ('B1-text-base', 'the literal string CAUSAL appears in the base '
      'payload text');
  end if;

  -- =================================================================================================
  -- B2 · verdict_policy, exact, in both modes.
  -- =================================================================================================
  if g->'verdict_policy' <> jsonb_build_object('classes', jsonb_build_array('DIRECT_FACT','ASSOCIATION'),
                                                'causal_claims', 'never') then
    insert into _fail values ('B2-policy-extended', format('verdict_policy was %s', g->'verdict_policy'));
  end if;
  if g0->'verdict_policy' <> jsonb_build_object('classes', jsonb_build_array('DIRECT_FACT','ASSOCIATION'),
                                                 'causal_claims', 'never') then
    insert into _fail values ('B2-policy-base', format('verdict_policy was %s', g0->'verdict_policy'));
  end if;

  -- =================================================================================================
  -- B3 · exhaustiveness of app.ci_verdict_class_v696 over every generator name the LIVE body emits.
  -- =================================================================================================
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = 'get_ci_opportunities_v1'
     and p.pronargs = 6;

  select array_agg(distinct m[1]) into v_names
    from regexp_matches(v_def, '(?<!>)''(?:id|generator)''\s*,\s*''([a-z][a-z_]*)', 'g') as m;

  if v_names is null or array_length(v_names, 1) < 15 then
    insert into _fail values ('B3-extraction', format('extracted %s generator name(s) from the live '
      'body, expected at least 15', coalesce(array_length(v_names,1), 0)));
  end if;

  foreach v_name in array coalesce(v_names, array[]::text[]) loop
    begin
      v_class := app.ci_verdict_class_v696(v_name);
      if v_class->>'class' not in ('DIRECT_FACT','ASSOCIATION') then
        insert into _fail values ('B3-exhaustive', format('generator "%s" mapped to non-typed class %s',
          v_name, v_class->>'class'));
      end if;
    exception when others then
      insert into _fail values ('B3-exhaustive', format('generator "%s" (present in the live body) is '
        'unmapped: %s', v_name, sqlerrm));
    end;
  end loop;

  -- an unknown name must raise, not silently resolve.
  v_ok := false;
  begin
    perform app.ci_verdict_class_v696('zz_totally_unknown_generator_696');
  exception when others then
    v_ok := true;
  end;
  if not v_ok then
    insert into _fail values ('B3-unknown', 'app.ci_verdict_class_v696 did not raise on an unmapped '
      'generator name');
  end if;

  -- =================================================================================================
  -- B4 · the mapping function's answer agrees with what the spine actually shipped, for every
  --      candidate THIS business's ranked set actually contains, in both modes.
  -- =================================================================================================
  for row_c in select c from jsonb_array_elements(g->'ranked') c
               union all
               select c from jsonb_array_elements(g0->'ranked') c
  loop
    v_class := app.ci_verdict_class_v696(row_c->>'id');
    if v_class->>'class' <> row_c->>'evidence_class' then
      insert into _fail values ('B4-agreement', format(
        'candidate %s: spine emitted evidence_class %s, app.ci_verdict_class_v696 says %s',
        row_c->>'id', row_c->>'evidence_class', v_class->>'class'));
    end if;
  end loop;

  -- and, named explicitly, the two generator classes this fixture is built to exercise:
  if (app.ci_verdict_class_v696('package_leakage:' || plan_big::text)->>'class') <> 'DIRECT_FACT' then
    insert into _fail values ('B4-named', 'package_leakage did not map to DIRECT_FACT');
  end if;
  if (app.ci_verdict_class_v696('gateway_followthrough:' || svc_gw::text)->>'class') <> 'ASSOCIATION' then
    insert into _fail values ('B4-named', 'gateway_followthrough did not map to ASSOCIATION');
  end if;

  -- =================================================================================================
  -- B5 · impact_class: 'expected_value' (extended, has a real modelled figure), 'scenario' (base,
  --      same candidate, only a scenario figure), 'none' (no cents figure at all, either mode).
  -- =================================================================================================
  select c into cand from jsonb_array_elements(g->'ranked') c
   where c->>'id' = 'package_leakage:' || plan_big::text;
  if cand->'impact'->>'impact_class' <> 'expected_value' then
    insert into _fail values ('B5-ev', format('package_leakage impact_class (extended) was %s, '
      'expected expected_value', cand->'impact'->>'impact_class'));
  end if;
  if coalesce((cand->'impact'->'expected_value'->>'cents')::bigint, -1) <> 19004 then
    insert into _fail values ('B5-ev-cents', format('package_leakage expected_value.cents was %s, '
      'expected 19004 (unchanged from v688 — this migration adds keys, it does not recompute)',
      cand->'impact'->'expected_value'->>'cents'));
  end if;

  select c into cand from jsonb_array_elements(g0->'ranked') c
   where c->>'id' = 'package_leakage:' || plan_big::text;
  if cand->'impact'->>'impact_class' <> 'scenario' then
    insert into _fail values ('B5-scenario', format('package_leakage impact_class (base) was %s, '
      'expected scenario', cand->'impact'->>'impact_class'));
  end if;
  if coalesce((cand->'impact'->>'cents')::bigint, -1) <> 100000 then
    insert into _fail values ('B5-scenario-cents', format('package_leakage base impact.cents was %s, '
      'expected 100000 (unchanged from v688)', cand->'impact'->>'cents'));
  end if;

  foreach v_txt in array array['gateway_followthrough:' || svc_gw::text, 'contactability_gap',
                                'data_quality_coverage'] loop
    select c into cand from jsonb_array_elements(g->'ranked') c where c->>'id' = v_txt;
    if cand is null then
      insert into _fail values ('B5-none-missing-extended', format('%s not found in extended ranked',
        v_txt));
    elsif cand->'impact'->>'impact_class' <> 'none' then
      insert into _fail values ('B5-none-extended', format('%s impact_class (extended) was %s, '
        'expected none', v_txt, cand->'impact'->>'impact_class'));
    end if;
    select c into cand from jsonb_array_elements(g0->'ranked') c where c->>'id' = v_txt;
    if cand is null then
      insert into _fail values ('B5-none-missing-base', format('%s not found in base ranked', v_txt));
    elsif cand->'impact'->>'impact_class' <> 'none' then
      insert into _fail values ('B5-none-base', format('%s impact_class (base) was %s, expected none',
        v_txt, cand->'impact'->>'impact_class'));
    end if;
  end loop;

  -- strength candidates are extended-only; if the weekday strength fired, it must be 'none' too
  -- (a strength never carries a cents figure — see v688's own generator, header line 'a strength is
  -- not a gap to close').
  select c into cand from jsonb_array_elements(g->'ranked') c
   where c->>'domain' = 'strength' and c->>'rank_class' = 'strength' limit 1;
  if cand is not null and cand->'impact'->>'impact_class' <> 'none' then
    insert into _fail values ('B5-strength', format('strength candidate %s impact_class was %s, '
      'expected none', cand->>'id', cand->'impact'->>'impact_class'));
  end if;

  -- =================================================================================================
  -- B6 · the twelve-key contract (v678's own frozen list) is unbroken by any of this: impact_class
  --      lives INSIDE impact, never as a candidate-level key, in EITHER mode. verdict_policy lives
  --      at the top of the RESULT, never on a candidate, in EITHER mode. The base-mode (p_extended
  --      => false) candidate additionally still carries EXACTLY v678's frozen twelve keys and no
  --      more — that check does not apply to extended-mode candidates, which legitimately carry
  --      five more top-level keys by nestly_v688's own design (judgement call 2: incentive, why_now,
  --      reversal_condition, alternatives, cost_basis) — asserting the twelve-key set against THOSE
  --      would be asserting against the wrong contract, not proving this migration's own invariant.
  -- =================================================================================================
  for row_c in select c from jsonb_array_elements(g0->'ranked') c
  loop
    if (select array_agg(k order by k) from jsonb_object_keys(row_c) k)
       <> array['action','comparison','confidence','domain','evidence','evidence_class','id','impact',
                'limitation','pattern','rank','rank_class'] then
      insert into _fail values ('B6-contract-base', format('base-mode candidate %s carries keys %s, '
        'not the frozen twelve-key contract — impact_class must never add a TOP-LEVEL key',
        row_c->>'id', (select array_agg(k order by k) from jsonb_object_keys(row_c) k)));
    end if;
  end loop;

  for row_c in select c from jsonb_array_elements(g->'ranked') c
               union all
               select c from jsonb_array_elements(g0->'ranked') c
  loop
    if row_c ? 'impact_class' then
      insert into _fail values ('B6-leak-candidate', format('candidate %s carries impact_class as a '
        'TOP-LEVEL key, not nested inside impact', row_c->>'id'));
    end if;
    if row_c ? 'verdict_policy' then
      insert into _fail values ('B6-leak-candidate', format('candidate %s carries verdict_policy — '
        'that key belongs on the RESULT, never on a candidate', row_c->>'id'));
    end if;
    if not (row_c->'impact' ? 'impact_class') then
      insert into _fail values ('B6-missing', format('candidate %s has no impact.impact_class',
        row_c->>'id'));
    end if;
  end loop;

  if g ? 'impact_class' or g0 ? 'impact_class' then
    insert into _fail values ('B6-leak-result', 'impact_class leaked onto the top-level result');
  end if;
end
$v696a$;

select case when count(*)=0
            then 'PASS — spine typed verdicts: no CAUSAL anywhere, verdict_policy stated, '
                 'app.ci_verdict_class_v696 exhaustive and in agreement, impact_class correct, '
                 'twelve-key contract unbroken'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v696: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
