-- NESTLY v742 -- synthetic-client exclusion, estate sweep 4 (CI-100 checklist checks 1, 5, 10).
-- Continues nestly_v687/v734/v737/v740. v740's own header named eight readers it found broken by
-- inspection but could not prove broken with its shared fixture in its time budget:
-- staff_list_returned_customers_v300, get_customer_lifecycle_v107, get_period_economics_v109,
-- get_revenue_driver_decomposition_v109, customer_get_business_presentation_v95,
-- preview_campaign_audience_v155, staff_list_customers_v129, get_campaign_results, and
-- app.get_growth_execution_result_at_v108. This migration works that list, by execution, one at
-- a time, not by re-grepping for "synthetic":
--
--   1. public.staff_list_returned_customers_v300 -- `visit_rows` read every sale with no
--      is_synthetic predicate at all (the same unfiltered-CTE shape retention_lapsed_
--      candidates_v244 had before nestly_v734). Proven with a DEDICATED away/return fixture (a
--      synthetic client given an old visit then a return visit 190 days later, closing an
--      80-day-away/30-day-window gap): before this fix, total_returned=2 and the synthetic
--      client's row was inside rows[]; a real client with the identical gap shape is correctly
--      present either way.
--   2. public.get_customer_lifecycle_v107 -- the `eligible` CTE (the source for every downstream
--      customer-activity and transaction-coverage figure) read `public.sales s` with no synthetic
--      predicate: metrics.transacting_identified_customers=6 instead of 5, coverage.
--      identified_transactions=10 instead of 8 (coverage.eligible_transactions is unaffected --
--      it is not identity-scoped, so it still correctly counts the 2 anonymous sales alongside
--      the 8 real ones once the synthetic client's 2 unreversed sales are excluded from it too).
--   3. public.preview_campaign_audience_v155 -- `customer_rows` selected `from public.clients
--      customer` with no is_synthetic filter (the same shape staff_list_customers_v154/v155 had
--      before nestly_v740): a synthetic client landing in an inactivity bucket inflated
--      matching_customers alongside a real client in the identical bucket.
--   4. public.staff_list_customers_v129 -- identical `customer_rows` shape to item 3, business-
--      wide with no branch or visit restriction at all: total counted every client row in the
--      business regardless of is_synthetic.
--   5. public.get_revenue_driver_decomposition_v109 -- BOTH `base` CTEs (current period and
--      comparison period, kept in sync as twins since v109's own convention) read `public.sales
--      sale` with no synthetic predicate: periods.current.revenue_cents=66000 instead of 60000,
--      periods.current.identified_revenue_cents=56000 instead of 50000, and the same shape
--      inflated the comparison period's figures by a second synthetic client placed there.
--   6. public.get_period_economics_v109 -- the `eligible` CTE (the sale population every other
--      CTE in this function derives from) read `public.sales sale` with no synthetic predicate:
--      coverage.eligible_sales=12 instead of 10, coverage.eligible_revenue_cents=66000 instead
--      of 60000.
--
-- CONFIRMED ALREADY CORRECT (read, not touched): public.customer_get_business_presentation_v95 is
-- a per-customer reader scoped to the caller's OWN verified `client_id` throughout (its `v_basis`
-- spend/points_earned/visits metric, balance, and tier progress all filter `client_id=v_client`);
-- a synthetic client reading their own presentation is unremarkable and it emits no firm-level
-- aggregate that could leak a synthetic client's figures into anyone else's view. No fix needed.
--
-- NOT FIXED, owed follow-ups: public.get_campaign_results and app.get_growth_execution_result_
-- at_v108 both compute per-member revenue/return figures scoped to an explicit membership table
-- (retention_campaign_members / growth_execution_members_v108) rather than a business-wide client
-- population -- neither reads `public.clients` or an unscoped `public.sales` at all. Proving
-- either broken requires a synthetic client deliberately enrolled as a campaign/execution member,
-- which does not fit this migration's shared population fixture without adding a second fixture
-- shape that means something different for every other assertion in it. Left for a migration with
-- its own dedicated membership fixture.
--
-- Every patch below is an anchored, comment-free replace-equality diff against the LIVE
-- pg_get_functiondef body -- same discipline as nestly_v668/v687/v714/v724/v734/v737/v740: capture
-- the body before, apply CREATE OR REPLACE, then assert the new body equals old-with-exactly-
-- this-substitution-and-nothing-else, or roll back the whole migration. ACLs are restated exactly
-- as they already are (CREATE OR REPLACE preserves existing grants; nothing here widens or
-- narrows anon/authenticated/service_role/public access, and app.analytics_sale_class_v1 itself
-- is untouched).
--
-- PROVEN BY: db/tests/executed/v742_corpus_synthetic_estate_4.sql -- the same 5 real clients /
-- 50000 cents / 8 visit-days plus 1 synthetic client with 3 sales (one fully reversed via a
-- native reversal_of row, unreversed net 6000) and 2 anonymous sales (10000 cents) v734/v737/v740
-- use, PLUS two dedicated pairs this migration's new candidates needed and v740's shared fixture
-- did not cover: a real+synthetic pair each with exactly one visit 65 days ago (the inactivity-
-- bucket proof for preview_campaign_audience_v155) and a real+synthetic pair each with an old
-- visit then a within-window return visit closing an 80-day+ gap (the away/return proof for
-- staff_list_returned_customers_v300). Each reader is called as its real principal: the firm
-- owner for owner-scoped reports, a non-owner staff row for plain staff_* reads, and a non-owner
-- manager row where the reader's own gate (staff_list_returned_customers_v300's `require_module_
-- scope_v145(p_business, null, 'retention')`) demands business-wide `can_see_branch`, which
-- app.can_see_branch never grants to a plain 'staff' role_class (only 'owner'/'admin' -- and
-- app.role_class maps 'manager' to 'admin').
--
-- ROLLBACK: each function's captured "before" body is available in this migration's own do-block
-- (re-run each CREATE OR REPLACE with the pre-image quoted in that block's comment).

begin;

create temp table _v742_before(fn text primary key, def text) on commit drop;

do $capture$
begin
  insert into _v742_before(fn, def)
  select 'staff_list_returned_customers_v300', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_list_returned_customers_v300'
  union all
  select 'get_customer_lifecycle_v107', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_customer_lifecycle_v107'
  union all
  select 'preview_campaign_audience_v155', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'preview_campaign_audience_v155'
  union all
  select 'staff_list_customers_v129', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_list_customers_v129'
  union all
  select 'get_revenue_driver_decomposition_v109', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_revenue_driver_decomposition_v109'
  union all
  select 'get_period_economics_v109', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_period_economics_v109';

  if (select count(*) from _v742_before) <> 6 then
    raise exception 'v742: expected exactly 6 captured function bodies, found %',
      (select count(*) from _v742_before);
  end if;
  if exists (select 1 from _v742_before where def ilike '%is_synthetic%') then
    raise exception 'v742: a target function already carries a synthetic-client exclusion -- '
      'stop and re-read before shipping';
  end if;
end
$capture$;

-- =============================================================================================
-- 1 · public.staff_list_returned_customers_v300
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.staff_list_returned_customers_v300(p_business uuid, p_away_days integer, p_window_days integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_cap constant integer := 50;
  v_away integer := greatest(1, least(365, coalesce(p_away_days, 60)));
  v_window integer := greatest(1, least(90, coalesce(p_window_days, 30)));
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_total bigint;
  v_rows jsonb;
begin
  -- Same gate as retention_lapsed_candidates_v244 (raises 42501 when out of scope).
  perform public.require_module_scope_v145(p_business, null, 'retention');

  with visit_rows as (
    select s.id, s.client_id, s.occurred_at, s.reversal_of
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.counts_as_visit = true
      and not sc.is_synthetic_client
  ),
  valid_visits as (
    -- validVisitSales, verbatim from v244: reversals are never visits; a reversed
    -- original is out. The two readers MUST agree on what a visit is.
    select v.client_id, v.occurred_at
    from visit_rows v
    where v.reversal_of is null
      and not exists (
        select 1 from visit_rows r where r.reversal_of = v.id
      )
  ),
  visit_days as (
    -- nestly_v724 (estate sweep 2): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699), anchored at the
    -- day's FIRST qualifying sale's occurred_at (same anchor rule as nestly_v709/v711/v714) --
    -- otherwise a same-day second sale on the RETURN visit itself becomes previous_visit_at and
    -- zeroes away_days, hiding a real multi-month lapse.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day,
           min(occurred_at) as occurred_at
    from valid_visits
    group by client_id, app.ci_visit_day_v699(occurred_at)
  ),
  ordered as (
    select vd.client_id, vd.occurred_at,
           lag(vd.occurred_at) over (partition by vd.client_id order by vd.occurred_at) as previous_visit_at,
           row_number() over (partition by vd.client_id order by vd.occurred_at desc) as recency
    from visit_days vd
  ),
  returned as (
    -- The LATEST visit per client, only when it closed a gap of >= v_away days and
    -- landed inside the last v_window days (Singapore calendar on both counts).
    select o.client_id,
           o.occurred_at as returned_at,
           ((o.occurred_at at time zone 'Asia/Singapore')::date
             - (o.previous_visit_at at time zone 'Asia/Singapore')::date)::integer as away_days
    from ordered o
    where o.recency = 1
      and o.previous_visit_at is not null
      and (v_today - (o.occurred_at at time zone 'Asia/Singapore')::date) <= v_window
      and ((o.occurred_at at time zone 'Asia/Singapore')::date
            - (o.previous_visit_at at time zone 'Asia/Singapore')::date) >= v_away
  )
  select count(*),
         coalesce(jsonb_agg(x.row order by x.returned_at desc)
                    filter (where x.rank <= v_cap), '[]'::jsonb)
    into v_total, v_rows
    from (
      select r.returned_at,
             row_number() over (order by r.returned_at desc, r.client_id) as rank,
             jsonb_build_object(
               'id', c.id,
               'full_name', c.full_name,
               'phone', c.phone,
               'away_days', r.away_days,
               'returned_at', r.returned_at
             ) as row
      from returned r
      join public.clients c on c.id = r.client_id and c.business_id = p_business
    ) x;

  return jsonb_build_object(
    'away_days', v_away,
    'window_days', v_window,
    'total_returned', coalesce(v_total, 0),
    'truncated', coalesce(v_total, 0) > v_cap,
    'rows', v_rows
  );
end
$function$;

do $check1$
declare v_before text; v_after text; v_expected text;
  v_old constant text := $lit$  with visit_rows as (
    select s.id, s.client_id, s.occurred_at, s.reversal_of
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_visit = true
  ),
$lit$;
  v_new constant text := $lit$  with visit_rows as (
    select s.id, s.client_id, s.occurred_at, s.reversal_of
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.counts_as_visit = true
      and not sc.is_synthetic_client
  ),
$lit$;
begin
  select def into v_before from _v742_before where fn = $lit$staff_list_returned_customers_v300$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_list_returned_customers_v300';
  if position(v_old in v_before) = 0 then
    raise exception 'v742/staff_list_returned_customers_v300: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v742/staff_list_returned_customers_v300: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check1$;

-- =============================================================================================
-- 2 · public.get_customer_lifecycle_v107
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_customer_lifecycle_v107(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid, p_as_of timestamp with time zone DEFAULT clock_timestamp())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
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
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and s.reversal_of is null
       and s.counts_as_visit
       and s.created_at <= p_as_of
       and not sc.is_synthetic_client
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
end $function$;

do $check2$
declare v_before text; v_after text; v_expected text;
  v_old constant text := $lit$      from public.sales s
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
  ), sequenced as ($lit$;
  v_new constant text := $lit$      from public.sales s
      cross join lateral app.v106_reporting_contract(
        s.business_id, s.branch_id, s.occurred_at
      ) c
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and s.reversal_of is null
       and s.counts_as_visit
       and s.created_at <= p_as_of
       and not sc.is_synthetic_client
       and (
         v_business_wide_identity
         or (p_branch is not null and s.branch_id = p_branch)
       )
  ), sequenced as ($lit$;
begin
  select def into v_before from _v742_before where fn = $lit$get_customer_lifecycle_v107$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_customer_lifecycle_v107';
  if position(v_old in v_before) = 0 then
    raise exception 'v742/get_customer_lifecycle_v107: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v742/get_customer_lifecycle_v107: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check2$;

-- =============================================================================================
-- 3 · public.preview_campaign_audience_v155
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.preview_campaign_audience_v155(p_business uuid, p_audience_key text, p_scope_mode text DEFAULT 'all'::text, p_branch_ids uuid[] DEFAULT ARRAY[]::uuid[], p_operational_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_scope_ids uuid[];
  v_label text;
  v_scope_is_whole_business boolean := false;
  v_buckets text[] := case
    when p_audience_key in ('inactive_30_59','30_59') then array['30_59']
    when p_audience_key in ('inactive_60_89','60_89') then array['60_89']
    when p_audience_key in ('inactive_90_plus','90_plus') then array['90_plus']
    when p_audience_key in ('inactive_60_plus') then array['60_89','90_plus']
    when p_audience_key in ('never','never_visited') then array['never']
    else null
  end;
  v_total integer;
  v_consent integer;
begin
  if v_buckets is null then
    raise exception 'unsupported_campaign_audience' using errcode='22023';
  end if;
  select coalesce(array_agg(scope.branch_id order by scope.branch_name),array[]::uuid[])
    into v_scope_ids
  from app.resolve_reporting_branch_scope_v155(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  ) scope;
  v_label := app.reporting_scope_label_v155(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  );
  select not exists(
    select 1
    from public.branches branch
    where branch.business_id = p_business
      and coalesce(branch.active,true)
      and not (branch.id = any(v_scope_ids))
  ) into v_scope_is_whole_business;

  with visit_facts as materialized (
    select sale.client_id,max(sale.occurred_at) as last_visit_at
    from public.sales sale
    where sale.business_id = p_business
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.occurred_at <= statement_timestamp()
      and sale.branch_id = any(v_scope_ids)
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
          and reversal.created_at <= statement_timestamp()
      )
    group by sale.client_id
  ), customer_scope as materialized (
    select distinct sale.client_id
    from public.sales sale
    where sale.business_id = p_business
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.branch_id = any(v_scope_ids)
  ), customer_rows as materialized (
    select customer.id,customer.marketing_consent,visit.last_visit_at,
      case when visit.last_visit_at is null then 'never'
        when ((statement_timestamp() at time zone 'Asia/Singapore')::date-
          (visit.last_visit_at at time zone 'Asia/Singapore')::date) between 30 and 59 then '30_59'
        when ((statement_timestamp() at time zone 'Asia/Singapore')::date-
          (visit.last_visit_at at time zone 'Asia/Singapore')::date) between 60 and 89 then '60_89'
        when ((statement_timestamp() at time zone 'Asia/Singapore')::date-
          (visit.last_visit_at at time zone 'Asia/Singapore')::date) >= 90 then '90_plus'
        else null
      end as bucket
    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and customer.is_synthetic = false
      and (
        v_scope_is_whole_business
        or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
      )
  ), eligible_rows as (
    select *
    from customer_rows customer
    where customer.bucket = any(v_buckets)
      and (customer.bucket <> 'never' or v_scope_is_whole_business)
  )
  select count(*)::integer,
         count(*) filter (where marketing_consent is true)::integer
    into v_total,v_consent
  from eligible_rows;

  return jsonb_build_object(
    'status','ok',
    'audience_key',p_audience_key,
    'scope',jsonb_build_object(
      'mode',p_scope_mode,
      'label',v_label,
      'branch_ids',to_jsonb(v_scope_ids),
      'wording',case when v_scope_is_whole_business
        then 'Business-wide audience'
        else 'Inactive in this branch scope'
      end
    ),
    'matching_customers',v_total,
    'unique_customers_after_deduplication',v_total,
    'eligible_notification_recipients',null,
    'consent_recorded',v_consent,
    'missing_or_unknown_consent',greatest(v_total-v_consent,0),
    'delivery_enabled',false,
    'message','Campaign delivery is not enabled yet. This preview is preparation-only.'
  );
end
$function$;

do $check3$
declare v_before text; v_after text; v_expected text;
  v_old constant text := $lit$    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and (
        v_scope_is_whole_business$lit$;
  v_new constant text := $lit$    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and customer.is_synthetic = false
      and (
        v_scope_is_whole_business$lit$;
begin
  select def into v_before from _v742_before where fn = $lit$preview_campaign_audience_v155$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'preview_campaign_audience_v155';
  if position(v_old in v_before) = 0 then
    raise exception 'v742/preview_campaign_audience_v155: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v742/preview_campaign_audience_v155: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check3$;

-- =============================================================================================
-- 4 · public.staff_list_customers_v129
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.staff_list_customers_v129(p_business uuid, p_search text DEFAULT NULL::text, p_inactive_days integer DEFAULT NULL::integer, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_as_of timestamptz := statement_timestamp();
  v_search text := lower(btrim(coalesce(p_search, '')));
  v_phone_search text := regexp_replace(coalesce(p_search, ''), '[^0-9]', '', 'g');
  v_cutoff_date date;
  v_loyalty_available boolean;
  v_program_enabled boolean;
  v_result jsonb;
begin
  if length(v_phone_search) = 10 and left(v_phone_search, 2) = '65' then
    v_phone_search := right(v_phone_search, 8);
  end if;
  if auth.uid() is null or not app.can_module_read(p_business, 'clients') then
    raise exception 'customer read access required' using errcode = '42501';
  end if;
  if p_inactive_days is not null and p_inactive_days not in (30, 60, 90) then
    raise exception 'inactive days must be 30, 60 or 90' using errcode = '22023';
  end if;
  if p_limit < 1 or p_limit > 100 then
    raise exception 'limit must be between 1 and 100' using errcode = '22023';
  end if;
  if p_offset < 0 or p_offset > 100000 then
    raise exception 'offset must be between 0 and 100000' using errcode = '22023';
  end if;

  v_cutoff_date := (v_as_of at time zone 'Asia/Singapore')::date - p_inactive_days;
  v_loyalty_available := app.metric_module_scope_available_v145(
    p_business, null, 'loyalty'
  );
  select exists (
    select 1
      from public.loyalty_programs program
     where program.business_id = p_business
       and coalesce(program.active, false)
       and program.configuration_status = 'published'
  ) into v_program_enabled;

  with visit_facts as materialized (
    select sale.client_id, max(sale.occurred_at) as last_visit_at
      from public.sales sale
     where sale.business_id = p_business
       and sale.client_id is not null
       and sale.counts_as_visit
       and sale.reversal_of is null
       and sale.occurred_at <= v_as_of
       and not exists (
         select 1 from public.sales reversal
          where reversal.business_id = sale.business_id
            and reversal.reversal_of = sale.id
            and reversal.created_at <= v_as_of
       )
     group by sale.client_id
  ), customer_rows as materialized (
    select customer.id, customer.full_name, customer.phone, customer.email,
      customer.birth_date, customer.marketing_consent, customer.created_at,
      visit.last_visit_at,
      case when visit.last_visit_at is null then null
        else ((v_as_of at time zone 'Asia/Singapore')::date -
          (visit.last_visit_at at time zone 'Asia/Singapore')::date)::integer
      end as days_since_last_visit
      from public.clients customer
      left join visit_facts visit on visit.client_id = customer.id
     where customer.business_id = p_business
       and customer.is_synthetic = false
       and (
         v_search = ''
         or position(v_search in lower(customer.full_name)) > 0
         or (length(v_phone_search) >= 4 and
           position(v_phone_search in coalesce(customer.phone_norm, '')) > 0)
       )
       and (
         p_inactive_days is null
         or visit.last_visit_at is null
         or (visit.last_visit_at at time zone 'Asia/Singapore')::date <= v_cutoff_date
       )
  ), page as materialized (
    select * from customer_rows customer
     order by
       case when p_inactive_days is not null and customer.last_visit_at is null then 0 else 1 end,
       case when p_inactive_days is not null then customer.last_visit_at end asc nulls first,
       case when p_inactive_days is null then customer.created_at end desc,
       customer.full_name, customer.id
     limit p_limit offset p_offset
  ), page_ledger as materialized (
    select ledger.client_id,
           greatest(coalesce(sum(ledger.points), 0), 0)::bigint as units
      from public.points_ledger ledger
      join page customer on customer.id = ledger.client_id
     where ledger.business_id = p_business
      and (app.programme_balance_scope_v312(p_business) = 'programme_pot' and ledger.programme_id is not distinct from app.live_balance_programme_v381(p_business))
     group by ledger.client_id
  ), page_batches as materialized (
    select batch.client_id,
           greatest(coalesce(sum(batch.remaining), 0), 0)::bigint as units
      from public.points_batches batch
      join page customer on customer.id = batch.client_id
     where batch.business_id = p_business
       and batch.remaining > 0
       and (batch.expires_at is null or batch.expires_at > v_as_of)
     group by batch.client_id
  ), page_credit as materialized (
    select ledger.client_id,
           greatest(coalesce(sum(ledger.amount_cents), 0), 0)::bigint as balance_cents
      from public.credit_ledger ledger
      join page customer on customer.id = ledger.client_id
     where ledger.business_id = p_business
     group by ledger.client_id
  ), page_balances as materialized (
    select customer.*,
      case
        when not v_loyalty_available then null::bigint
        when not v_program_enabled then 0::bigint
        else least(coalesce(points.units, 0), coalesce(batches.units, 0))
      end as points,
      case when v_loyalty_available
        then coalesce(credit.balance_cents, 0)
        else null::bigint
      end as balance_cents
      from page customer
      left join page_ledger points on points.client_id = customer.id
      left join page_batches batches on batches.client_id = customer.id
      left join page_credit credit on credit.client_id = customer.id
  )
  select jsonb_build_object(
    'status', 'ok',
    'as_of', v_as_of,
    'inactive_days', p_inactive_days,
    'loyalty_available', v_loyalty_available,
    'loyalty_program_enabled', v_program_enabled,
    'total', (select count(*) from customer_rows),
    'customers', coalesce((select jsonb_agg(jsonb_build_object(
      'id', customer.id,
      'full_name', customer.full_name,
      'phone', customer.phone,
      'email', customer.email,
      'birth_date', customer.birth_date,
      'marketing_consent', customer.marketing_consent,
      'created_at', customer.created_at,
      'last_visit_at', customer.last_visit_at,
      'days_since_last_visit', customer.days_since_last_visit,
      'points', customer.points,
      'balance_cents', customer.balance_cents
    ) order by
      case when p_inactive_days is not null and customer.last_visit_at is null then 0 else 1 end,
      case when p_inactive_days is not null then customer.last_visit_at end asc nulls first,
      case when p_inactive_days is null then customer.created_at end desc,
      customer.full_name, customer.id) from page_balances customer), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$function$;

do $check4$
declare v_before text; v_after text; v_expected text;
  v_old constant text := $lit$      from public.clients customer
      left join visit_facts visit on visit.client_id = customer.id
     where customer.business_id = p_business
       and (
         v_search = ''$lit$;
  v_new constant text := $lit$      from public.clients customer
      left join visit_facts visit on visit.client_id = customer.id
     where customer.business_id = p_business
       and customer.is_synthetic = false
       and (
         v_search = ''$lit$;
begin
  select def into v_before from _v742_before where fn = $lit$staff_list_customers_v129$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_list_customers_v129';
  if position(v_old in v_before) = 0 then
    raise exception 'v742/staff_list_customers_v129: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v742/staff_list_customers_v129: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check4$;

-- =============================================================================================
-- 5 · public.get_revenue_driver_decomposition_v109
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_revenue_driver_decomposition_v109(p_business uuid, p_current_from date, p_current_to date, p_comparison_from date, p_comparison_to date, p_branch uuid DEFAULT NULL::uuid, p_as_of timestamp with time zone DEFAULT statement_timestamp())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  c_total bigint:=0;
  c_identified bigint:=0;
  c_transactions integer:=0;
  c_clients integer:=0;
  c_total_transactions integer:=0;
  c_itemized_transactions integer:=0;
  c_itemized_revenue bigint:=0;
  p_total bigint:=0;
  p_identified bigint:=0;
  p_transactions integer:=0;
  p_clients integer:=0;
  p_total_transactions integer:=0;
  p_itemized_transactions integer:=0;
  p_itemized_revenue bigint:=0;
  c_anonymous bigint:=0;
  p_anonymous bigint:=0;
  c_coverage integer;
  p_coverage integer;
  c_itemized_transaction_coverage integer;
  p_itemized_transaction_coverage integer;
  c_itemized_revenue_coverage integer;
  p_itemized_revenue_coverage integer;
  p_frequency numeric;
  p_aov numeric;
  c_frequency numeric;
  c_aov numeric;
  d_customer bigint;
  d_frequency bigint;
  d_aov bigint;
  d_anonymous bigint;
  d_residual bigint;
  d_total bigint;
  d_sum bigint;
  v_available boolean:=false;
  v_reason text;
  v_currency text;
  v_currency_count integer;
begin
  perform app.v109_require_feature();
  perform app.v109_require_finance_scope(p_business,p_branch);
  if not app.can_module(p_business,'customerintel') then
    raise exception 'customerintel_module_required' using errcode='42501';
  end if;
  if p_current_from is null
     or p_current_to is null
     or p_comparison_from is null
     or p_comparison_to is null
     or p_current_from>=p_current_to
     or p_comparison_from>=p_comparison_to
     or p_as_of is null then
    raise exception 'valid local-date periods and as-of are required'
      using errcode='22023';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches branch
     where branch.id=p_branch and branch.business_id=p_business
  ) then
    raise exception 'branch does not belong to business' using errcode='22023';
  end if;

  select count(distinct contract.currency),min(contract.currency)
    into v_currency_count,v_currency
    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
   where sale.business_id=p_business
     and (p_branch is null or sale.branch_id=p_branch)
     and sale.counts_as_revenue
     and sale.reversal_of is null
     and sale.created_at<=p_as_of
     and (
       (
         (sale.occurred_at at time zone contract.timezone)::date>=p_current_from
         and
         (sale.occurred_at at time zone contract.timezone)::date<p_current_to
       ) or (
         (sale.occurred_at at time zone contract.timezone)::date>=
           p_comparison_from
         and
         (sale.occurred_at at time zone contract.timezone)::date<p_comparison_to
       )
     );
  if v_currency_count>1 then
    raise exception 'cross-currency driver comparisons are not supported'
      using errcode='22023';
  end if;
  if v_currency_count=0 then
    select upper(currency) into strict v_currency
      from public.businesses where id=p_business;
  end if;

  with base as (
    select
      app.v113_effective_client_id(sale.business_id,sale.client_id) as client_id,
      app.v106_sale_residual_minor(
        sale.id,p_current_to,p_as_of
      ) as amount_cents,
      exists (
        select 1
          from public.sale_items item
         where item.business_id=sale.business_id
           and item.sale_id=sale.id
           and item.line_cents>0
      ) as is_itemized
    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.counts_as_revenue
      and sale.reversal_of is null
      and not sc.is_synthetic_client
      and sale.created_at<=p_as_of
      and (sale.occurred_at at time zone contract.timezone)::date>=p_current_from
      and (sale.occurred_at at time zone contract.timezone)::date<p_current_to
      and app.v106_sale_residual_minor(
        sale.id,p_current_to,p_as_of
      )>0
  )
  select coalesce(sum(amount_cents),0),
    coalesce(sum(amount_cents) filter(where client_id is not null),0),
    count(*) filter(where client_id is not null),
    count(distinct client_id) filter(where client_id is not null),
    count(*),
    count(*) filter(where is_itemized),
    coalesce(sum(amount_cents) filter(where is_itemized),0)
  into c_total,c_identified,c_transactions,c_clients,
       c_total_transactions,c_itemized_transactions,c_itemized_revenue
  from base;

  with base as (
    select
      app.v113_effective_client_id(sale.business_id,sale.client_id) as client_id,
      app.v106_sale_residual_minor(
        sale.id,p_comparison_to,p_as_of
      ) as amount_cents,
      exists (
        select 1
          from public.sale_items item
         where item.business_id=sale.business_id
           and item.sale_id=sale.id
           and item.line_cents>0
      ) as is_itemized
    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.counts_as_revenue
      and sale.reversal_of is null
      and not sc.is_synthetic_client
      and sale.created_at<=p_as_of
      and (sale.occurred_at at time zone contract.timezone)::date>=
        p_comparison_from
      and (sale.occurred_at at time zone contract.timezone)::date<
        p_comparison_to
      and app.v106_sale_residual_minor(
        sale.id,p_comparison_to,p_as_of
      )>0
  )
  select coalesce(sum(amount_cents),0),
    coalesce(sum(amount_cents) filter(where client_id is not null),0),
    count(*) filter(where client_id is not null),
    count(distinct client_id) filter(where client_id is not null),
    count(*),
    count(*) filter(where is_itemized),
    coalesce(sum(amount_cents) filter(where is_itemized),0)
  into p_total,p_identified,p_transactions,p_clients,
       p_total_transactions,p_itemized_transactions,p_itemized_revenue
  from base;

  c_anonymous:=c_total-c_identified;
  p_anonymous:=p_total-p_identified;
  c_coverage:=case when c_total=0 then null
    else round(c_identified*10000.0/c_total)::integer end;
  p_coverage:=case when p_total=0 then null
    else round(p_identified*10000.0/p_total)::integer end;
  c_itemized_transaction_coverage:=case when c_total_transactions=0 then null
    else round(c_itemized_transactions*10000.0/c_total_transactions)::integer end;
  p_itemized_transaction_coverage:=case when p_total_transactions=0 then null
    else round(p_itemized_transactions*10000.0/p_total_transactions)::integer end;
  c_itemized_revenue_coverage:=case when c_total=0 then null
    else round(c_itemized_revenue*10000.0/c_total)::integer end;
  p_itemized_revenue_coverage:=case when p_total=0 then null
    else round(p_itemized_revenue*10000.0/p_total)::integer end;
  d_total:=c_total-p_total;
  v_available:=c_clients>0 and p_clients>0
    and c_transactions>0 and p_transactions>0;
  if v_available then
    p_frequency:=p_transactions::numeric/p_clients;
    p_aov:=p_identified::numeric/p_transactions;
    c_frequency:=c_transactions::numeric/c_clients;
    c_aov:=c_identified::numeric/c_transactions;
    d_customer:=round((c_clients-p_clients)*p_frequency*p_aov);
    d_frequency:=round(c_clients*(c_frequency-p_frequency)*p_aov);
    d_aov:=round(c_clients*c_frequency*(c_aov-p_aov));
    d_anonymous:=c_anonymous-p_anonymous;
    d_residual:=d_total-d_customer-d_frequency-d_aov-d_anonymous;
    d_sum:=d_customer+d_frequency+d_aov+d_anonymous+d_residual;
  else
    v_reason:=case
      when p_total=0 then 'comparison_period_has_no_revenue'
      when c_total=0 then 'current_period_has_no_revenue'
      when p_clients=0 or p_transactions=0
        then 'comparison_period_has_no_identified_customer_base'
      else 'current_period_has_no_identified_customer_base'
    end;
  end if;

  return jsonb_build_object(
    'contract_version','revenue_driver_decomposition_v109',
    'business_id',p_business,'as_of',p_as_of,'currency',v_currency,
    'status',case when v_available then 'ready' else 'unavailable' end,
    'unavailable_reason',v_reason,
    'identity_attribution','v111_current_effective_identity',
    'periods',jsonb_build_object(
      'comparison',jsonb_build_object(
        'from',p_comparison_from,'to',p_comparison_to,
        'basis','business_local_date','revenue_cents',p_total,
        'identified_revenue_cents',p_identified,
        'anonymous_revenue_cents',p_anonymous,
        'identified_customers',p_clients,
        'identified_transactions',p_transactions,
        'transactions',p_total_transactions,
        'itemized_transactions',p_itemized_transactions,
        'itemized_revenue_cents',p_itemized_revenue
      ),
      'current',jsonb_build_object(
        'from',p_current_from,'to',p_current_to,
        'basis','business_local_date','revenue_cents',c_total,
        'identified_revenue_cents',c_identified,
        'anonymous_revenue_cents',c_anonymous,
        'identified_customers',c_clients,
        'identified_transactions',c_transactions,
        'transactions',c_total_transactions,
        'itemized_transactions',c_itemized_transactions,
        'itemized_revenue_cents',c_itemized_revenue
      )
    ),
    'coverage',jsonb_build_object(
      'comparison_identified_revenue_bps',p_coverage,
      'current_identified_revenue_bps',c_coverage,
      'comparison_itemized_transaction_bps',p_itemized_transaction_coverage,
      'current_itemized_transaction_bps',c_itemized_transaction_coverage,
      'comparison_itemized_revenue_bps',p_itemized_revenue_coverage,
      'current_itemized_revenue_bps',c_itemized_revenue_coverage,
      'anonymous_revenue_is_separate_driver',true
    ),
    'line_item_analysis',jsonb_build_object(
      'status','coverage_only',
      'price_volume_mix_status','not_claimed',
      'reason',
        'line-level price and mix effects require complete itemization and a versioned taxonomy',
      'causal_claim',false
    ),
    'drivers',case when v_available then jsonb_build_object(
      'identified_customer_count_cents',d_customer,
      'purchase_frequency_cents',d_frequency,
      'average_transaction_value_cents',d_aov,
      'anonymous_revenue_cents',d_anonymous,
      'rounding_residual_cents',d_residual
    ) else 'null'::jsonb end,
    'reconciliation',jsonb_build_object(
      'period_revenue_delta_cents',d_total,
      'sum_driver_contributions_cents',d_sum,
      'rounding_residual_cents',d_residual,
      'reconciles',case when v_available then d_sum=d_total else null end
    ),
    'method',jsonb_build_object(
      'identity',
        'revenue = effective identified customers × purchase frequency × average transaction value + anonymous revenue',
      'identity_resolver','v111_current_effective_identity',
      'order',jsonb_build_array(
        'identified_customer_count','purchase_frequency',
        'average_transaction_value','anonymous_revenue','rounding_residual'
      ),
      'deterministic',true,'causal_claim',false
    )
  );
end
$function$;

do $check5$
declare v_before text; v_after text; v_expected text;
  v_old_current constant text := $lit$    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.counts_as_revenue
      and sale.reversal_of is null
      and sale.created_at<=p_as_of
      and (sale.occurred_at at time zone contract.timezone)::date>=p_current_from
      and (sale.occurred_at at time zone contract.timezone)::date<p_current_to
      and app.v106_sale_residual_minor(
        sale.id,p_current_to,p_as_of
      )>0
  )$lit$;
  v_new_current constant text := $lit$    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.counts_as_revenue
      and sale.reversal_of is null
      and not sc.is_synthetic_client
      and sale.created_at<=p_as_of
      and (sale.occurred_at at time zone contract.timezone)::date>=p_current_from
      and (sale.occurred_at at time zone contract.timezone)::date<p_current_to
      and app.v106_sale_residual_minor(
        sale.id,p_current_to,p_as_of
      )>0
  )$lit$;
  v_old_comparison constant text := $lit$    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.counts_as_revenue
      and sale.reversal_of is null
      and sale.created_at<=p_as_of
      and (sale.occurred_at at time zone contract.timezone)::date>=
        p_comparison_from
      and (sale.occurred_at at time zone contract.timezone)::date<
        p_comparison_to
      and app.v106_sale_residual_minor(
        sale.id,p_comparison_to,p_as_of
      )>0
  )$lit$;
  v_new_comparison constant text := $lit$    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.counts_as_revenue
      and sale.reversal_of is null
      and not sc.is_synthetic_client
      and sale.created_at<=p_as_of
      and (sale.occurred_at at time zone contract.timezone)::date>=
        p_comparison_from
      and (sale.occurred_at at time zone contract.timezone)::date<
        p_comparison_to
      and app.v106_sale_residual_minor(
        sale.id,p_comparison_to,p_as_of
      )>0
  )$lit$;
begin
  select def into v_before from _v742_before where fn = 'get_revenue_driver_decomposition_v109';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_revenue_driver_decomposition_v109';
  if position(v_old_current in v_before) = 0 then
    raise exception 'v742/get_revenue_driver_decomposition_v109: current-period anchor not found';
  end if;
  if position(v_old_comparison in v_before) = 0 then
    raise exception 'v742/get_revenue_driver_decomposition_v109: comparison-period anchor not found';
  end if;
  v_expected := replace(replace(v_before, v_old_current, v_new_current), v_old_comparison, v_new_comparison);
  if v_after <> v_expected then
    raise exception 'v742/get_revenue_driver_decomposition_v109: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check5$;

-- =============================================================================================
-- 6 · public.get_period_economics_v109
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_period_economics_v109(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid, p_investment_cents bigint DEFAULT NULL::bigint, p_investment_reference text DEFAULT NULL::text, p_as_of timestamp with time zone DEFAULT statement_timestamp())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_sales integer:=0;
  v_covered_sales integer:=0;
  v_sale_lines integer:=0;
  v_covered_sale_lines integer:=0;
  v_ambiguous_sale_lines integer:=0;
  v_revenue bigint:=0;
  v_covered_revenue bigint:=0;
  v_traceable_cogs bigint:=0;
  v_sale_transaction_coverage_bps integer;
  v_sale_revenue_coverage_bps integer;
  v_sale_coverage_passes boolean:=false;
  v_benefits integer:=0;
  v_covered_benefits integer:=0;
  v_benefit_value bigint:=0;
  v_covered_benefit_value bigint:=0;
  v_traceable_benefit_cost bigint:=0;
  v_benefit_coverage_bps integer;
  v_benefit_coverage_passes boolean:=true;
  v_deliveries integer:=0;
  v_covered_deliveries integer:=0;
  v_traceable_delivery_cost bigint:=0;
  v_delivery_coverage_bps integer;
  v_delivery_coverage_passes boolean:=true;
  v_coverage_passes boolean:=false;
  v_gross_profit bigint;
  v_contribution bigint;
  v_growth_investment bigint;
  v_total_investment bigint;
  v_net_return bigint;
  v_roi_bps bigint;
  v_unavailable jsonb:='[]'::jsonb;
  v_currency text;
  v_currency_count integer;
  v_extra_reference text;
begin
  perform app.v109_require_feature();
  perform app.v109_require_finance_scope(p_business,p_branch);
  if not app.can_module(p_business,'customerintel') then
    raise exception 'customerintel_module_required' using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_from>=p_to or p_as_of is null then
    raise exception 'valid half-open local-date period and as-of are required'
      using errcode='22023';
  end if;
  if p_investment_cents is not null and p_investment_cents<0 then
    raise exception 'investment cannot be negative' using errcode='22023';
  end if;
  if p_investment_cents>0
     and length(btrim(coalesce(p_investment_reference,'')))<3 then
    raise exception 'positive additional investment requires a source reference'
      using errcode='22023';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches branch_row
    where branch_row.id=p_branch and branch_row.business_id=p_business
  ) then
    raise exception 'branch does not belong to business' using errcode='22023';
  end if;

  select count(distinct contract.currency),min(contract.currency)
  into v_currency_count,v_currency
  from public.sales sale
  cross join lateral app.v106_reporting_contract(
    sale.business_id,sale.branch_id,sale.occurred_at
  ) contract
  where sale.business_id=p_business
    and (p_branch is null or sale.branch_id=p_branch)
    and sale.counts_as_revenue and sale.reversal_of is null
    and sale.created_at<=p_as_of
    and (sale.occurred_at at time zone contract.timezone)::date>=p_from
    and (sale.occurred_at at time zone contract.timezone)::date<p_to;
  if v_currency_count>1 then
    raise exception 'cross-currency reporting periods are not supported'
      using errcode='22023';
  end if;
  if v_currency_count=0 then
    select upper(currency) into strict v_currency
    from public.businesses where id=p_business;
  end if;

  with eligible as (
    select sale.*,contract.currency,
      app.v106_sale_residual_minor(
        sale.id,p_to,p_as_of
      ) as residual_cents
    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.counts_as_revenue and sale.reversal_of is null
      and not sc.is_synthetic_client
      and sale.created_at<=p_as_of
      and (sale.occurred_at at time zone contract.timezone)::date>=p_from
      and (sale.occurred_at at time zone contract.timezone)::date<p_to
      and app.v106_sale_residual_minor(sale.id,p_to,p_as_of)>0
  ), sale_shape as (
    select sale.*,
      exists(
        select 1 from public.sale_items item
        where item.business_id=p_business and item.sale_id=sale.id
      ) as is_itemized,
      coalesce((
        select sum(item.line_cents)
        from public.sale_items item
        where item.business_id=p_business and item.sale_id=sale.id
          and item.line_cents>0
      ),0)::bigint as positive_line_cents
    from eligible sale
  ), itemized_base as (
    select sale.id as sale_id,item.id as cost_line_key,
      sale.branch_id,sale.occurred_at,sale.currency,sale.kind as sale_kind,
      true as is_itemized,item.qty,item.line_cents as source_line_cents,
      case
        when item.item_type='retail' and item.product_id is not null
          then 'product'
        when item.item_type='service' and item.ref_id is not null
          then 'service'
        when item.item_type='package' and item.ref_id is not null
          then 'package'
        else null
      end as desired_scope_kind,
      case
        when item.item_type='retail' and item.product_id is not null
          then item.product_id::text
        when item.item_type in ('service','package') and item.ref_id is not null
          then item.ref_id::text
        else null
      end as desired_scope_key,
      sale.amount_cents as sale_original_cents,
      sale.residual_cents as sale_residual_cents,
      floor(
        sale.residual_cents::numeric*item.line_cents
        /sale.positive_line_cents
      )::bigint as allocated_base_cents,
      mod(
        sale.residual_cents::numeric*item.line_cents,
        sale.positive_line_cents
      ) as allocation_remainder
    from sale_shape sale
    join public.sale_items item
      on item.business_id=p_business and item.sale_id=sale.id
    where sale.is_itemized and sale.positive_line_cents>0
      and item.line_cents>0
  ), itemized_ranked as (
    select itemized_base.*,
      itemized_base.sale_residual_cents
        -sum(itemized_base.allocated_base_cents) over(
          partition by itemized_base.sale_id
        ) as remainder_to_assign,
      row_number() over(
        partition by itemized_base.sale_id
        order by itemized_base.allocation_remainder desc,
          itemized_base.cost_line_key
      ) as allocation_rank
    from itemized_base
  ), economic_lines as (
    select sale_id,cost_line_key,branch_id,occurred_at,currency,sale_kind,
      is_itemized,qty,source_line_cents,desired_scope_kind,desired_scope_key,
      sale_original_cents,sale_residual_cents,
      allocated_base_cents
        +case when allocation_rank<=remainder_to_assign then 1 else 0 end
        as allocated_cents
    from itemized_ranked
    union all
    -- An itemized parent with no positive economic line is never silently
    -- reclassified as a parent sale.  Keep one uncovered line so the report
    -- fails closed while still reconciling its full residual revenue.
    select sale.id,sale.id,sale.branch_id,sale.occurred_at,sale.currency,
      sale.kind,true,coalesce(sale.qty,1),greatest(sale.amount_cents,1),
      null::text,null::text,sale.amount_cents,sale.residual_cents,
      sale.residual_cents
    from sale_shape sale
    where sale.is_itemized and sale.positive_line_cents=0
    union all
    -- Sale-kind fallback exists only for genuinely non-itemized legacy rows.
    select sale.id,sale.id,sale.branch_id,sale.occurred_at,sale.currency,
      sale.kind,false,coalesce(sale.qty,1),greatest(sale.amount_cents,1),
      case when sale.product_id is not null then 'product' else 'sale_kind' end,
      case
        when sale.product_id is not null then sale.product_id::text
        else sale.kind
      end,
      sale.amount_cents,sale.residual_cents,
      sale.residual_cents
    from sale_shape sale
    where not sale.is_itemized
  ), candidate_pool as (
    select line.*,candidate.id as candidate_rule_id,
      candidate.cost_method,candidate.cost_value,
      candidate.effective_from,candidate.version_no,
      case
        when candidate.scope_kind=line.desired_scope_kind
          and candidate.scope_key=line.desired_scope_key then 0
        when not line.is_itemized and candidate.scope_kind='sale_kind'
          and candidate.scope_key=line.sale_kind then 1
        else 2
      end as scope_priority,
      case when candidate.branch_id=line.branch_id then 0 else 1 end
        as branch_priority
    from economic_lines line
    left join public.economic_cost_rules_v109 candidate
      on candidate.business_id=p_business
      and candidate.currency=line.currency
      and (candidate.branch_id is null or candidate.branch_id=line.branch_id)
      and candidate.effective_from<=line.occurred_at
      and (
        candidate.effective_to is null
        or candidate.effective_to>line.occurred_at
      )
      and (
        (
          candidate.scope_kind=line.desired_scope_kind
          and candidate.scope_key=line.desired_scope_key
        )
        or (
          not line.is_itemized
          and line.desired_scope_kind='product'
          and candidate.scope_kind='sale_kind'
          and candidate.scope_key=line.sale_kind
        )
      )
  ), ranked_candidates as (
    select candidate_pool.*,
      row_number() over(
        partition by sale_id,cost_line_key
        order by scope_priority,branch_priority,
          effective_from desc nulls last,version_no desc nulls last
      ) as selection_rank,
      count(candidate_rule_id) over(
        partition by sale_id,cost_line_key,scope_priority,branch_priority,
          effective_from
      ) as equal_precedence_rules
    from candidate_pool
  ), selected as (
    select *,
      candidate_rule_id is not null and equal_precedence_rules=1
        as is_covered,
      candidate_rule_id is not null and equal_precedence_rules>1
        as is_ambiguous,
      case
        when candidate_rule_id is null or equal_precedence_rules<>1 then null
        when cost_method='revenue_bps' then
          round(allocated_cents*cost_value::numeric/10000)::bigint
        when cost_method='fixed_per_unit' then
          round(
            cost_value*qty*sale_residual_cents::numeric
            /greatest(sale_original_cents,1)
          )::bigint
        else null
      end as cost_cents
    from ranked_candidates
    where selection_rank=1
  ), sale_summary as (
    select sale_id,count(*)::integer as eligible_lines,
      count(*) filter(where is_covered)::integer as covered_lines,
      count(*) filter(where is_ambiguous)::integer as ambiguous_lines,
      sum(allocated_cents)::bigint as revenue_cents,
      coalesce(sum(allocated_cents) filter(where is_covered),0)::bigint
        as covered_revenue_cents,
      coalesce(sum(cost_cents) filter(where is_covered),0)::bigint
        as cost_cents
    from selected
    group by sale_id
  )
  select count(*)::integer,
    count(*) filter(
      where covered_lines=eligible_lines and ambiguous_lines=0
    )::integer,
    coalesce(sum(eligible_lines),0)::integer,
    coalesce(sum(covered_lines),0)::integer,
    coalesce(sum(ambiguous_lines),0)::integer,
    coalesce(sum(revenue_cents),0)::bigint,
    coalesce(sum(covered_revenue_cents),0)::bigint,
    coalesce(sum(cost_cents),0)::bigint
  into v_sales,v_covered_sales,v_sale_lines,v_covered_sale_lines,
    v_ambiguous_sale_lines,v_revenue,v_covered_revenue,v_traceable_cogs
  from sale_summary;

  with eligible as (
    select entitlement.id,entitlement.value_cents,
      entitlement.entitlement_type,entitlement.redeemed_at,
      execution_row.branch_id,contract.currency
    from public.growth_entitlements_v108 entitlement
    join public.growth_executions_v108 execution_row
      on execution_row.id=entitlement.execution_id
      and execution_row.business_id=entitlement.business_id
    cross join lateral app.v106_reporting_contract(
      entitlement.business_id,execution_row.branch_id,entitlement.redeemed_at
    ) contract
    left join lateral (
      select event_row.sale_id,reversal_sale.occurred_at
      from public.growth_entitlement_events_v108 event_row
      join public.sales reversal_sale
        on reversal_sale.id=event_row.sale_id
        and reversal_sale.business_id=event_row.business_id
      where event_row.entitlement_id=entitlement.id
        and event_row.business_id=entitlement.business_id
        and event_row.event_type='reversed'
        and event_row.created_at<=p_as_of
        and reversal_sale.created_at<=p_as_of
        and reversal_sale.reversal_of=entitlement.redeemed_sale_id
      order by event_row.created_at desc,event_row.id desc
      limit 1
    ) reversal_evidence on true
    left join lateral app.v106_reporting_contract(
      entitlement.business_id,execution_row.branch_id,
      reversal_evidence.occurred_at
    ) reversal_contract on reversal_evidence.sale_id is not null
    where entitlement.business_id=p_business
      and (p_branch is null or execution_row.branch_id=p_branch)
      and entitlement.redeemed_at is not null
      and entitlement.redeemed_at<=p_as_of
      and (
        entitlement.reversed_at is null
        or entitlement.reversed_at>p_as_of
        or (
          entitlement.reversed_at<=p_as_of
          and reversal_evidence.sale_id is not null
          and (
            reversal_evidence.occurred_at
              at time zone reversal_contract.timezone
          )::date>=p_to
        )
      )
      and (
        entitlement.redeemed_at at time zone contract.timezone
      )::date>=p_from
      and (
        entitlement.redeemed_at at time zone contract.timezone
      )::date<p_to
  ), matched as (
    select benefit.id,benefit.value_cents,rule_row.id as rule_id,
      case
        when rule_row.cost_method='value_bps' then
          round(
            benefit.value_cents*rule_row.cost_value::numeric/10000
          )::bigint
        when rule_row.cost_method='fixed_per_event' then rule_row.cost_value
        else null
      end as cost_cents
    from eligible benefit
    left join lateral (
      select candidate.*
      from public.growth_cost_rules_v114 candidate
      where candidate.business_id=p_business
        and candidate.cost_class='benefit'
        and candidate.scope_key=benefit.entitlement_type
        and candidate.currency=benefit.currency
        and (
          candidate.branch_id is null
          or candidate.branch_id=benefit.branch_id
        )
        and candidate.effective_from<=benefit.redeemed_at
        and (
          candidate.effective_to is null
          or candidate.effective_to>benefit.redeemed_at
        )
      order by
        case when candidate.branch_id=benefit.branch_id then 0 else 1 end,
        candidate.effective_from desc,candidate.version_no desc
      limit 1
    ) rule_row on true
  )
  select count(*),count(*) filter(where rule_id is not null),
    coalesce(sum(value_cents),0),
    coalesce(sum(value_cents) filter(where rule_id is not null),0),
    coalesce(sum(cost_cents) filter(where rule_id is not null),0)
  into v_benefits,v_covered_benefits,v_benefit_value,
    v_covered_benefit_value,v_traceable_benefit_cost
  from matched;

  with eligible as (
    select dispatch.id,dispatch.branch_id,dispatch.provider,
      dispatch.delivered_at,contract.currency
    from public.growth_delivery_dispatches_v110 dispatch
    cross join lateral app.v106_reporting_contract(
      dispatch.business_id,dispatch.branch_id,dispatch.delivered_at
    ) contract
    where dispatch.business_id=p_business
      and (p_branch is null or dispatch.branch_id=p_branch)
      and dispatch.delivered_at is not null
      and dispatch.delivered_at<=p_as_of
      and (
        dispatch.delivered_at at time zone contract.timezone
      )::date>=p_from
      and (
        dispatch.delivered_at at time zone contract.timezone
      )::date<p_to
  ), matched as (
    select delivery.id,rule_row.id as rule_id,
      rule_row.cost_value as cost_cents
    from eligible delivery
    left join lateral (
      select candidate.*
      from public.growth_cost_rules_v114 candidate
      where candidate.business_id=p_business
        and candidate.cost_class='delivery'
        and candidate.scope_key=delivery.provider
        and candidate.currency=delivery.currency
        and (
          candidate.branch_id is null
          or candidate.branch_id=delivery.branch_id
        )
        and candidate.effective_from<=delivery.delivered_at
        and (
          candidate.effective_to is null
          or candidate.effective_to>delivery.delivered_at
        )
      order by
        case when candidate.branch_id=delivery.branch_id then 0 else 1 end,
        candidate.effective_from desc,candidate.version_no desc
      limit 1
    ) rule_row on true
  )
  select count(*),count(*) filter(where rule_id is not null),
    coalesce(sum(cost_cents) filter(where rule_id is not null),0)
  into v_deliveries,v_covered_deliveries,v_traceable_delivery_cost
  from matched;

  v_sale_transaction_coverage_bps:=case
    when v_sales=0 then null
    else round(v_covered_sales*10000.0/v_sales)::integer
  end;
  v_sale_revenue_coverage_bps:=case
    when v_revenue=0 then null
    else round(v_covered_revenue*10000.0/v_revenue)::integer
  end;
  v_sale_coverage_passes:=v_sales>0
    and v_sale_lines>0
    and v_covered_sales=v_sales
    and v_covered_sale_lines=v_sale_lines
    and v_ambiguous_sale_lines=0
    and v_covered_revenue=v_revenue;
  v_benefit_coverage_bps:=case
    when v_benefits=0 then null
    else round(v_covered_benefits*10000.0/v_benefits)::integer
  end;
  v_benefit_coverage_passes:=v_benefits=0
    or v_covered_benefits=v_benefits;
  v_delivery_coverage_bps:=case
    when v_deliveries=0 then null
    else round(v_covered_deliveries*10000.0/v_deliveries)::integer
  end;
  v_delivery_coverage_passes:=v_deliveries=0
    or v_covered_deliveries=v_deliveries;
  v_coverage_passes:=v_sale_coverage_passes
    and v_benefit_coverage_passes and v_delivery_coverage_passes;

  if v_sales=0 then
    v_unavailable:=v_unavailable||jsonb_build_array('no_eligible_sales');
  elsif not v_sale_coverage_passes then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('incomplete_traceable_sale_cost_coverage');
  end if;
  if v_ambiguous_sale_lines>0 then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('ambiguous_traceable_sale_cost_rules');
  end if;
  if not v_benefit_coverage_passes then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('incomplete_traceable_benefit_cost_coverage');
  end if;
  if not v_delivery_coverage_passes then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('incomplete_traceable_delivery_cost_coverage');
  end if;

  if v_coverage_passes then
    v_gross_profit:=v_revenue-v_traceable_cogs;
    v_contribution:=v_gross_profit-v_traceable_benefit_cost
      -v_traceable_delivery_cost;
    v_growth_investment:=v_traceable_benefit_cost+v_traceable_delivery_cost;
    v_total_investment:=v_growth_investment+coalesce(p_investment_cents,0);
    if v_total_investment>0 then
      v_net_return:=v_contribution-coalesce(p_investment_cents,0);
      v_roi_bps:=round(v_net_return*10000.0/v_total_investment);
    else
      v_unavailable:=v_unavailable
        ||jsonb_build_array('positive_traceable_investment_required');
    end if;
  end if;
  v_extra_reference:=nullif(btrim(coalesce(p_investment_reference,'')),'');

  return jsonb_build_object(
    'contract_version','period_economics_v109',
    'cost_contract_version','growth_costs_v114',
    'business_id',p_business,'as_of',p_as_of,
    'period',jsonb_build_object(
      'from',p_from,'to',p_to,'basis','business_local_date'
    ),
    'status',case
      when v_sales=0 then 'no_data'
      when v_coverage_passes then 'ready'
      else 'insufficient_cost_coverage'
    end,
    'coverage',jsonb_build_object(
      'cost_contract_version','growth_costs_v114',
      'eligible_sales',v_sales,'covered_sales',v_covered_sales,
      'eligible_sale_lines',v_sale_lines,
      'covered_sale_lines',v_covered_sale_lines,
      'ambiguous_sale_lines',v_ambiguous_sale_lines,
      'transaction_coverage_bps',v_sale_transaction_coverage_bps,
      'eligible_revenue_cents',v_revenue,
      'covered_revenue_cents',v_covered_revenue,
      'revenue_coverage_bps',v_sale_revenue_coverage_bps,
      'sale_cost_coverage_passes',v_sale_coverage_passes,
      'eligible_redeemed_benefits',v_benefits,
      'covered_redeemed_benefits',v_covered_benefits,
      'eligible_redeemed_benefit_value_cents',v_benefit_value,
      'covered_redeemed_benefit_value_cents',v_covered_benefit_value,
      'benefit_cost_coverage_bps',v_benefit_coverage_bps,
      'benefit_cost_coverage_passes',v_benefit_coverage_passes,
      'eligible_deliveries',v_deliveries,
      'covered_deliveries',v_covered_deliveries,
      'delivery_cost_coverage_bps',v_delivery_coverage_bps,
      'delivery_cost_coverage_passes',v_delivery_coverage_passes,
      'traceable_cost_coverage_passes',v_coverage_passes
    ),
    'profit',case when v_coverage_passes then jsonb_build_object(
      'currency',v_currency,'revenue_cents',v_revenue,
      'traceable_cogs_cents',v_traceable_cogs,
      'gross_profit_before_growth_costs_cents',v_gross_profit,
      'traceable_benefit_cost_cents',v_traceable_benefit_cost,
      'traceable_delivery_cost_cents',v_traceable_delivery_cost,
      'traceable_growth_cost_cents',
        v_traceable_benefit_cost+v_traceable_delivery_cost,
      'total_traceable_cost_cents',
        v_traceable_cogs+v_traceable_benefit_cost+v_traceable_delivery_cost,
      'contribution_after_growth_costs_cents',v_contribution,
      -- Compatibility alias: this is gross profit before growth costs.
      'gross_profit_cents',v_gross_profit
    ) else 'null'::jsonb end,
    'roi',case when v_roi_bps is not null then jsonb_build_object(
      'investment_cents',v_total_investment,
      'traceable_growth_investment_cents',v_growth_investment,
      'additional_investment_cents',coalesce(p_investment_cents,0),
      'investment_reference',case
        when v_extra_reference is null then 'v114 traceable benefit and delivery cost rules'
        else 'v114 traceable growth costs + '||v_extra_reference
      end,
      'additional_investment_reference',v_extra_reference,
      'net_return_cents',v_net_return,
      'return_on_investment_bps',v_roi_bps
    ) else 'null'::jsonb end,
    'unavailable_reasons',v_unavailable,
    'limitations',jsonb_build_array(
      'profit and contribution are returned only at complete sale-line, redeemed-benefit and delivery cost coverage',
      'itemized sale residuals, including in-period refunds, are allocated proportionally with deterministic largest-remainder rounding',
      'fixed unit costs preserve full unit COGS across checkout discounts and are reduced only by the sale refund survival ratio',
      'benefit reversals use the recorded reversal sale business date rather than the entitlement wall-clock update time',
      'sale-kind cost fallback is used only for genuinely non-itemized legacy sales',
      'ROI uses traceable redeemed-benefit and delivered-provider costs plus any separately sourced additional investment',
      'this period result is descriptive and is not a causal increment claim'
    )
  );
end $function$;

do $check6$
declare v_before text; v_after text; v_expected text;
  v_old constant text := $lit$  with eligible as (
    select sale.*,contract.currency,
      app.v106_sale_residual_minor(
        sale.id,p_to,p_as_of
      ) as residual_cents
    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.counts_as_revenue and sale.reversal_of is null
      and sale.created_at<=p_as_of
      and (sale.occurred_at at time zone contract.timezone)::date>=p_from
      and (sale.occurred_at at time zone contract.timezone)::date<p_to
      and app.v106_sale_residual_minor(sale.id,p_to,p_as_of)>0
  ), sale_shape as ($lit$;
  v_new constant text := $lit$  with eligible as (
    select sale.*,contract.currency,
      app.v106_sale_residual_minor(
        sale.id,p_to,p_as_of
      ) as residual_cents
    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.counts_as_revenue and sale.reversal_of is null
      and not sc.is_synthetic_client
      and sale.created_at<=p_as_of
      and (sale.occurred_at at time zone contract.timezone)::date>=p_from
      and (sale.occurred_at at time zone contract.timezone)::date<p_to
      and app.v106_sale_residual_minor(sale.id,p_to,p_as_of)>0
  ), sale_shape as ($lit$;
begin
  select def into v_before from _v742_before where fn = $lit$get_period_economics_v109$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_period_economics_v109';
  if position(v_old in v_before) = 0 then
    raise exception 'v742/get_period_economics_v109: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v742/get_period_economics_v109: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check6$;

-- ACLs restated exactly as live (CREATE OR REPLACE already preserves them -- this is an explicit
-- restatement for auditability, matching every prior grant, widening or narrowing nothing).
revoke all on function public.staff_list_returned_customers_v300(uuid,integer,integer) from public;
grant execute on function public.staff_list_returned_customers_v300(uuid,integer,integer) to public, postgres, anon, authenticated, service_role;

revoke all on function public.get_customer_lifecycle_v107(uuid,date,date,uuid,timestamp with time zone) from public;
grant execute on function public.get_customer_lifecycle_v107(uuid,date,date,uuid,timestamp with time zone) to postgres, authenticated, service_role;

revoke all on function public.preview_campaign_audience_v155(uuid,text,text,uuid[],uuid) from public;
grant execute on function public.preview_campaign_audience_v155(uuid,text,text,uuid[],uuid) to public, postgres, anon, authenticated, service_role;

revoke all on function public.staff_list_customers_v129(uuid,text,integer,integer,integer) from public;
grant execute on function public.staff_list_customers_v129(uuid,text,integer,integer,integer) to public, postgres, anon, authenticated, service_role;

revoke all on function public.get_revenue_driver_decomposition_v109(uuid,date,date,date,date,uuid,timestamp with time zone) from public;
grant execute on function public.get_revenue_driver_decomposition_v109(uuid,date,date,date,date,uuid,timestamp with time zone) to postgres, anon, authenticated, service_role;

revoke all on function public.get_period_economics_v109(uuid,date,date,uuid,bigint,text,timestamp with time zone) from public;
grant execute on function public.get_period_economics_v109(uuid,date,date,uuid,bigint,text,timestamp with time zone) to postgres, anon, authenticated, service_role;

commit;
