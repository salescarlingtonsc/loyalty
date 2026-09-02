-- EXECUTED acceptance fixture for nestly_v718 — margin guard made live for service-bound
-- candidates (check 74) and a second, non-incentive alternative kind for discovery/change
-- (check 77). Check 23 is investigated and deliberately NOT changed by nestly_v718 (see that
-- migration's own header/body comment "CHECK 23 — INVESTIGATION AND DELIBERATE NON-FIX") — this
-- fixture therefore asserts NOTHING new about materiality_class 'minor'; that ground stays covered
-- by nestly_v705's own BIZ_MINOR section.
--
-- Above the v422 watermark: reported n/a in the BASELINE phase, gated on the MIGRATED run
-- (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- =================================================================================================
-- PREDETERMINED TRUTH TABLE (every number below computed before the first run)
-- =================================================================================================
--
-- A. app.ci_standard_incentive_cents_v718() = 4000 (cents), directly. This is the SAME worked
--    figure nestly_v705's own executed fixture already commits to for app.ci_margin_guard_v705
--    (db/tests/executed/v705_corpus_spine_v3.sql, section A: svc_costed price=5000/cost=2000, guard
--    called with 4000 -> blocked/margin=3000, called with 1000 -> ok/margin=3000).
--
-- B. BIZ_GW_BLOCKED (full spine): the SAME proven funnel recipe as nestly_v688's own BIZ1
--    (db/tests/executed/v688_corpus_spine_v2.sql) — F1..F20 first visit at d1, ALL 20 return at
--    d1+10, 18 of 20 return at d1+20 — fires gateway_followthrough:<svc_gw>. svc_gw here carries
--    price_cents=5000, cost_cents=2000 (margin=3000). Because app.ci_standard_incentive_cents_v718()
--    = 4000 > margin 3000, the per-candidate app.ci_margin_guard_v705(biz, svc_gw, 4000) call this
--    migration wires in resolves to status='blocked', margin_cents=3000, reason naming both 4000 and
--    3000 (the SAME text shape nestly_v705's own A1-blocked assertion already proves for the
--    function directly — this fixture proves it is actually WIRED IN through the live candidate/
--    alternative, which nestly_v705 itself could not, since no candidate supplied a real service_id
--    before this migration). Asserted: candidate.margin_guard.status='blocked', margin_cents=3000;
--    the alternatives[*] entry with kind='incentive' carries the IDENTICAL cost_basis object;
--    candidate.limitation contains the guard's own reason text (the demotion is visible); candidate
--    is STILL present in ranked (rank_class was already 'unquantified' by the generator's own
--    design — the guard's demotion clause writes the SAME value, so this is not itself evidence of
--    demotion; the limitation text is) — and, per nestly_v712's own generic invariant (still in
--    force, untouched by this migration), impact.margin equals margin_guard exactly.
--
-- C. BIZ_GW_NOCOST: the IDENTICAL funnel recipe, isolated business, svc_gw carries price_cents=5000
--    and NO cost_cents (null). app.ci_margin_guard_v705(biz, svc_gw, 4000) resolves to
--    status='unavailable', margin_cents=null, reason EXACTLY 'no cost recorded for this service;
--    enter costs in Settings' (nestly_v705's own A3-nocost reason, verbatim). Asserted:
--    candidate.margin_guard matches that shape; candidate.limitation does NOT contain the
--    "would exceed" blocked-reason wording (proving the demotion clause did NOT fire for
--    'unavailable', only for 'blocked' — the two branches are genuinely distinguished, not
--    collapsed).
--
-- D. BIZ_DISC_CHANGE (check 77): ONE business, ONE window, THREE first_acquired_via cohorts under
--    the SAME 'acquisition_source' dimension get_ci_discovery_v1 already scans. NOTE: public.
--    clients.first_acquired_via is NOT settable via a plain INSERT — a BEFORE INSERT trigger
--    (app.clients_first_acquisition_default_v629, nestly_v629) always overwrites it from the
--    session-local GUC app.first_acquired_via, defaulting every insert with that GUC unset (or set
--    to a value outside its own nine-value allowlist) to the SAME 'unknown' bucket — nestly_v688's
--    own BIZ3 fixture never sets this GUC, which is exactly why its acquisition_source discovery
--    assertion is conditional, not asserted outright (all of BIZ3's clients silently collapse to
--    one 'unknown' group, or at best 'referral' vs 'unknown', not the clean two/three-way split the
--    header prose implies). This fixture sets the GUC explicitly per cohort so all three land in
--    genuinely distinct groups:
--      referral (12 clients, GUC='referral'): returns within 30 days 100% of the time in BOTH
--        halves (the discovery side, nestly_v688's own BIZ3 return-rate shape).
--      "walk-in" (12 clients, GUC='walk_in_till', the closest valid allowlisted value): returns 0%
--        of the time in BOTH halves (the 'rest' side).
--      "ads" (8 clients, GUC='campaign', the closest valid allowlisted value — referred to as "ads"
--        in this fixture's own comments/variable names for readability, though the stored/grouped
--        value is 'campaign'): returns 100% of the time in the TRAIN half, 0% of the time in the
--        HOLDOUT half (the change/deteriorating side — a NEW cohort this fixture adds;
--        get_ci_discovery_v1's own "Step 6: deterioration" is UNCONDITIONAL on the BH/candidate
--        pipeline the discovery side needs — only a floor of 5 in EACH half and a >=10pp
--        train-vs-holdout drop with a non-zero-crossing CI — n=8 in each half clears the floor by a
--        comfortable margin and a clean 100%->0% split is the same shape nestly_v688's own
--        referral/rest split already proves clears the CI check).
--    Asserted UNCONDITIONALLY (Step 6 has no significance-pipeline gate to make this a coin flip):
--      the DIRECT reader (public.get_ci_discovery_v1) reports a 'deteriorating' entry with
--      dimension='acquisition_source', group='campaign', train_pct=100.0, holdout_pct=0.0.
--    Asserted CONDITIONALLY (same hedge as nestly_v688's own BIZ3, since the BH/confounder pipeline
--    that gates 'discoveries' — unlike Step 6 — is not hand-guaranteed the way a single group's own
--    train-vs-holdout rate is):
--      IF the engine ranks a domain='discovery' candidate for acquisition_source, its alternatives
--        array has length >=2 and contains a kind='operational_change' entry whose 'what' text
--        contains 'Investigate the driver behind acquisition_source=' and the discovered group's own
--        name.
--      IF the engine ranks 'change:acquisition_source:campaign' (evidence n=8>=floor(5) on both halves,
--        so this is expected to fire, not merely possible — asserted conditionally only because an
--        environment where subgroup_evidence_v1's floor itself changed underfoot would otherwise
--        turn an unrelated regression into a false failure here), its alternatives array has length
--        >=2 and contains a kind='operational_change' entry whose 'what' text is EXACTLY 'Review
--        what changed for acquisition_source in the window.'.
--
-- =================================================================================================
-- LANDMINES HANDLED (learned from docs/qa/CI-CORPUS-FIXTURE-GUIDE.md and the v678/v683/v688/v696/
-- v705/v712 fixtures; not re-discovered here)
-- =================================================================================================
--  * created_at pinned to occurred_at/purchased_at on every backdated row.
--  * counts_as_revenue / counts_as_visit are NEVER passed on insert — they are trigger-resolved.
--  * the operational recipe (workspace controls + subscription lifecycle + subscriptions +
--    reporting_contract_versions_v106 backdated) is required for every business that calls the full
--    public.get_ci_opportunities_v1 RPC (app.ci_standard_incentive_cents_v718 does NOT gate — it
--    takes no arguments at all — so section A skips this entirely).
--  * every assertion of a denial/abstention first checks the population it rests on is what this
--    fixture intends (the "assert your preconditions" rule).

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000718ee1', 'zz-v718-owner1@example.test'),
  ('00000000-0000-4000-8000-000000718ee2', 'zz-v718-owner2@example.test'),
  ('00000000-0000-4000-8000-000000718ee3', 'zz-v718-owner3@example.test'),
  ('00000000-0000-4000-8000-000000718eee', 'zz-v718-sa@example.test')
  on conflict (id) do nothing;
insert into public.super_admins (user_id, email) values
  ('00000000-0000-4000-8000-000000718eee', 'zz-v718-sa@example.test')
  on conflict do nothing;

select set_config('request.jwt.claims', json_build_object(
    'sub', '00000000-0000-4000-8000-000000718eee', 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google'))
  )::text, true);

-- =================================================================================================
-- A · app.ci_standard_incentive_cents_v718() — direct call, no gate.
-- =================================================================================================
do $v718a$
declare
  v_cents bigint;
begin
  v_cents := app.ci_standard_incentive_cents_v718();
  if v_cents <> 4000 then
    insert into _fail values ('A-constant', format('expected 4000, got %s', v_cents));
  end if;
end
$v718a$;

-- =================================================================================================
-- B · BIZ_GW_BLOCKED — gateway_followthrough with a costed service whose margin the standard
--     incentive figure exceeds.
-- =================================================================================================
do $v718b$
declare
  biz     uuid := '00000000-0000-4000-8000-000000718001';
  br      uuid := '00000000-0000-4000-8000-000000718011';
  u_owner uuid := '00000000-0000-4000-8000-000000718ee1';
  svc_gw  uuid := '00000000-0000-4000-8000-0000007180a1';
  d1      date := current_date - 200;
  as_of   timestamptz := ((d1 + 150)::timestamp + time '12:00') at time zone 'Asia/Singapore';
  g       jsonb;
  cand    jsonb;
  alt     jsonb;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v718 gw blocked', 'zz-v718-gw-blocked', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v718 gw blocked main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz, u_owner, 'owner', 'ZZ v718 gw blocked owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v718 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  -- svc_gw: price 5000 / cost 2000 -> margin 3000. The standard incentive (4000) exceeds it.
  insert into public.services (id, business_id, name, price_cents, duration_min, cost_cents) values
    (svc_gw, biz, 'ZZ v718 gateway service (blocked)', 5000, 30, 2000);

  -- SAME proven funnel shape as nestly_v688's own BIZ1: F1..F20 first visit at d1, ALL return at
  -- d1+10, 18 of 20 return at d1+20.
  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000718' || lpad((100+s)::text,3,'0'))::uuid,
         biz, 'ZZ v718 gwb funnel ' || s from generate_series(1,20) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000718' || lpad((500+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000718' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 5000,
         (d1::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (d1::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,20) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000718' || lpad((500+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 5000, 5000 from generate_series(1,20) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000718' || lpad((520+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000718' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 5000,
         ((d1+10)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1+10)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,20) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000718' || lpad((520+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 5000, 5000 from generate_series(1,20) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000718' || lpad((540+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000718' || lpad((100+s)::text,3,'0'))::uuid,
         'service', 5000,
         ((d1+20)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1+20)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,18) s;   -- only 18 of 20
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000718' || lpad((540+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 5000, 5000 from generate_series(1,18) s;

  g := public.get_ci_opportunities_v1(biz, d1, d1, null, as_of, true);

  select c into cand from jsonb_array_elements(g->'ranked') c
   where c->>'id' = 'gateway_followthrough:' || svc_gw::text;
  if cand is null then
    insert into _fail values ('B-missing', 'gateway_followthrough:svc_gw was not promoted');
  else
    if cand->'margin_guard'->>'status' <> 'blocked' then
      insert into _fail values ('B-status', format('margin_guard.status was %s, expected blocked',
        cand->'margin_guard'->>'status'));
    end if;
    if (cand->'margin_guard'->>'margin_cents')::int <> 3000 then
      insert into _fail values ('B-margin', format('margin_guard.margin_cents was %s, expected 3000',
        cand->'margin_guard'->>'margin_cents'));
    end if;
    if position('4000' in coalesce(cand->'margin_guard'->>'reason','')) = 0
       or position('3000' in coalesce(cand->'margin_guard'->>'reason','')) = 0 then
      insert into _fail values ('B-reason', format('margin_guard.reason did not name both figures: %s',
        cand->'margin_guard'->>'reason'));
    end if;

    -- the incentive-kind alternative carries the IDENTICAL cost_basis.
    select a into alt from jsonb_array_elements(cand->'alternatives') a where a->>'kind' = 'incentive';
    if alt is null then
      insert into _fail values ('B-alt-missing', 'no incentive-kind alternative on gateway_followthrough');
    elsif alt->'cost_basis' is distinct from cand->'margin_guard' then
      insert into _fail values ('B-alt-mismatch',
        format('alternative cost_basis %s does not match candidate margin_guard %s',
               alt->'cost_basis', cand->'margin_guard'));
    end if;

    -- demotion is visible: the guard's own reason text is appended to limitation.
    if position('would exceed' in coalesce(cand->>'limitation','')) = 0 then
      insert into _fail values ('B-not-demoted', 'limitation does not carry the blocked guard reason');
    end if;

    -- nestly_v712's own generic invariant: impact.margin mirrors margin_guard exactly.
    if cand->'impact'->'margin' is distinct from cand->'margin_guard' then
      insert into _fail values ('B-impact-margin-mismatch',
        format('impact.margin %s does not match margin_guard %s',
               cand->'impact'->'margin', cand->'margin_guard'));
    end if;
  end if;
end
$v718b$;

-- =================================================================================================
-- C · BIZ_GW_NOCOST — identical funnel, service carries no cost_cents.
-- =================================================================================================
do $v718c$
declare
  biz     uuid := '00000000-0000-4000-8000-000000718002';
  br      uuid := '00000000-0000-4000-8000-000000718012';
  u_owner uuid := '00000000-0000-4000-8000-000000718ee2';
  svc_gw  uuid := '00000000-0000-4000-8000-0000007180a2';
  d1      date := current_date - 200;
  as_of   timestamptz := ((d1 + 150)::timestamp + time '12:00') at time zone 'Asia/Singapore';
  g       jsonb;
  cand    jsonb;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v718 gw nocost', 'zz-v718-gw-nocost', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v718 gw nocost main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz, u_owner, 'owner', 'ZZ v718 gw nocost owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v718 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  -- svc_gw: price 5000, NO cost_cents (null).
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_gw, biz, 'ZZ v718 gateway service (nocost)', 5000, 30);

  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-000000718' || lpad((200+s)::text,3,'0'))::uuid,
         biz, 'ZZ v718 gwn funnel ' || s from generate_series(1,20) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000718' || lpad((600+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000718' || lpad((200+s)::text,3,'0'))::uuid,
         'service', 5000,
         (d1::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (d1::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,20) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000718' || lpad((600+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 5000, 5000 from generate_series(1,20) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000718' || lpad((620+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000718' || lpad((200+s)::text,3,'0'))::uuid,
         'service', 5000,
         ((d1+10)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1+10)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,20) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000718' || lpad((620+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 5000, 5000 from generate_series(1,20) s;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select ('00000000-0000-4000-8000-000000718' || lpad((640+s)::text,3,'0'))::uuid,
         biz, br, ('00000000-0000-4000-8000-000000718' || lpad((200+s)::text,3,'0'))::uuid,
         'service', 5000,
         ((d1+20)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((d1+20)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,18) s;   -- only 18 of 20
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ('00000000-0000-4000-8000-000000718' || lpad((640+s)::text,3,'0'))::uuid,
         'service', svc_gw, 1, 5000, 5000 from generate_series(1,18) s;

  g := public.get_ci_opportunities_v1(biz, d1, d1, null, as_of, true);

  select c into cand from jsonb_array_elements(g->'ranked') c
   where c->>'id' = 'gateway_followthrough:' || svc_gw::text;
  if cand is null then
    insert into _fail values ('C-missing', 'gateway_followthrough:svc_gw was not promoted');
  else
    if cand->'margin_guard'->>'status' <> 'unavailable' or cand->'margin_guard'->>'margin_cents' is not null then
      insert into _fail values ('C-status', format('expected unavailable/null margin, got %s', cand->'margin_guard'));
    end if;
    if cand->'margin_guard'->>'reason' <> 'no cost recorded for this service; enter costs in Settings' then
      insert into _fail values ('C-reason', format('reason was not verbatim: %s', cand->'margin_guard'->>'reason'));
    end if;
    if position('would exceed' in coalesce(cand->>'limitation','')) > 0 then
      insert into _fail values ('C-wrongly-demoted', 'limitation carries a blocked-style reason despite an unavailable guard');
    end if;
  end if;
end
$v718c$;

-- =================================================================================================
-- D · BIZ_DISC_CHANGE — acquisition_source: referral/walk_in (discovery) + ads (deteriorating).
-- =================================================================================================
do $v718d$
declare
  biz       uuid := '00000000-0000-4000-8000-000000718003';
  br        uuid := '00000000-0000-4000-8000-000000718013';
  u_owner   uuid := '00000000-0000-4000-8000-000000718ee3';
  svc       uuid := '00000000-0000-4000-8000-0000007180d1';
  p_from    date := current_date - 400;
  p_to      date := current_date - 300;
  as_of     timestamptz := ((p_to + 60)::timestamp + time '12:00') at time zone 'Asia/Singapore';
  train_to  date := p_from + ((p_to - p_from)/2);
  hold_from date;
  g         jsonb;
  disc      jsonb;
  det       jsonb;
  cand      jsonb;
  alt       jsonb;
begin
  hold_from := train_to + 1;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v718 disc change', 'zz-v718-disc-change', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v718 disc change main', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, br, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore', upper(b.currency), true
    from public.businesses b where b.id = biz;
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz, u_owner, 'owner', 'ZZ v718 disc change owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v718 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc, biz, 'ZZ v718 disc change service', 1000, 30);

  -- 12 referral (100%/100%), 12 "walk-in" (0%/0%) — nestly_v688's own proven BIZ3 recipe, adapted.
  -- public.clients.first_acquired_via is NOT taken from this INSERT's column list at all: the
  -- BEFORE INSERT trigger app.clients_first_acquisition_default_v629() (nestly_v629) overwrites it
  -- from the session GUC app.first_acquired_via (falling back to 'unknown' when unset, or when the
  -- GUC's value is not one of ITS OWN nine-value allowlist, which does NOT include 'walk_in' or
  -- 'ads' — only 'walk_in_till' and 'campaign' are valid there). Every client inserted while a GUC
  -- is unset (or invalid) collapses into ONE shared 'unknown' acquisition_source group regardless of
  -- what this statement's own column list says — set the GUC, LOCAL to this transaction, before
  -- each cohort's insert so the three cohorts land in three DISTINCT groups instead of merging.
  perform set_config('app.first_acquired_via', 'referral', true);
  insert into public.clients (id, business_id, full_name, first_acquired_via)
  select ('00000000-0000-4000-8000-000000718' || lpad((900+s)::text,3,'0'))::uuid,
         biz, 'ZZ v718 referral ' || s, 'referral' from generate_series(1,12) s;
  perform set_config('app.first_acquired_via', 'walk_in_till', true);
  insert into public.clients (id, business_id, full_name, first_acquired_via)
  select ('00000000-0000-4000-8000-000000718' || lpad((920+s)::text,3,'0'))::uuid,
         biz, 'ZZ v718 walkin ' || s, 'walk_in_till' from generate_series(1,12) s;
  -- 8 "ads" (100% train, 0% holdout — the deteriorating cohort). 'campaign' is the closest valid
  -- allowlisted value to an ads-sourced client; the cohort is still referred to as "ads" in this
  -- fixture's own comments/variable names for readability, but the actual stored/grouped value is
  -- 'campaign'.
  perform set_config('app.first_acquired_via', 'campaign', true);
  insert into public.clients (id, business_id, full_name, first_acquired_via)
  select ('00000000-0000-4000-8000-000000718' || lpad((940+s)::text,3,'0'))::uuid,
         biz, 'ZZ v718 ads ' || s, 'campaign' from generate_series(1,8) s;
  perform set_config('app.first_acquired_via', '', true);   -- reset, so nothing later inherits it

  -- TRAIN half anchors (train_to): referral, walk_in, ads all have a first-half anchor visit.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, ('00000000-0000-4000-8000-000000718' || lpad((900+s)::text,3,'0'))::uuid,
         'service', 1000, (train_to::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (train_to::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,12) s
  union all
  select gen_random_uuid(), biz, br, ('00000000-0000-4000-8000-000000718' || lpad((920+s)::text,3,'0'))::uuid,
         'service', 1000, (train_to::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (train_to::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,12) s
  union all
  select gen_random_uuid(), biz, br, ('00000000-0000-4000-8000-000000718' || lpad((940+s)::text,3,'0'))::uuid,
         'service', 1000, (train_to::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (train_to::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,8) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc, 1, 1000, 1000 from public.sales s
   where s.business_id = biz and (s.occurred_at at time zone 'Asia/Singapore')::date = train_to;

  -- referral + ads return within 30 days of the train anchor; walk_in does not.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, ('00000000-0000-4000-8000-000000718' || lpad((900+s)::text,3,'0'))::uuid,
         'service', 1000, ((train_to+5)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((train_to+5)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,12) s
  union all
  select gen_random_uuid(), biz, br, ('00000000-0000-4000-8000-000000718' || lpad((940+s)::text,3,'0'))::uuid,
         'service', 1000, ((train_to+5)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((train_to+5)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,8) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc, 1, 1000, 1000 from public.sales s
   where s.business_id = biz and (s.occurred_at at time zone 'Asia/Singapore')::date = train_to+5;

  -- HOLDOUT half anchors: referral at hold_from (nestly_v688's own BIZ3 shape — its own return sale
  -- 5 days later is what needs to fall soon after this anchor). walk_in and "ads" are anchored at
  -- p_to instead (the LAST day of the holdout half, not hold_from) — deliberately, NOT the same
  -- placement as referral: get_ci_discovery_v1's own "returned" check is a GLOBAL 30-day lookahead
  -- from an anchor, not scoped to the half the anchor sits in, and the two halves here are adjacent
  -- (hold_from = train_to+1) — so an anchor placed at hold_from would fall inside the 30-day window
  -- that "ads"'s own train-half return sale (train_to+5) already opened, silently counting that
  -- EARLIER sale as a "return" for the holdout anchor too and erasing the 100%->0% drop this cohort
  -- exists to demonstrate. Placing the anchor at p_to (up to ~50 days after train_to, comfortably
  -- past the 30-day window) avoids that cross-half leakage; walk_in is moved the same way purely for
  -- honesty (0%/0% should mean genuinely no return in EITHER half, not an accident of contamination
  -- happening to cancel out) even though nothing in this fixture asserts walk_in's own rate.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, ('00000000-0000-4000-8000-000000718' || lpad((900+s)::text,3,'0'))::uuid,
         'service', 1000, (hold_from::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (hold_from::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,12) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc, 1, 1000, 1000 from public.sales s
   where s.business_id = biz and (s.occurred_at at time zone 'Asia/Singapore')::date = hold_from;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, ('00000000-0000-4000-8000-000000718' || lpad((920+s)::text,3,'0'))::uuid,
         'service', 1000, (p_to::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (p_to::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,12) s
  union all
  select gen_random_uuid(), biz, br, ('00000000-0000-4000-8000-000000718' || lpad((940+s)::text,3,'0'))::uuid,
         'service', 1000, (p_to::timestamp + time '09:00') at time zone 'Asia/Singapore',
         (p_to::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,8) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc, 1, 1000, 1000 from public.sales s
   where s.business_id = biz and (s.occurred_at at time zone 'Asia/Singapore')::date = p_to;

  -- ONLY referral returns within 30 days of ITS holdout anchor (walk_in and "ads" both do not — and,
  -- with their anchor now at p_to instead of hold_from, there is no earlier sale left close enough
  -- to be miscounted as one either).
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, br, ('00000000-0000-4000-8000-000000718' || lpad((900+s)::text,3,'0'))::uuid,
         'service', 1000, ((hold_from+5)::timestamp + time '09:00') at time zone 'Asia/Singapore',
         ((hold_from+5)::timestamp + time '09:00') at time zone 'Asia/Singapore'
    from generate_series(1,12) s;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc, 1, 1000, 1000 from public.sales s
   where s.business_id = biz and (s.occurred_at at time zone 'Asia/Singapore')::date = hold_from+5;

  ---------------------------------------------------------------------------
  -- D1 · direct reader: deteriorating (ads), unconditional.
  ---------------------------------------------------------------------------
  disc := public.get_ci_discovery_v1(biz, p_from, p_to, null);
  select d into det from jsonb_array_elements(coalesce(disc->'deteriorating','[]'::jsonb)) d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'campaign';
  if det is null then
    insert into _fail values ('D1-missing',
      'no deteriorating entry for acquisition_source=ads in the direct reader');
  else
    if (det->>'train_pct')::numeric <> 100.0 then
      insert into _fail values ('D1-train-pct', format('train_pct was %s, expected 100.0', det->>'train_pct'));
    end if;
    if (det->>'holdout_pct')::numeric <> 0.0 then
      insert into _fail values ('D1-holdout-pct', format('holdout_pct was %s, expected 0.0', det->>'holdout_pct'));
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- D2/D3 · engine: discovery / change alternatives, conditional (see this fixture's own header).
  ---------------------------------------------------------------------------
  g := public.get_ci_opportunities_v1(biz, p_from, p_to, null, as_of, true);

  if exists (select 1 from jsonb_array_elements(g->'ranked') c
              where c->>'domain' = 'discovery' and c->>'id' like 'discovery:acquisition_source:%') then
    select c into cand from jsonb_array_elements(g->'ranked') c
     where c->>'domain' = 'discovery' and c->>'id' like 'discovery:acquisition_source:%' limit 1;
    if jsonb_array_length(cand->'alternatives') < 2 then
      insert into _fail values ('D2-length',
        format('discovery alternatives length was %s, expected >=2', jsonb_array_length(cand->'alternatives')));
    end if;
    select a into alt from jsonb_array_elements(cand->'alternatives') a where a->>'kind' = 'operational_change';
    if alt is null then
      insert into _fail values ('D2-missing-kind', 'discovery alternatives has no operational_change entry');
    elsif position('Investigate the driver behind acquisition_source=' in coalesce(alt->>'what','')) = 0 then
      insert into _fail values ('D2-wording', format('operational_change what was: %s', alt->>'what'));
    end if;
  end if;

  if exists (select 1 from jsonb_array_elements(g->'ranked') c where c->>'id' = 'change:acquisition_source:campaign') then
    select c into cand from jsonb_array_elements(g->'ranked') c where c->>'id' = 'change:acquisition_source:campaign';
    if jsonb_array_length(cand->'alternatives') < 2 then
      insert into _fail values ('D3-length',
        format('change alternatives length was %s, expected >=2', jsonb_array_length(cand->'alternatives')));
    end if;
    select a into alt from jsonb_array_elements(cand->'alternatives') a where a->>'kind' = 'operational_change';
    if alt is null then
      insert into _fail values ('D3-missing-kind', 'change alternatives has no operational_change entry');
    elsif alt->>'what' <> 'Review what changed for acquisition_source in the window.' then
      insert into _fail values ('D3-wording', format('operational_change what was not verbatim: %s', alt->>'what'));
    end if;
  end if;
end
$v718d$;

select case when count(*)=0 then 'PASS — nestly_v718: margin guard live for gateway_followthrough '
            '(check 74) + discovery/change second alternative kind (check 77)'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v718: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
