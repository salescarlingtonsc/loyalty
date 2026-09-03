-- NESTLY v692 — record-level customer intelligence lineage (check 19), and a visit-day dedupe
-- fix in the v107 customer lifecycle contract (check 4).
--
-- Contract: docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md (v672, frozen). Fixture guide:
-- docs/qa/CI-CORPUS-FIXTURE-GUIDE.md. Proven by db/tests/executed/v692_corpus_lineage.sql.
--
-- ============================================================================================
-- PART 1 — public.get_ci_customer_records_v1 (check 19: insight -> cohort -> transactions)
-- ============================================================================================
-- Every aggregate Customer Intelligence reader (category mix, category customers, service
-- intelligence, ...) names a cohort or a customer inside it, but nothing lets an operator drill
-- from "customer X shows up in category A for $R across V visits" down to the actual rows that
-- produced R and V. This adds that one reader.
--
-- GATE: app.ci_access_gate_v667(p_business, p_branch) only — deliberately NOT wrapped in
-- app.subgroup_evidence_v1. That floor exists to stop a small COHORT from re-identifying its
-- members (nestly_v667's k=5 suppression on get_ci_category_customers_v1). This reader is the
-- opposite shape: it is handed one already-named client_id by a caller who reached it FROM an
-- aggregate that already cleared its own floor (or, for a super admin / assigned consultant,
-- already has firm-wide read access per app.ci_access_gate_v667 itself). There is no additional
-- disclosure to suppress — the identity was already on the screen that linked here.
--
-- POPULATION: the sales-level predicate is copied verbatim from
-- public.get_ci_category_customers_v1 (db/migrations/20260920_nestly_v680_ci_envelope.sql,
-- the live re-emit) MINUS that reader's own p_node_key restriction — this is the general
-- per-customer drill, not a category-filtered one. Every sale this reader returns for a client
-- is therefore exactly the population get_ci_category_customers_v1 would have summed for that
-- client at the same (business, branch, window, as_of); a caller who wants the category-A slice
-- filters the returned sale_items by node_key (via app.ci_effective_node_v650, the same
-- authority the aggregate calls) and gets, by construction, the identical revenue and visit
-- numbers the aggregate reported. That equality is what db/tests/executed/v692_corpus_lineage
-- .sql's lineage assertion proves, exactly, not approximately.
--
-- AS_OF: the same immutable-snapshot gate v680 put on every re-emitted reader (created_at <=
-- p_as_of on the sale and on any reversal, created_at <= p_as_of on the appointment) — a caller
-- pinning an old as_of must see the business exactly as it stood then, sale-for-sale.
--
-- PAYLOAD: 'scope' echo, 'sales' (id, occurred_at in SGT, kind, amount_cents,
-- counts_as_revenue/counts_as_visit, reversal_state, branch_id, sale_items with each item's
-- effective node via app.ci_effective_node_v650), 'appointments' (id, starts_at, status, staff
-- full name), 'totals' {sales, revenue_cents, visit_days} — visit_days is the v673 dedupe rule
-- (distinct Asia/Singapore calendar day, not a raw sale count) applied to THIS customer's own
-- qualifying sales, and 'observed_since'. Wrapped in the shared app.ci_envelope_v680 like every
-- other CI-A/B/C reader.
--
-- ============================================================================================
-- PART 2 — get_customer_lifecycle_v107: repeat_purchasers_in_period counts visit-days
-- ============================================================================================
-- db/migrations/20260729_nestly_v107_customer_lifecycle_contract.sql:322-323 counts a customer
-- as a "repeat purchaser in period" from `period_purchases >= 2`, and period_purchases is
-- `count(*) filter (where s.in_selected_period)` over public.sales rows — a RAW SALE COUNT. A
-- customer who buys three separate line items at the same till visit, or returns to the counter
-- twice in one afternoon for two separate tickets, reads as "two visits" by this measure even
-- though nestly_v673's funnel/retention readers (db/migrations/20260902_nestly_v673_retention_
-- funnels.sql) already settled that a "visit" is a distinct Asia/Singapore-local calendar day,
-- not a sale row — that is exactly why those readers bucket on
-- `(occurred_at at time zone <tz>)::date` and take the MIN per date rather than counting rows.
-- v107's own `sequenced` CTE already computes that per-outlet-effective-timezone business date
-- for every eligible sale (it is what `in_selected_period` is built from); this migration adds
-- one more aggregate over the SAME expression — count(distinct date) instead of count(*) — so
-- "repeat" means "came back on a different day", the same standard v673 already applies to
-- funnels and retention cohorts, applied here to lifecycle labels for the first time.
--
-- WHAT THIS DOES NOT CHANGE: new_customers, existing_returning_customers, reactivated_customers
-- and every policy/coverage/freshness key are untouched — none of them read period_purchases.
-- Only repeat_purchasers_in_period (and, downstream, repeat_in_period_rate_pct, which divides
-- it) moves. Every other lifecycle rule — first-ever purchase, the reactivation lapse threshold,
-- the business-wide-vs-branch identity/period-activity split — is exactly as v107 shipped it.
--
-- The diff is proven mechanically, the same way nestly_v668 proved its one-clause removal:
-- pg_get_functiondef captures the LIVE body before this migration runs, the new body is diffed
-- back against it with the intended substitutions applied via replace(), and any OTHER drift
-- raises and rolls the migration back rather than shipping silently. get_customer_lifecycle_v107
-- predates the v422 snapshot watermark (it is a BASELINE function, present in
-- tests/fixtures/db-schema-snapshot.sql), so its signature — CREATE OR REPLACE, not
-- drop-then-create — is unchanged; this migration only ever needed a p_branch-free precedent
-- (there is none: p_branch already exists on this function since v107 shipped) and adds no
-- parameter.
--
-- MUTATION-CHECKED (db/tests/executed/v692_corpus_lineage.sql): a customer with 3 same-day sales
-- and nothing else is asserted to NOT be a repeat purchaser under the new rule, and the fixture
-- separately reads the raw qualifying-sale count for that same customer directly against
-- public.sales (bypassing this function) to prove it is exactly 3 — i.e. that customer WOULD
-- have been misclassified a repeat purchaser under the old, un-deduped rule. A second customer
-- with 3 sales on one day plus 1 sale on a second day is asserted to BE a repeat purchaser
-- (2 distinct visit-days), and the lineage assertion above additionally cross-checks that same
-- customer's revenue/visit totals against get_ci_category_customers_v1 and an independent
-- hand-computed total, not merely against the function's own output re-read.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1 · get_ci_customer_records_v1
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_customer_records_v1(
  p_business uuid, p_client uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_result jsonb;
begin
  -- No app.subgroup_evidence_v1 floor here on purpose — see the migration header: this is a
  -- per-customer drill reached from an aggregate that already disclosed the identity (or from a
  -- caller with firm-wide read access), not a fresh cohort that could re-identify anyone.
  perform app.ci_access_gate_v667(p_business, p_branch);

  if p_client is null then
    raise exception 'p_client is required' using errcode = '22023';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;
  if not exists (select 1 from public.clients c
                  where c.id = p_client and c.business_id = p_business) then
    raise exception 'unknown client for this business' using errcode = '22023';
  end if;

  with qualifying_sales as (
    -- SAME population predicate as public.get_ci_category_customers_v1's sale-level filter
    -- (nestly_v680, live re-emit), minus that reader's own p_node_key restriction: this is the
    -- general per-customer drill, not a category-filtered slice, so the lineage assertion in
    -- db/tests/executed/v692_corpus_lineage.sql can filter the sale_items THIS reader returns by
    -- node_key itself and reconcile exactly against any category slice of that aggregate.
    select s.id, s.occurred_at, s.kind, s.amount_cents, s.counts_as_revenue, s.counts_as_visit,
           s.reversal_of, s.branch_id
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.client_id = p_client
       and (p_branch is null or s.branch_id = p_branch)
       and not coalesce(c.is_synthetic, false)
       and s.reversal_of is null
       and s.created_at <= p_as_of
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and coalesce(s.counts_as_visit, false)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  item_rows as (
    select si.sale_id, si.id, si.item_type, si.ref_id, si.qty, si.unit_cents, si.line_cents,
           en.node_key, en.classification
      from public.sale_items si
      cross join lateral app.ci_effective_node_v650(si) en
     where si.business_id = p_business
       and si.sale_id in (select qs.id from qualifying_sales qs)
  ),
  sales_json as (
    select qs.id,
           jsonb_build_object(
             'id', qs.id,
             'occurred_at', (qs.occurred_at at time zone 'Asia/Singapore'),
             'visit_date', (qs.occurred_at at time zone 'Asia/Singapore')::date,
             'kind', qs.kind,
             'amount_cents', qs.amount_cents,
             'counts_as_revenue', qs.counts_as_revenue,
             'counts_as_visit', qs.counts_as_visit,
             'branch_id', qs.branch_id,
             -- always reversal_of=null / reversed=false: qualifying_sales already excludes any
             -- sale that is itself a reversal, or that had been reversed as of p_as_of.
             'reversal_state', jsonb_build_object('reversal_of', qs.reversal_of, 'reversed', false),
             'sale_items', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'id', ir.id, 'item_type', ir.item_type, 'ref_id', ir.ref_id,
                        'qty', ir.qty, 'unit_cents', ir.unit_cents, 'line_cents', ir.line_cents,
                        'effective_node_key', ir.node_key,
                        'effective_node_classification', ir.classification)
                      order by ir.id)
                 from item_rows ir where ir.sale_id = qs.id), '[]'::jsonb)
           ) as rec
      from qualifying_sales qs
  ),
  appt_rows as (
    select a.id, a.starts_at, a.status, st.full_name as staff
      from public.appointments a
      left join public.staff st on st.id = a.staff_id
     where a.business_id = p_business
       and a.client_id = p_client
       and (p_branch is null or a.branch_id = p_branch)
       and a.created_at <= p_as_of
       and (a.starts_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  totals as (
    select count(distinct qs.id) as n_sales,
           coalesce(sum(ir.line_cents), 0)::bigint as revenue_cents,
           count(distinct (qs.occurred_at at time zone 'Asia/Singapore')::date) as visit_days
      from qualifying_sales qs
      left join item_rows ir on ir.sale_id = qs.id
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'client_id', p_client,
                                 'branch_id', p_branch, 'from', p_from, 'to', p_to),
    'sales', coalesce((select jsonb_agg(sj.rec order by sj.rec->>'occurred_at')
                         from sales_json sj), '[]'::jsonb),
    'appointments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', ar.id, 'starts_at', ar.starts_at, 'status', ar.status, 'staff', ar.staff)
             order by ar.starts_at)
        from appt_rows ar), '[]'::jsonb),
    'totals', jsonb_build_object('sales', t.n_sales, 'revenue_cents', t.revenue_cents,
                                  'visit_days', t.visit_days),
    'time_basis', 'sale_occurred_at',
    'observed_since', app.metric_observed_since_v1('category_snapshots', p_business))
    into v_result
    from totals t;

  return app.ci_envelope_v680('ci_customer_records_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_customer_records_v1(uuid,uuid,date,date,uuid,timestamptz)
  from public, anon;
grant execute on function public.get_ci_customer_records_v1(uuid,uuid,date,date,uuid,timestamptz)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 2 · get_customer_lifecycle_v107 — visit-day dedupe, proven by replace-equality
-- ---------------------------------------------------------------------------------------------
create temp table _v692_before(def text) on commit drop;

do $pre$
declare v_n integer;
begin
  insert into _v692_before(def)
  select pg_get_functiondef(p.oid)
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = 'get_customer_lifecycle_v107';

  select count(*) into v_n from _v692_before;
  if v_n <> 1 then
    raise exception 'v692: expected exactly one public.get_customer_lifecycle_v107, found %', v_n;
  end if;

  if position('period_purchases >= 2' in (select def from _v692_before)) = 0 then
    raise exception
      'v692: the raw-count repeat_purchasers_in_period clause is already absent — stop and re-read before shipping';
  end if;
end
$pre$;

create or replace function public.get_customer_lifecycle_v107(
  p_business uuid,
  p_from date,
  p_to date,
  p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp()
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_policy public.customer_lifecycle_policies_v107%rowtype;
  v_timezone text;
  v_currency text;
  v_business_wide_identity boolean;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_to <= p_from then
    raise exception 'p_to must be after p_from' using errcode = '22023';
  end if;
  if not (app.is_super_admin() or app.has_perm(p_business, 'view_finance')) then
    raise exception 'finance permission required' using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'branch is outside actor scope' using errcode = '42501';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches b
     where b.id = p_branch and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to business' using errcode = '23503';
  end if;
  v_business_wide_identity := app.can_see_branch(p_business, null);
  select * into strict v_policy
    from public.customer_lifecycle_policies_v107 p
   where p.business_id = p_business and p.effective_from <= p_as_of
   order by p.effective_from desc, p.version_no desc limit 1;
  select upper(currency) into strict v_currency
    from public.businesses where id = p_business;
  if p_branch is null then
    v_timezone := 'per_outlet';
  else
    select timezone into strict v_timezone
      from public.branches where id = p_branch and business_id = p_business;
  end if;

  with eligible as materialized (
    select s.id,
           app.v111_effective_client_id(s.business_id, s.client_id) as client_id,
           s.branch_id, s.occurred_at, s.created_at,
           s.amount_cents, c.timezone,
           app.v106_sale_residual_minor(s.id, p_to, p_as_of)
             as residual_minor
      from public.sales s
      cross join lateral app.v106_reporting_contract(
        s.business_id, s.branch_id, s.occurred_at
      ) c
     where s.business_id = p_business
       and s.reversal_of is null
       and s.counts_as_visit
       and s.created_at <= p_as_of
       and (
         v_business_wide_identity
         or (p_branch is not null and s.branch_id = p_branch)
       )
  ), sequenced as (
    select e.*,
           min(e.occurred_at) over (partition by e.client_id) as first_ever_at,
           first_value((e.occurred_at at time zone e.timezone)::date) over (
             partition by e.client_id order by e.occurred_at, e.id
           ) as first_ever_business_date,
           lag(e.occurred_at) over (
             partition by e.client_id order by e.occurred_at, e.id
           ) as previous_purchase_at,
           row_number() over (
             partition by e.client_id order by e.occurred_at, e.id
           ) as purchase_sequence,
           ((e.occurred_at at time zone e.timezone)::date >= p_from
             and (e.occurred_at at time zone e.timezone)::date < p_to
             and (p_branch is null or e.branch_id = p_branch)) as in_selected_period
      from eligible e
     where e.residual_minor > 0
  ), interval_evidence as (
    -- v651: the canonical cadence computation (extracted verbatim from this CTE).
    select b.client_id, b.interval_observations, b.median_interval_days
      from app.customer_cadence_batch_v1(
        p_business, p_from, p_to, p_as_of, p_branch, v_business_wide_identity) b
  ), customer_activity as (
    select s.client_id,
           count(*) filter (where s.in_selected_period)::integer as period_purchases,
           count(distinct (s.occurred_at at time zone s.timezone)::date)
             filter (where s.in_selected_period)::integer as period_visit_days,
           min(s.occurred_at) filter (where s.in_selected_period) as first_period_at,
           min(s.first_ever_at) as first_ever_at,
           bool_or(
             (s.occurred_at at time zone s.timezone)::date < p_from
           ) as purchased_before_period
      from sequenced s
     where s.client_id is not null
     group by s.client_id
    having count(*) filter (where s.in_selected_period) > 0
  ), first_period_evidence as (
    select distinct on (s.client_id)
           s.client_id, s.previous_purchase_at, s.timezone,
           s.first_ever_business_date
      from sequenced s
      join customer_activity a
        on a.client_id = s.client_id and a.first_period_at = s.occurred_at
     where s.in_selected_period
     order by s.client_id, s.occurred_at, s.id
  ), classified as (
    select a.*,
           f.previous_purchase_at,
           f.first_ever_business_date,
           coalesce(i.interval_observations, 0) as interval_observations,
           i.median_interval_days,
           case
             when coalesce(i.interval_observations, 0)
                    >= v_policy.customer_interval_min_observations
               then greatest(
                 1.0,
                 i.median_interval_days * v_policy.reactivation_multiplier
               )
             else v_policy.fallback_lapse_days::numeric
           end as effective_lapse_days,
           case
             when coalesce(i.interval_observations, 0)
                    >= v_policy.customer_interval_min_observations
               then 'customer_median_interval'
             else 'business_fallback'
           end as lapse_evidence_source
      from customer_activity a
      join first_period_evidence f using (client_id)
      left join interval_evidence i using (client_id)
  ), totals as (
    select
      count(*)::bigint as transacting_identified_customers,
      count(*) filter (
        where first_ever_business_date >= p_from
          and first_ever_business_date < p_to
      )::bigint as new_customers,
      count(*) filter (where purchased_before_period)::bigint
        as existing_returning_customers,
      count(*) filter (where period_visit_days >= 2)::bigint
        as repeat_purchasers_in_period,
      count(*) filter (
        where purchased_before_period
          and previous_purchase_at is not null
          and extract(epoch from (first_period_at - previous_purchase_at)) / 86400.0
                > effective_lapse_days
      )::bigint as reactivated_customers,
      count(*) filter (
        where lapse_evidence_source = 'customer_median_interval'
      )::bigint as customer_cadence_classifications,
      count(*) filter (
        where lapse_evidence_source = 'business_fallback'
      )::bigint as fallback_classifications
    from classified
  ), transaction_coverage as (
    select
      count(*) filter (
        where (occurred_at at time zone timezone)::date >= p_from
          and (occurred_at at time zone timezone)::date < p_to
          and (p_branch is null or branch_id = p_branch)
          and residual_minor > 0
      )::bigint as eligible_transactions,
      count(*) filter (
        where (occurred_at at time zone timezone)::date >= p_from
          and (occurred_at at time zone timezone)::date < p_to
          and (p_branch is null or branch_id = p_branch)
          and residual_minor > 0 and client_id is not null
      )::bigint as identified_transactions,
      max(occurred_at) filter (
        where (occurred_at at time zone timezone)::date >= p_from
          and (occurred_at at time zone timezone)::date < p_to
          and (p_branch is null or branch_id = p_branch)
          and residual_minor > 0
      ) as latest_purchase_occurred_at
    from eligible
  )
  select jsonb_build_object(
    'contract_version', 'v107.1',
    'generated_at', clock_timestamp(),
    'as_of', p_as_of,
    'scope', jsonb_build_object(
      'business_id', p_business,
      'branch_id', p_branch,
      'period', jsonb_build_object(
        'from', p_from, 'to', p_to, 'interval', '[from,to)'
      ),
      'timezone', v_timezone,
      'timezone_contract', case when p_branch is null
        then 'per_outlet_effective_timezone'
        else 'selected_outlet_effective_timezone'
      end,
      'currency', v_currency,
      'identity_scope', case when v_business_wide_identity
        then 'business'
        else 'selected_branch'
      end,
      'period_activity_scope', case when p_branch is null then 'business' else 'branch' end
    ),
    'status', case when x.eligible_transactions = 0 then 'no_data' else 'ok' end,
    'policy', jsonb_build_object(
      'id', v_policy.id,
      'version_no', v_policy.version_no,
      'effective_from', v_policy.effective_from,
      'fallback_lapse_days', v_policy.fallback_lapse_days,
      'customer_interval_min_observations',
        v_policy.customer_interval_min_observations,
      'reactivation_multiplier', v_policy.reactivation_multiplier,
      'legacy_assumption', v_policy.legacy_assumption
    ),
    'metrics', jsonb_build_object(
      'transacting_identified_customers', t.transacting_identified_customers,
      'new_customers', t.new_customers,
      'existing_returning_customers', t.existing_returning_customers,
      'repeat_purchasers_in_period', t.repeat_purchasers_in_period,
      'reactivated_customers', t.reactivated_customers,
      'existing_customer_share_pct',
        case when t.transacting_identified_customers = 0 then null
          else round(
            100 * t.existing_returning_customers::numeric
              / t.transacting_identified_customers, 2
          ) end,
      'repeat_in_period_rate_pct',
        case when t.transacting_identified_customers = 0 then null
          else round(
            100 * t.repeat_purchasers_in_period::numeric
              / t.transacting_identified_customers, 2
          ) end,
      'customer_cadence_classifications', t.customer_cadence_classifications,
      'fallback_classifications', t.fallback_classifications
    ),
    'coverage', jsonb_build_object(
      'eligible_transactions', x.eligible_transactions,
      'identified_transactions', x.identified_transactions,
      'identified_transaction_pct',
        case when x.eligible_transactions = 0 then null
          else round(
            100 * x.identified_transactions::numeric / x.eligible_transactions, 2
          ) end
    ),
    'freshness', jsonb_build_object(
      'latest_purchase_occurred_at', x.latest_purchase_occurred_at
    ),
    'definitions', jsonb_build_object(
      'first_ever_purchase',
        'earliest eligible counts_as_visit purchase in the business',
      'new_customer',
        'first-ever business purchase has a local business date in [from,to)',
      'existing_returning_customer',
        'at least one eligible purchase before from and at least one in [from,to)',
      'repeat_purchaser_in_period',
        'at least two distinct Asia/Singapore-local (per-outlet effective timezone) visit-days with an eligible purchase in [from,to); not a synonym for returning, and not the same as two sale rows recorded on the same calendar day',
      'reactivated_customer',
        'existing customer whose first in-period purchase follows a lapse strictly greater than the effective threshold',
      'effective_threshold',
        'customer median interval multiplied by policy multiplier when evidence is sufficient; otherwise policy fallback days'
    ),
    'formula_metadata', jsonb_build_object(
      'version', 'customer_lifecycle_v107_1',
      'eligible_purchase',
        'original sale with counts_as_visit=true, residual amount above zero, and created_at<=as_of',
      'identity_attribution',
        'immutable sales.client_id is resolved through app.v111_effective_client_id for current synchronized reporting',
      'existing_customer_share',
        'existing_returning_customers / transacting_identified_customers',
      'repeat_in_period_rate',
        'repeat_purchasers_in_period / transacting_identified_customers',
      'zero_denominator', 'ratios are null',
      'lapse_comparison', 'gap_days > effective_lapse_days'
    ),
    'limitations', jsonb_build_array(
      'Anonymous purchases contribute to identity coverage but cannot be lifecycle-classified.',
      'Customer-specific cadence uses only pre-period intervals to avoid future leakage.',
      'The migration default is 90 days until an owner or super-admin publishes a business policy.',
      'Lifecycle is aggregate reporting only and does not expose customer PII.'
    )
  ) into v_result
  from totals t cross join transaction_coverage x;
  return v_result;
end $$;

revoke all on function public.get_customer_lifecycle_v107(
  uuid, date, date, uuid, timestamptz
) from public, anon;
grant execute on function public.get_customer_lifecycle_v107(
  uuid, date, date, uuid, timestamptz
) to authenticated;

-- Prove the diff is exactly the intended diff: three substitutions (the new period_visit_days
-- column, the totals filter that reads it, and the definitions text that describes it), nothing
-- else moved.
do $post$
declare
  v_before   text;
  v_after    text;
  v_expected text;
  v_clause_a constant text :=
E'           count(*) filter (where s.in_selected_period)::integer as period_purchases,
           min(s.occurred_at) filter (where s.in_selected_period) as first_period_at,';
  v_repl_a constant text :=
E'           count(*) filter (where s.in_selected_period)::integer as period_purchases,
           count(distinct (s.occurred_at at time zone s.timezone)::date)
             filter (where s.in_selected_period)::integer as period_visit_days,
           min(s.occurred_at) filter (where s.in_selected_period) as first_period_at,';
  v_clause_b constant text :=
E'      count(*) filter (where period_purchases >= 2)::bigint
        as repeat_purchasers_in_period,';
  v_repl_b constant text :=
E'      count(*) filter (where period_visit_days >= 2)::bigint
        as repeat_purchasers_in_period,';
  v_clause_c constant text :=
E'      \'repeat_purchaser_in_period\',
        \'at least two eligible purchases in [from,to); not a synonym for returning\',';
  v_repl_c constant text :=
E'      \'repeat_purchaser_in_period\',
        \'at least two distinct Asia/Singapore-local (per-outlet effective timezone) visit-days with an eligible purchase in [from,to); not a synonym for returning, and not the same as two sale rows recorded on the same calendar day\',';
begin
  select def into v_before from _v692_before;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = 'get_customer_lifecycle_v107';

  if position(v_clause_a in v_before) = 0 then
    raise exception 'v692: clause A (period_purchases/first_period_at) not found in the expected shape';
  end if;
  if position(v_clause_b in v_before) = 0 then
    raise exception 'v692: clause B (repeat_purchasers_in_period filter) not found in the expected shape';
  end if;
  if position(v_clause_c in v_before) = 0 then
    raise exception 'v692: clause C (repeat_purchaser_in_period definition text) not found in the expected shape';
  end if;

  v_expected := replace(replace(replace(v_before, v_clause_a, v_repl_a), v_clause_b, v_repl_b),
                         v_clause_c, v_repl_c);

  if v_after <> v_expected then
    raise exception
      'v692: the new get_customer_lifecycle_v107 differs from the old one by more than the three '
      'intended substitutions. Old:%  %New:%  %', E'\n', v_expected, E'\n', v_after;
  end if;

  if position('period_purchases >= 2' in v_after) > 0 then
    raise exception 'v692: the raw-count repeat_purchasers_in_period filter did not clear';
  end if;
  if position('period_visit_days' in v_after) = 0 then
    raise exception 'v692: period_visit_days did not land';
  end if;
end
$post$;

commit;
