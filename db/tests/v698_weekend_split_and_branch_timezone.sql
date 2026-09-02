-- EXECUTED acceptance fixture for nestly_v698 — weekday/weekend split in daypart (check 37) and
-- per-branch timezone through get_ci_daypart_v1 (check 8).
--
-- Named for v698 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md). Proves
-- db/migrations/20260902_nestly_v698_weekend_split_and_branch_timezone.sql.
--
-- AUTH CONTEXT. Same reasoning as db/tests/executed/v693_corpus_exclusions_verdicts.sql: a
-- super-admin session clears app.ci_access_gate_v667's platform arm outright, so this fixture
-- does not need a fully operational merchant workspace — it is not testing entitlement, v667's
-- own corpus already does that.
--
-- ===============================================================================================
-- SCENARIO A — weekend_split TRUTH TABLE (single branch, Asia/Singapore, check 37)
-- ===============================================================================================
--   Window [wa_from, wa_to] spans exactly one Wednesday (dow=3, weekday) and one Saturday
--   (dow=6, weekend), nothing else.
--     Weekday (Wednesday): 5 sales x 1000 cents = 5 visits, 5000 revenue_cents.
--       5 >= floor(5) -> evidence.status='ok' -> revenue_per_visit_cents = round(5000/5) = 1000.
--     Weekend (Saturday): 3 sales x 2000 cents = 3 visits, 6000 revenue_cents.
--       3 < floor(5) -> evidence.status='insufficient' -> revenue_per_visit_cents = null
--       (revenue_cents/visits themselves stay visible — only the derived rate is withheld).
--   Expected weekend_split:
--     {weekday:{visits:5, revenue_cents:5000, revenue_per_visit_cents:1000, evidence.status:'ok'},
--      weekend:{visits:3, revenue_cents:6000, revenue_per_visit_cents:null, evidence.status:'insufficient'},
--      evidence_class:'ASSOCIATION', difference_note: non-empty}
--
-- ===============================================================================================
-- SCENARIO B — per-branch timezone through get_ci_daypart_v1 (check 8)
-- ===============================================================================================
--   One business, three ACTIVE branches on three timezones:
--     br_sg  'Asia/Singapore'   (first branch -> billing_state='included' by the v665 trigger)
--     br_pt  'Australia/Perth'  (UTC+8, no DST -- SAME OFFSET as Asia/Singapore)
--     br_kol 'Asia/Kolkata'     (UTC+5:30)
--   br_pt and br_kol are the business's 2nd and 3rd branch -- the v665
--   app.assign_branch_billing_state_v665 trigger forces every branch after the first to
--   billing_state='pending_payment' AND active=false UNLESS the insert explicitly asks for
--   billing_state='active'. Both are inserted with billing_state='active' and the fixture
--   asserts .active=true on all three before trusting anything downstream (per the fixture
--   guide's "assert your preconditions" rule) -- this IS the "second-branch billing trap"
--   the task brief calls out, handled by asserting it rather than being silently defeated by it.
--
--   Firm-wide (p_branch=null): three DISTINCT timezone names among active branches ->
--     app.ci_bucket_tz_v698 resolves 'Asia/Singapore' / timezone_basis='mixed_branches_default'
--     (disclosed, not silently assumed).
--
--   Three sales on br_kol (UTC timestamps and their local conversions, computed before running
--   anything):
--     s1 2026-08-10 02:00:00 UTC -> SGT Mon 10:00 (hour 10, weekday) | IST Mon 07:30 (hour 7, weekday)
--     s2 2026-08-08 17:00:00 UTC -> SGT Sun 01:00 (hour 1, weekend)  | IST Sat 22:30 (hour 22, weekend)
--     s3 2026-08-09 17:00:00 UTC -> SGT Mon 01:00 (hour 1, weekday) | IST Sun 22:30 (hour 22, weekend)
--   s3 is the pivot: SAME sale, weekday under the firm-wide SG default, weekend under br_kol's
--   own clock -- "weekend_split moves" when the bucketing timezone changes, and is the fixture's
--   built-in mutation-sensitivity proof (a single input -- which timezone resolves -- flips the
--   verdict; get the branch-vs-firm-wide selection wrong and this assertion goes red).
--
--   Per-branch query (p_branch=br_kol, bucket_timezone='Asia/Kolkata', timezone_basis='branch'):
--   this window only ever sees br_kol's own three sales (branch-scoped), so:
--     weekday (Monday, s1 only): visits=1, revenue_cents=700.
--     weekend (Sat+Sun, s2+s3):  visits=2, revenue_cents=800+900=1700.
--
--   SAME-OFFSET PROOF ("prove no change"): s4 on br_pt and s5 on br_sg share the identical UTC
--   instant as s1 (2026-08-10 02:00:00 UTC, SGT Monday 10:00, weekday either way since Perth's
--   offset matches SG's). Because Australia/Perth and Asia/Singapore carry the identical +8
--   offset (neither observes DST), querying p_branch=br_pt and p_branch=br_sg must produce
--   byte-identical hour/dow/visits/revenue_cents for that sale -- proving the *numbers* are
--   unaffected by which of two same-offset zone NAMES resolved, even though bucket_timezone
--   itself differs.
--
--   Firm-wide query (p_branch=null, bucket_timezone='Asia/Singapore', timezone_basis='mixed_branches_default')
--   sums ACROSS all three branches within the same window, so it also picks up s4 and s5 (both
--   land Monday/weekday under the SG default, same as s1 and s3):
--     weekday (Monday, s1+s3+s4+s5): visits=4, revenue_cents=700+900+555+555=2710.
--     weekend (Sunday, s2 only):     visits=1, revenue_cents=800.

\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

do $v698$
declare
  u_sa uuid := '00000000-0000-4000-8000-000000698003';
  v_err text;

  -- Scenario A
  bizA uuid := '00000000-0000-4000-8000-000000698001';
  brA  uuid := '00000000-0000-4000-8000-000000698002';
  c_wd uuid;
  c_we uuid;
  wa_wed date; wa_sat date;
  wa_from date; wa_to date;
  r_a jsonb;
  ws jsonb;

  -- Scenario B
  bizB   uuid := '00000000-0000-4000-8000-000000698011';
  br_sg  uuid := '00000000-0000-4000-8000-000000698012';
  br_pt  uuid := '00000000-0000-4000-8000-000000698013';
  br_kol uuid := '00000000-0000-4000-8000-000000698014';
  c_kol uuid; c_pt uuid; c_sg uuid;
  wb_from date; wb_to date;
  r_kol jsonb; r_firm jsonb; r_pt jsonb; r_sg jsonb;
  tz_kol jsonb; tz_firm jsonb; tz_pt jsonb; tz_sg jsonb;
  h10_pt jsonb; h10_sg jsonb;
begin
  ---------------------------------------------------------------------------
  -- platform (super admin) session — see CI-CORPUS-FIXTURE-GUIDE.md
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values (u_sa, 'zz-v698-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v698-sa@example.test')
    on conflict do nothing;

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  begin
    perform app.ci_access_gate_v667(bizA, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PRE-gate-A',
      format('fixture super admin cannot pass app.ci_access_gate_v667 (sqlstate %s); every '
             'assertion below would be vacuous', v_err));
  end;

  ---------------------------------------------------------------------------
  -- SCENARIO A fixture
  ---------------------------------------------------------------------------
  c_wd := gen_random_uuid();
  c_we := gen_random_uuid();

  insert into public.businesses (id, name, slug, enabled_modules) values
    (bizA, 'ZZ v698 weekend-split fixture', 'zz-v698-weekend-split',
     array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active, timezone) values
    (brA, bizA, 'ZZ v698 branch A', true, true, 'Asia/Singapore');

  -- pin to a real Wednesday/Saturday pair, far enough in the past to be stable and isolated
  wa_wed := date_trunc('week', current_date - 400)::date + 2;  -- Wednesday
  wa_sat := wa_wed + 3;                                        -- Saturday, same week
  wa_from := wa_wed - 1;
  wa_to := wa_sat + 1;

  if extract(isodow from wa_wed)::int is distinct from 3 then
    insert into _fail values ('PRE-A-wed', 'expected Wednesday, got isodow ' || extract(isodow from wa_wed)::text);
  end if;
  if extract(isodow from wa_sat)::int is distinct from 6 then
    insert into _fail values ('PRE-A-sat', 'expected Saturday, got isodow ' || extract(isodow from wa_sat)::text);
  end if;

  insert into public.clients (id, business_id, full_name) values
    (c_wd, bizA, 'ZZ v698 weekday client'), (c_we, bizA, 'ZZ v698 weekend client');

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), bizA, brA, c_wd, 'service', 1000,
         (wa_wed::timestamp + (n || ' minute')::interval + time '09:00') at time zone 'Asia/Singapore',
         (wa_wed::timestamp + (n || ' minute')::interval + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(0, 4) as n;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), bizA, brA, c_we, 'service', 2000,
         (wa_sat::timestamp + (n || ' minute')::interval + time '11:00') at time zone 'Asia/Singapore',
         (wa_sat::timestamp + (n || ' minute')::interval + time '11:00') at time zone 'Asia/Singapore'
    from generate_series(0, 2) as n;

  r_a := public.get_ci_daypart_v1(bizA, wa_from, wa_to);
  ws := r_a->'weekend_split';

  if r_a->>'bucket_timezone' is distinct from 'Asia/Singapore' then
    insert into _fail values ('A-bucket-tz', coalesce(r_a->>'bucket_timezone','null'));
  end if;
  if r_a->>'timezone_basis' is distinct from 'firm_agreed' then
    insert into _fail values ('A-tz-basis', coalesce(r_a->>'timezone_basis','null'));
  end if;
  if ws is null then
    insert into _fail values ('A-ws-null', 'expected a weekend_split object');
  else
    if (ws->'weekday'->>'visits')::int is distinct from 5 then
      insert into _fail values ('A-weekday-visits', coalesce(ws->'weekday'->>'visits','null'));
    end if;
    if (ws->'weekday'->>'revenue_cents')::int is distinct from 5000 then
      insert into _fail values ('A-weekday-revenue', coalesce(ws->'weekday'->>'revenue_cents','null'));
    end if;
    if (ws->'weekday'->>'revenue_per_visit_cents')::int is distinct from 1000 then
      insert into _fail values ('A-weekday-rate', coalesce(ws->'weekday'->>'revenue_per_visit_cents','null'));
    end if;
    if ws->'weekday'->'evidence'->>'status' is distinct from 'ok' then
      insert into _fail values ('A-weekday-evidence', coalesce(ws->'weekday'->'evidence'->>'status','null'));
    end if;

    if (ws->'weekend'->>'visits')::int is distinct from 3 then
      insert into _fail values ('A-weekend-visits', coalesce(ws->'weekend'->>'visits','null'));
    end if;
    if (ws->'weekend'->>'revenue_cents')::int is distinct from 6000 then
      insert into _fail values ('A-weekend-revenue', coalesce(ws->'weekend'->>'revenue_cents','null'));
    end if;
    if ws->'weekend'->>'revenue_per_visit_cents' is not null then
      insert into _fail values ('A-weekend-rate-not-null',
        'below-floor weekend rate leaked: ' || (ws->'weekend'->>'revenue_per_visit_cents'));
    end if;
    if ws->'weekend'->'evidence'->>'status' is distinct from 'insufficient' then
      insert into _fail values ('A-weekend-evidence', coalesce(ws->'weekend'->'evidence'->>'status','null'));
    end if;

    if ws->>'evidence_class' is distinct from 'ASSOCIATION' then
      insert into _fail values ('A-evidence-class', coalesce(ws->>'evidence_class','null'));
    end if;
    if coalesce(length(ws->>'difference_note'), 0) = 0 then
      insert into _fail values ('A-note', 'expected a non-empty difference_note');
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- SCENARIO B fixture
  ---------------------------------------------------------------------------
  begin
    perform app.ci_access_gate_v667(bizB, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PRE-gate-B',
      format('fixture super admin cannot pass app.ci_access_gate_v667 for bizB (sqlstate %s)', v_err));
  end;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (bizB, 'ZZ v698 branch-timezone fixture', 'zz-v698-branch-tz',
     array['dashboard','clients','sales','reports']);

  -- first branch: born 'included', active by default
  insert into public.branches (id, business_id, name, is_default, active, timezone)
  values (br_sg, bizB, 'ZZ v698 branch SG', true, true, 'Asia/Singapore');

  -- second/third branches: the v665 trigger forces billing_state='pending_payment' + active=false
  -- unless billing_state='active' is explicitly requested. Requested here on purpose.
  insert into public.branches (id, business_id, name, is_default, active, timezone, billing_state)
  values (br_pt, bizB, 'ZZ v698 branch Perth', false, true, 'Australia/Perth', 'active');
  insert into public.branches (id, business_id, name, is_default, active, timezone, billing_state)
  values (br_kol, bizB, 'ZZ v698 branch Kolkata', false, true, 'Asia/Kolkata', 'active');

  -- PRECONDITION: the second-branch billing trap did not silently defeat this fixture.
  if not (select br.active from public.branches br where br.id = br_sg) then
    insert into _fail values ('PRE-B-sg-inactive', 'br_sg unexpectedly inactive');
  end if;
  if not (select br.active from public.branches br where br.id = br_pt) then
    insert into _fail values ('PRE-B-pt-inactive',
      'br_pt was forced inactive by the v665 second-branch billing trap — fixture did not set billing_state=active correctly');
  end if;
  if not (select br.active from public.branches br where br.id = br_kol) then
    insert into _fail values ('PRE-B-kol-inactive',
      'br_kol was forced inactive by the v665 second-branch billing trap — fixture did not set billing_state=active correctly');
  end if;
  if (select br.billing_state from public.branches br where br.id = br_sg) is distinct from 'included' then
    insert into _fail values ('PRE-B-sg-billing', coalesce((select br.billing_state from public.branches br where br.id = br_sg), 'null'));
  end if;

  c_kol := gen_random_uuid();
  c_pt := gen_random_uuid();
  c_sg := gen_random_uuid();
  insert into public.clients (id, business_id, full_name) values
    (c_kol, bizB, 'ZZ v698 client kol'),
    (c_pt, bizB, 'ZZ v698 client pt'),
    (c_sg, bizB, 'ZZ v698 client sg');

  wb_from := '2026-08-08'; wb_to := '2026-08-10';

  -- s1, s2, s3 on br_kol
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (gen_random_uuid(), bizB, br_kol, c_kol, 'service', 700, '2026-08-10 02:00:00+00', '2026-08-10 02:00:00+00'),
    (gen_random_uuid(), bizB, br_kol, c_kol, 'service', 800, '2026-08-08 17:00:00+00', '2026-08-08 17:00:00+00'),
    (gen_random_uuid(), bizB, br_kol, c_kol, 'service', 900, '2026-08-09 17:00:00+00', '2026-08-09 17:00:00+00');

  -- s4 on br_pt, s5 on br_sg — identical UTC instant to s1
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values
    (gen_random_uuid(), bizB, br_pt, c_pt, 'service', 555, '2026-08-10 02:00:00+00', '2026-08-10 02:00:00+00'),
    (gen_random_uuid(), bizB, br_sg, c_sg, 'service', 555, '2026-08-10 02:00:00+00', '2026-08-10 02:00:00+00');

  ---------------------------------------------------------------------------
  -- ASSERT: app.ci_bucket_tz_v698 resolution
  ---------------------------------------------------------------------------
  tz_kol := app.ci_bucket_tz_v698(bizB, br_kol);
  if tz_kol->>'timezone' is distinct from 'Asia/Kolkata' or tz_kol->>'timezone_basis' is distinct from 'branch' then
    insert into _fail values ('B-tz-kol', tz_kol::text);
  end if;

  tz_firm := app.ci_bucket_tz_v698(bizB, null);
  if tz_firm->>'timezone' is distinct from 'Asia/Singapore' or tz_firm->>'timezone_basis' is distinct from 'mixed_branches_default' then
    insert into _fail values ('B-tz-firm', tz_firm::text);
  end if;

  tz_pt := app.ci_bucket_tz_v698(bizB, br_pt);
  if tz_pt->>'timezone' is distinct from 'Australia/Perth' or tz_pt->>'timezone_basis' is distinct from 'branch' then
    insert into _fail values ('B-tz-pt', tz_pt::text);
  end if;

  tz_sg := app.ci_bucket_tz_v698(bizB, br_sg);
  if tz_sg->>'timezone' is distinct from 'Asia/Singapore' or tz_sg->>'timezone_basis' is distinct from 'branch' then
    insert into _fail values ('B-tz-sg', tz_sg::text);
  end if;

  ---------------------------------------------------------------------------
  -- ASSERT: per-branch (Kolkata) weekend_split vs firm-wide (mixed -> SG default) weekend_split
  ---------------------------------------------------------------------------
  r_kol := public.get_ci_daypart_v1(bizB, wb_from, wb_to, br_kol);
  if r_kol->>'bucket_timezone' is distinct from 'Asia/Kolkata' then
    insert into _fail values ('B-kol-bucket-tz', coalesce(r_kol->>'bucket_timezone','null'));
  end if;
  if r_kol->>'timezone_basis' is distinct from 'branch' then
    insert into _fail values ('B-kol-tz-basis', coalesce(r_kol->>'timezone_basis','null'));
  end if;
  if (r_kol->'weekend_split'->'weekday'->>'visits')::int is distinct from 1 then
    insert into _fail values ('B-kol-weekday-visits', coalesce(r_kol->'weekend_split'->'weekday'->>'visits','null'));
  end if;
  if (r_kol->'weekend_split'->'weekday'->>'revenue_cents')::int is distinct from 700 then
    insert into _fail values ('B-kol-weekday-revenue', coalesce(r_kol->'weekend_split'->'weekday'->>'revenue_cents','null'));
  end if;
  if (r_kol->'weekend_split'->'weekend'->>'visits')::int is distinct from 2 then
    insert into _fail values ('B-kol-weekend-visits', coalesce(r_kol->'weekend_split'->'weekend'->>'visits','null'));
  end if;
  if (r_kol->'weekend_split'->'weekend'->>'revenue_cents')::int is distinct from 1700 then
    insert into _fail values ('B-kol-weekend-revenue', coalesce(r_kol->'weekend_split'->'weekend'->>'revenue_cents','null'));
  end if;

  r_firm := public.get_ci_daypart_v1(bizB, wb_from, wb_to, null);
  if r_firm->>'bucket_timezone' is distinct from 'Asia/Singapore' then
    insert into _fail values ('B-firm-bucket-tz', coalesce(r_firm->>'bucket_timezone','null'));
  end if;
  if r_firm->>'timezone_basis' is distinct from 'mixed_branches_default' then
    insert into _fail values ('B-firm-tz-basis', coalesce(r_firm->>'timezone_basis','null'));
  end if;
  -- firm-wide sums across all three branches within the window, so it also picks up s4 (br_pt)
  -- and s5 (br_sg) -- both Monday/weekday under the SG default (see header truth table).
  if (r_firm->'weekend_split'->'weekday'->>'visits')::int is distinct from 4 then
    insert into _fail values ('B-firm-weekday-visits', coalesce(r_firm->'weekend_split'->'weekday'->>'visits','null'));
  end if;
  if (r_firm->'weekend_split'->'weekday'->>'revenue_cents')::int is distinct from 2710 then
    insert into _fail values ('B-firm-weekday-revenue', coalesce(r_firm->'weekend_split'->'weekday'->>'revenue_cents','null'));
  end if;
  if (r_firm->'weekend_split'->'weekend'->>'visits')::int is distinct from 1 then
    insert into _fail values ('B-firm-weekend-visits', coalesce(r_firm->'weekend_split'->'weekend'->>'visits','null'));
  end if;
  if (r_firm->'weekend_split'->'weekend'->>'revenue_cents')::int is distinct from 800 then
    insert into _fail values ('B-firm-weekend-revenue', coalesce(r_firm->'weekend_split'->'weekend'->>'revenue_cents','null'));
  end if;

  -- MUTATION PROOF: s3 (900 cents) is weekday under the firm default but weekend under br_kol's
  -- own clock, so br_kol's weekend bucket (s2+s3=2 visits) must NOT equal what it would be if s3
  -- stayed on the weekday side (1 visit, s2 alone). A single flip (which timezone resolves) moves
  -- s3 across the weekday/weekend line, so getting the branch-vs-firm-wide selection wrong turns
  -- this assertion red.
  if (r_kol->'weekend_split'->'weekend'->>'visits')::int is distinct from 2 then
    insert into _fail values ('B-mutation-no-movement',
      'expected s3 to land in br_kol''s weekend bucket (visits=2), proving the timezone actually '
      'used for bucketing came from the branch, not a fixed default — got '
      || coalesce(r_kol->'weekend_split'->'weekend'->>'visits','null'));
  end if;

  ---------------------------------------------------------------------------
  -- ASSERT: same-offset proof — Perth (branch) vs Singapore (branch) agree byte-for-byte on the
  -- hour-10 bucket for their identical-UTC-instant sales, despite different bucket_timezone names.
  ---------------------------------------------------------------------------
  r_pt := public.get_ci_daypart_v1(bizB, wb_from, wb_to, br_pt);
  r_sg := public.get_ci_daypart_v1(bizB, wb_from, wb_to, br_sg);

  if r_pt->>'bucket_timezone' is distinct from 'Australia/Perth' then
    insert into _fail values ('B-pt-bucket-tz', coalesce(r_pt->>'bucket_timezone','null'));
  end if;
  if r_sg->>'bucket_timezone' is distinct from 'Asia/Singapore' then
    insert into _fail values ('B-sg-bucket-tz', coalesce(r_sg->>'bucket_timezone','null'));
  end if;

  select h into h10_pt from jsonb_array_elements(r_pt->'hours') h where (h->>'hour')::int = 10;
  select h into h10_sg from jsonb_array_elements(r_sg->'hours') h where (h->>'hour')::int = 10;

  if h10_pt is null or h10_sg is null then
    insert into _fail values ('B-offset-missing', 'expected an hour-10 bucket in both br_pt and br_sg payloads');
  else
    if (h10_pt->>'visits')::int is distinct from 1 or (h10_sg->>'visits')::int is distinct from 1 then
      insert into _fail values ('B-offset-visits', format('pt=%s sg=%s', h10_pt->>'visits', h10_sg->>'visits'));
    end if;
    if (h10_pt->>'revenue_cents')::int is distinct from (h10_sg->>'revenue_cents')::int
       or (h10_pt->>'revenue_cents')::int is distinct from 555 then
      insert into _fail values ('B-offset-revenue', format('pt=%s sg=%s', h10_pt->>'revenue_cents', h10_sg->>'revenue_cents'));
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- VOCABULARY — no CAUSAL claim in either scenario's payload.
  ---------------------------------------------------------------------------
  if r_a::text like '%CAUSAL%' then
    insert into _fail values ('VOCAB-A', 'CAUSAL found in scenario A daypart payload');
  end if;
  if r_kol::text like '%CAUSAL%' or r_firm::text like '%CAUSAL%'
     or r_pt::text like '%CAUSAL%' or r_sg::text like '%CAUSAL%' then
    insert into _fail values ('VOCAB-B', 'CAUSAL found in scenario B daypart payload');
  end if;
end
$v698$;

select case when count(*) = 0
            then 'PASS — v698 weekend/weekday split truth table + per-branch daypart timezone'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v698: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
