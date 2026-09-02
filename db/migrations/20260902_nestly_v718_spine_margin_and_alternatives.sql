-- NESTLY v718 — margin guard made live for service-bound candidates (check 74), a second,
-- non-incentive alternative kind for the discovery and change generators (check 77), and an
-- honest, documented non-fix for check 23 ("minor" materiality_class reachability) that does NOT
-- touch any frozen fixture.
--
-- ================================================================================================
-- REFUTER FINDINGS THIS MIGRATION CLOSES
-- ================================================================================================
-- (74) app.ci_margin_guard_v705 is called exactly ONCE inside public.get_ci_opportunities_v1, with
-- (p_business, null, 0) — v_margin_guard_cannibal, nestly_v705's own JC3 — because the ONLY
-- candidate whose OWN incentive.kind is 'credit'/'discount' (loyalty_cannibalisation_gap) names no
-- specific service. That call is CORRECT for that candidate and is NOT touched here (JC3 stands:
-- "candidates naming no service keep 'unavailable' with reason 'no service specified for this
-- incentive'"). The refuter's finding is a SEPARATE gap: every candidate whose 'alternatives' array
-- carries a kind='incentive' entry gets that entry's cost_basis from the SAME static
-- c_incentive_unavailable constant, REGARDLESS of whether the candidate actually names a service —
-- so the guard's 'blocked' branch was dead for every service-bound candidate, not just cosmetically
-- unused but structurally unreachable (no candidate ever supplied a real service_id to the function).
--
-- Read every generator (v688's header, and the body itself, grep for 'service_id'): the ONLY
-- candidate that carries a real public.services.id is gateway_followthrough:<service_id> (domain
-- 'service_intelligence'). category_concentration (domain 'category_mix') is NOT service-bound in
-- the current schema — its node comes from public.get_ci_category_mix_v1, which classifies revenue
-- by TAXONOMY NODE (public.taxonomy_nodes), and there is no column anywhere linking a
-- taxonomy_nodes.node_key (or the category payload) back to a single public.services.id (confirmed
-- by reading public.get_ci_category_mix_v1's live definition end to end and by grep across every
-- migration for a services<->taxonomy linkage column — none exists). Inventing a "this category ==
-- this one service" mapping would be exactly the fabrication v680's own header forbade ("no assumed
-- uplift smuggled in") — so category_concentration's margin_guard stays 'unavailable' with reason
-- 'no service specified for this incentive', UNCHANGED, honestly, rather than guessing a service.
-- package_leakage:<plan_id> similarly names a public.package_plans.id, not a public.services.id — a
-- package plan is not looked up by app.ci_margin_guard_v705 (which joins public.services), so it is
-- ALSO left alone. strength:service:<service_id> DOES carry a real service_id, but (post-nestly_v712)
-- its alternatives are [no_action, reminder_only] — it never had an 'incentive' kind alternative to
-- guard in the first place, so there is nothing to wire there either.
--
-- Fix: app.ci_standard_incentive_cents_v718() — the ONE place a "no candidate-specific amount
-- declared" incentive proposal lives, a flat cents figure (see JC1 below for why flat, and why this
-- exact figure), used ONLY for the gateway_followthrough candidate's 'incentive'-kind alternative
-- and (generically, so it always agrees with the alternative) that candidate's own top-level
-- 'margin_guard' key. Both are now REAL app.ci_margin_guard_v705(business, service_id, cents) calls,
-- keyed off the service_id embedded in the candidate's own id ('gateway_followthrough:' ||
-- service_id) — so 'ok'/'blocked' are both reachable from real data (a real price/cost pair), never
-- fabricated, and the pre-existing generic demotion pass (nestly_v705's own "when g.mg is blocked,
-- demote to unquantified with the guard's reason appended to limitation" — untouched by this
-- migration) picks the new per-candidate result up automatically, with no further wiring needed.
--
-- (77) discovery and change each emit exactly ONE alternative (kind='reminder_only', primary=true) —
-- failing "every candidate carries >=2 distinct alternative kinds including one non-incentive".
-- Fix: add a SECOND, non-primary, non-incentive kind to each, reusing data already on the candidate
-- (dimension/group) so nothing is invented:
--   discovery -> kind='operational_change', what='Investigate the driver behind <dimension>=<group>
--     before acting.'
--   change    -> kind='operational_change', what='Review what changed for <dimension> in the
--     window.' (the brief allows 'service_recovery' OR 'operational_change' here; 'change' fires on
--     ANY of five segment_dimensions [weekday/age_gender/category_node/acquisition_source/branch],
--     most of which are not service-shaped, so 'operational_change' — a general investigate-the-
--     driver lever — is the honest, non-domain-specific choice, not 'service_recovery', which
--     implies a specific service failed and would be a fabricated implication for e.g. a weekday or
--     branch deterioration.)
-- Both keep reminder_only as the sole primary=true entry (nestly_v688's own one-primary invariant,
-- reconfirmed by nestly_v712 for the three strength generators and staff_mix_underperformance) — the
-- new entry is added as primary=false, so no existing primary is demoted and the invariant holds by
-- construction rather than by a second edit.
--
-- (23) INVESTIGATED, NOT CHANGED — reported per this task's own instruction ("if any frozen fixture
-- would change, DO NOT edit it — report the assertion and both values and stop"). See section
-- "CHECK 23 — INVESTIGATION AND DELIBERATE NON-FIX" below for the full trace: the one honest fix
-- (making package_leakage's expected_value report {status:'unavailable'} instead of {cents:0} when
-- EVERY holder's app.return_probability_v681 call abstains) flips
-- db/tests/executed/v688_corpus_spine_v2.sql's frozen assertion A4 (line 407-409: "plan_small was
-- promoted despite EV 0 < the materiality bar" must NEVER fire) from PASS to FAIL, because an
-- 'unavailable' expected_value has no 'cents' key, which makes the PRE-EXISTING (untouched, v688's
-- own) EV-materiality gate pass the candidate through UNCONDITIONALLY instead of filtering it — so
-- plan_small would flip from "absent from ranked, abstained with reason 'below_materiality:...'" to
-- "present in ranked with materiality_class='minor'". That fixture is frozen; this migration does
-- NOT make that change. Nothing in app.ci_materiality_threshold_bps_v705, the mc classification
-- lateral, or the EV gate is touched by this migration.
--
-- ================================================================================================
-- JUDGEMENT CALLS
-- ================================================================================================
-- JC1 — app.ci_standard_incentive_cents_v718() returns a FLAT 4000 (cents), not a percentage of the
-- named service's price. A percentage was considered and rejected: nestly_v705's own executed
-- fixture (db/tests/executed/v705_corpus_spine_v3.sql, section A, "BIZ_MG direct calls") already
-- fixes 4000/2000/5000 (incentive/cost/price) as the canonical worked illustration for this exact
-- function ("NOTE the brief's own worked example (price 5000/cost 2000/incentive 4000)... this
-- fixture asserts the ARITHMETICALLY CORRECT margin (3000)") — reusing that SAME figure here, rather
-- than deriving a new one from a percentage-of-price formula, keeps every worked example in this
-- migration set consistent with the one nestly_v705 already committed to, and avoids inventing a
-- discount-percentage policy this migration was never asked to design. A flat cents figure is also
-- consistent with this engine's existing style of single-authority POLICY constants (c_gap_pp,
-- c_util_pct, c_conc_bps, c_reach_pct, c_cannibal_pct, c_staff_index_bar, and now
-- app.ci_materiality_threshold_bps_v705 itself) — none of those are derived from the row they judge
-- either. A future change (e.g. a percentage-of-price policy, or a per-business configurable amount)
-- touches this ONE function.
--
-- JC2 — the per-candidate margin guard is computed TWICE (once inline inside the base-generator
-- enrichment loop, for the alternative's cost_basis; once again in the post-gate generic lateral
-- pass, for the top-level margin_guard key) rather than computed once and threaded between the two
-- passes. app.ci_margin_guard_v705 is `stable` (a single read of public.services inside the same
-- statement/transaction), and both calls use IDENTICAL arguments (the same service_id parsed from
-- the same candidate id, the same app.ci_standard_incentive_cents_v718() constant) — so the two
-- calls are guaranteed to agree, and this avoids restructuring either pass's anchors (each stays a
-- single, independently-provable substitution, matching the discipline nestly_v705/v712 already
-- established) to smuggle a value between them.
--
-- Method: the SAME capture-anchor-replace-verify-roundtrip discipline as
-- db/migrations/20260902_nestly_v696_spine_typed_verdicts.sql, ..._v705_spine_v3.sql, and
-- ..._v712_spine_wording_closures.sql — capture public.get_ci_opportunities_v1's LIVE body (post-
-- v712) via pg_get_functiondef, assert each of four anchors occurs EXACTLY ONCE, apply four chained
-- replace() substitutions inside one CREATE OR REPLACE, then reverse all four against the new live
-- body and require the round-trip to reproduce the captured original byte-for-byte. Nothing here
-- hand-retypes the ~1950-line function body. No candidate id, key, or count already shipped by
-- v678/v680/v688/v696/v705/v712 is touched; the base pass (p_extended=>false) is untouched by every
-- one of these four substitutions.
--
-- ROLLBACK: re-apply the captured pre-v718 body verbatim (the temp table this migration builds
-- prints it on failure), or reverse each of the four substitutions by hand — the post-check block
-- names each one.

begin;

-- ================================================================================================
-- CHECK 23 — INVESTIGATION AND DELIBERATE NON-FIX (no schema/function change in this section)
-- ================================================================================================
-- 'minor' materiality_class is architecturally unreachable for a non-degenerate (realistic-revenue)
-- business: any candidate whose expected_value.cents is present is, BY CONSTRUCTION, already >=
-- v_ev_bar (the SAME 1%-of-period-revenue bar the classifier itself uses, unified onto ONE authority
-- by nestly_v712) — v688's own pre-existing EV-materiality gate filters out (as an
-- 'below_materiality:...' abstention) every EV-bearing candidate below that bar BEFORE it ever
-- reaches the materiality_class lateral, so an EV-bearing candidate that survives to classification
-- can only ever be 'material'. 'minor' can therefore only arise from the classifier's OTHER path —
-- expected_value genuinely unavailable, but a real scenario_cents (impact.cents) figure survives —
-- and no generator in the live body currently produces that combination: package_leakage is the only
-- generator whose impact.cents is ever a real non-null number, and its own expected_value computation
-- ALWAYS returns a numeric 'cents' key (defaulting to 0 via coalesce(sum(...),0) when every holder's
-- app.return_probability_v681 call abstains) rather than reporting {status:'unavailable'} — every
-- other generator's impact.cents is null unconditionally, by deliberate design (no assumed uplift).
--
-- The one honest fix considered — make package_leakage's expected_value say {status:'unavailable'}
-- when EVERY holder abstains, rather than {cents:0} — was traced end to end against the frozen
-- fixture db/tests/executed/v688_corpus_spine_v2.sql, section A4 (its own comment: "package_leakage:
-- plan_small — the materiality-gate mode-diff mutation check"). plan_small's 5 holders (K1..K5) have
-- no other sale ever recorded, so every one of them is exactly the "abstains" case. TODAY: v_ev_pkg_
-- cents = 0 (a present 'cents' key) fails the EV gate (0 < v_ev_bar for this business's real, non-
-- trivial revenue) -> plan_small is ABSENT from `ranked`, with an abstention `{generator:
-- 'package_leakage:<plan_sm>', reason: 'below_materiality:...'}` — asserted at lines 407-409:
--   if exists (select 1 from jsonb_array_elements(ranked) c
--               where c->>'id' = 'package_leakage:' || plan_sm::text) then
--     insert into _fail values ('A4-promoted', 'plan_small was promoted despite EV 0 < the
--       materiality bar');
--   end if;
-- WITH THE FIX: expected_value becomes {status:'unavailable', reason:'every holder''s return-
-- probability model abstained; no behavioural estimate available'} — this jsonb has NO 'cents' key,
-- so the EV gate's own clause `(e->'impact'->'expected_value'->>'cents') is null` is now TRUE, which
-- means the gate lets the candidate through UNCONDITIONALLY (that clause exists precisely so a
-- genuinely-unquantified candidate is never penalised for lacking a number) — plan_small would then
-- be PRESENT in `ranked`, and since its scenario_cents (impact.cents, the raw unused-session value,
-- unaffected by this change) is small relative to this business's real revenue, its
-- materiality_class would resolve to 'minor'. That is precisely two DIFFERENT values
-- (ABSENT-from-ranked/abstained vs PRESENT-in-ranked/materiality_class='minor') for the SAME frozen
-- assertion (A4-promoted) — the fixture is frozen, so this migration does NOT make that change.
-- 'minor' remains a structurally-valid, correctly-implemented classification (the classifier's own
-- logic already matches the check-23 brief's definition exactly: scenario-only or unquantified-EV
-- candidates whose scenario cents is below the bar) that no currently-live generator happens to
-- produce outside the degenerate near-zero-revenue case nestly_v705's own BIZ_MINOR fixture already
-- demonstrates. Making it reachable for a realistic business needs a generator-level change (which
-- one is now known and traced above) that this migration declines to make because it breaks a frozen
-- fixture, not because the direction is wrong.

do $v718_note$
begin
  raise notice 'nestly_v718: check 23 (materiality_class minor reachability) investigated, NOT '
    'changed — see this migration''s own header/body comment "CHECK 23 — INVESTIGATION AND '
    'DELIBERATE NON-FIX": the one honest fix (package_leakage EV honestly abstaining when every '
    'holder''s return-probability model abstains) flips db/tests/executed/v688_corpus_spine_v2.sql''s '
    'frozen A4-promoted assertion from PASS to FAIL (plan_small: absent-from-ranked/abstained today '
    'vs present-in-ranked/materiality_class=minor with the fix) — reported and stopped per '
    'instruction, not implemented.';
end
$v718_note$;

-- ================================================================================================
-- 1 · app.ci_standard_incentive_cents_v718() — the ONE place the "no candidate-specific amount
--     declared" incentive proposal lives (check 74, JC1 above). Internal-only, same lock-down style
--     as app.ci_materiality_threshold_bps_v705.
-- ================================================================================================
create or replace function app.ci_standard_incentive_cents_v718()
returns bigint
language sql
immutable
as $ci718inc$
  select 4000::bigint;   -- the standard "no declared amount" proposed incentive, in cents.
$ci718inc$;
revoke all on function app.ci_standard_incentive_cents_v718() from public, anon, authenticated;
grant execute on function app.ci_standard_incentive_cents_v718() to authenticated, service_role;

-- ================================================================================================
-- 2 · Capture the LIVE public.get_ci_opportunities_v1 body (post-v712) and assert every anchor
--     occurs exactly once before touching it — a silent no-op here would look exactly like a
--     successful fix.
-- ================================================================================================
create temp table _v718_before(def text) on commit drop;

do $v718pre$
declare
  v_n integer;
  v_def text;
  v_count integer;

  a1 constant text := $a1$          jsonb_build_object('kind', 'incentive', 'primary', false,
            'what', 'Offer a discount or loyalty credit to prompt a second visit.',
            'cost_basis', c_incentive_unavailable))$a1$;

  a2 constant text := $a2$    cross join lateral (
      select case when t.c->'incentive'->>'kind' in ('credit', 'discount')
                  then v_margin_guard_cannibal else null end as mg
    ) g$a2$;

  a3 constant text := $a3$      'reversal_condition', format('Reconsider this call if the difference falls back under %s '
                                    'points on the next holdout split.', v_dsc.d->>'diff_pp'),
      'alternatives', jsonb_build_array(jsonb_build_object('kind', 'reminder_only', 'primary', true,
        'what', 'Note it and monitor, no spend.',
        'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend'))),$a3$;

  a4 constant text := $a4$      'reversal_condition', format('Reconsider this call if the holdout-half rate recovers to '
                                    'within %s points of the train-half rate.', v_dsc.d->>'diff_pp'),
      'alternatives', jsonb_build_array(jsonb_build_object('kind', 'reminder_only', 'primary', true,
        'what', 'Note it and monitor, no spend.',
        'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend'))),$a4$;
begin
  insert into _v718_before(def)
  select pg_get_functiondef(p.oid)
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = 'get_ci_opportunities_v1'
     and p.pronargs = 6;

  select count(*) into v_n from _v718_before;
  if v_n <> 1 then
    raise exception
      'v718: expected exactly one public.get_ci_opportunities_v1(uuid,date,date,uuid,timestamptz,'
      'boolean), found %; this migration''s anchors are written against the post-v712 body', v_n;
  end if;

  select def into v_def from _v718_before;

  v_count := (length(v_def) - length(replace(v_def, a1, ''))) / length(a1);
  if v_count <> 1 then raise exception 'v718: anchor 1 (service_intelligence incentive alt) occurs % times (expected 1)', v_count; end if;
  v_count := (length(v_def) - length(replace(v_def, a2, ''))) / length(a2);
  if v_count <> 1 then raise exception 'v718: anchor 2 (post-gate g lateral) occurs % times (expected 1)', v_count; end if;
  v_count := (length(v_def) - length(replace(v_def, a3, ''))) / length(a3);
  if v_count <> 1 then raise exception 'v718: anchor 3 (discovery alternatives) occurs % times (expected 1)', v_count; end if;
  v_count := (length(v_def) - length(replace(v_def, a4, ''))) / length(a4);
  if v_count <> 1 then raise exception 'v718: anchor 4 (change alternatives) occurs % times (expected 1)', v_count; end if;
end
$v718pre$;

-- ================================================================================================
-- 3 · The four anchored substitutions, applied together, executed as one CREATE OR REPLACE.
-- ================================================================================================
do $v718patch$
declare
  v_def text;
  v_expected text;

  a1 constant text := $a1$          jsonb_build_object('kind', 'incentive', 'primary', false,
            'what', 'Offer a discount or loyalty credit to prompt a second visit.',
            'cost_basis', c_incentive_unavailable))$a1$;
  n1 constant text := $n1$          jsonb_build_object('kind', 'incentive', 'primary', false,
            'what', 'Offer a discount or loyalty credit to prompt a second visit.',
            -- NESTLY v718 (check 74) — gateway_followthrough is the only base-generator candidate
            -- that names a real public.services.id (embedded in its own id); resolve the guard for
            -- real instead of the static c_incentive_unavailable fallback.
            'cost_basis', case when v_id like 'gateway_followthrough:%' then
              app.ci_margin_guard_v705(p_business,
                nullif(split_part(v_id, ':', 2), '')::uuid,
                app.ci_standard_incentive_cents_v718())
            else c_incentive_unavailable end))$n1$;

  a2 constant text := $a2$    cross join lateral (
      select case when t.c->'incentive'->>'kind' in ('credit', 'discount')
                  then v_margin_guard_cannibal else null end as mg
    ) g$a2$;
  n2 constant text := $n2$    cross join lateral (
      -- NESTLY v718 (check 74) — the SAME resolution as the service_intelligence alternatives case
      -- above (JC2 in this migration's header: computed twice, both calls agree by construction
      -- since app.ci_margin_guard_v705 is stable and both use identical arguments), so
      -- gateway_followthrough's top-level margin_guard key and its alternative's cost_basis are
      -- never out of step. Every other candidate is untouched: loyalty_cannibalisation_gap (the
      -- only OTHER incentive.kind in ('credit','discount')) still resolves via the pre-existing
      -- v_margin_guard_cannibal constant (nestly_v705 JC3 — it names no service, stays
      -- 'unavailable'); every remaining candidate still resolves to null (impact.margin
      -- 'not_applicable', nestly_v712).
      select case
               when t.c->>'id' like 'gateway_followthrough:%' then
                 app.ci_margin_guard_v705(p_business,
                   nullif(split_part(t.c->>'id', ':', 2), '')::uuid,
                   app.ci_standard_incentive_cents_v718())
               when t.c->'incentive'->>'kind' in ('credit', 'discount') then v_margin_guard_cannibal
               else null
             end as mg
    ) g$n2$;

  a3 constant text := $a3$      'reversal_condition', format('Reconsider this call if the difference falls back under %s '
                                    'points on the next holdout split.', v_dsc.d->>'diff_pp'),
      'alternatives', jsonb_build_array(jsonb_build_object('kind', 'reminder_only', 'primary', true,
        'what', 'Note it and monitor, no spend.',
        'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend'))),$a3$;
  n3 constant text := $n3$      'reversal_condition', format('Reconsider this call if the difference falls back under %s '
                                    'points on the next holdout split.', v_dsc.d->>'diff_pp'),
      -- NESTLY v718 (check 77) — a second, non-primary, non-incentive alternative kind, reusing the
      -- candidate's own dimension/group (nothing invented).
      'alternatives', jsonb_build_array(
        jsonb_build_object('kind', 'reminder_only', 'primary', true,
          'what', 'Note it and monitor, no spend.',
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
        jsonb_build_object('kind', 'operational_change', 'primary', false,
          'what', format('Investigate the driver behind %s=%s before acting.',
                          v_dsc.d->>'dimension', v_dsc.d->>'group'),
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0,
            'note', 'operational, no incentive spend'))),$n3$;

  a4 constant text := $a4$      'reversal_condition', format('Reconsider this call if the holdout-half rate recovers to '
                                    'within %s points of the train-half rate.', v_dsc.d->>'diff_pp'),
      'alternatives', jsonb_build_array(jsonb_build_object('kind', 'reminder_only', 'primary', true,
        'what', 'Note it and monitor, no spend.',
        'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend'))),$a4$;
  n4 constant text := $n4$      'reversal_condition', format('Reconsider this call if the holdout-half rate recovers to '
                                    'within %s points of the train-half rate.', v_dsc.d->>'diff_pp'),
      -- NESTLY v718 (check 77) — a second, non-primary, non-incentive alternative kind. Deliberately
      -- 'operational_change' rather than 'service_recovery': 'change' fires on ANY of five
      -- segment_dimensions (weekday/age_gender/category_node/acquisition_source/branch), most of
      -- which are not service-shaped, so implying a specific service failed would be a fabricated
      -- implication for e.g. a weekday or branch deterioration (see this migration's own header).
      'alternatives', jsonb_build_array(
        jsonb_build_object('kind', 'reminder_only', 'primary', true,
          'what', 'Note it and monitor, no spend.',
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
        jsonb_build_object('kind', 'operational_change', 'primary', false,
          'what', format('Review what changed for %s in the window.', v_dsc.d->>'dimension'),
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0,
            'note', 'operational, no incentive spend'))),$n4$;
begin
  select def into v_def from _v718_before;

  v_expected := replace(v_def, a1, n1);
  v_expected := replace(v_expected, a2, n2);
  v_expected := replace(v_expected, a3, n3);
  v_expected := replace(v_expected, a4, n4);

  execute v_expected;
end
$v718patch$;

revoke all on function public.get_ci_opportunities_v1(uuid,date,date,uuid,timestamptz,boolean) from public, anon;
grant execute on function public.get_ci_opportunities_v1(uuid,date,date,uuid,timestamptz,boolean)
  to authenticated, service_role;

-- ================================================================================================
-- 4 · Reverse all four substitutions against the NEW live body and require the round-trip to equal
--     the captured original, byte for byte.
-- ================================================================================================
do $v718post$
declare
  v_before text;
  v_after  text;
  v_roundtrip text;

  a1 constant text := $a1$          jsonb_build_object('kind', 'incentive', 'primary', false,
            'what', 'Offer a discount or loyalty credit to prompt a second visit.',
            'cost_basis', c_incentive_unavailable))$a1$;
  n1 constant text := $n1$          jsonb_build_object('kind', 'incentive', 'primary', false,
            'what', 'Offer a discount or loyalty credit to prompt a second visit.',
            -- NESTLY v718 (check 74) — gateway_followthrough is the only base-generator candidate
            -- that names a real public.services.id (embedded in its own id); resolve the guard for
            -- real instead of the static c_incentive_unavailable fallback.
            'cost_basis', case when v_id like 'gateway_followthrough:%' then
              app.ci_margin_guard_v705(p_business,
                nullif(split_part(v_id, ':', 2), '')::uuid,
                app.ci_standard_incentive_cents_v718())
            else c_incentive_unavailable end))$n1$;

  a2 constant text := $a2$    cross join lateral (
      select case when t.c->'incentive'->>'kind' in ('credit', 'discount')
                  then v_margin_guard_cannibal else null end as mg
    ) g$a2$;
  n2 constant text := $n2$    cross join lateral (
      -- NESTLY v718 (check 74) — the SAME resolution as the service_intelligence alternatives case
      -- above (JC2 in this migration's header: computed twice, both calls agree by construction
      -- since app.ci_margin_guard_v705 is stable and both use identical arguments), so
      -- gateway_followthrough's top-level margin_guard key and its alternative's cost_basis are
      -- never out of step. Every other candidate is untouched: loyalty_cannibalisation_gap (the
      -- only OTHER incentive.kind in ('credit','discount')) still resolves via the pre-existing
      -- v_margin_guard_cannibal constant (nestly_v705 JC3 — it names no service, stays
      -- 'unavailable'); every remaining candidate still resolves to null (impact.margin
      -- 'not_applicable', nestly_v712).
      select case
               when t.c->>'id' like 'gateway_followthrough:%' then
                 app.ci_margin_guard_v705(p_business,
                   nullif(split_part(t.c->>'id', ':', 2), '')::uuid,
                   app.ci_standard_incentive_cents_v718())
               when t.c->'incentive'->>'kind' in ('credit', 'discount') then v_margin_guard_cannibal
               else null
             end as mg
    ) g$n2$;

  a3 constant text := $a3$      'reversal_condition', format('Reconsider this call if the difference falls back under %s '
                                    'points on the next holdout split.', v_dsc.d->>'diff_pp'),
      'alternatives', jsonb_build_array(jsonb_build_object('kind', 'reminder_only', 'primary', true,
        'what', 'Note it and monitor, no spend.',
        'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend'))),$a3$;
  n3 constant text := $n3$      'reversal_condition', format('Reconsider this call if the difference falls back under %s '
                                    'points on the next holdout split.', v_dsc.d->>'diff_pp'),
      -- NESTLY v718 (check 77) — a second, non-primary, non-incentive alternative kind, reusing the
      -- candidate's own dimension/group (nothing invented).
      'alternatives', jsonb_build_array(
        jsonb_build_object('kind', 'reminder_only', 'primary', true,
          'what', 'Note it and monitor, no spend.',
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
        jsonb_build_object('kind', 'operational_change', 'primary', false,
          'what', format('Investigate the driver behind %s=%s before acting.',
                          v_dsc.d->>'dimension', v_dsc.d->>'group'),
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0,
            'note', 'operational, no incentive spend'))),$n3$;

  a4 constant text := $a4$      'reversal_condition', format('Reconsider this call if the holdout-half rate recovers to '
                                    'within %s points of the train-half rate.', v_dsc.d->>'diff_pp'),
      'alternatives', jsonb_build_array(jsonb_build_object('kind', 'reminder_only', 'primary', true,
        'what', 'Note it and monitor, no spend.',
        'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend'))),$a4$;
  n4 constant text := $n4$      'reversal_condition', format('Reconsider this call if the holdout-half rate recovers to '
                                    'within %s points of the train-half rate.', v_dsc.d->>'diff_pp'),
      -- NESTLY v718 (check 77) — a second, non-primary, non-incentive alternative kind. Deliberately
      -- 'operational_change' rather than 'service_recovery': 'change' fires on ANY of five
      -- segment_dimensions (weekday/age_gender/category_node/acquisition_source/branch), most of
      -- which are not service-shaped, so implying a specific service failed would be a fabricated
      -- implication for e.g. a weekday or branch deterioration (see this migration's own header).
      'alternatives', jsonb_build_array(
        jsonb_build_object('kind', 'reminder_only', 'primary', true,
          'what', 'Note it and monitor, no spend.',
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
        jsonb_build_object('kind', 'operational_change', 'primary', false,
          'what', format('Review what changed for %s in the window.', v_dsc.d->>'dimension'),
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0,
            'note', 'operational, no incentive spend'))),$n4$;
begin
  select def into v_before from _v718_before;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = 'get_ci_opportunities_v1'
     and p.pronargs = 6;

  v_roundtrip := replace(v_after, n1, a1);
  v_roundtrip := replace(v_roundtrip, n2, a2);
  v_roundtrip := replace(v_roundtrip, n3, a3);
  v_roundtrip := replace(v_roundtrip, n4, a4);

  if v_roundtrip <> v_before then
    raise exception
      'v718: the new definition differs from the old one by more than the four intended '
      'substitutions — reversing them did not reproduce the original body.';
  end if;

  if position('ci_standard_incentive_cents_v718' in v_after) = 0 then
    raise exception 'v718: app.ci_standard_incentive_cents_v718() call did not make it into the new body';
  end if;
  if position($chk1$'gateway_followthrough:%'$chk1$ in v_after) = 0 then
    raise exception 'v718: the gateway_followthrough service_id like-match did not make it into the new body';
  end if;
  if position('Investigate the driver behind' in v_after) = 0 then
    raise exception 'v718: the discovery operational_change alternative did not make it into the new body';
  end if;
  if position('Review what changed for' in v_after) = 0 then
    raise exception 'v718: the change operational_change alternative did not make it into the new body';
  end if;
end
$v718post$;

commit;
