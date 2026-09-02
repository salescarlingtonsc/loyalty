-- EXECUTED acceptance fixture for nestly_v695 — service/segment cadence fallback (check 46) and
-- the cadence + v179 halves of the typed-verdicts vocabulary (check 17).
--
-- WHY. db/migrations/20260920_nestly_v695_service_cadence_fallback.sql adds two pooled-evidence
-- cadence authorities (app.service_cadence_v695, app.segment_cadence_v695) and widens
-- app.customer_cadence_v1's fallback chain from two tiers to four:
--   customer_median_interval -> service_median -> segment_median -> business_fallback -> none.
-- It also splices four additive 'evidence_class' keys into app.v179_business_insights. This
-- fixture proves both with a PREDETERMINED truth table, not `> 0` spot checks, and mutation-checks
-- the service median so a hardcoded/tautological reader would show red.
--
-- Named v695 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- AUTH CONTEXT. Neither app.customer_cadence_v1, app.service_cadence_v695,
-- app.segment_cadence_v695, app.v695_sector_cadence_multiplier nor app.v179_business_insights
-- call auth.uid()/auth.jwt() anywhere in their bodies (grepped the migration; same pattern the
-- v651 and v690 corpora already documented). No request.jwt.claims impersonation is needed; the
-- harness's superuser role calls them directly.
--
-- VISIT ELIGIBILITY (app.customer_cadence_batch_v1, unchanged): reversal_of is null,
-- counts_as_visit, created_at <= p_as_of, residual > 0 as of the residual horizon. Every sale
-- below uses kind='service' (no sale_policies override row -> counts_as_visit=true per
-- db/migrations/20260717_frenly_v10_sale_policy.sql:111-122), matching the v651/v690 fixtures.
--
-- V106 LANDMINE (same one v651/v690 document): a brand-new branch's reporting contract is dated
-- "now" by app.v106_append_reporting_contract(), which would silently exclude every backdated
-- sale below from app.customer_cadence_batch_v1's inner join. Worked around with an explicit
-- early-dated contract row, exactly as those two fixtures do.
--
-- SERVICE/SEGMENT CADENCE EXCLUSIONS (app.analytics_sale_class_v1, v628): reversal + non-visit +
-- synthetic-client exclusion for app.service_cadence_v695/app.segment_cadence_v695. None of the
-- fixture's sales are reversed, non-visit, or synthetic, so this is exercised but not separately
-- asserted here (v691's own corpus already proves the exclusion authority itself).
--
-- TIME BASE: v_as_of is pinned to midnight Singapore time on the current test date, and every
-- occurred_at is midnight-SGT on a (current_date - N) date -- every gap is an exact integer
-- number of days, matching the v651/v690 convention.
--
-- ============================================================================================
-- TRUTH TABLE
-- ============================================================================================
-- Business industry = 'fnb' -> app.v695_sector_cadence_multiplier = 1.75
--   (public.sector_policy_versions_v109 'fnb'/'lapse_detection' row, cadence_multiplier=1.75 --
--   read verbatim from db/migrations/20260729_nestly_v109_economics_driver_sector_policy.sql).
--
-- T1 SERVICE TIER. Service S bought by 6 customers (cl_s1..cl_s6), each exactly twice, 14 days
--   apart (first purchase 60 days ago, second 46 days ago -- gap 60-46=14). Every gap is 14, so
--   app.service_cadence_v695(biz, S, as_of):
--     observations=6, evidence={n:6,floor:5,status:'ok'}, median_interval_days=14.0.
--   cl_x has exactly ONE purchase, of S, 10 days ago -- own-cadence obs=0 (< gate 3) -> falls
--   through. cl_x's single most-purchased service is S (their only service, count=1).
--   service_cadence_v695(S) clears the floor (n=6 >= 5) -> evidence_source='service_median',
--   effective_lapse_days = round(14.0 * 1.75, 1) = 24.5, fallback_evidence={n:6,floor:5},
--   evidence_class='ASSOCIATION', a 'note' is present. days_since_last_visit=10 < 24.5 ->
--   deviation_state='within_cycle' (expected_next_from/_to are null for this tier: no single-
--   customer window exists to report).
--
-- T2 SEGMENT TIER. Service T (-> taxonomy node 'beverages.specialty_drinks', level-2 parent
--   'beverages') bought by exactly 2 customers (cl_y, cl_z), each twice, 20 days apart. Service U
--   (-> 'beverages.coffee_tea', same level-2 parent 'beverages') bought by 3 MORE customers
--   (cl_w1..cl_w3), each twice, also 20 days apart. So:
--     app.service_cadence_v695(biz, T, as_of): observations=2, evidence={n:2,floor:5,
--       status:'insufficient'} (only 2 contributing customers, T has no other buyers) ->
--       median_interval_days IS NULL.
--     app.segment_cadence_v695(biz,'category','beverages',as_of) pools T's 2 buyers + U's 3
--       buyers = 5 distinct contributing customers, 5 intervals, EVERY gap 20 days ->
--       observations=5, evidence={n:5,floor:5,status:'ok'}, median_interval_days=20.0
--       (hand-computed: percentile_cont(0.5) of {20,20,20,20,20} = 20).
--   cl_y: own-cadence obs=1 (< gate 3) -> falls through. cl_y's single most-purchased service is
--   T (their only service, count=2). service_cadence_v695(T) is insufficient (n=2 < floor 5) ->
--   falls to segment. cl_y's single most-purchased category is 'beverages' (via T). segment tier
--   clears the floor -> evidence_source='segment_median',
--   effective_lapse_days = round(20.0 * 1.75, 1) = 35.0, fallback_evidence={n:5,floor:5},
--   evidence_class='ASSOCIATION'.
--
-- T3 BUSINESS FALLBACK, UNCHANGED. cl_none has exactly ONE sale, with NO sale_items at all (no
--   service, no category to fall through to) -- the v_service_id and v_segment_key lookups both
--   return no row. evidence_source='business_fallback', effective_lapse_days=90 (the seeded
--   customer_lifecycle_policies_v107.fallback_lapse_days -- IDENTICAL to the pre-v695 constant;
--   the CORE computation is untouched by this migration), evidence_class='ASSOCIATION', and
--   'fallback_evidence' is ABSENT (not merely null -- the key itself is not present, since a
--   fixed policy constant is not a subgroup sample with its own n/floor).
--
-- T4 CUSTOMER TIER, UNCHANGED (reused verbatim from the v651/v690 truth table). cl_median: 5
--   visits at [40,33,25,16,6] days ago -> gaps [7,8,9,10], interval_observations=4,
--   median_interval_days=8.5 (percentile_cont(0.5) of {7,8,9,10}), clears the seeded gate
--   (customer_interval_min_observations=3) -> evidence_source='customer_median_interval',
--   evidence_class='DIRECT_FACT', dispersion identical to the v690 truth table: p25=7.75,
--   p75=9.25, iqr_days=1.50 (percentile_cont interpolation over {7,8,9,10}, proven in
--   db/tests/executed/v690_corpus_dispersion_floor.sql D1).
--
-- T5 ACQUISITION SEGMENT (direct call, not exercised through customer_cadence_v1 -- the fallback
--   chain only resolves 'category' segments). 5 customers acquired via 'walk_in_till'
--   (cl_acq1..cl_acq5), each with 2 paid visits of a plain retail-mapped item, 12 days apart:
--   app.segment_cadence_v695(biz,'acquisition','walk_in_till',as_of): observations=5,
--   evidence={n:5,floor:5,status:'ok'}, median_interval_days=12.0.
--
-- T6 MUTATION-CHECK (proves app.service_cadence_v695 is genuinely input-sensitive, not a
--   hardcoded pair -- sales is append-only, so the mutation is a further INSERT, not an edit,
--   same technique db/tests/executed/v684_corpus_dictionary.sql already established). Service
--   M bought by 5 customers, each twice, with DELIBERATELY VARIED gaps [6,8,10,12,14] days:
--     sorted {6,8,10,12,14}, n=5 -> median (3rd order stat) = 10.0. evidence n=5,floor=5,status=ok.
--   Add a 6th buyer with a gap of 100 days (one more INSERT, sales stays append-only):
--     sorted {6,8,10,12,14,100}, n=6 -> median = avg(3rd,4th) = (10+12)/2 = 11.0. A reader that
--     always returned the seeded 10.0 regardless of input would fail this half of the check.
-- ============================================================================================

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v695$
declare
  biz            uuid := '00000000-0000-4000-8000-000000695001';
  branch         uuid := '00000000-0000-4000-8000-000000695011';

  svc_s          uuid := '00000000-0000-4000-8000-000000695101';
  svc_t          uuid := '00000000-0000-4000-8000-000000695102';
  svc_u          uuid := '00000000-0000-4000-8000-000000695103';
  svc_m          uuid := '00000000-0000-4000-8000-000000695104';
  svc_retail     uuid := '00000000-0000-4000-8000-000000695105';

  cl_s1 uuid := '00000000-0000-4000-8000-000000695201';
  cl_s2 uuid := '00000000-0000-4000-8000-000000695202';
  cl_s3 uuid := '00000000-0000-4000-8000-000000695203';
  cl_s4 uuid := '00000000-0000-4000-8000-000000695204';
  cl_s5 uuid := '00000000-0000-4000-8000-000000695205';
  cl_s6 uuid := '00000000-0000-4000-8000-000000695206';
  cl_x  uuid := '00000000-0000-4000-8000-000000695207';

  cl_y  uuid := '00000000-0000-4000-8000-000000695301';
  cl_z  uuid := '00000000-0000-4000-8000-000000695302';
  cl_w1 uuid := '00000000-0000-4000-8000-000000695303';
  cl_w2 uuid := '00000000-0000-4000-8000-000000695304';
  cl_w3 uuid := '00000000-0000-4000-8000-000000695305';

  cl_none   uuid := '00000000-0000-4000-8000-000000695401';
  cl_median uuid := '00000000-0000-4000-8000-000000695501';

  cl_acq1 uuid := '00000000-0000-4000-8000-000000695601';
  cl_acq2 uuid := '00000000-0000-4000-8000-000000695602';
  cl_acq3 uuid := '00000000-0000-4000-8000-000000695603';
  cl_acq4 uuid := '00000000-0000-4000-8000-000000695604';
  cl_acq5 uuid := '00000000-0000-4000-8000-000000695605';

  cl_m1 uuid := '00000000-0000-4000-8000-000000695701';
  cl_m2 uuid := '00000000-0000-4000-8000-000000695702';
  cl_m3 uuid := '00000000-0000-4000-8000-000000695703';
  cl_m4 uuid := '00000000-0000-4000-8000-000000695704';
  cl_m5 uuid := '00000000-0000-4000-8000-000000695705';
  cl_m6 uuid := '00000000-0000-4000-8000-000000695706';

  v_as_of timestamptz := (current_date)::timestamp at time zone 'Asia/Singapore';
  v_mult  numeric;
  g       jsonb;
  h       jsonb;
  v_err   text;
begin
  ---------------------------------------------------------------------------
  -- fixture business (industry='fnb' -> v109 cadence_multiplier=1.75), branch, v106 landmine
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules, industry)
  values (biz, 'ZZ v695 cadence fallback fixture', 'zz-v695-cadence-fallback',
          array['dashboard','clients','sales','reports'], 'fnb');
  insert into public.branches (id, business_id, name, is_default, active)
  values (branch, biz, 'ZZ v695 branch', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, branch, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore',
         upper(b.currency), true
    from public.businesses b where b.id = biz;

  if not exists (
    select 1 from public.customer_lifecycle_policies_v107 p
     where p.business_id = biz
       and p.fallback_lapse_days = 90
       and p.customer_interval_min_observations = 3
       and p.reactivation_multiplier = 2.000
  ) then
    insert into _fail values ('PRE-policy',
      'auto-seeded customer_lifecycle_policies_v107 row does not match the documented '
      'defaults (90 / 3 / 2.000); the whole T4/T3 truth table below assumes those numbers');
  end if;

  select (parameters->>'cadence_multiplier')::numeric into v_mult
    from public.sector_policy_versions_v109
   where sector_key = 'fnb' and policy_key = 'lapse_detection' and status = 'published';
  if v_mult is distinct from 1.75 then
    insert into _fail values ('PRE-multiplier',
      format('sector_policy_versions_v109 fnb cadence_multiplier=%s, expected 1.75 -- the '
             'T1/T2 effective_lapse_days truth table below assumes 1.75', v_mult));
  end if;

  ---------------------------------------------------------------------------
  -- services + canonical category mapping (level-2 parents: 'food', 'beverages')
  ---------------------------------------------------------------------------
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_s, biz, 'ZZ Set Meal', 1200, 30),
    (svc_t, biz, 'ZZ Bubble Tea', 600, 10),
    (svc_u, biz, 'ZZ Latte', 700, 10),
    (svc_m, biz, 'ZZ Mutation Probe', 500, 10),
    (svc_retail, biz, 'ZZ Retail Item', 300, 5);

  insert into public.service_canonical_map (business_id, service_id, node_key, version_no, method)
  values
    (biz, svc_s, 'food.mains', 1, 'owner_chosen'),
    (biz, svc_t, 'beverages.specialty_drinks', 1, 'owner_chosen'),
    (biz, svc_u, 'beverages.coffee_tea', 1, 'owner_chosen');
  -- svc_m and svc_retail deliberately left unmapped: T6's mutation probe and T5's acquisition
  -- scenario exercise service/segment cadence directly and need no category resolution.

  ---------------------------------------------------------------------------
  -- customers (T5's acquisition-path customers are inserted separately, under the
  -- app.first_acquired_via GUC).
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name) values
    (cl_s1, biz, 'ZZ v695 S buyer 1'), (cl_s2, biz, 'ZZ v695 S buyer 2'),
    (cl_s3, biz, 'ZZ v695 S buyer 3'), (cl_s4, biz, 'ZZ v695 S buyer 4'),
    (cl_s5, biz, 'ZZ v695 S buyer 5'), (cl_s6, biz, 'ZZ v695 S buyer 6'),
    (cl_x,  biz, 'ZZ v695 single S visit'),
    (cl_y,  biz, 'ZZ v695 T buyer Y'), (cl_z, biz, 'ZZ v695 T buyer Z'),
    (cl_w1, biz, 'ZZ v695 U buyer 1'), (cl_w2, biz, 'ZZ v695 U buyer 2'),
    (cl_w3, biz, 'ZZ v695 U buyer 3'),
    (cl_none, biz, 'ZZ v695 nothing applicable'),
    (cl_median, biz, 'ZZ v695 median rhythm'),
    (cl_m1, biz, 'ZZ v695 M buyer 1'), (cl_m2, biz, 'ZZ v695 M buyer 2'),
    (cl_m3, biz, 'ZZ v695 M buyer 3'), (cl_m4, biz, 'ZZ v695 M buyer 4'),
    (cl_m5, biz, 'ZZ v695 M buyer 5'), (cl_m6, biz, 'ZZ v695 M mutation buyer');

  ---------------------------------------------------------------------------
  -- T1 -- service tier: 6 buyers of S, each twice, 14 days apart. cl_x: one S purchase only.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl, 'service', 1200,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from (values (cl_s1,60),(cl_s1,46), (cl_s2,60),(cl_s2,46), (cl_s3,60),(cl_s3,46),
                 (cl_s4,60),(cl_s4,46), (cl_s5,60),(cl_s5,46), (cl_s6,60),(cl_s6,46)) as t(cl,o);

  insert into public.sale_items (business_id, sale_id, item_type, ref_id, description, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc_s, 'ZZ Set Meal', 1, 1200, 1200
    from public.sales s
   where s.business_id = biz and s.client_id in (cl_s1,cl_s2,cl_s3,cl_s4,cl_s5,cl_s6);

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, branch, cl_x, 'service', 1200,
          (current_date - 10)::timestamp at time zone 'Asia/Singapore',
          (current_date - 10)::timestamp at time zone 'Asia/Singapore');
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, description, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc_s, 'ZZ Set Meal', 1, 1200, 1200
    from public.sales s where s.business_id = biz and s.client_id = cl_x;

  ---------------------------------------------------------------------------
  -- T2 -- segment tier: T bought by cl_y/cl_z (2 buyers only), U bought by cl_w1..w3 (3 more),
  -- both mapped under the 'beverages' level-2 category, all gaps 20 days.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl, 'service', 600,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from (values (cl_y,35),(cl_y,15), (cl_z,35),(cl_z,15)) as t(cl,o);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, description, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc_t, 'ZZ Bubble Tea', 1, 600, 600
    from public.sales s where s.business_id = biz and s.client_id in (cl_y, cl_z);

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl, 'service', 700,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from (values (cl_w1,35),(cl_w1,15), (cl_w2,35),(cl_w2,15), (cl_w3,35),(cl_w3,15)) as t(cl,o);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, description, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc_u, 'ZZ Latte', 1, 700, 700
    from public.sales s where s.business_id = biz and s.client_id in (cl_w1, cl_w2, cl_w3);

  ---------------------------------------------------------------------------
  -- T3 -- business fallback, unchanged: one sale, no sale_items at all.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, branch, cl_none, 'service', 500,
          (current_date - 5)::timestamp at time zone 'Asia/Singapore',
          (current_date - 5)::timestamp at time zone 'Asia/Singapore');

  ---------------------------------------------------------------------------
  -- T4 -- customer tier, unchanged (v651/v690 client_median reused verbatim).
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl_median, 'service', 1000,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from unnest(array[40,33,25,16,6]) as o;

  ---------------------------------------------------------------------------
  -- T5 -- acquisition segment (direct call): 5 customers acquired via 'walk_in_till', 2 retail
  -- visits each, 12 days apart. app.clients writes are guarded: the acquisition-path GUC must
  -- be set before each insert (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md's write-guard table).
  ---------------------------------------------------------------------------
  perform set_config('app.first_acquired_via', 'walk_in_till', true);
  insert into public.clients (id, business_id, full_name) values
    (cl_acq1, biz, 'ZZ v695 acq 1'), (cl_acq2, biz, 'ZZ v695 acq 2'),
    (cl_acq3, biz, 'ZZ v695 acq 3'), (cl_acq4, biz, 'ZZ v695 acq 4'),
    (cl_acq5, biz, 'ZZ v695 acq 5');
  if not (select bool_and(first_acquired_via = 'walk_in_till')
            from public.clients where id in (cl_acq1,cl_acq2,cl_acq3,cl_acq4,cl_acq5)) then
    insert into _fail values ('PRE-acquisition',
      'the app.first_acquired_via GUC did not stick -- the T5 acquisition-segment scenario '
      'proves nothing without it');
  end if;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl, 'retail', 300,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from (values (cl_acq1,24),(cl_acq1,12), (cl_acq2,24),(cl_acq2,12), (cl_acq3,24),(cl_acq3,12),
                 (cl_acq4,24),(cl_acq4,12), (cl_acq5,24),(cl_acq5,12)) as t(cl,o);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, description, qty, unit_cents, line_cents)
  select biz, s.id, 'retail', svc_retail, 'ZZ Retail Item', 1, 300, 300
    from public.sales s
   where s.business_id = biz and s.client_id in (cl_acq1,cl_acq2,cl_acq3,cl_acq4,cl_acq5);

  ---------------------------------------------------------------------------
  -- T6 -- mutation-check seed: 5 buyers of M, VARIED gaps [6,8,10,12,14].
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl, 'service', 500,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from (values (cl_m1,100,94), (cl_m2,100,92), (cl_m3,100,90), (cl_m4,100,88), (cl_m5,100,86))
         as t(cl,o1,o2), lateral (values (o1),(o2)) as u(o);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, description, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc_m, 'ZZ Mutation Probe', 1, 500, 500
    from public.sales s where s.business_id = biz and s.client_id in (cl_m1,cl_m2,cl_m3,cl_m4,cl_m5);

  ---------------------------------------------------------------------------
  -- T1 assertions
  ---------------------------------------------------------------------------
  begin
    g := app.service_cadence_v695(biz, svc_s, v_as_of);
    if (g->>'observations')::int <> 6 then
      insert into _fail values ('T1-service', format('observations=%s, expected 6', g->>'observations'));
    end if;
    if (g->'evidence'->>'n')::int <> 6 or (g->'evidence'->>'floor')::int <> 5
       or g->'evidence'->>'status' <> 'ok' then
      insert into _fail values ('T1-service', format('evidence=%s, expected n=6,floor=5,status=ok', g->'evidence'));
    end if;
    if (g->>'median_interval_days')::numeric <> 14.0 then
      insert into _fail values ('T1-service', format('median_interval_days=%s, expected 14.0', g->>'median_interval_days'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T1-service', format('app.service_cadence_v695(S) raised %s', v_err));
  end;

  begin
    g := app.customer_cadence_v1(biz, cl_x, v_as_of);
    if g->>'status' <> 'ready' then
      insert into _fail values ('T1-pre', format('cl_x status=%s, expected ready', g->>'status'));
    end if;
    if (g->>'interval_observations')::int <> 0 then
      insert into _fail values ('T1-pre',
        format('cl_x interval_observations=%s, expected 0 (one visit, no interval, so the '
               'customer tier must not have been chosen)', g->>'interval_observations'));
    end if;
    if g->>'evidence_source' <> 'service_median' then
      insert into _fail values ('T1',
        format('cl_x evidence_source=%s, expected service_median', g->>'evidence_source'));
    end if;
    if (g->>'effective_lapse_days')::numeric <> 24.5 then
      insert into _fail values ('T1',
        format('cl_x effective_lapse_days=%s, expected round(14.0*1.75,1)=24.5', g->>'effective_lapse_days'));
    end if;
    if g->>'evidence_class' <> 'ASSOCIATION' then
      insert into _fail values ('T1',
        format('cl_x evidence_class=%s, expected ASSOCIATION', g->>'evidence_class'));
    end if;
    if not (g ? 'note') or length(coalesce(g->>'note','')) = 0 then
      insert into _fail values ('T1', 'cl_x (ASSOCIATION tier) has no note key');
    end if;
    if (g->'fallback_evidence'->>'n')::int <> 6 or (g->'fallback_evidence'->>'floor')::int <> 5 then
      insert into _fail values ('T1',
        format('cl_x fallback_evidence=%s, expected {n:6,floor:5}', g->'fallback_evidence'));
    end if;
    if g->>'deviation_state' <> 'within_cycle' then
      insert into _fail values ('T1',
        format('cl_x (10d absent, effective_lapse 24.5d) deviation_state=%s, expected within_cycle',
               g->>'deviation_state'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T1', format('customer_cadence_v1(cl_x) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- T2 assertions
  ---------------------------------------------------------------------------
  begin
    g := app.service_cadence_v695(biz, svc_t, v_as_of);
    if g->'evidence'->>'status' <> 'insufficient' or (g->'evidence'->>'n')::int <> 2 then
      insert into _fail values ('T2-service', format('T evidence=%s, expected n=2,status=insufficient', g->'evidence'));
    end if;
    if g->'median_interval_days' is distinct from 'null'::jsonb then
      insert into _fail values ('T2-service',
        format('T median_interval_days=%s, expected null (insufficient evidence)', g->>'median_interval_days'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T2-service', format('app.service_cadence_v695(T) raised %s', v_err));
  end;

  begin
    g := app.segment_cadence_v695(biz, 'category', 'beverages', v_as_of);
    if (g->>'observations')::int <> 5 then
      insert into _fail values ('T2-segment', format('observations=%s, expected 5', g->>'observations'));
    end if;
    if (g->'evidence'->>'n')::int <> 5 or (g->'evidence'->>'floor')::int <> 5
       or g->'evidence'->>'status' <> 'ok' then
      insert into _fail values ('T2-segment', format('evidence=%s, expected n=5,floor=5,status=ok', g->'evidence'));
    end if;
    if (g->>'median_interval_days')::numeric <> 20.0 then
      insert into _fail values ('T2-segment', format('median_interval_days=%s, expected 20.0', g->>'median_interval_days'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T2-segment', format('app.segment_cadence_v695(beverages) raised %s', v_err));
  end;

  begin
    g := app.customer_cadence_v1(biz, cl_y, v_as_of);
    if g->>'status' <> 'ready' then
      insert into _fail values ('T2-pre', format('cl_y status=%s, expected ready', g->>'status'));
    end if;
    if g->>'evidence_source' <> 'segment_median' then
      insert into _fail values ('T2',
        format('cl_y evidence_source=%s, expected segment_median (service T insufficient, '
               'category beverages ok)', g->>'evidence_source'));
    end if;
    if (g->>'effective_lapse_days')::numeric <> 35.0 then
      insert into _fail values ('T2',
        format('cl_y effective_lapse_days=%s, expected round(20.0*1.75,1)=35.0', g->>'effective_lapse_days'));
    end if;
    if (g->'fallback_evidence'->>'n')::int <> 5 or (g->'fallback_evidence'->>'floor')::int <> 5 then
      insert into _fail values ('T2',
        format('cl_y fallback_evidence=%s, expected {n:5,floor:5}', g->'fallback_evidence'));
    end if;
    if g->>'evidence_class' <> 'ASSOCIATION' then
      insert into _fail values ('T2', format('cl_y evidence_class=%s, expected ASSOCIATION', g->>'evidence_class'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T2', format('customer_cadence_v1(cl_y) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- T3 assertions -- business_fallback, unchanged core numbers, but evidence_class is additive.
  ---------------------------------------------------------------------------
  begin
    g := app.customer_cadence_v1(biz, cl_none, v_as_of);
    if g->>'status' <> 'ready' then
      insert into _fail values ('T3-pre', format('cl_none status=%s, expected ready', g->>'status'));
    end if;
    if g->>'evidence_source' <> 'business_fallback' then
      insert into _fail values ('T3',
        format('cl_none evidence_source=%s, expected business_fallback (no service, no category)',
               g->>'evidence_source'));
    end if;
    if (g->>'effective_lapse_days')::numeric <> 90 then
      insert into _fail values ('T3',
        format('cl_none effective_lapse_days=%s, expected the UNCHANGED fallback_lapse_days=90',
               g->>'effective_lapse_days'));
    end if;
    if g->>'evidence_class' <> 'ASSOCIATION' then
      insert into _fail values ('T3', format('cl_none evidence_class=%s, expected ASSOCIATION', g->>'evidence_class'));
    end if;
    if g ? 'fallback_evidence' then
      insert into _fail values ('T3',
        'cl_none (business_fallback) carries a fallback_evidence key -- a fixed policy '
        'constant is not a subgroup sample and must not fabricate an n/floor');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T3', format('customer_cadence_v1(cl_none) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- T4 assertions -- customer tier byte-identical to the v651/v690 truth table.
  ---------------------------------------------------------------------------
  begin
    g := app.customer_cadence_v1(biz, cl_median, v_as_of);
    if g->>'status' <> 'ready' then
      insert into _fail values ('T4-pre', format('cl_median status=%s, expected ready', g->>'status'));
    end if;
    if (g->>'interval_observations')::int <> 4 then
      insert into _fail values ('T4', format('interval_observations=%s, expected 4', g->>'interval_observations'));
    end if;
    if g->>'evidence_source' <> 'customer_median_interval' then
      insert into _fail values ('T4',
        format('cl_median evidence_source=%s, expected customer_median_interval (unchanged tier)',
               g->>'evidence_source'));
    end if;
    if (g->>'median_interval_days')::numeric <> 8.5 then
      insert into _fail values ('T4', format('median_interval_days=%s, expected 8.5', g->>'median_interval_days'));
    end if;
    if g->>'evidence_class' <> 'DIRECT_FACT' then
      insert into _fail values ('T4',
        format('cl_median evidence_class=%s, expected DIRECT_FACT (own-history tier)', g->>'evidence_class'));
    end if;
    if g ? 'fallback_evidence' then
      insert into _fail values ('T4', 'cl_median (customer_median_interval) unexpectedly carries fallback_evidence');
    end if;
    if (g->'dispersion'->>'p25')::numeric <> 7.75 or (g->'dispersion'->>'p75')::numeric <> 9.25
       or (g->'dispersion'->>'iqr_days')::numeric <> 1.50 then
      insert into _fail values ('T4',
        format('cl_median dispersion=%s, expected {p25:7.75,p75:9.25,iqr_days:1.50} -- must be '
               'IDENTICAL to the pre-v695 (v690) truth table', g->'dispersion'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T4', format('customer_cadence_v1(cl_median) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- T5 assertions -- acquisition segment, direct call.
  ---------------------------------------------------------------------------
  begin
    g := app.segment_cadence_v695(biz, 'acquisition', 'walk_in_till', v_as_of);
    if (g->>'observations')::int <> 5 then
      insert into _fail values ('T5', format('observations=%s, expected 5', g->>'observations'));
    end if;
    if (g->'evidence'->>'n')::int <> 5 or (g->'evidence'->>'floor')::int <> 5
       or g->'evidence'->>'status' <> 'ok' then
      insert into _fail values ('T5', format('evidence=%s, expected n=5,floor=5,status=ok', g->'evidence'));
    end if;
    if (g->>'median_interval_days')::numeric <> 12.0 then
      insert into _fail values ('T5', format('median_interval_days=%s, expected 12.0', g->>'median_interval_days'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T5', format('app.segment_cadence_v695(acquisition) raised %s', v_err));
  end;

  begin
    if app.segment_cadence_v695(biz, 'bogus_kind', 'x', v_as_of) is not null then
      insert into _fail values ('T5-guard', 'segment_cadence_v695 accepted an unknown segment_kind');
    end if;
    insert into _fail values ('T5-guard', 'segment_cadence_v695 did not raise on an unknown segment_kind');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('T5-guard', format('unexpected sqlstate %s for an unknown segment_kind', v_err));
    end if;
  end;

  ---------------------------------------------------------------------------
  -- T6 -- mutation-check: seed value first, then a further INSERT (sales is append-only).
  ---------------------------------------------------------------------------
  begin
    g := app.service_cadence_v695(biz, svc_m, v_as_of);
    if (g->>'observations')::int <> 5 then
      insert into _fail values ('T6-seed', format('observations=%s, expected 5', g->>'observations'));
    end if;
    if (g->'evidence'->>'n')::int <> 5 or g->'evidence'->>'status' <> 'ok' then
      insert into _fail values ('T6-seed', format('evidence=%s, expected n=5,status=ok', g->'evidence'));
    end if;
    if (g->>'median_interval_days')::numeric <> 10.0 then
      insert into _fail values ('T6-seed',
        format('median_interval_days=%s, expected 10.0 (median of {6,8,10,12,14})', g->>'median_interval_days'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T6-seed', format('app.service_cadence_v695(M, seed) raised %s', v_err));
  end;

  -- the mutation: one more buyer, gap 100 days (append-only INSERT, never an UPDATE).
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (gen_random_uuid(), biz, branch, cl_m6, 'service', 500,
     (current_date - 150)::timestamp at time zone 'Asia/Singapore',
     (current_date - 150)::timestamp at time zone 'Asia/Singapore'),
    (gen_random_uuid(), biz, branch, cl_m6, 'service', 500,
     (current_date - 50)::timestamp at time zone 'Asia/Singapore',
     (current_date - 50)::timestamp at time zone 'Asia/Singapore');
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, description, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc_m, 'ZZ Mutation Probe', 1, 500, 500
    from public.sales s where s.business_id = biz and s.client_id = cl_m6;

  begin
    h := app.service_cadence_v695(biz, svc_m, v_as_of);
    if (h->>'observations')::int <> 6 then
      insert into _fail values ('T6-mutated', format('observations=%s, expected 6', h->>'observations'));
    end if;
    if (h->'evidence'->>'n')::int <> 6 then
      insert into _fail values ('T6-mutated', format('evidence.n=%s, expected 6', h->'evidence'->>'n'));
    end if;
    if (h->>'median_interval_days')::numeric <> 11.0 then
      insert into _fail values ('T6-mutated',
        format('median_interval_days=%s, expected 11.0 (median of {6,8,10,12,14,100}) -- if '
               'this still reads 10.0, app.service_cadence_v695 ignored the new buyer entirely',
               h->>'median_interval_days'));
    end if;
    if h->>'median_interval_days' = g->>'median_interval_days' then
      insert into _fail values ('T6-mutation-check',
        'the median did not change after adding a 6th buyer with a wildly different gap -- '
        'this reader looks hardcoded, not computed');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T6-mutated', format('app.service_cadence_v695(M, mutated) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- v179 typed-verdict splices: retention/weekday/top_customers=DIRECT_FACT, at_risk=ASSOCIATION,
  -- CAUSAL never appears. Uses cl_median's own sales as the window (already inserted above).
  ---------------------------------------------------------------------------
  begin
    g := app.v179_business_insights(biz,
           (current_date - 41), current_date, (current_date - 400), (current_date - 300));
    if g->'retention'->>'evidence_class' <> 'DIRECT_FACT' then
      insert into _fail values ('V179-retention',
        format('evidence_class=%s, expected DIRECT_FACT', g->'retention'->>'evidence_class'));
    end if;
    if g->'weekday_pattern'->>'evidence_class' <> 'DIRECT_FACT' then
      insert into _fail values ('V179-weekday',
        format('evidence_class=%s, expected DIRECT_FACT', g->'weekday_pattern'->>'evidence_class'));
    end if;
    if g->'top_customers'->>'evidence_class' <> 'DIRECT_FACT' then
      insert into _fail values ('V179-top_customers',
        format('evidence_class=%s, expected DIRECT_FACT', g->'top_customers'->>'evidence_class'));
    end if;
    if g->'at_risk'->>'evidence_class' <> 'ASSOCIATION' then
      insert into _fail values ('V179-at_risk',
        format('evidence_class=%s, expected ASSOCIATION', g->'at_risk'->>'evidence_class'));
    end if;
    if not (g->'at_risk' ? 'evidence_class_note') or length(coalesce(g->'at_risk'->>'evidence_class_note','')) = 0 then
      insert into _fail values ('V179-at_risk', 'at_risk (ASSOCIATION) has no evidence_class_note');
    end if;
    if g::text ilike '%CAUSAL%' then
      insert into _fail values ('V179-causal', 'CAUSAL appears somewhere in the v179 payload -- it must never appear');
    end if;
    -- existing keys/values from v690 are untouched: 'customers' and 'their_lifetime_revenue_cents'
    -- must both still be present alongside the new evidence_class key.
    if not (g->'at_risk' ? 'customers') or not (g->'at_risk' ? 'evidence') then
      insert into _fail values ('V179-at_risk', 'at_risk lost a pre-existing key (customers/evidence)');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('V179', format('app.v179_business_insights raised %s', v_err));
  end;
end
$v695$;

select case when count(*)=0
            then 'PASS — v695 service/segment cadence fallback: 4-tier chain, mutation-sensitive '
                 'service median, acquisition segment, v179 typed verdicts (cadence + v179 halves)'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v695: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
