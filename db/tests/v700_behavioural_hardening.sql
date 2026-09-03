-- EXECUTED acceptance fixture for nestly_v700 — behavioural hardening of three v683 readers
-- (get_ci_staff_identity_v1, get_ci_rebooking_v1, get_ci_loyalty_programmes_v1), per an
-- independent refuter's findings against v683 (commit bda4c6b6), plus the shared CI envelope
-- (check 16) added mid-build once a refuter noticed none of the three ever called
-- app.ci_envelope_v680.
--
-- Named above the v422 baseline watermark: n/a in the baseline phase, gated on the migrated run
-- (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md). Every assertion is a PREDETERMINED exact value, never a
-- `> 0` spot check.
--
-- TRUTH TABLE — SECTION A: get_ci_staff_identity_v1 coverage floor (finding 1)
--   biz_a1: exactly 1 sale, staff_id set, no appointment. -> total_sales=1, evidence
--     {n:1,floor:5,status:'insufficient'}. credited_staff_id numerator=1 (count intact) but
--     pct MUST be null; booked/line/actual_provider numerator=0, pct null; operator_user_id
--     numerator=1 (trigger-defaulted to the calling session's uid), pct null.
--   biz_a2: exactly 6 sales, all staff_id set, no appointments. -> total_sales=6, evidence 'ok'.
--     credited_staff_id = 6/6 = 100.0 (pct now PRESENT). operator_user_id = 6/6 = 100.0.
--     booked/line/actual_provider = 0/6 = 0.0 (present, not null — 0.0 is a real computed pct,
--     not the below-floor null).
--   MUTATION: reverting credited_staff_id's line back to the pre-v700 raw app.rate_block_v1
--     call and re-running against biz_a1 must turn the null-pct assertion red (prove the guard
--     is what makes it null, not some other null-producing default).
--
-- TRUTH TABLE — SECTION B: get_ci_rebooking_v1 composition floor (finding 2)
--   biz_b: one rebooked cohort, 6 mature appointments, 5 on SVC_X and 1 on SVC_Y (all linked via
--     public.link_rebooked_appointment_v1 from one common source appointment).
--     -> cohort n=6. composition SVC_X: numerator=5, denominator=6, evidence(5)='ok' ->
--        pct = round(100*5/6,1) = 83.3 (PRESENT). composition SVC_Y: numerator=1, denominator=6,
--        evidence(1)='insufficient' -> pct MUST be null even though the cohort itself (n=6>=5)
--        clears its OWN floor — this is exactly the bug: gating must be per-service, not
--        per-cohort.
--   MUTATION: reverting the composition share line back to raw app.rate_block_v1(cm.n, c.n) and
--     re-running must turn SVC_Y's null-pct assertion red.
--
-- TRUTH TABLE — SECTION C: get_ci_loyalty_programmes_v1 (finding 3a/3b)
--   C1 (floor): biz_c1 has exactly one real, non-synthetic client with one qualifying visit in
--     the window -> eligible_customers=1. points.participation: numerator=0 (no points_ledger
--     row), denominator=1, evidence(1)='insufficient' -> pct MUST be null.
--   C2/C3 (synthetic exclusion): biz_base and biz_synth are TWINS. Both have exactly one real
--     client cl_real with an identical points redemption (redeemed_at = today-40, mature) and an
--     identical rewarded referral (qualified_at = today-40, mature), each followed by the SAME
--     real subsequent qualifying sale at today-30 (a paid return within 30 days of both events).
--     biz_synth ADDITIONALLY has a synthetic client cl_synth with its OWN points redemption and
--     rewarded referral at today-40 plus its own subsequent sale at today-30. If the exclusion
--     fix holds, cl_synth contributes NOTHING: biz_base's and biz_synth's points AND referral
--     outcome blocks (redemptions_total, immature, paid_return_within_30d numerator/denominator,
--     cannibalisation_proxy.within_cycle numerator/denominator) must be BYTE-IDENTICAL.
--   MUTATION: reverting the points-programme events query back to its pre-v700 (no join, no
--     is_synthetic filter) shape and re-running BOTH businesses must make their points outcome
--     blocks DIFFER (biz_synth's redemptions_total/paid_return inflate by cl_synth's row) — the
--     assertion of equality must go red without the fix.
--
-- SECTION D (check 16): every one of the three payloads above additionally carries the shared
-- app.ci_envelope_v680 shape — generated_at/as_of/period/exclusions (all five counts:
-- reversed_sales, synthetic_clients, anonymous_sales, missing_demographics,
-- overlapping_campaigns)/trace_id — asserted inline alongside each section's own truth table
-- rather than as a separate pass, since each section already has a live payload in hand.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

-- Shared super admin — every read in this fixture goes through the platform arm of
-- app.ci_access_gate_v667, per the fixture guide and v683's own precedent, since none of these
-- assertions are about entitlement (v667's own corpus already proves that boundary).
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000700001', 'zz-v700-sa@example.test')
  on conflict (id) do nothing;
insert into public.super_admins (user_id, email) values
  ('00000000-0000-4000-8000-000000700001', 'zz-v700-sa@example.test')
  on conflict do nothing;

-- Reused by every loyalty-programme business below: app.customer_cadence_v1 (called from inside
-- app.ci_loyalty_outcomes_v683 for the cannibalisation proxy) resolves a per-branch reporting
-- contract whose auto-created first version has effective_from ~ now(), which is AFTER every
-- backdated sale these fixtures insert. A second, earlier version fixes it — same technique
-- v683's own fixture uses (zz_v683_seed_reporting_contract), renamed here to avoid any
-- same-name collision with that file (each executed test gets its own database, so a collision
-- is not actually possible, but the distinct name keeps grep honest about which fixture owns it).
create or replace procedure zz_v700_seed_reporting_contract(p_biz uuid, p_branch uuid)
language plpgsql as $$
begin
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  values (p_biz, p_branch, 2, '2020-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', 'SGD', false);
end;
$$;

-- ============================================================================================
-- SECTION A — get_ci_staff_identity_v1 coverage floor (finding 1) + envelope (finding 4)
-- ============================================================================================
do $v700a$
declare
  u_sa      uuid := '00000000-0000-4000-8000-000000700001';
  biz_a1    uuid := '00000000-0000-4000-8000-000000700011';
  br_a1     uuid := '00000000-0000-4000-8000-000000700012';
  cl_a1     uuid := '00000000-0000-4000-8000-000000700013';
  st_a1     uuid := '00000000-0000-4000-8000-000000700014';
  biz_a2    uuid := '00000000-0000-4000-8000-000000700021';
  br_a2     uuid := '00000000-0000-4000-8000-000000700022';
  cl_a2     uuid := '00000000-0000-4000-8000-000000700023';
  st_a2     uuid := '00000000-0000-4000-8000-000000700024';
  v_today   date := (now() at time zone 'Asia/Singapore')::date;
  v_from    date;
  v_to      date;
  g         jsonb;
  v_def     text;
  v_mutated text;
  i         integer;
begin
  v_from := v_today - 20; v_to := v_today - 1;

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz_a1, 'ZZ v700 staff-id floor (1 sale)', 'zz-v700-staffid-1',
          array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (br_a1, biz_a1, 'ZZ v700 branch A1', true, true);
  insert into public.clients (id, business_id, full_name) values (cl_a1, biz_a1, 'ZZ v700 A1 client');
  -- sales.staff_id carries a composite FK to staff(id, business_id) (a later migration than
  -- v683), so a real staff row is required even though this fixture never logs in as them.
  insert into public.staff (id, business_id, role, full_name, active) values (st_a1, biz_a1, 'staff', 'ZZ v700 A1 staff', true);
  insert into public.sales (id, business_id, branch_id, client_id, staff_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz_a1, br_a1, cl_a1, st_a1, 'service', 5000,
          (v_today - 5)::timestamp at time zone 'Asia/Singapore',
          (v_today - 5)::timestamp at time zone 'Asia/Singapore');

  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz_a2, 'ZZ v700 staff-id floor (6 sales)', 'zz-v700-staffid-6',
          array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (br_a2, biz_a2, 'ZZ v700 branch A2', true, true);
  insert into public.clients (id, business_id, full_name) values (cl_a2, biz_a2, 'ZZ v700 A2 client');
  insert into public.staff (id, business_id, role, full_name, active) values (st_a2, biz_a2, 'staff', 'ZZ v700 A2 staff', true);
  for i in 1..6 loop
    insert into public.sales (id, business_id, branch_id, client_id, staff_id, kind, amount_cents, occurred_at, created_at)
    values (gen_random_uuid(), biz_a2, br_a2, cl_a2, st_a2, 'service', 5000,
            (v_today - i)::timestamp at time zone 'Asia/Singapore',
            (v_today - i)::timestamp at time zone 'Asia/Singapore');
  end loop;

  -- --- biz_a1: below floor (n=1) ---
  g := public.get_ci_staff_identity_v1(biz_a1, v_from, v_to, null);

  if (g->'coverage'->>'total_sales')::int is distinct from 1 then
    insert into _fail values ('A1-total', g->'coverage'->>'total_sales');
  end if;
  if (g->'coverage'->'evidence'->>'n')::int is distinct from 1
     or (g->'coverage'->'evidence'->>'floor')::int is distinct from 5
     or (g->'coverage'->'evidence'->>'status') is distinct from 'insufficient' then
    insert into _fail values ('A1-evidence', g->'coverage'->'evidence');
  end if;
  if (g->'coverage'->'credited_staff_id'->>'numerator')::int is distinct from 1
     or (g->'coverage'->'credited_staff_id'->>'denominator')::int is distinct from 1 then
    insert into _fail values ('A1-credited-counts', g->'coverage'->'credited_staff_id');
  end if;
  if (g->'coverage'->'credited_staff_id'->>'pct') is not null then
    insert into _fail values ('A1-credited-pct-not-null',
      'n=1 is below the floor of 5 -- credited_staff_id.pct must be null even though numerator/denominator are populated');
  end if;
  if (g->'coverage'->'operator_user_id'->>'numerator')::int is distinct from 1 then
    insert into _fail values ('A1-operator-numerator', g->'coverage'->'operator_user_id');
  end if;
  if (g->'coverage'->'operator_user_id'->>'pct') is not null
     or (g->'coverage'->'booked_staff_id'->>'pct') is not null
     or (g->'coverage'->'line_staff'->>'pct') is not null
     or (g->'coverage'->'actual_provider'->>'pct') is not null then
    insert into _fail values ('A1-other-pct-not-null', g->'coverage');
  end if;

  -- envelope (check 16)
  if not (g ? 'generated_at' and g ? 'as_of' and g ? 'period' and g ? 'exclusions' and g ? 'trace_id') then
    insert into _fail values ('A1-envelope-missing', g::text);
  end if;
  if not (g->'exclusions' ? 'reversed_sales' and g->'exclusions' ? 'synthetic_clients'
          and g->'exclusions' ? 'anonymous_sales' and g->'exclusions' ? 'missing_demographics'
          and g->'exclusions' ? 'overlapping_campaigns') then
    insert into _fail values ('A1-exclusions-incomplete', g->'exclusions');
  end if;

  -- --- biz_a2: at floor (n=6) ---
  g := public.get_ci_staff_identity_v1(biz_a2, v_from, v_to, null);

  if (g->'coverage'->>'total_sales')::int is distinct from 6 then
    insert into _fail values ('A2-total', g->'coverage'->>'total_sales');
  end if;
  if (g->'coverage'->'evidence'->>'status') is distinct from 'ok' then
    insert into _fail values ('A2-evidence', g->'coverage'->'evidence');
  end if;
  if (g->'coverage'->'credited_staff_id'->>'numerator')::int is distinct from 6
     or (g->'coverage'->'credited_staff_id'->>'denominator')::int is distinct from 6
     or (g->'coverage'->'credited_staff_id'->>'pct')::numeric is distinct from 100.0 then
    insert into _fail values ('A2-credited', g->'coverage'->'credited_staff_id');
  end if;
  if (g->'coverage'->'operator_user_id'->>'pct')::numeric is distinct from 100.0 then
    insert into _fail values ('A2-operator', g->'coverage'->'operator_user_id');
  end if;
  if (g->'coverage'->'booked_staff_id'->>'pct')::numeric is distinct from 0.0
     or (g->'coverage'->'line_staff'->>'pct')::numeric is distinct from 0.0
     or (g->'coverage'->'actual_provider'->>'pct')::numeric is distinct from 0.0 then
    insert into _fail values ('A2-zero-rates-present', g->'coverage');
  end if;

end
$v700a$;

-- MUTATION: SAVEPOINT/ROLLBACK TO are plain top-level SQL, not valid inside a PL/pgSQL DO block
-- (there is no direct PL/pgSQL statement for them — only an EXCEPTION block gives an implicit
-- one), so the mutate/check/restore sequence is three separate DO blocks joined by top-level
-- savepoint commands, referencing the same fixed business id the setup block above just wrote.
savepoint sp_a;
do $v700a_mutate$
declare
  biz_a1    uuid := '00000000-0000-4000-8000-000000700011';
  v_from    date := ((now() at time zone 'Asia/Singapore')::date) - 20;
  v_to      date := ((now() at time zone 'Asia/Singapore')::date) - 1;
  g         jsonb;
  v_def     text;
  v_mutated text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_staff_identity_v1(uuid,date,date,uuid)')) into v_def;
  v_mutated := replace(v_def,
    $m1$'credited_staff_id', app.rate_block_floor_gated_v683(v_credited, v_total, app.subgroup_evidence_v1(v_total)),$m1$,
    $m2$'credited_staff_id', app.rate_block_v1(v_credited, v_total),$m2$);
  if v_mutated = v_def then
    insert into _fail values ('A-mutation-anchor-missing', 'could not find the credited_staff_id line to mutate');
  else
    execute v_mutated;
    g := public.get_ci_staff_identity_v1(biz_a1, v_from, v_to, null);
    if (g->'coverage'->'credited_staff_id'->>'pct') is null then
      insert into _fail values ('A-mutation-not-red',
        'mutated (unguarded) function still returned a null pct for n=1 -- this fixture cannot distinguish fixed from unfixed');
    end if;
  end if;
end
$v700a_mutate$;
rollback to savepoint sp_a;

do $v700a_sanity$
declare
  biz_a1  uuid := '00000000-0000-4000-8000-000000700011';
  v_from  date := ((now() at time zone 'Asia/Singapore')::date) - 20;
  v_to    date := ((now() at time zone 'Asia/Singapore')::date) - 1;
  g       jsonb;
begin
  -- sanity: the real (fixed) function is restored by the rollback.
  g := public.get_ci_staff_identity_v1(biz_a1, v_from, v_to, null);
  if (g->'coverage'->'credited_staff_id'->>'pct') is not null then
    insert into _fail values ('A-restore-failed', 'fix was not restored after rollback to savepoint');
  end if;
end
$v700a_sanity$;

-- ============================================================================================
-- SECTION B — get_ci_rebooking_v1 per-service composition floor (finding 2) + envelope
-- ============================================================================================
do $v700b$
declare
  u_sa      uuid := '00000000-0000-4000-8000-000000700001';
  u_owner   uuid := '00000000-0000-4000-8000-000000700101';
  st_owner  uuid := '00000000-0000-4000-8000-000000700102';
  biz       uuid := '00000000-0000-4000-8000-000000700110';
  br1       uuid := '00000000-0000-4000-8000-000000700111';
  svc_x     uuid := '00000000-0000-4000-8000-000000700112';
  svc_y     uuid := '00000000-0000-4000-8000-000000700113';
  appt_src  uuid := '00000000-0000-4000-8000-000000700114';
  cl_src    uuid := '00000000-0000-4000-8000-000000700115';
  v_today   date := (now() at time zone 'Asia/Singapore')::date;
  v_from    date;
  v_to      date;
  g         jsonb;
  v_def     text;
  v_mutated text;
  i         integer;
  cl        uuid; appt uuid; svc uuid;
begin
  v_from := v_today - 100; v_to := v_today - 1;

  insert into auth.users (id, email) values (u_owner, 'zz-v700-b-owner@example.test')
    on conflict (id) do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v700 rebooking floor', 'zz-v700-rebooking',
          array['dashboard','clients','sales','reports','appointments']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (br1, biz, 'ZZ v700 rebooking branch', true, true);
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_by, decided_at, decision_reason)
  values (biz, 'approved', u_sa, now(), 'zz-v700 fixture')
    on conflict (business_id) do update set approval_status = 'approved',
      decided_by = u_sa, decided_at = now(), decision_reason = 'zz-v700 fixture';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state = 'current', workspace_paused = false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update set status = 'active', payment_status = 'paid',
      current_period_end = now() + interval '30 days';
  insert into public.staff (id, business_id, user_id, role, full_name, active)
  values (st_owner, biz, u_owner, 'owner', 'ZZ v700 Owner', true);
  insert into public.staff_branches (business_id, staff_id, branch_id) values (biz, st_owner, br1);
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_x, biz, 'ZZ v700 Service X', 5000, 30),
    (svc_y, biz, 'ZZ v700 Service Y', 8000, 45);

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);

  insert into public.clients (id, business_id, full_name) values (cl_src, biz, 'ZZ v700 rebook src client');
  insert into public.appointments
    (id, business_id, branch_id, client_id, staff_id, starts_at, ends_at, status, service_id, created_at)
  values (appt_src, biz, br1, cl_src, st_owner,
          (v_today - 200)::timestamp at time zone 'Asia/Singapore',
          (v_today - 200)::timestamp at time zone 'Asia/Singapore' + interval '1 hour',
          'completed', svc_x, now() - interval '200 days');

  -- 6 rebooked, mature appointments: 5 x SVC_X, 1 x SVC_Y.
  for i in 1..6 loop
    cl := gen_random_uuid();
    appt := gen_random_uuid();
    svc := case when i <= 5 then svc_x else svc_y end;

    insert into public.clients (id, business_id, full_name)
    values (cl, biz, 'ZZ v700 rebooked client ' || i);

    insert into public.appointments
      (id, business_id, branch_id, client_id, staff_id, starts_at, ends_at, status, service_id, created_at)
    values (appt, biz, br1, cl, st_owner,
            (v_today - 90)::timestamp at time zone 'Asia/Singapore',
            (v_today - 90)::timestamp at time zone 'Asia/Singapore' + interval '1 hour',
            'completed', svc, now() - interval '95 days');

    perform public.link_rebooked_appointment_v1(biz, appt, appt_src);

    insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                               occurred_at, created_at, appointment_id)
    values (gen_random_uuid(), biz, br1, cl, 'service', 5000,
            (v_today - 90)::timestamp at time zone 'Asia/Singapore',
            (v_today - 90)::timestamp at time zone 'Asia/Singapore', appt);
  end loop;

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  g := public.get_ci_rebooking_v1(biz, v_from, v_to, null);

  if (g->'cohorts'->'rebooked_at_departure'->>'n')::int is distinct from 6 then
    insert into _fail values ('B-n', g->'cohorts'->'rebooked_at_departure'->>'n');
  end if;
  if not exists (
    select 1 from jsonb_array_elements(g->'cohorts'->'rebooked_at_departure'->'composition') e
     where (e->>'service_id')::uuid = svc_x
       and (e->'share'->>'numerator')::int = 5 and (e->'share'->>'denominator')::int = 6
       and (e->'share'->>'pct')::numeric = 83.3
  ) then
    insert into _fail values ('B-svc-x-share', g->'cohorts'->'rebooked_at_departure'->'composition');
  end if;
  if not exists (
    select 1 from jsonb_array_elements(g->'cohorts'->'rebooked_at_departure'->'composition') e
     where (e->>'service_id')::uuid = svc_y
       and (e->'share'->>'numerator')::int = 1 and (e->'share'->>'denominator')::int = 6
       and (e->'share'->>'pct') is null
  ) then
    insert into _fail values ('B-svc-y-share-not-null',
      g->'cohorts'->'rebooked_at_departure'->'composition');
  end if;

  if not (g ? 'generated_at' and g ? 'as_of' and g ? 'period' and g ? 'exclusions' and g ? 'trace_id') then
    insert into _fail values ('B-envelope-missing', g::text);
  end if;
  if not (g->'exclusions' ? 'reversed_sales' and g->'exclusions' ? 'synthetic_clients'
          and g->'exclusions' ? 'anonymous_sales' and g->'exclusions' ? 'missing_demographics'
          and g->'exclusions' ? 'overlapping_campaigns') then
    insert into _fail values ('B-exclusions-incomplete', g->'exclusions');
  end if;

end
$v700b$;

-- MUTATION (see the note on SECTION A's own mutation for why this is three DO blocks joined by
-- top-level savepoint commands rather than one).
savepoint sp_b;
do $v700b_mutate$
declare
  biz   uuid := '00000000-0000-4000-8000-000000700110';
  svc_y uuid := '00000000-0000-4000-8000-000000700113';
  v_from date := ((now() at time zone 'Asia/Singapore')::date) - 100;
  v_to   date := ((now() at time zone 'Asia/Singapore')::date) - 1;
  g         jsonb;
  v_def     text;
  v_mutated text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_rebooking_v1(uuid,date,date,uuid)')) into v_def;
  v_mutated := replace(v_def,
    $m3$'share', app.rate_block_floor_gated_v683(cm.n, c.n, app.subgroup_evidence_v1(cm.n::integer)))$m3$,
    $m4$'share', app.rate_block_v1(cm.n, c.n))$m4$);
  if v_mutated = v_def then
    insert into _fail values ('B-mutation-anchor-missing', 'could not find the composition share line to mutate');
  else
    execute v_mutated;
    g := public.get_ci_rebooking_v1(biz, v_from, v_to, null);
    if not exists (
      select 1 from jsonb_array_elements(g->'cohorts'->'rebooked_at_departure'->'composition') e
       where (e->>'service_id')::uuid = svc_y and (e->'share'->>'pct') is not null
    ) then
      insert into _fail values ('B-mutation-not-red',
        'mutated (ungated) function still returned a null pct for SVC_Y (n=1) -- this fixture cannot distinguish fixed from unfixed');
    end if;
  end if;
end
$v700b_mutate$;
rollback to savepoint sp_b;

do $v700b_sanity$
declare
  biz   uuid := '00000000-0000-4000-8000-000000700110';
  svc_y uuid := '00000000-0000-4000-8000-000000700113';
  v_from date := ((now() at time zone 'Asia/Singapore')::date) - 100;
  v_to   date := ((now() at time zone 'Asia/Singapore')::date) - 1;
  g jsonb;
begin
  g := public.get_ci_rebooking_v1(biz, v_from, v_to, null);
  if exists (
    select 1 from jsonb_array_elements(g->'cohorts'->'rebooked_at_departure'->'composition') e
     where (e->>'service_id')::uuid = svc_y and (e->'share'->>'pct') is not null
  ) then
    insert into _fail values ('B-restore-failed', 'fix was not restored after rollback to savepoint');
  end if;
end
$v700b_sanity$;

-- ============================================================================================
-- SECTION C — get_ci_loyalty_programmes_v1: participation floor (3a), synthetic exclusion (3b),
-- plus envelope
-- ============================================================================================
do $v700c$
declare
  u_sa       uuid := '00000000-0000-4000-8000-000000700001';
  biz_c1     uuid := '00000000-0000-4000-8000-000000700201';
  br_c1      uuid := '00000000-0000-4000-8000-000000700202';
  cl_c1      uuid := '00000000-0000-4000-8000-000000700203';
  biz_base   uuid := '00000000-0000-4000-8000-000000700210';
  br_base    uuid := '00000000-0000-4000-8000-000000700211';
  cl_real1   uuid := '00000000-0000-4000-8000-000000700212';
  biz_synth  uuid := '00000000-0000-4000-8000-000000700220';
  br_synth   uuid := '00000000-0000-4000-8000-000000700221';
  cl_real2   uuid := '00000000-0000-4000-8000-000000700222';
  cl_synth   uuid := '00000000-0000-4000-8000-000000700223';
  v_today    date := (now() at time zone 'Asia/Singapore')::date;
  v_from     date;
  v_to       date;
  g          jsonb;
  g_base     jsonb;
  g_synth    jsonb;
  v_def      text;
  v_mutated  text;
begin
  v_from := v_today - 100; v_to := v_today - 1;

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  -- --- C1: participation floor (eligible=1) ---
  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz_c1, 'ZZ v700 loyalty floor', 'zz-v700-loyalty-floor',
          array['dashboard','clients','sales','reports','loyalty']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (br_c1, biz_c1, 'ZZ v700 loyalty floor branch', true, true);
  insert into public.clients (id, business_id, full_name) values (cl_c1, biz_c1, 'ZZ v700 C1 client');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz_c1, br_c1, cl_c1, 'service', 5000,
          (v_today - 50)::timestamp at time zone 'Asia/Singapore',
          (v_today - 50)::timestamp at time zone 'Asia/Singapore');

  g := public.get_ci_loyalty_programmes_v1(biz_c1, v_from, v_to, null);

  if (g->>'eligible_customers')::int is distinct from 1 then
    insert into _fail values ('C1-eligible', g->>'eligible_customers');
  end if;
  if (g->'programmes'->'points'->>'status') is distinct from 'ready' then
    insert into _fail values ('C1-points-status', g->'programmes'->'points'->>'status');
  end if;
  if (g->'programmes'->'points'->'participation'->>'numerator')::int is distinct from 0
     or (g->'programmes'->'points'->'participation'->>'denominator')::int is distinct from 1 then
    insert into _fail values ('C1-participation-counts', g->'programmes'->'points'->'participation');
  end if;
  if (g->'programmes'->'points'->'participation'->>'pct') is not null then
    insert into _fail values ('C1-participation-pct-not-null',
      'eligible=1 is below the floor of 5 -- participation.pct must be null');
  end if;

  if not (g ? 'generated_at' and g ? 'as_of' and g ? 'period' and g ? 'exclusions' and g ? 'trace_id') then
    insert into _fail values ('C1-envelope-missing', g::text);
  end if;
  if not (g->'exclusions' ? 'reversed_sales' and g->'exclusions' ? 'synthetic_clients'
          and g->'exclusions' ? 'anonymous_sales' and g->'exclusions' ? 'missing_demographics'
          and g->'exclusions' ? 'overlapping_campaigns') then
    insert into _fail values ('C1-exclusions-incomplete', g->'exclusions');
  end if;

  -- --- C2/C3: twin businesses, synthetic exclusion ---
  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz_base, 'ZZ v700 loyalty twin BASE', 'zz-v700-loyalty-base',
          array['dashboard','clients','sales','reports','loyalty']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (br_base, biz_base, 'ZZ v700 loyalty base branch', true, true);
  call zz_v700_seed_reporting_contract(biz_base, br_base);
  insert into public.clients (id, business_id, full_name) values (cl_real1, biz_base, 'ZZ v700 real client (base)');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (gen_random_uuid(), biz_base, br_base, cl_real1, 'service', 5000,
     (v_today - 95)::timestamp at time zone 'Asia/Singapore', (v_today - 95)::timestamp at time zone 'Asia/Singapore'),
    (gen_random_uuid(), biz_base, br_base, cl_real1, 'service', 5000,
     (v_today - 30)::timestamp at time zone 'Asia/Singapore', (v_today - 30)::timestamp at time zone 'Asia/Singapore');
  insert into public.loyalty_redemptions
    (business_id, client_id, reward_name, points_spent, credit_cents, consumes_balance, fulfillment_kind, redeemed_at, reward_snapshot)
  values (biz_base, cl_real1, 'ZZ v700 base reward', 50, 0, true, 'manual_item',
          (v_today - 40)::timestamp at time zone 'Asia/Singapore', jsonb_build_object('x', 1));
  insert into public.referrals (business_id, referrer_client_id, status, qualified_at)
  values (biz_base, cl_real1, 'rewarded', (v_today - 40)::timestamp at time zone 'Asia/Singapore');

  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz_synth, 'ZZ v700 loyalty twin SYNTH', 'zz-v700-loyalty-synth',
          array['dashboard','clients','sales','reports','loyalty']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (br_synth, biz_synth, 'ZZ v700 loyalty synth branch', true, true);
  call zz_v700_seed_reporting_contract(biz_synth, br_synth);
  insert into public.clients (id, business_id, full_name) values (cl_real2, biz_synth, 'ZZ v700 real client (synth twin)');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (gen_random_uuid(), biz_synth, br_synth, cl_real2, 'service', 5000,
     (v_today - 95)::timestamp at time zone 'Asia/Singapore', (v_today - 95)::timestamp at time zone 'Asia/Singapore'),
    (gen_random_uuid(), biz_synth, br_synth, cl_real2, 'service', 5000,
     (v_today - 30)::timestamp at time zone 'Asia/Singapore', (v_today - 30)::timestamp at time zone 'Asia/Singapore');
  insert into public.loyalty_redemptions
    (business_id, client_id, reward_name, points_spent, credit_cents, consumes_balance, fulfillment_kind, redeemed_at, reward_snapshot)
  values (biz_synth, cl_real2, 'ZZ v700 synth-twin reward', 50, 0, true, 'manual_item',
          (v_today - 40)::timestamp at time zone 'Asia/Singapore', jsonb_build_object('x', 1));
  insert into public.referrals (business_id, referrer_client_id, status, qualified_at)
  values (biz_synth, cl_real2, 'rewarded', (v_today - 40)::timestamp at time zone 'Asia/Singapore');

  -- The extra synthetic client, biz_synth ONLY: its own points redemption + rewarded referral +
  -- subsequent paid-return sale, all timed identically to the real client's.
  insert into public.clients (id, business_id, full_name, is_synthetic)
  values (cl_synth, biz_synth, 'ZZ v700 synthetic client', true);
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz_synth, br_synth, cl_synth, 'service', 5000,
          (v_today - 30)::timestamp at time zone 'Asia/Singapore', (v_today - 30)::timestamp at time zone 'Asia/Singapore');
  insert into public.loyalty_redemptions
    (business_id, client_id, reward_name, points_spent, credit_cents, consumes_balance, fulfillment_kind, redeemed_at, reward_snapshot)
  values (biz_synth, cl_synth, 'ZZ v700 synthetic reward', 50, 0, true, 'manual_item',
          (v_today - 40)::timestamp at time zone 'Asia/Singapore', jsonb_build_object('x', 1));
  insert into public.referrals (business_id, referrer_client_id, status, qualified_at)
  values (biz_synth, cl_synth, 'rewarded', (v_today - 40)::timestamp at time zone 'Asia/Singapore');

  g_base := public.get_ci_loyalty_programmes_v1(biz_base, v_from, v_to, null);
  g_synth := public.get_ci_loyalty_programmes_v1(biz_synth, v_from, v_to, null);

  if (g_base->'programmes'->'points'->'redemptions') is distinct from (g_synth->'programmes'->'points'->'redemptions') then
    insert into _fail values ('C-points-redemptions-differ',
      format('base=%s synth=%s', g_base->'programmes'->'points'->'redemptions', g_synth->'programmes'->'points'->'redemptions'));
  end if;
  if (g_base->'programmes'->'points'->'immature') is distinct from (g_synth->'programmes'->'points'->'immature') then
    insert into _fail values ('C-points-immature-differ', 'synthetic client leaked into immature count');
  end if;
  if (g_base->'programmes'->'points'->'paid_return_within_30d') is distinct from (g_synth->'programmes'->'points'->'paid_return_within_30d') then
    insert into _fail values ('C-points-paid-return-differ',
      format('base=%s synth=%s', g_base->'programmes'->'points'->'paid_return_within_30d', g_synth->'programmes'->'points'->'paid_return_within_30d'));
  end if;
  if (g_base->'programmes'->'points'->'cannibalisation_proxy') is distinct from (g_synth->'programmes'->'points'->'cannibalisation_proxy') then
    insert into _fail values ('C-points-cannibalisation-differ',
      format('base=%s synth=%s', g_base->'programmes'->'points'->'cannibalisation_proxy', g_synth->'programmes'->'points'->'cannibalisation_proxy'));
  end if;

  if (g_base->'programmes'->'referral'->'redemptions') is distinct from (g_synth->'programmes'->'referral'->'redemptions') then
    insert into _fail values ('C-referral-redemptions-differ',
      format('base=%s synth=%s', g_base->'programmes'->'referral'->'redemptions', g_synth->'programmes'->'referral'->'redemptions'));
  end if;
  if (g_base->'programmes'->'referral'->'paid_return_within_30d') is distinct from (g_synth->'programmes'->'referral'->'paid_return_within_30d') then
    insert into _fail values ('C-referral-paid-return-differ',
      format('base=%s synth=%s', g_base->'programmes'->'referral'->'paid_return_within_30d', g_synth->'programmes'->'referral'->'paid_return_within_30d'));
  end if;
  if (g_base->'programmes'->'referral'->'cannibalisation_proxy') is distinct from (g_synth->'programmes'->'referral'->'cannibalisation_proxy') then
    insert into _fail values ('C-referral-cannibalisation-differ',
      format('base=%s synth=%s', g_base->'programmes'->'referral'->'cannibalisation_proxy', g_synth->'programmes'->'referral'->'cannibalisation_proxy'));
  end if;

  -- The real client's own redemption must actually be counted (equality alone would also pass
  -- if BOTH sides were wrongly zero) — assert redemptions_total = 1 on each side explicitly.
  if (g_base->'programmes'->'points'->'redemptions')::int is distinct from 1
     or (g_synth->'programmes'->'points'->'redemptions')::int is distinct from 1 then
    insert into _fail values ('C-points-redemptions-not-one',
      format('base=%s synth=%s', g_base->'programmes'->'points'->'redemptions', g_synth->'programmes'->'points'->'redemptions'));
  end if;
  if (g_base->'programmes'->'referral'->'redemptions')::int is distinct from 1
     or (g_synth->'programmes'->'referral'->'redemptions')::int is distinct from 1 then
    insert into _fail values ('C-referral-redemptions-not-one',
      format('base=%s synth=%s', g_base->'programmes'->'referral'->'redemptions', g_synth->'programmes'->'referral'->'redemptions'));
  end if;

  -- exclusions.synthetic_clients: biz_synth's own SALES include the synthetic client's
  -- subsequent-sale row within the window, so this count is a real, non-trivial 1 for biz_synth
  -- and 0 for biz_base -- the envelope's exclusion count is doing real work here, not decoration.
  if (g_synth->'exclusions'->>'synthetic_clients')::bigint is distinct from 1 then
    insert into _fail values ('C-synth-exclusions-count', g_synth->'exclusions'->>'synthetic_clients');
  end if;
  if (g_base->'exclusions'->>'synthetic_clients')::bigint is distinct from 0 then
    insert into _fail values ('C-base-exclusions-count', g_base->'exclusions'->>'synthetic_clients');
  end if;

  if not (g_base ? 'generated_at' and g_base ? 'as_of' and g_base ? 'period' and g_base ? 'exclusions' and g_base ? 'trace_id') then
    insert into _fail values ('C-base-envelope-missing', g_base::text);
  end if;
  if not (g_synth ? 'generated_at' and g_synth ? 'as_of' and g_synth ? 'period' and g_synth ? 'exclusions' and g_synth ? 'trace_id') then
    insert into _fail values ('C-synth-envelope-missing', g_synth::text);
  end if;

end
$v700c$;

-- MUTATION (see the note on SECTION A's own mutation for why this is three DO blocks joined by
-- top-level savepoint commands rather than one): revert the points-programme events query to
-- its pre-v700 shape (no join, no is_synthetic exclusion). Re-running both twins must now make
-- them DISAGREE.
savepoint sp_c;
do $v700c_mutate$
declare
  biz_base  uuid := '00000000-0000-4000-8000-000000700210';
  biz_synth uuid := '00000000-0000-4000-8000-000000700220';
  v_from date := ((now() at time zone 'Asia/Singapore')::date) - 100;
  v_to   date := ((now() at time zone 'Asia/Singapore')::date) - 1;
  g_base    jsonb;
  g_synth   jsonb;
  v_def     text;
  v_mutated text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid)')) into v_def;
  v_mutated := replace(v_def,
    $m5$    select coalesce(jsonb_agg(jsonb_build_object('client_id', lr.client_id, 'at', lr.redeemed_at)), '[]'::jsonb)
      into v_events
      from public.loyalty_redemptions lr
      join public.clients c on c.id = lr.client_id
     where lr.business_id = p_business
       and coalesce(lr.consumes_balance, true)
       and not coalesce(c.is_synthetic, false)
       and (lr.redeemed_at at time zone 'Asia/Singapore')::date between p_from and p_to;$m5$,
    $m6$    select coalesce(jsonb_agg(jsonb_build_object('client_id', lr.client_id, 'at', lr.redeemed_at)), '[]'::jsonb)
      into v_events
      from public.loyalty_redemptions lr
     where lr.business_id = p_business
       and coalesce(lr.consumes_balance, true)
       and (lr.redeemed_at at time zone 'Asia/Singapore')::date between p_from and p_to;$m6$);
  if v_mutated = v_def then
    insert into _fail values ('C-mutation-anchor-missing', 'could not find the points events query to mutate');
  else
    execute v_mutated;
    g_base := public.get_ci_loyalty_programmes_v1(biz_base, v_from, v_to, null);
    g_synth := public.get_ci_loyalty_programmes_v1(biz_synth, v_from, v_to, null);
    if (g_base->'programmes'->'points'->'redemptions') is not distinct from (g_synth->'programmes'->'points'->'redemptions') then
      insert into _fail values ('C-mutation-not-red',
        format('mutated (unfiltered) function still agreed: base=%s synth=%s -- this fixture cannot distinguish fixed from unfixed',
          g_base->'programmes'->'points'->'redemptions', g_synth->'programmes'->'points'->'redemptions'));
    end if;
    if (g_synth->'programmes'->'points'->'redemptions')::int is distinct from 2 then
      insert into _fail values ('C-mutation-wrong-inflation',
        format('expected the mutated synth business to inflate to 2 redemptions, got %s',
          g_synth->'programmes'->'points'->'redemptions'));
    end if;
  end if;
end
$v700c_mutate$;
rollback to savepoint sp_c;

do $v700c_sanity$
declare
  biz_base  uuid := '00000000-0000-4000-8000-000000700210';
  biz_synth uuid := '00000000-0000-4000-8000-000000700220';
  v_from date := ((now() at time zone 'Asia/Singapore')::date) - 100;
  v_to   date := ((now() at time zone 'Asia/Singapore')::date) - 1;
  g_base  jsonb;
  g_synth jsonb;
begin
  g_base := public.get_ci_loyalty_programmes_v1(biz_base, v_from, v_to, null);
  g_synth := public.get_ci_loyalty_programmes_v1(biz_synth, v_from, v_to, null);
  if (g_base->'programmes'->'points'->'redemptions') is distinct from (g_synth->'programmes'->'points'->'redemptions') then
    insert into _fail values ('C-restore-failed', 'fix was not restored after rollback to savepoint');
  end if;
end
$v700c_sanity$;

select case when count(*)=0 then 'PASS — v700 behavioural hardening holds' else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v700: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
