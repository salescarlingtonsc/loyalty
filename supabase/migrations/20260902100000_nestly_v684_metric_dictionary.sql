-- NESTLY v684 — one versioned metric dictionary, and the five contradictory concepts
-- (loyal / frequent / retained / high-LTV / at-risk) defined DISJOINTLY and testably.
--
-- Closes acceptance checks 11 and 29 (docs/qa/CI-ACCEPTANCE-VERDICT-2026-09-02.md). This
-- migration does not invent new semantics for revenue, visits, lifecycle, cadence, retention,
-- ATV or lifetime value — it MAPS the definitions already frozen in production readers:
--
--   revenue / transaction  public.get_revenue_truth_v106            (v106)
--   new / existing_returning / repeat / reactivated
--                           public.get_customer_lifecycle_v107       (v107)
--   cadence_median / lapsed app.customer_cadence_v1 / _batch_v1     (v651, extracted from v107)
--   retained                public.get_ci_retention_windows_v1       (v673)
--   atv                     public.get_ci_demographics_v1            (v674)
--   ltv                     public.staff_list_customers_v155         (v629 lifetime_spend_cents)
--   at_risk                 public.get_report_insight_evidence_v179 (AI-report policy)
--                           AND app.customer_cadence_v1 deviation_state='overdue' (CI policy)
--
-- ---------------------------------------------------------------------------------------------
-- WHY AT_RISK NEEDS TWO ENTRIES, NOT ONE
-- ---------------------------------------------------------------------------------------------
-- v179 (AI firm report, 2026-08-06) and v651 (canonical cadence, 2026-08-31) each answer
-- "is this customer at risk" and they do not agree:
--
--   v179: a "regular" (2+ lifetime counts_as_visit visits, no reversal) whose last visit is a
--         FIXED 45-180 days before the report's p_to. A single-visit customer is NEVER at risk
--         under this policy, no matter how long ago that one visit was.
--   v651: deviation_state='overdue' — days since last visit exceeds the customer's OWN rhythm
--         (median interval x reactivation_multiplier) once they clear a minimum-observations
--         gate, else the business's fallback_lapse_days (90 by migration default). There is no
--         fixed day window and no minimum-visit-count gate: a single very old purchase is judged
--         against the 90-day fallback exactly like anyone else with insufficient own-rhythm
--         evidence.
--
-- Both are real, both are live, and this dictionary discloses the tension rather than picking a
-- winner or silently reconciling them (docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md's own
-- house style). app.ci_customer_classes_v1 below implements the CI (v651) policy only, because
-- it is the one the frozen statistical-authority contract already builds on (lapsed, cadence).
--
-- ---------------------------------------------------------------------------------------------
-- WHY THE FIVE CLASSES ARE DISJOINT "BY CONSTRUCTION", NOT BY COINCIDENCE
-- ---------------------------------------------------------------------------------------------
-- app.ci_customer_classes_v1 computes `loyal` as
--     (qualifying visits in the last 180 days >= 6) AND NOT at_risk
-- using the SAME `at_risk` boolean the function returns, not a second, independently-derived
-- "not overdue" check. Algebraically, at_risk = true implies NOT at_risk = false implies
-- loyal = false, for EVERY input — the mutual exclusion holds even before any fixture data is
-- seeded. The corpus fixture (db/tests/executed/v684_corpus_dictionary.sql) still asserts it
-- across four real customers, and mutation-checks one of them, because "true by construction"
-- is a claim worth proving against the compiled function, not just reading in the source.
--
-- `frequent` (median inter-visit interval <= 14 days, >= 3 observations) is deliberately NOT
-- part of the `loyal` computation: a frequent customer who has since gone overdue is frequent
-- but not loyal (fixture customer G). Frequency describes a customer's past RHYTHM; loyalty
-- additionally requires that rhythm still be current.
--
-- `retained` answers a different question in time than the other four: it is a ONE-TIME
-- historical fact (did this customer return within 90 days of their very FIRST visit, ever),
-- computed from app.ci_customer_classes_v1's `retained` field via the same population rule as
-- v673's cohort reader (0/60-day window fixed at 90 days here — a single-customer instance of
-- v673's horizon set). It does not update once earned and is independent of a customer's
-- CURRENT standing — a customer can be retained=true and at_risk=true at the same time (they
-- came back once, long ago, and have since gone quiet again). It is not claimed disjoint from
-- anything.
--
-- `high_ltv` (lifetime spend >= the business's own 80th percentile of identified-customer
-- lifetime spend, reusing v629's lifetime_spend_cents definition verbatim: every sale kind,
-- no branch/date scope, reversals cancelled on both sides) is likewise independent of the other
-- four — a single huge purchase can make a customer high_ltv while leaving them frequent=false,
-- loyal=false and retained=false (fixture customer H).
--
-- Proof: db/tests/executed/v684_corpus_dictionary.sql. No `> 0` assertions; every boolean and
-- the 80th-percentile threshold itself are asserted to an exact predetermined value.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. app.ci_metric_dictionary_v1() — the canonical, versioned, machine-readable definitions.
-- ---------------------------------------------------------------------------------------------
create or replace function app.ci_metric_dictionary_v1()
returns jsonb
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select jsonb_build_object(
    'version', 'ci_dictionary_v684_1',
    'metrics', jsonb_build_object(

      'revenue', jsonb_build_object(
        'definition', 'Recorded revenue: the net minor-currency amount of original sales with '
          || 'counts_as_revenue=true, after native full-sale reversals and reconciled external '
          || 'refund allocations, bucketed to a period by the sale''s effective outlet timezone.',
        'unit', 'currency minor units (cents), business currency',
        'numerator', 'sum(v106 net_minor) over eligible original sales in the period',
        'denominator', null,
        'source_function', 'public.get_revenue_truth_v106',
        'since_version', 'v106',
        'notes', 'formula_metadata.version=revenue_truth_v106_1. Invariant: known_revenue = '
          || 'identified_revenue + anonymous_revenue. counts_as_revenue is a per-business, '
          || 'per-sale-kind POLICY (app.sale_policy_set, v10), not a fixed list of sale kinds.'
      ),

      'visit', jsonb_build_object(
        'definition', 'A qualifying visit: an original sale with counts_as_visit=true, not '
          || 'itself a reversal (reversal_of is null) and not itself later reversed. v673''s '
          || 'funnel/retention readers additionally bucket the visit to one Singapore-time '
          || 'calendar date (visit_date), so more than one qualifying sale on the same SGT day '
          || 'is a single visit for sequencing purposes.',
        'unit', 'count (sale-level unless noted as day-deduped)',
        'numerator', null,
        'denominator', null,
        'source_function', jsonb_build_array(
          'app.customer_cadence_batch_v1',
          'public.get_ci_funnel_conversion_v1',
          'public.get_ci_retention_windows_v1'
        ),
        'since_version', 'v107 (sale-level count); v673 (day-deduped visit_date)',
        'notes', 'DISCLOSED DIVERGENCE, not reconciled here: v107/v651 (paid_visits) and v179 '
          || '(lifetime_visits) count one visit per qualifying SALE row; v673 dedupes '
          || 'same-SGT-day sales into a single visit_date for first/second/third-visit '
          || 'sequencing. Both are "as implemented" in live production readers.'
      ),

      'transaction', jsonb_build_object(
        'definition', 'A completed transaction: an original sale (reversal_of is null) whose '
          || 'v106 residual (net) amount, after native reversals and reconciled external '
          || 'refund allocations, is greater than zero as of the report''s as_of instant.',
        'unit', 'count',
        'numerator', 'count(*) filter (where net_minor > 0)',
        'denominator', null,
        'source_function', 'public.get_revenue_truth_v106',
        'since_version', 'v106',
        'notes', 'A sale can be revenue-qualifying (counts_as_revenue) without being '
          || 'visit-qualifying (counts_as_visit), or the reverse; "transaction" here is '
          || 'specifically the revenue reader''s completed_transactions figure.'
      ),

      'new', jsonb_build_object(
        'definition', 'new_customer: the client''s first-ever eligible purchase '
          || '(counts_as_visit=true, v106 residual > 0) has a local business date in '
          || '[p_from, p_to).',
        'unit', 'count of transacting identified customers',
        'numerator', 'count(*) filter (where first_ever_business_date in [p_from,p_to))',
        'denominator', 'transacting_identified_customers (for a rate; the raw count is not '
          || 'itself a rate)',
        'source_function', 'public.get_customer_lifecycle_v107',
        'since_version', 'v107',
        'notes', 'Business-wide identity for the "first-ever" test; period activity is scoped '
          || 'to the selected branch when p_branch is given (v107 header).'
      ),

      'existing_returning', jsonb_build_object(
        'definition', 'existing_returning_customer: at least one eligible purchase strictly '
          || 'before p_from AND at least one eligible purchase in [p_from,p_to).',
        'unit', 'count of transacting identified customers',
        'numerator', 'count(*) filter (where purchased_before_period)',
        'denominator', 'transacting_identified_customers',
        'source_function', 'public.get_customer_lifecycle_v107',
        'since_version', 'v107',
        'notes', 'Not the same population as `repeat` — a customer can be existing_returning '
          || 'with exactly one purchase in the current period.'
      ),

      'repeat', jsonb_build_object(
        'definition', 'repeat_purchaser_in_period: at least two eligible purchases in '
          || '[p_from,p_to), regardless of the customer''s age — deliberately NOT a synonym '
          || 'for existing_returning.',
        'unit', 'count of transacting identified customers',
        'numerator', 'count(*) filter (where period_purchases >= 2)',
        'denominator', 'transacting_identified_customers',
        'source_function', 'public.get_customer_lifecycle_v107',
        'since_version', 'v107',
        'notes', 'A brand-new customer who buys twice in their very first period is repeat=true '
          || 'and new=true simultaneously; the two are independent flags on the same reader.'
      ),

      'reactivated', jsonb_build_object(
        'definition', 'reactivated_customer: an existing_returning customer whose first '
          || 'in-period purchase follows a lapse (gap_days) strictly greater than the '
          || 'effective threshold — the customer''s own median interval multiplied by the '
          || 'business''s reactivation_multiplier when interval_observations clears '
          || 'customer_interval_min_observations, else the business fallback_lapse_days.',
        'unit', 'count of transacting identified customers',
        'numerator', 'count(*) filter (where purchased_before_period and gap_days > '
          || 'effective_lapse_days)',
        'denominator', 'transacting_identified_customers',
        'source_function', jsonb_build_array(
          'public.get_customer_lifecycle_v107', 'app.customer_cadence_batch_v1'
        ),
        'since_version', 'v107 (definition); v651 (canonical median/threshold computation, '
          || 're-pointing v107 at it byte-identically)',
        'notes', 'Migration-default policy: fallback_lapse_days=90, '
          || 'customer_interval_min_observations=3, reactivation_multiplier=2.0, effective '
          || 'from -infinity until an owner or super-admin publishes a business-specific one.'
      ),

      'retained', jsonb_build_object(
        'definition', 'Fixed-window retention: within a cohort of clients whose first visit '
          || 'falls in a period, the share with ANY qualifying visit strictly after their own '
          || 'first visit and within a fixed horizon of it. public.get_ci_retention_windows_v1 '
          || 'reports horizons {30,60,90,180,365} days at cohort level; '
          || 'app.ci_customer_classes_v1 below is a single-customer instance fixed at the '
          || '90-day horizon.',
        'unit', 'rate (customers returned / cohort size)',
        'numerator', 'customers with a qualifying visit in (first_visit_date, first_visit_date '
          || '+ horizon]',
        'denominator', 'cohort_n (the cohort''s full size, mature cells only)',
        'source_function', jsonb_build_array(
          'public.get_ci_retention_windows_v1', 'app.ci_customer_classes_v1'
        ),
        'since_version', 'v673',
        'notes', 'A (cohort, horizon) CELL — not any one customer''s own date — is reported '
          || 'only once fully matured (cohort_month_last_day + horizon <= today, SGT); an '
          || 'immature cell is named in immature_cells, never silently omitted. `retained` is '
          || 'a one-time historical fact about a customer''s FIRST visit, unlike `lapsed` / '
          || '`at_risk`, which describe current standing — a customer can be retained=true and '
          || 'at_risk=true simultaneously.'
      ),

      'lapsed', jsonb_build_object(
        'definition', 'deviation_state=''overdue'': as of p_as_of, the days since a client''s '
          || 'last qualifying visit exceed the effective lapse threshold (customer median '
          || 'interval x reactivation_multiplier when interval_observations clears '
          || 'customer_interval_min_observations, else fallback_lapse_days) — the identical '
          || 'threshold construction v107 uses for `reactivated`, now named once.',
        'unit', 'boolean, per customer',
        'numerator', null,
        'denominator', null,
        'source_function', 'app.customer_cadence_v1',
        'since_version', 'v651',
        'notes', 'Other deviation_state values from the same function: due, late, within_cycle. '
          || '`lapsed` here means specifically overdue — see `at_risk` for why this is one of '
          || 'two live at-risk policies, not the only one.'
      ),

      'at_risk', jsonb_build_object(
        'definition', 'TWO LIVE POLICIES answer "is this customer at risk", and they '
          || 'deliberately disagree — disclosed here, not reconciled. '
          || '(1) AI-REPORT POLICY (public.get_report_insight_evidence_v179): a "regular" '
          || '(2+ lifetime counts_as_visit visits) whose last visit is a FIXED 45-180 days '
          || 'before the report''s p_to; a single-visit customer is never at risk under this '
          || 'policy no matter how old that visit is. '
          || '(2) CI POLICY (app.customer_cadence_v1 / app.ci_customer_classes_v1): '
          || 'deviation_state=''overdue'' — an OWN-RHYTHM comparison against the customer''s '
          || 'median interval, or the business fallback_lapse_days (90 by default) when there '
          || 'is not enough interval evidence. There is no fixed day window and no '
          || 'minimum-visit-count gate under this policy.',
        'unit', 'boolean or count, per policy — see source_function',
        'numerator', 'their_lifetime_revenue_cents / recovery_value_one_visit_each_cents '
          || '(v179 policy only)',
        'denominator', null,
        'source_function', jsonb_build_array(
          'public.get_report_insight_evidence_v179', 'app.customer_cadence_v1'
        ),
        'since_version', 'v179 (AI-report policy); v651 (CI policy)',
        'notes', 'TENSION DISCLOSED: a customer with one huge purchase long ago clears the '
          || 'v179 "2+ lifetime visits" gate as false (v179 never flags them) while the CI '
          || 'policy''s 90-day fallback can independently call the same customer overdue. '
          || 'app.ci_customer_classes_v1.at_risk implements the CI policy ONLY; it is not a '
          || 'merge of the two.'
      ),

      'ltv', jsonb_build_object(
        'definition', 'Realised lifetime value, not projected: the sum of amount_cents across '
          || 'EVERY sale of every kind for the client, business-wide, with no branch scope and '
          || 'no date window, and with reversals excluded on BOTH sides (a reversal row and the '
          || 'original sale it reverses both drop out).',
        'unit', 'currency minor units (cents)',
        'numerator', 'sum(sales.amount_cents) where reversal_of is null and not later reversed',
        'denominator', null,
        'source_function', 'public.staff_list_customers_v155 (lifetime_spend_cents)',
        'since_version', 'v629',
        'notes', 'Deliberately counts package/membership/gift-card sale kinds too — owner '
          || 'ruling: "everything the customer paid" — unlike v106''s counts_as_revenue-gated '
          || 'revenue figure. A package SESSION is a $0 sale and adds nothing; the package was '
          || 'already counted at its full price when it was sold. This is a REALISED, '
          || 'backward-looking figure, labelled here explicitly as NOT a projected/forecast LTV.'
      ),

      'atv', jsonb_build_object(
        'definition', 'Average transaction value: revenue_cents divided by the count of '
          || 'REVENUE-qualifying sales (counts_as_revenue) in the cell — not counts_as_visit. '
          || 'A $0 or non-revenue visit moves footfall (the `visits` figure) but has no '
          || '"transaction value" and is excluded from the ATV denominator.',
        'unit', 'currency minor units (cents) per revenue-qualifying transaction',
        'numerator', 'revenue_cents (cell)',
        'denominator', 'count of counts_as_revenue sales in the cell',
        'source_function', 'public.get_ci_demographics_v1',
        'since_version', 'v674',
        'notes', 'Below the k=5 evidence floor (app.subgroup_evidence_v1) the cell keeps its '
          || 'real customers/revenue_cents/visits and atv_cents is nulled — never dropped, '
          || 'never a fabricated average from a handful of people.'
      ),

      'identified_coverage', jsonb_build_object(
        'definition', 'The share of a population (sales, transactions, or customers) carrying '
          || 'a linked, non-null client_id, always reported beside the eligible total via '
          || 'app.rate_block_v1 rather than as a bare percentage.',
        'unit', 'rate',
        'numerator', 'identified_revenue_minor / identified_transactions / '
          || 'identified_transaction_pct — per reader',
        'denominator', 'known_revenue_minor / eligible_transactions / '
          || 'transacting_identified_customers — per reader',
        'source_function', jsonb_build_array(
          'public.get_revenue_truth_v106', 'public.get_customer_lifecycle_v107',
          'public.get_ci_demographics_v1'
        ),
        'since_version', 'v106',
        'notes', 'One concept, several call sites; each reader states its own '
          || 'numerator/denominator pair rather than this dictionary inventing a single formula '
          || 'that would not match any one of them exactly.'
      ),

      'cadence_median', jsonb_build_object(
        'definition', 'median_interval_days: the median (percentile_cont 0.5) of a client''s '
          || 'paid-visit-to-paid-visit gaps in days, computed only over qualifying visits '
          || '(counts_as_visit, not reversed) before the computation''s cutoff date, via the '
          || 'canonical app.customer_cadence_batch_v1. Null when the client has fewer than 2 '
          || 'such visits (zero measured intervals).',
        'unit', 'days (median)',
        'numerator', null,
        'denominator', null,
        'source_function', 'app.customer_cadence_batch_v1',
        'since_version', 'v651 (extracted verbatim from v107''s original interval_evidence CTE; '
          || 'no behaviour change)',
        'notes', 'Whether the median is TRUSTED for a policy decision (vs falling back to '
          || 'fallback_lapse_days) depends on interval_observations >= '
          || 'customer_lifecycle_policies_v107.customer_interval_min_observations (default 3) '
          || '— the median can be non-null and still be policy-ignored below that floor.'
      ),

      'return_probability', jsonb_build_object(
        'definition', 'Referenced by name only, per this phase''s instruction (present in the '
          || 'schema at the time this dictionary was written): a memoryless-exponential hazard '
          || 'on the customer''s OWN rhythm, P(return within H days of p_as_of) = '
          || '1 - exp(-H / m), where m is the median inter-visit interval from the v651 '
          || 'canonical cadence authority (app.customer_cadence_batch_v1) and H defaults to 30 '
          || 'days. Distinct from `retained` (a one-time historical fact) and `lapsed`/`at_risk` '
          || '(a current rhythm-deviation fact): this is a forward-looking probability, not a '
          || 'backward-looking classification.',
        'unit', 'probability in [0,1], null when abstaining',
        'numerator', null,
        'denominator', null,
        'source_function', jsonb_build_array(
          'app.return_probability_v681', 'public.evaluate_return_probability_v681'
        ),
        'since_version', 'v681',
        'notes', 'ABSTAINS (status=''insufficient'', probability=null) when measured intervals '
          || 'k < 3 — a fixed floor independent of any business''s own cadence policy, stricter '
          || 'than app.customer_cadence_v1''s policy-configurable gate, because a probability '
          || 'claim is a stronger statement than a lapse classification. Deliberately does NOT '
          || 'use days-already-elapsed-since-last-visit as a covariate: the exponential is '
          || 'memoryless by construction, so folding that in would not change the number. '
          || 'public.evaluate_return_probability_v681 measures calibration/discrimination '
          || 'against a temporally-held-out real outcome rather than asserting the model works.'
      )
    )
  );
$$;
revoke all on function app.ci_metric_dictionary_v1() from public, anon, authenticated;
grant execute on function app.ci_metric_dictionary_v1() to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 2. public.get_ci_dictionary_v1() — the caller-facing wrapper. Gated only on auth.uid() not
--    null (docs/design/ci/CI-METRIC-DICTIONARY.md is a public-to-authenticated reference, not
--    tenant data): no business scope, no branch scope, nothing tenant-specific to leak.
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_dictionary_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  return app.ci_metric_dictionary_v1();
end;
$$;
revoke all on function public.get_ci_dictionary_v1() from public, anon;
grant execute on function public.get_ci_dictionary_v1() to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 3. app.ci_customer_classes_v1(p_business, p_client, p_as_of) — the disjoint-by-construction
--    classifier for the five concepts, each computed from the dictionary's own definitions.
-- ---------------------------------------------------------------------------------------------
create or replace function app.ci_customer_classes_v1(
  p_business uuid,
  p_client uuid,
  p_as_of timestamptz default clock_timestamp()
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_client_id uuid;
  v_cadence jsonb;
  v_status text;
  v_deviation text;
  v_interval_obs integer;
  v_median numeric;
  v_visits_180d integer;
  v_first_visit_at timestamptz;
  v_retained boolean;
  v_at_risk boolean;
  v_loyal boolean;
  v_frequent boolean;
  v_high_ltv boolean;
  v_client_ltv bigint;
  v_p80 numeric;
begin
  -- One authority for "may this caller read this business's intelligence?" — no branch
  -- dimension: this is a per-client, business-wide answer (v667 convention).
  perform app.ci_access_gate_v667(p_business, null);

  v_client_id := app.v111_effective_client_id(p_business, p_client);

  -- -------------------------------------------------------------------------------------------
  -- Qualifying-visit facts: same three-part filter as every v650/v667/v673 CI reader
  -- (counts_as_visit, reversal_of is null, not itself later reversed) plus synthetic exclusion.
  -- -------------------------------------------------------------------------------------------
  with elig as materialized (
    select s.occurred_at
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.client_id = v_client_id
       and coalesce(s.counts_as_visit, false)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and not coalesce(c.is_synthetic, false)
  )
  select
    count(*) filter (
      where occurred_at >= p_as_of - interval '180 days' and occurred_at <= p_as_of
    )::integer,
    min(occurred_at)
    into v_visits_180d, v_first_visit_at
    from elig;

  -- retained: v673's fixed-window semantics, single-customer instance at the 90-day horizon —
  -- ANY qualifying visit strictly after the client's own first visit and within 90 days of it.
  with elig as materialized (
    select s.occurred_at
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.client_id = v_client_id
       and coalesce(s.counts_as_visit, false)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and not coalesce(c.is_synthetic, false)
  )
  select exists (
    select 1 from elig e
     where v_first_visit_at is not null
       and e.occurred_at > v_first_visit_at
       and e.occurred_at <= v_first_visit_at + interval '90 days'
  ) into v_retained;

  -- lapsed / at_risk / frequent all derive from the SAME canonical per-customer cadence answer
  -- (app.customer_cadence_v1, v651) — the CI policy, not the v179 AI-report policy.
  v_cadence := app.customer_cadence_v1(p_business, p_client, p_as_of);
  v_status := v_cadence ->> 'status';
  v_deviation := v_cadence ->> 'deviation_state';
  v_interval_obs := coalesce((v_cadence ->> 'interval_observations')::integer, 0);
  v_median := nullif(v_cadence ->> 'median_interval_days', '')::numeric;

  -- at_risk: CI policy only (deviation_state='overdue'), computed only when the cadence
  -- function actually reached a ready answer (status='ready'); a client with zero paid visits
  -- ('insufficient') cannot be overdue against anything.
  v_at_risk := (v_status = 'ready') and (v_deviation = 'overdue');

  -- frequent: median inter-visit interval <= 14 days AND >= 3 measured observations. Uses the
  -- SAME median/observations app.customer_cadence_v1 reports (itself sourced from the v651
  -- canonical batch computation), not a re-derived value.
  v_frequent := (v_median is not null) and (v_median <= 14) and (v_interval_obs >= 3);

  -- loyal: >= 6 qualifying visits in the last 180 days AND NOT at_risk. Reuses the at_risk
  -- boolean directly — this is what makes at_risk/loyal mutually exclusive BY CONSTRUCTION,
  -- not by an independently-computed "not overdue" check that could drift out of sync.
  v_loyal := (v_visits_180d >= 6) and (not v_at_risk);

  -- high_ltv: lifetime spend (v629 definition, verbatim: every sale kind, no branch/date scope,
  -- reversals cancelled on both sides) >= the business's own 80th percentile of the same figure
  -- across its identified customer directory (non-synthetic clients; a client with zero sales
  -- contributes 0, exactly as v629's coalesce does).
  with population as materialized (
    select c.id as client_id,
           coalesce((
             select sum(s.amount_cents)
               from public.sales s
              where s.business_id = p_business
                and s.client_id = c.id
                and s.reversal_of is null
                and not exists (
                  select 1 from public.sales r where r.reversal_of = s.id
                )
           ), 0)::bigint as lifetime_spend_cents
      from public.clients c
     where c.business_id = p_business
       and not coalesce(c.is_synthetic, false)
  )
  select
    (select p.lifetime_spend_cents from population p where p.client_id = v_client_id),
    (select percentile_cont(0.8) within group (order by p.lifetime_spend_cents) from population p)
    into v_client_ltv, v_p80;

  v_high_ltv := (v_client_ltv is not null) and (v_p80 is not null) and (v_client_ltv >= v_p80);

  return jsonb_build_object(
    'contract_version', 'ci_customer_classes_v684_1',
    'as_of', p_as_of,
    'business_id', p_business,
    'client_id', v_client_id,
    'classes', jsonb_build_object(
      'frequent', v_frequent,
      'loyal', v_loyal,
      'retained', v_retained,
      'high_ltv', v_high_ltv,
      'at_risk', v_at_risk
    ),
    'inputs', jsonb_build_object(
      'visits_last_180d', v_visits_180d,
      'first_visit_at', v_first_visit_at,
      'cadence', v_cadence,
      'lifetime_spend_cents', coalesce(v_client_ltv, 0),
      'business_p80_lifetime_spend_cents', v_p80,
      'retained_horizon_days', 90,
      'frequent_median_threshold_days', 14,
      'frequent_min_observations', 3,
      'loyal_min_visits_180d', 6
    )
  );
end;
$$;
revoke all on function app.ci_customer_classes_v1(uuid, uuid, timestamptz)
  from public, anon, authenticated;
grant execute on function app.ci_customer_classes_v1(uuid, uuid, timestamptz)
  to authenticated, service_role;

commit;
