-- EXECUTED regression fixture for nestly_v736 -- CI-100-CHECKLIST check 96 (Privacy and
-- small-cell protection), proven for EVERY principal class that can read Customer Intelligence,
-- not only the owner.
--
-- Read before touching this file: docs/qa/CI-100-CHECKLIST.md check 96 (verbatim: "Sensitive
-- demographic or customer details remain role-scoped; unsafe small groups are suppressed."),
-- docs/qa/CI-CORPUS-FIXTURE-GUIDE.md (impersonation, operational-business scaffolding,
-- consultant assignment via sme_prospects, super-admin Google claims -- every recipe below
-- follows it verbatim), and db/tests/executed/v667_ci_access_boundaries.sql B6/B7 (the
-- owner-principal small-cell floor=5 assertions this fixture extends to every OTHER principal).
--
-- WHY A NEW FIXTURE INSTEAD OF EXTENDING v667. v667 proves the floor for ONE reader
-- (get_ci_category_customers_v1) under ONE served principal (the assigned consultant, for B3;
-- the owner is refused entirely under the PRODUCT-TRUTH-vs-v523 reading v667 encodes at its own
-- head). This fixture proves small-cell behaviour across FIVE readers
-- (get_ci_category_customers_v1, get_ci_customer_records_v1, get_ci_demographics_v1,
-- get_ci_staff_identity_v1, get_ci_staff_performance_v1) and the AI evidence pack's sessionless
-- drain path (app.v176_evidence_pack via app.v676_open_internal_drain, nestly_v676/v720), under
-- FOUR principal classes each (owner, assigned consultant, super admin, a stranger firm), on a
-- corpus built AFTER nestly_v689 (customerintel + view_finance) so it exercises the CURRENT
-- gate, not the v667-era one.
--
-- PREDETERMINED TRUTH TABLE (asserted as exact equality throughout; never `> 0`):
--   node_rare  ("small" cohort): 3 identified customers, 1 sale @ 1000 cents each -> below the
--              floor (5, app.subgroup_evidence_v1). get_ci_category_customers_v1 must return
--              customers=[] and suppressed{cohort_size:3, floor:5}.
--   node_pop   ("big" cohort):   6 identified customers, 1 sale @ 1000 cents each -> at/above
--              the floor. get_ci_category_customers_v1 must return 6 named rows.
--   Demographics: the small cohort is also one (age_band, gender) cell (n=3, '31_40'/'female');
--              the big cohort is a DIFFERENT cell (n=6, '41_50'/'male'). Cell n=3 -> atv_cents
--              null, evidence.status='insufficient'. Cell n=6 -> atv_cents present,
--              evidence.status='ok'. Demographics cells never carry a name or client_id at all
--              -- structurally, not just below the floor -- and this fixture asserts that shape
--              directly rather than assuming it.
--   Staff:     staff_low is credited (sale_items.staff_id) on the 3-client rare group ->
--              total_visits=3 (< floor). staff_ok is credited on the 6-client pop group ->
--              total_visits=6 (>= floor).
--   AI evidence pack (sessionless drain): biz_a's whole identified population for the test
--              window is 3+6=9 clients (>= floor) -> top_customers share percentages AND rows
--              present (unchanged from before nestly_v739). biz_c is seeded with exactly 2
--              identified clients (< floor) -> share percentages null AND (since nestly_v739)
--              rows=[] with a suppressed object -- see the T7 assertions below, updated by
--              nestly_v739 to match.
--
-- ONE FINDING RECORDED, NOT FAILED (F2 below was CLOSED by nestly_v739 -- see that migration and
-- the updated T7 assertions further down; this fixture now asserts the fixed behaviour instead of
-- characterizing the gap). Per the working instructions: "assert whatever the checklist's wording
-- requires and report if the reader discloses a name at n<5". Check 96's text is about CUSTOMER
-- identity and demographic small groups; it says nothing about staff (employee) identity. F1 below
-- is a deliberate, already-reviewed product shape (nestly_v683/v699), not an access-boundary
-- defect, so this fixture CHARACTERIZES it (asserts the real, current behaviour, so a change shows
-- up as a diff) rather than failing on it:
--   F1 get_ci_staff_performance_v1 discloses `full_name` for EVERY staff row regardless of n --
--      only the rate-like fields (revenue_per_visit_cents, adjusted.expected_revenue_cents,
--      adjusted.index) null out below the floor. A staff member with 3 evidence-ok visits is
--      named exactly as prominently as one with 300. get_ci_staff_identity_v1, by contrast,
--      NEVER discloses a name at any n -- it returns staff_id (uuid) only, so the two staff
--      readers disagree on whether staff identity is small-cell-sensitive at all.
--   F2 (CLOSED by nestly_v739). Was: the AI evidence pack's `insights.top_customers.rows` were
--      NEVER suppressed by the floor -- only `top1_share_of_total_revenue_pct` /
--      `top5_share_of_total_revenue_pct` (and the identified-revenue twins) nulled out. The rows
--      themselves always rendered (up to 5, ordered by revenue) via app.v177_person_label --
--      "First L." for a two-token name, a bare single token for a one-token name, "Guest XXXX" for
--      none -- REGARDLESS of how small the identified population was. In a 2-customer window that
--      was a first-name-plus-revenue-rank disclosure the owner-facing category-customers floor
--      refuses to make about the same two people. nestly_v739 closed the gap: `rows` now empties
--      to [] and a `suppressed` object (shaped like get_ci_category_customers_v1's own:
--      reason/floor/cohort_size) is emitted whenever top_customers.evidence.status is
--      'insufficient', reusing the exact same subgroup_evidence_v1 expression the share fields
--      already gated on -- so all three (shares, rows, suppressed) now agree on the same n<5 line.
--
-- Named for v736: every "served" assertion below is preceded by a precondition assertion that
-- the principal genuinely holds the access being exercised (fixture-guide rule). Every
-- "refused" assertion asserts errcode 42501 exactly, never merely "raised". One transaction,
-- rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v736$
declare
  biz_a      uuid := '00000000-0000-4000-8000-000000073601'; -- entitled firm
  biz_b      uuid := '00000000-0000-4000-8000-000000073602'; -- stranger firm (owner B)
  biz_c      uuid := '00000000-0000-4000-8000-000000073603'; -- tiny firm, evidence-pack only
  u_sa       uuid := '00000000-0000-4000-8000-000000073701';
  u_cons     uuid := '00000000-0000-4000-8000-000000073702';
  u_owner_a  uuid := '00000000-0000-4000-8000-000000073703';
  u_owner_b  uuid := '00000000-0000-4000-8000-000000073704';
  cons_id    uuid := '00000000-0000-4000-8000-000000073801';
  co_id      uuid := '00000000-0000-4000-8000-000000073802';
  svc_rare   uuid := '00000000-0000-4000-8000-000000073901';
  svc_pop    uuid := '00000000-0000-4000-8000-000000073902';
  staff_low  uuid := '00000000-0000-4000-8000-000000073a01'; -- 3 evidence-ok visits (< floor)
  staff_ok   uuid := '00000000-0000-4000-8000-000000073a02'; -- 6 evidence-ok visits (>= floor)
  k_floor    int  := 5;
  d_from     date := current_date - 20;
  d_to       date := current_date;
  node_rare  text;
  node_pop   text;
  g          jsonb;
  v_names    int;
  v_err      text;
  cl_id      uuid;
  cl_rare    uuid[];
  cl_pop     uuid[];
  cl_c       uuid[];
begin
  ---------------------------------------------------------------------------
  -- actors
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_sa,'zz-v736-sa@example.test'), (u_cons,'zz-v736-cons@example.test'),
    (u_owner_a,'zz-v736-oa@example.test'), (u_owner_b,'zz-v736-ob@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (u_sa,'zz-v736-sa@example.test') on conflict do nothing;

  ---------------------------------------------------------------------------
  -- businesses. biz_a is fully operational and post-v689 entitled: 'customerintel' in
  -- enabled_modules AND the owner's role carries view_finance (owner role does, by
  -- app.role_perms -- checked below as a precondition, not assumed).
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz_a,'ZZ v736 firm A','zz-v736-a', array['dashboard','clients','sales','reports','customerintel']),
    (biz_b,'ZZ v736 firm B','zz-v736-b', array['dashboard','clients','sales','reports']),
    (biz_c,'ZZ v736 firm C','zz-v736-c', array['dashboard','clients','sales','reports']);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz_a, u_owner_a, 'owner', 'ZZ v736 owner A', true, 'approved'),
    (biz_b, u_owner_b, 'owner', 'ZZ v736 owner B', true, 'approved');

  -- Operational scaffolding for biz_a ONLY (fixture-guide "making a business genuinely
  -- operational"): the merchant arm of app.ci_access_gate_v667 needs app.is_salon_member(biz_a)
  -- true, which needs an approved workspace AND a paying subscription, not merely a staff row.
  -- biz_b is never read as itself (owner_b is only ever the STRANGER trying to read biz_a) and
  -- biz_c is read only through the sessionless drain, which does not consult is_salon_member at
  -- all -- neither needs this scaffolding, and skipping it keeps the fixture from proving
  -- something nobody asked it to prove.
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz_a, 'approved', now(), 'v736 small-cell principals fixture')
    on conflict (business_id) do update
      set approval_status='approved', decided_at=now(),
          decision_reason='v736 small-cell principals fixture';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz_a, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz_a, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  -- The assigned consultant, for biz_a only (fixture-guide "assigning a consultant").
  insert into public.platform_consultants (id, user_id, display_name, tier, employment_started_on, active)
    values (cons_id, u_cons, 'ZZ v736 consultant', 'senior', current_date - 400, true);
  insert into public.sme_companies (id, legal_name, trading_name)
    values (co_id, 'ZZ v736 Firm A Pte Ltd', 'ZZ v736 Firm A');
  insert into public.sme_prospects (company_id, legacy_stage_raw, assigned_consultant_id,
                                    ownership_state, queue_key,
                                    converted_business_id, converted_at, converted_by)
    values (co_id, 'zz-v736-fixture', cons_id, 'owned', null, biz_a, clock_timestamp(), u_sa);

  ---------------------------------------------------------------------------
  -- catalogue: one rare node (3 customers) and one popular node (6 customers)
  ---------------------------------------------------------------------------
  select n.node_key into node_rare from public.taxonomy_nodes n
   where n.version_no=1 and n.level=2 order by n.node_key limit 1;
  select n.node_key into node_pop from public.taxonomy_nodes n
   where n.version_no=1 and n.level=2 and n.node_key <> node_rare order by n.node_key limit 1;
  if node_rare is null or node_pop is null then
    insert into _fail values ('T0','taxonomy v1 has fewer than two level-2 nodes; fixture cannot run');
    return;
  end if;

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_rare, biz_a, 'ZZ v736 rare', 1000, 30),
    (svc_pop,  biz_a, 'ZZ v736 pop',  1000, 30);
  insert into public.service_canonical_map
    (business_id, service_id, node_key, version_no, method, mapped_by) values
    (biz_a, svc_rare, node_rare, 1, 'owner_chosen', u_owner_a),
    (biz_a, svc_pop,  node_pop,  1, 'owner_chosen', u_owner_a);

  insert into public.staff (business_id, id, role, full_name, active, access_state) values
    (biz_a, staff_low, 'staff', 'ZZ v736 staff low-n', true, 'approved'),
    (biz_a, staff_ok,  'staff', 'ZZ v736 staff ok-n',  true, 'approved');

  -- 3 rare-node customers, born 1994-01-15 / female -> one demographic cell, n=3.
  select array_agg(('00000000-0000-4000-8000-000000073b' || lpad((10+ser.i)::text,2,'0'))::uuid)
    into cl_rare from generate_series(1,3) ser(i);
  insert into public.clients (id, business_id, full_name, birth_date, gender)
  select c, biz_a, 'Zzcust' || row_number() over () || ' Rareperson', date '1994-01-15', 'female'
    from unnest(cl_rare) c;

  -- 6 pop-node customers, born 1978-01-15 / male -> a DIFFERENT demographic cell, n=6.
  select array_agg(('00000000-0000-4000-8000-000000073c' || lpad((10+ser.i)::text,2,'0'))::uuid)
    into cl_pop from generate_series(1,6) ser(i);
  insert into public.clients (id, business_id, full_name, birth_date, gender)
  select c, biz_a, 'Zzcust' || row_number() over () || ' Popperson', date '1978-01-15', 'male'
    from unnest(cl_pop) c;

  -- One sale + one credited service line per client. Rare group -> staff_low; pop group ->
  -- staff_ok. This is deliberate reuse (see header): the same 3/6 populations that prove the
  -- category-customers floor also prove the demographics floor and the staff-performance floor,
  -- instead of building three separate corpora for one number each.
  insert into public.sales (id, business_id, client_id, kind, amount_cents,
                            occurred_at, counts_as_revenue, counts_as_visit)
  select gen_random_uuid(), biz_a, c, 'service', 1000,
         (d_to - 1)::timestamp at time zone 'Asia/Singapore', true, true
    from unnest(cl_rare) c;
  insert into public.sales (id, business_id, client_id, kind, amount_cents,
                            occurred_at, counts_as_revenue, counts_as_visit)
  select gen_random_uuid(), biz_a, c, 'service', 1000,
         (d_to - 1)::timestamp at time zone 'Asia/Singapore', true, true
    from unnest(cl_pop) c;

  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents,
                                 line_cents, staff_id)
  select s.business_id, s.id, 'service', svc_rare, 1, s.amount_cents, s.amount_cents, staff_low
    from public.sales s where s.business_id = biz_a and s.client_id = any(cl_rare);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents,
                                 line_cents, staff_id)
  select s.business_id, s.id, 'service', svc_pop, 1, s.amount_cents, s.amount_cents, staff_ok
    from public.sales s where s.business_id = biz_a and s.client_id = any(cl_pop);

  -- biz_c: exactly 2 identified, revenue-bearing customers -- the evidence pack's
  -- below-floor scenario. Not entangled with biz_a's population at all.
  select array_agg(('00000000-0000-4000-8000-000000073d' || lpad((10+ser.i)::text,2,'0'))::uuid)
    into cl_c from generate_series(1,2) ser(i);
  insert into public.clients (id, business_id, full_name)
  select c, biz_c, 'Zzcust' || row_number() over () || ' Tinyperson' from unnest(cl_c) c;
  insert into public.sales (id, business_id, client_id, kind, amount_cents,
                            occurred_at, counts_as_revenue, counts_as_visit)
  select gen_random_uuid(), biz_c, c, 'service', 2000,
         (d_to - 1)::timestamp at time zone 'Asia/Singapore', true, true
    from unnest(cl_c) c;

  ---------------------------------------------------------------------------
  -- T0-pre. Preconditions: every principal genuinely holds the access its "served" assertions
  -- below rely on, or those assertions would pass vacuously (fixture-guide "the rule that
  -- matters most").
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_a,'role','authenticated')::text, true);
  if not app.is_salon_member(biz_a) then
    insert into _fail values ('T0-pre','owner A is not a salon member; every owner assertion below is vacuous');
  end if;
  if not app.can_module(biz_a,'customerintel') then
    insert into _fail values ('T0-pre','owner A cannot resolve customerintel; every owner assertion below is vacuous');
  end if;
  if not app.has_perm(biz_a,'view_finance') then
    insert into _fail values ('T0-pre','owner A lacks view_finance; every owner assertion below is vacuous');
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub',u_cons,'role','authenticated')::text, true);
  if not exists (select 1 from app.assigned_consultant_v94(biz_a) c where c.user_id = u_cons) then
    insert into _fail values ('T0-pre','the fixture consultant is not resolved as assigned to biz_a; every consultant assertion below is vacuous');
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_b,'role','authenticated')::text, true);
  if app.is_salon_member(biz_a) or exists (select 1 from app.assigned_consultant_v94(biz_a) c where c.user_id = u_owner_b) then
    insert into _fail values ('T0-pre','owner B unexpectedly holds access to biz_a; every stranger refusal below is vacuous');
  end if;

  perform set_config('request.jwt.claims', null, true);

  ---------------------------------------------------------------------------
  -- T1. get_ci_category_customers_v1, below floor (node_rare, 3 customers).
  --     Owner, consultant and super admin must all see the SAME suppressed shape.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_a,'role','authenticated')::text, true);
  begin
    g := public.get_ci_category_customers_v1(biz_a, node_rare, d_from, d_to);
    if coalesce(jsonb_array_length(g->'customers'),-1) <> 0 then
      insert into _fail values ('T1-owner', format('rare category returned %s customer rows, expected 0 (suppressed)', jsonb_array_length(g->'customers')));
    end if;
    if coalesce((g->'suppressed'->>'cohort_size')::int,-1) <> 3 then
      insert into _fail values ('T1-owner', format('suppressed.cohort_size was %s, expected 3', g->'suppressed'->>'cohort_size'));
    end if;
    if coalesce((g->'suppressed'->>'floor')::int,-1) <> k_floor then
      insert into _fail values ('T1-owner', format('suppressed.floor was %s, expected %s', g->'suppressed'->>'floor', k_floor));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T1-owner', format('entitled owner refused on below-floor category read (%s)', v_err));
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub',u_cons,'role','authenticated')::text, true);
  begin
    g := public.get_ci_category_customers_v1(biz_a, node_rare, d_from, d_to);
    if coalesce(jsonb_array_length(g->'customers'),-1) <> 0
       or coalesce((g->'suppressed'->>'cohort_size')::int,-1) <> 3 then
      insert into _fail values ('T1-consultant', 'below-floor category read did not match the owner''s suppressed shape');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T1-consultant', format('assigned consultant refused on below-floor category read (%s)', v_err));
  end;

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  begin
    g := public.get_ci_category_customers_v1(biz_a, node_rare, d_from, d_to);
    if coalesce(jsonb_array_length(g->'customers'),-1) <> 0
       or coalesce((g->'suppressed'->>'cohort_size')::int,-1) <> 3 then
      insert into _fail values ('T1-superadmin', 'below-floor category read did not match the owner''s suppressed shape');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T1-superadmin', format('super admin refused on below-floor category read (%s)', v_err));
  end;

  ---------------------------------------------------------------------------
  -- T2. get_ci_category_customers_v1, at/above floor (node_pop, 6 customers): names present.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_a,'role','authenticated')::text, true);
  begin
    g := public.get_ci_category_customers_v1(biz_a, node_pop, d_from, d_to);
    if jsonb_array_length(g->'customers') <> 6 then
      insert into _fail values ('T2-owner', format('pop category returned %s rows, expected 6', jsonb_array_length(g->'customers')));
    end if;
    select count(*) into v_names
      from jsonb_array_elements(g->'customers') c
     where coalesce(c->>'full_name','') <> '';
    if v_names <> 6 then
      insert into _fail values ('T2-owner', format('%s of 6 at-floor rows carried a name, expected 6', v_names));
    end if;
    if g->'suppressed' is distinct from 'null'::jsonb then
      insert into _fail values ('T2-owner', 'an at-floor cohort was marked suppressed');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T2-owner', format('entitled owner refused on at-floor category read (%s)', v_err));
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub',u_cons,'role','authenticated')::text, true);
  begin
    g := public.get_ci_category_customers_v1(biz_a, node_pop, d_from, d_to);
    if jsonb_array_length(g->'customers') <> 6 then
      insert into _fail values ('T2-consultant', format('consultant saw %s rows, expected 6', jsonb_array_length(g->'customers')));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T2-consultant', format('assigned consultant refused on at-floor category read (%s)', v_err));
  end;

  ---------------------------------------------------------------------------
  -- T3. get_ci_customer_records_v1: single-client drill. No floor by design (the migration
  --     header: "not a fresh cohort that could re-identify anyone" -- the caller either already
  --     saw this identity in an aggregate, or holds firm-wide access). Must still answer for
  --     the owner and the consultant even though the client is drawn from the 3-person
  --     BELOW-FLOOR cohort -- proving the absence of a floor is deliberate, not an oversight
  --     that happens to look permissive.
  ---------------------------------------------------------------------------
  cl_id := cl_rare[1];
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_a,'role','authenticated')::text, true);
  begin
    g := public.get_ci_customer_records_v1(biz_a, cl_id, d_from, d_to);
    if coalesce(jsonb_array_length(g->'sales'),0) < 1 then
      insert into _fail values ('T3-owner', 'owner drill on a below-floor-cohort client returned no sales');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T3-owner', format('entitled owner refused on the per-client drill (%s)', v_err));
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub',u_cons,'role','authenticated')::text, true);
  begin
    g := public.get_ci_customer_records_v1(biz_a, cl_id, d_from, d_to);
    if coalesce(jsonb_array_length(g->'sales'),0) < 1 then
      insert into _fail values ('T3-consultant', 'consultant drill on a below-floor-cohort client returned no sales');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T3-consultant', format('assigned consultant refused on the per-client drill (%s)', v_err));
  end;

  ---------------------------------------------------------------------------
  -- T4. get_ci_demographics_v1: the 3-customer cell (below floor) nulls its rate field and
  --     reports evidence.status='insufficient'; the 6-customer cell (at floor) does not. Both
  --     cells are asserted to carry no customer-identifying key at all (structural, not merely
  --     "empty at n<5") -- a demographics cell was never a customer row to begin with.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_a,'role','authenticated')::text, true);
  begin
    g := public.get_ci_demographics_v1(biz_a, d_from, d_to);
    if not exists (
      select 1 from jsonb_array_elements(g->'cells') c
       where c->>'age_band'='31_40' and c->>'gender'='female'
         and (c->>'customers')::int = 3
    ) then
      insert into _fail values ('T4-owner', 'the 3-customer (31_40/female) demographics cell was not found with customers=3');
    end if;
    if exists (
      select 1 from jsonb_array_elements(g->'cells') c
       where c->>'age_band'='31_40' and c->>'gender'='female'
         and c->'atv_cents' is distinct from 'null'::jsonb
    ) then
      insert into _fail values ('T4-owner', 'the below-floor demographics cell disclosed a non-null atv_cents');
    end if;
    if exists (
      select 1 from jsonb_array_elements(g->'cells') c
       where c->>'age_band'='31_40' and c->>'gender'='female'
         and c->'evidence'->>'status' <> 'insufficient'
    ) then
      insert into _fail values ('T4-owner', 'the below-floor demographics cell did not report evidence.status=insufficient');
    end if;
    if not exists (
      select 1 from jsonb_array_elements(g->'cells') c
       where c->>'age_band'='41_50' and c->>'gender'='male'
         and (c->>'customers')::int = 6
    ) then
      insert into _fail values ('T4-owner', 'the 6-customer (41_50/male) demographics cell was not found with customers=6');
    end if;
    if exists (
      select 1 from jsonb_array_elements(g->'cells') c
       where c->>'age_band'='41_50' and c->>'gender'='male'
         and c->'evidence'->>'status' <> 'ok'
    ) then
      insert into _fail values ('T4-owner', 'the at-floor (41_50/male, n=6) demographics cell did not report evidence.status=ok');
    end if;
    -- Structural check: NO cell, at any n, carries a customer-identifying key.
    if exists (
      select 1 from jsonb_array_elements(g->'cells') c
       where c ? 'full_name' or c ? 'client_id' or c ? 'customer_id' or c ? 'name'
    ) then
      insert into _fail values ('T4-owner', 'a demographics cell carried a customer-identifying key');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T4-owner', format('entitled owner refused on demographics (%s)', v_err));
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub',u_cons,'role','authenticated')::text, true);
  begin
    g := public.get_ci_demographics_v1(biz_a, d_from, d_to);
    if g is null then insert into _fail values ('T4-consultant', 'consultant got no demographics payload'); end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T4-consultant', format('assigned consultant refused on demographics (%s)', v_err));
  end;

  ---------------------------------------------------------------------------
  -- T5. get_ci_staff_identity_v1: never discloses a name at any n -- staff_id (uuid) only.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_a,'role','authenticated')::text, true);
  begin
    g := public.get_ci_staff_identity_v1(biz_a, d_from, d_to);
    if g::text ilike '%full_name%' or g::text ilike '%ZZ v736 staff%' then
      insert into _fail values ('T5-owner', 'get_ci_staff_identity_v1 leaked a staff name into its payload');
    end if;
    if coalesce((g->'coverage'->>'total_sales')::int,-1) <> 9 then
      insert into _fail values ('T5-owner', format('staff identity coverage.total_sales was %s, expected 9 (3 rare + 6 pop)', g->'coverage'->>'total_sales'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T5-owner', format('entitled owner refused on staff identity (%s)', v_err));
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub',u_cons,'role','authenticated')::text, true);
  begin
    g := public.get_ci_staff_identity_v1(biz_a, d_from, d_to);
    if g::text ilike '%full_name%' then
      insert into _fail values ('T5-consultant', 'get_ci_staff_identity_v1 leaked a staff name into its payload for the consultant');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T5-consultant', format('assigned consultant refused on staff identity (%s)', v_err));
  end;

  ---------------------------------------------------------------------------
  -- T6 (FINDING F1, characterized not failed). get_ci_staff_performance_v1: full_name is
  --    disclosed for BOTH staff_low (n=3, below floor) and staff_ok (n=6, at floor); only the
  --    rate-like fields are floor-gated. Asserted as the observed shape so a future change to
  --    this either direction shows up as a fixture diff.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_a,'role','authenticated')::text, true);
  begin
    g := public.get_ci_staff_performance_v1(biz_a, d_from, d_to);

    if not exists (select 1 from jsonb_array_elements(g->'staff') s
                     where s->>'staff_id' = staff_low::text
                       and s->>'full_name' = 'ZZ v736 staff low-n') then
      insert into _fail values ('T6-F1', 'staff_low''s full_name was NOT disclosed at n=3 -- F1''s header claim is stale, re-read before trusting it');
    end if;
    if exists (select 1 from jsonb_array_elements(g->'staff') s
                where s->>'staff_id' = staff_low::text
                  and s->'evidence'->>'status' <> 'insufficient') then
      insert into _fail values ('T6-owner', 'staff_low (n=3) did not report evidence.status=insufficient');
    end if;
    if exists (select 1 from jsonb_array_elements(g->'staff') s
                where s->>'staff_id' = staff_low::text
                  and (s->'unadjusted'->'revenue_per_visit_cents' is distinct from 'null'::jsonb
                       or s->'adjusted'->'expected_revenue_cents' is distinct from 'null'::jsonb
                       or s->'adjusted'->'index' is distinct from 'null'::jsonb)) then
      insert into _fail values ('T6-owner', 'staff_low (n=3, below floor) disclosed a rate-like field that should have nulled out');
    end if;

    if not exists (select 1 from jsonb_array_elements(g->'staff') s
                     where s->>'staff_id' = staff_ok::text
                       and s->>'full_name' = 'ZZ v736 staff ok-n') then
      insert into _fail values ('T6-owner', 'staff_ok''s full_name was not disclosed at n=6');
    end if;
    if exists (select 1 from jsonb_array_elements(g->'staff') s
                where s->>'staff_id' = staff_ok::text
                  and s->'evidence'->>'status' <> 'ok') then
      insert into _fail values ('T6-owner', 'staff_ok (n=6) did not report evidence.status=ok');
    end if;
    if exists (select 1 from jsonb_array_elements(g->'staff') s
                where s->>'staff_id' = staff_ok::text
                  and s->'unadjusted'->'revenue_per_visit_cents' is not distinct from 'null'::jsonb) then
      insert into _fail values ('T6-owner', 'staff_ok (n=6, at floor) unexpectedly nulled revenue_per_visit_cents');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T6-owner', format('entitled owner refused on staff performance (%s)', v_err));
  end;

  ---------------------------------------------------------------------------
  -- T7 (FINDING F2, CLOSED by nestly_v739). AI evidence pack, sessionless drain
  --     (app.v176_evidence_pack via app.v676_open_internal_drain -- nestly_v676/v720, the
  --     ONE real production caller's own shape). biz_a: 9-client window (>= floor) -> share
  --     percentages AND rows present, unchanged. biz_c: 2-client window (< floor) -> share
  --     percentages null AND (since nestly_v739) rows=[] with a suppressed object shaped like
  --     get_ci_category_customers_v1's own. biz_a's rows still carry v177-redacted labels, never
  --     the client's raw multi-word full_name.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', null, true); -- sessionless: auth.uid() must read null
  perform app.v676_open_internal_drain();
  begin
    g := app.v176_evidence_pack(biz_a, 'monthly', d_from, d_to);
    if (g->'insights'->'top_customers'->'top1_share_of_total_revenue_pct') is null
       or (g->'insights'->'top_customers'->'top1_share_of_total_revenue_pct') = 'null'::jsonb then
      insert into _fail values ('T7-bizA', 'the 9-client (>= floor) window unexpectedly nulled top1_share_of_total_revenue_pct');
    end if;
    if (g->'insights'->'top_customers'->'suppressed') is distinct from 'null'::jsonb then
      insert into _fail values ('T7-bizA', 'the 9-client (>= floor) window unexpectedly carried a top_customers.suppressed object');
    end if;
    if not exists (select 1 from jsonb_array_elements(g->'insights'->'top_customers'->'rows') r
                    where r->>'label' !~ ' ' or r->>'label' ~ '^[A-Za-z0-9]+ [A-Z]\.$') then
      insert into _fail values ('T7-bizA', 'no top_customers row matched the v177 "single token or First L." label shape');
    end if;
    if exists (select 1 from jsonb_array_elements(g->'insights'->'top_customers'->'rows') r
                where r->>'label' ilike '%Rareperson%' or r->>'label' ilike '%Popperson%') then
      insert into _fail values ('T7-bizA', 'a top_customers row disclosed the client''s raw fixture full_name, not a v177 label');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T7-bizA', format('sessionless drain call raised %s reading biz_a evidence pack', v_err));
  end;
  perform app.v676_close_internal_drain();

  perform app.v676_open_internal_drain();
  begin
    g := app.v176_evidence_pack(biz_c, 'monthly', d_from, d_to);
    if (g->'insights'->'top_customers'->'top1_share_of_total_revenue_pct') is not null
       and (g->'insights'->'top_customers'->'top1_share_of_total_revenue_pct') <> 'null'::jsonb then
      insert into _fail values ('T7-bizC', 'the 2-client (< floor) window did NOT null top1_share_of_total_revenue_pct -- header is stale');
    end if;
    -- F2, CLOSED by nestly_v739: rows now suppress to [] below the floor, with a
    -- get_ci_category_customers_v1-shaped `suppressed` object.
    if coalesce(jsonb_array_length(g->'insights'->'top_customers'->'rows'),0) <> 0 then
      insert into _fail values ('T7-bizC', format(
        'nestly_v739 regression: expected top_customers.rows=[] in a 2-client below-floor window, got %s row(s)',
        jsonb_array_length(g->'insights'->'top_customers'->'rows')));
    end if;
    if (g->'insights'->'top_customers'->'suppressed') is null
       or (g->'insights'->'top_customers'->'suppressed') = 'null'::jsonb then
      insert into _fail values ('T7-bizC', 'top_customers.suppressed was null in a 2-client below-floor window, expected an object');
    else
      if g->'insights'->'top_customers'->'suppressed'->>'reason' <> 'below_small_cell_floor' then
        insert into _fail values ('T7-bizC', format('suppressed.reason=%s, expected below_small_cell_floor',
          g->'insights'->'top_customers'->'suppressed'->>'reason'));
      end if;
      if (g->'insights'->'top_customers'->'suppressed'->>'floor')::int <> 5 then
        insert into _fail values ('T7-bizC', format('suppressed.floor=%s, expected 5',
          g->'insights'->'top_customers'->'suppressed'->>'floor'));
      end if;
      if (g->'insights'->'top_customers'->'suppressed'->>'cohort_size')::int <> 2 then
        insert into _fail values ('T7-bizC', format('suppressed.cohort_size=%s, expected 2',
          g->'insights'->'top_customers'->'suppressed'->>'cohort_size'));
      end if;
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T7-bizC', format('sessionless drain call raised %s reading biz_c evidence pack', v_err));
  end;
  perform app.v676_close_internal_drain();

  ---------------------------------------------------------------------------
  -- T8. Stranger (owner B): 42501 on every reader above, and on the evidence pack read through
  --     owner B's own SESSION (not the drain -- the drain is sessionless by construction and
  --     is not owner B's route in production; this proves owner B's session specifically).
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_b,'role','authenticated')::text, true);

  begin
    g := public.get_ci_category_customers_v1(biz_a, node_pop, d_from, d_to);
    insert into _fail values ('T8-category', 'a stranger firm''s owner read biz_a category customers');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('T8-category', format('refused with %s, expected 42501', v_err));
  end;

  begin
    g := public.get_ci_customer_records_v1(biz_a, cl_id, d_from, d_to);
    insert into _fail values ('T8-records', 'a stranger firm''s owner read biz_a''s per-client drill (floor-free reader, still tenant-scoped)');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('T8-records', format('refused with %s, expected 42501', v_err));
  end;

  begin
    g := public.get_ci_demographics_v1(biz_a, d_from, d_to);
    insert into _fail values ('T8-demographics', 'a stranger firm''s owner read biz_a demographics');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('T8-demographics', format('refused with %s, expected 42501', v_err));
  end;

  begin
    g := public.get_ci_staff_identity_v1(biz_a, d_from, d_to);
    insert into _fail values ('T8-staffid', 'a stranger firm''s owner read biz_a staff identity');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('T8-staffid', format('refused with %s, expected 42501', v_err));
  end;

  begin
    g := public.get_ci_staff_performance_v1(biz_a, d_from, d_to);
    insert into _fail values ('T8-staffperf', 'a stranger firm''s owner read biz_a staff performance');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('T8-staffperf', format('refused with %s, expected 42501', v_err));
  end;

  begin
    g := app.v176_evidence_pack(biz_a, 'monthly', d_from, d_to);
    insert into _fail values ('T8-evidencepack', 'a stranger firm''s owner session read biz_a''s AI evidence pack directly');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('T8-evidencepack', format('refused with %s, expected 42501', v_err));
  end;

  perform set_config('request.jwt.claims', null, true);
end
$v736$;

select case when count(*)=0
            then 'PASS -- small-cell suppression holds for owner, consultant and super admin; tenant isolation holds for the stranger; one non-failing finding recorded (F1 staff full_name); F2 (evidence-pack top_customers rows) closed by nestly_v739'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v736: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
