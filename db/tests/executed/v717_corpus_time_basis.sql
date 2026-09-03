-- EXECUTED acceptance fixture for nestly_v717 -- check 35/13 (time_basis on all seven readers)
-- and check 61 (category-mix floor gate on app.subgroup_evidence_v1), plus check 8 (branch-clock
-- behavioural proof on app.customer_cadence_v1, read alongside this migration as the corpus that
-- CLOSES check 8 for the cadence surface -- v717 itself only re-emits the five readers named
-- below plus the demographic-cohort time_basis fix; it does not touch app.customer_cadence_v1,
-- which was already correct since v706/v709 and is proven, not patched, here).
--
-- Named v717 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- ============================================================================================
-- TRUTH TABLE A -- time_basis on all seven readers (predetermined from reading each body; see
-- the migration header for the column each one actually buckets on)
-- ============================================================================================
--   get_ci_acquisition_v1        result->>'time_basis'                = 'client_created_at'
--   get_ci_category_mix_v1       result->>'time_basis'                = 'sale_occurred_at'
--   get_ci_contactability_v1     result->>'time_basis'                = 'as_of'
--   get_ci_daypart_v1            result->>'time_basis'                = 'sale_occurred_at'  (v698, unmodified -- proof only)
--   get_ci_demographic_cohort_v1 result->>'time_basis'                = 'sale_occurred_at'  (v717 top-level fix -- see below)
--   get_ci_engagement_v1         result->>'time_basis'                = 'engagement_event_occurred_at'
--   get_ci_funnel_v1             result->>'time_basis'                = 'funnel_counter_day'
--
-- get_ci_demographic_cohort_v1 is the one surprise in this corpus: v706 (2026-09-02, an earlier
-- migration this session) already added 'time_basis' to the reader's own 'period' object, and
-- reading the source alone says "done". It is not: app.ci_envelope_v680 always overwrites the
-- top-level 'period' key with its own version (jsonb `||`, right operand wins on collision), so
-- the v706 addition never reached a caller. B2 below asserts the FINAL envelope output, not the
-- source, which is exactly the class of false-closure check 35/13 exists to catch -- part of why
-- this fixture calls every reader for real rather than trusting pg_get_functiondef.
--
-- ============================================================================================
-- TRUTH TABLE B -- category-mix floor gate (check 61 / the "3-of-3 trap", check 62, applied to
-- category distributions specifically). Floor = app.subgroup_evidence_v1's default, 5.
-- ============================================================================================
--   zz_v717_cat_low  (3 customers, $10.00/$20.00/$30.00): evidence.n=3 < floor 5 -> insufficient.
--     distribution IS NULL. skew_note IS NULL. revenue_cents=6000, line_count=3, customer_count=3
--     (counts stay -- only the rate/distribution-shaped fields are gated).
--   zz_v717_cat_high (6 customers, $5/$10/$15/$20/$25/$30): evidence.n=6 >= floor 5 -> ok.
--     distribution present: n=6, mean=1750.00, median=1750.00, top1_share_bps=2857,
--     skew_material=false, mean_excl_top1=1500.00 (hand-computed: mean of {500,1000,1500,2000,
--     2500} = 7500/5 = 1500.00). revenue_cents=10500, line_count=6, customer_count=6.
--
-- ============================================================================================
-- TRUTH TABLE C -- check 8, branch-clock behavioural proof on app.customer_cadence_v1. Two
-- otherwise-identical firms, ONE branch each, differing only in branch timezone (Kolkata vs
-- Singapore). Each firm's one customer has two paid sales: an early one (2026-07-01T02:00:00Z,
-- unambiguous in both zones) and a late one at 2026-08-09T17:00:00Z -- 2026-08-09 22:30 in
-- Kolkata (+05:30), 2026-08-10 01:00 in Singapore (+08:00): the SAME instant is Aug 9 in one
-- zone and Aug 10 in the other. p_as_of := 2026-08-09T18:00:00Z (Aug 9 23:30 Kolkata, Aug 10
-- 02:00 Singapore -- same split).
--
-- app.customer_cadence_v1 resolves p_before/p_residual_to as (p_as_of at bucket-tz)::date + 1,
-- and app.customer_cadence_batch_v1 only counts a visit_day < p_before -- but the visit_day
-- itself is computed by app.ci_visit_day_v699, which is HARD-WIRED to Asia/Singapore (v699,
-- deliberately, unrelated to bucket_timezone). So the late sale's visit_day is fixed at 2026-08-10
-- regardless of firm, while the CUTOFF differs by firm:
--   Kolkata firm: bucket_timezone=Asia/Kolkata (firm_agreed, its one branch). p_before =
--     (Aug 9 23:30 Kolkata)::date + 1 = Aug 10. Late-sale visit_day (Aug 10) < Aug 10 is FALSE
--     -> late sale EXCLUDED. Only the early sale counts: paid_visits=1, last_visit_at=early sale,
--     interval_observations=0.
--   Singapore firm: bucket_timezone=Asia/Singapore (firm_agreed). p_before =
--     (Aug 10 02:00 Singapore)::date + 1 = Aug 11. Late-sale visit_day (Aug 10) < Aug 11 is TRUE
--     -> late sale INCLUDED. paid_visits=2, last_visit_at=late sale, interval_observations=1,
--     median_interval_days=39.6 (hand-computed: (2026-08-09T17:00 - 2026-07-01T02:00) / 86400).
-- Same customer shape, same as_of instant, same underlying sales -- the ONLY input that differs
-- is which timezone the branch (hence the firm) is in, and it changes last_visit_at AND
-- paid_visits, not merely a cosmetic label. Both firms disclose timezone_basis='firm_agreed'
-- (each has exactly one active branch, so app.ci_bucket_tz_v698's single-branch case applies).
-- ============================================================================================

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

-- ------------------------------------------------------------------------------------------
-- platform impersonation: a super admin can read any firm's CI surface
-- (app.v176_can_read_firm_report), the same route every other CI corpus fixture in this repo
-- uses to clear app.ci_access_gate_v667 without wiring a full operational business.
-- ------------------------------------------------------------------------------------------
do $v717setup$
declare
  u_sa uuid := '00000000-0000-4000-8000-000000717eee';
begin
  insert into auth.users (id, email) values (u_sa, 'zz-v717-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v717-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method', 'oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
end;
$v717setup$;

-- ============================================================================================
-- PART A -- time_basis on all seven readers
-- ============================================================================================
do $v717a$
declare
  biz    uuid := '00000000-0000-4000-8000-000000717501';
  br     uuid := '00000000-0000-4000-8000-000000717511';
  cl     uuid := '00000000-0000-4000-8000-000000717601';
  node   text := 'zz_v717_demog_node';
  p_from date := current_date - 30;
  p_to   date := current_date;
  v_as_of timestamptz := clock_timestamp();
  r      jsonb;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v717 general', 'zz-v717-general', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active, timezone, billing_state)
  values (br, biz, 'ZZ general branch', true, true, 'Asia/Singapore', 'active');
  insert into public.taxonomy_nodes (version_no, pack, level, parent_key, node_key, label, question)
  values (1, 'generic', 2, null, node, 'ZZ demographic node', '?')
  on conflict do nothing;

  perform set_config('app.first_acquired_via', 'qr', true);
  insert into public.clients (id, business_id, full_name, created_at, first_acquired_via)
  values (cl, biz, 'ZZ acquire client', now() - interval '10 days', 'qr');

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, created_at, counts_as_revenue, counts_as_visit)
  values (gen_random_uuid(), biz, br, cl, 'service', 1000,
          now() - interval '5 days', now() - interval '5 days', true, true);

  -- A1 -- get_ci_acquisition_v1
  r := public.get_ci_acquisition_v1(biz, p_from, p_to, null, v_as_of);
  if r->>'time_basis' is distinct from 'client_created_at' then
    insert into _fail values ('A1-acquisition', format('time_basis=%s, expected client_created_at', r->>'time_basis'));
  end if;

  -- A2 -- get_ci_category_mix_v1 (top-level time_basis only here; the floor gate is PART B)
  r := public.get_ci_category_mix_v1(biz, p_from, p_to, null, v_as_of);
  if r->>'time_basis' is distinct from 'sale_occurred_at' then
    insert into _fail values ('A2-category_mix', format('time_basis=%s, expected sale_occurred_at', r->>'time_basis'));
  end if;

  -- A3 -- get_ci_contactability_v1
  r := public.get_ci_contactability_v1(biz, null, v_as_of);
  if r->>'time_basis' is distinct from 'as_of' then
    insert into _fail values ('A3-contactability', format('time_basis=%s, expected as_of', r->>'time_basis'));
  end if;

  -- A4 -- get_ci_daypart_v1 (regression floor: already emitted this since v698, unmodified here)
  r := public.get_ci_daypart_v1(biz, p_from, p_to, null, v_as_of);
  if r->>'time_basis' is distinct from 'sale_occurred_at' then
    insert into _fail values ('A4-daypart', format('time_basis=%s, expected sale_occurred_at', r->>'time_basis'));
  end if;

  -- A5 -- get_ci_demographic_cohort_v1 (the v717 fix: must appear TOP-LEVEL, surviving the
  -- envelope's period overwrite -- an empty cohort is fine, this only checks the key travels).
  r := public.get_ci_demographic_cohort_v1(biz, 'female', 18, 65, node, p_from, p_to, 60, null, v_as_of);
  if r->>'time_basis' is distinct from 'sale_occurred_at' then
    insert into _fail values ('A5-demographic_cohort', format('time_basis=%s, expected sale_occurred_at (top-level; check it is not only nested under period, which the envelope overwrites)', r->>'time_basis'));
  end if;
  if r->'period'->>'time_basis' is not distinct from null and r->>'time_basis' is null then
    insert into _fail values ('A5-demographic_cohort-envelope-clobber',
      'neither a top-level time_basis nor a period.time_basis is present -- the v706 nested key and the v717 top-level key are both missing');
  end if;

  -- A6 -- get_ci_engagement_v1
  r := public.get_ci_engagement_v1(biz, 12, null, v_as_of);
  if r->>'time_basis' is distinct from 'engagement_event_occurred_at' then
    insert into _fail values ('A6-engagement', format('time_basis=%s, expected engagement_event_occurred_at', r->>'time_basis'));
  end if;

  -- A7 -- get_ci_funnel_v1
  r := public.get_ci_funnel_v1(biz, p_from, p_to, null, v_as_of);
  if r->>'time_basis' is distinct from 'funnel_counter_day' then
    insert into _fail values ('A7-funnel', format('time_basis=%s, expected funnel_counter_day', r->>'time_basis'));
  end if;
end
$v717a$;

-- ============================================================================================
-- PART B -- category-mix floor gate (check 61)
-- ============================================================================================
do $v717b$
declare
  biz      uuid := '00000000-0000-4000-8000-000000717401';
  br       uuid := '00000000-0000-4000-8000-000000717411';
  svc_low  uuid := '00000000-0000-4000-8000-000000717421';
  svc_high uuid := '00000000-0000-4000-8000-000000717422';
  cl       uuid;
  s        uuid;
  i        integer;
  r        jsonb;
  cat_low  jsonb;
  cat_high jsonb;
begin
  insert into public.taxonomy_nodes (version_no, pack, level, parent_key, node_key, label, question)
  values
    (1, 'generic', 2, null, 'zz_v717_cat_low', 'ZZ Low', '?'),
    (1, 'generic', 2, null, 'zz_v717_cat_high', 'ZZ High', '?')
  on conflict do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v717 catmix', 'zz-v717-catmix', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active, timezone, billing_state)
  values (br, biz, 'ZZ catmix branch', true, true, 'Asia/Singapore', 'active');
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_low, biz, 'ZZ svc low', 1000, 30),
    (svc_high, biz, 'ZZ svc high', 500, 30);
  insert into public.service_canonical_map (business_id, service_id, node_key, version_no, method) values
    (biz, svc_low, 'zz_v717_cat_low', 1, 'owner_chosen'),
    (biz, svc_high, 'zz_v717_cat_high', 1, 'owner_chosen');

  -- zz_v717_cat_low: 3 distinct customers, $10/$20/$30 -- below the floor of 5.
  for i in 1..3 loop
    cl := gen_random_uuid();
    insert into public.clients (id, business_id, full_name) values (cl, biz, format('ZZ low %s', i));
    s := gen_random_uuid();
    insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                               occurred_at, created_at, counts_as_revenue, counts_as_visit)
    values (s, biz, br, cl, 'service', 1000 * i, now() - interval '2 days', now() - interval '2 days', true, true);
    insert into public.sale_items (sale_id, business_id, item_type, ref_id, qty, unit_cents, line_cents)
    values (s, biz, 'service', svc_low, 1, 1000 * i, 1000 * i);
  end loop;

  -- zz_v717_cat_high: 6 distinct customers, $5/$10/$15/$20/$25/$30 -- at/above the floor of 5.
  for i in 1..6 loop
    cl := gen_random_uuid();
    insert into public.clients (id, business_id, full_name) values (cl, biz, format('ZZ high %s', i));
    s := gen_random_uuid();
    insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                               occurred_at, created_at, counts_as_revenue, counts_as_visit)
    values (s, biz, br, cl, 'service', 500 * i, now() - interval '2 days', now() - interval '2 days', true, true);
    insert into public.sale_items (sale_id, business_id, item_type, ref_id, qty, unit_cents, line_cents)
    values (s, biz, 'service', svc_high, 1, 500 * i, 500 * i);
  end loop;

  r := public.get_ci_category_mix_v1(biz, (current_date - 10), current_date, null, clock_timestamp());
  select c into cat_low from jsonb_array_elements(r->'categories') c where c->>'node_key' = 'zz_v717_cat_low';
  select c into cat_high from jsonb_array_elements(r->'categories') c where c->>'node_key' = 'zz_v717_cat_high';

  if cat_low is null then
    insert into _fail values ('B-low-missing', 'zz_v717_cat_low absent from categories array');
  else
    -- NOTE: jsonb_build_object('distribution', null, ...) stores a JSON null, not a SQL NULL --
    -- `cat_low->'distribution' is not null` is always true against a JSON null (it is a jsonb
    -- VALUE, not the absence of one). ->> correctly folds a JSON null to SQL NULL; use that.
    if (cat_low->>'distribution') is not null then
      insert into _fail values ('B-low-distribution', format('expected null, got %s', cat_low->>'distribution'));
    end if;
    if cat_low->>'skew_note' is not null then
      insert into _fail values ('B-low-skew_note', format('expected null, got %s', cat_low->>'skew_note'));
    end if;
    if cat_low->'evidence' is distinct from '{"n":3,"floor":5,"status":"insufficient"}'::jsonb then
      insert into _fail values ('B-low-evidence', format('got %s', cat_low->'evidence'));
    end if;
    if (cat_low->>'revenue_cents')::bigint <> 6000 then
      insert into _fail values ('B-low-revenue', format('revenue_cents=%s, expected 6000', cat_low->>'revenue_cents'));
    end if;
    if (cat_low->>'line_count')::int <> 3 then
      insert into _fail values ('B-low-line_count', format('line_count=%s, expected 3', cat_low->>'line_count'));
    end if;
    if (cat_low->>'customer_count')::int <> 3 then
      insert into _fail values ('B-low-customer_count', format('customer_count=%s, expected 3', cat_low->>'customer_count'));
    end if;
  end if;

  if cat_high is null then
    insert into _fail values ('B-high-missing', 'zz_v717_cat_high absent from categories array');
  else
    if (cat_high->>'distribution') is null then
      insert into _fail values ('B-high-distribution', 'expected a distribution block, got null');
    else
      if (cat_high->'distribution'->>'n')::int <> 6 then
        insert into _fail values ('B-high-dist-n', format('n=%s, expected 6', cat_high->'distribution'->>'n'));
      end if;
      if (cat_high->'distribution'->>'mean')::numeric <> 1750.00 then
        insert into _fail values ('B-high-dist-mean', format('mean=%s, expected 1750.00', cat_high->'distribution'->>'mean'));
      end if;
      if (cat_high->'distribution'->>'median')::numeric <> 1750.00 then
        insert into _fail values ('B-high-dist-median', format('median=%s, expected 1750.00', cat_high->'distribution'->>'median'));
      end if;
      if (cat_high->'distribution'->>'top1_share_bps')::int <> 2857 then
        insert into _fail values ('B-high-dist-top1', format('top1_share_bps=%s, expected 2857', cat_high->'distribution'->>'top1_share_bps'));
      end if;
      if (cat_high->'distribution'->>'skew_material')::boolean is distinct from false then
        insert into _fail values ('B-high-dist-skew', 'skew_material expected false');
      end if;
      if (cat_high->'distribution'->>'mean_excl_top1')::numeric <> 1500.00 then
        insert into _fail values ('B-high-dist-mxt1', format('mean_excl_top1=%s, expected 1500.00', cat_high->'distribution'->>'mean_excl_top1'));
      end if;
    end if;
    if cat_high->'evidence' is distinct from '{"n":6,"floor":5,"status":"ok"}'::jsonb then
      insert into _fail values ('B-high-evidence', format('got %s', cat_high->'evidence'));
    end if;
    if (cat_high->>'revenue_cents')::bigint <> 10500 then
      insert into _fail values ('B-high-revenue', format('revenue_cents=%s, expected 10500', cat_high->>'revenue_cents'));
    end if;
    if (cat_high->>'line_count')::int <> 6 then
      insert into _fail values ('B-high-line_count', format('line_count=%s, expected 6', cat_high->>'line_count'));
    end if;
    if (cat_high->>'customer_count')::int <> 6 then
      insert into _fail values ('B-high-customer_count', format('customer_count=%s, expected 6', cat_high->>'customer_count'));
    end if;
  end if;
end
$v717b$;

-- ============================================================================================
-- PART C -- app.customer_cadence_v1 branch-clock behaviour (check 8)
-- ============================================================================================
do $v717c$
declare
  biz_kol uuid := '00000000-0000-4000-8000-000000717201';
  biz_sg  uuid := '00000000-0000-4000-8000-000000717202';
  br_kol  uuid := '00000000-0000-4000-8000-000000717211';
  br_sg   uuid := '00000000-0000-4000-8000-000000717212';
  cl_kol  uuid := '00000000-0000-4000-8000-000000717301';
  cl_sg   uuid := '00000000-0000-4000-8000-000000717302';
  v_as_of timestamptz := '2026-08-09T18:00:00+00'::timestamptz;
  r_kol   jsonb;
  r_sg    jsonb;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz_kol, 'ZZ v717 kol', 'zz-v717-kol', array['dashboard','clients','sales','reports']),
    (biz_sg, 'ZZ v717 sg', 'zz-v717-sg', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active, timezone, billing_state) values
    (br_kol, biz_kol, 'ZZ kol branch', true, true, 'Asia/Kolkata', 'active'),
    (br_sg, biz_sg, 'ZZ sg branch', true, true, 'Asia/Singapore', 'active');

  -- v106 LANDMINE (documented in v651/v709's own fixtures): a brand-new branch's reporting
  -- contract otherwise starts "now", inner-joining out every backdated sale below. Backdate an
  -- explicit version_no=2 row per branch, same as v709's fixture does.
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  values
    (biz_kol, br_kol, 2, '2000-01-01T00:00:00+05:30'::timestamptz, 'Asia/Kolkata', 'SGD', true),
    (biz_sg, br_sg, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', 'SGD', true);

  -- a v107 lifecycle policy per firm (version_no=2: version_no=1 is auto-seeded per business by
  -- trigger, so this is an override, not the first row -- same pattern as v683's own fixture).
  insert into public.customer_lifecycle_policies_v107
    (business_id, version_no, effective_from, fallback_lapse_days,
     customer_interval_min_observations, reactivation_multiplier, note, legacy_assumption)
  values
    (biz_kol, 2, '2000-01-01T00:00:00+00'::timestamptz, 60, 2, 1.5, 'zz-v717 kol', true),
    (biz_sg, 2, '2000-01-01T00:00:00+00'::timestamptz, 60, 2, 1.5, 'zz-v717 sg', true);

  insert into public.clients (id, business_id, full_name) values
    (cl_kol, biz_kol, 'ZZ v717 kol client'),
    (cl_sg, biz_sg, 'ZZ v717 sg client');

  -- identical sale shape in both firms: an early sale (unambiguous in both zones) and a late
  -- sale at the exact instant that splits Kolkata (Aug 9) from Singapore (Aug 10).
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, created_at, counts_as_revenue, counts_as_visit) values
    (gen_random_uuid(), biz_kol, br_kol, cl_kol, 'service', 1000,
     '2026-07-01T02:00:00+00', '2026-07-01T02:00:00+00', true, true),
    (gen_random_uuid(), biz_kol, br_kol, cl_kol, 'service', 1000,
     '2026-08-09T17:00:00+00', '2026-08-09T17:00:00+00', true, true),
    (gen_random_uuid(), biz_sg, br_sg, cl_sg, 'service', 1000,
     '2026-07-01T02:00:00+00', '2026-07-01T02:00:00+00', true, true),
    (gen_random_uuid(), biz_sg, br_sg, cl_sg, 'service', 1000,
     '2026-08-09T17:00:00+00', '2026-08-09T17:00:00+00', true, true);

  -- PRECONDITIONS: both firms genuinely have exactly one active branch in the timezone the
  -- truth table assumes, or the divergence below proves nothing.
  if (select br.timezone from public.branches br where br.id = br_kol) is distinct from 'Asia/Kolkata' then
    insert into _fail values ('C-pre-kol-tz', 'br_kol is not Asia/Kolkata');
  end if;
  if (select br.timezone from public.branches br where br.id = br_sg) is distinct from 'Asia/Singapore' then
    insert into _fail values ('C-pre-sg-tz', 'br_sg is not Asia/Singapore');
  end if;

  r_kol := app.customer_cadence_v1(biz_kol, cl_kol, v_as_of);
  r_sg := app.customer_cadence_v1(biz_sg, cl_sg, v_as_of);

  if r_kol->>'timezone_basis' is distinct from 'firm_agreed' then
    insert into _fail values ('C-kol-tzbasis', format('got %s', r_kol->>'timezone_basis'));
  end if;
  if r_sg->>'timezone_basis' is distinct from 'firm_agreed' then
    insert into _fail values ('C-sg-tzbasis', format('got %s', r_sg->>'timezone_basis'));
  end if;
  if r_kol->>'bucket_timezone' is distinct from 'Asia/Kolkata' then
    insert into _fail values ('C-kol-tz', format('got %s', r_kol->>'bucket_timezone'));
  end if;
  if r_sg->>'bucket_timezone' is distinct from 'Asia/Singapore' then
    insert into _fail values ('C-sg-tz', format('got %s', r_sg->>'bucket_timezone'));
  end if;

  -- the behavioural divergence itself: same customer shape, same as_of instant, different
  -- branch clock -> different last_visit_at AND different paid_visits.
  if (r_kol->>'paid_visits')::int <> 1 then
    insert into _fail values ('C-kol-paid_visits', format('got %s, expected 1 (late sale excluded: its SG-anchored visit_day, 2026-08-10, is not < the Kolkata-clock cutoff of 2026-08-10)', r_kol->>'paid_visits'));
  end if;
  -- Compared as timestamptz, not text: `->>'last_visit_at'` renders in whatever TimeZone GUC
  -- this psql session happens to have, so a text/string comparison against a hardcoded
  -- '...+00:00' literal is session-dependent and can false-positive-fail on a cluster whose
  -- default display timezone is not UTC. Casting both sides to timestamptz compares the actual
  -- instant, which is what the truth table above actually asserts.
  if (r_kol->>'last_visit_at')::timestamptz is distinct from '2026-07-01T02:00:00+00'::timestamptz then
    insert into _fail values ('C-kol-last_visit_at', format('got %s, expected the early sale (2026-07-01T02:00:00+00)', r_kol->>'last_visit_at'));
  end if;
  if (r_sg->>'paid_visits')::int <> 2 then
    insert into _fail values ('C-sg-paid_visits', format('got %s, expected 2 (late sale included: its SG-anchored visit_day, 2026-08-10, IS < the Singapore-clock cutoff of 2026-08-11)', r_sg->>'paid_visits'));
  end if;
  if (r_sg->>'last_visit_at')::timestamptz is distinct from '2026-08-09T17:00:00+00'::timestamptz then
    insert into _fail values ('C-sg-last_visit_at', format('got %s, expected the late sale (2026-08-09T17:00:00+00)', r_sg->>'last_visit_at'));
  end if;

  -- the divergence is not a fixture accident: both firms hold the identical underlying sales,
  -- so last_visit_at/paid_visits must actually differ between them.
  if r_kol->>'paid_visits' is not distinct from r_sg->>'paid_visits'
     and (r_kol->>'last_visit_at')::timestamptz is not distinct from (r_sg->>'last_visit_at')::timestamptz then
    insert into _fail values ('C-no-divergence',
      'Kolkata-branch and Singapore-branch firms produced identical cadence output -- the branch clock had no effect, which is the defect check 8 exists to catch');
  end if;
end
$v717c$;

select case when count(*) = 0
         then 'PASS -- time_basis on all seven readers, category-mix floor gate, cadence branch clock'
         else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v717: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
