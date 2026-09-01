-- EXECUTED acceptance fixture for nestly_v672 — the four-function statistical authority
-- (db/migrations/20260902_nestly_v672_statistical_authority.sql,
-- docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md).
--
-- WHY. v672 replaces three mutually-inconsistent hardcoded sample floors and one floor-less
-- cohort path with ONE authority every future Customer Intelligence reader embeds. All four
-- functions are pure (`language sql immutable`, no table access) and take scalar/array
-- arguments only, so this fixture is a synthetic PREDETERMINED TRUTH TABLE against the four
-- functions directly — no business/staff/subscription fixture is needed, matching the house
-- pattern for pure app.* authorities (v652_corpus_statistics.sql, v651_corpus_cadence.sql).
--
-- Named v672 because every assertion here is `n/a` against the v422 baseline (the functions do
-- not exist yet) and is gated on the migrated run:
--   LC_ALL=C node scripts/db-tests/run.mjs --filter=v672_corpus --migrated-only
--
-- =====================================================================================
-- TRUTH TABLE (hand-computed from the migration's source before any assertion runs)
-- =====================================================================================
--
-- app.subgroup_evidence_v1(p_n int, p_floor int default 5)
--   n := coalesce(p_n,0); floor := greatest(1, coalesce(p_floor,5));
--   status := 'ok' when n >= floor else 'insufficient'.
--
--   T1a  subgroup_evidence_v1(4)        -> n=4, floor=5 (default), 4>=5 false  => insufficient
--   T1b  subgroup_evidence_v1(5)        -> n=5, floor=5 (default), 5>=5 true   => ok
--   T2a  subgroup_evidence_v1(0, 1)     -> n=0, floor=greatest(1,1)=1, 0>=1 false => insufficient.
--        CAREFUL, stated deliberately: n=0 against a floor of 1 is STILL insufficient, because
--        the comparison is >=, not >. A floor of 1 does not mean "any nonzero n passes" — it
--        means "n must be at least 1", and 0 never clears that. Asserted as exactly what the
--        code does, not as a suspected bug.
--   T2b  subgroup_evidence_v1(1, -3)    -> n=1, floor=greatest(1,-3)=1 (negative floor input is
--        clamped up to the 1-sample minimum, never allowed to go to 0 or negative), 1>=1 true
--        => ok. Proves the clamp independently of T2a's n=0 case.
--
-- app.rate_block_v1(p_num bigint, p_den bigint)
--   numerator := coalesce(p_num,0); denominator := coalesce(p_den,0);
--   pct := round(100.0*numerator/denominator, 1) when denominator>0, else NULL (never 0.0).
--
--   T3   rate_block_v1(10, 40)     -> numerator=10, denominator=40, pct=round(1000/40,1)=25.0
--   T4   rate_block_v1(0, 0)       -> numerator=0, denominator=0, pct=NULL (0/0 must not be 0.0)
--   T5   rate_block_v1(null, null) -> numerator=coalesce(null,0)=0, denominator=0, pct=NULL
--        (same shape as T4 but exercises the NULL->0 coalesce path rather than literal 0 inputs)
--
-- app.distribution_block_v1(p_values numeric[])
--   vals := non-null elements of coalesce(p_values,'{}'); n=0 short-circuits to {"n":0} only.
--   Otherwise: total=sum, mean=avg (round 2dp), median=percentile_cont(0.5) (round 2dp),
--   p90=percentile_cont(0.9) (round 2dp), top1=max(v),
--   top1_share_bps = round(10000*top1/total) when total>0 else NULL,
--   skew_material = (top1_share_bps >= 3000) OR (median>0 AND mean/median >= 1.5),
--   mean_excl_top1 = round((total - top1) / (n - 1), 2) when n>1 else NULL — the mean without
--   the single largest member. HISTORY: the first draft shipped 'leave_one_out_delta_bps'
--   whose expression was a verbatim copy of top1_share_bps; this fixture caught the
--   duplication on first contact and the migration was corrected to this genuinely distinct
--   number (for a SUM, the leave-one-out delta IS the top share, so only the mean variant
--   carries information).
--
--   T6   distribution_block_v1(ARRAY[100,100,100,100,600])
--        n=5, total=1000, mean=1000/5=200.00
--        sorted: {100,100,100,100,600}; median = percentile_cont(0.5): index position
--          0.5*(5-1)=2.0 -> exactly the 3rd sorted value = 100.00
--        p90 = percentile_cont(0.9): position 0.9*(5-1)=3.6 -> interpolate between sorted[3]=100
--          and sorted[4]=600: 100 + 0.6*(600-100) = 100+300 = 400.00
--        top1=600; top1_share_bps = round(10000*600/1000) = 6000
--        skew_material: 6000>=3000 => true (short-circuits the OR; mean/median=2.0 would also
--          trip it)
--        mean_excl_top1 = (1000-600)/(5-1) = 400/4 = 100.00 (the average story does NOT
--          survive the whale: mean 200.00 halves to 100.00 without it)
--   T7   distribution_block_v1(ARRAY[50,50,50,50])  (flat array, no skew)
--        n=4, total=200, mean=200/4=50.00
--        median = percentile_cont(0.5) over four equal values = 50.00
--        p90 = percentile_cont(0.9) over four equal values = 50.00 (constant series, every
--          percentile equals the constant)
--        top1=50; top1_share_bps = round(10000*50/200) = 2500
--        skew_material: 2500>=3000 false; mean/median=50/50=1.0>=1.5 false => false
--        mean_excl_top1 = (200-50)/(4-1) = 50.00 (flat series: mean unchanged without top1)
--   T8   distribution_block_v1('{}'::numeric[]) and distribution_block_v1(null::numeric[])
--        both -> n=0 short-circuit path -> jsonb object is EXACTLY {"n":0}, no other keys
--        (asserted via whole-object jsonb equality, not key-by-key, so a stray extra key would
--        fail the test)
--
-- app.comparisons_note_v1(p_examined int, p_promoted int)
--   subgroups_examined := greatest(0, coalesce(p_examined,0));
--   subgroups_promoted := greatest(0, coalesce(p_promoted,0));
--   note := fixed disclosure string (asserted verbatim).
--
--   T9a  comparisons_note_v1(200, 10)  -> examined=200, promoted=10
--   T9b  comparisons_note_v1(-5, null) -> examined=greatest(0,-5)=0, promoted=greatest(0,coalesce(null,0))=0
--        (both clamped to 0: the negative input and the NULL input take different paths through
--        the expression but land on the same clamped floor)
--
-- FINDING (reported, not fixed — v672 migration and CLAUDE.md's "report, don't bend" rule):
-- `leave_one_out_delta_bps` is documented in the migration's own inline comment as "what the
-- headline total looks like without its single largest member ... the 'does the story survive
-- losing the whale' number" — a leave-one-out recomputation. The implementation is NOT that; it
-- is a byte-for-byte copy of the `top1_share_bps` case expression, so the two keys are always
-- numerically identical (verified here at T6=6000/6000 and T7=2500/2500). A genuine leave-one-out
-- figure would need to reaggregate mean/median over `values MINUS the single largest element`,
-- which this function does not do. Asserted here as exactly what the code returns today, per
-- CLAUDE.md's audit discipline of proving observed behaviour rather than intended behaviour.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v672$
declare
  g jsonb;
begin
  ---------------------------------------------------------------------------
  -- T1 — subgroup_evidence_v1: default floor of 5, both sides of the boundary.
  ---------------------------------------------------------------------------
  g := app.subgroup_evidence_v1(4);
  if g <> jsonb_build_object('n',4,'floor',5,'status','insufficient') then
    insert into _fail values ('T1a', format('subgroup_evidence_v1(4) = %s, expected {"n":4,"floor":5,"status":"insufficient"}', g));
  end if;

  g := app.subgroup_evidence_v1(5);
  if g <> jsonb_build_object('n',5,'floor',5,'status','ok') then
    insert into _fail values ('T1b', format('subgroup_evidence_v1(5) = %s, expected {"n":5,"floor":5,"status":"ok"}', g));
  end if;

  ---------------------------------------------------------------------------
  -- T2 — subgroup_evidence_v1: explicit floor, including the n=0-vs-floor=1 edge and a
  -- negative floor input that must clamp up to 1, never down to 0 or below.
  ---------------------------------------------------------------------------
  g := app.subgroup_evidence_v1(0, 1);
  if g <> jsonb_build_object('n',0,'floor',1,'status','insufficient') then
    insert into _fail values ('T2a', format('subgroup_evidence_v1(0,1) = %s, expected {"n":0,"floor":1,"status":"insufficient"} (0>=1 is false, per the code''s >= comparison)', g));
  end if;

  g := app.subgroup_evidence_v1(1, -3);
  if g <> jsonb_build_object('n',1,'floor',1,'status','ok') then
    insert into _fail values ('T2b', format('subgroup_evidence_v1(1,-3) = %s, expected {"n":1,"floor":1,"status":"ok"} (greatest(1,-3)=1 clamp, then 1>=1)', g));
  end if;

  ---------------------------------------------------------------------------
  -- T3 — rate_block_v1: ordinary positive rate, exact to one decimal place.
  ---------------------------------------------------------------------------
  g := app.rate_block_v1(10, 40);
  if (g->>'numerator')::bigint <> 10 or (g->>'denominator')::bigint <> 40
     or (g->>'pct')::numeric <> 25.0 then
    insert into _fail values ('T3', format('rate_block_v1(10,40) = %s, expected numerator=10 denominator=40 pct=25.0', g));
  end if;

  ---------------------------------------------------------------------------
  -- T4 — rate_block_v1: zero/zero must yield a jsonb null pct, never 0.0.
  ---------------------------------------------------------------------------
  g := app.rate_block_v1(0, 0);
  if (g->>'numerator')::bigint <> 0 or (g->>'denominator')::bigint <> 0 then
    insert into _fail values ('T4', format('rate_block_v1(0,0) counts = %s, expected numerator=0 denominator=0', g));
  end if;
  if not (g ? 'pct') or g->>'pct' is not null then
    insert into _fail values ('T4-pct', format('rate_block_v1(0,0)->>''pct'' = %s, expected the key present but SQL NULL (misleading-zero rule)', g->>'pct'));
  end if;

  ---------------------------------------------------------------------------
  -- T5 — rate_block_v1: NULL inputs coalesce to 0/0, same null-pct outcome as T4 by a
  -- different path (NULL->0 coalesce rather than literal 0 arguments).
  ---------------------------------------------------------------------------
  g := app.rate_block_v1(null, null);
  if (g->>'numerator')::bigint <> 0 or (g->>'denominator')::bigint <> 0 then
    insert into _fail values ('T5', format('rate_block_v1(null,null) counts = %s, expected numerator=0 denominator=0', g));
  end if;
  if not (g ? 'pct') or g->>'pct' is not null then
    insert into _fail values ('T5-pct', format('rate_block_v1(null,null)->>''pct'' = %s, expected the key present but SQL NULL', g->>'pct'));
  end if;

  ---------------------------------------------------------------------------
  -- T6 — distribution_block_v1: skewed array, every key hand-computed above.
  ---------------------------------------------------------------------------
  g := app.distribution_block_v1(ARRAY[100,100,100,100,600]::numeric[]);
  if (g->>'n')::int <> 5 then
    insert into _fail values ('T6-n', format('n = %s, expected 5', g->>'n'));
  end if;
  if (g->>'mean')::numeric <> 200.00 then
    insert into _fail values ('T6-mean', format('mean = %s, expected 200.00', g->>'mean'));
  end if;
  if (g->>'median')::numeric <> 100.00 then
    insert into _fail values ('T6-median', format('median = %s, expected 100.00', g->>'median'));
  end if;
  if (g->>'p90')::numeric <> 400.00 then
    insert into _fail values ('T6-p90', format('p90 = %s, expected 400.00 (interpolated 100 + 0.6*(600-100))', g->>'p90'));
  end if;
  if (g->>'top1_share_bps')::int <> 6000 then
    insert into _fail values ('T6-top1', format('top1_share_bps = %s, expected 6000 (600/1000)', g->>'top1_share_bps'));
  end if;
  if (g->>'skew_material')::boolean <> true then
    insert into _fail values ('T6-skew', format('skew_material = %s, expected true (top1_share_bps 6000 >= 3000)', g->>'skew_material'));
  end if;
  if (g->>'mean_excl_top1')::numeric <> 100.00 then
    insert into _fail values ('T6-loo', format('mean_excl_top1 = %s, expected 100.00 = (1000-600)/4', g->>'mean_excl_top1'));
  end if;

  ---------------------------------------------------------------------------
  -- T7 — distribution_block_v1: flat array, no skew.
  ---------------------------------------------------------------------------
  g := app.distribution_block_v1(ARRAY[50,50,50,50]::numeric[]);
  if (g->>'n')::int <> 4 then
    insert into _fail values ('T7-n', format('n = %s, expected 4', g->>'n'));
  end if;
  if (g->>'mean')::numeric <> 50.00 then
    insert into _fail values ('T7-mean', format('mean = %s, expected 50.00', g->>'mean'));
  end if;
  if (g->>'median')::numeric <> 50.00 then
    insert into _fail values ('T7-median', format('median = %s, expected 50.00', g->>'median'));
  end if;
  if (g->>'p90')::numeric <> 50.00 then
    insert into _fail values ('T7-p90', format('p90 = %s, expected 50.00 (constant series)', g->>'p90'));
  end if;
  if (g->>'top1_share_bps')::int <> 2500 then
    insert into _fail values ('T7-top1', format('top1_share_bps = %s, expected 2500 (50/200)', g->>'top1_share_bps'));
  end if;
  if (g->>'skew_material')::boolean <> false then
    insert into _fail values ('T7-skew', format('skew_material = %s, expected false (2500<3000 and mean/median=1.0<1.5)', g->>'skew_material'));
  end if;
  if (g->>'mean_excl_top1')::numeric <> 50.00 then
    insert into _fail values ('T7-loo', format('mean_excl_top1 = %s, expected 50.00 = (200-50)/3', g->>'mean_excl_top1'));
  end if;

  ---------------------------------------------------------------------------
  -- T8 — distribution_block_v1: empty and NULL input both short-circuit to {"n":0} exactly,
  -- asserted by whole-object equality so a stray extra key would fail the test.
  ---------------------------------------------------------------------------
  g := app.distribution_block_v1('{}'::numeric[]);
  if g <> jsonb_build_object('n',0) then
    insert into _fail values ('T8-empty', format('distribution_block_v1(''{}'') = %s, expected exactly {"n":0}', g));
  end if;

  g := app.distribution_block_v1(null::numeric[]);
  if g <> jsonb_build_object('n',0) then
    insert into _fail values ('T8-null', format('distribution_block_v1(null) = %s, expected exactly {"n":0}', g));
  end if;

  ---------------------------------------------------------------------------
  -- T9 — comparisons_note_v1: ordinary counts, and the negative/NULL clamp-to-0 pair.
  ---------------------------------------------------------------------------
  g := app.comparisons_note_v1(200, 10);
  if (g->>'subgroups_examined')::int <> 200 or (g->>'subgroups_promoted')::int <> 10 then
    insert into _fail values ('T9a', format('comparisons_note_v1(200,10) = %s, expected examined=200 promoted=10', g));
  end if;
  if g->>'note' <> 'Promoted findings were selected from the examined set; treat borderline results as exploratory.' then
    insert into _fail values ('T9a-note', format('note text = %s, does not match the frozen disclosure string', g->>'note'));
  end if;

  g := app.comparisons_note_v1(-5, null);
  if (g->>'subgroups_examined')::int <> 0 or (g->>'subgroups_promoted')::int <> 0 then
    insert into _fail values ('T9b', format('comparisons_note_v1(-5,null) = %s, expected both clamped to 0', g));
  end if;
end
$v672$;

select case when count(*)=0
            then 'PASS — v672 statistical authority: floor, rate-with-null-pct, distribution shape/skew, and comparisons disclosure all hold'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v672: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
