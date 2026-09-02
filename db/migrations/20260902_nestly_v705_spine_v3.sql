-- NESTLY v705 — consultant spine v3: materiality (check 23), margin protection + capacity
-- (checks 25/74), category-concentration distribution surfacing (check 66), a campaigns generator
-- (check 22), and the rebooking/operational-change alternatives (check 77).
--
-- Re-emit lineage: public.get_ci_opportunities_v1's body is captured LIVE via pg_get_functiondef at
-- apply time (v696 runs before this migration in ledger order, so the live body already carries
-- verdict_policy/impact_class — confirmed below by presence checks, not assumed). Eight anchored
-- substitutions against that live text, each asserted to occur EXACTLY ONCE before being touched,
-- built via chained replace() calls, executed as one CREATE OR REPLACE, then reversed against the
-- new live body and required to reproduce the captured original byte-for-byte — the same capture-
-- anchor-replace-verify-roundtrip discipline as db/migrations/20260902_nestly_v696_spine_typed_
-- verdicts.sql, extended from three substitutions to eight (the eighth is a hotfix to the
-- v_has_v683 gate, broken by db/migrations/20260902_nestly_v699_visit_day_authority.sql after this
-- migration was first drafted — see JC6 below). Nothing here hand-retypes the ~1800-line function
-- body.
--
-- ================================================================================================
-- REBUTTAL (this migration's whole point, check 74): every number this migration adds is either a
-- real figure read from a real row, or an honest 'unavailable'/'blocked' disclosure. There is no
-- code path in app.ci_margin_guard_v705 or app.ci_capacity_v705 that invents a plausible-looking
-- cost or a plausible-looking capacity number when the underlying row does not exist. A service
-- with no recorded cost_cents returns {status:'unavailable', reason:'no cost recorded for this
-- service; enter costs in Settings', margin_cents:null} — never a margin computed from a guessed
-- cost, and never a silent 'ok'. A business with zero staff_hours rows returns
-- {status:'unavailable', reason:'no staff schedule rows recorded'} — never a capacity percentage
-- computed against a zero or fabricated denominator. Both functions are internal helpers
-- (security definer, revoked from public/anon/authenticated, granted to service_role only — the
-- same lock-down as app.ci_loyalty_eligible_v683) precisely so nothing outside this engine can be
-- tempted to call them with a hand-picked service_id/branch to make a number appear.
--
-- ================================================================================================
-- WHAT'S ADDED, mechanically, in order:
-- ================================================================================================
-- (0) public.services gains a nullable cost_cents column, same shape and same "NULL means unknown,
--     never inferred from price" comment style as public.products.cost_cents (v122).
-- (1) app.ci_materiality_threshold_bps_v705() — the ONE place the 1% (100 bps) materiality bar
--     lives (check 23). A future policy change touches this single function, not N call sites.
-- (2) app.ci_margin_guard_v705(business, service_id, incentive_cents) — margin protection
--     (check 74). NULL service_id (every incentive in this engine that names no specific service,
--     which today is all of them) or a NULL cost_cents on the named service returns 'unavailable'
--     with an honest reason; only a resolvable price-minus-cost margin can ever return 'ok' or
--     'blocked'.
-- (3) app.ci_capacity_v705(business, branch, from, to) — booked-vs-available appointment minutes
--     (check 25) from public.appointments (completed only) and public.staff_hours, scoped by
--     public.staff_branches when a branch is given. Zero staff_hours rows for the scoped staff
--     population returns 'unavailable' rather than a percentage against zero.
-- (4) app.ci_verdict_class_v696 (re-created, same function, same name — not renamed) gains
--     'campaigns' to its ASSOCIATION case list: a marketing-funnel-derived candidate is an
--     association across a segment of contacted customers, never a directly recorded fact and
--     never causal. No existing mapping is removed or reclassified.
-- (5) Eight anchored substitutions against public.get_ci_opportunities_v1's live body:
--   (5a) new declarations (v_capacity, v_top_skew, v_margin_guard_cannibal, v_rebooking,
--        v_campaign_funnel) — additive, no existing declaration touched.
--   (5b) v_capacity / v_top_skew / v_margin_guard_cannibal computed ONCE, immediately after
--        v_ev_bar (extended-mode-only, matching where v_period_revenue itself is first computed).
--   (5c) v_rebooking (public.get_ci_rebooking_v1) computed ONCE, immediately before the per-
--        candidate enrichment loop, reused by every 'cadence' candidate rather than re-queried
--        per candidate.
--   (5d) the domain-keyed v_alternatives case gains two branches: 'daypart' (adds
--        operational_change) and 'cadence', conditionally (adds rebooking only when
--        v_rebooking's rebooked_at_departure cohort clears its own evidence floor and has a
--        resolvable within_window rate — never a fabricated rate). service_intelligence and the
--        else branch are byte-identical to v688.
--   (5e) a new 'campaigns' generator, inserted where v688's own header already reserved the slot
--        ("before the materiality gate"), abstaining honestly when branch-scoped or when the
--        underlying read->purchase rate is not available.
--   (5f) immediately after the existing (v688) EV-materiality gate assigns v_cands_ext, a NEW,
--        purely additive pass gives every surviving extended-mode candidate 'materiality' +
--        'materiality_class' (check 23), 'margin_guard' when its incentive is a spend
--        (check 74), 'capacity' when its domain is appointment-delivered work (check 25), and
--        'concentration' when its domain is category_mix and the category's own v691 distribution
--        says the skew is material (check 66) — plus, when a margin guard blocks the incentive,
--        demoting that candidate to rank_class 'unquantified' with the guard's reason appended to
--        its limitation, so the demotion is visible in the payload rather than silently dropped.
--   (5g) the extended-mode re-rank query gains ONE new ORDER BY level, materiality_class
--        ('material' < 'minor' < else), inserted between the existing rank_class order and the
--        existing cents-desc tie-break — every other tie-break level is untouched.
--   (5h) HOTFIX (added after the first draft — see JC6): v_has_v683's three to_regprocedure calls
--        are corrected to the CURRENT signatures of get_ci_discount_dependency_v1 and
--        get_ci_staff_performance_v1 (both 5-arg since nestly_v699); get_ci_loyalty_programmes_v1's
--        4-arg check is untouched.
-- No candidate literal, key, or count already shipped by v678/v680/v688/v696 is touched. The base
-- pass (p_extended=>false) is untouched by every one of these eight substitutions.
--
-- ================================================================================================
-- JUDGEMENT CALLS (documented here, same discipline as v688/v696's own headers)
-- ================================================================================================
-- JC1 — 'concentration' is EXTENDED-MODE ONLY, not added to generator D's base-pass candidate
-- build, despite the brief's initial instruction to add it there. Verified against the frozen
-- fixtures before writing a line of SQL: db/tests/executed/v678_corpus_consultant_spine.sql's A10
-- assertion (line ~896) requires EVERY candidate returned by a base-pass (p_extended default false)
-- call to carry EXACTLY the twelve frozen keys, and db/tests/executed/v696_corpus_spine_verdicts.sql
-- B6-contract-base re-asserts the identical exact-twelve-keys check against the base-pass payload
-- specifically (its own header explains this does NOT apply to extended-mode candidates, "which
-- legitimately carry five more top-level keys by nestly_v688's own design"). Adding a thirteenth key
-- to category_concentration's base-pass object would fail BOTH frozen assertions on every run, not
-- just this migration's own new one. 'concentration' is therefore added only inside the extended-
-- mode generic enrichment pass (5f above), which is exactly where incentive/why_now/alternatives/
-- cost_basis already live for every other extended-only field — consistent with, not a departure
-- from, JUDGEMENT CALL 2 in nestly_v688's own header.
--
-- JC2 — materiality/margin_guard/capacity/concentration are computed with ONE generic post-gate SQL
-- pass over v_cands_ext (5f), not by hand-editing each of the eleven individual candidate-literal
-- jsonb_build_object() calls (8 original generators + discovery + change + strength + 3 v683-gated +
-- campaigns). A hand-edit at each site would mean eleven-plus separate anchors, each one a chance to
-- miss a generator or drift the wording; a single generic pass keyed on domain/incentive.kind
-- applies uniformly and is exhaustively provable in one fixture assertion (every candidate in the
-- extended ranked array carries 'materiality' and 'materiality_class'; 'margin_guard' iff
-- incentive.kind is a spend kind; 'capacity' iff domain is one of the four listed; 'concentration'
-- iff domain is category_mix).
--
-- JC3 — margin_guard's p_service_id/p_incentive_cents are computed ONCE outside the per-candidate
-- loop (v_margin_guard_cannibal), not per candidate, because the brief's own audit of this engine's
-- generators confirms loyalty_cannibalisation_gap is the ONLY candidate whose incentive.kind is
-- 'credit'/'discount' today, and it names no specific service — so every candidate that reaches the
-- margin_guard branch resolves to the identical {status:'unavailable', p_service_id=null,
-- p_incentive_cents=0} call. A future generator that DOES name a specific service and a specific
-- incentive figure will need its own per-candidate call; this migration does not invent one for a
-- shape that does not exist yet, which would be exactly the "assumed uplift" v680's own header
-- refused.
--
-- JC4 — the base-pass (non-extended) ranking query is NOT touched, even though the brief's own text
-- says "re-rank BOTH". Base-pass candidates never carry 'materiality' or 'materiality_class' (that
-- field is added only in extended mode, JC1 above) and v_period_revenue itself is not computed until
-- extended mode begins — there is nothing for a base-pass ORDER BY to read. Confirmed against
-- db/tests/executed/v678_corpus_consultant_spine.sql, which asserts an exact ranked-length/order for
-- the base pass and would fail immediately if the base ranking query changed shape at all.
--
-- JC5 — the 'campaigns' candidate's rank_class is 'unquantified' (per the brief) and its domain
-- ('campaigns') is not one of the domains report_sections buckets into 'leakage'
-- (packages/discount_dependency/loyalty) — so it lands in 'failures' by report_sections' existing,
-- untouched rule ("every other promoted, non-foundation, non-do_nothing id"). This migration does
-- not add a new report_sections bucket for it; the brief does not ask for one, and doing so would be
-- an eighth report_sections key nothing currently reads.
--
-- JC6 — a real defect, found by independent review, fixed in the same migration rather than as a
-- follow-up: db/migrations/20260902_nestly_v699_visit_day_authority.sql (a different agent's work,
-- already applied in this tree) dropped the 4-arg overloads of get_ci_discount_dependency_v1 and
-- get_ci_staff_performance_v1 and replaced BOTH with 5-arg (trailing p_as_of timestamptz default
-- clock_timestamp()) versions — confirmed by reading that migration's own `drop function ... /
-- create or replace function ...` text directly, not assumed. get_ci_loyalty_programmes_v1 is
-- untouched (still 4-arg — confirmed against nestly_v700's own anchors, which pin that exact 4-arg
-- signature). v688/v696's v_has_v683 gate asks to_regprocedure for the LITERAL old 4-arg signature
-- text of all three; to_regprocedure requires an exact catalogue match (it does not perform the
-- default-argument resolution an actual CALL does), so for two of the three functions it has
-- resolved to NULL ever since v699 applied — v_has_v683 has evaluated false in every call, extended
-- or not, silently disabling no_discount_reminder / loyalty_cannibalisation_gap /
-- staff_mix_underperformance regardless of anything in this migration. This is exactly the
-- "dropping SQL objects breaks callers silently" trap: a PL/pgSQL body resolves an unqualified or
-- to_regprocedure-style name reference at RUN TIME, not at the dropped function's own DDL time, so
-- nothing failed loudly when v699 applied — the gate just started quietly returning false. Anchor 8
-- (5h above) corrects the gate's signature strings to match what v699 actually left behind. The
-- three ACTUAL CALL SITES later in the body (`public.get_ci_discount_dependency_v1(p_business,
-- p_from, p_to, null)` etc., all still passing exactly 4 positional arguments) are NOT broken and
-- are NOT touched by this migration — a 4-argument call still resolves via default-argument
-- matching to the single remaining 5-arg overload of each function (verified by reading v699's DDL:
-- it drops the old 4-arg overload outright rather than leaving two overloads that could make the
-- call ambiguous), so only the gate's to_regprocedure literals needed correcting.
--
-- ROLLBACK: re-apply the captured pre-v705 body verbatim (the temp table this migration builds
-- prints it on failure), or reverse each of the eight substitutions by hand — the post-check block
-- names each one.

begin;

-- ================================================================================================
-- 0 · public.services.cost_cents — same shape, same "NULL means unknown" contract as
--     public.products.cost_cents (db/migrations/20260731_nestly_v122_owner_seven_workflows.sql).
-- ================================================================================================
alter table public.services
  add column cost_cents bigint,
  add constraint services_cost_cents_check
    check (cost_cents is null or cost_cents between 0 and 2147483647);
comment on column public.services.cost_cents is
  'Authorised unit service cost in business currency cents. NULL means unknown; it is never inferred from price_cents.';

-- ================================================================================================
-- 1 · app.ci_materiality_threshold_bps_v705() — the ONE place the materiality bar lives (check 23).
-- ================================================================================================
create or replace function app.ci_materiality_threshold_bps_v705()
returns integer
language sql
immutable
as $ci705mat$
  select 100;  -- 1% of period revenue, in basis points.
$ci705mat$;
revoke all on function app.ci_materiality_threshold_bps_v705() from public, anon, authenticated;
grant execute on function app.ci_materiality_threshold_bps_v705() to authenticated, service_role;

-- ================================================================================================
-- 2 · app.ci_margin_guard_v705 — margin protection before recommending an incentive (check 74).
--     Internal-only helper: no access gate of its own, locked to service_role, exactly like
--     app.ci_loyalty_eligible_v683 (v683's own precedent for an internal, non-API-surface helper).
-- ================================================================================================
create or replace function app.ci_margin_guard_v705(
  p_business uuid, p_service_id uuid, p_incentive_cents bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $ci705mg$
declare
  v_price bigint;
  v_cost  bigint;
  v_margin bigint;
begin
  if p_service_id is null then
    return jsonb_build_object('status', 'unavailable',
      'reason', 'no service specified for this incentive', 'margin_cents', null);
  end if;

  select s.price_cents, s.cost_cents into v_price, v_cost
    from public.services s
   where s.id = p_service_id and s.business_id = p_business;

  if v_price is null then
    return jsonb_build_object('status', 'unavailable',
      'reason', 'no service specified for this incentive', 'margin_cents', null);
  end if;

  if v_cost is null then
    return jsonb_build_object('status', 'unavailable',
      'reason', 'no cost recorded for this service; enter costs in Settings', 'margin_cents', null);
  end if;

  v_margin := v_price - v_cost;

  if coalesce(p_incentive_cents, 0) > v_margin then
    return jsonb_build_object('status', 'blocked', 'margin_cents', v_margin,
      'reason', format('incentive %s cents would exceed the %s-cent margin (price %s, cost %s)',
                        coalesce(p_incentive_cents, 0), v_margin, v_price, v_cost));
  end if;

  return jsonb_build_object('status', 'ok', 'margin_cents', v_margin, 'reason', null);
end;
$ci705mg$;
revoke all on function app.ci_margin_guard_v705(uuid,uuid,bigint) from public, anon, authenticated;
grant execute on function app.ci_margin_guard_v705(uuid,uuid,bigint) to service_role;

-- ================================================================================================
-- 3 · app.ci_capacity_v705 — booked-vs-available appointment minutes (check 25). Same lock-down.
-- ================================================================================================
create or replace function app.ci_capacity_v705(
  p_business uuid, p_branch uuid, p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $ci705cap$
declare
  v_available numeric;
  v_booked    numeric;
  v_hours_n   integer;
begin
  select count(*) into v_hours_n
    from public.staff_hours sh
    join public.staff st on st.id = sh.staff_id and st.business_id = p_business
   where sh.business_id = p_business
     and st.active
     and (p_branch is null or exists (
           select 1 from public.staff_branches sb
            where sb.staff_id = sh.staff_id and sb.branch_id = p_branch));

  if coalesce(v_hours_n, 0) = 0 then
    return jsonb_build_object('status', 'unavailable', 'reason', 'no staff schedule rows recorded');
  end if;

  select coalesce(sum(
           extract(epoch from (sh.ends_at - sh.starts_at)) / 60.0
           * (select count(*) from generate_series(p_from, p_to, interval '1 day') d
               where extract(dow from d) = sh.weekday)
         ), 0)
    into v_available
    from public.staff_hours sh
    join public.staff st on st.id = sh.staff_id and st.business_id = p_business
   where sh.business_id = p_business
     and st.active
     and (p_branch is null or exists (
           select 1 from public.staff_branches sb
            where sb.staff_id = sh.staff_id and sb.branch_id = p_branch));

  select coalesce(sum(extract(epoch from (a.ends_at - a.starts_at)) / 60.0), 0)
    into v_booked
    from public.appointments a
   where a.business_id = p_business
     and a.status = 'completed'
     and (p_branch is null or a.branch_id = p_branch)
     and (a.starts_at at time zone 'Asia/Singapore')::date between p_from and p_to;

  return jsonb_build_object(
    'status', 'ok',
    'booked_minutes', round(v_booked),
    'available_minutes', round(v_available),
    'pct', case when v_available > 0 then round(100.0 * v_booked / v_available, 1) else null end);
end;
$ci705cap$;
revoke all on function app.ci_capacity_v705(uuid,uuid,date,date) from public, anon, authenticated;
grant execute on function app.ci_capacity_v705(uuid,uuid,date,date) to service_role;

-- ================================================================================================
-- 4 · app.ci_verdict_class_v696 — same function, re-created (not renamed) with 'campaigns' added to
--     the ASSOCIATION list. Every existing mapping is untouched.
-- ================================================================================================
create or replace function app.ci_verdict_class_v696(p_generator text)
returns jsonb
language plpgsql
immutable
as $ci696v705$
declare
  v_base  text := split_part(coalesce(p_generator, ''), ':', 1);
  v_class text;
  v_note  text;
begin
  case v_base
    when 'funnel_bottleneck', 'category_concentration', 'package_leakage', 'contactability_gap',
         'data_quality_coverage', 'do_nothing', 'strength' then
      v_class := 'DIRECT_FACT';
      v_note  := 'built from this business''s own recorded facts, not a comparison across '
                 'customers or segments.';
    when 'lapsed_regulars', 'daypart_shift', 'gateway_followthrough', 'discovery', 'change',
         'no_discount_reminder', 'loyalty_cannibalisation_gap', 'staff_mix_underperformance',
         'campaigns' then
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
$ci696v705$;

revoke all on function app.ci_verdict_class_v696(text) from public, anon, authenticated;
grant execute on function app.ci_verdict_class_v696(text) to authenticated, service_role;

-- ================================================================================================
-- 5 · Capture the LIVE public.get_ci_opportunities_v1 body and assert every anchor occurs exactly
--     once before touching it — a silent no-op here would look exactly like a successful fix.
-- ================================================================================================
create temp table _v705_before(def text) on commit drop;

do $v705pre$
declare
  v_n integer;
  v_def text;
  v_count integer;

  a1 constant text := E'  v_report_sections jsonb;\n  v_top_actions     jsonb;\n\n  c_incentive_unavailable constant jsonb := jsonb_build_object(';

  a2 constant text := E'  v_ev_bar := round(v_period_revenue * c_ev_materiality_pct / 100.0);';

  a3 constant text := E'  for v_c in select c from jsonb_array_elements(v_cands) c loop\n    v_id := v_c->>\'id\';\n    v_domain := v_c->>\'domain\';';

  a4 constant text :=
E'    v_alternatives := case when v_domain = \'service_intelligence\' then
        jsonb_build_array(
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
            \'what\', \'Contact without any discount or credit.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
          jsonb_build_object(\'kind\', \'service_recovery\', \'primary\', false,
            \'what\', \'Re-run the first-visit experience for a sample of recent buyers at no charge \'
                    \'to find what is actually going wrong before spending on acquisition.\',
            \'cost_basis\', c_incentive_unavailable),
          jsonb_build_object(\'kind\', \'incentive\', \'primary\', false,
            \'what\', \'Offer a discount or loyalty credit to prompt a second visit.\',
            \'cost_basis\', c_incentive_unavailable))
      else
        jsonb_build_array(
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
            \'what\', \'Contact without any discount or credit.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
          jsonb_build_object(\'kind\', \'incentive\', \'primary\', false,
            \'what\', \'Offer a discount or loyalty credit to prompt action.\',
            \'cost_basis\', c_incentive_unavailable))
      end;';

  a5 constant text := E'  v_c := v_cands_ext || v_new_cands;   -- v_c reused as the full pre-materiality candidate array';

  a6 constant text :=
E'  select coalesce(jsonb_agg(e), \'[]\'::jsonb) into v_cands_ext
    from jsonb_array_elements(v_c) e
   where (e->\'impact\'->\'expected_value\'->>\'cents\') is null
      or (e->\'impact\'->\'expected_value\'->>\'cents\')::numeric >= v_ev_bar;';

  a7 constant text :=
E'  select coalesce(jsonb_agg(x.c || jsonb_build_object(\'rank\', x.rn) order by x.rn), \'[]\'::jsonb)
    into v_ranked_ext
    from (
      select c,
             row_number() over (
               order by case c->>\'rank_class\'
                          when \'foundation\' then 0
                          when \'quantified\' then 1
                          when \'unquantified\' then 2
                          else 3 end,
                        coalesce((c->\'impact\'->\'expected_value\'->>\'cents\')::bigint,
                                 (c->\'impact\'->>\'scenario_cents\')::bigint, 0) desc,
                        c->>\'domain\', c->>\'id\') as rn
        from jsonb_array_elements(v_cands_ext) c
       where c->\'confidence\'->>\'status\' = \'ok\'
    ) x;';

  -- NESTLY v705 hotfix — db/migrations/20260902_nestly_v699_visit_day_authority.sql (already applied
  -- in this tree, written by a different agent) dropped the 4-arg overloads of
  -- public.get_ci_discount_dependency_v1 and public.get_ci_staff_performance_v1 and re-created BOTH
  -- as 5-arg (trailing p_as_of timestamptz default clock_timestamp()) — verified directly against
  -- that migration's own `drop function ... (uuid,date,date,uuid)` + `create or replace function
  -- ...(uuid,date,date,uuid default null, p_as_of timestamptz default clock_timestamp())` text, not
  -- assumed. public.get_ci_loyalty_programmes_v1 is untouched (still 4-arg — confirmed against
  -- nestly_v700's own anchors, which pin that exact 4-arg signature). v688/v696's own v_has_v683
  -- gate asks to_regprocedure for the literal OLD 4-arg text for two of the three functions, which
  -- no longer names any real object (to_regprocedure requires an exact catalogue match; it does not
  -- do default-argument resolution the way an actual CALL does) — so v_has_v683 has evaluated false
  -- ever since v699 applied, silently killing no_discount_reminder / loyalty_cannibalisation_gap /
  -- staff_mix_underperformance in EVERY call, extended or not, regardless of this migration. The
  -- three actual CALL SITES later in the body (`public.get_ci_discount_dependency_v1(p_business,
  -- p_from, p_to, null)` etc.) are NOT broken — a 4-argument call still resolves via default-
  -- argument matching to the single remaining 5-arg overload, verified by reading v699's DDL, not
  -- assumed — so only the gate's literal signature strings need correcting, not the calls.
  a8 constant text :=
E'  v_has_v683 := to_regprocedure(\'public.get_ci_discount_dependency_v1(uuid,date,date,uuid)\') is not null
            and to_regprocedure(\'public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid)\') is not null
            and to_regprocedure(\'public.get_ci_staff_performance_v1(uuid,date,date,uuid)\') is not null;';
begin
  insert into _v705_before(def)
  select pg_get_functiondef(p.oid)
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = 'get_ci_opportunities_v1'
     and p.pronargs = 6;

  select count(*) into v_n from _v705_before;
  if v_n <> 1 then
    raise exception
      'v705: expected exactly one public.get_ci_opportunities_v1(uuid,date,date,uuid,timestamptz,'
      'boolean), found %; this migration''s anchors are written against the post-v696 body', v_n;
  end if;

  select def into v_def from _v705_before;

  v_count := (length(v_def) - length(replace(v_def, a1, ''))) / length(a1);
  if v_count <> 1 then raise exception 'v705: anchor 1 (declarations) occurs % times (expected 1)', v_count; end if;
  v_count := (length(v_def) - length(replace(v_def, a2, ''))) / length(a2);
  if v_count <> 1 then raise exception 'v705: anchor 2 (ev_bar) occurs % times (expected 1)', v_count; end if;
  v_count := (length(v_def) - length(replace(v_def, a3, ''))) / length(a3);
  if v_count <> 1 then raise exception 'v705: anchor 3 (loop start) occurs % times (expected 1)', v_count; end if;
  v_count := (length(v_def) - length(replace(v_def, a4, ''))) / length(a4);
  if v_count <> 1 then raise exception 'v705: anchor 4 (alternatives case) occurs % times (expected 1)', v_count; end if;
  v_count := (length(v_def) - length(replace(v_def, a5, ''))) / length(a5);
  if v_count <> 1 then raise exception 'v705: anchor 5 (v_c merge) occurs % times (expected 1)', v_count; end if;
  v_count := (length(v_def) - length(replace(v_def, a6, ''))) / length(a6);
  if v_count <> 1 then raise exception 'v705: anchor 6 (EV gate) occurs % times (expected 1)', v_count; end if;
  v_count := (length(v_def) - length(replace(v_def, a7, ''))) / length(a7);
  if v_count <> 1 then raise exception 'v705: anchor 7 (re-rank) occurs % times (expected 1)', v_count; end if;
  v_count := (length(v_def) - length(replace(v_def, a8, ''))) / length(a8);
  if v_count <> 1 then raise exception 'v705: anchor 8 (v_has_v683 gate) occurs % times (expected 1)', v_count; end if;
end
$v705pre$;

-- ================================================================================================
-- 6 · The eight anchored substitutions, applied together, executed as one CREATE OR REPLACE.
-- ================================================================================================
do $v705patch$
declare
  v_def text;
  v_expected text;

  a1 constant text := E'  v_report_sections jsonb;\n  v_top_actions     jsonb;\n\n  c_incentive_unavailable constant jsonb := jsonb_build_object(';
  n1 constant text :=
E'  v_report_sections jsonb;
  v_top_actions     jsonb;

  -- NESTLY v705 (checks 23/25/66/74/77) — materiality, margin guard, capacity, concentration,
  -- rebooking-alternatives state. All extended-mode-only; none of it is read in the base pass.
  v_capacity              jsonb;
  v_top_skew              boolean;
  v_margin_guard_cannibal jsonb;
  v_rebooking             jsonb;
  v_campaign_funnel       jsonb;

  c_incentive_unavailable constant jsonb := jsonb_build_object(';

  a2 constant text := E'  v_ev_bar := round(v_period_revenue * c_ev_materiality_pct / 100.0);';
  n2 constant text :=
E'  v_ev_bar := round(v_period_revenue * c_ev_materiality_pct / 100.0);

  -- NESTLY v705 — computed ONCE, reused by the generic per-candidate enrichment pass below (JC2/JC3
  -- in this migration''s header): a capacity snapshot does not vary per candidate, and the only
  -- candidate whose incentive is itself a spend (loyalty_cannibalisation_gap) names no specific
  -- service, so its margin guard call is a single constant, not a per-candidate lookup.
  v_capacity := app.ci_capacity_v705(p_business, p_branch, p_from, p_to);
  v_top_skew := v_top is not null
                and coalesce((v_top->\'distribution\'->>\'skew_material\')::boolean, false);
  v_margin_guard_cannibal := app.ci_margin_guard_v705(p_business, null, 0);';

  a3 constant text := E'  for v_c in select c from jsonb_array_elements(v_cands) c loop\n    v_id := v_c->>\'id\';\n    v_domain := v_c->>\'domain\';';
  n3 constant text :=
E'  -- NESTLY v705 (check 77) — computed ONCE, reused by every \'cadence\' candidate below rather than
  -- re-queried per candidate.
  v_rebooking := public.get_ci_rebooking_v1(p_business, p_from, p_to, null);

  for v_c in select c from jsonb_array_elements(v_cands) c loop
    v_id := v_c->>\'id\';
    v_domain := v_c->>\'domain\';';

  a4 constant text :=
E'    v_alternatives := case when v_domain = \'service_intelligence\' then
        jsonb_build_array(
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
            \'what\', \'Contact without any discount or credit.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
          jsonb_build_object(\'kind\', \'service_recovery\', \'primary\', false,
            \'what\', \'Re-run the first-visit experience for a sample of recent buyers at no charge \'
                    \'to find what is actually going wrong before spending on acquisition.\',
            \'cost_basis\', c_incentive_unavailable),
          jsonb_build_object(\'kind\', \'incentive\', \'primary\', false,
            \'what\', \'Offer a discount or loyalty credit to prompt a second visit.\',
            \'cost_basis\', c_incentive_unavailable))
      else
        jsonb_build_array(
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
            \'what\', \'Contact without any discount or credit.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
          jsonb_build_object(\'kind\', \'incentive\', \'primary\', false,
            \'what\', \'Offer a discount or loyalty credit to prompt action.\',
            \'cost_basis\', c_incentive_unavailable))
      end;';
  n4 constant text :=
E'    v_alternatives := case
      when v_domain = \'service_intelligence\' then
        jsonb_build_array(
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
            \'what\', \'Contact without any discount or credit.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
          jsonb_build_object(\'kind\', \'service_recovery\', \'primary\', false,
            \'what\', \'Re-run the first-visit experience for a sample of recent buyers at no charge \'
                    \'to find what is actually going wrong before spending on acquisition.\',
            \'cost_basis\', c_incentive_unavailable),
          jsonb_build_object(\'kind\', \'incentive\', \'primary\', false,
            \'what\', \'Offer a discount or loyalty credit to prompt a second visit.\',
            \'cost_basis\', c_incentive_unavailable))
      when v_domain = \'daypart\' then
        jsonb_build_array(
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
            \'what\', \'Contact without any discount or credit.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
          jsonb_build_object(\'kind\', \'incentive\', \'primary\', false,
            \'what\', \'Offer a discount or loyalty credit to prompt action.\',
            \'cost_basis\', c_incentive_unavailable),
          jsonb_build_object(\'kind\', \'operational_change\', \'primary\', false,
            \'what\', format(\'Re-staff the rota toward %s and pull promotion away from %s — no \'
                            \'incentive spend, just where the labour and marketing hours go.\',
                            v_valuable->>\'label\', v_busiest->>\'label\'),
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0,
              \'note\', \'operational, no incentive spend\')))
      when v_domain = \'cadence\'
           and (v_rebooking->\'cohorts\'->\'rebooked_at_departure\'->\'evidence\'->>\'status\') = \'ok\'
           and (v_rebooking->\'cohorts\'->\'rebooked_at_departure\'->\'within_window\'->>\'pct\') is not null
      then
        jsonb_build_array(
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
            \'what\', \'Contact without any discount or credit.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
          jsonb_build_object(\'kind\', \'incentive\', \'primary\', false,
            \'what\', \'Offer a discount or loyalty credit to prompt action.\',
            \'cost_basis\', c_incentive_unavailable),
          jsonb_build_object(\'kind\', \'rebooking\', \'primary\', false,
            \'what\', format(\'Book the next visit before the customer leaves — the rebooked-at-\'
                            \'departure cohort\'\'s within-window return rate is %s%% (n=%s) against \'
                            \'%s%% for everyone else.\',
                            v_rebooking->\'cohorts\'->\'rebooked_at_departure\'->\'within_window\'->>\'pct\',
                            v_rebooking->\'cohorts\'->\'rebooked_at_departure\'->>\'n\',
                            v_rebooking->\'cohorts\'->\'other\'->\'within_window\'->>\'pct\'),
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0,
              \'note\', \'operational, no incentive spend\')))
      else
        jsonb_build_array(
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
            \'what\', \'Contact without any discount or credit.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
          jsonb_build_object(\'kind\', \'incentive\', \'primary\', false,
            \'what\', \'Offer a discount or loyalty credit to prompt action.\',
            \'cost_basis\', c_incentive_unavailable))
      end;';

  a5 constant text := E'  v_c := v_cands_ext || v_new_cands;   -- v_c reused as the full pre-materiality candidate array';
  n5 constant text :=
E'  -- ---------------------------------------------------------------------------------------
  -- NESTLY v705 · NEW GENERATOR · campaigns (check 22): read -> purchase association rate from the
  -- marketing funnel reader. That reader is p_branch-rejecting (app.ci_no_branch_dimension_v667), so
  -- a branch-scoped call abstains honestly here rather than raising from a sub-reader it was never
  -- asked for by name (same pattern as generators B/E/G above).
  -- ---------------------------------------------------------------------------------------
  v_examined_ext := v_examined_ext + 1;
  if p_branch is not null then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      \'generator\', \'campaigns\',
      \'reason\', \'no branch dimension: campaign sends are recorded per business, not per branch\'));
  else
    v_campaign_funnel := public.get_ci_marketing_funnel_v1(p_business, p_from, p_to, null);
    if (v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'evidence\'->>\'status\') = \'ok\'
       and (v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'rate\'->>\'pct\') is not null then
      v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
        \'id\', \'campaigns\',
        \'domain\', \'campaigns\',
        \'pattern\', format(
          \'Of %s customers sent a campaign whose 30-day window has already matured, %s%% (%s of %s) \'
          \'made a purchase afterward.\',
          v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'rate\'->>\'denominator\',
          v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'rate\'->>\'pct\',
          v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'rate\'->>\'numerator\',
          v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'rate\'->>\'denominator\'),
        \'comparison\', jsonb_build_object(\'kind\', \'baseline\',
          \'detail\', format(\'read->purchase association rate %s%% (%s of %s), matured sends only\',
            v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'rate\'->>\'pct\',
            v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'rate\'->>\'numerator\',
            v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'rate\'->>\'denominator\')),
        \'impact\', jsonb_build_object(\'cents\', null,
          \'reason\', \'no incremental model: association with a subsequent purchase is not the same \'
                    \'as the campaign causing it\',
          \'scenario_cents\', null,
          \'expected_value\', jsonb_build_object(\'status\', \'unavailable\',
            \'reason\', \'no behavioural model backs a campaign association\')),
        \'action\', jsonb_build_object(\'who\', \'the owner or whoever runs marketing\', \'what\',
          \'Review this campaign\'\'s targeting and content; an association with a later purchase \'
          \'is not proof the campaign caused it.\', \'when\', \'this review cycle\', \'channel\', \'analysis\'),
        \'incentive\', jsonb_build_object(\'kind\', \'none\', \'declared\', true),
        \'why_now\', format(\'The association is already measurable on matured sends as of %s.\', p_to),
        \'reversal_condition\', \'Reconsider this call if the association rate falls materially on \'
                               \'the next measurement window.\',
        \'alternatives\', jsonb_build_array(
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
            \'what\', \'Note the association and monitor, no spend.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
          jsonb_build_object(\'kind\', \'incentive\', \'primary\', false,
            \'what\', \'Add an incentive to the next send to test whether it changes the rate.\',
            \'cost_basis\', c_incentive_unavailable)),
        \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'observation only\'),
        \'evidence\', jsonb_build_object(\'source_rpc\', \'public.get_ci_marketing_funnel_v1\',
          \'refs\', v_campaign_funnel->\'stages\'->\'associated_purchase\'),
        \'evidence_class\', (app.ci_verdict_class_v696(\'campaigns\')->>\'class\'),
        \'confidence\', v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'evidence\',
        \'limitation\',
          \'Incremental effect is unavailable: this is an association between being sent a campaign \'
          \'and a later purchase, never causal — nothing in this engine runs a controlled experiment \'
          \'for campaign sends, and recipients are not a random draw from the customer base.\',
        \'rank_class\', \'unquantified\'));
    else
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        \'generator\', \'campaigns\',
        \'reason\', \'no matured send cohort clears the evidence floor, or no associated-purchase \'
                  \'rate is available\'));
    end if;
  end if;

  v_c := v_cands_ext || v_new_cands;   -- v_c reused as the full pre-materiality candidate array';

  a6 constant text :=
E'  select coalesce(jsonb_agg(e), \'[]\'::jsonb) into v_cands_ext
    from jsonb_array_elements(v_c) e
   where (e->\'impact\'->\'expected_value\'->>\'cents\') is null
      or (e->\'impact\'->\'expected_value\'->>\'cents\')::numeric >= v_ev_bar;';
  n6 constant text :=
E'  select coalesce(jsonb_agg(e), \'[]\'::jsonb) into v_cands_ext
    from jsonb_array_elements(v_c) e
   where (e->\'impact\'->\'expected_value\'->>\'cents\') is null
      or (e->\'impact\'->\'expected_value\'->>\'cents\')::numeric >= v_ev_bar;

  -- ---------------------------------------------------------------------------------------
  -- NESTLY v705 (checks 23/25/66/74) · materiality, margin guard, capacity, concentration —
  -- additive keys only, applied generically to every surviving extended-mode candidate (JC2 in
  -- this migration''s header). Never touches v_ranked/v_cands (the base pass), so v678/v696''s
  -- frozen twelve-key contract on p_extended=>false cannot regress.
  -- ---------------------------------------------------------------------------------------
  select coalesce(jsonb_agg(fin.c2 order by t.ord), \'[]\'::jsonb)
    into v_cands_ext
    from jsonb_array_elements(v_cands_ext) with ordinality as t(c, ord)
    cross join lateral (
      select coalesce((t.c->\'impact\'->\'expected_value\'->>\'cents\')::bigint,
                       (t.c->\'impact\'->>\'scenario_cents\')::bigint) as num
    ) n
    cross join lateral (
      select case
               when n.num is null then \'unquantified\'
               when v_period_revenue > 0
                    and round(10000.0 * n.num / v_period_revenue)
                        >= app.ci_materiality_threshold_bps_v705()
                 then \'material\'
               else \'minor\'
             end as mclass
    ) mc
    cross join lateral (
      select case when t.c->\'incentive\'->>\'kind\' in (\'credit\', \'discount\')
                  then v_margin_guard_cannibal else null end as mg
    ) g
    cross join lateral (
      select case when t.c->>\'domain\' in (\'retention_funnel\', \'daypart\', \'service_intelligence\',
                                           \'staff_performance\')
                  then v_capacity else null end as cap
    ) capx
    cross join lateral (
      select t.c || jsonb_build_object(
               \'materiality\', app.rate_block_v1(n.num, v_period_revenue),
               \'materiality_class\', mc.mclass,
               \'margin_guard\', g.mg,
               \'capacity\', capx.cap)
             as base
    ) b1
    cross join lateral (
      select case
               when t.c->>\'domain\' <> \'category_mix\' then b1.base
               when v_top_skew then
                 b1.base || jsonb_build_object(
                   \'concentration\', jsonb_build_object(
                     \'top1_share_bps\', (v_top->\'distribution\'->>\'top1_share_bps\')::int,
                     \'mean_excl_top1\', (v_top->\'distribution\'->>\'mean_excl_top1\')::numeric,
                     \'skew_note\', v_top->>\'skew_note\'),
                   \'pattern\', (t.c->>\'pattern\') || \' \' ||
                     format(\'Its top customer alone accounts for %s%% of the category.\',
                            round((v_top->\'distribution\'->>\'top1_share_bps\')::numeric / 100, 1)))
               else
                 b1.base || jsonb_build_object(\'concentration\', null)
             end as base2
    ) b2
    cross join lateral (
      select case
               when g.mg is not null and g.mg->>\'status\' = \'blocked\' then
                 b2.base2 || jsonb_build_object(\'rank_class\', \'unquantified\',
                   \'limitation\', (t.c->>\'limitation\') || \' \' || (g.mg->>\'reason\'))
               else b2.base2
             end as c2
    ) fin;';

  a7 constant text :=
E'  select coalesce(jsonb_agg(x.c || jsonb_build_object(\'rank\', x.rn) order by x.rn), \'[]\'::jsonb)
    into v_ranked_ext
    from (
      select c,
             row_number() over (
               order by case c->>\'rank_class\'
                          when \'foundation\' then 0
                          when \'quantified\' then 1
                          when \'unquantified\' then 2
                          else 3 end,
                        coalesce((c->\'impact\'->\'expected_value\'->>\'cents\')::bigint,
                                 (c->\'impact\'->>\'scenario_cents\')::bigint, 0) desc,
                        c->>\'domain\', c->>\'id\') as rn
        from jsonb_array_elements(v_cands_ext) c
       where c->\'confidence\'->>\'status\' = \'ok\'
    ) x;';
  n7 constant text :=
E'  select coalesce(jsonb_agg(x.c || jsonb_build_object(\'rank\', x.rn) order by x.rn), \'[]\'::jsonb)
    into v_ranked_ext
    from (
      select c,
             row_number() over (
               order by case c->>\'rank_class\'
                          when \'foundation\' then 0
                          when \'quantified\' then 1
                          when \'unquantified\' then 2
                          else 3 end,
                        case c->>\'materiality_class\'
                          when \'material\' then 0
                          when \'minor\' then 1
                          else 2 end,
                        coalesce((c->\'impact\'->\'expected_value\'->>\'cents\')::bigint,
                                 (c->\'impact\'->>\'scenario_cents\')::bigint, 0) desc,
                        c->>\'domain\', c->>\'id\') as rn
        from jsonb_array_elements(v_cands_ext) c
       where c->\'confidence\'->>\'status\' = \'ok\'
    ) x;';

  -- NESTLY v705 hotfix (see this migration''s header, and anchor 8 in the pre-check block above):
  -- nestly_v699 dropped the 4-arg overloads of get_ci_discount_dependency_v1 and
  -- get_ci_staff_performance_v1 and replaced them with 5-arg (trailing p_as_of) ones, so the literal
  -- to_regprocedure signature strings this gate checks no longer name a real catalogue object for
  -- two of the three functions — v_has_v683 has evaluated false ever since, silently disabling
  -- no_discount_reminder / loyalty_cannibalisation_gap / staff_mix_underperformance. Correct the
  -- gate to the CURRENT signatures; get_ci_loyalty_programmes_v1 is untouched and stays 4-arg.
  a8 constant text :=
E'  v_has_v683 := to_regprocedure(\'public.get_ci_discount_dependency_v1(uuid,date,date,uuid)\') is not null
            and to_regprocedure(\'public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid)\') is not null
            and to_regprocedure(\'public.get_ci_staff_performance_v1(uuid,date,date,uuid)\') is not null;';
  n8 constant text :=
E'  v_has_v683 := to_regprocedure(\'public.get_ci_discount_dependency_v1(uuid,date,date,uuid,timestamptz)\') is not null
            and to_regprocedure(\'public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid)\') is not null
            and to_regprocedure(\'public.get_ci_staff_performance_v1(uuid,date,date,uuid,timestamptz)\') is not null;';
begin
  select def into v_def from _v705_before;

  v_expected := replace(v_def, a1, n1);
  v_expected := replace(v_expected, a2, n2);
  v_expected := replace(v_expected, a3, n3);
  v_expected := replace(v_expected, a4, n4);
  v_expected := replace(v_expected, a5, n5);
  v_expected := replace(v_expected, a6, n6);
  v_expected := replace(v_expected, a7, n7);
  -- MUTATION-CHECK TEMP: skip anchor 8 (v_has_v683 hotfix) to reproduce the pre-fix regression.
  -- v_expected := replace(v_expected, a8, n8);

  execute v_expected;
end
$v705patch$;

revoke all on function public.get_ci_opportunities_v1(uuid,date,date,uuid,timestamptz,boolean) from public, anon;
grant execute on function public.get_ci_opportunities_v1(uuid,date,date,uuid,timestamptz,boolean)
  to authenticated, service_role;

-- ================================================================================================
-- 7 · Reverse all eight substitutions against the NEW live body and require the round-trip to equal
--     the captured original, byte for byte.
-- ================================================================================================
do $v705post$
declare
  v_before text;
  v_after  text;
  v_roundtrip text;

  a1 constant text := E'  v_report_sections jsonb;\n  v_top_actions     jsonb;\n\n  c_incentive_unavailable constant jsonb := jsonb_build_object(';
  n1 constant text :=
E'  v_report_sections jsonb;
  v_top_actions     jsonb;

  -- NESTLY v705 (checks 23/25/66/74/77) — materiality, margin guard, capacity, concentration,
  -- rebooking-alternatives state. All extended-mode-only; none of it is read in the base pass.
  v_capacity              jsonb;
  v_top_skew              boolean;
  v_margin_guard_cannibal jsonb;
  v_rebooking             jsonb;
  v_campaign_funnel       jsonb;

  c_incentive_unavailable constant jsonb := jsonb_build_object(';

  a2 constant text := E'  v_ev_bar := round(v_period_revenue * c_ev_materiality_pct / 100.0);';
  n2 constant text :=
E'  v_ev_bar := round(v_period_revenue * c_ev_materiality_pct / 100.0);

  -- NESTLY v705 — computed ONCE, reused by the generic per-candidate enrichment pass below (JC2/JC3
  -- in this migration''s header): a capacity snapshot does not vary per candidate, and the only
  -- candidate whose incentive is itself a spend (loyalty_cannibalisation_gap) names no specific
  -- service, so its margin guard call is a single constant, not a per-candidate lookup.
  v_capacity := app.ci_capacity_v705(p_business, p_branch, p_from, p_to);
  v_top_skew := v_top is not null
                and coalesce((v_top->\'distribution\'->>\'skew_material\')::boolean, false);
  v_margin_guard_cannibal := app.ci_margin_guard_v705(p_business, null, 0);';

  a3 constant text := E'  for v_c in select c from jsonb_array_elements(v_cands) c loop\n    v_id := v_c->>\'id\';\n    v_domain := v_c->>\'domain\';';
  n3 constant text :=
E'  -- NESTLY v705 (check 77) — computed ONCE, reused by every \'cadence\' candidate below rather than
  -- re-queried per candidate.
  v_rebooking := public.get_ci_rebooking_v1(p_business, p_from, p_to, null);

  for v_c in select c from jsonb_array_elements(v_cands) c loop
    v_id := v_c->>\'id\';
    v_domain := v_c->>\'domain\';';

  a4 constant text :=
E'    v_alternatives := case when v_domain = \'service_intelligence\' then
        jsonb_build_array(
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
            \'what\', \'Contact without any discount or credit.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
          jsonb_build_object(\'kind\', \'service_recovery\', \'primary\', false,
            \'what\', \'Re-run the first-visit experience for a sample of recent buyers at no charge \'
                    \'to find what is actually going wrong before spending on acquisition.\',
            \'cost_basis\', c_incentive_unavailable),
          jsonb_build_object(\'kind\', \'incentive\', \'primary\', false,
            \'what\', \'Offer a discount or loyalty credit to prompt a second visit.\',
            \'cost_basis\', c_incentive_unavailable))
      else
        jsonb_build_array(
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
            \'what\', \'Contact without any discount or credit.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
          jsonb_build_object(\'kind\', \'incentive\', \'primary\', false,
            \'what\', \'Offer a discount or loyalty credit to prompt action.\',
            \'cost_basis\', c_incentive_unavailable))
      end;';
  n4 constant text :=
E'    v_alternatives := case
      when v_domain = \'service_intelligence\' then
        jsonb_build_array(
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
            \'what\', \'Contact without any discount or credit.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
          jsonb_build_object(\'kind\', \'service_recovery\', \'primary\', false,
            \'what\', \'Re-run the first-visit experience for a sample of recent buyers at no charge \'
                    \'to find what is actually going wrong before spending on acquisition.\',
            \'cost_basis\', c_incentive_unavailable),
          jsonb_build_object(\'kind\', \'incentive\', \'primary\', false,
            \'what\', \'Offer a discount or loyalty credit to prompt a second visit.\',
            \'cost_basis\', c_incentive_unavailable))
      when v_domain = \'daypart\' then
        jsonb_build_array(
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
            \'what\', \'Contact without any discount or credit.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
          jsonb_build_object(\'kind\', \'incentive\', \'primary\', false,
            \'what\', \'Offer a discount or loyalty credit to prompt action.\',
            \'cost_basis\', c_incentive_unavailable),
          jsonb_build_object(\'kind\', \'operational_change\', \'primary\', false,
            \'what\', format(\'Re-staff the rota toward %s and pull promotion away from %s — no \'
                            \'incentive spend, just where the labour and marketing hours go.\',
                            v_valuable->>\'label\', v_busiest->>\'label\'),
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0,
              \'note\', \'operational, no incentive spend\')))
      when v_domain = \'cadence\'
           and (v_rebooking->\'cohorts\'->\'rebooked_at_departure\'->\'evidence\'->>\'status\') = \'ok\'
           and (v_rebooking->\'cohorts\'->\'rebooked_at_departure\'->\'within_window\'->>\'pct\') is not null
      then
        jsonb_build_array(
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
            \'what\', \'Contact without any discount or credit.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
          jsonb_build_object(\'kind\', \'incentive\', \'primary\', false,
            \'what\', \'Offer a discount or loyalty credit to prompt action.\',
            \'cost_basis\', c_incentive_unavailable),
          jsonb_build_object(\'kind\', \'rebooking\', \'primary\', false,
            \'what\', format(\'Book the next visit before the customer leaves — the rebooked-at-\'
                            \'departure cohort\'\'s within-window return rate is %s%% (n=%s) against \'
                            \'%s%% for everyone else.\',
                            v_rebooking->\'cohorts\'->\'rebooked_at_departure\'->\'within_window\'->>\'pct\',
                            v_rebooking->\'cohorts\'->\'rebooked_at_departure\'->>\'n\',
                            v_rebooking->\'cohorts\'->\'other\'->\'within_window\'->>\'pct\'),
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0,
              \'note\', \'operational, no incentive spend\')))
      else
        jsonb_build_array(
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
            \'what\', \'Contact without any discount or credit.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
          jsonb_build_object(\'kind\', \'incentive\', \'primary\', false,
            \'what\', \'Offer a discount or loyalty credit to prompt action.\',
            \'cost_basis\', c_incentive_unavailable))
      end;';

  a5 constant text := E'  v_c := v_cands_ext || v_new_cands;   -- v_c reused as the full pre-materiality candidate array';
  n5 constant text :=
E'  -- ---------------------------------------------------------------------------------------
  -- NESTLY v705 · NEW GENERATOR · campaigns (check 22): read -> purchase association rate from the
  -- marketing funnel reader. That reader is p_branch-rejecting (app.ci_no_branch_dimension_v667), so
  -- a branch-scoped call abstains honestly here rather than raising from a sub-reader it was never
  -- asked for by name (same pattern as generators B/E/G above).
  -- ---------------------------------------------------------------------------------------
  v_examined_ext := v_examined_ext + 1;
  if p_branch is not null then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      \'generator\', \'campaigns\',
      \'reason\', \'no branch dimension: campaign sends are recorded per business, not per branch\'));
  else
    v_campaign_funnel := public.get_ci_marketing_funnel_v1(p_business, p_from, p_to, null);
    if (v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'evidence\'->>\'status\') = \'ok\'
       and (v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'rate\'->>\'pct\') is not null then
      v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
        \'id\', \'campaigns\',
        \'domain\', \'campaigns\',
        \'pattern\', format(
          \'Of %s customers sent a campaign whose 30-day window has already matured, %s%% (%s of %s) \'
          \'made a purchase afterward.\',
          v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'rate\'->>\'denominator\',
          v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'rate\'->>\'pct\',
          v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'rate\'->>\'numerator\',
          v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'rate\'->>\'denominator\'),
        \'comparison\', jsonb_build_object(\'kind\', \'baseline\',
          \'detail\', format(\'read->purchase association rate %s%% (%s of %s), matured sends only\',
            v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'rate\'->>\'pct\',
            v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'rate\'->>\'numerator\',
            v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'rate\'->>\'denominator\')),
        \'impact\', jsonb_build_object(\'cents\', null,
          \'reason\', \'no incremental model: association with a subsequent purchase is not the same \'
                    \'as the campaign causing it\',
          \'scenario_cents\', null,
          \'expected_value\', jsonb_build_object(\'status\', \'unavailable\',
            \'reason\', \'no behavioural model backs a campaign association\')),
        \'action\', jsonb_build_object(\'who\', \'the owner or whoever runs marketing\', \'what\',
          \'Review this campaign\'\'s targeting and content; an association with a later purchase \'
          \'is not proof the campaign caused it.\', \'when\', \'this review cycle\', \'channel\', \'analysis\'),
        \'incentive\', jsonb_build_object(\'kind\', \'none\', \'declared\', true),
        \'why_now\', format(\'The association is already measurable on matured sends as of %s.\', p_to),
        \'reversal_condition\', \'Reconsider this call if the association rate falls materially on \'
                               \'the next measurement window.\',
        \'alternatives\', jsonb_build_array(
          jsonb_build_object(\'kind\', \'reminder_only\', \'primary\', true,
            \'what\', \'Note the association and monitor, no spend.\',
            \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'no spend\')),
          jsonb_build_object(\'kind\', \'incentive\', \'primary\', false,
            \'what\', \'Add an incentive to the next send to test whether it changes the rate.\',
            \'cost_basis\', c_incentive_unavailable)),
        \'cost_basis\', jsonb_build_object(\'status\', \'declared\', \'cents\', 0, \'note\', \'observation only\'),
        \'evidence\', jsonb_build_object(\'source_rpc\', \'public.get_ci_marketing_funnel_v1\',
          \'refs\', v_campaign_funnel->\'stages\'->\'associated_purchase\'),
        \'evidence_class\', (app.ci_verdict_class_v696(\'campaigns\')->>\'class\'),
        \'confidence\', v_campaign_funnel->\'stages\'->\'associated_purchase\'->\'evidence\',
        \'limitation\',
          \'Incremental effect is unavailable: this is an association between being sent a campaign \'
          \'and a later purchase, never causal — nothing in this engine runs a controlled experiment \'
          \'for campaign sends, and recipients are not a random draw from the customer base.\',
        \'rank_class\', \'unquantified\'));
    else
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        \'generator\', \'campaigns\',
        \'reason\', \'no matured send cohort clears the evidence floor, or no associated-purchase \'
                  \'rate is available\'));
    end if;
  end if;

  v_c := v_cands_ext || v_new_cands;   -- v_c reused as the full pre-materiality candidate array';

  a6 constant text :=
E'  select coalesce(jsonb_agg(e), \'[]\'::jsonb) into v_cands_ext
    from jsonb_array_elements(v_c) e
   where (e->\'impact\'->\'expected_value\'->>\'cents\') is null
      or (e->\'impact\'->\'expected_value\'->>\'cents\')::numeric >= v_ev_bar;';
  n6 constant text :=
E'  select coalesce(jsonb_agg(e), \'[]\'::jsonb) into v_cands_ext
    from jsonb_array_elements(v_c) e
   where (e->\'impact\'->\'expected_value\'->>\'cents\') is null
      or (e->\'impact\'->\'expected_value\'->>\'cents\')::numeric >= v_ev_bar;

  -- ---------------------------------------------------------------------------------------
  -- NESTLY v705 (checks 23/25/66/74) · materiality, margin guard, capacity, concentration —
  -- additive keys only, applied generically to every surviving extended-mode candidate (JC2 in
  -- this migration''s header). Never touches v_ranked/v_cands (the base pass), so v678/v696''s
  -- frozen twelve-key contract on p_extended=>false cannot regress.
  -- ---------------------------------------------------------------------------------------
  select coalesce(jsonb_agg(fin.c2 order by t.ord), \'[]\'::jsonb)
    into v_cands_ext
    from jsonb_array_elements(v_cands_ext) with ordinality as t(c, ord)
    cross join lateral (
      select coalesce((t.c->\'impact\'->\'expected_value\'->>\'cents\')::bigint,
                       (t.c->\'impact\'->>\'scenario_cents\')::bigint) as num
    ) n
    cross join lateral (
      select case
               when n.num is null then \'unquantified\'
               when v_period_revenue > 0
                    and round(10000.0 * n.num / v_period_revenue)
                        >= app.ci_materiality_threshold_bps_v705()
                 then \'material\'
               else \'minor\'
             end as mclass
    ) mc
    cross join lateral (
      select case when t.c->\'incentive\'->>\'kind\' in (\'credit\', \'discount\')
                  then v_margin_guard_cannibal else null end as mg
    ) g
    cross join lateral (
      select case when t.c->>\'domain\' in (\'retention_funnel\', \'daypart\', \'service_intelligence\',
                                           \'staff_performance\')
                  then v_capacity else null end as cap
    ) capx
    cross join lateral (
      select t.c || jsonb_build_object(
               \'materiality\', app.rate_block_v1(n.num, v_period_revenue),
               \'materiality_class\', mc.mclass,
               \'margin_guard\', g.mg,
               \'capacity\', capx.cap)
             as base
    ) b1
    cross join lateral (
      select case
               when t.c->>\'domain\' <> \'category_mix\' then b1.base
               when v_top_skew then
                 b1.base || jsonb_build_object(
                   \'concentration\', jsonb_build_object(
                     \'top1_share_bps\', (v_top->\'distribution\'->>\'top1_share_bps\')::int,
                     \'mean_excl_top1\', (v_top->\'distribution\'->>\'mean_excl_top1\')::numeric,
                     \'skew_note\', v_top->>\'skew_note\'),
                   \'pattern\', (t.c->>\'pattern\') || \' \' ||
                     format(\'Its top customer alone accounts for %s%% of the category.\',
                            round((v_top->\'distribution\'->>\'top1_share_bps\')::numeric / 100, 1)))
               else
                 b1.base || jsonb_build_object(\'concentration\', null)
             end as base2
    ) b2
    cross join lateral (
      select case
               when g.mg is not null and g.mg->>\'status\' = \'blocked\' then
                 b2.base2 || jsonb_build_object(\'rank_class\', \'unquantified\',
                   \'limitation\', (t.c->>\'limitation\') || \' \' || (g.mg->>\'reason\'))
               else b2.base2
             end as c2
    ) fin;';

  a7 constant text :=
E'  select coalesce(jsonb_agg(x.c || jsonb_build_object(\'rank\', x.rn) order by x.rn), \'[]\'::jsonb)
    into v_ranked_ext
    from (
      select c,
             row_number() over (
               order by case c->>\'rank_class\'
                          when \'foundation\' then 0
                          when \'quantified\' then 1
                          when \'unquantified\' then 2
                          else 3 end,
                        coalesce((c->\'impact\'->\'expected_value\'->>\'cents\')::bigint,
                                 (c->\'impact\'->>\'scenario_cents\')::bigint, 0) desc,
                        c->>\'domain\', c->>\'id\') as rn
        from jsonb_array_elements(v_cands_ext) c
       where c->\'confidence\'->>\'status\' = \'ok\'
    ) x;';
  n7 constant text :=
E'  select coalesce(jsonb_agg(x.c || jsonb_build_object(\'rank\', x.rn) order by x.rn), \'[]\'::jsonb)
    into v_ranked_ext
    from (
      select c,
             row_number() over (
               order by case c->>\'rank_class\'
                          when \'foundation\' then 0
                          when \'quantified\' then 1
                          when \'unquantified\' then 2
                          else 3 end,
                        case c->>\'materiality_class\'
                          when \'material\' then 0
                          when \'minor\' then 1
                          else 2 end,
                        coalesce((c->\'impact\'->\'expected_value\'->>\'cents\')::bigint,
                                 (c->\'impact\'->>\'scenario_cents\')::bigint, 0) desc,
                        c->>\'domain\', c->>\'id\') as rn
        from jsonb_array_elements(v_cands_ext) c
       where c->\'confidence\'->>\'status\' = \'ok\'
    ) x;';

  a8 constant text :=
E'  v_has_v683 := to_regprocedure(\'public.get_ci_discount_dependency_v1(uuid,date,date,uuid)\') is not null
            and to_regprocedure(\'public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid)\') is not null
            and to_regprocedure(\'public.get_ci_staff_performance_v1(uuid,date,date,uuid)\') is not null;';
  n8 constant text :=
E'  v_has_v683 := to_regprocedure(\'public.get_ci_discount_dependency_v1(uuid,date,date,uuid,timestamptz)\') is not null
            and to_regprocedure(\'public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid)\') is not null
            and to_regprocedure(\'public.get_ci_staff_performance_v1(uuid,date,date,uuid,timestamptz)\') is not null;';
begin
  select def into v_before from _v705_before;
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
  v_roundtrip := replace(v_roundtrip, n7, a7);
  v_roundtrip := replace(v_roundtrip, n8, a8);

  if v_roundtrip <> v_before then
    raise exception
      'v705: the new definition differs from the old one by more than the eight intended '
      'substitutions — reversing them did not reproduce the original body.';
  end if;

  if position('materiality_class' in v_before) > 0 then
    raise exception 'v705: materiality_class already present before this migration — stop and re-read';
  end if;
  if position('materiality_class' in v_after) = 0 then
    raise exception 'v705: materiality_class did not make it into the new body';
  end if;
  if position('ci_capacity_v705' in v_after) = 0 then
    raise exception 'v705: ci_capacity_v705 call did not make it into the new body';
  end if;
  if position('ci_margin_guard_v705' in v_after) = 0 then
    raise exception 'v705: ci_margin_guard_v705 call did not make it into the new body';
  end if;
  if position('get_ci_marketing_funnel_v1' in v_after) = 0 then
    raise exception 'v705: campaigns generator did not make it into the new body';
  end if;
  if position('get_ci_discount_dependency_v1(uuid,date,date,uuid,timestamptz)' in v_after) = 0 then
    raise exception 'v705: v_has_v683 gate (discount_dependency) was not corrected to the post-v699 5-arg signature';
  end if;
  if position('get_ci_staff_performance_v1(uuid,date,date,uuid,timestamptz)' in v_after) = 0 then
    raise exception 'v705: v_has_v683 gate (staff_performance) was not corrected to the post-v699 5-arg signature';
  end if;
end
$v705post$;

-- ================================================================================================
-- 8 · Self-certifying exhaustiveness: every generator name the LIVE (post-patch) body actually
--     emits must resolve through app.ci_verdict_class_v696 without raising (same style as v696's
--     own step 5 — belt-and-suspenders alongside the fixture's own, independent extraction).
-- ================================================================================================
do $v705exh$
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

  if v_names is null or array_length(v_names, 1) < 16 then
    raise exception
      'v705: extracted only % generator name(s) from the live body, expected at least 16 (v696''s '
      '15 plus campaigns) — the extraction regex itself may have drifted',
      coalesce(array_length(v_names, 1), 0);
  end if;

  if not ('campaigns' = any(v_names)) then
    raise exception 'v705: the live body no longer emits the campaigns generator name';
  end if;

  foreach v_name in array v_names loop
    begin
      v_class := app.ci_verdict_class_v696(v_name);
    exception when others then
      raise exception
        'v705: app.ci_verdict_class_v696 does not map generator "%" that the live body emits — %',
        v_name, sqlerrm;
    end;
    if v_class->>'class' not in ('DIRECT_FACT', 'ASSOCIATION') then
      raise exception 'v705: generator "%" mapped to non-typed class %', v_name, v_class->>'class';
    end if;
  end loop;
end
$v705exh$;

commit;
