-- EXECUTED acceptance fixture for nestly_v690 — dispersion alongside the median (check 45), and
-- one sample-floor authority reaching v179 and v108 as well as the v672 readers (check 61).
--
-- Named v690 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- AUTH CONTEXT. None of app.customer_cadence_batch_v1, app.customer_cadence_v1,
-- app.v179_business_insights, app.subgroup_evidence_v1, app.evidence_block_v1 or
-- app.ci_floor_registry_v690 call auth.uid()/auth.jwt() anywhere in their bodies. The one
-- gated-by-auth trigger touched here (app.enforce_branch_module_row_v94, fired on every sales
-- insert) explicitly returns early `if auth.uid() is null` (verified by reading its body,
-- tests/fixtures/db-schema-snapshot.sql:4803-4824) — so a plain insert with no
-- request.jwt.claims impersonation clears it, same as the v651 fixture found for cadence.
-- public.refresh_growth_recommendation_v108 DOES require auth.uid()/permissions, but this
-- fixture never calls it directly (see D3 below for why).
--
-- ============================================================================================
-- TRUTH TABLE
-- ============================================================================================
-- D1 dispersion, gaps 7,8,9,10 (n=4 intervals):
--   p25 = percentile_cont(0.25): position 0.25*(4-1)=0.75 -> interpolate rank1(7)..rank2(8):
--         7 + 0.75*(8-7) = 7.75
--   p75 = percentile_cont(0.75): position 0.75*(4-1)=2.25 -> interpolate rank3(9)..rank4(10):
--         9 + 0.25*(10-9) = 9.25
--   iqr_days = 9.25 - 7.75 = 1.50
--   basis = 'inter-purchase intervals'
-- D2 dispersion, single interval (2 visits, one gap): interval_observations=1 < 2 ->
--   'dispersion' must be a genuine jsonb null, not a degenerate {p25:x,p75:x,iqr_days:0}.
-- D3 v179 at_risk, 1-customer cohort (2 visits each 1000/2000 cents, 120d/60d ago):
--   n=1 < floor 5 -> evidence.status='insufficient'; recovery_value_one_visit_each_cents must be
--   NULL; customers=1 and their_lifetime_revenue_cents=3000 (the counts) must be KEPT, not null.
-- D4 v179 at_risk, 6-customer cohort (each: 2 visits of 1000 cents, 120d/60d ago):
--   n=6 >= floor 5 -> evidence.status='ok'; recovery_value_one_visit_each_cents =
--   sum(avg_ticket_cents) = 6 * 1000 = 6000 (hand-computed, asserted exactly).
-- D5 v108 arm-size routes through app.subgroup_evidence_v1: with eligible=9, holdout=20%,
--   floor=5 -> holdout arm = floor(9*0.20) = 1 (< 5, insufficient); treatment arm = 9-1 = 8
--   (>= 5, ok). With eligible=30, holdout=20%, floor=5 -> holdout arm = 6 (ok), treatment = 24
--   (ok). Structural proof: the live function body contains the two
--   app.subgroup_evidence_v1(...) calls, not the old raw `<` comparison.
-- D6 registry: app.ci_floor_registry_v690() names exactly 4 surfaces, and each named authority,
--   called directly, behaves as the registry claims.
-- ============================================================================================

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v690$
declare
  -- D1/D2 fixture (cadence dispersion)
  biz            uuid := '00000000-0000-4000-8000-0000000690a1';
  branch         uuid := '00000000-0000-4000-8000-0000000690a2';
  cl_median      uuid := '00000000-0000-4000-8000-0000000690a3';
  cl_pair        uuid := '00000000-0000-4000-8000-0000000690a4';
  v_as_of        timestamptz := (current_date)::timestamp at time zone 'Asia/Singapore';
  g              jsonb;
  v_err          text;
  v_indep_p25    numeric;
  v_indep_p75    numeric;

  -- D3/D4 fixture (v179 at_risk evidence)
  biz_small      uuid := '00000000-0000-4000-8000-0000000690b1';
  biz_ok         uuid := '00000000-0000-4000-8000-0000000690b2';
  cl_small       uuid := '00000000-0000-4000-8000-0000000690b3';
  cl_ok1         uuid := '00000000-0000-4000-8000-0000000690c1';
  cl_ok2         uuid := '00000000-0000-4000-8000-0000000690c2';
  cl_ok3         uuid := '00000000-0000-4000-8000-0000000690c3';
  cl_ok4         uuid := '00000000-0000-4000-8000-0000000690c4';
  cl_ok5         uuid := '00000000-0000-4000-8000-0000000690c5';
  cl_ok6         uuid := '00000000-0000-4000-8000-0000000690c6';
  v_to           date := current_date;
  v_pack         jsonb;

  v_reg          jsonb;
  v_def          text;
begin
  ---------------------------------------------------------------------------
  -- D1/D2 fixture setup — same shape as db/tests/executed/v651_corpus_cadence.sql, including
  -- the v106 reporting-contract backdating landmine (a fresh branch's contract is dated "now",
  -- which would silently exclude every backdated visit below).
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v690 dispersion fixture', 'zz-v690-dispersion', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (branch, biz, 'ZZ v690 branch', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, branch, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore',
         upper(b.currency), true
    from public.businesses b where b.id = biz;

  insert into public.clients (id, business_id, full_name) values
    (cl_median, biz, 'ZZ v690 median (7-10d)'),
    (cl_pair,   biz, 'ZZ v690 single-interval pair');

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl_median, 'service', 1000,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from unnest(array[40,33,25,16,6]) as o;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl_pair, 'service', 1000,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from unnest(array[20,5]) as o;

  ---------------------------------------------------------------------------
  -- D1 — dispersion on the 7/8/9/10 rhythm, asserted exactly, and independently
  -- recomputed (mutation check: a wrong percentile index in the function still has to
  -- agree with this separately-written percentile_cont call over the same raw gaps).
  ---------------------------------------------------------------------------
  select percentile_cont(0.25) within group (order by g_days),
         percentile_cont(0.75) within group (order by g_days)
    into v_indep_p25, v_indep_p75
    from unnest(array[7,8,9,10]::numeric[]) as g_days;

  if v_indep_p25 <> 7.75 or v_indep_p75 <> 9.25 then
    insert into _fail values ('D1-pre',
      format('independent percentile_cont over {7,8,9,10} gave p25=%s p75=%s, expected 7.75/9.25 '
             '— the truth table''s own arithmetic is wrong, not the function', v_indep_p25, v_indep_p75));
  end if;

  begin
    g := app.customer_cadence_v1(biz, cl_median, v_as_of);
    if g->>'status' <> 'ready' then
      insert into _fail values ('D1-pre', format('status=%s, expected ready', g->>'status'));
    end if;
    if g->'dispersion' is null or g->'dispersion' = 'null'::jsonb then
      insert into _fail values ('D1', 'client_median (4 intervals) got a null dispersion block');
    else
      if (g#>>'{dispersion,p25}')::numeric <> 7.75 then
        insert into _fail values ('D1',
          format('dispersion.p25=%s, expected 7.75', g#>>'{dispersion,p25}'));
      end if;
      if (g#>>'{dispersion,p75}')::numeric <> 9.25 then
        insert into _fail values ('D1',
          format('dispersion.p75=%s, expected 9.25', g#>>'{dispersion,p75}'));
      end if;
      if (g#>>'{dispersion,iqr_days}')::numeric <> 1.50 then
        insert into _fail values ('D1',
          format('dispersion.iqr_days=%s, expected 1.50', g#>>'{dispersion,iqr_days}'));
      end if;
      if (g#>>'{dispersion,p25}')::numeric <> v_indep_p25
         or (g#>>'{dispersion,p75}')::numeric <> v_indep_p75 then
        insert into _fail values ('D1-mutation',
          'function dispersion does not match the independently computed percentile_cont values');
      end if;
      if g#>>'{dispersion,basis}' <> 'inter-purchase intervals' then
        insert into _fail values ('D1',
          format('dispersion.basis=%s, expected ''inter-purchase intervals''', g#>>'{dispersion,basis}'));
      end if;
    end if;
    -- Existing keys (median/observations) must be untouched by this migration.
    if (g->>'interval_observations')::int <> 4 or (g->>'median_interval_days')::numeric <> 8.5 then
      insert into _fail values ('D1-regression',
        'v690 changed an existing customer_cadence_v1 key — median/observations no longer match v651''s truth table');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('D1', format('customer_cadence_v1(client_median) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- D2 — a single interval must not manufacture a degenerate dispersion block.
  ---------------------------------------------------------------------------
  begin
    g := app.customer_cadence_v1(biz, cl_pair, v_as_of);
    if g->>'status' <> 'ready' then
      insert into _fail values ('D2-pre', format('status=%s, expected ready', g->>'status'));
    end if;
    if (g->>'interval_observations')::int <> 1 then
      insert into _fail values ('D2-pre',
        format('interval_observations=%s, expected 1 (one gap)', g->>'interval_observations'));
    end if;
    if (g->'dispersion') is distinct from 'null'::jsonb then
      insert into _fail values ('D2',
        format('client_pair (1 interval) got dispersion=%s, expected a genuine null '
               '— a single gap is not a spread', g->'dispersion'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('D2', format('customer_cadence_v1(client_pair) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- D3 — v179 at_risk, 1-customer cohort: evidence insufficient, rate nulled, counts kept.
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz_small, 'ZZ v690 at-risk small', 'zz-v690-atrisk-small', array['dashboard','clients','sales','reports']);
  insert into public.clients (id, business_id, full_name) values (cl_small, biz_small, 'ZZ v690 lone at-risk');
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (gen_random_uuid(), biz_small, cl_small, 'service', 1000,
     (current_date - 120)::timestamp at time zone 'Asia/Singapore',
     (current_date - 120)::timestamp at time zone 'Asia/Singapore'),
    (gen_random_uuid(), biz_small, cl_small, 'service', 2000,
     (current_date - 60)::timestamp at time zone 'Asia/Singapore',
     (current_date - 60)::timestamp at time zone 'Asia/Singapore');

  begin
    v_pack := app.v179_business_insights(biz_small, v_to - 6, v_to, v_to - 13, v_to - 7);
    if (v_pack#>>'{at_risk,customers}')::int <> 1 then
      insert into _fail values ('D3-pre',
        format('at_risk.customers=%s, expected 1 (fixture precondition)', v_pack#>>'{at_risk,customers}'));
    end if;
    if (v_pack#>>'{at_risk,evidence,status}') <> 'insufficient' then
      insert into _fail values ('D3',
        format('at_risk.evidence.status=%s, expected insufficient (n=1 < floor 5)',
               v_pack#>>'{at_risk,evidence,status}'));
    end if;
    if (v_pack#>'{at_risk,recovery_value_one_visit_each_cents}') is distinct from 'null'::jsonb then
      insert into _fail values ('D3',
        format('at_risk.recovery_value_one_visit_each_cents=%s, expected null when evidence is insufficient',
               v_pack#>>'{at_risk,recovery_value_one_visit_each_cents}'));
    end if;
    -- the COUNTS must survive — this is the mutation check for the null-when-insufficient rule:
    -- a mutation that also nulls the counts (instead of only the rate-like field) must be caught.
    if (v_pack#>>'{at_risk,customers}')::int <> 1 then
      insert into _fail values ('D3-mutation', 'at_risk.customers was nulled/changed alongside the rate field');
    end if;
    if (v_pack#>>'{at_risk,their_lifetime_revenue_cents}')::bigint <> 3000 then
      insert into _fail values ('D3-mutation',
        format('at_risk.their_lifetime_revenue_cents=%s, expected 3000 (kept, not nulled)',
               v_pack#>>'{at_risk,their_lifetime_revenue_cents}'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('D3', format('v179_business_insights(biz_small) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- D4 — v179 at_risk, 6-customer cohort: evidence ok, value present and hand-computed.
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz_ok, 'ZZ v690 at-risk ok', 'zz-v690-atrisk-ok', array['dashboard','clients','sales','reports']);
  insert into public.clients (id, business_id, full_name)
  select c.id, biz_ok, 'ZZ v690 at-risk #' || c.n
    from (values (cl_ok1,1),(cl_ok2,2),(cl_ok3,3),(cl_ok4,4),(cl_ok5,5),(cl_ok6,6)) as c(id, n);
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz_ok, c.id, 'service', 1000,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from (values (cl_ok1),(cl_ok2),(cl_ok3),(cl_ok4),(cl_ok5),(cl_ok6)) as c(id)
   cross join unnest(array[120,60]) as o;

  begin
    v_pack := app.v179_business_insights(biz_ok, v_to - 6, v_to, v_to - 13, v_to - 7);
    if (v_pack#>>'{at_risk,customers}')::int <> 6 then
      insert into _fail values ('D4-pre',
        format('at_risk.customers=%s, expected 6 (fixture precondition)', v_pack#>>'{at_risk,customers}'));
    end if;
    if (v_pack#>>'{at_risk,evidence,status}') <> 'ok' then
      insert into _fail values ('D4',
        format('at_risk.evidence.status=%s, expected ok (n=6 >= floor 5)',
               v_pack#>>'{at_risk,evidence,status}'));
    end if;
    if (v_pack#>>'{at_risk,recovery_value_one_visit_each_cents}')::bigint <> 6000 then
      insert into _fail values ('D4',
        format('at_risk.recovery_value_one_visit_each_cents=%s, expected 6000 (6 x 1000 avg ticket)',
               v_pack#>>'{at_risk,recovery_value_one_visit_each_cents}'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('D4', format('v179_business_insights(biz_ok) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- D5 — v108's arm-size check routes through the shared authority. Structural proof: the live
  -- function body contains the two app.subgroup_evidence_v1(...) calls and no longer contains
  -- the old raw comparison. Functional proof: the exact expression shape used in the patch,
  -- evaluated at the policy floor boundary (below and above), on both example audiences.
  ---------------------------------------------------------------------------
  select pg_get_functiondef(to_regprocedure('public.refresh_growth_recommendation_v108(uuid,uuid)'))
    into v_def;
  if v_def is null then
    insert into _fail values ('D5-pre', 'refresh_growth_recommendation_v108 not found');
  else
    if position('app.subgroup_evidence_v1(' in v_def) = 0 then
      insert into _fail values ('D5',
        'refresh_growth_recommendation_v108 no longer calls app.subgroup_evidence_v1 — the arm-size '
        'check does not route through the shared authority');
    end if;
    if position('v_eligible * v_policy.holdout_percent / 100.0) < v_policy.minimum_arm_size' in v_def) > 0 then
      insert into _fail values ('D5',
        'refresh_growth_recommendation_v108 still contains the old raw `<` comparison — the swap did not take');
    end if;
  end if;

  -- eligible=9, holdout=20%: holdout arm = floor(9*0.2)=1 (< floor 5 => insufficient),
  -- treatment arm = 9-1=8 (>= floor 5 => ok).
  if (app.subgroup_evidence_v1(floor(9 * 20 / 100.0)::integer, 5) ->> 'status') <> 'insufficient' then
    insert into _fail values ('D5',
      'holdout arm of 1 against floor 5 (eligible=9, holdout=20%) did not report insufficient');
  end if;
  if (app.subgroup_evidence_v1((9 - floor(9 * 20 / 100.0))::integer, 5) ->> 'status') <> 'ok' then
    insert into _fail values ('D5',
      'treatment arm of 8 against floor 5 (eligible=9, holdout=20%) did not report ok');
  end if;
  -- eligible=30, holdout=20%: holdout arm = 6 (ok), treatment arm = 24 (ok) — both clear the floor.
  if (app.subgroup_evidence_v1(floor(30 * 20 / 100.0)::integer, 5) ->> 'status') <> 'ok' then
    insert into _fail values ('D5',
      'holdout arm of 6 against floor 5 (eligible=30, holdout=20%) did not report ok');
  end if;
  if (app.subgroup_evidence_v1((30 - floor(30 * 20 / 100.0))::integer, 5) ->> 'status') <> 'ok' then
    insert into _fail values ('D5',
      'treatment arm of 24 against floor 5 (eligible=30, holdout=20%) did not report ok');
  end if;

  ---------------------------------------------------------------------------
  -- D6 — the registry names exactly the surfaces it claims to, and each authority it names
  -- behaves the way the registry says.
  ---------------------------------------------------------------------------
  begin
    v_reg := app.ci_floor_registry_v690();
    if v_reg->>'contract_version' <> 'v690' then
      insert into _fail values ('D6', format('contract_version=%s, expected v690', v_reg->>'contract_version'));
    end if;
    if jsonb_array_length(v_reg->'surfaces') <> 4 then
      insert into _fail values ('D6',
        format('registry lists %s surfaces, expected exactly 4', jsonb_array_length(v_reg->'surfaces')));
    end if;
    if not exists (
      select 1 from jsonb_array_elements(v_reg->'surfaces') s
      where s->>'surface' = 'v672_subgroup_readers' and s->>'authority' = 'app.subgroup_evidence_v1'
    ) then
      insert into _fail values ('D6', 'registry missing the v672_subgroup_readers row');
    end if;
    if not exists (
      select 1 from jsonb_array_elements(v_reg->'surfaces') s
      where s->>'surface' = 'v179_business_insights' and s->>'authority' = 'app.subgroup_evidence_v1'
    ) then
      insert into _fail values ('D6', 'registry missing the v179_business_insights row');
    end if;
    if not exists (
      select 1 from jsonb_array_elements(v_reg->'surfaces') s
      where s->>'surface' = 'v108_bring_back_arm_size' and s->>'authority' = 'app.subgroup_evidence_v1'
    ) then
      insert into _fail values ('D6', 'registry missing the v108_bring_back_arm_size row');
    end if;
    if not exists (
      select 1 from jsonb_array_elements(v_reg->'surfaces') s
      where s->>'surface' = 'v652_evidence_block' and s->>'authority' = 'app.evidence_block_v1'
    ) then
      insert into _fail values ('D6', 'registry missing the v652_evidence_block row');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('D6', format('ci_floor_registry_v690 raised %s', v_err));
  end;

  -- Cross-check the v652 authority named by the registry actually behaves as a separate,
  -- parameterised floor (p_min_arm), distinct from subgroup_evidence_v1's fixed default.
  begin
    g := app.evidence_block_v1(
      'test_population', 'test_denominator', current_date - 30, current_date,
      3, 3, 3, 0, 'test_comparison', 'strong_pattern', array[]::text[], null, 10);
    if g->>'verdict' <> 'insufficient' then
      insert into _fail values ('D6-v652',
        format('evidence_block_v1 with arms of 3 against its own p_min_arm=10 gave verdict=%s, expected insufficient',
               g->>'verdict'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('D6-v652', format('evidence_block_v1 raised %s', v_err));
  end;
end
$v690$;

select case when count(*)=0
            then 'PASS — v690 dispersion (median + spread, honest null under 2 intervals) and '
                 'one floor authority (v179 at_risk evidence, v108 arm-size routing, registry)'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v690: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
