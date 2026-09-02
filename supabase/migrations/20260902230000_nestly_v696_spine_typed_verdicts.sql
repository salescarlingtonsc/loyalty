-- NESTLY v696 — spine typed verdicts (check 17, spine half): a single canonical mapping from
-- generator name to evidence class, a payload-level statement of the policy that mapping
-- enforces, and an impact_class flag distinguishing a scenario figure from a modelled expected
-- value — all additive, none of it touching a single candidate literal already shipped.
--
-- ================================================================================================
-- WHAT THIS PROVES. Every candidate public.get_ci_opportunities_v1 emits, in both p_extended
-- modes, already carries an evidence_class of DIRECT_FACT or ASSOCIATION and never CAUSAL — that
-- was true the moment nestly_v688 shipped (grep the eighteen 'evidence_class' literals in that
-- migration and there is no third value). What did NOT exist until this migration is a single
-- function a caller (or a future generator author) can ask "what class does a candidate built
-- this way belong to", instead of fifteen independently-typed string literals scattered across a
-- 700-line body with no shared authority. app.ci_verdict_class_v696(p_generator text) is that
-- function. db/tests/executed/v696_corpus_spine_verdicts.sql proves two things about it: (1) it is
-- EXHAUSTIVE over every generator name public.get_ci_opportunities_v1's live body actually emits —
-- enumerated by regexp-scanning that body's own pg_get_functiondef text, not by trusting a
-- hand-written list that could silently drift — and (2) its answer for each of those names agrees
-- with the literal evidence_class the spine already ships for that generator.
--
-- ================================================================================================
-- JUDGEMENT CALL — lapsed_regulars is ASSOCIATION, not DIRECT_FACT.
-- ================================================================================================
-- A generator that compares a customer only against their OWN history reads, on first principles,
-- like a "customer's own recorded facts" case — the same bucket as an expiring credit or package
-- balance, or a birthday. lapsed_regulars is exactly that shape (app.customer_cadence_v1, compared
-- against nothing but that one customer's own median inter-visit interval) and yet nestly_v688
-- ships it as evidence_class 'ASSOCIATION' (see that migration, generator B), not 'DIRECT_FACT'.
-- This migration does NOT reclassify it. Two independent reasons converge on leaving it alone:
--   (a) "overdue" is itself the output of a STATISTICAL model (a median over noisy, unevenly-spaced
--       past intervals, with its own evidence floor) rather than a directly observed fact like a
--       credit expiry date or a stored birth date — the comparison is real, but what is compared
--       against is inferred, not recorded.
--   (b) db/tests/executed/v678_corpus_consultant_spine.sql and v688_corpus_spine_v2.sql are FROZEN
--       fixtures that assert this spine's contract byte-for-byte for every existing caller; edging
--       one candidate's evidence_class from ASSOCIATION to DIRECT_FACT would be exactly the kind of
--       silent behavioural drift those fixtures exist to catch, for a call that does not itself
--       need this migration's brief (which is additive keys plus a policy statement, not a re-
--       litigation of nestly_v688's own generator-by-generator judgement calls).
-- app.ci_verdict_class_v696 therefore encodes what nestly_v688 actually shipped, verified against
-- the live body rather than assumed, and is the single place a future disagreement with that
-- call should be resolved — not a silent divergence between what this function says and what the
-- spine emits.
--
-- ================================================================================================
-- WHAT CHANGES IN public.get_ci_opportunities_v1, MECHANICALLY.
-- ================================================================================================
-- Three anchored substitutions against the LIVE pg_get_functiondef text (the v688 body, confirmed
-- below by presence checks before touching it — no other migration in this tree redefines this
-- function between v688 and v696), each verified to occur EXACTLY ONCE before it is applied and
-- reversed-and-diffed against the original after, in the db/tests/executed/v690_corpus_dispersion_
-- floor.sql / v668 anchor-and-round-trip style: a targeted replace(), not a hand-retyped 700-line
-- function body.
--   1. v_result gains a top-level 'verdict_policy' key: {classes:['DIRECT_FACT','ASSOCIATION'],
--      causal_claims:'never'} — the caller-facing statement of the same invariant the fixture
--      proves mechanically. Added once, where v_result is first built, so both p_extended modes
--      carry it (extended mode only ever merges MORE keys into v_result afterward).
--   2. Immediately before the base-pass v_result is built, every candidate in v_ranked gains
--      impact.impact_class: 'scenario' when impact.cents carries a figure, 'none' when it does
--      not. Base-pass impact never carries an expected_value (that concept starts in extended
--      mode), so 'expected_value' cannot appear here — this is mechanical, not asserted.
--   3. Immediately after the extended-mode do_nothing/stale-evidence fallback line, every candidate
--      in v_ranked_ext gains the same key, now three-way: 'expected_value' when
--      impact.expected_value.cents is a real figure (lapsed_regulars, package_leakage:* only),
--      'scenario' when only impact.cents is (every other quantified/foundation candidate that
--      still states a cents figure), 'none' otherwise. Re-running the same computation on the
--      v_promoted_ext=0 fallback (which reuses v_ranked's own, already-enriched do_nothing/
--      stale-evidence entry) is idempotent — recomputing the same value twice, not a second kind
--      of enrichment.
-- No `'id'`, `'evidence_class'`, `'domain'`, or any other existing candidate key is touched by any
-- of the three substitutions. The function's signature, grants, and every other candidate field
-- are untouched, so CREATE OR REPLACE (not DROP + CREATE) is sufficient and the v688 grants stand.
--
-- ROLLBACK: re-apply v688's function body verbatim (its own migration file is the source of
-- truth); or reverse each of the three anchors below by hand — the post-check block prints exactly
-- what each one replaced.

begin;

-- ================================================================================================
-- 1 · app.ci_verdict_class_v696 — the canonical, exhaustive generator -> evidence-class mapping.
--     A brand-new function: nothing to diff against, so this is a plain CREATE.
-- ================================================================================================
create or replace function app.ci_verdict_class_v696(p_generator text)
returns jsonb
language plpgsql
immutable
as $ci696$
declare
  v_base  text := split_part(coalesce(p_generator, ''), ':', 1);
  v_class text;
  v_note  text;
begin
  case v_base
    -- DIRECT_FACT: built from this business's own recorded facts (its own sales, its own visits,
    -- its own coverage, its own weekday/category/service revenue) — never a comparison ACROSS
    -- customers or against another business.
    when 'funnel_bottleneck', 'category_concentration', 'package_leakage', 'contactability_gap',
         'data_quality_coverage', 'do_nothing', 'strength' then
      v_class := 'DIRECT_FACT';
      v_note  := 'built from this business''s own recorded facts, not a comparison across '
                 'customers or segments.';
    -- ASSOCIATION: a pattern observed across customers, staff, or segments — including a
    -- customer's OWN cadence, since "overdue" is the output of a statistical median-interval
    -- model, not a directly recorded fact (see this migration's header judgement call on
    -- lapsed_regulars). Never CAUSAL: nothing in this engine runs a controlled experiment.
    when 'lapsed_regulars', 'daypart_shift', 'gateway_followthrough', 'discovery', 'change',
         'no_discount_reminder', 'loyalty_cannibalisation_gap', 'staff_mix_underperformance' then
      v_class := 'ASSOCIATION';
      v_note  := 'an association observed across customers, staff, or segments — disclosed as '
                 'observed, never as caused.';
    else
      raise exception
        'app.ci_verdict_class_v696: unmapped generator "%" (base "%") — every generator '
        'public.get_ci_opportunities_v1 emits must be added here before it ships', p_generator, v_base
        using errcode = '22023';
  end case;
  return jsonb_build_object('class', v_class, 'note', v_note);
end;
$ci696$;

revoke all on function app.ci_verdict_class_v696(text) from public, anon, authenticated;
grant execute on function app.ci_verdict_class_v696(text) to authenticated, service_role;

-- ================================================================================================
-- 2 · Capture the live public.get_ci_opportunities_v1 body and refuse to run against a shape this
--     migration does not recognise — a silent no-op here would look exactly like a successful fix.
-- ================================================================================================
create temp table _v696_before(def text) on commit drop;

do $pre$
declare
  v_n integer;
  v_def text;
  v_anchor_policy constant text :=
E'    \'refusal_reason\', v_refusal,
    \'observed_since\', app.metric_observed_since_v1(\'ci_opportunities\', p_business));';
  v_anchor_base constant text :=
E'  else
    v_refusal := null;
  end if;

  -- =============================================================================================
  -- THE BASE (v680-identical) RESULT. Non-extended callers stop here.
  -- =============================================================================================
  v_result := jsonb_build_object(';
  v_anchor_ext constant text :=
E'  if v_promoted_ext = 0 then
    v_ranked_ext := v_ranked;  -- reuse the base pass\'s do_nothing/stale-evidence entry
  end if;';
  v_count integer;
begin
  insert into _v696_before(def)
  select pg_get_functiondef(p.oid)
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = 'get_ci_opportunities_v1'
     and p.pronargs = 6;

  select count(*) into v_n from _v696_before;
  if v_n <> 1 then
    raise exception
      'v696: expected exactly one public.get_ci_opportunities_v1(uuid,date,date,uuid,timestamptz,'
      'boolean), found %; this migration''s three anchors are written against the v688 body '
      'specifically', v_n;
  end if;

  select def into v_def from _v696_before;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_policy, ''))) / length(v_anchor_policy);
  if v_count <> 1 then
    raise exception
      'v696: verdict_policy anchor occurs % times (expected 1) — live body drifted from v688; '
      're-extract with pg_get_functiondef and re-diff rather than guessing', v_count;
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_base, ''))) / length(v_anchor_base);
  if v_count <> 1 then
    raise exception
      'v696: base-result impact_class anchor occurs % times (expected 1) — live body drifted from '
      'v688', v_count;
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_ext, ''))) / length(v_anchor_ext);
  if v_count <> 1 then
    raise exception
      'v696: extended-result impact_class anchor occurs % times (expected 1) — live body drifted '
      'from v688', v_count;
  end if;
end
$pre$;

-- ================================================================================================
-- 3 · The three anchored substitutions, applied together, then executed as one CREATE OR REPLACE.
-- ================================================================================================
do $patch$
declare
  v_def      text;
  v_expected text;
  v_anchor_policy constant text :=
E'    \'refusal_reason\', v_refusal,
    \'observed_since\', app.metric_observed_since_v1(\'ci_opportunities\', p_business));';
  v_new_policy constant text :=
E'    \'refusal_reason\', v_refusal,
    \'observed_since\', app.metric_observed_since_v1(\'ci_opportunities\', p_business),
    \'verdict_policy\', jsonb_build_object(
      \'classes\', jsonb_build_array(\'DIRECT_FACT\', \'ASSOCIATION\'),
      \'causal_claims\', \'never\'));';
  v_anchor_base constant text :=
E'  else
    v_refusal := null;
  end if;

  -- =============================================================================================
  -- THE BASE (v680-identical) RESULT. Non-extended callers stop here.
  -- =============================================================================================
  v_result := jsonb_build_object(';
  v_new_base constant text :=
E'  else
    v_refusal := null;
  end if;

  -- =============================================================================================
  -- NESTLY v696 (check 17, spine half) — impact_class, additive only. Base-pass impact never
  -- carries an expected_value (that concept starts in extended mode), so the only two reachable
  -- states here are \'scenario\' (impact.cents states a figure) and \'none\' (it does not). No
  -- literal evidence_class is touched anywhere in this function; app.ci_verdict_class_v696 is
  -- checked against those literals by db/tests/executed/v696_corpus_spine_verdicts.sql, never
  -- substituted into this body, so v678/v680/v688\'s byte-identical assertions cannot regress.
  -- =============================================================================================
  select coalesce(jsonb_agg(
           t.c || jsonb_build_object(\'impact\',
             (t.c->\'impact\') || jsonb_build_object(\'impact_class\',
               case when (t.c->\'impact\'->\'expected_value\'->>\'cents\') is not null
                      then \'expected_value\'
                    when (t.c->\'impact\'->>\'cents\') is not null then \'scenario\'
                    else \'none\' end))
           order by t.ord), \'[]\'::jsonb)
    into v_ranked
    from jsonb_array_elements(v_ranked) with ordinality as t(c, ord);

  -- =============================================================================================
  -- THE BASE (v680-identical) RESULT. Non-extended callers stop here.
  -- =============================================================================================
  v_result := jsonb_build_object(';
  v_anchor_ext constant text :=
E'  if v_promoted_ext = 0 then
    v_ranked_ext := v_ranked;  -- reuse the base pass\'s do_nothing/stale-evidence entry
  end if;';
  v_new_ext constant text :=
E'  if v_promoted_ext = 0 then
    v_ranked_ext := v_ranked;  -- reuse the base pass\'s do_nothing/stale-evidence entry
  end if;

  -- NESTLY v696 (check 17, spine half) — the same additive impact_class pass, now three-way:
  -- \'expected_value\' beats \'scenario\' beats \'none\'. Idempotent on the v_promoted_ext=0
  -- fallback above, which reuses an already-enriched v_ranked entry — recomputing the same value
  -- twice is harmless, not a second kind of enrichment.
  select coalesce(jsonb_agg(
           t.c || jsonb_build_object(\'impact\',
             (t.c->\'impact\') || jsonb_build_object(\'impact_class\',
               case when (t.c->\'impact\'->\'expected_value\'->>\'cents\') is not null
                      then \'expected_value\'
                    when (t.c->\'impact\'->>\'cents\') is not null then \'scenario\'
                    else \'none\' end))
           order by t.ord), \'[]\'::jsonb)
    into v_ranked_ext
    from jsonb_array_elements(v_ranked_ext) with ordinality as t(c, ord);';
begin
  select def into v_def from _v696_before;

  v_expected := replace(v_def, v_anchor_policy, v_new_policy);
  v_expected := replace(v_expected, v_anchor_base, v_new_base);
  v_expected := replace(v_expected, v_anchor_ext, v_new_ext);

  execute v_expected;
end
$patch$;

-- ================================================================================================
-- 4 · Prove the diff is exactly the diff that was intended: reverse all three substitutions against
--     the NEW live body and require the round-trip to equal the captured original, byte for byte.
-- ================================================================================================
do $post$
declare
  v_before     text;
  v_after      text;
  v_roundtrip  text;
  v_anchor_policy constant text :=
E'    \'refusal_reason\', v_refusal,
    \'observed_since\', app.metric_observed_since_v1(\'ci_opportunities\', p_business));';
  v_new_policy constant text :=
E'    \'refusal_reason\', v_refusal,
    \'observed_since\', app.metric_observed_since_v1(\'ci_opportunities\', p_business),
    \'verdict_policy\', jsonb_build_object(
      \'classes\', jsonb_build_array(\'DIRECT_FACT\', \'ASSOCIATION\'),
      \'causal_claims\', \'never\'));';
  v_anchor_base constant text :=
E'  else
    v_refusal := null;
  end if;

  -- =============================================================================================
  -- THE BASE (v680-identical) RESULT. Non-extended callers stop here.
  -- =============================================================================================
  v_result := jsonb_build_object(';
  v_new_base constant text :=
E'  else
    v_refusal := null;
  end if;

  -- =============================================================================================
  -- NESTLY v696 (check 17, spine half) — impact_class, additive only. Base-pass impact never
  -- carries an expected_value (that concept starts in extended mode), so the only two reachable
  -- states here are \'scenario\' (impact.cents states a figure) and \'none\' (it does not). No
  -- literal evidence_class is touched anywhere in this function; app.ci_verdict_class_v696 is
  -- checked against those literals by db/tests/executed/v696_corpus_spine_verdicts.sql, never
  -- substituted into this body, so v678/v680/v688\'s byte-identical assertions cannot regress.
  -- =============================================================================================
  select coalesce(jsonb_agg(
           t.c || jsonb_build_object(\'impact\',
             (t.c->\'impact\') || jsonb_build_object(\'impact_class\',
               case when (t.c->\'impact\'->\'expected_value\'->>\'cents\') is not null
                      then \'expected_value\'
                    when (t.c->\'impact\'->>\'cents\') is not null then \'scenario\'
                    else \'none\' end))
           order by t.ord), \'[]\'::jsonb)
    into v_ranked
    from jsonb_array_elements(v_ranked) with ordinality as t(c, ord);

  -- =============================================================================================
  -- THE BASE (v680-identical) RESULT. Non-extended callers stop here.
  -- =============================================================================================
  v_result := jsonb_build_object(';
  v_anchor_ext constant text :=
E'  if v_promoted_ext = 0 then
    v_ranked_ext := v_ranked;  -- reuse the base pass\'s do_nothing/stale-evidence entry
  end if;';
  v_new_ext constant text :=
E'  if v_promoted_ext = 0 then
    v_ranked_ext := v_ranked;  -- reuse the base pass\'s do_nothing/stale-evidence entry
  end if;

  -- NESTLY v696 (check 17, spine half) — the same additive impact_class pass, now three-way:
  -- \'expected_value\' beats \'scenario\' beats \'none\'. Idempotent on the v_promoted_ext=0
  -- fallback above, which reuses an already-enriched v_ranked entry — recomputing the same value
  -- twice is harmless, not a second kind of enrichment.
  select coalesce(jsonb_agg(
           t.c || jsonb_build_object(\'impact\',
             (t.c->\'impact\') || jsonb_build_object(\'impact_class\',
               case when (t.c->\'impact\'->\'expected_value\'->>\'cents\') is not null
                      then \'expected_value\'
                    when (t.c->\'impact\'->>\'cents\') is not null then \'scenario\'
                    else \'none\' end))
           order by t.ord), \'[]\'::jsonb)
    into v_ranked_ext
    from jsonb_array_elements(v_ranked_ext) with ordinality as t(c, ord);';
begin
  select def into v_before from _v696_before;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = 'get_ci_opportunities_v1'
     and p.pronargs = 6;

  v_roundtrip := replace(v_after, v_new_policy, v_anchor_policy);
  v_roundtrip := replace(v_roundtrip, v_new_base, v_anchor_base);
  v_roundtrip := replace(v_roundtrip, v_new_ext, v_anchor_ext);

  if v_roundtrip <> v_before then
    raise exception
      'v696: the new definition differs from the old one by more than the three intended '
      'substitutions — reversing them did not reproduce the original body. Roundtrip:%  %Before:%  %',
      E'\n', v_roundtrip, E'\n', v_before;
  end if;

  if position('impact_class' in v_before) > 0 then
    raise exception 'v696: impact_class already present before this migration — stop and re-read';
  end if;
  if position('impact_class' in v_after) = 0 then
    raise exception 'v696: impact_class did not make it into the new body';
  end if;
  if position('verdict_policy' in v_after) = 0 then
    raise exception 'v696: verdict_policy did not make it into the new body';
  end if;
end
$post$;

-- ================================================================================================
-- 5 · Self-certifying exhaustiveness: every generator name the LIVE (post-patch) body actually
--     emits must resolve through app.ci_verdict_class_v696 without raising. Belt-and-suspenders
--     alongside the fixture's own, independent extraction — this one runs at apply time, on
--     whatever shape the function has right now, not a hand-written list.
-- ================================================================================================
do $exhaustive$
declare
  v_def   text;
  v_names text[];
  v_name  text;
  v_class jsonb;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = 'get_ci_opportunities_v1'
     and p.pronargs = 6;

  select array_agg(distinct m[1]) into v_names
    from regexp_matches(v_def, '(?<!>)''(?:id|generator)''\s*,\s*''([a-z][a-z_]*)', 'g') as m;

  if v_names is null or array_length(v_names, 1) < 15 then
    raise exception
      'v696: extracted only % generator name(s) from the live body, expected at least 15 — the '
      'extraction regex itself may have drifted', coalesce(array_length(v_names, 1), 0);
  end if;

  foreach v_name in array v_names loop
    begin
      v_class := app.ci_verdict_class_v696(v_name);
    exception when others then
      raise exception
        'v696: app.ci_verdict_class_v696 does not map generator "%" that the live body emits — % ',
        v_name, sqlerrm;
    end;
    if v_class->>'class' not in ('DIRECT_FACT', 'ASSOCIATION') then
      raise exception 'v696: generator "%" mapped to non-typed class %', v_name, v_class->>'class';
    end if;
  end loop;
end
$exhaustive$;

commit;
