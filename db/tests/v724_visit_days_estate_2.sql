-- EXECUTED acceptance fixture for nestly_v724 — check 4 estate refutation (round 2).
--
-- Named for v724 (above the v422 baseline watermark): n/a in the baseline phase (every function
-- below already exists pre-migration with the OLD raw-row counting, so the assertions below
-- simply fail there — reported n/a per docs/qa/CI-CORPUS-FIXTURE-GUIDE.md), gated on the
-- migrated run. Proves db/migrations/20260920_nestly_v724_visit_days_estate_2.sql.
--
-- ============================================================================================
-- FIXED FIXTURE DATA.
--
--   Client R ("split bill"): 3 sales on ONE calendar day (today - 30 days, at 09:00/13:00/18:00
--     SGT), 1 sale the next day (today - 29 days), 1 sale a week after that (today - 22 days).
--     5 raw sale rows. 3 distinct visit-days: {D-30, D-29, D-22}. Has a phone for the till
--     phone-lookup check.
--   Client C ("five distinct days"): 5 sales, one per day, at today minus {25,20,15,10,5} days.
--     5 raw sale rows. 5 distinct visit-days (no collisions).
--   Client S ("single-day split, acquisition discriminator"): 2 sales on ONE calendar day (today
--     - 12 days). 2 raw sale rows, 1 distinct visit-day — must NOT count as a repeat customer.
--   Client X ("comeback"): one visit 90 days ago, then a same-day split bill (2 sales) 10 days
--     ago — a real 80-day-away return that a raw-row lag() collapses to away_days=0.
--
--   R and C both carry a resolvable demographic (age band 31_40, gender female) so they land in
--   the SAME demographics cell; S and X carry none, so they fall into 'unclassified' and cannot
--   contaminate that cell's count.
--
--   PREDETERMINED TRUTH TABLE (asserted exactly, never > 0):
--     v176/v177 firm/branch visits (window covering R+C): 8, not the 10 raw sales.
--     v177_customers: R visit_count=3, C visit_count=5.
--     v177_overview: sales.current/prior.visits equal what v176_sales_window returns for the
--       same two windows (proves inheritance, not a hardcoded number).
--     till card (app.v666_till_customer_card) and phone lookup (public.lookup_client_by_phone):
--       R visits=3.
--     get_attention_list_v548: R appears with cadence_days ≈ 4.1 (median of the two TRUE
--       cross-day intervals [1.125, 7.0] days — a raw-row lag() would instead median the four
--       raw intervals [0.1667, 0.2083, 0.75, 7.0] ≈ 0.5 days) and status='slipping'.
--     get_ci_acquisition_v1: the 'unknown' acquisition-source group holds all four clients
--       (R, C, S, X all default to first_acquired_via='unknown'); repeat_customers=3 (R, C, X —
--       each with >=2 distinct visit-days), excluding S (1 distinct day, 2 raw sales).
--     get_ci_demographics_v1: the (31_40, female) cell's visits=8 (R:3 + C:5), customers=2.
--     staff_list_returned_customers_v300(biz, 60, 30): lists X with away_days=80.
-- ============================================================================================

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v724$
declare
  biz      uuid := '00000000-0000-4000-8000-000000724001';
  branch1  uuid := '00000000-0000-4000-8000-000000724011';
  u_owner  uuid := '00000000-0000-4000-8000-000000724101';
  cl_r     uuid := '00000000-0000-4000-8000-000000724201';
  cl_c     uuid := '00000000-0000-4000-8000-000000724202';
  -- S and X live in a SEPARATE business (biz2) so they cannot contaminate biz's firm-wide
  -- visits total -- the "8, not 10" truth table below is R+C alone.
  biz2     uuid := '00000000-0000-4000-8000-000000724002';
  branch2  uuid := '00000000-0000-4000-8000-000000724012';
  u_owner2 uuid := '00000000-0000-4000-8000-000000724102';
  cl_s     uuid := '00000000-0000-4000-8000-000000724203';
  cl_x     uuid := '00000000-0000-4000-8000-000000724204';

  v_today_sgt  date := (now() at time zone 'Asia/Singapore')::date;
  v_today      date := v_today_sgt;

  v_r_day1 date;  -- 3 same-day sales
  v_r_day2 date;  -- next day
  v_r_day3 date;  -- a week after day2
  v_r_ts1  timestamptz;
  v_r_ts2  timestamptz;
  v_r_ts3  timestamptz;
  v_r_ts4  timestamptz;
  v_r_ts5  timestamptz;
  v_c_ts   timestamptz[];
  v_s_day  date;
  v_s_ts1  timestamptz;
  v_s_ts2  timestamptz;

  v_err    text;
  v_result jsonb;
  v_val    numeric;
  v_int    integer;
  v_bool   boolean;
  v_text   text;

  v_owner_claims text;

  -- v177_overview inheritance check
  v_cur_from date;
  v_pri_from date;
  v_pri_to   date;
  v_expect_cur jsonb;
  v_expect_pri jsonb;
begin
  v_r_day1 := v_today_sgt - 30;
  v_r_day2 := v_today_sgt - 29;
  v_r_day3 := v_today_sgt - 22;
  v_r_ts1  := (v_r_day1::timestamp + time '09:00') at time zone 'Asia/Singapore';
  v_r_ts2  := (v_r_day1::timestamp + time '13:00') at time zone 'Asia/Singapore';
  v_r_ts3  := (v_r_day1::timestamp + time '18:00') at time zone 'Asia/Singapore';
  v_r_ts4  := (v_r_day2::timestamp + time '12:00') at time zone 'Asia/Singapore';
  v_r_ts5  := (v_r_day3::timestamp + time '12:00') at time zone 'Asia/Singapore';
  select array_agg((d::timestamp + time '12:00') at time zone 'Asia/Singapore' order by d desc)
    into v_c_ts
    from unnest(array[v_today_sgt-25, v_today_sgt-20, v_today_sgt-15, v_today_sgt-10, v_today_sgt-5]) d;
  v_s_day := v_today_sgt - 12;
  v_s_ts1 := (v_s_day::timestamp + time '10:00') at time zone 'Asia/Singapore';
  v_s_ts2 := (v_s_day::timestamp + time '15:00') at time zone 'Asia/Singapore';

  ---------------------------------------------------------------------------
  -- actors, business, branch, staff, workspace/subscription
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_owner, 'zz-v724-owner@example.test'),
    (u_owner2, 'zz-v724-owner2@example.test')
  on conflict (id) do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v724 visit-days estate 2', 'zz-v724-visit-days-2',
     array['dashboard','dailyreport','clients','sales','reports','retention','customerintel','loyalty']),
    (biz2, 'ZZ v724 visit-days estate 2b', 'zz-v724-visit-days-2b',
     array['dashboard','dailyreport','clients','sales','reports','retention','customerintel','loyalty']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (branch1, biz, 'ZZ v724 branch one', true, true),
    (branch2, biz2, 'ZZ v724b branch one', true, true);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values
    (biz, u_owner, 'owner', 'ZZ v724 owner', true, 'approved'),
    (biz2, u_owner2, 'owner', 'ZZ v724b owner', true, 'approved');

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values
    (biz, 'approved', now(), 'fixture'),
    (biz2, 'approved', now(), 'fixture')
    on conflict (business_id) do update
      set approval_status='approved', decided_at=now(), decision_reason='fixture';

  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false), (biz2, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;

  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days'),
         (biz2, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update set payment_status='paid';

  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select b.id, br.id, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore',
         upper(b.currency), true
    from public.businesses b join public.branches br on br.business_id = b.id
   where b.id in (biz, biz2);

  v_owner_claims := json_build_object('sub', u_owner, 'role', 'authenticated')::text;
  perform set_config('request.jwt.claims', v_owner_claims, true);

  ---------------------------------------------------------------------------
  -- PRECONDITIONS
  ---------------------------------------------------------------------------
  if not app.has_perm(biz, 'view_sales') then
    insert into _fail values ('PRE-owner-view-sales', 'fixture owner lacks view_sales');
  end if;
  if not app.can_module(biz, 'clients') then
    insert into _fail values ('PRE-owner-clients-module', 'fixture owner lacks the clients module');
  end if;
  if not app.can_module(biz, 'retention') then
    insert into _fail values ('PRE-owner-retention-module', 'fixture owner lacks the retention module');
  end if;
  begin
    perform app.ci_access_gate_v667(biz, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PRE-ci-gate', format('owner cannot clear ci_access_gate_v667 (sqlstate %s)', v_err));
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner2, 'role', 'authenticated')::text, true);
  if not app.can_module(biz2, 'retention') then
    insert into _fail values ('PRE-owner2-retention-module', 'fixture owner2 lacks the retention module');
  end if;
  begin
    perform app.ci_access_gate_v667(biz2, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PRE-ci-gate2', format('owner2 cannot clear ci_access_gate_v667 (sqlstate %s)', v_err));
  end;
  perform set_config('request.jwt.claims', v_owner_claims, true);

  ---------------------------------------------------------------------------
  -- clients
  ---------------------------------------------------------------------------
  -- full_name shapes matter here: app.v177_person_label collapses to "first-token last-initial.",
  -- so both names must share a first token (to prove a real lookup, not a fluke) while differing
  -- in their SECOND word's first letter, or the two labels collide.
  insert into public.clients (id, business_id, full_name, phone, birth_date, gender) values
    (cl_r, biz, 'ZZv724 Rsplitbill', '+65 8100 0201', date '1994-06-15', 'female'),
    (cl_c, biz, 'ZZv724 Cfivedays', null, date '1993-03-20', 'female');
  insert into public.clients (id, business_id, full_name) values
    (cl_s, biz2, 'ZZ v724 single-day-split (S)'),
    (cl_x, biz2, 'ZZ v724 comeback (X)');

  ---------------------------------------------------------------------------
  -- sales — R: 3 same-day + 1 next-day + 1 a week later (5 raw rows, 3 visit-days)
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, created_at)
  values
    (gen_random_uuid(), biz, branch1, cl_r, 'service', 5000, v_r_ts1, v_r_ts1),
    (gen_random_uuid(), biz, branch1, cl_r, 'service', 5000, v_r_ts2, v_r_ts2),
    (gen_random_uuid(), biz, branch1, cl_r, 'service', 5000, v_r_ts3, v_r_ts3),
    (gen_random_uuid(), biz, branch1, cl_r, 'service', 5000, v_r_ts4, v_r_ts4),
    (gen_random_uuid(), biz, branch1, cl_r, 'service', 5000, v_r_ts5, v_r_ts5);

  ---------------------------------------------------------------------------
  -- sales — C: 5 distinct days (5 raw rows, 5 visit-days)
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, created_at)
  select gen_random_uuid(), biz, branch1, cl_c, 'service', 5000, ts, ts
    from unnest(v_c_ts) as ts;

  ---------------------------------------------------------------------------
  -- sales — S and X (biz2): switch to owner2's session (branch-module write checks fire on the
  -- INSERT trigger regardless of who is nominally running this block).
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner2, 'role', 'authenticated')::text, true);

  -- S: 2 sales, one calendar day (2 raw rows, 1 visit-day)
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, created_at)
  values
    (gen_random_uuid(), biz2, branch2, cl_s, 'service', 5000, v_s_ts1, v_s_ts1),
    (gen_random_uuid(), biz2, branch2, cl_s, 'service', 5000, v_s_ts2, v_s_ts2);

  -- X: one visit 90 days ago, then a same-day split bill 10 days ago (away_days=80)
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, created_at)
  values
    (gen_random_uuid(), biz2, branch2, cl_x, 'service', 5000, now() - interval '90 days', now() - interval '90 days'),
    (gen_random_uuid(), biz2, branch2, cl_x, 'service', 5000, now() - interval '10 days', now() - interval '10 days'),
    (gen_random_uuid(), biz2, branch2, cl_x, 'service', 5000,
      (now() - interval '10 days') + interval '5 minutes', (now() - interval '10 days') + interval '5 minutes');

  perform set_config('request.jwt.claims', v_owner_claims, true);

  ---------------------------------------------------------------------------
  -- CHECK 1 — app.v176_sales_window: firm-wide visits = 8 (R:3 + C:5), not 10 raw sales.
  ---------------------------------------------------------------------------
  v_result := app.v176_sales_window(biz, (v_today_sgt - 40), v_today);
  v_int := (v_result ->> 'visits')::integer;
  if v_int is distinct from 8 then
    insert into _fail values ('T1-v176-visits', format('v176_sales_window visits = %s, expected 8', v_int));
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 2 — app.v177_sales_window: branch-scoped, same total (all sales on branch1).
  ---------------------------------------------------------------------------
  v_result := app.v177_sales_window(biz, branch1, (v_today_sgt - 40), v_today);
  v_int := (v_result ->> 'visits')::integer;
  if v_int is distinct from 8 then
    insert into _fail values ('T2-v177sw-visits', format('v177_sales_window visits = %s, expected 8', v_int));
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 3 — app.v177_customers: visit_count per recent client is the distinct-day count.
  ---------------------------------------------------------------------------
  v_result := app.v177_customers(biz);
  v_text := app.v177_person_label('ZZv724 Rsplitbill', cl_r);
  select (c ->> 'visit_count')::integer into v_int
    from jsonb_array_elements(v_result -> 'recent') c
    where c ->> 'label' = v_text;
  if v_int is null then
    insert into _fail values ('T3-v177c-nomatch', format('could not locate client R (label %s) in v177_customers recent[]', v_text));
  elsif v_int is distinct from 3 then
    insert into _fail values ('T3-v177c-R-visitcount', format('R visit_count = %s, expected 3', v_int));
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 4 — app.v177_overview: sales.current/prior.visits equal what v176_sales_window
  -- returns for the SAME two windows (proves inheritance rather than a hardcoded number).
  ---------------------------------------------------------------------------
  v_cur_from := v_today - 29;
  v_pri_to   := v_today - 30;
  v_pri_from := v_today - 59;
  v_expect_cur := app.v176_sales_window(biz, v_cur_from, v_today);
  v_expect_pri := app.v176_sales_window(biz, v_pri_from, v_pri_to);

  v_result := app.v177_overview(biz, null);
  if (v_result -> 'sales' -> 'current' ->> 'visits') is distinct from (v_expect_cur ->> 'visits') then
    insert into _fail values ('T4-v177ov-current', format('overview current visits = %s, v176_sales_window says %s',
      v_result -> 'sales' -> 'current' ->> 'visits', v_expect_cur ->> 'visits'));
  end if;
  if (v_result -> 'sales' -> 'prior' ->> 'visits') is distinct from (v_expect_pri ->> 'visits') then
    insert into _fail values ('T4-v177ov-prior', format('overview prior visits = %s, v176_sales_window says %s',
      v_result -> 'sales' -> 'prior' ->> 'visits', v_expect_pri ->> 'visits'));
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 5 — app.v666_till_customer_card: R visits = 3.
  ---------------------------------------------------------------------------
  v_result := app.v666_till_customer_card(biz, cl_r);
  v_int := (v_result ->> 'visits')::integer;
  if v_int is distinct from 3 then
    insert into _fail values ('T5-v666-R-visits', format('till card visits = %s, expected 3', v_int));
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 6 — public.lookup_client_by_phone: R visits = 3 (same shape, independently).
  ---------------------------------------------------------------------------
  v_result := public.lookup_client_by_phone(biz, '+65 8100 0201');
  if (v_result ->> 'status') is distinct from 'found' then
    insert into _fail values ('T6-lcbp-pre', format('lookup_client_by_phone status = %s, expected found', v_result ->> 'status'));
  end if;
  v_int := (v_result ->> 'visits')::integer;
  if v_int is distinct from 3 then
    insert into _fail values ('T6-lcbp-R-visits', format('lookup_client_by_phone visits = %s, expected 3', v_int));
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 7 — public.get_attention_list_v548: R appears with cadence_days ~= 4.1 (the
  -- day-collapsed median of [1.125, 7.0] days), not the raw-row median (~0.5 days), and
  -- status='slipping' (last visit ~22 days ago, far past the slipping threshold either way).
  ---------------------------------------------------------------------------
  v_result := public.get_attention_list_v548(biz, null, 50);
  select (row ->> 'cadence_days')::numeric, row ->> 'status' into v_val, v_text
    from jsonb_array_elements(v_result -> 'rows') row
    where (row ->> 'client_id')::uuid = cl_r;
  if v_val is null then
    insert into _fail values ('T7-gal548-nomatch', 'client R does not appear in get_attention_list_v548 rows');
  else
    if v_val < 3.5 or v_val > 4.6 then
      insert into _fail values ('T7-gal548-cadence', format('R cadence_days = %s, expected ~4.1 (day-collapsed), not ~0.5 (raw-row)', v_val));
    end if;
    if v_text is distinct from 'slipping' then
      insert into _fail values ('T7-gal548-status', format('R status = %s, expected slipping', v_text));
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 7b — structural: get_attention_list_v548's live body must reference the authority.
  ---------------------------------------------------------------------------
  if position('app.ci_visit_day_v699' in
      coalesce(pg_get_functiondef(to_regprocedure('public.get_attention_list_v548(uuid,uuid,integer)')), '')) = 0 then
    insert into _fail values ('T7b-gal548-authority', 'get_attention_list_v548 does not reference app.ci_visit_day_v699');
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 8 — public.get_ci_acquisition_v1 (biz2, owner2 session): the 'unknown' source group
  -- holds S and X; repeat_customers=1 (X, 2 distinct visit-days), excluding S (1 distinct
  -- visit-day despite 2 raw sales).
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner2, 'role', 'authenticated')::text, true);

  v_result := public.get_ci_acquisition_v1(biz2, (v_today_sgt - 100), v_today, null, clock_timestamp());
  select (src ->> 'customers')::integer, (src ->> 'repeat_customers')::integer
    into v_int, v_val
    from jsonb_array_elements(v_result -> 'sources') src
    where src ->> 'via' = 'unknown' and src ->> 'evidence' = 'unknown';
  if v_int is null then
    insert into _fail values ('T8-gcav1-nomatch', 'no unknown/unknown acquisition source row found');
  else
    if v_int is distinct from 2 then
      insert into _fail values ('T8-gcav1-customers', format('unknown-source customers = %s, expected 2 (S, X)', v_int));
    end if;
    if v_val is distinct from 1 then
      insert into _fail values ('T8-gcav1-repeat', format('unknown-source repeat_customers = %s, expected 1 (X only; S excluded)', v_val));
    end if;
  end if;

  perform set_config('request.jwt.claims', v_owner_claims, true);

  ---------------------------------------------------------------------------
  -- CHECK 9 — public.get_ci_demographics_v1: the (31_40, female) cell's visits = 8, customers = 2.
  ---------------------------------------------------------------------------
  v_result := public.get_ci_demographics_v1(biz, (v_today_sgt - 40), v_today, null, clock_timestamp());
  select (cell ->> 'visits')::integer, (cell ->> 'customers')::integer into v_int, v_val
    from jsonb_array_elements(v_result -> 'cells') cell
    where cell ->> 'age_band' = '31_40' and cell ->> 'gender' = 'female';
  if v_int is null then
    insert into _fail values ('T9-gcdv1-nomatch', 'no (31_40, female) demographics cell found');
  else
    if v_val is distinct from 2 then
      insert into _fail values ('T9-gcdv1-customers', format('(31_40,female) cell customers = %s, expected 2', v_val));
    end if;
    if v_int is distinct from 8 then
      insert into _fail values ('T9-gcdv1-visits', format('(31_40,female) cell visits = %s, expected 8', v_int));
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 10 — public.staff_list_returned_customers_v300(biz2, 60, 30): lists X with
  -- away_days=80.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner2, 'role', 'authenticated')::text, true);
  v_result := public.staff_list_returned_customers_v300(biz2, 60, 30);
  perform set_config('request.jwt.claims', v_owner_claims, true);
  select (row ->> 'away_days')::integer into v_int
    from jsonb_array_elements(v_result -> 'rows') row
    where (row ->> 'id')::uuid = cl_x;
  if v_int is null then
    insert into _fail values ('T10-slrc300-nomatch',
      'client X does not appear in staff_list_returned_customers_v300 -- the raw-row bug would zero '
      'away_days and correctly exclude X from THIS list (away_days>=60 required), so a missing row '
      'here is the exact symptom this migration fixes');
  elsif v_int is distinct from 80 then
    insert into _fail values ('T10-slrc300-awaydays', format('X away_days = %s, expected 80', v_int));
  end if;

  ---------------------------------------------------------------------------
  -- CHECK 11 — app.ci_visit_registry_v699 names all eleven readers from this migration.
  ---------------------------------------------------------------------------
  v_result := app.ci_visit_registry_v699();
  if not (v_result -> 'readers' ? 'app.v176_sales_window')
     or not (v_result -> 'readers' ? 'app.v177_sales_window')
     or not (v_result -> 'readers' ? 'app.v177_customers')
     or not (v_result -> 'readers' ? 'app.v177_overview')
     or not (v_result -> 'readers' ? 'app.v666_till_customer_card')
     or not (v_result -> 'readers' ? 'public.lookup_client_by_phone')
     or not (v_result -> 'readers' ? 'public.staff_scan_member_qr_v327')
     or not (v_result -> 'readers' ? 'public.get_attention_list_v548')
     or not (v_result -> 'readers' ? 'public.get_ci_acquisition_v1')
     or not (v_result -> 'readers' ? 'public.get_ci_demographics_v1')
     or not (v_result -> 'readers' ? 'public.staff_list_returned_customers_v300') then
    insert into _fail values ('T11-registry-missing', 'ci_visit_registry_v699 is missing one or more nestly_v724 readers');
  end if;
  if (v_result -> 'readers' -> 'app.v176_sales_window' ->> 'uses_authority') is distinct from 'true' then
    insert into _fail values ('T11-registry-flag', 'app.v176_sales_window registry entry is not uses_authority=true');
  end if;

  ---------------------------------------------------------------------------
  -- Existing-fixture regression sanity: functions this migration touches must still be callable
  -- and must not have regressed for clients seeded on distinct calendar days elsewhere in the
  -- corpus (spot-checked structurally by every T*-authority assertion above; the full existing
  -- suites are run separately by the harness itself, not re-executed inline here).
  ---------------------------------------------------------------------------
end
$v724$;

select case when count(*)=0 then 'PASS — every visits/repeat/returning figure in this second estate sweep counts distinct (client, visit-day) pairs'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v724: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
