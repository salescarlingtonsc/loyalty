-- EXECUTED acceptance fixture for nestly_v652 — the shared evidence contract
-- (app.evidence_block_v1, db/migrations/20260831_nestly_v652_evidence_contract.sql).
--
-- WHY. v652 is the one place the product is allowed to say "this looks like it worked" about a
-- non-randomised comparison (e.g. the Recovered Revenue report, public.get_recovery_report_v550).
-- Its whole job is discipline: refuse to speak past what a tiny, non-randomised, biased-baseline
-- comparison can actually support. This fixture is a synthetic PREDETERMINED TRUTH TABLE against
-- app.evidence_block_v1 directly — no business/staff/subscription fixture is needed because the
-- function is a pure, ACL-gated computation with no table reads (see the migration: no SELECT
-- from any relation, `immutable`, `security invoker` by omission). The only precondition worth
-- proving is the ACL itself: it is `revoke all ... from public, anon` / `grant ... to authenticated,
-- service_role`, so an `anon` caller must be refused before any of S1-S6 can be trusted.
--
-- Named v652 because every assertion here is `n/a` against the v422 baseline (the function does
-- not exist yet) and is gated on the migrated run. Run with --migrated-only while iterating:
--   LC_ALL=C node scripts/db-tests/run.mjs --filter=v652_corpus --migrated-only
--
-- =====================================================================================
-- TRUTH TABLE (all arithmetic spelled out by hand before any assertion runs)
-- =====================================================================================
--
-- PRE  ACL.  Neither `anon` nor `authenticated` holds USAGE on the internal `app` schema in this
--      harness's baseline-grants.sql (scripts/db-tests/baseline-grants.sql:37 grants schema `app`
--      USAGE to service_role only, matching production's real posture: `app` is never exposed to
--      PostgREST session roles, only `public` is). So the v652 migration's own
--      `grant execute on function app.evidence_block_v1(...) to authenticated, service_role` is,
--      in practice, inert for a direct caller — a real `authenticated` session can only ever
--      reach evidence_block_v1 indirectly, through a SECURITY DEFINER wrapper such as
--      public.get_recovery_report_v550, which runs as the function owner and does not need the
--      caller's own schema privilege. PRE proves both halves of that: `anon` is refused (42501,
--      as expected) AND — this is the one genuinely interesting finding in this section —
--      `authenticated` is ALSO refused with 42501 despite being explicitly named in the grant.
--      This is recorded as a minor, low-risk finding (see PRE-authenticated below), not fixed
--      here. S1-S6 then call the function the way every other internal `app.*` fixture in this
--      corpus does (v551_top_share_denominator.sql, v426_tier_resolver.sql, etc.): directly, as
--      the harness's own bootstrap role, which is how the SECURITY DEFINER call path actually
--      runs in production.
--
-- S1   THE FLOOR BITES, AND IS A REAL PARAMETER, NOT A DECORATION.
--      Fixed data: treated 5/5 (100%), comparison 5/0 (0%). n=5 per arm in both calls below.
--        S1a  p_min_arm left at its DEFAULT (10). 5 < 10 on both arms  => verdict MUST be
--             'insufficient', regardless of the 100-pp gap the raw rates show.
--        S1b  SAME data, p_min_arm explicitly lowered to 3. 5 >= 3 on both arms, so the floor
--             no longer applies and the interval must be evaluated on its own terms:
--               p1=1.0, p2=0.0, diff=1.0
--               var1 = 1*(1-1)/5 = 0, var2 = 0*(1-0)/5 = 0  =>  se = 0
--               lo = hi = 1.0  =>  100.0pp, a ZERO-WIDTH interval that does not span zero
--             => verdict MUST NOT be 'insufficient' this time (it resolves to 'strong_pattern'
--             under the default ceiling). The pair (S1a vs S1b) proves p_min_arm is read, not
--             hardcoded — and S1b is flagged separately below as a recorded Wald limitation
--             (a perfect small-n split collapses the interval to a single point).
--
-- S2   THE THREE-OF-THREE TRAP (default floor, independent of S1's parameter probe).
--      treated 3/3 (100%), comparison 3/0 (0%). Both arms are 3, under the default min_arm=10.
--      A naive reading of "3-for-3, versus 0-for-3" looks like a slam dunk; evidence_block_v1
--      must cap it at 'insufficient' purely on sample size, before the interval is even relevant.
--
-- S3   A CI THAT SPANS ZERO CANNOT BE A PATTERN, even with both arms comfortably over the floor.
--      treated 26/50 (52%), comparison 24/50 (48%). n=50 per arm, well over min_arm=10.
--        p1=0.52, p2=0.48, diff=0.04
--        var1 = 0.52*0.48/50 = 0.004992, var2 = 0.48*0.52/50 = 0.004992, sum = 0.009984
--        se = sqrt(0.009984) ≈ 0.0999200
--        1.96*se ≈ 0.1958432
--        lo ≈ 0.04 - 0.1958432 = -0.1558432  => -15.6pp (rounded)
--        hi ≈ 0.04 + 0.1958432 =  0.2358432  =>  23.6pp (rounded)
--      lo <= 0 <= hi (the interval straddles zero: 52% cannot be told apart from 48% at n=50
--      per arm) => verdict MUST be 'insufficient', never 'strong_pattern'.
--
-- S4   EFFECT SIZE TRAVELS WITH THE VERDICT (and the whole shape of the block is populated).
--      treated 100/200 (50%), comparison 60/200 (30%). n=200 per arm.
--        p1=0.5, p2=0.3, diff=0.2 exactly => absolute_pp = 20.0 exactly
--        relative = p1/p2 = 0.5/0.3 = 1.6666... => round(.,2) = 1.67
--        var1 = 0.5*0.5/200 = 0.00125, var2 = 0.3*0.7/200 = 0.00105, sum = 0.0023
--        se = sqrt(0.0023) ≈ 0.0479583
--        1.96*se ≈ 0.0939983
--        lo ≈ 0.2 - 0.0939983 = 0.1060017 => 10.6pp (rounded)
--        hi ≈ 0.2 + 0.0939983 = 0.2939983 => 29.4pp (rounded)
--      Interval is strictly positive (10.6..29.4), doesn't span zero, both arms over the floor
--      => under the default ceiling ('strong_pattern') this is the one case in the whole fixture
--      that is allowed to say 'strong_pattern'. S4 asserts the numeric payload (rates.treated_pct
--      =50.0, rates.comparison_pct=30.0, difference.absolute_pp=20.0 exactly, difference.relative
--      =1.67 exactly, difference.confidence_95_pp within 0.1pp of [10.6, 29.4]) travels alongside
--      the verdict word, and that `sample` echoes the exact input counts.
--
-- S5   THE VERDICT CEILING IS HONOURED — reusing S4's exact data (the one dataset in this fixture
--      that would otherwise earn 'strong_pattern' on its own arithmetic):
--        S5a  p_max_verdict default ('strong_pattern')      => verdict = 'strong_pattern'
--        S5b  p_max_verdict = 'early_signal'                => verdict = 'early_signal'
--        S5c  p_max_verdict = 'insufficient'                => verdict = 'insufficient'
--      Same numbers, three different verdicts purely from the ceiling parameter — this is what
--      v550's own call site relies on (it always passes 'early_signal' because its baseline is
--      never a holdout).
--
-- S6   THE INTERVAL METHOD IS DISCLOSED, AND ITS KNOWN LIMITATION IS RECORDED.
--      S6a asserts difference.method equals the exact string the migration hardcodes:
--        'normal approximation, 95% interval on the difference in rates'
--      i.e. an UNADJUSTED NORMAL-APPROXIMATION (WALD) INTERVAL — no continuity correction, no
--      Wilson/Agresti-Coull adjustment. Wald intervals are known to misbehave at small n or at
--      rates near 0%/100%, because the variance estimate p(1-p)/n collapses toward zero exactly
--      where the true sampling uncertainty is largest.
--
--      S6b is the constructed extreme case: treated 9/10 (90%), comparison 1/10 (10%), n=10 per
--      arm (AT the default floor, not below it, so the floor does not intervene):
--        p1=0.9, p2=0.1, diff=0.8
--        var1 = 0.9*0.1/10 = 0.009, var2 = 0.1*0.9/10 = 0.009, sum = 0.018
--        se = sqrt(0.018) ≈ 0.1341641
--        1.96*se ≈ 0.2629616
--        lo ≈ 0.8 - 0.2629616 = 0.5370384 =>  53.7pp (rounded)
--        hi ≈ 0.8 + 0.2629616 = 1.0629616 => 106.3pp (rounded)
--      A percentage-point DIFFERENCE between two rates can never legally exceed 100pp in
--      magnitude (100% minus 0% is the most extreme gap that exists). 106.3pp is outside that
--      legal range. This is NOT an endorsement of the method and NOT something to special-case
--      away in the fixture — it is exactly the failure mode the v652 migration's own comment
--      warns about ("no non-randomised comparison ... may ever report strong_pattern" is a
--      verdict-level safeguard; it does nothing to keep the numeric interval itself inside
--      [-100, 100]pp). The assertion below is intentionally left to FAIL if the product's Wald
--      interval produces an out-of-range bound, per the standing instruction not to weaken a
--      finding that is real. A Wilson or Agresti-Coull interval would not do this (both are
--      bounded to [0,1] on each arm by construction and only asymptotically approach a Wald
--      interval as n grows), which is the recorded limitation, not a suggested fix.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v652$
declare
  u_auth uuid := '00000000-0000-4000-8000-000000065201';
  g jsonb;
  v_err text;
  v_lo numeric; v_hi numeric;
begin
  ---------------------------------------------------------------------------
  -- PRE — ACL precondition: anon must be refused, and so (surprisingly) is authenticated.
  ---------------------------------------------------------------------------
  set local role anon;
  perform set_config('request.jwt.claims', null, true);
  begin
    g := app.evidence_block_v1('p','d', current_date-1, current_date, 5,5,5,0,'c');
    insert into _fail values ('PRE-anon','anon reached app.evidence_block_v1; expected a schema/execute refusal');
  exception when insufficient_privilege then null;   -- 42501, required
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('PRE-anon', format('anon call raised %s, expected 42501 (insufficient_privilege)', v_err));
  end;
  reset role;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_auth, 'role','authenticated')::text, true);
  begin
    g := app.evidence_block_v1('p','d', current_date-1, current_date, 5,5,5,0,'c');
    -- If this ever stops raising, the finding below is stale and should be deleted, not silenced.
    insert into _fail values ('PRE-authenticated-STALE',
      'authenticated could now call app.evidence_block_v1 directly -- the finding recorded in this file''s header no longer holds; update the comment, do not just delete this line');
  exception when insufficient_privilege then
    -- EXPECTED, and documented above: the v652 migration grants EXECUTE on this function to
    -- `authenticated`, but `authenticated` has no USAGE on schema `app` at all (baseline-
    -- grants.sql:37; matches production's real posture), so that grant is inert for any direct
    -- caller — only a SECURITY DEFINER wrapper (public.get_recovery_report_v550) can ever reach
    -- it. Recorded as a minor, informational finding in the file header; not asserted as a
    -- failure here because it is not a statistical-discipline defect and is (at worst) a
    -- misleading-but-harmless grant, not an access-control hole.
    null;
  when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PRE-authenticated', format('authenticated call raised %s, expected 42501', v_err));
  end;
  reset role;
  perform set_config('request.jwt.claims', null, true);

  -- S1-S6 below call app.evidence_block_v1 directly as the harness bootstrap role, matching
  -- every other internal app.* fixture in this corpus (v551_top_share_denominator.sql,
  -- v426_tier_resolver.sql, ...) and the real production call path through the SECURITY
  -- DEFINER wrapper, which runs as the function owner and is unaffected by the schema-usage
  -- gap documented above.

  ---------------------------------------------------------------------------
  -- S1a — floor at its DEFAULT (10): 5-per-arm must be 'insufficient' despite a 100pp gap.
  ---------------------------------------------------------------------------
  g := app.evidence_block_v1(
    'ZZ v652 S1a population', 'ZZ v652 S1a denominator', current_date-30, current_date,
    5, 5, 5, 0, 'ZZ v652 S1a comparison');
  if g->>'verdict' <> 'insufficient' then
    insert into _fail values ('S1a',
      format('5-per-arm (below default min_arm=10) returned verdict %s, expected insufficient', g->>'verdict'));
  end if;
  if (g->'sample'->>'treated')::int <> 5 or (g->'sample'->>'treated_events')::int <> 5
     or (g->'sample'->>'comparison')::int <> 5 or (g->'sample'->>'comparison_events')::int <> 0 then
    insert into _fail values ('S1a', format('sample block did not echo the exact inputs: %s', g->'sample'));
  end if;

  ---------------------------------------------------------------------------
  -- S1b — SAME 5-per-arm data, p_min_arm lowered to 3: the floor must genuinely stop applying,
  -- proving the parameter is read rather than a hardcoded 10.
  ---------------------------------------------------------------------------
  g := app.evidence_block_v1(
    'ZZ v652 S1b population', 'ZZ v652 S1b denominator', current_date-30, current_date,
    5, 5, 5, 0, 'ZZ v652 S1b comparison',
    p_max_verdict => 'strong_pattern', p_min_arm => 3);
  if g->>'verdict' = 'insufficient' then
    insert into _fail values ('S1b',
      'lowering p_min_arm to 3 (5-per-arm now above the floor) still returned insufficient; the parameter is not being read');
  end if;
  if (g->'difference'->>'absolute_pp')::numeric <> 100.0 then
    insert into _fail values ('S1b',
      format('expected a 100.0pp gap (100%% vs 0%%), got %s', g->'difference'->>'absolute_pp'));
  end if;
  -- Recorded Wald limitation: a perfect 5/5 split against a perfect 0/5 collapses se to zero,
  -- so the 95% interval is a single point (100.0, 100.0) at n=5 per arm. That IS today's
  -- documented behaviour (see file header) — not asserted as a failure, just pinned so a future
  -- change to the method is visible here.
  v_lo := (g->'difference'->'confidence_95_pp'->>0)::numeric;
  v_hi := (g->'difference'->'confidence_95_pp'->>1)::numeric;
  if v_lo <> 100.0 or v_hi <> 100.0 then
    insert into _fail values ('S1b-limitation',
      format('expected the documented zero-width degenerate interval [100.0,100.0] at n=5 with a perfect split, got [%s,%s]', v_lo, v_hi));
  end if;

  ---------------------------------------------------------------------------
  -- S2 — the three-of-three trap. n=3 per arm, default floor (10). Must be capped.
  ---------------------------------------------------------------------------
  g := app.evidence_block_v1(
    'ZZ v652 S2 population', 'ZZ v652 S2 denominator', current_date-14, current_date,
    3, 3, 3, 0, 'ZZ v652 S2 comparison');
  if g->>'verdict' <> 'insufficient' then
    insert into _fail values ('S2',
      format('a 3-of-3 (100%%) cohort vs 0-of-3 returned verdict %s, expected insufficient', g->>'verdict'));
  end if;
  if g->>'verdict' = 'strong_pattern' then
    insert into _fail values ('S2', 'the three-of-three trap produced strong_pattern outright');
  end if;

  ---------------------------------------------------------------------------
  -- S3 — a CI spanning zero, with both arms comfortably over the floor (n=50 each).
  ---------------------------------------------------------------------------
  g := app.evidence_block_v1(
    'ZZ v652 S3 population', 'ZZ v652 S3 denominator', current_date-30, current_date,
    50, 26, 50, 24, 'ZZ v652 S3 comparison');
  if g->>'verdict' <> 'insufficient' then
    insert into _fail values ('S3',
      format('52%% vs 48%% at n=50/arm (CI spans zero) returned verdict %s, expected insufficient', g->>'verdict'));
  end if;
  v_lo := (g->'difference'->'confidence_95_pp'->>0)::numeric;
  v_hi := (g->'difference'->'confidence_95_pp'->>1)::numeric;
  if v_lo >= 0 or v_hi <= 0 then
    insert into _fail values ('S3',
      format('expected an interval straddling zero, got [%s,%s] which does not', v_lo, v_hi));
  end if;
  if abs(v_lo - (-15.6)) > 0.1 or abs(v_hi - 23.6) > 0.1 then
    insert into _fail values ('S3',
      format('hand-computed CI is [-15.6, 23.6] pp +/-0.1, got [%s,%s]', v_lo, v_hi));
  end if;

  ---------------------------------------------------------------------------
  -- S4 — effect size (and the rest of the block) travels with the verdict.
  ---------------------------------------------------------------------------
  g := app.evidence_block_v1(
    'ZZ v652 S4 population', 'ZZ v652 S4 denominator', current_date-60, current_date,
    200, 100, 200, 60, 'ZZ v652 S4 comparison');
  if (g->'sample'->>'treated')::int <> 200 or (g->'sample'->>'treated_events')::int <> 100
     or (g->'sample'->>'comparison')::int <> 200 or (g->'sample'->>'comparison_events')::int <> 60 then
    insert into _fail values ('S4', format('sample block did not echo the exact inputs: %s', g->'sample'));
  end if;
  if (g->'rates'->>'treated_pct')::numeric <> 50.0 or (g->'rates'->>'comparison_pct')::numeric <> 30.0 then
    insert into _fail values ('S4',
      format('expected rates 50.0/30.0, got %s', g->'rates'));
  end if;
  if (g->'difference'->>'absolute_pp')::numeric <> 20.0 then
    insert into _fail values ('S4',
      format('expected absolute_pp = 20.0 exactly (hand-computed 0.5-0.3), got %s', g->'difference'->>'absolute_pp'));
  end if;
  if (g->'difference'->>'relative')::numeric <> 1.67 then
    insert into _fail values ('S4',
      format('expected relative = round(0.5/0.3,2) = 1.67 exactly, got %s', g->'difference'->>'relative'));
  end if;
  v_lo := (g->'difference'->'confidence_95_pp'->>0)::numeric;
  v_hi := (g->'difference'->'confidence_95_pp'->>1)::numeric;
  if abs(v_lo - 10.6) > 0.1 or abs(v_hi - 29.4) > 0.1 then
    insert into _fail values ('S4',
      format('hand-computed CI is [10.6, 29.4] pp +/-0.1, got [%s,%s]', v_lo, v_hi));
  end if;
  if g->>'verdict' <> 'strong_pattern' then
    insert into _fail values ('S4',
      format('this dataset (interval strictly positive, both arms over the floor) should earn strong_pattern under the default ceiling, got %s', g->>'verdict'));
  end if;

  ---------------------------------------------------------------------------
  -- S5 — the ceiling genuinely caps the verdict, on the exact same S4 data.
  ---------------------------------------------------------------------------
  g := app.evidence_block_v1(
    'ZZ v652 S5a population', 'ZZ v652 S5a denominator', current_date-60, current_date,
    200, 100, 200, 60, 'ZZ v652 S5a comparison',
    p_max_verdict => 'strong_pattern');
  if g->>'verdict' <> 'strong_pattern' or g->>'verdict_ceiling' <> 'strong_pattern' then
    insert into _fail values ('S5a', format('ceiling=strong_pattern gave verdict=%s ceiling=%s', g->>'verdict', g->>'verdict_ceiling'));
  end if;

  g := app.evidence_block_v1(
    'ZZ v652 S5b population', 'ZZ v652 S5b denominator', current_date-60, current_date,
    200, 100, 200, 60, 'ZZ v652 S5b comparison',
    p_max_verdict => 'early_signal');
  if g->>'verdict' <> 'early_signal' then
    insert into _fail values ('S5b',
      format('ceiling=early_signal on data that would otherwise be strong_pattern returned verdict=%s', g->>'verdict'));
  end if;
  if g->>'verdict_ceiling' <> 'early_signal' then
    insert into _fail values ('S5b', format('verdict_ceiling not echoed: %s', g->>'verdict_ceiling'));
  end if;

  g := app.evidence_block_v1(
    'ZZ v652 S5c population', 'ZZ v652 S5c denominator', current_date-60, current_date,
    200, 100, 200, 60, 'ZZ v652 S5c comparison',
    p_max_verdict => 'insufficient');
  if g->>'verdict' <> 'insufficient' then
    insert into _fail values ('S5c',
      format('ceiling=insufficient on data that would otherwise be strong_pattern returned verdict=%s', g->>'verdict'));
  end if;

  -- Bonus: an unsupported ceiling value must be rejected outright (documented in the migration),
  -- not silently coerced to something else.
  begin
    g := app.evidence_block_v1(
      'x','x', current_date-1, current_date, 200,100,200,60,'x', p_max_verdict => 'definitely_true');
    insert into _fail values ('S5-guard', 'an unsupported p_max_verdict value was accepted instead of raising');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('S5-guard', format('unsupported ceiling raised %s, expected 22023', v_err));
    end if;
  end;

  ---------------------------------------------------------------------------
  -- S6a — the interval method is disclosed verbatim.
  ---------------------------------------------------------------------------
  g := app.evidence_block_v1(
    'ZZ v652 S6a population', 'ZZ v652 S6a denominator', current_date-60, current_date,
    200, 100, 200, 60, 'ZZ v652 S6a comparison');
  if g->'difference'->>'method' <> 'normal approximation, 95% interval on the difference in rates' then
    insert into _fail values ('S6a',
      format('difference.method changed from the documented Wald disclosure: %s', g->'difference'->>'method'));
  end if;

  ---------------------------------------------------------------------------
  -- S6b — extreme small-n, near-boundary rates (90% vs 10%, n=10/arm, AT not below the floor).
  -- RECORDED LIMITATION, not a fix: an unadjusted Wald interval on the difference can produce a
  -- bound outside the only legally possible range for a percentage-point difference, [-100,100].
  -- This assertion is deliberately left able to fail — see file header. It is NOT weakened.
  ---------------------------------------------------------------------------
  g := app.evidence_block_v1(
    'ZZ v652 S6b population', 'ZZ v652 S6b denominator', current_date-10, current_date,
    10, 9, 10, 1, 'ZZ v652 S6b comparison');
  if (g->'sample'->>'treated')::int <> 10 or (g->'sample'->>'comparison')::int <> 10 then
    insert into _fail values ('S6b-pre', 'fixture did not land at n=10 per arm; the floor-boundary case would be untested');
  end if;
  v_lo := (g->'difference'->'confidence_95_pp'->>0)::numeric;
  v_hi := (g->'difference'->'confidence_95_pp'->>1)::numeric;
  if abs(v_lo - 53.7) > 0.2 or abs(v_hi - 106.3) > 0.2 then
    insert into _fail values ('S6b',
      format('hand-computed CI is [53.7, 106.3] pp +/-0.2 for 90%% vs 10%% at n=10/arm, got [%s,%s] -- recompute the truth table before trusting the next check', v_lo, v_hi));
  end if;
  if v_lo < -100 or v_lo > 100 or v_hi < -100 or v_hi > 100 then
    insert into _fail values ('S6b-defect',
      format('SUSPECTED PRODUCT DEFECT: app.evidence_block_v1 returned a percentage-point difference bound of [%s,%s], outside the only legal range [-100,100] for a difference between two rates. This is the unadjusted-Wald-interval limitation the v652 migration comment does not disclose numerically -- a Wilson/Agresti-Coull interval is bounded by construction and would not do this. Not fixed here per instructions; do not weaken this assertion.', v_lo, v_hi));
  end if;
  if g->>'verdict' = 'insufficient' then
    insert into _fail values ('S6b-context',
      'expected this n=10/arm, non-overlapping-CI case to clear the floor and NOT be capped to insufficient, which would have hidden the out-of-range interval behind a floor refusal instead of exposing it');
  end if;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$v652$;

select case when count(*)=0
            then 'PASS — v652 evidence contract: floor, CI-spans-zero, effect size, ceiling, and method all hold'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v652: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
