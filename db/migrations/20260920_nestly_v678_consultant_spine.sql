-- NESTLY v678 — the consultant spine: a typed, ranked, cross-domain opportunity engine.
--
-- Phase CI-C of the rescoped Customer Intelligence program
-- (docs/qa/CI-ACCEPTANCE-VERDICT-2026-09-02.md, phase CI-C row: "Typed insight contract
-- (pattern->comparison->impact->action->evidence->confidence->limitation), multi-class
-- opportunity generation, cross-domain ranking with 'do nothing' as a ranked outcome").
-- Closes checks 21-30 and 71-79. Proven by db/tests/executed/v678_corpus_consultant_spine.sql.
--
-- The CI-C verdict's own diagnosis of what was missing: "No discovery or diagnosis layer
-- (section C, 8/10 absent): nothing generates candidate issues across domains, ranks them...
-- The 'five most important things' question has no engine behind it." and "One opportunity
-- class (section H, 6/10 absent)... A consultant with one move is not a consultant."
--
-- ONE new RPC: public.get_ci_opportunities_v1(business, from, to, branch default null).
-- It writes nothing, computes no metric of its own, and owns no population rule. Every number
-- it reports is READ BACK from a committed CI reader and re-emitted verbatim under
-- `evidence.refs`. That is deliberate and is the single most important structural property of
-- this file: the founding defect of this surface was a renderer reading keys a superseded
-- definition emitted, so this engine is written against the keys the CURRENT migration sources
-- actually emit, and the corpus fixture asserts the emitted values rather than the shapes.
--
-- ---------------------------------------------------------------------------------------------
-- WHAT IT CONSUMES (and the exact keys it reads — checked against each migration's source)
-- ---------------------------------------------------------------------------------------------
--   v673 public.get_ci_funnel_conversion_v1(biz,from,to,window_days,branch)
--        -> stage_1_to_2 / stage_2_to_3 (rate_block: numerator/denominator/pct),
--           immature{first_stage,second_stage}, bottleneck, evidence, window_days, time_basis
--   v675 public.get_ci_daypart_v1(biz,from,to,branch)
--        -> weekdays[]{dow,label,visits,revenue_cents,revenue_per_visit_cents,
--           weekday_occurrences,visits_per_occurrence,evidence},
--           busiest_weekday{dow,label,visits}, most_valuable_weekday{dow,label,
--           revenue_per_visit_cents}
--   v675 public.get_ci_service_intelligence_v1(biz,from,to,branch)
--        -> services[]{service_id,service_name,buyers,orders,revenue_cents,repeat_buyers,
--           repeat_rate,gateway_count,median_days_to_next_purchase,evidence}, truncated
--   v675 public.get_ci_package_intelligence_v1(biz,from,to,branch)  [NO branch dimension]
--        -> plans[]{plan_id,plan_name,sold_count,sessions_included,sessions_used,utilisation,
--           median_days_between_sessions,expired_or_lapsed_with_unused,repurchase_count,
--           outside_spend_cents,evidence}
--   v667 public.get_ci_category_mix_v1(biz,from,to,branch)
--        -> categories[]{node_key,label,revenue_cents,line_count,customer_count,
--           projected_share_bps,children}, coverage{stampable_revenue_cents,classified_pct_bps,
--           projected_share_bps}, status
--   v667 public.get_ci_contactability_v1(biz,branch)   [NO branch dimension]
--        -> business_offers{category,customers,allowed_by_channel{whatsapp,sms,email,push,
--           in_app,call}}, rewards_and_points{...}, note
--   v674 public.get_ci_demographics_v1(biz,from,to,branch)
--        -> cells[], unclassified{}, coverage{demographics:rate_block, revenue:rate_block}
--   v651 app.customer_cadence_batch_v1(biz,before,residual_to,as_of,branch,business_wide)
--        -> (client_id, interval_observations, median_interval_days, last_visit_at, paid_visits)
--        and app.customer_cadence_v1(biz,client,as_of) -> deviation_state, evidence_source, ...
--   v672 app.subgroup_evidence_v1 / rate_block_v1 / comparisons_note_v1 (the frozen statistical
--        authority, docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md) — embedded, never reimplemented.
--
-- The readers are all SECURITY DEFINER and re-run app.ci_access_gate_v667 themselves against the
-- SESSION's jwt claims (auth.uid() reads a GUC, which a SECURITY DEFINER context does not change),
-- so calling them from here is defence in depth rather than a bypass: an unentitled caller is
-- refused twice, once by this function's own gate and again by each reader's.
--
-- ---------------------------------------------------------------------------------------------
-- THE TYPED INSIGHT CONTRACT (checks 71, 17-18)
-- ---------------------------------------------------------------------------------------------
-- Every entry in `ranked` — including the do-nothing outcome — carries EXACTLY these twelve keys
-- and no others. Ten are the contract the phase specifies; two (`rank_class`, `rank`) are added
-- by the ranker and are disclosed here rather than smuggled in:
--
--   id             stable within a payload. Per-entity generators suffix the entity's uuid, so
--                  two under-utilised plans are two distinct opportunities, not one repeated.
--   domain         which analytical domain produced it.
--   pattern        ONE sentence, carrying its own numbers. Never a number-free adjective.
--   comparison     {kind: 'baseline'|'threshold'|'cross_segment', detail}. A finding with no
--                  named comparison is an opinion; the kind says what it was measured against.
--   impact         {cents: bigint|null, method: text}  when quantified, or
--                  {cents: null, reason: text}         when it is honestly not quantifiable.
--                  A candidate NEVER invents a cents figure from an assumed uplift.
--   action         {who, what, when, channel} — a recommendation nobody can execute is not one.
--   evidence       {source_rpc, refs} — refs holds the ACTUAL numbers used, re-emitted exactly
--                  as the source reader produced them (rate blocks stay whole, per v672's rule
--                  that a rate always travels with its counts).
--   evidence_class 'DIRECT_FACT' | 'ASSOCIATION'. **'CAUSAL' IS NEVER EMITTED HERE.** Nothing in
--                  this engine is experimental: there is no holdout, no randomisation and no
--                  counterfactual. The bring-back engine (v108) remains the only path in this
--                  product with a causal claim, and it is out of scope for CI-C. The dividing
--                  line used below: DIRECT_FACT = every number in `pattern` and `impact` is a
--                  measured value or arithmetic on measured values; ASSOCIATION = the candidate
--                  links two measured facts, or projects a measured quantity onto an unobserved
--                  future, with no controlled comparison behind it.
--   confidence     app.subgroup_evidence_v1 of the SMALLEST population the claim rests on — not
--                  the largest, and not the one that flatters it. Where a claim compares two
--                  populations (funnel stages, a service against the firm funnel, two weekdays)
--                  the smaller denominator governs.
--   limitation     one honest sentence: the thing a skeptic would say first.
--   rank_class     'foundation' | 'quantified' | 'unquantified' | 'do_nothing'.
--   rank           1-based position in `ranked`.
--
-- THE FLOOR IS STRUCTURAL, NOT ADVISORY. No candidate may carry a rate whose denominator is
-- below the shared floor: each generator computes its confidence FIRST and abstains when the
-- status is not 'ok', and a final defensive sweep re-checks every accumulated candidate and
-- moves any that slipped through into `abstentions` with reason 'below_evidence_floor'. The
-- fixture asserts the sweep removes nothing, so the sweep is a tripwire rather than a crutch.
--
-- ---------------------------------------------------------------------------------------------
-- RANKING, AND WHY DATA QUALITY OUTRANKS BUSINESS ADVICE (checks 22-23, 72, 76)
-- ---------------------------------------------------------------------------------------------
-- Order: rank_class 'foundation' first, then 'quantified' by impact.cents descending, then
-- 'unquantified', with (domain, id) as the deterministic tie-break so two runs over the same
-- data produce the same list.
--
-- 'foundation' exists for exactly one candidate class — coverage defects (check 30). A severe
-- coverage problem outranks every recommendation built on top of it even though it carries no
-- dollar figure, because a recommendation derived from 60%-classified revenue is not a smaller
-- version of the right answer, it is an answer to a different question. Putting it below the
-- quantified items would invert the order a senior reviewer would read them in.
--
-- THE DO-NOTHING OUTCOME (check 72) is a first-class ranked result, not an empty array. When
-- every generator abstains, `ranked` contains exactly one entry, id 'do_nothing', carrying the
-- same twelve keys as any other candidate. An empty array reads as "the engine found nothing to
-- say", which is indistinguishable from "the engine broke"; a do-nothing entry states which bar
-- was not cleared and still discloses how many candidates were examined to reach it.
--
-- DISCLOSURE (check 69, and the reason `comparisons` is last): `comparisons` is
-- app.comparisons_note_v1(examined, promoted). `examined` counts EVERY candidate slot evaluated,
-- abstentions included — one for each single-shot generator whether or not it fires, and one for
-- each entity a per-entity generator inspected (each package plan, each service), floored at one
-- per generator so a generator that ran and found no entities still declares itself. Ten
-- findings out of fourteen evaluations is a different claim from ten out of two hundred, and the
-- reader is entitled to know which one they are holding.
--
-- ---------------------------------------------------------------------------------------------
-- JUDGEMENT CALLS, recorded rather than left silent
-- ---------------------------------------------------------------------------------------------
-- 1. BRANCH SCOPE. Three domains have no branch dimension by construction: package intelligence
--    (client_packages carries no branch column — v675's own finding), contactability (firm-level
--    consent), and lapsed regulars (app.customer_cadence_v1 resolves the v107 lifecycle policy
--    firm-wide and emits deviation_state only for a firm-wide computation). When p_branch is
--    given, those three generators ABSTAIN with a named reason and are still counted in
--    `examined`. They do NOT quietly return firm-wide numbers under a branch label — that is the
--    misleading-output failure mode v667 was written to close, and it would be worse here
--    because the output is a recommendation, not a metric.
--
-- 2. LAPSED-REGULARS IMPACT is the only place this engine multiplies anything by a behavioural
--    assumption, and it is confined to ONE visit at the customer's OWN historical average
--    ticket: sum over the qualifying customers of round(their lifetime revenue-qualifying sale
--    total / their count of such sales). No uplift, no retention multiplier, no discount rate.
--    The method string states this and the limitation says plainly that an overdue customer is
--    not a lost one. Deliberately NOT modelled: any assumed response rate — the moment a
--    response rate enters, the figure becomes a forecast wearing a measurement's clothes.
--
-- 3. PACKAGE LEAKAGE VALUES A SESSION at round(plan price / plan sessions), read from
--    public.package_plans because get_ci_package_intelligence_v1 does not emit price (checked
--    against v675's source, not assumed). The unused count comes from the payload
--    (sessions_included - sessions_used). The limitation records what this is and is not: the
--    revenue was already recognised at purchase (sales.kind='package' is counts_as_revenue,
--    counts_as_visit=false per v10), so the figure is prepaid service at risk of lapsing —
--    a liability and a goodwill exposure — not incremental revenue. It also records that a
--    holder who bought at a different snapshot price is valued here at today's list price.
--
-- 4. THE DAYPART RATIO IGNORES ZERO-REVENUE WEEKDAYS. The gold-vs-dead test is
--    max(revenue_per_visit) >= 2 x min(revenue_per_visit) over weekdays that are BOTH
--    evidence-ok AND strictly above zero revenue per visit. A weekday of purely zero-value
--    visits (redeemed entitlements, package sessions) would otherwise make the ratio fire
--    against literally any nonzero day: "twice zero" is not a comparison.
--
-- 5. CATEGORY CONCENTRATION IS MEASURED OVER CLASSIFIED REVENUE ONLY — the sum of the
--    `categories` array — never over stampable_revenue_cents. Dividing a classified numerator by
--    an unclassified-inclusive denominator would understate concentration by exactly the coverage
--    gap, which is the sibling defect this engine's own foundation candidate exists to surface.
--    Its confidence is sized by the TOP category's customer_count, so concentration is never
--    declared from a handful of customers.
--
-- 6. THE GATEWAY GENERATOR COMPARES A SERVICE'S BUYERS' REPEAT RATE AGAINST THE FIRM'S OWN
--    first-to-second funnel rate, which is a baseline comparison, not a controlled one: whoever
--    chooses that service is not a random draw from the firm's first-timers. That is why its
--    evidence_class is ASSOCIATION and its limitation says so. It needs the funnel rate to exist
--    and clear the floor, so it abstains wholesale when the funnel cannot support a baseline.
--
-- 7. NOTHING HERE WRITES. No audit row, no cache, no ledger. The engine is a read; a
--    recommendation only becomes an event when a human acts on it.

begin;

create or replace function public.get_ci_opportunities_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  -- Thresholds, named once. Every one of these is a policy choice, so it lives here where a
  -- reviewer can see all of them together rather than buried in a WHERE clause.
  c_funnel_window   constant integer := 60;    -- days, matches v673's own default
  c_gap_pp          constant numeric := 15.0;  -- points a stage/service must trail by
  c_util_pct        constant numeric := 50.0;  -- package utilisation below this leaks
  c_conc_bps        constant integer := 6000;  -- 60% of classified revenue in one category
  c_daypart_ratio   constant numeric := 2.0;   -- gold weekday vs dead weekday
  c_gateway_min     constant integer := 5;     -- minimum gateway buyers to judge a service
  c_reach_pct       constant numeric := 50.0;  -- contactable share below this is a gap
  c_classified_bps  constant integer := 9000;  -- classified revenue coverage below this is a
  c_demog_pct       constant numeric := 50.0;  -- foundation defect; same for demographics

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

  -- funnel scratch, shared with the gateway generator
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
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  -- =============================================================================================
  -- GENERATOR A · retention funnel — a named bottleneck with a material gap between the stages
  -- =============================================================================================
  v_examined := v_examined + 1;
  v_funnel := public.get_ci_funnel_conversion_v1(p_business, p_from, p_to, c_funnel_window, p_branch);
  v_f_d1 := (v_funnel->'stage_1_to_2'->>'denominator')::bigint;
  v_f_d2 := (v_funnel->'stage_2_to_3'->>'denominator')::bigint;
  v_f_p1 := (v_funnel->'stage_1_to_2'->>'pct')::numeric;
  v_f_p2 := (v_funnel->'stage_2_to_3'->>'pct')::numeric;
  v_f_stage := v_funnel->>'bottleneck';
  -- The claim rests on BOTH stage denominators; the smaller one governs (contract note above).
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
      'reason', format('the stages differ by %s points, below the %s-point materiality bar',
                        round(abs(v_f_p1 - v_f_p2), 1), c_gap_pp)));
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
    -- Two steps on purpose. The overdue set is resolved FIRST, so app.customer_cadence_v1 is
    -- asked exactly once per customer with a paid visit; folding it into the ticket join would
    -- let the planner re-evaluate a whole-business cadence computation per sale row.
    with overdue as materialized (
      select b.client_id
        from app.customer_cadence_batch_v1(
               p_business,
               ((now() at time zone 'Asia/Singapore')::date + 1),
               ((now() at time zone 'Asia/Singapore')::date + 1),
               now(), null, true) b
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
  v_daypart := public.get_ci_daypart_v1(p_business, p_from, p_to, p_branch);
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
  elsif v_hi is null or v_lo is null
        or (v_hi->>'dow')::int = (v_lo->>'dow')::int
        or (v_hi->>'revenue_per_visit_cents')::numeric
             < c_daypart_ratio * (v_lo->>'revenue_per_visit_cents')::numeric then
    v_abst := v_abst || jsonb_build_array(jsonb_build_object(
      'generator', 'daypart_shift',
      'reason', format('no pair of evidence-backed weekdays differs by %sx in revenue per visit',
                        c_daypart_ratio)));
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
  v_catmix := public.get_ci_category_mix_v1(p_business, p_from, p_to, p_branch);
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
    v_pkg := public.get_ci_package_intelligence_v1(p_business, p_from, p_to, null);
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
        -- price is NOT in the reader's payload (checked against v675's source), so the plan's own
        -- row supplies the per-session unit. Judgement call 3 in the header.
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
  v_svc := public.get_ci_service_intelligence_v1(p_business, p_from, p_to, p_branch);
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
  v_demog := public.get_ci_demographics_v1(p_business, p_from, p_to, p_branch);
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
  -- THE FLOOR SWEEP · a tripwire, not a crutch. Every generator already refuses to promote a
  -- candidate whose confidence is not 'ok'; this re-checks the accumulated set so a future
  -- generator that forgets cannot ship a rate below the floor. The corpus fixture asserts this
  -- removes nothing, which is what keeps it a tripwire.
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
      -- Honest, and deliberately not flattering: this outcome rests on no subgroup at all.
      'confidence', app.subgroup_evidence_v1(0),
      'limitation',
        '"No opportunity" is a statement about what this period''s data can support, not a finding '
        'that the business has none — a thin window and a healthy business look identical here.',
      'rank_class', 'do_nothing',
      'rank', 1));
  end if;

  return jsonb_build_object(
    'contract', 'ci_opportunities_v1',
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                 'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'ranked', v_ranked,
    'abstentions', v_abst,
    'comparisons', app.comparisons_note_v1(v_examined, v_promoted),
    'observed_since', app.metric_observed_since_v1('ci_opportunities', p_business));
end;
$function$;

revoke all on function public.get_ci_opportunities_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_opportunities_v1(uuid,date,date,uuid)
  to authenticated, service_role;

commit;
