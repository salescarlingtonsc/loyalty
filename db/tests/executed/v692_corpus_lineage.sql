-- EXECUTED acceptance fixture for nestly_v692 — record-level lineage (check 19) and the v107
-- visit-day dedupe (check 4).
--
-- Named for v692 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- Reads db/migrations/20260902_nestly_v692_lineage_and_visit_dedupe.sql.
--
-- TRUTH TABLE (numbers computed before running anything):
--   customer X — service sales in taxonomy node A: 3 on day1 (1000 + 1500 + 500 cents) and
--     1 on day2 (2000 cents). At the pinned as_of (before a 5th sale is even recorded):
--       visits (V) = 4 distinct sales, revenue (R) = 1000+1500+500+2000 = 5000 cents,
--       visit_days = 2 (day1, day2) — a REPEAT purchaser under the new dedupe rule.
--     A 5th sale (day2, 3000 cents) is recorded (created_at) AFTER the pinned as_of. Under that
--     same pinned as_of it must not appear anywhere (V/R/visit_days unchanged: 4/5000/2). Under
--     a LATER as_of it must appear: V=5, R=8000, visit_days still 2 (same two calendar days).
--   customer Y — 3 service sales, all on day1, no taxonomy node set (irrelevant to the lineage
--     assertion, only exercises v107): raw sale count in period = 3 (>=2, so Y WOULD have been
--     a "repeat purchaser" under the pre-v692 raw-count rule) but visit_days = 1, so Y must NOT
--     be a repeat purchaser under the new rule.
--   Four filler customers (1 node-A sale each, day1) are also seeded so node A's cohort size is
--   5, at or above nestly_v667's k=5 small-cell floor on get_ci_category_customers_v1 — without
--   them that reader suppresses 'customers' to '[]' entirely and the lineage assertion would
--   prove nothing (CI-CORPUS-FIXTURE-GUIDE's "assert your preconditions"). They also transact
--   within the v107 window, so:
--   get_customer_lifecycle_v107 over the period containing day1/day2: transacting_identified_
--     customers = 6 (X, Y, and the 4 fillers), repeat_purchasers_in_period = 1 (X only — the
--     fillers have a single sale each, so they are neither raw-count nor visit-day repeats).
--   LINEAGE: get_ci_category_customers_v1's row for X in node A (visits, revenue_cents) must
--     equal get_ci_customer_records_v1's own totals for X, filtered to node A's sale_items, at
--     the SAME as_of — exactly, both at the pinned as_of (4/5000) and at the later as_of (5/8000).

\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

do $v692$
declare
  biz        uuid := '00000000-0000-4000-8000-000000692001';
  br         uuid := '00000000-0000-4000-8000-000000692002';
  u_owner    uuid := '00000000-0000-4000-8000-000000692003';
  staff_id   uuid := '00000000-0000-4000-8000-000000692004';
  cX         uuid := '00000000-0000-4000-8000-000000692101';
  cY         uuid := '00000000-0000-4000-8000-000000692102';
  cF1        uuid := '00000000-0000-4000-8000-000000692111';
  cF2        uuid := '00000000-0000-4000-8000-000000692112';
  cF3        uuid := '00000000-0000-4000-8000-000000692113';
  cF4        uuid := '00000000-0000-4000-8000-000000692114';
  s_f1 uuid := '00000000-0000-4000-8000-000000692211';
  s_f2 uuid := '00000000-0000-4000-8000-000000692212';
  s_f3 uuid := '00000000-0000-4000-8000-000000692213';
  s_f4 uuid := '00000000-0000-4000-8000-000000692214';

  s_x1 uuid := '00000000-0000-4000-8000-000000692201';
  s_x2 uuid := '00000000-0000-4000-8000-000000692202';
  s_x3 uuid := '00000000-0000-4000-8000-000000692203';
  s_x4 uuid := '00000000-0000-4000-8000-000000692204';
  s_x5 uuid := '00000000-0000-4000-8000-000000692205';
  s_y1 uuid := '00000000-0000-4000-8000-000000692301';
  s_y2 uuid := '00000000-0000-4000-8000-000000692302';
  s_y3 uuid := '00000000-0000-4000-8000-000000692303';
  appt1 uuid := '00000000-0000-4000-8000-000000692401';

  nodeA text;
  d0    date := current_date - 300;
  day1  date;
  day2  date;

  -- CI reader window (inclusive [from,to])
  p_from_ci date;
  p_to_ci   date;
  -- v107 window (half-open [from,to))
  p_from_107 date;
  p_to_107   date;

  v_t0        timestamptz := clock_timestamp();
  v_as_of     timestamptz;
  v_as_of_later timestamptz;

  cc1 jsonb; cc2 jsonb; rec1 jsonb; rec2 jsonb; life jsonb;
  x_row jsonb;
  x_visits_agg bigint; x_revenue_agg bigint;
  rec_v bigint; rec_r bigint;
  v_raw_y int; v_raw_x int;
  v_days_x int; v_days_y int;
  v_err text;
begin
  ---------------------------------------------------------------------------
  -- business, branch, operational recipe (guide: "making a business genuinely operational")
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_owner, 'zz-v692-owner@example.test')
    on conflict (id) do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v692 lineage firm', 'zz-v692-lineage',
     array['dashboard','clients','sales','reports','customerintel']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v692 main', true, true);

  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  values (biz, null, 2, '-infinity', 'Asia/Singapore', 'SGD', true),
         (biz, br,   2, '-infinity', 'Asia/Singapore', 'SGD', true)
  on conflict do nothing;

  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values (biz, u_owner, 'owner', 'ZZ v692 owner', true, 'approved');
  insert into public.staff (id, business_id, user_id, role, full_name, active, access_state)
  values (staff_id, biz, null, 'staff', 'ZZ v692 therapist', true, 'approved');

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v692 fixture')
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

  -- PRECONDITION (CI-CORPUS-FIXTURE-GUIDE "the rule that matters most").
  if not app.is_salon_member(biz) or not app.can_module(biz, 'reports') then
    insert into _fail values ('pre-access', 'fixture owner lacks reports access; every assertion below would prove nothing');
    return;
  end if;
  if not app.has_perm(biz, 'view_finance') then
    insert into _fail values ('pre-finance', 'fixture owner lacks view_finance; every v107 assertion below would prove nothing');
    return;
  end if;

  select n.node_key into nodeA from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 order by n.node_key limit 1;
  if nodeA is null then
    insert into _fail values ('pre-taxonomy', 'no level-2 taxonomy node at version 1');
    return;
  end if;

  day1 := d0;
  day2 := d0 + 1;
  p_from_ci := day1;      p_to_ci := day2;         -- inclusive [from,to]
  p_from_107 := day1;     p_to_107 := day2 + 1;     -- half-open [from,to)

  insert into public.clients (id, business_id, full_name) values
    (cX, biz, 'ZZ v692 customer X'),
    (cY, biz, 'ZZ v692 customer Y'),
    (cF1, biz, 'ZZ v692 filler 1'),
    (cF2, biz, 'ZZ v692 filler 2'),
    (cF3, biz, 'ZZ v692 filler 3'),
    (cF4, biz, 'ZZ v692 filler 4');

  ---------------------------------------------------------------------------
  -- X: 3 sales on day1, 1 sale on day2, all node A. created_at = v_t0 (well before as_of).
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  values
    (s_x1, biz, br, cX, 'service', 1000,
     (day1::timestamp + time '09:00') at time zone 'Asia/Singapore', v_t0, true, true, true, v_t0, 0, v_t0),
    (s_x2, biz, br, cX, 'service', 1500,
     (day1::timestamp + time '11:00') at time zone 'Asia/Singapore', v_t0, true, true, true, v_t0, 0, v_t0),
    (s_x3, biz, br, cX, 'service', 500,
     (day1::timestamp + time '15:00') at time zone 'Asia/Singapore', v_t0, true, true, true, v_t0, 0, v_t0),
    (s_x4, biz, br, cX, 'service', 2000,
     (day2::timestamp + time '10:00') at time zone 'Asia/Singapore', v_t0, true, true, true, v_t0, 0, v_t0);

  insert into public.sale_items (business_id, sale_id, item_type, canonical_node_key, qty, unit_cents, line_cents)
  values
    (biz, s_x1, 'service', nodeA, 1, 1000, 1000),
    (biz, s_x2, 'service', nodeA, 1, 1500, 1500),
    (biz, s_x3, 'service', nodeA, 1, 500, 500),
    (biz, s_x4, 'service', nodeA, 1, 2000, 2000);

  insert into public.appointments (id, business_id, client_id, staff_id, starts_at, ends_at,
    status, branch_id, created_at)
  values (appt1, biz, cX, staff_id,
          (day1::timestamp + time '09:00') at time zone 'Asia/Singapore',
          (day1::timestamp + time '09:30') at time zone 'Asia/Singapore',
          'completed', br, v_t0);

  ---------------------------------------------------------------------------
  -- Fillers: 1 node-A sale each, so the node-A cohort size clears the k=5 small-cell floor
  -- (nestly_v667) on get_ci_category_customers_v1. Irrelevant to every value asserted for X.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  values
    (s_f1, biz, br, cF1, 'service', 100,
     (day1::timestamp + time '09:00') at time zone 'Asia/Singapore', v_t0, true, true, true, v_t0, 0, v_t0),
    (s_f2, biz, br, cF2, 'service', 100,
     (day1::timestamp + time '09:00') at time zone 'Asia/Singapore', v_t0, true, true, true, v_t0, 0, v_t0),
    (s_f3, biz, br, cF3, 'service', 100,
     (day1::timestamp + time '09:00') at time zone 'Asia/Singapore', v_t0, true, true, true, v_t0, 0, v_t0),
    (s_f4, biz, br, cF4, 'service', 100,
     (day1::timestamp + time '09:00') at time zone 'Asia/Singapore', v_t0, true, true, true, v_t0, 0, v_t0);
  insert into public.sale_items (business_id, sale_id, item_type, canonical_node_key, qty, unit_cents, line_cents)
  values
    (biz, s_f1, 'service', nodeA, 1, 100, 100),
    (biz, s_f2, 'service', nodeA, 1, 100, 100),
    (biz, s_f3, 'service', nodeA, 1, 100, 100),
    (biz, s_f4, 'service', nodeA, 1, 100, 100);

  ---------------------------------------------------------------------------
  -- Y: 3 sales, all on day1, no category. created_at = v_t0.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  values
    (s_y1, biz, br, cY, 'service', 800,
     (day1::timestamp + time '09:15') at time zone 'Asia/Singapore', v_t0, true, true, true, v_t0, 0, v_t0),
    (s_y2, biz, br, cY, 'service', 900,
     (day1::timestamp + time '12:15') at time zone 'Asia/Singapore', v_t0, true, true, true, v_t0, 0, v_t0),
    (s_y3, biz, br, cY, 'service', 700,
     (day1::timestamp + time '16:15') at time zone 'Asia/Singapore', v_t0, true, true, true, v_t0, 0, v_t0);

  ---------------------------------------------------------------------------
  -- Pin the snapshot, then record a 5th X sale AFTER it.
  ---------------------------------------------------------------------------
  v_as_of := v_t0 + interval '1 minute';
  v_as_of_later := v_as_of + interval '2 minutes';

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  values
    (s_x5, biz, br, cX, 'service', 3000,
     (day2::timestamp + time '18:00') at time zone 'Asia/Singapore',
     v_as_of + interval '1 minute', true, true, true, v_as_of + interval '1 minute', 0,
     v_as_of + interval '1 minute');
  insert into public.sale_items (business_id, sale_id, item_type, canonical_node_key, qty, unit_cents, line_cents)
  values (biz, s_x5, 'service', nodeA, 1, 3000, 3000);

  ---------------------------------------------------------------------------
  -- PRE-CHECKS — the fixture's own arithmetic, independent of every reader under test.
  ---------------------------------------------------------------------------
  select count(*),
         count(distinct (s.occurred_at at time zone 'Asia/Singapore')::date)
    into v_raw_x, v_days_x
    from public.sales s
   where s.business_id = biz and s.client_id = cX and s.reversal_of is null
     and s.counts_as_visit and s.created_at <= v_as_of
     and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from_ci and p_to_ci;
  if v_raw_x <> 4 or v_days_x <> 2 then
    insert into _fail values ('pre-arith-x',
      format('expected X to have 4 raw sales / 2 visit-days at the pinned as_of, got %s/%s', v_raw_x, v_days_x));
  end if;

  select count(*),
         count(distinct (s.occurred_at at time zone 'Asia/Singapore')::date)
    into v_raw_y, v_days_y
    from public.sales s
   where s.business_id = biz and s.client_id = cY and s.reversal_of is null
     and s.counts_as_visit and s.created_at <= v_as_of
     and (s.occurred_at at time zone 'Asia/Singapore')::date >= p_from_107
     and (s.occurred_at at time zone 'Asia/Singapore')::date < p_to_107;
  if v_raw_y <> 3 or v_days_y <> 1 then
    insert into _fail values ('pre-arith-y',
      format('expected Y to have 3 raw sales / 1 visit-day, got %s/%s', v_raw_y, v_days_y));
  end if;

  ---------------------------------------------------------------------------
  -- LINEAGE — pinned as_of: category_customers vs. customer_records, exact.
  ---------------------------------------------------------------------------
  begin
    cc1 := public.get_ci_category_customers_v1(biz, nodeA, p_from_ci, p_to_ci, 100, null, v_as_of);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('L1', format('get_ci_category_customers_v1 raised %s', v_err));
    return;
  end;
  select c into x_row from jsonb_array_elements(cc1->'customers') c
   where (c->>'client_id')::uuid = cX;
  if x_row is null then
    insert into _fail values ('L1', 'X is absent from get_ci_category_customers_v1 at the pinned as_of');
    return;
  end if;
  x_visits_agg := (x_row->>'visits')::bigint;
  x_revenue_agg := (x_row->>'revenue_cents')::bigint;
  if x_visits_agg <> 4 or x_revenue_agg <> 5000 then
    insert into _fail values ('L1', format('category_customers X: expected visits=4 revenue_cents=5000, got visits=%s revenue_cents=%s',
      x_visits_agg, x_revenue_agg));
  end if;

  begin
    rec1 := public.get_ci_customer_records_v1(biz, cX, p_from_ci, p_to_ci, null, v_as_of);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('L2', format('get_ci_customer_records_v1 raised %s', v_err));
    return;
  end;
  if jsonb_array_length(rec1->'sales') <> 4 then
    insert into _fail values ('L2-asof', format('records at pinned as_of: expected 4 sales, got %s (the 5th sale must be invisible)',
      jsonb_array_length(rec1->'sales')));
  end if;
  if (rec1#>>'{totals,sales}')::bigint <> 4
     or (rec1#>>'{totals,revenue_cents}')::bigint <> 5000
     or (rec1#>>'{totals,visit_days}')::bigint <> 2 then
    insert into _fail values ('L2-totals', format('records totals at pinned as_of: expected sales=4 revenue_cents=5000 visit_days=2, got %s',
      rec1->'totals'));
  end if;

  -- Filter the records reader's own sale_items by node A and reconcile EXACTLY against the
  -- aggregate's V/R for X — the check 19 lineage assertion, insight -> cohort -> transactions.
  select count(*) filter (where matched), coalesce(sum(matched_cents) filter (where matched), 0)
    into rec_v, rec_r
    from (
      select exists (
               select 1 from jsonb_array_elements(se->'sale_items') it
                where (it->>'effective_node_key') = nodeA
                   or (it->>'effective_node_key') like nodeA || '.%'
             ) as matched,
             (select coalesce(sum((it->>'line_cents')::bigint), 0)
                from jsonb_array_elements(se->'sale_items') it
               where (it->>'effective_node_key') = nodeA
                  or (it->>'effective_node_key') like nodeA || '.%') as matched_cents
        from jsonb_array_elements(rec1->'sales') se
    ) t;

  if rec_v <> x_visits_agg or rec_r <> x_revenue_agg then
    insert into _fail values ('L3-lineage', format(
      'lineage mismatch at pinned as_of: category_customers gave visits=%s revenue_cents=%s, '
      'customer_records (filtered to node %s) gave visits=%s revenue_cents=%s',
      x_visits_agg, x_revenue_agg, nodeA, rec_v, rec_r));
  end if;
  if rec_v <> 4 or rec_r <> 5000 then
    insert into _fail values ('L3-exact', format('expected the lineage totals to be exactly 4/5000, got %s/%s', rec_v, rec_r));
  end if;

  -- MUTATION-CHECK (alter the expected R): a deliberately wrong expectation must NOT match —
  -- proves the assertion above is exact-value, not a loose or vacuous comparison.
  if rec_r = x_revenue_agg + 1 or rec_v = x_visits_agg + 1 then
    insert into _fail values ('L3-mutation', 'the lineage check would have passed against a wrong-by-one expectation — it is not exact');
  end if;

  ---------------------------------------------------------------------------
  -- LINEAGE — later as_of: the 5th sale is now visible on BOTH readers, still exactly equal.
  ---------------------------------------------------------------------------
  cc2 := public.get_ci_category_customers_v1(biz, nodeA, p_from_ci, p_to_ci, 100, null, v_as_of_later);
  select c into x_row from jsonb_array_elements(cc2->'customers') c
   where (c->>'client_id')::uuid = cX;
  x_visits_agg := (x_row->>'visits')::bigint;
  x_revenue_agg := (x_row->>'revenue_cents')::bigint;
  if x_visits_agg <> 5 or x_revenue_agg <> 8000 then
    insert into _fail values ('L4', format('category_customers X at later as_of: expected visits=5 revenue_cents=8000, got visits=%s revenue_cents=%s',
      x_visits_agg, x_revenue_agg));
  end if;

  rec2 := public.get_ci_customer_records_v1(biz, cX, p_from_ci, p_to_ci, null, v_as_of_later);
  if jsonb_array_length(rec2->'sales') <> 5
     or (rec2#>>'{totals,sales}')::bigint <> 5
     or (rec2#>>'{totals,revenue_cents}')::bigint <> 8000
     or (rec2#>>'{totals,visit_days}')::bigint <> 2 then
    insert into _fail values ('L5', format('records at later as_of: expected 5 sales / revenue_cents=8000 / visit_days=2, got sales=%s totals=%s',
      jsonb_array_length(rec2->'sales'), rec2->'totals'));
  end if;

  select count(*) filter (where matched), coalesce(sum(matched_cents) filter (where matched), 0)
    into rec_v, rec_r
    from (
      select exists (
               select 1 from jsonb_array_elements(se->'sale_items') it
                where (it->>'effective_node_key') = nodeA
                   or (it->>'effective_node_key') like nodeA || '.%'
             ) as matched,
             (select coalesce(sum((it->>'line_cents')::bigint), 0)
                from jsonb_array_elements(se->'sale_items') it
               where (it->>'effective_node_key') = nodeA
                  or (it->>'effective_node_key') like nodeA || '.%') as matched_cents
        from jsonb_array_elements(rec2->'sales') se
    ) t;
  if rec_v <> x_visits_agg or rec_r <> x_revenue_agg or rec_v <> 5 or rec_r <> 8000 then
    insert into _fail values ('L6-lineage-later', format(
      'lineage mismatch at later as_of: category_customers visits=%s revenue_cents=%s vs records visits=%s revenue_cents=%s',
      x_visits_agg, x_revenue_agg, rec_v, rec_r));
  end if;

  -- appointment surfaced, with the fields the reader promises.
  if jsonb_array_length(rec1->'appointments') <> 1
     or (rec1#>>'{appointments,0,status}') <> 'completed'
     or (rec1#>>'{appointments,0,staff}') <> 'ZZ v692 therapist' then
    insert into _fail values ('L7-appointments', format('appointments block wrong: %s', rec1->'appointments'));
  end if;

  ---------------------------------------------------------------------------
  -- DEDUPE (v107) — X is a repeat (2 visit-days), Y is not (1 visit-day, 3 raw sales).
  ---------------------------------------------------------------------------
  begin
    life := public.get_customer_lifecycle_v107(biz, p_from_107, p_to_107, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('D1', format('get_customer_lifecycle_v107 raised %s', v_err));
    return;
  end;
  if (life#>>'{metrics,transacting_identified_customers}')::bigint <> 6 then
    insert into _fail values ('D1', format('expected transacting_identified_customers=6 (X, Y, 4 fillers), got %s',
      life#>>'{metrics,transacting_identified_customers}'));
  end if;
  if (life#>>'{metrics,repeat_purchasers_in_period}')::bigint <> 1 then
    insert into _fail values ('D2', format(
      'expected repeat_purchasers_in_period=1 (X only, 2 visit-days; Y has 1 visit-day '
      'despite %s raw sales), got %s', v_raw_y, life#>>'{metrics,repeat_purchasers_in_period}'));
  end if;

  -- RAW-COUNT MUTATION-CHECK: Y's raw qualifying-sale count (bypassing the function entirely,
  -- read directly against public.sales) is >=2 — proof that Y WOULD have been misclassified a
  -- repeat purchaser under the pre-v692 raw-count rule, and is not merely a coincidental "0".
  if v_raw_y < 2 then
    insert into _fail values ('D3-mutation', format(
      'Y''s raw sale count is %s (<2) — the dedupe fixture proves nothing without a customer '
      'whose raw count and visit-day count actually disagree', v_raw_y));
  end if;
  if v_days_y >= 2 then
    insert into _fail values ('D3-mutation', 'Y unexpectedly has >=2 visit-days — the dedupe distinction is not being exercised');
  end if;

  -- definitions text updated to describe the new rule (not a stale description of raw counting).
  if position('visit-day' in coalesce(life#>>'{definitions,repeat_purchaser_in_period}', '')) = 0 then
    insert into _fail values ('D4', format('repeat_purchaser_in_period definition still describes raw purchases, not visit-days: %s',
      life#>>'{definitions,repeat_purchaser_in_period}'));
  end if;

  perform set_config('request.jwt.claims', null, true);
end
$v692$;

select case when count(*)=0
            then 'PASS — v692: category_customers/customer_records lineage reconciles exactly '
                 '(pinned and later as_of), and get_customer_lifecycle_v107 counts repeat '
                 'purchasers by distinct visit-day, not raw sale count'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v692: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
