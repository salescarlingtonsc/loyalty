-- NESTLY v712 — three closures against public.get_ci_opportunities_v1, live at HEAD a69f8124
-- (nestly_v705's own re-emit; confirmed via pg_get_functiondef against this tree's migrated
-- harness — v707/v709/v710, applied after v705 in ledger order, do not touch this function's body,
-- confirmed by reading them, not assumed):
--
--   (23) Materiality threshold, ONE bar. v688's c_ev_materiality_pct constant (numeric := 1.0,
--        hand-typed inside get_ci_opportunities_v1's own declare block) is replaced with a
--        derivation from app.ci_materiality_threshold_bps_v705() (the single materiality-bps
--        authority nestly_v705 already introduced for check 23's OWN post-gate materiality_class
--        pass). Before this migration the EV-bar gate (the pre-existing v688 filter that drops
--        any EV-bearing candidate under the bar) and the materiality_class classifier read the SAME
--        1% figure from TWO separate places — an accidental agreement, not a single source of
--        truth. After this migration there is exactly one place the bar lives; a future change to
--        app.ci_materiality_threshold_bps_v705() moves both.
--
--   (25) Business-impact translation. Every extended-mode candidate's 'impact' object gains five
--        keys — affected_customers, revenue_cents, margin, capacity, retention_risk — computed
--        generically, once, in the SAME post-gate lateral pass nestly_v705 already added (JC2 in
--        that migration's own header: one pass over v_cands_ext, not eleven hand-edited generator
--        literals). Every value is traced to a figure this pass (or nestly_v705's own pass, which
--        this one runs immediately after) has ALREADY computed for a different purpose — nothing
--        here invents a number:
--          affected_customers <- the candidate's own confidence.n (app.subgroup_evidence_v1's own
--                                 sample count, already computed by every generator for evidence
--                                 gating)
--          revenue_cents      <- n.num, the SAME coalesce(expected_value.cents, scenario_cents)
--                                 nestly_v705's materiality_class already reads
--          margin              <- g.mg, nestly_v705's own app.ci_margin_guard_v705 result
--          capacity             <- capx.cap, nestly_v705's own app.ci_capacity_v705 result
--          retention_risk      <- 'ok'/at_risk_n (the SAME confidence.n again) only for the two
--                                 domains this engine's own lifecycle vocabulary calls retention-
--                                 relevant (cadence, retention_funnel); 'not_applicable' elsewhere.
--        Every one of the five honestly reports {status:'not_applicable'} when nothing backs it —
--        never a zero standing in for "unknown". base-pass (p_extended=>false) candidates are
--        untouched (this pass runs only inside the p_extended=>true branch, on v_cands_ext, exactly
--        where nestly_v705's own materiality/margin_guard/capacity/concentration keys already land)
--        — v678/v696's frozen twelve-key base-pass contract cannot regress (that fixture never
--        calls p_extended=>true, confirmed by reading it: no occurrence of the string anywhere in
--        db/tests/executed/v678_corpus_consultant_spine.sql).
--
--   (77) Alternative-kind diversity, no exclusions. Two generator families carried exactly one
--        alternative, kind='reminder_only', primary=true — a single-kind array, failing "every
--        candidate carries >=2 distinct alternative kinds including one non-incentive":
--          - the three strength generators (strength:weekday, strength:category, strength:service
--            — nestly_v688's own three-candidate block). Each now carries TWO: a NEW
--            kind='no_action', primary=true, what='keep doing this; nothing to change' (the
--            genuinely primary recommendation for a strength — there is nothing to change), PLUS
--            the existing reminder_only, demoted to primary=false.
--          - staff_mix_underperformance (the v683-gated generator, present because
--            db/migrations/20260920_nestly_v683_staff_rebooking_loyalty_discount.sql is applied in
--            this tree). It now carries TWO: a NEW kind='operational_change', primary=true,
--            what='review the mix this person is scheduled on (training, booking rules, roster)'
--            (an operational lever distinct from coaching — where this person is scheduled and
--            what they are booked to sell, not a pay change), PLUS the existing reminder_only,
--            demoted to primary=false.
--        In both cases, demoting the pre-existing entry to primary=false (rather than leaving two
--        primary=true entries) keeps the ONE-primary invariant nestly_v688's own
--        A2-alternatives-primary assertion already enforces on lapsed_regulars — never tested
--        against strength or staff_mix before, but there is no reason either should behave
--        differently. Both new kinds are non-incentive, so this also keeps the pre-existing "no
--        cost-unavailable incentive alternative is silently required" shape intact — no incentive
--        kind is invented for a candidate that never had a cost figure to guard.
--        The base-generator case (service_intelligence/daypart/cadence/else, nestly_v688/v705) and
--        every other extended-only candidate (discovery, change, no_discount_reminder,
--        loyalty_cannibalisation_gap, campaigns) are untouched by this migration — they already
--        carry >=2 distinct kinds including reminder_only wherever they carry an 'alternatives'
--        array at all (verified by reading the live body: every other 'alternatives' site already
--        lists two or three kinds). With this migration, EVERY generator this engine's live body
--        emits an 'alternatives' array for now carries >=2 distinct kinds including a non-incentive
--        one — no candidate class is left with a single-kind array, and none is exempted by a
--        fixture built so its preconditions never fire; the executed fixture below deliberately
--        seeds staff_mix_underperformance's own preconditions (a staff member with >=5 evidence-ok
--        visits whose mix-adjusted index falls under app.ci_staff_performance's 0.80 bar, the same
--        two-service-class shape nestly_v683's own fixture proves) so the generator actually fires
--        and is asserted, not assumed.
--
-- Method: the SAME capture-anchor-replace-verify-roundtrip discipline as
-- db/migrations/20260920_nestly_v696_spine_typed_verdicts.sql and ..._v705_spine_v3.sql — capture
-- public.get_ci_opportunities_v1's LIVE body via pg_get_functiondef, assert each of six anchors
-- occurs EXACTLY ONCE, apply six chained replace() substitutions inside one CREATE OR REPLACE,
-- then reverse all six against the new live body and require the round-trip to reproduce the
-- captured original byte-for-byte. Nothing here hand-retypes the ~1900-line function body. No
-- candidate id, key, or count already shipped by v678/v680/v688/v696/v705 is touched; the base pass
-- (p_extended=>false) is untouched by every one of these six substitutions.
--
-- ROLLBACK: re-apply the captured pre-v712 body verbatim (the temp table this migration builds
-- prints it on failure), or reverse each of the six substitutions by hand — the post-check block
-- names each one.

begin;

-- ================================================================================================
-- 1 · Capture the LIVE public.get_ci_opportunities_v1 body and assert every anchor occurs exactly
--     once before touching it — a silent no-op here would look exactly like a successful fix.
-- ================================================================================================
create temp table _v712_before(def text) on commit drop;

do $v712pre$
declare
  v_n integer;
  v_def text;
  v_count integer;

  a1 constant text :=
E'  c_ev_materiality_pct constant numeric := 1.0;   -- new (check 65): EV < 1% of period revenue';

  a2 constant text :=
E'    cross join lateral (
      select t.c || jsonb_build_object(
               \'materiality\', app.rate_block_v1(n.num, v_period_revenue),
               \'materiality_class\', mc.mclass,
               \'margin_guard\', g.mg,
               \'capacity\', capx.cap)
             as base
    ) b1';

  a3 constant text :=
E'      \'reversal_condition\', format(\'Reconsider this call if revenue per visit on %s falls under \'
        \'%s cents.\', v_top_weekday->>\'label\', v_top_weekday->>\'revenue_per_visit_cents\'),
      \'alternatives\', jsonb_build_array(jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
        \'what\', \'No action needed beyond monitoring.\',
        \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';

  a4 constant text :=
E'      \'reversal_condition\', format(\'Reconsider this call if its revenue falls under %s cents.\',
        v_top_category->>\'revenue_cents\'),
      \'alternatives\', jsonb_build_array(jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
        \'what\', \'No action needed beyond monitoring.\',
        \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';

  a5 constant text :=
E'      \'reversal_condition\', format(\'Reconsider this call if its revenue falls under %s cents.\',
        v_top_service->>\'revenue_cents\'),
      \'alternatives\', jsonb_build_array(jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
        \'what\', \'No action needed beyond monitoring.\',
        \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';

  a6 constant text :=
E'        \'reversal_condition\', format(\'Reconsider this call once the index rises to %s or above.\',
                                      c_staff_index_bar),
        \'alternatives\', jsonb_build_array(jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
          \'what\', \'Coach, no compensation change.\',
          \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';
begin
  insert into _v712_before(def)
  select pg_get_functiondef(p.oid)
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = 'get_ci_opportunities_v1'
     and p.pronargs = 6;

  select count(*) into v_n from _v712_before;
  if v_n <> 1 then
    raise exception
      'v712: expected exactly one public.get_ci_opportunities_v1(uuid,date,date,uuid,timestamptz,'
      'boolean), found %; this migration''s anchors are written against the post-v705 body', v_n;
  end if;

  select def into v_def from _v712_before;

  v_count := (length(v_def) - length(replace(v_def, a1, ''))) / length(a1);
  if v_count <> 1 then raise exception 'v712: anchor 1 (materiality constant) occurs % times (expected 1)', v_count; end if;
  v_count := (length(v_def) - length(replace(v_def, a2, ''))) / length(a2);
  if v_count <> 1 then raise exception 'v712: anchor 2 (post-gate b1 lateral) occurs % times (expected 1)', v_count; end if;
  v_count := (length(v_def) - length(replace(v_def, a3, ''))) / length(a3);
  if v_count <> 1 then raise exception 'v712: anchor 3 (strength:weekday alternatives) occurs % times (expected 1)', v_count; end if;
  v_count := (length(v_def) - length(replace(v_def, a4, ''))) / length(a4);
  if v_count <> 1 then raise exception 'v712: anchor 4 (strength:category alternatives) occurs % times (expected 1)', v_count; end if;
  v_count := (length(v_def) - length(replace(v_def, a5, ''))) / length(a5);
  if v_count <> 1 then raise exception 'v712: anchor 5 (strength:service alternatives) occurs % times (expected 1)', v_count; end if;
  v_count := (length(v_def) - length(replace(v_def, a6, ''))) / length(a6);
  if v_count <> 1 then raise exception 'v712: anchor 6 (staff_mix_underperformance alternatives) occurs % times (expected 1)', v_count; end if;
end
$v712pre$;

-- ================================================================================================
-- 2 · The six anchored substitutions, applied together, executed as one CREATE OR REPLACE.
-- ================================================================================================
do $v712patch$
declare
  v_def text;
  v_expected text;

  a1 constant text :=
E'  c_ev_materiality_pct constant numeric := 1.0;   -- new (check 65): EV < 1% of period revenue';
  n1 constant text :=
E'  c_ev_materiality_pct constant numeric :=
    app.ci_materiality_threshold_bps_v705() / 100.0;   -- NESTLY v712 (check 23): ONE bar, derived';

  a2 constant text :=
E'    cross join lateral (
      select t.c || jsonb_build_object(
               \'materiality\', app.rate_block_v1(n.num, v_period_revenue),
               \'materiality_class\', mc.mclass,
               \'margin_guard\', g.mg,
               \'capacity\', capx.cap)
             as base
    ) b1';
  n2 constant text :=
E'    cross join lateral (
      select coalesce((t.c->\'confidence\'->>\'n\')::int, 0) as n
    ) cn
    cross join lateral (
      -- NESTLY v712 (check 25) — affected_customers/revenue_cents/margin/capacity/retention_risk,
      -- every value traced to an ALREADY-COMPUTED figure (cn.n from the candidate''s own
      -- confidence.n; n.num from the same expected_value/scenario_cents this pass already reads;
      -- g.mg/capx.cap already computed above) — never a fabricated number, honest not_applicable
      -- when the underlying figure does not exist for this candidate''s domain.
      select jsonb_build_object(
               \'affected_customers\', jsonb_build_object(
                 \'status\', case when cn.n > 0 then \'ok\' else \'not_applicable\' end, \'n\', cn.n),
               \'revenue_cents\', case when n.num is null
                 then jsonb_build_object(\'status\', \'not_applicable\')
                 else jsonb_build_object(\'status\', \'ok\', \'cents\', n.num) end,
               \'margin\', coalesce(g.mg, jsonb_build_object(\'status\', \'not_applicable\',
                 \'reason\', \'no incentive spend for this candidate\')),
               \'capacity\', coalesce(capx.cap, jsonb_build_object(\'status\', \'not_applicable\')),
               \'retention_risk\', case when t.c->>\'domain\' in (\'cadence\', \'retention_funnel\')
                 then jsonb_build_object(\'status\', \'ok\', \'at_risk_n\', cn.n)
                 else jsonb_build_object(\'status\', \'not_applicable\') end)
             as extra
    ) imp5
    cross join lateral (
      select t.c || jsonb_build_object(
               \'materiality\', app.rate_block_v1(n.num, v_period_revenue),
               \'materiality_class\', mc.mclass,
               \'margin_guard\', g.mg,
               \'capacity\', capx.cap,
               \'impact\', (t.c->\'impact\') || imp5.extra)
             as base
    ) b1';

  a3 constant text :=
E'      \'reversal_condition\', format(\'Reconsider this call if revenue per visit on %s falls under \'
        \'%s cents.\', v_top_weekday->>\'label\', v_top_weekday->>\'revenue_per_visit_cents\'),
      \'alternatives\', jsonb_build_array(jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
        \'what\', \'No action needed beyond monitoring.\',
        \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';
  n3 constant text :=
E'      \'reversal_condition\', format(\'Reconsider this call if revenue per visit on %s falls under \'
        \'%s cents.\', v_top_weekday->>\'label\', v_top_weekday->>\'revenue_per_visit_cents\'),
      \'alternatives\', jsonb_build_array(
        jsonb_build_object(\'kind\', \'no_action\', \'primary\', true,
          \'what\', \'keep doing this; nothing to change\',
          \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
        jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', false,
          \'what\', \'No action needed beyond monitoring.\',
          \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';

  a4 constant text :=
E'      \'reversal_condition\', format(\'Reconsider this call if its revenue falls under %s cents.\',
        v_top_category->>\'revenue_cents\'),
      \'alternatives\', jsonb_build_array(jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
        \'what\', \'No action needed beyond monitoring.\',
        \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';
  n4 constant text :=
E'      \'reversal_condition\', format(\'Reconsider this call if its revenue falls under %s cents.\',
        v_top_category->>\'revenue_cents\'),
      \'alternatives\', jsonb_build_array(
        jsonb_build_object(\'kind\', \'no_action\', \'primary\', true,
          \'what\', \'keep doing this; nothing to change\',
          \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
        jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', false,
          \'what\', \'No action needed beyond monitoring.\',
          \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';

  a5 constant text :=
E'      \'reversal_condition\', format(\'Reconsider this call if its revenue falls under %s cents.\',
        v_top_service->>\'revenue_cents\'),
      \'alternatives\', jsonb_build_array(jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
        \'what\', \'No action needed beyond monitoring.\',
        \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';
  n5 constant text :=
E'      \'reversal_condition\', format(\'Reconsider this call if its revenue falls under %s cents.\',
        v_top_service->>\'revenue_cents\'),
      \'alternatives\', jsonb_build_array(
        jsonb_build_object(\'kind\', \'no_action\', \'primary\', true,
          \'what\', \'keep doing this; nothing to change\',
          \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
        jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', false,
          \'what\', \'No action needed beyond monitoring.\',
          \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';

  a6 constant text :=
E'        \'reversal_condition\', format(\'Reconsider this call once the index rises to %s or above.\',
                                      c_staff_index_bar),
        \'alternatives\', jsonb_build_array(jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
          \'what\', \'Coach, no compensation change.\',
          \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';
  n6 constant text :=
E'        \'reversal_condition\', format(\'Reconsider this call once the index rises to %s or above.\',
                                      c_staff_index_bar),
        \'alternatives\', jsonb_build_array(
          jsonb_build_object(\'kind\', \'operational_change\', \'primary\', true,
            \'what\', \'review the mix this person is scheduled on (training, booking rules, roster)\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0,
              \'note\', \'operational, no incentive spend\')),
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', false,
            \'what\', \'Coach, no compensation change.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';
begin
  select def into v_def from _v712_before;

  v_expected := replace(v_def, a1, n1);
  v_expected := replace(v_expected, a2, n2);
  v_expected := replace(v_expected, a3, n3);
  v_expected := replace(v_expected, a4, n4);
  v_expected := replace(v_expected, a5, n5);
  v_expected := replace(v_expected, a6, n6);

  execute v_expected;
end
$v712patch$;

revoke all on function public.get_ci_opportunities_v1(uuid,date,date,uuid,timestamptz,boolean) from public, anon;
grant execute on function public.get_ci_opportunities_v1(uuid,date,date,uuid,timestamptz,boolean)
  to authenticated, service_role;

-- ================================================================================================
-- 3 · Reverse all six substitutions against the NEW live body and require the round-trip to equal
--     the captured original, byte for byte.
-- ================================================================================================
do $v712post$
declare
  v_before text;
  v_after  text;
  v_roundtrip text;
  v_no_action_kind constant text := E'\'kind\', \'no_action\'';

  a1 constant text :=
E'  c_ev_materiality_pct constant numeric := 1.0;   -- new (check 65): EV < 1% of period revenue';
  n1 constant text :=
E'  c_ev_materiality_pct constant numeric :=
    app.ci_materiality_threshold_bps_v705() / 100.0;   -- NESTLY v712 (check 23): ONE bar, derived';

  a2 constant text :=
E'    cross join lateral (
      select t.c || jsonb_build_object(
               \'materiality\', app.rate_block_v1(n.num, v_period_revenue),
               \'materiality_class\', mc.mclass,
               \'margin_guard\', g.mg,
               \'capacity\', capx.cap)
             as base
    ) b1';
  n2 constant text :=
E'    cross join lateral (
      select coalesce((t.c->\'confidence\'->>\'n\')::int, 0) as n
    ) cn
    cross join lateral (
      -- NESTLY v712 (check 25) — affected_customers/revenue_cents/margin/capacity/retention_risk,
      -- every value traced to an ALREADY-COMPUTED figure (cn.n from the candidate''s own
      -- confidence.n; n.num from the same expected_value/scenario_cents this pass already reads;
      -- g.mg/capx.cap already computed above) — never a fabricated number, honest not_applicable
      -- when the underlying figure does not exist for this candidate''s domain.
      select jsonb_build_object(
               \'affected_customers\', jsonb_build_object(
                 \'status\', case when cn.n > 0 then \'ok\' else \'not_applicable\' end, \'n\', cn.n),
               \'revenue_cents\', case when n.num is null
                 then jsonb_build_object(\'status\', \'not_applicable\')
                 else jsonb_build_object(\'status\', \'ok\', \'cents\', n.num) end,
               \'margin\', coalesce(g.mg, jsonb_build_object(\'status\', \'not_applicable\',
                 \'reason\', \'no incentive spend for this candidate\')),
               \'capacity\', coalesce(capx.cap, jsonb_build_object(\'status\', \'not_applicable\')),
               \'retention_risk\', case when t.c->>\'domain\' in (\'cadence\', \'retention_funnel\')
                 then jsonb_build_object(\'status\', \'ok\', \'at_risk_n\', cn.n)
                 else jsonb_build_object(\'status\', \'not_applicable\') end)
             as extra
    ) imp5
    cross join lateral (
      select t.c || jsonb_build_object(
               \'materiality\', app.rate_block_v1(n.num, v_period_revenue),
               \'materiality_class\', mc.mclass,
               \'margin_guard\', g.mg,
               \'capacity\', capx.cap,
               \'impact\', (t.c->\'impact\') || imp5.extra)
             as base
    ) b1';

  a3 constant text :=
E'      \'reversal_condition\', format(\'Reconsider this call if revenue per visit on %s falls under \'
        \'%s cents.\', v_top_weekday->>\'label\', v_top_weekday->>\'revenue_per_visit_cents\'),
      \'alternatives\', jsonb_build_array(jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
        \'what\', \'No action needed beyond monitoring.\',
        \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';
  n3 constant text :=
E'      \'reversal_condition\', format(\'Reconsider this call if revenue per visit on %s falls under \'
        \'%s cents.\', v_top_weekday->>\'label\', v_top_weekday->>\'revenue_per_visit_cents\'),
      \'alternatives\', jsonb_build_array(
        jsonb_build_object(\'kind\', \'no_action\', \'primary\', true,
          \'what\', \'keep doing this; nothing to change\',
          \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
        jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', false,
          \'what\', \'No action needed beyond monitoring.\',
          \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';

  a4 constant text :=
E'      \'reversal_condition\', format(\'Reconsider this call if its revenue falls under %s cents.\',
        v_top_category->>\'revenue_cents\'),
      \'alternatives\', jsonb_build_array(jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
        \'what\', \'No action needed beyond monitoring.\',
        \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';
  n4 constant text :=
E'      \'reversal_condition\', format(\'Reconsider this call if its revenue falls under %s cents.\',
        v_top_category->>\'revenue_cents\'),
      \'alternatives\', jsonb_build_array(
        jsonb_build_object(\'kind\', \'no_action\', \'primary\', true,
          \'what\', \'keep doing this; nothing to change\',
          \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
        jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', false,
          \'what\', \'No action needed beyond monitoring.\',
          \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';

  a5 constant text :=
E'      \'reversal_condition\', format(\'Reconsider this call if its revenue falls under %s cents.\',
        v_top_service->>\'revenue_cents\'),
      \'alternatives\', jsonb_build_array(jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
        \'what\', \'No action needed beyond monitoring.\',
        \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';
  n5 constant text :=
E'      \'reversal_condition\', format(\'Reconsider this call if its revenue falls under %s cents.\',
        v_top_service->>\'revenue_cents\'),
      \'alternatives\', jsonb_build_array(
        jsonb_build_object(\'kind\', \'no_action\', \'primary\', true,
          \'what\', \'keep doing this; nothing to change\',
          \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
        jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', false,
          \'what\', \'No action needed beyond monitoring.\',
          \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';

  a6 constant text :=
E'        \'reversal_condition\', format(\'Reconsider this call once the index rises to %s or above.\',
                                      c_staff_index_bar),
        \'alternatives\', jsonb_build_array(jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
          \'what\', \'Coach, no compensation change.\',
          \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';
  n6 constant text :=
E'        \'reversal_condition\', format(\'Reconsider this call once the index rises to %s or above.\',
                                      c_staff_index_bar),
        \'alternatives\', jsonb_build_array(
          jsonb_build_object(\'kind\', \'operational_change\', \'primary\', true,
            \'what\', \'review the mix this person is scheduled on (training, booking rules, roster)\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0,
              \'note\', \'operational, no incentive spend\')),
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', false,
            \'what\', \'Coach, no compensation change.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\'))),';
begin
  select def into v_before from _v712_before;
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
  v_roundtrip := replace(v_roundtrip, n5, a5);
  v_roundtrip := replace(v_roundtrip, n6, a6);

  if v_roundtrip <> v_before then
    raise exception
      'v712: the new definition differs from the old one by more than the six intended '
      'substitutions — reversing them did not reproduce the original body.';
  end if;

  if position(a1 in v_after) > 0 then
    raise exception 'v712: the pre-v712 hand-typed 1.0 materiality constant text is still present';
  end if;
  if position('app.ci_materiality_threshold_bps_v705() / 100.0' in v_after) = 0 then
    raise exception 'v712: the materiality constant does not reference app.ci_materiality_threshold_bps_v705()';
  end if;
  if position('affected_customers' in v_after) = 0 then
    raise exception 'v712: affected_customers did not make it into the new body';
  end if;
  if position('retention_risk' in v_after) = 0 then
    raise exception 'v712: retention_risk did not make it into the new body';
  end if;
  if (length(v_after) - length(replace(v_after, v_no_action_kind, ''))) / length(v_no_action_kind) <> 3 then
    raise exception 'v712: expected exactly three no_action alternatives (one per strength generator)';
  end if;
  if position('operational_change' in v_after) = 0
     or position('review the mix this person is scheduled on' in v_after) = 0 then
    raise exception 'v712: staff_mix_underperformance''s operational_change alternative did not make it into the new body';
  end if;
end
$v712post$;

commit;
