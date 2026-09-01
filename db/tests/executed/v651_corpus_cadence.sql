-- EXECUTED acceptance fixture for nestly_v651 — the canonical cadence authority.
--
-- WHY. v651 (db/migrations/20260831_nestly_v651_canonical_cadence.sql) consolidated three
-- independent "median inter-purchase interval x multiplier" implementations behind two
-- functions: app.customer_cadence_batch_v1 (the extracted computation) and
-- app.customer_cadence_v1 (the per-customer, policy-resolved answer — jsonb, security definer,
-- granted service_role only). This fixture proves the consumer-facing app.customer_cadence_v1
-- behaves exactly as documented, with a PREDETERMINED truth table, not `> 0` spot checks.
--
-- Named v651 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- AUTH CONTEXT. app.customer_cadence_v1 never calls auth.uid() / auth.jwt() anywhere in its
-- body (confirmed by reading the migration) — it takes p_business/p_client as plain arguments
-- and reads public.customer_lifecycle_policies_v107 + app.customer_cadence_batch_v1 directly.
-- No RLS-relevant membership or operational-workspace check exists in this function at all, so
-- no request.jwt.claims impersonation is needed to exercise it; the harness's superuser role
-- can call it directly (it is SECURITY DEFINER, granted only to service_role, but grants don't
-- restrict a superuser). The one real prerequisite is a customer_lifecycle_policies_v107 row,
-- which is auto-seeded by trg_customer_lifecycle_policy_v107_business_insert
-- (app.v107_seed_business_policy) on every `insert into public.businesses` with EXACTLY
-- fallback_lapse_days=90, customer_interval_min_observations=3, reactivation_multiplier=2.000
-- (read verbatim from db/migrations/20260729_nestly_v107_customer_lifecycle_contract.sql:75-84)
-- — this fixture relies on that seeded row rather than inserting its own, and the truth table
-- below is computed against exactly those three numbers.
--
-- VISIT ELIGIBILITY. A sale counts as an interval-eligible visit only if:
--   reversal_of is null, counts_as_visit, created_at <= p_as_of, and
--   app.v106_sale_residual_minor(...) > 0 as of the residual horizon.
-- counts_as_visit is NOT settable on insert — trigger app.on_sale_policy_snapshot overwrites it
-- from app.sale_policy(business_id, kind); kind='service' resolves to counts_as_visit=true with
-- no sale_policies override row (db/migrations/20260717_frenly_v10_sale_policy.sql:111-122), so
-- every sale below uses kind='service' and no sale_policies row is seeded.
--
-- TIME BASE. p_as_of is pinned to midnight Singapore time on the current test date (v_as_of
-- below), and every occurred_at is midnight-SGT on a (current_date - N) date. This makes every
-- gap and every "days ago" figure an exact integer number of 86400-second days — no
-- floating/time-of-day slop, so the truth table below holds exactly regardless of the wall-clock
-- time the harness happens to run at.
--
-- ============================================================================================
-- TRUTH TABLE (all offsets are days before v_as_of = midnight SGT, current_date)
-- ============================================================================================
-- C1 client_median   visits at [40,33,25,16,6] ago -> gaps [7,8,9,10]
--                     interval_observations = 4 (visits - 1)
--                     median_interval_days  = percentile_cont(0.5) of {7,8,9,10} = 8.5
--                       (n=4, interpolated between the 2nd and 3rd order stats: (8+9)/2)
--
-- C2 client_A        visits at [54,47,39,30,20] ago -> gaps [7,8,9,10], median 8.5, obs=4
--                     last visit 20 days ago. policy multiplier=2.0 -> effective_lapse=17.0
--                     20 > 17.0  => deviation_state = 'overdue'
-- C2 client_B        visits at [250,200,145,85,20] ago -> gaps [50,55,60,65], median 57.5, obs=4
--                     last visit 20 days ago (IDENTICAL absence to client_A).
--                     effective_lapse = 57.5*2.0 = 115.0; 20 <= 115 => not overdue.
--                     expected_next_from = last_visit + 57.5*0.75d = +43.125d; 20 < 43.125
--                       => deviation_state = 'within_cycle'
--                     HEADLINE ASSERTION: identical elapsed absence, opposite risk classification,
--                     because each customer is judged against their OWN rhythm.
--
-- C3 client_due      visits at [38,28,18,8] ago -> gaps [10,10,10], median 10.0, obs=3
--                     (obs=3 exactly clears the seeded min_observations=3 gate)
--                     last visit 8 days ago. effective_lapse = 10*2.0 = 20.0 (not overdue)
--                     expected_next_from = +7.5d, expected_next_to = +12.5d
--                     8 >= 7.5 and 8 <= 12.5 => deviation_state = 'due'
--                     (contrasted directly against client_A's 'overdue' from the SAME run)
--
-- C4 (reuses client_due) expected_next_from/_to must be a RANGE, not a single date, and must
--                     equal last_visit_at + 7.5 days / + 12.5 days exactly, bracketing the
--                     median-interval point (last_visit_at + 10 days) strictly inside the range.
--
-- C5 client_median   (from C1) has obs=4 >= gate 3 => evidence_source = 'customer_median_interval'
--    client_thin      visits at [20,5] ago -> one gap of 15 days, obs=1 < gate 3
--                     => evidence_source = 'business_fallback' (real single interval exists,
--                        just not trusted below the gate — median_interval_days is still 15.0,
--                        which is correct: the number is genuine, just distrusted)
--
-- C6 client_single   ONE visit only, 5 days ago -> ZERO gaps -> interval_observations = 0,
--                     median_interval_days must be NULL (no interval exists to compute a median
--                     from). evidence_source = 'business_fallback' (obs 0 < gate 3).
--    client_zero      NO sales at all -> status = 'insufficient', evidence_source = 'none',
--                     interval_observations = 0 (the correctly-documented empty shape, shown
--                     for contrast with client_single).
-- ============================================================================================

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v651$
declare
  biz            uuid := '00000000-0000-4000-8000-000000651001';
  branch         uuid := '00000000-0000-4000-8000-000000651011';
  cl_median      uuid := '00000000-0000-4000-8000-000000651101';
  cl_a           uuid := '00000000-0000-4000-8000-000000651102';
  cl_b           uuid := '00000000-0000-4000-8000-000000651103';
  cl_due         uuid := '00000000-0000-4000-8000-000000651104';
  cl_thin        uuid := '00000000-0000-4000-8000-000000651105';
  cl_single      uuid := '00000000-0000-4000-8000-000000651106';
  cl_zero        uuid := '00000000-0000-4000-8000-000000651107';
  v_as_of        timestamptz := (current_date)::timestamp at time zone 'Asia/Singapore';
  g              jsonb;
  v_err          text;
begin
  ---------------------------------------------------------------------------
  -- fixture business + branch (auto-seeds customer_lifecycle_policies_v107:
  -- fallback_lapse_days=90, customer_interval_min_observations=3,
  -- reactivation_multiplier=2.000 — verified against the trigger body, not assumed)
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v651 cadence fixture', 'zz-v651-cadence', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (branch, biz, 'ZZ v651 branch', true, true);

  -- v106 LANDMINE (found while building this fixture, not a v651 defect): the branch-insert
  -- trigger app.v106_append_reporting_contract() dates a BRAND NEW branch's first reporting
  -- contract from transaction_timestamp() (i.e. "now", this test's begin), never '-infinity' —
  -- that legacy backdating only applies to branches that existed at v106's own migration time.
  -- app.customer_cadence_batch_v1's "eligible" CTE does `cross join lateral
  -- app.v106_reporting_contract(...)`, an inner join: a sale whose occurred_at predates its
  -- branch's contract effective_from is silently dropped from eligibility, with no error. Every
  -- visit in this fixture is deliberately backdated (real cadence history), so a fresh branch's
  -- "contract starts now" row would silently exclude every one of them. A real production branch
  -- never hits this — it has existed since before any of its sales occurred. Work around it here
  -- the same way v106 itself backdates pre-existing branches: add an explicit early-dated
  -- contract version for this branch.
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, branch, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore',
         upper(b.currency), true
    from public.businesses b where b.id = biz;

  -- PRECONDITION: the auto-seed must have produced exactly the policy this truth table assumes.
  if not exists (
    select 1 from public.customer_lifecycle_policies_v107 p
     where p.business_id = biz
       and p.fallback_lapse_days = 90
       and p.customer_interval_min_observations = 3
       and p.reactivation_multiplier = 2.000
  ) then
    insert into _fail values ('PRE-policy',
      'auto-seeded customer_lifecycle_policies_v107 row does not match the documented defaults '
      '(90 / 3 / 2.000); the whole truth table below is computed against those numbers');
  end if;

  ---------------------------------------------------------------------------
  -- customers
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name) values
    (cl_median, biz, 'ZZ v651 median'),
    (cl_a,      biz, 'ZZ v651 rhythm A (7-10d)'),
    (cl_b,      biz, 'ZZ v651 rhythm B (50-65d)'),
    (cl_due,    biz, 'ZZ v651 due-not-overdue'),
    (cl_thin,   biz, 'ZZ v651 thin history'),
    (cl_single, biz, 'ZZ v651 single visit'),
    (cl_zero,   biz, 'ZZ v651 zero visits');

  -- created_at is pinned to occurred_at (rather than left at its clock_timestamp() default).
  -- Both app.customer_cadence_batch_v1's "eligible" CTE and app.v106_sale_residual_minor gate
  -- on `s.created_at <= p_as_of`, and v_as_of above is pinned to MIDNIGHT SGT today — which is
  -- earlier than "right now" real wall-clock time on every run. A sale left at its real
  -- clock_timestamp() default (this instant, always after today's midnight) would fail that
  -- gate and be silently dropped from eligibility no matter how far in the past its occurred_at
  -- is. This is a fixture-timing trap, not a v651 defect: a real sale's created_at is set at
  -- the moment it happened, so this situation cannot arise for a genuine past visit outside a
  -- test that pins occurred_at to the past while created_at defaults to the actual present.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl_median, 'service', 1000,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from unnest(array[40,33,25,16,6]) as o;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl_a, 'service', 1000,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from unnest(array[54,47,39,30,20]) as o;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl_b, 'service', 1000,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from unnest(array[250,200,145,85,20]) as o;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl_due, 'service', 1000,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from unnest(array[38,28,18,8]) as o;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl_thin, 'service', 1000,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from unnest(array[20,5]) as o;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl_single, 'service', 1000,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from unnest(array[5]) as o;
  -- cl_zero gets no sales at all.

  ---------------------------------------------------------------------------
  -- C1 — median interval IS the median, and observations = gaps, not visits.
  ---------------------------------------------------------------------------
  begin
    g := app.customer_cadence_v1(biz, cl_median, v_as_of);
    if g->>'status' <> 'ready' then
      insert into _fail values ('C1-pre', format('status=%s, expected ready', g->>'status'));
    end if;
    if (g->>'interval_observations')::int <> 4 then
      insert into _fail values ('C1',
        format('interval_observations=%s, expected 4 (5 visits - 1, not 5)', g->>'interval_observations'));
    end if;
    if (g->>'median_interval_days')::numeric <> 8.5 then
      insert into _fail values ('C1',
        format('median_interval_days=%s, expected 8.5 (median of {7,8,9,10})', g->>'median_interval_days'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('C1', format('customer_cadence_v1 raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- C2 — the headline A/B risk ordering: identical absence, own-rhythm-relative risk.
  ---------------------------------------------------------------------------
  begin
    g := app.customer_cadence_v1(biz, cl_a, v_as_of);
    if g->>'status' <> 'ready' then
      insert into _fail values ('C2-pre-a', format('status=%s, expected ready', g->>'status'));
    end if;
    if g->>'evidence_source' <> 'customer_median_interval' then
      insert into _fail values ('C2-pre-a',
        format('client_A evidence_source=%s, expected customer_median_interval (obs=4 clears gate 3)',
               g->>'evidence_source'));
    end if;
    if g->>'deviation_state' <> 'overdue' then
      insert into _fail values ('C2',
        format('client_A (7-10d rhythm, 20d absent, effective_lapse=17.0) deviation_state=%s, expected overdue',
               g->>'deviation_state'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('C2', format('customer_cadence_v1(client_A) raised %s', v_err));
  end;

  begin
    g := app.customer_cadence_v1(biz, cl_b, v_as_of);
    if g->>'status' <> 'ready' then
      insert into _fail values ('C2-pre-b', format('status=%s, expected ready', g->>'status'));
    end if;
    if g->>'evidence_source' <> 'customer_median_interval' then
      insert into _fail values ('C2-pre-b',
        format('client_B evidence_source=%s, expected customer_median_interval (obs=4 clears gate 3)',
               g->>'evidence_source'));
    end if;
    if g->>'deviation_state' <> 'within_cycle' then
      insert into _fail values ('C2',
        format('client_B (50-65d rhythm, 20d absent, effective_lapse=115.0) deviation_state=%s, '
               'expected within_cycle — IDENTICAL 20-day absence to client_A must NOT read as risk '
               'when it sits inside this customer''s own, slower rhythm', g->>'deviation_state'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('C2', format('customer_cadence_v1(client_B) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- C3 — overdue vs approaching/due are different states.
  ---------------------------------------------------------------------------
  begin
    g := app.customer_cadence_v1(biz, cl_due, v_as_of);
    if g->>'status' <> 'ready' then
      insert into _fail values ('C3-pre', format('status=%s, expected ready', g->>'status'));
    end if;
    if (g->>'interval_observations')::int <> 3 then
      insert into _fail values ('C3-pre',
        format('interval_observations=%s, expected 3 (at the gate, must still clear it)',
               g->>'interval_observations'));
    end if;
    if g->>'deviation_state' <> 'due' then
      insert into _fail values ('C3',
        format('client_due (median 10d, 8d absent, window 7.5-12.5d) deviation_state=%s, expected due',
               g->>'deviation_state'));
    end if;
    if g->>'deviation_state' = 'overdue' then
      insert into _fail values ('C3',
        'client_due was classified overdue — indistinguishable from a genuinely overdue customer');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('C3', format('customer_cadence_v1(client_due) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- C4 — expected-next-visit is a WINDOW, not a single date, and it brackets the
  --      customer's own median rhythm (reuses client_due: median 10d, last visit 8d ago).
  ---------------------------------------------------------------------------
  begin
    g := app.customer_cadence_v1(biz, cl_due, v_as_of);
    if g->'expected_next_from' is null or g->'expected_next_to' is null then
      insert into _fail values ('C4',
        'client_due (above the observations gate) got a null expected_next_from/_to window');
    elsif (g->>'expected_next_from')::timestamptz = (g->>'expected_next_to')::timestamptz then
      insert into _fail values ('C4',
        'expected_next_from equals expected_next_to — a single date, not a window');
    else
      if (g->>'expected_next_from')::timestamptz <>
         (g->>'last_visit_at')::timestamptz + interval '7.5 days' then
        insert into _fail values ('C4',
          format('expected_next_from=%s, expected last_visit_at + 7.5 days = %s',
                 g->>'expected_next_from',
                 ((g->>'last_visit_at')::timestamptz + interval '7.5 days')));
      end if;
      if (g->>'expected_next_to')::timestamptz <>
         (g->>'last_visit_at')::timestamptz + interval '12.5 days' then
        insert into _fail values ('C4',
          format('expected_next_to=%s, expected last_visit_at + 12.5 days = %s',
                 g->>'expected_next_to',
                 ((g->>'last_visit_at')::timestamptz + interval '12.5 days')));
      end if;
      -- the median-interval point itself must sit strictly inside the window
      if not ( (g->>'last_visit_at')::timestamptz + interval '10 days'
                 > (g->>'expected_next_from')::timestamptz
               and (g->>'last_visit_at')::timestamptz + interval '10 days'
                 < (g->>'expected_next_to')::timestamptz ) then
        insert into _fail values ('C4',
          'the median-rhythm point (last_visit + median_interval_days) does not fall inside '
          'the returned expected_next_from/_to window');
      end if;
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('C4', format('customer_cadence_v1(client_due) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- C5 — evidence source is named: per-customer rhythm above the gate, business
  --      fallback below it (client_thin has ONE real 15-day gap, just not enough
  --      observations to be trusted as the customer's rhythm).
  ---------------------------------------------------------------------------
  begin
    g := app.customer_cadence_v1(biz, cl_median, v_as_of);
    if g->>'evidence_source' <> 'customer_median_interval' then
      insert into _fail values ('C5',
        format('client_median (obs=4, gate=3) evidence_source=%s, expected customer_median_interval',
               g->>'evidence_source'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('C5', format('customer_cadence_v1(client_median) raised %s', v_err));
  end;

  begin
    g := app.customer_cadence_v1(biz, cl_thin, v_as_of);
    if g->>'status' <> 'ready' then
      insert into _fail values ('C5-pre', format('status=%s, expected ready', g->>'status'));
    end if;
    if (g->>'interval_observations')::int <> 1 then
      insert into _fail values ('C5-pre',
        format('client_thin interval_observations=%s, expected 1 (one gap, below gate 3)',
               g->>'interval_observations'));
    end if;
    if g->>'evidence_source' <> 'business_fallback' then
      insert into _fail values ('C5',
        format('client_thin (obs=1, gate=3) evidence_source=%s, expected business_fallback',
               g->>'evidence_source'));
    end if;
    if (g->>'effective_lapse_days')::numeric <> 90 then
      insert into _fail values ('C5',
        format('client_thin effective_lapse_days=%s, expected the fallback_lapse_days policy value 90',
               g->>'effective_lapse_days'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('C5', format('customer_cadence_v1(client_thin) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- C6 — abstention on thin history. client_single has exactly ONE visit: zero
  -- intervals exist, so no median can honestly be computed. client_zero has NO
  -- visits at all, shown for contrast against the documented empty shape.
  ---------------------------------------------------------------------------
  begin
    g := app.customer_cadence_v1(biz, cl_zero, v_as_of);
    if g->>'status' <> 'insufficient' then
      insert into _fail values ('C6-zero',
        format('client_zero (no sales at all) status=%s, expected insufficient', g->>'status'));
    end if;
    if g->>'evidence_source' <> 'none' then
      insert into _fail values ('C6-zero',
        format('client_zero evidence_source=%s, expected none', g->>'evidence_source'));
    end if;
    if coalesce((g->>'interval_observations')::int, -1) <> 0 then
      insert into _fail values ('C6-zero',
        format('client_zero interval_observations=%s, expected 0', g->>'interval_observations'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('C6-zero', format('customer_cadence_v1(client_zero) raised %s', v_err));
  end;

  begin
    g := app.customer_cadence_v1(biz, cl_single, v_as_of);
    if g->>'status' <> 'ready' then
      insert into _fail values ('C6-pre',
        format('client_single status=%s (expected ready — one visit is not zero visits)', g->>'status'));
    end if;
    if (g->>'interval_observations')::int <> 0 then
      insert into _fail values ('C6-pre',
        format('client_single interval_observations=%s, expected 0 (one visit has no interval)',
               g->>'interval_observations'));
    end if;
    -- THE ASSERTION THAT MATTERS: with zero interval observations there is no gap to compute a
    -- median FROM. A returned numeric median here would be fabricated, not measured.
    if (g->'median_interval_days') is distinct from 'null'::jsonb then
      insert into _fail values ('C6',
        format('client_single (0 interval observations, 1 visit) returned median_interval_days=%s '
               'instead of null — this looks like a real defect: app.customer_cadence_v1 does '
               '"round(coalesce(v_row.median_interval_days, 0)::numeric, 1)" (v651 line ~170), so a '
               'customer with a single visit and literally zero measured intervals is handed a '
               'plausible-looking "0.0 days between visits" figure. That reads as "this customer '
               'visits every day" to any consumer of the payload, which is the opposite of the '
               'truth (no rhythm is known at all). evidence_source correctly says business_fallback, '
               'but the median field does not honestly reflect "no data" the way it does for the '
               'true zero-visit case (client_zero, which correctly returns status=insufficient and '
               'no median field at all).', g->>'median_interval_days'));
    end if;
    if g->>'evidence_source' <> 'business_fallback' then
      insert into _fail values ('C6',
        format('client_single evidence_source=%s, expected business_fallback (0 obs < gate 3)',
               g->>'evidence_source'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('C6', format('customer_cadence_v1(client_single) raised %s', v_err));
  end;
end
$v651$;

select case when count(*)=0
            then 'PASS — v651 canonical cadence: median math, own-rhythm risk ordering, '
                 'due/overdue distinction, window shape, evidence source, thin-history abstention'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v651: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
