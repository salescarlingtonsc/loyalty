-- NESTLY v700 — behavioural hardening of three v683 readers, per an independent refuter's
-- findings against v683 (commit bda4c6b6):
--
--   1. get_ci_staff_identity_v1: booked_staff_id/credited_staff_id/line_staff/operator_user_id/
--      actual_provider coverage rates used raw app.rate_block_v1 — a 1-sale business reported
--      100.0% with no evidence block at all. Fix: add an 'evidence' block on total_sales via
--      app.subgroup_evidence_v1, and floor-gate every coverage rate through
--      app.rate_block_floor_gated_v683 (v683) so a below-floor coverage figure nulls its pct
--      while leaving the numerator/denominator counts exactly as computed.
--   2. get_ci_rebooking_v1: per-service composition.share was ungated — a service with only 1
--      contributing appointment still reported a real pct. Fix: gate each service's share on
--      THAT SERVICE'S OWN member count (cm.n), not the cohort's n_mature.
--   3. get_ci_loyalty_programmes_v1: (a) 'participation' in all seven programme blocks used raw
--      app.rate_block_v1 against v_eligible with no floor gate. Fix: floor-gate participation on
--      v_eligible via app.subgroup_evidence_v1, same wrapper as above. (b) None of the seven
--      redemption-event queries (loyalty_redemptions, stamp_milestone_claims, benefit_fulfilments,
--      referrals, welcome_offer_grants_v215, customer_birthday_redemptions, bringback_grants_v361)
--      joined clients or excluded is_synthetic, so a synthetic client's redemption event inflated
--      redemptions_total/paid_return/cannibalisation for every programme. Fix: join
--      public.clients on the client column each table actually has, and exclude
--      not coalesce(c.is_synthetic, false), in all seven.
--
-- CONTRACT: docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md (v672, frozen) — every rate-like
-- verdict travels with app.subgroup_evidence_v1 and is null, never a computed pct, below the
-- floor; raw counts are never gated. FIXTURE GUIDE: docs/qa/CI-CORPUS-FIXTURE-GUIDE.md.
--
-- METHOD: extract-and-diff against the LIVE bodies, same style as v668/v690/v695 — every patch
-- below captures pg_get_functiondef(...) from the running cluster, asserts the exact anchor
-- substring it is about to replace occurs the expected number of times (never assumed), performs
-- the replacement, executes the new CREATE OR REPLACE, then reverses every replacement on the
-- freshly-read post-patch definition and requires the result to equal the pre-patch definition
-- byte-for-byte. Any drift anywhere else in the function — not just at the intended edit sites —
-- raises and rolls the whole migration back. No function is re-typed from memory.
--
-- WHY EVERY OTHER v683 READER IS UNTOUCHED: get_ci_staff_performance_v1 and
-- get_ci_discount_dependency_v1 already floor-gate every rate-like figure through
-- app.subgroup_evidence_v1 / app.rate_block_floor_gated_v683 (verified by grep against the live
-- v683 body before writing this migration) — the refuter's report names only the three functions
-- patched here. get_ci_marketing_funnel_v1's 'read' and 'associated_purchase' rates are already
-- floor-gated the same way. This migration adds no new reader and touches no other function.
--
-- v696 (get_ci_opportunities_v1), v697 (get_ci_service_intelligence_v1), v698 (get_ci_daypart_v1)
-- and v699 (get_ci_staff_performance_v1's own further hardening, get_ci_discount_dependency_v1's
-- own further hardening) are sibling migrations in flight from other sessions; nothing here
-- redefines any function those own.
--
-- EXISTING v683 FIXTURE (db/tests/executed/v683_corpus_behavioural_authorities.sql) STAYS GREEN.
-- Checked line-by-line before writing this migration (grep against the fixture file):
--   * get_ci_staff_identity_v1's coverage assertions (39-total/39-booked/39-credited/39-line/
--     39-operator/39-actual-provider) all read ONLY '->>'numerator'' — never 'pct' — so gating
--     pct null-below-floor changes nothing they check. (The fixture's own total_sales is 3,
--     below the k=5 floor, so pct newly becomes null there — exactly the defect being fixed, and
--     invisible to a fixture that never asserted pct.)
--   * get_ci_rebooking_v1's composition assertions (52-composition-a/52-composition-b) read only
--     '->'share'->>'numerator'' and '->'share'->>'denominator'' — never 'share'->>'pct''. Both
--     services in that fixture (SVC_A n=3, SVC_B n=2) are below the floor, so their share.pct
--     newly nulls; the fixture does not check it.
--   * get_ci_loyalty_programmes_v1's participation assertions (54-points-participation,
--     54-referral-participation, the tiers/stamps n=0 checks) read only '->>'numerator'' and
--     '->>'denominator'' — never 'participation'->>'pct''.
-- No assertion in that fixture reads a 'pct' key this migration's gating could flip, so nothing
-- in it changes value. Per the task brief's instruction, this is reported rather than assumed:
-- if a future reviewer finds a 'pct' assertion in that file this migration missed, that is the
-- "report and stop" case, not silently editing v683's fixture.
--
--   4. (added mid-build, check 16) None of the three readers above ever called
--      app.ci_envelope_v680 (v680) or app.ci_exclusion_counts_v680, so the shared envelope
--      (generated_at/as_of/period/exclusions/trace_id — the same five keys get_ci_daypart_v1's
--      v693 body carries) never reached them, and their 'exclusions' block (all five counts:
--      reversed_sales, synthetic_clients, anonymous_sales, missing_demographics,
--      overlapping_campaigns) was simply absent. Fix (section 4 below): each of the three
--      builds its existing payload into v_result exactly as before, then returns
--      app.ci_envelope_v680('<query_version>', p_business, p_branch, p_from, p_to,
--      clock_timestamp(), app.ci_exclusion_counts_v680(...), v_result) instead of returning
--      v_result directly. This is purely ADDITIVE — app.ci_envelope_v680 merges five new
--      top-level keys onto the payload via `payload || …` and never touches an existing key, so
--      every key the v683 fixture already reads ('scope','coverage','sales','truncated',
--      'cohorts','evidence_class','limitation','eligible_customers','programmes','time_basis')
--      is untouched. Checked against the fixture directly (grepped for 'generated_at'/'as_of'/
--      'period'/'exclusions'/'trace_id' — zero hits), so nothing in it could regress.
--
--      DELIBERATELY NOT DONE: adding a p_as_of parameter (the other half of what v680 did for
--      its original six readers, giving them an immutable-snapshot gate — check 9). Two of the
--      three functions here are called by other migrations' code with a fixed 4-argument arity
--      and one of them (nestly_v688's get_ci_opportunities_v1, itself owned by a sibling
--      migration) FEATURE-DETECTS with
--      `to_regprocedure('public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid)')` before
--      calling `public.get_ci_loyalty_programmes_v1(p_business, p_from, p_to, null)` — a literal
--      4-argument call, not a defaulted 5th argument. Adding a trailing p_as_of parameter would
--      require `drop function ...(uuid,date,date,uuid)` first (Postgres cannot CREATE OR REPLACE
--      a different argument list — the same reason v680's own header gives for using DROP), and
--      dropping that exact 4-arg signature would silently flip v688's to_regprocedure check to
--      NULL and disable its extended-mode enrichment path — the "dropping SQL objects breaks
--      callers silently" trap, not a hypothetical one, since the call site is grepped and
--      confirmed live in this same tree. So this migration wraps the envelope using
--      `clock_timestamp()` as p_as_of internally and changes no signature; the immutable-snapshot
--      gate for these three readers is out of scope here and not silently claimed as done.
--
-- PROOF: db/tests/executed/v700_corpus_behavioural_hardening.sql.

begin;

-- ============================================================================================
-- 1. get_ci_staff_identity_v1 — coverage evidence + floor-gated coverage rates (finding 1)
-- ============================================================================================
do $patch_staff_identity$
declare
  v_def      text;
  v_anchor   constant text := $a1$    'coverage', jsonb_build_object(
      'total_sales', v_total,
      'booked_staff_id', app.rate_block_v1(v_booked, v_total),
      'credited_staff_id', app.rate_block_v1(v_credited, v_total),
      'line_staff', app.rate_block_v1(v_line, v_total),
      'operator_user_id', app.rate_block_v1(v_operator, v_total),
      'actual_provider', app.rate_block_v1(v_actual, v_total)));$a1$;
  v_new      constant text := $b1$    'coverage', jsonb_build_object(
      'total_sales', v_total,
      'evidence', app.subgroup_evidence_v1(v_total),
      'booked_staff_id', app.rate_block_floor_gated_v683(v_booked, v_total, app.subgroup_evidence_v1(v_total)),
      'credited_staff_id', app.rate_block_floor_gated_v683(v_credited, v_total, app.subgroup_evidence_v1(v_total)),
      'line_staff', app.rate_block_floor_gated_v683(v_line, v_total, app.subgroup_evidence_v1(v_total)),
      'operator_user_id', app.rate_block_floor_gated_v683(v_operator, v_total, app.subgroup_evidence_v1(v_total)),
      'actual_provider', app.rate_block_floor_gated_v683(v_actual, v_total, app.subgroup_evidence_v1(v_total))));$b1$;
  v_count    integer;
  v_expected text;
  v_after    text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_staff_identity_v1(uuid,date,date,uuid)')) into v_def;
  if v_def is null then
    raise exception 'v700: public.get_ci_staff_identity_v1 not found';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 1 then
    raise exception 'v700: staff_identity coverage anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor, v_new);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_staff_identity_v1(uuid,date,date,uuid)')) into v_after;
  v_roundtrip := replace(v_after, v_new, v_anchor);
  if v_roundtrip <> v_def then
    raise exception
      'v700: get_ci_staff_identity_v1 changed by more than the intended edit. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_staff_identity$;
-- ACL restated verbatim (unchanged by this migration — same argument list).
revoke all on function public.get_ci_staff_identity_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_staff_identity_v1(uuid,date,date,uuid) to authenticated, service_role;

-- ============================================================================================
-- 2. get_ci_rebooking_v1 — gate each service's composition.share on that service's OWN member
--    count (cm.n), not the cohort total (c.n) (finding 2)
-- ============================================================================================
do $patch_rebooking$
declare
  v_def      text;
  v_anchor   constant text := $a2$                  'share', app.rate_block_v1(cm.n, c.n))$a2$;
  v_new      constant text := $b2$                  'share', app.rate_block_floor_gated_v683(cm.n, c.n, app.subgroup_evidence_v1(cm.n::integer)))$b2$;
  v_count    integer;
  v_expected text;
  v_after    text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_rebooking_v1(uuid,date,date,uuid)')) into v_def;
  if v_def is null then
    raise exception 'v700: public.get_ci_rebooking_v1 not found';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 2 then
    raise exception 'v700: rebooking composition-share anchor occurs % times (expected 2) — live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor, v_new);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_rebooking_v1(uuid,date,date,uuid)')) into v_after;
  v_roundtrip := replace(v_after, v_new, v_anchor);
  if v_roundtrip <> v_def then
    raise exception
      'v700: get_ci_rebooking_v1 changed by more than the intended edit. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_rebooking$;
revoke all on function public.get_ci_rebooking_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_rebooking_v1(uuid,date,date,uuid) to authenticated, service_role;

-- ============================================================================================
-- 3. get_ci_loyalty_programmes_v1 — floor-gate participation (finding 3a) and exclude synthetic
--    clients from all seven redemption-event queries (finding 3b)
-- ============================================================================================

do $patch_loyalty$
declare
  v_def text;

  -- 3a. participation, identical text in all seven programme blocks.
  v_anchor_participation constant text :=
    $a3$      'participation', app.rate_block_v1(v_enrolled, v_eligible),$a3$;
  v_new_participation constant text :=
    $b3$      'participation', app.rate_block_floor_gated_v683(v_enrolled, v_eligible, app.subgroup_evidence_v1(v_eligible)),$b3$;

  -- 3b. one anchor per programme's events query — table name differs in every one, so each is
  -- unique text even where the alias letter repeats (points 'lr', stamps 'smc', tiers 'bf',
  -- referral 'r', welcome 'g'/welcome_offer_grants_v215, birthday 'r'/customer_birthday_
  -- redemptions, bring-back 'g'/bringback_grants_v361).
  v_anchor_points constant text := $a_pts$    select coalesce(jsonb_agg(jsonb_build_object('client_id', lr.client_id, 'at', lr.redeemed_at)), '[]'::jsonb)
      into v_events
      from public.loyalty_redemptions lr
     where lr.business_id = p_business
       and coalesce(lr.consumes_balance, true)
       and (lr.redeemed_at at time zone 'Asia/Singapore')::date between p_from and p_to;$a_pts$;
  v_new_points constant text := $b_pts$    select coalesce(jsonb_agg(jsonb_build_object('client_id', lr.client_id, 'at', lr.redeemed_at)), '[]'::jsonb)
      into v_events
      from public.loyalty_redemptions lr
      join public.clients c on c.id = lr.client_id
     where lr.business_id = p_business
       and coalesce(lr.consumes_balance, true)
       and not coalesce(c.is_synthetic, false)
       and (lr.redeemed_at at time zone 'Asia/Singapore')::date between p_from and p_to;$b_pts$;

  v_anchor_stamps constant text := $a_stp$    select coalesce(jsonb_agg(jsonb_build_object('client_id', smc.client_id, 'at', smc.claimed_at)), '[]'::jsonb)
      into v_events
      from public.stamp_milestone_claims smc
     where smc.business_id = p_business and smc.programme_id = v_spine_stamps.id
       and (smc.claimed_at at time zone 'Asia/Singapore')::date between p_from and p_to;$a_stp$;
  v_new_stamps constant text := $b_stp$    select coalesce(jsonb_agg(jsonb_build_object('client_id', smc.client_id, 'at', smc.claimed_at)), '[]'::jsonb)
      into v_events
      from public.stamp_milestone_claims smc
      join public.clients c on c.id = smc.client_id
     where smc.business_id = p_business and smc.programme_id = v_spine_stamps.id
       and not coalesce(c.is_synthetic, false)
       and (smc.claimed_at at time zone 'Asia/Singapore')::date between p_from and p_to;$b_stp$;

  v_anchor_tiers constant text := $a_tir$    select coalesce(jsonb_agg(jsonb_build_object('client_id', bf.client_id, 'at', bf.occurred_at)), '[]'::jsonb)
      into v_events
      from public.benefit_fulfilments bf
     where bf.business_id = p_business
       and bf.fulfilment_kind = 'checkout_discount'
       and bf.canonical_benefit_key like 'tierdiscount:%'
       and bf.client_id is not null
       and (bf.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to;$a_tir$;
  v_new_tiers constant text := $b_tir$    select coalesce(jsonb_agg(jsonb_build_object('client_id', bf.client_id, 'at', bf.occurred_at)), '[]'::jsonb)
      into v_events
      from public.benefit_fulfilments bf
      join public.clients c on c.id = bf.client_id
     where bf.business_id = p_business
       and bf.fulfilment_kind = 'checkout_discount'
       and bf.canonical_benefit_key like 'tierdiscount:%'
       and bf.client_id is not null
       and not coalesce(c.is_synthetic, false)
       and (bf.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to;$b_tir$;

  v_anchor_referral constant text := $a_ref$    select coalesce(jsonb_agg(jsonb_build_object('client_id', r.referrer_client_id, 'at', r.qualified_at)), '[]'::jsonb)
      into v_events
      from public.referrals r
     where r.business_id = p_business and r.status = 'rewarded' and r.qualified_at is not null
       and (r.qualified_at at time zone 'Asia/Singapore')::date between p_from and p_to;$a_ref$;
  v_new_referral constant text := $b_ref$    select coalesce(jsonb_agg(jsonb_build_object('client_id', r.referrer_client_id, 'at', r.qualified_at)), '[]'::jsonb)
      into v_events
      from public.referrals r
      join public.clients c on c.id = r.referrer_client_id
     where r.business_id = p_business and r.status = 'rewarded' and r.qualified_at is not null
       and not coalesce(c.is_synthetic, false)
       and (r.qualified_at at time zone 'Asia/Singapore')::date between p_from and p_to;$b_ref$;

  v_anchor_welcome constant text := $a_wel$    select coalesce(jsonb_agg(jsonb_build_object('client_id', g.client_id, 'at', g.redeemed_at)), '[]'::jsonb)
      into v_events
      from public.welcome_offer_grants_v215 g
     where g.business_id = p_business and g.status = 'redeemed'
       and (g.redeemed_at at time zone 'Asia/Singapore')::date between p_from and p_to;$a_wel$;
  v_new_welcome constant text := $b_wel$    select coalesce(jsonb_agg(jsonb_build_object('client_id', g.client_id, 'at', g.redeemed_at)), '[]'::jsonb)
      into v_events
      from public.welcome_offer_grants_v215 g
      join public.clients c on c.id = g.client_id
     where g.business_id = p_business and g.status = 'redeemed'
       and not coalesce(c.is_synthetic, false)
       and (g.redeemed_at at time zone 'Asia/Singapore')::date between p_from and p_to;$b_wel$;

  v_anchor_birthday constant text := $a_bir$    select coalesce(jsonb_agg(jsonb_build_object('client_id', r.client_id, 'at', r.created_at)), '[]'::jsonb)
      into v_events
      from public.customer_birthday_redemptions r
     where r.business_id = p_business and r.operation_kind = 'redemption' and r.active
       and (r.created_at at time zone 'Asia/Singapore')::date between p_from and p_to;$a_bir$;
  v_new_birthday constant text := $b_bir$    select coalesce(jsonb_agg(jsonb_build_object('client_id', r.client_id, 'at', r.created_at)), '[]'::jsonb)
      into v_events
      from public.customer_birthday_redemptions r
      join public.clients c on c.id = r.client_id
     where r.business_id = p_business and r.operation_kind = 'redemption' and r.active
       and not coalesce(c.is_synthetic, false)
       and (r.created_at at time zone 'Asia/Singapore')::date between p_from and p_to;$b_bir$;

  v_anchor_bringback constant text := $a_bb$    select coalesce(jsonb_agg(jsonb_build_object('client_id', g.client_id, 'at', g.redeemed_at)), '[]'::jsonb)
      into v_events
      from public.bringback_grants_v361 g
     where g.business_id = p_business and g.status = 'redeemed'
       and (g.redeemed_at at time zone 'Asia/Singapore')::date between p_from and p_to;$a_bb$;
  v_new_bringback constant text := $b_bb$    select coalesce(jsonb_agg(jsonb_build_object('client_id', g.client_id, 'at', g.redeemed_at)), '[]'::jsonb)
      into v_events
      from public.bringback_grants_v361 g
      join public.clients c on c.id = g.client_id
     where g.business_id = p_business and g.status = 'redeemed'
       and not coalesce(c.is_synthetic, false)
       and (g.redeemed_at at time zone 'Asia/Singapore')::date between p_from and p_to;$b_bb$;

  v_count     integer;
  v_expected  text;
  v_after     text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid)')) into v_def;
  if v_def is null then
    raise exception 'v700: public.get_ci_loyalty_programmes_v1 not found';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_participation, ''))) / length(v_anchor_participation);
  if v_count <> 7 then
    raise exception 'v700: participation anchor occurs % times (expected 7) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_points, ''))) / length(v_anchor_points);
  if v_count <> 1 then
    raise exception 'v700: points-events anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_stamps, ''))) / length(v_anchor_stamps);
  if v_count <> 1 then
    raise exception 'v700: stamps-events anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_tiers, ''))) / length(v_anchor_tiers);
  if v_count <> 1 then
    raise exception 'v700: tiers-events anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_referral, ''))) / length(v_anchor_referral);
  if v_count <> 1 then
    raise exception 'v700: referral-events anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_welcome, ''))) / length(v_anchor_welcome);
  if v_count <> 1 then
    raise exception 'v700: welcome-events anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_birthday, ''))) / length(v_anchor_birthday);
  if v_count <> 1 then
    raise exception 'v700: birthday-events anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_bringback, ''))) / length(v_anchor_bringback);
  if v_count <> 1 then
    raise exception 'v700: bringback-events anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_participation, v_new_participation);
  v_expected := replace(v_expected, v_anchor_points, v_new_points);
  v_expected := replace(v_expected, v_anchor_stamps, v_new_stamps);
  v_expected := replace(v_expected, v_anchor_tiers, v_new_tiers);
  v_expected := replace(v_expected, v_anchor_referral, v_new_referral);
  v_expected := replace(v_expected, v_anchor_welcome, v_new_welcome);
  v_expected := replace(v_expected, v_anchor_birthday, v_new_birthday);
  v_expected := replace(v_expected, v_anchor_bringback, v_new_bringback);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid)')) into v_after;

  v_roundtrip := replace(v_after, v_new_participation, v_anchor_participation);
  v_roundtrip := replace(v_roundtrip, v_new_points, v_anchor_points);
  v_roundtrip := replace(v_roundtrip, v_new_stamps, v_anchor_stamps);
  v_roundtrip := replace(v_roundtrip, v_new_tiers, v_anchor_tiers);
  v_roundtrip := replace(v_roundtrip, v_new_referral, v_anchor_referral);
  v_roundtrip := replace(v_roundtrip, v_new_welcome, v_anchor_welcome);
  v_roundtrip := replace(v_roundtrip, v_new_birthday, v_anchor_birthday);
  v_roundtrip := replace(v_roundtrip, v_new_bringback, v_anchor_bringback);

  if v_roundtrip <> v_def then
    raise exception
      'v700: get_ci_loyalty_programmes_v1 changed by more than the eight intended edits. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_loyalty$;
revoke all on function public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid) to authenticated, service_role;

-- ============================================================================================
-- 4. THE SHARED CI ENVELOPE (finding 4 / check 16) — none of the three readers above ever
--    called app.ci_envelope_v680, so their payload carried no generated_at/as_of/period/
--    exclusions/trace_id. Each is patched, additively, to build its existing payload into
--    v_result exactly as before and then return app.ci_envelope_v680(...) wrapping it, the same
--    shape get_ci_daypart_v1's v693 body already returns. No p_as_of parameter is added (see the
--    header note on why: it would require dropping the 4-arg
--    get_ci_loyalty_programmes_v1(uuid,date,date,uuid) signature that nestly_v688's
--    get_ci_opportunities_v1 feature-detects and calls literally) — clock_timestamp() is used
--    for p_as_of internally instead.
-- ============================================================================================

-- --------------------------------------------------------------------------------------------
-- 4a. get_ci_staff_identity_v1
-- --------------------------------------------------------------------------------------------
do $patch_envelope_staff_identity$
declare
  v_def text;

  v_anchor_declare constant text := $aeis$declare
  v_rows jsonb;
  v_total integer;
  v_booked integer;
  v_credited integer;
  v_line integer;
  v_operator integer;
  v_actual integer;
begin$aeis$;
  v_new_declare constant text := $beis$declare
  v_rows jsonb;
  v_total integer;
  v_booked integer;
  v_credited integer;
  v_line integer;
  v_operator integer;
  v_actual integer;
  v_result jsonb;
begin$beis$;

  -- The tail below embeds this migration's OWN section-1 fix verbatim (v_new from the earlier
  -- do-block) — by the time this section runs, that is what the live body actually contains.
  v_anchor_tail constant text := $aeit$  return jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'sales', v_rows,
    'truncated', v_total > 500,
    'coverage', jsonb_build_object(
      'total_sales', v_total,
      'evidence', app.subgroup_evidence_v1(v_total),
      'booked_staff_id', app.rate_block_floor_gated_v683(v_booked, v_total, app.subgroup_evidence_v1(v_total)),
      'credited_staff_id', app.rate_block_floor_gated_v683(v_credited, v_total, app.subgroup_evidence_v1(v_total)),
      'line_staff', app.rate_block_floor_gated_v683(v_line, v_total, app.subgroup_evidence_v1(v_total)),
      'operator_user_id', app.rate_block_floor_gated_v683(v_operator, v_total, app.subgroup_evidence_v1(v_total)),
      'actual_provider', app.rate_block_floor_gated_v683(v_actual, v_total, app.subgroup_evidence_v1(v_total))));$aeit$;
  v_new_tail constant text := $beit$  v_result := jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'sales', v_rows,
    'truncated', v_total > 500,
    'coverage', jsonb_build_object(
      'total_sales', v_total,
      'evidence', app.subgroup_evidence_v1(v_total),
      'booked_staff_id', app.rate_block_floor_gated_v683(v_booked, v_total, app.subgroup_evidence_v1(v_total)),
      'credited_staff_id', app.rate_block_floor_gated_v683(v_credited, v_total, app.subgroup_evidence_v1(v_total)),
      'line_staff', app.rate_block_floor_gated_v683(v_line, v_total, app.subgroup_evidence_v1(v_total)),
      'operator_user_id', app.rate_block_floor_gated_v683(v_operator, v_total, app.subgroup_evidence_v1(v_total)),
      'actual_provider', app.rate_block_floor_gated_v683(v_actual, v_total, app.subgroup_evidence_v1(v_total))));

  return app.ci_envelope_v680('ci_staff_identity_v1', p_business, p_branch, p_from, p_to,
    clock_timestamp(),
    app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, clock_timestamp()),
    v_result);$beit$;

  v_count     integer;
  v_expected  text;
  v_after     text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_staff_identity_v1(uuid,date,date,uuid)')) into v_def;
  if v_def is null then
    raise exception 'v700: public.get_ci_staff_identity_v1 not found (envelope patch)';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_declare, ''))) / length(v_anchor_declare);
  if v_count <> 1 then
    raise exception 'v700: staff_identity envelope declare-anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_tail, ''))) / length(v_anchor_tail);
  if v_count <> 1 then
    raise exception 'v700: staff_identity envelope tail-anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_declare, v_new_declare);
  v_expected := replace(v_expected, v_anchor_tail, v_new_tail);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_staff_identity_v1(uuid,date,date,uuid)')) into v_after;
  v_roundtrip := replace(v_after, v_new_declare, v_anchor_declare);
  v_roundtrip := replace(v_roundtrip, v_new_tail, v_anchor_tail);
  if v_roundtrip <> v_def then
    raise exception
      'v700: get_ci_staff_identity_v1 envelope patch changed more than the two intended edits. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_envelope_staff_identity$;
revoke all on function public.get_ci_staff_identity_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_staff_identity_v1(uuid,date,date,uuid) to authenticated, service_role;

-- --------------------------------------------------------------------------------------------
-- 4b. get_ci_rebooking_v1
-- --------------------------------------------------------------------------------------------
do $patch_envelope_rebooking$
declare
  v_def text;

  v_anchor_declare constant text := $aerd$declare
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_window_days constant integer := 60;
  v_rebooked jsonb;
  v_other jsonb;
begin$aerd$;
  v_new_declare constant text := $berd$declare
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_window_days constant integer := 60;
  v_rebooked jsonb;
  v_other jsonb;
  v_result jsonb;
begin$berd$;

  v_anchor_tail constant text := $aert$  return jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'window_days', v_window_days,
    'cohorts', jsonb_build_object(
      'rebooked_at_departure', coalesce(v_rebooked,
        jsonb_build_object('n', 0, 'evidence', app.subgroup_evidence_v1(0),
                            'immature', 0, 'within_window', app.rate_block_v1(0,0),
                            'composition', '[]'::jsonb)),
      'other', coalesce(v_other,
        jsonb_build_object('n', 0, 'evidence', app.subgroup_evidence_v1(0),
                            'immature', 0, 'within_window', app.rate_block_v1(0,0),
                            'composition', '[]'::jsonb))),
    'evidence_class', 'ASSOCIATION',
    'limitation', 'Association only: customers who rebook at departure are not a random draw. '
      'This comparison does not establish that rebooking improves subsequent return; the '
      'difference may simply reflect that already more loyal customers are the ones who rebook.');$aert$;
  v_new_tail constant text := $bert$  v_result := jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'window_days', v_window_days,
    'cohorts', jsonb_build_object(
      'rebooked_at_departure', coalesce(v_rebooked,
        jsonb_build_object('n', 0, 'evidence', app.subgroup_evidence_v1(0),
                            'immature', 0, 'within_window', app.rate_block_v1(0,0),
                            'composition', '[]'::jsonb)),
      'other', coalesce(v_other,
        jsonb_build_object('n', 0, 'evidence', app.subgroup_evidence_v1(0),
                            'immature', 0, 'within_window', app.rate_block_v1(0,0),
                            'composition', '[]'::jsonb))),
    'evidence_class', 'ASSOCIATION',
    'limitation', 'Association only: customers who rebook at departure are not a random draw. '
      'This comparison does not establish that rebooking improves subsequent return; the '
      'difference may simply reflect that already more loyal customers are the ones who rebook.');

  return app.ci_envelope_v680('ci_rebooking_v1', p_business, p_branch, p_from, p_to,
    clock_timestamp(),
    app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, clock_timestamp()),
    v_result);$bert$;

  v_count     integer;
  v_expected  text;
  v_after     text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_rebooking_v1(uuid,date,date,uuid)')) into v_def;
  if v_def is null then
    raise exception 'v700: public.get_ci_rebooking_v1 not found (envelope patch)';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_declare, ''))) / length(v_anchor_declare);
  if v_count <> 1 then
    raise exception 'v700: rebooking envelope declare-anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_tail, ''))) / length(v_anchor_tail);
  if v_count <> 1 then
    raise exception 'v700: rebooking envelope tail-anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_declare, v_new_declare);
  v_expected := replace(v_expected, v_anchor_tail, v_new_tail);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_rebooking_v1(uuid,date,date,uuid)')) into v_after;
  v_roundtrip := replace(v_after, v_new_declare, v_anchor_declare);
  v_roundtrip := replace(v_roundtrip, v_new_tail, v_anchor_tail);
  if v_roundtrip <> v_def then
    raise exception
      'v700: get_ci_rebooking_v1 envelope patch changed more than the two intended edits. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_envelope_rebooking$;
revoke all on function public.get_ci_rebooking_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_rebooking_v1(uuid,date,date,uuid) to authenticated, service_role;

-- --------------------------------------------------------------------------------------------
-- 4c. get_ci_loyalty_programmes_v1
-- --------------------------------------------------------------------------------------------

do $patch_envelope_loyalty$
declare
  v_def text;

  v_anchor_declare constant text := $aeld$declare
  v_eligible integer;
  v_incrementality_unavailable constant jsonb :=
    jsonb_build_object('status', 'unavailable',
      'reason', 'no holdout; see v108 for the measured bring-back path');
  v_points jsonb; v_stamps jsonb; v_tiers jsonb; v_referral jsonb;
  v_welcome jsonb; v_birthday jsonb; v_bringback jsonb;

  v_spine_points record; v_spine_stamps record; v_spine_tiers record; v_spine_referral record;
  v_enrolled integer; v_events jsonb; v_outcomes jsonb;
  v_bb_incrementality jsonb;
begin$aeld$;
  v_new_declare constant text := $beld$declare
  v_eligible integer;
  v_incrementality_unavailable constant jsonb :=
    jsonb_build_object('status', 'unavailable',
      'reason', 'no holdout; see v108 for the measured bring-back path');
  v_points jsonb; v_stamps jsonb; v_tiers jsonb; v_referral jsonb;
  v_welcome jsonb; v_birthday jsonb; v_bringback jsonb;

  v_spine_points record; v_spine_stamps record; v_spine_tiers record; v_spine_referral record;
  v_enrolled integer; v_events jsonb; v_outcomes jsonb;
  v_bb_incrementality jsonb;
  v_result jsonb;
begin$beld$;

  v_anchor_tail constant text := $aelt$  return jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'from', p_from, 'to', p_to),
    'time_basis', 'redemption_event_at',
    'eligible_customers', v_eligible,
    'programmes', jsonb_build_object(
      'points', v_points, 'stamps', v_stamps, 'tiers', v_tiers, 'referral', v_referral,
      'welcome', v_welcome, 'birthday', v_birthday, 'bring_back', v_bringback));$aelt$;
  v_new_tail constant text := $belt$  v_result := jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'from', p_from, 'to', p_to),
    'time_basis', 'redemption_event_at',
    'eligible_customers', v_eligible,
    'programmes', jsonb_build_object(
      'points', v_points, 'stamps', v_stamps, 'tiers', v_tiers, 'referral', v_referral,
      'welcome', v_welcome, 'birthday', v_birthday, 'bring_back', v_bringback));

  return app.ci_envelope_v680('ci_loyalty_programmes_v1', p_business, p_branch, p_from, p_to,
    clock_timestamp(),
    app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, clock_timestamp()),
    v_result);$belt$;

  v_count     integer;
  v_expected  text;
  v_after     text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid)')) into v_def;
  if v_def is null then
    raise exception 'v700: public.get_ci_loyalty_programmes_v1 not found (envelope patch)';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_declare, ''))) / length(v_anchor_declare);
  if v_count <> 1 then
    raise exception 'v700: loyalty envelope declare-anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_tail, ''))) / length(v_anchor_tail);
  if v_count <> 1 then
    raise exception 'v700: loyalty envelope tail-anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_declare, v_new_declare);
  v_expected := replace(v_expected, v_anchor_tail, v_new_tail);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid)')) into v_after;
  v_roundtrip := replace(v_after, v_new_declare, v_anchor_declare);
  v_roundtrip := replace(v_roundtrip, v_new_tail, v_anchor_tail);
  if v_roundtrip <> v_def then
    raise exception
      'v700: get_ci_loyalty_programmes_v1 envelope patch changed more than the two intended edits. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_envelope_loyalty$;
revoke all on function public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid) to authenticated, service_role;

commit;
