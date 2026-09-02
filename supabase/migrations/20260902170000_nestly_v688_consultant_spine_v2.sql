-- NESTLY v688 — consultant spine v2: expected value, materiality, incentive disclosure,
-- alternatives, reversal conditions, and three new generator classes (discovery/change/strength),
-- plus (v683 being present in this tree) no_discount_reminder / loyalty_cannibalisation_gap /
-- staff_mix_underperformance.
--
-- Independently re-verified as REFUTED and re-closed here: checks 65 (materiality gate) and 73
-- (expected value alongside the raw scenario sum), plus 22, 43, 71, 74, 77, 78, 79.
--
-- Re-emit lineage: public.get_ci_opportunities_v1's body starts from the LIVE v680 re-emit
-- (db/migrations/20260902_nestly_v680_ci_envelope.sql:1478-2368 — confirmed via
-- pg_get_functiondef against the migrated harness before touching it), extract-and-diff,
-- byte-faithful except the additions documented below.
--
-- ================================================================================================
-- JUDGEMENT CALL 1 — a trailing p_extended flag, not a silent contract change.
-- ================================================================================================
-- db/tests/executed/v678_corpus_consultant_spine.sql and v680_corpus_envelope.sql are FROZEN,
-- unmodified inputs to this migration (the brief requires their assertions still pass) and both
-- assert an EXACT twelve-key contract on every candidate object
-- (action,comparison,confidence,domain,evidence,evidence_class,id,impact,limitation,pattern,
-- rank,rank_class — v678 line ~896) plus EXACT examined/promoted/ranked-length counts (14/10/10
-- for scenario 1, 8/0/1 for scenario 2). Every requirement in this migration's brief — expected
-- value, cost_basis, incentive, why_now, alternatives, reversal_condition, three-to-six new
-- generator classes, report_sections, top_actions — either adds new top-level candidate keys or
-- changes how many candidates a call produces. Doing that unconditionally would make v678's exact
-- key-set and exact count assertions fail on every run, not just the new one.
--
-- The trailing parameter follows the SAME pattern v680 itself used to add p_as_of: a new default
-- parameter never breaks a shorter existing call. `p_extended boolean default false` preserves
-- the v680 behaviour byte-for-byte for every caller that does not pass it — which is every
-- existing caller, including both frozen fixtures, since default false is HTTP/RPC-invisible
-- (nothing was calling with 6 positional args before this migration existed). A production caller
-- who wants expected value, materiality, cost basis, incentives, alternatives, reversal
-- conditions, discovery/change/strength candidates and report_sections passes p_extended=>true.
-- This is a disclosed compatibility seam, not a hidden downgrade: the OLD 8-generator core
-- (v_cands/v_abst/v_examined/v_ranked/freshness/refusal_reason) is computed identically in both
-- modes and is exactly what ships when p_extended is false.
--
-- ================================================================================================
-- JUDGEMENT CALL 2 — where the new fields live.
-- ================================================================================================
-- Because p_extended=>true is a genuinely different contract from the frozen one (no existing
-- fixture ever calls it), extended candidates are free to carry new top-level keys, and do:
-- incentive, why_now, alternatives, reversal_condition, cost_basis sit at the top level; impact
-- keeps 'cents'/'method'/'reason' from the base pass AND gains 'scenario_cents' (an explicit alias
-- of the same value — check 73's own wording, "the current raw sum, kept") plus 'expected_value'.
--
-- ================================================================================================
-- JUDGEMENT CALL 3 — the below_materiality tag on the two PRE-EXISTING gap/ratio abstentions.
-- ================================================================================================
-- Check 65's funnel-gap-15pp and daypart-ratio-2x rules ALREADY EXISTED in v680 (c_gap_pp,
-- c_daypart_ratio) — this migration's delta there is cosmetic (tagging the reason text with the
-- literal token 'below_materiality' so a caller can filter on it) plus ONE new rule: a quantified
-- candidate's expected value below 1% of the period's own known revenue also abstains as
-- 'below_materiality'. Verified safe against v678: neither of its two reason strings is asserted
-- by exact/substring match anywhere in that fixture (grepped before editing), so retagging them is
-- not a silent regression of a pinned string.
--
-- ================================================================================================
-- EXPECTED VALUE (check 73). lapsed_regulars: EV = sum over overdue regulars of
-- P_i * ticket_i, where P_i is app.return_probability_v681(business, client, p_as_of)'s
-- 'probability' (a customer on which that model itself abstains — k<3 measured intervals,
-- app.v681's OWN hard floor, independent of whatever this business's lifecycle policy accepts —
-- contributes 0 to the sum and is counted in expected_value.inputs.abstained, never silently
-- dropped). package_leakage: EV = sum over the plan's IN-WINDOW holders with sessions remaining
-- of (remaining_sessions * per_session_cents * P_holder), same model, same abstention handling.
-- Every other candidate's expected_value is {status:'unavailable', reason:...} — there is no
-- behavioural model backing a funnel-gap, a daypart ratio, a category share, a contactability
-- rate, a coverage gap, a discovery association, a deterioration, a strength, or (new) a discount-
-- dependency reminder cohort, a loyalty cannibalisation proxy, or a staff mix index. Fabricating a
-- number for any of those would be exactly the "assumed uplift" v680's own header already refused.
--
-- ================================================================================================
-- COST BASIS (check 74) is derived from incentive.kind, not asserted independently: kind='none'
-- (every reminder/operational action in this engine) => {status:'declared', cents:0, note:...}.
-- kind in ('credit','discount') (the loyalty-cannibalisation candidate, the only one in this
-- engine whose action is itself an incentive spend) => {status:'unavailable',
-- reason:'no cost coverage: services carry no cost field; products.cost_cents nullable'} — the
-- exact reason text the brief specifies, verbatim.
--
-- ================================================================================================
-- NEW GENERATOR CLASSES (checks 22, 79).
--   discovery  — one candidate per REPLICATED entry in public.get_ci_discovery_v1's own
--                'discoveries' array (holdout-validated already, by that reader's own contract);
--                evidence_class ASSOCIATION, rank_class 'unquantified'.
--   change     — one candidate per entry in that SAME reader's 'deteriorating' array (a
--                different pipeline inside v686, see that migration's header); rank_class
--                'unquantified'.
--   strength   — up to three candidates: the top evidence-ok weekday (by revenue_per_visit, from
--                the SAME v_daypart payload generator C already computed), the top classified
--                category (from v_catmix, generator D), and the top evidence-ok service (from
--                v_svc, generator F) by revenue. rank_class 'strength' — ranked AFTER every
--                opportunity rank_class (foundation < quantified < unquantified < strength), so a
--                strength never crowds out an actionable gap.
--   (present because db/migrations/20260902_nestly_v683_staff_rebooking_loyalty_discount.sql is
--   applied in this tree — checked via to_regprocedure, not assumed):
--   no_discount_reminder        — the discount-dependency reader's own reminder_only_candidates
--                                  cohort (check 57), summarised as ONE candidate, never one row
--                                  per customer (the reader itself already small-cell-suppresses
--                                  below 5; this generator additionally never lists individuals).
--   loyalty_cannibalisation_gap — the 'ready' loyalty programme with the highest
--                                  cannibalisation_proxy.within_cycle.pct (>=50%, evidence ok):
--                                  most of its redemptions coincide with visits the customer's own
--                                  rhythm already predicted, i.e. the programme is buying visits
--                                  that were coming anyway.
--   staff_mix_underperformance  — the staff member with the lowest mix-adjusted index (<0.80,
--                                  evidence ok) from get_ci_staff_performance_v1.
--
-- report_sections (checks 22/79) buckets ranked ids for a human skim: strengths (rank_class
-- 'strength'), change (domain 'change'), unnoticed_behaviour (domain 'discovery'), leakage
-- (domain in packages/discount_dependency/loyalty — money already at risk of walking away),
-- failures (every other promoted, non-foundation, non-do_nothing id), margin (always
-- {status:'unavailable', reason:...} — no COGS/cost-of-goods field exists on services or sales in
-- this schema, so a margin section can never be computed honestly), segments (discovery/change
-- entries whose dimension is itself a customer segment: age_gender or category_node).
-- top_actions is the first five entries of 'ranked', full objects (check 79).
-- ================================================================================================

begin;

drop function if exists public.get_ci_opportunities_v1(uuid,date,date,uuid,timestamptz);
create or replace function public.get_ci_opportunities_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp(), p_extended boolean default false)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  c_funnel_window   constant integer := 60;
  c_gap_pp          constant numeric := 15.0;
  c_util_pct        constant numeric := 50.0;
  c_conc_bps        constant integer := 6000;
  c_daypart_ratio   constant numeric := 2.0;
  c_gateway_min     constant integer := 5;
  c_reach_pct       constant numeric := 50.0;
  c_classified_bps  constant integer := 9000;
  c_demog_pct       constant numeric := 50.0;
  c_stale_days      constant integer := 400;
  c_stale_period_days constant integer := 90;
  c_ev_materiality_pct constant numeric := 1.0;   -- new (check 65): EV < 1% of period revenue
  c_cannibal_pct    constant numeric := 50.0;      -- new: loyalty_cannibalisation_gap bar
  c_staff_index_bar constant numeric := 0.80;      -- new: staff_mix_underperformance bar

  v_funnel      jsonb;
  v_daypart     jsonb;
  v_svc         jsonb;
  v_pkg         jsonb;
  v_catmix      jsonb;
  v_contact     jsonb;
  v_demog       jsonb;

  v_cands       jsonb := '[]'::jsonb;
  v_abst        jsonb := '[]'::jsonb;
  v_ranked      jsonb;
  v_examined    integer := 0;
  v_promoted    integer := 0;

  v_f_d1        bigint;
  v_f_d2        bigint;
  v_f_p1        numeric;
  v_f_p2        numeric;
  v_f_stage     text;
  v_f_conf      jsonb;

  v_conf        jsonb;
  v_hi          jsonb;
  v_lo          jsonb;
  v_busiest     jsonb;
  v_valuable    jsonb;
  v_top         jsonb;
  v_classified  bigint;
  v_share_bps   integer;

  v_lapsed_n    integer;
  v_lapsed_sum  bigint;

  v_plan        record;
  v_service     record;
  v_n_entities  integer;
  v_unused      bigint;
  v_unit        bigint;

  v_bo          jsonb;
  v_customers   bigint;
  v_best        bigint;
  v_best_ch     text;

  v_classified_bps integer;
  v_demog_pct   numeric;
  v_identified  bigint;

  v_obs_min     timestamptz;
  v_stale       boolean;
  v_period_far  boolean;
  v_refusal     text;
  v_result      jsonb;

  -- ---------------------------------------------------------------------------------------
  -- extended-mode-only state (all computed and used ONLY when p_extended)
  -- ---------------------------------------------------------------------------------------
  v_has_v683       boolean;
  v_period_revenue bigint;
  v_ev_bar         numeric;
  v_cands_ext      jsonb := '[]'::jsonb;
  v_abst_ext       jsonb;
  v_ranked_ext     jsonb;
  v_examined_ext   integer;
  v_promoted_ext   integer;
  v_c              jsonb;
  v_id             text;
  v_domain         text;
  v_impact         jsonb;
  v_action         jsonb;
  v_incentive      jsonb;
  v_why_now        text;
  v_alternatives   jsonb;
  v_reversal       text;
  v_cost_basis     jsonb;
  v_ev             jsonb;

  v_ev_lapsed_cents   bigint;
  v_ev_lapsed_abst    integer;
  v_ev_pkg_cents      bigint;
  v_ev_pkg_abst       integer;

  v_discovery       jsonb;
  v_new_cands       jsonb := '[]'::jsonb;
  v_dsc             record;

  v_top_weekday     jsonb;
  v_top_category    jsonb;
  v_top_service     jsonb;

  v_discount_dep    jsonb;
  v_reminder_n      integer;
  v_loyalty         jsonb;
  v_best_programme  text;
  v_best_cannibal   numeric;
  v_staff_perf      jsonb;
  v_worst_staff     jsonb;

  v_report_sections jsonb;
  v_top_actions     jsonb;

  c_incentive_unavailable constant jsonb := jsonb_build_object(
    'status', 'unavailable',
    'reason', 'no cost coverage: services carry no cost field; products.cost_cents nullable');
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  -- =============================================================================================
  -- GENERATOR A · retention funnel — a named bottleneck with a material gap between the stages
  -- =============================================================================================
  v_examined := v_examined + 1;
  v_funnel := public.get_ci_funnel_conversion_v1(p_business, p_from, p_to, c_funnel_window, p_branch, p_as_of);
  v_f_d1 := (v_funnel->'stage_1_to_2'->>'denominator')::bigint;
  v_f_d2 := (v_funnel->'stage_2_to_3'->>'denominator')::bigint;
  v_f_p1 := (v_funnel->'stage_1_to_2'->>'pct')::numeric;
  v_f_p2 := (v_funnel->'stage_2_to_3'->>'pct')::numeric;
  v_f_stage := v_funnel->>'bottleneck';
  v_f_conf := app.subgroup_evidence_v1(least(coalesce(v_f_d1, 0), coalesce(v_f_d2, 0))::int);

  if v_f_stage is null or v_f_p1 is null or v_f_p2 is null then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'funnel_bottleneck',
      'reason', 'no bottleneck is nameable: a stage rate is null or the two stages are tied'));
  elsif v_f_conf->>'status' <> 'ok' then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'funnel_bottleneck',
      'reason', format('smallest stage denominator (%s) is below the sample floor of %s',
                        v_f_conf->>'n', v_f_conf->>'floor')));
  elsif abs(v_f_p1 - v_f_p2) < c_gap_pp then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'funnel_bottleneck',
      'reason', format('below_materiality: the stages differ by %s points, below the %s-point '
                        'materiality bar', round(abs(v_f_p1 - v_f_p2), 1), c_gap_pp)));
  else
    v_cands := v_cands || jsonb_build_array(jsonb_build_object(
      'id', 'funnel_bottleneck',
      'domain', 'retention_funnel',
      'pattern', format(
        'Of %s customers whose first visit matured, %s%% came back for a second within %s days, '
        'and %s%% of those went on to a third; the %s step is the weaker of the two by %s points.',
        v_f_d1, v_f_p1, c_funnel_window, v_f_p2, replace(v_f_stage, '_', '-'),
        round(abs(v_f_p1 - v_f_p2), 1)),
      'comparison', jsonb_build_object(
        'kind', 'cross_segment',
        'detail', format('first-to-second conversion (%s%%, n=%s) against second-to-third '
                          '(%s%%, n=%s), both on the same %s-day maturity rule',
                          v_f_p1, v_f_d1, v_f_p2, v_f_d2, c_funnel_window)),
      'impact', jsonb_build_object(
        'cents', null,
        'reason', 'no incremental model: converting a funnel gap into cents requires an assumed '
                  'uplift, which would be a forecast rather than a measurement'),
      'action', jsonb_build_object(
        'who', 'the owner, with the staff who serve the visit before the drop',
        'what', format('Fix the %s drop-off — rework what happens at the end of that visit '
                        '(rebook on the spot, name the next appointment, hand over the follow-up '
                        'offer) rather than adding another campaign upstream of it.',
                        replace(v_f_stage, '_', '-')),
        'when', 'within the next full ' || c_funnel_window || '-day cycle, so the change is measurable',
        'channel', 'in_person_at_checkout'),
      'evidence', jsonb_build_object(
        'source_rpc', 'public.get_ci_funnel_conversion_v1',
        'refs', jsonb_build_object(
          'stage_1_to_2', v_funnel->'stage_1_to_2',
          'stage_2_to_3', v_funnel->'stage_2_to_3',
          'bottleneck', v_f_stage,
          'immature', v_funnel->'immature',
          'window_days', v_funnel->'window_days',
          'reader_evidence', v_funnel->'evidence')),
      'evidence_class', 'DIRECT_FACT',
      'confidence', v_f_conf,
      'limitation',
        'Both rates are measured on customers who have already had a full window, so a recent '
        'change in how the firm operates is not visible here yet, and the two stages are not the '
        'same people — the second-to-third denominator is a self-selected subset of the first.',
      'rank_class', 'unquantified'));
  end if;

  -- =============================================================================================
  -- GENERATOR B · lapsed regulars — customers overdue against their OWN median rhythm
  -- =============================================================================================
  v_examined := v_examined + 1;
  if p_branch is not null then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'lapsed_regulars',
      'reason', 'no branch dimension: app.customer_cadence_v1 resolves the v107 lifecycle policy '
                'firm-wide and emits deviation_state only for a firm-wide computation'));
  else
    with overdue as materialized (
      select b.client_id
        from app.customer_cadence_batch_v1(
               p_business,
               ((p_as_of at time zone 'Asia/Singapore')::date + 1),
               ((p_as_of at time zone 'Asia/Singapore')::date + 1),
               p_as_of, null, true) b
        cross join lateral (
          select app.customer_cadence_v1(p_business, b.client_id) as cad
        ) c
       where c.cad->>'deviation_state' = 'overdue'
         and c.cad->>'evidence_source' = 'customer_median_interval'
    ),
    tickets as (
      select o.client_id,
             round(sum(s.amount_cents)::numeric / count(*)) as avg_ticket
        from overdue o
        join public.sales s
          on s.business_id = p_business
         and app.v111_effective_client_id(s.business_id, s.client_id) = o.client_id
        cross join lateral app.analytics_sale_class_v1(s) sc
       where sc.include_revenue
         and not sc.is_synthetic_client
         and s.created_at <= p_as_of
       group by o.client_id
    )
    select count(*)::int, coalesce(sum(coalesce(t.avg_ticket, 0)), 0)::bigint
      into v_lapsed_n, v_lapsed_sum
      from overdue o
      left join tickets t on t.client_id = o.client_id;

    v_conf := app.subgroup_evidence_v1(coalesce(v_lapsed_n, 0));
    if coalesce(v_lapsed_n, 0) = 0 then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'lapsed_regulars',
        'reason', 'no customer is overdue against a rhythm of their own: every overdue customer '
                  'is judged on the business fallback, which says nothing about that person'));
    elsif v_conf->>'status' <> 'ok' then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'lapsed_regulars',
        'reason', format('%s overdue regular(s) is below the sample floor of %s',
                          v_conf->>'n', v_conf->>'floor')));
    else
      v_cands := v_cands || jsonb_build_array(jsonb_build_object(
        'id', 'lapsed_regulars',
        'domain', 'cadence',
        'pattern', format(
          '%s customers with an established visit rhythm are now overdue against their OWN median '
          'interval; one return visit each at their own historical average ticket is worth %s cents.',
          v_lapsed_n, v_lapsed_sum),
        'comparison', jsonb_build_object(
          'kind', 'baseline',
          'detail', 'each customer is compared against their own median inter-visit interval '
                    '(app.customer_cadence_v1, evidence_source=customer_median_interval), never '
                    'against a firm-wide days-since-last-visit cut-off'),
        'impact', jsonb_build_object(
          'cents', v_lapsed_sum,
          'method', 'sum over the overdue regulars of round(that customer''s lifetime '
                    'revenue-qualifying sale total / their count of such sales) — one visit each, '
                    'at their own average ticket. No response rate, no uplift, no discounting.'),
        'action', jsonb_build_object(
          'who', 'front desk',
          'what', 'Contact these customers individually, referencing what they last had and when, '
                  'before offering anything — the list is small enough to work by hand and a '
                  'discount is not what a customer with a broken rhythm is missing.',
          'when', 'this week',
          'channel', 'whatsapp_or_call_where_consent_exists'),
        'evidence', jsonb_build_object(
          'source_rpc', 'app.customer_cadence_batch_v1 + app.customer_cadence_v1',
          'refs', jsonb_build_object(
            'overdue_regulars', v_lapsed_n,
            'recoverable_cents', v_lapsed_sum,
            'deviation_state', 'overdue',
            'evidence_source', 'customer_median_interval')),
        'evidence_class', 'ASSOCIATION',
        'confidence', v_conf,
        'limitation',
          'An overdue customer is not a lost customer: some would have returned unprompted, so '
          'the figure is the value at stake, not the value a campaign would add.',
        'rank_class', 'quantified'));
    end if;
  end if;

  -- =============================================================================================
  -- GENERATOR C · dead-vs-gold weekday — the busiest day is not the valuable one
  -- =============================================================================================
  v_examined := v_examined + 1;
  v_daypart := public.get_ci_daypart_v1(p_business, p_from, p_to, p_branch, p_as_of);
  v_busiest := v_daypart->'busiest_weekday';
  v_valuable := v_daypart->'most_valuable_weekday';

  select w into v_hi
    from jsonb_array_elements(coalesce(v_daypart->'weekdays', '[]'::jsonb)) w
   where w->'evidence'->>'status' = 'ok'
     and w->>'revenue_per_visit_cents' is not null
     and (w->>'revenue_per_visit_cents')::numeric > 0
   order by (w->>'revenue_per_visit_cents')::numeric desc, (w->>'dow')::int
   limit 1;
  select w into v_lo
    from jsonb_array_elements(coalesce(v_daypart->'weekdays', '[]'::jsonb)) w
   where w->'evidence'->>'status' = 'ok'
     and w->>'revenue_per_visit_cents' is not null
     and (w->>'revenue_per_visit_cents')::numeric > 0
   order by (w->>'revenue_per_visit_cents')::numeric asc, (w->>'dow')::int
   limit 1;

  if v_busiest is null or v_valuable is null or v_valuable->>'dow' is null then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'daypart_shift',
      'reason', 'no weekday clears the evidence floor, so no weekday may be called most valuable'));
  elsif (v_busiest->>'dow')::int = (v_valuable->>'dow')::int then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'daypart_shift',
      'reason', format('the busiest and most valuable weekday are the same day (%s); there is no '
                        'capacity to shift', v_busiest->>'label')));
  elsif v_hi is null or v_lo is null or (v_hi->>'dow')::int = (v_lo->>'dow')::int then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'daypart_shift',
      'reason', 'no comparable pair of evidence-backed weekdays exists to compare a ratio against'));
  elsif (v_hi->>'revenue_per_visit_cents')::numeric
             < c_daypart_ratio * (v_lo->>'revenue_per_visit_cents')::numeric then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'daypart_shift',
      'reason', format('below_materiality: no pair of evidence-backed weekdays differs by %sx in '
                        'revenue per visit (actual ratio %s)', c_daypart_ratio,
                        round((v_hi->>'revenue_per_visit_cents')::numeric
                              / nullif((v_lo->>'revenue_per_visit_cents')::numeric, 0), 2))));
  else
    v_conf := app.subgroup_evidence_v1(least((v_hi->>'visits')::int, (v_lo->>'visits')::int));
    if v_conf->>'status' <> 'ok' then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'daypart_shift',
        'reason', 'the thinner of the two compared weekdays is below the sample floor'));
    else
      v_cands := v_cands || jsonb_build_array(jsonb_build_object(
        'id', 'daypart_shift',
        'domain', 'daypart',
        'pattern', format(
          '%s takes %s cents per visit against %s''s %s — %sx — while %s is the busiest day by '
          'volume (%s visits).',
          v_hi->>'label', v_hi->>'revenue_per_visit_cents', v_lo->>'label',
          v_lo->>'revenue_per_visit_cents',
          round((v_hi->>'revenue_per_visit_cents')::numeric
                 / nullif((v_lo->>'revenue_per_visit_cents')::numeric, 0), 1),
          v_busiest->>'label', v_busiest->>'visits'),
        'comparison', jsonb_build_object(
          'kind', 'cross_segment',
          'detail', format('%s (n=%s visits) against %s (n=%s visits), both above the sample floor, '
                            'each measured over the same number of weekday occurrences in the window',
                            v_hi->>'label', v_hi->>'visits', v_lo->>'label', v_lo->>'visits')),
        'impact', jsonb_build_object(
          'cents', null,
          'reason', 'no incremental model: moving capacity between weekdays has no measured '
                    'counterfactual here, and assuming the gold day''s per-visit value would '
                    'survive extra volume is exactly the assumption that must not be smuggled in'),
        'action', jsonb_build_object(
          'who', 'the owner, with whoever writes the rota',
          'what', format('Shift capacity and promotion toward %s — staff it first, book the '
                          'higher-value work into it, and stop spending promotion on %s, which is '
                          'already full of low-value visits.',
                          v_valuable->>'label', v_busiest->>'label'),
          'when', 'next rota cycle',
          'channel', 'rota_and_promotions'),
        'evidence', jsonb_build_object(
          'source_rpc', 'public.get_ci_daypart_v1',
          'refs', jsonb_build_object(
            'gold_weekday', v_hi,
            'dead_weekday', v_lo,
            'busiest_weekday', v_busiest,
            'most_valuable_weekday', v_valuable,
            'time_basis', v_daypart->'time_basis')),
        'evidence_class', 'ASSOCIATION',
        'confidence', v_conf,
        'limitation',
          'Revenue per visit is a mix effect as much as a day effect: the valuable day may simply '
          'be when the expensive service is offered, and the till timestamp is not arrival time.',
        'rank_class', 'unquantified'));
    end if;
  end if;

  -- =============================================================================================
  -- GENERATOR D · category concentration — diversification risk
  -- =============================================================================================
  v_examined := v_examined + 1;
  v_catmix := public.get_ci_category_mix_v1(p_business, p_from, p_to, p_branch, p_as_of);
  select coalesce(sum((c->>'revenue_cents')::bigint), 0) into v_classified
    from jsonb_array_elements(coalesce(v_catmix->'categories', '[]'::jsonb)) c;
  select c into v_top
    from jsonb_array_elements(coalesce(v_catmix->'categories', '[]'::jsonb)) c
   order by (c->>'revenue_cents')::bigint desc, c->>'node_key'
   limit 1;

  if v_top is null or coalesce(v_classified, 0) <= 0 then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'category_concentration',
      'reason', 'no classified revenue in the window, so no share can be computed'));
  else
    v_share_bps := (10000.0 * (v_top->>'revenue_cents')::bigint / v_classified)::int;
    v_conf := app.subgroup_evidence_v1((v_top->>'customer_count')::int);
    if v_share_bps < c_conc_bps then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'category_concentration',
        'reason', format('the largest category holds %s bps of classified revenue, below the %s '
                          'bps concentration bar', v_share_bps, c_conc_bps)));
    elsif v_conf->>'status' <> 'ok' then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'category_concentration',
        'reason', format('the largest category has %s customer(s), below the sample floor of %s',
                          v_conf->>'n', v_conf->>'floor')));
    else
      v_cands := v_cands || jsonb_build_array(jsonb_build_object(
        'id', 'category_concentration',
        'domain', 'category_mix',
        'pattern', format(
          '%s cents of %s cents of classified revenue — %s%% — comes from a single category (%s), '
          'bought by %s customers.',
          v_top->>'revenue_cents', v_classified, round(v_share_bps / 100.0, 1),
          coalesce(v_top->>'label', v_top->>'node_key'), v_top->>'customer_count'),
        'comparison', jsonb_build_object(
          'kind', 'threshold',
          'detail', format('largest level-2 category share of CLASSIFIED revenue (%s bps) against '
                            'the %s bps concentration bar; unclassified revenue is deliberately '
                            'outside the denominator', v_share_bps, c_conc_bps)),
        'impact', jsonb_build_object(
          'cents', null,
          'reason', 'concentration is an exposure profile, not a cash figure; the amount at risk '
                    'is the category revenue already stated, and how much of it would actually '
                    'move is unmeasurable from this data'),
        'action', jsonb_build_object(
          'who', 'the owner',
          'what', format('Treat %s as a single point of failure: know what a price, staffing or '
                          'demand change there does to the month, and pick ONE adjacent category '
                          'to grow deliberately rather than diversifying everywhere at once.',
                          coalesce(v_top->>'label', v_top->>'node_key')),
          'when', 'this quarter',
          'channel', 'planning'),
        'evidence', jsonb_build_object(
          'source_rpc', 'public.get_ci_category_mix_v1',
          'refs', jsonb_build_object(
            'top_category', v_top,
            'classified_revenue_cents', v_classified,
            'top_share_bps', v_share_bps,
            'coverage', v_catmix->'coverage')),
        'evidence_class', 'DIRECT_FACT',
        'confidence', v_conf,
        'limitation',
          'A concentrated mix is not automatically a fault — a specialist earns its living that '
          'way — and this share is computed only over revenue that was classified at all.',
        'rank_class', 'unquantified'));
    end if;
  end if;

  -- =============================================================================================
  -- GENERATOR E · package leakage — prepaid sessions nobody is using (one candidate per plan)
  -- =============================================================================================
  if p_branch is not null then
    v_examined := v_examined + 1;
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'package_leakage',
      'reason', 'no branch dimension: client_packages carries no branch column (v675), so a '
                'branch-scoped utilisation figure cannot be produced honestly'));
  else
    v_pkg := public.get_ci_package_intelligence_v1(p_business, p_from, p_to, null, p_as_of);
    v_n_entities := coalesce(jsonb_array_length(v_pkg->'plans'), 0);
    v_examined := v_examined + greatest(1, v_n_entities);
    if v_n_entities = 0 then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'package_leakage',
        'reason', 'no package plan had a purchase inside the window'));
    end if;
    for v_plan in
      select e.value as p from jsonb_array_elements(coalesce(v_pkg->'plans', '[]'::jsonb)) e
    loop
      if v_plan.p->'evidence'->>'status' <> 'ok' then
        v_abst := v_abst || jsonb_build_array(jsonb_build_object(
          'generator', 'package_leakage:' || (v_plan.p->>'plan_id'),
          'reason', format('%s package(s) sold in the window is below the sample floor of %s',
                            v_plan.p->'evidence'->>'n', v_plan.p->'evidence'->>'floor')));
      elsif v_plan.p->'utilisation'->>'pct' is null
            or (v_plan.p->'utilisation'->>'pct')::numeric >= c_util_pct then
        v_abst := v_abst || jsonb_build_array(jsonb_build_object(
          'generator', 'package_leakage:' || (v_plan.p->>'plan_id'),
          'reason', format('utilisation is %s%%, at or above the %s%% leakage bar',
                            coalesce(v_plan.p->'utilisation'->>'pct', 'null'), c_util_pct)));
      else
        v_unused := (v_plan.p->>'sessions_included')::bigint
                     - (v_plan.p->>'sessions_used')::bigint;
        select round(pp.price_cents::numeric / nullif(pp.sessions, 0))::bigint into v_unit
          from public.package_plans pp
         where pp.id = (v_plan.p->>'plan_id')::uuid and pp.business_id = p_business;
        if v_unit is null or v_unused <= 0 then
          v_abst := v_abst || jsonb_build_array(jsonb_build_object(
            'generator', 'package_leakage:' || (v_plan.p->>'plan_id'),
            'reason', 'no unused sessions, or the plan carries no per-session price to value them'));
        else
          v_cands := v_cands || jsonb_build_array(jsonb_build_object(
            'id', 'package_leakage:' || (v_plan.p->>'plan_id'),
            'domain', 'packages',
            'pattern', format(
              '%s of %s sessions sold on "%s" are still unused (%s%% utilisation across %s '
              'packages), worth %s cents of prepaid service at %s cents a session.',
              v_unused, v_plan.p->>'sessions_included', v_plan.p->>'plan_name',
              v_plan.p->'utilisation'->>'pct', v_plan.p->>'sold_count',
              v_unused * v_unit, v_unit),
            'comparison', jsonb_build_object(
              'kind', 'threshold',
              'detail', format('plan utilisation %s%% against the %s%% bar, on %s packages sold '
                                'inside the window', v_plan.p->'utilisation'->>'pct', c_util_pct,
                                v_plan.p->>'sold_count')),
            'impact', jsonb_build_object(
              'cents', v_unused * v_unit,
              'method', format('(sessions_included %s - sessions_used %s) x round(plan price / '
                                'plan sessions) = %s x %s. The session count comes from '
                                'get_ci_package_intelligence_v1; the per-session unit from '
                                'public.package_plans, which the payload does not carry.',
                                v_plan.p->>'sessions_included', v_plan.p->>'sessions_used',
                                v_unused, v_unit)),
            'action', jsonb_build_object(
              'who', 'front desk',
              'what', format('Book the unused "%s" sessions out: call every holder with sessions '
                              'left and put a date in the diary on the call, rather than waiting '
                              'for them to come back on their own.', v_plan.p->>'plan_name'),
              'when', 'this month',
              'channel', 'call_or_whatsapp_where_consent_exists'),
            'evidence', jsonb_build_object(
              'source_rpc', 'public.get_ci_package_intelligence_v1 + public.package_plans',
              'refs', jsonb_build_object(
                'plan_id', v_plan.p->'plan_id',
                'plan_name', v_plan.p->'plan_name',
                'sold_count', v_plan.p->'sold_count',
                'sessions_included', v_plan.p->'sessions_included',
                'sessions_used', v_plan.p->'sessions_used',
                'utilisation', v_plan.p->'utilisation',
                'expired_or_lapsed_with_unused', v_plan.p->'expired_or_lapsed_with_unused',
                'unused_sessions', v_unused,
                'per_session_cents', v_unit)),
            'evidence_class', 'DIRECT_FACT',
            'confidence', v_plan.p->'evidence',
            'limitation',
              'This is prepaid service at risk of lapsing, not new revenue: the money was already '
              'recognised when the package was sold, and a holder who bought at an older price is '
              'valued here at the plan''s current list price.',
            'rank_class', 'quantified'));
        end if;
      end if;
    end loop;
  end if;

  -- =============================================================================================
  -- GENERATOR F · gateway services whose buyers do not come back (one candidate per service)
  -- =============================================================================================
  v_svc := public.get_ci_service_intelligence_v1(p_business, p_from, p_to, p_branch, p_as_of);
  v_n_entities := coalesce(jsonb_array_length(v_svc->'services'), 0);
  v_examined := v_examined + greatest(1, v_n_entities);
  if v_f_p1 is null or v_f_conf->>'status' <> 'ok' then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'gateway_followthrough',
      'reason', 'the firm''s own first-to-second funnel rate is unavailable or below the sample '
                'floor, so there is no baseline to judge a service against'));
  elsif v_n_entities = 0 then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'gateway_followthrough',
      'reason', 'no service was bought inside the window'));
  else
    for v_service in
      select e.value as s from jsonb_array_elements(coalesce(v_svc->'services', '[]'::jsonb)) e
    loop
      if (v_service.s->>'gateway_count')::int < c_gateway_min then
        v_abst := v_abst || jsonb_build_array(jsonb_build_object(
          'generator', 'gateway_followthrough:' || (v_service.s->>'service_id'),
          'reason', format('%s first-ever buyers is below the %s needed to call it a gateway',
                            v_service.s->>'gateway_count', c_gateway_min)));
      elsif v_service.s->'evidence'->>'status' <> 'ok'
            or v_service.s->'repeat_rate'->>'pct' is null then
        v_abst := v_abst || jsonb_build_array(jsonb_build_object(
          'generator', 'gateway_followthrough:' || (v_service.s->>'service_id'),
          'reason', 'the service''s buyer count is below the sample floor, so its repeat rate is '
                    'withheld and cannot be compared'));
      elsif v_f_p1 - (v_service.s->'repeat_rate'->>'pct')::numeric < c_gap_pp then
        v_abst := v_abst || jsonb_build_array(jsonb_build_object(
          'generator', 'gateway_followthrough:' || (v_service.s->>'service_id'),
          'reason', format('repeat rate %s%% trails the firm''s %s%% by less than %s points',
                            v_service.s->'repeat_rate'->>'pct', v_f_p1, c_gap_pp)));
      else
        v_conf := app.subgroup_evidence_v1(
                    least((v_service.s->>'buyers')::int, coalesce(v_f_d1, 0)::int));
        if v_conf->>'status' <> 'ok' then
          v_abst := v_abst || jsonb_build_array(jsonb_build_object(
            'generator', 'gateway_followthrough:' || (v_service.s->>'service_id'),
            'reason', 'the smaller of the service''s buyers and the funnel denominator is below '
                      'the sample floor'));
        else
          v_cands := v_cands || jsonb_build_array(jsonb_build_object(
            'id', 'gateway_followthrough:' || (v_service.s->>'service_id'),
            'domain', 'service_intelligence',
            'pattern', format(
              '"%s" is how %s customers first arrived, but only %s%% of its %s buyers bought it '
              'again, against a firm-wide first-to-second rate of %s%% — %s points behind.',
              v_service.s->>'service_name', v_service.s->>'gateway_count',
              v_service.s->'repeat_rate'->>'pct', v_service.s->>'buyers', v_f_p1,
              round(v_f_p1 - (v_service.s->'repeat_rate'->>'pct')::numeric, 1)),
            'comparison', jsonb_build_object(
              'kind', 'baseline',
              'detail', format('this service''s repeat rate (%s of %s buyers) against the firm''s '
                                'own first-to-second conversion (%s%%, n=%s) as the baseline',
                                v_service.s->'repeat_rate'->>'numerator',
                                v_service.s->'repeat_rate'->>'denominator', v_f_p1, v_f_d1)),
            'impact', jsonb_build_object(
              'cents', null,
              'reason', 'no incremental model: the gap says the first experience under-converts, '
                        'not how much revenue a better one would add'),
            'action', jsonb_build_object(
              'who', 'the owner, with the staff who deliver this service',
              'what', format('Fix the first-visit experience for "%s": watch the appointment end '
                              'to end, decide what the next step should be for someone who has '
                              'only ever had this one thing, and make offering it part of the '
                              'service rather than an afterthought.', v_service.s->>'service_name'),
              'when', 'within the month',
              'channel', 'in_person_at_the_appointment'),
            'evidence', jsonb_build_object(
              'source_rpc', 'public.get_ci_service_intelligence_v1 + '
                            'public.get_ci_funnel_conversion_v1',
              'refs', jsonb_build_object(
                'service_id', v_service.s->'service_id',
                'service_name', v_service.s->'service_name',
                'buyers', v_service.s->'buyers',
                'orders', v_service.s->'orders',
                'revenue_cents', v_service.s->'revenue_cents',
                'gateway_count', v_service.s->'gateway_count',
                'repeat_rate', v_service.s->'repeat_rate',
                'firm_stage_1_to_2', v_funnel->'stage_1_to_2')),
            'evidence_class', 'ASSOCIATION',
            'confidence', v_conf,
            'limitation',
              'Whoever chooses this service is not a random draw from the firm''s first-timers, so '
              'the gap may be who they are rather than what happened to them.',
            'rank_class', 'unquantified'));
        end if;
      end if;
    end loop;
  end if;

  -- =============================================================================================
  -- GENERATOR G · contactability — most customers cannot legally be reached at all
  -- =============================================================================================
  v_examined := v_examined + 1;
  if p_branch is not null then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'contactability_gap',
      'reason', 'no branch dimension: consent is recorded per business, not per branch'));
  else
    v_contact := public.get_ci_contactability_v1(p_business, null);
    v_bo := v_contact->'business_offers';
    v_customers := (v_bo->>'customers')::bigint;
    select e.key, e.value::bigint into v_best_ch, v_best
      from jsonb_each_text(coalesce(v_bo->'allowed_by_channel', '{}'::jsonb)) e
     order by e.value::bigint desc, e.key
     limit 1;
    v_conf := app.subgroup_evidence_v1(coalesce(v_customers, 0)::int);
    if coalesce(v_customers, 0) = 0 or v_conf->>'status' <> 'ok' then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'contactability_gap',
        'reason', format('%s identified customer(s) is below the sample floor of %s',
                          v_conf->>'n', v_conf->>'floor')));
    elsif 100.0 * coalesce(v_best, 0) / v_customers >= c_reach_pct then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'contactability_gap',
        'reason', format('the best channel reaches %s%% of customers, at or above the %s%% bar',
                          round(100.0 * coalesce(v_best, 0) / v_customers, 1), c_reach_pct)));
    else
      v_cands := v_cands || jsonb_build_array(jsonb_build_object(
        'id', 'contactability_gap',
        'domain', 'contactability',
        'pattern', format(
          'Only %s of %s customers (%s%%) can lawfully be sent a business offer on the best '
          'available channel (%s); the rest have no affirmative consent on record.',
          coalesce(v_best, 0), v_customers,
          round(100.0 * coalesce(v_best, 0) / v_customers, 1), v_best_ch),
        'comparison', jsonb_build_object(
          'kind', 'threshold',
          'detail', format('best single-channel reachable share (%s of %s) against the %s%% bar; '
                            'the best channel is used because per-channel counts cannot be unioned '
                            'from the reader''s payload, which makes this an under-statement of '
                            'reach, never an over-statement',
                            coalesce(v_best, 0), v_customers, c_reach_pct)),
        'impact', jsonb_build_object(
          'cents', null,
          'reason', 'no incremental model: the value of being able to contact someone depends on '
                    'what would be said to them, which does not exist yet'),
        'action', jsonb_build_object(
          'who', 'front desk',
          'what', 'Ask for consent at checkout, in person, with the notice shown — one question '
                  'at the point of payment, recorded per channel. Do not bulk-import or assume '
                  'existing customers are opted in.',
          'when', 'starting immediately, reviewed in 30 days',
          'channel', 'in_person_at_checkout'),
        'evidence', jsonb_build_object(
          'source_rpc', 'public.get_ci_contactability_v1',
          'refs', jsonb_build_object(
            'business_offers', v_bo,
            'best_channel', v_best_ch,
            'best_channel_allowed', coalesce(v_best, 0),
            'note', v_contact->'note')),
        'evidence_class', 'DIRECT_FACT',
        'confidence', v_conf,
        'limitation',
          'A customer unreachable for marketing is still reachable for a booking they asked for; '
          'this counts consent for proactive offers only, and a customer with two channels is '
          'counted once per channel, so the true reachable union is somewhere between the best '
          'channel and their sum.',
        'rank_class', 'unquantified'));
    end if;
  end if;

  -- =============================================================================================
  -- GENERATOR H · data quality (check 30) — a FOUNDATION candidate, ranked above business advice
  -- =============================================================================================
  v_examined := v_examined + 1;
  v_demog := public.get_ci_demographics_v1(p_business, p_from, p_to, p_branch, p_as_of);
  v_classified_bps := (v_catmix->'coverage'->>'classified_pct_bps')::int;
  v_demog_pct := (v_demog->'coverage'->'demographics'->>'pct')::numeric;
  v_identified := (v_demog->'coverage'->'demographics'->>'denominator')::bigint;
  v_conf := app.subgroup_evidence_v1(coalesce(v_identified, 0)::int);

  if v_conf->>'status' <> 'ok' then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'data_quality_coverage',
      'reason', format('%s identified customer(s) is below the sample floor of %s, so a coverage '
                        'complaint would itself rest on nothing',
                        v_conf->>'n', v_conf->>'floor')));
  elsif not ((v_classified_bps is not null and v_classified_bps < c_classified_bps)
             or (v_demog_pct is not null and v_demog_pct < c_demog_pct)) then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'data_quality_coverage',
      'reason', format('coverage is adequate: %s bps of revenue classified, %s%% of customers '
                        'demographically resolved', coalesce(v_classified_bps::text, 'null'),
                        coalesce(v_demog_pct::text, 'null'))));
  else
    v_cands := v_cands || jsonb_build_array(jsonb_build_object(
      'id', 'data_quality_coverage',
      'domain', 'data_quality',
      'pattern', format(
        'Only %s%% of revenue is classified to a category and only %s%% of %s active customers '
        'have a resolved age and gender — every category, cohort and mix finding below is drawn '
        'from that fraction.',
        case when v_classified_bps is null then 'an unknown share of'
             else round(v_classified_bps / 100.0, 1)::text end,
        coalesce(v_demog_pct::text, 'an unknown share of'), v_identified),
      'comparison', jsonb_build_object(
        'kind', 'threshold',
        'detail', format('classified revenue coverage %s bps against %s bps, and demographic '
                          'coverage %s%% against %s%%',
                          coalesce(v_classified_bps::text, 'null'), c_classified_bps,
                          coalesce(v_demog_pct::text, 'null'), c_demog_pct)),
      'impact', jsonb_build_object(
        'cents', null,
        'reason', 'a coverage defect has no revenue figure of its own; what it does is put an '
                  'error bar on every figure above it'),
      'action', jsonb_build_object(
        'who', 'the owner, once, then front desk on an ongoing basis',
        'what', 'Map every service and product to a category in Settings, and capture date of '
                'birth and gender at the point a customer is created rather than retrospectively. '
                'Do this BEFORE acting on any category or cohort finding in this list.',
        'when', 'before the next review',
        'channel', 'settings_and_checkout'),
      'evidence', jsonb_build_object(
        'source_rpc', 'public.get_ci_category_mix_v1 + public.get_ci_demographics_v1',
        'refs', jsonb_build_object(
          'category_coverage', v_catmix->'coverage',
          'demographic_coverage', v_demog->'coverage'->'demographics',
          'unclassified_customers', v_demog->'unclassified',
          'classified_bar_bps', c_classified_bps,
          'demographic_bar_pct', c_demog_pct)),
      'evidence_class', 'DIRECT_FACT',
      'confidence', v_conf,
      'limitation',
        'Coverage is not accuracy: fully classified revenue can still be classified wrongly, and '
        'this says nothing about whether the mapped categories are the right ones.',
      'rank_class', 'foundation'));
  end if;

  -- =============================================================================================
  -- THE FLOOR SWEEP · a tripwire, not a crutch.
  -- =============================================================================================
  v_abst := v_abst || coalesce((
    select jsonb_agg(jsonb_build_object(
             'generator', c->>'id', 'reason', 'below_evidence_floor'))
      from jsonb_array_elements(v_cands) c
     where c->'confidence'->>'status' is distinct from 'ok'), '[]'::jsonb);

  select coalesce(jsonb_agg(x.c || jsonb_build_object('rank', x.rn) order by x.rn), '[]'::jsonb)
    into v_ranked
    from (
      select c,
             row_number() over (
               order by case c->>'rank_class'
                          when 'foundation' then 0
                          when 'quantified' then 1
                          else 2 end,
                        coalesce((c->'impact'->>'cents')::bigint, 0) desc,
                        c->>'domain', c->>'id') as rn
        from jsonb_array_elements(v_cands) c
       where c->'confidence'->>'status' = 'ok'
    ) x;

  v_promoted := coalesce(jsonb_array_length(v_ranked), 0);

  -- =============================================================================================
  -- THE DO-NOTHING OUTCOME · a ranked result in its own right (check 72)
  -- =============================================================================================
  if v_promoted = 0 then
    v_ranked := jsonb_build_array(jsonb_build_object(
      'id', 'do_nothing',
      'domain', 'none',
      'pattern', 'No opportunity clears the evidence bar',
      'comparison', jsonb_build_object(
        'kind', 'threshold',
        'detail', format('all %s candidate evaluation(s) were made and every one abstained; the '
                          'reasons are listed under "abstentions"', v_examined)),
      'impact', jsonb_build_object(
        'cents', null,
        'reason', 'nothing is being recommended, so there is nothing to value'),
      'action', jsonb_build_object(
        'who', 'the consultant',
        'what', 'Take no action from this analysis. If a recommendation is wanted, the constraint '
                'is evidence, not effort: read the abstention reasons and fix whichever one is '
                'cheapest to clear (usually volume, coverage, or consent capture).',
        'when', 'revisit at the next review',
        'channel', 'none'),
      'evidence', jsonb_build_object(
        'source_rpc', 'public.get_ci_funnel_conversion_v1, public.get_ci_daypart_v1, '
                      'public.get_ci_category_mix_v1, public.get_ci_service_intelligence_v1, '
                      'public.get_ci_package_intelligence_v1, public.get_ci_contactability_v1, '
                      'public.get_ci_demographics_v1, app.customer_cadence_v1',
        'refs', jsonb_build_object(
          'candidates_examined', v_examined,
          'candidates_promoted', 0,
          'abstentions', v_abst)),
      'evidence_class', 'DIRECT_FACT',
      'confidence', app.subgroup_evidence_v1(0),
      'limitation',
        '"No opportunity" is a statement about what this period''s data can support, not a finding '
        'that the business has none — a thin window and a healthy business look identical here.',
      'rank_class', 'do_nothing',
      'rank', 1));
  end if;

  -- =============================================================================================
  -- FRESHNESS (check 97) — observed_since_min across the six re-emitted sub-readers this engine
  -- consumes and that carry the field, and a stale-evidence refusal that overrides ranking.
  -- =============================================================================================
  select min(x) into v_obs_min
    from (values
      ((v_funnel->>'observed_since')::timestamptz),
      ((v_daypart->>'observed_since')::timestamptz),
      ((v_svc->>'observed_since')::timestamptz),
      ((v_pkg->>'observed_since')::timestamptz),
      ((v_catmix->>'observed_since')::timestamptz),
      ((v_demog->>'observed_since')::timestamptz)
    ) as t(x)
   where x is not null;

  v_period_far := p_to < (p_as_of at time zone 'Asia/Singapore')::date - c_stale_period_days;
  v_stale := v_obs_min is not null and p_as_of - v_obs_min > make_interval(days => c_stale_days);

  if v_stale then
    v_refusal := 'stale_evidence';
    v_ranked := jsonb_build_array(jsonb_build_object(
      'id', 'do_nothing',
      'domain', 'none',
      'pattern', 'No opportunity is ranked: the evidence behind this analysis is stale.',
      'comparison', jsonb_build_object(
        'kind', 'threshold',
        'detail', format(
          'observed_since_min=%s, as_of=%s — stale when as_of is more than %s days past '
          'observed_since_min (period_far_from_as_of=%s is disclosed but does not itself refuse)',
          v_obs_min, p_as_of, c_stale_days, v_period_far)),
      'impact', jsonb_build_object(
        'cents', null,
        'reason', 'ranking is refused on stale evidence, so there is nothing to value'),
      'action', jsonb_build_object(
        'who', 'the consultant',
        'what', 'Refresh the underlying data (or request a more recent period) before ranking — '
                'acting on this analysis without doing so risks acting on facts that are no '
                'longer true.',
        'when', 'before the next review',
        'channel', 'none'),
      'evidence', jsonb_build_object(
        'source_rpc', 'public.get_ci_opportunities_v1',
        'refs', jsonb_build_object(
          'observed_since_min', v_obs_min, 'as_of', p_as_of, 'period_to', p_to,
          'period_far_from_as_of', v_period_far, 'stale_days_bar', c_stale_days)),
      'evidence_class', 'DIRECT_FACT',
      'confidence', app.subgroup_evidence_v1(0),
      'limitation',
        'Staleness is a statement about data freshness, not about whether opportunities exist.',
      'rank_class', 'do_nothing',
      'rank', 1));
    v_promoted := 0;
  else
    v_refusal := null;
  end if;

  -- =============================================================================================
  -- THE BASE (v680-identical) RESULT. Non-extended callers stop here.
  -- =============================================================================================
  v_result := jsonb_build_object(
    'contract', 'ci_opportunities_v1',
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                 'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'ranked', v_ranked,
    'abstentions', v_abst,
    'comparisons', app.comparisons_note_v1(v_examined, v_promoted),
    'freshness', jsonb_build_object(
      'observed_since_min', v_obs_min,
      'generated_at', clock_timestamp(),
      'stale', v_stale,
      'period_far_from_as_of', v_period_far),
    'refusal_reason', v_refusal,
    'observed_since', app.metric_observed_since_v1('ci_opportunities', p_business));

  if not p_extended or v_stale then
    -- a stale-evidence refusal is a full-stop in both modes: nothing more to enrich.
    if p_extended then
      v_result := v_result || jsonb_build_object(
        'report_sections', jsonb_build_object(
          'strengths', '[]'::jsonb, 'failures', '[]'::jsonb, 'leakage', '[]'::jsonb,
          'margin', jsonb_build_object('status', 'unavailable',
            'reason', 'no COGS/cost-of-goods field on services or sales in this schema'),
          'unnoticed_behaviour', '[]'::jsonb, 'segments', '[]'::jsonb, 'change', '[]'::jsonb),
        'top_actions', (select coalesce(jsonb_agg(e), '[]'::jsonb)
                          from jsonb_array_elements(v_ranked) e limit 5));
    end if;
    return app.ci_envelope_v680('ci_opportunities_v1', p_business, p_branch, p_from, p_to,
      p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
  end if;

  -- =============================================================================================
  -- EXTENDED MODE STARTS HERE. Nothing above this point behaves differently because of it.
  -- =============================================================================================
  v_has_v683 := to_regprocedure('public.get_ci_discount_dependency_v1(uuid,date,date,uuid)') is not null
            and to_regprocedure('public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid)') is not null
            and to_regprocedure('public.get_ci_staff_performance_v1(uuid,date,date,uuid)') is not null;

  select coalesce(sum(s.amount_cents), 0) into v_period_revenue
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
   where s.business_id = p_business
     and (p_branch is null or s.branch_id = p_branch)
     and sc.include_revenue
     and not sc.is_synthetic_client
     and s.created_at <= p_as_of
     and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to;
  v_ev_bar := round(v_period_revenue * c_ev_materiality_pct / 100.0);

  -- ---------------------------------------------------------------------------------------
  -- EV for lapsed_regulars (check 73): re-derive the overdue+ticket population (same query as
  -- generator B — p_branch is already known null here, since generator B itself only ever runs
  -- firm-wide) and score each with app.return_probability_v681.
  -- ---------------------------------------------------------------------------------------
  v_ev_lapsed_cents := 0;
  v_ev_lapsed_abst := 0;
  if p_branch is null then
    for v_dsc in
      with overdue as materialized (
        select b.client_id
          from app.customer_cadence_batch_v1(
                 p_business,
                 ((p_as_of at time zone 'Asia/Singapore')::date + 1),
                 ((p_as_of at time zone 'Asia/Singapore')::date + 1),
                 p_as_of, null, true) b
          cross join lateral (select app.customer_cadence_v1(p_business, b.client_id) as cad) c
         where c.cad->>'deviation_state' = 'overdue'
           and c.cad->>'evidence_source' = 'customer_median_interval'
      ),
      tickets as (
        select o.client_id,
               round(sum(s.amount_cents)::numeric / count(*)) as avg_ticket
          from overdue o
          join public.sales s
            on s.business_id = p_business
           and app.v111_effective_client_id(s.business_id, s.client_id) = o.client_id
          cross join lateral app.analytics_sale_class_v1(s) sc
         where sc.include_revenue and not sc.is_synthetic_client and s.created_at <= p_as_of
         group by o.client_id
      )
      select o.client_id, coalesce(t.avg_ticket, 0) as avg_ticket
        from overdue o left join tickets t on t.client_id = o.client_id
    loop
      v_ev := app.return_probability_v681(p_business, v_dsc.client_id, p_as_of);
      if v_ev->>'status' = 'ready' then
        v_ev_lapsed_cents := v_ev_lapsed_cents
          + round((v_ev->>'probability')::numeric * v_dsc.avg_ticket)::bigint;
      else
        v_ev_lapsed_abst := v_ev_lapsed_abst + 1;
      end if;
    end loop;
  end if;

  -- ---------------------------------------------------------------------------------------
  -- Build the extended candidate set: enrich the ORIGINAL (base-pass) candidates, then append
  -- the new generator classes, THEN apply the materiality gate, THEN re-rank.
  -- ---------------------------------------------------------------------------------------
  for v_c in select c from jsonb_array_elements(v_cands) c loop
    v_id := v_c->>'id';
    v_domain := v_c->>'domain';

    -- incentive + why_now + reversal_condition + alternatives, per domain
    if v_domain = 'retention_funnel' then
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format(
        'The %s-day maturity window for this cohort has already fully elapsed as of %s; every '
        'day the %s step goes unaddressed carries the same gap into the next cohort.',
        c_funnel_window, p_to, replace(v_f_stage, '_', '-'));
      v_reversal := format(
        'Reconsider this call if the stage gap narrows to under %s points over one more full '
        '%s-day cycle.', c_gap_pp, c_funnel_window);
    elsif v_domain = 'cadence' then
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format(
        '%s customers are already overdue against their OWN rhythm as of %s; the longer the gap '
        'runs past their personal median interval, the more likely they re-anchor elsewhere.',
        v_lapsed_n, p_as_of::date);
      v_reversal := format(
        'Reconsider this call if fewer than half of these %s overdue customers return within 60 '
        'days of being contacted.', v_lapsed_n);
    elsif v_domain = 'daypart' then
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format(
        '%s is already %sx more valuable per visit than %s as of %s; every rota cycle left '
        'unchanged trades a %s-value slot for a %s-value one.',
        v_valuable->>'label',
        round((v_hi->>'revenue_per_visit_cents')::numeric
              / nullif((v_lo->>'revenue_per_visit_cents')::numeric, 0), 1),
        v_busiest->>'label', p_to, v_valuable->>'label', v_busiest->>'label');
      v_reversal := format(
        'Reconsider this call if the ratio between the two weekdays falls under %sx.',
        c_daypart_ratio);
    elsif v_domain = 'category_mix' then
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format(
        'The top category already holds %s bps of classified revenue as of %s; a single '
        'disruption there removes %s cents from the period in one stroke.',
        v_share_bps, p_to, v_top->>'revenue_cents');
      v_reversal := format(
        'Reconsider this call if the top category''s share falls under %s bps of classified '
        'revenue.', c_conc_bps);
    elsif v_domain = 'packages' then
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format(
        '%s cents of prepaid sessions on "%s" are already unused as of %s; every day past the '
        'holder''s own usage rhythm shortens the runway before expiry forfeits them.',
        (v_c->'impact'->>'cents'), v_c->'evidence'->'refs'->>'plan_name', p_to);
      v_reversal := format(
        'Reconsider this call if utilisation rises to %s%% or above.', c_util_pct);
    elsif v_domain = 'service_intelligence' then
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format(
        '%s%% of this service''s buyers already fail to return, %s points behind the firm''s '
        '%s%% baseline as of %s.', v_c->'evidence'->'refs'->'repeat_rate'->>'pct',
        round(v_f_p1 - (v_c->'evidence'->'refs'->'repeat_rate'->>'pct')::numeric, 1),
        v_f_p1, p_to);
      v_reversal := format(
        'Reconsider this call if the repeat rate closes to within %s points of the firm''s %s%%.',
        c_gap_pp, v_f_p1);
    elsif v_domain = 'contactability' then
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format(
        'Only %s%% of customers are lawfully reachable as of %s; every new customer added '
        'without capturing consent widens this gap.',
        round(100.0 * coalesce(v_best, 0) / nullif(v_customers, 0), 1), p_to);
      v_reversal := format(
        'Reconsider this call once the best-channel reachable share reaches %s%%.', c_reach_pct);
    elsif v_domain = 'data_quality' then
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format(
        '%s bps of revenue remain unclassified as of %s; every day of new sales without mapping '
        'compounds the blind spot beneath every other finding here.',
        10000 - coalesce(v_classified_bps, 0), p_to);
      v_reversal := format(
        'Reconsider this call once classified revenue reaches %s bps AND demographic coverage '
        'reaches %s%%.', c_classified_bps, c_demog_pct);
    else
      v_incentive := jsonb_build_object('kind', 'none', 'declared', true);
      v_why_now := format('As of %s, this pattern still holds in the current period.', p_to);
      v_reversal := 'Reconsider this call once the underlying numbers change materially.';
    end if;

    v_cost_basis := case when v_incentive->>'kind' = 'none'
      then jsonb_build_object('status', 'declared', 'cents', 0,
             'note', 'a reminder/operational action carries no incentive spend')
      else c_incentive_unavailable end;

    v_alternatives := case when v_domain = 'service_intelligence' then
        jsonb_build_array(
          jsonb_build_object('kind', 'reminder_only', 'primary', true,
            'what', 'Contact without any discount or credit.',
            'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
          jsonb_build_object('kind', 'service_recovery', 'primary', false,
            'what', 'Re-run the first-visit experience for a sample of recent buyers at no charge '
                    'to find what is actually going wrong before spending on acquisition.',
            'cost_basis', c_incentive_unavailable),
          jsonb_build_object('kind', 'incentive', 'primary', false,
            'what', 'Offer a discount or loyalty credit to prompt a second visit.',
            'cost_basis', c_incentive_unavailable))
      else
        jsonb_build_array(
          jsonb_build_object('kind', 'reminder_only', 'primary', true,
            'what', 'Contact without any discount or credit.',
            'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
          jsonb_build_object('kind', 'incentive', 'primary', false,
            'what', 'Offer a discount or loyalty credit to prompt action.',
            'cost_basis', c_incentive_unavailable))
      end;

    -- expected value: only lapsed_regulars and package_leakage:* carry a behavioural model
    if v_id = 'lapsed_regulars' then
      v_ev := jsonb_build_object(
        'cents', v_ev_lapsed_cents,
        'method', 'sum over overdue regulars of app.return_probability_v681(business, client, '
                  'as_of).probability * that customer''s own average ticket; a customer on which '
                  'the model itself abstains contributes 0 and is counted in inputs.abstained',
        'inputs', jsonb_build_object('scored', v_lapsed_n - v_ev_lapsed_abst,
                                      'abstained', v_ev_lapsed_abst));
    elsif v_domain = 'packages' then
      select coalesce(sum(
               cp.remaining
               * (v_c->'evidence'->'refs'->>'per_session_cents')::bigint
               * coalesce((app.return_probability_v681(p_business, cp.client_id, p_as_of)
                            ->>'probability')::numeric, 0)), 0)::bigint,
             count(*) filter (where (app.return_probability_v681(p_business, cp.client_id, p_as_of)
                                       ->>'status') <> 'ready')
        into v_ev_pkg_cents, v_ev_pkg_abst
        from public.client_packages cp
        join public.clients c2 on c2.id = cp.client_id
       where cp.plan_id = (v_c->'evidence'->'refs'->>'plan_id')::uuid
         and cp.business_id = p_business
         and not coalesce(c2.is_synthetic, false)
         and cp.remaining > 0
         and (cp.purchased_at at time zone 'Asia/Singapore')::date between p_from and p_to;
      v_ev := jsonb_build_object(
        'cents', round(v_ev_pkg_cents),
        'method', 'sum over the plan''s in-window holders with sessions remaining of '
                  'remaining_sessions * per_session_cents * app.return_probability_v681(business, '
                  'holder, as_of).probability; a holder on which the model abstains contributes 0 '
                  'and is counted in inputs.abstained',
        'inputs', jsonb_build_object('abstained', v_ev_pkg_abst));
    else
      v_ev := jsonb_build_object('status', 'unavailable',
        'reason', 'no behavioural model backs this candidate''s pattern');
    end if;

    v_impact := (v_c->'impact') || jsonb_build_object(
      'scenario_cents', v_c->'impact'->'cents', 'expected_value', v_ev);

    v_cands_ext := v_cands_ext || jsonb_build_array(
      v_c || jsonb_build_object(
        'impact', v_impact, 'incentive', v_incentive, 'why_now', v_why_now,
        'reversal_condition', v_reversal, 'alternatives', v_alternatives,
        'cost_basis', v_cost_basis));
  end loop;
  v_examined_ext := v_examined;

  -- ---------------------------------------------------------------------------------------
  -- NEW GENERATOR · discovery (check 22/79): one candidate per REPLICATED discovery
  -- ---------------------------------------------------------------------------------------
  -- get_ci_discovery_v1 needs a period wide enough to split into two non-empty halves (it raises
  -- 22023 otherwise, by its own design). A caller asking a single-day/short-window question of
  -- this engine (a real, legitimate call shape) gets an honest abstention here instead of an
  -- unhandled exception surfacing from a sub-reader it never asked for by name.
  v_examined_ext := v_examined_ext + 1;
  if (p_to - p_from) < 2 then
    v_discovery := null;
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'discovery',
      'reason', 'the requested period is too short to split into a train and a holdout half'));
  else
    v_discovery := public.get_ci_discovery_v1(p_business, p_from, p_to, p_branch);
  end if;
  for v_dsc in select e.value as d from jsonb_array_elements(coalesce(v_discovery->'discoveries','[]'::jsonb)) e loop
    v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
      'id', 'discovery:' || (v_dsc.d->>'dimension') || ':' || (v_dsc.d->>'group'),
      'domain', 'discovery',
      'pattern', format('The "%s" segment in dimension "%s" differs from the rest by %s points '
                         '(train %s%%, n=%s), and the direction replicated on unseen holdout data.',
                         v_dsc.d->>'group', v_dsc.d->>'dimension', v_dsc.d->>'diff_pp',
                         v_dsc.d->'train'->>'rate', v_dsc.d->'train'->>'n'),
      'comparison', jsonb_build_object('kind', 'cross_segment',
        'detail', format('train vs rest diff %s pp; holdout n=%s, rate %s%%',
                          v_dsc.d->>'diff_pp', v_dsc.d->'holdout'->>'n', v_dsc.d->'holdout'->>'rate')),
      'impact', jsonb_build_object('cents', null, 'reason',
        'an association, not an incremental model: no assumed uplift is smuggled in',
        'scenario_cents', null,
        'expected_value', jsonb_build_object('status', 'unavailable',
          'reason', 'no behavioural model backs a discovered association')),
      'action', jsonb_build_object('who', 'the owner', 'what',
        format('Look at "%s" (%s) specifically: something about this group already behaves '
               'differently and it held up on later data.', v_dsc.d->>'group', v_dsc.d->>'dimension'),
        'when', 'this review cycle', 'channel', 'analysis'),
      'incentive', jsonb_build_object('kind', 'none', 'declared', true),
      'why_now', format('The pattern already replicated on holdout data as of %s; the longer it '
                         'goes unexamined the more the underlying cause compounds.', p_to),
      'reversal_condition', format('Reconsider this call if the difference falls back under %s '
                                    'points on the next holdout split.', v_dsc.d->>'diff_pp'),
      'alternatives', jsonb_build_array(jsonb_build_object('kind', 'reminder_only', 'primary', true,
        'what', 'Note it and monitor, no spend.',
        'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend'))),
      'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'observation only'),
      'evidence', jsonb_build_object('source_rpc', 'public.get_ci_discovery_v1', 'refs', v_dsc.d),
      'evidence_class', 'ASSOCIATION',
      'confidence', app.subgroup_evidence_v1((v_dsc.d->'train'->>'n')::int),
      'limitation', 'A discovered association is not a cause; predefined dimensions were scanned '
                    'and this one survived false-discovery control and holdout replication.',
      'rank_class', 'unquantified'));
  end loop;

  -- ---------------------------------------------------------------------------------------
  -- NEW GENERATOR · change (check 22/79): one candidate per deteriorating cell
  -- ---------------------------------------------------------------------------------------
  v_examined_ext := v_examined_ext + 1;
  for v_dsc in select e.value as d from jsonb_array_elements(coalesce(v_discovery->'deteriorating','[]'::jsonb)) e loop
    v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
      'id', 'change:' || (v_dsc.d->>'dimension') || ':' || (v_dsc.d->>'group'),
      'domain', 'change',
      'pattern', format('"%s" (%s) fell from %s%% in the first half of the period to %s%% in the '
                         'second, a drop of %s points.', v_dsc.d->>'group', v_dsc.d->>'dimension',
                         v_dsc.d->'train'->>'rate', v_dsc.d->'holdout'->>'rate', v_dsc.d->>'diff_pp'),
      'comparison', jsonb_build_object('kind', 'baseline',
        'detail', format('this group''s own train rate (n=%s) against its own holdout rate (n=%s)',
                          v_dsc.d->'train'->>'n', v_dsc.d->'holdout'->>'n')),
      'impact', jsonb_build_object('cents', null, 'reason',
        'no incremental model: a rate decline is not a cash figure without an assumed baseline',
        'scenario_cents', null,
        'expected_value', jsonb_build_object('status', 'unavailable',
          'reason', 'no behavioural model backs a deteriorating cell')),
      'action', jsonb_build_object('who', 'the owner', 'what',
        format('Find out what changed for "%s" between the two halves of the period before it '
               'compounds further.', v_dsc.d->>'group'),
        'when', 'this review cycle', 'channel', 'analysis'),
      'incentive', jsonb_build_object('kind', 'none', 'declared', true),
      'why_now', format('This segment''s own rate has already fallen %s points as of %s.',
                         v_dsc.d->>'diff_pp', p_to),
      'reversal_condition', format('Reconsider this call if the holdout-half rate recovers to '
                                    'within %s points of the train-half rate.', v_dsc.d->>'diff_pp'),
      'alternatives', jsonb_build_array(jsonb_build_object('kind', 'reminder_only', 'primary', true,
        'what', 'Note it and monitor, no spend.',
        'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend'))),
      'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'observation only'),
      'evidence', jsonb_build_object('source_rpc', 'public.get_ci_discovery_v1', 'refs', v_dsc.d),
      'evidence_class', 'ASSOCIATION',
      'confidence', app.subgroup_evidence_v1(least((v_dsc.d->'train'->>'n')::int,
                                                    (v_dsc.d->'holdout'->>'n')::int)),
      'limitation', 'Deterioration is measured on the same self-selected group across halves of '
                    'one period; it is not validated against an independent cause.',
      'rank_class', 'unquantified'));
  end loop;

  -- ---------------------------------------------------------------------------------------
  -- NEW GENERATOR · strength (check 22/79): top evidence-ok weekday / category / service,
  -- ranked strictly after every opportunity (rank_class 'strength').
  -- ---------------------------------------------------------------------------------------
  v_examined_ext := v_examined_ext + 3;
  v_top_weekday := v_hi;
  select c into v_top_category
    from jsonb_array_elements(coalesce(v_catmix->'categories', '[]'::jsonb)) c
   order by (c->>'revenue_cents')::bigint desc, c->>'node_key' limit 1;
  select s into v_top_service
    from jsonb_array_elements(coalesce(v_svc->'services', '[]'::jsonb)) s
   where s->'evidence'->>'status' = 'ok'
   order by (s->>'revenue_cents')::bigint desc, s->>'service_id' limit 1;

  if v_top_weekday is not null then
    v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
      'id', 'strength:weekday:' || (v_top_weekday->>'dow'),
      'domain', 'strength',
      'pattern', format('%s already returns %s cents per visit, the strongest weekday measured.',
                         v_top_weekday->>'label', v_top_weekday->>'revenue_per_visit_cents'),
      'comparison', jsonb_build_object('kind', 'threshold',
        'detail', 'evidence-ok weekday with the highest revenue per visit in the window'),
      'impact', jsonb_build_object('cents', null, 'reason', 'a strength is not a gap to close',
        'scenario_cents', null,
        'expected_value', jsonb_build_object('status', 'unavailable',
          'reason', 'strengths are descriptive, not a prediction')),
      'action', jsonb_build_object('who', 'the owner', 'what',
        format('Protect %s: staff it reliably and do not let it silently drift.', v_top_weekday->>'label'),
        'when', 'ongoing', 'channel', 'rota'),
      'incentive', jsonb_build_object('kind', 'none', 'declared', true),
      'why_now', format('As of %s this remains the strongest weekday measured.', p_to),
      'reversal_condition', format('Reconsider this call if revenue per visit on %s falls under '
        '%s cents.', v_top_weekday->>'label', v_top_weekday->>'revenue_per_visit_cents'),
      'alternatives', jsonb_build_array(jsonb_build_object('kind', 'reminder_only', 'primary', true,
        'what', 'No action needed beyond monitoring.',
        'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend'))),
      'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'observation only'),
      'evidence', jsonb_build_object('source_rpc', 'public.get_ci_daypart_v1', 'refs', v_top_weekday),
      'evidence_class', 'DIRECT_FACT',
      'confidence', app.subgroup_evidence_v1((v_top_weekday->>'visits')::int),
      'limitation', 'A strength today is not a guarantee it persists.',
      'rank_class', 'strength'));
  end if;

  if v_top_category is not null then
    v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
      'id', 'strength:category:' || (v_top_category->>'node_key'),
      'domain', 'strength',
      'pattern', format('%s already leads all classified categories at %s cents of revenue.',
        coalesce(v_top_category->>'label', v_top_category->>'node_key'), v_top_category->>'revenue_cents'),
      'comparison', jsonb_build_object('kind', 'threshold', 'detail', 'top classified category by revenue'),
      'impact', jsonb_build_object('cents', null, 'reason', 'a strength is not a gap to close',
        'scenario_cents', null,
        'expected_value', jsonb_build_object('status', 'unavailable',
          'reason', 'strengths are descriptive, not a prediction')),
      'action', jsonb_build_object('who', 'the owner', 'what',
        format('Keep %s well stocked and staffed; it already carries the mix.',
               coalesce(v_top_category->>'label', v_top_category->>'node_key')),
        'when', 'ongoing', 'channel', 'planning'),
      'incentive', jsonb_build_object('kind', 'none', 'declared', true),
      'why_now', format('As of %s this remains the top classified category.', p_to),
      'reversal_condition', format('Reconsider this call if its revenue falls under %s cents.',
        v_top_category->>'revenue_cents'),
      'alternatives', jsonb_build_array(jsonb_build_object('kind', 'reminder_only', 'primary', true,
        'what', 'No action needed beyond monitoring.',
        'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend'))),
      'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'observation only'),
      'evidence', jsonb_build_object('source_rpc', 'public.get_ci_category_mix_v1', 'refs', v_top_category),
      'evidence_class', 'DIRECT_FACT',
      'confidence', app.subgroup_evidence_v1((v_top_category->>'customer_count')::int),
      'limitation', 'A strength today is not a guarantee it persists.',
      'rank_class', 'strength'));
  end if;

  if v_top_service is not null then
    v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
      'id', 'strength:service:' || (v_top_service->>'service_id'),
      'domain', 'strength',
      'pattern', format('"%s" already leads all services at %s cents of revenue.',
        v_top_service->>'service_name', v_top_service->>'revenue_cents'),
      'comparison', jsonb_build_object('kind', 'threshold', 'detail', 'top evidence-ok service by revenue'),
      'impact', jsonb_build_object('cents', null, 'reason', 'a strength is not a gap to close',
        'scenario_cents', null,
        'expected_value', jsonb_build_object('status', 'unavailable',
          'reason', 'strengths are descriptive, not a prediction')),
      'action', jsonb_build_object('who', 'the owner', 'what',
        format('Protect "%s": keep it staffed and do not let quality drift.', v_top_service->>'service_name'),
        'when', 'ongoing', 'channel', 'planning'),
      'incentive', jsonb_build_object('kind', 'none', 'declared', true),
      'why_now', format('As of %s this remains the top-performing service.', p_to),
      'reversal_condition', format('Reconsider this call if its revenue falls under %s cents.',
        v_top_service->>'revenue_cents'),
      'alternatives', jsonb_build_array(jsonb_build_object('kind', 'reminder_only', 'primary', true,
        'what', 'No action needed beyond monitoring.',
        'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend'))),
      'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'observation only'),
      'evidence', jsonb_build_object('source_rpc', 'public.get_ci_service_intelligence_v1', 'refs', v_top_service),
      'evidence_class', 'DIRECT_FACT',
      'confidence', app.subgroup_evidence_v1((v_top_service->>'buyers')::int),
      'limitation', 'A strength today is not a guarantee it persists.',
      'rank_class', 'strength'));
  end if;

  -- ---------------------------------------------------------------------------------------
  -- v683-GATED GENERATORS (present in this tree — checked, not assumed)
  -- ---------------------------------------------------------------------------------------
  if v_has_v683 and p_branch is null then
    v_examined_ext := v_examined_ext + 1;
    v_discount_dep := public.get_ci_discount_dependency_v1(p_business, p_from, p_to, null);
    v_reminder_n := coalesce(jsonb_array_length(v_discount_dep->'reminder_only_candidates'->'candidates'), 0);
    if v_discount_dep->'reminder_only_candidates'->'suppressed' is not null then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'no_discount_reminder',
        'reason', 'below_evidence_floor: ' ||
          coalesce(v_discount_dep->'reminder_only_candidates'->'suppressed'->>'reason', '')));
    elsif v_reminder_n = 0 then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'no_discount_reminder',
        'reason', 'no organic returner is currently overdue'));
    else
      v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
        'id', 'no_discount_reminder',
        'domain', 'discount_dependency',
        'pattern', format('%s organic returners (never discount-dependent) are overdue right now; '
                           'they do not need an incentive to come back, only a reminder.', v_reminder_n),
        'comparison', jsonb_build_object('kind', 'threshold',
          'detail', format('%s organic-class customers overdue against their own cadence', v_reminder_n)),
        'impact', jsonb_build_object('cents', null,
          'reason', 'no incremental model for a reminder-only contact',
          'scenario_cents', null,
          'expected_value', jsonb_build_object('status', 'unavailable',
            'reason', 'no behavioural model backs this cohort figure')),
        'action', jsonb_build_object('who', 'front desk', 'what',
          'Send a reminder, no incentive: these customers already return without one.',
          'when', 'this week', 'channel', 'whatsapp_or_call_where_consent_exists'),
        'incentive', jsonb_build_object('kind', 'none', 'declared', true),
        'why_now', format('%s customers are already overdue as of %s.', v_reminder_n, p_to),
        'reversal_condition', format('Reconsider this call if fewer than %s of these customers '
          'return within 30 days of the reminder.', ceil(v_reminder_n / 2.0)),
        'alternatives', jsonb_build_array(jsonb_build_object('kind', 'reminder_only', 'primary', true,
          'what', 'Contact without any discount or credit.',
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
          jsonb_build_object('kind', 'incentive', 'primary', false,
            'what', 'Offer a discount anyway.', 'cost_basis', c_incentive_unavailable)),
        'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'reminder only, no incentive'),
        'evidence', jsonb_build_object('source_rpc', 'public.get_ci_discount_dependency_v1',
          'refs', jsonb_build_object('reminder_only_candidates_n', v_reminder_n)),
        'evidence_class', 'ASSOCIATION',
        'confidence', app.subgroup_evidence_v1(v_reminder_n),
        'limitation', 'Organic-vs-dependent classification is itself a proxy on discount history, '
                      'not a controlled experiment.',
        'rank_class', 'unquantified'));
    end if;

    v_examined_ext := v_examined_ext + 1;
    v_loyalty := public.get_ci_loyalty_programmes_v1(p_business, p_from, p_to, null);
    v_best_programme := null; v_best_cannibal := null;
    for v_dsc in
      select key as k, value as v from jsonb_each(coalesce(v_loyalty->'programmes', '{}'::jsonb))
    loop
      if v_dsc.v->>'status' = 'ready'
         and (v_dsc.v->'cannibalisation_proxy'->'within_cycle'->>'pct') is not null
         and (v_dsc.v->'cannibalisation_proxy'->'within_cycle'->>'pct')::numeric >= c_cannibal_pct
         and (v_best_cannibal is null
              or (v_dsc.v->'cannibalisation_proxy'->'within_cycle'->>'pct')::numeric > v_best_cannibal)
      then
        v_best_cannibal := (v_dsc.v->'cannibalisation_proxy'->'within_cycle'->>'pct')::numeric;
        v_best_programme := v_dsc.k;
      end if;
    end loop;
    if v_best_programme is null then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'loyalty_cannibalisation_gap',
        'reason', format('no active loyalty programme has a within-cycle cannibalisation share '
                          'at or above the %s%% bar', c_cannibal_pct)));
    else
      v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
        'id', 'loyalty_cannibalisation_gap',
        'domain', 'loyalty',
        'pattern', format('%s%% of "%s" redemptions coincide with visits the customer''s own '
                           'rhythm already predicted — the programme is largely buying visits '
                           'that were coming anyway.', v_best_cannibal, v_best_programme),
        'comparison', jsonb_build_object('kind', 'threshold',
          'detail', format('within-cycle share %s%% against the %s%% cannibalisation bar',
                            v_best_cannibal, c_cannibal_pct)),
        'impact', jsonb_build_object('cents', null,
          'reason', 'no incremental model: this is a proxy, not a measured incremental effect',
          'scenario_cents', null,
          'expected_value', jsonb_build_object('status', 'unavailable',
            'reason', 'no behavioural model backs a cannibalisation proxy')),
        'action', jsonb_build_object('who', 'the owner', 'what',
          format('Review "%s"''s reward design: redemptions that were coming anyway are pure '
                 'margin loss, not incremental visits.', v_best_programme),
          'when', 'next programme review', 'channel', 'planning'),
        'incentive', jsonb_build_object('kind', 'credit', 'declared', true),
        'why_now', format('%s%% within-cycle as of %s; every redemption cycle at this level is '
                           'spend without incremental return.', v_best_cannibal, p_to),
        'reversal_condition', format('Reconsider this call if the within-cycle share falls under '
                                      '%s%%.', c_cannibal_pct),
        'alternatives', jsonb_build_array(
          jsonb_build_object('kind', 'reminder_only', 'primary', true,
            'what', 'Review the programme design at no cost before changing the reward itself.',
            'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend')),
          jsonb_build_object('kind', 'incentive', 'primary', false,
            'what', 'Redesign the reward (raise the bar or lower the value).',
            'cost_basis', c_incentive_unavailable)),
        'cost_basis', c_incentive_unavailable,
        'evidence', jsonb_build_object('source_rpc', 'public.get_ci_loyalty_programmes_v1',
          'refs', jsonb_build_object('programme', v_best_programme, 'within_cycle_pct', v_best_cannibal)),
        'evidence_class', 'ASSOCIATION',
        'confidence', app.subgroup_evidence_v1(5),
        'limitation', 'within_cycle is a proxy on the customer''s own rhythm, not a measured '
                      'incremental effect (see app.ci_loyalty_outcomes_v683).',
        'rank_class', 'unquantified'));
    end if;

    v_examined_ext := v_examined_ext + 1;
    v_staff_perf := public.get_ci_staff_performance_v1(p_business, p_from, p_to, null);
    select s into v_worst_staff
      from jsonb_array_elements(coalesce(v_staff_perf->'staff', '[]'::jsonb)) s
     where s->'evidence'->>'status' = 'ok'
       and (s->'adjusted'->>'index') is not null
       and (s->'adjusted'->>'index')::numeric < c_staff_index_bar
     order by (s->'adjusted'->>'index')::numeric asc, s->>'staff_id' limit 1;
    if v_worst_staff is null then
      v_abst := v_abst || jsonb_build_array(jsonb_build_object(
        'generator', 'staff_mix_underperformance',
        'reason', format('no staff member''s mix-adjusted index is below the %s bar',
                          c_staff_index_bar)));
    else
      v_new_cands := v_new_cands || jsonb_build_array(jsonb_build_object(
        'id', 'staff_mix_underperformance:' || (v_worst_staff->>'staff_id'),
        'domain', 'staff_performance',
        'pattern', format('%s''s mix-adjusted index is %s — below what the same service mix '
                           'earns at the firm average.',
                           coalesce(v_worst_staff->>'full_name', v_worst_staff->>'staff_id'),
                           v_worst_staff->'adjusted'->>'index'),
        'comparison', jsonb_build_object('kind', 'baseline',
          'detail', format('actual revenue / expected revenue at the firm''s own per-service '
                            'average ticket, index %s against the %s bar',
                            v_worst_staff->'adjusted'->>'index', c_staff_index_bar)),
        'impact', jsonb_build_object('cents', null,
          'reason', 'no incremental model: a mix-adjusted index gap is not itself a cash figure',
          'scenario_cents', null,
          'expected_value', jsonb_build_object('status', 'unavailable',
            'reason', 'no behavioural model backs a staff performance index')),
        'action', jsonb_build_object('who', 'the owner, with this staff member', 'what',
          format('Coach %s on upselling/service delivery for their own mix — the gap is against '
                 'the FIRM''S OWN average for the services they already perform, not a made-up '
                 'target.', coalesce(v_worst_staff->>'full_name', v_worst_staff->>'staff_id')),
          'when', 'next 1:1', 'channel', 'in_person_coaching'),
        'incentive', jsonb_build_object('kind', 'none', 'declared', true),
        'why_now', format('Index is already %s as of %s; every day at this level under-earns '
                           'against the firm''s own price list for the same services.',
                           v_worst_staff->'adjusted'->>'index', p_to),
        'reversal_condition', format('Reconsider this call once the index rises to %s or above.',
                                      c_staff_index_bar),
        'alternatives', jsonb_build_array(jsonb_build_object('kind', 'reminder_only', 'primary', true,
          'what', 'Coach, no compensation change.',
          'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'no spend'))),
        'cost_basis', jsonb_build_object('status', 'declared', 'cents', 0, 'note', 'coaching only'),
        'evidence', jsonb_build_object('source_rpc', 'public.get_ci_staff_performance_v1',
          'refs', v_worst_staff),
        'evidence_class', 'ASSOCIATION',
        'confidence', v_worst_staff->'evidence',
        'limitation', 'A mix-adjusted index is observational: it does not control for tenure, '
                      'shift allocation, or customer selection.',
        'rank_class', 'unquantified'));
    end if;
  end if;

  -- ---------------------------------------------------------------------------------------
  -- MATERIALITY GATE (check 65), the EV half: any candidate with a computed expected_value
  -- below 1% of the period's own known revenue abstains, even with evidence ok.
  -- ---------------------------------------------------------------------------------------
  v_c := v_cands_ext || v_new_cands;   -- v_c reused as the full pre-materiality candidate array

  select coalesce(jsonb_agg(jsonb_build_object(
           'generator', e->>'id',
           'reason', format('below_materiality: expected value %s cents is below 1%% of period '
                             'revenue (%s cents)', e->'impact'->'expected_value'->>'cents', v_ev_bar)))
         , '[]'::jsonb)
    into v_abst_ext
    from jsonb_array_elements(v_c) e
   where (e->'impact'->'expected_value'->>'cents') is not null
     and (e->'impact'->'expected_value'->>'cents')::numeric < v_ev_bar;
  v_abst_ext := v_abst || v_abst_ext;

  select coalesce(jsonb_agg(e), '[]'::jsonb) into v_cands_ext
    from jsonb_array_elements(v_c) e
   where (e->'impact'->'expected_value'->>'cents') is null
      or (e->'impact'->'expected_value'->>'cents')::numeric >= v_ev_bar;

  -- ---------------------------------------------------------------------------------------
  -- RE-RANK: foundation < quantified (by EV desc, else scenario_cents desc) < unquantified <
  -- strength; ties broken by domain, id.
  -- ---------------------------------------------------------------------------------------
  select coalesce(jsonb_agg(x.c || jsonb_build_object('rank', x.rn) order by x.rn), '[]'::jsonb)
    into v_ranked_ext
    from (
      select c,
             row_number() over (
               order by case c->>'rank_class'
                          when 'foundation' then 0
                          when 'quantified' then 1
                          when 'unquantified' then 2
                          else 3 end,
                        coalesce((c->'impact'->'expected_value'->>'cents')::bigint,
                                 (c->'impact'->>'scenario_cents')::bigint, 0) desc,
                        c->>'domain', c->>'id') as rn
        from jsonb_array_elements(v_cands_ext) c
       where c->'confidence'->>'status' = 'ok'
    ) x;

  v_promoted_ext := coalesce(jsonb_array_length(v_ranked_ext), 0);

  if v_promoted_ext = 0 then
    v_ranked_ext := v_ranked;  -- reuse the base pass's do_nothing/stale-evidence entry
  end if;

  -- ---------------------------------------------------------------------------------------
  -- report_sections + top_actions (checks 22/79)
  -- ---------------------------------------------------------------------------------------
  select jsonb_build_object(
    'strengths', coalesce((select jsonb_agg(c->>'id') from jsonb_array_elements(v_ranked_ext) c
                            where c->>'rank_class' = 'strength'), '[]'::jsonb),
    'change', coalesce((select jsonb_agg(c->>'id') from jsonb_array_elements(v_ranked_ext) c
                         where c->>'domain' = 'change'), '[]'::jsonb),
    'unnoticed_behaviour', coalesce((select jsonb_agg(c->>'id') from jsonb_array_elements(v_ranked_ext) c
                                      where c->>'domain' = 'discovery'), '[]'::jsonb),
    'leakage', coalesce((select jsonb_agg(c->>'id') from jsonb_array_elements(v_ranked_ext) c
                          where c->>'domain' in ('packages','discount_dependency','loyalty')), '[]'::jsonb),
    'margin', jsonb_build_object('status', 'unavailable',
      'reason', 'no COGS/cost-of-goods field on services or sales in this schema'),
    'segments', coalesce((select jsonb_agg(c->>'id') from jsonb_array_elements(v_ranked_ext) c
                           where c->>'domain' in ('discovery','change')
                             and c->'evidence'->'refs'->>'dimension' in ('age_gender','category_node')),
                          '[]'::jsonb),
    'failures', coalesce((select jsonb_agg(c->>'id') from jsonb_array_elements(v_ranked_ext) c
                           where c->>'rank_class' not in ('foundation','strength','do_nothing')
                             and c->>'domain' not in ('discovery','change','packages',
                                                       'discount_dependency','loyalty')), '[]'::jsonb)
  ) into v_report_sections;

  select coalesce(jsonb_agg(e), '[]'::jsonb) into v_top_actions
    from (select e from jsonb_array_elements(v_ranked_ext) e limit 5) t;

  v_result := v_result || jsonb_build_object(
    'ranked', v_ranked_ext,
    'abstentions', v_abst_ext,
    'comparisons', app.comparisons_note_v1(v_examined_ext, v_promoted_ext),
    'report_sections', v_report_sections,
    'top_actions', v_top_actions);

  return app.ci_envelope_v680('ci_opportunities_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$function$;

revoke all on function public.get_ci_opportunities_v1(uuid,date,date,uuid,timestamptz,boolean) from public, anon;
grant execute on function public.get_ci_opportunities_v1(uuid,date,date,uuid,timestamptz,boolean)
  to authenticated, service_role;

commit;
