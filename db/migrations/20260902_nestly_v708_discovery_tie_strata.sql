-- NESTLY v708 -- check 68 REFUTATION FIX #3 (Customer Intelligence discovery confounder verdicts:
-- exact-tie strata were silently agreeing).
--
-- Reads: docs/qa/CI-100-CHECKLIST.md check 68 ("Confounder checks. Service, staff, branch,
-- customer mix, prior behaviour and competing campaigns are tested where relevant."),
-- db/migrations/20260902_nestly_v702_discovery_verdict_rigor.sql (the confound_final CTE this
-- migration extract-and-diffs from -- grepped: no migration after v702 touches confound_agg /
-- survivors_with_confound / confound_final / confound_block / the 'unverified' list membership
-- test; v706 re-emitted this function's decl/anchors/scope/current_pct only, none of which
-- overlap the region patched here). Proven by db/tests/executed/v708_corpus_discovery_ties.sql.
--
-- THE REFUTER RESIDUAL: confound_agg buckets each checked (eligible) stratum by
-- sign(g_rate - rest_rate) vs the candidate's own aggregate sign (focus_sign). strata_consistent
-- counts stratum_sign = focus_sign (stratum_sign <> 0), strata_reversed counts
-- stratum_sign <> focus_sign (stratum_sign <> 0). An EXACT TIE -- stratum_sign = 0, i.e. the
-- stratum's own group rate and rest rate are identical, no difference in either direction -- is
-- counted in NEITHER bucket, yet confound_final's verdict CASE only tested
-- `when strata_reversed = 0 then 'consistent'`. A survivor with, say, 3 checked strata where 2 are
-- exact ties and 1 agrees has strata_reversed = 0 (true) and sailed to 'consistent' -- promoted to
-- 'discoveries' with the note "sign holds across all 3 checked strata", which is false: the sign
-- held in exactly 1 of those 3, and was simply never contradicted in the other 2 because there was
-- no signal there at all. A tie is not agreement, and "not disagreement" is not "consistent".
--
-- THE FIX. confound_agg gains strata_tied (count where stratum_sign = 0), carried through
-- survivors_with_confound into confound_final/confound_block exactly like strata_checked/
-- strata_consistent/strata_reversed already are. confound_final's verdict CASE now requires
-- 'consistent' to mean every checked stratum actually agreed -- strata_reversed = 0 AND
-- strata_consistent = strata_checked (equivalently, strata_tied = 0) -- and a strand where
-- strata_reversed = 0 but strata_tied > 0 gets a new, distinct verdict, 'tied', rather than being
-- folded into 'consistent' (refutation 2's exact mistake, now fixed a second way in the same
-- function) or into 'reversed'/'mixed' (which would falsely claim a stratum disagreed when it
-- merely showed nothing). confound_block's 'note' gains a 'tied' branch
-- ("N of M checked strata showed no difference; not promoted") and restates the 'consistent'
-- branch to report the consistent/checked counts explicitly rather than implying agreement from
-- the absence of reversal alone. The 'unverified' list-membership test (previously
-- confound_verdict = 'unchecked' only) now reads confound_verdict in ('unchecked','tied') --
-- 'tied' means "the check ran but found nothing to disagree or agree with," which is exactly the
-- same caller-facing posture as 'unchecked' ("not promoted, read the confounders block yourself"),
-- so it goes to the same disclosure list. 'discoveries' (confound_verdict = 'consistent' only,
-- since v702) and 'confounded' (confound_verdict in ('mixed','reversed'), unchanged since v702)
-- need no membership change: a 'tied' survivor was never eligible for either, since it satisfies
-- neither's test.
--
-- Every patch below is an anchored extract-and-diff replace-equality edit of the LIVE body
-- (pg_get_functiondef captured at apply time), verified to round-trip back to the exact live
-- original once the intended edits are reversed -- same discipline as v668/v690/v698/v702/v706,
-- never a hand-retyped guess at the base text.
--
-- Re-emits ONLY public.get_ci_discovery_v1. Does not touch get_ci_service_intelligence_v1 (v707)
-- or get_ci_opportunities_v1 (v705), nor app.customer_cadence_v1 / app.v179_business_insights /
-- get_ci_funnel_conversion_v1 / get_ci_retention_windows_v1 / get_ci_demographic_cohort_v1 (all
-- v706, none of which touch discovery's confounder machinery).

begin;

do $patch_discovery_ties$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_discovery_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v708: public.get_ci_discovery_v1(uuid,date,date,uuid,timestamptz) not found';
  end if;
  if position('strata_tied' in v_def) > 0 then
    raise exception 'v708: strata_tied already present in the live body -- this migration already applied';
  end if;

  -- Anchor 1: confound_agg -- add strata_tied alongside strata_checked/strata_consistent/strata_reversed.
  v_count := (length(v_def) - length(replace(v_def, $zzv708tag1zzz$           count(*) filter (where stratum_sign <> focus_sign and stratum_sign <> 0) as strata_reversed,$zzv708tag1zzz$, ''))) / greatest(length($zzv708tag2zzz$           count(*) filter (where stratum_sign <> focus_sign and stratum_sign <> 0) as strata_reversed,$zzv708tag2zzz$), 1);
  if v_count <> 1 then
    raise exception 'v708: discovery.agg anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  -- Anchor 2: survivors_with_confound -- carry strata_tied through with the same coalesce shape.
  v_count := (length(v_def) - length(replace(v_def, $zzv708tag3zzz$           coalesce(ca.strata_reversed, 0) as strata_reversed,$zzv708tag3zzz$, ''))) / greatest(length($zzv708tag4zzz$           coalesce(ca.strata_reversed, 0) as strata_reversed,$zzv708tag4zzz$), 1);
  if v_count <> 1 then
    raise exception 'v708: discovery.survivors anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  -- Anchor 3: confound_final -- 'consistent' now requires strata_consistent = strata_checked
  -- (no ties); a reversed=0 survivor with at least one tie is 'tied', not 'consistent'.
  v_count := (length(v_def) - length(replace(v_def, $zzv708tag5zzz$           case when strata_checked = 0 then 'unchecked'
                when strata_reversed::numeric / strata_checked > 0.5 then 'reversed'
                when strata_reversed = 0 then 'consistent'
                else 'mixed' end as verdict$zzv708tag5zzz$, ''))) / greatest(length($zzv708tag6zzz$           case when strata_checked = 0 then 'unchecked'
                when strata_reversed::numeric / strata_checked > 0.5 then 'reversed'
                when strata_reversed = 0 then 'consistent'
                else 'mixed' end as verdict$zzv708tag6zzz$), 1);
  if v_count <> 1 then
    raise exception 'v708: discovery.verdict_case anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  -- Anchor 4: confound_block jsonb -- disclose strata_tied alongside the other three counts.
  v_count := (length(v_def) - length(replace(v_def, $zzv708tag7zzz$             'strata_reversed', strata_reversed,
             'verdict', verdict,$zzv708tag7zzz$, ''))) / greatest(length($zzv708tag8zzz$             'strata_reversed', strata_reversed,
             'verdict', verdict,$zzv708tag8zzz$), 1);
  if v_count <> 1 then
    raise exception 'v708: discovery.block_fields anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  -- Anchor 5: confound_block's 'note' case -- add the 'tied' branch, restate 'consistent' honestly.
  v_count := (length(v_def) - length(replace(v_def, $zzv708tag9zzz$             'note', case verdict
               when 'reversed' then format(
                 'sign reverses in %s of %s checked strata (a majority); the aggregate direction '
                 'may be driven by an uneven mix of %s across strata rather than a genuine '
                 'within-stratum effect', strata_reversed, strata_checked, group_key)
               when 'mixed' then format(
                 '%s of %s checked strata reverse sign; interpret the aggregate direction with caution',
                 strata_reversed, strata_checked)
               when 'unchecked' then
                 'no other dimension cleared the floor on both sides; not promoted'
               else format('sign holds across all %s checked strata', strata_checked)
             end,$zzv708tag9zzz$, ''))) / greatest(length($zzv708tag10zzz$             'note', case verdict
               when 'reversed' then format(
                 'sign reverses in %s of %s checked strata (a majority); the aggregate direction '
                 'may be driven by an uneven mix of %s across strata rather than a genuine '
                 'within-stratum effect', strata_reversed, strata_checked, group_key)
               when 'mixed' then format(
                 '%s of %s checked strata reverse sign; interpret the aggregate direction with caution',
                 strata_reversed, strata_checked)
               when 'unchecked' then
                 'no other dimension cleared the floor on both sides; not promoted'
               else format('sign holds across all %s checked strata', strata_checked)
             end,$zzv708tag10zzz$), 1);
  if v_count <> 1 then
    raise exception 'v708: discovery.block_note anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  -- Anchor 6: 'unverified' list membership -- 'tied' joins 'unchecked' (same caller-facing posture:
  -- the check ran, or could not; either way nothing was promoted, and the confounders block is
  -- the one place that says why).
  v_count := (length(v_def) - length(replace(v_def, $zzv708tag11zzz$          from survivor_replicated sr where sr.replicated and sr.confound_verdict = 'unchecked'), '[]'::jsonb),$zzv708tag11zzz$, ''))) / greatest(length($zzv708tag12zzz$          from survivor_replicated sr where sr.replicated and sr.confound_verdict = 'unchecked'), '[]'::jsonb),$zzv708tag12zzz$), 1);
  if v_count <> 1 then
    raise exception 'v708: discovery.unverified_filter anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := v_def;
  v_expected := replace(v_expected, $zzv708tag13zzz$           count(*) filter (where stratum_sign <> focus_sign and stratum_sign <> 0) as strata_reversed,$zzv708tag13zzz$, $zzv708tag14zzz$           count(*) filter (where stratum_sign <> focus_sign and stratum_sign <> 0) as strata_reversed,
           count(*) filter (where stratum_sign = 0) as strata_tied,$zzv708tag14zzz$);
  v_expected := replace(v_expected, $zzv708tag15zzz$           coalesce(ca.strata_reversed, 0) as strata_reversed,$zzv708tag15zzz$, $zzv708tag16zzz$           coalesce(ca.strata_reversed, 0) as strata_reversed,
           coalesce(ca.strata_tied, 0) as strata_tied,$zzv708tag16zzz$);
  v_expected := replace(v_expected, $zzv708tag17zzz$           case when strata_checked = 0 then 'unchecked'
                when strata_reversed::numeric / strata_checked > 0.5 then 'reversed'
                when strata_reversed = 0 then 'consistent'
                else 'mixed' end as verdict$zzv708tag17zzz$, $zzv708tag18zzz$           case when strata_checked = 0 then 'unchecked'
                when strata_reversed::numeric / strata_checked > 0.5 then 'reversed'
                -- v708 (check 68 refutation 3): strata_reversed = 0 alone does not mean every
                -- checked stratum agreed -- an exact tie (stratum_sign = 0) is neither consistent
                -- nor reversed, and used to fall silently into 'consistent'. 'consistent' now
                -- requires every checked stratum to have actually agreed (strata_consistent =
                -- strata_checked); a reversed=0 survivor with at least one tie gets its own
                -- verdict, 'tied', disclosed as unverified rather than promoted.
                when strata_reversed = 0 and strata_consistent = strata_checked then 'consistent'
                when strata_reversed = 0 then 'tied'
                else 'mixed' end as verdict$zzv708tag18zzz$);
  v_expected := replace(v_expected, $zzv708tag19zzz$             'strata_reversed', strata_reversed,
             'verdict', verdict,$zzv708tag19zzz$, $zzv708tag20zzz$             'strata_reversed', strata_reversed,
             'strata_tied', strata_tied,
             'verdict', verdict,$zzv708tag20zzz$);
  v_expected := replace(v_expected, $zzv708tag21zzz$             'note', case verdict
               when 'reversed' then format(
                 'sign reverses in %s of %s checked strata (a majority); the aggregate direction '
                 'may be driven by an uneven mix of %s across strata rather than a genuine '
                 'within-stratum effect', strata_reversed, strata_checked, group_key)
               when 'mixed' then format(
                 '%s of %s checked strata reverse sign; interpret the aggregate direction with caution',
                 strata_reversed, strata_checked)
               when 'unchecked' then
                 'no other dimension cleared the floor on both sides; not promoted'
               else format('sign holds across all %s checked strata', strata_checked)
             end,$zzv708tag21zzz$, $zzv708tag22zzz$             'note', case verdict
               when 'reversed' then format(
                 'sign reverses in %s of %s checked strata (a majority); the aggregate direction '
                 'may be driven by an uneven mix of %s across strata rather than a genuine '
                 'within-stratum effect', strata_reversed, strata_checked, group_key)
               when 'mixed' then format(
                 '%s of %s checked strata reverse sign; interpret the aggregate direction with caution',
                 strata_reversed, strata_checked)
               when 'unchecked' then
                 'no other dimension cleared the floor on both sides; not promoted'
               when 'tied' then format(
                 '%s of %s checked strata showed no difference; not promoted',
                 strata_tied, strata_checked)
               else format('sign holds in %s of %s checked strata (no ties)', strata_consistent, strata_checked)
             end,$zzv708tag22zzz$);
  v_expected := replace(v_expected, $zzv708tag23zzz$          from survivor_replicated sr where sr.replicated and sr.confound_verdict = 'unchecked'), '[]'::jsonb),$zzv708tag23zzz$, $zzv708tag24zzz$          from survivor_replicated sr where sr.replicated and sr.confound_verdict in ('unchecked','tied')), '[]'::jsonb),$zzv708tag24zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_discovery_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $zzv708tag25zzz$          from survivor_replicated sr where sr.replicated and sr.confound_verdict in ('unchecked','tied')), '[]'::jsonb),$zzv708tag25zzz$, $zzv708tag26zzz$          from survivor_replicated sr where sr.replicated and sr.confound_verdict = 'unchecked'), '[]'::jsonb),$zzv708tag26zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv708tag27zzz$             'note', case verdict
               when 'reversed' then format(
                 'sign reverses in %s of %s checked strata (a majority); the aggregate direction '
                 'may be driven by an uneven mix of %s across strata rather than a genuine '
                 'within-stratum effect', strata_reversed, strata_checked, group_key)
               when 'mixed' then format(
                 '%s of %s checked strata reverse sign; interpret the aggregate direction with caution',
                 strata_reversed, strata_checked)
               when 'unchecked' then
                 'no other dimension cleared the floor on both sides; not promoted'
               when 'tied' then format(
                 '%s of %s checked strata showed no difference; not promoted',
                 strata_tied, strata_checked)
               else format('sign holds in %s of %s checked strata (no ties)', strata_consistent, strata_checked)
             end,$zzv708tag27zzz$, $zzv708tag28zzz$             'note', case verdict
               when 'reversed' then format(
                 'sign reverses in %s of %s checked strata (a majority); the aggregate direction '
                 'may be driven by an uneven mix of %s across strata rather than a genuine '
                 'within-stratum effect', strata_reversed, strata_checked, group_key)
               when 'mixed' then format(
                 '%s of %s checked strata reverse sign; interpret the aggregate direction with caution',
                 strata_reversed, strata_checked)
               when 'unchecked' then
                 'no other dimension cleared the floor on both sides; not promoted'
               else format('sign holds across all %s checked strata', strata_checked)
             end,$zzv708tag28zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv708tag29zzz$             'strata_reversed', strata_reversed,
             'strata_tied', strata_tied,
             'verdict', verdict,$zzv708tag29zzz$, $zzv708tag30zzz$             'strata_reversed', strata_reversed,
             'verdict', verdict,$zzv708tag30zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv708tag31zzz$           case when strata_checked = 0 then 'unchecked'
                when strata_reversed::numeric / strata_checked > 0.5 then 'reversed'
                -- v708 (check 68 refutation 3): strata_reversed = 0 alone does not mean every
                -- checked stratum agreed -- an exact tie (stratum_sign = 0) is neither consistent
                -- nor reversed, and used to fall silently into 'consistent'. 'consistent' now
                -- requires every checked stratum to have actually agreed (strata_consistent =
                -- strata_checked); a reversed=0 survivor with at least one tie gets its own
                -- verdict, 'tied', disclosed as unverified rather than promoted.
                when strata_reversed = 0 and strata_consistent = strata_checked then 'consistent'
                when strata_reversed = 0 then 'tied'
                else 'mixed' end as verdict$zzv708tag31zzz$, $zzv708tag32zzz$           case when strata_checked = 0 then 'unchecked'
                when strata_reversed::numeric / strata_checked > 0.5 then 'reversed'
                when strata_reversed = 0 then 'consistent'
                else 'mixed' end as verdict$zzv708tag32zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv708tag33zzz$           coalesce(ca.strata_reversed, 0) as strata_reversed,
           coalesce(ca.strata_tied, 0) as strata_tied,$zzv708tag33zzz$, $zzv708tag34zzz$           coalesce(ca.strata_reversed, 0) as strata_reversed,$zzv708tag34zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv708tag35zzz$           count(*) filter (where stratum_sign <> focus_sign and stratum_sign <> 0) as strata_reversed,
           count(*) filter (where stratum_sign = 0) as strata_tied,$zzv708tag35zzz$, $zzv708tag36zzz$           count(*) filter (where stratum_sign <> focus_sign and stratum_sign <> 0) as strata_reversed,$zzv708tag36zzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v708: get_ci_discovery_v1 changed by more than the 6 intended edit(s) [agg, survivors, verdict_case, block_fields, block_note, unverified_filter]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_discovery_ties$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_discovery_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_discovery_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

commit;
