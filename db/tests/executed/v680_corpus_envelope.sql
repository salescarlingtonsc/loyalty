-- v680 corpus — the shared CI envelope (generated_at/as_of/period/exclusions/trace_id), the
-- immutable-snapshot as_of gate, and get_ci_opportunities_v1's stale-evidence refusal.
--
-- Reads db/migrations/20260902_nestly_v680_ci_envelope.sql. Runs ABOVE the v422 baseline
-- watermark, so it is reported `n/a` in the pre-migration phase and gated on the migrated run.
--
-- TRUTH TABLE (numbers computed before running anything, per CI-CORPUS-FIXTURE-GUIDE):
--   E1  every re-emitted reader carries generated_at/as_of/period/exclusions/trace_id;
--       period.interval='[from,to]', period.timezone='Asia/Singapore'; category mix at an
--       untouched window still reports its OWN pre-existing 'status':'empty' key (byte-faithful).
--   E2  category mix at a pinned as_of: 1000 cents, unchanged after a second sale lands under
--       the SAME as_of, 3000 cents (1000+2000) under a fresh as_of.
--   E3  trace_id: identical under the pinned as_of + unchanged data; different once a fresh
--       as_of sees the grown population.
--   E4  one reversed pair (2 rows) + one synthetic client's sale -> exclusions.reversed_sales=2,
--       exclusions.synthetic_clients=1.
--   E5  one client, 3 same-day sales, nothing else in an isolated window -> funnel
--       stage_1_to_2 = {numerator:0, denominator:1} (population counted once, never converted).
--   E6  sale 10000 cents, external partial refund of 3000 reconciled -> known_revenue_minor=7000.
--   E7  Aug-31-23:59:59-SGT and Sep-1-00:00:00-SGT sales bucket to different ISO weekdays; a
--       sale backdated 30 days (occurred_at) but recorded now (created_at) is excluded under an
--       as_of pinned 10 days ago (0 cents) and included under as_of now (400 cents).
--   E8  get_ci_opportunities_v1 with as_of 500 days in the future refuses to rank: ranked is a
--       single do_nothing entry, refusal_reason='stale_evidence'.
--   E9  LATE refund: sale 10000 cents seeded inside the window; as_of pinned; THEN an external
--       refund of 3000 is reconciled (recorded after the pin) with business_date still inside the
--       window -> get_revenue_truth_v106 at the pinned as_of still reports 10000 (late refund
--       invisible to that snapshot); at a fresh as_of it reports 7000 (now included).

\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

do $v680$
declare
  biz uuid := '00000000-0000-4000-8000-000000680001';
  br  uuid := '00000000-0000-4000-8000-000000680002';
  u_owner uuid := '00000000-0000-4000-8000-000000680003';
  svc1 uuid := '00000000-0000-4000-8000-000000680004';
  node1 text;
  d0 date := current_date - 200;

  -- E1
  c_e1 uuid := '00000000-0000-4000-8000-000000680101';
  v_arr jsonb[];
  v_r jsonb;
  i int;
  r_empty jsonb;

  -- E2/E3
  c_e2 uuid := '00000000-0000-4000-8000-000000680201';
  s_a uuid := '00000000-0000-4000-8000-000000680202';
  s_b uuid := '00000000-0000-4000-8000-000000680203';
  w2_from date; w2_to date;
  p_as_of_1 timestamptz;
  p_as_of_2 timestamptz;
  r1 jsonb; r2 jsonb; r3 jsonb;
  trace1 text; trace2 text; trace3 text;

  -- E4
  c_e4a uuid := '00000000-0000-4000-8000-000000680401';
  c_e4b uuid := '00000000-0000-4000-8000-000000680402';
  s_r1 uuid := '00000000-0000-4000-8000-000000680403';
  s_r1_rev uuid := '00000000-0000-4000-8000-000000680404';
  s_synth uuid := '00000000-0000-4000-8000-000000680405';
  w4 date;
  r4 jsonb;

  -- E5
  c_e5 uuid := '00000000-0000-4000-8000-000000680501';
  w5 date;
  r5 jsonb;

  -- E6
  c_e6 uuid := '00000000-0000-4000-8000-000000680601';
  s_v106 uuid := '00000000-0000-4000-8000-000000680602';
  v_currency text;
  v_ingest jsonb;
  v_event_id uuid;
  v_recon jsonb;
  r6 jsonb;

  -- E7
  c_e7a uuid := '00000000-0000-4000-8000-000000680701';
  c_e7b uuid := '00000000-0000-4000-8000-000000680702';
  c_e7c uuid := '00000000-0000-4000-8000-000000680703';
  s_e7c uuid := '00000000-0000-4000-8000-000000680704';
  v_dow1 int; v_dow2 int;
  r7a jsonb;
  w7c_from date; w7c_to date;
  r7b_early jsonb; r7b_now jsonb;

  -- E8
  r8 jsonb;

  -- E9
  c_e9 uuid := '00000000-0000-4000-8000-000000680901';
  s_e9 uuid := '00000000-0000-4000-8000-000000680902';
  w9_from date; w9_to date;
  v_as_of9 timestamptz;
  v_ingest9 jsonb;
  v_event_id9 uuid;
  v_recon9 jsonb;
  v_recon9_created_at timestamptz;
  r9_pinned jsonb;
  r9_fresh jsonb;
begin
  ---------------------------------------------------------------------------
  -- business, branch, operational recipe (guide: "making a business genuinely operational")
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_owner, 'zz-v680-owner@example.test')
    on conflict (id) do nothing;

  -- 'customerintel' is required alongside 'reports': v573 gates get_revenue_truth_v106 (E6) on
  -- that module too (see db/tests/executed/v106_corpus_revenue_truth.sql's own fixture note).
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v680 envelope firm', 'zz-v680-envelope',
     array['dashboard','clients','sales','reports','packages','till','customerintel']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v680 main', true, true);

  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;

  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values (biz, u_owner, 'owner', 'ZZ v680 owner', true, 'approved');

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v680 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role','authenticated')::text, true);

  if not app.is_salon_member(biz) or not app.can_module(biz, 'reports') then
    insert into _fail values ('pre-access',
      'fixture owner lacks reports access; every assertion below would prove nothing');
    return;
  end if;

  select n.node_key into node1 from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 order by n.node_key limit 1;
  if node1 is null then
    insert into _fail values ('pre-taxonomy', 'no level-2 taxonomy node at version 1');
    return;
  end if;

  insert into public.services (id, business_id, name, price_cents, duration_min)
  values (svc1, biz, 'ZZ v680 service', 1000, 30);

  insert into public.clients (id, business_id, full_name) values
    (c_e1, biz, 'ZZ v680 e1'),
    (c_e2, biz, 'ZZ v680 e2'),
    (c_e4a, biz, 'ZZ v680 e4a'),
    (c_e5, biz, 'ZZ v680 e5'),
    (c_e6, biz, 'ZZ v680 e6'),
    (c_e7a, biz, 'ZZ v680 e7a'),
    (c_e7b, biz, 'ZZ v680 e7b'),
    (c_e7c, biz, 'ZZ v680 e7c');
  insert into public.clients (id, business_id, full_name, is_synthetic)
  values (c_e4b, biz, 'ZZ v680 synthetic', true);

  ---------------------------------------------------------------------------
  -- E1 — envelope shape, on every re-emitted reader, at an otherwise-untouched window
  ---------------------------------------------------------------------------
  v_arr := array[
    public.get_ci_funnel_conversion_v1(biz, d0 - 5, d0 - 4),
    public.get_ci_retention_windows_v1(biz, d0 - 5, d0 - 4),
    public.get_ci_demographics_v1(biz, d0 - 5, d0 - 4),
    public.get_ci_demographic_cohort_v1(biz, 'female', 0, 99, node1, d0 - 5, d0 - 4),
    public.get_ci_daypart_v1(biz, d0 - 5, d0 - 4),
    public.get_ci_service_intelligence_v1(biz, d0 - 5, d0 - 4),
    public.get_ci_package_intelligence_v1(biz, d0 - 5, d0 - 4),
    public.get_ci_category_mix_v1(biz, d0 - 5, d0 - 4),
    public.get_ci_category_customers_v1(biz, node1, d0 - 5, d0 - 4),
    public.get_ci_acquisition_v1(biz, d0 - 5, d0 - 4),
    public.get_ci_opportunities_v1(biz, d0 - 5, d0 - 4)
  ];
  for i in 1 .. array_length(v_arr, 1) loop
    v_r := v_arr[i];
    if not (v_r ? 'generated_at' and v_r ? 'as_of' and v_r ? 'period'
            and v_r ? 'exclusions' and v_r ? 'trace_id') then
      insert into _fail values ('E1-keys-' || i, 'missing envelope key(s) in: ' || v_r::text);
    end if;
    if v_r->'period'->>'interval' is distinct from '[from,to]' then
      insert into _fail values ('E1-interval-' || i, coalesce(v_r->'period'->>'interval', 'null'));
    end if;
    if v_r->'period'->>'timezone' is distinct from 'Asia/Singapore' then
      insert into _fail values ('E1-timezone-' || i, coalesce(v_r->'period'->>'timezone', 'null'));
    end if;
    if not (v_r->'exclusions' ? 'reversed_sales' and v_r->'exclusions' ? 'synthetic_clients'
            and v_r->'exclusions' ? 'anonymous_sales') then
      insert into _fail values ('E1-exclusions-' || i, coalesce((v_r->'exclusions')::text, 'null'));
    end if;
    if jsonb_typeof(v_r->'exclusions'->'reversed_sales') <> 'number'
       or jsonb_typeof(v_r->'exclusions'->'synthetic_clients') <> 'number'
       or jsonb_typeof(v_r->'exclusions'->'anonymous_sales') <> 'number' then
      insert into _fail values ('E1-exclusion-numbers-' || i,
        'an exclusion count is not a JSON number: ' || (v_r->'exclusions')::text);
    end if;
  end loop;

  -- byte-faithful check: category mix's OWN pre-existing key, unchanged, at an empty window.
  r_empty := v_arr[8];
  if r_empty->>'status' is distinct from 'empty' then
    insert into _fail values ('E1-byte-faithful', 'category mix status: ' || coalesce(r_empty->>'status','null'));
  end if;

  ---------------------------------------------------------------------------
  -- E2 / E3 — immutable snapshot + deterministic trace_id (category mix)
  ---------------------------------------------------------------------------
  w2_from := d0 + 50; w2_to := d0 + 50;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                            occurred_at, created_at)
  values (s_a, biz, br, c_e2, 'service', 1000,
          (w2_from::timestamp + time '10:00') at time zone 'Asia/Singapore',
          (w2_from::timestamp + time '10:00') at time zone 'Asia/Singapore');
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (biz, s_a, 'service', svc1, 1, 1000, 1000);

  p_as_of_1 := clock_timestamp();
  r1 := public.get_ci_category_mix_v1(biz, w2_from, w2_to, null, p_as_of_1);
  if (r1->'coverage'->>'stampable_revenue_cents')::bigint is distinct from 1000 then
    insert into _fail values ('E2-pre',
      'expected 1000 before the second sale, got ' || coalesce(r1->'coverage'->>'stampable_revenue_cents','null'));
  end if;
  trace1 := r1->>'trace_id';

  -- a second sale, recorded strictly AFTER p_as_of_1
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                            occurred_at, created_at)
  values (s_b, biz, br, c_e2, 'service', 2000,
          (w2_from::timestamp + time '11:00') at time zone 'Asia/Singapore',
          clock_timestamp());
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (biz, s_b, 'service', svc1, 1, 2000, 2000);

  -- same pinned as_of -> totals AND trace_id unchanged (check 9, check 20)
  r2 := public.get_ci_category_mix_v1(biz, w2_from, w2_to, null, p_as_of_1);
  if (r2->'coverage'->>'stampable_revenue_cents')::bigint is distinct from 1000 then
    insert into _fail values ('E2-pinned',
      'totals moved under a pinned as_of: ' || coalesce(r2->'coverage'->>'stampable_revenue_cents','null'));
  end if;
  trace2 := r2->>'trace_id';
  if trace2 is distinct from trace1 then
    insert into _fail values ('E3-same', 'trace_id changed for identical inputs over unobserved data');
  end if;

  -- fresh as_of -> totals grow by exactly the new sale, trace_id changes (check 20)
  p_as_of_2 := clock_timestamp();
  r3 := public.get_ci_category_mix_v1(biz, w2_from, w2_to, null, p_as_of_2);
  if (r3->'coverage'->>'stampable_revenue_cents')::bigint is distinct from 3000 then
    insert into _fail values ('E2-fresh',
      'expected 3000 (1000+2000) under a fresh as_of, got ' || coalesce(r3->'coverage'->>'stampable_revenue_cents','null'));
  end if;
  trace3 := r3->>'trace_id';
  if trace3 = trace1 then
    insert into _fail values ('E3-diff', 'trace_id unchanged after a fresh as_of over grown data');
  end if;

  ---------------------------------------------------------------------------
  -- E4 — exclusion counts: one reversed pair (2 rows) + one synthetic client's sale
  ---------------------------------------------------------------------------
  w4 := d0 + 60;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                            occurred_at, created_at)
  values (s_r1, biz, br, c_e4a, 'service', 500,
          (w4::timestamp + time '09:00') at time zone 'Asia/Singapore',
          (w4::timestamp + time '09:00') at time zone 'Asia/Singapore');

  perform set_config('app.sale_reversal_insert_id', s_r1_rev::text, true);
  perform set_config('app.sale_reversal_original_id', s_r1::text, true);
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at,
                            created_at, reversal_of, reversal_reason, reversal_actor,
                            reversal_idempotency_key)
  values (s_r1_rev, biz, br, c_e4a, 'service', -500,
          (w4::timestamp + time '09:30') at time zone 'Asia/Singapore',
          (w4::timestamp + time '09:30') at time zone 'Asia/Singapore',
          s_r1, 'ZZ v680 fixture reversal', u_owner, 'zz-v680-rev-idem-001');
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                            occurred_at, created_at)
  values (s_synth, biz, br, c_e4b, 'service', 700,
          (w4::timestamp + time '10:00') at time zone 'Asia/Singapore',
          (w4::timestamp + time '10:00') at time zone 'Asia/Singapore');

  r4 := public.get_ci_category_mix_v1(biz, w4, w4);
  if (r4->'exclusions'->>'reversed_sales')::int is distinct from 2 then
    insert into _fail values ('E4-reversed',
      'expected 2, got ' || coalesce(r4->'exclusions'->>'reversed_sales','null'));
  end if;
  if (r4->'exclusions'->>'synthetic_clients')::int is distinct from 1 then
    insert into _fail values ('E4-synthetic',
      'expected 1, got ' || coalesce(r4->'exclusions'->>'synthetic_clients','null'));
  end if;

  ---------------------------------------------------------------------------
  -- E5 — same-day multi-txn: one client, 3 same-day sales, isolated window
  ---------------------------------------------------------------------------
  w5 := d0 + 80;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                            occurred_at, created_at)
  select gen_random_uuid(), biz, br, c_e5, 'service', 300,
         (w5::timestamp + (t || ':00')::time) at time zone 'Asia/Singapore',
         (w5::timestamp + (t || ':00')::time) at time zone 'Asia/Singapore'
    from unnest(array['09','13','18']) as t;

  r5 := public.get_ci_funnel_conversion_v1(biz, w5, w5);
  if (r5->'stage_1_to_2'->>'denominator')::int is distinct from 1 then
    insert into _fail values ('E5-denominator',
      'expected the client counted once as a mature first visit, got ' ||
      coalesce(r5->'stage_1_to_2'->>'denominator','null'));
  end if;
  if (r5->'stage_1_to_2'->>'numerator')::int is distinct from 0 then
    insert into _fail values ('E5-numerator',
      'a same-day transaction was wrongly counted as a second visit: numerator=' ||
      coalesce(r5->'stage_1_to_2'->>'numerator','null'));
  end if;

  ---------------------------------------------------------------------------
  -- E6 — partial external refund via the real v106 RPC
  ---------------------------------------------------------------------------
  if not app.has_perm(biz, 'view_finance') then
    insert into _fail values ('E6-pre', 'fixture owner lacks view_finance; E6 is vacuous');
  else
    select currency into v_currency from public.businesses where id = biz;

    insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                              occurred_at, created_at)
    values (s_v106, biz, br, c_e6, 'retail', 10000,
            (d0 + 90)::timestamp + time '12:00', (d0 + 90)::timestamp + time '12:00');

    v_ingest := public.ingest_external_commerce_event_v106(
      biz, br, 'refund_completed', 'zz_v680_pos', 'zz-v680-evt-1', 'zz-v680-idem-1',
      ((d0 + 90)::timestamp + time '12:05') at time zone 'Asia/Singapore',
      v_currency, -3000, '{}'::jsonb);
    v_event_id := (v_ingest->>'event_id')::uuid;

    v_recon := public.reconcile_external_commerce_event_v106(
      v_event_id, s_v106, 'zz-v680-recon-1',
      jsonb_build_array(jsonb_build_object('amount_minor', 3000)));
    if v_recon->>'status' <> 'reconciled' then
      insert into _fail values ('E6-recon', 'reconcile status: ' || coalesce(v_recon->>'status','null'));
    end if;

    r6 := public.get_revenue_truth_v106(biz, d0 + 90, d0 + 91, br, clock_timestamp());
    if (r6->'totals'->>'known_revenue_minor')::bigint is distinct from 7000 then
      insert into _fail values ('E6-known-revenue',
        'expected 7000 (10000-3000), got ' || coalesce(r6->'totals'->>'known_revenue_minor','null'));
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- E7 — midnight edge (different ISO weekdays) + backdate under a pinned as_of
  ---------------------------------------------------------------------------
  v_dow1 := extract(isodow from timestamp '2026-08-31 23:59:59')::int;
  v_dow2 := extract(isodow from timestamp '2026-09-01 00:00:00')::int;
  if v_dow1 = v_dow2 then
    insert into _fail values ('E7-pre', 'the two midnight-edge timestamps landed on the same weekday');
  end if;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                            occurred_at, created_at)
  values
    (gen_random_uuid(), biz, br, c_e7a, 'service', 100,
     '2026-08-31 23:59:59+08'::timestamptz, '2026-08-31 23:59:59+08'::timestamptz),
    (gen_random_uuid(), biz, br, c_e7b, 'service', 100,
     '2026-09-01 00:00:00+08'::timestamptz, '2026-09-01 00:00:00+08'::timestamptz);

  r7a := public.get_ci_daypart_v1(biz, '2026-08-31'::date, '2026-09-01'::date, br);
  if not exists (
    select 1 from jsonb_array_elements(r7a->'weekdays') w
     where (w->>'dow')::int = v_dow1 and (w->>'visits')::int >= 1
  ) then
    insert into _fail values ('E7-dow1', format('no visit recorded for dow %s (2026-08-31 23:59:59 SGT)', v_dow1));
  end if;
  if not exists (
    select 1 from jsonb_array_elements(r7a->'weekdays') w
     where (w->>'dow')::int = v_dow2 and (w->>'visits')::int >= 1
  ) then
    insert into _fail values ('E7-dow2', format('no visit recorded for dow %s (2026-09-01 00:00:00 SGT)', v_dow2));
  end if;

  -- backdated occurred_at, recorded now, gated by a pinned-in-the-past as_of
  w7c_from := current_date - 31; w7c_to := current_date - 29;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                            occurred_at, created_at)
  values (s_e7c, biz, br, c_e7c, 'service', 400,
          (current_date - 30)::timestamp + time '12:00', clock_timestamp());
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (biz, s_e7c, 'service', svc1, 1, 400, 400);

  r7b_early := public.get_ci_category_mix_v1(biz, w7c_from, w7c_to, null,
                 clock_timestamp() - interval '10 days');
  if (r7b_early->'coverage'->>'stampable_revenue_cents')::bigint is distinct from 0 then
    insert into _fail values ('E7-backdate-early',
      'a sale recorded after the pinned as_of leaked into the snapshot: ' ||
      coalesce(r7b_early->'coverage'->>'stampable_revenue_cents','null'));
  end if;

  r7b_now := public.get_ci_category_mix_v1(biz, w7c_from, w7c_to, null, clock_timestamp());
  if (r7b_now->'coverage'->>'stampable_revenue_cents')::bigint is distinct from 400 then
    insert into _fail values ('E7-backdate-now',
      'expected 400 under as_of now, got ' || coalesce(r7b_now->'coverage'->>'stampable_revenue_cents','null'));
  end if;

  ---------------------------------------------------------------------------
  -- E8 — freshness refusal: as_of far enough in the future to be stale regardless of data
  ---------------------------------------------------------------------------
  r8 := public.get_ci_opportunities_v1(biz, d0, d0 + 1, null, clock_timestamp() + interval '500 days');
  if (r8->'freshness'->>'stale') is distinct from 'true' then
    insert into _fail values ('E8-stale-flag', 'freshness.stale: ' || coalesce(r8->'freshness'->>'stale','null'));
  end if;
  if r8->>'refusal_reason' is distinct from 'stale_evidence' then
    insert into _fail values ('E8-refusal-reason', 'refusal_reason: ' || coalesce(r8->>'refusal_reason','null'));
  end if;
  if jsonb_array_length(r8->'ranked') is distinct from 1
     or r8->'ranked'->0->>'id' is distinct from 'do_nothing'
     or r8->'ranked'->0->>'rank_class' is distinct from 'do_nothing' then
    insert into _fail values ('E8-ranked', 'ranked: ' || (r8->'ranked')::text);
  end if;

  ---------------------------------------------------------------------------
  -- E9 — LATE refund: reconciled after a pinned as_of, dated inside the window
  ---------------------------------------------------------------------------
  if not app.has_perm(biz, 'view_finance') then
    insert into _fail values ('E9-pre', 'fixture owner lacks view_finance; E9 is vacuous');
  else
    select upper(b.currency) into v_currency from public.businesses b where b.id = biz;

    w9_from := d0 + 110; w9_to := d0 + 111;

    insert into public.clients (id, business_id, full_name) values
      (c_e9, biz, 'ZZ v680 e9');

    insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                              occurred_at, created_at)
    values (s_e9, biz, br, c_e9, 'retail', 10000,
            (w9_from::timestamp + time '12:00') at time zone 'Asia/Singapore',
            (w9_from::timestamp + time '12:00') at time zone 'Asia/Singapore');

    -- pin BEFORE the refund is even ingested/reconciled
    v_as_of9 := clock_timestamp();

    -- ingested + reconciled AFTER the pin, but business_date (from occurred_at) is inside the window
    v_ingest9 := public.ingest_external_commerce_event_v106(
      biz, br, 'refund_completed', 'zz_v680_pos', 'zz-v680-evt-9', 'zz-v680-idem-9',
      ((w9_from::timestamp + time '12:05') at time zone 'Asia/Singapore'),
      v_currency, -3000, '{}'::jsonb);
    v_event_id9 := (v_ingest9->>'event_id')::uuid;

    v_recon9 := public.reconcile_external_commerce_event_v106(
      v_event_id9, s_e9, 'zz-v680-recon-9',
      jsonb_build_array(jsonb_build_object('amount_minor', 3000)));
    if v_recon9->>'status' <> 'reconciled' then
      insert into _fail values ('E9-recon', 'reconcile status: ' || coalesce(v_recon9->>'status','null'));
    end if;

    -- precondition: the refund's reconciliation row really was recorded AFTER the pinned as_of
    select r.created_at into v_recon9_created_at
      from public.commerce_event_reconciliations_v106 r
     where r.id = (v_recon9->>'reconciliation_id')::uuid;
    if v_recon9_created_at is null or v_recon9_created_at <= v_as_of9 then
      insert into _fail values ('E9-pre-timing',
        'expected the reconciliation created_at to be after the pinned as_of; created_at=' ||
        coalesce(v_recon9_created_at::text, 'null') || ' as_of=' || v_as_of9::text);
    end if;

    -- pinned as_of: the LATE refund is invisible to that immutable snapshot -> still 10000
    r9_pinned := public.get_revenue_truth_v106(biz, w9_from, w9_to, br, v_as_of9);
    if (r9_pinned->'totals'->>'known_revenue_minor')::bigint is distinct from 10000 then
      insert into _fail values ('E9-pinned',
        'expected 10000 (late refund invisible under the pinned as_of), got ' ||
        coalesce(r9_pinned->'totals'->>'known_revenue_minor','null'));
    end if;

    -- fresh as_of: the snapshot has moved past the reconciliation -> now 7000
    r9_fresh := public.get_revenue_truth_v106(biz, w9_from, w9_to, br, clock_timestamp());
    if (r9_fresh->'totals'->>'known_revenue_minor')::bigint is distinct from 7000 then
      insert into _fail values ('E9-fresh',
        'expected 7000 (10000-3000) once the snapshot includes the late refund, got ' ||
        coalesce(r9_fresh->'totals'->>'known_revenue_minor','null'));
    end if;
  end if;

end
$v680$;

select case when count(*) = 0 then 'PASS — v680 envelope: shape, immutability, exclusions, trace, freshness'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v680: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
