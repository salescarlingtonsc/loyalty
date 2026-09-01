-- EXECUTED regression fixture for nestly_v106 — revenue-truth contract of
-- public.get_revenue_truth_v106 (db/migrations/20260729_nestly_v106_revenue_truth_foundation.sql).
--
-- Named v106 because it proves behaviour at or below the v422 snapshot watermark: it must
-- pass in BOTH the baseline and migrated phases of the harness (scripts/db-tests/run.mjs).
--
-- WHY THESE SIX. get_revenue_truth_v106's own header states the reporting contract in prose
-- ("total = identified + anonymous", "a zero denominator produces NULL", refund cutoff by
-- business date, etc). This fixture turns each clause into a predetermined-number assertion
-- instead of trusting the prose:
--   R1  identified_revenue + anonymous_revenue == known_revenue EXACTLY, and both transaction
--       counts sum to the total.
--   R2  a full native reversal (sales.reversal_of) nets its pair to exactly 0, and does not
--       touch an unrelated sale in the same window.
--   R3  a refund reconciled OUTSIDE the report window (business_date >= p_to) must not reduce
--       the in-window figure — proven both ways: excluded when p_to stays before the refund,
--       and included (revenue drops to 0) once p_to is widened past it, so the exclusion is
--       shown to be real and not an accidental "refunds never apply" bug.
--   R4  a $0 sale that counts as a visit adds 0 to revenue and is excluded from
--       completed_transactions, while remaining tagged counts_as_visit=true — i.e. the ledger
--       still counts it as a visit even though v106 does not count it as a transaction.
--   R5  a package purchase (kind='package', revenue booked upfront per
--       app.sale_policy_defaults()) plus three $0 session-consumption sales books revenue
--       exactly once; the sessions add nothing.
--   R6  the coverage block exposes a numerator AND a denominator (identified_transactions /
--       completed_transactions, identified_revenue_minor / known_revenue_minor), and the
--       published percentage is exactly numerator/denominator on the seeded numbers — reusing
--       R1's business, so R6 needs no fixture of its own.
--
-- FIXTURE-TIMING TRAP (found while writing this file, not in the guide): the v106 migration's
-- own AFTER INSERT trigger (trg_v106_business_reporting_contract_insert /
-- trg_v106_branch_reporting_contract_insert) stamps effective_from = transaction_timestamp()
-- on the contract row it creates for a freshly-inserted business/branch. app.v106_reporting_
-- contract() requires effective_from <= occurred_at. A fixture that seeds sales dated in the
-- PAST (the natural instinct — "5 days ago") gets ZERO matching contract rows, so the
-- cross-join-lateral in get_revenue_truth_v106 silently drops every such sale from the
-- "eligible" set: every revenue figure reads back as 0, which LOOKS like a passing R4/R5
-- assertion (zero-value sales "correctly" contributing 0) for the wrong reason. All dates
-- below are therefore in the FUTURE relative to the fixture's own transaction start, so they
-- postdate the auto-created contract's effective_from and are genuinely evaluated.
--
-- THE DEFECT THIS FILE FOUND, AND ITS FIX (kept in full, because the reasoning is the evidence).
-- Everything from here to the truth table was written when the defect was still open and all six
-- assertions were red. It is now CLOSED by db/migrations/20260901_nestly_v668_complete_v523_
-- entitlement.sql, which removes the customerintel short-circuit from
-- app.effective_platform_module_mode_v94 and so completes the owner ruling nestly_v523 recorded
-- on 2026-08-26. The only fixture change that accompanied the fix is that this business now
-- lists 'customerintel' in its enabled_modules — which is what v573's gate asks for, and which
-- an operating firm entitled to Reports genuinely holds (nestly_v171 appends customerintel to
-- every published bundle carrying 'reports'). The expected numbers below are untouched.
--
-- ORIGINAL REPORT (found while writing this file, reported not bent around — see
-- "Rules that decide whether this is worth anything" in the task). db/migrations/20260828_
-- nestly_v573_module_off_reaches_the_rpcs.sql added `and app.can_module(p_business,
-- 'customerintel')` to get_revenue_truth_v106's authorization gate, alongside get_customer_
-- intelligence_v83 and friends. But app.effective_platform_module_mode_v94 (v94/v620)
-- unconditionally returns 'disabled' for the 'customerintel' module for EVERY caller — that is
-- the mechanism that makes Customer Intelligence platform/consulting-only (see db/tests/
-- executed/v666_ci_access_boundaries.sql B1). app.staff_module_mode_v94 checks that platform
-- mode BEFORE it ever looks at staff.role, so v573's own safety argument ("role='owner' returns
-- the platform mode so owners always pass") is false for this one module: the function returns
-- 'disabled' before the owner branch is reached. get_revenue_truth_v106 is NOT a Customer
-- Intelligence RPC — nestly_v523's own commit note says its known_revenue figure "is the same
-- number the Dashboard, Business Insights and P&L accrual tile show" — so gating it on
-- 'customerintel' makes it unreachable by ANY firm role (owner, manager, bookkeeper), not just
-- by an unentitled one. Verified directly against the migrated database (peekaa_migrated):
-- an owner with app.has_perm(biz,'view_finance')=true and a fully operational workspace gets
-- 42501 'finance permission required'; the identical call under a super-admin session (with the
-- v625 Google-SSO claim shape) succeeds. R1/R2/R4/R5/R6 below call get_revenue_truth_v106 as
-- the OWNER, because that is the RPC's own documented caller (baseline/pre-v573 behaviour, and
-- the only caller that makes "Dashboard/P&L truth" a coherent claim) — so they were EXPECTED to
-- keep failing in the MIGRATED phase until the hard-disable was corrected. This file does not
-- route around it by calling as a super admin: doing so would hide the regression instead of
-- proving it. v668 corrected the resolver rather than v573's gate, so the gate still means what
-- it says — an unentitled firm is still refused — and an entitled one is now served.
--
-- TRUTH TABLE (all amounts in cents; window bounds are half-open dates [p_from, p_to)):
--   R1  window [D+1, D+4). Identified: 3 x 5000 = 15000. Anonymous: 2 x 2500 = 5000.
--       known_revenue = 20000 = 15000 + 5000. completed_transactions = 5 = 3 identified + 2
--       anonymous.
--   R2  window [D+5, D+8). sale_rev 7300, its full reversal -7300 -> net 0, excluded from
--       completed_transactions. sale_other 4444, untouched. known_revenue = 4444,
--       completed_transactions = 1.
--   R3  window [D+9, D+12). sale_r3 6100 at D+10. Refund event -6100 reconciled with
--       business_date D+13 (>= window end D+12, i.e. outside the window).
--         R3a  same window (p_to = D+12): refund excluded -> residual/known_revenue = 6100.
--         R3b  window widened to p_to = D+14 (now includes D+13): refund applies ->
--              residual/known_revenue = 0.
--   R4  window [D+15, D+17). One $0 sale at D+16, counts_as_revenue=true,
--       counts_as_visit=true. known_revenue = 0, completed_transactions = 0, but the row
--       itself still reads counts_as_visit = true.
--   R5  window [D+18, D+22). One package sale 12000 at D+19 (kind='package'). Three $0
--       session-consumption sales (kind='service') at D+20/D+20/D+21. known_revenue = 12000,
--       completed_transactions = 1.
--   R6  reuses R1's payload. identified_transactions=3, completed_transactions=5 ->
--       identity_transaction_pct = round(100*3/5, 2) = 60.00. identified_revenue_minor=15000,
--       known_revenue_minor=20000 -> identity_revenue_pct = round(100*15000/20000, 2) = 75.00.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v106$
declare
  biz        uuid := '00000000-0000-4000-8000-000000010601';
  br         uuid := '00000000-0000-4000-8000-000000010611';
  u_owner    uuid := '00000000-0000-4000-8000-000000010602';
  cl_r1      uuid := '00000000-0000-4000-8000-000000010701';
  d          date := current_date;

  -- R1
  s_r1_id1   uuid := '00000000-0000-4000-8000-000000010801';
  s_r1_id2   uuid := '00000000-0000-4000-8000-000000010802';
  s_r1_id3   uuid := '00000000-0000-4000-8000-000000010803';
  s_r1_an1   uuid := '00000000-0000-4000-8000-000000010804';
  s_r1_an2   uuid := '00000000-0000-4000-8000-000000010805';
  g1         jsonb;

  -- R2
  s_r2_rev   uuid := '00000000-0000-4000-8000-000000010811';
  s_r2_rvsl  uuid := '00000000-0000-4000-8000-000000010812';
  s_r2_other uuid := '00000000-0000-4000-8000-000000010813';
  g2         jsonb;

  -- R3
  s_r3       uuid := '00000000-0000-4000-8000-000000010821';
  ev_r3      uuid;
  recon_r3   jsonb;
  g3a        jsonb;
  g3b        jsonb;
  resid_a    bigint;

  -- R4
  s_r4       uuid := '00000000-0000-4000-8000-000000010831';
  g4         jsonb;
  v_visit    boolean;

  -- R5
  s_r5_pkg   uuid := '00000000-0000-4000-8000-000000010841';
  s_r5_sess1 uuid := '00000000-0000-4000-8000-000000010842';
  s_r5_sess2 uuid := '00000000-0000-4000-8000-000000010843';
  s_r5_sess3 uuid := '00000000-0000-4000-8000-000000010844';
  g5         jsonb;

  v_err      text;
  v_defect_hint text;
begin
  ---------------------------------------------------------------------------
  -- actor + operational business (full recipe from docs/qa/CI-CORPUS-FIXTURE-GUIDE.md,
  -- "Making a business genuinely operational" — miss any one row and every read below
  -- refuses for a billing/approval reason, not a revenue-truth reason).
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_owner, 'zz-v106-owner@example.test')
    on conflict (id) do nothing;

  /* 'customerintel' is listed because v573 gates get_revenue_truth_v106 on it, and because a
     firm entitled to 'reports' genuinely carries it: nestly_v171 appended customerintel to every
     published sector bundle that contains 'reports' and resynced every business. Before v668 the
     entitlement bought nothing (the resolver short-circuited it to 'disabled' for every caller),
     which is the defect described above; listing it is what makes the six assertions below a
     test of revenue-truth arithmetic rather than a test of a hard-disabled module. */
  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v106 revenue truth', 'zz-v106-revenue-truth',
          array['dashboard','clients','sales','reports','customerintel']);

  insert into public.branches (id, business_id, name, is_default, active)
  values (br, biz, 'ZZ v106 branch', true, true);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values (biz, u_owner, 'owner', 'ZZ v106 owner', true, 'approved');

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v106 revenue-truth fixture')
    on conflict (business_id) do update
      set approval_status='approved', decided_at=now(),
          decision_reason='v106 revenue-truth fixture';

  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;

  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.clients (id, business_id, full_name)
  values (cl_r1, biz, 'ZZ v106 Identified Client');

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role','authenticated')::text, true);

  -- PRECONDITION. Every read below is meaningless if the owner does not genuinely hold
  -- view_finance on this business — a refusal-shaped failure downstream would look like a
  -- product defect while actually being a fixture defect.
  if not app.has_perm(biz, 'view_finance') then
    insert into _fail values ('PRE',
      'fixture owner lacks view_finance; every get_revenue_truth_v106 call below is vacuous');
    return;
  end if;

  -- Diagnostic only (does not gate anything): if a get_revenue_truth_v106 call below raises
  -- 42501 while this is true, the owner genuinely holds view_finance and the workspace is open
  -- — the refusal is coming from the 'customerintel' can_module leg specifically. Post-v668 that
  -- combination should be impossible for this business, because it now carries the module in
  -- enabled_modules; if it reappears, the resolver has been short-circuited again rather than
  -- the fixture being under-built.
  if app.has_perm(biz, 'view_finance') and not app.can_module(biz, 'customerintel') then
    v_defect_hint := ' -- diagnosed: has_perm(view_finance)=true, can_module(customerintel)=false '
      || 'even though this business lists customerintel in enabled_modules; that is the v523/v668 '
      || '"customerintel is globally hard-disabled" defect returning, not a fixture problem';
  else
    v_defect_hint := '';
  end if;

  ---------------------------------------------------------------------------
  -- R1 — identified + anonymous reconcile exactly.
  -- Identified: 3 x 5000 = 15000.  Anonymous: 2 x 2500 = 5000.  known = 20000.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  values
    (s_r1_id1, biz, br, cl_r1, 'service', 5000, d+2, true, true, true, d+2, 0, d+2),
    (s_r1_id2, biz, br, cl_r1, 'service', 5000, d+2, true, true, true, d+2, 0, d+2),
    (s_r1_id3, biz, br, cl_r1, 'service', 5000, d+2, true, true, true, d+2, 0, d+2),
    (s_r1_an1, biz, br, null,  'service', 2500, d+2, true, true, true, d+2, 0, d+2),
    (s_r1_an2, biz, br, null,  'service', 2500, d+2, true, true, true, d+2, 0, d+2);

  begin
    g1 := public.get_revenue_truth_v106(biz, d+1, d+4, br);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('R1', format('get_revenue_truth_v106 raised %s%s', v_err, v_defect_hint));
  end;

  if g1 is not null then
    if (g1#>>'{totals,known_revenue_minor}')::bigint <> 20000 then
      insert into _fail values ('R1', format('known_revenue_minor was %s, expected 20000',
        g1#>>'{totals,known_revenue_minor}'));
    end if;
    if (g1#>>'{totals,identified_revenue_minor}')::bigint <> 15000 then
      insert into _fail values ('R1', format('identified_revenue_minor was %s, expected 15000',
        g1#>>'{totals,identified_revenue_minor}'));
    end if;
    if (g1#>>'{totals,anonymous_revenue_minor}')::bigint <> 5000 then
      insert into _fail values ('R1', format('anonymous_revenue_minor was %s, expected 5000',
        g1#>>'{totals,anonymous_revenue_minor}'));
    end if;
    if (g1#>>'{totals,identified_revenue_minor}')::bigint
       + (g1#>>'{totals,anonymous_revenue_minor}')::bigint
       <> (g1#>>'{totals,known_revenue_minor}')::bigint then
      insert into _fail values ('R1',
        'identified_revenue_minor + anonymous_revenue_minor did not equal known_revenue_minor');
    end if;
    if (g1#>>'{totals,identified_transactions}')::bigint <> 3 then
      insert into _fail values ('R1', format('identified_transactions was %s, expected 3',
        g1#>>'{totals,identified_transactions}'));
    end if;
    if (g1#>>'{totals,anonymous_transactions}')::bigint <> 2 then
      insert into _fail values ('R1', format('anonymous_transactions was %s, expected 2',
        g1#>>'{totals,anonymous_transactions}'));
    end if;
    if (g1#>>'{totals,identified_transactions}')::bigint
       + (g1#>>'{totals,anonymous_transactions}')::bigint
       <> (g1#>>'{totals,completed_transactions}')::bigint then
      insert into _fail values ('R1',
        'identified_transactions + anonymous_transactions did not equal completed_transactions');
    end if;
    if (g1#>>'{totals,completed_transactions}')::bigint <> 5 then
      insert into _fail values ('R1', format('completed_transactions was %s, expected 5',
        g1#>>'{totals,completed_transactions}'));
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- R2 — full reversal nets to zero, and does not touch an unrelated sale.
  -- sale_rev 7300 + full reversal -7300 -> 0.  sale_other 4444 untouched.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  values
    (s_r2_rev,   biz, br, null, 'service', 7300, d+6, true, true,  true, d+6, 0, d+6),
    (s_r2_other, biz, br, null, 'service', 4444, d+6, true, true,  true, d+6, 0, d+6);

  -- The reversal-insert guard (v20) only accepts a reversal row through this token, which is
  -- how public.reverse_sale() gates direct writes; the fixture opens the same door the RPC
  -- uses rather than re-implementing the whole financial engine just to prove v106's math.
  perform set_config('app.sale_reversal_insert_id', s_r2_rvsl::text, true);
  perform set_config('app.sale_reversal_original_id', s_r2_rev::text, true);
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at,
    reversal_of, reversal_reason, reversal_actor, reversal_idempotency_key)
  values
    (s_r2_rvsl, biz, br, null, 'service', -7300, d+6, true, false, false, d+6, 0, d+6,
     s_r2_rev, 'v106 fixture full reversal test', u_owner, 'v106-r2-reversal-1');
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);

  if app.v106_sale_residual_minor(s_r2_rev, (d+8)::date, clock_timestamp()) <> 0 then
    insert into _fail values ('R2', format(
      'reversed sale residual was %s, expected exactly 0',
      app.v106_sale_residual_minor(s_r2_rev, (d+8)::date, clock_timestamp())));
  end if;

  begin
    g2 := public.get_revenue_truth_v106(biz, d+5, d+8, br);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('R2', format('get_revenue_truth_v106 raised %s%s', v_err, v_defect_hint));
  end;

  if g2 is not null then
    if (g2#>>'{totals,known_revenue_minor}')::bigint <> 4444 then
      insert into _fail values ('R2', format(
        'window known_revenue_minor was %s, expected 4444 (reversed pair should contribute 0, '
        'unrelated sale should still show)', g2#>>'{totals,known_revenue_minor}'));
    end if;
    if (g2#>>'{totals,completed_transactions}')::bigint <> 1 then
      insert into _fail values ('R2', format(
        'window completed_transactions was %s, expected 1 (only the unrelated sale)',
        g2#>>'{totals,completed_transactions}'));
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- R3 — a refund reconciled OUTSIDE the report window must not reduce the in-window figure.
  -- sale_r3 6100 at D+10.  Refund event business_date D+13.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  values
    (s_r3, biz, br, null, 'service', 6100, d+10, true, true, true, d+10, 0, d+10);

  begin
    declare v_ingest jsonb;
    begin
      v_ingest := public.ingest_external_commerce_event_v106(
        biz, br, 'refund_completed', 'zz_v106_pos', 'v106-r3-refund-1',
        'v106-r3-idem-1', (d+13)::timestamp at time zone 'Asia/Singapore',
        'SGD', -6100, '{}'::jsonb
      );
      if v_ingest->>'status' <> 'accepted' then
        insert into _fail values ('R3-pre',
          format('external refund event was not accepted: %s', v_ingest));
      end if;
      ev_r3 := (v_ingest->>'event_id')::uuid;
    end;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('R3-pre', format('ingest_external_commerce_event_v106 raised %s', v_err));
  end;

  if ev_r3 is not null then
    begin
      recon_r3 := public.reconcile_external_commerce_event_v106(
        ev_r3, s_r3, 'v106-r3-recon-1',
        jsonb_build_array(jsonb_build_object('amount_minor', 6100))
      );
      if recon_r3->>'status' <> 'reconciled' then
        insert into _fail values ('R3-pre',
          format('external refund reconciliation did not succeed: %s', recon_r3));
      end if;
    exception when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('R3-pre',
        format('reconcile_external_commerce_event_v106 raised %s', v_err));
    end;
  end if;

  -- R3a: window ends BEFORE the refund's business date (D+12 <= D+13) -> refund excluded.
  resid_a := app.v106_sale_residual_minor(s_r3, (d+12)::date, clock_timestamp());
  if resid_a <> 6100 then
    insert into _fail values ('R3a', format(
      'residual with p_to=D+12 was %s, expected 6100 (refund dated D+13 is outside the window '
      'and must not apply)', resid_a));
  end if;

  begin
    g3a := public.get_revenue_truth_v106(biz, d+9, d+12, br);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('R3a', format('get_revenue_truth_v106 raised %s%s', v_err, v_defect_hint));
  end;
  if g3a is not null and (g3a#>>'{totals,known_revenue_minor}')::bigint <> 6100 then
    insert into _fail values ('R3a', format(
      'report known_revenue_minor was %s, expected 6100 (out-of-window refund must not reduce it)',
      g3a#>>'{totals,known_revenue_minor}'));
  end if;

  -- R3b: window widened to include the refund's business date (D+13 < D+14) -> refund applies.
  -- This is the control: it proves the R3a exclusion is a real date comparison, not a bug that
  -- always ignores refunds (which would also have produced 6100 in R3a).
  resid_a := app.v106_sale_residual_minor(s_r3, (d+14)::date, clock_timestamp());
  if resid_a <> 0 then
    insert into _fail values ('R3b', format(
      'residual with p_to=D+14 was %s, expected exactly 0 (refund is now inside the window)',
      resid_a));
  end if;

  begin
    g3b := public.get_revenue_truth_v106(biz, d+9, d+14, br);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('R3b', format('get_revenue_truth_v106 raised %s%s', v_err, v_defect_hint));
  end;
  if g3b is not null and (g3b#>>'{totals,known_revenue_minor}')::bigint <> 0 then
    insert into _fail values ('R3b', format(
      'report known_revenue_minor was %s, expected exactly 0 once the refund is in-window',
      g3b#>>'{totals,known_revenue_minor}'));
  end if;

  ---------------------------------------------------------------------------
  -- R4 — a $0 visit sale adds 0 to revenue but is still tagged as a visit.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  values
    (s_r4, biz, br, cl_r1, 'service', 0, d+16, true, true, false, d+16, 0, d+16);

  begin
    g4 := public.get_revenue_truth_v106(biz, d+15, d+17, br);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('R4', format('get_revenue_truth_v106 raised %s%s', v_err, v_defect_hint));
  end;
  if g4 is not null then
    if (g4#>>'{totals,known_revenue_minor}')::bigint <> 0 then
      insert into _fail values ('R4', format('known_revenue_minor was %s, expected 0',
        g4#>>'{totals,known_revenue_minor}'));
    end if;
    if (g4#>>'{totals,completed_transactions}')::bigint <> 0 then
      insert into _fail values ('R4', format(
        'completed_transactions was %s, expected 0 (a $0 row is not a revenue transaction)',
        g4#>>'{totals,completed_transactions}'));
    end if;
  end if;

  select s.counts_as_visit into v_visit from public.sales s where s.id = s_r4;
  if v_visit is distinct from true then
    insert into _fail values ('R4',
      'the $0 sale no longer reads counts_as_visit=true; it would be silently dropped from '
      'whatever downstream logic counts visits (retention windows read this same column)');
  end if;

  ---------------------------------------------------------------------------
  -- R5 — package revenue is booked once; session consumption adds nothing.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  values
    (s_r5_pkg,   biz, br, cl_r1, 'package', 12000, d+19, true, false, true,  d+19, 0, d+19),
    (s_r5_sess1, biz, br, cl_r1, 'service',     0, d+20, true, false, false, d+20, 0, d+20),
    (s_r5_sess2, biz, br, cl_r1, 'service',     0, d+20, true, false, false, d+20, 0, d+20),
    (s_r5_sess3, biz, br, cl_r1, 'service',     0, d+21, true, false, false, d+21, 0, d+21);

  begin
    g5 := public.get_revenue_truth_v106(biz, d+18, d+22, br);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('R5', format('get_revenue_truth_v106 raised %s%s', v_err, v_defect_hint));
  end;
  if g5 is not null then
    if (g5#>>'{totals,known_revenue_minor}')::bigint <> 12000 then
      insert into _fail values ('R5', format(
        'known_revenue_minor was %s, expected 12000 (the package price, exactly once)',
        g5#>>'{totals,known_revenue_minor}'));
    end if;
    if (g5#>>'{totals,completed_transactions}')::bigint <> 1 then
      insert into _fail values ('R5', format(
        'completed_transactions was %s, expected 1 (the $0 sessions must not be counted)',
        g5#>>'{totals,completed_transactions}'));
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- R6 — coverage exposes a numerator and denominator, and the percentage matches them.
  -- Reuses R1's payload (g1): identified_transactions=3, completed_transactions=5,
  -- identified_revenue_minor=15000, known_revenue_minor=20000.
  ---------------------------------------------------------------------------
  if g1 is not null then
    if g1#>'{totals,identified_transactions}' is null or g1#>'{totals,completed_transactions}' is null then
      insert into _fail values ('R6',
        'payload does not expose identified_transactions/completed_transactions as raw counts');
    end if;
    if g1#>'{totals,identified_revenue_minor}' is null or g1#>'{totals,known_revenue_minor}' is null then
      insert into _fail values ('R6',
        'payload does not expose identified_revenue_minor/known_revenue_minor as raw counts');
    end if;
    if (g1#>>'{coverage,identity_transaction_pct}')::numeric <> 60.00 then
      insert into _fail values ('R6', format(
        'identity_transaction_pct was %s, expected 60.00 (= 100*3/5 on the seeded counts)',
        g1#>>'{coverage,identity_transaction_pct}'));
    end if;
    if (g1#>>'{coverage,identity_revenue_pct}')::numeric <> 75.00 then
      insert into _fail values ('R6', format(
        'identity_revenue_pct was %s, expected 75.00 (= 100*15000/20000 on the seeded amounts)',
        g1#>>'{coverage,identity_revenue_pct}'));
    end if;
  end if;

  perform set_config('request.jwt.claims', null, true);
end
$v106$;

select case when count(*)=0
            then 'PASS — v106 revenue truth: identity split, reversal, refund window, zero-'
                 'value visits, package-once, coverage numerator/denominator all hold'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v106: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
